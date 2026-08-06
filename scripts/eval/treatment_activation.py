"""Execution-grounded attestation for the long-horizon TinyKG treatment.

The experiment manifest says that the TinyKG arm has a persistent task DAG.
That declaration is not treatment evidence.  This module binds three separate
surfaces before a rollout can be admitted:

* the native event stream proves which tool bytes actually crossed the runtime;
* the append-only transcript supplies those bytes without trusting debug logs;
* the frozen TinyKG executable re-reads the scratch store and proves that the
  same task is still completed with independent verification evidence.

No scenario answer or task-specific string is inspected here.  The contract is
mechanical: one persistent task must move create -> claim -> completed, while a
baseline arm must not expose a persistent TinyKG lifecycle at all.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, Mapping

from .model import ValidationError, validate_treatment_activation_receipt


ACTIVATION_SCHEMA_VERSION = 1
ACTIVATION_CONTRACT = "metacodes-treatment-activation-v1"
PERSISTENT_EXPECTATION = "persistent_task_lifecycle"
ABSENT_EXPECTATION = "persistent_tinykg_lifecycle_absent"
EVENT_SCHEMA_VERSION = 3
MAX_EVENTS_BYTES = 64 * 1024 * 1024
MAX_TRANSCRIPT_BYTES = 16 * 1024 * 1024
MAX_LINE_BYTES = 4 * 1024 * 1024
PACKET_TIMEOUT_SECONDS = 20
STORE_RELATIVE_PATH = Path(".home/.metacodes/kg/store.kg")
CLEARED_TOOL_RESULT_STUB = "[tool result cleared to save context]"
TOOL_RESULT_COMMITMENT_RE = re.compile(
    r"^\[tool-result-commitment original_bytes=([0-9]+) "
    r"sha256=([0-9a-f]{64})\]$"
)


@dataclass(frozen=True)
class ToolUse:
    tool_use_id: str
    name: str
    input_text: str
    result_text: str
    result_is_error: bool


@dataclass(frozen=True)
class NativeCall:
    tool_use_id: str
    name: str
    started_sequence: int
    finished_sequence: int
    input_bytes: int
    input_sha256: str
    result_bytes: int
    result_sha256: str
    is_error: bool


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _is_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(char in "0123456789abcdef" for char in value)
    )


def _read_regular_file(path: Path, *, label: str, max_bytes: int) -> bytes:
    try:
        info = path.lstat()
    except OSError as exc:
        raise ValidationError(f"treatment activation cannot stat {label}: {exc}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise ValidationError(f"treatment activation {label} must be a regular file")
    if info.st_size > max_bytes:
        raise ValidationError(
            f"treatment activation {label} exceeds {max_bytes} bytes"
        )
    try:
        payload = path.read_bytes()
    except OSError as exc:
        raise ValidationError(f"treatment activation cannot read {label}: {exc}") from exc
    if len(payload) != info.st_size:
        raise ValidationError(f"treatment activation {label} changed while being read")
    return payload


def _parse_json_lines(payload: bytes, *, label: str) -> list[Mapping[str, Any]]:
    rows: list[Mapping[str, Any]] = []
    for line_no, raw_line in enumerate(payload.splitlines(), 1):
        if not raw_line.strip():
            continue
        if len(raw_line) > MAX_LINE_BYTES:
            raise ValidationError(
                f"treatment activation {label}:{line_no} exceeds {MAX_LINE_BYTES} bytes"
            )
        try:
            value = json.loads(raw_line)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValidationError(
                f"treatment activation {label}:{line_no} is invalid JSON: {exc}"
            ) from exc
        if not isinstance(value, dict):
            raise ValidationError(
                f"treatment activation {label}:{line_no} must be a JSON object"
            )
        rows.append(value)
    if not rows:
        raise ValidationError(f"treatment activation {label} is empty")
    return rows


def _non_empty_string(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValidationError(f"{where}: expected non-empty string")
    return value


def _parse_transcript(payload: bytes) -> Dict[str, ToolUse]:
    uses: Dict[str, tuple[str, str]] = {}
    results: Dict[str, tuple[str, bool]] = {}
    for row_no, row in enumerate(
        _parse_json_lines(payload, label="transcript.jsonl"), 1
    ):
        blocks = row.get("blocks")
        if not isinstance(blocks, list):
            raise ValidationError(
                f"treatment activation transcript.jsonl:{row_no}.blocks must be an array"
            )
        for block_no, block in enumerate(blocks):
            if not isinstance(block, dict):
                raise ValidationError(
                    f"treatment activation transcript.jsonl:{row_no}.blocks[{block_no}] "
                    "must be an object"
                )
            kind = block.get("type")
            if kind == "tool_use":
                tool_use_id = _non_empty_string(
                    block.get("id"), "treatment activation tool_use.id"
                )
                name = _non_empty_string(
                    block.get("name"), "treatment activation tool_use.name"
                )
                input_text = _non_empty_string(
                    block.get("input"), "treatment activation tool_use.input"
                )
                if tool_use_id in uses:
                    raise ValidationError(
                        f"treatment activation transcript duplicates tool_use id {tool_use_id!r}"
                    )
                uses[tool_use_id] = (name, input_text)
            elif kind == "tool_result":
                tool_use_id = _non_empty_string(
                    block.get("tool_use_id"),
                    "treatment activation tool_result.tool_use_id",
                )
                content = block.get("content")
                is_error = block.get("is_error")
                if not isinstance(content, str) or not isinstance(is_error, bool):
                    raise ValidationError(
                        "treatment activation tool_result requires string content and "
                        "boolean is_error"
                    )
                if tool_use_id in results:
                    raise ValidationError(
                        f"treatment activation transcript duplicates tool_result id {tool_use_id!r}"
                    )
                results[tool_use_id] = (content, is_error)

    dangling_results = sorted(set(results) - set(uses))
    if dangling_results:
        raise ValidationError(
            f"treatment activation transcript has results without uses: {dangling_results}"
        )
    missing_results = sorted(set(uses) - set(results))
    if missing_results:
        raise ValidationError(
            f"treatment activation transcript has uses without results: {missing_results}"
        )
    return {
        tool_use_id: ToolUse(
            tool_use_id=tool_use_id,
            name=name,
            input_text=input_text,
            result_text=results[tool_use_id][0],
            result_is_error=results[tool_use_id][1],
        )
        for tool_use_id, (name, input_text) in uses.items()
        if tool_use_id in results
    }


def _parse_native_events(
    payload: bytes,
) -> tuple[Mapping[str, Any], Dict[str, NativeCall]]:
    # Native sequence numbers are local to one agent-loop invocation.  The E2E
    # driver appends several invocations to the same artifact, so every new
    # run_started legitimately restarts at zero.  Keep the raw sequence for
    # per-trace integrity, but use the append ordinal below for lifecycle order
    # across invocations.
    starts: Dict[str, tuple[str, str, int, int, str]] = {}
    finishes: Dict[str, tuple[str, str, int, int, str, bool]] = {}
    run_metadata: list[Mapping[str, Any]] = []
    trace_ids: set[str] = set()
    active_trace_id: str | None = None
    active_session_id: str | None = None
    expected_sequence = 0
    identity_keys = (
        "run_id",
        "trial",
        "suite_id",
        "task_id",
        "task_fingerprint",
        "task_fingerprint_provenance",
        "model_provider",
        "model_id",
        "model_fingerprint",
        "runtime_model_provider",
        "runtime_model_id",
        "harness_config_id",
        "harness_revision",
        "harness_fingerprint",
        "permission_mode",
        "runtime_permission_mode",
        "environment_fingerprint",
        "grader_fingerprint",
        "max_metered_tokens",
        "max_cost_usd",
    )
    for row_no, envelope in enumerate(
        _parse_json_lines(payload, label="events.jsonl"), 1
    ):
        if envelope.get("schema_version") != EVENT_SCHEMA_VERSION:
            raise ValidationError(
                f"treatment activation events.jsonl:{row_no} has unsupported schema"
            )
        sequence = envelope.get("sequence")
        if not isinstance(sequence, int) or isinstance(sequence, bool):
            raise ValidationError(
                f"treatment activation events.jsonl:{row_no}.sequence is invalid"
            )
        session_id = envelope.get("session_id")
        if not isinstance(session_id, str) or not session_id:
            raise ValidationError(
                f"treatment activation events.jsonl:{row_no}.session_id is invalid"
            )
        monotonic_elapsed_ns = envelope.get("monotonic_elapsed_ns")
        if (
            not isinstance(monotonic_elapsed_ns, int)
            or isinstance(monotonic_elapsed_ns, bool)
            or monotonic_elapsed_ns < 0
        ):
            raise ValidationError(
                f"treatment activation events.jsonl:{row_no}.monotonic_elapsed_ns is invalid"
            )
        event = envelope.get("event")
        if not isinstance(event, dict) or len(event) != 1:
            raise ValidationError(
                f"treatment activation events.jsonl:{row_no}.event must have one variant"
            )
        kind, value = next(iter(event.items()))
        if not isinstance(value, dict):
            raise ValidationError(
                f"treatment activation events.jsonl:{row_no}.{kind} must be an object"
            )
        trace_id = _non_empty_string(
            value.get("trace_id"),
            f"treatment activation events.jsonl:{row_no}.{kind}.trace_id",
        )
        if kind == "run_started":
            if active_trace_id is not None:
                raise ValidationError(
                    "treatment activation native invocation started before the prior "
                    f"trace {active_trace_id!r} finished"
                )
            if trace_id in trace_ids:
                raise ValidationError(
                    f"treatment activation native events duplicate trace {trace_id!r}"
                )
            metadata = value.get("metadata")
            if not isinstance(metadata, dict):
                raise ValidationError(
                    f"treatment activation events.jsonl:{row_no}.run_started has no metadata"
                )
            invocation = metadata.get("invocation")
            if (
                not isinstance(invocation, int)
                or isinstance(invocation, bool)
                or invocation != len(run_metadata)
            ):
                raise ValidationError(
                    "treatment activation native invocation identities are not contiguous: "
                    f"expected {len(run_metadata)}, observed {invocation!r}"
                )
            if run_metadata and any(
                metadata.get(key) != run_metadata[0].get(key) for key in identity_keys
            ):
                raise ValidationError(
                    "treatment activation native events mix execution identities"
                )
            run_metadata.append(metadata)
            trace_ids.add(trace_id)
            active_trace_id = trace_id
            active_session_id = session_id
            expected_sequence = 0
        elif active_trace_id is None:
            raise ValidationError(
                f"treatment activation native {kind} appears outside an invocation"
            )

        if trace_id != active_trace_id:
            raise ValidationError(
                "treatment activation native trace changed within an invocation: "
                f"expected {active_trace_id!r}, observed {trace_id!r}"
            )
        if session_id != active_session_id:
            raise ValidationError(
                f"treatment activation native trace {trace_id!r} changed session_id"
            )
        if sequence != expected_sequence:
            raise ValidationError(
                "treatment activation native event sequence is not contiguous within "
                f"trace {trace_id!r}: expected {expected_sequence}, observed {sequence}"
            )
        expected_sequence += 1

        # The zero-based append ordinal is globally ordered even though the raw
        # native sequence restarts for every invocation.
        global_sequence = row_no - 1
        if kind == "run_started":
            continue
        elif kind == "tool_started":
            tool_use_id = _non_empty_string(
                value.get("id"), "treatment activation tool_started.id"
            )
            name = _non_empty_string(
                value.get("name"), "treatment activation tool_started.name"
            )
            input_bytes = value.get("input_bytes")
            input_sha256 = value.get("input_sha256")
            if (
                not isinstance(input_bytes, int)
                or isinstance(input_bytes, bool)
                or input_bytes < 0
                or not _is_sha256(input_sha256)
            ):
                raise ValidationError(
                    f"treatment activation tool_started {tool_use_id!r} has invalid digest"
                )
            if tool_use_id in starts:
                raise ValidationError(
                    f"treatment activation native events duplicate start {tool_use_id!r}"
                )
            starts[tool_use_id] = (
                trace_id,
                name,
                global_sequence,
                input_bytes,
                input_sha256,
            )
        elif kind == "tool_finished":
            tool_use_id = _non_empty_string(
                value.get("id"), "treatment activation tool_finished.id"
            )
            name = _non_empty_string(
                value.get("name"), "treatment activation tool_finished.name"
            )
            result_bytes = value.get("result_bytes")
            result_sha256 = value.get("result_sha256")
            is_error = value.get("is_error")
            if (
                not isinstance(result_bytes, int)
                or isinstance(result_bytes, bool)
                or result_bytes < 0
                or not _is_sha256(result_sha256)
                or not isinstance(is_error, bool)
            ):
                raise ValidationError(
                    f"treatment activation tool_finished {tool_use_id!r} has invalid digest"
                )
            if tool_use_id in finishes:
                raise ValidationError(
                    f"treatment activation native events duplicate finish {tool_use_id!r}"
                )
            finishes[tool_use_id] = (
                trace_id,
                name,
                global_sequence,
                result_bytes,
                result_sha256,
                is_error,
            )
        elif kind == "run_finished":
            dropped_events = value.get("dropped_events")
            if (
                not isinstance(dropped_events, int)
                or isinstance(dropped_events, bool)
                or dropped_events != 0
            ):
                raise ValidationError(
                    f"treatment activation native trace {trace_id!r} dropped events"
                )
            active_trace_id = None
            active_session_id = None
            expected_sequence = 0

    if not run_metadata:
        raise ValidationError("treatment activation native events have no run_started metadata")
    if active_trace_id is not None:
        raise ValidationError(
            f"treatment activation native trace {active_trace_id!r} is incomplete"
        )
    canonical_metadata = run_metadata[0]

    dangling = sorted((set(starts) ^ set(finishes)))
    if dangling:
        raise ValidationError(
            f"treatment activation native events have incomplete tool calls: {dangling}"
        )
    calls: Dict[str, NativeCall] = {}
    for tool_use_id, (
        start_trace,
        name,
        start_sequence,
        input_bytes,
        input_sha256,
    ) in starts.items():
        (
            finish_trace,
            finish_name,
            finish_sequence,
            result_bytes,
            result_sha256,
            is_error,
        ) = finishes[tool_use_id]
        if (
            start_trace != finish_trace
            or name != finish_name
            or start_sequence >= finish_sequence
        ):
            raise ValidationError(
                f"treatment activation native call {tool_use_id!r} has invalid lifecycle"
            )
        calls[tool_use_id] = NativeCall(
            tool_use_id=tool_use_id,
            name=name,
            started_sequence=start_sequence,
            finished_sequence=finish_sequence,
            input_bytes=input_bytes,
            input_sha256=input_sha256,
            result_bytes=result_bytes,
            result_sha256=result_sha256,
            is_error=is_error,
        )
    return canonical_metadata, calls


def _bind_tool_call(
    tool: ToolUse,
    native_calls: Mapping[str, NativeCall],
    *,
    require_success: bool = True,
) -> NativeCall:
    native = native_calls.get(tool.tool_use_id)
    if native is None or native.name != tool.name:
        raise ValidationError(
            f"treatment activation tool {tool.tool_use_id!r} is not bound to native events"
        )
    input_bytes = tool.input_text.encode("utf-8")
    result_commitment = _tool_result_commitment(tool.result_text)
    result_bytes = tool.result_text.encode("utf-8")
    expected_result_bytes = (
        len(result_bytes) if result_commitment is None else result_commitment[0]
    )
    expected_result_sha256 = (
        _sha256_bytes(result_bytes)
        if result_commitment is None
        else result_commitment[1]
    )
    if (
        native.input_bytes != len(input_bytes)
        or native.input_sha256 != _sha256_bytes(input_bytes)
        or native.result_bytes != expected_result_bytes
        or native.result_sha256 != expected_result_sha256
        or native.is_error != tool.result_is_error
    ):
        raise ValidationError(
            f"treatment activation transcript/native hash mismatch for {tool.tool_use_id!r}"
        )
    if require_success and native.is_error:
        raise ValidationError(
            f"treatment activation lifecycle tool {tool.tool_use_id!r} failed"
        )
    return native


def _tool_result_commitment(text: str) -> tuple[int, str] | None:
    """Resolve a context projection to its execution-time byte commitment.

    Evaluation traces intentionally avoid raw tool payloads.  When the live
    conversation clears or truncates a result, the projection must therefore
    retain the original byte count and SHA-256.  The old unauthenticated stub is
    rejected: accepting it would recreate the exact evidence hole this binding
    is meant to close.
    """
    lines = text.splitlines()
    commitment_line: str | None = None
    if text.startswith(CLEARED_TOOL_RESULT_STUB):
        if len(lines) < 2:
            raise ValidationError(
                "treatment activation projected tool result lacks a byte commitment"
            )
        commitment_line = lines[1]
    elif lines and lines[0].startswith("[tool-result-commitment "):
        commitment_line = lines[0]
    else:
        return None
    match = TOOL_RESULT_COMMITMENT_RE.fullmatch(commitment_line)
    if match is None:
        raise ValidationError(
            "treatment activation projected tool result has an invalid byte commitment"
        )
    return int(match.group(1)), match.group(2)


def _bind_all_tool_calls(
    transcript_calls: Mapping[str, ToolUse],
    native_calls: Mapping[str, NativeCall],
) -> None:
    """Require the two independent execution surfaces to describe the same calls.

    Binding only the three expected lifecycle calls would let a removed transcript
    row hide a forbidden baseline ``Kg*`` call while its native event remained.
    Exact id-set equality closes that negative-evidence hole.  Non-lifecycle tool
    failures are allowed here; rollout validity is decided separately.
    """
    transcript_ids = set(transcript_calls)
    native_ids = set(native_calls)
    if transcript_ids != native_ids:
        raise ValidationError(
            "treatment activation transcript/native tool-call identities differ: "
            f"transcript_only={sorted(transcript_ids - native_ids)}, "
            f"native_only={sorted(native_ids - transcript_ids)}"
        )
    for tool in transcript_calls.values():
        _bind_tool_call(tool, native_calls, require_success=False)


def _json_object(text: str, where: str) -> Mapping[str, Any]:
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ValidationError(f"{where}: invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ValidationError(f"{where}: expected JSON object")
    return value


def _projected_json_object(
    tool: ToolUse, where: str
) -> Mapping[str, Any] | None:
    if _tool_result_commitment(tool.result_text) is not None:
        return None
    return _json_object(tool.result_text, where)


def _trace_row(phase: str, native: NativeCall) -> Dict[str, Any]:
    return {
        "phase": phase,
        "tool_use_id": native.tool_use_id,
        "started_sequence": native.started_sequence,
        "finished_sequence": native.finished_sequence,
        "input_sha256": native.input_sha256,
        "result_sha256": native.result_sha256,
    }


def _task_lifecycle(
    transcript_calls: Mapping[str, ToolUse], native_calls: Mapping[str, NativeCall]
) -> tuple[int, list[Dict[str, Any]]]:
    task_calls = [
        tool
        for tool in transcript_calls.values()
        if tool.name in {"TaskCreate", "TaskUpdate"}
    ]
    bound = [(tool, _bind_tool_call(tool, native_calls)) for tool in task_calls]
    creates = [(tool, native) for tool, native in bound if tool.name == "TaskCreate"]
    if len(creates) != 1:
        raise ValidationError(
            "TinyKG treatment requires exactly one execution-grounded TaskCreate; "
            f"observed {len(creates)}"
        )
    create_tool, create_native = creates[0]
    create_input = _json_object(create_tool.input_text, "TaskCreate input")
    _non_empty_string(create_input.get("subject"), "TaskCreate input.subject")
    _non_empty_string(create_input.get("description"), "TaskCreate input.description")
    create_result = _projected_json_object(create_tool, "TaskCreate result")

    updates: list[
        tuple[ToolUse, NativeCall, Mapping[str, Any], Mapping[str, Any] | None]
    ] = []
    for tool, native in bound:
        if tool.name != "TaskUpdate":
            continue
        update_input = _json_object(tool.input_text, "TaskUpdate input")
        update_result = _projected_json_object(tool, "TaskUpdate result")
        updates.append((tool, native, update_input, update_result))
    if len(updates) != 2:
        raise ValidationError(
            "TinyKG treatment requires exactly claim and completed TaskUpdate calls; "
            f"observed {len(updates)}"
        )

    claim = next((row for row in updates if row[2].get("status") == "in_progress"), None)
    completed = next((row for row in updates if row[2].get("status") == "completed"), None)
    if claim is None or completed is None:
        raise ValidationError(
            "TinyKG treatment lifecycle must contain in_progress then completed"
        )
    _, claim_native, claim_input, claim_result = claim
    _, completed_native, completed_input, completed_result = completed
    task_id_text = claim_input.get("taskId")
    if (
        not isinstance(task_id_text, str)
        or not task_id_text.startswith("kg-")
        or not task_id_text[3:].isdigit()
        or completed_input.get("taskId") != task_id_text
    ):
        raise ValidationError(
            "TinyKG treatment used more than one valid persistent task lifecycle"
        )
    task_id = int(task_id_text[3:])
    if create_result is not None:
        task = create_result.get("task")
        if not isinstance(task, dict) or task.get("persisted") is not True:
            raise ValidationError(
                "TinyKG treatment TaskCreate did not return persisted=true"
            )
        if task.get("id") != task_id_text:
            raise ValidationError(
                "TinyKG treatment TaskCreate did not return the updated kg-* id"
            )
    if claim_result is not None:
        if claim_result.get("claimed") is not True:
            raise ValidationError("TinyKG treatment claim did not return claimed=true")
        packet = claim_result.get("task_packet")
        if (
            not isinstance(packet, dict)
            or not isinstance(packet.get("query"), dict)
            or packet["query"].get("task_id") != task_id
            or packet["query"].get("status") != "claimed"
        ):
            raise ValidationError("TinyKG treatment claim lacks the same live task packet")
    _non_empty_string(
        completed_input.get("conclusion"), "TaskUpdate completed conclusion"
    )
    if completed_result is not None and completed_result.get("closed") is not True:
        raise ValidationError("TinyKG treatment completion did not return closed=true")
    if not (
        create_native.finished_sequence < claim_native.started_sequence
        and claim_native.finished_sequence < completed_native.started_sequence
    ):
        raise ValidationError(
            "TinyKG treatment lifecycle is not ordered create -> claim -> completed"
        )
    return task_id, [
        _trace_row("created", create_native),
        _trace_row("claimed", claim_native),
        _trace_row("completed", completed_native),
    ]


def _safe_workspace_path(workspace: Path) -> Path:
    try:
        info = workspace.lstat()
        resolved = workspace.resolve(strict=True)
    except OSError as exc:
        raise ValidationError(f"treatment activation workspace is unavailable: {exc}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise ValidationError("treatment activation workspace must be a real directory")
    return resolved


def _store_packet(
    workspace: Path,
    tinykg_binary: Path,
    expected_tinykg_sha256: str,
    task_id: int,
) -> tuple[Mapping[str, Any], bytes, str]:
    store = workspace / STORE_RELATIVE_PATH
    try:
        store_info = store.lstat()
        if stat.S_ISLNK(store_info.st_mode) or not stat.S_ISDIR(store_info.st_mode):
            raise ValidationError("TinyKG treatment store must be a real directory")
        resolved_store = store.resolve(strict=True)
        resolved_store.relative_to(workspace)
    except ValidationError:
        raise
    except (OSError, ValueError) as exc:
        raise ValidationError(f"TinyKG treatment store is unavailable or escapes: {exc}") from exc
    manifest = store / ".tinykg/store-manifest.json"
    manifest_bytes = _read_regular_file(
        manifest, label="TinyKG store manifest", max_bytes=1024 * 1024
    )

    binary = tinykg_binary.resolve(strict=True)
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValidationError("TinyKG treatment verifier binary is not executable")
    before = _sha256_bytes(binary.read_bytes())
    if before != expected_tinykg_sha256:
        raise ValidationError(
            "TinyKG treatment verifier binary differs from frozen experiment identity"
        )
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("METACODES_") and not key.startswith("TINYKG_")
    }
    try:
        completed = subprocess.run(
            [
                str(binary),
                "task-packet",
                str(resolved_store),
                str(task_id),
                "--format",
                "json",
                "--meta",
                "--limit",
                "8",
                "--max-nodes",
                "16",
                "--max-edges",
                "24",
                "--max-chars",
                "200000",
            ],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=PACKET_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ValidationError(f"TinyKG task-packet verification failed: {exc}") from exc
    after = _sha256_bytes(binary.read_bytes())
    if after != before:
        raise ValidationError("TinyKG verifier binary changed during task-packet read")
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()[-1000:]
        raise ValidationError(
            f"TinyKG task-packet exited {completed.returncode}: {detail}"
        )
    packet_bytes = completed.stdout.strip()
    if len(packet_bytes) > 1024 * 1024:
        raise ValidationError("TinyKG task-packet exceeded verifier bound")
    try:
        packet = json.loads(packet_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValidationError(f"TinyKG task-packet is invalid JSON: {exc}") from exc
    if not isinstance(packet, dict):
        raise ValidationError("TinyKG task-packet must be an object")
    return packet, packet_bytes, _sha256_bytes(manifest_bytes)


def _verify_store_packet(packet: Mapping[str, Any], task_id: int) -> list[int]:
    query = packet.get("query")
    root = packet.get("root")
    summary = packet.get("summary")
    nodes = packet.get("nodes")
    edges = packet.get("edges")
    if (
        packet.get("schema_version") != "tinykg-agent-retrieval-v1"
        or packet.get("mode") != "task-packet"
        or not isinstance(query, dict)
        or query.get("task_id") != task_id
        or query.get("status") != "completed"
        or query.get("readiness") is not None
        or not isinstance(root, dict)
        or root.get("id") != task_id
        or root.get("kind") != "task"
        or not isinstance(summary, dict)
        or summary.get("truncated") is not False
        or not isinstance(nodes, list)
        or not isinstance(edges, list)
    ):
        raise ValidationError(
            "TinyKG treatment task-packet does not prove a complete terminal task"
        )
    node_kinds = {
        node.get("id"): node.get("kind")
        for node in nodes
        if isinstance(node, dict) and isinstance(node.get("id"), int)
    }
    verification_ids = sorted(
        {
            edge.get("dst")
            for edge in edges
            if isinstance(edge, dict)
            and edge.get("src") == task_id
            and edge.get("rel") == "verified_by"
            and edge.get("direction") == "outgoing"
            and edge.get("view_role") == "verified_by_out"
            and isinstance(edge.get("dst"), int)
            and node_kinds.get(edge.get("dst")) == "verification"
        }
    )
    if not verification_ids:
        raise ValidationError(
            "TinyKG treatment completed task has no verified_by verification node"
        )
    return verification_ids


def _execution_identity(metadata: Mapping[str, Any]) -> Dict[str, Any]:
    trial = metadata.get("trial")
    if not isinstance(trial, int) or isinstance(trial, bool) or trial < 0:
        raise ValidationError("treatment activation native metadata has invalid trial")
    return {
        "run_id": _non_empty_string(
            metadata.get("run_id"), "treatment activation native run_id"
        ),
        "suite_id": _non_empty_string(
            metadata.get("suite_id"), "treatment activation native suite_id"
        ),
        "task_id": _non_empty_string(
            metadata.get("task_id"), "treatment activation native task_id"
        ),
        "trial": trial,
        "harness_config_id": _non_empty_string(
            metadata.get("harness_config_id"),
            "treatment activation native harness_config_id",
        ),
    }


def attest_treatment_activation(
    workspace: Path,
    arm_id: str,
    tinykg_binary: Path,
    expected_tinykg_sha256: str,
) -> Dict[str, Any]:
    """Build one deterministic receipt from raw rollout artifacts."""
    if arm_id not in {"codex_style", "claude_style", "tinykg"}:
        raise ValidationError(f"unknown treatment activation arm {arm_id!r}")
    if not _is_sha256(expected_tinykg_sha256):
        raise ValidationError("treatment activation requires a frozen TinyKG SHA-256")
    try:
        resolved_binary = tinykg_binary.resolve(strict=True)
    except OSError as exc:
        raise ValidationError(f"frozen TinyKG binary is unavailable: {exc}") from exc
    if not resolved_binary.is_file() or not os.access(resolved_binary, os.X_OK):
        raise ValidationError("frozen TinyKG binary is not executable")
    if _sha256_bytes(resolved_binary.read_bytes()) != expected_tinykg_sha256:
        raise ValidationError(
            "TinyKG treatment verifier binary differs from frozen experiment identity"
        )
    root = _safe_workspace_path(workspace)
    events_bytes = _read_regular_file(
        root / "events.jsonl", label="events.jsonl", max_bytes=MAX_EVENTS_BYTES
    )
    transcript_bytes = _read_regular_file(
        root / "transcript.jsonl",
        label="transcript.jsonl",
        max_bytes=MAX_TRANSCRIPT_BYTES,
    )
    metadata, native_calls = _parse_native_events(events_bytes)
    transcript_calls = _parse_transcript(transcript_bytes)
    _bind_all_tool_calls(transcript_calls, native_calls)
    execution = _execution_identity(metadata)
    common = {
        "schema_version": ACTIVATION_SCHEMA_VERSION,
        "contract": ACTIVATION_CONTRACT,
        "arm_id": arm_id,
        "status": "verified",
        "execution": execution,
        "artifacts": {
            "events_sha256": _sha256_bytes(events_bytes),
            "transcript_sha256": _sha256_bytes(transcript_bytes),
            "tinykg_binary_sha256": expected_tinykg_sha256,
        },
    }
    if arm_id != "tinykg":
        persistent_tools = sorted(
            {
                tool.name
                for tool in transcript_calls.values()
                if tool.name.startswith("Kg")
            }
        )
        kg_updates = []
        persisted_creates = []
        for tool in transcript_calls.values():
            if tool.name not in {"TaskCreate", "TaskUpdate"}:
                continue
            input_value = _json_object(tool.input_text, f"{tool.name} input")
            result_value = _json_object(tool.result_text, f"{tool.name} result")
            if tool.name == "TaskUpdate" and str(input_value.get("taskId", "")).startswith(
                "kg-"
            ):
                kg_updates.append(tool.tool_use_id)
            task = result_value.get("task")
            if tool.name == "TaskCreate" and isinstance(task, dict) and (
                task.get("persisted") is True
                or str(task.get("id", "")).startswith("kg-")
            ):
                persisted_creates.append(tool.tool_use_id)
        store_path = root / STORE_RELATIVE_PATH
        if (
            persistent_tools
            or kg_updates
            or persisted_creates
            or store_path.exists()
            or store_path.is_symlink()
        ):
            raise ValidationError(
                f"{arm_id} unexpectedly activated persistent TinyKG treatment"
            )
        receipt = {
            **common,
            "expectation": ABSENT_EXPECTATION,
            "trace": [],
            "task": None,
            "store": {"present": False},
        }
        validate_treatment_activation_receipt(
            receipt, "treatment_activation", expected_arm=arm_id
        )
        return receipt

    task_id, trace = _task_lifecycle(transcript_calls, native_calls)
    packet, packet_bytes, manifest_sha256 = _store_packet(
        root, resolved_binary, expected_tinykg_sha256, task_id
    )
    verification_ids = _verify_store_packet(packet, task_id)
    receipt = {
        **common,
        "expectation": PERSISTENT_EXPECTATION,
        "trace": trace,
        "task": {"id": task_id, "kind": "task", "status": "completed"},
        "store": {
            "present": True,
            "relative_path": STORE_RELATIVE_PATH.as_posix(),
            "manifest_sha256": manifest_sha256,
            "packet_schema": "tinykg-agent-retrieval-v1",
            "packet_sha256": _sha256_bytes(packet_bytes),
            "verification_node_ids": verification_ids,
        },
    }
    validate_treatment_activation_receipt(
        receipt, "treatment_activation", expected_arm=arm_id
    )
    return receipt


def _workspace_from_rollout(rollout: Mapping[str, Any]) -> Path:
    artifacts = rollout.get("artifacts")
    if not isinstance(artifacts, dict):
        raise ValidationError("rollout artifacts are missing for treatment activation")
    workspace = artifacts.get("workspace")
    if not isinstance(workspace, str) or not workspace:
        raise ValidationError("rollout workspace is missing for treatment activation")
    return Path(workspace)


def _require_receipt_identity(
    receipt: Mapping[str, Any], rollout: Mapping[str, Any], arm_id: str
) -> None:
    validate_treatment_activation_receipt(
        receipt, "rollout.treatment_activation", expected_arm=arm_id
    )
    expected = {
        "run_id": rollout.get("run_id"),
        "suite_id": rollout.get("suite_id"),
        "task_id": rollout.get("task_id"),
        "trial": rollout.get("trial"),
        "harness_config_id": rollout.get("harness", {}).get("config_id")
        if isinstance(rollout.get("harness"), dict)
        else None,
    }
    if receipt.get("execution") != expected:
        raise ValidationError(
            "treatment activation receipt does not match normalized rollout identity"
        )


def attach_treatment_activation(
    rollout: Dict[str, Any],
    arm_id: str,
    tinykg_binary: Path,
    expected_tinykg_sha256: str,
) -> Dict[str, Any]:
    """Attest raw artifacts and attach the receipt to one normalized rollout."""
    receipt = attest_treatment_activation(
        _workspace_from_rollout(rollout),
        arm_id,
        tinykg_binary,
        expected_tinykg_sha256,
    )
    _require_receipt_identity(receipt, rollout, arm_id)
    rollout["treatment_activation"] = receipt
    return receipt


def reverify_treatment_activation(
    rollout: Mapping[str, Any],
    arm_id: str,
    tinykg_binary: Path,
    expected_tinykg_sha256: str,
) -> None:
    """Recompute the receipt; a copied JSON claim is never sufficient."""
    receipt = rollout.get("treatment_activation")
    if not isinstance(receipt, dict):
        raise ValidationError(
            f"{arm_id} rollout is missing treatment_activation receipt"
        )
    _require_receipt_identity(receipt, rollout, arm_id)
    observed = attest_treatment_activation(
        _workspace_from_rollout(rollout),
        arm_id,
        tinykg_binary,
        expected_tinykg_sha256,
    )
    if observed != receipt:
        raise ValidationError(
            f"{arm_id} treatment activation artifacts changed after attestation"
        )


def receipt_fingerprint(receipts: Iterable[Mapping[str, Any]]) -> str:
    """Stable paper/provenance digest for a complete receipt set."""
    payload = "\n".join(
        json.dumps(dict(receipt), ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        for receipt in receipts
    ).encode("utf-8")
    return _sha256_bytes(payload)
