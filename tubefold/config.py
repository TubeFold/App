from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from .claude_settings import DEFAULT_CLAUDE_MODEL, DEFAULT_CLAUDE_REASONING_EFFORT
from .codex_settings import DEFAULT_CODEX_MODEL, DEFAULT_CODEX_REASONING_EFFORT
from .output_language import DEFAULT_OUTPUT_LANGUAGE, normalize_output_language


PROJECT_ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class AppConfig:
    host: str
    port: int
    api_token: str | None
    allowed_origins: tuple[str, ...]
    provider: str
    python_executable: str
    codex_timeout_seconds: int
    data_dir: Path
    output_dir: Path
    codex_model: str = DEFAULT_CODEX_MODEL
    codex_reasoning_effort: str = DEFAULT_CODEX_REASONING_EFFORT
    claude_model: str = DEFAULT_CLAUDE_MODEL
    claude_reasoning_effort: str = DEFAULT_CLAUDE_REASONING_EFFORT
    output_language: str = DEFAULT_OUTPUT_LANGUAGE
    max_request_bytes: int = 1024 * 64

    @property
    def database_path(self) -> Path:
        return self.data_dir / "database.sqlite"

    @property
    def videos_dir(self) -> Path:
        return self.data_dir / "videos"

    @property
    def jobs_dir(self) -> Path:
        return self.data_dir / "jobs"

    @property
    def logs_dir(self) -> Path:
        return self.data_dir / "logs"


def default_data_dir() -> Path:
    return Path.home() / "Library" / "Application Support" / "TubeFold"


def load_config() -> AppConfig:
    data_dir = Path(os.path.expandvars(os.path.expanduser(os.environ.get("TUBEFOLD_DATA_DIR", str(default_data_dir())))))
    provider = os.environ.get("TUBEFOLD_PROVIDER", os.environ.get("PROVIDER", "codex"))
    token = os.environ.get("TUBEFOLD_API_TOKEN")
    allowed_origins = tuple(
        origin.strip()
        for origin in os.environ.get("TUBEFOLD_ALLOWED_ORIGINS", "chrome-extension://*,null").split(",")
        if origin.strip()
    )
    output_dir = Path(
        os.path.expandvars(
            os.path.expanduser(os.environ.get("TUBEFOLD_OUTPUT_DIR", str(data_dir / "exports")))
        )
    )
    return AppConfig(
        host="127.0.0.1",
        port=int(os.environ.get("TUBEFOLD_PORT", "43821")),
        api_token=token,
        allowed_origins=allowed_origins,
        provider=provider,
        python_executable=os.environ.get("TUBEFOLD_PYTHON", str(PROJECT_ROOT / ".venv" / "bin" / "python")),
        codex_timeout_seconds=int(os.environ.get("CODEX_TIMEOUT_SECONDS", "900")),
        data_dir=data_dir.resolve(),
        output_dir=output_dir.resolve(),
        codex_model=os.environ.get("TUBEFOLD_CODEX_MODEL", os.environ.get("CODEX_MODEL", DEFAULT_CODEX_MODEL)),
        codex_reasoning_effort=os.environ.get(
            "TUBEFOLD_CODEX_REASONING_EFFORT",
            os.environ.get("CODEX_REASONING_EFFORT", DEFAULT_CODEX_REASONING_EFFORT),
        ),
        claude_model=os.environ.get("TUBEFOLD_CLAUDE_MODEL", os.environ.get("CLAUDE_MODEL", DEFAULT_CLAUDE_MODEL)),
        claude_reasoning_effort=os.environ.get(
            "TUBEFOLD_CLAUDE_REASONING_EFFORT",
            os.environ.get("CLAUDE_REASONING_EFFORT", DEFAULT_CLAUDE_REASONING_EFFORT),
        ),
        output_language=normalize_output_language(os.environ.get("TUBEFOLD_OUTPUT_LANGUAGE")),
    )
