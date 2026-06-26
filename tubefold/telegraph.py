"""Publish summary Markdown to Telegram's Telegraph (telegra.ph) service.

Self-contained, stdlib only. Three concerns live here:

- ``markdown_to_nodes`` / ``strip_front_matter`` — convert a summary's Markdown
  body into the Telegraph "Node" JSON DOM that ``createPage`` expects.
- ``TelegraphClient`` — a thin urllib client for the public Telegraph API
  (``createAccount`` / ``createPage`` / ``editPage``). A ``request_fn`` can be
  injected so tests never touch the network.
- ``TelegraphStore`` / ``TelegraphPublisher`` — persist the single anonymous
  account token (created once, reused forever) and turn a stored summary into a
  published article, caching the resulting URL on the video row.

Telegraph constraints that shape this module (verified against telegra.ph/api):
- Account creation is free/anonymous; ``createAccount`` returns a long-lived
  ``access_token`` that is the only credential we need afterwards.
- ``content`` is an array of Node (string | {tag, attrs?, children?}), max 64 KB.
- Allowed tags are a fixed set; headings are only ``h3``/``h4`` (no ``h1``/``h2``).
- Pages are public and cannot be deleted, only edited.
"""

from __future__ import annotations

import hashlib
import json
import logging
import re
import secrets
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

from .config import AppConfig


logger = logging.getLogger(__name__)

API_BASE_URL = "https://api.telegra.ph"

# Telegraph rejects content larger than 64 KB; stay safely under it.
MAX_CONTENT_BYTES = 63_000
MAX_TITLE_LENGTH = 256

RequestFn = Callable[[str, dict[str, Any]], dict[str, Any]]


class TelegraphError(Exception):
    """Raised when the Telegraph API returns ``ok: false`` or is unreachable."""


# --------------------------------------------------------------------------- #
# Markdown -> Telegraph nodes
# --------------------------------------------------------------------------- #

_FRONT_MATTER_RE = re.compile(r"^---\n.*?\n---\n", re.DOTALL)
_HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")
_HR_RE = re.compile(r"^\s*([-*_])\1{2,}\s*$")
_UL_RE = re.compile(r"^\s*[-*+]\s+(.*)$")
_OL_RE = re.compile(r"^\s*\d+[.)]\s+(.*)$")
_BLOCKQUOTE_RE = re.compile(r"^\s*>\s?(.*)$")
_FENCE_RE = re.compile(r"^\s*(```|~~~)")

# Inline patterns, scanned earliest-match-wins. Code spans win over everything
# else so their contents stay literal.
_INLINE_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("code", re.compile(r"`([^`]+)`")),
    ("link", re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")),
    ("bold", re.compile(r"\*\*([^*]+)\*\*|__([^_]+)__")),
    ("italic", re.compile(r"\*([^*]+)\*|_([^_]+)_")),
    ("strike", re.compile(r"~~([^~]+)~~")),
]


def strip_front_matter(markdown: str) -> str:
    """Remove a leading ``---``-delimited YAML front-matter block, if present."""
    return _FRONT_MATTER_RE.sub("", markdown.lstrip("﻿"), count=1).lstrip("\n")


def _inline_nodes(text: str) -> list[Any]:
    """Convert a single line of inline Markdown into a list of Telegraph nodes."""
    if not text:
        return []

    best: tuple[int, str, re.Match[str]] | None = None
    for kind, pattern in _INLINE_PATTERNS:
        match = pattern.search(text)
        if match and (best is None or match.start() < best[0]):
            best = (match.start(), kind, match)

    if best is None:
        return [text]

    start, kind, match = best
    nodes: list[Any] = []
    if start > 0:
        nodes.append(text[:start])

    inner = next((group for group in match.groups() if group is not None), "")
    if kind == "code":
        nodes.append({"tag": "code", "children": [inner]})
    elif kind == "link":
        label, href = match.group(1), match.group(2)
        nodes.append({"tag": "a", "attrs": {"href": href}, "children": _inline_nodes(label)})
    elif kind == "bold":
        nodes.append({"tag": "strong", "children": _inline_nodes(inner)})
    elif kind == "italic":
        nodes.append({"tag": "em", "children": _inline_nodes(inner)})
    elif kind == "strike":
        nodes.append({"tag": "s", "children": _inline_nodes(inner)})

    nodes.extend(_inline_nodes(text[match.end():]))
    return nodes


