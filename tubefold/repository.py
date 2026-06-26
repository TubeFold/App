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

                CREATE TABLE IF NOT EXISTS watch_activity (
                    youtube_video_id TEXT PRIMARY KEY,
                    canonical_url TEXT NOT NULL,
                    title TEXT,
                    channel_name TEXT,
                    thumbnail_url TEXT,
                    duration_seconds REAL,
                    watched_at TEXT NOT NULL,
                    dismissed_at TEXT
                );
                """
            )
            self._migrate(conn)

    def _migrate(self, conn: sqlite3.Connection) -> None:
        existing = {row["name"] for row in conn.execute("PRAGMA table_info(videos)")}
        for column in ("telegraph_url", "telegraph_path", "telegraph_summary_hash"):
            if column not in existing:
                conn.execute(f"ALTER TABLE videos ADD COLUMN {column} TEXT")

        job_columns = {row["name"] for row in conn.execute("PRAGMA table_info(jobs)")}
        for column, sql_type in (
            ("provider", "TEXT"),
            ("input_tokens", "INTEGER"),
            ("output_tokens", "INTEGER"),
            ("total_tokens", "INTEGER"),
            ("cost_usd", "REAL"),
            ("weekly_percent", "REAL"),
            ("weekly_resets_at", "INTEGER"),
            ("primary_percent", "REAL"),
        ):
            if column not in job_columns:
                conn.execute(f"ALTER TABLE jobs ADD COLUMN {column} {sql_type}")

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

    def delete_video(self, video_id: str) -> str | None:
        """Delete a video and all of its jobs. Returns the video's youtube_video_id
        (so callers can clean up on-disk artifacts), or None if it didn't exist."""
        with self.connect() as conn:
            row = conn.execute(
                "SELECT youtube_video_id FROM videos WHERE id = ?", (video_id,)
            ).fetchone()
            if row is None:
                return None
            conn.execute("DELETE FROM jobs WHERE video_id = ?", (video_id,))
            conn.execute("DELETE FROM videos WHERE id = ?", (video_id,))
            return row["youtube_video_id"]

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

    def record_watch_activity(
        self,
        youtube_video_id: str,
        canonical_url: str,
        title: str | None = None,
        channel_name: str | None = None,
        thumbnail_url: str | None = None,
        duration_seconds: float | None = None,
    ) -> None:
        """Remember the most recently opened YouTube video so the app can suggest it.

        Re-opening a video refreshes ``watched_at`` but **preserves any prior dismissal**:
        once the user closes a suggestion with the X it stays hidden for good, even if they
        watch the video again."""
        now = utc_now()
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO watch_activity (
                    youtube_video_id, canonical_url, title, channel_name,
                    thumbnail_url, duration_seconds, watched_at, dismissed_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(youtube_video_id) DO UPDATE SET
                    canonical_url = excluded.canonical_url,
                    title = COALESCE(excluded.title, watch_activity.title),
                    channel_name = COALESCE(NULLIF(excluded.channel_name, ''), watch_activity.channel_name),
                    thumbnail_url = COALESCE(excluded.thumbnail_url, watch_activity.thumbnail_url),
                    duration_seconds = COALESCE(excluded.duration_seconds, watch_activity.duration_seconds),
                    watched_at = excluded.watched_at
                """,
                (youtube_video_id, canonical_url, title, channel_name, thumbnail_url, duration_seconds, now),
            )

    def latest_watch_suggestion(self) -> sqlite3.Row | None:
        """Newest non-dismissed watched video, joined to the library so the caller knows
        whether it has already been added (and the local video id / status if so).

        A video that is currently being summarized (any active status) is skipped — once
        the user has kicked off a job there is nothing to suggest, so we fall through to the
        next watched video instead."""
        placeholders = ",".join("?" for _ in ACTIVE_STATUSES)
        with self.connect() as conn:
            return conn.execute(
                f"""
                SELECT
                    watch_activity.*,
                    videos.id AS library_video_id,
                    videos.status AS library_status
                FROM watch_activity
                LEFT JOIN videos ON videos.youtube_video_id = watch_activity.youtube_video_id
                WHERE watch_activity.dismissed_at IS NULL
                  AND (videos.status IS NULL OR videos.status NOT IN ({placeholders}))
                ORDER BY watch_activity.watched_at DESC
                LIMIT 1
                """,
                tuple(ACTIVE_STATUSES),
            ).fetchone()

    def dismiss_watch_activity(self, youtube_video_id: str) -> None:
        with self.connect() as conn:
            conn.execute(
                "UPDATE watch_activity SET dismissed_at = ? WHERE youtube_video_id = ?",
                (utc_now(), youtube_video_id),
            )

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

    def reclaim_orphaned_jobs(self, code: str, message: str) -> list[str]:
        """Fail any job left mid-run by a previous process and reset its video.

        The worker processes jobs one at a time, so on a fresh start nothing is
        actually running: any job in an in-progress status (fetching*/generating)
        was interrupted (the app was quit or the provider was killed) and would
        otherwise show "processing" forever. We mark those failed so the user can
        regenerate. Queued jobs are left alone — the worker will pick them up.
        Returns the ids of the jobs that were reclaimed."""
        in_progress = [
            ProcessingStatus.FETCHING_METADATA.value,
            ProcessingStatus.FETCHING_TRANSCRIPT.value,
            ProcessingStatus.GENERATING_SUMMARY.value,
        ]
        placeholders = ",".join("?" for _ in in_progress)
        now = utc_now()
        with self.connect() as conn:
            rows = conn.execute(
                f"SELECT id, video_id FROM jobs WHERE status IN ({placeholders})",
                tuple(in_progress),
            ).fetchall()
            for row in rows:
                conn.execute(
                    "UPDATE jobs SET status = ?, finished_at = COALESCE(finished_at, ?), error_message = ? WHERE id = ?",
                    (ProcessingStatus.FAILED.value, now, message, row["id"]),
                )
                conn.execute(
                    "UPDATE videos SET status = ?, updated_at = ?, error_code = ?, error_message = ? WHERE id = ?",
                    (ProcessingStatus.FAILED.value, now, code, message, row["video_id"]),
                )
        return [row["id"] for row in rows]

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

    def set_job_usage(self, job_id: str, usage: dict[str, Any]) -> None:
        """Persist the token usage + quota snapshot captured from a provider run.

        ``usage`` is the parsed sidecar dict; codex carries ``weekly_percent`` etc.,
        claude carries ``cost_usd``. Missing keys simply store NULL."""
        with self.connect() as conn:
            conn.execute(
                """
                UPDATE jobs
                SET provider = ?, input_tokens = ?, output_tokens = ?, total_tokens = ?,
                    cost_usd = ?, weekly_percent = ?, weekly_resets_at = ?, primary_percent = ?
                WHERE id = ?
                """,
                (
                    usage.get("provider"),
                    usage.get("input_tokens"),
                    usage.get("output_tokens"),
                    usage.get("total_tokens"),
                    usage.get("cost_usd"),
                    usage.get("weekly_percent"),
                    usage.get("weekly_resets_at"),
                    usage.get("primary_percent"),
                    job_id,
                ),
            )

    def usage_summary(self) -> dict[str, Any]:
        """Aggregate token usage across all jobs that recorded any.

        Returns total tokens, a per-provider breakdown (tokens/cost/job count) and
        the freshest codex weekly-quota snapshot (the latest job carrying one)."""
        with self.connect() as conn:
            rows = conn.execute(
                """
                SELECT provider,
                       COUNT(*) AS jobs,
                       COALESCE(SUM(input_tokens), 0) AS input_tokens,
                       COALESCE(SUM(output_tokens), 0) AS output_tokens,
                       COALESCE(SUM(total_tokens), 0) AS total_tokens,
                       COALESCE(SUM(cost_usd), 0) AS cost_usd
                FROM jobs
                WHERE total_tokens IS NOT NULL
                GROUP BY provider
                """
            ).fetchall()
            codex_weekly = conn.execute(
                """
                SELECT weekly_percent, weekly_resets_at, primary_percent, finished_at
                FROM jobs
                WHERE weekly_percent IS NOT NULL
                ORDER BY COALESCE(finished_at, created_at) DESC
                LIMIT 1
                """
            ).fetchone()

        by_provider: dict[str, Any] = {}
        total_tokens = 0
        for row in rows:
            provider = row["provider"] or "unknown"
            total_tokens += int(row["total_tokens"])
            by_provider[provider] = {
                "jobs": int(row["jobs"]),
                "inputTokens": int(row["input_tokens"]),
                "outputTokens": int(row["output_tokens"]),
                "totalTokens": int(row["total_tokens"]),
                "costUsd": float(row["cost_usd"]) if row["cost_usd"] else None,
            }

        weekly = None
        if codex_weekly is not None:
            weekly = {
                "usedPercent": codex_weekly["weekly_percent"],
                "resetsAt": codex_weekly["weekly_resets_at"],
                "primaryPercent": codex_weekly["primary_percent"],
                "capturedAt": codex_weekly["finished_at"],
            }

        return {
            "totalTokens": total_tokens,
            "byProvider": by_provider,
            "codexWeekly": weekly,
        }

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
