#!/usr/bin/env python3
"""Run the zero-paid Mac ontology-to-rule host chain against loopback services."""

from __future__ import annotations

import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from typing import Any


BUILD_HEX = "c" * 64
BUILD_ID = "sha256:" + BUILD_HEX
SCHEMA_DIGEST = "b" * 64
API_KEY = "mac-pilot-tinykg-non-secret"
REVISION = "d" * 64
TASK_CAPABILITY = "task-hierarchy-canonical-read-v1"
ONTOLOGY_CAPABILITY = "tinykg-ontology-rule-snapshot-v1"
SUMMARY = "A governed ontology is context, not promotion authority."
FALSIFIER = "A held-out replay observes ontology context self-authorizing promotion."


def _canonical(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _sha256(payload: bytes | str) -> str:
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _metadata(request_id: str) -> dict[str, Any]:
    return {
        "protocolVersion": 2,
        "schemaMode": "server-canonical",
        "schemaDigest": SCHEMA_DIGEST,
        "controlPlaneVersion": 1,
        "implementation": "tinykg-web",
        "implementationVersion": "mac-pilot",
        "buildId": BUILD_ID,
        "capabilities": [TASK_CAPABILITY, ONTOLOGY_CAPABILITY],
        "engine": {
            "implementation": "tinykg-cli",
            "version": "mac-pilot",
            "binarySha256": BUILD_HEX,
            "metadataValid": True,
        },
        "requestId": request_id,
    }


class PilotState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.commands: list[dict[str, Any]] = []
        self.provider_bodies: list[dict[str, Any]] = []


STATE = PilotState()


def _ontology_snapshot(args: list[str]) -> bytes:
    if len(args) != 9 or args[1] != "--project-sha256" or args[3] != "--project-key":
        raise ValueError("invalid ontology-rule-snapshot arguments")
    if args[5:] != ["--max-items", "48", "--max-chars", "200000"]:
        raise ValueError("ontology-rule-snapshot bounds drifted")
    project_id = int(args[0])
    project_sha256 = args[2]
    project_key = args[4]
    provenance = [{
        "kind": "user_correction",
        "node_id": 17,
        "evidence_sha256": "a" * 64,
    }]
    provenance_body = {
        "schema_version": "tinykg-ontology-provenance-v1",
        "refs": provenance,
    }
    ontology = [{
        "node_id": 42,
        "kind": "concept",
        "scope": "project:metacodes/control-plane",
        "authority": "agent_hypothesis",
        "summary": SUMMARY,
        "summary_sha256": _sha256(SUMMARY),
        "provenance": provenance,
        "provenance_sha256": _sha256(_canonical(provenance_body)),
        "falsifier": FALSIFIER,
        "falsifier_sha256": _sha256(FALSIFIER),
        "contradicted": False,
        "deprecated": False,
        "retrieval_excluded": False,
    }]
    body = {
        "schema_version": ONTOLOGY_CAPABILITY,
        "capability": ONTOLOGY_CAPABILITY,
        "tinykg_build_id": BUILD_ID,
        "project_node_id": project_id,
        "project_sha256": project_sha256,
        "project_key": project_key,
        "revision": REVISION,
        "bounded": True,
        "truncated": False,
        "max_items": 48,
        "max_chars": 200000,
        "used_chars": len(SUMMARY.encode()) + len(FALSIFIER.encode()),
        "ontology": ontology,
    }
    return _canonical({**body, "snapshot_sha256": _sha256(_canonical(body))})


class TinyKgHandler(BaseHTTPRequestHandler):
    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/api/run" or self.headers.get("x-api-key") != API_KEY:
            self.send_response(401)
            self.end_headers()
            return
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", "0"))))
        command = body["command"]
        args = body.get("args") or []
        required = body.get("requiredCapabilities") or []
        if TASK_CAPABILITY not in required:
            self.send_error(400, "missing task capability")
            return
        if command == "ontology-rule-snapshot" and ONTOLOGY_CAPABILITY not in required:
            self.send_error(400, "missing ontology snapshot capability")
            return
        if command != "ontology-rule-snapshot" and ONTOLOGY_CAPABILITY in required:
            self.send_error(400, "ontology snapshot capability leaked to ordinary command")
            return
        with STATE.lock:
            STATE.commands.append(body)
        stdout = ""
        if command == "store-info":
            stdout = "nodes=2\nstorage_format_version=2\nschema_version=3\n"
        elif command == "find":
            if len(args) != 2 or args[0] != "project":
                self.send_error(400, "invalid find")
                return
            stdout = f"7\tproject\t{args[1]}\n"
        elif command == "ontology-rule-snapshot":
            try:
                stdout = _ontology_snapshot(args).decode("utf-8")
            except (ValueError, KeyError) as exc:
                self.send_error(400, str(exc))
                return
        else:
            self.send_error(400, "unexpected command")
            return
        response = {
            **_metadata(body["requestId"]),
            "ok": True,
            "code": 0,
            "stdout": stdout,
            "stderr": "",
            "generation": 0,
            "commitState": "none",
            "replayed": False,
        }
        payload = _canonical(response)
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def _proposal() -> str:
    lean = (
        'def spec : RuleSpec := { targetTool := "Write", targetScope := .existingFile, '
        "denyTarget := true, maxInputBytes := 8192, maxAgentDepth := 4, "
        "authoritativeOnly := true, effectRequirement := .none }\n"
        "theorem spec_valid : valid spec = true := by rfl"
    )
    return json.dumps({
        "schema_version": "metacodes-rule-author-response-v1",
        "decision": "propose",
        "reason": "A narrow candidate captures the authenticated correction.",
        "invariant": "Ontology context never authorizes its own promotion.",
        "falsifier": "A held-out replay observes context self-authorizing promotion.",
        "rule_spec": {
            "target_tool": "Write",
            "target_scope": "existing_file",
            "deny_target": True,
            "max_input_bytes": 8192,
            "max_agent_depth": 4,
            "authoritative_only": True,
            "effect_requirement": "none",
        },
        "lean_source": lean,
    }, ensure_ascii=False, separators=(",", ":"))


def _sse() -> bytes:
    text = json.dumps(_proposal(), ensure_ascii=False)
    rows = [
        'data: {"type":"message_start","message":{"id":"msg_mac_pilot","role":"assistant","model":"mac-pilot-rule-author","usage":{"input_tokens":10,"output_tokens":0,"cache_read_input_tokens":7,"cache_creation_input_tokens":3}}}',
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
        f'data: {{"type":"content_block_delta","index":0,"delta":{{"type":"text_delta","text":{text}}}}}',
        'data: {"type":"content_block_stop","index":0}',
        'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":80}}',
        'data: {"type":"message_stop"}',
    ]
    return ("\n\n".join(rows) + "\n\n").encode("utf-8")


class ProviderHandler(BaseHTTPRequestHandler):
    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def do_POST(self) -> None:  # noqa: N802
        raw = self.rfile.read(int(self.headers.get("content-length", "0")))
        body = json.loads(raw)
        with STATE.lock:
            STATE.provider_bodies.append(body)
        payload = _sse()
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def _start(handler: type[BaseHTTPRequestHandler]) -> tuple[ThreadingHTTPServer, threading.Thread]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


def run(probe: Path, output: Path) -> dict[str, Any]:
    if output.exists() or output.is_symlink():
        raise RuntimeError(f"pilot output already exists: {output}")
    output.mkdir(parents=True, mode=0o700)
    home = output / "home/.metacodes/kg"
    home.mkdir(parents=True, mode=0o700)
    kg_server, kg_thread = _start(TinyKgHandler)
    provider_server, provider_thread = _start(ProviderHandler)
    try:
        config = home / "daemon.json"
        config.write_text(json.dumps({
            "url": f"http://127.0.0.1:{kg_server.server_port}",
            "api_key": API_KEY,
            "expected_build_id": BUILD_ID,
            "expected_schema_digest": SCHEMA_DIGEST,
        }, separators=(",", ":")), encoding="utf-8")
        config.chmod(0o600)
        env = {
            name: value
            for name, value in os.environ.items()
            if not name.startswith("METACODES_KG_") and not name.startswith("TINYKG_")
        }
        completed = subprocess.run(
            [str(probe), f"http://127.0.0.1:{provider_server.server_port}/v1/messages", str(output)],
            env=env,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
        )
        if completed.returncode != 0:
            raise RuntimeError(f"pilot child failed: {completed.stderr.strip()}")
        result = json.loads(completed.stdout)
        with STATE.lock:
            commands = list(STATE.commands)
            provider_bodies = list(STATE.provider_bodies)
        counts: dict[str, int] = {}
        for row in commands:
            counts[row["command"]] = counts.get(row["command"], 0) + 1
        if counts != {"store-info": 1, "find": 3, "ontology-rule-snapshot": 6}:
            raise RuntimeError(f"unexpected TinyKG command trace: {counts}")
        if len(provider_bodies) != 1:
            raise RuntimeError(f"expected one provider request, got {len(provider_bodies)}")
        provider_body = provider_bodies[0]
        encoded_provider = _canonical(provider_body)
        if "tools" in provider_body or b"ACTOR_SECRET_CACHE_PREFIX" in encoded_provider:
            raise RuntimeError("rule-author request leaked actor tools or context")
        if not result.get("candidate_created") or not result.get("candidate_binding_verified"):
            raise RuntimeError("source-bound candidate was not verified")
        receipt = {
            **result,
            "mac_host_process": True,
            "provider_requests": len(provider_bodies),
            "tinykg_command_counts": counts,
            "tinykg_atomic_command_simulated": True,
            "external_network_requests": 0,
            "remote_tinykg_skill_touched": False,
            "provider_request_sha256": _sha256(encoded_provider),
        }
        report = output / "mac-pilot-receipt.json"
        report.write_text(json.dumps(receipt, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        report.chmod(0o600)
        return receipt
    finally:
        kg_server.shutdown()
        kg_server.server_close()
        provider_server.shutdown()
        provider_server.server_close()
        kg_thread.join(timeout=5)
        provider_thread.join(timeout=5)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    temporary: tempfile.TemporaryDirectory[str] | None = None
    if args.output is None:
        temporary = tempfile.TemporaryDirectory(prefix="metacodes-mac-rule-pilot-")
        output = Path(temporary.name) / "run"
    else:
        output = args.output.resolve()
    try:
        receipt = run(args.probe.resolve(strict=True), output)
        print(json.dumps(receipt, ensure_ascii=False, sort_keys=True))
        return 0
    finally:
        if temporary is not None:
            temporary.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
