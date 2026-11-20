"""Serve the Bench workbench page over the runtime in `scripts.eval.harbor.bench`.

    python3 -m scripts.eval.harbor.viewer.server --jobs-dir ~/harbor-runs --port 18766

This module is presentation only: HTTP routes, authorization and the static
page. What a route answers comes from `Workbench`, which serves the jobs under
each `--jobs-dir` from the evaluation store; without `--config` it is
read-only. Python 3.9; SQLite needs only the standard library.
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
from scripts.eval.harbor.store.backend import json_text

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
    ("X-Frame-Options", "DENY"),
    # No Content-Security-Policy: the workbench runs on a private network, and a
    # CSP blocks the browser annotation overlays (e.g. Codex desktop's selection).
    ("Referrer-Policy", "no-referrer"),
)


# A batch request lists task names for every dataset; other bodies are small.
POST_LIMITS = {"/api/batches": 512 * 1024}
POST_LIMIT = 16384


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
                path = urlsplit(self.path).path
                limit = POST_LIMITS.get(path, POST_LIMIT)
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= limit or self.headers.get_content_type() != "application/json":
                    raise ValueError(f"需要 application/json（不超过 {limit // 1024}KB）")
                payload = json.loads(self.rfile.read(length))
                if path == "/api/runs":
                    self.send_json(workbench.launch(payload), 202)
                elif path == "/api/batches":
                    self.send_json(workbench.create_batch(payload), 202)
                elif path == "/api/batch/cancel" and isinstance(payload, dict):
                    self.send_json(workbench.cancel_batch(payload.get("id")))
                elif path == "/api/store":
                    self.send_json(workbench.store_action(payload))
                elif path == "/api/setup":
                    self.send_json(workbench.start_setup(payload), 202)
                elif path == "/api/login" and payload == {}:
                    self.send_json(workbench.start_login(), 202)
                elif path == "/api/providers":
                    self.send_json(workbench.add_provider(payload), 201)
                elif path == "/api/providers/remove" and isinstance(payload, dict):
                    self.send_json(workbench.remove_provider(payload.get("id")))
                elif path == "/api/providers/probe" and isinstance(payload, dict):
                    self.send_json(workbench.probe_provider(payload.get("id"), payload.get("model")))
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
            elif path == "/api/suite":
                try:
                    self.send_json(workbench.suite_tasks(query.get("id")))
                except ValueError as exc:
                    self.send_json({"error": str(exc)}, 404)
            elif path in ("/api/setup", "/api/login", "/api/providers"):
                # Setup logs, the device code and provider endpoints are for
                # the capability holder.
                if not self.authorized():
                    self.send_json({"error": "请使用 metacodes bench 输出的工作台授权链接"}, 403)
                elif path == "/api/providers":
                    self.send_json(workbench.providers())
                elif path == "/api/setup":
                    self.send_json(workbench.setup_status())
                else:
                    self.send_json(workbench.login_status())
            elif path == "/api/batch":
                value = workbench.batch(query.get("id"))
                if value is None:
                    self.send_json({"error": "no such batch"}, 404)
                    return
                self.send_json({**value, "can_run": self.authorized()})
            elif path == "/api/store":
                self.send_json(workbench.store_status(self.authorized()))
            elif path == "/api/run":
                self.send_found(workbench.run(query.get("name")), "no such run")
            elif path == "/api/jobs":
                self.send_json(workbench.jobs(query.get("batch") or "all"))
            elif path == "/api/job":
                self.send_found(workbench.job(query.get("name", "")), "no such job")
            elif path == "/api/trial":
                self.send_found(workbench.trial(query.get("job", ""), query.get("trial", "")), "no such trial")
            elif path == "/api/job.csv":
                view = workbench.job(query.get("name", ""))
                if view is None:
                    self.send_json({"error": "no such job"}, 404)
                    return
                self.send_bytes(data.job_csv(view).encode("utf-8", "replace"), "text/csv; charset=utf-8",
                                attachment=f"{view['name']}.csv")
            else:
                self.send_json({"error": "not found"}, 404)

        def send_found(self, value, missing: str) -> None:
            if value is None:
                self.send_json({"error": missing}, 404)
            else:
                self.send_json(value)

        def send_json(self, value, status: int = 200) -> None:
            # A lone surrogate (a broken emoji in a trajectory) is sent as
            # its JSON escape instead of failing the response.
            body = json_text(value).encode("utf-8")
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
    workbench: Optional[Workbench] = None

    def server_close(self):
        super().server_close()
        if self.workbench is not None:
            self.workbench.close()

    def server_bind(self):
        # HTTPServer otherwise reverse-resolves the bind address. A public
        # bind can stall on DNS before the CLI's readiness deadline, even
        # though this service only needs the configured address and port.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def make_server(workbench: Workbench, bind: str, port: int, token="") -> ThreadingHTTPServer:
    server = WorkbenchHTTPServer((bind, port), make_handler(workbench, token))
    server.workbench = workbench
    workbench.start_batches()
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
    workbench = Workbench(data.Library(args.jobs_dir), manager)
    server = make_server(workbench, args.bind, args.port, token)
    workbench.sync_in_background()
    host = "127.0.0.1" if args.bind == "0.0.0.0" else args.bind
    url = args.public_url or f"http://{host}:{server.server_address[1]}/"
    url = url.rstrip("/") + "/"
    if args.ready_file:
        atomic_json(args.ready_file, {"url": url, "token": token, "pid": os.getpid(),
                                    "listen_url": f"http://{host}:{server.server_address[1]}/",
                                    "jobs_dir": str(args.jobs_dir[0].resolve()),
                                    "store": workbench.library.store.config.describe()})
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
