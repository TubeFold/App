from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .codex_settings import (
    CODEX_MODEL_OPTIONS,
    CODEX_REASONING_EFFORT_OPTIONS,
    DEFAULT_CODEX_MODEL,
    DEFAULT_CODEX_REASONING_EFFORT,
    normalize_codex_settings,
    valid_codex_model,
    valid_codex_reasoning_effort,
)
from .config import AppConfig
from .output_language import DEFAULT_OUTPUT_LANGUAGE, normalize_output_language
from .repository import utc_now


CONNECTION_MARKER = "CODEX_CONNECTION_OK"


@dataclass(frozen=True)
class ProcessResult:
    exit_code: int
    stdout: str
    stderr: str
    duration_seconds: float


class ProviderSetupStore:
    def __init__(self, config: AppConfig) -> None:
        self.config = config
        self.path = config.data_dir / "provider-setup.json"

    def load(self) -> dict[str, Any]:
        default_state = {
            "selectedProviderID": "codex",
            "codexExecutablePath": None,
            "codexVersion": None,
            "codexModel": self.config.codex_model or DEFAULT_CODEX_MODEL,
            "codexReasoningEffort": self.config.codex_reasoning_effort or DEFAULT_CODEX_REASONING_EFFORT,
            "outputLanguage": self.config.output_language or DEFAULT_OUTPUT_LANGUAGE,
            "providerSetupCompleted": False,
            "lastSuccessfulConnectionTest": None,
            "preferredOutputDirectory": str(self.config.output_dir),
        }
        if self.path.exists():
            stored = json.loads(self.path.read_text(encoding="utf-8"))
            default_state.update(stored)
        return self._normalize(default_state)

    @staticmethod
    def _normalize(state: dict[str, Any]) -> dict[str, Any]:
        state = normalize_codex_settings(state)
        state["outputLanguage"] = normalize_output_language(state.get("outputLanguage"))
        return state

    def save(self, state: dict[str, Any]) -> dict[str, Any]:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return state

    def update(self, **changes: Any) -> dict[str, Any]:
        state = self.load()
        state.update(changes)
        return self.save(state)


