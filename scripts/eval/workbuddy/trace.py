"""Pure parsing helpers for the WorkBuddy metacodes adapter.

This module deliberately has no Harbor dependency.  The overlay agent converts
the returned intermediate representation into ATIF objects inside WorkBuddy's
pinned Python environment, while metacodes can test the lossy boundary with its
ordinary standard-library test suite.
"""

from __future__ import annotations

import json
import hashlib
import os
import re
import stat
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional
from urllib.parse import urlsplit, urlunsplit


MAX_TRACE_BYTES = 64 * 1024 * 1024
LEGACY_CONTROL_METRICS_SCHEMA = "metacodes-workbuddy-control-metrics-v1"
PROJECT_RULE_CONTROL_METRICS_SCHEMA = "metacodes-workbuddy-control-metrics-v2"
CONTROL_METRICS_SCHEMA = "metacodes-workbuddy-control-metrics-v3"
CONTROL_METRICS_SCHEMAS = frozenset(
    {
        LEGACY_CONTROL_METRICS_SCHEMA,
        PROJECT_RULE_CONTROL_METRICS_SCHEMA,
        CONTROL_METRICS_SCHEMA,
    }
)
OBSERVATION_JOURNAL_SCHEMA = "metacodes-tool-observation-journal-v1"
TOOL_OBSERVATION_SCHEMA = "metacodes-tool-observation-v1"
RULE_FILTER_SCHEMA = "metacodes-project-rule-filter-v1"
RULE_FILTER_PROOF = (
    "MetaCodesControl.ProjectRule.target_mismatch_admits_both"
)
FORMAL_DECISION_SCHEMAS = {
    "metacodes-project-formal-decision-v1",
    "metacodes-project-formal-decision-v2",
    "metacodes-project-formal-decision-batch-v2",
    "metacodes-project-formal-decision-batch-v3",
    "metacodes-project-formal-decision-batch-v4",
    "metacodes-project-formal-decision-batch-v5",
}
CURRENT_FORMAL_BATCH_SCHEMA = "metacodes-project-formal-decision-batch-v5"
OBSERVATION_FILENAME = "metacodes-tool-observations.jsonl"
_HEX64 = re.compile(r"^[0-9a-f]{64}$")
_KG_TOOLS = {"KgRemember", "KgRecall", "KgContext"}
_TASK_DAG_TOOLS = {"TaskCreate", "TaskGet", "TaskList", "TaskUpdate", "TaskStop"}
_MASK64 = (1 << 64) - 1


class TraceError(ValueError):
    """The captured headless output cannot support an auditable trajectory."""


def anthropic_messages_endpoint(proxy_url: str) -> str:
    """Turn a WorkBuddy proxy root into metacodes' complete messages URL.

    WorkBuddy models describe the job-private proxy by origin, while metacodes'
    ``METACODES_BASE_URL`` contract is a complete inference endpoint.  Keeping
    this conversion explicit makes the proxy classify the call as inference and
    rewrite the route alias to its pinned backend model.
    """

    if not isinstance(proxy_url, str) or "\n" in proxy_url or "\r" in proxy_url:
        raise TraceError("WorkBuddy proxy URL is invalid")
    parsed = urlsplit(proxy_url)
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.netloc
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/", "/v1/messages", "/v1/messages/"}
    ):
        raise TraceError("WorkBuddy proxy URL is not an HTTP origin or messages endpoint")
    return urlunsplit((parsed.scheme, parsed.netloc, "/v1/messages", "", ""))


def _rotl64(value: int, bits: int) -> int:
    return ((value << bits) | (value >> (64 - bits))) & _MASK64


def _xxhash64(value: bytes, seed: int = 0) -> int:
    """Match ``std.hash.XxHash64`` used by metacodes project state paths."""

    p1, p2 = 11400714785074694791, 14029467366897019727
    p3, p4, p5 = 1609587929392839161, 9650029242287828579, 2870177450012600261

    def round_(accumulator: int, lane: int) -> int:
        accumulator = (accumulator + lane * p2) & _MASK64
        return (_rotl64(accumulator, 31) * p1) & _MASK64

    offset = 0
    if len(value) >= 32:
        lanes = [
            (seed + p1 + p2) & _MASK64,
            (seed + p2) & _MASK64,
            seed & _MASK64,
            (seed - p1) & _MASK64,
        ]
        limit = len(value) - 32
        while offset <= limit:
            for index in range(4):
                lane = int.from_bytes(
                    value[offset + index * 8 : offset + (index + 1) * 8], "little"
                )
                lanes[index] = round_(lanes[index], lane)
            offset += 32
        result = sum(
            _rotl64(lane, rotation)
            for lane, rotation in zip(lanes, (1, 7, 12, 18))
        ) & _MASK64
        for lane in lanes:
            result ^= round_(0, lane)
            result = (result * p1 + p4) & _MASK64
    else:
        result = (seed + p5) & _MASK64

    result = (result + len(value)) & _MASK64
    while offset + 8 <= len(value):
        result ^= round_(0, int.from_bytes(value[offset : offset + 8], "little"))
        result = (_rotl64(result, 27) * p1 + p4) & _MASK64
        offset += 8
    if offset + 4 <= len(value):
        result ^= (int.from_bytes(value[offset : offset + 4], "little") * p1) & _MASK64
        result = (_rotl64(result, 23) * p2 + p3) & _MASK64
        offset += 4
    while offset < len(value):
        result ^= (value[offset] * p5) & _MASK64
        result = (_rotl64(result, 11) * p1) & _MASK64
        offset += 1
    result ^= result >> 33
    result = (result * p2) & _MASK64
    result ^= result >> 29
    result = (result * p3) & _MASK64
    result ^= result >> 32
    return result & _MASK64


def project_state_hash(project_root: str) -> str:
    """Return the exact 16-hex project directory key used by the Zig runtime."""

    return f"{_xxhash64(project_root.encode('utf-8')):016x}"


