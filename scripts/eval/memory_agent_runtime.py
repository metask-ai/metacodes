"""Execute frozen memory schedules through the real metacodes agent runtime.

This is deliberately a host-side runner, not a replay synthesizer.  Every row
starts the native ``metacodes`` binary, supplies execution metadata over an
inherited read-only fd, captures native events through an anonymous fd, and
records the provider cassette.  TinyKG arms use a hash-pinned binary and a
fresh store below the owned run directory; the TinyKG skill harness is never
imported or executed.

The built-in provider is a deterministic *wiring smoke*.  It calls the real
KgRecall/KgContext tools and then returns a fixed negative answer.  It is useful
for proving the execution boundary at zero paid cost, but is intentionally not
memory-quality evidence.
"""

from __future__ import annotations

import hashlib
import http.server
import json
import math
import os
import platform
import re
import socketserver
import stat
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, MutableMapping, Sequence, Tuple

from .e2e_adapter import (
    NATIVE_EVENT_SCHEMA_VERSION,
    _native_trace_metrics,
    finalize_evaluation_fd,
)
from .memory_benchmark import PROTOCOL_ID, file_sha256
from .memory_procedural_adapter import (
    evaluate_workspace,
    validate_validator_bundle,
)
from .memory_replay import (
    REPLAY_SCHEMA_VERSION,
    _artifact_tree_digest,
    load_manifest,
    replay_observations,
)
from .memory_tinykg_local import (
    LocalTinyKg,
    _batch_bytes,
    _store_info,
    _tree_digest,
    build_case_batch,
)
from .model import ValidationError, stable_json


RUNTIME_RECEIPT_SCHEMA_VERSION = 2
RUNTIME_METADATA_SCHEMA_VERSION = NATIVE_EVENT_SCHEMA_VERSION
SCRIPTED_PROVIDER_ID = "metacodes-memory-scripted-wiring-v1"
ARM_TO_RUNTIME = {
    "no_memory": "codex_style",
    "codex_style": "codex_style",
    "markdown_memory": "claude_style",
    "claude_style": "claude_style",
    "tinykg_lexical": "tinykg",
    "tinykg": "tinykg",
}
SAFE_STOP_REASONS = frozenset({"end_turn", "max_turns", "tool_loop", "budget"})
HEX64 = re.compile(r"^[0-9a-f]{64}$")


def _fail(where: str, message: str) -> None:
    raise ValidationError(f"{where}: {message}")


def _canonical_sha256(value: Any) -> str:
    return hashlib.sha256(stable_json(value).encode("utf-8")).hexdigest()


def _hash_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _hash_text(value: str) -> str:
    return _hash_bytes(value.encode("utf-8"))


def _safe_component(value: str) -> str:
    prefix = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")[:40] or "run"
    return f"{prefix}-{_hash_text(value)[:12]}"


def _inside(child: Path, parent: Path, where: str) -> Path:
    resolved_child = child.expanduser().resolve()
    resolved_parent = parent.expanduser().resolve()
    try:
        resolved_child.relative_to(resolved_parent)
    except ValueError as exc:
        raise ValidationError(f"{where}: path escapes the owned run directory") from exc
    return resolved_child


def _write_new(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags, 0o600)
    except OSError as exc:
        raise ValidationError(f"cannot create fresh runtime artifact {path}: {exc}") from exc
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(fd, payload[offset:])
            if written <= 0:
                raise OSError("short write")
            offset += written
        os.fsync(fd)
    except BaseException:
        try:
            path.unlink()
        except OSError:
            pass
        raise
    finally:
        os.close(fd)


def _load_json(path: Path, label: str) -> Mapping[str, Any]:
    def reject_duplicates(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                _fail(label, f"duplicate field {key!r}")
            result[key] = value
        return result

    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicates)
    except ValidationError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValidationError(f"cannot read {label} {path}: {exc}") from exc
    if not isinstance(value, dict):
        _fail(label, "expected an object")
    return value


def _xxhash64(data: bytes, seed: int = 0) -> int:
    """Small dependency-free XXH64 implementation matching Zig XxHash64."""

    mask = (1 << 64) - 1
    p1, p2 = 11400714785074694791, 14029467366897019727
    p3, p4, p5 = 1609587929392839161, 9650029242287828579, 2870177450012600261

    def rotl(value: int, bits: int) -> int:
        return ((value << bits) | (value >> (64 - bits))) & mask

    def lane(value: int, word: int) -> int:
        value = (value + word * p2) & mask
        value = rotl(value, 31)
        return (value * p1) & mask

    length = len(data)
    offset = 0
    if length >= 32:
        v1 = (seed + p1 + p2) & mask
        v2 = (seed + p2) & mask
        v3 = seed & mask
        v4 = (seed - p1) & mask
        limit = length - 32
        while offset <= limit:
            v1 = lane(v1, int.from_bytes(data[offset : offset + 8], "little"))
            v2 = lane(v2, int.from_bytes(data[offset + 8 : offset + 16], "little"))
            v3 = lane(v3, int.from_bytes(data[offset + 16 : offset + 24], "little"))
            v4 = lane(v4, int.from_bytes(data[offset + 24 : offset + 32], "little"))
            offset += 32
        value = (rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18)) & mask
        for item in (v1, v2, v3, v4):
            mixed = lane(0, item)
            value ^= mixed
            value = (value * p1 + p4) & mask
    else:
        value = (seed + p5) & mask
    value = (value + length) & mask
    while offset + 8 <= length:
        mixed = lane(0, int.from_bytes(data[offset : offset + 8], "little"))
        value ^= mixed
        value = (rotl(value, 27) * p1 + p4) & mask
        offset += 8
    if offset + 4 <= length:
        value ^= (int.from_bytes(data[offset : offset + 4], "little") * p1) & mask
        value &= mask
        value = (rotl(value, 23) * p2 + p3) & mask
        offset += 4
    while offset < length:
        value ^= (data[offset] * p5) & mask
        value &= mask
        value = (rotl(value, 11) * p1) & mask
        offset += 1
    value ^= value >> 33
    value = (value * p2) & mask
    value ^= value >> 29
    value = (value * p3) & mask
    value ^= value >> 32
    return value & mask


