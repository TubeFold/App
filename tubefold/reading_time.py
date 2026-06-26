"""Estimate how long a summary takes to read.

A stdlib-only port of the ``readtime`` package's algorithm
(https://github.com/alanhamlett/readtime), which itself mirrors Medium's
read-time formula:

- average reading speed of ``DEFAULT_WPM`` (265) words per minute,
- words counted by splitting on ``\\W+`` (matching ``readtime`` exactly, empty
  tokens included),
- inline images add time that decays from 12s for the first image down to a
  3s-per-image floor,
- the final read time is ``max(1, ceil(seconds / 60))`` minutes.

The summary's visible text is extracted by reusing :mod:`telegraph`'s Markdown
parser, so link URLs are dropped and only their labels are counted — the same
behaviour ``readtime``'s HTML parser has.
"""

from __future__ import annotations

import math
import re
from typing import Any

from .telegraph import markdown_to_nodes, strip_front_matter


DEFAULT_WPM = 265
_WORD_DELIMITER = re.compile(r"\W+")


def read_time_as_seconds(text: str, images: int = 0, wpm: int = DEFAULT_WPM) -> int:
    """Reading time of plain text in seconds (``readtime.read_time_as_seconds``)."""
    try:
        num_words = len(_WORD_DELIMITER.split(text.strip()))
    except (AttributeError, TypeError):
        num_words = 0

    seconds = math.ceil(num_words / wpm * 60)

    delta = 12
    for _ in range(max(0, images)):
        seconds += delta
        if delta > 3:
            delta -= 1

    return seconds


def _collect_text(nodes: list[Any], out: list[str], images: list[Any]) -> None:
    for node in nodes:
        if isinstance(node, str):
            out.append(node)
        elif isinstance(node, dict):
            if node.get("tag") == "img":
                images.append(node)
            children = node.get("children")
            if isinstance(children, list):
                _collect_text(children, out, images)


def _markdown_plain_text(summary_markdown: str) -> tuple[str, int]:
    body = strip_front_matter(summary_markdown or "")
    parts: list[str] = []
    images: list[Any] = []
    _collect_text(markdown_to_nodes(body), parts, images)
    plain_text = re.sub(r"\s+", " ", " ".join(parts)).strip()
    return plain_text, len(images)


def reading_seconds_for_markdown(summary_markdown: str, wpm: int = DEFAULT_WPM) -> int:
    text, images = _markdown_plain_text(summary_markdown)
    return read_time_as_seconds(text, images=images, wpm=wpm)


def reading_minutes_for_markdown(summary_markdown: str, wpm: int = DEFAULT_WPM) -> int:
    """Whole-minute read time of a summary's Markdown, never below 1."""
    seconds = reading_seconds_for_markdown(summary_markdown, wpm=wpm)
    return max(1, math.ceil(seconds / 60))


def reading_time_label(minutes: int) -> str:
    """Human label, e.g. ``"5 min read"`` (matches ``readtime``'s repr)."""
    return f"{minutes} min read"