def _list_item(text: str) -> dict[str, Any]:
    return {"tag": "li", "children": _inline_nodes(text.strip())}


def markdown_to_nodes(markdown: str) -> list[Any]:
    """Convert summary Markdown (body only) into a Telegraph content node array.

    Handles the constructs our summaries actually use: ATX headings (mapped to
    ``h3``/``h4`` since Telegraph forbids ``h1``/``h2``), paragraphs, ordered and
    unordered lists, blockquotes, fenced code blocks, horizontal rules, and inline
    bold/italic/strikethrough/code/links. Unknown syntax degrades to plain text.
    """
    lines = markdown.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    nodes: list[Any] = []
    paragraph: list[str] = []
    index = 0

    def flush_paragraph() -> None:
        if paragraph:
            text = " ".join(line.strip() for line in paragraph).strip()
            if text:
                nodes.append({"tag": "p", "children": _inline_nodes(text)})
            paragraph.clear()

    while index < len(lines):
        line = lines[index]
        stripped = line.strip()

        if not stripped:
            flush_paragraph()
            index += 1
            continue

        if _FENCE_RE.match(line):
            flush_paragraph()
            fence = _FENCE_RE.match(line).group(1)
            index += 1
            code_lines: list[str] = []
            while index < len(lines) and not lines[index].strip().startswith(fence):
                code_lines.append(lines[index])
                index += 1
            index += 1  # consume closing fence
            nodes.append({"tag": "pre", "children": ["\n".join(code_lines)]})
            continue

        heading = _HEADING_RE.match(line)
        if heading:
            flush_paragraph()
            level = len(heading.group(1))
            tag = "h3" if level <= 2 else "h4"
            nodes.append({"tag": tag, "children": _inline_nodes(heading.group(2).strip())})
            index += 1
            continue

        if _HR_RE.match(line):
            flush_paragraph()
            nodes.append({"tag": "hr"})
            index += 1
            continue

        if _UL_RE.match(line):
            flush_paragraph()
            items: list[Any] = []
            while index < len(lines) and _UL_RE.match(lines[index]):
                items.append(_list_item(_UL_RE.match(lines[index]).group(1)))
                index += 1
            nodes.append({"tag": "ul", "children": items})
            continue

        if _OL_RE.match(line):
            flush_paragraph()
            items = []
            while index < len(lines) and _OL_RE.match(lines[index]):
                items.append(_list_item(_OL_RE.match(lines[index]).group(1)))
                index += 1
            nodes.append({"tag": "ol", "children": items})
            continue

        if _BLOCKQUOTE_RE.match(line):
            flush_paragraph()
            quote_lines: list[str] = []
            while index < len(lines) and _BLOCKQUOTE_RE.match(lines[index]):
                quote_lines.append(_BLOCKQUOTE_RE.match(lines[index]).group(1))
                index += 1
            text = " ".join(part.strip() for part in quote_lines).strip()
            nodes.append({"tag": "blockquote", "children": _inline_nodes(text)})
            continue

        paragraph.append(line)
        index += 1

    flush_paragraph()
    return nodes


def _content_within_limit(content: list[Any]) -> list[Any]:
    """Drop trailing nodes until the serialized content fits Telegraph's 64 KB cap."""
    if len(json.dumps(content, ensure_ascii=False).encode("utf-8")) <= MAX_CONTENT_BYTES:
        return content
    trimmed = list(content)
    notice = {"tag": "p", "children": [{"tag": "em", "children": ["… (summary truncated to fit Telegraph)"]}]}
    while trimmed:
        trimmed.pop()
        candidate = trimmed + [notice]
        if len(json.dumps(candidate, ensure_ascii=False).encode("utf-8")) <= MAX_CONTENT_BYTES:
            return candidate
    return [notice]


