from __future__ import annotations

import unittest

from youtube_brain.reading_time import (
    DEFAULT_WPM,
    read_time_as_seconds,
    reading_minutes_for_markdown,
    reading_seconds_for_markdown,
    reading_time_label,
)


class ReadTimeAlgorithmTests(unittest.TestCase):
    def test_wpm_seconds_math(self) -> None:
        # 2 words at 2 wpm -> exactly one minute.
        self.assertEqual(read_time_as_seconds("hello world", wpm=2), 60)
        # ceil rounding: 3 words at 2 wpm -> 90 seconds.
        self.assertEqual(read_time_as_seconds("a b c", wpm=2), 90)

    def test_default_wpm(self) -> None:
        self.assertEqual(DEFAULT_WPM, 265)
        words = " ".join(["word"] * 265)
        self.assertEqual(read_time_as_seconds(words), 60)

    def test_image_time_decays_to_three_second_floor(self) -> None:
        base = read_time_as_seconds("x", images=0)
        # 11 images: 12,11,10,9,8,7,6,5,4,3 then a 3s floor = 78 extra seconds.
        self.assertEqual(read_time_as_seconds("x", images=11) - base, 78)
        # A single image adds the full 12 seconds.
        self.assertEqual(read_time_as_seconds("x", images=1) - base, 12)

    def test_minutes_never_below_one(self) -> None:
        self.assertEqual(reading_minutes_for_markdown(""), 1)
        self.assertEqual(reading_minutes_for_markdown("# Title\n\nA short body."), 1)

    def test_longer_summary_takes_more_minutes(self) -> None:
        body = "# Title\n\n" + " ".join(["word"] * 1200)
        self.assertGreater(reading_minutes_for_markdown(body), 1)

    def test_label_format(self) -> None:
        self.assertEqual(reading_time_label(1), "1 min read")
        self.assertEqual(reading_time_label(7), "7 min read")

    def test_link_urls_are_not_counted(self) -> None:
        with_link = "Read this [guide](https://example.com/very/long/path/with/many/words)."
        without_link = "Read this guide."
        self.assertEqual(
            reading_seconds_for_markdown(with_link),
            reading_seconds_for_markdown(without_link),
        )

    def test_front_matter_is_ignored(self) -> None:
        front = '---\ntitle: "X"\nurl: "https://youtu.be/abc"\n---\n\nBody text here.'
        self.assertEqual(
            reading_seconds_for_markdown(front),
            reading_seconds_for_markdown("Body text here."),
        )


if __name__ == "__main__":
    unittest.main()
