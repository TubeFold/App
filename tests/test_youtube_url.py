from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from tubefold_lib import normalize_youtube_url, parse_youtube_video_id


class YouTubeUrlTests(unittest.TestCase):
    def test_watch_url(self) -> None:
        self.assertEqual(
            parse_youtube_video_id("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s"),
            "dQw4w9WgXcQ",
        )

    def test_short_url(self) -> None:
        self.assertEqual(parse_youtube_video_id("https://youtu.be/dQw4w9WgXcQ?si=test"), "dQw4w9WgXcQ")

    def test_embed_url(self) -> None:
        self.assertEqual(parse_youtube_video_id("https://youtube.com/embed/dQw4w9WgXcQ"), "dQw4w9WgXcQ")

    def test_shorts_url(self) -> None:
        self.assertEqual(parse_youtube_video_id("https://youtube.com/shorts/dQw4w9WgXcQ"), "dQw4w9WgXcQ")

    def test_plain_video_id(self) -> None:
        self.assertEqual(parse_youtube_video_id("dQw4w9WgXcQ"), "dQw4w9WgXcQ")

    def test_placeholder_video_id_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            parse_youtube_video_id("VIDEO_ID")

    def test_normalized_url(self) -> None:
        self.assertEqual(
            normalize_youtube_url("https://youtu.be/dQw4w9WgXcQ"),
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        )


if __name__ == "__main__":
    unittest.main()