def _project_domain(project_root: Path) -> str:
    resolved = str(project_root.resolve())
    return f"{project_root.name or 'root'}-{_xxhash64(resolved.encode('utf-8')):016x}"[: len(project_root.name or 'root') + 9]


def _agent_batch(
    batch: bytes,
    logical_ids: Mapping[int, str],
    root_node_id: int,
    domain: str,
) -> Tuple[bytes, Dict[int, str], int, Mapping[str, int]]:
    """Add the exact project-containment root used by KgClient recall."""

    records = [json.loads(line) for line in batch.decode("utf-8").splitlines() if line]
    if not records or records[0] != {"version": 1}:
        _fail("memory agent TinyKG batch", "invalid version header")
    nodes: List[Mapping[str, Any]] = []
    edges: List[Mapping[str, Any]] = []
    for record in records[1:]:
        shifted = dict(record)
        if shifted.get("op") == "node":
            shifted["id"] = int(shifted["id"]) + 1
            nodes.append(shifted)
        elif shifted.get("op") == "edge":
            shifted["id"] = int(shifted["id"]) + 1
            shifted["src"] = int(shifted["src"]) + 1
            shifted["dst"] = int(shifted["dst"]) + 1
            edges.append(shifted)
        else:
            _fail("memory agent TinyKG batch", "unsupported record")
    project = {"op": "node", "id": 1, "kind": "project", "name": domain}
    next_edge = max((int(edge["id"]) for edge in edges), default=0) + 1
    containment: List[Mapping[str, Any]] = []
    for node in nodes:
        containment.append(
            {"op": "edge", "id": next_edge, "src": 1, "rel": "contain", "dst": node["id"]}
        )
        next_edge += 1
    shifted_logical = {node_id + 1: value for node_id, value in logical_ids.items()}
    counts = {
        "nodes": 1 + len(nodes),
        "edges": len(edges) + len(containment),
        "abstraction_nodes": sum(node.get("kind") == "concept" for node in nodes),
    }
    return _batch_bytes([project, *nodes], [*edges, *containment]), shifted_logical, root_node_id + 1, counts


def _empty_project_batch(domain: str) -> bytes:
    return _batch_bytes(
        [{"op": "node", "id": 1, "kind": "project", "name": domain}],
        [],
    )


def _text_sse(text: str, request_id: int) -> bytes:
    events = [
        {
            "type": "message_start",
            "message": {
                "id": f"smoke-{request_id}",
                "role": "assistant",
                "model": SCRIPTED_PROVIDER_ID,
                "usage": {"input_tokens": 1, "output_tokens": 1},
            },
        },
        {
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "text", "text": ""},
        },
        {
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "text_delta", "text": text},
        },
        {"type": "content_block_stop", "index": 0},
        {
            "type": "message_delta",
            "delta": {"stop_reason": "end_turn"},
            "usage": {"output_tokens": 1},
        },
        {"type": "message_stop"},
    ]
    return "".join(
        f"data: {json.dumps(event, ensure_ascii=False, separators=(',', ':'))}\n\n"
        for event in events
    ).encode("utf-8")


def _tool_sse(tools: Sequence[Tuple[str, str, Mapping[str, Any]]], request_id: int) -> bytes:
    events: List[Mapping[str, Any]] = [
        {
            "type": "message_start",
            "message": {
                "id": f"smoke-{request_id}",
                "role": "assistant",
                "model": SCRIPTED_PROVIDER_ID,
                "usage": {"input_tokens": 1, "output_tokens": 1},
            },
        }
    ]
    for index, (tool_id, name, tool_input) in enumerate(tools):
        raw_input = stable_json(tool_input)
        events.extend(
            [
                {
                    "type": "content_block_start",
                    "index": index,
                    "content_block": {
                        "type": "tool_use",
                        "id": tool_id,
                        "name": name,
                        "input": {},
                    },
                },
                {
                    "type": "content_block_delta",
                    "index": index,
                    "delta": {
                        "type": "input_json_delta",
                        "partial_json": raw_input,
                    },
                },
                {"type": "content_block_stop", "index": index},
            ]
        )
    events.extend(
        [
            {
                "type": "message_delta",
                "delta": {"stop_reason": "tool_use"},
                "usage": {"output_tokens": max(1, len(tools))},
            },
            {"type": "message_stop"},
        ]
    )
    return "".join(
        f"data: {json.dumps(event, ensure_ascii=False, separators=(',', ':'))}\n\n"
        for event in events
    ).encode("utf-8")


