#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
from pathlib import Path

from usage_sidecar import claude_usage_from_result, write_usage_sidecar


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Claude Code CLI provider with timeout")
    parser.add_argument("prompt_file", type=Path)
    parser.add_argument("output_file", type=Path)
    parser.add_argument("workdir", type=Path)
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()

    claude = shutil.which("claude")
    if claude is None:
        print("[ERROR] Missing dependency: claude", file=sys.stderr)
        return 127

    prompt = args.prompt_file.read_text(encoding="utf-8")
    args.output_file.parent.mkdir(parents=True, exist_ok=True)
    args.workdir.mkdir(parents=True, exist_ok=True)

    model = os.environ.get("CLAUDE_MODEL", "").strip()
    effort = os.environ.get("CLAUDE_REASONING_EFFORT", "").strip()
    command = [claude, "--print"]
    if model:
        command.extend(["--model", model])
    if effort:
        command.extend(["--effort", effort])
    command.extend(["--output-format", "json"])

    # Run from an isolated temp dir so the CLI never discovers the repo's CLAUDE.md
    # or other project context; the prompt is the only input, read from stdin.
    process = subprocess.Popen(
        command,
        cwd=str(args.workdir),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(prompt, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            stdout, stderr = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = process.communicate()
        print(f"[ERROR] Claude timed out after {args.timeout} seconds", file=sys.stderr)
        return 124

    if process.returncode != 0:
        detail = classify_failure(stdout + "\n" + stderr)
        print(f"[ERROR] Claude exited with status {process.returncode}: {detail}", file=sys.stderr)
        if stderr.strip():
            print(stderr.strip(), file=sys.stderr)
        return process.returncode or 1

    body, usage = parse_response(stdout)
    args.output_file.write_text(body, encoding="utf-8")
    if not args.output_file.read_text(encoding="utf-8", errors="replace").strip():
        print("[ERROR] Claude produced no output", file=sys.stderr)
        if stderr.strip():
            print(stderr.strip(), file=sys.stderr)
        return 1
    if usage is not None:
        try:
            write_usage_sidecar(args.output_file, usage)
        except OSError:
            pass  # usage capture is best-effort, never fatal
    return 0


def parse_response(stdout: str) -> tuple[str, dict | None]:
    """Pull the Markdown body and token usage out of the JSON result object.

    Falls back to treating stdout as the raw body (and skipping usage) if it is
    not the expected ``--output-format json`` object, so a CLI format change can
    never break summary generation.
    """
    try:
        result_obj = json.loads(stdout)
    except ValueError:
        return stdout, None
    if not isinstance(result_obj, dict) or "result" not in result_obj:
        return stdout, None
    body = result_obj.get("result")
    if not isinstance(body, str):
        return stdout, None
    return body, claude_usage_from_result(result_obj)


def classify_failure(output: str) -> str:
    text = output.casefold()
    if "not logged in" in text or "auth" in text or "login" in text:
        return "authorization/login problem"
    if "rate limit" in text or "usage limit" in text or "quota" in text or "limit" in text:
        return "rate limit or quota problem"
    if "network" in text or "connection" in text or "timed out" in text:
        return "network problem"
    return "see Claude stderr"


if __name__ == "__main__":
    raise SystemExit(main())
