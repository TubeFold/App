#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
from pathlib import Path

from usage_sidecar import codex_usage_from_jsonl, write_usage_sidecar


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Codex CLI provider with timeout")
    parser.add_argument("prompt_file", type=Path)
    parser.add_argument("output_file", type=Path)
    parser.add_argument("workdir", type=Path)
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()

    codex = shutil.which("codex")
    if codex is None:
        print("[ERROR] Missing dependency: codex", file=os.sys.stderr)
        return 127

    prompt = args.prompt_file.read_text(encoding="utf-8")
    args.output_file.parent.mkdir(parents=True, exist_ok=True)
    args.workdir.mkdir(parents=True, exist_ok=True)

    codex_model = os.environ.get("CODEX_MODEL", "").strip()
    reasoning_effort = os.environ.get("CODEX_REASONING_EFFORT", "").strip()
    command = [
        codex,
        "exec",
    ]
    if codex_model:
        command.extend(["--model", codex_model])
    if reasoning_effort:
        command.extend(["-c", f'model_reasoning_effort="{reasoning_effort}"'])
    command.extend(
        [
        "--sandbox",
        "read-only",
        "--cd",
        str(args.workdir),
        "--skip-git-repo-check",
        "--ephemeral",
        "--ignore-rules",
        "--color",
        "never",
        "--json",
        "--output-last-message",
        str(args.output_file),
        "-",
        ]
    )

    process = subprocess.Popen(
        command,
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
        print(f"[ERROR] Codex timed out after {args.timeout} seconds", file=os.sys.stderr)
        return 124

    if process.returncode != 0:
        # Codex reports the real failure (e.g. an API 400) as an "error"/"turn.failed"
        # event on the --json stdout stream, NOT on stderr — surface it so the cause
        # isn't lost behind a generic message.
        stream_error = error_from_json_stream(stdout)
        detail = classify_failure(stream_error or (stdout + "\n" + stderr))
        print(f"[ERROR] Codex exited with status {process.returncode}: {detail}", file=os.sys.stderr)
        if stream_error:
            print(stream_error, file=os.sys.stderr)
        if stderr.strip():
            print(stderr.strip(), file=os.sys.stderr)
        return process.returncode or 1

    if not args.output_file.exists():
        print("[ERROR] Codex did not create output file", file=os.sys.stderr)
        return 1
    if not args.output_file.read_text(encoding="utf-8", errors="replace").strip():
        print("[ERROR] Codex output file is empty", file=os.sys.stderr)
        return 1
    usage = codex_usage_from_jsonl(stdout)
    if usage is not None:
        try:
            write_usage_sidecar(args.output_file, usage)
        except OSError:
            pass  # usage capture is best-effort, never fatal
    return 0


def error_from_json_stream(stdout: str) -> str:
    """Pull the human-readable message out of Codex's --json error events.

    Codex streams JSONL to stdout; on failure it emits an "error" and/or
    "turn.failed" event whose message holds the real cause (often a nested JSON
    API error). Returns the last such message found, or "" if none."""
    found = ""
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
        if event.get("type") not in ("error", "turn.failed"):
            continue
        message = event.get("message")
        if message is None and isinstance(event.get("error"), dict):
            message = event["error"].get("message")
        if isinstance(message, str) and message.strip():
            found = message.strip()
    return found


def classify_failure(output: str) -> str:
    text = output.casefold()
    if "auth" in text or "login" in text or "not logged in" in text:
        return "authorization/login problem"
    if "rate limit" in text or "quota" in text or "limit" in text:
        return "rate limit or quota problem"
    if "network" in text or "connection" in text or "timed out" in text:
        return "network problem"
    if "invalid_request_error" in text or "cannot be used with reasoning" in text:
        return "invalid request (model/reasoning-effort/tools combination)"
    return "see Codex output below"


if __name__ == "__main__":
    raise SystemExit(main())