def _tool_results(body: Mapping[str, Any]) -> Dict[str, str]:
    result: Dict[str, str] = {}
    messages = body.get("messages")
    if not isinstance(messages, list):
        return result
    for message in messages:
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict) or item.get("type") != "tool_result":
                continue
            tool_id = item.get("tool_use_id")
            value = item.get("content")
            if isinstance(tool_id, str) and isinstance(value, str):
                result[tool_id] = value
    return result


class _ScriptedPlanner:
    def __init__(self, prompt: str, tinykg_enabled: bool) -> None:
        self.prompt = prompt
        self.tinykg_enabled = tinykg_enabled
        self.stage = "recall" if tinykg_enabled else "final"

    def response(self, body: Mapping[str, Any], request_id: int) -> bytes:
        results = _tool_results(body)
        if self.stage == "recall":
            self.stage = "context"
            return _tool_sse(
                [("kg-recall-1", "KgRecall", {"query": self.prompt})],
                request_id,
            )
        if self.stage == "context":
            raw = results.get("kg-recall-1", "")
            node_id = None
            try:
                parsed = json.loads(raw)
                hits = parsed.get("hits") if isinstance(parsed, dict) else None
                if isinstance(hits, list) and hits and isinstance(hits[0], dict):
                    node_id = hits[0].get("node_id")
            except json.JSONDecodeError:
                pass
            if isinstance(node_id, int) and not isinstance(node_id, bool):
                self.stage = "final"
                return _tool_sse(
                    [("kg-context-1", "KgContext", {"node_id": node_id, "limit": 12})],
                    request_id,
                )
            self.stage = "final"
        return _text_sse("runtime-smoke", request_id)


class ScriptedMemoryProvider:
    """Loopback-only deterministic Anthropic SSE provider for native L2."""

    def __init__(self, prompt: str, tinykg_enabled: bool) -> None:
        self.planner = _ScriptedPlanner(prompt, tinykg_enabled)
        self.requests: List[Mapping[str, Any]] = []
        self._server: socketserver.TCPServer | None = None
        self._thread: threading.Thread | None = None
        self.port: int | None = None

    def __enter__(self) -> "ScriptedMemoryProvider":
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args: Any) -> None:
                return

            def do_POST(self) -> None:  # noqa: N802 - stdlib callback name
                try:
                    length = int(self.headers.get("content-length", "0"))
                    if length < 0 or length > 16 * 1024 * 1024:
                        raise ValueError("request exceeds scripted-provider cap")
                    raw = self.rfile.read(length)
                    body = json.loads(raw)
                    if not isinstance(body, dict):
                        raise ValueError("request must be an object")
                    outer.requests.append(body)
                    response = outer.planner.response(body, len(outer.requests))
                except (UnicodeError, json.JSONDecodeError, ValueError):
                    self.send_response(400)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.end_headers()
                try:
                    self.wfile.write(response)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return

        socketserver.TCPServer.allow_reuse_address = True
        self._server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
        self.port = int(self._server.server_address[1])
        self._thread = threading.Thread(
            target=self._server.serve_forever,
            name="memory-scripted-provider",
            daemon=True,
        )
        self._thread.start()
        return self

    @property
    def url(self) -> str:
        if self.port is None:
            raise RuntimeError("scripted provider has not started")
        return f"http://127.0.0.1:{self.port}/v1/messages"

    def __exit__(self, *_args: Any) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
        if self._thread is not None:
            self._thread.join(timeout=2)


def _public_procedural_cases(source: Mapping[str, Any]) -> Dict[str, Mapping[str, Any]]:
    result: Dict[str, Mapping[str, Any]] = {}
    families = source.get("families")
    if not isinstance(families, list):
        return result
    for family in families:
        if not isinstance(family, dict) or not isinstance(family.get("cases"), list):
            continue
        for case in family["cases"]:
            if isinstance(case, dict) and isinstance(case.get("id"), str):
                result[case["id"]] = {**case, "_family_id": family.get("id")}
    return result


def _materialize_workspace(case: Mapping[str, Any], workspace: Path) -> Dict[str, str]:
    raw_workspace = case.get("workspace")
    files = raw_workspace.get("files") if isinstance(raw_workspace, dict) else None
    if not isinstance(files, list) or not files:
        _fail("procedural public workspace", "missing files")
    baseline: Dict[str, str] = {}
    for index, item in enumerate(files):
        if not isinstance(item, dict):
            _fail("procedural public workspace", f"files[{index}] is not an object")
        relative = item.get("path")
        content = item.get("content")
        expected = item.get("sha256")
        if not isinstance(relative, str) or not isinstance(content, str) or not isinstance(expected, str):
            _fail("procedural public workspace", f"files[{index}] is incomplete")
        target = (workspace / relative).resolve()
        _inside(target, workspace, "procedural workspace file")
        if _hash_text(content) != expected:
            _fail("procedural public workspace", f"files[{index}] content hash mismatch")
        _write_new(target, content.encode("utf-8"))
        baseline[relative] = content
    return baseline


def _read_workspace(workspace: Path, baseline: Mapping[str, str]) -> Dict[str, str]:
    result: Dict[str, str] = {}
    for relative in baseline:
        target = _inside(workspace / relative, workspace, "procedural workspace result")
        try:
            info = target.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_size > 16 * 1024 * 1024:
                _fail("procedural workspace result", f"invalid file {relative!r}")
            result[relative] = target.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            raise ValidationError(f"cannot read procedural result {relative!r}: {exc}") from exc
    return result


