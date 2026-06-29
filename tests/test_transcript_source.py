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
    def test_manual_original_preferred_over_auto(self) -> None:
        # Original language = English (the ASR track); the manual English track wins.
        transcripts = [
            FakeTranscript("English auto", "en", True),
            FakeTranscript("English manual", "en", False),
        ]
        selected = select_transcript(transcripts)
        self.assertEqual(selected.language_code, "en")
        self.assertFalse(selected.is_generated)

    def test_falls_back_to_auto_in_original_language(self) -> None:
        # No manual track in the original (English) language, so the ASR one is used,
        # never the German manual translation.
        transcripts = [
            FakeTranscript("German manual", "de", False),
            FakeTranscript("English auto", "en", True),
        ]
        selected = select_transcript(transcripts)
        self.assertEqual(selected.language_code, "en")
        self.assertTrue(selected.is_generated)

    def test_original_language_beats_manual_translation(self) -> None:
        # The video is Russian (ASR=ru); an English manual translation must NOT win.
        transcripts = [
            FakeTranscript("Russian auto", "ru", True),
            FakeTranscript("English manual", "en", False),
        ]
        selected = select_transcript(transcripts)
        self.assertEqual(selected.language_code, "ru")
        self.assertTrue(selected.is_generated)

    def test_regional_manual_matches_original_base_language(self) -> None:
        # ASR "en" + manual "en-US": base languages match, manual wins.
        transcripts = [
            FakeTranscript("English auto", "en", True),
            FakeTranscript("English US", "en-US", False),
        ]
        selected = select_transcript(transcripts)
        self.assertEqual(selected.language_code, "en-US")
        self.assertFalse(selected.is_generated)

    def test_no_asr_falls_back_to_first_manual(self) -> None:
        # Original language unknown (no ASR track): take the manual track.
        transcripts = [FakeTranscript("Portuguese", "pt-BR", False)]
        selected = select_transcript(transcripts, allow_any=True)
        self.assertEqual(selected.language_code, "pt-BR")

    def test_no_asr_without_fallback_raises(self) -> None:
        with self.assertRaises(TranscriptError):
            select_transcript([FakeTranscript("Portuguese", "pt-BR", False)], allow_any=False)

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
