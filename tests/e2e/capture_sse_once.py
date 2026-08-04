#!/usr/bin/env python3
"""Capture one Anthropic-compatible request and return a minimal SSE response."""

from __future__ import annotations

import http.server
import sys
from pathlib import Path


class Handler(http.server.BaseHTTPRequestHandler):
    request_path: Path

    def do_POST(self) -> None:  # noqa: N802 - stdlib callback name
        length = int(self.headers.get("Content-Length", "0"))
        self.request_path.write_bytes(self.rfile.read(length))
        body = b'data: {"type":"message_stop"}\n\n'
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *args: object) -> None:
        del args


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: capture_sse_once.py <request.json> <url-file>")
    Handler.request_path = Path(sys.argv[1])
    url_file = Path(sys.argv[2])
    with http.server.HTTPServer(("127.0.0.1", 0), Handler) as server:
        url_file.write_text(
            f"http://127.0.0.1:{server.server_port}/v1/messages\n", encoding="utf-8"
        )
        server.handle_request()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
