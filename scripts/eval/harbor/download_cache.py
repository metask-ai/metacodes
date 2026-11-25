from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import signal
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, Optional, Tuple
from urllib.parse import unquote, urlsplit

DEFAULT_PORT = 3143
DEFAULT_TTL = 600.0
STATS_PATH = "/_stats"
STATS_FILE = "stats.json"
STATS_INTERVAL = 5.0
CHUNK = 64 * 1024
RELAY_LIMIT = 1024 * 1024
REWRITE_LIMIT = 64 * 1024 * 1024
UPSTREAM_TIMEOUT = 60
COUNTERS = ("requests", "hits", "misses", "stale", "errors", "bytes_cached", "bytes_fetched")
IMMUTABLE = {
    "pypi": re.compile(r"^packages/"),
    "npm": re.compile(r"^(?:@[^/]+/)?[^/]+/-/[^/]+\.tgz$"),
    "go": re.compile(r"/@v/v\d+\.\d+\.\d+[^/]*\.(?:info|mod|zip)$"),
    "conda": re.compile(r"\.(?:conda|tar\.bz2)$"),
    "rustup": re.compile(r"^(?:dist/\d{4}-\d{2}-\d{2}/|rustup/archive/)"),
    "github": re.compile(r"^[^/]+/[^/]+/releases/download/[^/]+/[^/]+$"),
}
KINDS = tuple(IMMUTABLE)
ROUTED_ONLY = {"github": IMMUTABLE["github"]}
REWRITTEN_KINDS = ("npm", "pypi")
REWRITTEN_TYPES = ("application/json", "application/vnd.", "text/html")
FORWARDED_HEADERS = ("Accept", "User-Agent")
UNSAFE = re.compile(r"[\x00-\x1f\x7f\\]")
RANGE = re.compile(r"^bytes=(\d*)-(\d*)$")


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def safe_path(rest: str) -> bool:
    if UNSAFE.search(rest):
        return False
    segments = rest.split("/")
    if "" in segments[:-1]:
        return False
    decoded = [part for segment in segments for part in unquote(segment).split("/")]
    return not any(part in ("..", ".") for part in decoded) and not UNSAFE.search(unquote(rest))


def parse_range(value: str, size: int) -> Optional[Tuple[int, int]]:
    found = RANGE.match(value.strip())
    if not found or not (found.group(1) or found.group(2)):
        return None
    if not found.group(1):
        length = int(found.group(2))
        return (max(0, size - length), size - 1) if length else None
    first = int(found.group(1))
    last = min(int(found.group(2)), size - 1) if found.group(2) else size - 1
    return (first, last) if first <= last else None


class Fetch:
    def __init__(self, temporary: Path):
        self.temporary = temporary
        self.final: Optional[Path] = None
        self.cond = threading.Condition()
        self.status: Optional[int] = None
        self.content_type = ""
        self.length: Optional[int] = None
        self.relayed = b""
        self.written = 0
        self.readable = 0
        self.done = False
        self.error: Optional[str] = None


class Entry:
    def __init__(self, handle, meta: Dict):
        self.handle = handle
        self.size = int(meta["size"])
        self.content_type = str(meta.get("content_type") or "application/octet-stream")


