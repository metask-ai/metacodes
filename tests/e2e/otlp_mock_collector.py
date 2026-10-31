#!/usr/bin/env python3
"""Loopback OTLP/HTTP trace receiver for the daemon e2e scripts.

Accepts `POST /v1/traces` (any content type), appends each request as one JSON
line `{"content_type": ..., "authorization": ..., "body": <text>}` to
<out-file>, and answers 200 `{}`. Listens on 127.0.0.1 on a port the kernel
picks and writes its base URL (no path) to <url-file> once listening.
"""

from __future__ import annotations

import http.server
import json
import sys
import threading
from pathlib import Path

LOCK = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    out: Path

    def do_POST(self) -> None:  # noqa: N802 - stdlib callback name
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path != "/v1/traces":
            self.send_response(404)
            self.end_headers()
            return
        record = {
            "content_type": self.headers.get("Content-Type", ""),
            "authorization": self.headers.get("Authorization", ""),
            "body": body.decode("utf-8", "replace"),
        }
        with LOCK, self.out.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, _format: str, *args: object) -> None:
        del args


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: otlp_mock_collector.py <url-file> <out-file>")
    url_file, out = Path(sys.argv[1]), Path(sys.argv[2])
    Handler.out = out
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    pending = url_file.with_name(url_file.name + ".tmp")
    pending.write_text(f"http://127.0.0.1:{server.server_port}\n", encoding="utf-8")
    pending.replace(url_file)  # readers never see a partial line
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