class CodexProviderDiagnostics:
    def __init__(self, config: AppConfig) -> None:
        self.config = config
        self.store = ProviderSetupStore(config)

    def state(self) -> dict[str, Any]:
        return self.store.load()

    def model_options(self) -> dict[str, Any]:
        return {
            "modelOptions": CODEX_MODEL_OPTIONS,
            "reasoningEffortOptions": CODEX_REASONING_EFFORT_OPTIONS,
        }

    def save_model_settings(self, model: str | None, reasoning_effort: str | None) -> dict[str, Any]:
        state = self.store.update(
            codexModel=valid_codex_model(model),
            codexReasoningEffort=valid_codex_reasoning_effort(reasoning_effort),
        )
        return {
            "status": "saved",
            "provider": "codex",
            "state": state,
            **self.model_options(),
        }

    def save_output_language(self, value: str | None) -> dict[str, Any]:
        state = self.store.update(outputLanguage=normalize_output_language(value))
        return {
            "status": "saved",
            "provider": "codex",
            "state": state,
            **self.model_options(),
        }

    def detect_installation(self, requested_path: str | None = None) -> dict[str, Any]:
        candidates = self._candidate_paths(requested_path)
        checked: list[str] = []
        for candidate in candidates:
            if not candidate:
                continue
            path = Path(os.path.expanduser(candidate)).resolve()
            checked.append(str(path))
            if not path.exists():
                continue
            if not os.access(path, os.X_OK):
                self._mark_setup_incomplete(clear_path=False)
                return self._installation_result("invalid", path, None, checked, "Codex was found, but it cannot be launched.")

            result = run_process([str(path), "--version"], cwd=tempfile.gettempdir(), timeout=15)
            if result.exit_code == 0:
                version = parse_codex_version(result.stdout, result.stderr)
                self.store.update(codexExecutablePath=str(path), codexVersion=version, selectedProviderID="codex")
                return self._installation_result("installed", path, version, checked, "Ready to check sign-in.")
            self._mark_setup_incomplete(clear_path=False)
            return self._installation_result(
                "failed",
                path,
                None,
                checked,
                "Codex is installed, but the app could not read its version.",
                process=result,
            )

        self._mark_setup_incomplete(clear_path=True)
        return {
            "status": "notInstalled",
            "provider": "codex",
            "displayName": "Codex CLI",
            "path": None,
            "version": None,
            "checkedPaths": checked,
            "userMessage": "Codex CLI was not found.",
            "details": {
                "timestamp": utc_now(),
                "errorCategory": "installationMissing",
            },
        }

    def test_connection(self, executable_path: str | None = None) -> dict[str, Any]:
        state = self.store.load()
        path_value = executable_path or state.get("codexExecutablePath")
        if not path_value:
            detected = self.detect_installation()
            if detected["status"] != "installed":
                return {
                    "status": "installationMissing",
                    "provider": "codex",
                    "userMessage": "Codex CLI was not found.",
                    "details": detected.get("details", {}),
                }
            path_value = detected["path"]

        codex_path = Path(os.path.expanduser(str(path_value))).resolve()
        if not codex_path.exists() or not os.access(codex_path, os.X_OK):
            self._mark_setup_incomplete(clear_path=False)
            return {
                "status": "installationInvalid",
                "provider": "codex",
                "userMessage": "Codex executable is missing or cannot be launched.",
                "details": {"codexPath": str(codex_path), "timestamp": utc_now(), "errorCategory": "installationInvalid"},
            }

        with tempfile.TemporaryDirectory(prefix="youtube-brain-codex-test-") as tmp:
            tmp_path = Path(tmp)
            output_file = tmp_path / "last-message.txt"
            model = valid_codex_model(str(state.get("codexModel") or self.config.codex_model))
            reasoning_effort = valid_codex_reasoning_effort(
                str(state.get("codexReasoningEffort") or self.config.codex_reasoning_effort)
            )
            args = [
                str(codex_path),
                "exec",
                "--model",
                model,
                "-c",
                f'model_reasoning_effort="{reasoning_effort}"',
                "--sandbox",
                "read-only",
                "--cd",
                str(tmp_path),
                "--skip-git-repo-check",
                "--ephemeral",
                "--ignore-rules",
                "--color",
                "never",
                "--output-last-message",
                str(output_file),
                "-",
            ]
            prompt = f"Reply with exactly: {CONNECTION_MARKER}\n"
            result = run_process(args, cwd=tmp_path, timeout=90, stdin=prompt)
            output_text = output_file.read_text(encoding="utf-8", errors="replace").strip() if output_file.exists() else ""

        category = classify_codex_result(result, output_text)
        details = {
            "codexPath": str(codex_path),
            "codexModel": model,
            "codexReasoningEffort": reasoning_effort,
            "exitCode": result.exit_code,
            "errorCategory": category,
            "stderrExcerpt": excerpt(result.stderr),
            "stdoutExcerpt": excerpt(result.stdout),
            "durationSeconds": round(result.duration_seconds, 2),
            "timestamp": utc_now(),
        }

        if category == "success":
            self.store.update(
                selectedProviderID="codex",
                codexExecutablePath=str(codex_path),
                providerSetupCompleted=True,
                lastSuccessfulConnectionTest=utc_now(),
            )
            return {
                "status": "success",
                "provider": "codex",
                "userMessage": "Codex is connected and ready.",
                "details": details,
            }

        self._mark_setup_incomplete(clear_path=False)
        status_map = {
            "authenticationRequired": "authenticationRequired",
            "usageLimitReached": "usageLimitReached",
            "networkUnavailable": "networkError",
            "timeout": "timeout",
            "invalidOutput": "invalidResponse",
        }
        return {
            "status": status_map.get(category, "processFailed"),
            "provider": "codex",
            "userMessage": user_message_for_category(category),
            "details": details,
        }

    def _mark_setup_incomplete(self, clear_path: bool) -> None:
        changes: dict[str, Any] = {
            "providerSetupCompleted": False,
            "lastSuccessfulConnectionTest": None,
        }
        if clear_path:
            changes["codexExecutablePath"] = None
            changes["codexVersion"] = None
        self.store.update(**changes)

    def complete_setup(self) -> dict[str, Any]:
        state = self.store.update(providerSetupCompleted=True, selectedProviderID="codex")
        return {
            "status": "completed",
            "provider": "codex",
            "state": state,
        }

    def _candidate_paths(self, requested_path: str | None) -> list[str]:
        state = self.store.load()
        candidates: list[str] = []
        if requested_path:
            candidates.append(requested_path)
        if state.get("codexExecutablePath"):
            candidates.append(str(state["codexExecutablePath"]))
        shell_path = detect_via_login_shell()
        if shell_path:
            candidates.append(shell_path)
        candidates.extend(
            [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                str(Path.home() / ".local/bin/codex"),
            ]
        )
        deduped: list[str] = []
        seen: set[str] = set()
        for candidate in candidates:
            expanded = str(Path(os.path.expanduser(candidate)).resolve())
            if expanded not in seen:
                deduped.append(expanded)
                seen.add(expanded)
        return deduped

    @staticmethod
    def _installation_result(
        status: str,
        path: Path,
        version: str | None,
        checked: list[str],
        message: str,
        process: ProcessResult | None = None,
    ) -> dict[str, Any]:
        return {
            "status": status,
            "provider": "codex",
            "displayName": "Codex CLI",
            "path": str(path),
            "version": version,
            "checkedPaths": checked,
            "userMessage": message,
            "details": {
                "codexPath": str(path),
                "codexVersion": version,
                "exitCode": process.exit_code if process else 0,
                "stderrExcerpt": excerpt(process.stderr) if process else "",
                "stdoutExcerpt": excerpt(process.stdout) if process else "",
                "timestamp": utc_now(),
                "errorCategory": "none" if status == "installed" else "installationInvalid",
            },
        }


