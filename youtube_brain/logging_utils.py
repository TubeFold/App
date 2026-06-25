from __future__ import annotations

import logging
import sys
from pathlib import Path

from .config import AppConfig


def configure_logging(config: AppConfig) -> None:
    config.logs_dir.mkdir(parents=True, exist_ok=True)
    root = logging.getLogger()
    if getattr(root, "_youtube_brain_configured", False):
        return

    root.setLevel(logging.INFO)
    formatter = logging.Formatter("%(asctime)s %(levelname)s [%(name)s] %(message)s")

    stream = logging.StreamHandler(sys.stderr)
    stream.setFormatter(formatter)
    root.addHandler(stream)

    file_handler = logging.FileHandler(config.logs_dir / "app.log", encoding="utf-8")
    file_handler.setFormatter(formatter)
    root.addHandler(file_handler)

    setattr(root, "_youtube_brain_configured", True)


def append_job_log(job_dir: Path, message: str) -> None:
    from .repository import utc_now

    job_dir.mkdir(parents=True, exist_ok=True)
    with (job_dir / "job.log").open("a", encoding="utf-8") as handle:
        handle.write(f"{utc_now()} {message}\n")
