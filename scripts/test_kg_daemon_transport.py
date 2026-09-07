#!/usr/bin/env python3
"""Exercise two Metacodes processes against one bounded mock StoreActor."""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import re
import subprocess
import threading
import time
import tempfile
import os


BUILD_ID = "sha256:" + "a" * 64
SCHEMA_DIGEST = "b" * 64
API_KEY = "transport-test-key"


class Actor:
    def __init__(self) -> None:
        self.generation = 0
        self.receipts: dict[str, tuple[bytes, dict]] = {}
        self.dropped: set[str] = set()
        self.sessions: set[str] = set()
        self.lock = threading.Lock()
        self.markdown_uploads: list[dict] = []
        self.request_count = 0


ACTOR = Actor()


def metadata() -> dict:
    return {
        "protocolVersion": 2,
        "schemaMode": "server-canonical",
        "schemaDigest": SCHEMA_DIGEST,
        "controlPlaneVersion": 1,
        "implementation": "tinykg-web",
        "implementationVersion": "test",
        "buildId": BUILD_ID,
        "capabilities": ["task-hierarchy-canonical-read-v1"],
        "engine": {
            "implementation": "tinykg-cli",
            "version": "test",
            "binarySha256": "c" * 64,
            "metadataValid": True,
        },
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def do_POST(self) -> None:  # noqa: N802
        if self.headers.get("x-api-key") != API_KEY:
            self.send_response(401)
            self.end_headers()
            return
        raw = self.rfile.read(int(self.headers.get("content-length", "0")))
        ACTOR.request_count += 1
        body = json.loads(raw)
        request_id = body["requestId"]
        command = body.get("command", "__markdown__")
        if command == "add-node" and self.server.mode == "service-unavailable":  # type: ignore[attr-defined]
            self.send_response(503)
            self.end_headers()
            return
        if command == "slow":
            # The stall the "timeout" scenario must NOT wait out: the probe's
            # 100 ms client deadline has to return long before this. Keep it
            # equal to the end-to-end bound asserted in main() (#105).
            time.sleep(5.0)
        if command in {"stats", "add-node"} and self.server.mode == "backpressure":  # type: ignore[attr-defined]
            response = self.response(body, False, -3, "", "tinykgd: error: DaemonQueueFull\n", "none")
            return self.send_json(response)
        if command == "stats" and self.server.mode == "conflict":  # type: ignore[attr-defined]
            response = self.response(body, False, 2, "", "tinykgd: error: RequestIdConflict\n", "none")
            return self.send_json(response)
        with ACTOR.lock:
            previous = ACTOR.receipts.get(request_id)
            if previous:
                fingerprint, response = previous
                if fingerprint != raw:
                    response = self.response(body, False, 2, "", "tinykgd: error: RequestIdConflict\n", "none")
                else:
                    response = {**response, "replayed": True}
                return self.send_json(response)
            if command == "add-node":
                ACTOR.generation += 1
                response = self.response(body, True, 0, f"node {ACTOR.generation}\n", "", "committed")
            elif command == "query":
                session_id = body.get("sessionId")
                if not session_id:
                    response = self.response(body, False, 2, "", "missing session\n", "none")
                else:
                    ACTOR.sessions.add(session_id)
                    response = self.response(body, True, 0, "ok\n", "", "none")
                    response["session"] = {
                        "sessionId": session_id,
                        "generation": ACTOR.generation,
                        "expiresAtMs": 1,
                    }
            elif command == "__markdown__":
                ACTOR.generation += 1
                ACTOR.markdown_uploads.append(body)
                response = self.response(body, True, 0, "import_md_doc document=42 nodes_imported=1\n", "", "committed")
            else:
                response = self.response(body, True, 0, "nodes=1\nstorage_format_version=3\nschema_version=3\n", "", "none")
                if command == "schema-drift":
                    response["schemaDigest"] = "d" * 64
            ACTOR.receipts[request_id] = (raw, response)
            # An acknowledged write can lose its response. Metacodes must not
            # let the generic transport replay it; the transaction controller
            # first records the ambiguous request and re-observes state.
            if command == "add-node" and self.server.mode == "drop-write-response":  # type: ignore[attr-defined]
                ACTOR.dropped.add(request_id)
                self.connection.shutdown(2)
                self.connection.close()
                return
        self.send_json(response)

    def response(self, body: dict, ok: bool, code: int, stdout: str, stderr: str, commit: str) -> dict:
        return {
            **metadata(),
            "requestId": body["requestId"],
            "ok": ok,
            "code": code,
            "stdout": stdout,
            "stderr": stderr,
            "generation": ACTOR.generation,
            "commitState": commit,
            "replayed": False,
        }

    def send_json(self, value: dict) -> None:
        payload = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def run_probe(
    binary: str,
    url: str,
    action: str,
    *,
    env: dict[str, str] | None = None,
    cwd: str | None = None,
) -> str:
    child_env = dict(os.environ)
    for key in (
        "METACODES_KG_CONFIG",
        "METACODES_KG_URL",
        "METACODES_KG_API_KEY",
        "METACODES_KG_EXPECTED_BUILD_ID",
        "METACODES_KG_EXPECTED_SCHEMA_DIGEST",
        # 这三个决定 KgClient 走 CLI 还是 daemon。不清掉的话,开发机上一个
        # `METACODES_KG_TRANSPORT=cli-exclusive` 就能让整套用例红掉——实测连既有的
        # client-config 都会失败。探针断言的是代码行为,不该受宿主环境左右。
        "METACODES_KG_TRANSPORT",
        "METACODES_KG_STORE",
        "METACODES_KG_BIN",
        "TINYKG_REMOTE_CONFIG",
        "TINYKG_REMOTE_URL",
        "TINYKG_API_KEY",
        "TINYKG_REMOTE_EXPECTED_BUILD_ID",
    ):
        child_env.pop(key, None)
    child_env.update(env or {})
    # `cwd` 会改子进程的工作目录,而 --probe 传进来的是相对路径 → 必须先绝对化,
    # 否则换了 cwd 就找不到探针二进制。
    result = subprocess.run(
        [os.path.abspath(binary), url, API_KEY, BUILD_ID, SCHEMA_DIGEST, action],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=15,
        env=child_env,
        cwd=cwd,
    )
    return result.stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.mode = "normal"  # type: ignore[attr-defined]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_port}"
    try:
        first = run_probe(args.probe, url, "write")
        second = run_probe(args.probe, url, "write")
        query = run_probe(args.probe, url, "query")
        markdown = run_probe(args.probe, url, "markdown")
        assert "generation=1" in first and "replayed=false" in first and "commit=committed" in first
        assert "generation=2" in second and "replayed=false" in second and "commit=committed" in second
        assert "generation=2" in query and len(ACTOR.sessions) == 1
        assert "markdown_upload=observed" in markdown
        assert len(ACTOR.markdown_uploads) == 1
        assert ACTOR.markdown_uploads[0]["markdown"] == "# Uploaded\n\nprivate bytes\n"
        assert ACTOR.markdown_uploads[0]["sourceKey"] == "000000000000002a"
        assert "path" not in ACTOR.markdown_uploads[0]
        with tempfile.TemporaryDirectory() as config_dir:
            config_path = os.path.join(config_dir, "metacodes-daemon.json")
            with open(config_path, "w", encoding="utf-8") as handle:
                json.dump({"url": url, "api_key": API_KEY, "expected_build_id": BUILD_ID}, handle)
            os.chmod(config_path, 0o600)
            skill_config_path = os.path.join(config_dir, "tinykg-skill-remote.json")
            with open(skill_config_path, "w", encoding="utf-8") as handle:
                json.dump({
                    "url": "http://127.0.0.1:1",
                    "api_key": "must-not-be-used",
                    "expected_build_id": "sha256:" + "f" * 64,
                }, handle)
            os.chmod(skill_config_path, 0o600)
            configured = run_probe(
                args.probe, url, "client-config",
                env={
                    "METACODES_KG_CONFIG": config_path,
                    "TINYKG_REMOTE_CONFIG": skill_config_path,
                },
            )
            assert "metacodes_local_daemon_config=ready" in configured
            before_skill_only = ACTOR.request_count
            skill_only = run_probe(
                args.probe, url, "client-config-degraded",
                env={"TINYKG_REMOTE_CONFIG": skill_config_path},
            )
            assert "unsafe_local_daemon_config=degraded" in skill_only
            assert ACTOR.request_count == before_skill_only
            before_invalid = ACTOR.request_count
            with open(config_path, "w", encoding="utf-8") as handle:
                handle.write('{"url":')
            degraded = run_probe(
                args.probe, url, "client-config-degraded",
                env={"METACODES_KG_CONFIG": config_path},
            )
            assert "unsafe_local_daemon_config=degraded" in degraded
            assert ACTOR.request_count == before_invalid
            os.unlink(config_path)
            missing = run_probe(
                args.probe, url, "client-config-degraded",
                env={"METACODES_KG_CONFIG": config_path},
            )
            assert "unsafe_local_daemon_config=degraded" in missing
            assert ACTOR.request_count == before_invalid
        # issue #30: an unconfigured client cloned for a worker thread must not be
        # promoted to CLI-exclusive and must not materialise a Store. The probe
        # asserts the in-process invariants; the empty cwd afterwards is the
        # observable one — the original defect wrote `daemon-owned/` and
        # `daemon-owned.tinykg-daemon.lock` into whatever directory the process
        # happened to be in, which for the e2e suite was the git worktree.
        before_clone = ACTOR.request_count
        with tempfile.TemporaryDirectory() as probe_cwd:
            cloned = run_probe(
                args.probe, url, "unconfigured-clone-no-store", cwd=probe_cwd,
            )
            assert "unconfigured_clone_owns_no_store=pass" in cloned
            leaked = sorted(os.listdir(probe_cwd))
            assert leaked == [], f"unconfigured clone leaked store artifacts into cwd: {leaked}"
        assert ACTOR.request_count == before_clone
        server.mode = "backpressure"  # type: ignore[attr-defined]
        assert "backpressure=observed" in run_probe(args.probe, url, "backpressure")
        assert "backpressure_write_no_commit=observed" in run_probe(args.probe, url, "backpressure-write")
        server.mode = "conflict"  # type: ignore[attr-defined]
        assert "conflict=observed" in run_probe(args.probe, url, "conflict")
        server.mode = "normal"  # type: ignore[attr-defined]
        assert "unauthorized_write_no_commit=observed" in run_probe(args.probe, url, "unauthorized-write")
        assert "shared_schema_pin=observed" in run_probe(args.probe, url, "schema-drift-across-clone")
        server.mode = "drop-write-response"  # type: ignore[attr-defined]
        ambiguous_once = run_probe(args.probe, url, "ambiguous-blocks-writes")
        assert "ambiguous_write_blocked=observed" in ambiguous_once
        # One semantic attempt crossed the actor; a forbidden transport replay
        # would advance this by two or mark the receipt replayed.
        assert ACTOR.generation == 4
        server.mode = "normal"  # type: ignore[attr-defined]
        # Proof that the client deadline (100 ms) fired instead of waiting out
        # the server's "slow" stall: the whole probe process (spawn, connect,
        # timeout, exit) returns before that stall would have ended. Stall and
        # bound are both 5 s (Handler.do_POST) so process-spawn jitter on a
        # loaded shared CI runner cannot fake a failure; at 1 s it did (#105).
        # scripts/rule_control.py pins both literals as declared evidence.
        started = time.monotonic()
        assert "wall_clock_timeout=observed" in run_probe(args.probe, url, "timeout")
        assert time.monotonic() - started < 5.0
        server.shutdown()
        server.server_close()
        assert "unavailable_read=observed" in run_probe(args.probe, url, "unavailable-read")
        ambiguous = run_probe(args.probe, url, "unavailable-write")
        assert "ambiguous_write=observed" in ambiguous
        match = re.search(r"^request_id=([A-Za-z0-9_.:-]{1,128})$", ambiguous, re.MULTILINE)
        assert match is not None and match.group(1).startswith("metacodes-")
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.mode = "service-unavailable"  # type: ignore[attr-defined]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_port}"
        unavailable = run_probe(args.probe, url, "service-unavailable-write")
        assert "ambiguous_write=observed" in unavailable
        assert re.search(r"^request_id=metacodes-[A-Za-z0-9_.:-]+$", unavailable, re.MULTILINE)
        server.shutdown()
        server.server_close()
        print("kg_daemon_transport=pass")
        print(f"shared_generation={ACTOR.generation}")
        print("metacodes_processes=2")
        print(f"store_actor_instances=1")
        print(f"generation_bound_sessions={len(ACTOR.sessions)}")
        print("shared_schema_pin=pass")
        print(f"markdown_uploads={len(ACTOR.markdown_uploads)}")
        print("write_transport_retries=0")
        print("ambiguous_write_latch=pass")
        print("metacodes_local_daemon_config=pass")
        print("skill_remote_config_ignored=pass")
        return 0
    finally:
        if thread.is_alive():
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    raise SystemExit(main())