def run_process(
    args: list[str],
    cwd: str | Path,
    timeout: int,
    stdin: str | None = None,
) -> ProcessResult:
    started = time.monotonic()
    try:
        completed = subprocess.run(
            args,
            cwd=cwd,
            input=stdin,
            text=True,
            capture_output=True,
            timeout=timeout,
            env=controlled_environment(),
        )
        return ProcessResult(
            exit_code=completed.returncode,
            stdout=completed.stdout or "",
            stderr=completed.stderr or "",
            duration_seconds=time.monotonic() - started,
        )
    except subprocess.TimeoutExpired as error:
        return ProcessResult(
            exit_code=124,
            stdout=error.stdout or "",
            stderr=error.stderr or "",
            duration_seconds=time.monotonic() - started,
        )
    except PermissionError as error:
        return ProcessResult(exit_code=126, stdout="", stderr=str(error), duration_seconds=time.monotonic() - started)
    except OSError as error:
        return ProcessResult(exit_code=127, stdout="", stderr=str(error), duration_seconds=time.monotonic() - started)


def controlled_environment() -> dict[str, str]:
    env = os.environ.copy()
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    return env


def detect_via_login_shell() -> str | None:
    shell = os.environ.get("SHELL", "/bin/zsh")
    try:
        result = subprocess.run(
            [shell, "-lc", "command -v codex"],
            text=True,
            capture_output=True,
            timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip().splitlines()[0]
    except (OSError, subprocess.TimeoutExpired):
        pass
    return shutil.which("codex")


def parse_codex_version(stdout: str, stderr: str) -> str:
    text = (stdout or stderr).strip()
    return text.splitlines()[0] if text else "unknown"


def classify_codex_result(result: ProcessResult, output_text: str) -> str:
    combined = f"{result.stdout}\n{result.stderr}\n{output_text}".casefold()
    if result.exit_code == 0 and output_text.strip() == CONNECTION_MARKER:
        return "success"
    if result.exit_code == 124:
        return "timeout"
    if "not logged in" in combined or "login" in combined or "auth" in combined:
        return "authenticationRequired"
    if "rate limit" in combined or "usage limit" in combined or "quota" in combined:
        return "usageLimitReached"
    if "network" in combined or "connection" in combined or "could not resolve" in combined or "timed out" in combined:
        return "networkUnavailable"
    if result.exit_code != 0:
        return "processFailed"
    return "invalidOutput"


def user_message_for_category(category: str) -> str:
    return {
        "authenticationRequired": "Codex is installed, but you are not signed in.",
        "usageLimitReached": "Codex is connected, but your current usage limit has been reached.",
        "networkUnavailable": "Could not reach Codex services.",
        "timeout": "Codex did not respond in time.",
        "invalidOutput": "Codex responded, but the connection test could not be verified.",
        "processFailed": "Codex process failed.",
    }.get(category, "Codex connection test failed.")


def excerpt(text: str, max_chars: int = 1200) -> str:
    clean = (text or "").strip()
    if len(clean) <= max_chars:
        return clean
    return clean[:max_chars].rstrip() + "..."
