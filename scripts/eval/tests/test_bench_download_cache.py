from __future__ import annotations

import http.client
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from scripts.eval.harbor import download_cache
from scripts.eval.tests.posix_only import POSIX

REPO = Path(__file__).resolve().parents[3]


class Upstream:
    def __init__(self):
        self.pages = {}
        self.seen = []
        self.release = threading.Event()
        self.release.set()
        self.first_chunk_sent = threading.Event()
        upstream = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def do_GET(self):
                upstream.seen.append((self.path, self.headers.get("Accept"), self.headers.get("Accept-Encoding")))
                page = upstream.pages.get(self.path)
                if page is None:
                    self.reply(404, b"missing\n", {})
                    return
                status, body, headers = page() if callable(page) else page
                self.reply(status, body, headers)

            def reply(self, status, body, headers):
                self.send_response(status)
                chunked = headers.get("Transfer-Encoding") == "chunked"
                for name, value in headers.items():
                    self.send_header(name, value)
                if not chunked:
                    self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if chunked:
                    self.wfile.write(b"%x\r\n%s\r\n0\r\n\r\n" % (len(body), body))
                    return
                half = len(body) // 2
                self.wfile.write(body[:half])
                self.wfile.flush()
                upstream.first_chunk_sent.set()
                upstream.release.wait(10)
                self.wfile.write(body[half:])

        self.server = download_cache.Server(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def paths(self):
        return [path for path, _, _ in self.seen]

    def close(self):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()


@unittest.skipUnless(POSIX, "the cache runs in a Linux container and renames files that readers hold open")
class CacheFixture(unittest.TestCase):
    KINDS = ("pypi", "npm", "go", "conda", "rustup", "github")

    def setUp(self):
        self.upstream = Upstream()
        self.addCleanup(self.upstream.close)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name) / "cache"
        self.cache = self.open_cache()

    def open_cache(self, ttl=600.0):
        routes = {kind: f"{self.upstream.url}/{kind}-root" for kind in self.KINDS}
        cache = download_cache.DownloadCache(self.directory, routes, ttl=ttl).start()
        self.addCleanup(cache.close)
        return cache

    def get(self, path, headers=None, method="GET", cache=None):
        connection = http.client.HTTPConnection("127.0.0.1", (cache or self.cache).port, timeout=20)
        try:
            connection.request(method, path, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def stats(self, kind, cache=None):
        return json.loads(self.get("/_stats", cache=cache)[2])["routes"][kind]


class HitAndMissTest(CacheFixture):
    def test_a_second_request_is_served_without_asking_upstream(self):
        wheel = os.urandom(300_000)
        self.upstream.pages["/pypi-root/packages/ab/demo-1.0-py3-none-any.whl"] = (
            200, wheel, {"Content-Type": "application/zip"})
        first = self.get("/pypi/packages/ab/demo-1.0-py3-none-any.whl")
        second = self.get("/pypi/packages/ab/demo-1.0-py3-none-any.whl")
        self.assertEqual((first[0], first[2], first[1]["X-Metacodes-Cache"]), (200, wheel, "miss"))
        self.assertEqual((second[0], second[2], second[1]["X-Metacodes-Cache"]), (200, wheel, "hit"))
        self.assertEqual(second[1]["Content-Type"], "application/zip")
        self.assertEqual(self.upstream.paths(), ["/pypi-root/packages/ab/demo-1.0-py3-none-any.whl"])
        self.assertEqual(self.upstream.seen[0][2], "identity")
        row = self.stats("pypi")
        self.assertEqual({k: row[k] for k in download_cache.COUNTERS},
                         {"requests": 2, "hits": 1, "misses": 1, "stale": 0, "errors": 0,
                          "bytes_cached": len(wheel), "bytes_fetched": len(wheel)})
        self.assertEqual(row["upstream"], self.upstream.url + "/pypi-root")
        whole = json.loads(self.get("/_stats")[2])
        self.assertEqual((whole["schema_version"], whole["entries"], whole["disk_bytes"]), (1, 1, len(wheel)))

    def test_concurrent_requests_share_one_upstream_download_and_get_bytes_while_it_runs(self):
        archive = os.urandom(400_000)
        self.upstream.pages["/github-root/astral-sh/uv/releases/download/0.9.5/uv.tar.gz"] = (200, archive, {})
        self.upstream.release.clear()
        path = "/github/astral-sh/uv/releases/download/0.9.5/uv.tar.gz"
        early = http.client.HTTPConnection("127.0.0.1", self.cache.port, timeout=20)
        self.addCleanup(early.close)
        early.request("GET", path)
        response = early.getresponse()
        self.assertEqual(response.getheader("Content-Length"), str(len(archive)))
        self.assertEqual(response.read(1000), archive[:1000])
        self.assertFalse(self.upstream.release.is_set())
        with ThreadPoolExecutor(8) as pool:
            followers = [pool.submit(self.get, path) for _ in range(8)]
            time.sleep(0.3)
            self.upstream.release.set()
            results = [f.result() for f in followers]
        self.assertEqual(archive[:1000] + response.read(), archive)
        self.assertTrue(all(status == 200 and body == archive for status, _, body in results))
        self.assertEqual(len(self.upstream.seen), 1)
        row = self.stats("github")
        self.assertEqual((row["requests"], row["misses"], row["hits"], row["bytes_fetched"]), (9, 1, 8, len(archive)))

    def test_a_client_that_leaves_does_not_abort_the_download(self):
        blob = os.urandom(200_000)
        self.upstream.pages["/conda-root/pkgs/main/linux-64/numpy-2.0.conda"] = (200, blob, {})
        self.upstream.release.clear()
        connection = http.client.HTTPConnection("127.0.0.1", self.cache.port, timeout=20)
        connection.request("GET", "/conda/pkgs/main/linux-64/numpy-2.0.conda")
        connection.getresponse().read(10)
        connection.close()
        self.upstream.release.set()
        deadline = time.monotonic() + 10
        while json.loads(self.get("/_stats")[2])["entries"] < 1 and time.monotonic() < deadline:
            time.sleep(0.05)
        status, headers, body = self.get("/conda/pkgs/main/linux-64/numpy-2.0.conda")
        self.assertEqual((status, body, headers["X-Metacodes-Cache"]), (200, blob, "hit"))
        self.assertEqual(len(self.upstream.seen), 1)

    def test_a_redirect_is_followed_and_its_target_cached(self):
        asset = b"python-build" * 1000
        release = "/github-root/astral-sh/python-build-standalone/releases/download/20251014/cpython.tar.gz"
        self.upstream.pages[release] = (302, b"", {"Location": self.upstream.url + "/cdn/object-1"})
        self.upstream.pages["/cdn/object-1"] = (200, asset, {})
        path = "/github/astral-sh/python-build-standalone/releases/download/20251014/cpython.tar.gz"
        self.assertEqual(self.get(path)[2], asset)
        self.assertEqual(self.get(path)[2], asset)
        self.assertEqual(self.upstream.paths(), [release, "/cdn/object-1"])

    def test_a_response_without_a_length_is_served_complete_with_one(self):
        self.upstream.pages["/go-root/example.com/mod/@v/v1.2.3.mod"] = (
            200, b"module example.com/mod\n", {"Transfer-Encoding": "chunked"})
        status, headers, body = self.get("/go/example.com/mod/@v/v1.2.3.mod")
        self.assertEqual((status, body, headers["Content-Length"]), (200, b"module example.com/mod\n", "23"))
        self.assertEqual(self.get("/go/example.com/mod/@v/v1.2.3.mod")[1]["X-Metacodes-Cache"], "hit")

    def test_other_statuses_are_relayed_and_not_cached(self):
        status, headers, body = self.get("/pypi/simple/no-such-package/")
        self.assertEqual((status, body, headers["X-Metacodes-Cache"]), (404, b"missing\n", "miss"))
        self.upstream.pages["/pypi-root/simple/no-such-package/"] = (200, b"<a>now</a>", {"Content-Type": "text/plain"})
        self.assertEqual(self.get("/pypi/simple/no-such-package/")[2], b"<a>now</a>")
        self.assertEqual(len(self.upstream.seen), 2)
        self.assertEqual(json.loads(self.get("/_stats")[2])["entries"], 1)

    def test_an_upstream_that_closes_early_leaves_nothing_cached(self):
        class Short(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Length", "1000")
                self.end_headers()
                self.wfile.write(b"x" * 10)

        broken = ThreadingHTTPServer(("127.0.0.1", 0), Short)
        threading.Thread(target=broken.serve_forever, daemon=True).start()
        self.addCleanup(broken.server_close)
        self.addCleanup(broken.shutdown)
        cache = download_cache.DownloadCache(Path(self.tmp.name) / "short",
                                             {"npm": f"http://127.0.0.1:{broken.server_port}"}).start()
        self.addCleanup(cache.close)
        with self.assertRaises(http.client.IncompleteRead):
            self.get("/npm/pkg/-/pkg-1.0.0.tgz", cache=cache)
        deadline = time.monotonic() + 5
        while cache.store.inflight and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertEqual(cache.store.stats()["entries"], 0)
        self.assertEqual([p.name for p in (Path(self.tmp.name) / "short/objects").rglob("*") if p.is_file()], [])


class FreshnessTest(CacheFixture):
    def test_a_mutable_page_is_fetched_again_after_its_ttl_and_served_stale_when_upstream_fails(self):
        cache = self.open_cache(ttl=0.4)
        versions = iter([b"v1", b"v2"])
        state = {"fail": False}

        def page():
            if state["fail"]:
                return 503, b"down", {}
            return 200, next(versions), {"Content-Type": "text/plain"}

        self.upstream.pages["/go-root/example.com/mod/@v/list"] = page
        path = "/go/example.com/mod/@v/list"
        self.assertEqual(self.get(path, cache=cache)[2], b"v1")
        self.assertEqual(self.get(path, cache=cache)[1]["X-Metacodes-Cache"], "hit")
        time.sleep(0.5)
        self.assertEqual(self.get(path, cache=cache)[2], b"v2")
        time.sleep(0.5)
        state["fail"] = True
        status, headers, body = self.get(path, cache=cache)
        self.assertEqual((status, body, headers["X-Metacodes-Cache"]), (200, b"v2", "stale"))
        self.upstream.close()
        status, headers, body = self.get(path, cache=cache)
        self.assertEqual((status, body, headers["X-Metacodes-Cache"]), (200, b"v2", "stale"))
        row = self.stats("go", cache)
        self.assertEqual((row["requests"], row["hits"], row["misses"], row["stale"], row["errors"]), (5, 1, 2, 2, 0))

    def test_an_immutable_file_outlives_the_ttl_and_a_failing_upstream_without_a_copy_is_an_error(self):
        cache = self.open_cache(ttl=0.1)
        self.upstream.pages["/rustup-root/dist/2026-01-02/rustc.tar.xz"] = (200, b"rustc", {})
        self.upstream.pages["/rustup-root/dist/channel-rust-stable.toml"] = (503, b"down", {})
        self.assertEqual(self.get("/rustup/dist/2026-01-02/rustc.tar.xz", cache=cache)[2], b"rustc")
        time.sleep(0.3)
        self.assertEqual(self.get("/rustup/dist/2026-01-02/rustc.tar.xz", cache=cache)[1]["X-Metacodes-Cache"], "hit")
        self.assertEqual(len(self.upstream.seen), 1)
        status, headers, _ = self.get("/rustup/dist/channel-rust-stable.toml", cache=cache)
        self.assertEqual((status, headers["X-Metacodes-Cache"]), (503, "error"))
        self.assertEqual(self.stats("rustup", cache)["errors"], 1)

    def test_what_counts_as_immutable_per_kind(self):
        cases = {
            "pypi": ("packages/ab/cd/demo-1.0.tar.gz", "simple/demo/"),
            "npm": ("left-pad/-/left-pad-1.3.0.tgz", "left-pad"),
            "go": ("github.com/a/b/@v/v1.0.0.zip", "github.com/a/b/@v/list"),
            "conda": ("pkgs/main/linux-64/zlib-1.3.tar.bz2", "pkgs/main/linux-64/repodata.json"),
            "rustup": ("rustup/archive/1.28.2/x86_64-unknown-linux-gnu/rustup-init", "rustup/release-stable.toml"),
        }
        for kind, (kept, refreshed) in cases.items():
            with self.subTest(kind=kind):
                self.assertTrue(download_cache.IMMUTABLE[kind].search(kept))
                self.assertFalse(download_cache.IMMUTABLE[kind].search(refreshed))
        self.assertTrue(download_cache.IMMUTABLE["npm"].search("@scope/name/-/name-2.0.0.tgz"))
        self.assertFalse(download_cache.IMMUTABLE["go"].search("github.com/a/b/@v/master.info"))
        self.assertFalse(download_cache.IMMUTABLE["go"].search("github.com/a/b/@latest"))

    def test_a_mutable_page_is_cached_per_accept_header(self):
        def page():
            accept = self.upstream.seen[-1][1]
            return 200, (accept or "none").encode(), {"Content-Type": "text/plain"}

        self.upstream.pages["/conda-root/pkgs/main/noarch/repodata.json"] = page
        path = "/conda/pkgs/main/noarch/repodata.json"
        self.assertEqual(self.get(path, {"Accept": "application/json"})[2], b"application/json")
        self.assertEqual(self.get(path, {"Accept": "text/html"})[2], b"text/html")
        self.assertEqual(self.get(path, {"Accept": "application/json"})[1]["X-Metacodes-Cache"], "hit")
        self.assertEqual(len(self.upstream.seen), 2)


class ContentTest(CacheFixture):
    def test_a_range_is_answered_from_the_cached_file(self):
        wheel = bytes(range(256)) * 40
        self.upstream.pages["/pypi-root/packages/demo.whl"] = (200, wheel, {})
        cold = self.get("/pypi/packages/demo.whl", {"Range": "bytes=-100"})
        self.assertEqual((cold[0], cold[2]), (200, wheel))
        for header, expected, content_range in (
                ("bytes=10-19", wheel[10:20], f"bytes 10-19/{len(wheel)}"),
                ("bytes=-100", wheel[-100:], f"bytes {len(wheel) - 100}-{len(wheel) - 1}/{len(wheel)}"),
                (f"bytes={len(wheel) - 5}-", wheel[-5:], f"bytes {len(wheel) - 5}-{len(wheel) - 1}/{len(wheel)}")):
            with self.subTest(header=header):
                status, headers, body = self.get("/pypi/packages/demo.whl", {"Range": header})
                self.assertEqual((status, body, headers["Content-Range"]), (206, expected, content_range))
        head = self.get("/pypi/packages/demo.whl", method="HEAD")
        self.assertEqual((head[0], head[1]["Content-Length"], head[1]["Accept-Ranges"], head[2]),
                         (200, str(len(wheel)), "bytes", b""))
        self.assertEqual(len(self.upstream.seen), 1)

    def test_npm_metadata_names_tarballs_through_the_cache(self):
        root = self.upstream.url + "/npm-root"
        document = json.dumps({"name": "left-pad", "versions": {"1.3.0": {"dist": {
            "tarball": root + "/left-pad/-/left-pad-1.3.0.tgz"}}}}).encode()
        self.upstream.pages["/npm-root/left-pad"] = (200, document, {"Content-Type": "application/json"})
        self.upstream.pages["/npm-root/left-pad/-/left-pad-1.3.0.tgz"] = (200, root.encode() + b" tarball", {})
        own = f"http://127.0.0.1:{self.cache.port}/npm"
        for _ in range(2):
            status, headers, body = self.get("/npm/left-pad")
            self.assertEqual(status, 200)
            self.assertEqual(int(headers["Content-Length"]), len(body))
            tarball = json.loads(body)["versions"]["1.3.0"]["dist"]["tarball"]
            self.assertEqual(tarball, own + "/left-pad/-/left-pad-1.3.0.tgz")
        self.assertEqual(urllib.request.urlopen(tarball, timeout=10).read(), root.encode() + b" tarball")
        self.assertEqual(self.upstream.paths(), ["/npm-root/left-pad", "/npm-root/left-pad/-/left-pad-1.3.0.tgz"])

    def test_paths_that_escape_or_are_not_routed_never_reach_upstream(self):
        for path, expected in (("/pypi/../etc/passwd", 400), ("/pypi/simple/%2e%2e/%2e%2e/secret", 400),
                               ("/pypi/packages//demo.whl", 400), ("/npm/a%2f..%2f..%2fb", 400),
                               ("/pypi/packages/a%5cb", 400), ("/hf/gpt2/resolve/main/config.json", 404),
                               ("/unknown/x", 404), ("/github/astral-sh/uv.git/info/refs", 404),
                               ("/github/astral-sh/uv/archive/refs/heads/main.tar.gz", 404),
                               ("/github/astral-sh/uv/releases/latest/download/uv.tar.gz", 404)):
            with self.subTest(path=path):
                self.assertEqual(self.get(path)[0], expected)
        for method in ("POST", "PUT", "DELETE"):
            with self.subTest(method=method):
                status, headers, _ = self.get("/github/astral-sh/uv/git-upload-pack", method=method)
                self.assertEqual((status, headers["Allow"]), (405, "GET, HEAD"))
        self.assertEqual(self.upstream.seen, [])
        self.assertEqual(self.stats("pypi")["requests"], 0)

    def test_a_query_string_reaches_upstream_and_keys_the_entry(self):
        self.upstream.pages["/conda-root/search?q=a"] = (200, b"a", {})
        self.upstream.pages["/conda-root/search?q=b"] = (200, b"b", {})
        self.assertEqual([self.get("/conda/search?q=a")[2], self.get("/conda/search?q=b")[2],
                          self.get("/conda/search?q=a")[2]], [b"a", b"b", b"a"])
        self.assertEqual(self.upstream.paths(), ["/conda-root/search?q=a", "/conda-root/search?q=b"])


class RestartTest(CacheFixture):
    def test_entries_and_counters_survive_a_restart(self):
        self.upstream.pages["/pypi-root/packages/demo.whl"] = (200, b"wheel-bytes", {})
        self.get("/pypi/packages/demo.whl")
        self.get("/pypi/packages/demo.whl")
        leftover = self.directory / "objects/pypi/zz"
        leftover.mkdir(parents=True)
        (leftover / "half.0123.part").write_bytes(b"partial")
        self.cache.close()
        again = self.open_cache()
        self.assertFalse((leftover / "half.0123.part").exists())
        status, headers, body = self.get("/pypi/packages/demo.whl", cache=again)
        self.assertEqual((status, body, headers["X-Metacodes-Cache"]), (200, b"wheel-bytes", "hit"))
        whole = json.loads(self.get("/_stats", cache=again)[2])
        row = whole["routes"]["pypi"]
        self.assertEqual((row["requests"], row["hits"], row["misses"], row["bytes_fetched"]), (3, 2, 1, 11))
        self.assertEqual((whole["entries"], whole["disk_bytes"]), (1, 11))
        self.assertEqual(len(self.upstream.seen), 1)

    def test_another_upstream_never_gets_the_objects_of_the_previous_one(self):
        self.upstream.pages["/npm-root/left-pad/-/left-pad-1.3.0.tgz"] = (200, b"from the first registry", {})
        self.upstream.pages["/go-root/example.com/mod/@v/list"] = (200, b"v1.0.0\n", {"Content-Type": "text/plain"})
        tarball, listing = "/npm/left-pad/-/left-pad-1.3.0.tgz", "/go/example.com/mod/@v/list"
        self.assertEqual(self.get(tarball)[2], b"from the first registry")
        self.assertEqual(self.get(listing)[2], b"v1.0.0\n")
        self.cache.close()
        other = Upstream()
        self.addCleanup(other.close)
        other.pages["/npm-root/left-pad/-/left-pad-1.3.0.tgz"] = (200, b"from the second registry", {})
        routes = {kind: f"{other.url}/{kind}-root" for kind in self.KINDS}
        moved = download_cache.DownloadCache(self.directory, routes, ttl=0.0).start()
        self.addCleanup(moved.close)
        status, headers, body = self.get(tarball, cache=moved)
        self.assertEqual((status, body, headers["X-Metacodes-Cache"]), (200, b"from the second registry", "miss"))
        self.assertEqual(self.get(tarball, cache=moved)[1]["X-Metacodes-Cache"], "hit")
        self.assertEqual(other.paths(), ["/npm-root/left-pad/-/left-pad-1.3.0.tgz"])
        other.close()
        status, headers, _ = self.get(listing, cache=moved)
        self.assertEqual((status, headers["X-Metacodes-Cache"]), (502, "error"))
        moved.close()
        back = self.open_cache()
        self.assertEqual(self.get(tarball, cache=back)[2], b"from the first registry")
        self.assertEqual(len(self.upstream.seen), 2)

    def test_the_script_runs_alone_and_saves_its_counters_on_sigterm(self):
        self.upstream.pages["/pypi-root/packages/demo.whl"] = (200, b"standalone", {})
        directory = Path(self.tmp.name) / "standalone"
        script = REPO / "scripts/eval/harbor/download_cache.py"
        with tempfile.TemporaryDirectory() as elsewhere:
            process = subprocess.Popen([sys.executable, "-I", str(script), "--port", "0", "--dir", str(directory),
                                        "--route", "pypi=" + self.upstream.url + "/pypi-root"], cwd=elsewhere,
                                       stdout=subprocess.PIPE, text=True)
            self.addCleanup(process.kill)
            self.addCleanup(process.stdout.close)
            port = int(process.stdout.readline().rsplit(":", 1)[1])
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/pypi/packages/demo.whl", timeout=10) as response:
                self.assertEqual(response.read(), b"standalone")
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(10), 0)
        saved = json.loads((directory / "stats.json").read_text())["routes"]["pypi"]
        self.assertEqual((saved["requests"], saved["misses"], saved["bytes_fetched"]), (1, 1, 10))
        refused = subprocess.run([sys.executable, "-I", str(script), "--dir", str(directory), "--route", "hf=https://x"],
                                 capture_output=True, text=True)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("invalid --route", refused.stderr)


if __name__ == "__main__":
    unittest.main()