def _read_regular_bytes(path: Path, *, limit: int = MAX_TRACE_BYTES) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise TraceError(f"cannot open trace file {path}: {exc}") from exc
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise TraceError(f"trace path is not a regular file: {path}")
        if info.st_nlink != 1:
            raise TraceError(f"trace path has unexpected hard links: {path}")
        if info.st_size > limit:
            raise TraceError(f"trace file exceeds {limit} bytes: {path}")
        chunks: List[bytes] = []
        observed = 0
        while True:
            chunk = os.read(descriptor, min(65536, limit + 1 - observed))
            if not chunk:
                break
            chunks.append(chunk)
            observed += len(chunk)
            if observed > limit:
                raise TraceError(f"trace file grew beyond {limit} bytes: {path}")
        after = os.fstat(descriptor)
        identity = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
        if identity != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise TraceError(f"trace file changed while being observed: {path}")
        content = b"".join(chunks)
        if len(content) > limit:
            raise TraceError(f"trace file grew beyond {limit} bytes: {path}")
        return content
    except OSError as exc:
        raise TraceError(f"cannot read trace file {path}: {exc}") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _read_regular_file(path: Path, *, limit: int = MAX_TRACE_BYTES) -> str:
    try:
        return _read_regular_bytes(path, limit=limit).decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise TraceError(f"cannot read trace file {path}: {exc}") from exc


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _json_lines_from_text(
    content: str, path: Path, *, allow_prose: bool
) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for number, raw in enumerate(content.splitlines(), 1):
        line = raw.strip()
        if not line:
            continue
        if not line.startswith("{"):
            if allow_prose:
                continue
            raise TraceError(f"non-JSON evidence at {path}:{number}")
        def unique(pairs: List[tuple[str, Any]]) -> Dict[str, Any]:
            value: Dict[str, Any] = {}
            for key, item in pairs:
                if key in value:
                    raise TraceError(f"duplicate JSON field {key!r} at {path}:{number}")
                value[key] = item
            return value

        try:
            value = json.loads(line, object_pairs_hook=unique)
        except json.JSONDecodeError as exc:
            raise TraceError(f"malformed JSON at {path}:{number}: {exc}") from exc
        if not isinstance(value, dict):
            raise TraceError(f"JSON trace row is not an object at {path}:{number}")
        rows.append(value)
    return rows


def read_json_lines(path: Path, *, limit: int = MAX_TRACE_BYTES) -> List[Dict[str, Any]]:
    """Read JSON objects from a mixed-log NDJSON file.

    metacodes may emit diagnostic prose around its headless JSON lines.  Prose
    is ignored, but a line that claims to be JSON and is malformed is rejected:
    silently skipping a truncated result can turn a failed run into an empty
    successful trajectory.
    """

    return _json_lines_from_text(
        _read_regular_file(path, limit=limit), path, allow_prose=True
    )


def final_result(events: Iterable[Mapping[str, Any]]) -> Dict[str, Any]:
    results = [dict(row) for row in events if row.get("type") == "result"]
    if len(results) != 1:
        raise TraceError(f"expected exactly one metacodes result event, found {len(results)}")
    result = results[0]
    required = {
        "stop_reason": str,
        "turns": int,
        "tool_calls": int,
        "input_tokens": int,
        "output_tokens": int,
        "cost_usd": (int, float),
        "text": str,
    }
    for key, expected in required.items():
        value = result.get(key)
        if isinstance(value, bool) or not isinstance(value, expected):
            raise TraceError(f"result field {key!r} has invalid type")
    for key in ("turns", "tool_calls", "input_tokens", "output_tokens"):
        if result[key] < 0:
            raise TraceError(f"result field {key!r} must be non-negative")
    if float(result["cost_usd"]) < 0:
        raise TraceError("result cost_usd must be non-negative")
    for key in ("cache_read_input_tokens", "cache_creation_input_tokens"):
        value = result.get(key, 0)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise TraceError(f"result field {key!r} must be a non-negative integer")
        result[key] = value
    return result


def _tool_arguments(value: Any) -> Dict[str, Any]:
    if isinstance(value, dict):
        return dict(value)
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            return {"_raw_json": value}
        if isinstance(parsed, dict):
            return parsed
        return {"_raw_json": value}
    return {"_raw_value": value}


def _new_step(source: str, message: str = "") -> Dict[str, Any]:
    return {
        "source": source,
        "message": message,
        "reasoning_content": None,
        "tool_calls": [],
        "observations": [],
        "extra": {},
    }


def transcript_ir(
    messages: Iterable[Mapping[str, Any]],
    *,
    result: Optional[Mapping[str, Any]] = None,
) -> List[Dict[str, Any]]:
    """Convert metacodes transcript rows into an ATIF-shaped pure-Python IR."""

    steps: List[Dict[str, Any]] = []
    call_owner: Dict[str, int] = {}
    for message_index, row in enumerate(messages):
        role = row.get("role")
        if role not in {"user", "assistant"}:
            raise TraceError(f"transcript row {message_index} has invalid role")
        blocks = row.get("blocks")
        if not isinstance(blocks, list):
            raise TraceError(f"transcript row {message_index} has invalid blocks")

        text_parts: List[str] = []
        reasoning_parts: List[str] = []
        calls: List[Dict[str, Any]] = []
        results: List[Dict[str, Any]] = []
        for block_index, block in enumerate(blocks):
            if not isinstance(block, dict):
                raise TraceError(
                    f"transcript block {message_index}:{block_index} is not an object"
                )
            kind = block.get("type")
            if kind == "text":
                text_parts.append(str(block.get("text", "")))
            elif kind == "thinking":
                reasoning_parts.append(str(block.get("thinking", "")))
            elif kind == "tool_use":
                call_id = block.get("id")
                name = block.get("name")
                if not isinstance(call_id, str) or not call_id:
                    raise TraceError("tool_use is missing a non-empty id")
                if not isinstance(name, str) or not name:
                    raise TraceError("tool_use is missing a non-empty name")
                if call_id in call_owner:
                    raise TraceError(f"duplicate tool call id: {call_id}")
                calls.append(
                    {
                        "tool_call_id": call_id,
                        "function_name": name,
                        "arguments": _tool_arguments(block.get("input")),
                    }
                )
            elif kind == "tool_result":
                call_id = block.get("tool_use_id")
                if not isinstance(call_id, str) or not call_id:
                    raise TraceError("tool_result is missing a non-empty tool_use_id")
                results.append(
                    {
                        "source_call_id": call_id,
                        "content": str(block.get("content", "")),
                        "extra": {"is_error": bool(block.get("is_error", False))},
                    }
                )
            else:
                raise TraceError(f"unsupported transcript block type: {kind!r}")

        prose = "\n".join(part for part in text_parts if part)
        reasoning = "\n".join(part for part in reasoning_parts if part) or None
        if prose or reasoning or calls:
            step = _new_step("agent" if role == "assistant" else "user", prose)
            step["reasoning_content"] = reasoning
            step["tool_calls"] = calls
            steps.append(step)
            owner = len(steps) - 1
            for call in calls:
                call_owner[call["tool_call_id"]] = owner

        for observation in results:
            owner = call_owner.get(observation["source_call_id"])
            if owner is None:
                orphan = _new_step("user")
                orphan["observations"].append(observation)
                orphan["extra"]["orphan_tool_result"] = True
                steps.append(orphan)
            else:
                steps[owner]["observations"].append(observation)

    if not steps and result is not None and isinstance(result.get("text"), str):
        steps.append(_new_step("agent", str(result["text"])))
    if not steps:
        raise TraceError("transcript produced no ATIF steps")
    for step_id, step in enumerate(steps, 1):
        step["step_id"] = step_id
    return steps


