from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from .claude_settings import (
    CLAUDE_MODEL_OPTIONS,
    CLAUDE_REASONING_EFFORT_OPTIONS,
    DEFAULT_CLAUDE_MODEL,
    DEFAULT_CLAUDE_REASONING_EFFORT,
    normalize_claude_settings,
    valid_claude_model,
    valid_claude_reasoning_effort,
)
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
CLAUDE_CONNECTION_MARKER = "CLAUDE_CONNECTION_OK"


@dataclass(frozen=True)
class ProcessResult:
    exit_code: int
    stdout: str
    stderr: str
    duration_seconds: float


def _codex_connection_command(
    executable: str, model: str, effort: str, workdir: Path, output_file: Path
) -> tuple[list[str], bool]:
    """Codex writes its final message to --output-last-message; we read the file."""
    args = [
        executable,
        "exec",
        "--model",
        model,
        "-c",
        f'model_reasoning_effort="{effort}"',
        "--sandbox",
        "read-only",
        "--cd",
        str(workdir),
        "--skip-git-repo-check",
        "--ephemeral",
        "--ignore-rules",
        "--color",
        "never",
        "--output-last-message",
        str(output_file),
        "-",
    ]
    return args, False


def _claude_connection_command(
    executable: str, model: str, effort: str, workdir: Path, output_file: Path
) -> tuple[list[str], bool]:
    """Claude Code prints the final message to stdout in --print mode."""
    args = [executable, "--print", "--model", model]
    if effort:
        args += ["--effort", effort]
    args += ["--output-format", "text"]
    return args, True


@dataclass(frozen=True)
class ProviderDescriptor:
    provider_id: str
    display_name: str
    binary_name: str
    marker: str
    marker_exact: bool
    model_options: list[dict[str, str]]
    effort_options: list[dict[str, str]]
    default_model: str
    default_effort: str
    valid_model: Callable[[str | None], str]
    valid_effort: Callable[[str | None], str]
    normalize_settings: Callable[[dict[str, Any]], dict[str, Any]]
    build_connection_command: Callable[[str, str, str, Path, Path], tuple[list[str], bool]]
    homebrew_paths: tuple[str, ...]

    @property
    def path_key(self) -> str:
        return f"{self.provider_id}ExecutablePath"

    @property
    def version_key(self) -> str:
        return f"{self.provider_id}Version"

    @property
    def model_key(self) -> str:
        return f"{self.provider_id}Model"

    @property
    def effort_key(self) -> str:
        return f"{self.provider_id}ReasoningEffort"

    @property
    def connected_key(self) -> str:
        return f"{self.provider_id}ConnectedAt"


CODEX_DESCRIPTOR = ProviderDescriptor(
    provider_id="codex",
    display_name="Codex CLI",
    binary_name="codex",
    marker=CONNECTION_MARKER,
    marker_exact=True,
    model_options=CODEX_MODEL_OPTIONS,
    effort_options=CODEX_REASONING_EFFORT_OPTIONS,
    default_model=DEFAULT_CODEX_MODEL,
    default_effort=DEFAULT_CODEX_REASONING_EFFORT,
    valid_model=valid_codex_model,
    valid_effort=valid_codex_reasoning_effort,
    normalize_settings=normalize_codex_settings,
    build_connection_command=_codex_connection_command,
    homebrew_paths=(
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        str(Path.home() / ".local/bin/codex"),
    ),
)

CLAUDE_DESCRIPTOR = ProviderDescriptor(
    provider_id="claude",
    display_name="Claude Code CLI",
    binary_name="claude",
    marker=CLAUDE_CONNECTION_MARKER,
    marker_exact=False,
    model_options=CLAUDE_MODEL_OPTIONS,
    effort_options=CLAUDE_REASONING_EFFORT_OPTIONS,
    default_model=DEFAULT_CLAUDE_MODEL,
    default_effort=DEFAULT_CLAUDE_REASONING_EFFORT,
    valid_model=valid_claude_model,
    valid_effort=valid_claude_reasoning_effort,
    normalize_settings=normalize_claude_settings,
    build_connection_command=_claude_connection_command,
    homebrew_paths=(
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        str(Path.home() / ".local/bin/claude"),
        str(Path.home() / ".claude/local/claude"),
    ),
)

