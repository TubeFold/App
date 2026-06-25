#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
from pathlib import Path


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

    command = [
        codex,
        "exec",
        "--sandbox",
        "read-only",
        "--cd",
        str(args.workdir),
        "--skip-git-repo-check",
        "--ephemeral",
        "--ignore-rules",
        "--color",
        "never",
        "--output-last-message",
        str(args.output_file),
        "-",
    ]

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
        detail = classify_failure(stdout + "\n" + stderr)
        print(f"[ERROR] Codex exited with status {process.returncode}: {detail}", file=os.sys.stderr)
        if stderr.strip():
            print(stderr.strip(), file=os.sys.stderr)
        return process.returncode or 1

    if not args.output_file.exists():
        print("[ERROR] Codex did not create output file", file=os.sys.stderr)
        return 1
    if not args.output_file.read_text(encoding="utf-8", errors="replace").strip():
        print("[ERROR] Codex output file is empty", file=os.sys.stderr)
        return 1
    return 0


def classify_failure(output: str) -> str:
    text = output.casefold()
    if "auth" in text or "login" in text or "not logged in" in text:
        return "authorization/login problem"
    if "rate limit" in text or "quota" in text or "limit" in text:
        return "rate limit or quota problem"
    if "network" in text or "connection" in text or "timed out" in text:
        return "network problem"
    return "see Codex stderr"


if __name__ == "__main__":
    raise SystemExit(main())
