"""Shared helpers for emitting provider token-usage sidecar files.

Providers write **only** the Markdown body to ``<output_file>`` (the pipeline
contract). Token usage is written alongside it to ``<output_file>.usage.json``
so ``processing.py`` can persist it without touching the summary. Parsing
failures are best-effort and never fatal — a missing sidecar simply means
"no usage recorded for this run".
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
    """Extract token usage from ``codex exec --json`` JSONL output.

    Codex's JSONL schema changed across CLI versions, so we handle both:

    * **Current** (codex-cli >= ~0.40): a flat ``turn.completed`` event carrying
      ``usage`` (``input_tokens``/``cached_input_tokens``/``output_tokens``/
      ``reasoning_output_tokens``).
    * **Legacy**: an ``event_msg`` whose ``payload.type == "token_count"`` holds
      ``info.total_token_usage``.

    The **last** matching event of either kind wins (cumulative totals for the
    run). The current format is preferred when both appear. Returns ``None``
    when neither is found.
    """
    last_turn: dict[str, Any] | None = None
    last_token_count: dict[str, Any] | None = None
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") == "turn.completed" and isinstance(event.get("usage"), dict):
            last_turn = event["usage"]
            continue
        payload = event.get("payload")
        if isinstance(payload, dict) and payload.get("type") == "token_count":
            last_token_count = payload

    if last_turn is not None:
        input_tokens = _as_int(last_turn.get("input_tokens"))
        output_tokens = _as_int(last_turn.get("output_tokens"))
        # No total in the new schema, and cached input isn't billed as fresh
        # usage — report total = input + output (matches the Claude wrapper).
        return {
            "provider": "codex",
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "reasoning_output_tokens": _as_int(last_turn.get("reasoning_output_tokens")),
            "cached_input_tokens": _as_int(last_turn.get("cached_input_tokens")),
            "total_tokens": input_tokens + output_tokens,
        }

    if last_token_count is None:
        return None

    info = last_token_count.get("info") or {}
    total = info.get("total_token_usage") or {}

    return {
        "provider": "codex",
        "input_tokens": _as_int(total.get("input_tokens")),
        "output_tokens": _as_int(total.get("output_tokens")),
        "reasoning_output_tokens": _as_int(total.get("reasoning_output_tokens")),
        "total_tokens": _as_int(total.get("total_tokens")),
    }
