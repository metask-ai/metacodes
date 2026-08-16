"""Derive private coding-progress statistics from local WorkBuddy evidence.

The analyzer is read-only and emits aggregate measurements only. It does not
write TinyKG, alter the benchmark receipt schema, or retain tool arguments and
results in its output. Its purpose is to measure whether a harness change gets
to a verified result sooner and avoids low-value work after that point.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shlex
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional

from .trace import TraceError, _json_lines_from_text, _read_regular_bytes


SCHEMA_VERSION = "metacodes-workbuddy-progress-analysis-v1"
_CHECKPOINT_PREFIX = "[verification checkpoint]\n"
_MUTATION_TOOLS = {"Write", "Edit", "NotebookEdit"}
_TEST_HEADS = {"pytest", "py.test", "ctest"}


def _observed_rows(path: Path) -> tuple[List[Dict[str, Any]], str]:
    payload = _read_regular_bytes(path)
    try:
        text = payload.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise TraceError(f"progress evidence is not UTF-8: {path}") from exc
    return (
        _json_lines_from_text(text, path, allow_prose=True),
        hashlib.sha256(payload).hexdigest(),
    )


def _arguments(value: Any) -> Dict[str, Any]:
    if isinstance(value, dict):
        return dict(value)
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            return {}
        return dict(parsed) if isinstance(parsed, dict) else {}
    return {}


def _result_object(content: Any) -> Optional[Dict[str, Any]]:
    if not isinstance(content, str):
        return None
    try:
        value = json.loads(content)
    except json.JSONDecodeError:
        return None
    return dict(value) if isinstance(value, dict) else None


def _safe_shell_tokens(command: str) -> Optional[tuple[List[str], bool]]:
    if any(marker in command for marker in ("\n", ";", "`", "$(")):
        return None
    display_pipe = False
    if "|" in command:
        if command.count("|") != 1:
            return None
        command, viewer = command.split("|", 1)
        try:
            viewer_tokens = shlex.split(viewer)
        except ValueError:
            return None
        if not viewer_tokens or Path(viewer_tokens[0]).name not in {"head", "tail"}:
            return None
        display_pipe = True
    # Match the runtime classifier: any number of directory changes may
    # precede exactly one final test, and every segment is joined by &&.
    parts = command.split("&&")
    if any(not part.strip() for part in parts):
        return None
    candidate = parts[-1].strip()
    for prefix_source in parts[:-1]:
        try:
            prefix = shlex.split(prefix_source)
        except ValueError:
            return None
        if not prefix or prefix[0] != "cd":
            return None
    try:
        tokens = shlex.split(candidate)
    except ValueError:
        return None
    while tokens and tokens[0] in {"timeout", "time", "nice", "env"}:
        # Bounded approximation matching the Zig observer: discard wrapper
        # options/assignments/numeric durations, then inspect the real command.
        tokens = tokens[1:]
        while tokens and (
            tokens[0].startswith("-")
            or "=" in tokens[0]
            or re.fullmatch(r"\d+[smh]?", tokens[0]) is not None
        ):
            tokens = tokens[1:]
    return (tokens, display_pipe) if tokens else None


def _verification_kind(command: str) -> Optional[tuple[str, bool]]:
    parsed = _safe_shell_tokens(command)
    if not parsed:
        return None
    tokens, display_pipe = parsed
    if any(token in {"--version", "-V", "--help", "-h"} for token in tokens[1:]):
        return None
    head = Path(tokens[0]).name
    if head in _TEST_HEADS:
        return (head, display_pipe)
    if head in {"python", "python3"} and tokens[1:3] == ["-m", "pytest"]:
        return ("pytest", display_pipe)
    if head == "zig" and len(tokens) >= 2:
        if tokens[1] == "test" or (
            len(tokens) >= 3 and tokens[1] == "build" and tokens[2].startswith("test")
        ):
            return ("zig", display_pipe)
    if head in {"cargo", "go"} and len(tokens) >= 2 and tokens[1] == "test":
        return (head, display_pipe)
    if head == "npm" and len(tokens) >= 2:
        if tokens[1] == "test" or (
            len(tokens) >= 3 and tokens[1] == "run" and tokens[2].startswith("test")
        ):
            return ("npm", display_pipe)
    if head in {"pnpm", "yarn", "make"} and len(tokens) >= 2 and tokens[1].startswith("test"):
        return (head, display_pipe)
    return None


def _pytest_summary_passed(result: Mapping[str, Any]) -> bool:
    for field in ("stdout", "stderr"):
        value = result.get(field)
        if not isinstance(value, str):
            continue
        if (
            " passed" in value
            and " failed" not in value
            and " errors" not in value
            and " ERROR" not in value
            and "no tests ran" not in value
        ):
            return True
    return False


def _realized_mutation(effect: Any, valid: Any) -> bool:
    if valid is not True or not isinstance(effect, dict):
        return False
    value = effect.get("file_mutation_v2")
    if not isinstance(value, dict):
        return False
    mutation = value.get("mutation")
    reobservation = value.get("reobservation")
    return (
        isinstance(mutation, dict)
        and mutation.get("change") == "changed"
        and isinstance(reobservation, dict)
        and reobservation.get("state") == "matched"
    )


def _tool_rows(messages: Iterable[Mapping[str, Any]]) -> List[Dict[str, Any]]:
    calls: Dict[str, Dict[str, Any]] = {}
    ordered: List[Dict[str, Any]] = []
    checkpoint_messages: Dict[int, int] = {}
    for message_index, row in enumerate(messages):
        role = row.get("role")
        if role not in {"user", "assistant"}:
            raise TraceError(f"transcript row {message_index} has invalid role")
        blocks = row.get("blocks")
        if not isinstance(blocks, list):
            raise TraceError(f"transcript row {message_index} has invalid blocks")
        message_checkpoint_markers = 0
        message_has_tool_result = False
        for block in blocks:
            if not isinstance(block, dict):
                raise TraceError("transcript contains a non-object block")
            if block.get("type") == "tool_use":
                call_id = block.get("id")
                name = block.get("name")
                if (
                    not isinstance(call_id, str)
                    or not call_id
                    or call_id in calls
                    or not isinstance(name, str)
                    or not name
                ):
                    raise TraceError("transcript contains an invalid tool call")
                item = {
                    "id": call_id,
                    "name": name,
                    # Calls in one assistant message may execute in parallel.
                    # Preserve that boundary so an earlier slot in the same
                    # message cannot masquerade as causal pre-test mutation.
                    "assistant_turn": message_index,
                    "arguments": _arguments(block.get("input")),
                    "result": None,
                    "is_error": None,
                }
                calls[call_id] = item
                ordered.append(item)
            elif block.get("type") == "tool_result":
                message_has_tool_result = True
                call_id = block.get("tool_use_id")
                if not isinstance(call_id, str) or call_id not in calls:
                    raise TraceError("transcript contains an orphan tool result")
                if calls[call_id]["result"] is not None:
                    raise TraceError("transcript contains a duplicate tool result")
                calls[call_id]["result"] = block.get("content")
                calls[call_id]["is_error"] = block.get("is_error", False)
                calls[call_id]["result_message"] = message_index
            elif block.get("type") == "text":
                value = block.get("text")
                if isinstance(value, str) and value.startswith(_CHECKPOINT_PREFIX):
                    if role != "user":
                        raise TraceError("verification checkpoint appears outside a user message")
                    message_checkpoint_markers += 1
        # An initial user prompt that happens to quote the marker is not an
        # actuation. Runtime injection shares the user message containing the
        # triggering tool_result.
        if message_has_tool_result and message_checkpoint_markers:
            checkpoint_messages[message_index] = message_checkpoint_markers
    if any(item["result"] is None for item in ordered):
        raise TraceError("transcript contains an incomplete tool call")
    for item in ordered:
        item["checkpoint_markers_in_result_message"] = checkpoint_messages.get(
            item["result_message"], 0
        )
    # Keep the count attached to the first row so callers do not retain or
    # return any model-visible text. Empty trajectories still report zero.
    if ordered:
        ordered[0]["total_checkpoint_messages"] = sum(checkpoint_messages.values())
    return ordered


def _observation_rows(rows: Iterable[Mapping[str, Any]]) -> Dict[str, Dict[str, Any]]:
    finished: Dict[str, Dict[str, Any]] = {}
    for row in rows:
        elapsed = row.get("monotonic_elapsed_ns")
        event = row.get("event")
        if isinstance(elapsed, bool) or not isinstance(elapsed, int) or elapsed < 0:
            raise TraceError("observation elapsed time is invalid")
        if not isinstance(event, dict):
            raise TraceError("observation event is invalid")
        item = event.get("tool_observation")
        dispatch = item.get("dispatch_finished") if isinstance(item, dict) else None
        if not isinstance(dispatch, dict):
            continue
        call_id = dispatch.get("id")
        if not isinstance(call_id, str) or not call_id or call_id in finished:
            raise TraceError("dispatch finish identity is invalid or duplicated")
        finished[call_id] = {"elapsed_ns": elapsed, **dispatch}
    return finished


def _enforced_pre_blocked_ids(rows: Iterable[Mapping[str, Any]]) -> set[str]:
    """Dispatch ids the formal gate blocked before dispatch, under enforcement.

    A pre-dispatch enforced block is the one legitimate way a transcript tool
    call can lack a dispatch observation: blocking means the dispatch never
    happened, while the model still receives the denial as a tool result.  A
    shadow-mode block cannot justify a missing dispatch (shadow actuates as
    admit), so actuation must be literally "enforced"."""

    blocked: set[str] = set()
    for row in rows:
        event = row.get("event")
        item = event.get("tool_observation") if isinstance(event, dict) else None
        if not isinstance(item, dict):
            continue
        batch = item.get("formal_decision_batch")
        if isinstance(batch, dict):
            decisions = batch.get("decisions")
            if (
                batch.get("phase") == "pre"
                and batch.get("actuation") == "enforced"
                and isinstance(batch.get("dispatch_id"), str)
                and isinstance(decisions, list)
                and any(
                    isinstance(decision, dict) and decision.get("result") == "block"
                    for decision in decisions
                )
            ):
                blocked.add(batch["dispatch_id"])
        single = item.get("formal_decision")
        if isinstance(single, dict):
            if (
                single.get("phase") == "pre"
                and single.get("actuation") == "enforced"
                and single.get("result") == "block"
                and isinstance(single.get("dispatch_id"), str)
            ):
                blocked.add(single["dispatch_id"])
    return blocked


_PREDISPATCH_REJECTION_CODES = {"permission_denied"}


def _predispatch_rejected_ids(transcript) -> set:
    """Call ids whose result is a host-side pre-dispatch rejection."""

    rejected = set()
    for row in transcript:
        for block in row.get("blocks") or []:
            if not isinstance(block, dict) or block.get("type") != "tool_result":
                continue
            if block.get("is_error") is not True:
                continue
            content = block.get("content")
            if not isinstance(content, str):
                continue
            try:
                payload = json.loads(content)
            except json.JSONDecodeError:
                continue
            code = (
                payload.get("error", {}).get("code")
                if isinstance(payload, dict) and isinstance(payload.get("error"), dict)
                else None
            )
            if code in _PREDISPATCH_REJECTION_CODES:
                rejected.add(block.get("tool_use_id"))
    return rejected


def analyze_progress(transcript_path: Path, observation_path: Path) -> Dict[str, Any]:
    transcript, transcript_sha256 = _observed_rows(transcript_path)
    observation_rows, observation_sha256 = _observed_rows(observation_path)
    tools = _tool_rows(transcript)
    observations = _observation_rows(observation_rows)
    # Every transcript call must either have dispatched (an observation row)
    # or be individually justified by a host-side pre-dispatch rejection.
    # Two such mechanisms exist: an enforced formal pre-block, and a
    # permission denial (observed in the field when a model hallucinates a
    # disabled tool like Task — the call appears in the transcript with a
    # permission_denied error result and legitimately never dispatches).
    # The rejection roster is closed: a transcript-only call with a SUCCESS
    # result, or with an unrecognized error shape, stays fail-closed — that
    # is a real ledger hole, not a rejection.
    transcript_only = {item["id"] for item in tools} - set(observations)
    unjustified = (
        transcript_only
        - _enforced_pre_blocked_ids(observation_rows)
        - _predispatch_rejected_ids(transcript)
    )
    if unjustified or set(observations) - {item["id"] for item in tools}:
        raise TraceError("transcript and observation dispatch identities differ")
    if transcript_only:
        # A blocked call is not a dispatch; progress metrics index dispatches.
        tools = [item for item in tools if item["id"] not in transcript_only]

    first_mutation: Optional[int] = None
    first_mutation_turn: Optional[int] = None
    first_green: Optional[int] = None
    first_green_turn: Optional[int] = None
    verification_calls = 0
    successful_verifications = 0
    mutation_calls = 0
    realized_mutations: List[tuple[int, int]] = []
    repeated_exact = 0
    checkpoint_messages = tools[0].get("total_checkpoint_messages", 0) if tools else 0
    checkpoints_after_green = 0
    seen_signatures: set[tuple[str, str, str]] = set()
    for index, item in enumerate(tools, 1):
        observation = observations[item["id"]]
        if _realized_mutation(observation.get("effect"), observation.get("effect_valid")):
            mutation_calls += 1
            realized_mutations.append((index, item["assistant_turn"]))
            first_mutation = first_mutation or index
            if first_mutation_turn is None:
                first_mutation_turn = item["assistant_turn"]
        kind: Optional[tuple[str, bool]] = None
        success = False
        if item["name"] == "Bash":
            command = item["arguments"].get("command")
            if isinstance(command, str):
                kind = _verification_kind(command)
            result = _result_object(item["result"])
            success = (
                kind is not None
                and item["is_error"] is False
                and result is not None
                and result.get("exit_code") == 0
                and (
                    not kind[1]
                    or (kind[0] in {"pytest", "py.test"} and _pytest_summary_passed(result))
                )
            )
        if kind is not None:
            verification_calls += 1
        if success:
            successful_verifications += 1
            if (
                first_mutation_turn is not None
                and first_mutation_turn < item["assistant_turn"]
                and first_green is None
            ):
                first_green = index
                first_green_turn = item["assistant_turn"]
                checkpoints_after_green += item["checkpoint_markers_in_result_message"]
        signature = (
            item["name"],
            hashlib.sha256(json.dumps(item["arguments"], sort_keys=True).encode()).hexdigest(),
            hashlib.sha256(str(item["result"]).encode()).hexdigest(),
        )
        if signature in seen_signatures:
            repeated_exact += 1
        seen_signatures.add(signature)

    final_ns = max((row["elapsed_ns"] for row in observations.values()), default=0)
    first_mutation_ns = (
        observations[tools[first_mutation - 1]["id"]]["elapsed_ns"]
        if first_mutation is not None
        else None
    )
    first_green_ns = (
        observations[tools[first_green - 1]["id"]]["elapsed_ns"]
        if first_green is not None
        else None
    )
    green_turn_end_ns = (
        max(
            observations[item["id"]]["elapsed_ns"]
            for item in tools
            if item["assistant_turn"] == first_green_turn
        )
        if first_green_turn is not None
        else None
    )
    calls_after_green = (
        sum(item["assistant_turn"] > first_green_turn for item in tools)
        if first_green_turn is not None
        else None
    )
    mutation_after_green = (
        sum(turn > first_green_turn for _index, turn in realized_mutations)
        if first_green_turn is not None
        else 0
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "source": {
            "transcript_sha256": transcript_sha256,
            "observation_journal_sha256": observation_sha256,
        },
        "progress": {
            "tool_calls": len(tools),
            "first_mutation_call": first_mutation,
            "first_successful_verification_call": first_green,
            "calls_after_first_successful_verification": calls_after_green,
            "mutation_calls": mutation_calls,
            "mutations_after_first_successful_verification": mutation_after_green,
            "verification_calls": verification_calls,
            "successful_verifications": successful_verifications,
            "exact_repeated_tool_input_result_calls": repeated_exact,
            "checkpoint_messages": checkpoint_messages,
            "checkpoint_messages_after_successful_verification": checkpoints_after_green,
            "time_to_first_mutation_ms": (
                round(first_mutation_ns / 1_000_000, 3)
                if first_mutation_ns is not None
                else None
            ),
            "time_to_first_successful_verification_ms": (
                round(first_green_ns / 1_000_000, 3)
                if first_green_ns is not None
                else None
            ),
            "time_after_first_successful_verification_ms": (
                round((final_ns - green_turn_end_ns) / 1_000_000, 3)
                if green_turn_end_ns is not None
                else None
            ),
            "time_to_final_dispatch_ms": round(final_ns / 1_000_000, 3),
        },
        "privacy": {
            "tool_arguments_retained": False,
            "tool_results_retained": False,
            "paths_retained": False,
            "memory_text_retained": False,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--transcript", type=Path, required=True)
    parser.add_argument("--observations", type=Path, required=True)
    args = parser.parse_args()
    print(
        json.dumps(
            analyze_progress(args.transcript, args.observations),
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