def _parse_result(stdout: str) -> Mapping[str, Any]:
    rows: List[Mapping[str, Any]] = []
    for line in stdout.splitlines():
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValidationError(f"native metacodes stdout is not NDJSON: {exc}") from exc
        if isinstance(value, dict) and value.get("type") == "result":
            rows.append(value)
    if len(rows) != 1:
        _fail("native metacodes stdout", f"expected exactly one result row, observed {len(rows)}")
    result = rows[0]
    required = {
        "type",
        "stop_reason",
        "turns",
        "tool_calls",
        "input_tokens",
        "output_tokens",
        "cost_usd",
        "text",
    }
    if set(result) != required:
        _fail("native metacodes result", f"unexpected fields: {sorted(set(result) ^ required)}")
    if not isinstance(result["stop_reason"], str) or not result["stop_reason"]:
        _fail("native metacodes result.stop_reason", "expected non-empty string")
    for key in ("turns", "tool_calls", "input_tokens", "output_tokens"):
        value = result[key]
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            _fail(f"native metacodes result.{key}", "expected non-negative integer")
    cost = result["cost_usd"]
    if (
        not isinstance(cost, (int, float))
        or isinstance(cost, bool)
        or not math.isfinite(float(cost))
        or float(cost) < 0
    ):
        _fail("native metacodes result.cost_usd", "expected finite non-negative number")
    if not isinstance(result["text"], str):
        _fail("native metacodes result.text", "expected string")
    return result


def _cassette_tool_data(
    cassette: Path,
    logical_ids: Mapping[int, str],
) -> Tuple[List[Mapping[str, str]], List[str], List[str], bool, int]:
    query_variants: List[Mapping[str, str]] = []
    retrieved: List[str] = []
    verified: List[str] = []
    graph_truncated = False
    exposed_bytes = 0
    seen_tools: set[str] = set()
    for request_path in sorted(cassette.glob("req-*.json")):
        body = _load_json(request_path, "provider request cassette")
        messages = body.get("messages")
        if not isinstance(messages, list):
            continue
        known_uses: Dict[str, Tuple[str, Mapping[str, Any]]] = {}
        results: Dict[str, str] = {}
        for message in messages:
            content = message.get("content") if isinstance(message, dict) else None
            if not isinstance(content, list):
                continue
            for item in content:
                if not isinstance(item, dict):
                    continue
                if item.get("type") == "tool_use":
                    tool_id, name, tool_input = item.get("id"), item.get("name"), item.get("input")
                    if isinstance(tool_id, str) and isinstance(name, str) and isinstance(tool_input, dict):
                        known_uses[tool_id] = (name, tool_input)
                elif item.get("type") == "tool_result":
                    tool_id, value = item.get("tool_use_id"), item.get("content")
                    if isinstance(tool_id, str) and isinstance(value, str):
                        results[tool_id] = value
        for tool_id, (name, tool_input) in known_uses.items():
            if tool_id in seen_tools or tool_id not in results:
                continue
            seen_tools.add(tool_id)
            raw_result = results[tool_id]
            exposed_bytes += len(raw_result.encode("utf-8"))
            if name == "KgRecall":
                query = tool_input.get("query")
                if isinstance(query, str):
                    query_variants.append(
                        {"kind": "exact" if not query_variants else "semantic", "text": query}
                    )
                try:
                    parsed = json.loads(raw_result)
                except json.JSONDecodeError:
                    continue
                hits = parsed.get("hits") if isinstance(parsed, dict) else None
                if isinstance(hits, list):
                    for hit in hits:
                        node_id = hit.get("node_id") if isinstance(hit, dict) else None
                        logical = logical_ids.get(node_id) if isinstance(node_id, int) else None
                        if logical is not None and logical not in retrieved:
                            retrieved.append(logical)
            elif name == "KgContext":
                node_id = tool_input.get("node_id")
                logical = logical_ids.get(node_id) if isinstance(node_id, int) else None
                if logical is not None and logical not in verified:
                    verified.append(logical)
                try:
                    parsed = json.loads(raw_result)
                    if isinstance(parsed, dict):
                        graph_truncated = graph_truncated or bool(
                            parsed.get("graph_truncated")
                            or (isinstance(parsed.get("summary"), dict) and parsed["summary"].get("truncated"))
                        )
                except json.JSONDecodeError:
                    pass
    return query_variants, retrieved, verified, graph_truncated, exposed_bytes


def _runtime_metadata(
    *,
    manifest: Mapping[str, Any],
    case: Mapping[str, Any],
    schedule: Mapping[str, Any],
    events_path: Path,
    run_id: str,
    model_provider: str,
    harness_fingerprint: str,
    environment_fingerprint: str,
) -> Mapping[str, Any]:
    return {
        "schema_version": RUNTIME_METADATA_SCHEMA_VERSION,
        "events_path": str(events_path),
        "run_id": run_id,
        "trial": schedule["trial"],
        "suite_id": manifest["manifest_id"],
        "task_id": case["id"],
        "task_fingerprint": _canonical_sha256(case),
        "model_provider": model_provider,
        "model_id": manifest["execution"]["model_id"],
        "model_fingerprint": manifest["execution"]["model_fingerprint"],
        "harness_config_id": f"memory:{schedule['arm']}",
        "harness_revision": manifest["execution"]["harness_revision"],
        "harness_fingerprint": harness_fingerprint,
        "permission_mode": "bypass_permissions",
        "environment_fingerprint": environment_fingerprint,
        "grader_fingerprint": case["grader"]["fingerprint"],
    }


