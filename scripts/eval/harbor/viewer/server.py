"""Serve the Harbor bench viewer.

    python3 -m scripts.eval.harbor.viewer.server --jobs-dir ~/harbor-runs --port 18766

It ingests the jobs under each `--jobs-dir` into the evaluation store
(scripts/eval/harbor/store) and serves their summaries, per-trial rows,
trajectories and verifier output from that store as JSON to a static page.
Requests address jobs and trials by validated name in the store, never by
path.  Python 3.9; SQLite needs only the standard library.
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

from scripts.eval.harbor import suites
from scripts.eval.harbor.store import config as store_config
from scripts.eval.harbor.store.backend import Store, json_text, open_ephemeral
from scripts.eval.harbor.store.library import StoreLibrary
from scripts.eval.harbor.viewer import data
from scripts.eval.harbor.viewer.runner import ACTIVE, RunManager, atomic_json, runtime_env, settings
from scripts.eval.harbor.viewer.setup import LoginManager, SetupManager

RUNTIME_ROOT = Path(__file__).resolve().parents[4]

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


def make_handler(library: StoreLibrary, manager=None, token=""):
    setups = SetupManager(manager.config_path) if manager else None
    logins = LoginManager(manager.config_path) if manager else None
    if manager is not None:
        manager.setup_running = setups.mutating

    def managed_view(name, with_rows=True):
        view = library.job_view(name)
        if view is None:
            return None
        run = next((r for r in manager.runs() if r["name"] == name), None) if manager else None
        run = run or library.run_record(name)
        # Suite/category: the launch record, else inferred from Harbor's dataset.
        view.update(suites.label((run or {}).get("suite")) or suites.label(suites.infer(view.get("dataset"))))
        judge = (run or {}).get("judge")
        if isinstance(judge, dict) and isinstance(judge.get("model"), str):
            # Which LLM judge scored the run (model id and route, no secret).
            view["judge"] = {"model": judge["model"], "via": judge.get("via")}
        if run and run["status"] in {"failed", "cancelled", "interrupted"} and view["running"]:
            # Harbor may be interrupted before it writes a final result.
            # Preserve those files, and display the durable worker outcome.
            view["running"] = False
            view["execution_status"] = run["status"]
            for row in view["rows"]:
                if row["status"] == "running":
                    row.update(status="invalid", cause="execution: " + run["status"])
            view["summary"] = data.summarize(view["rows"])
            started, finished = data.parse_time(view.get("started_at")), data.parse_time(run.get("finished_at"))
            if finished:
                view["finished_at"] = finished.isoformat()
                view["wall_s"] = (finished - started).total_seconds() if started else None
        if not with_rows:
            view.pop("rows", None)
        return view

    class Handler(BaseHTTPRequestHandler):
        server_version = "metacodes-bench-viewer/1"

        def authorized(self):
            if manager is None:
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
                    self.send_json(manager.launch(payload), 202)
                elif path == "/api/setup":
                    # Under the launch lock: a launch and a setup that may
                    # restart Docker never start at the same time.
                    with manager.lock:
                        busy = any(run.get("status") in ACTIVE for run in manager.runs())
                        started = setups.start(payload, runtime_env(), str(RUNTIME_ROOT), busy=busy)
                    self.send_json(started, 202)
                elif path == "/api/login" and payload == {}:
                    self.send_json(logins.start(runtime_env()), 202)
                elif path == "/api/cancel" and isinstance(payload, dict):
                    self.send_json(manager.cancel(payload.get("name")))
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
                catalog = manager.catalog() if manager else {"service": "metacodes-bench", "schema_version": 1, "ready": False, "reasons": ["当前服务为只读模式"], "runs": []}
                self.send_json({**catalog, "can_run": self.authorized()})
            elif path == "/api/suite":
                if manager is None:
                    self.send_json({"error": "当前服务为只读模式"}, 404)
                    return
                try:
                    self.send_json(manager.suite_tasks(query.get("id")))
                except ValueError as exc:
                    self.send_json({"error": str(exc)}, 404)
            elif path in ("/api/setup", "/api/login"):
                # Setup logs and the device code are for the capability holder.
                if not self.authorized():
                    self.send_json({"error": "请使用 metacodes bench 输出的工作台授权链接"}, 403)
                elif path == "/api/setup":
                    self.send_json({"setup": setups.latest()})
                else:
                    self.send_json(logins.status())
            elif path == "/api/run":
                record = next((r for r in manager.runs() if r["name"] == query.get("name")), None) if manager else None
                if not record:
                    self.send_json({"error": "no such run"}, 404)
                    return
                self.send_json({**record, "log": data.tail(manager.records / (record["name"] + ".log"))})
            elif path == "/api/jobs":
                library.maybe_sync()
                jobs = [view for view in (managed_view(name, False) for name in library.job_names()) if view]
                jobs.sort(key=lambda view: view["started_at"] or "", reverse=True)
                storage = library.storage()
                self.send_json({"jobs": jobs, "runs": manager.runs() if manager else [],
                                "summary": data.merge_summaries(j["summary"] for j in jobs),
                                "storage": {**storage,
                                            "records_dir": str(manager.records) if manager else None,
                                            "format": storage["database"]["format"]}})
            elif path == "/api/job":
                library.maybe_sync()
                view = managed_view(query.get("name", ""))
                if view is None:
                    self.send_json({"error": "no such job"}, 404)
                    return
                self.send_json(view)
            elif path == "/api/trial":
                library.maybe_sync()
                job, trial = query.get("job", ""), query.get("trial", "")
                detail = library.trial_detail(job, trial)
                if detail is None:
                    self.send_json({"error": "no such trial"}, 404)
                    return
                view = managed_view(job)
                for row in view["rows"] if view else []:
                    if row["trial"] == trial:
                        detail["row"] = row
                        break
                self.send_json(detail)
            elif path == "/api/job.csv":
                library.maybe_sync()
                view = managed_view(query.get("name", ""))
                if view is None:
                    self.send_json({"error": "no such job"}, 404)
                    return
                body = data.job_csv(view).encode("utf-8", "replace")
                self.send_bytes(
                    body,
                    "text/csv; charset=utf-8",
                    attachment=f"{view['name']}.csv",
                )
            else:
                self.send_json({"error": "not found"}, 404)

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
    library: Optional[StoreLibrary] = None

    def server_close(self):
        super().server_close()
        if self.library is not None:
            self.library.close()

    def server_bind(self):
        # HTTPServer otherwise reverse-resolves the bind address. A public
        # bind can stall on DNS before the CLI's readiness deadline, even
        # though this service only needs the configured address and port.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def library_for(roots, manager=None) -> StoreLibrary:
    """The store a service reads: the workbench's configured store, or a
    private temporary one for a read-only viewer without a workbench."""
    if manager is not None:
        store = Store(store_config.for_workbench(settings(manager.config_path), manager.config_path))
    else:
        store = open_ephemeral()
    return StoreLibrary(store, roots, owns_store=True)


def make_server(library, bind: str, port: int, manager=None, token="") -> ThreadingHTTPServer:
    """`library` is a StoreLibrary, or a data.Library whose roots are then
    served through the workbench's store."""
    if isinstance(library, data.Library):
        library = library_for(library.roots, manager)
    server = WorkbenchHTTPServer((bind, port), make_handler(library, manager, token))
    server.library = library
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
    library = library_for(args.jobs_dir, manager)
    server = make_server(library, args.bind, args.port, manager, token)
    # Historical imports can take a while; serve meanwhile.
    library.start_background()
    host = "127.0.0.1" if args.bind == "0.0.0.0" else args.bind
    url = args.public_url or f"http://{host}:{server.server_address[1]}/"
    url = url.rstrip("/") + "/"
    if args.ready_file:
        atomic_json(args.ready_file, {"url": url, "token": token, "pid": os.getpid(),
                                    "listen_url": f"http://{host}:{server.server_address[1]}/",
                                    "jobs_dir": str(args.jobs_dir[0].resolve()),
                                    "store": library.store.config.describe()})
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
