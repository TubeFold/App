from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any


class ProcessingStatus(str, Enum):
    QUEUED = "queued"
    FETCHING_METADATA = "fetchingMetadata"
    FETCHING_TRANSCRIPT = "fetchingTranscript"
    GENERATING_SUMMARY = "generatingSummary"
    READY = "ready"
    FAILED = "failed"
    CANCELLED = "cancelled"


ACTIVE_STATUSES = {
    ProcessingStatus.QUEUED.value,
    ProcessingStatus.FETCHING_METADATA.value,
    ProcessingStatus.FETCHING_TRANSCRIPT.value,
    ProcessingStatus.GENERATING_SUMMARY.value,
}


@dataclass(frozen=True)
class SummaryRequest:
    video_id: str
    url: str
    title: str | None = None
    channel_name: str | None = None
    duration_seconds: float | None = None
    current_time_seconds: float | None = None
    thumbnail_url: str | None = None
    source: str = "chrome-extension"

    @classmethod
    def from_json(cls, data: dict[str, Any], normalized_video_id: str, canonical_url: str) -> "SummaryRequest":
        return cls(
            video_id=normalized_video_id,
            url=canonical_url,
            title=_optional_str(data.get("title")),
            channel_name=_optional_str(data.get("channelName")),
            duration_seconds=_optional_float(data.get("durationSeconds")),
            current_time_seconds=_optional_float(data.get("currentTimeSeconds")),
            thumbnail_url=_optional_str(data.get("thumbnailURL")),
            source=_optional_str(data.get("source")) or "chrome-extension",
        )


@dataclass(frozen=True)
class ProcessingError(Exception):
    code: str
    user_message: str
    technical_message: str


def _optional_str(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _optional_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None