def _format_watch_label(duration_seconds: Any) -> str | None:
    """Human "N min watch" label for the video runtime, or ``None`` if unknown."""
    try:
        total = int(round(float(duration_seconds)))
    except (TypeError, ValueError):
        return None
    if total <= 0:
        return None
    if total >= 3600:
        hours, remainder = divmod(total, 3600)
        minutes = remainder // 60
        return f"{hours}h {minutes:02d}m watch"
    minutes = max(1, round(total / 60))
    return f"{minutes} min watch"


def build_article_content(
    summary_markdown: str,
    video_url: str,
    channel: str | None,
    duration_seconds: Any = None,
) -> list[Any]:
    """Assemble the full Telegraph content: a source header, a rule, then the summary.

    The header is two lines so the time trade-off reads at a glance: the first
    line links to the video and shows how long it is to *watch*; the second line
    shows how long the summary is to *read*.
    """
    from .reading_time import reading_minutes_for_markdown, reading_time_label

    body = markdown_to_nodes(strip_front_matter(summary_markdown))

    header_children: list[Any] = [
        {"tag": "a", "attrs": {"href": video_url}, "children": ["▶ Watch on YouTube"]},
    ]
    if channel:
        header_children.append(f" · {channel}")
    watch_label = _format_watch_label(duration_seconds)
    if watch_label:
        header_children.append(f" · {watch_label}")

    read_label = reading_time_label(reading_minutes_for_markdown(summary_markdown))
    read_line = {"tag": "p", "children": [{"tag": "em", "children": [f"📄 {read_label} summary"]}]}

    content: list[Any] = [
        {"tag": "p", "children": header_children},
        read_line,
        {"tag": "hr"},
        *body,
    ]
    return _content_within_limit(content)


# --------------------------------------------------------------------------- #
# Telegraph API client
# --------------------------------------------------------------------------- #


