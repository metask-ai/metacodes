"""Serve the Bench workbench page over the runtime in `scripts.eval.harbor.bench`.

    python3 -m scripts.eval.harbor.viewer.server --jobs-dir ~/harbor-runs --port 18766

This module is presentation only: HTTP routes, authorization and the static
page. What a route answers comes from `Workbench`, which serves the jobs under
each `--jobs-dir` from the evaluation store; without `--config` it is
read-only. Python 3.9; SQLite needs only the standard library.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import socketserver
import sys
import threading
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs, urlsplit

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


# A profile run lists task names for every dataset; other bodies are small.
POST_LIMITS = {"/api/profiles/run": 512 * 1024}
POST_LIMIT = 16384


def _authority(netloc, scheme):
    """(host, effective port) of a URL authority; None when malformed."""
    try:
        parts = urlsplit(scheme + "://" + netloc)
        effective = parts.port or (443 if scheme == "https" else 80)
    except ValueError:
        return None
    return ((parts.hostname or "").lower().rstrip("."), effective) if parts.hostname else None


def _ip_literal(name):
    try:
        ipaddress.ip_address(name)
        return True
    except ValueError:
        return False


def trusted_origin(host_header, server_port, public_url=None):
    """The origin a browser uses for this entry, or None when `Host` names
    no entry of this workbench.

    There is no login, so the entry itself is checked: a DNS-rebound
    foreign name pointing at the service carries that name in `Host`.
    Trusted are the configured public URL, `localhost` and IP literals on
    the listening port (a rebinding page cannot make a browser send an IP
    literal it did not navigate to)."""
    if public_url:
        public = urlsplit(public_url)
        wanted = _authority(public.netloc, public.scheme)
        if wanted and _authority(host_header, public.scheme) == wanted:
            return (public.scheme, wanted[0], wanted[1])
    entry = _authority(host_header, "http")
    if entry and entry[1] == server_port and (entry[0] == "localhost" or _ip_literal(entry[0])):
        return ("http", entry[0], entry[1])
    return None


def same_origin(origin, trusted):
    """Whether a browser `Origin` header is exactly the trusted origin
    (scheme, host and effective port, RFC 6454)."""
    parts = urlsplit(origin or "")
    if parts.scheme not in ("http", "https") or parts.path not in ("", "/") or parts.query or parts.fragment:
        return False
    return (parts.scheme, *(_authority(parts.netloc, parts.scheme) or ("", 0))) == trusted


def make_handler(workbench: Workbench, public_url=None):
    class Handler(BaseHTTPRequestHandler):
        server_version = "metacodes-bench-viewer/1"

        def authorized(self):
            # The workbench runs on a trusted internal network: whoever can
            # open the page may configure and launch. Only a service started
            # without --config (a plain viewer) is read-only.
            return workbench.can_launch

        def entry(self):
            return trusted_origin(self.headers.get("Host", ""), self.server.server_address[1], public_url)

        def refuse_entry(self):
            self.send_json({"error": "请用工作台地址访问（--public-url 配置的地址、IP 或 localhost）"}, 403)

        def do_POST(self):
            # No login, but a page from another site must not drive the
            # workbench through a visitor's browser: the entry must be one
            # of the workbench's, and a browser's Origin exactly that entry.
            # Clients without an Origin (the CLI) only need a trusted entry.
            trusted = self.entry()
            if trusted is None:
                self.refuse_entry()
                return
            origin = self.headers.get("Origin")
            if origin is not None and not same_origin(origin, trusted):
                self.send_json({"error": "origin refused"}, 403)
                return
            if not self.authorized():
                self.send_json({"error": "当前服务为只读模式"}, 403)
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
                elif path == "/api/profiles/run":
                    self.send_json(workbench.queue_profile(payload), 202)
                elif path == "/api/profile/cancel" and isinstance(payload, dict):
                    self.send_json(workbench.cancel_profile(payload.get("id")))
                elif path == "/api/profile/rename" and isinstance(payload, dict):
                    self.send_json(workbench.rename_profile(payload.get("id"), payload.get("name")))
                elif path == "/api/profile/delete" and isinstance(payload, dict):
                    self.send_json(workbench.delete_profile(payload.get("id")))
                elif path == "/api/store":
                    self.send_json(workbench.store_action(payload))
                elif path == "/api/setup":
                    self.send_json(workbench.start_setup(payload), 202)
                elif path == "/api/build":
                    self.send_json(workbench.start_build(payload), 202)
                elif path == "/api/build/cancel" and payload == {}:
                    self.send_json(workbench.cancel_build())
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
            except Exception:
                traceback.print_exc()
                self.send_json({"error": "工作台内部错误，详见 service.log"}, 500)

        def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
            url = urlsplit(self.path)
            query = {key: values[0] for key, values in parse_qs(url.query).items()}
            if self.entry() is None:  # a rebound foreign name reads nothing either
                self.refuse_entry()
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
                    self.send_json(workbench.suite_tasks(query.get("id"), query.get("executor")))
                except ValueError as exc:
                    self.send_json({"error": str(exc)}, 404)
            elif path in ("/api/setup", "/api/login", "/api/providers", "/api/build", "/api/commits"):
                # A plain viewer (no --config) has none of these.
                if not self.authorized():
                    self.send_json({"error": "当前服务为只读模式"}, 403)
                elif path == "/api/commits":
                    try:
                        self.send_json(workbench.commits(query))
                    except ValueError as exc:
                        self.send_json({"error": str(exc)}, 400)
                elif path == "/api/build":
                    self.send_json(workbench.build_status())
                elif path == "/api/providers":
                    self.send_json(workbench.providers())
                elif path == "/api/setup":
                    self.send_json(workbench.setup_status())
                else:
                    self.send_json(workbench.login_status())
            elif path == "/api/profile":
                value = workbench.profile(query.get("id"))
                if value is None:
                    self.send_json({"error": "no such profile"}, 404)
                    return
                self.send_json({**value, "can_run": self.authorized()})
            elif path == "/api/store":
                self.send_json(workbench.store_status(self.authorized()))
            elif path == "/api/leaderboard":
                self.send_found(workbench.leaderboard(query.get("suite")), "no published board for this suite")
            elif path == "/api/run":
                self.send_found(workbench.run(query.get("name")), "no such run")
            elif path == "/api/jobs":
                self.send_json({**workbench.jobs(query.get("profile") or "all"), "can_run": self.authorized()})
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


def make_server(workbench: Workbench, bind: str, port: int, public_url=None) -> ThreadingHTTPServer:
    """`public_url` is the address users open besides IP literals and
    localhost (see trusted_origin)."""
    server = WorkbenchHTTPServer((bind, port), make_handler(workbench, public_url))
    server.workbench = workbench
    workbench.start_profiles()
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
    workbench = Workbench(data.Library(args.jobs_dir), manager)
    server = make_server(workbench, args.bind, args.port, args.public_url)
    workbench.sync_in_background()
    address, port = server.server_address[:2]
    listen_url = f"http://{'127.0.0.1' if address == '0.0.0.0' else address}:{port}/"
    url = (args.public_url or listen_url).rstrip("/") + "/"
    if args.ready_file:
        atomic_json(args.ready_file, {"url": url, "pid": os.getpid(), "bind": args.bind,
                                    "listen_url": listen_url,
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
