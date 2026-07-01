from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tubefold.config import AppConfig
from tubefold.provider_setup import (
    ClaudeProviderDiagnostics,
    ProviderSetupStore,
    diagnostics_for,
    provider_summaries,
)


def make_config(data_dir: Path) -> AppConfig:
    return AppConfig(
        host="127.0.0.1",
        port=0,
        api_token=None,
        allowed_origins=("chrome-extension://*",),
        provider="claude",
        python_executable="python3",
        codex_timeout_seconds=30,
        data_dir=data_dir,
        output_dir=data_dir / "exports",
    )


def write_fake_claude(path: Path, marker: str = "CLAUDE_CONNECTION_OK", version: str = "2.1.177 (Claude Code)") -> None:
    path.write_text(
        f"""#!/usr/bin/env python3
import sys

if "--version" in sys.argv:
    print({version!r})
    raise SystemExit(0)

if "--print" in sys.argv:
    _prompt = sys.stdin.read()
    sys.stdout.write({marker!r})
    raise SystemExit(0)

print("unexpected invocation", sys.argv, file=sys.stderr)
raise SystemExit(2)
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


def write_auth_required_claude(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import sys

if "--version" in sys.argv:
    print("2.1.177 (Claude Code)")
    raise SystemExit(0)

print("Invalid API key · Please run /login", file=sys.stderr)
raise SystemExit(1)
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


class ClaudeProviderTests(unittest.TestCase):
    def test_detect_installation_saves_path_and_version(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            fake_claude = data_dir / "claude"
            write_fake_claude(fake_claude)
            diagnostics = ClaudeProviderDiagnostics(make_config(data_dir))

            result = diagnostics.detect_installation(str(fake_claude))

            self.assertEqual(result["status"], "installed")
            self.assertEqual(result["path"], str(fake_claude.resolve()))
            self.assertEqual(result["version"], "2.1.177 (Claude Code)")
            state = diagnostics.state()
            self.assertEqual(state["claudeExecutablePath"], str(fake_claude.resolve()))
            self.assertEqual(state["claudeVersion"], "2.1.177 (Claude Code)")
            self.assertEqual(state["selectedProviderID"], "claude")

    def test_connection_test_success_sets_completed_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            fake_claude = data_dir / "claude"
            write_fake_claude(fake_claude)
            diagnostics = ClaudeProviderDiagnostics(make_config(data_dir))
            diagnostics.detect_installation(str(fake_claude))

            result = diagnostics.test_connection()

            self.assertEqual(result["status"], "success")
            self.assertEqual(result["details"]["errorCategory"], "success")
            state = diagnostics.state()
            self.assertTrue(state["providerSetupCompleted"])
            self.assertEqual(state["selectedProviderID"], "claude")
            self.assertTrue(state["lastSuccessfulConnectionTest"])
            self.assertTrue(state["claudeConnectedAt"])

    def test_model_settings_are_saved_and_normalized(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            diagnostics = ClaudeProviderDiagnostics(make_config(data_dir))

            result = diagnostics.save_model_settings("opus", "high")

            self.assertEqual(result["status"], "saved")
            state = diagnostics.state()
            self.assertEqual(state["claudeModel"], "opus")
            self.assertEqual(state["claudeReasoningEffort"], "high")

            diagnostics.save_model_settings("unknown", "unsupported")
            state = diagnostics.state()
            self.assertEqual(state["claudeModel"], "sonnet")
            self.assertEqual(state["claudeReasoningEffort"], "auto")

    def test_connection_test_invalid_response(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            fake_claude = data_dir / "claude"
            write_fake_claude(fake_claude, marker="WRONG")
            diagnostics = ClaudeProviderDiagnostics(make_config(data_dir))

            result = diagnostics.test_connection(str(fake_claude))

            self.assertEqual(result["status"], "invalidResponse")
            self.assertEqual(result["details"]["errorCategory"], "invalidOutput")

    def test_auth_failure_marks_setup_incomplete(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            fake_claude = data_dir / "claude"
            write_auth_required_claude(fake_claude)
            diagnostics = ClaudeProviderDiagnostics(make_config(data_dir))
            diagnostics.detect_installation(str(fake_claude))

            result = diagnostics.test_connection(str(fake_claude))

            self.assertEqual(result["status"], "authenticationRequired")
            state = diagnostics.state()
            self.assertFalse(state["providerSetupCompleted"])
            self.assertIsNone(state["lastSuccessfulConnectionTest"])

    def test_select_switches_active_provider_and_completion(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            config = make_config(data_dir)
            fake_claude = data_dir / "claude"
            write_fake_claude(fake_claude)
            claude = ClaudeProviderDiagnostics(config)
            claude.detect_installation(str(fake_claude))
            claude.test_connection()

            store = ProviderSetupStore(config)
            # Switch to codex (never configured) -> setup is incomplete for it.
            state = store.select("codex")
            self.assertEqual(state["selectedProviderID"], "codex")
            self.assertFalse(state["providerSetupCompleted"])

            # Switch back to claude -> its prior successful connection is remembered.
            state = store.select("claude")
            self.assertEqual(state["selectedProviderID"], "claude")
            self.assertTrue(state["providerSetupCompleted"])

    def test_provider_summaries_report_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            config = make_config(data_dir)
            fake_claude = data_dir / "claude"
            write_fake_claude(fake_claude)
            claude = ClaudeProviderDiagnostics(config)
            claude.detect_installation(str(fake_claude))
            claude.test_connection()

            summaries = {item["id"]: item for item in provider_summaries(config)}
            self.assertEqual(set(summaries), {"codex", "claude"})
            self.assertTrue(summaries["claude"]["configured"])
            self.assertFalse(summaries["codex"]["configured"])
            self.assertEqual(summaries["claude"]["displayName"], "Claude Code CLI")

    def test_diagnostics_for_unknown_falls_back_to_codex(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(Path(directory))
            self.assertEqual(diagnostics_for("bogus", config).provider_id, "codex")
            self.assertEqual(diagnostics_for("claude", config).provider_id, "claude")


if __name__ == "__main__":
    unittest.main()
