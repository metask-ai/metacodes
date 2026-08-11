"""Pure parsing helpers for the WorkBuddy metacodes adapter.

This module deliberately has no Harbor dependency.  The overlay agent converts
the returned intermediate representation into ATIF objects inside WorkBuddy's
pinned Python environment, while metacodes can test the lossy boundary with its
ordinary standard-library test suite.
"""

from __future__ import annotations

import json
import os
import stat
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional


MAX_TRACE_BYTES = 64 * 1024 * 1024


class TraceError(ValueError):
    """The captured headless output cannot support an auditable trajectory."""


def _read_regular_file(path: Path, *, limit: int = MAX_TRACE_BYTES) -> str:
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
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            content = handle.read(limit + 1)
        if len(content) > limit:
            raise TraceError(f"trace file grew beyond {limit} bytes: {path}")
        return content.decode("utf-8", errors="strict")
    except (OSError, UnicodeDecodeError) as exc:
        raise TraceError(f"cannot read trace file {path}: {exc}") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def read_json_lines(path: Path, *, limit: int = MAX_TRACE_BYTES) -> List[Dict[str, Any]]:
    """Read JSON objects from a mixed-log NDJSON file.

    metacodes may emit diagnostic prose around its headless JSON lines.  Prose
    is ignored, but a line that claims to be JSON and is malformed is rejected:
    silently skipping a truncated result can turn a failed run into an empty
    successful trajectory.
    """

    rows: List[Dict[str, Any]] = []
    for number, raw in enumerate(_read_regular_file(path, limit=limit).splitlines(), 1):
        line = raw.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise TraceError(f"malformed JSON at {path}:{number}: {exc}") from exc
        if not isinstance(value, dict):
            raise TraceError(f"JSON trace row is not an object at {path}:{number}")
        rows.append(value)
    return rows


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


def load_trace_ir(output_path: Path, transcript_path: Path) -> Dict[str, Any]:
    events = read_json_lines(output_path)
    result = final_result(events)
    transcript = read_json_lines(transcript_path)
    return {
        "result": result,
        "steps": transcript_ir(transcript, result=result),
    }
