from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from usage_sidecar import (
    claude_usage_from_result,
    codex_usage_from_jsonl,
    sidecar_path,
    write_usage_sidecar,
)


CLAUDE_RESULT = {
    "type": "result",
    "is_error": False,
    "result": "# Summary\n\nBody.",
    "total_cost_usd": 0.0123,
    "usage": {
        "input_tokens": 2,
        "cache_creation_input_tokens": 11985,
        "cache_read_input_tokens": 16845,
        "output_tokens": 2583,
    },
}

# Current codex-cli (>= ~0.40) --json schema: a flat turn.completed usage block,
# with no rate_limits snapshot anywhere in the stream.
CODEX_JSONL_TURN_COMPLETED = "\n".join(
    [
        json.dumps({"type": "thread.started", "thread_id": "abc"}),
        json.dumps({"type": "turn.started"}),
        json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": "ok"}}),
        json.dumps(
            {
                "type": "turn.completed",
                "usage": {
                    "input_tokens": 16286,
                    "cached_input_tokens": 10624,
                    "output_tokens": 5,
                    "reasoning_output_tokens": 0,
                },
            }
        ),
    ]
)

# Legacy schema: event_msg/token_count payload. (Any rate_limits snapshot it may
# carry is ignored — the app no longer surfaces quota.)
CODEX_JSONL = "\n".join(
    [
        json.dumps({"type": "event_msg", "payload": {"type": "agent_message", "message": "hi"}}),
        json.dumps(
            {
                "type": "event_msg",
                "payload": {
                    "type": "token_count",
                    "info": {"total_token_usage": {"input_tokens": 100, "output_tokens": 20, "reasoning_output_tokens": 5, "total_tokens": 125}},
                },
            }
        ),
        # A later, cumulative token_count event should win.
        json.dumps(
            {
                "type": "event_msg",
                "payload": {
                    "type": "token_count",
                    "info": {"total_token_usage": {"input_tokens": 300, "output_tokens": 80, "reasoning_output_tokens": 40, "total_tokens": 420}},
                },
            }
        ),
    ]
)


class ClaudeUsageTests(unittest.TestCase):
    def test_extracts_tokens_and_cost(self) -> None:
        usage = claude_usage_from_result(CLAUDE_RESULT)
        assert usage is not None
        self.assertEqual(usage["provider"], "claude")
        self.assertEqual(usage["input_tokens"], 2)
        self.assertEqual(usage["output_tokens"], 2583)
        self.assertEqual(usage["cache_read_input_tokens"], 16845)
        self.assertEqual(usage["total_tokens"], 2585)  # input + output
        self.assertAlmostEqual(usage["cost_usd"], 0.0123)

    def test_missing_usage_returns_none(self) -> None:
        self.assertIsNone(claude_usage_from_result({"result": "x"}))


class CodexUsageTests(unittest.TestCase):
    def test_turn_completed_usage(self) -> None:
        usage = codex_usage_from_jsonl(CODEX_JSONL_TURN_COMPLETED)
        assert usage is not None
        self.assertEqual(usage["provider"], "codex")
        self.assertEqual(usage["input_tokens"], 16286)
        self.assertEqual(usage["output_tokens"], 5)
        self.assertEqual(usage["reasoning_output_tokens"], 0)
        self.assertEqual(usage["cached_input_tokens"], 10624)
        self.assertEqual(usage["total_tokens"], 16291)  # input + output, cache excluded

    def test_turn_completed_preferred_over_legacy_token_count(self) -> None:
        combined = CODEX_JSONL + "\n" + CODEX_JSONL_TURN_COMPLETED
        usage = codex_usage_from_jsonl(combined)
        assert usage is not None
        self.assertEqual(usage["input_tokens"], 16286)

    def test_uses_last_legacy_token_count(self) -> None:
        usage = codex_usage_from_jsonl(CODEX_JSONL)
        assert usage is not None
        self.assertEqual(usage["provider"], "codex")
        self.assertEqual(usage["total_tokens"], 420)
        self.assertEqual(usage["input_tokens"], 300)
        self.assertEqual(usage["reasoning_output_tokens"], 40)
        self.assertNotIn("weekly_percent", usage)

    def test_no_token_count_returns_none(self) -> None:
        self.assertIsNone(codex_usage_from_jsonl('{"type":"event_msg","payload":{"type":"agent_message"}}'))

    def test_garbled_lines_are_skipped(self) -> None:
        self.assertIsNone(codex_usage_from_jsonl("not json\nstill not json"))


class SidecarTests(unittest.TestCase):
    def test_sidecar_path_appends_suffix(self) -> None:
        self.assertEqual(sidecar_path(Path("/x/provider-output.md")).name, "provider-output.md.usage.json")

    def test_write_roundtrip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "provider-output.md"
            write_usage_sidecar(output, {"provider": "codex", "total_tokens": 9})
            data = json.loads(sidecar_path(output).read_text(encoding="utf-8"))
            self.assertEqual(data["total_tokens"], 9)


if __name__ == "__main__":
    unittest.main()
