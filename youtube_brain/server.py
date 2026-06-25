from __future__ import annotations

import argparse
import json
import logging
import re
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import ThreadingMixIn
from typing import Any

from scripts.youtube_summary_lib import normalize_youtube_url, parse_youtube_video_id

from . import API_VERSION, APP_VERSION
from .config import AppConfig, load_config
from .logging_utils import configure_logging
from .models import SummaryRequest
from .processing import ProcessingQueue
from .provider_setup import CodexProviderDiagnostics
from .repository import Repository


logger = logging.getLogger(__name__)


class YouTubeBrainServer(ThreadingHTTPServer):
    def __init__(self, config: AppConfig, repository: Repository, queue: ProcessingQueue) -> None:
        super().__init__((config.host, config.port), RequestHandler)
        self.config = config
        self.repository = repository
        self.queue = queue


class RequestHandler(BaseHTTPRequestHandler):
    server: YouTubeBrainServer

    def log_message(self, format: str, *args: Any) -> None:
        logger.info("HTTP %s - %s", self.address_string(), format % args)

    def do_OPTIONS(self) -> None:
        logger.info("OPTIONS path=%s origin=%s", self.path, self.headers.get("Origin"))
        self._send_json({}, status=HTTPStatus.NO_CONTENT)

    def do_GET(self) -> None:
        logger.info("GET path=%s origin=%s", self.path, self.headers.get("Origin"))
        if self.path == "/health":
            self._send_json({"status": "ok", "appVersion": APP_VERSION, "apiVersion": API_VERSION})
            return

        if self.path == "/api/v1/provider-setup":
            if not self._authorized():
                return
            diagnostics = CodexProviderDiagnostics(self.server.config)
            self._send_json({"provider": "codex", "state": diagnostics.state(), **diagnostics.model_options()})
            return

        if self.path == "/api/v1/videos":
            if not self._authorized():
                return
            videos = [self._video_payload(video) for video in self.server.repository.list_videos()]
            self._send_json({"videos": videos})
            return

        match = re.fullmatch(r"/api/v1/jobs/([^/?]+)", self.path)
        if match:
            if not self._authorized():
                return
            job = self.server.repository.get_job(match.group(1))
            if job is None:
                logger.warning("Job lookup miss job=%s", match.group(1))
                self._send_error("not_found", "Job was not found.", HTTPStatus.NOT_FOUND)
                return
            self._send_json(
                {
                    "jobId": job["id"],
                    "status": job["status"],
                    "progress": None,
                    "error": job["error_message"],
                }
            )
            return

        match = re.fullmatch(r"/api/v1/videos/by-youtube-id/([^/?]+)", self.path)
        if match:
            if not self._authorized():
                return
            youtube_id = match.group(1)
            video = self.server.repository.get_video_by_youtube_id(youtube_id)
            if video is None:
                logger.info("Video lookup youtube_id=%s exists=false", youtube_id)
                self._send_json({"exists": False})
                return
            logger.info("Video lookup youtube_id=%s exists=true local_video_id=%s status=%s", youtube_id, video["id"], video["status"])
            self._send_json({"exists": True, "videoId": video["id"], "status": video["status"]})
            return

        self._send_error("not_found", "Endpoint was not found.", HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        logger.info("POST path=%s origin=%s content_length=%s", self.path, self.headers.get("Origin"), self.headers.get("Content-Length"))
        if not self._authorized():
            return

        if self.path == "/api/v1/summaries":
            data = self._read_json_body()
            if data is None:
                return
            try:
                raw_url = str(data.get("url") or data.get("canonicalURL") or "")
                video_id = parse_youtube_video_id(str(data.get("videoId") or raw_url))
                canonical_url = normalize_youtube_url(raw_url or video_id)
                request = SummaryRequest.from_json(data, video_id, canonical_url)
            except ValueError:
                logger.warning("Invalid summary request url=%r videoId=%r", data.get("url"), data.get("videoId"))
                self._send_error("invalid_youtube_url", "The URL is not a supported YouTube video.", HTTPStatus.BAD_REQUEST)
                return

            logger.info(
                "Summary request youtube_id=%s canonical_url=%s title=%r source=%s",
                request.video_id,
                request.url,
                request.title,
                request.source,
            )
            status, video_record_id, job_id = self.server.repository.create_or_reuse(request)
            logger.info(
                "Summary request result youtube_id=%s status=%s local_video_id=%s job=%s",
                request.video_id,
                status,
                video_record_id,
                job_id or None,
            )
            if status == "queued":
                self.server.queue.notify()
                self._send_json({"jobId": job_id, "videoId": video_record_id, "status": "queued"}, HTTPStatus.ACCEPTED)
            elif status == "already_processing":
                self._send_json({"jobId": job_id, "videoId": video_record_id, "status": "already_processing"})
            else:
                self._send_json({"jobId": None, "videoId": video_record_id, "status": "already_exists"})
            return

        if self.path == "/api/v1/provider-setup/codex/detect":
            data = self._read_optional_json_body()
            if data is None:
                return
            diagnostics = CodexProviderDiagnostics(self.server.config)
            result = diagnostics.detect_installation(data.get("path") if data else None)
            logger.info("Provider setup detect status=%s path=%s version=%s", result.get("status"), result.get("path"), result.get("version"))
            self._send_json(result)
            return

        if self.path == "/api/v1/provider-setup/codex/test":
            data = self._read_optional_json_body()
            if data is None:
                return
            diagnostics = CodexProviderDiagnostics(self.server.config)
            result = diagnostics.test_connection(data.get("path") if data else None)
            logger.info(
                "Provider setup connection test status=%s category=%s",
                result.get("status"),
                (result.get("details") or {}).get("errorCategory"),
            )
            self._send_json(result)
            return

        if self.path == "/api/v1/provider-setup/complete":
            diagnostics = CodexProviderDiagnostics(self.server.config)
            result = diagnostics.complete_setup()
            logger.info("Provider setup completed provider=codex")
            self._send_json(result)
            return

        if self.path == "/api/v1/provider-setup/codex/model":
            data = self._read_json_body()
            if data is None:
                return
            diagnostics = CodexProviderDiagnostics(self.server.config)
            result = diagnostics.save_model_settings(data.get("model"), data.get("reasoningEffort"))
            state = result.get("state") or {}
            logger.info(
                "Provider setup model saved provider=codex model=%s reasoning_effort=%s",
                state.get("codexModel"),
                state.get("codexReasoningEffort"),
            )
            self._send_json(result)
            return

        match = re.fullmatch(r"/api/v1/videos/([^/?]+)/regenerate", self.path)
        if match:
            video = self.server.repository.get_video(match.group(1))
            if video is None:
                logger.warning("Regenerate requested for missing video=%s", match.group(1))
                self._send_error("not_found", "Video was not found.", HTTPStatus.NOT_FOUND)
                return
            logger.info("Regenerate requested local_video_id=%s youtube_id=%s", video["id"], video["youtube_video_id"])
            request = SummaryRequest(
                video_id=video["youtube_video_id"],
                url=video["canonical_url"],
                title=video["title"],
                channel_name=video["channel_name"],
                duration_seconds=video["duration_seconds"],
                thumbnail_url=video["thumbnail_url"],
            )
            _status, video_record_id, job_id = self.server.repository.create_or_reuse(request, force_regenerate=True)
            self.server.queue.notify()
            self._send_json({"jobId": job_id, "videoId": video_record_id, "status": "queued"}, HTTPStatus.ACCEPTED)
            return

        self._send_error("not_found", "Endpoint was not found.", HTTPStatus.NOT_FOUND)

    def _read_json_body(self) -> dict[str, Any] | None:
        content_type = self.headers.get("Content-Type", "")
        if "application/json" not in content_type:
            logger.warning("Rejected request content_type=%r", content_type)
            self._send_error("invalid_content_type", "Content-Type must be application/json.", HTTPStatus.UNSUPPORTED_MEDIA_TYPE)
            return None
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0 or length > self.server.config.max_request_bytes:
            logger.warning("Rejected request body length=%s max=%s", length, self.server.config.max_request_bytes)
            self._send_error("invalid_request_body", "Request body is empty or too large.", HTTPStatus.BAD_REQUEST)
            return None
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except json.JSONDecodeError:
            logger.warning("Rejected invalid JSON body length=%s", length)
            self._send_error("invalid_json", "Request body is not valid JSON.", HTTPStatus.BAD_REQUEST)
            return None

    def _read_optional_json_body(self) -> dict[str, Any] | None:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length == 0:
            return {}
        return self._read_json_body()

    def _authorized(self) -> bool:
        token = self.server.config.api_token
        if not token:
            return True
        expected = f"Bearer {token}"
        if self.headers.get("Authorization") == expected:
            return True
        logger.warning("Unauthorized request path=%s", self.path)
        self._send_error("unauthorized", "Invalid local API token.", HTTPStatus.UNAUTHORIZED)
        return False

    def _send_error(self, code: str, message: str, status: HTTPStatus) -> None:
        logger.info("Response error status=%s code=%s message=%s", status.value, code, message)
        self._send_json({"error": {"code": code, "message": message}}, status)

    def _send_json(self, payload: dict[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        if status != HTTPStatus.NO_CONTENT:
            self.send_header("Content-Length", str(len(body)))
        self._send_cors_headers()
        self.end_headers()
        if status != HTTPStatus.NO_CONTENT:
            self.wfile.write(body)

    @staticmethod
    def _video_payload(video: Any) -> dict[str, Any]:
        return {
            "id": video["id"],
            "youtubeVideoID": video["youtube_video_id"],
            "canonicalURL": video["canonical_url"],
            "title": video["title"],
            "channelName": video["channel_name"],
            "thumbnailURL": video["thumbnail_url"],
            "durationSeconds": video["duration_seconds"],
            "currentTimeAtRequest": video["current_time_at_request"],
            "createdAt": video["created_at"],
            "updatedAt": video["updated_at"],
            "status": video["status"],
            "transcriptPath": video["transcript_path"],
            "summaryPath": video["summary_path"],
            "errorCode": video["error_code"],
            "errorMessage": video["error_message"],
            "latestJobID": video["latest_job_id"],
            "latestJobStatus": video["latest_job_status"],
            "latestJobCreatedAt": video["latest_job_created_at"],
            "latestJobFinishedAt": video["latest_job_finished_at"],
        }

    def _send_cors_headers(self) -> None:
        origin = self.headers.get("Origin")
        if origin and origin_allowed(origin, self.server.config.allowed_origins):
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization,Content-Type")


def origin_allowed(origin: str, allowed: tuple[str, ...]) -> bool:
    return "*" in allowed or origin in allowed or ("chrome-extension://*" in allowed and origin.startswith("chrome-extension://"))


def build_server(config: AppConfig | None = None) -> YouTubeBrainServer:
    config = config or load_config()
    configure_logging(config)
    config.data_dir.mkdir(parents=True, exist_ok=True)
    config.videos_dir.mkdir(parents=True, exist_ok=True)
    config.jobs_dir.mkdir(parents=True, exist_ok=True)
    config.logs_dir.mkdir(parents=True, exist_ok=True)
    repository = Repository(config.database_path)
    queue = ProcessingQueue(config, repository)
    server = YouTubeBrainServer(config, repository, queue)
    logger.info(
        "Server configured host=%s port=%s provider=%s data_dir=%s db=%s token_enabled=%s allowed_origins=%s",
        config.host,
        config.port,
        config.provider,
        config.data_dir,
        config.database_path,
        bool(config.api_token),
        ",".join(config.allowed_origins),
    )
    queue.start()
    return server


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the local YouTube Brain API server")
    parser.add_argument("--port", type=int, help="Override server port")
    parser.add_argument("--provider", help="Override provider name")
    args = parser.parse_args()

    config = load_config()
    if args.port is not None or args.provider is not None:
        config = AppConfig(
            host=config.host,
            port=args.port if args.port is not None else config.port,
            api_token=config.api_token,
            allowed_origins=config.allowed_origins,
            provider=args.provider or config.provider,
            python_executable=config.python_executable,
            codex_timeout_seconds=config.codex_timeout_seconds,
            data_dir=config.data_dir,
            output_dir=config.output_dir,
            codex_model=config.codex_model,
            codex_reasoning_effort=config.codex_reasoning_effort,
            max_request_bytes=config.max_request_bytes,
        )

    server = build_server(config)
    logger.info("YouTube Brain API listening on http://%s:%s", config.host, server.server_port)
    print(f"YouTube Brain API listening on http://{config.host}:{server.server_port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        logger.info("Shutting down YouTube Brain API")
        server.queue.stop()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
