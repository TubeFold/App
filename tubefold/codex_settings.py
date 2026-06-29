from __future__ import annotations

from typing import Any


DEFAULT_CODEX_MODEL = "gpt-5.4-mini"
DEFAULT_CODEX_REASONING_EFFORT = "medium"

CODEX_MODEL_OPTIONS: list[dict[str, str]] = [
    {
        "id": "gpt-5.5",
        "label": "GPT-5.5",
        "description": "Recommended Codex model for complex coding, computer use, knowledge work, and research.",
    },
    {
        "id": "gpt-5.4",
        "label": "GPT-5.4",
        "description": "Flagship model for professional work with strong coding, reasoning, and tool use.",
    },
    {
        "id": "gpt-5.4-mini",
        "label": "GPT-5.4 Mini",
        "description": "Fast, efficient mini model for responsive coding tasks and subagents.",
    },
]

CODEX_REASONING_EFFORT_OPTIONS: list[dict[str, str]] = [
    # "minimal" is deliberately omitted: the Codex CLI injects the web_search and
    # image_gen tools server-side for these models, and the API rejects that
    # combination with reasoning.effort 'minimal' (HTTP 400), so every job fails.
    {"id": "low", "label": "Low", "description": "Fast summaries with light reasoning."},
    {"id": "medium", "label": "Medium", "description": "Recommended balance."},
    {"id": "high", "label": "High", "description": "More careful summaries, slower."},
    {"id": "xhigh", "label": "Extra High", "description": "Hardest jobs where latency matters less."},
]


def valid_codex_model(value: str | None) -> str:
    if value and any(option["id"] == value for option in CODEX_MODEL_OPTIONS):
        return value
    return DEFAULT_CODEX_MODEL


def valid_codex_reasoning_effort(value: str | None) -> str:
    if value and any(option["id"] == value for option in CODEX_REASONING_EFFORT_OPTIONS):
        return value
    return DEFAULT_CODEX_REASONING_EFFORT


def normalize_codex_settings(state: dict[str, Any]) -> dict[str, Any]:
    state["codexModel"] = valid_codex_model(str(state.get("codexModel") or ""))
    state["codexReasoningEffort"] = valid_codex_reasoning_effort(str(state.get("codexReasoningEffort") or ""))
    return state
