#!/usr/bin/env python3
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Iterable


DEFAULT_PREFERRED_LANGS = ["pl", "ru", "en"]


@dataclass(frozen=True)
class TranscriptResult:
    text: str
    language: str
    language_code: str
    is_generated: bool


class TranscriptError(RuntimeError):
    pass


def normalize_preferred_langs(value: str | Iterable[str] | None) -> list[str]:
    if value is None:
        return list(DEFAULT_PREFERRED_LANGS)
    if isinstance(value, str):
        items = value.split(",")
    else:
        items = list(value)

    normalized: list[str] = []
    for item in items:
        language = str(item).strip()
        if not language:
            continue
        if language.endswith(".*"):
            language = language[:-2]
        elif language.endswith("*"):
            language = language[:-1]
        normalized.append(language)
    return normalized or list(DEFAULT_PREFERRED_LANGS)


def language_matches(language_code: str, preferred: str) -> bool:
    return language_code.casefold().startswith(preferred.casefold())


def select_transcript(
    transcripts: Iterable[Any],
    preferred_langs: Iterable[str] | None = None,
    allow_any: bool = True,
) -> Any:
    transcript_list = list(transcripts)
    preferred = normalize_preferred_langs(preferred_langs)

    for generated in (False, True):
        for language in preferred:
            for transcript in transcript_list:
                if bool(getattr(transcript, "is_generated", False)) == generated and language_matches(
                    str(getattr(transcript, "language_code", "")), language
                ):
                    return transcript

    if allow_any and transcript_list:
        return transcript_list[0]

    raise TranscriptError("No transcript found for configured languages")


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
    preferred_langs: Iterable[str] | None = None,
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
        selected = select_transcript(transcript_list, preferred_langs, allow_any=allow_any)
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