def _non_negative_int(value: Any, where: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise TraceError(f"{where} must be a non-negative integer")
    return value


def _hex_identity(value: Any, where: str) -> str:
    if not isinstance(value, str) or _HEX64.fullmatch(value) is None:
        raise TraceError(f"{where} must be 64 lowercase hex characters")
    return value


def _result_json(content: Any, where: str) -> Any:
    if not isinstance(content, str):
        raise TraceError(f"{where} content is not text")
    try:
        return json.loads(content)
    except json.JSONDecodeError as exc:
        raise TraceError(f"{where} returned invalid JSON: {exc}") from exc


def _result_object(content: Any, where: str) -> Dict[str, Any]:
    value = _result_json(content, where)
    if not isinstance(value, dict):
        raise TraceError(f"{where} result is not a JSON object")
    return value


def _record_context_governance(
    tinykg: Dict[str, int], context: Mapping[str, Any], where: str
) -> None:
    """Validate and count one real TinyKG graph-governance observation.

    The observation can come from an explicit ``KgContext`` tool call or from
    the deterministic ``auto_context`` attached to a governed v3 recall.  The
    latter is not another model-issued tool call, but it is still a real host
    read and must not disappear from mechanism-effect statistics.
    """

    governance = context.get("knowledge_governance")
    if not isinstance(governance, dict):
        raise TraceError(f"{where} is missing knowledge governance evidence")
    if governance.get("schema_version") != "metacodes-knowledge-governance-v1":
        raise TraceError(f"{where} knowledge governance schema is unsupported")
    trust = governance.get("trust_state")
    trust_keys = {
        "evidence_connected_candidate": "context_evidence_connected",
        "unverified_candidate": "context_unverified",
        "contradicted": "context_contradicted",
        "superseded": "context_superseded",
        "incomplete_graph": "context_incomplete_graph",
    }
    if trust not in trust_keys:
        raise TraceError(f"{where} trust_state is unknown")
    tinykg["context_observations"] += 1
    tinykg[trust_keys[trust]] += 1


def _record_auto_context(
    tinykg: Dict[str, int],
    payload: Mapping[str, Any],
    hits: List[Mapping[str, Any]],
    declared_plan: Mapping[str, Any],
) -> None:
    raw = payload.get("auto_context")
    if raw is None:
        return
    if not isinstance(raw, dict):
        raise TraceError("KgRecall auto_context is malformed")
    if (
        raw.get("schema_version") != "metacodes-auto-context-v1"
        or raw.get("selection_policy")
        != "first_new_evidence_then_new_then_merged_v1"
        or declared_plan.get("intent") != "enumeration"
        or declared_plan.get("stage") != "semantic_expansion"
        or not hits
    ):
        raise TraceError("KgRecall auto_context contract is invalid")
    context = raw.get("context")
    if not isinstance(context, dict):
        raise TraceError("KgRecall auto_context context is malformed")
    node_id = context.get("node_id")
    graph = context.get("graph")
    graph_query = graph.get("query") if isinstance(graph, dict) else None
    if (
        isinstance(node_id, bool)
        or not isinstance(node_id, int)
        or node_id <= 0
        or not isinstance(graph_query, dict)
        or graph_query.get("root_id") != node_id
    ):
        raise TraceError("KgRecall auto_context is not bound to its graph root")
    first_new_evidence = next(
        (
            hit["node_id"]
            for hit in hits
            if hit.get("seen_before") is False and hit.get("type") == "evidence"
        ),
        None,
    )
    first_new = next(
        (hit["node_id"] for hit in hits if hit.get("seen_before") is False),
        None,
    )
    expected = first_new_evidence or first_new or hits[0]["node_id"]
    if node_id != expected:
        raise TraceError("KgRecall auto_context violates deterministic selection")
    _record_context_governance(tinykg, context, "KgRecall auto_context")
    tinykg["auto_context_succeeded"] += 1


def _task_list_has_kg_status(content: Any) -> bool:
    """Validate TaskList's public array contract and extract KG evidence.

    TaskList is intentionally the one task-DAG query whose result is a JSON
    array.  Task rows and the optional ``parallel_hint`` navigation row share
    that array; neither should be coerced into the object contract used by
    mutation tools merely to simplify the benchmark observer.
    """

    value = _result_json(content, "TaskList")
    if not isinstance(value, list):
        raise TraceError("TaskList result is not a JSON array")
    observed = False
    for item in value:
        if not isinstance(item, dict):
            raise TraceError("TaskList row is not an object")
        if "parallel_hint" in item:
            if set(item) != {"parallel_hint"} or not isinstance(
                item["parallel_hint"], str
            ) or not item["parallel_hint"]:
                raise TraceError("TaskList parallel hint is malformed")
            continue
        task_id = item.get("id")
        subject = item.get("subject")
        status = item.get("status")
        if (
            not isinstance(task_id, str)
            or not task_id
            or not isinstance(subject, str)
            or not subject
            or status not in {"pending", "in_progress", "completed", "blocked"}
        ):
            raise TraceError("TaskList task row is malformed")
        kg_status = item.get("kg_status")
        if kg_status is None:
            continue
        if not task_id.startswith("kg-") or kg_status not in {
            "open",
            "claimed",
            "completed",
            "failed",
        }:
            raise TraceError("TaskList kg_status is malformed")
        # One successful list call is one status-bearing observation, not one
        # state transition per row.  Mixed open/claimed rows are legitimate.
        observed = True
    return observed


def _tool_control_metrics(messages: Iterable[Mapping[str, Any]]) -> Dict[str, Any]:
    calls: Dict[str, Dict[str, Any]] = {}
    results: Dict[str, Dict[str, Any]] = {}
    for message_index, row in enumerate(messages):
        blocks = row.get("blocks")
        if not isinstance(blocks, list):
            raise TraceError(f"transcript row {message_index} has invalid blocks")
        for block_index, block in enumerate(blocks):
            if not isinstance(block, dict):
                raise TraceError(
                    f"transcript block {message_index}:{block_index} is not an object"
                )
            kind = block.get("type")
            if kind == "tool_use":
                call_id = block.get("id")
                name = block.get("name")
                if not isinstance(call_id, str) or not call_id or call_id in calls:
                    raise TraceError("control metrics found an invalid or duplicate tool call id")
                if not isinstance(name, str) or not name:
                    raise TraceError("control metrics found a tool call without a name")
                calls[call_id] = {"name": name, "input": block.get("input")}
            elif kind == "tool_result":
                call_id = block.get("tool_use_id")
                if not isinstance(call_id, str) or not call_id or call_id in results:
                    raise TraceError("control metrics found an invalid or duplicate tool result id")
                is_error = block.get("is_error", False)
                if not isinstance(is_error, bool):
                    raise TraceError("control metrics found a non-boolean tool error marker")
                results[call_id] = {
                    "content": block.get("content"),
                    "is_error": is_error,
                }
            elif kind not in {"text", "thinking"}:
                raise TraceError(f"control metrics found an unsupported transcript block: {kind!r}")
    orphan_results = sorted(set(results) - set(calls))
    if orphan_results:
        raise TraceError("control metrics found orphan tool results")

    tinykg = {
        "calls": 0,
        "succeeded": 0,
        "failed": 0,
        "remember_calls": 0,
        "remember_succeeded": 0,
        "recall_calls": 0,
        "recall_succeeded": 0,
        "recall_hit_calls": 0,
        "recall_miss_calls": 0,
        "recall_nodes": 0,
        "recall_new_nodes": 0,
        "recall_repeated_nodes": 0,
        "recall_governed_calls": 0,
        "context_calls": 0,
        "context_succeeded": 0,
        "auto_context_succeeded": 0,
        "context_observations": 0,
        "context_evidence_connected": 0,
        "context_unverified": 0,
        "context_contradicted": 0,
        "context_superseded": 0,
        "context_incomplete_graph": 0,
        "task_dag_calls": 0,
        "task_dag_succeeded": 0,
        "task_dag_failed": 0,
        "task_create_calls": 0,
        "task_get_calls": 0,
        "task_list_calls": 0,
        "task_update_calls": 0,
        "task_stop_calls": 0,
        "task_tinykg_status_results": 0,
        "task_terminal_commits": 0,
    }
    formal_tool = {"audit_calls": 0, "audit_succeeded": 0, "audit_failed": 0}
    for call_id, call in calls.items():
        name = call["name"]
        result = results.get(call_id)
        failed = result is None or result["is_error"]
        if name in _KG_TOOLS:
            tinykg["calls"] += 1
            tinykg["failed" if failed else "succeeded"] += 1
            key = {
                "KgRemember": "remember_calls",
                "KgRecall": "recall_calls",
                "KgContext": "context_calls",
            }[name]
            tinykg[key] += 1
            if failed:
                continue
            payload = _result_object(result["content"], name)
            if name == "KgRemember":
                tinykg["remember_succeeded"] += 1
            elif name == "KgRecall":
                hits = payload.get("hits")
                count = _non_negative_int(payload.get("count"), "KgRecall count")
                if not isinstance(hits, list) or len(hits) != count:
                    raise TraceError("KgRecall hits/count evidence is inconsistent")
                tinykg["recall_succeeded"] += 1
                tinykg["recall_nodes"] += count
                tinykg["recall_hit_calls" if count else "recall_miss_calls"] += 1
                plan = payload.get("lexical_query_plan")
                if plan is not None:
                    if not isinstance(plan, dict):
                        raise TraceError("KgRecall lexical plan receipt is malformed")
                    plan_version = plan.get("schema_version")
                    expected_scope = {
                        "lexical-query-plan-v1": "agent_run_plan",
                        "lexical-query-plan-v2": "agent_run_explicit",
                        "lexical-query-plan-v3": "agent_run_batch",
                    }.get(plan_version)
                    if (
                        expected_scope is None
                        or plan.get("seen_state_verified") is not True
                        or plan.get("ledger_scope") != expected_scope
                    ):
                        raise TraceError("KgRecall lexical plan governance receipt is invalid")
                    _hex_identity(plan.get("plan_sha256"), "KgRecall plan identity")
                    batch_v3 = plan_version == "lexical-query-plan-v3"
                    new_count = _non_negative_int(
                        plan.get("probe_new_hit_count" if batch_v3 else "new_hit_count"),
                        "KgRecall new_hit_count",
                    )
                    repeated_count = _non_negative_int(
                        plan.get("probe_repeated_hit_count" if batch_v3 else "repeated_hit_count"),
                        "KgRecall repeated_hit_count",
                    )
                    seen_ids = set()
                    observed_new = 0
                    observed_repeated = 0
                    for hit in hits:
                        if not isinstance(hit, dict):
                            raise TraceError("KgRecall hit is not an object")
                        node_id = hit.get("node_id")
                        seen_before = hit.get("seen_before")
                        if (
                            isinstance(node_id, bool)
                            or not isinstance(node_id, int)
                            or node_id <= 0
                            or node_id in seen_ids
                            or not isinstance(seen_before, bool)
                        ):
                            raise TraceError("KgRecall hit identity/gain evidence is invalid")
                        seen_ids.add(node_id)
                        if seen_before:
                            observed_repeated += 1
                        else:
                            observed_new += 1
                    if batch_v3:
                        call_input = call.get("input")
                        declared_plan = (
                            call_input.get("lexical_plan")
                            if isinstance(call_input, dict)
                            else None
                        )
                        declared_variants = (
                            declared_plan.get("variants")
                            if isinstance(declared_plan, dict)
                            else None
                        )
                        variant_receipts = plan.get("variant_receipts")
                        executed = _non_negative_int(
                            plan.get("executed_variant_count"),
                            "KgRecall executed_variant_count",
                        )
                        variant_count = _non_negative_int(
                            plan.get("variant_count"),
                            "KgRecall variant_count",
                        )
                        if (
                            not isinstance(call_input, dict)
                            or not isinstance(declared_plan, dict)
                            or declared_plan.get("schema_version") != plan_version
                            or not isinstance(declared_variants, list)
                            or not 1 <= len(declared_variants) <= 4
                            or variant_count != len(declared_variants)
                            or executed != variant_count
                            or plan.get("intent") != declared_plan.get("intent")
                            or plan.get("stage") != declared_plan.get("stage")
                            or plan.get("execution") != "host_batch_all"
                            or plan.get("all_variants_executed") is not True
                            or not isinstance(variant_receipts, list)
                            or len(variant_receipts) != executed
                            or _non_negative_int(plan.get("merged_hit_count"), "KgRecall merged_hit_count") != count
                            or _non_negative_int(plan.get("merged_new_hit_count"), "KgRecall merged_new_hit_count") != observed_new
                            or _non_negative_int(plan.get("merged_previously_seen_count"), "KgRecall merged_previously_seen_count") != observed_repeated
                        ):
                            raise TraceError("KgRecall batch coverage receipt is inconsistent")
                        receipt_new = 0
                        receipt_repeated = 0
                        probe_seen = {
                            hit["node_id"] for hit in hits if hit["seen_before"]
                        }
                        ordered_merged = []
                        for variant_index, (variant_receipt, declared_variant) in enumerate(
                            zip(variant_receipts, declared_variants)
                        ):
                            if (
                                not isinstance(variant_receipt, dict)
                                or not isinstance(declared_variant, dict)
                                or variant_receipt.get("variant_index") != variant_index
                                or variant_receipt.get("variant_kind")
                                != declared_variant.get("kind")
                            ):
                                raise TraceError("KgRecall batch variant receipt is malformed")
                            node_ids = variant_receipt.get("node_ids")
                            if (
                                not isinstance(node_ids, list)
                                or len(node_ids) > 8
                                or any(
                                    isinstance(node_id, bool)
                                    or not isinstance(node_id, int)
                                    or node_id <= 0
                                    for node_id in node_ids
                                )
                                or len(node_ids) != len(set(node_ids))
                            ):
                                raise TraceError("KgRecall batch variant node ids are malformed")
                            observed_probe_new = 0
                            observed_probe_repeated = 0
                            for node_id in node_ids:
                                if node_id not in seen_ids:
                                    raise TraceError("KgRecall batch variant references an unmerged node")
                                if node_id in probe_seen:
                                    observed_probe_repeated += 1
                                else:
                                    observed_probe_new += 1
                                    probe_seen.add(node_id)
                                if node_id not in ordered_merged:
                                    ordered_merged.append(node_id)
                            declared_new = _non_negative_int(
                                variant_receipt.get("new_hit_count"),
                                "KgRecall batch new_hit_count",
                            )
                            declared_repeated = _non_negative_int(
                                variant_receipt.get("repeated_hit_count"),
                                "KgRecall batch repeated_hit_count",
                            )
                            if (declared_new, declared_repeated) != (
                                observed_probe_new,
                                observed_probe_repeated,
                            ):
                                raise TraceError("KgRecall batch variant gain evidence is inconsistent")
                            receipt_new += declared_new
                            receipt_repeated += declared_repeated
                        if (
                            ordered_merged != [hit["node_id"] for hit in hits]
                            or (receipt_new, receipt_repeated)
                            != (new_count, repeated_count)
                        ):
                            raise TraceError("KgRecall batch information-gain receipt is inconsistent")
                        _record_auto_context(
                            tinykg, payload, hits, declared_plan
                        )
                    elif (new_count, repeated_count) != (
                        observed_new,
                        observed_repeated,
                    ):
                        raise TraceError("KgRecall information-gain receipt is inconsistent")
                    tinykg["recall_governed_calls"] += 1
                    tinykg["recall_new_nodes"] += new_count
                    tinykg["recall_repeated_nodes"] += repeated_count
            else:
                _record_context_governance(tinykg, payload, "KgContext")
                tinykg["context_succeeded"] += 1
        elif name in _TASK_DAG_TOOLS:
            tinykg["task_dag_calls"] += 1
            tinykg["task_dag_failed" if failed else "task_dag_succeeded"] += 1
            tinykg[{
                "TaskCreate": "task_create_calls",
                "TaskGet": "task_get_calls",
                "TaskList": "task_list_calls",
                "TaskUpdate": "task_update_calls",
                "TaskStop": "task_stop_calls",
            }[name]] += 1
            if not failed:
                if name == "TaskList":
                    if _task_list_has_kg_status(result["content"]):
                        tinykg["task_tinykg_status_results"] += 1
                    continue
                payload = _result_object(result["content"], name)
                kg_status = payload.get("kg_status")
                if kg_status is None and name == "TaskCreate":
                    task = payload.get("task")
                    task_id = task.get("id") if isinstance(task, dict) else None
                    if isinstance(task_id, str) and task_id.startswith("kg-"):
                        kg_status = "open"
                if kg_status is None and name == "TaskUpdate":
                    if payload.get("claimed") is True and isinstance(
                        payload.get("claimed_by"), str
                    ):
                        kg_status = "claimed"
                    elif payload.get("closed") is True:
                        kg_status = "completed"
                    elif payload.get("failed") is True:
                        kg_status = "failed"
                if kg_status is not None:
                    if kg_status not in {"open", "claimed", "completed", "failed"}:
                        raise TraceError(f"{name} kg_status is malformed")
                    tinykg["task_tinykg_status_results"] += 1
                    if kg_status in {"completed", "failed"}:
                        tinykg["task_terminal_commits"] += 1
        elif name == "FormalAuditTask":
            formal_tool["audit_calls"] += 1
            formal_tool["audit_failed" if failed else "audit_succeeded"] += 1
            if not failed:
                _result_object(result["content"], name)

    return {
        "transcript_tool_calls": len(calls),
        "transcript_tool_results": len(results),
        "transcript_calls_without_result": len(set(calls) - set(results)),
        "tinykg": tinykg,
        "formal_tool": formal_tool,
    }


def _formal_decision_metrics(payload: Mapping[str, Any], *, batch: bool) -> Dict[str, Any]:
    schema = payload.get("schema_version")
    if schema not in FORMAL_DECISION_SCHEMAS:
        raise TraceError("formal decision schema is unsupported")
    phase = payload.get("phase")
    actuation = payload.get("actuation")
    if phase not in {"pre", "post"} or actuation not in {"enforced", "shadow"}:
        raise TraceError("formal decision phase or actuation is invalid")
    kernel_sha = _hex_identity(payload.get("kernel_sha256"), "formal kernel identity")
    bundle_sha = _hex_identity(payload.get("bundle_sha256"), "formal bundle identity")
    checker_elapsed_ns = _non_negative_int(
        payload.get("checker_elapsed_ns"), "formal checker elapsed time"
    )
    checker_bytes = _non_negative_int(payload.get("checker_bytes"), "formal checker bytes")
    if batch:
        decisions = payload.get("decisions")
        size = _non_negative_int(payload.get("checker_batch_size"), "formal batch size")
        if (
            not isinstance(decisions, list)
            or not decisions
            or len(decisions) > size
            or (
                len(decisions) < size
                and isinstance(decisions[-1], dict)
                and decisions[-1].get("result") == "admit"
            )
        ):
            raise TraceError("formal decision batch cardinality is inconsistent")
        checker_call = _hex_identity(
            payload.get("checker_call_sha256"), "formal checker call identity"
        )
    else:
        decisions = [payload]
        size = _non_negative_int(payload.get("checker_batch_size", 1), "formal batch size")
        if size != 1:
            raise TraceError("legacy formal decision must have batch size one")
        raw_call = payload.get("checker_call_sha256")
        checker_call = (
            _hex_identity(raw_call, "formal checker call identity")
            if raw_call is not None
            else _sha256(
                (str(payload.get("request_sha256")) + str(payload.get("verdict_sha256"))).encode(
                    "ascii", errors="strict"
                )
            )
        )
    counts = {"admit": 0, "block": 0, "fault": 0, "recovery_directions": 0}
    operations = {
        "pre_decision": 0,
        "post_decision": 0,
        "recovery_pre_decision": 0,
        "recovery_post_decision": 0,
    }
    for decision in decisions:
        if not isinstance(decision, dict):
            raise TraceError("formal decision is not an object")
        result = decision.get("result")
        if result not in {"admit", "block", "fault"}:
            raise TraceError("formal decision result is invalid")
        counts[result] += 1
        operation = decision.get("operation")
        if operation is None and not batch:
            operation = "pre_decision" if phase == "pre" else "post_decision"
        if operation not in operations:
            raise TraceError("formal decision operation is invalid")
        operation_phase = "pre" if operation in {
            "pre_decision",
            "recovery_pre_decision",
        } else "post"
        if operation_phase != phase:
            raise TraceError("formal decision operation disagrees with its phase")
        operations[operation] += 1
        recovery = decision.get("recovery_action", "none")
        if recovery not in {"none", "edit_existing_file_exact"}:
            raise TraceError("formal recovery action is invalid")
        if recovery != "none" and result != "block":
            raise TraceError("formal recovery direction is not attached to a block")
        if recovery != "none":
            counts["recovery_directions"] += 1
    return {
        **counts,
        "operations": operations,
        "actuation": actuation,
        "kernel_sha256": kernel_sha,
        "bundle_sha256": bundle_sha,
        "checker_call_sha256": checker_call,
        "checker_elapsed_ns": checker_elapsed_ns,
        "checker_bytes": checker_bytes,
    }


def _rule_filter_metrics(payload: Mapping[str, Any]) -> Dict[str, Any]:
    if payload.get("schema_version") != RULE_FILTER_SCHEMA:
        raise TraceError("project rule filter schema is unsupported")
    dispatch_id = payload.get("dispatch_id")
    phase = payload.get("phase")
    operation = payload.get("operation")
    if not isinstance(dispatch_id, str) or not dispatch_id:
        raise TraceError("project rule filter dispatch identity is invalid")
    if phase not in {"pre", "post"} or operation not in {
        "ordinary",
        "exact_edit_recovery",
    }:
        raise TraceError("project rule filter phase or operation is invalid")
    if payload.get("proof") != RULE_FILTER_PROOF:
        raise TraceError("project rule filter proof identity is invalid")
    active = _non_negative_int(payload.get("active_rule_count"), "active rule count")
    checker = _non_negative_int(
        payload.get("checker_rule_count"), "checker rule count"
    )
    pruned = _non_negative_int(
        payload.get("statically_pruned_rule_count"), "statically pruned rule count"
    )
    if active == 0 or checker > active or pruned != active - checker:
        raise TraceError("project rule filter cardinality is inconsistent")
    if operation == "exact_edit_recovery" and checker == 0:
        raise TraceError("exact recovery filter erased its source rule")
    revision = _non_negative_int(payload.get("bundle_revision"), "filter bundle revision")
    if revision == 0:
        raise TraceError("project rule filter bundle revision is invalid")
    return {
        "dispatch_id": dispatch_id,
        "phase": phase,
        "operation": operation,
        "project_sha256": _hex_identity(
            payload.get("project_sha256"), "filter project identity"
        ),
        "bundle_sha256": _hex_identity(
            payload.get("bundle_sha256"), "filter bundle identity"
        ),
        "bundle_revision": revision,
        "kernel_sha256": _hex_identity(
            payload.get("kernel_sha256"), "filter kernel identity"
        ),
        "active_rule_count": active,
        "checker_rule_count": checker,
        "statically_pruned_rule_count": pruned,
    }


def _journal_control_metrics(rows: Iterable[Mapping[str, Any]]) -> Dict[str, Any]:
    records = list(rows)
    if len(records) < 2:
        raise TraceError("tool observation journal is incomplete")
    session_id: Optional[str] = None
    run_id: Optional[str] = None
    prior_elapsed = -1
    started: Dict[str, Mapping[str, Any]] = {}
    finished: Dict[str, Mapping[str, Any]] = {}
    outcome_counts = {
        name: 0
        for name in (
            "succeeded",
            "tool_error",
            "pending",
            "host_failed",
            "host_rejected",
            "host_fatal",
        )
    }
    formal = {
        "checker_calls": 0,
        "decisions": 0,
        "admit": 0,
        "block": 0,
        "fault": 0,
        "enforced_blocks": 0,
        "shadow_blocks": 0,
        "recovery_directions": 0,
        "checker_elapsed_ns": 0,
        "checker_elapsed_ns_max": 0,
        "checker_bytes_max": 0,
        "pre_decisions": 0,
        "post_decisions": 0,
        "recovery_pre_decisions": 0,
        "recovery_post_decisions": 0,
        "rule_filter_events": 0,
        "active_rule_phases": 0,
        "checker_rule_phases": 0,
        "statically_pruned_rule_phases": 0,
    }
    rule_filters: Dict[tuple[str, str], Dict[str, Any]] = {}
    filters_by_dispatch: Dict[str, Dict[str, Any]] = {}
    consumed_filters: set[tuple[str, str]] = set()
    checker_calls = set()
    kernel_ids = set()
    bundle_ids = set()
    actuations = set()
    run_started = 0
    run_finished = 0
    for expected_sequence, row in enumerate(records):
        if row.get("schema_version") != OBSERVATION_JOURNAL_SCHEMA:
            raise TraceError("tool observation journal schema is unsupported")
        if row.get("sequence") != expected_sequence:
            raise TraceError("tool observation journal sequence is not contiguous")
        elapsed = _non_negative_int(
            row.get("monotonic_elapsed_ns"), "journal monotonic elapsed time"
        )
        if elapsed < prior_elapsed:
            raise TraceError("tool observation journal time moved backwards")
        prior_elapsed = elapsed
        current_session = row.get("session_id")
        current_run = row.get("run_id")
        if not isinstance(current_session, str) or not current_session:
            raise TraceError("tool observation journal session identity is missing")
        if not isinstance(current_run, str) or not current_run:
            raise TraceError("tool observation journal run identity is missing")
        session_id = session_id or current_session
        run_id = run_id or current_run
        if current_session != session_id or current_run != run_id:
            raise TraceError("tool observation journal identity drifted")
        event = row.get("event")
        if not isinstance(event, dict) or len(event) != 1:
            raise TraceError("tool observation journal event is malformed")
        kind, payload = next(iter(event.items()))
        if not isinstance(payload, dict):
            raise TraceError("tool observation journal event payload is malformed")
        if kind == "run_started":
            run_started += 1
            if expected_sequence != 0:
                raise TraceError("run_started is not the first journal event")
        elif kind == "run_finished":
            run_finished += 1
            if expected_sequence != len(records) - 1:
                raise TraceError("run_finished is not the last journal event")
        elif kind != "tool_observation":
            raise TraceError("tool observation journal event kind is unsupported")
        else:
            if len(payload) != 1:
                raise TraceError("tool observation payload is malformed")
            observation_kind, observation = next(iter(payload.items()))
            if not isinstance(observation, dict):
                raise TraceError("tool observation payload is not an object")
            if observation_kind == "dispatch_started":
                if observation.get("schema_version") != TOOL_OBSERVATION_SCHEMA:
                    raise TraceError("dispatch observation schema is unsupported")
                dispatch_id = observation.get("id")
                if not isinstance(dispatch_id, str) or not dispatch_id or dispatch_id in started:
                    raise TraceError("dispatch start identity is invalid or duplicated")
                zero_filter = rule_filters.pop((dispatch_id, "pre"), None)
                if zero_filter is not None and zero_filter["checker_rule_count"] != 0:
                    raise TraceError("checker-backed pre filter bypassed its formal batch")
                if zero_filter is not None:
                    consumed_filters.add((dispatch_id, "pre"))
                if (
                    dispatch_id in filters_by_dispatch
                    and (dispatch_id, "pre") not in consumed_filters
                ):
                    raise TraceError("filtered dispatch is missing its pre authorization path")
                started[dispatch_id] = observation
            elif observation_kind == "dispatch_finished":
                if observation.get("schema_version") != TOOL_OBSERVATION_SCHEMA:
                    raise TraceError("dispatch observation schema is unsupported")
                dispatch_id = observation.get("id")
                if not isinstance(dispatch_id, str) or not dispatch_id or dispatch_id in finished:
                    raise TraceError("dispatch finish identity is invalid or duplicated")
                outcome = observation.get("outcome")
                if outcome not in outcome_counts:
                    raise TraceError("dispatch outcome is invalid")
                zero_filter = rule_filters.pop((dispatch_id, "post"), None)
                if zero_filter is not None and zero_filter["checker_rule_count"] != 0:
                    raise TraceError("checker-backed post filter bypassed its formal batch")
                if zero_filter is not None:
                    consumed_filters.add((dispatch_id, "post"))
                if (
                    dispatch_id in filters_by_dispatch
                    and (dispatch_id, "post") not in consumed_filters
                ):
                    raise TraceError("filtered dispatch is missing its post authorization path")
                outcome_counts[outcome] += 1
                finished[dispatch_id] = observation
            elif observation_kind in {"formal_decision", "formal_decision_batch"}:
                if (
                    observation_kind == "formal_decision_batch"
                    and observation.get("schema_version") == CURRENT_FORMAL_BATCH_SCHEMA
                ):
                    filter_key = (str(observation.get("dispatch_id")), str(observation.get("phase")))
                    filter_item = rule_filters.pop(filter_key, None)
                    if filter_item is None:
                        raise TraceError("current formal batch is missing its rule filter")
                    if (
                        filter_item["checker_rule_count"]
                        != observation.get("checker_batch_size")
                        or filter_item["project_sha256"]
                        != observation.get("project_sha256")
                        or filter_item["bundle_sha256"] != observation.get("bundle_sha256")
                        or filter_item["kernel_sha256"] != observation.get("kernel_sha256")
                        or filter_item["bundle_revision"]
                        != observation.get("bundle_revision")
                    ):
                        raise TraceError("project rule filter does not bind its formal batch")
                    consumed_filters.add(filter_key)
                item = _formal_decision_metrics(
                    observation, batch=observation_kind == "formal_decision_batch"
                )
                if observation_kind == "formal_decision_batch" and observation.get(
                    "schema_version"
                ) == CURRENT_FORMAL_BATCH_SCHEMA:
                    saw_recovery = (
                        item["operations"]["recovery_pre_decision"]
                        + item["operations"]["recovery_post_decision"]
                    ) > 0
                    if (filter_item["operation"] == "exact_edit_recovery") != saw_recovery:
                        raise TraceError("project rule filter operation disagrees with its batch")
                call_id = item["checker_call_sha256"]
                if call_id in checker_calls:
                    raise TraceError("formal checker call identity was reused")
                checker_calls.add(call_id)
                kernel_ids.add(item["kernel_sha256"])
                bundle_ids.add(item["bundle_sha256"])
                actuations.add(item["actuation"])
                formal["checker_calls"] += 1
                formal["decisions"] += item["admit"] + item["block"] + item["fault"]
                for key in ("admit", "block", "fault", "recovery_directions"):
                    formal[key] += item[key]
                formal[f"{item['actuation']}_blocks"] += item["block"]
                formal["checker_elapsed_ns"] += item["checker_elapsed_ns"]
                formal["checker_elapsed_ns_max"] = max(
                    formal["checker_elapsed_ns_max"], item["checker_elapsed_ns"]
                )
                formal["checker_bytes_max"] = max(
                    formal["checker_bytes_max"], item["checker_bytes"]
                )
                for operation, count in item["operations"].items():
                    formal[f"{operation.removesuffix('_decision')}_decisions"] += count
            elif observation_kind == "rule_filter":
                item = _rule_filter_metrics(observation)
                key = (item["dispatch_id"], item["phase"])
                if key in rule_filters:
                    raise TraceError("project rule filter was duplicated")
                prior = filters_by_dispatch.get(item["dispatch_id"])
                identity = {
                    name: item[name]
                    for name in (
                        "project_sha256",
                        "bundle_sha256",
                        "bundle_revision",
                        "kernel_sha256",
                        "active_rule_count",
                    )
                }
                if prior is not None and prior != identity:
                    raise TraceError("project rule filter identity drifted")
                filters_by_dispatch[item["dispatch_id"]] = identity
                rule_filters[key] = item
                formal["rule_filter_events"] += 1
                formal["active_rule_phases"] += item["active_rule_count"]
                formal["checker_rule_phases"] += item["checker_rule_count"]
                formal["statically_pruned_rule_phases"] += item[
                    "statically_pruned_rule_count"
                ]
            elif observation_kind == "verification_final_gate":
                # Terminal record of the session-end verification obligation:
                # exactly one per run, schema-pinned, both arms carry it (the
                # baseline in record-only observe mode). Surfaced so paired
                # analysis can read the obligation outcome from the ATIF row.
                if (
                    observation.get("schema_version")
                    != "metacodes-verification-final-gate-v1"
                    or not isinstance(observation.get("enforced"), bool)
                    or not isinstance(observation.get("obligation_met"), bool)
                ):
                    raise TraceError("verification final-gate record is invalid")
                if formal.get("verification_final_gate_records"):
                    raise TraceError("duplicate verification final-gate record")
                nudges = observation.get("nudges")
                if not isinstance(nudges, int) or isinstance(nudges, bool) or nudges < 0:
                    raise TraceError("verification final-gate nudges are invalid")
                # Integer counters only: the control-metrics contract validates
                # every value in this namespace as a non-negative integer, and
                # the keys appear only when the record exists so historical
                # trajectories recompute unchanged.
                formal["verification_final_gate_records"] = 1
                formal["verification_gate_enforced"] = int(
                    bool(observation.get("enforced"))
                )
                formal["verification_obligation_met"] = int(
                    bool(observation.get("obligation_met"))
                )
                formal["verification_mutations_occurred"] = int(
                    bool(observation.get("mutations_occurred"))
                )
                formal["verification_nudges"] = nudges
            elif observation_kind in {"rule_coverage_gap", "rule_bounds_overflow"}:
                # Diagnostic-only signals: no identity to cross-check here,
                # but count them so silence stays distinguishable from absence.
                formal[observation_kind + "_events"] = (
                    formal.get(observation_kind + "_events", 0) + 1
                )
            else:
                raise TraceError("tool observation kind is unsupported")
    if run_started != 1 or run_finished != 1:
        raise TraceError("tool observation journal must contain one complete run")
    if set(started) != set(finished):
        raise TraceError("tool dispatch observation pairs are incomplete")
    if rule_filters:
        raise TraceError("project rule filter was not consumed by checker or dispatch")
    for dispatch_id in started:
        before = started[dispatch_id]
        after = finished[dispatch_id]
        for key in ("requested_name", "dispatched_name", "origin", "agent_depth"):
            if before.get(key) != after.get(key):
                raise TraceError("tool dispatch identity changed between start and finish")
    return {
        "records": len(records),
        "session_id_sha256": _sha256(session_id.encode("utf-8")),
        "run_id_sha256": _sha256(run_id.encode("utf-8")),
        "dispatch_started": len(started),
        "dispatch_finished": len(finished),
        "dispatch_outcomes": outcome_counts,
        "formal": {
            **formal,
            "used": formal["checker_calls"] > 0 or formal["rule_filter_events"] > 0,
            "kernel_sha256s": sorted(kernel_ids),
            "bundle_sha256s": sorted(bundle_ids),
            "actuations": sorted(actuations),
        },
    }


def load_control_metrics(
    transcript_path: Path, observation_path: Path
) -> Dict[str, Any]:
    """Derive bounded post-run Lean/TinyKG metrics without retaining payload text."""

    transcript_bytes = _read_regular_bytes(transcript_path)
    observation_bytes = _read_regular_bytes(observation_path)
    try:
        transcript_text = transcript_bytes.decode("utf-8", errors="strict")
        observation_text = observation_bytes.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise TraceError(f"control evidence is not UTF-8: {exc}") from exc
    transcript = _json_lines_from_text(transcript_text, transcript_path, allow_prose=False)
    observations = _json_lines_from_text(
        observation_text, observation_path, allow_prose=False
    )
    tools = _tool_control_metrics(transcript)
    journal = _journal_control_metrics(observations)
    return {
        "schema_version": CONTROL_METRICS_SCHEMA,
        "source": {
            "transcript_sha256": _sha256(transcript_bytes),
            "observation_journal_sha256": _sha256(observation_bytes),
            "observation_journal_records": journal["records"],
            "session_id_sha256": journal["session_id_sha256"],
            "run_id_sha256": journal["run_id_sha256"],
        },
        "tool_runtime": {
            "transcript_tool_calls": tools["transcript_tool_calls"],
            "transcript_tool_results": tools["transcript_tool_results"],
            "transcript_calls_without_result": tools["transcript_calls_without_result"],
            "dispatch_started": journal["dispatch_started"],
            "dispatch_finished": journal["dispatch_finished"],
            "dispatch_outcomes": journal["dispatch_outcomes"],
        },
        "tinykg": {
            **tools["tinykg"],
            "used": tools["tinykg"]["calls"] > 0
            or tools["tinykg"]["task_dag_calls"] > 0,
        },
        "lean": {**journal["formal"], **tools["formal_tool"]},
        "privacy": {
            "tool_arguments_retained": False,
            "tool_results_retained": False,
            "memory_text_retained": False,
        },
    }


def load_trace_ir(output_path: Path, transcript_path: Path) -> Dict[str, Any]:
    events = read_json_lines(output_path)
    result = final_result(events)
    transcript = read_json_lines(transcript_path)
    return {
        "result": result,
        "steps": transcript_ir(transcript, result=result),
    }
