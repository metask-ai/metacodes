"""Deterministic Anthropic-SSE provider for official WorkBuddy L2 runs.

The default scenario returns one final answer and preserves the original proxy
and adapter smoke test.  ``control-plane-v1`` is a stricter zero-paid scripted
actor: each accepted request must contain the exact previous tool result before
the next tool call is issued.  It exercises real metacodes tool dispatch,
TinyKG, task-DAG and project-Lean paths without pretending to solve a benchmark
task or emitting any control-plane metric itself.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Mapping


SCHEMA_VERSION = "metacodes-workbuddy-mock-provider-v2"
MOCK_CREDENTIAL = "metacodes-workbuddy-mock-only"
MAX_REQUEST_BYTES = 16 * 1024 * 1024
SCENARIOS = (
    "final-v1",
    "control-plane-v1",
    "headless-permission-v1",
    "guessed-disabled-tool-v1",
)
CONTROL_MEMORY = (
    "workbuddy-w05-control-marker: real local TinyKG and project Lean gate "
    "must be observed before quality evaluation"
)


class ScenarioError(ValueError):
    """The caller drifted from the frozen zero-paid scripted interaction."""


def _write_all(descriptor: int, payload: bytes) -> None:
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            raise OSError("short mock-provider artifact write")
        offset += written


def _private_new(path: Path, payload: bytes) -> None:
    parent = path.parent.resolve(strict=True)
    info = parent.stat()
    if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o022:
        raise ValueError("mock-provider artifact parent must be private")
    if hasattr(os, "geteuid") and info.st_uid != os.geteuid():
        raise ValueError("mock-provider artifact parent must be owned by the current user")
    if path.exists() or path.is_symlink():
        raise ValueError(f"refusing to overwrite mock-provider artifact: {path}")
    descriptor = os.open(
        parent / path.name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        _write_all(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    parent_descriptor = os.open(parent, os.O_RDONLY)
    try:
        os.fsync(parent_descriptor)
    finally:
        os.close(parent_descriptor)


def _events_sse(events: list[dict[str, Any]]) -> bytes:
    return b"".join(
        b"data: " + json.dumps(event, separators=(",", ":")).encode("utf-8") + b"\n\n"
        for event in events
    )


def _final_sse(request_number: int, text: str) -> bytes:
    message_id = f"msg_workbuddy_mock_{request_number}"
    events: list[dict[str, Any]] = [
        {
            "type": "message_start",
            "message": {
                "id": message_id,
                "role": "assistant",
                "model": "glm-5.2",
                "usage": {
                    "input_tokens": 100,
                    "output_tokens": 0,
                    "cache_read_input_tokens": 64,
                    "cache_creation_input_tokens": 8,
                },
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
            "delta": {
                "type": "text_delta",
                "text": text,
            },
        },
        {"type": "content_block_stop", "index": 0},
        {
            "type": "message_delta",
            "delta": {"stop_reason": "end_turn", "stop_sequence": None},
            "usage": {"output_tokens": 8},
        },
        {"type": "message_stop"},
    ]
    return _events_sse(events)


def _tool_sse(request_number: int, call_id: str, name: str, value: Mapping[str, Any]) -> bytes:
    message_id = f"msg_workbuddy_mock_{request_number}"
    compact = json.dumps(dict(value), separators=(",", ":"), ensure_ascii=False)
    return _events_sse(
        [
            {
                "type": "message_start",
                "message": {
                    "id": message_id,
                    "role": "assistant",
                    "model": "glm-5.2",
                    "usage": {
                        "input_tokens": 100,
                        "output_tokens": 0,
                        "cache_read_input_tokens": 64,
                        "cache_creation_input_tokens": 8,
                    },
                },
            },
            {
                "type": "content_block_start",
                "index": 0,
                "content_block": {
                    "type": "tool_use",
                    "id": call_id,
                    "name": name,
                    "input": {},
                },
            },
            {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "input_json_delta", "partial_json": compact},
            },
            {"type": "content_block_stop", "index": 0},
            {
                "type": "message_delta",
                "delta": {"stop_reason": "tool_use", "stop_sequence": None},
                "usage": {"output_tokens": 8},
            },
            {"type": "message_stop"},
        ]
    )


def _blocks(message: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    content = message.get("content")
    if not isinstance(content, list):
        return []
    return [item for item in content if isinstance(item, Mapping)]


def _tool_names(request: Mapping[str, Any]) -> set[str]:
    tools = request.get("tools")
    if not isinstance(tools, list):
        return set()
    return {
        str(tool["name"])
        for tool in tools
        if isinstance(tool, Mapping) and isinstance(tool.get("name"), str)
    }


def _result_text(request: Mapping[str, Any], call_id: str) -> tuple[str, bool]:
    messages = request.get("messages")
    if not isinstance(messages, list):
        raise ScenarioError("request messages are missing")
    matches: list[Mapping[str, Any]] = []
    for message in messages:
        if not isinstance(message, Mapping):
            continue
        for block in _blocks(message):
            if block.get("type") == "tool_result" and block.get("tool_use_id") == call_id:
                matches.append(block)
    if len(matches) != 1:
        raise ScenarioError(f"expected exactly one result for {call_id}")
    block = matches[0]
    is_error = block.get("is_error", False)
    if not isinstance(is_error, bool):
        raise ScenarioError(f"tool result {call_id} has an invalid error marker")
    content = block.get("content")
    if isinstance(content, str):
        return content, is_error
    if isinstance(content, list):
        texts = [
            item.get("text")
            for item in content
            if isinstance(item, Mapping)
            and item.get("type") == "text"
            and isinstance(item.get("text"), str)
        ]
        if len(texts) == 1:
            return str(texts[0]), is_error
    raise ScenarioError(f"tool result {call_id} has unsupported content")


def _result_object(request: Mapping[str, Any], call_id: str) -> dict[str, Any]:
    text, is_error = _result_text(request, call_id)
    if is_error:
        raise ScenarioError(f"tool result {call_id} reported an error")
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ScenarioError(f"tool result {call_id} is not JSON") from exc
    if not isinstance(value, dict):
        raise ScenarioError(f"tool result {call_id} is not an object")
    return value


def _require_tools(request: Mapping[str, Any], *names: str) -> None:
    missing = set(names) - _tool_names(request)
    if missing:
        raise ScenarioError(f"scripted tools are unavailable: {sorted(missing)}")


def _control_plane_sse(request_number: int, request: Mapping[str, Any]) -> bytes:
    """Advance only after the real previous tool outcome is observable."""

    _require_tools(
        request,
        "KgRemember",
        "KgRecall",
        "KgContext",
        "TaskCreate",
        "TaskUpdate",
        "Write",
    )
    if request_number == 1:
        return _tool_sse(
            request_number,
            "w05-remember",
            "KgRemember",
            {"text": CONTROL_MEMORY, "kind": "decision", "scope": "project"},
        )
    if request_number == 2:
        remembered = _result_object(request, "w05-remember")
        remembered_node = remembered.get("remembered")
        node_id = (
            remembered_node.get("node_id")
            if isinstance(remembered_node, Mapping)
            else None
        )
        if isinstance(node_id, bool) or not isinstance(node_id, int) or node_id <= 0:
            raise ScenarioError("KgRemember did not return a positive node_id")
        return _tool_sse(
            request_number,
            "w05-recall",
            "KgRecall",
            {
                "query": CONTROL_MEMORY,
                "lexical_plan": {
                    "schema_version": "lexical-query-plan-v1",
                    "intent": "fact_lookup",
                    "stage": "seed",
                    "variants": [{"kind": "exact", "text": CONTROL_MEMORY}],
                    "variant_index": 0,
                    "seen_node_ids": [],
                },
            },
        )
    if request_number == 3:
        recalled = _result_object(request, "w05-recall")
        hits = recalled.get("hits")
        count = recalled.get("count")
        if (
            isinstance(count, bool)
            or not isinstance(count, int)
            or count <= 0
            or not isinstance(hits, list)
            or len(hits) != count
            or not isinstance(hits[0], Mapping)
        ):
            raise ScenarioError("KgRecall did not return a consistent non-empty hit set")
        node_id = hits[0].get("node_id")
        if isinstance(node_id, bool) or not isinstance(node_id, int) or node_id <= 0:
            raise ScenarioError("KgRecall hit has no positive node_id")
        return _tool_sse(
            request_number,
            "w05-context",
            "KgContext",
            {"node_id": node_id, "limit": 12},
        )
    if request_number == 4:
        context = _result_object(request, "w05-context")
        governance = context.get("knowledge_governance")
        if not isinstance(governance, Mapping) or governance.get("schema_version") != (
            "metacodes-knowledge-governance-v1"
        ):
            raise ScenarioError("KgContext did not return governed knowledge evidence")
        return _tool_sse(
            request_number,
            "w05-task-create",
            "TaskCreate",
            {
                "subject": "WorkBuddy W0.5 real control plane",
                "description": "Close only after the governed output is written.",
            },
        )
    if request_number == 5:
        created = _result_object(request, "w05-task-create")
        task = created.get("task")
        task_id = task.get("id") if isinstance(task, Mapping) else None
        if not isinstance(task_id, str) or not task_id.startswith("kg-"):
            raise ScenarioError("TaskCreate did not persist a TinyKG task")
        return _tool_sse(
            request_number,
            "w05-task-claim",
            "TaskUpdate",
            {"taskId": task_id, "status": "in_progress"},
        )
    if request_number == 6:
        claimed = _result_object(request, "w05-task-claim")
        if claimed.get("claimed") is not True or not isinstance(
            claimed.get("claimed_by"), str
        ):
            raise ScenarioError("TaskUpdate did not claim the TinyKG task")
        return _tool_sse(
            request_number,
            "w05-write",
            "Write",
            {
                "file_path": "/workspace/result.txt",
                "content": "metacodes workbuddy w05 ok\n",
            },
        )
    if request_number == 7:
        _write_result, write_is_error = _result_text(request, "w05-write")
        if write_is_error:
            raise ScenarioError("Write reported an error")
        created = _result_object(request, "w05-task-create")
        task = created.get("task")
        task_id = task.get("id") if isinstance(task, Mapping) else None
        if not isinstance(task_id, str) or not task_id.startswith("kg-"):
            raise ScenarioError("TaskCreate identity disappeared before completion")
        return _tool_sse(
            request_number,
            "w05-task-complete",
            "TaskUpdate",
            {
                "taskId": task_id,
                "status": "completed",
                "conclusion": "W0.5 governed artifact was written and reobserved.",
                "produces": ["/workspace/result.txt"],
                "uses": ["TinyKG", "project Lean gate"],
            },
        )
    if request_number == 8:
        completed = _result_object(request, "w05-task-complete")
        if completed.get("closed") is not True:
            raise ScenarioError("TaskUpdate did not commit the terminal TinyKG state")
        return _final_sse(
            request_number,
            "W0.5 completed through real TinyKG, task-DAG and project-rule control paths.",
        )
    raise ScenarioError("control-plane-v1 received more than eight requests")


def _scenario_sse(scenario: str, request_number: int, request: Mapping[str, Any]) -> bytes:
    if scenario == "final-v1":
        return _final_sse(
            request_number,
            "Mock L2 completed without modifying the benchmark workspace.",
        )
    if scenario == "control-plane-v1":
        return _control_plane_sse(request_number, request)
    if scenario == "headless-permission-v1":
        _require_tools(request, "Write")
        if request_number == 1:
            return _tool_sse(
                request_number,
                "headless-protected-write",
                "Write",
                {"file_path": ".gitignore", "content": "must-not-write\n"},
            )
        if request_number == 2:
            content, is_error = _result_text(request, "headless-protected-write")
            if not is_error or '"code":"permission_denied"' not in content:
                raise ScenarioError("headless protected Write was not denied")
            return _final_sse(request_number, "protected write was denied safely")
        raise ScenarioError("headless-permission-v1 received more than two requests")
    if scenario == "guessed-disabled-tool-v1":
        pair = (request_number + 1) // 2
        call_id = f"guessed-disabled-plan-{pair}"
        if request_number % 2 == 1:
            if "EnterPlanMode" in _tool_names(request):
                raise ScenarioError("disabled plan tool remained provider-visible")
            # Deliberately violate the advertised schema. The host must still
            # enforce the same ceiling at dispatch rather than trusting the
            # provider to call only declared tools.
            return _tool_sse(request_number, call_id, "EnterPlanMode", {})
        content, is_error = _result_text(request, call_id)
        if not is_error or '"code":"permission_denied"' not in content:
            raise ScenarioError("guessed disabled tool escaped dispatch policy")
        return _final_sse(request_number, "guessed disabled tool was denied safely")
    raise ScenarioError(f"unsupported scenario: {scenario}")


class _Handler(BaseHTTPRequestHandler):
    server_version = "metacodes-workbuddy-mock/1"

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
        if self.path != "/v1/messages":
            self.send_error(404)
            return
        if self.headers.get("Authorization") != f"Bearer {MOCK_CREDENTIAL}":
            self.send_error(401)
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.send_error(400)
            return
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self.send_error(413)
            return
        body = self.rfile.read(length)
        try:
            request = json.loads(body)
        except (UnicodeError, json.JSONDecodeError):
            self.send_error(400)
            return
        if not isinstance(request, dict) or not request.get("model") or not request.get("messages"):
            self.send_error(400)
            return
        with self.server.state_lock:  # type: ignore[attr-defined]
            number = self.server.requests + 1  # type: ignore[attr-defined]
            try:
                payload = _scenario_sse(self.server.scenario, number, request)  # type: ignore[attr-defined]
            except ScenarioError as exc:
                self.send_error(409, str(exc))
                return
            self.server.requests = number  # type: ignore[attr-defined]
            row = {
                "schema_version": SCHEMA_VERSION,
                "scenario": self.server.scenario,  # type: ignore[attr-defined]
                "request_number": number,
                "path": self.path,
                "body_sha256": hashlib.sha256(body).hexdigest(),
                "model": request.get("model"),
                "stream": request.get("stream"),
                "tool_names": sorted(_tool_names(request)),
                "tool_schema_sha256": hashlib.sha256(
                    json.dumps(
                        request.get("tools", []),
                        sort_keys=True,
                        separators=(",", ":"),
                    ).encode("utf-8")
                ).hexdigest(),
                "control_metrics_absent": b"control_metrics" not in body,
            }
            with self.server.request_log.open("ab") as handle:  # type: ignore[attr-defined]
                handle.write(json.dumps(row, sort_keys=True).encode("utf-8") + b"\n")
                handle.flush()
                os.fsync(handle.fileno())
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, _format: str, *_args: object) -> None:
        return


def serve(*, ready: Path, request_log: Path, port: int, scenario: str = "final-v1") -> None:
    import threading

    server = ThreadingHTTPServer(("127.0.0.1", port), _Handler)
    server.state_lock = threading.Lock()  # type: ignore[attr-defined]
    server.requests = 0  # type: ignore[attr-defined]
    server.request_log = request_log  # type: ignore[attr-defined]
    server.scenario = scenario  # type: ignore[attr-defined]
    try:
        _private_new(request_log, b"")
        _private_new(
            ready,
            (
                json.dumps(
                    {
                        "schema_version": SCHEMA_VERSION,
                        "scenario": scenario,
                        "port": server.server_port,
                    }
                )
                + "\n"
            ).encode("utf-8"),
        )
    except BaseException:
        server.server_close()
        raise
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ready", required=True, type=Path)
    parser.add_argument("--request-log", required=True, type=Path)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--scenario", choices=SCENARIOS, default="final-v1")
    args = parser.parse_args(argv)
    serve(
        ready=args.ready,
        request_log=args.request_log,
        port=args.port,
        scenario=args.scenario,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
