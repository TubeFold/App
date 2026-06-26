from __future__ import annotations

import json
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path


from tubefold.config import AppConfig
from tubefold.repository import Repository
from tubefold.server import TubeFoldServer


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
        self.server = TubeFoldServer(test_config(data_dir), self.repository, self.queue)  # type: ignore[arg-type]
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
        self.assertTrue(body["backendFeatures"]["claudeProvider"])
        self.assertTrue(body["backendFeatures"]["usageStats"])
        self.assertTrue(body["backendFeatures"]["watchActivity"])

    def test_usage_endpoint_empty_then_aggregates(self) -> None:
        empty = self.get_json("/api/v1/usage")
        self.assertEqual(empty["totalTokens"], 0)
        self.assertEqual(empty["byProvider"], {})
        self.assertIsNone(empty["codexWeekly"])

        # Seed a video + two jobs with usage, one carrying a codex weekly snapshot.
        from tubefold.models import SummaryRequest

        request = SummaryRequest.from_json({}, "dQw4w9WgXcQ", "https://youtu.be/dQw4w9WgXcQ")
        _, _, job_a = self.repository.create_or_reuse(request)
        self.repository.set_job_usage(
            job_a,
            {"provider": "codex", "input_tokens": 1000, "output_tokens": 200, "total_tokens": 1200,
             "weekly_percent": 55.0, "weekly_resets_at": 1782895766, "primary_percent": 30.0},
        )
        _, _, job_b = self.repository.create_or_reuse(request, force_regenerate=True)
        self.repository.set_job_usage(
            job_b,
            {"provider": "claude", "input_tokens": 300, "output_tokens": 100, "total_tokens": 400, "cost_usd": 0.05},
        )

        usage = self.get_json("/api/v1/usage")
        self.assertEqual(usage["totalTokens"], 1600)
        self.assertEqual(usage["byProvider"]["codex"]["totalTokens"], 1200)
        self.assertEqual(usage["byProvider"]["codex"]["jobs"], 1)
        self.assertEqual(usage["byProvider"]["claude"]["totalTokens"], 400)
        self.assertAlmostEqual(usage["byProvider"]["claude"]["costUsd"], 0.05)
        self.assertEqual(usage["codexWeekly"]["usedPercent"], 55.0)
        self.assertEqual(usage["codexWeekly"]["resetsAt"], 1782895766)

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

    def test_reclaim_orphaned_jobs_fails_interrupted_jobs(self) -> None:
        from tubefold.models import ProcessingStatus, SummaryRequest

        request = SummaryRequest.from_json({}, "dQw4w9WgXcQ", "https://youtu.be/dQw4w9WgXcQ")
        _, video_id, job_id = self.repository.create_or_reuse(request)
        # Simulate the worker getting interrupted mid-run (e.g. the app was quit
        # while the provider was generating the summary).
        self.repository.mark_status(video_id, job_id, ProcessingStatus.GENERATING_SUMMARY)

        reclaimed = self.repository.reclaim_orphaned_jobs("interrupted", "stopped")
        self.assertEqual(reclaimed, [job_id])

        video = self.repository.get_video(video_id)
        self.assertEqual(video["status"], ProcessingStatus.FAILED.value)
        self.assertEqual(video["error_code"], "interrupted")
        job = self.repository.get_job(job_id)
        self.assertEqual(job["status"], ProcessingStatus.FAILED.value)
        self.assertIsNotNone(job["finished_at"])

        # A second pass finds nothing left to reclaim, and queued jobs are untouched.
        _, _, queued_job = self.repository.create_or_reuse(request, force_regenerate=True)
        self.assertEqual(self.repository.reclaim_orphaned_jobs("interrupted", "stopped"), [])
        self.assertEqual(self.repository.get_job(queued_job)["status"], ProcessingStatus.QUEUED.value)

    def test_manual_add_without_thumbnail_gets_derived_cover(self) -> None:
        self.post_json(
            "/api/v1/summaries",
            {"url": "https://youtu.be/kdDBQoi_NmQ", "source": "macos-app"},
        )
        library = self.get_json("/api/v1/videos")
        video = library["videos"][0]
        self.assertEqual(video["youtubeVideoID"], "kdDBQoi_NmQ")
        self.assertEqual(video["thumbnailURL"], "https://i.ytimg.com/vi/kdDBQoi_NmQ/hqdefault.jpg")

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

    def test_provider_setup_lists_providers_and_supports_selection(self) -> None:
        response = self.get_json("/api/v1/provider-setup")
        self.assertEqual(response["provider"], "codex")
        provider_ids = {item["id"] for item in response["providers"]}
        self.assertEqual(provider_ids, {"codex", "claude"})

        selected = self.post_json("/api/v1/provider-setup/select", {"provider": "claude"})
        self.assertEqual(selected["status"], "selected")
        self.assertEqual(selected["provider"], "claude")
        self.assertEqual(selected["state"]["selectedProviderID"], "claude")

        reloaded = self.get_json("/api/v1/provider-setup")
        self.assertEqual(reloaded["provider"], "claude")
        self.assertEqual(reloaded["state"]["claudeModel"], "sonnet")

    def test_provider_setup_claude_model_endpoint_saves_settings(self) -> None:
        saved = self.post_json(
            "/api/v1/provider-setup/claude/model",
            {"model": "opus", "reasoningEffort": "high"},
        )
        self.assertEqual(saved["status"], "saved")
        self.assertEqual(saved["provider"], "claude")
        self.assertEqual(saved["state"]["claudeModel"], "opus")
        self.assertEqual(saved["state"]["claudeReasoningEffort"], "high")

    def test_provider_setup_select_rejects_unknown_provider(self) -> None:
        with self.assertRaises(urllib.error.HTTPError) as context:
            self.post_json("/api/v1/provider-setup/select", {"provider": "bogus"})
        self.assertEqual(context.exception.code, 400)
        context.exception.close()

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

    def test_watch_activity_records_and_surfaces_suggestion(self) -> None:
        empty = self.get_json("/api/v1/watch-activity")
        self.assertIsNone(empty["suggestion"])

        recorded = self.post_json(
            "/api/v1/watch-activity",
            {
                "url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                "title": "Never Gonna Give You Up",
                "channelName": "Rick Astley",
                "durationSeconds": 213,
                "source": "chrome-extension",
            },
        )
        self.assertEqual(recorded["status"], "recorded")

        body = self.get_json("/api/v1/watch-activity")
        suggestion = body["suggestion"]
        self.assertIsNotNone(suggestion)
        self.assertEqual(suggestion["youtubeVideoID"], "dQw4w9WgXcQ")
        self.assertEqual(suggestion["canonicalURL"], "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        self.assertEqual(suggestion["title"], "Never Gonna Give You Up")
        self.assertEqual(suggestion["channelName"], "Rick Astley")
        self.assertEqual(suggestion["thumbnailURL"], "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        self.assertFalse(suggestion["inLibrary"])
        self.assertIsNone(suggestion["libraryVideoID"])

    def test_watch_activity_reflects_library_membership(self) -> None:
        self.post_json("/api/v1/watch-activity", {"url": "https://youtu.be/dQw4w9WgXcQ"})
        created = self.post_json("/api/v1/summaries", {"url": "https://youtu.be/dQw4w9WgXcQ"})

        suggestion = self.get_json("/api/v1/watch-activity")["suggestion"]
        self.assertTrue(suggestion["inLibrary"])
        self.assertEqual(suggestion["libraryVideoID"], created["videoId"])
        self.assertEqual(suggestion["libraryStatus"], "queued")

    def test_watch_activity_dismiss_hides_until_reopened(self) -> None:
        self.post_json("/api/v1/watch-activity", {"url": "https://youtu.be/dQw4w9WgXcQ"})
        self.post_json("/api/v1/watch-activity/dismiss", {"youtubeVideoID": "dQw4w9WgXcQ"})
        self.assertIsNone(self.get_json("/api/v1/watch-activity")["suggestion"])

        # Re-opening the same video resurfaces it as a fresh suggestion.
        self.post_json("/api/v1/watch-activity", {"url": "https://youtu.be/dQw4w9WgXcQ"})
        resurfaced = self.get_json("/api/v1/watch-activity")["suggestion"]
        self.assertIsNotNone(resurfaced)
        self.assertEqual(resurfaced["youtubeVideoID"], "dQw4w9WgXcQ")

    def test_watch_activity_rejects_invalid_url(self) -> None:
        with self.assertRaises(urllib.error.HTTPError) as context:
            self.post_json("/api/v1/watch-activity", {"url": "https://example.com"})
        self.assertEqual(context.exception.code, 400)
        context.exception.close()

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
