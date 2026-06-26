from __future__ import annotations

import json
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .models import ACTIVE_STATUSES, ProcessingStatus, SummaryRequest


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class Repository:
    def __init__(self, database_path: Path) -> None:
        self.database_path = database_path
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.database_path, timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        return conn

    def _init_db(self) -> None:
        with self.connect() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS videos (
                    id TEXT PRIMARY KEY,
                    youtube_video_id TEXT NOT NULL UNIQUE,
                    canonical_url TEXT NOT NULL,
                    title TEXT,
                    channel_name TEXT,
                    thumbnail_url TEXT,
                    duration_seconds REAL,
                    current_time_at_request REAL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    status TEXT NOT NULL,
                    transcript_path TEXT,
                    summary_path TEXT,
                    summary_markdown TEXT,
                    error_code TEXT,
                    error_message TEXT
                );

                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY,
                    video_id TEXT NOT NULL,
                    status TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    started_at TEXT,
                    finished_at TEXT,
                    retry_count INTEGER NOT NULL DEFAULT 0,
                    error_message TEXT,
                    FOREIGN KEY(video_id) REFERENCES videos(id)
                );
                """
            )
            self._migrate(conn)

    def _migrate(self, conn: sqlite3.Connection) -> None:
        existing = {row["name"] for row in conn.execute("PRAGMA table_info(videos)")}
        for column in ("telegraph_url", "telegraph_path", "telegraph_summary_hash"):
            if column not in existing:
                conn.execute(f"ALTER TABLE videos ADD COLUMN {column} TEXT")

    def get_video_by_youtube_id(self, youtube_video_id: str) -> sqlite3.Row | None:
        with self.connect() as conn:
            return conn.execute(
                "SELECT * FROM videos WHERE youtube_video_id = ?",
                (youtube_video_id,),
            ).fetchone()

    def get_video(self, video_id: str) -> sqlite3.Row | None:
        with self.connect() as conn:
            return conn.execute("SELECT * FROM videos WHERE id = ?", (video_id,)).fetchone()

    def list_videos(self, limit: int = 200) -> list[sqlite3.Row]:
        with self.connect() as conn:
            return list(
                conn.execute(
                    """
                    SELECT
                        videos.*,
                        latest_jobs.id AS latest_job_id,
                        latest_jobs.status AS latest_job_status,
                        latest_jobs.created_at AS latest_job_created_at,
                        latest_jobs.finished_at AS latest_job_finished_at
                    FROM videos
                    LEFT JOIN jobs AS latest_jobs
                        ON latest_jobs.id = (
                            SELECT jobs.id
                            FROM jobs
                            WHERE jobs.video_id = videos.id
                            ORDER BY jobs.created_at DESC
                            LIMIT 1
                        )
                    ORDER BY videos.updated_at DESC, videos.created_at DESC
                    LIMIT ?
                    """,
                    (limit,),
                )
            )

    def get_job(self, job_id: str) -> sqlite3.Row | None:
        with self.connect() as conn:
            return conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()

    def latest_active_job_for_video(self, video_id: str) -> sqlite3.Row | None:
        placeholders = ",".join("?" for _ in ACTIVE_STATUSES)
        with self.connect() as conn:
            return conn.execute(
                f"""
                SELECT * FROM jobs
                WHERE video_id = ? AND status IN ({placeholders})
                ORDER BY created_at DESC
                LIMIT 1
                """,
                (video_id, *ACTIVE_STATUSES),
            ).fetchone()

    def create_or_reuse(self, request: SummaryRequest, force_regenerate: bool = False) -> tuple[str, str, str]:
        now = utc_now()
        with self.connect() as conn:
            existing = conn.execute(
                "SELECT * FROM videos WHERE youtube_video_id = ?",
                (request.video_id,),
            ).fetchone()

            if existing and not force_regenerate:
                if existing["status"] == ProcessingStatus.READY.value:
                    return "already_exists", existing["id"], ""
                active_job = self.latest_active_job_for_video(existing["id"])
                if active_job:
                    return "already_processing", existing["id"], active_job["id"]
                if existing["status"] != ProcessingStatus.FAILED.value:
                    return "already_exists", existing["id"], ""

            if existing:
                video_id = existing["id"]
                conn.execute(
                    """
                    UPDATE videos
                    SET canonical_url = ?, title = COALESCE(?, title), channel_name = COALESCE(?, channel_name),
                        thumbnail_url = COALESCE(?, thumbnail_url), duration_seconds = COALESCE(?, duration_seconds),
                        current_time_at_request = COALESCE(?, current_time_at_request), updated_at = ?,
                        status = ?, error_code = NULL, error_message = NULL
                    WHERE id = ?
                    """,
                    (
                        request.url,
                        request.title,
                        request.channel_name,
                        request.thumbnail_url,
                        request.duration_seconds,
                        request.current_time_seconds,
                        now,
                        ProcessingStatus.QUEUED.value,
                        video_id,
                    ),
                )
            else:
                video_id = str(uuid.uuid4())
                conn.execute(
                    """
                    INSERT INTO videos (
                        id, youtube_video_id, canonical_url, title, channel_name, thumbnail_url,
                        duration_seconds, current_time_at_request, created_at, updated_at, status
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        video_id,
                        request.video_id,
                        request.url,
                        request.title,
                        request.channel_name,
                        request.thumbnail_url,
                        request.duration_seconds,
                        request.current_time_seconds,
                        now,
                        now,
                        ProcessingStatus.QUEUED.value,
                    ),
                )

            job_id = str(uuid.uuid4())
            conn.execute(
                """
                INSERT INTO jobs (id, video_id, status, created_at, retry_count)
                VALUES (?, ?, ?, ?, 0)
                """,
                (job_id, video_id, ProcessingStatus.QUEUED.value, now),
            )
            return "queued", video_id, job_id

    def list_queued_jobs(self) -> list[sqlite3.Row]:
        with self.connect() as conn:
            return list(
                conn.execute(
                    """
                    SELECT * FROM jobs
                    WHERE status = ?
                    ORDER BY created_at ASC
                    """,
                    (ProcessingStatus.QUEUED.value,),
                )
            )

    def mark_status(self, video_id: str, job_id: str, status: ProcessingStatus) -> None:
        now = utc_now()
        with self.connect() as conn:
            conn.execute("UPDATE videos SET status = ?, updated_at = ? WHERE id = ?", (status.value, now, video_id))
            if status == ProcessingStatus.QUEUED:
                conn.execute("UPDATE jobs SET status = ? WHERE id = ?", (status.value, job_id))
            elif status in {ProcessingStatus.READY, ProcessingStatus.FAILED, ProcessingStatus.CANCELLED}:
                conn.execute(
                    "UPDATE jobs SET status = ?, finished_at = COALESCE(finished_at, ?) WHERE id = ?",
                    (status.value, now, job_id),
                )
            else:
                conn.execute(
                    "UPDATE jobs SET status = ?, started_at = COALESCE(started_at, ?) WHERE id = ?",
                    (status.value, now, job_id),
                )

    def update_metadata(
        self,
        video_id: str,
        title: str | None = None,
        channel_name: str | None = None,
        duration_seconds: float | None = None,
        thumbnail_url: str | None = None,
    ) -> None:
        """Fill in metadata fields as soon as it is fetched, without clobbering
        anything a client already supplied. Title/channel/duration use COALESCE so
        existing values win when the fetch returns blanks; the thumbnail is only set
        when the row has none yet (a client-provided cover may be higher quality)."""
        now = utc_now()
        with self.connect() as conn:
            conn.execute(
                """
                UPDATE videos
                SET title = COALESCE(?, title),
                    channel_name = COALESCE(NULLIF(?, ''), channel_name),
                    duration_seconds = COALESCE(?, duration_seconds),
                    thumbnail_url = COALESCE(thumbnail_url, NULLIF(?, '')),
                    updated_at = ?
                WHERE id = ?
                """,
                (title, channel_name, duration_seconds, thumbnail_url, now, video_id),
            )

    def mark_ready(
        self,
        video_id: str,
        job_id: str,
        transcript_path: Path,
        summary_path: Path,
        summary_markdown: str,
        metadata: dict[str, Any],
    ) -> None:
        now = utc_now()
        with self.connect() as conn:
            conn.execute(
                """
                UPDATE videos
                SET status = ?, updated_at = ?, transcript_path = ?, summary_path = ?, summary_markdown = ?,
                    title = COALESCE(?, title), channel_name = COALESCE(?, channel_name),
                    duration_seconds = COALESCE(?, duration_seconds), error_code = NULL, error_message = NULL
                WHERE id = ?
                """,
                (
                    ProcessingStatus.READY.value,
                    now,
                    str(transcript_path),
                    str(summary_path),
                    summary_markdown,
                    metadata.get("title"),
                    metadata.get("channel"),
                    metadata.get("duration_seconds"),
                    video_id,
                ),
            )
            conn.execute(
                "UPDATE jobs SET status = ?, finished_at = COALESCE(finished_at, ?) WHERE id = ?",
                (ProcessingStatus.READY.value, now, job_id),
            )

    def set_telegraph_page(self, video_id: str, url: str, path: str, summary_hash: str = "") -> None:
        with self.connect() as conn:
            conn.execute(
                "UPDATE videos SET telegraph_url = ?, telegraph_path = ?, telegraph_summary_hash = ? WHERE id = ?",
                (url, path, summary_hash, video_id),
            )

    def mark_failed(self, video_id: str, job_id: str, code: str, message: str) -> None:
        now = utc_now()
        with self.connect() as conn:
            conn.execute(
                """
                UPDATE videos
                SET status = ?, updated_at = ?, error_code = ?, error_message = ?
                WHERE id = ?
                """,
                (ProcessingStatus.FAILED.value, now, code, message, video_id),
            )
            conn.execute(
                "UPDATE jobs SET status = ?, finished_at = COALESCE(finished_at, ?), error_message = ? WHERE id = ?",
                (ProcessingStatus.FAILED.value, now, message, job_id),
            )

    @staticmethod
    def row_to_video(row: sqlite3.Row) -> dict[str, Any]:
        return {key: row[key] for key in row.keys()}

    @staticmethod
    def row_to_job(row: sqlite3.Row) -> dict[str, Any]:
        return {key: row[key] for key in row.keys()}

    @staticmethod
    def write_json(path: Path, data: dict[str, Any]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
