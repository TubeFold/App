from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

from scripts.youtube_summary_lib import (
    metadata_fields,
    processed_at_now,
    strip_outer_markdown_fence,
    validate_provider_response,
    yaml_front_matter,
)

from .config import AppConfig, PROJECT_ROOT
from .codex_settings import DEFAULT_CODEX_MODEL, DEFAULT_CODEX_REASONING_EFFORT, normalize_codex_settings
from .logging_utils import append_job_log
from .models import ProcessingError, ProcessingStatus
from .provider_setup import ProviderSetupStore
from .repository import Repository


logger = logging.getLogger(__name__)


class ProcessingQueue:
    def __init__(self, config: AppConfig, repository: Repository) -> None:
        self.config = config
        self.repository = repository
        self._condition = threading.Condition()
        self._stopped = False
        self._worker = threading.Thread(target=self._run, name="youtube-brain-processing", daemon=True)

    def start(self) -> None:
        logger.info("Starting processing queue provider=%s data_dir=%s", self.config.provider, self.config.data_dir)
        self._worker.start()
        self.enqueue_existing_queued_jobs()

    def stop(self) -> None:
        logger.info("Stopping processing queue")
        with self._condition:
            self._stopped = True
            self._condition.notify_all()
        self._worker.join(timeout=5)

    def enqueue_existing_queued_jobs(self) -> None:
        with self._condition:
            self._condition.notify_all()

    def notify(self) -> None:
        logger.info("Processing queue notified")
        with self._condition:
            self._condition.notify_all()

    def _run(self) -> None:
        while True:
            with self._condition:
                if self._stopped:
                    return
                jobs = self.repository.list_queued_jobs()
                if not jobs:
                    self._condition.wait(timeout=2)
                    continue
                job = jobs[0]
                logger.info("Dequeued job=%s video_id=%s", job["id"], job["video_id"])

            video = self.repository.get_video(job["video_id"])
            if video is None:
                logger.error("Skipping job=%s because video record is missing", job["id"])
                continue
            try:
                self.process_job(video_id=video["id"], job_id=job["id"])
            except ProcessingError as error:
                logger.error(
                    "Job failed job=%s video=%s code=%s message=%s details=%s",
                    job["id"],
                    video["youtube_video_id"],
                    error.code,
                    error.user_message,
                    error.technical_message,
                )
                self.repository.mark_failed(video["id"], job["id"], error.code, error.user_message)
            except Exception as error:  # noqa: BLE001
                logger.exception("Unexpected job failure job=%s video=%s", job["id"], video["youtube_video_id"])
                self.repository.mark_failed(video["id"], job["id"], "process_failed", str(error))

    def process_job(self, video_id: str, job_id: str) -> None:
        video = self.repository.get_video(video_id)
        if video is None:
            raise ProcessingError("video_missing", "Video record is missing.", f"Missing video {video_id}")

        job_dir = self.config.jobs_dir / job_id
        video_dir = self.config.videos_dir / video["youtube_video_id"]
        job_dir.mkdir(parents=True, exist_ok=True)
        video_dir.mkdir(parents=True, exist_ok=True)
        logger.info(
            "Starting job=%s local_video_id=%s youtube_id=%s title=%r job_dir=%s",
            job_id,
            video_id,
            video["youtube_video_id"],
            video["title"],
            job_dir,
        )
        append_job_log(job_dir, f"start job={job_id} local_video_id={video_id} youtube_id={video['youtube_video_id']}")

        input_json = {
            "videoId": video["youtube_video_id"],
            "url": video["canonical_url"],
            "title": video["title"],
            "channelName": video["channel_name"],
            "thumbnailURL": video["thumbnail_url"],
            "durationSeconds": video["duration_seconds"],
            "currentTimeAtRequest": video["current_time_at_request"],
        }
        self.repository.write_json(job_dir / "input.json", input_json)
        append_job_log(job_dir, "input.json written")

        logger.info("Job=%s status=%s", job_id, ProcessingStatus.FETCHING_METADATA.value)
        append_job_log(job_dir, f"status {ProcessingStatus.FETCHING_METADATA.value}")
        self.repository.mark_status(video_id, job_id, ProcessingStatus.FETCHING_METADATA)
        metadata_json = job_dir / "metadata.json"
        metadata = self._fetch_metadata(video["canonical_url"], video["youtube_video_id"], metadata_json)

        logger.info("Job=%s status=%s", job_id, ProcessingStatus.FETCHING_TRANSCRIPT.value)
        append_job_log(job_dir, f"status {ProcessingStatus.FETCHING_TRANSCRIPT.value}")
        self.repository.mark_status(video_id, job_id, ProcessingStatus.FETCHING_TRANSCRIPT)
        transcript_file = job_dir / "transcript.txt"
        transcript_info_json = job_dir / "transcript-info.json"
        self._fetch_transcript(video["youtube_video_id"], transcript_file, transcript_info_json, job_dir)
        transcript = transcript_file.read_text(encoding="utf-8")
        append_job_log(job_dir, f"transcript received chars={len(transcript)} path={transcript_file}")

        logger.info("Job=%s status=%s transcript_chars=%s", job_id, ProcessingStatus.GENERATING_SUMMARY.value, len(transcript))
        append_job_log(job_dir, f"status {ProcessingStatus.GENERATING_SUMMARY.value}")
        self.repository.mark_status(video_id, job_id, ProcessingStatus.GENERATING_SUMMARY)
        provider_output = job_dir / "provider-output.md"
        prompt_file = job_dir / "prompt.md"
        summary_file = job_dir / "summary.md"
        transcript_info = json.loads(transcript_info_json.read_text(encoding="utf-8"))
        self._render_prompt(metadata_json, transcript_file, transcript_info, prompt_file, video["canonical_url"], job_dir)
        self._run_provider(prompt_file, provider_output, job_dir)

        response = strip_outer_markdown_fence(provider_output.read_text(encoding="utf-8", errors="replace"))
        validate_provider_response(response)
        fields = metadata_fields(metadata, video["canonical_url"])
        markdown = self._build_markdown(fields, transcript_info, response)
        summary_file.write_text(markdown, encoding="utf-8")
        append_job_log(job_dir, f"summary.md written chars={len(markdown)} path={summary_file}")

        final_transcript = video_dir / "transcript.txt"
        final_metadata = video_dir / "metadata.json"
        final_summary = video_dir / "summary.md"
        shutil.copyfile(transcript_file, final_transcript)
        shutil.copyfile(metadata_json, final_metadata)
        shutil.copyfile(summary_file, final_summary)

        self.repository.mark_ready(video_id, job_id, final_transcript, final_summary, markdown, fields)
        append_job_log(job_dir, f"ready summary_path={final_summary}")
        logger.info(
            "Job ready job=%s youtube_id=%s summary_chars=%s summary_path=%s",
            job_id,
            video["youtube_video_id"],
            len(markdown),
            final_summary,
        )

    def _fetch_metadata(self, url: str, video_id: str, output_json: Path) -> dict[str, Any]:
        script = PROJECT_ROOT / "scripts" / "get-video-metadata.sh"
        if shutil.which("yt-dlp") is None:
            logger.info("yt-dlp not found; using fallback metadata video=%s", video_id)
            metadata = {
                "id": video_id,
                "title": video_id,
                "webpage_url": url,
                "channel": "",
                "duration": None,
                "upload_date": "",
            }
            self.repository.write_json(output_json, metadata)
            append_job_log(output_json.parent, "metadata fallback because yt-dlp is unavailable")
            return metadata

        completed = self._run_process([str(script), url, str(output_json)], output_json.parent, timeout=120, label="metadata")
        if completed.returncode != 0:
            logger.warning("Metadata fetch failed video=%s exit=%s; using fallback", video_id, completed.returncode)
            metadata = {
                "id": video_id,
                "title": video_id,
                "webpage_url": url,
                "channel": "",
                "duration": None,
                "upload_date": "",
            }
            self.repository.write_json(output_json, metadata)
            append_job_log(output_json.parent, f"metadata fallback because yt-dlp exited {completed.returncode}")
            return metadata
        full_metadata = json.loads(output_json.read_text(encoding="utf-8"))
        fields = metadata_fields(full_metadata, url)
        compact_metadata = {
            "id": fields["video_id"],
            "title": fields["title"],
            "channel": fields["channel"],
            "duration": fields["duration_seconds"],
            "upload_date": str(fields["published_at"]).replace("-", "") if fields["published_at"] else "",
            "webpage_url": fields["url"],
        }
        self.repository.write_json(output_json, compact_metadata)
        append_job_log(
            output_json.parent,
            f"metadata fetched title={fields['title']!r} channel={fields['channel']!r} duration_seconds={fields['duration_seconds']}",
        )
        logger.info(
            "Metadata fetched video=%s title=%r channel=%r duration=%s",
            video_id,
            fields["title"],
            fields["channel"],
            fields["duration_seconds"],
        )
        return compact_metadata

    def _fetch_transcript(self, video_id: str, transcript_file: Path, info_json: Path, job_dir: Path) -> None:
        script = PROJECT_ROOT / "scripts" / "fetch-transcript.py"
        if not Path(self.config.python_executable).exists():
            raise ProcessingError(
                "python_not_found",
                "Python executable was not found.",
                self.config.python_executable,
            )
        completed = self._run_process(
            [
                self.config.python_executable,
                str(script),
                video_id,
                str(transcript_file),
                str(info_json),
                "--preferred-langs",
                os.environ.get("PREFERRED_TRANSCRIPT_LANGS", "pl,ru,en"),
                "--allow-any",
                os.environ.get("ALLOW_ANY_TRANSCRIPT_LANGUAGE", "true"),
            ],
            job_dir,
            timeout=120,
            label="transcript",
        )
        if completed.returncode != 0:
            raise ProcessingError("transcript_unavailable", "Transcript is unavailable for this video.", completed.stderr)
        if not transcript_file.exists() or not transcript_file.read_text(encoding="utf-8").strip():
            raise ProcessingError("transcript_empty", "Transcript is empty.", str(transcript_file))
        info = json.loads(info_json.read_text(encoding="utf-8"))
        chars = len(transcript_file.read_text(encoding="utf-8"))
        append_job_log(
            job_dir,
            f"transcript fetched language={info.get('language_code')} generated={info.get('is_generated')} chars={chars}",
        )
        logger.info(
            "Transcript fetched video=%s language=%s generated=%s chars=%s",
            video_id,
            info.get("language_code"),
            info.get("is_generated"),
            chars,
        )

    def _render_prompt(
        self,
        metadata_json: Path,
        transcript_file: Path,
        transcript_info: dict[str, Any],
        prompt_file: Path,
        fallback_url: str,
        job_dir: Path,
    ) -> None:
        script = PROJECT_ROOT / "scripts" / "render-prompt.py"
        template = PROJECT_ROOT / "prompts" / "detailed-summary.md"
        language = transcript_language_label(transcript_info)
        completed = self._run_process(
            [
                self.config.python_executable,
                str(script),
                str(template),
                str(metadata_json),
                str(transcript_file),
                language,
                str(prompt_file),
                "--fallback-url",
                fallback_url,
            ],
            job_dir,
            timeout=60,
            label="prompt",
        )
        if completed.returncode != 0:
            raise ProcessingError("prompt_failed", "Could not render prompt.", completed.stderr)
        append_job_log(job_dir, f"prompt rendered chars={prompt_file.stat().st_size} path={prompt_file}")
        logger.info("Prompt rendered job_dir=%s bytes=%s", job_dir, prompt_file.stat().st_size)

    def _run_provider(self, prompt_file: Path, output_file: Path, job_dir: Path) -> None:
        provider = PROJECT_ROOT / "providers" / f"{self.config.provider}.sh"
        if not provider.exists():
            raise ProcessingError("provider_not_found", "Summary provider was not found.", str(provider))
        env = os.environ.copy()
        env["CODEX_TIMEOUT_SECONDS"] = str(self.config.codex_timeout_seconds)
        codex_settings = self._codex_settings()
        if self.config.provider == "codex":
            env["CODEX_MODEL"] = codex_settings["model"]
            env["CODEX_REASONING_EFFORT"] = codex_settings["reasoning_effort"]
            append_job_log(
                job_dir,
                f"provider settings model={codex_settings['model']} reasoning_effort={codex_settings['reasoning_effort']}",
            )
            logger.info(
                "Provider settings provider=codex model=%s reasoning_effort=%s",
                codex_settings["model"],
                codex_settings["reasoning_effort"],
            )
        completed = self._run_process(
            [str(provider), str(prompt_file), str(output_file)],
            job_dir,
            timeout=self.config.codex_timeout_seconds + 30,
            env=env,
            label=f"provider-{self.config.provider}",
        )
        if completed.returncode != 0:
            code = "codex_process_failed" if self.config.provider == "codex" else "summary_process_failed"
            raise ProcessingError(code, "Could not generate summary.", completed.stderr)
        if not output_file.exists() or not output_file.read_text(encoding="utf-8", errors="replace").strip():
            raise ProcessingError("summary_empty", "Summary output is empty.", str(output_file))
        output_chars = len(output_file.read_text(encoding="utf-8", errors="replace"))
        append_job_log(job_dir, f"provider completed provider={self.config.provider} output_chars={output_chars}")
        logger.info("Provider completed provider=%s output_chars=%s output=%s", self.config.provider, output_chars, output_file)

    def _codex_settings(self) -> dict[str, str]:
        if self.config.provider != "codex":
            return {"model": "", "reasoning_effort": ""}
        try:
            state = ProviderSetupStore(self.config).load()
        except (OSError, ValueError):
            state = {}
        state = normalize_codex_settings(
            {
                "codexModel": state.get("codexModel") or self.config.codex_model or DEFAULT_CODEX_MODEL,
                "codexReasoningEffort": state.get("codexReasoningEffort")
                or self.config.codex_reasoning_effort
                or DEFAULT_CODEX_REASONING_EFFORT,
            }
        )
        return {
            "model": str(state["codexModel"]),
            "reasoning_effort": str(state["codexReasoningEffort"]),
        }

    def _run_process(
        self,
        args: list[str],
        cwd: Path,
        timeout: int,
        env: dict[str, str] | None = None,
        label: str = "process",
    ) -> subprocess.CompletedProcess[str]:
        stdout_log = cwd / f"{label}.stdout.log"
        stderr_log = cwd / f"{label}.stderr.log"
        command_for_log = " ".join(args)
        append_job_log(cwd, f"process start label={label} timeout={timeout}s cwd={cwd} argv={command_for_log}")
        logger.info("Process start label=%s timeout=%ss cwd=%s argv=%s", label, timeout, cwd, command_for_log)
        started = time.monotonic()
        try:
            completed = subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=timeout, env=env)
        except subprocess.TimeoutExpired as error:
            stdout_log.write_text(error.stdout or "", encoding="utf-8")
            stderr_log.write_text(error.stderr or "", encoding="utf-8")
            append_job_log(cwd, f"process timeout label={label} timeout={timeout}s")
            logger.error("Process timeout label=%s timeout=%ss", label, timeout)
            raise ProcessingError("process_timeout", "Processing timed out.", " ".join(args)) from error
        stdout_log.write_text(completed.stdout or "", encoding="utf-8")
        stderr_log.write_text(completed.stderr or "", encoding="utf-8")
        elapsed = time.monotonic() - started
        append_job_log(
            cwd,
            "process exit "
            f"label={label} code={completed.returncode} elapsed={elapsed:.2f}s "
            f"stdout_bytes={len(completed.stdout or '')} stderr_bytes={len(completed.stderr or '')} "
            f"stdout={stdout_log.name} stderr={stderr_log.name}",
        )
        logger.info(
            "Process exit label=%s code=%s elapsed=%.2fs stdout_bytes=%s stderr_bytes=%s",
            label,
            completed.returncode,
            elapsed,
            len(completed.stdout or ""),
            len(completed.stderr or ""),
        )
        return completed

    def _build_markdown(self, fields: dict[str, Any], transcript_info: dict[str, Any], response: str) -> str:
        codex_settings = self._codex_settings()
        provider_label = self.config.provider
        if self.config.provider == "codex":
            provider_label = f"codex {codex_settings['model']}"

        metadata = {
            "type": "youtube-summary",
            "source": "youtube",
            "video_id": fields["video_id"],
            "url": fields["url"],
            "title": fields["title"],
            "channel": fields["channel"],
            "duration_seconds": fields["duration_seconds"],
            "published_at": fields["published_at"],
            "processed_at": processed_at_now(),
            "subtitle_language": transcript_info.get("language_code", ""),
            "transcript_language": transcript_info.get("language", ""),
            "transcript_language_code": transcript_info.get("language_code", ""),
            "transcript_is_generated": bool(transcript_info.get("is_generated")),
            "provider": provider_label,
            "prompt_template": "detailed-summary",
        }
        if self.config.provider == "codex":
            metadata["codex_model"] = codex_settings["model"]
            metadata["codex_reasoning_effort"] = codex_settings["reasoning_effort"]

        front_matter = yaml_front_matter(
            metadata
        )
        return front_matter + response.strip() + "\n"


def transcript_language_label(transcript_info: dict[str, Any]) -> str:
    language = str(transcript_info.get("language") or "").strip()
    code = str(transcript_info.get("language_code") or "").strip()
    generated = "auto" if transcript_info.get("is_generated") else "manual"
    if language and code and language != code:
        return f"{language} ({code}, {generated})"
    return f"{code or language or 'unknown'} ({generated})"
