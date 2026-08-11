"""Deterministic Anthropic-SSE provider for the official WorkBuddy L2.

This server is infrastructure evidence only: it returns a final text answer and
cannot solve benchmark tasks.  Its purpose is to exercise the real
WorkBuddy runner, job-private proxy, credential-FD resolver, containerized
metacodes binary, trace adapter, scorer, and paid-journal receipt without a
paid provider request.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


SCHEMA_VERSION = "metacodes-workbuddy-mock-provider-v1"
MOCK_CREDENTIAL = "metacodes-workbuddy-mock-only"
MAX_REQUEST_BYTES = 16 * 1024 * 1024


def _write_all(descriptor: int, payload: bytes) -> None:
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            raise OSError("short mock-provider artifact write")
        offset += written


def _private_new(path: Path, payload: bytes) -> None:
    parent = path.parent.resolve(strict=True)
    info = parent.stat()
    if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o022:
        raise ValueError("mock-provider artifact parent must be private")
    if hasattr(os, "geteuid") and info.st_uid != os.geteuid():
        raise ValueError("mock-provider artifact parent must be owned by the current user")
    if path.exists() or path.is_symlink():
        raise ValueError(f"refusing to overwrite mock-provider artifact: {path}")
    descriptor = os.open(
        parent / path.name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        _write_all(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    parent_descriptor = os.open(parent, os.O_RDONLY)
    try:
        os.fsync(parent_descriptor)
    finally:
        os.close(parent_descriptor)


def _sse(request_number: int) -> bytes:
    message_id = f"msg_workbuddy_mock_{request_number}"
    events: list[dict[str, Any]] = [
        {
            "type": "message_start",
            "message": {
                "id": message_id,
                "role": "assistant",
                "model": "glm-5.2",
                "usage": {
                    "input_tokens": 100,
                    "output_tokens": 0,
                    "cache_read_input_tokens": 64,
                    "cache_creation_input_tokens": 8,
                },
            },
        },
        {
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "text", "text": ""},
        },
        {
            "type": "content_block_delta",
            "index": 0,
            "delta": {
                "type": "text_delta",
                "text": "Mock L2 completed without modifying the benchmark workspace.",
            },
        },
        {"type": "content_block_stop", "index": 0},
        {
            "type": "message_delta",
            "delta": {"stop_reason": "end_turn", "stop_sequence": None},
            "usage": {"output_tokens": 8},
        },
        {"type": "message_stop"},
    ]
    return b"".join(
        b"data: " + json.dumps(event, separators=(",", ":")).encode("utf-8") + b"\n\n"
        for event in events
    )


class _Handler(BaseHTTPRequestHandler):
    server_version = "metacodes-workbuddy-mock/1"

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
        if self.path != "/v1/messages":
            self.send_error(404)
            return
        if self.headers.get("Authorization") != f"Bearer {MOCK_CREDENTIAL}":
            self.send_error(401)
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.send_error(400)
            return
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self.send_error(413)
            return
        body = self.rfile.read(length)
        try:
            request = json.loads(body)
        except (UnicodeError, json.JSONDecodeError):
            self.send_error(400)
            return
        if not isinstance(request, dict) or not request.get("model") or not request.get("messages"):
            self.send_error(400)
            return
        with self.server.state_lock:  # type: ignore[attr-defined]
            self.server.requests += 1  # type: ignore[attr-defined]
            number = self.server.requests  # type: ignore[attr-defined]
            row = {
                "schema_version": SCHEMA_VERSION,
                "request_number": number,
                "path": self.path,
                "body_sha256": hashlib.sha256(body).hexdigest(),
                "model": request.get("model"),
                "stream": request.get("stream"),
            }
            with self.server.request_log.open("ab") as handle:  # type: ignore[attr-defined]
                handle.write(json.dumps(row, sort_keys=True).encode("utf-8") + b"\n")
                handle.flush()
                os.fsync(handle.fileno())
        payload = _sse(number)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, _format: str, *_args: object) -> None:
        return


def serve(*, ready: Path, request_log: Path, port: int) -> None:
    import threading

    server = ThreadingHTTPServer(("127.0.0.1", port), _Handler)
    server.state_lock = threading.Lock()  # type: ignore[attr-defined]
    server.requests = 0  # type: ignore[attr-defined]
    server.request_log = request_log  # type: ignore[attr-defined]
    try:
        _private_new(request_log, b"")
        _private_new(
            ready,
            (
                json.dumps(
                    {"schema_version": SCHEMA_VERSION, "port": server.server_port}
                )
                + "\n"
            ).encode("utf-8"),
        )
    except BaseException:
        server.server_close()
        raise
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ready", required=True, type=Path)
    parser.add_argument("--request-log", required=True, type=Path)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args(argv)
    serve(ready=args.ready, request_log=args.request_log, port=args.port)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