class Store:
    def __init__(self, directory: Path, routes: Dict[str, str], ttl: float = DEFAULT_TTL, opener=None):
        self.directory = Path(directory)
        self.objects = self.directory / "objects"
        self.routes = {kind: url.rstrip("/") for kind, url in routes.items()}
        self.ttl = ttl
        self.opener = opener or urllib.request.build_opener()
        self.lock = threading.Lock()
        self.inflight: Dict[Tuple[str, str], Fetch] = {}
        self.stats_lock = threading.Lock()
        self.started_at = now_iso()
        self.dirty = False
        self.objects.mkdir(parents=True, exist_ok=True)
        self.entries, self.disk_bytes = self.scan()
        self.counters = self.load_counters()

    def scan(self) -> Tuple[int, int]:
        entries = size = 0
        for path in self.objects.rglob("*"):
            if not path.is_file():
                continue
            if path.name.endswith(".part"):
                path.unlink()
            elif path.name.endswith(".meta"):
                body = path.with_suffix("")
                if body.is_file():
                    entries += 1
                    size += body.stat().st_size
        return entries, size

    def load_counters(self) -> Dict[str, Dict[str, int]]:
        try:
            saved = json.loads((self.directory / STATS_FILE).read_text(encoding="utf-8"))["routes"]
        except (OSError, ValueError, KeyError, TypeError):
            saved = {}
        counters = {}
        for kind in self.routes:
            row = saved.get(kind) if isinstance(saved, dict) else None
            counters[kind] = {name: int(row.get(name) or 0) if isinstance(row, dict) else 0 for name in COUNTERS}
        return counters

    def count(self, kind: str, **deltas: int) -> None:
        with self.stats_lock:
            for name, delta in deltas.items():
                self.counters[kind][name] += delta
            self.dirty = True

    def stats(self) -> Dict:
        with self.stats_lock:
            routes = {kind: {"upstream": self.routes[kind], **row} for kind, row in self.counters.items()}
            return {"schema_version": 1, "started_at": self.started_at, "entries": self.entries,
                    "disk_bytes": self.disk_bytes, "routes": routes}

    def save_stats(self) -> None:
        with self.stats_lock:
            if not self.dirty:
                return
            self.dirty = False
        staging = self.directory / (STATS_FILE + ".tmp")
        staging.write_text(json.dumps(self.stats()), encoding="utf-8")
        os.replace(staging, self.directory / STATS_FILE)

    def body_path(self, kind: str, key: str) -> Path:
        digest = hashlib.sha256((self.routes[kind] + "\n" + key).encode("utf-8", "surrogatepass")).hexdigest()
        return self.objects / kind / digest[:2] / digest

    def read_entry(self, body: Path, fresh_only: bool, immutable: bool) -> Optional[Entry]:
        try:
            meta = json.loads(body.with_suffix(".meta").read_text(encoding="utf-8"))
            if fresh_only and not immutable and time.time() - float(meta["fetched_at"]) >= self.ttl:
                return None
            handle = open(body, "rb")
        except (OSError, ValueError, KeyError, TypeError):
            return None
        return Entry(handle, meta)

    def acquire(self, kind: str, key: str, url: str, headers: Dict[str, str], immutable: bool):
        body = self.body_path(kind, key)
        with self.lock:
            entry = self.read_entry(body, True, immutable)
            if entry is not None:
                return entry, None, False
            fetch = self.inflight.get((kind, key))
            if fetch is not None:
                return None, fetch, False
            body.parent.mkdir(parents=True, exist_ok=True)
            fetch = Fetch(body.with_name(body.name + "." + uuid.uuid4().hex + ".part"))
            self.inflight[(kind, key)] = fetch
        threading.Thread(target=self.download, args=(fetch, kind, key, url, headers, body), daemon=True).start()
        return None, fetch, True

    def stale(self, kind: str, key: str) -> Optional[Entry]:
        with self.lock:
            return self.read_entry(self.body_path(kind, key), False, False)

    def download(self, fetch: Fetch, kind: str, key: str, url: str, headers: Dict[str, str], body: Path) -> None:
        counted = False
        try:
            request = urllib.request.Request(url, headers={**headers, "Accept-Encoding": "identity"})
            try:
                response = self.opener.open(request, timeout=UPSTREAM_TIMEOUT)
            except urllib.error.HTTPError as answer:
                with answer:
                    self.relay(fetch, answer.code, answer.headers.get("Content-Type"), answer.read(RELAY_LIMIT))
                return
            with response:
                if response.status != 200:
                    self.relay(fetch, response.status, response.headers.get("Content-Type"), response.read(RELAY_LIMIT))
                    return
                declared = response.headers.get("Content-Length")
                length = int(declared) if declared and declared.isdigit() else None
                with fetch.cond:
                    fetch.status = 200
                    fetch.content_type = response.headers.get("Content-Type") or "application/octet-stream"
                    fetch.length = length
                    fetch.cond.notify_all()
                with open(fetch.temporary, "wb") as out:
                    while True:
                        chunk = response.read(CHUNK)
                        if not chunk:
                            break
                        out.write(chunk)
                        out.flush()
                        with fetch.cond:
                            fetch.written += len(chunk)
                            if length is None or fetch.written < length:
                                fetch.readable = fetch.written
                            fetch.cond.notify_all()
            if length is not None and fetch.written != length:
                raise OSError(f"upstream closed after {fetch.written} of {length} bytes")
            self.count(kind, bytes_fetched=fetch.written)
            counted = True
            self.commit(fetch, kind, body, url)
        except Exception as exc:
            if not counted:
                self.count(kind, bytes_fetched=fetch.written)
            with fetch.cond:
                fetch.error = f"{type(exc).__name__}: {exc}"
                fetch.done = True
                fetch.cond.notify_all()
            try:
                fetch.temporary.unlink()
            except OSError:
                pass
        finally:
            with self.lock:
                self.inflight.pop((kind, key), None)

    def relay(self, fetch: Fetch, status: int, content_type: Optional[str], body: bytes) -> None:
        with fetch.cond:
            fetch.status = status
            fetch.content_type = content_type or "text/plain"
            fetch.relayed = body
            fetch.done = True
            fetch.cond.notify_all()

    def commit(self, fetch: Fetch, kind: str, body: Path, url: str) -> None:
        meta = {"size": fetch.written, "content_type": fetch.content_type, "fetched_at": time.time(), "url": url}
        staging = fetch.temporary.with_suffix(".meta.part")
        staging.write_text(json.dumps(meta), encoding="utf-8")
        with fetch.cond:
            with self.lock:
                try:
                    replaced = body.stat().st_size
                except OSError:
                    replaced = None
                os.replace(fetch.temporary, body)
                os.replace(staging, body.with_suffix(".meta"))
            with self.stats_lock:
                self.entries += replaced is None
                self.disk_bytes += fetch.written - (replaced or 0)
                self.dirty = True
            fetch.final = body
            fetch.readable = fetch.written
            fetch.done = True
            fetch.cond.notify_all()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "metacodes-download-cache"

    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.answer(True)

    def do_HEAD(self):
        self.answer(False)

    def refuse(self):
        self.close_connection = True
        self.plain(405, "only GET and HEAD are served\n", {"Allow": "GET, HEAD"})

    do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = refuse

    def plain(self, status: int, text: str, headers: Optional[Dict[str, str]] = None, content_type="text/plain; charset=utf-8",
              body: Optional[bytes] = None, with_body=True) -> None:
        payload = text.encode() if body is None else body
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if with_body and self.command != "HEAD":
            self.wfile.write(payload)

    def answer(self, with_body: bool) -> None:
        store: Store = self.server.store
        parts = urlsplit(self.path)
        if parts.path == STATS_PATH:
            self.plain(200, json.dumps(store.stats()), content_type="application/json")
            return
        kind, _, rest = parts.path.lstrip("/").partition("/")
        if kind not in store.routes:
            self.plain(404, "no such route\n")
            return
        if not safe_path(rest):
            self.plain(400, "invalid path\n")
            return
        if kind in ROUTED_ONLY and not ROUTED_ONLY[kind].match(rest):
            self.plain(404, "not served through the cache\n")
            return
        pattern = IMMUTABLE.get(kind)
        immutable = bool(pattern and pattern.search(rest))
        target = rest + ("?" + parts.query if parts.query else "")
        forwarded = {name: self.headers[name] for name in FORWARDED_HEADERS if self.headers.get(name)}
        key = target if immutable else target + "\n" + forwarded.get("Accept", "")
        store.count(kind, requests=1)
        try:
            entry, fetch, started = store.acquire(kind, key, store.routes[kind] + "/" + target, forwarded, immutable)
        except OSError as exc:
            store.count(kind, errors=1)
            self.plain(500, "cache directory failed: " + str(exc) + "\n", {"X-Metacodes-Cache": "error"})
            return
        try:
            if entry is not None:
                self.serve_entry(kind, entry, "hit", immutable, with_body)
                return
            with fetch.cond:
                while fetch.status is None and not fetch.done:
                    fetch.cond.wait()
            outcome = "miss" if started else "hit"
            if fetch.status == 200:
                if fetch.length is not None and not self.rewrites(kind, immutable, fetch.content_type):
                    self.follow(kind, fetch, outcome, with_body)
                    return
                with fetch.cond:
                    while not fetch.done:
                        fetch.cond.wait()
                entry = store.stale(kind, key) if fetch.error is None else None
                if entry is not None:
                    self.serve_entry(kind, entry, outcome, immutable, with_body, ranged=False)
                    return
            elif fetch.status is not None and fetch.status < 500:
                store.count(kind, misses=1)
                self.plain(fetch.status, "", {"X-Metacodes-Cache": "miss"}, fetch.content_type, fetch.relayed, with_body)
                return
            entry = store.stale(kind, key)
            if entry is not None:
                self.serve_entry(kind, entry, "stale", immutable, with_body)
                return
            store.count(kind, errors=1)
            if fetch.status is not None and fetch.status != 200:
                self.plain(fetch.status, "", {"X-Metacodes-Cache": "error"}, fetch.content_type, fetch.relayed, with_body)
            else:
                self.plain(502, "upstream failed: " + str(fetch.error) + "\n", {"X-Metacodes-Cache": "error"})
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        finally:
            if entry is not None:
                entry.handle.close()

    def rewrites(self, kind: str, immutable: bool, content_type: str) -> bool:
        return (kind in REWRITTEN_KINDS and not immutable and bool(self.headers.get("Host"))
                and content_type.lower().startswith(REWRITTEN_TYPES))

    def serve_entry(self, kind: str, entry: Entry, outcome: str, immutable: bool, with_body: bool, ranged=True) -> None:
        store: Store = self.server.store
        counted = {"hit": "hits", "miss": "misses", "stale": "stale"}[outcome]
        headers = {"X-Metacodes-Cache": outcome}
        if self.rewrites(kind, immutable, entry.content_type) and entry.size <= REWRITE_LIMIT:
            own = "http://" + self.headers["Host"] + "/" + kind
            payload = entry.handle.read().replace(store.routes[kind].encode(), own.encode())
            store.count(kind, **{counted: 1}, bytes_cached=len(payload) if outcome != "miss" and with_body else 0)
            self.plain(200, "", headers, entry.content_type, payload, with_body)
            return
        span = parse_range(self.headers.get("Range") or "", entry.size) if ranged and entry.size else None
        first, last = span if span else (0, entry.size - 1)
        length = last - first + 1
        self.send_response(206 if span else 200)
        self.send_header("Content-Type", entry.content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        if span:
            self.send_header("Content-Range", f"bytes {first}-{last}/{entry.size}")
        for name, value in headers.items():
            self.send_header(name, value)
        self.end_headers()
        sent = 0
        try:
            if with_body:
                entry.handle.seek(first)
                while sent < length:
                    chunk = entry.handle.read(min(CHUNK, length - sent))
                    if not chunk:
                        self.close_connection = True
                        break
                    self.wfile.write(chunk)
                    sent += len(chunk)
        finally:
            store.count(kind, **{counted: 1}, bytes_cached=sent if outcome != "miss" else 0)

    def follow(self, kind: str, fetch: Fetch, outcome: str, with_body: bool) -> None:
        store: Store = self.server.store
        self.send_response(200)
        self.send_header("Content-Type", fetch.content_type)
        self.send_header("Content-Length", str(fetch.length))
        self.send_header("X-Metacodes-Cache", outcome)
        self.end_headers()
        sent = 0
        try:
            if not with_body:
                return
            with fetch.cond:
                while fetch.written == 0 and not fetch.done:
                    fetch.cond.wait()
                if fetch.error is not None:
                    self.close_connection = True
                    return
                handle = open(fetch.final if fetch.final is not None else fetch.temporary, "rb")
            with handle:
                while sent < fetch.length:
                    with fetch.cond:
                        while fetch.readable <= sent and fetch.error is None:
                            fetch.cond.wait(1)
                        if fetch.error is not None:
                            self.close_connection = True
                            return
                        available = fetch.readable - sent
                    chunk = handle.read(min(CHUNK, available))
                    if not chunk:
                        self.close_connection = True
                        return
                    self.wfile.write(chunk)
                    sent += len(chunk)
        finally:
            store.count(kind, **{"misses" if outcome == "miss" else "hits": 1},
                        bytes_cached=sent if outcome == "hit" else 0)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 256


class DownloadCache:
    def __init__(self, directory, routes: Dict[str, str], bind="127.0.0.1", port=0, ttl: float = DEFAULT_TTL):
        self.store = Store(Path(directory), routes, ttl)
        self.server = Server((bind, port), Handler)
        self.server.store = self.store
        self.stopped = threading.Event()

    @property
    def port(self) -> int:
        return self.server.server_address[1]

    def start(self) -> "DownloadCache":
        threading.Thread(target=self.server.serve_forever, args=(0.1,), daemon=True).start()
        threading.Thread(target=self.persist, daemon=True).start()
        return self

    def persist(self) -> None:
        while not self.stopped.wait(STATS_INTERVAL):
            try:
                self.store.save_stats()
            except OSError:
                pass

    def close(self) -> None:
        if self.stopped.is_set():
            return
        self.stopped.set()
        self.server.shutdown()
        self.server.server_close()
        self.store.save_stats()

    def __enter__(self):
        return self.start()

    def __exit__(self, *_exc):
        self.close()


def parse_routes(values) -> Dict[str, str]:
    routes = {}
    for value in values or []:
        kind, _, url = value.partition("=")
        if kind not in KINDS or not re.match(r"^https?://", url):
            raise SystemExit("invalid --route " + value + " (expected <" + "|".join(KINDS) + ">=http(s)://...)")
        routes[kind] = url
    return routes


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="download_cache")
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--dir", required=True)
    parser.add_argument("--ttl", type=float, default=DEFAULT_TTL)
    parser.add_argument("--route", action="append")
    args = parser.parse_args(argv)
    cache = DownloadCache(args.dir, parse_routes(args.route), args.bind, args.port, args.ttl)
    done = threading.Event()
    for number in (signal.SIGTERM, signal.SIGINT):
        signal.signal(number, lambda *_args: done.set())
    cache.start()
    print(f"download cache listening on {args.bind}:{cache.port}", flush=True)
    done.wait()
    cache.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
