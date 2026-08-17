#!/usr/bin/env python3
"""Derive bounded, non-secret evidence from a tool-result provider cassette.

The raw cassette can contain prompts, tool output, and model text, so this
analyzer never copies those fields into its report.  It records sizes, hashes,
schema/state facts, usage, and whether a recovered byte range was echoed in the
final answer.  Raw cassettes remain local evaluation artifacts.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any, Iterable, Mapping


BASH_SCHEMA = "metacodes.bash-result.v2"
PROJECTION_SCHEMA = "metacodes.tool-result-projection.v1"
READ_SCHEMA = "metacodes.read-artifact.v1"


class EvaluationError(RuntimeError):
    pass


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _ordered_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, separators=(",", ":"), sort_keys=False
    ).encode("utf-8")


def _cassette_digest(paths: Iterable[Path]) -> str:
    digest = hashlib.sha256()
    for path in sorted(paths, key=lambda item: item.name):
        digest.update(path.name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def _load_json(path: Path) -> Mapping[str, Any]:
    try:
        value = json.loads(path.read_bytes())
    except (OSError, json.JSONDecodeError) as exc:
        raise EvaluationError(f"cannot read {path.name}: {exc}") from exc
    if not isinstance(value, dict):
        raise EvaluationError(f"{path.name} is not a JSON object")
    return value


def _content_blocks(body: Mapping[str, Any]) -> Iterable[Mapping[str, Any]]:
    messages = body.get("messages")
    if not isinstance(messages, list):
        return
    for message in messages:
        if not isinstance(message, dict):
            continue
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if isinstance(block, dict):
                yield block


def _tool_result(block: Mapping[str, Any]) -> tuple[str, bytes] | None:
    if block.get("type") != "tool_result" or not isinstance(block.get("content"), str):
        return None
    tool_use_id = block.get("tool_use_id")
    if not isinstance(tool_use_id, str) or not tool_use_id:
        return None
    return tool_use_id, block["content"].encode("utf-8")


def _request_prefix_stable(requests: list[Mapping[str, Any]]) -> bool:
    for previous, current in zip(requests, requests[1:]):
        old_messages = previous.get("messages")
        new_messages = current.get("messages")
        if not isinstance(old_messages, list) or not isinstance(new_messages, list):
            return False
        if len(new_messages) < len(old_messages):
            return False
        if _ordered_json_bytes(new_messages[: len(old_messages)]) != _ordered_json_bytes(
            old_messages
        ):
            return False
        for key in ("model", "system", "tools", "cache_control"):
            if previous.get(key) != current.get(key):
                return False
    return True


def _stable_prefix(requests: list[Mapping[str, Any]]) -> Mapping[str, Any]:
    fingerprints: set[str] = set()
    system_hashes: set[str] = set()
    tool_hashes: set[str] = set()
    for body in requests:
        system = body.get("system")
        tools = body.get("tools")
        if not isinstance(system, str) or not isinstance(tools, list):
            raise EvaluationError("normal request is missing system or tools")
        if body.get("cache_control") != {"type": "ephemeral"}:
            raise EvaluationError("request cache_control is not sealed ephemeral")
        system_bytes = system.encode("utf-8")
        tools_bytes = _ordered_json_bytes(tools)
        prefix = _ordered_json_bytes(
            {
                "model": body.get("model"),
                "system": system,
                "tools": tools,
                "cache_control": body.get("cache_control"),
            },
        )
        fingerprints.add(_sha256(prefix))
        system_hashes.add(_sha256(system_bytes))
        tool_hashes.add(_sha256(tools_bytes))
    return {
        "stable": len(fingerprints) == len(system_hashes) == len(tool_hashes) == 1,
        "sha256": next(iter(fingerprints)) if len(fingerprints) == 1 else None,
        "system_sha256": next(iter(system_hashes)) if len(system_hashes) == 1 else None,
        "tools_sha256": next(iter(tool_hashes)) if len(tool_hashes) == 1 else None,
    }


def _read_sse(path: Path) -> tuple[Mapping[str, int], str, str | None, bool]:
    usage: dict[str, int] = {}
    text_parts: list[str] = []
    stop_reason: str | None = None
    complete = False
    try:
        lines = path.read_text(encoding="utf-8", errors="strict").splitlines()
    except (OSError, UnicodeError) as exc:
        raise EvaluationError(f"cannot read {path.name}: {exc}") from exc
    for line in lines:
        if not line.startswith("data: "):
            continue
        try:
            event = json.loads(line[6:])
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") == "message_stop":
            complete = True
        candidate = event.get("usage")
        if not isinstance(candidate, dict) and isinstance(event.get("message"), dict):
            candidate = event["message"].get("usage")
        if isinstance(candidate, dict):
            for key in (
                "input_tokens",
                "output_tokens",
                "cache_read_input_tokens",
                "cache_creation_input_tokens",
            ):
                value = candidate.get(key)
                if isinstance(value, int) and value >= 0:
                    usage[key] = value
        delta = event.get("delta")
        if isinstance(delta, dict):
            if isinstance(delta.get("text"), str):
                text_parts.append(delta["text"])
            if isinstance(delta.get("stop_reason"), str):
                stop_reason = delta["stop_reason"]
    return usage, "".join(text_parts), stop_reason, complete


def _load_headless_result(path: Path | None) -> Mapping[str, Any] | None:
    if path is None:
        return None
    try:
        lines = [line for line in path.read_text(encoding="utf-8").splitlines() if line]
    except (OSError, UnicodeError) as exc:
        raise EvaluationError(f"cannot read headless result: {exc}") from exc
    if len(lines) != 1:
        raise EvaluationError("headless result must contain exactly one NDJSON event")
    try:
        result = json.loads(lines[0])
    except json.JSONDecodeError as exc:
        raise EvaluationError(f"invalid headless result: {exc}") from exc
    if not isinstance(result, dict) or result.get("type") != "result":
        raise EvaluationError("headless result event is missing")
    return result


def _load_wall_seconds(path: Path | None) -> float | None:
    if path is None:
        return None
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise EvaluationError(f"cannot read time receipt: {exc}") from exc
    values = [line.split(maxsplit=1)[1] for line in lines if line.startswith("real ")]
    if len(values) != 1:
        raise EvaluationError("time receipt must contain exactly one real value")
    try:
        value = float(values[0])
    except ValueError as exc:
        raise EvaluationError("time receipt real value is invalid") from exc
    if value < 0:
        raise EvaluationError("time receipt real value is negative")
    return value


def analyze(
    cassette: Path,
    expected_offset: int | None,
    expected_limit: int | None,
    headless_result_path: Path | None = None,
    time_path: Path | None = None,
) -> Mapping[str, Any]:
    request_paths = sorted(cassette.glob("req-*.json"))
    response_paths = sorted(cassette.glob("sse-*.txt"))
    if not request_paths or len(request_paths) != len(response_paths):
        raise EvaluationError("cassette request/response count is empty or mismatched")
    requests = [_load_json(path) for path in request_paths]
    headless = _load_headless_result(headless_result_path)
    wall_seconds = _load_wall_seconds(time_path)

    result_digests: dict[str, set[str]] = {}
    result_occurrences: dict[str, int] = {}
    bash_results: dict[str, Mapping[str, Any]] = {}
    read_results: dict[str, Mapping[str, Any]] = {}
    projection_artifacts = 0
    projection_fallbacks = 0
    for body in requests:
        for block in _content_blocks(body):
            tool_result = _tool_result(block)
            if tool_result is None:
                continue
            tool_use_id, raw = tool_result
            result_digests.setdefault(tool_use_id, set()).add(_sha256(raw))
            result_occurrences[tool_use_id] = result_occurrences.get(tool_use_id, 0) + 1
            try:
                value = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if not isinstance(value, dict):
                continue
            schema = value.get("schema_version")
            if schema == BASH_SCHEMA:
                bash_results[tool_use_id] = value
            elif schema == READ_SCHEMA:
                read_results[tool_use_id] = value
            elif schema == PROJECTION_SCHEMA:
                projection = value.get("projection")
                projection_artifacts += int(projection == "artifact")
                projection_fallbacks += int(projection == "fallback")
            elif isinstance(schema, str) and schema.startswith(
                ("metacodes.bash-result.", "metacodes.tool-result-projection.", "metacodes.read-artifact.")
            ):
                # A recognized envelope family at an unrecognized version:
                # counting it as absent would make a fully-unparsed run
                # indistinguishable from a clean one. Transcripts carry many
                # OTHER schema_version objects, so only these families are
                # closed here.
                raise EvaluationError(
                    f"unsupported tool-result envelope schema: {schema}"
                )

    usage_totals = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_read_input_tokens": 0,
        "cache_creation_input_tokens": 0,
    }
    final_text = ""
    stop_reasons: list[str | None] = []
    response_complete: list[bool] = []
    per_response_usage: list[Mapping[str, int]] = []
    for response_path in response_paths:
        usage, text, stop_reason, complete = _read_sse(response_path)
        per_response_usage.append(usage)
        for key in usage_totals:
            usage_totals[key] += usage.get(key, 0)
        final_text = text
        stop_reasons.append(stop_reason)
        response_complete.append(complete)
    if headless is not None:
        if isinstance(headless.get("text"), str):
            final_text = headless["text"]
        for key in usage_totals:
            value = headless.get(key)
            if isinstance(value, int) and value >= 0:
                usage_totals[key] = value

    recoveries: list[Mapping[str, Any]] = []
    bash_artifact_ids = {
        value.get(channel)
        for value in bash_results.values()
        for channel in ("stdout_artifact_id", "stderr_artifact_id")
        if isinstance(value.get(channel), str)
    }
    for value in read_results.values():
        data = value.get("data")
        offset = value.get("offset")
        returned = value.get("returned_bytes")
        artifact_id = value.get("artifact_id")
        matches_expected = (
            (expected_offset is None or offset == expected_offset)
            and (expected_limit is None or returned == expected_limit)
        )
        recoveries.append(
            {
                "artifact_matches_bash": artifact_id in bash_artifact_ids,
                "offset": offset,
                "returned_bytes": returned,
                "encoding": value.get("encoding"),
                "data_echoed_in_final": isinstance(data, str) and data in final_text,
                "matches_expected_range": matches_expected,
            }
        )

    uncached = usage_totals["input_tokens"]
    cached = usage_totals["cache_read_input_tokens"]
    effective = uncached + cached
    provider_prefix = _stable_prefix(requests)
    conversation_prefix_stable = _request_prefix_stable(requests)
    completed = (
        headless.get("stop_reason") == "end_turn"
        if headless is not None
        else stop_reasons[-1] == "end_turn"
    )
    # A model may make one bounded probe (for example offset 0) before the
    # requested read.  The claim is satisfied by at least one exact,
    # provenance-matching range that is copied into the final answer; unrelated
    # bounded reads are cost/latency observations, not correctness failures.
    recoveries_ok = any(
        item["artifact_matches_bash"]
        and item["matches_expected_range"]
        and item["data_echoed_in_final"]
        for item in recoveries
    )
    bash_recoverable = bool(bash_results) and all(
        value.get("stdout_capture_complete") is True
        and value.get("stdout_recoverable") is True
        and isinstance(value.get("stdout_sha256"), str)
        for value in bash_results.values()
    )
    return {
        "schema_version": "metacodes.tool-result-projection-eval.v1",
        "cassette": {
            "request_count": len(request_paths),
            "request_bytes": [path.stat().st_size for path in request_paths],
            "response_count": len(response_paths),
            "response_bytes": [path.stat().st_size for path in response_paths],
            "responses_complete": response_complete,
            "sha256": _cassette_digest([*request_paths, *response_paths]),
        },
        "cache": {
            "provider_prefix": provider_prefix,
            "conversation_prefix_stable": conversation_prefix_stable,
            "cache_read_ratio": (cached / effective) if effective else 0.0,
        },
        "tool_results": {
            "distinct": len(result_digests),
            "history_byte_stable": all(len(items) == 1 for items in result_digests.values()),
            "occurrences": sorted(result_occurrences.values()),
            "bash_v2": len(bash_results),
            "bash_recoverable": bash_recoverable,
            "read_artifact": len(read_results),
            "projection_artifacts": projection_artifacts,
            "projection_fallbacks": projection_fallbacks,
            "recoveries": recoveries,
            "recovery_success": recoveries_ok,
        },
        "provider": {
            "usage_totals": usage_totals,
            "per_response_usage": per_response_usage,
            "stop_reasons": stop_reasons,
            "completed": completed,
            "headless_result_present": headless is not None,
            "cost_usd": headless.get("cost_usd") if headless is not None else None,
            "turns": headless.get("turns") if headless is not None else None,
            "tool_calls": headless.get("tool_calls") if headless is not None else None,
            "declared_unrecoverable": "unrecoverable" in final_text,
            "wall_seconds": wall_seconds,
        },
        "claim_gate": {
            "passed": (
                provider_prefix["stable"]
                and conversation_prefix_stable
                and all(len(items) == 1 for items in result_digests.values())
                and bash_recoverable
                and recoveries_ok
                and projection_fallbacks == 0
                and completed
            )
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cassette", type=Path)
    parser.add_argument("--expected-offset", type=int)
    parser.add_argument("--expected-limit", type=int)
    parser.add_argument("--headless-result", type=Path)
    parser.add_argument("--time-file", type=Path)
    args = parser.parse_args()
    if args.expected_offset is not None and args.expected_offset < 0:
        parser.error("--expected-offset must be non-negative")
    if args.expected_limit is not None and args.expected_limit <= 0:
        parser.error("--expected-limit must be positive")
    try:
        report = analyze(
            args.cassette,
            args.expected_offset,
            args.expected_limit,
            args.headless_result,
            args.time_file,
        )
    except EvaluationError as exc:
        parser.exit(2, f"error: {exc}\n")
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if report["claim_gate"]["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
