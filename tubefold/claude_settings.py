from __future__ import annotations

from typing import Any


DEFAULT_CLAUDE_MODEL = "sonnet"
DEFAULT_CLAUDE_REASONING_EFFORT = "auto"

CLAUDE_MODEL_OPTIONS: list[dict[str, str]] = [
    {
        "id": "opus",
        "label": "Opus 4.8",
        "description": "Most capable Claude model for the hardest, longest transcripts.",
    },
    {
        "id": "sonnet",
        "label": "Sonnet 5",
        "description": "Recommended balance of quality and speed for everyday summaries.",
    },
    {
        "id": "haiku",
        "label": "Haiku 4.5",
        "description": "Fastest, most efficient model for quick summaries.",
    },
]

# Effort ids mirror the Claude Code CLI's own `--effort` levels (low, medium,
# high, xhigh, max) verbatim — Anthropic ships no prettier display names, so we
# don't invent any. "auto" is a TubeFold-only sentinel: the provider omits
# `--effort` entirely and lets the CLI pick the model's default.
CLAUDE_REASONING_EFFORT_OPTIONS: list[dict[str, str]] = [
    {"id": "auto", "label": "Auto", "description": "Let Claude pick the model's default effort."},
    {"id": "low", "label": "Low", "description": "Fast summaries with light reasoning."},
    {"id": "medium", "label": "Medium", "description": "Balanced reasoning."},
    {"id": "high", "label": "High", "description": "More careful summaries, slower."},
    {"id": "xhigh", "label": "xhigh", "description": "Extended reasoning for harder transcripts."},
    {"id": "max", "label": "max", "description": "Deepest reasoning for the toughest transcripts."},
]


def valid_claude_model(value: str | None) -> str:
    if value and any(option["id"] == value for option in CLAUDE_MODEL_OPTIONS):
        return value
    return DEFAULT_CLAUDE_MODEL


def valid_claude_reasoning_effort(value: str | None) -> str:
    if value and any(option["id"] == value for option in CLAUDE_REASONING_EFFORT_OPTIONS):
        return value
    return DEFAULT_CLAUDE_REASONING_EFFORT


def normalize_claude_settings(state: dict[str, Any]) -> dict[str, Any]:
    state["claudeModel"] = valid_claude_model(str(state.get("claudeModel") or ""))
    state["claudeReasoningEffort"] = valid_claude_reasoning_effort(str(state.get("claudeReasoningEffort") or ""))
    return state
