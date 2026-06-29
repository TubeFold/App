from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHANGELOG_SCRIPT = ROOT / "scripts" / "changelog.py"

spec = importlib.util.spec_from_file_location("changelog", CHANGELOG_SCRIPT)
assert spec is not None and spec.loader is not None
changelog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(changelog)


class ChangelogTests(unittest.TestCase):
    def test_extract_section_consumes_heading_date(self) -> None:
        text = "# Changelog\n\n## [1.2] - 2026-06-29\n### Added\n- Nice things.\n"
        self.assertEqual(
            changelog.extract_section(text, "v1.2"),
            "### Added\n- Nice things.",
        )

    def test_inject_description_marks_inline_notes_as_markdown(self) -> None:
        directory = Path(tempfile.mkdtemp())
        appcast = directory / "appcast.xml"
        appcast.write_text(
            '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
            "  <channel>\n"
            "    <item>\n"
            "      <title>TubeFold 0.6</title>\n"
            "      <sparkle:shortVersionString>0.6</sparkle:shortVersionString>\n"
            "    </item>\n"
            "  </channel>\n"
            "</rss>\n",
            encoding="utf-8",
        )

        rc = changelog.main([
            "inject",
            "--version",
            "0.6",
            "--changelog",
            str(ROOT / "CHANGELOG.md"),
            str(appcast),
        ])

        self.assertEqual(rc, 0)
        xml = appcast.read_text(encoding="utf-8")
        self.assertIn('<description sparkle:format="markdown"><![CDATA[', xml)
        self.assertIn("### Added\n- Export any summary to PDF.", xml)


if __name__ == "__main__":
    unittest.main()
