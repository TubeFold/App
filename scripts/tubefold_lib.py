#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import unicodedata
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse, urlunparse


TRUE_VALUES = {"1", "true", "yes", "on"}
FALSE_VALUES = {"0", "false", "no", "off"}


def parse_bool(value: str | bool | None, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    normalized = value.strip().casefold()
    if normalized in TRUE_VALUES:
        return True
    if normalized in FALSE_VALUES:
        return False
    return default


def parse_env_file(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}

    config: dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"Invalid config line {line_number} in {path}: missing '='")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            raise ValueError(f"Invalid config key {key!r} in {path}:{line_number}")
        config[key] = _unquote_env_value(value)
    return config


def _unquote_env_value(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        value = value[1:-1]
    if value.startswith("export "):
        value = value.removeprefix("export ").strip()
    return value


def expand_path(value: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(value))).resolve()


VIDEO_ID_RE = re.compile(r"[A-Za-z0-9_-]{11}")


def parse_youtube_video_id(value: str) -> str:
    candidate = value.strip()
    if VIDEO_ID_RE.fullmatch(candidate):
        return candidate

    if "://" not in candidate and candidate.casefold().startswith(
        ("youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be")
    ):
        candidate = "https://" + candidate

    parsed = urlparse(candidate)
    host = parsed.netloc.casefold()
    if host.startswith("www."):
        host = host[4:]

    video_id = ""
    if host == "youtu.be":
        video_id = parsed.path.strip("/").split("/", 1)[0]
    elif host in {"youtube.com", "m.youtube.com"} and parsed.path == "/watch":
        video_id = parse_qs(parsed.query).get("v", [""])[0]
    elif host in {"youtube.com", "m.youtube.com"}:
        parts = [part for part in parsed.path.split("/") if part]
        if len(parts) >= 2 and parts[0] in {"embed", "shorts", "live"}:
            video_id = parts[1]

    video_id = video_id.split("?", 1)[0].split("&", 1)[0]
    if not video_id or not VIDEO_ID_RE.fullmatch(video_id):
        raise ValueError(
            "Unsupported YouTube URL. Expected youtube.com/watch?v=..., youtu.be/..., "
            "youtube.com/embed/..., youtube.com/shorts/... or a plain video ID."
        )
    return video_id


def normalize_youtube_url(url: str) -> str:
    video_id = parse_youtube_video_id(url)

    return urlunparse(("https", "www.youtube.com", "/watch", "", f"v={video_id}", ""))


def extract_video_id(url: str) -> str:
    return parse_youtube_video_id(url)


def youtube_thumbnail_url(video_id: str) -> str:
    """Deterministic thumbnail URL derived from a YouTube video id.

    Manually-added videos arrive as a bare URL with no thumbnail; the id alone
    is enough to build a working cover image without any network call.
    """
    video_id = str(video_id or "").strip()
    if not video_id:
        return ""
    return f"https://i.ytimg.com/vi/{video_id}/hqdefault.jpg"


def duration_hms(seconds: Any) -> str:
    try:
        total = int(seconds)
    except (TypeError, ValueError):
        return ""
    if total < 0:
        return ""
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours:d}:{minutes:02d}:{secs:02d}"
    return f"{minutes:d}:{secs:02d}"


def published_date(metadata: dict[str, Any]) -> str:
    raw = metadata.get("upload_date") or metadata.get("release_date")
    if isinstance(raw, str) and re.fullmatch(r"\d{8}", raw):
        return f"{raw[:4]}-{raw[4:6]}-{raw[6:8]}"
    timestamp = metadata.get("timestamp")
    if isinstance(timestamp, (int, float)):
        return _dt.datetime.fromtimestamp(timestamp, _dt.timezone.utc).date().isoformat()
    return ""


def metadata_fields(metadata: dict[str, Any], fallback_url: str) -> dict[str, Any]:
    url = metadata.get("webpage_url") or metadata.get("original_url") or fallback_url
    try:
        normalized_url = normalize_youtube_url(str(url))
    except ValueError:
        normalized_url = fallback_url

    video_id = metadata.get("id")
    if not video_id:
        try:
            video_id = extract_video_id(normalized_url)
        except ValueError:
            video_id = ""

    return {
        "video_id": str(video_id or ""),
        "url": normalized_url,
        "title": str(metadata.get("title") or video_id or "YouTube video"),
        "channel": str(
            metadata.get("channel")
            or metadata.get("uploader")
            or metadata.get("creator")
            or metadata.get("channel_id")
            or ""
        ),
        "duration_seconds": _int_or_none(metadata.get("duration")),
        "duration": duration_hms(metadata.get("duration")),
        "published_at": published_date(metadata),
    }


