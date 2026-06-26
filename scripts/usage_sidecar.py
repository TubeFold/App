"""Shared helpers for emitting provider token-usage sidecar files.

Providers write **only** the Markdown body to ``<output_file>`` (the pipeline
contract). Token usage and live quota are written alongside it to
``<output_file>.usage.json`` so ``processing.py`` can persist them without
touching the summary. Parsing failures are best-effort and never fatal — a
missing sidecar simply means "no usage recorded for this run".
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def sidecar_path(output_file: Path) -> Path:
    return Path(str(output_file) + ".usage.json")


def write_usage_sidecar(output_file: Path, usage: dict[str, Any]) -> None:
    path = sidecar_path(output_file)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(usage, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _as_int(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def claude_usage_from_result(result_obj: dict[str, Any]) -> dict[str, Any] | None:
    """Extract usage from a ``claude --print --output-format json`` result object.

    Claude's accounting splits the prompt into fresh vs. cached input tokens;
    we surface the parts and report total = input + output (cache reads are not
    billed as fresh usage). Returns ``None`` when no usage block is present.
    """
    usage = result_obj.get("usage")
    if not isinstance(usage, dict):
        return None
    input_tokens = _as_int(usage.get("input_tokens"))
    output_tokens = _as_int(usage.get("output_tokens"))
    cache_creation = _as_int(usage.get("cache_creation_input_tokens"))
    cache_read = _as_int(usage.get("cache_read_input_tokens"))
    cost = result_obj.get("total_cost_usd")
    return {
        "provider": "claude",
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cache_creation_input_tokens": cache_creation,
        "cache_read_input_tokens": cache_read,
        "total_tokens": input_tokens + output_tokens,
        "cost_usd": float(cost) if isinstance(cost, (int, float)) else None,
    }


def codex_usage_from_jsonl(stdout: str) -> dict[str, Any] | None:
    """Extract usage + weekly quota from ``codex exec --json`` JSONL output.

    Scans for the **last** ``token_count`` event (the cumulative totals for the
    run) and reads its ``rate_limits`` snapshot (``secondary`` = the 7-day
    window). Returns ``None`` when no token_count event is found.
    """
    last: dict[str, Any] | None = None
    for line in stdout.splitlines():
        line = line.strip()
        if not line or '"token_count"' not in line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        payload = event.get("payload") if isinstance(event, dict) else None
        if isinstance(payload, dict) and payload.get("type") == "token_count":
            last = payload
    if last is None:
        return None

    info = last.get("info") or {}
    total = info.get("total_token_usage") or {}
    rate_limits = last.get("rate_limits") or {}
    secondary = rate_limits.get("secondary") or {}
    primary = rate_limits.get("primary") or {}

    def _percent(window: dict[str, Any]) -> float | None:
        value = window.get("used_percent")
        return float(value) if isinstance(value, (int, float)) else None

    return {
        "provider": "codex",
        "input_tokens": _as_int(total.get("input_tokens")),
        "output_tokens": _as_int(total.get("output_tokens")),
        "reasoning_output_tokens": _as_int(total.get("reasoning_output_tokens")),
        "total_tokens": _as_int(total.get("total_tokens")),
        "weekly_percent": _percent(secondary),
        "weekly_resets_at": secondary.get("resets_at"),
        "primary_percent": _percent(primary),
        "plan_type": rate_limits.get("plan_type"),
    }
