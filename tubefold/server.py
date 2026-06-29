from __future__ import annotations

import argparse
import json
import logging
import re
import shutil
import time
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import ThreadingMixIn
from typing import Any

from scripts.tubefold_lib import normalize_youtube_url, parse_youtube_video_id, youtube_thumbnail_url

from . import API_VERSION, APP_VERSION
from .config import AppConfig, load_config
from .logging_utils import configure_logging
from .models import ProcessingStatus, SummaryRequest
from .processing import ProcessingQueue
from .provider_setup import (
    DESCRIPTORS,
    ProviderSetupStore,
    diagnostics_for,
    provider_summaries,
    selected_diagnostics,
)
from .reading_time import reading_minutes_for_markdown
from .repository import Repository
from .telegraph import TelegraphError, TelegraphPublisher


logger = logging.getLogger(__name__)


class TubeFoldServer(ThreadingHTTPServer):
    def __init__(self, config: AppConfig, repository: Repository, queue: ProcessingQueue) -> None:
        super().__init__((config.host, config.port), RequestHandler)
        self.config = config
        self.repository = repository
        self.queue = queue


class RequestHandler(BaseHTTPRequestHandler):
    server: TubeFoldServer

    def log_message(self, format: str, *args: Any) -> None:
        logger.info("HTTP %s - %s", self.address_string(), format % args)

    def do_OPTIONS(self) -> None:
        logger.info("OPTIONS path=%s origin=%s", self.path, self.headers.get("Origin"))
        self._note_extension_origin()
        self._send_json({}, status=HTTPStatus.NO_CONTENT)

    def do_GET(self) -> None:
        logger.info("GET path=%s origin=%s", self.path, self.headers.get("Origin"))
        self._note_extension_origin()
        if self.path == "/health":
            self._send_json(
                {
                    "status": "ok",
                    "appVersion": APP_VERSION,
                    "apiVersion": API_VERSION,
                    "backendFeatures": {
                        "codexModelSettings": True,
                        "libraryRegenerate": True,
                        "unlimitedTranscripts": True,
                        "telegraphPublish": True,
                        "outputLanguageSetting": True,
                        "readingTime": True,
                        "claudeProvider": True,
                        "usageStats": True,
                        "watchActivity": True,
                        "libraryDelete": True,
                        "resetData": True,
                    },
                }
            )
            return

        if self.path == "/api/v1/provider-setup":
            if not self._authorized():
                return
            diagnostics = selected_diagnostics(self.server.config)
            self._send_json(
                {
                    "provider": diagnostics.provider_id,
                    "state": diagnostics.state(),
                    "providers": provider_summaries(self.server.config),
                    **diagnostics.model_options(),
                }
            )
            return

        if self.path == "/api/v1/videos":
            if not self._authorized():
                return
            jobs_dir = self.server.config.jobs_dir
            videos = [self._video_payload(video, jobs_dir) for video in self.server.repository.list_videos()]
            self._send_json({"videos": videos})
            return

        if self.path == "/api/v1/usage":
            if not self._authorized():
                return
            self._send_json(self.server.repository.usage_summary())
            return

        if self.path == "/api/v1/extension-status":
            if not self._authorized():
                return
            last_seen = self.server.repository.extension_last_seen()
            self._send_json(
                {
                    "connected": _extension_connected(last_seen),
                    "lastSeenAt": last_seen,
                }
            )
            return

        if self.path == "/api/v1/watch-activity":
            if not self._authorized():
                return
            row = self.server.repository.latest_watch_suggestion()
            self._send_json({"suggestion": self._watch_suggestion_payload(row) if row else None})
            return

        match = re.fullmatch(r"/api/v1/jobs/([^/?]+)", self.path)
        if match:
            if not self._authorized():
                return
            job = self.server.repository.get_job(match.group(1))
            if job is None:
                logger.warning("Job lookup miss job=%s", match.group(1))
                self._send_error("not_found", "Job was not found.", HTTPStatus.NOT_FOUND)
                return
            self._send_json(
                {
                    "jobId": job["id"],
                    "status": job["status"],
                    "progress": None,
                    "error": job["error_message"],
                }
            )
            return

        match = re.fullmatch(r"/api/v1/videos/by-youtube-id/([^/?]+)", self.path)
        if match:
            if not self._authorized():
                return
            youtube_id = match.group(1)
            video = self.server.repository.get_video_by_youtube_id(youtube_id)
            if video is None:
                logger.info("Video lookup youtube_id=%s exists=false", youtube_id)
                self._send_json({"exists": False})
                return
            logger.info("Video lookup youtube_id=%s exists=true local_video_id=%s status=%s", youtube_id, video["id"], video["status"])
            self._send_json({"exists": True, "videoId": video["id"], "status": video["status"]})
            return

        self._send_error("not_found", "Endpoint was not found.", HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        logger.info("POST path=%s origin=%s content_length=%s", self.path, self.headers.get("Origin"), self.headers.get("Content-Length"))
        self._note_extension_origin()
        if not self._authorized():
            return

        if self.path == "/api/v1/summaries":
            data = self._read_json_body()
            if data is None:
                return
            try:
                raw_url = str(data.get("url") or data.get("canonicalURL") or "")
                video_id = parse_youtube_video_id(str(data.get("videoId") or raw_url))
                canonical_url = normalize_youtube_url(raw_url or video_id)
                request = SummaryRequest.from_json(data, video_id, canonical_url)
            except ValueError:
                logger.warning("Invalid summary request url=%r videoId=%r", data.get("url"), data.get("videoId"))
                self._send_error("invalid_youtube_url", "The URL is not a supported YouTube video.", HTTPStatus.BAD_REQUEST)
                return

            logger.info(
                "Summary request youtube_id=%s canonical_url=%s title=%r source=%s",
                request.video_id,
                request.url,
                request.title,
                request.source,
            )
            status, video_record_id, job_id = self.server.repository.create_or_reuse(request)
            logger.info(
                "Summary request result youtube_id=%s status=%s local_video_id=%s job=%s",
                request.video_id,
                status,
                video_record_id,
                job_id or None,
            )
            if status == "queued":
                self.server.queue.notify()
                self._send_json({"jobId": job_id, "videoId": video_record_id, "status": "queued"}, HTTPStatus.ACCEPTED)
            elif status == "already_processing":
                self._send_json({"jobId": job_id, "videoId": video_record_id, "status": "already_processing"})
            else:
                self._send_json({"jobId": None, "videoId": video_record_id, "status": "already_exists"})
            return

        if self.path == "/api/v1/watch-activity":
            data = self._read_json_body()
            if data is None:
                return
            try:
                raw_url = str(data.get("url") or data.get("canonicalURL") or "")
                video_id = parse_youtube_video_id(str(data.get("videoId") or raw_url))
                canonical_url = normalize_youtube_url(raw_url or video_id)
            except ValueError:
                logger.warning("Invalid watch activity url=%r videoId=%r", data.get("url"), data.get("videoId"))
                self._send_error("invalid_youtube_url", "The URL is not a supported YouTube video.", HTTPStatus.BAD_REQUEST)
                return
            self.server.repository.record_watch_activity(
                youtube_video_id=video_id,
                canonical_url=canonical_url,
                title=(str(data["title"]) if data.get("title") else None),
                channel_name=(str(data["channelName"]) if data.get("channelName") else None),
                thumbnail_url=(str(data["thumbnailURL"]) if data.get("thumbnailURL") else None),
                duration_seconds=_optional_float(data.get("durationSeconds")),
            )
            logger.info("Watch activity recorded youtube_id=%s source=%s", video_id, data.get("source"))
            self._send_json({"status": "recorded"})
            return

        if self.path == "/api/v1/watch-activity/dismiss":
            data = self._read_json_body()
            if data is None:
                return
            try:
                youtube_id = parse_youtube_video_id(str(data.get("youtubeVideoID") or data.get("videoId") or ""))
            except ValueError:
                self._send_error("invalid_youtube_url", "A valid YouTube video id is required.", HTTPStatus.BAD_REQUEST)
                return
            self.server.repository.dismiss_watch_activity(youtube_id)
            logger.info("Watch activity dismissed youtube_id=%s", youtube_id)
            self._send_json({"status": "dismissed"})
            return

        if self.path == "/api/v1/reset":
            removed = self.server.repository.reset()
            # Best-effort cleanup of on-disk artifacts so nothing lingers after the
            # database is wiped. The dirs are recreated lazily on the next job.
            for directory in (
                self.server.config.videos_dir,
                self.server.config.jobs_dir,
                self.server.config.logs_dir,
            ):
                shutil.rmtree(directory, ignore_errors=True)
                directory.mkdir(parents=True, exist_ok=True)
            logger.info("Reset all data removed=%s", removed)
            self._send_json({"status": "reset", "removed": removed})
            return

        if self.path == "/api/v1/provider-setup/select":
            data = self._read_json_body()
            if data is None:
                return
            provider_id = str(data.get("provider") or "")
            if provider_id not in DESCRIPTORS:
                self._send_error("invalid_provider", "Unknown provider.", HTTPStatus.BAD_REQUEST)
                return
            state = ProviderSetupStore(self.server.config).select(provider_id)
            diagnostics = diagnostics_for(provider_id, self.server.config)
            logger.info("Provider selected provider=%s completed=%s", provider_id, state.get("providerSetupCompleted"))
            self._send_json(
                {
                    "status": "selected",
                    "provider": provider_id,
                    "state": state,
                    "providers": provider_summaries(self.server.config),
                    **diagnostics.model_options(),
                }
            )
            return

        match = re.fullmatch(r"/api/v1/provider-setup/(codex|claude)/(detect|test|model)", self.path)
        if match:
            provider_id, action = match.group(1), match.group(2)
            diagnostics = diagnostics_for(provider_id, self.server.config)
            if action == "detect":
                data = self._read_optional_json_body()
                if data is None:
                    return
                result = diagnostics.detect_installation(data.get("path") if data else None)
                logger.info(
                    "Provider setup detect provider=%s status=%s path=%s version=%s",
                    provider_id,
                    result.get("status"),
                    result.get("path"),
                    result.get("version"),
                )
                self._send_json(result)
                return
            if action == "test":
                data = self._read_optional_json_body()
                if data is None:
                    return
                result = diagnostics.test_connection(data.get("path") if data else None)
                logger.info(
                    "Provider setup connection test provider=%s status=%s category=%s",
                    provider_id,
                    result.get("status"),
                    (result.get("details") or {}).get("errorCategory"),
                )
                self._send_json(result)
                return
            # action == "model"
            data = self._read_json_body()
            if data is None:
                return
            result = diagnostics.save_model_settings(data.get("model"), data.get("reasoningEffort"))
            state = result.get("state") or {}
            logger.info(
                "Provider setup model saved provider=%s model=%s reasoning_effort=%s",
                provider_id,
                state.get(f"{provider_id}Model"),
                state.get(f"{provider_id}ReasoningEffort"),
            )
            self._send_json(result)
            return

        if self.path == "/api/v1/provider-setup/complete":
            diagnostics = selected_diagnostics(self.server.config)
            result = diagnostics.complete_setup()
            logger.info("Provider setup completed provider=%s", diagnostics.provider_id)
            self._send_json(result)
            return

        if self.path == "/api/v1/provider-setup/output-language":
            data = self._read_json_body()
            if data is None:
                return
            diagnostics = selected_diagnostics(self.server.config)
            result = diagnostics.save_output_language(data.get("outputLanguage"))
            logger.info(
                "Provider setup output language saved value=%r",
                (result.get("state") or {}).get("outputLanguage"),
            )
            self._send_json(result)
            return

        match = re.fullmatch(r"/api/v1/videos/([^/?]+)/regenerate", self.path)
        if match:
            video = self.server.repository.get_video(match.group(1))
            if video is None:
                logger.warning("Regenerate requested for missing video=%s", match.group(1))
                self._send_error("not_found", "Video was not found.", HTTPStatus.NOT_FOUND)
                return
            logger.info("Regenerate requested local_video_id=%s youtube_id=%s", video["id"], video["youtube_video_id"])
            request = SummaryRequest(
                video_id=video["youtube_video_id"],
                url=video["canonical_url"],
                title=video["title"],
                channel_name=video["channel_name"],
                duration_seconds=video["duration_seconds"],
                thumbnail_url=video["thumbnail_url"],
            )
            _status, video_record_id, job_id = self.server.repository.create_or_reuse(request, force_regenerate=True)
            self.server.queue.notify()
            self._send_json({"jobId": job_id, "videoId": video_record_id, "status": "queued"}, HTTPStatus.ACCEPTED)
            return

        match = re.fullmatch(r"/api/v1/videos/([^/?]+)/publish-telegraph", self.path)
        if match:
            video = self.server.repository.get_video(match.group(1))
            if video is None:
                logger.warning("Telegraph publish requested for missing video=%s", match.group(1))
                self._send_error("not_found", "Video was not found.", HTTPStatus.NOT_FOUND)
                return
            if video["status"] != ProcessingStatus.READY.value:
                self._send_error("not_ready", "The summary is not ready to publish yet.", HTTPStatus.CONFLICT)
                return
            try:
                result = TelegraphPublisher(self.server.config, self.server.repository).publish(video)
            except TelegraphError as error:
                logger.warning("Telegraph publish failed video=%s error=%s", video["youtube_video_id"], error)
                self._send_error("telegraph_failed", str(error), HTTPStatus.BAD_GATEWAY)
                return
            logger.info(
                "Telegraph publish result video=%s status=%s url=%s",
                video["youtube_video_id"],
                result["status"],
                result["url"],
            )
            self._send_json(result)
            return

        self._send_error("not_found", "Endpoint was not found.", HTTPStatus.NOT_FOUND)

    def do_DELETE(self) -> None:
        logger.info("DELETE path=%s origin=%s", self.path, self.headers.get("Origin"))
        self._note_extension_origin()
        if not self._authorized():
            return

        match = re.fullmatch(r"/api/v1/videos/([^/?]+)", self.path)
        if match:
            video_id = match.group(1)
            youtube_id = self.server.repository.delete_video(video_id)
            if youtube_id is None:
                logger.warning("Delete requested for missing video=%s", video_id)
                self._send_error("not_found", "Video was not found.", HTTPStatus.NOT_FOUND)
                return
            # Best-effort artifact cleanup; a missing dir is fine. The worker tolerates a
            # vanished video row (it skips queued jobs whose video is gone), so deleting
            # mid-processing is safe.
            shutil.rmtree(self.server.config.videos_dir / youtube_id, ignore_errors=True)
            logger.info("Deleted video local_video_id=%s youtube_id=%s", video_id, youtube_id)
            self._send_json({"status": "deleted", "videoId": video_id})
            return

        self._send_error("not_found", "Endpoint was not found.", HTTPStatus.NOT_FOUND)

    def _read_json_body(self) -> dict[str, Any] | None:
        content_type = self.headers.get("Content-Type", "")
        if "application/json" not in content_type:
            logger.warning("Rejected request content_type=%r", content_type)
            self._send_error("invalid_content_type", "Content-Type must be application/json.", HTTPStatus.UNSUPPORTED_MEDIA_TYPE)
            return None
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0 or length > self.server.config.max_request_bytes:
            logger.warning("Rejected request body length=%s max=%s", length, self.server.config.max_request_bytes)
            self._send_error("invalid_request_body", "Request body is empty or too large.", HTTPStatus.BAD_REQUEST)
            return None
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except json.JSONDecodeError:
            logger.warning("Rejected invalid JSON body length=%s", length)
            self._send_error("invalid_json", "Request body is not valid JSON.", HTTPStatus.BAD_REQUEST)
            return None

    def _read_optional_json_body(self) -> dict[str, Any] | None:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length == 0:
            return {}
        return self._read_json_body()

    def _authorized(self) -> bool:
        token = self.server.config.api_token
        if not token:
            return True
        expected = f"Bearer {token}"
        if self.headers.get("Authorization") == expected:
            return True
        logger.warning("Unauthorized request path=%s", self.path)
        self._send_error("unauthorized", "Invalid local API token.", HTTPStatus.UNAUTHORIZED)
        return False

    def _note_extension_origin(self) -> None:
        """Remember that the Chrome extension is talking to us whenever a request
        carries a ``chrome-extension://`` origin (including the CORS preflight). This
        is what lets the macOS app stop nudging users who already have the extension.

        Throttled to one DB write every few minutes via an in-memory timestamp on the
        server so a burst of requests doesn't hammer SQLite; best-effort, never fatal."""
        origin = self.headers.get("Origin") or ""
        if not origin.startswith("chrome-extension://"):
            return
        now = time.monotonic()
        last = getattr(self.server, "_extension_seen_monotonic", None)
        if last is not None and (now - last) < 300:
            return
        self.server._extension_seen_monotonic = now
        try:
            self.server.repository.mark_extension_seen()
        except Exception:  # pragma: no cover - telemetry only, must never break a request
            logger.debug("Could not record extension activity", exc_info=True)

    def _send_error(self, code: str, message: str, status: HTTPStatus) -> None:
        logger.info("Response error status=%s code=%s message=%s", status.value, code, message)
        self._send_json({"error": {"code": code, "message": message}}, status)

    def _send_json(self, payload: dict[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        if status != HTTPStatus.NO_CONTENT:
            self.send_header("Content-Length", str(len(body)))
        self._send_cors_headers()
        self.end_headers()
        if status != HTTPStatus.NO_CONTENT:
            self.wfile.write(body)

    @staticmethod
    def _video_payload(video: Any, jobs_dir: Path | None = None) -> dict[str, Any]:
        summary_markdown = video["summary_markdown"]
        reading_time_minutes = (
            reading_minutes_for_markdown(summary_markdown)
            if summary_markdown and str(summary_markdown).strip()
            else None
        )
        # Path to the latest job's per-stage logs (job.log + provider stdout/stderr),
        # so the app can offer "Show Logs" on failure. Only set when the dir exists.
        job_log_path = None
        latest_job_id = video["latest_job_id"]
        if jobs_dir is not None and latest_job_id:
            candidate = jobs_dir / str(latest_job_id)
            if candidate.is_dir():
                job_log_path = str(candidate)
        return {
            "id": video["id"],
            "youtubeVideoID": video["youtube_video_id"],
            "canonicalURL": video["canonical_url"],
            "title": video["title"],
            "channelName": video["channel_name"],
            "thumbnailURL": video["thumbnail_url"] or youtube_thumbnail_url(video["youtube_video_id"]),
            "durationSeconds": video["duration_seconds"],
            "currentTimeAtRequest": video["current_time_at_request"],
            "createdAt": video["created_at"],
            "updatedAt": video["updated_at"],
            "status": video["status"],
            "transcriptPath": video["transcript_path"],
            "summaryPath": video["summary_path"],
            "errorCode": video["error_code"],
            "errorMessage": video["error_message"],
            "latestJobID": video["latest_job_id"],
            "latestJobStatus": video["latest_job_status"],
            "latestJobCreatedAt": video["latest_job_created_at"],
            "latestJobFinishedAt": video["latest_job_finished_at"],
            "telegraphURL": video["telegraph_url"],
            "readingTimeMinutes": reading_time_minutes,
            "jobLogPath": job_log_path,
        }

    @staticmethod
    def _watch_suggestion_payload(row: Any) -> dict[str, Any]:
        return {
            "youtubeVideoID": row["youtube_video_id"],
            "canonicalURL": row["canonical_url"],
            "title": row["title"],
            "channelName": row["channel_name"],
            "thumbnailURL": row["thumbnail_url"] or youtube_thumbnail_url(row["youtube_video_id"]),
            "durationSeconds": row["duration_seconds"],
            "watchedAt": row["watched_at"],
            "inLibrary": row["library_video_id"] is not None,
            "libraryVideoID": row["library_video_id"],
            "libraryStatus": row["library_status"],
        }

    def _send_cors_headers(self) -> None:
        origin = self.headers.get("Origin")
        if origin and origin_allowed(origin, self.server.config.allowed_origins):
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization,Content-Type")


def _extension_connected(last_seen: str | None, *, max_age_days: int = 30) -> bool:
    """True if the Chrome extension has talked to the backend within ``max_age_days``.

    A missing or stale timestamp reads as "not installed" so the app keeps gently
    nudging — and resumes nudging if the extension goes quiet for a month (e.g. it
    was removed)."""
    if not last_seen:
        return False
    try:
        seen = datetime.fromisoformat(last_seen)
    except ValueError:
        return False
    if seen.tzinfo is None:
        seen = seen.replace(tzinfo=timezone.utc)
    return datetime.now(timezone.utc) - seen <= timedelta(days=max_age_days)


def _optional_float(value: Any) -> float | None:
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def origin_allowed(origin: str, allowed: tuple[str, ...]) -> bool:
    return "*" in allowed or origin in allowed or ("chrome-extension://*" in allowed and origin.startswith("chrome-extension://"))


def build_server(config: AppConfig | None = None) -> TubeFoldServer:
    config = config or load_config()
    configure_logging(config)
    config.data_dir.mkdir(parents=True, exist_ok=True)
    config.videos_dir.mkdir(parents=True, exist_ok=True)
    config.jobs_dir.mkdir(parents=True, exist_ok=True)
    config.logs_dir.mkdir(parents=True, exist_ok=True)
    repository = Repository(config.database_path)
    queue = ProcessingQueue(config, repository)
    server = TubeFoldServer(config, repository, queue)
    logger.info(
        "Server configured host=%s port=%s provider=%s data_dir=%s db=%s token_enabled=%s allowed_origins=%s",
        config.host,
        config.port,
        config.provider,
        config.data_dir,
        config.database_path,
        bool(config.api_token),
        ",".join(config.allowed_origins),
    )
    queue.start()
    return server


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the local TubeFold API server")
    parser.add_argument("--port", type=int, help="Override server port")
    parser.add_argument("--provider", help="Override provider name")
    args = parser.parse_args()

    config = load_config()
    if args.port is not None or args.provider is not None:
        config = AppConfig(
            host=config.host,
            port=args.port if args.port is not None else config.port,
            api_token=config.api_token,
            allowed_origins=config.allowed_origins,
            provider=args.provider or config.provider,
            python_executable=config.python_executable,
            codex_timeout_seconds=config.codex_timeout_seconds,
            data_dir=config.data_dir,
            output_dir=config.output_dir,
            codex_model=config.codex_model,
            codex_reasoning_effort=config.codex_reasoning_effort,
            claude_model=config.claude_model,
            claude_reasoning_effort=config.claude_reasoning_effort,
            output_language=config.output_language,
            max_request_bytes=config.max_request_bytes,
        )

    server = build_server(config)
    logger.info("TubeFold API listening on http://%s:%s", config.host, server.server_port)
    print(f"TubeFold API listening on http://{config.host}:{server.server_port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        logger.info("Shutting down TubeFold API")
        server.queue.stop()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