class TelegraphClient:
    def __init__(self, request_fn: RequestFn | None = None, timeout: int = 20) -> None:
        self._request_fn = request_fn or self._http_request
        self._timeout = timeout

    def _http_request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        data = urllib.parse.urlencode(params).encode("utf-8")
        request = urllib.request.Request(f"{API_BASE_URL}/{method}", data=data)
        try:
            with urllib.request.urlopen(request, timeout=self._timeout) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise TelegraphError(f"Could not reach Telegraph: {error}") from error
        except json.JSONDecodeError as error:
            raise TelegraphError("Telegraph returned an invalid response.") from error
        return payload

    def _call(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        payload = self._request_fn(method, params)
        if not payload.get("ok"):
            raise TelegraphError(str(payload.get("error") or "Unknown Telegraph error"))
        return payload.get("result") or {}

    def create_account(self, short_name: str, author_name: str = "", author_url: str = "") -> dict[str, Any]:
        params = {"short_name": short_name[:32] or "tubefold"}
        if author_name:
            params["author_name"] = author_name[:128]
        if author_url:
            params["author_url"] = author_url[:512]
        return self._call("createAccount", params)

    def create_page(
        self,
        access_token: str,
        title: str,
        content: list[Any],
        author_name: str = "",
        author_url: str = "",
    ) -> dict[str, Any]:
        params = self._page_params(access_token, title, content, author_name, author_url)
        return self._call("createPage", params)

    def edit_page(
        self,
        access_token: str,
        path: str,
        title: str,
        content: list[Any],
        author_name: str = "",
        author_url: str = "",
    ) -> dict[str, Any]:
        params = self._page_params(access_token, title, content, author_name, author_url)
        params["path"] = path
        return self._call(f"editPage/{urllib.parse.quote(path)}", params)

    @staticmethod
    def _page_params(
        access_token: str,
        title: str,
        content: list[Any],
        author_name: str,
        author_url: str,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {
            "access_token": access_token,
            "title": (title.strip() or "YouTube summary")[:MAX_TITLE_LENGTH],
            "content": json.dumps(content, ensure_ascii=False),
        }
        if author_name:
            params["author_name"] = author_name[:128]
        if author_url:
            params["author_url"] = author_url[:512]
        return params


# --------------------------------------------------------------------------- #
# Persistence + publishing
# --------------------------------------------------------------------------- #


class TelegraphStore:
    """Persists the single anonymous Telegraph account (created once, reused)."""

    def __init__(self, config: AppConfig) -> None:
        self.path = config.data_dir / "telegraph-account.json"

    def load(self) -> dict[str, Any]:
        if not self.path.exists():
            return {}
        try:
            return json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}

    def save(self, state: dict[str, Any]) -> dict[str, Any]:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return state


class TelegraphPublisher:
    def __init__(self, config: AppConfig, repository: Any, client: TelegraphClient | None = None) -> None:
        self.config = config
        self.repository = repository
        self.store = TelegraphStore(config)
        self.client = client or TelegraphClient()

    def _ensure_account_token(self) -> str:
        state = self.store.load()
        token = state.get("accessToken")
        if token:
            return str(token)

        short_name = f"yt-brain-{secrets.token_hex(4)}"
        account = self.client.create_account(short_name=short_name, author_name="TubeFold")
        token = str(account.get("access_token") or "")
        if not token:
            raise TelegraphError("Telegraph did not return an access token.")
        self.store.save(
            {
                "accessToken": token,
                "shortName": account.get("short_name") or short_name,
                "createdAt": utc_now(),
            }
        )
        logger.info("Created Telegraph account short_name=%s", short_name)
        return token

    def publish(self, video: Any) -> dict[str, Any]:
        """Publish, refresh, or reopen the Telegraph article for a ready video.

        One article per video (a stable URL):
        - first publish creates the page and caches its URL/path;
        - a repeat click with an unchanged summary just reopens the same URL;
        - if the summary was regenerated since publishing, the same page is
          updated in place via ``editPage`` and the same URL is reopened.
        """
        summary = _row_get(video, "summary_markdown")
        if not summary:
            summary_path = _row_get(video, "summary_path")
            if summary_path and Path(summary_path).exists():
                summary = Path(summary_path).read_text(encoding="utf-8")
        if not summary or not summary.strip():
            raise TelegraphError("This video has no summary to publish yet.")

        summary_hash = hashlib.sha256(summary.encode("utf-8")).hexdigest()
        cached_url = _row_get(video, "telegraph_url")
        cached_path = _row_get(video, "telegraph_path")
        cached_hash = _row_get(video, "telegraph_summary_hash")

        if cached_url and cached_path and cached_hash == summary_hash:
            return {"url": cached_url, "status": "reused"}

        token = self._ensure_account_token()
        video_url = _row_get(video, "canonical_url") or ""
        channel = _row_get(video, "channel_name") or ""
        title = _row_get(video, "title") or _row_get(video, "youtube_video_id") or "YouTube summary"
        duration_seconds = _row_get(video, "duration_seconds")
        content = build_article_content(summary, video_url, channel, duration_seconds)

        if cached_url and cached_path:
            self.client.edit_page(
                access_token=token,
                path=cached_path,
                title=title,
                content=content,
                author_name=channel,
                author_url=video_url,
            )
            self.repository.set_telegraph_page(_row_get(video, "id"), cached_url, cached_path, summary_hash)
            logger.info("Updated Telegraph page video=%s url=%s", _row_get(video, "youtube_video_id"), cached_url)
            return {"url": cached_url, "status": "updated"}

        result = self.client.create_page(
            access_token=token,
            title=title,
            content=content,
            author_name=channel,
            author_url=video_url,
        )
        url = str(result.get("url") or "")
        path = str(result.get("path") or "")
        if not url:
            raise TelegraphError("Telegraph did not return a page URL.")

        self.repository.set_telegraph_page(_row_get(video, "id"), url, path, summary_hash)
        logger.info("Published Telegraph page video=%s url=%s", _row_get(video, "youtube_video_id"), url)
        return {"url": url, "status": "published"}


def _row_get(row: Any, key: str) -> Any:
    """Read a column from a sqlite3.Row or a plain dict."""
    try:
        return row[key]
    except (IndexError, KeyError):
        return None


def utc_now() -> str:
    from .repository import utc_now as _utc_now

    return _utc_now()
