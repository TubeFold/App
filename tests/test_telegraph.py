from __future__ import annotations

import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from tubefold.config import AppConfig
from tubefold.models import SummaryRequest
from tubefold.repository import Repository
from tubefold.server import TubeFoldServer
from tubefold.telegraph import (
    MAX_CONTENT_BYTES,
    TelegraphClient,
    TelegraphPublisher,
    build_article_content,
    markdown_to_nodes,
    strip_front_matter,
)
import tubefold.server as server_module


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


class FakeTelegraph:
    """A request_fn for TelegraphClient that records calls and never hits the network."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, dict]] = []
        self.account_count = 0
        self.create_page_count = 0
        self.edit_page_count = 0

    def __call__(self, method: str, params: dict) -> dict:
        self.calls.append((method, params))
        if method == "createAccount":
            self.account_count += 1
            return {"ok": True, "result": {"access_token": "tok-123", "short_name": params["short_name"]}}
        if method == "createPage":
            self.create_page_count += 1
            return {"ok": True, "result": {"path": "Test-Page-01", "url": "https://telegra.ph/Test-Page-01"}}
        if method.startswith("editPage"):
            self.edit_page_count += 1
            return {"ok": True, "result": {"path": params.get("path"), "url": "https://telegra.ph/Test-Page-01"}}
        return {"ok": False, "error": "UNKNOWN_METHOD"}


def insert_ready_video(repository: Repository, summary_markdown: str, video_id: str = "dQw4w9WgXcQ") -> str:
    request = SummaryRequest(
        video_id=video_id,
        url=f"https://www.youtube.com/watch?v={video_id}",
        title="Test Video",
        channel_name="Test Channel",
    )
    _status, local_id, job_id = repository.create_or_reuse(request)
    repository.mark_ready(
        local_id,
        job_id,
        transcript_path=Path("/tmp/transcript.txt"),
        summary_path=Path("/tmp/summary.md"),
        summary_markdown=summary_markdown,
        metadata={"title": "Test Video", "channel": "Test Channel", "duration_seconds": 100},
    )
    return local_id


class MarkdownConversionTests(unittest.TestCase):
    def test_headings_map_to_h3_and_h4(self) -> None:
        self.assertEqual(markdown_to_nodes("# Title"), [{"tag": "h3", "children": ["Title"]}])
        self.assertEqual(markdown_to_nodes("## Title"), [{"tag": "h3", "children": ["Title"]}])
        self.assertEqual(markdown_to_nodes("### Sub"), [{"tag": "h4", "children": ["Sub"]}])
        self.assertEqual(markdown_to_nodes("#### Sub"), [{"tag": "h4", "children": ["Sub"]}])

    def test_unordered_and_ordered_lists(self) -> None:
        ul = markdown_to_nodes("- one\n- two")
        self.assertEqual(ul, [{"tag": "ul", "children": [
            {"tag": "li", "children": ["one"]},
            {"tag": "li", "children": ["two"]},
        ]}])
        ol = markdown_to_nodes("1. one\n2. two")
        self.assertEqual(ol[0]["tag"], "ol")
        self.assertEqual(len(ol[0]["children"]), 2)

    def test_inline_formatting(self) -> None:
        nodes = markdown_to_nodes("Plain **bold** and *italic* and `code` and [text](https://e.com).")
        children = nodes[0]["children"]
        self.assertEqual(nodes[0]["tag"], "p")
        self.assertIn({"tag": "strong", "children": ["bold"]}, children)
        self.assertIn({"tag": "em", "children": ["italic"]}, children)
        self.assertIn({"tag": "code", "children": ["code"]}, children)
        self.assertIn({"tag": "a", "attrs": {"href": "https://e.com"}, "children": ["text"]}, children)

    def test_horizontal_rule_and_code_fence(self) -> None:
        self.assertEqual(markdown_to_nodes("---"), [{"tag": "hr"}])
        fenced = markdown_to_nodes("```\nline1\nline2\n```")
        self.assertEqual(fenced, [{"tag": "pre", "children": ["line1\nline2"]}])

    def test_strip_front_matter(self) -> None:
        doc = '---\ntype: "tubefold"\ntitle: "X"\n---\n\n# Body\n\ntext'
        stripped = strip_front_matter(doc)
        self.assertFalse(stripped.startswith("---"))
        self.assertTrue(stripped.startswith("# Body"))

    def test_no_h1_or_h2_tags_emitted(self) -> None:
        nodes = markdown_to_nodes("# A\n## B\n### C")
        tags = {node["tag"] for node in nodes}
        self.assertFalse(tags & {"h1", "h2"})
        self.assertEqual(tags, {"h3", "h4"})

    def test_article_content_has_source_header(self) -> None:
        content = build_article_content("# Summary\n\nBody.", "https://youtu.be/abc", "Some Channel")
        self.assertEqual(content[0]["tag"], "p")
        link = content[0]["children"][0]
        self.assertEqual(link["tag"], "a")
        self.assertEqual(link["attrs"]["href"], "https://youtu.be/abc")
        # One header line, then the rule.
        self.assertEqual(content[1], {"tag": "hr"})

    def test_reading_time_is_on_the_header_line(self) -> None:
        content = build_article_content("# Summary\n\nBody.", "https://youtu.be/abc", "Some Channel")
        header_text = "".join(part for part in content[0]["children"] if isinstance(part, str))
        self.assertIn("min read summary", header_text)

    def test_header_combines_watch_and_read_on_one_line(self) -> None:
        content = build_article_content(
            "# Summary\n\nBody.", "https://youtu.be/abc", "Some Channel", duration_seconds=1380
        )
        header_text = "".join(part for part in content[0]["children"] if isinstance(part, str))
        self.assertIn("23 min", header_text)
        self.assertIn("or", header_text)
        self.assertIn("min read summary", header_text)
        # The combined line replaces the old separate reading-time paragraph.
        self.assertEqual(content[1], {"tag": "hr"})

    def test_header_shows_only_read_time_when_duration_unknown(self) -> None:
        content = build_article_content("# Summary\n\nBody.", "https://youtu.be/abc", "Some Channel")
        header_text = "".join(part for part in content[0]["children"] if isinstance(part, str))
        self.assertIn("min read summary", header_text)
        self.assertNotIn(" or ", header_text)

    def test_content_truncated_under_64kb(self) -> None:
        huge = "\n\n".join(f"Paragraph {i} " + "word " * 200 for i in range(400))
        content = build_article_content(huge, "https://youtu.be/abc", "Channel")
        size = len(json.dumps(content, ensure_ascii=False).encode("utf-8"))
        self.assertLessEqual(size, MAX_CONTENT_BYTES)
        self.assertIn("truncated", json.dumps(content[-1], ensure_ascii=False))


class PublisherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.data_dir = Path(self.tmp.name)
        self.config = test_config(self.data_dir)
        self.repository = Repository(self.data_dir / "database.sqlite")
        self.fake = FakeTelegraph()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def publisher(self) -> TelegraphPublisher:
        return TelegraphPublisher(self.config, self.repository, client=TelegraphClient(request_fn=self.fake))

    def test_first_publish_creates_account_once_and_page(self) -> None:
        vid = insert_ready_video(self.repository, "# Title\n\nBody content here.")
        result = self.publisher().publish(self.repository.get_video(vid))
        self.assertEqual(result["status"], "published")
        self.assertEqual(result["url"], "https://telegra.ph/Test-Page-01")
        self.assertEqual(self.fake.account_count, 1)
        self.assertEqual(self.fake.create_page_count, 1)
        self.assertTrue((self.data_dir / "telegraph-account.json").exists())

    def test_repeat_publish_reuses_url_without_new_calls(self) -> None:
        vid = insert_ready_video(self.repository, "# Title\n\nBody content here.")
        self.publisher().publish(self.repository.get_video(vid))
        second = self.publisher().publish(self.repository.get_video(vid))
        self.assertEqual(second["status"], "reused")
        self.assertEqual(self.fake.create_page_count, 1)
        self.assertEqual(self.fake.account_count, 1)
        self.assertEqual(self.fake.edit_page_count, 0)

    def test_account_token_reused_across_videos(self) -> None:
        first = insert_ready_video(self.repository, "# One\n\nBody one.", video_id="dQw4w9WgXcQ")
        second = insert_ready_video(self.repository, "# Two\n\nBody two.", video_id="9bZkp7q19f0")
        self.publisher().publish(self.repository.get_video(first))
        self.publisher().publish(self.repository.get_video(second))
        self.assertEqual(self.fake.account_count, 1)
        self.assertEqual(self.fake.create_page_count, 2)

    def test_regenerated_summary_updates_same_page_via_editpage(self) -> None:
        vid = insert_ready_video(self.repository, "# Title\n\nOriginal body.")
        first = self.publisher().publish(self.repository.get_video(vid))
        # Simulate a regenerate that rewrote the summary.
        self.repository.mark_ready(
            vid,
            "job-2",
            transcript_path=Path("/tmp/transcript.txt"),
            summary_path=Path("/tmp/summary.md"),
            summary_markdown="# Title\n\nUpdated body with new content.",
            metadata={"title": "Test Video", "channel": "Test Channel", "duration_seconds": 100},
        )
        second = self.publisher().publish(self.repository.get_video(vid))
        self.assertEqual(second["status"], "updated")
        self.assertEqual(second["url"], first["url"])
        self.assertEqual(self.fake.create_page_count, 1)
        self.assertEqual(self.fake.edit_page_count, 1)

    def test_publish_without_summary_raises(self) -> None:
        request = SummaryRequest(video_id="dQw4w9WgXcQ", url="https://youtu.be/dQw4w9WgXcQ", title="X")
        _status, vid, _job = self.repository.create_or_reuse(request)
        from tubefold.telegraph import TelegraphError

        with self.assertRaises(TelegraphError):
            self.publisher().publish(self.repository.get_video(vid))


class PublishEndpointTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.data_dir = Path(self.tmp.name)
        self.repository = Repository(self.data_dir / "database.sqlite")
        self.fake = FakeTelegraph()

        # Route the server's publisher through the fake transport.
        self._orig_publisher = server_module.TelegraphPublisher
        fake = self.fake
        server_module.TelegraphPublisher = lambda config, repo: TelegraphPublisher(
            config, repo, client=TelegraphClient(request_fn=fake)
        )

        class DummyQueue:
            def notify(self) -> None:
                pass

        self.server = TubeFoldServer(test_config(self.data_dir), self.repository, DummyQueue())  # type: ignore[arg-type]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        server_module.TelegraphPublisher = self._orig_publisher
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.tmp.cleanup()

    def post(self, path: str) -> dict:
        request = urllib.request.Request(self.base_url + path, data=b"", method="POST")
        with urllib.request.urlopen(request) as response:
            return json.loads(response.read().decode("utf-8"))

    def test_publish_ready_video(self) -> None:
        vid = insert_ready_video(self.repository, "# Title\n\nA useful body for the summary.")
        body = self.post(f"/api/v1/videos/{vid}/publish-telegraph")
        self.assertEqual(body["status"], "published")
        self.assertEqual(body["url"], "https://telegra.ph/Test-Page-01")
        library = json.loads(
            urllib.request.urlopen(self.base_url + "/api/v1/videos").read().decode("utf-8")
        )
        self.assertEqual(library["videos"][0]["telegraphURL"], "https://telegra.ph/Test-Page-01")
        self.assertGreaterEqual(library["videos"][0]["readingTimeMinutes"], 1)

    def test_publish_not_ready_returns_conflict(self) -> None:
        request = SummaryRequest(video_id="dQw4w9WgXcQ", url="https://youtu.be/dQw4w9WgXcQ", title="X")
        _status, vid, _job = self.repository.create_or_reuse(request)
        with self.assertRaises(urllib.error.HTTPError) as context:
            self.post(f"/api/v1/videos/{vid}/publish-telegraph")
        self.assertEqual(context.exception.code, 409)

    def test_publish_missing_video_returns_404(self) -> None:
        with self.assertRaises(urllib.error.HTTPError) as context:
            self.post("/api/v1/videos/does-not-exist/publish-telegraph")
        self.assertEqual(context.exception.code, 404)


if __name__ == "__main__":
    unittest.main()
