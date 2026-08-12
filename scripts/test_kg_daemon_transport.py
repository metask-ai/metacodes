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
        body = json.loads(raw)
        request_id = body["requestId"]
        command = body.get("command", "__markdown__")
        if command == "slow":
            time.sleep(1.0)
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
                response = self.response(body, True, 0, "nodes=1\nstorage_format_version=2\nschema_version=3\n", "", "none")
            ACTOR.receipts[request_id] = (raw, response)
            # The first write commits then loses the response. The client must
            # retry the byte-identical envelope and receive the replay receipt.
            if command == "add-node" and request_id not in ACTOR.dropped:
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


def run_probe(binary: str, url: str, action: str) -> str:
    result = subprocess.run(
        [binary, url, API_KEY, BUILD_ID, SCHEMA_DIGEST, action],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=15,
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
        assert "generation=1" in first and "replayed=true" in first and "commit=committed" in first
        assert "generation=2" in second and "replayed=true" in second and "commit=committed" in second
        assert "generation=2" in query and len(ACTOR.sessions) == 1
        assert "markdown_upload=observed" in markdown
        assert len(ACTOR.markdown_uploads) == 1
        assert ACTOR.markdown_uploads[0]["markdown"] == "# Uploaded\n\nprivate bytes\n"
        assert ACTOR.markdown_uploads[0]["sourceKey"] == "000000000000002a"
        assert "path" not in ACTOR.markdown_uploads[0]
        server.mode = "backpressure"  # type: ignore[attr-defined]
        assert "backpressure=observed" in run_probe(args.probe, url, "backpressure")
        assert "backpressure_write_no_commit=observed" in run_probe(args.probe, url, "backpressure-write")
        server.mode = "conflict"  # type: ignore[attr-defined]
        assert "conflict=observed" in run_probe(args.probe, url, "conflict")
        server.mode = "normal"  # type: ignore[attr-defined]
        assert "unauthorized_write_no_commit=observed" in run_probe(args.probe, url, "unauthorized-write")
        started = time.monotonic()
        assert "wall_clock_timeout=observed" in run_probe(args.probe, url, "timeout")
        assert time.monotonic() - started < 1.0
        server.shutdown()
        server.server_close()
        assert "unavailable_read=observed" in run_probe(args.probe, url, "unavailable-read")
        ambiguous = run_probe(args.probe, url, "unavailable-write")
        assert "ambiguous_write=observed" in ambiguous
        match = re.search(r"^request_id=([A-Za-z0-9_.:-]{1,128})$", ambiguous, re.MULTILINE)
        assert match is not None and match.group(1).startswith("metacodes-")
        print("kg_daemon_transport=pass")
        print(f"shared_generation={ACTOR.generation}")
        print("metacodes_processes=2")
        print(f"store_actor_instances=1")
        print(f"generation_bound_sessions={len(ACTOR.sessions)}")
        print(f"markdown_uploads={len(ACTOR.markdown_uploads)}")
        return 0
    finally:
        if thread.is_alive():
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    raise SystemExit(main())
