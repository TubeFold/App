from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def _write_executable(path: Path, body: str) -> None:
    path.write_text("#!/usr/bin/env python3\n" + body, encoding="utf-8")
    path.chmod(0o755)


def _run_wrapper(script: str, fake_name: str, fake_body: str) -> tuple[int, Path]:
    """Run a provider wrapper with a fake CLI on PATH; return (rc, output_file)."""
    directory = Path(tempfile.mkdtemp())
    fake = directory / fake_name
    _write_executable(fake, fake_body)
    prompt = directory / "prompt.md"
    prompt.write_text("summarize this", encoding="utf-8")
    output = directory / "provider-output.md"
    workdir = directory / "work"
    env = dict(os.environ)
    env["PATH"] = f"{directory}{os.pathsep}{env['PATH']}"
    completed = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / script), str(prompt), str(output), str(workdir)],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return completed.returncode, output


class ClaudeWrapperTests(unittest.TestCase):
    def test_writes_body_and_usage_sidecar(self) -> None:
        rc, output = _run_wrapper(
            "run-claude-provider.py",
            "claude",
            "import sys, json\n"
            "sys.stdin.read()\n"
            "print(json.dumps({'type':'result','is_error':False,'result':'# Body\\n',"
            "'total_cost_usd':0.02,'usage':{'input_tokens':5,'output_tokens':10,"
            "'cache_read_input_tokens':3,'cache_creation_input_tokens':1}}))\n",
        )
        self.assertEqual(rc, 0)
        self.assertEqual(output.read_text(encoding="utf-8"), "# Body\n")
        sidecar = json.loads(Path(str(output) + ".usage.json").read_text(encoding="utf-8"))
        self.assertEqual(sidecar["provider"], "claude")
        self.assertEqual(sidecar["total_tokens"], 15)
        self.assertAlmostEqual(sidecar["cost_usd"], 0.02)

    def test_non_json_output_still_writes_body_without_sidecar(self) -> None:
        rc, output = _run_wrapper(
            "run-claude-provider.py",
            "claude",
            "import sys\nsys.stdin.read()\nsys.stdout.write('# Plain body\\n')\n",
        )
        self.assertEqual(rc, 0)
        self.assertEqual(output.read_text(encoding="utf-8"), "# Plain body\n")
        self.assertFalse(Path(str(output) + ".usage.json").exists())


class CodexWrapperTests(unittest.TestCase):
    def test_writes_body_and_usage_sidecar(self) -> None:
        rc, output = _run_wrapper(
            "run-codex-provider.py",
            "codex",
            "import sys, json\n"
            "args = sys.argv\n"
            "out = args[args.index('--output-last-message') + 1]\n"
            "sys.stdin.read()\n"
            "open(out, 'w').write('# Codex body\\n')\n"
            "print(json.dumps({'type':'event_msg','payload':{'type':'token_count',"
            "'info':{'total_token_usage':{'input_tokens':7,'output_tokens':3,"
            "'reasoning_output_tokens':1,'total_tokens':11}},"
            "'rate_limits':{'primary':{'used_percent':30.0},"
            "'secondary':{'used_percent':55.0,'resets_at':123},'plan_type':'plus'}}}))\n",
        )
        self.assertEqual(rc, 0)
        self.assertEqual(output.read_text(encoding="utf-8"), "# Codex body\n")
        sidecar = json.loads(Path(str(output) + ".usage.json").read_text(encoding="utf-8"))
        self.assertEqual(sidecar["provider"], "codex")
        self.assertEqual(sidecar["total_tokens"], 11)
        self.assertEqual(sidecar["weekly_percent"], 55.0)


if __name__ == "__main__":
    unittest.main()
