from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from youtube_brain.config import AppConfig
from youtube_brain.provider_setup import CodexProviderDiagnostics


def make_config(data_dir: Path) -> AppConfig:
    return AppConfig(
        host="127.0.0.1",
        port=0,
        api_token=None,
        allowed_origins=("chrome-extension://*",),
        provider="codex",
        python_executable="python3",
        codex_timeout_seconds=30,
        data_dir=data_dir,
        output_dir=data_dir / "exports",
    )


def write_fake_codex(path: Path, marker: str = "CODEX_CONNECTION_OK", version: str = "codex-cli 1.2.3") -> None:
    path.write_text(
        f"""#!/usr/bin/env python3
import pathlib
import sys

if "--version" in sys.argv:
    print({version!r})
    raise SystemExit(0)

if len(sys.argv) >= 2 and sys.argv[1] == "exec":
    output = None
    for index, arg in enumerate(sys.argv):
        if arg == "--output-last-message" and index + 1 < len(sys.argv):
            output = pathlib.Path(sys.argv[index + 1])
            break
    if output is None:
        print("missing output path", file=sys.stderr)
        raise SystemExit(2)
    _prompt = sys.stdin.read()
    output.write_text({marker!r}, encoding="utf-8")
    raise SystemExit(0)

print("unexpected invocation", sys.argv, file=sys.stderr)
raise SystemExit(2)
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


def write_auth_required_codex(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import sys

if "--version" in sys.argv:
    print("codex-cli 1.2.3")
    raise SystemExit(0)

print("not logged in", file=sys.stderr)
raise SystemExit(1)
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


class ProviderSetupTests(unittest.TestCase):
    def test_detect_installation_saves_path_and_version(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            fake_codex = data_dir / "codex"
            write_fake_codex(fake_codex)
            diagnostics = CodexProviderDiagnostics(make_config(data_dir))

            result = diagnostics.detect_installation(str(fake_codex))

            self.assertEqual(result["status"], "installed")
            self.assertEqual(result["path"], str(fake_codex.resolve()))
            self.assertEqual(result["version"], "codex-cli 1.2.3")
            state = diagnostics.state()
            self.assertEqual(state["codexExecutablePath"], str(fake_codex.resolve()))
            self.assertEqual(state["codexVersion"], "codex-cli 1.2.3")

    def test_connection_test_success_sets_completed_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            fake_codex = data_dir / "codex"
            write_fake_codex(fake_codex)
            diagnostics = CodexProviderDiagnostics(make_config(data_dir))
            diagnostics.detect_installation(str(fake_codex))

            result = diagnostics.test_connection()

            self.assertEqual(result["status"], "success")
            self.assertEqual(result["details"]["errorCategory"], "success")
            state = diagnostics.state()
            self.assertTrue(state["providerSetupCompleted"])
            self.assertEqual(state["selectedProviderID"], "codex")
            self.assertTrue(state["lastSuccessfulConnectionTest"])

    def test_model_settings_are_saved_and_normalized(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            diagnostics = CodexProviderDiagnostics(make_config(data_dir))

            result = diagnostics.save_model_settings("gpt-5.5", "high")

            self.assertEqual(result["status"], "saved")
            state = diagnostics.state()
            self.assertEqual(state["codexModel"], "gpt-5.5")
            self.assertEqual(state["codexReasoningEffort"], "high")

            diagnostics.save_model_settings("unknown", "unsupported")
            state = diagnostics.state()
            self.assertEqual(state["codexModel"], "gpt-5.4-mini")
            self.assertEqual(state["codexReasoningEffort"], "medium")

    def test_output_language_is_saved_and_normalized(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            diagnostics = CodexProviderDiagnostics(make_config(data_dir))

            self.assertEqual(diagnostics.state()["outputLanguage"], "English")

            result = diagnostics.save_output_language("  日本語 \n語")
            self.assertEqual(result["status"], "saved")
            self.assertEqual(diagnostics.state()["outputLanguage"], "日本語 語")

            diagnostics.save_output_language("")
            self.assertEqual(diagnostics.state()["outputLanguage"], "English")

    def test_connection_test_invalid_response(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            fake_codex = data_dir / "codex"
            write_fake_codex(fake_codex, marker="WRONG")
            diagnostics = CodexProviderDiagnostics(make_config(data_dir))

            result = diagnostics.test_connection(str(fake_codex))

            self.assertEqual(result["status"], "invalidResponse")
            self.assertEqual(result["details"]["errorCategory"], "invalidOutput")

    def test_invalid_installation_marks_setup_incomplete(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            fake_codex = data_dir / "codex"
            write_fake_codex(fake_codex)
            fake_codex.chmod(0o644)
            diagnostics = CodexProviderDiagnostics(make_config(data_dir))
            diagnostics.store.update(
                codexExecutablePath=str(fake_codex),
                codexVersion="codex-cli 1.2.3",
                providerSetupCompleted=True,
                lastSuccessfulConnectionTest="2026-06-25T00:00:00Z",
            )

            result = diagnostics.detect_installation(str(fake_codex))

            self.assertEqual(result["status"], "invalid")
            state = diagnostics.state()
            self.assertFalse(state["providerSetupCompleted"])
            self.assertIsNone(state["lastSuccessfulConnectionTest"])

    def test_auth_failure_marks_setup_incomplete(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            fake_codex = data_dir / "codex"
            write_auth_required_codex(fake_codex)
            diagnostics = CodexProviderDiagnostics(make_config(data_dir))
            diagnostics.detect_installation(str(fake_codex))
            diagnostics.store.update(providerSetupCompleted=True, lastSuccessfulConnectionTest="2026-06-25T00:00:00Z")

            result = diagnostics.test_connection(str(fake_codex))

            self.assertEqual(result["status"], "authenticationRequired")
            state = diagnostics.state()
            self.assertFalse(state["providerSetupCompleted"])
            self.assertIsNone(state["lastSuccessfulConnectionTest"])


if __name__ == "__main__":
    unittest.main()