DESCRIPTORS: dict[str, ProviderDescriptor] = {
    CODEX_DESCRIPTOR.provider_id: CODEX_DESCRIPTOR,
    CLAUDE_DESCRIPTOR.provider_id: CLAUDE_DESCRIPTOR,
}

DEFAULT_PROVIDER_ID = CODEX_DESCRIPTOR.provider_id


class ProviderSetupStore:
    def __init__(self, config: AppConfig) -> None:
        self.config = config
        self.path = config.data_dir / "provider-setup.json"

    def load(self) -> dict[str, Any]:
        default_state: dict[str, Any] = {
            "selectedProviderID": DEFAULT_PROVIDER_ID,
            "codexExecutablePath": None,
            "codexVersion": None,
            "codexModel": self.config.codex_model or DEFAULT_CODEX_MODEL,
            "codexReasoningEffort": self.config.codex_reasoning_effort or DEFAULT_CODEX_REASONING_EFFORT,
            "codexConnectedAt": None,
            "claudeExecutablePath": None,
            "claudeVersion": None,
            "claudeModel": self.config.claude_model or DEFAULT_CLAUDE_MODEL,
            "claudeReasoningEffort": self.config.claude_reasoning_effort or DEFAULT_CLAUDE_REASONING_EFFORT,
            "claudeConnectedAt": None,
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
        state = normalize_claude_settings(state)
        if state.get("selectedProviderID") not in DESCRIPTORS:
            state["selectedProviderID"] = DEFAULT_PROVIDER_ID
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

    def select(self, provider_id: str) -> dict[str, Any]:
        provider_id = provider_id if provider_id in DESCRIPTORS else DEFAULT_PROVIDER_ID
        state = self.load()
        descriptor = DESCRIPTORS[provider_id]
        connected = state.get(descriptor.connected_key)
        state["selectedProviderID"] = provider_id
        state["providerSetupCompleted"] = bool(connected)
        state["lastSuccessfulConnectionTest"] = connected
        return self.save(state)


class CliProviderDiagnostics:
    """Detection, sign-in test, and settings for a CLI provider used via the user's subscription."""

    def __init__(self, config: AppConfig, descriptor: ProviderDescriptor) -> None:
        self.config = config
        self.descriptor = descriptor
        self.store = ProviderSetupStore(config)

    @property
    def provider_id(self) -> str:
        return self.descriptor.provider_id

    def state(self) -> dict[str, Any]:
        return self.store.load()

    def model_options(self) -> dict[str, Any]:
        return {
            "modelOptions": self.descriptor.model_options,
            "reasoningEffortOptions": self.descriptor.effort_options,
        }

    def save_model_settings(self, model: str | None, reasoning_effort: str | None) -> dict[str, Any]:
        state = self.store.update(
            **{
                self.descriptor.model_key: self.descriptor.valid_model(model),
                self.descriptor.effort_key: self.descriptor.valid_effort(reasoning_effort),
            }
        )
        return {
            "status": "saved",
            "provider": self.provider_id,
            "state": state,
            **self.model_options(),
        }

    def save_output_language(self, value: str | None) -> dict[str, Any]:
        state = self.store.update(outputLanguage=normalize_output_language(value))
        return {
            "status": "saved",
            "provider": self.provider_id,
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
                return self._installation_result(
                    "invalid", path, None, checked, f"{self.descriptor.display_name} was found, but it cannot be launched."
                )

            result = run_process([str(path), "--version"], cwd=tempfile.gettempdir(), timeout=15)
            if result.exit_code == 0:
                version = parse_cli_version(result.stdout, result.stderr)
                self.store.update(
                    **{
                        self.descriptor.path_key: str(path),
                        self.descriptor.version_key: version,
                    },
                    selectedProviderID=self.provider_id,
                )
                return self._installation_result("installed", path, version, checked, "Ready to check sign-in.")
            self._mark_setup_incomplete(clear_path=False)
            return self._installation_result(
                "failed",
                path,
                None,
                checked,
                f"{self.descriptor.display_name} is installed, but the app could not read its version.",
                process=result,
            )

        self._mark_setup_incomplete(clear_path=True)
        return {
            "status": "notInstalled",
            "provider": self.provider_id,
            "displayName": self.descriptor.display_name,
            "path": None,
            "version": None,
            "checkedPaths": checked,
            "userMessage": f"{self.descriptor.display_name} was not found.",
            "details": {
                "timestamp": utc_now(),
                "errorCategory": "installationMissing",
            },
        }

    def test_connection(self, executable_path: str | None = None) -> dict[str, Any]:
        state = self.store.load()
        path_value = executable_path or state.get(self.descriptor.path_key)
        if not path_value:
            detected = self.detect_installation()
            if detected["status"] != "installed":
                return {
                    "status": "installationMissing",
                    "provider": self.provider_id,
                    "userMessage": f"{self.descriptor.display_name} was not found.",
                    "details": detected.get("details", {}),
                }
            path_value = detected["path"]

        exe_path = Path(os.path.expanduser(str(path_value))).resolve()
        if not exe_path.exists() or not os.access(exe_path, os.X_OK):
            self._mark_setup_incomplete(clear_path=False)
            return {
                "status": "installationInvalid",
                "provider": self.provider_id,
                "userMessage": f"{self.descriptor.display_name} executable is missing or cannot be launched.",
                "details": {
                    "executablePath": str(exe_path),
                    "timestamp": utc_now(),
                    "errorCategory": "installationInvalid",
                },
            }

        with tempfile.TemporaryDirectory(prefix=f"tubefold-{self.provider_id}-test-") as tmp:
            tmp_path = Path(tmp)
            output_file = tmp_path / "last-message.txt"
            model = self.descriptor.valid_model(str(state.get(self.descriptor.model_key) or self._config_model()))
            effort = self.descriptor.valid_effort(
                str(state.get(self.descriptor.effort_key) or self._config_effort())
            )
            args, reads_stdout = self.descriptor.build_connection_command(
                str(exe_path), model, effort, tmp_path, output_file
            )
            prompt = f"Reply with exactly: {self.descriptor.marker}\n"
            result = run_process(args, cwd=tmp_path, timeout=90, stdin=prompt)
            if reads_stdout:
                output_text = result.stdout.strip()
            else:
                output_text = output_file.read_text(encoding="utf-8", errors="replace").strip() if output_file.exists() else ""

        category = classify_result(result, output_text, self.descriptor)
        details = {
            "executablePath": str(exe_path),
            "model": model,
            "reasoningEffort": effort,
            "exitCode": result.exit_code,
            "errorCategory": category,
            "stderrExcerpt": excerpt(result.stderr),
            "stdoutExcerpt": excerpt(result.stdout),
            "durationSeconds": round(result.duration_seconds, 2),
            "timestamp": utc_now(),
        }

        if category == "success":
            now = utc_now()
            self.store.update(
                selectedProviderID=self.provider_id,
                providerSetupCompleted=True,
                lastSuccessfulConnectionTest=now,
                **{
                    self.descriptor.path_key: str(exe_path),
                    self.descriptor.connected_key: now,
                },
            )
            return {
                "status": "success",
                "provider": self.provider_id,
                "userMessage": f"{self.descriptor.display_name} is connected and ready.",
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
            "provider": self.provider_id,
            "userMessage": user_message_for_category(category, self.descriptor),
            "details": details,
        }

    def _mark_setup_incomplete(self, clear_path: bool) -> None:
        changes: dict[str, Any] = {
            "providerSetupCompleted": False,
            "lastSuccessfulConnectionTest": None,
            self.descriptor.connected_key: None,
        }
        if clear_path:
            changes[self.descriptor.path_key] = None
            changes[self.descriptor.version_key] = None
        self.store.update(**changes)

    def complete_setup(self) -> dict[str, Any]:
        state = self.store.update(providerSetupCompleted=True, selectedProviderID=self.provider_id)
        return {
            "status": "completed",
            "provider": self.provider_id,
            "state": state,
        }

    def _config_model(self) -> str:
        if self.provider_id == "claude":
            return self.config.claude_model
        return self.config.codex_model

    def _config_effort(self) -> str:
        if self.provider_id == "claude":
            return self.config.claude_reasoning_effort
        return self.config.codex_reasoning_effort

    def _candidate_paths(self, requested_path: str | None) -> list[str]:
        state = self.store.load()
        candidates: list[str] = []
        if requested_path:
            candidates.append(requested_path)
        if state.get(self.descriptor.path_key):
            candidates.append(str(state[self.descriptor.path_key]))
        shell_path = detect_via_login_shell(self.descriptor.binary_name)
        if shell_path:
            candidates.append(shell_path)
        candidates.extend(self.descriptor.homebrew_paths)
        deduped: list[str] = []
        seen: set[str] = set()
        for candidate in candidates:
            expanded = str(Path(os.path.expanduser(candidate)).resolve())
            if expanded not in seen:
                deduped.append(expanded)
                seen.add(expanded)
        return deduped

    def _installation_result(
        self,
        status: str,
        path: Path,
        version: str | None,
        checked: list[str],
        message: str,
        process: ProcessResult | None = None,
    ) -> dict[str, Any]:
        return {
            "status": status,
            "provider": self.provider_id,
            "displayName": self.descriptor.display_name,
            "path": str(path),
            "version": version,
            "checkedPaths": checked,
            "userMessage": message,
            "details": {
                "executablePath": str(path),
                "version": version,
                "exitCode": process.exit_code if process else 0,
                "stderrExcerpt": excerpt(process.stderr) if process else "",
                "stdoutExcerpt": excerpt(process.stdout) if process else "",
                "timestamp": utc_now(),
                "errorCategory": "none" if status == "installed" else "installationInvalid",
            },
        }


class CodexProviderDiagnostics(CliProviderDiagnostics):
    def __init__(self, config: AppConfig) -> None:
        super().__init__(config, CODEX_DESCRIPTOR)


class ClaudeProviderDiagnostics(CliProviderDiagnostics):
    def __init__(self, config: AppConfig) -> None:
        super().__init__(config, CLAUDE_DESCRIPTOR)


def diagnostics_for(provider_id: str | None, config: AppConfig) -> CliProviderDiagnostics:
    descriptor = DESCRIPTORS.get(provider_id or "", CODEX_DESCRIPTOR)
    return CliProviderDiagnostics(config, descriptor)


def selected_diagnostics(config: AppConfig) -> CliProviderDiagnostics:
    state = ProviderSetupStore(config).load()
    return diagnostics_for(state.get("selectedProviderID"), config)


def provider_summaries(config: AppConfig) -> list[dict[str, Any]]:
    state = ProviderSetupStore(config).load()
    summaries: list[dict[str, Any]] = []
    for descriptor in DESCRIPTORS.values():
        summaries.append(
            {
                "id": descriptor.provider_id,
                "displayName": descriptor.display_name,
                "configured": bool(state.get(descriptor.connected_key)),
                "executablePath": state.get(descriptor.path_key),
                "version": state.get(descriptor.version_key),
            }
        )
    return summaries


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


def detect_via_login_shell(binary_name: str) -> str | None:
    shell = os.environ.get("SHELL", "/bin/zsh")
    try:
        result = subprocess.run(
            [shell, "-lc", f"command -v {binary_name}"],
            text=True,
            capture_output=True,
            timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip().splitlines()[0]
    except (OSError, subprocess.TimeoutExpired):
        pass
    return shutil.which(binary_name)


def parse_cli_version(stdout: str, stderr: str) -> str:
    text = (stdout or stderr).strip()
    return text.splitlines()[0] if text else "unknown"


def classify_result(result: ProcessResult, output_text: str, descriptor: ProviderDescriptor) -> str:
    combined = f"{result.stdout}\n{result.stderr}\n{output_text}".casefold()
    marker_ok = output_text.strip() == descriptor.marker if descriptor.marker_exact else descriptor.marker in output_text
    if result.exit_code == 0 and marker_ok:
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


def user_message_for_category(category: str, descriptor: ProviderDescriptor) -> str:
    name = descriptor.display_name
    return {
        "authenticationRequired": f"{name} is installed, but you are not signed in.",
        "usageLimitReached": f"{name} is connected, but your current usage limit has been reached.",
        "networkUnavailable": f"Could not reach {name} services.",
        "timeout": f"{name} did not respond in time.",
        "invalidOutput": f"{name} responded, but the connection test could not be verified.",
        "processFailed": f"{name} process failed.",
    }.get(category, f"{name} connection test failed.")


def excerpt(text: str, max_chars: int = 1200) -> str:
    clean = (text or "").strip()
    if len(clean) <= max_chars:
        return clean
    return clean[:max_chars].rstrip() + "..."