def _sanitized_environment(base: Mapping[str, str]) -> Dict[str, str]:
    forbidden_exact = {
        "HOME",
        "TMPDIR",
        "TMP",
        "TEMP",
        "METACODES_KG_BIN",
        "METACODES_KG_STORE",
        "METACODES_LONG_HORIZON_ARM",
        "METACODES_BASE_URL",
        "METACODES_RECORD_DIR",
        "METACODES_EVAL_METADATA_FD",
        "METACODES_EVAL_FD",
        "METACODES_LOG",
        "METACODES_LOG_FILE",
    }
    return {
        key: value
        for key, value in base.items()
        if not key.startswith("TINYKG_") and key not in forbidden_exact
    }


def run_memory_agent_schedule(
    *,
    metacodes_binary: Path,
    expected_metacodes_sha256: str,
    tinykg_binary: Path,
    expected_tinykg_sha256: str,
    source_path: Path,
    manifest_path: Path,
    run_dir: Path,
    observations_path: Path,
    runtime_receipt_path: Path,
    validator_bundle_path: Path | None = None,
    timeout_seconds: int = 45,
) -> Tuple[List[Mapping[str, Any]], Mapping[str, Any]]:
    """Run one complete frozen schedule with the zero-cost scripted provider."""

    metacodes = metacodes_binary.expanduser().resolve()
    tinykg = tinykg_binary.expanduser().resolve()
    if not metacodes.is_file() or not os.access(metacodes, os.X_OK):
        _fail("metacodes runtime binary", "not executable")
    if not tinykg.is_file() or not os.access(tinykg, os.X_OK):
        _fail("TinyKG runtime binary", "not executable")
    metacodes_sha = file_sha256(metacodes)
    tinykg_sha = file_sha256(tinykg)
    if not HEX64.fullmatch(expected_metacodes_sha256) or metacodes_sha != expected_metacodes_sha256:
        _fail("metacodes runtime binary", "SHA-256 mismatch")
    if not HEX64.fullmatch(expected_tinykg_sha256) or tinykg_sha != expected_tinykg_sha256:
        _fail("TinyKG runtime binary", "SHA-256 mismatch")

    manifest = load_manifest(manifest_path)
    source = _load_json(source_path, "memory adapter source")
    source_sha = file_sha256(source_path)
    if source_sha != manifest["dataset"]["source_sha256"]:
        _fail("memory adapter source", "SHA-256 does not match manifest")
    if source.get("adapter_id") != manifest["dataset"]["adapter_id"]:
        _fail("memory adapter source", "adapter id does not match manifest")
    if source.get("adapter_revision") != manifest["dataset"]["adapter_revision"]:
        _fail("memory adapter source", "adapter revision does not match manifest")

    procedural_cases = _public_procedural_cases(source)
    validators: Dict[str, Mapping[str, Any]] = {}
    if manifest["dataset"]["adapter_id"] == "coding-intent-families":
        if validator_bundle_path is None:
            _fail("procedural memory runtime", "validator bundle is required")
        bundle = _load_json(validator_bundle_path, "procedural validator bundle")
        validate_validator_bundle(bundle, source)
        validators = {item["case_id"]: item for item in bundle["cases"]}
    elif validator_bundle_path is not None:
        _fail("memory agent runtime", "validator bundle is only valid for procedural adapter")

    resolved_run = run_dir.expanduser().resolve()
    if resolved_run.exists():
        _fail("memory agent run directory", "must not already exist")
    observations_output = _inside(observations_path, resolved_run, "memory observations output")
    receipt_output = _inside(runtime_receipt_path, resolved_run, "memory runtime receipt output")
    if observations_output == receipt_output:
        _fail("memory agent runtime", "observation and receipt outputs must be distinct")
    resolved_run.mkdir(parents=True)

    def artifact_relative(path: Path, label: str) -> str:
        return _inside(path, resolved_run, label).relative_to(resolved_run).as_posix()

    local = LocalTinyKg(
        tinykg,
        expected_sha256=expected_tinykg_sha256,
        run_dir=resolved_run / "local-tinykg",
        timeout_seconds=timeout_seconds,
    )
    cases = {case["id"]: case for case in manifest["cases"]}
    arms = {arm["id"]: arm for arm in manifest["execution"]["arms"]}
    for arm_id in arms:
        if arm_id not in ARM_TO_RUNTIME:
            _fail("memory agent runtime", f"unsupported arm {arm_id!r}")

    observations: List[Mapping[str, Any]] = []
    rollout_receipts: List[Mapping[str, Any]] = []
    procedural_stores: MutableMapping[Tuple[str, int, str], Mapping[str, Any]] = {}

    for expected_sequence, schedule in enumerate(manifest["schedule"]):
        if schedule["sequence"] != expected_sequence:
            _fail("memory schedule", "sequence is not contiguous")
        case = cases[schedule["case_id"]]
        arm_id = schedule["arm"]
        runtime_arm = ARM_TO_RUNTIME[arm_id]
        tinykg_enabled = runtime_arm == "tinykg"
        component = _safe_component(
            f"{expected_sequence}:{case['id']}:{schedule['trial']}:{arm_id}"
        )
        artifact_dir = resolved_run / "rollouts" / f"{expected_sequence:05d}-{component}"
        artifact_dir.mkdir(parents=True)
        if case["benchmark"] == "procedural_transfer":
            project_root = (
                resolved_run
                / "procedural-projects"
                / _safe_component(
                    f"{case.get('family_id')}:{schedule['trial']}:{arm_id}"
                )
            )
            workspace = project_root / "workspaces" / component
        else:
            project_root = artifact_dir / "project"
            workspace = project_root / "workspace"
        workspace.mkdir(parents=True)
        (project_root / ".git").mkdir(exist_ok=True)
        sealed_home = artifact_dir / "sealed-home"
        child_tmp = artifact_dir / "tmp"
        cassette = artifact_dir / "cassette"
        for directory in (sealed_home, child_tmp, cassette):
            directory.mkdir()

        baseline: Dict[str, str] = {}
        public_case = procedural_cases.get(case["id"])
        if public_case is not None:
            baseline = _materialize_workspace(public_case, workspace)

        store: Path | None = None
        logical_ids: Dict[int, str] = {}
        graph_revision_before = "none"
        graph_revision_after = "none"
        raw_store_digest_before = "none"
        raw_store_digest_after = "none"
        store_nodes = 0
        store_edges = 0
        store_text_stale = False
        abstraction_nodes = 0
        if tinykg_enabled:
            domain = _project_domain(project_root)
            family_key = (
                str(case.get("family_id") or case["id"]),
                int(schedule["trial"]),
                arm_id,
            )
            if case["benchmark"] == "procedural_transfer" and family_key in procedural_stores:
                prior = procedural_stores[family_key]
                store = Path(str(prior["store"]))
                logical_ids = dict(prior["logical_ids"])
                abstraction_nodes = int(prior["abstraction_nodes"])
            else:
                store = local.store_root / f"{_safe_component(':'.join(map(str, family_key)))}.kg"
                local.command("init", store, ())
                batch_path = local.batch_root / f"{_safe_component(':'.join(map(str, family_key)))}.jsonl"
                if case["benchmark"] == "procedural_transfer":
                    batch = _empty_project_batch(domain)
                    counts = {"nodes": 1, "edges": 0, "abstraction_nodes": 0}
                else:
                    raw_batch, raw_logical, root_id, _query_case = build_case_batch(
                        source,
                        manifest,
                        case["id"],
                    )
                    batch, logical_ids, _root_id, counts = _agent_batch(
                        raw_batch,
                        raw_logical,
                        root_id,
                        domain,
                    )
                _write_new(batch_path, batch)
                local.command("apply", store, (str(batch_path),))
                abstraction_nodes = counts["abstraction_nodes"]
                if case["benchmark"] == "procedural_transfer":
                    procedural_stores[family_key] = {
                        "store": str(store),
                        "logical_ids": logical_ids,
                        "abstraction_nodes": abstraction_nodes,
                    }
            graph_revision_before = _tree_digest(store, normalize_store_manifest=True)
            raw_store_digest_before = _tree_digest(store)
            info = _store_info(local.command("store-info", store, ()))
            store_nodes, store_edges = int(info["nodes"]), int(info["edges"])
            if info.get("text_stale") not in {"0", "1"}:
                _fail(f"native memory rollout {case['id']}", "invalid TinyKG text_stale state")
            store_text_stale = info["text_stale"] == "1"

        events = artifact_dir / "native-events.jsonl"
        metadata_path = artifact_dir / "runtime-metadata.json"
        stdout_path = artifact_dir / "stdout.ndjson"
        stderr_path = artifact_dir / "stderr.log"
        run_id = f"{manifest['manifest_id']}:{expected_sequence}:{case['id']}:{schedule['trial']}:{arm_id}"
        harness_fingerprint = _canonical_sha256(
            {
                "metacodes_binary_sha256": metacodes_sha,
                "harness_revision": manifest["execution"]["harness_revision"],
                "arm": arms[arm_id],
                "runtime_arm": runtime_arm,
                "provider": SCRIPTED_PROVIDER_ID,
            }
        )
        environment_fingerprint = _canonical_sha256(
            {
                "platform": platform.platform(),
                "python": platform.python_version(),
                "source_sha256": source_sha,
                "tinykg_binary_sha256": tinykg_sha if tinykg_enabled else None,
                "project_domain": _project_domain(project_root),
            }
        )
        metadata = _runtime_metadata(
            manifest=manifest,
            case=case,
            schedule=schedule,
            events_path=events,
            run_id=run_id,
            model_provider="scripted-local",
            harness_fingerprint=harness_fingerprint,
            environment_fingerprint=environment_fingerprint,
        )
        _write_new(
            metadata_path,
            (json.dumps(metadata, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8"),
        )
        metadata_fd = os.open(metadata_path, os.O_RDONLY)
        metadata_path.unlink()
        events_file = tempfile.TemporaryFile()
        started = time.monotonic_ns()
        try:
            with ScriptedMemoryProvider(case["prompt"], tinykg_enabled) as provider:
                env = _sanitized_environment(os.environ)
                env.update(
                    {
                        "HOME": str(sealed_home),
                        "TMPDIR": str(child_tmp),
                        "TMP": str(child_tmp),
                        "TEMP": str(child_tmp),
                        "LC_ALL": "C",
                        "LANG": "C",
                        "METACODES_NO_PROBE": "1",
                        "METACODES_LONG_HORIZON_ARM": runtime_arm,
                        "METACODES_RECORD_DIR": str(cassette),
                        "METACODES_EVAL_METADATA_FD": str(metadata_fd),
                        "METACODES_EVAL_FD": str(events_file.fileno()),
                    }
                )
                if tinykg_enabled and store is not None:
                    env["METACODES_KG_BIN"] = str(tinykg)
                    env["METACODES_KG_STORE"] = str(store)
                completed = subprocess.run(
                    [
                        str(metacodes),
                        "--api-key",
                        "scripted-local-no-secret",
                        "--base-url",
                        provider.url,
                        "--model",
                        manifest["execution"]["model_id"],
                        "--permission",
                        "bypassPermissions",
                        "--no-theme",
                        "--record",
                        str(cassette),
                        "-p",
                        case["prompt"],
                        "--json",
                    ],
                    cwd=workspace,
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=timeout_seconds,
                    check=False,
                    pass_fds=(metadata_fd, events_file.fileno()),
                )
                provider_request_count = len(provider.requests)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ValidationError(f"native memory rollout {run_id} failed to execute: {exc}") from exc
        finally:
            os.close(metadata_fd)
        elapsed_ms = (time.monotonic_ns() - started) / 1_000_000.0
        finalize_evaluation_fd(events_file.fileno(), events)
        events_file.close()
        _write_new(stdout_path, completed.stdout.encode("utf-8"))
        _write_new(stderr_path, completed.stderr.encode("utf-8"))
        result = _parse_result(completed.stdout)
        native, native_error = _native_trace_metrics(events)
        if native_error is not None or native is None:
            _fail(f"native memory rollout {run_id}", native_error or "invalid events")
        metrics = native["metrics"]
        if completed.returncode != 0:
            _fail(f"native memory rollout {run_id}", f"process exited {completed.returncode}")
        if result["stop_reason"] not in SAFE_STOP_REASONS:
            _fail(f"native memory rollout {run_id}", f"unsafe stop {result['stop_reason']!r}")
        if not native["complete"] or native["starts"] != 1 or native["finishes"] != 1:
            _fail(f"native memory rollout {run_id}", "native lifecycle is incomplete")
        if native["dropped_events_total"] != 0:
            _fail(f"native memory rollout {run_id}", "native events were dropped")
        native_metadata = native["metadata"]
        for key in (
            "run_id",
            "task_id",
            "task_fingerprint",
            "model_fingerprint",
            "harness_fingerprint",
            "environment_fingerprint",
            "grader_fingerprint",
        ):
            if native_metadata.get(key) != metadata[key]:
                _fail(f"native memory rollout {run_id}", f"metadata drift in {key}")
        if native_metadata.get("runtime_model_id") != manifest["execution"]["model_id"]:
            _fail(f"native memory rollout {run_id}", "runtime model id drift")
        if native_metadata.get("runtime_permission_mode") != "bypass_permissions":
            _fail(f"native memory rollout {run_id}", "runtime permission drift")
        if metrics["model_request_count"] != provider_request_count or provider_request_count < 1:
            _fail(f"native memory rollout {run_id}", "provider/native request count mismatch")
        metric_cost = float(metrics["cost_usd"])
        result_cost = float(result["cost_usd"])
        if (
            not math.isfinite(metric_cost)
            or not math.isfinite(result_cost)
            or metric_cost < 0
            or result_cost < 0
            or abs(metric_cost - result_cost) > 1e-12
        ):
            _fail(f"native memory rollout {run_id}", "runtime emitted an invalid estimated cost")

        query_variants, retrieved, verified, graph_truncated, exposed_bytes = _cassette_tool_data(
            cassette,
            logical_ids,
        )
        if len([item for item in query_variants if item["kind"] == "semantic"]) > 4:
            _fail(f"native memory rollout {run_id}", "semantic query cap exceeded")
        if tinykg_enabled:
            assert store is not None
            graph_revision_after = _tree_digest(store, normalize_store_manifest=True)
            raw_store_digest_after = _tree_digest(store)
            if graph_revision_after != graph_revision_before:
                _fail(f"native memory rollout {run_id}", "read-only memory rollout changed TinyKG store")
            if raw_store_digest_after != raw_store_digest_before:
                _fail(
                    f"native memory rollout {run_id}",
                    "read-only memory rollout changed raw TinyKG store bytes",
                )
            if not query_variants:
                _fail(f"native memory rollout {run_id}", "TinyKG arm did not call KgRecall")
        elif query_variants:
            _fail(f"native memory rollout {run_id}", "control arm reached TinyKG tools")

        deterministic_success: bool | None = None
        evaluator_invalid: str | None = None
        if case["benchmark"] == "procedural_transfer":
            validator_entry = validators.get(case["id"])
            if validator_entry is None:
                evaluator_invalid = "validator bundle missing case"
            else:
                candidate = _read_workspace(workspace, baseline)
                deterministic_success, _failures = evaluate_workspace(
                    baseline,
                    candidate,
                    validator_entry["validator"],
                )

        observation: Mapping[str, Any] = {
            "schema_version": REPLAY_SCHEMA_VERSION,
            "protocol_id": PROTOCOL_ID,
            "case_id": case["id"],
            "trial": schedule["trial"],
            "arm": arm_id,
            "execution": {"status": "completed", "invalid_reason": None},
            "evaluator": {
                "status": "invalid" if evaluator_invalid else "ready",
                "invalid_reason": evaluator_invalid,
                "deterministic_success": deterministic_success if not evaluator_invalid else None,
            },
            "prediction": str(result["text"]),
            "retrieval": {
                "enabled": tinykg_enabled,
                "k": 8 if query_variants else 0,
                "hop_count": 1 if verified else 0,
                "query_variants": query_variants,
                "retrieved_evidence_ids": retrieved,
                "verified_evidence_ids": verified,
                "graph_truncated": graph_truncated,
            },
            "memory": {
                "write_mode": "read_only" if tinykg_enabled else "disabled",
                "exposed_tokens": (exposed_bytes + 3) // 4,
                "internal_tokens": 0,
                "inserted_nodes": 0,
                "active_nodes": store_nodes,
                "provenance_links": store_edges,
                "abstraction_nodes": abstraction_nodes,
                "abstraction_nodes_with_provenance": abstraction_nodes,
                "candidate_fanout": float(len(retrieved)),
            },
            "graph": {
                "revision": graph_revision_after,
                "text_stale": store_text_stale,
                "retrieval_excluded_nodes": 0,
                "contradiction_edges": 0,
            },
            "governance": {
                "stale_candidates": 0,
                "stale_rejected": 0,
                "contradictory_candidates": 0,
                "contradictory_rejected": 0,
                "retrieval_excluded_returned": 0,
                "provenance_missing_returned": 0,
                "offline_write_events": 0,
            },
            "cost": {
                # The provider is an in-process test fixture; token-priced
                # runtime telemetry is preserved in the native event artifact
                # and receipt, while actual paid spend is exactly zero.
                "cost_usd": 0.0,
                "wall_time_ms": float(metrics["wall_time_ms"]),
            },
            "trajectory": {
                "model_requests": int(metrics["model_request_count"]),
                "tool_calls": int(metrics["tool_calls"]),
                "tool_errors": int(metrics["model_tool_errors"] + metrics["harness_tool_errors"]),
                "turns": int(metrics["turns"]),
            },
        }
        observations.append(observation)
        rollout_receipts.append(
            {
                "sequence": expected_sequence,
                "case_id": case["id"],
                "trial": schedule["trial"],
                "arm": arm_id,
                "run_id": run_id,
                "task_fingerprint": _canonical_sha256(case),
                "metacodes_binary_sha256": metacodes_sha,
                "tinykg_binary_sha256": tinykg_sha if tinykg_enabled else None,
                "native_events_sha256": file_sha256(events),
                "result_sha256": file_sha256(stdout_path),
                "stderr_sha256": file_sha256(stderr_path),
                "cassette_sha256": _artifact_tree_digest(cassette),
                "transcript_sha256": _artifact_tree_digest(sealed_home),
                "workspace_sha256": _artifact_tree_digest(workspace),
                "artifact_paths": {
                    "native_events": artifact_relative(events, "native events artifact"),
                    "result": artifact_relative(stdout_path, "native result artifact"),
                    "stderr": artifact_relative(stderr_path, "native stderr artifact"),
                    "cassette": artifact_relative(cassette, "provider cassette artifact"),
                    "transcript": artifact_relative(sealed_home, "transcript artifact"),
                    "workspace": artifact_relative(workspace, "workspace artifact"),
                    "store": artifact_relative(store, "TinyKG store artifact")
                    if store is not None
                    else None,
                },
                "store_revision_before": graph_revision_before,
                "store_revision_after": graph_revision_after,
                "raw_store_digest_before": raw_store_digest_before,
                "raw_store_digest_after": raw_store_digest_after,
                "stop_reason": result["stop_reason"],
                "provider_mode": "scripted-local",
                "provider_requests": provider_request_count,
                "external_network_calls": 0,
                "paid_cost_usd": 0.0,
                "estimated_cost_usd": float(metrics["cost_usd"]),
                "observation_sha256": _canonical_sha256(observation),
                "host_elapsed_ms": elapsed_ms,
            }
        )

    receipt: Mapping[str, Any] = {
        "schema_version": RUNTIME_RECEIPT_SCHEMA_VERSION,
        "protocol_id": PROTOCOL_ID,
        "manifest_sha256": _canonical_sha256(manifest),
        "observations_sha256": _canonical_sha256(observations),
        "dataset_sha256": source_sha,
        "adapter_id": manifest["dataset"]["adapter_id"],
        "adapter_revision": manifest["dataset"]["adapter_revision"],
        "model_id": manifest["execution"]["model_id"],
        "model_fingerprint": manifest["execution"]["model_fingerprint"],
        "harness_revision": manifest["execution"]["harness_revision"],
        "arms": list(manifest["execution"]["arms"]),
        "graders": [
            {"case_id": case["id"], "fingerprint": case["grader"]["fingerprint"]}
            for case in manifest["cases"]
        ],
        "execution_mode": "native-agent-loop-scripted-wiring-smoke",
        "quality_evidence": False,
        "metacodes_binary_sha256": metacodes_sha,
        "tinykg_binary_sha256": tinykg_sha,
        "external_network_calls": 0,
        "paid_cost_usd": 0.0,
        "estimated_cost_usd": sum(
            float(rollout["estimated_cost_usd"]) for rollout in rollout_receipts
        ),
        "rollouts": rollout_receipts,
    }
    # Join before publication: a malformed observation must not leave a receipt
    # that looks complete.  The v2 receipt validator additionally binds each
    # row to native artifacts.
    replay_observations(
        manifest,
        observations,
        dataset_source=source_path,
        runtime_receipt=receipt,
        runtime_artifact_root=resolved_run,
    )
    _write_new(
        observations_output,
        b"".join((stable_json(row) + "\n").encode("utf-8") for row in observations),
    )
    _write_new(
        receipt_output,
        (stable_json(receipt) + "\n").encode("utf-8"),
    )
    return observations, receipt
