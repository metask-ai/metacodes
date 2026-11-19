"""Serve the Bench workbench page over the runtime in `scripts.eval.harbor.bench`.

    python3 -m scripts.eval.harbor.viewer.server --jobs-dir ~/harbor-runs --port 18766

This module is presentation only: HTTP routes, authorization and the static
page. What a route answers comes from `Workbench`; without `--config` it is
read-only. Python 3.9, stdlib only.
"""

from __future__ import annotations

import argparse
import hmac
import json
import os
import secrets
import socketserver
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs, urlsplit
from http.cookies import SimpleCookie

from scripts.eval.harbor.bench import data
from scripts.eval.harbor.bench.runner import RunManager, atomic_json
from scripts.eval.harbor.bench.workbench import Workbench

STATIC_DIR = Path(__file__).resolve().parent / "static"
STATIC = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/viewer.css": ("viewer.css", "text/css; charset=utf-8"),
    "/viewer.js": ("viewer.js", "text/javascript; charset=utf-8"),
}
SECURITY_HEADERS = (
    ("Cache-Control", "no-store"),
    ("X-Content-Type-Options", "nosniff"),
    (
        "Content-Security-Policy",
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
        "object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
    ),
    ("Referrer-Policy", "no-referrer"),
)


def make_handler(workbench: Workbench, token=""):
    class Handler(BaseHTTPRequestHandler):
        server_version = "metacodes-bench-viewer/1"

        def authorized(self):
            if not workbench.can_launch:
                return False
            bearer = self.headers.get("Authorization", "").removeprefix("Bearer ")
            cookie = SimpleCookie()
            try:
                cookie.load(self.headers.get("Cookie", ""))
            except Exception:
                return False
            value = cookie["bench_session"].value if "bench_session" in cookie else ""
            return bool(token) and (hmac.compare_digest(bearer, token) or hmac.compare_digest(value, token))

        def do_POST(self):
            # A browser must prove same-origin intent as well as carry the
            # workbench capability. Native clients use a bearer capability.
            origin = self.headers.get("Origin")
            host = self.headers.get("Host", "")
            if origin and urlsplit(origin).netloc != host:
                self.send_json({"error": "origin refused"}, 403)
                return
            if not self.authorized():
                self.send_json({"error": "请使用 metacodes bench 输出的工作台授权链接"}, 403)
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 16384 or self.headers.get_content_type() != "application/json":
                    raise ValueError("需要 application/json（不超过 16KB）")
                payload = json.loads(self.rfile.read(length))
                path = urlsplit(self.path).path
                if path == "/api/runs":
                    self.send_json(workbench.launch(payload), 202)
                elif path == "/api/cancel" and isinstance(payload, dict):
                    self.send_json(workbench.cancel(payload.get("name")))
                elif path == "/api/stop" and payload == {}:
                    self.send_json({"stopped": True})
                    threading.Thread(target=self.server.shutdown, daemon=True).start()
                else:
                    self.send_json({"error": "not found"}, 404)
            except (ValueError, TypeError) as exc:
                self.send_json({"error": str(exc)}, 400)
            except BrokenPipeError:
                pass

        def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
            url = urlsplit(self.path)
            query = {key: values[0] for key, values in parse_qs(url.query).items()}
            if url.path == "/" and token and hmac.compare_digest(query.get("token", ""), token):
                self.send_response(303)
                self.send_header("Set-Cookie", "bench_session=" + token + "; Path=/; HttpOnly; SameSite=Strict")
                self.send_header("Location", "/")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                return
            try:
                self.route(url.path, query)
            except BrokenPipeError:
                pass
            except Exception:  # never leak paths or tracebacks to the page
                self.send_json({"error": "internal error"}, 500)

        def route(self, path: str, query: dict) -> None:
            if path in STATIC:
                name, mime = STATIC[path]
                self.send_bytes((STATIC_DIR / name).read_bytes(), mime)
            elif path == "/api/workbench":
                self.send_json({**workbench.catalog(), "can_run": self.authorized()})
            elif path == "/api/run":
                self.send_found(workbench.run(query.get("name")), "no such run")
            elif path == "/api/jobs":
                self.send_json(workbench.jobs())
            elif path == "/api/job":
                self.send_found(workbench.job(query.get("name", "")), "no such job")
            elif path == "/api/trial":
                self.send_found(workbench.trial(query.get("job", ""), query.get("trial", "")), "no such trial")
            elif path == "/api/job.csv":
                view = workbench.job(query.get("name", ""))
                if view is None:
                    self.send_json({"error": "no such job"}, 404)
                    return
                self.send_bytes(data.job_csv(view).encode("utf-8"), "text/csv; charset=utf-8",
                                attachment=f"{view['name']}.csv")
            else:
                self.send_json({"error": "not found"}, 404)

        def send_found(self, value, missing: str) -> None:
            if value is None:
                self.send_json({"error": missing}, 404)
            else:
                self.send_json(value)

        def send_json(self, value, status: int = 200) -> None:
            body = json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8")
            self.send_bytes(body, "application/json; charset=utf-8", status=status)

        def send_bytes(self, body: bytes, mime: str, status: int = 200, attachment: Optional[str] = None) -> None:
            self.send_response(status)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(body)))
            if attachment:
                self.send_header("Content-Disposition", f'attachment; filename="{attachment}"')
            for name, value in SECURITY_HEADERS:
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, _format: str, *_args: object) -> None:
            return

    return Handler


class WorkbenchHTTPServer(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer otherwise reverse-resolves the bind address. A public
        # bind can stall on DNS before the CLI's readiness deadline, even
        # though this service only needs the configured address and port.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def make_server(workbench: Workbench, bind: str, port: int, token="") -> ThreadingHTTPServer:
    server = WorkbenchHTTPServer((bind, port), make_handler(workbench, token))
    server.daemon_threads = True
    return server


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Serve the Harbor bench viewer.")
    parser.add_argument("--jobs-dir", action="append", type=Path, required=True,
                        help="a Harbor jobs directory (repeatable)")
    parser.add_argument("--bind", default="127.0.0.1",
                        help="listen address (default 127.0.0.1; 0.0.0.0 to share on the network)")
    parser.add_argument("--port", type=int, default=18766)
    parser.add_argument("--config", type=Path, help="server-owned workbench settings")
    parser.add_argument("--ready-file", type=Path)
    parser.add_argument("--public-url")
    args = parser.parse_args(argv)
    manager = RunManager(args.jobs_dir[0], args.config) if args.config else None
    token = secrets.token_urlsafe(32) if manager else ""
    server = make_server(Workbench(data.Library(args.jobs_dir), manager), args.bind, args.port, token)
    host = "127.0.0.1" if args.bind == "0.0.0.0" else args.bind
    url = args.public_url or f"http://{host}:{server.server_address[1]}/"
    url = url.rstrip("/") + "/"
    if args.ready_file:
        atomic_json(args.ready_file, {"url": url, "token": token, "pid": os.getpid(),
                                    "listen_url": f"http://{host}:{server.server_address[1]}/",
                                    "jobs_dir": str(args.jobs_dir[0].resolve())})
        args.ready_file.chmod(0o600)
    print("Bench 工作台：" + url, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
