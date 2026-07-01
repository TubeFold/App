from __future__ import annotations

import json
import shutil
import sys
import tempfile
import types
import unittest
from pathlib import Path

from tubefold.config import AppConfig
from tubefold.provider_setup import ProviderSetupStore
from tubefold.models import SummaryRequest
from tubefold.processing import ProcessingQueue
from tubefold.repository import Repository


ROOT = Path(__file__).resolve().parents[1]


class ProcessingTests(unittest.TestCase):
    def test_fake_provider_processing_writes_video_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            repository = Repository(data_dir / "database.sqlite")
            config = AppConfig(
                host="127.0.0.1",
                port=0,
                api_token=None,
                allowed_origins=("chrome-extension://*",),
                provider="fake",
                python_executable=sys.executable,
                codex_timeout_seconds=30,
                data_dir=data_dir,
                output_dir=data_dir / "exports",
            )
            queue = ProcessingQueue(config, repository)
            request = SummaryRequest(
                video_id="dQw4w9WgXcQ",
                url="https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                title="Fixture Video",
                source="chrome-extension",
            )
            status, video_id, job_id = repository.create_or_reuse(request)
            self.assertEqual(status, "queued")

            def fake_metadata(_self, _url: str, _youtube_id: str, output_json: Path) -> dict:
                metadata = json.loads((ROOT / "tests" / "fixtures" / "metadata.json").read_text(encoding="utf-8"))
                output_json.write_text(json.dumps(metadata, ensure_ascii=False), encoding="utf-8")
                return metadata

            def fake_transcript(_self, _youtube_id: str, transcript_file: Path, info_json: Path, _job_dir: Path) -> None:
                shutil.copyfile(ROOT / "tests" / "fixtures" / "transcript.txt", transcript_file)
                info_json.write_text(
                    json.dumps({"language": "Polish", "language_code": "pl", "is_generated": False}),
                    encoding="utf-8",
                )

            queue._fetch_metadata = types.MethodType(fake_metadata, queue)  # type: ignore[method-assign]
            queue._fetch_transcript = types.MethodType(fake_transcript, queue)  # type: ignore[method-assign]
            queue.process_job(video_id, job_id)

            video = repository.get_video(video_id)
            self.assertIsNotNone(video)
            assert video is not None
            self.assertEqual(video["status"], "ready")
            summary_path = Path(video["summary_path"])
            transcript_path = Path(video["transcript_path"])
            self.assertTrue(summary_path.exists())
            self.assertTrue(transcript_path.exists())
            self.assertEqual(summary_path.name, "[TubeFold] Hello - World- Demo.md")
            summary = summary_path.read_text(encoding="utf-8")
            self.assertIn('model: "fake"', summary)
            self.assertIn("# Fake Summary", summary)

    def test_codex_markdown_includes_model_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            repository = Repository(data_dir / "database.sqlite")
            config = AppConfig(
                host="127.0.0.1",
                port=0,
                api_token=None,
                allowed_origins=("chrome-extension://*",),
                provider="codex",
                python_executable=sys.executable,
                codex_timeout_seconds=30,
                data_dir=data_dir,
                output_dir=data_dir / "exports",
            )
            ProviderSetupStore(config).update(codexModel="gpt-5.5", codexReasoningEffort="high")
            queue = ProcessingQueue(config, repository)

            markdown = queue._build_markdown(
                {
                    "video_id": "abc123def45",
                    "url": "https://www.youtube.com/watch?v=abc123def45",
                    "title": "Demo",
                    "channel": "Channel",
                    "duration_seconds": 10,
                    "published_at": "2026-06-25",
                },
                {"language": "English", "language_code": "en", "is_generated": False},
                "# Summary",
            )

            # Effort is forced to "auto" (no user selection), so the header omits
            # any "(effort: ...)" suffix regardless of stored setup state.
            self.assertIn('model: "Codex GPT-5.5"', markdown)
            self.assertNotIn("effort:", markdown)

    def test_claude_selection_drives_markdown_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            repository = Repository(data_dir / "database.sqlite")
            config = AppConfig(
                host="127.0.0.1",
                port=0,
                api_token=None,
                allowed_origins=("chrome-extension://*",),
                provider="codex",
                python_executable=sys.executable,
                codex_timeout_seconds=30,
                data_dir=data_dir,
                output_dir=data_dir / "exports",
            )
            # The server boots with provider=codex, but the UI selection picks claude.
            ProviderSetupStore(config).update(
                selectedProviderID="claude",
                claudeModel="opus",
                claudeReasoningEffort="high",
            )
            queue = ProcessingQueue(config, repository)
            self.assertEqual(queue._active_provider(), "claude")

            markdown = queue._build_markdown(
                {
                    "video_id": "abc123def45",
                    "url": "https://www.youtube.com/watch?v=abc123def45",
                    "title": "Demo",
                    "channel": "Channel",
                    "duration_seconds": 10,
                    "published_at": "2026-06-25",
                },
                {"language": "English", "language_code": "en", "is_generated": False},
                "# Summary",
            )

            self.assertIn('model: "Claude Opus 4.8"', markdown)
            self.assertNotIn("effort:", markdown)


if __name__ == "__main__":
    unittest.main()
