from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from tubefold_lib import safe_filename, unique_markdown_path


class OutputTests(unittest.TestCase):
    def test_safe_filename(self) -> None:
        self.assertEqual(safe_filename("Hello / World: Part 1"), "Hello - World - Part 1")
        self.assertEqual(safe_filename("   Many    spaces   "), "Many spaces")
        self.assertEqual(safe_filename("."), "Untitled YouTube Video")
        self.assertEqual(safe_filename("Emoji 🎮 Test"), "Emoji 🎮 Test")

    def test_unique_markdown_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            (output_dir / "Video.md").write_text("existing", encoding="utf-8")
            self.assertEqual(unique_markdown_path(output_dir, "Video").name, "Video (2).md")


if __name__ == "__main__":
    unittest.main()
