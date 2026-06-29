#!/usr/bin/env python3
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Iterable


@dataclass(frozen=True)
class TranscriptResult:
    text: str
    language: str
    language_code: str
    is_generated: bool


class TranscriptError(RuntimeError):
    pass


def base_language(code: Any) -> str:
    """Base subtag of a language code, lowercased (``en-US`` -> ``en``)."""
    return str(code or "").split("-")[0].strip().casefold()


def original_language_code(transcripts: Iterable[Any]) -> str | None:
    """The video's original spoken language, inferred from the ASR track.

    YouTube auto-generates ("asr") captions from the video's audio, so the
    auto-generated track's language is the language actually spoken in the
    video. There is normally exactly one such track. Returns ``None`` when no
    auto-generated track is present (original language can't be inferred).
    """
    for transcript in transcripts:
        if bool(getattr(transcript, "is_generated", False)):
            code = base_language(getattr(transcript, "language_code", ""))
            if code:
                return code
    return None


def select_transcript(transcripts: Iterable[Any], allow_any: bool = True) -> Any:
    """Pick the transcript in the video's original language.

    Always targets the original spoken language (see ``original_language_code``)
    rather than any fixed preference list, since the summary's output language is
    controlled separately. Within the original language a manual (human-authored)
    track is preferred over the auto-generated one. When the original language
    can't be determined (no ASR track), ``allow_any`` decides whether to fall
    back to the best available track or to fail.
    """
    transcript_list = list(transcripts)
    if not transcript_list:
        raise TranscriptError("No transcript found for this video")

    original = original_language_code(transcript_list)
    if original is not None:
        for generated in (False, True):  # manual first, then auto-generated
            for transcript in transcript_list:
                if bool(getattr(transcript, "is_generated", False)) == generated and (
                    base_language(getattr(transcript, "language_code", "")) == original
                ):
                    return transcript

    if allow_any:
        # Original language unknown (no ASR track): prefer a manual track, then
        # take whatever is available.
        for transcript in transcript_list:
            if not bool(getattr(transcript, "is_generated", False)):
                return transcript
        return transcript_list[0]

    raise TranscriptError("Could not determine the video's original transcript language")


def snippets_to_text(snippets: Iterable[Any]) -> str:
    parts: list[str] = []
    for snippet in snippets:
        if isinstance(snippet, dict):
            raw = snippet.get("text", "")
        else:
            raw = getattr(snippet, "text", "")
        text = str(raw).replace("\n", " ").strip()
        if text:
            parts.append(text)
    return re.sub(r"\s+", " ", " ".join(parts)).strip()


def fetched_transcript_to_text(fetched: Any) -> str:
    snippets = getattr(fetched, "snippets", fetched)
    return snippets_to_text(snippets)


def fetch_transcript(
    video_id: str,
    requested_language: str | None = None,
    allow_any: bool = True,
) -> TranscriptResult:
    try:
        from youtube_transcript_api import YouTubeTranscriptApi
        from youtube_transcript_api._errors import NoTranscriptFound, TranscriptsDisabled, VideoUnavailable
    except ImportError as error:
        raise TranscriptError(
            "Missing dependency: youtube-transcript-api. Install it with: "
            "python3 -m pip install youtube-transcript-api"
        ) from error

    api = YouTubeTranscriptApi()

    try:
        if requested_language:
            fetched = api.fetch(video_id, languages=[requested_language])
            text = fetched_transcript_to_text(fetched)
            return TranscriptResult(
                text=text,
                language=str(getattr(fetched, "language", requested_language)),
                language_code=str(getattr(fetched, "language_code", requested_language)),
                is_generated=bool(getattr(fetched, "is_generated", False)),
            )

        transcript_list = api.list(video_id)
        selected = select_transcript(transcript_list, allow_any=allow_any)
        fetched = selected.fetch()
        text = fetched_transcript_to_text(fetched)
        return TranscriptResult(
            text=text,
            language=str(getattr(selected, "language", "")),
            language_code=str(getattr(selected, "language_code", "")),
            is_generated=bool(getattr(selected, "is_generated", False)),
        )
    except TranscriptsDisabled as error:
        raise TranscriptError("Transcripts are disabled for this video") from error
    except NoTranscriptFound as error:
        raise TranscriptError("No transcript found for this video") from error
    except VideoUnavailable as error:
        raise TranscriptError("Video is unavailable") from error


def ensure_transcript_text(result: TranscriptResult) -> None:
    if not result.text or len(result.text) < 20:
        raise TranscriptError("Transcript is empty")
