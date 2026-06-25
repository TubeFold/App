from __future__ import annotations

import sys
import unittest
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from youtube_transcript_source import TranscriptError, select_transcript, snippets_to_text


@dataclass
class FakeTranscript:
    language: str
    language_code: str
    is_generated: bool


@dataclass
class FakeSnippet:
    text: str


class TranscriptSourceTests(unittest.TestCase):
    def test_manual_transcript_is_preferred_before_auto_tier(self) -> None:
        transcripts = [
            FakeTranscript("Polish auto", "pl", True),
            FakeTranscript("English manual", "en", False),
        ]
        selected = select_transcript(transcripts, ["pl", "ru", "en"], allow_any=True)
        self.assertEqual(selected.language_code, "en")
        self.assertFalse(selected.is_generated)

    def test_auto_generated_preferred_language(self) -> None:
        transcripts = [
            FakeTranscript("German manual", "de", False),
            FakeTranscript("English auto", "en", True),
        ]
        selected = select_transcript(transcripts, ["pl", "ru", "en"], allow_any=True)
        self.assertEqual(selected.language_code, "en")
        self.assertTrue(selected.is_generated)

    def test_regional_language_code_matches_preferred_prefix(self) -> None:
        transcripts = [FakeTranscript("English US", "en-US", False)]
        selected = select_transcript(transcripts, ["en"], allow_any=False)
        self.assertEqual(selected.language_code, "en-US")

    def test_fallback_first_available(self) -> None:
        transcripts = [FakeTranscript("Portuguese", "pt-BR", True)]
        selected = select_transcript(transcripts, ["pl"], allow_any=True)
        self.assertEqual(selected.language_code, "pt-BR")

    def test_no_transcript_without_fallback(self) -> None:
        with self.assertRaises(TranscriptError):
            select_transcript([FakeTranscript("Portuguese", "pt-BR", True)], ["pl"], allow_any=False)

    def test_snippets_to_text_normalizes_whitespace_and_keeps_unicode(self) -> None:
        text = snippets_to_text(
            [
                FakeSnippet("Hello\nworld"),
                FakeSnippet("  Привет   мир  "),
                {"text": "zażółć   gęślą"},
            ]
        )
        self.assertEqual(text, "Hello world Привет мир zażółć gęślą")


if __name__ == "__main__":
    unittest.main()
