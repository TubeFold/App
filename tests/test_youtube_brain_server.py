from __future__ import annotations

import json
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path


from youtube_brain.config import AppConfig
from youtube_brain.repository import Repository
from youtube_brain.server import YouTubeBrainServer


class DummyQueue:
    def __init__(self) -> None:
        self.notified = False

    def notify(self) -> None:
        self.notified = True


def test_config(data_dir: Path, port: int = 0) -> AppConfig:
    return AppConfig(
        host="127.0.0.1",
        port=port,
        api_token=None,
        allowed_origins=("chrome-extension://*", "null"),
        provider="fake",
        python_executable="python3",
        codex_timeout_seconds=30,
        data_dir=data_dir,
        output_dir=data_dir / "exports",
    )


class ServerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        data_dir = Path(self.tmp.name)
        self.repository = Repository(data_dir / "database.sqlite")
        self.queue = DummyQueue()
        self.server = YouTubeBrainServer(test_config(data_dir), self.repository, self.queue)  # type: ignore[arg-type]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.tmp.cleanup()

    def test_health(self) -> None:
        body = self.get_json("/health")
        self.assertEqual(body["status"], "ok")
        self.assertEqual(body["apiVersion"], 1)
        self.assertTrue(body["backendFeatures"]["unlimitedTranscripts"])
        self.assertTrue(body["backendFeatures"]["libraryRegenerate"])
        self.assertTrue(body["backendFeatures"]["codexModelSettings"])

    def test_summary_request_creates_job_and_dedupes_active_video(self) -> None:
        request = {
            "videoId": "dQw4w9WgXcQ",
            "url": "https://youtu.be/dQw4w9WgXcQ?t=42",
            "title": "Test Video",
            "source": "chrome-extension",
        }
        first = self.post_json("/api/v1/summaries", request)
        self.assertEqual(first["status"], "queued")
        self.assertTrue(first["jobId"])
        self.assertTrue(self.queue.notified)

        second = self.post_json("/api/v1/summaries", request)
        self.assertEqual(second["status"], "already_processing")
        self.assertEqual(second["jobId"], first["jobId"])

        state = self.get_json("/api/v1/videos/by-youtube-id/dQw4w9WgXcQ")
        self.assertTrue(state["exists"])
        self.assertEqual(state["status"], "queued")

        library = self.get_json("/api/v1/videos")
        self.assertEqual(len(library["videos"]), 1)
        self.assertEqual(library["videos"][0]["youtubeVideoID"], "dQw4w9WgXcQ")
        self.assertEqual(library["videos"][0]["title"], "Test Video")
        self.assertEqual(library["videos"][0]["status"], "queued")
        self.assertEqual(library["videos"][0]["latestJobID"], first["jobId"])

    def test_invalid_youtube_url(self) -> None:
        with self.assertRaises(urllib.error.HTTPError) as context:
            self.post_json("/api/v1/summaries", {"url": "https://example.com"})
        self.assertEqual(context.exception.code, 400)
        context.exception.close()

    def test_provider_setup_model_endpoint_saves_settings(self) -> None:
        response = self.get_json("/api/v1/provider-setup")
        self.assertEqual(response["state"]["codexModel"], "gpt-5.4-mini")
        self.assertTrue(response["modelOptions"])

        saved = self.post_json(
            "/api/v1/provider-setup/codex/model",
            {"model": "gpt-5.5", "reasoningEffort": "high"},
        )

        self.assertEqual(saved["status"], "saved")
        self.assertEqual(saved["state"]["codexModel"], "gpt-5.5")
        self.assertEqual(saved["state"]["codexReasoningEffort"], "high")

    def test_output_language_endpoint_saves_and_normalizes(self) -> None:
        response = self.get_json("/api/v1/provider-setup")
        self.assertEqual(response["state"]["outputLanguage"], "English")

        saved = self.post_json(
            "/api/v1/provider-setup/output-language",
            {"outputLanguage": "  Russian \n"},
        )
        self.assertEqual(saved["status"], "saved")
        self.assertEqual(saved["state"]["outputLanguage"], "Russian")

        reloaded = self.get_json("/api/v1/provider-setup")
        self.assertEqual(reloaded["state"]["outputLanguage"], "Russian")

        blanked = self.post_json(
            "/api/v1/provider-setup/output-language",
            {"outputLanguage": "   "},
        )
        self.assertEqual(blanked["state"]["outputLanguage"], "English")

    def get_json(self, path: str) -> dict:
        with urllib.request.urlopen(self.base_url + path, timeout=5) as response:
            return json.loads(response.read().decode("utf-8"))

    def post_json(self, path: str, payload: dict) -> dict:
        request = urllib.request.Request(
            self.base_url + path,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.loads(response.read().decode("utf-8"))


if __name__ == "__main__":
    unittest.main()