def _int_or_none(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def safe_filename(title: str, max_length: int = 120) -> str:
    value = unicodedata.normalize("NFC", title or "")
    value = "".join(ch for ch in value if unicodedata.category(ch)[0] != "C")
    value = re.sub(r"[/\\:]+", " - ", value)
    value = re.sub(r'[<>|"*?]+', "", value)
    value = re.sub(r"\s+", " ", value).strip(" .")
    if not value or value in {".", ".."}:
        value = "Untitled YouTube Video"
    if len(value) > max_length:
        value = value[:max_length].rstrip(" .")
    return value or "Untitled YouTube Video"


def unique_markdown_path(output_dir: Path, title: str) -> Path:
    base = safe_filename(title)
    candidate = output_dir / f"{base}.md"
    if not candidate.exists():
        return candidate

    for index in range(2, 1000):
        candidate = output_dir / f"{base} ({index}).md"
        if not candidate.exists():
            return candidate
    raise RuntimeError(f"Unable to find a free filename for {base!r}")


def yaml_front_matter(fields: dict[str, Any]) -> str:
    lines = ["---"]
    for key, value in fields.items():
        lines.append(f"{key}: {_yaml_scalar(value)}")
    lines.append("---")
    return "\n".join(lines) + "\n\n"


def _yaml_scalar(value: Any) -> str:
    if value is None:
        return '""'
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)


def model_label(provider: str, model: str, reasoning_effort: str = "") -> str:
    """Combined model field, e.g. ``codex gpt-5.4-mini (effort: medium)``."""
    provider = (provider or "").strip()
    model = (model or "").strip()
    reasoning_effort = (reasoning_effort or "").strip()
    label = f"{provider} {model}".strip() if model else provider
    if reasoning_effort:
        label = f"{label} (effort: {reasoning_effort})"
    return label


def processed_at_now() -> str:
    return _dt.datetime.now().astimezone().isoformat(timespec="seconds")


def render_template(template_text: str, values: dict[str, Any]) -> str:
    rendered = template_text
    for key, value in values.items():
        rendered = rendered.replace("{{" + key + "}}", "" if value is None else str(value))
    return rendered


PROJECT_NAME = "TubeFold"
PROJECT_URL = "https://tubefold.com"


def tubefold_footer_markdown() -> str:
    """A light "made with TubeFold" credit appended to every saved ``.md``.

    Rendered as a horizontal rule followed by an italic one-liner. Telegraph does
    *not* inherit this — ``telegraph.build_article_content`` strips it (via
    :func:`strip_tubefold_footer`) and renders its own richer credit that also
    carries the watch→read time. Keeping the marker text here keeps the writer
    and the stripper in sync."""
    return f"\n---\n\n_Generated with [{PROJECT_NAME}]({PROJECT_URL})_\n"


# Matches the trailing block produced by ``tubefold_footer_markdown`` — an
# optional rule then an italic "Generated with [label](href)" credit line at the
# very end of the document. Label/href are matched generically so re-branding
# the credit doesn't break the stripper.
_FOOTER_STRIP_RE = re.compile(
    r"\n*-{3,}[ \t]*\n+_Generated with \[[^\]]+\]\([^)]+\)_[ \t]*\n*\Z"
)


def strip_tubefold_footer(markdown: str) -> str:
    """Remove a trailing TubeFold credit footer, if present (no-op otherwise)."""
    return _FOOTER_STRIP_RE.sub("", markdown)


def strip_outer_markdown_fence(text: str) -> str:
    stripped = text.strip()
    match = re.fullmatch(r"```(?:markdown|md)?[ \t]*\n(?P<body>.*)\n```[ \t]*", stripped, re.DOTALL | re.IGNORECASE)
    if match:
        return match.group("body").strip() + "\n"
    return text.strip() + "\n"


def validate_provider_response(text: str) -> None:
    stripped = text.strip()
    if not stripped:
        raise ValueError("Provider output is empty")
    if len(stripped) < 20:
        raise ValueError("Provider output is too short to be a useful summary")


def _main() -> int:
    parser = argparse.ArgumentParser(description="Shared helpers for tubefold")
    subparsers = parser.add_subparsers(dest="command", required=True)

    sanitize = subparsers.add_parser("sanitize-filename")
    sanitize.add_argument("title")
    sanitize.add_argument("--max-length", type=int, default=120)

    args = parser.parse_args()
    if args.command == "sanitize-filename":
        print(safe_filename(args.title, args.max_length))
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(_main())
