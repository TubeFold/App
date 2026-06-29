from __future__ import annotations

from typing import Any


DEFAULT_CLAUDE_MODEL = "sonnet"
DEFAULT_CLAUDE_REASONING_EFFORT = "medium"

CLAUDE_MODEL_OPTIONS: list[dict[str, str]] = [
    {
        "id": "opus",
        "label": "Opus 4.8",
        "description": "Most capable Claude model for the hardest, longest transcripts.",
    },
    {
        "id": "sonnet",
        "label": "Sonnet 4.6",
        "description": "Recommended balance of quality and speed for everyday summaries.",
    },
    {
        "id": "haiku",
        "label": "Haiku 4.5",
        "description": "Fastest, most efficient model for quick summaries.",
    },
]

CLAUDE_REASONING_EFFORT_OPTIONS: list[dict[str, str]] = [
    {"id": "low", "label": "Low", "description": "Fast summaries with light reasoning."},
    {"id": "medium", "label": "Medium", "description": "Recommended balance."},
    {"id": "high", "label": "High", "description": "More careful summaries, slower."},
    {"id": "xhigh", "label": "Extra High", "description": "Harder jobs where latency matters less."},
    {"id": "max", "label": "Maximum", "description": "Deepest reasoning for the toughest transcripts."},
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
