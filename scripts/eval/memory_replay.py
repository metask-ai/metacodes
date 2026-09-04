"""Replay host-owned memory observations into immutable benchmark rows.

The case manifest owns gold answers, evidence ids, treatment fingerprints and
the complete schedule.  Observation JSONL owns only what the runner observed.
Joining them here prevents a model-generated artifact from choosing its own
gold data, identity, or denominator.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
import stat
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Iterable, List, Mapping, Sequence, Tuple

from .memory_benchmark import (
    BENCHMARKS,
    PROTOCOL_ID,
    SCHEMA_VERSION as RESULT_SCHEMA_VERSION,
    file_sha256,
    is_online_memory_case,
    normalized_exact_match,
    validate_memory_row,
)
from .memory_budget_journal import (
    MAX_USER_AUTHORITY_USD,
    usd_to_microusd,
    usd_to_microusd_ceiling,
    validate_checkpoint_payload,
)
from .memory_consolidation import (
    SCHEMA_VERSION as CONSOLIDATION_SCHEMA_VERSION,
    validate_artifacts as _validate_consolidation_artifacts,
    validate_receipt as _validate_consolidation_receipt,
)
from .memory_query_plan import (
    QUERY_PLAN_INVALID_PREFIX,
    build_query_plan_trace,
    load_and_verify_query_plan_sidecar,
    summarize_query_plan_traces,
)
from .model import ValidationError, stable_json, POSIX_MODE_BITS


REPLAY_SCHEMA_VERSION = 1
LEGACY_OBSERVATION_SCHEMA_VERSION = 1
OBSERVATION_SCHEMA_VERSION = 2
LEGACY_RUNTIME_RECEIPT_SCHEMA_VERSION = 2
RUNTIME_RECEIPT_SCHEMA_VERSION = 3
LEGACY_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION = 4
BUDGET_JOURNAL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION = 5
PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION = 6
PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION = 7
PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION = 8
PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION = 9
NATIVE_RUNTIME_RECEIPT_VERSIONS = frozenset(
    {
        LEGACY_RUNTIME_RECEIPT_SCHEMA_VERSION,
        RUNTIME_RECEIPT_SCHEMA_VERSION,
        LEGACY_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        BUDGET_JOURNAL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
    }
)
PRODUCTION_RUNTIME_RECEIPT_VERSIONS = frozenset(
    {
        LEGACY_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        BUDGET_JOURNAL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
    }
)
# Deliberately private and identity-checked: canonical replay must never opt
# into recomputing a historical query-plan sidecar through a convenient bool.
# The failed-run analyzer imports this capability explicitly and still emits
# analysis-only, non-promotable output.
_FAILED_RUN_QUERY_PLAN_REANALYSIS = object()
LEGACY_RUNNER_SOURCE_MODULES = (
    "e2e_adapter",
    "memory_agent_runtime",
    "memory_agent_runtime_smoke",
    "memory_benchmark",
    "memory_hotpot_adapter",
    "memory_longmem_adapter",
    "memory_procedural_adapter",
    "memory_replay",
    "memory_tinykg_local",
    "model",
)
RUNNER_SOURCE_MODULES = (
    *LEGACY_RUNNER_SOURCE_MODULES,
    "memory_query_plan",
)
LEGACY_PRODUCTION_RUNNER_SOURCE_MODULES = (
    *LEGACY_RUNNER_SOURCE_MODULES,
    "memory_agent_runtime_pilot",
)
PRE_QUERY_PLAN_PRODUCTION_RUNNER_SOURCE_MODULES = (
    *LEGACY_PRODUCTION_RUNNER_SOURCE_MODULES,
    "memory_budget_journal",
)
PRE_CONSOLIDATION_PRODUCTION_RUNNER_SOURCE_MODULES = (
    *RUNNER_SOURCE_MODULES,
    "memory_agent_runtime_pilot",
    "memory_budget_journal",
)
PRODUCTION_RUNNER_SOURCE_MODULES = (
    *PRE_CONSOLIDATION_PRODUCTION_RUNNER_SOURCE_MODULES,
    "memory_consolidation",
)
PRODUCTION_PROVIDER_ID = "metask-anthropic-compatible-v1"
PRODUCTION_MODEL_PROVIDER = "anthropic"
PRODUCTION_MODEL_ID = "glm-5.2"
PRODUCTION_EXECUTION_MODE = "native-agent-loop-production-memory-pilot"
PRODUCTION_PRICING_PROVENANCE = (
    "metacodes_glm-5.2_conservative_sonnet4_usd_guardrail_2026-08-07_not_provider_bill"
)
PRODUCTION_DISALLOWED_PROVIDER_TOOLS = (
    "Agent",
    "Task",
    "TaskBatch",
    "TeamCreate",
    "WebFetch",
    "WebSearch",
)
PRODUCTION_ALLOWED_PROVIDER_TOOLS = (
    "Read",
    "Write",
    "Edit",
    "ApplyPatch",
    "Glob",
    "Grep",
    "CodeMap",
    "FindSymbol",
    "Bash",
    "BashOutput",
    "KillShell",
    "KgRemember",
    "KgRecall",
    "KgContext",
)
PRODUCTION_TOOL_NETWORK_ISOLATION = "not_proven_bash_network_unsandboxed"
PRODUCTION_SANDBOX_BACKEND = "macos-seatbelt-sandbox-exec-v1"
LEGACY_PRODUCTION_SANDBOX_PROBE_SCHEMA_VERSION = 1
READ_ONLY_PRODUCTION_SANDBOX_PROBE_SCHEMA_VERSION = 2
PRODUCTION_SANDBOX_PROBE_SCHEMA_VERSION = 3
PRODUCTION_FILESYSTEM_ISOLATION = "not_proven_bypass_permissions_same_uid"
PRODUCTION_CHILD_PATH = "/bin:/usr/bin"
PRODUCTION_RIPGREP_SNAPSHOT_PATH = "production-toolchain/.metacodes/toolchain/rg"
PRODUCTION_AUTO_COMPACT_POLICY = "disabled_threshold_reject_any_compact_event"
PRODUCTION_FORCE_COMPACT_AT = "9223372036854775807"
SCOPED_RECALL_PREFIX = "<system-reminder>\n# 相关持久记忆(按你的请求自动召回,可能不全)\n"
LOOP_BREAKER_FINALIZATION = (
    "[loop-breaker] Repeated ineffective tool actions were stopped. "
    "Do not call any more tools. Using only the evidence already present, "
    "provide a concise final answer covering completed work, verified results, "
    "remaining blockers, and the next step."
)
HEX64 = re.compile(r"^[0-9a-f]{64}$")
IDENTIFIER = re.compile(r"^[a-z0-9][a-z0-9_.:-]{0,127}$")
TREATMENT_LEAK_TERMS = (
    "tinykg",
    "codex",
    "claude",
    "no_memory",
    "markdown_memory",
    "tinykg_lexical",
    "treatment arm",
)


def _fail(where: str, message: str) -> None:
    raise ValidationError(f"{where}: {message}")


def _object(value: Any, where: str, keys: Iterable[str]) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        _fail(where, "expected an object")
    expected = frozenset(keys)
    missing = expected - set(value)
    unknown = set(value) - expected
    if missing:
        _fail(where, f"missing fields: {sorted(missing)}")
    if unknown:
        _fail(where, f"unknown fields: {sorted(unknown)}")
    return value


def _string(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value.strip():
        _fail(where, "expected non-empty string")
    return value


def _text(value: Any, where: str) -> str:
    if not isinstance(value, str):
        _fail(where, "expected a string")
    return value


def _identifier(value: Any, where: str) -> str:
    result = _string(value, where)
    if IDENTIFIER.fullmatch(result) is None:
        _fail(where, "expected a stable lowercase identifier")
    return result


def _hash(value: Any, where: str) -> str:
    result = _string(value, where)
    if HEX64.fullmatch(result) is None:
        _fail(where, "expected lowercase SHA-256 hex")
    return result


def _integer(value: Any, where: str, *, minimum: int = 0, maximum: int | None = None) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        _fail(where, f"expected integer >= {minimum}")
    if maximum is not None and value > maximum:
        _fail(where, f"expected integer <= {maximum}")
    return value


def _string_list(value: Any, where: str, *, allow_empty: bool) -> List[str]:
    if not isinstance(value, list):
        _fail(where, "expected an array")
    result = [_string(item, f"{where}[{index}]") for index, item in enumerate(value)]
    if not allow_empty and not result:
        _fail(where, "must not be empty")
    if len(set(result)) != len(result):
        _fail(where, "must not contain duplicates")
    return result


def _canonical_sha256(value: Any) -> str:
    return hashlib.sha256(stable_json(value).encode("utf-8")).hexdigest()


def _query_plan_source_bound(receipt: Mapping[str, Any], where: str) -> bool:
    """Distinguish historical receipts from query-plan-aware runs.

    The runner source list is already part of the runtime receipt identity.
    Treating arbitrary source lists as "legacy" would let a caller remove the
    analyzer module and thereby make a missing sidecar look acceptable.
    """

    schema_version = receipt.get("schema_version")
    if schema_version == LEGACY_RUNTIME_RECEIPT_SCHEMA_VERSION:
        return False
    raw_sources = receipt.get("runner_sources")
    if not isinstance(raw_sources, list):
        _fail(f"{where}.runner_sources", "expected an array")
    modules: List[str] = []
    for index, source in enumerate(raw_sources):
        if not isinstance(source, dict):
            _fail(f"{where}.runner_sources[{index}]", "expected an object")
        modules.append(
            _identifier(
                source.get("module"),
                f"{where}.runner_sources[{index}].module",
            )
        )
    observed = tuple(modules)
    if schema_version == RUNTIME_RECEIPT_SCHEMA_VERSION:
        if frozenset(observed) not in {
            frozenset(LEGACY_RUNNER_SOURCE_MODULES),
            frozenset(RUNNER_SOURCE_MODULES),
        }:
            _fail(f"{where}.runner_sources", "unknown native runtime source set")
    elif schema_version == LEGACY_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION:
        if observed != LEGACY_PRODUCTION_RUNNER_SOURCE_MODULES:
            _fail(f"{where}.runner_sources", "unknown legacy production source set")
    elif schema_version in {
        BUDGET_JOURNAL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
    }:
        expected_sources = {
            BUDGET_JOURNAL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION:
                PRE_QUERY_PLAN_PRODUCTION_RUNNER_SOURCE_MODULES,
            PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION:
                PRE_CONSOLIDATION_PRODUCTION_RUNNER_SOURCE_MODULES,
            PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION:
                PRODUCTION_RUNNER_SOURCE_MODULES,
            PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION:
                PRODUCTION_RUNNER_SOURCE_MODULES,
            PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION:
                PRODUCTION_RUNNER_SOURCE_MODULES,
        }[schema_version]
        if observed != expected_sources:
            _fail(f"{where}.runner_sources", "unknown production runtime source set")
    else:
        _fail(f"{where}.schema_version", "unsupported native runtime receipt")
    return "memory_query_plan" in observed


def _production_harness_fingerprint(
    *,
    metacodes_binary_sha256: str,
    tinykg_binary_sha256: str | None,
    harness_revision: str,
    arm: Mapping[str, Any],
    runtime_arm: str,
    runtime_budget: Mapping[str, Any],
    runner_sources: Sequence[Mapping[str, Any]],
    allowed_provider_tools: Sequence[str] | None = None,
    ripgrep_binary_sha256: str | None = None,
) -> str:
    """Compute the production harness identity used at run and replay time."""

    identity = {
            "metacodes_binary_sha256": metacodes_binary_sha256,
            "tinykg_binary_sha256": tinykg_binary_sha256,
            "harness_revision": harness_revision,
            "arm": arm,
            "runtime_arm": runtime_arm,
            "provider": PRODUCTION_PROVIDER_ID,
            "runtime_budget": runtime_budget,
            "disallowed_provider_tools": list(PRODUCTION_DISALLOWED_PROVIDER_TOOLS),
            "filesystem_isolation": PRODUCTION_FILESYSTEM_ISOLATION,
            "auto_compact_policy": PRODUCTION_AUTO_COMPACT_POLICY,
            "runner_sources_sha256": _canonical_sha256(list(runner_sources)),
    }
    if allowed_provider_tools is not None or ripgrep_binary_sha256 is not None:
        if allowed_provider_tools is None or ripgrep_binary_sha256 is None:
            _fail("production harness fingerprint", "incomplete toolchain identity")
        identity["allowed_provider_tools"] = list(allowed_provider_tools)
        identity["ripgrep_binary_sha256"] = ripgrep_binary_sha256
    return _canonical_sha256(identity)


def _finite_number(value: Any, where: str, *, minimum: float = 0.0) -> float:
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(float(value))
        or float(value) < minimum
    ):
        _fail(where, f"expected finite number >= {minimum}")
    return float(value)


def _artifact_relative_path(value: Any, where: str) -> PurePosixPath:
    raw = _string(value, where)
    path = PurePosixPath(raw)
    if path.is_absolute() or raw != path.as_posix() or any(part in {"", ".", ".."} for part in path.parts):
        _fail(where, "expected a normalized relative POSIX path")
    return path


def _artifact_path(root: Path, value: Any, where: str, *, directory: bool) -> Path:
    relative = _artifact_relative_path(value, where)
    try:
        resolved_root = root.expanduser().resolve(strict=True)
    except OSError as exc:
        raise ValidationError(f"{where}: artifact root is unavailable: {exc}") from exc
    if not resolved_root.is_dir():
        _fail(where, "artifact root is not a directory")
    current = resolved_root
    try:
        for part in relative.parts:
            current = current / part
            info = current.lstat()
            if stat.S_ISLNK(info.st_mode):
                _fail(where, "artifact path contains a symlink")
    except OSError as exc:
        raise ValidationError(f"{where}: artifact is unavailable: {exc}") from exc
    try:
        current.resolve(strict=True).relative_to(resolved_root)
    except (OSError, ValueError) as exc:
        raise ValidationError(f"{where}: artifact escapes the receipt root") from exc
    if directory and not current.is_dir():
        _fail(where, "expected a directory artifact")
    if not directory and not current.is_file():
        _fail(where, "expected a file artifact")
    if not directory and current.lstat().st_nlink != 1:
        _fail(where, "hard-linked file artifacts are forbidden")
    return current


def _artifact_tree_digest(
    root: Path,
    where: str = "runtime artifact",
    *,
    ignore_lock_files: bool = False,
) -> str:
    records: List[Mapping[str, Any]] = []
    try:
        if stat.S_ISLNK(root.lstat().st_mode) or not root.is_dir():
            _fail(where, "expected a non-symlink directory")
        for path in sorted(root.rglob("*")):
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                _fail(where, f"unexpected symlink {relative!r}")
            if stat.S_ISDIR(info.st_mode):
                records.append({"path": relative, "type": "directory"})
                continue
            if not stat.S_ISREG(info.st_mode):
                _fail(where, f"unexpected non-regular entry {relative!r}")
            if ignore_lock_files and path.name.endswith(".lock"):
                continue
            if info.st_nlink != 1:
                _fail(where, f"unexpected hard-linked file {relative!r}")
            data = path.read_bytes()
            records.append(
                {
                    "path": relative,
                    "type": "file",
                    "bytes": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                }
            )
    except ValidationError:
        raise
    except OSError as exc:
        raise ValidationError(f"{where}: cannot re-observe artifact tree: {exc}") from exc
    return hashlib.sha256(stable_json(records).encode("utf-8")).hexdigest()


def _path_is_within(raw_path: Any, root: Path | None) -> bool:
    if root is None or not isinstance(raw_path, str) or not raw_path:
        return False
    try:
        Path(raw_path).expanduser().resolve(strict=False).relative_to(root.resolve(strict=True))
    except (OSError, ValueError):
        return False
    return True


def _cassette_memory_activity(
    root: Path,
    where: str,
    *,
    memory_root: Path | None = None,
) -> Mapping[str, int]:
    """Recompute executed memory operations from the raw provider requests.

    Requests contain the complete conversation-so-far, so tool ids are
    deduplicated across files and count only after a matching tool_result is
    observable.  A repeated id with different semantics is corruption, not a
    second event.
    """

    request_paths = sorted(root.glob("req-*.json"))
    if not request_paths:
        _fail(where, "provider cassette has no request artifacts")
    request_numbers: List[int] = []
    tool_defs: Dict[str, Tuple[str, str]] = {}
    tool_results: Dict[str, Tuple[bool, str]] = {}
    for request_path in request_paths:
        match = re.fullmatch(r"req-([0-9]+)\.json", request_path.name)
        if match is None:
            _fail(where, f"malformed request artifact {request_path.name!r}")
        request_numbers.append(int(match.group(1)))
        body = _load_unique_json(request_path, f"{where}.{request_path.name}")
        messages = body.get("messages")
        if not isinstance(messages, list):
            _fail(f"{where}.{request_path.name}.messages", "expected an array")
        for message in messages:
            content = message.get("content") if isinstance(message, dict) else None
            if not isinstance(content, list):
                continue
            for item in content:
                if not isinstance(item, dict):
                    continue
                item_type = item.get("type")
                if item_type == "tool_use":
                    tool_id = item.get("id")
                    name = item.get("name")
                    tool_input = item.get("input")
                    if not isinstance(tool_id, str) or not tool_id:
                        _fail(where, "tool_use has no stable id")
                    if not isinstance(name, str) or not name:
                        _fail(where, f"tool_use {tool_id!r} has no name")
                    if not isinstance(tool_input, dict):
                        _fail(where, f"tool_use {tool_id!r} has non-object input")
                    signature = (name, stable_json(tool_input))
                    prior = tool_defs.get(tool_id)
                    if prior is not None and prior != signature:
                        _fail(where, f"tool id {tool_id!r} changed semantics across requests")
                    tool_defs[tool_id] = signature
                elif item_type == "tool_result":
                    tool_id = item.get("tool_use_id")
                    if isinstance(tool_id, str) and tool_id:
                        is_error = item.get("is_error", False)
                        if not isinstance(is_error, bool):
                            _fail(where, f"tool_result {tool_id!r} has non-boolean is_error")
                        signature = (is_error, stable_json(item.get("content")))
                        prior = tool_results.get(tool_id)
                        if prior is not None and prior != signature:
                            _fail(where, f"tool result {tool_id!r} changed semantics across requests")
                        tool_results[tool_id] = signature
    if request_numbers != list(range(1, len(request_paths) + 1)):
        _fail(where, "provider request sequence is not contiguous from one")

    counts = {
        "provider_requests": len(request_paths),
        "tinykg_reads": 0,
        "tinykg_writes": 0,
        "markdown_reads": 0,
        "markdown_writes": 0,
        "forbidden_provider_tool_attempts": 0,
        "contained_forbidden_provider_tool_attempts": 0,
        "uncontained_forbidden_provider_tool_attempts": 0,
    }
    for tool_id, (name, raw_input) in tool_defs.items():
        tool_input = json.loads(raw_input)
        if name in PRODUCTION_DISALLOWED_PROVIDER_TOOLS:
            counts["forbidden_provider_tool_attempts"] += 1
            result = tool_results.get(tool_id)
            safely_denied = False
            if result is not None and result[0]:
                try:
                    content = json.loads(result[1])
                    denial = json.loads(content) if isinstance(content, str) else content
                except json.JSONDecodeError:
                    denial = None
                error = denial.get("error") if isinstance(denial, dict) else None
                safely_denied = bool(
                    isinstance(error, dict)
                    and error.get("code") == "permission_denied"
                    and error.get("category") == "safety"
                    and error.get("recoverable") is False
                )
            counter = (
                "contained_forbidden_provider_tool_attempts"
                if safely_denied
                else "uncontained_forbidden_provider_tool_attempts"
            )
            counts[counter] += 1
        markdown_read = name in {"Read", "Grep"} and (
            _path_is_within(tool_input.get("file_path"), memory_root)
            or _path_is_within(tool_input.get("path"), memory_root)
        )
        markdown_write = name in {"Write", "Edit"} and _path_is_within(
            tool_input.get("file_path"), memory_root
        )
        memory_operation = (
            name in {"KgRecall", "KgContext", "KgRemember"}
            or markdown_read
            or markdown_write
        )
        if memory_operation and tool_id not in tool_results:
            _fail(where, f"memory tool {tool_id!r} has no observable result")
        if tool_id not in tool_results:
            continue
        result_is_error = tool_results[tool_id][0]
        if name in {"KgRecall", "KgContext"}:
            counts["tinykg_reads"] += 1
        elif name == "KgRemember" and not result_is_error:
            counts["tinykg_writes"] += 1
        if markdown_read:
            counts["markdown_reads"] += 1
        elif markdown_write and not result_is_error:
            counts["markdown_writes"] += 1
    return counts


def _validate_production_provider_tool_schema(
    root: Path,
    where: str,
    allowed_tools: Sequence[str],
) -> None:
    """Re-open every provider request and enforce the sealed schema ceiling."""

    allowed = set(allowed_tools)
    if not allowed or len(allowed) != len(allowed_tools):
        _fail(where, "production allowed-tool policy is empty or duplicated")
    request_paths = sorted(root.glob("req-*.json"))
    if not request_paths:
        _fail(where, "provider cassette has no request artifacts")
    for request_path in request_paths:
        body = _load_unique_json(request_path, f"{where}.{request_path.name}")
        tools = body.get("tools")
        if not isinstance(tools, list):
            if _is_final_toolless_loop_breaker_request(
                body,
                request_path=request_path,
                final_request_path=request_paths[-1],
            ):
                continue
            _fail(f"{where}.{request_path.name}.tools", "expected an array")
        seen: set[str] = set()
        for index, raw_tool in enumerate(tools):
            tool_where = f"{where}.{request_path.name}.tools[{index}]"
            if not isinstance(raw_tool, dict):
                _fail(tool_where, "expected an object")
            name = _string(raw_tool.get("name"), f"{tool_where}.name")
            if name in seen:
                _fail(f"{tool_where}.name", "duplicate provider tool definition")
            seen.add(name)
            if name not in allowed:
                _fail(
                    f"{tool_where}.name",
                    f"provider schema exposed out-of-policy tool {name!r}",
                )


def _is_final_toolless_loop_breaker_request(
    body: Mapping[str, Any],
    *,
    request_path: Path,
    final_request_path: Path,
) -> bool:
    """Recognize the deliberately capability-free breaker finalization turn.

    The native loop removes the provider tool schema for this one borrowed turn,
    so omission is safer than an empty-but-drifting schema. Keep the exception
    narrow: an explicit null, a non-final request, a changed instruction, or a
    request without the triggering tool result remains invalid.
    """

    if "tools" in body or request_path != final_request_path:
        return False
    messages = body.get("messages")
    if not isinstance(messages, list) or not messages:
        return False
    final_message = messages[-1]
    if not isinstance(final_message, dict) or final_message.get("role") != "user":
        return False
    content = final_message.get("content")
    if not isinstance(content, list):
        return False
    text_blocks = [
        item.get("text")
        for item in content
        if isinstance(item, dict) and item.get("type") == "text"
    ]
    has_tool_result = any(
        isinstance(item, dict) and item.get("type") == "tool_result"
        for item in content
    )
    return has_tool_result and text_blocks == [LOOP_BREAKER_FINALIZATION]


def _cassette_memory_exposure(
    root: Path,
    where: str,
    *,
    memory_root: Path | None,
    expected_memory_index: bytes,
    count_graph_context: bool,
) -> Mapping[str, int]:
    """Recompute memory bytes actually exposed to the production model.

    Provider requests repeat the complete conversation, so both tool results
    and injected context must be deduplicated. Only successful memory-read
    results count; unrelated Read/Bash/test output and memory-write receipts do
    not. ``expected_memory_index`` is the pre-rollout MEMORY.md payload, which
    must occur exactly once in the first request when non-empty.
    """

    request_paths = sorted(root.glob("req-*.json"))
    if not request_paths:
        _fail(where, "provider cassette has no request artifacts")
    first = _load_unique_json(request_paths[0], f"{where}.{request_paths[0].name}")
    first_messages = first.get("messages")
    if not isinstance(first_messages, list):
        _fail(f"{where}.{request_paths[0].name}.messages", "expected an array")

    first_text_blocks: List[str] = []
    for message in first_messages:
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, list):
            continue
        for item in content:
            if (
                isinstance(item, dict)
                and item.get("type") == "text"
                and isinstance(item.get("text"), str)
            ):
                first_text_blocks.append(item["text"])

    auto_injected_bytes = 0
    if expected_memory_index:
        try:
            index_text = expected_memory_index.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ValidationError(f"{where}: MEMORY.md is not UTF-8: {exc}") from exc
        occurrences = sum(block.count(index_text) for block in first_text_blocks)
        if occurrences != 1:
            _fail(where, f"expected one injected MEMORY.md index, observed {occurrences}")
        auto_injected_bytes += len(expected_memory_index)

    if count_graph_context:
        seen_sections: set[str] = set()
        for block in first_text_blocks:
            date_start = block.rfind("# currentDate\n")
            if date_start < 0:
                continue
            graph_start = block.rfind("# Knowledge Graph\n", 0, date_start)
            if graph_start < 0:
                continue
            section = block[graph_start:date_start]
            if section and section not in seen_sections:
                seen_sections.add(section)
                auto_injected_bytes += len(section.encode("utf-8"))
        auto_injected_bytes += sum(
            len(block.encode("utf-8"))
            for block in first_text_blocks
            if block.startswith(SCOPED_RECALL_PREFIX)
        )

    tool_defs: Dict[str, Tuple[str, str]] = {}
    tool_results: Dict[str, Tuple[str, bool]] = {}
    for request_path in request_paths:
        body = _load_unique_json(request_path, f"{where}.{request_path.name}")
        messages = body.get("messages")
        if not isinstance(messages, list):
            _fail(f"{where}.{request_path.name}.messages", "expected an array")
        for message in messages:
            content = message.get("content") if isinstance(message, dict) else None
            if not isinstance(content, list):
                continue
            for item in content:
                if not isinstance(item, dict):
                    continue
                if item.get("type") == "tool_use":
                    tool_id = item.get("id")
                    name = item.get("name")
                    tool_input = item.get("input")
                    if not isinstance(tool_id, str) or not tool_id:
                        _fail(where, "tool_use has no stable id")
                    if not isinstance(name, str) or not isinstance(tool_input, dict):
                        _fail(where, f"tool_use {tool_id!r} is malformed")
                    signature = (name, stable_json(tool_input))
                    prior = tool_defs.get(tool_id)
                    if prior is not None and prior != signature:
                        _fail(where, f"tool id {tool_id!r} changed semantics across requests")
                    tool_defs[tool_id] = signature
                elif item.get("type") == "tool_result":
                    tool_id = item.get("tool_use_id")
                    content_value = item.get("content")
                    if isinstance(tool_id, str) and isinstance(content_value, str):
                        observed = (content_value, item.get("is_error") is True)
                        prior = tool_results.get(tool_id)
                        if prior is not None and prior != observed:
                            _fail(where, f"tool result {tool_id!r} changed across requests")
                        tool_results[tool_id] = observed

    tool_result_bytes = 0
    for tool_id, (name, raw_input) in tool_defs.items():
        result = tool_results.get(tool_id)
        if result is None or result[1]:
            continue
        tool_input = json.loads(raw_input)
        markdown_read = name in {"Read", "Grep"} and (
            _path_is_within(tool_input.get("file_path"), memory_root)
            or _path_is_within(tool_input.get("path"), memory_root)
        )
        if name in {"KgRecall", "KgContext"} or markdown_read:
            tool_result_bytes += len(result[0].encode("utf-8"))

    return {
        "auto_injected_bytes": auto_injected_bytes,
        "tool_result_bytes": tool_result_bytes,
        "total_bytes": auto_injected_bytes + tool_result_bytes,
    }


def _cassette_scoped_recall_injections(root: Path, where: str) -> List[bytes]:
    """Read exact host-injected recall blocks from the first provider request.

    Native events carry only byte/hash commitments. The cassette independently
    proves those committed bytes crossed the provider boundary.
    """

    request_paths = sorted(root.glob("req-*.json"))
    if not request_paths:
        _fail(where, "provider cassette has no request artifacts")
    first = _load_unique_json(request_paths[0], f"{where}.{request_paths[0].name}")
    messages = first.get("messages")
    if not isinstance(messages, list):
        _fail(f"{where}.{request_paths[0].name}.messages", "expected an array")
    result: List[bytes] = []
    for message in messages:
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, list):
            continue
        for item in content:
            text = (
                item.get("text")
                if isinstance(item, dict) and item.get("type") == "text"
                else None
            )
            if isinstance(text, str) and text.startswith(SCOPED_RECALL_PREFIX):
                result.append(text.encode("utf-8"))
    return result


def _cassette_treatment_activation(
    root: Path,
    runtime_arm: str,
    model_id: str,
    where: str = "production treatment activation",
) -> Mapping[str, Any]:
    requests = sorted(root.glob("req-*.json"))
    if not requests:
        _fail(where, "provider cassette is empty")
    body = _load_unique_json(requests[0], f"{where}.request")
    if body.get("model") != model_id:
        _fail(f"{where}.model", "request model drift")
    system = body.get("system")
    if not isinstance(system, str):
        _fail(f"{where}.system", "request system prompt is unavailable")
    tools = body.get("tools")
    if not isinstance(tools, list):
        _fail(f"{where}.tools", "request tool schema is unavailable")
    names = {
        item.get("name")
        for item in tools
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    }
    kg_tools = {"KgRemember", "KgRecall", "KgContext"}
    has_memory = "# Memory" in system
    has_graph = "# Knowledge Graph" in system
    if runtime_arm == "codex_style":
        valid = not has_memory and not has_graph and not (names & kg_tools)
    elif runtime_arm == "claude_style":
        valid = has_memory and not has_graph and not (names & kg_tools)
    elif runtime_arm == "tinykg":
        valid = has_memory and has_graph and kg_tools <= names
    else:
        valid = False
    if not valid:
        _fail(where, f"request does not match runtime arm {runtime_arm!r}")
    evidence = {
        "runtime_arm": runtime_arm,
        "system_prompt_sha256": hashlib.sha256(system.encode("utf-8")).hexdigest(),
        "tool_names_sha256": _canonical_sha256(sorted(names)),
        "memory_prompt_active": has_memory,
        "knowledge_graph_prompt_active": has_graph,
        "tinykg_tools_active": sorted(names & kg_tools),
    }
    return {**evidence, "fingerprint": _canonical_sha256(evidence)}


def _cassette_context_cache(
    root: Path,
    model_id: str,
    where: str = "production context/cache",
) -> Mapping[str, Any]:
    """Recompute the provider-visible cache prefix from every raw request.

    A treatment must not buy memory quality by silently changing the stable
    system/tools prefix on each turn. The one capability-free loop-breaker
    finalization request is counted separately and cannot impersonate a normal
    cacheable request.
    """

    requests = sorted(root.glob("req-*.json"))
    if not requests:
        _fail(where, "provider cassette is empty")
    expected_cache_control = {"type": "ephemeral"}
    normal_prefixes: set[str] = set()
    system_hashes: set[str] = set()
    system_sizes: set[int] = set()
    tool_hashes: set[str] = set()
    tool_sizes: set[int] = set()
    normal_requests = 0
    tool_less_finalizations = 0
    for request_path in requests:
        body = _load_unique_json(request_path, f"{where}.{request_path.name}")
        if body.get("model") != model_id:
            _fail(f"{where}.{request_path.name}.model", "request model drift")
        if body.get("cache_control") != expected_cache_control:
            _fail(
                f"{where}.{request_path.name}.cache_control",
                "production request must keep the sealed ephemeral cache contract",
            )
        tools = body.get("tools")
        if not isinstance(tools, list):
            if _is_final_toolless_loop_breaker_request(
                body,
                request_path=request_path,
                final_request_path=requests[-1],
            ):
                tool_less_finalizations += 1
                continue
            _fail(f"{where}.{request_path.name}.tools", "normal request has no tool schema")
        system = body.get("system")
        if not isinstance(system, str) or not system:
            _fail(f"{where}.{request_path.name}.system", "cacheable system prompt is missing")
        system_bytes = system.encode("utf-8")
        # Preserve provider-visible map/list order. Canonical sort_keys hashing
        # would hide a property-order drift that can change the model-facing
        # tool prefix even when the parsed JSON values compare equal.
        tools_bytes = json.dumps(
            tools,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=False,
        ).encode("utf-8")
        normal_requests += 1
        system_hashes.add(hashlib.sha256(system_bytes).hexdigest())
        system_sizes.add(len(system_bytes))
        tool_hashes.add(hashlib.sha256(tools_bytes).hexdigest())
        tool_sizes.add(len(tools_bytes))
        prefix_bytes = json.dumps(
            {
                "model": model_id,
                "system": system,
                "tools": tools,
                "cache_control": expected_cache_control,
            },
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=False,
        ).encode("utf-8")
        normal_prefixes.add(hashlib.sha256(prefix_bytes).hexdigest())
    if normal_requests < 1:
        _fail(where, "cassette has no normal cacheable provider request")
    if any(
        len(values) != 1
        for values in (
            normal_prefixes,
            system_hashes,
            system_sizes,
            tool_hashes,
            tool_sizes,
        )
    ):
        _fail(where, "system or full tool schema changed within one rollout")
    return {
        "normal_request_count": normal_requests,
        "tool_less_finalization_request_count": tool_less_finalizations,
        "cache_control": expected_cache_control,
        "system_prompt_sha256": next(iter(system_hashes)),
        "system_prompt_bytes": next(iter(system_sizes)),
        "tools_schema_sha256": next(iter(tool_hashes)),
        "tools_schema_bytes": next(iter(tool_sizes)),
        "cacheable_prefix_sha256": next(iter(normal_prefixes)),
        "prefix_stable": True,
    }


def _summarize_context_cache(
    rollout_receipts: Sequence[Mapping[str, Any]],
) -> Mapping[str, Any]:
    """Aggregate arm-level context/cache evidence and derive a claim gate."""

    by_arm: Dict[str, Dict[str, Any]] = {}
    blockers: List[str] = []
    for arm in sorted({str(item["arm"]) for item in rollout_receipts}):
        rows = [item for item in rollout_receipts if item["arm"] == arm]
        contexts = [item.get("context_cache") for item in rows]
        if any(not isinstance(item, dict) for item in contexts):
            _fail("production context/cache summary", f"arm {arm!r} is missing evidence")
        typed = [item for item in contexts if isinstance(item, dict)]
        input_tokens = sum(int(item["input_tokens"]) for item in typed)
        cache_read_tokens = sum(int(item["cache_read_tokens"]) for item in typed)
        cache_write_tokens = sum(int(item["cache_write_tokens"]) for item in typed)
        prompt_tokens = input_tokens + cache_read_tokens + cache_write_tokens
        prefixes = sorted({str(item["cacheable_prefix_sha256"]) for item in typed})
        system_hashes = sorted({str(item["system_prompt_sha256"]) for item in typed})
        system_sizes = sorted({int(item["system_prompt_bytes"]) for item in typed})
        tool_hashes = sorted({str(item["tools_schema_sha256"]) for item in typed})
        tool_sizes = sorted({int(item["tools_schema_bytes"]) for item in typed})
        prefix_stable = all(
            len(values) == 1
            for values in (prefixes, system_hashes, system_sizes, tool_hashes, tool_sizes)
        ) and all(
            item.get("prefix_stable") is True for item in typed
        )
        original_context_preserved = all(
            item.get("original_context_preserved") is True for item in typed
        )
        normal_request_count = sum(
            int(item["normal_request_count"]) for item in typed
        )
        tool_less_finalization_request_count = sum(
            int(item["tool_less_finalization_request_count"]) for item in typed
        )
        summary = {
            "rollouts": len(rows),
            "normal_request_count": normal_request_count,
            "tool_less_finalization_request_count": tool_less_finalization_request_count,
            "input_tokens": input_tokens,
            "output_tokens": sum(int(item["output_tokens"]) for item in typed),
            "cache_read_tokens": cache_read_tokens,
            "cache_write_tokens": cache_write_tokens,
            "cache_reuse_ratio": (
                cache_read_tokens / prompt_tokens if prompt_tokens > 0 else 0.0
            ),
            "cache_break_count": sum(int(item["cache_break_count"]) for item in typed),
            "system_prompt_sha256": system_hashes[0] if len(system_hashes) == 1 else None,
            "system_prompt_bytes": system_sizes[0] if len(system_sizes) == 1 else None,
            "tools_schema_sha256": tool_hashes[0] if len(tool_hashes) == 1 else None,
            "tools_schema_bytes": tool_sizes[0] if len(tool_sizes) == 1 else None,
            "cacheable_prefix_sha256": prefixes[0] if len(prefixes) == 1 else None,
            "prefix_stable": prefix_stable,
            "compact_request_count": sum(
                int(item["compact_request_count"]) for item in typed
            ),
            "auto_compact_event_count": sum(
                int(item["auto_compact_event_count"]) for item in typed
            ),
            "context_projection_count": sum(
                int(item["context_projection_count"]) for item in typed
            ),
            "context_projected_bytes": sum(
                int(item["context_projected_bytes"]) for item in typed
            ),
            "memory_exposed_tokens": sum(
                int(item["memory_exposed_tokens"]) for item in typed
            ),
            "estimated_cost_usd": sum(
                float(row["estimated_cost_usd"]) for row in rows
            ),
            "metered_tokens": sum(int(row["metered_tokens"]) for row in rows),
            "host_elapsed_ms": sum(float(row["host_elapsed_ms"]) for row in rows),
            "original_context_preserved": original_context_preserved,
        }
        if not prefix_stable:
            blockers.append(f"{arm}:cacheable_prefix_drift")
        if normal_request_count < 2:
            blockers.append(f"{arm}:insufficient_cache_reuse_opportunity")
        elif cache_read_tokens == 0:
            # Equal zero-hit ratios across arms are absence of evidence, not
            # evidence that memory preserved the provider cache contract.
            blockers.append(f"{arm}:cache_reuse_unobserved")
        if summary["cache_break_count"] != 0:
            blockers.append(f"{arm}:cache_break")
        if summary["compact_request_count"] != 0 or summary["auto_compact_event_count"] != 0:
            blockers.append(f"{arm}:compact")
        if summary["context_projection_count"] != 0 or not original_context_preserved:
            blockers.append(f"{arm}:context_projection")
        by_arm[arm] = summary

    baseline = by_arm.get("no_memory")
    if baseline is None:
        blockers.append("missing_no_memory_baseline")
    else:
        baseline_ratio = float(baseline["cache_reuse_ratio"])
        for arm in ("markdown_memory", "tinykg_lexical"):
            candidate = by_arm.get(arm)
            if candidate is None:
                blockers.append(f"missing_{arm}")
            elif float(candidate["cache_reuse_ratio"]) + 1e-12 < baseline_ratio:
                blockers.append(f"{arm}:cache_reuse_below_no_memory")
    return {
        "schema_version": 1,
        "cache_reuse_ratio_denominator": "input_plus_cache_read_plus_cache_write_tokens",
        "by_arm": by_arm,
        "context_cache_claim_gate_passed": not blockers,
        "claim_blockers": blockers,
    }


def _native_warm_cache_metrics(
    path: Path,
    context_cache: Mapping[str, Any],
    where: str = "production warm context/cache",
) -> Mapping[str, Any]:
    """Measure cache reuse after the first normal provider request.

    The receipt-v9 cache summary intentionally keeps its historical aggregate
    metric.  That metric includes each rollout's cold first request and, when
    present, the tool-less breaker finalization request.  This function reads
    the immutable native event artifact and exposes a separate diagnostic
    metric that excludes both.  It is deliberately fail-closed when the
    native usage timeline cannot be reconciled with the receipt's request
    classification; a partial timeline must never become a positive cache
    claim.
    """

    from .e2e_adapter import (
        MAX_NATIVE_EVENT_BYTES,
        NATIVE_EVENT_SCHEMA_VERSION,
        _native_trace_metrics,
        _read_regular_text_capped,
    )

    native, native_error = _native_trace_metrics(path)
    if native_error is not None or native is None:
        _fail(f"{where}.native_events", native_error or "invalid native events")
    text, artifact_error = _read_regular_text_capped(path, MAX_NATIVE_EVENT_BYTES)
    if artifact_error is not None or text is None:
        _fail(f"{where}.native_events", artifact_error or "cannot read native events")

    usages: List[Mapping[str, Any]] = []
    for line_no, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            envelope = json.loads(line)
        except json.JSONDecodeError as exc:
            _fail(f"{where}.native_events:{line_no}", f"invalid JSON: {exc}")
        if envelope.get("schema_version") != NATIVE_EVENT_SCHEMA_VERSION:
            _fail(f"{where}.native_events:{line_no}", "schema version drift")
        tagged = envelope.get("event")
        if not isinstance(tagged, dict) or len(tagged) != 1:
            _fail(f"{where}.native_events:{line_no}", "malformed event union")
        payload = tagged.get("usage")
        if isinstance(payload, dict):
            usages.append(payload)

    normal_request_count = _integer(
        context_cache.get("normal_request_count"),
        f"{where}.normal_request_count",
        minimum=1,
    )
    finalization_count = _integer(
        context_cache.get("tool_less_finalization_request_count"),
        f"{where}.tool_less_finalization_request_count",
    )

    def metered_tokens(usage: Mapping[str, Any]) -> int:
        return sum(
            _integer(usage.get(key), f"{where}.usage.{key}")
            for key in (
                "input_tokens",
                "output_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
            )
        )

    # The runtime emits a zero-valued usage event before the provider reports
    # its metering.  Use the first non-zero event as the cold normal request;
    # finalization is a known suffix and is excluded from warm reuse.
    real_usages = [
        usage
        for usage in usages
        if metered_tokens(usage) > 0
        or _finite_number(usage.get("estimated_cost_usd"), f"{where}.usage.cost") > 0
    ]
    expected_real = normal_request_count + finalization_count
    if len(real_usages) != expected_real:
        _fail(
            f"{where}.native_events",
            "usage timeline does not match normal/finalization request counts",
        )
    if finalization_count and finalization_count > len(real_usages):
        _fail(f"{where}.tool_less_finalization_request_count", "exceeds usage timeline")
    normal_usages = real_usages[:normal_request_count]
    finalization_usages = real_usages[normal_request_count:]
    if len(finalization_usages) != finalization_count:
        _fail(f"{where}.native_events", "finalization usage suffix is incomplete")

    def totals(values: Sequence[Mapping[str, Any]]) -> Dict[str, int]:
        return {
            key: sum(_integer(item.get(key), f"{where}.usage.{key}") for item in values)
            for key in (
                "input_tokens",
                "output_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
            )
        }

    cold = totals(normal_usages[:1])
    warm = totals(normal_usages[1:])
    finalization = totals(finalization_usages)
    warm_denominator = (
        warm["input_tokens"]
        + warm["cache_read_tokens"]
        + warm["cache_write_tokens"]
    )
    return {
        "usage_event_count": len(usages),
        "zero_usage_event_count": len(usages) - len(real_usages),
        "real_usage_event_count": len(real_usages),
        "normal_request_count": normal_request_count,
        "tool_less_finalization_request_count": finalization_count,
        "warm_request_count": len(normal_usages) - 1,
        "cold_start": cold,
        "warm": warm,
        "finalization": finalization,
        "warm_cache_reuse_denominator_tokens": warm_denominator,
        "warm_cache_reuse_ratio": (
            warm["cache_read_tokens"] / warm_denominator
            if warm_denominator > 0
            else None
        ),
        "warm_cache_hit": warm["cache_read_tokens"] > 0,
        "timeline_verified": True,
    }


def summarize_warm_context_cache(
    runtime_receipt: Mapping[str, Any],
    artifact_root: Path,
    *,
    runtime_receipt_sha256: str | None = None,
    where: str = "memory warm context/cache analysis",
) -> Mapping[str, Any]:
    """Create a local, receipt-bound warm-cache diagnostic sidecar.

    This does not modify or upgrade receipt-v9.  Each native event file is
    rehashed against the receipt before its usage timeline is used, so the
    sidecar cannot be populated from an unrelated trace.  It is diagnostic
    evidence only; the production claim gate remains the receipt-v9 gate.
    """

    schema_version = runtime_receipt.get("schema_version")
    if schema_version != PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION:
        _fail(f"{where}.schema_version", "warm-cache analysis requires production receipt-v9")
    rollouts = runtime_receipt.get("rollouts")
    if not isinstance(rollouts, list) or not rollouts:
        _fail(f"{where}.rollouts", "expected non-empty receipt rollouts")
    if runtime_receipt_sha256 is not None:
        _hash(runtime_receipt_sha256, f"{where}.runtime_receipt_sha256")

    by_arm: Dict[str, List[Mapping[str, Any]]] = {}
    rollout_metrics: List[Mapping[str, Any]] = []
    for index, raw_rollout in enumerate(rollouts):
        rollout_where = f"{where}.rollouts[{index}]"
        if not isinstance(raw_rollout, dict):
            _fail(rollout_where, "expected an object")
        paths = raw_rollout.get("artifact_paths")
        if not isinstance(paths, dict):
            _fail(f"{rollout_where}.artifact_paths", "expected an object")
        relative = _artifact_relative_path(
            paths.get("native_events"),
            f"{rollout_where}.artifact_paths.native_events",
        ).as_posix()
        path = _artifact_path(
            artifact_root,
            relative,
            f"{rollout_where}.artifact_paths.native_events",
            directory=False,
        )
        expected_digest = _hash(
            raw_rollout.get("native_events_sha256"),
            f"{rollout_where}.native_events_sha256",
        )
        try:
            observed_digest = file_sha256(path)
        except OSError as exc:
            raise ValidationError(f"{rollout_where}.native_events: cannot hash artifact: {exc}") from exc
        if observed_digest != expected_digest:
            _fail(f"{rollout_where}.native_events_sha256", "native event artifact drift")
        context_cache = raw_rollout.get("context_cache")
        if not isinstance(context_cache, dict):
            _fail(f"{rollout_where}.context_cache", "expected an object")
        metric = {
            "sequence": _integer(raw_rollout.get("sequence"), f"{rollout_where}.sequence"),
            "arm": _identifier(raw_rollout.get("arm"), f"{rollout_where}.arm"),
            "run_id": _string(raw_rollout.get("run_id"), f"{rollout_where}.run_id"),
            "native_events_sha256": expected_digest,
            **_native_warm_cache_metrics(path, context_cache, rollout_where),
        }
        rollout_metrics.append(metric)
        by_arm.setdefault(metric["arm"], []).append(metric)

    summaries: Dict[str, Mapping[str, Any]] = {}
    for arm in sorted(by_arm):
        rows = by_arm[arm]
        warm = [row["warm"] for row in rows]
        cold = [row["cold_start"] for row in rows]
        finalization = [row["finalization"] for row in rows]
        warm_denominator = sum(row["warm_cache_reuse_denominator_tokens"] for row in rows)
        warm_reads = sum(item["cache_read_tokens"] for item in warm)
        all_reads = warm_reads + sum(item["cache_read_tokens"] for item in cold) + sum(
            item["cache_read_tokens"] for item in finalization
        )
        all_prompt = sum(
            item["input_tokens"] + item["cache_read_tokens"] + item["cache_write_tokens"]
            for item in (*warm, *cold, *finalization)
        )
        summaries[arm] = {
            "rollouts": len(rows),
            "normal_request_count": sum(row["normal_request_count"] for row in rows),
            "warm_request_count": sum(row["warm_request_count"] for row in rows),
            "tool_less_finalization_request_count": sum(
                row["tool_less_finalization_request_count"] for row in rows
            ),
            "usage_event_count": sum(row["usage_event_count"] for row in rows),
            "zero_usage_event_count": sum(row["zero_usage_event_count"] for row in rows),
            "real_usage_event_count": sum(row["real_usage_event_count"] for row in rows),
            "warm_input_tokens": sum(item["input_tokens"] for item in warm),
            "warm_output_tokens": sum(item["output_tokens"] for item in warm),
            "warm_cache_read_tokens": warm_reads,
            "warm_cache_write_tokens": sum(item["cache_write_tokens"] for item in warm),
            "warm_cache_reuse_denominator_tokens": warm_denominator,
            "warm_cache_reuse_ratio": (
                warm_reads / warm_denominator if warm_denominator > 0 else None
            ),
            "warm_cache_opportunity_rollouts": sum(
                row["warm_request_count"] > 0 for row in rows
            ),
            "warm_cache_hit_rollouts": sum(row["warm_cache_hit"] for row in rows),
            "aggregate_cache_read_tokens": all_reads,
            "aggregate_prompt_tokens": all_prompt,
            "aggregate_cache_reuse_ratio": all_reads / all_prompt if all_prompt > 0 else None,
        }

    baseline = summaries.get("no_memory")
    comparison: Dict[str, Any] = {}
    blockers: List[str] = []
    if baseline is None or baseline["warm_cache_reuse_ratio"] is None:
        blockers.append("missing_no_memory_warm_cache_baseline")
    else:
        for arm in ("markdown_memory", "tinykg_lexical"):
            candidate = summaries.get(arm)
            if candidate is None or candidate["warm_cache_reuse_ratio"] is None:
                blockers.append(f"missing_{arm}_warm_cache_baseline")
                continue
            difference = float(candidate["warm_cache_reuse_ratio"]) - float(
                baseline["warm_cache_reuse_ratio"]
            )
            comparison[arm] = {
                "risk_difference": difference,
                "not_below_no_memory": difference >= -1e-12,
            }
            if difference < -1e-12:
                blockers.append(f"{arm}:warm_cache_below_no_memory")
    receipt_summary = runtime_receipt.get("context_cache_summary")
    if not isinstance(receipt_summary, dict):
        blockers.append("missing_receipt_context_cache_summary")
    elif receipt_summary.get("context_cache_claim_gate_passed") is not True:
        blockers.append("receipt_context_cache_claim_gate_not_passed")
    return {
        "schema_version": 1,
        "diagnostic_only": True,
        "runtime_receipt_sha256": runtime_receipt_sha256,
        "artifact_root_contract": "receipt-bound-native-events",
        "warm_cache_reuse_denominator": "warm_input_plus_cache_read_plus_cache_write_tokens_after_first_normal_request",
        "rollouts": rollout_metrics,
        "by_arm": summaries,
        "comparison_to_no_memory": comparison,
        "warm_cache_diagnostic_gate_passed": not blockers,
        "claim_blockers": blockers,
    }


def render_warm_context_cache_markdown(
    summary: Mapping[str, Any], title: str = "metacodes warm-cache diagnostic"
) -> str:
    lines = [
        f"# {title}",
        "",
        "> Diagnostic only. This sidecar does not upgrade receipt-v9 or establish a memory-quality claim.",
        "",
        f"- Denominator: `{summary['warm_cache_reuse_denominator']}`",
        f"- Diagnostic gate: `{'PASS' if summary['warm_cache_diagnostic_gate_passed'] else 'FAIL'}`",
        "",
        "| Arm | Rollouts | Normal requests | Warm requests | Warm cache-read | Warm denominator | Warm reuse | Aggregate reuse |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for arm, value in sorted(summary["by_arm"].items()):
        warm_ratio = value["warm_cache_reuse_ratio"]
        aggregate_ratio = value["aggregate_cache_reuse_ratio"]
        lines.append(
            f"| {arm} | {value['rollouts']} | {value['normal_request_count']} | "
            f"{value['warm_request_count']} | {value['warm_cache_read_tokens']} | "
            f"{value['warm_cache_reuse_denominator_tokens']} | "
            f"{'n/a' if warm_ratio is None else f'{warm_ratio:.5f}'} | "
            f"{'n/a' if aggregate_ratio is None else f'{aggregate_ratio:.5f}'} |"
        )
    lines.extend(["", "## Blockers", ""])
    blockers = summary["claim_blockers"]
    if blockers:
        lines.extend(f"- `{item}`" for item in blockers)
    else:
        lines.append("- none")
    lines.append("")
    return "\n".join(lines)


def _native_pricing_provenance(path: Path, where: str) -> str:
    observed: set[str] = set()
    try:
        for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not line.strip():
                continue
            value = json.loads(line)
            event = value.get("event") if isinstance(value, dict) else None
            usage = event.get("usage") if isinstance(event, dict) else None
            if not isinstance(usage, dict):
                continue
            provenance = usage.get("pricing_provenance")
            if not isinstance(provenance, str) or not provenance:
                _fail(f"{where}:{line_no}", "usage has no pricing provenance")
            observed.add(provenance)
    except ValidationError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValidationError(f"{where}: cannot inspect native pricing events: {exc}") from exc
    if len(observed) != 1:
        _fail(where, "expected one non-empty pricing provenance")
    return next(iter(observed))


def _load_unique_json(path: Path, label: str) -> Mapping[str, Any]:
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
        raise ValidationError(f"cannot read {label}: {exc}") from exc
    if not isinstance(value, dict):
        _fail(label, "expected one JSON object")
    return value


def load_observations(path: Path) -> List[Mapping[str, Any]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise ValidationError(f"cannot read memory observations {path}: {exc}") from exc
    result: List[Mapping[str, Any]] = []
    for line_no, line in enumerate(lines, 1):
        if not line.strip():
            continue
        temporary = path.with_name(f"{path.name}:{line_no}")
        # Use the same duplicate-key rejection as top-level manifests without
        # manufacturing a second permissive JSON parser.
        def reject_duplicates(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
            value: Dict[str, Any] = {}
            for key, item in pairs:
                if key in value:
                    _fail(str(temporary), f"duplicate field {key!r}")
                value[key] = item
            return value

        try:
            row = json.loads(line, object_pairs_hook=reject_duplicates)
        except ValidationError:
            raise
        except json.JSONDecodeError as exc:
            raise ValidationError(f"{path}:{line_no}: invalid JSON: {exc}") from exc
        if not isinstance(row, dict):
            _fail(f"{path}:{line_no}", "expected one JSON object")
        result.append(row)
    if not result:
        raise ValidationError(f"memory observations {path} are empty")
    return result


def load_manifest(path: Path) -> Mapping[str, Any]:
    manifest = _load_unique_json(path, f"memory manifest {path}")
    validate_manifest(manifest, f"memory manifest {path}")
    return manifest


def load_runtime_receipt(path: Path) -> Mapping[str, Any]:
    return _load_unique_json(path, f"memory runtime receipt {path}")


def _production_runtime_arm(arm_id: str) -> str:
    if arm_id in {"no_memory", "codex_style"}:
        return "codex_style"
    if arm_id in {"markdown_memory", "claude_style"}:
        return "claude_style"
    if arm_id in {"tinykg_lexical", "tinykg"}:
        return "tinykg"
    _fail("production runtime arm", f"unsupported arm {arm_id!r}")
    raise AssertionError("unreachable")


def _validate_budget_transaction_receipt(
    raw: Any,
    *,
    where: str,
    expected_run_id: str,
    expected_manifest_sha256: str,
    expected_model_fingerprint: str,
    expected_harness_fingerprint: str,
    expected_max_cost_usd: float,
    expected_max_metered_tokens: int,
    expected_actual_cost_usd: float,
    expected_actual_metered_tokens: int,
) -> Mapping[str, Any]:
    value = _object(
        raw,
        where,
        (
            "journal_id",
            "journal_revision",
            "journal_head_sha256",
            "transaction_id",
            "state",
            "identity_sha256",
            "run_id",
            "manifest_sha256",
            "model_fingerprint",
            "harness_fingerprint",
            "provider_identity",
            "max_cost_microusd",
            "max_metered_tokens",
            "reservation_revision",
            "reservation_head_sha256",
            "authorization_revision",
            "authorization_head_sha256",
            "commit_revision",
            "commit_head_sha256",
            "actual_cost_microusd",
            "actual_metered_tokens",
        ),
    )
    journal_id = _hash(value["journal_id"], f"{where}.journal_id")
    journal_revision = _integer(
        value["journal_revision"], f"{where}.journal_revision", minimum=3
    )
    journal_head = _hash(value["journal_head_sha256"], f"{where}.journal_head_sha256")
    if value["state"] != "committed":
        _fail(f"{where}.state", "successful rollout must bind a committed transaction")
    identity = {
        "run_id": _string(value["run_id"], f"{where}.run_id"),
        "manifest_sha256": _hash(
            value["manifest_sha256"], f"{where}.manifest_sha256"
        ),
        "model_fingerprint": _hash(
            value["model_fingerprint"], f"{where}.model_fingerprint"
        ),
        "harness_fingerprint": _hash(
            value["harness_fingerprint"], f"{where}.harness_fingerprint"
        ),
        "provider_identity": _string(
            value["provider_identity"], f"{where}.provider_identity"
        ),
        "max_cost_microusd": _integer(
            value["max_cost_microusd"], f"{where}.max_cost_microusd", minimum=1
        ),
        "max_metered_tokens": _integer(
            value["max_metered_tokens"], f"{where}.max_metered_tokens", minimum=1
        ),
    }
    expected_identity = {
        "run_id": expected_run_id,
        "manifest_sha256": expected_manifest_sha256,
        "model_fingerprint": expected_model_fingerprint,
        "harness_fingerprint": expected_harness_fingerprint,
        "provider_identity": PRODUCTION_PROVIDER_ID,
        "max_cost_microusd": usd_to_microusd(expected_max_cost_usd),
        "max_metered_tokens": expected_max_metered_tokens,
    }
    if identity != expected_identity:
        _fail(where, "transaction identity or fixed caps drifted")
    identity_sha = _canonical_sha256(identity)
    if _hash(value["identity_sha256"], f"{where}.identity_sha256") != identity_sha:
        _fail(f"{where}.identity_sha256", "does not bind transaction identity")
    reservation_revision = _integer(
        value["reservation_revision"], f"{where}.reservation_revision", minimum=1
    )
    transaction_id = _hash(value["transaction_id"], f"{where}.transaction_id")
    if transaction_id != _canonical_sha256(
        {
            "journal_id": journal_id,
            "reservation_revision": reservation_revision,
            "identity": identity,
        }
    ):
        _fail(f"{where}.transaction_id", "does not bind journal revision and identity")
    authorization_revision = _integer(
        value["authorization_revision"],
        f"{where}.authorization_revision",
        minimum=reservation_revision + 1,
    )
    commit_revision = _integer(
        value["commit_revision"],
        f"{where}.commit_revision",
        minimum=authorization_revision + 1,
    )
    for key in (
        "reservation_head_sha256",
        "authorization_head_sha256",
        "commit_head_sha256",
    ):
        _hash(value[key], f"{where}.{key}")
    if commit_revision != journal_revision or value["commit_head_sha256"] != journal_head:
        _fail(where, "commit receipt does not bind its journal revision/head")
    actual_cost = _integer(
        value["actual_cost_microusd"], f"{where}.actual_cost_microusd"
    )
    actual_tokens = _integer(
        value["actual_metered_tokens"], f"{where}.actual_metered_tokens"
    )
    if actual_cost != usd_to_microusd_ceiling(expected_actual_cost_usd):
        _fail(f"{where}.actual_cost_microusd", "does not conservatively bind runtime cost")
    if actual_tokens != expected_actual_metered_tokens:
        _fail(f"{where}.actual_metered_tokens", "does not bind runtime token usage")
    return value


def _validate_budget_journal_receipt(
    raw: Any,
    *,
    where: str,
    manifest_sha256: str,
    model_fingerprint: str,
    budget: Mapping[str, Any],
) -> Mapping[str, Any]:
    value = _object(
        raw,
        where,
        (
            "schema_version",
            "journal_id",
            "authority",
            "revision",
            "head_sha256",
            "committed_cost_microusd",
            "committed_metered_tokens",
            "unsettled_max_cost_microusd",
            "unsettled_max_metered_tokens",
            "exposure_cost_microusd",
            "exposure_metered_tokens",
            "transaction_states",
            "checkpoint_path",
            "checkpoint_sha256",
        ),
    )
    if value["schema_version"] != 1:
        _fail(f"{where}.schema_version", "unsupported budget journal schema")
    authority = _object(
        value["authority"],
        f"{where}.authority",
        (
            "manifest_sha256",
            "model_fingerprint",
            "provider_identity",
            "total_cost_microusd",
            "total_metered_tokens",
        ),
    )
    expected_authority = {
        "manifest_sha256": manifest_sha256,
        "model_fingerprint": model_fingerprint,
        "provider_identity": PRODUCTION_PROVIDER_ID,
        "total_cost_microusd": usd_to_microusd(budget["max_total_cost_usd"]),
        "total_metered_tokens": budget["max_total_metered_tokens"],
    }
    if authority != expected_authority:
        _fail(f"{where}.authority", "does not bind experiment authority")
    expected_journal_id = _canonical_sha256(
        {"schema_version": 1, "authority": authority}
    )
    if _hash(value["journal_id"], f"{where}.journal_id") != expected_journal_id:
        _fail(f"{where}.journal_id", "does not bind authority")
    _integer(value["revision"], f"{where}.revision", minimum=1)
    _hash(value["head_sha256"], f"{where}.head_sha256")
    _artifact_relative_path(value["checkpoint_path"], f"{where}.checkpoint_path")
    _hash(value["checkpoint_sha256"], f"{where}.checkpoint_sha256")
    for key in (
        "committed_cost_microusd",
        "committed_metered_tokens",
        "unsettled_max_cost_microusd",
        "unsettled_max_metered_tokens",
        "exposure_cost_microusd",
        "exposure_metered_tokens",
    ):
        _integer(value[key], f"{where}.{key}")
    if value["unsettled_max_cost_microusd"] != 0 or value[
        "unsettled_max_metered_tokens"
    ] != 0:
        _fail(where, "successful schedule cannot have unsettled exposure")
    states = value["transaction_states"]
    if not isinstance(states, dict) or any(
        not isinstance(key, str)
        or not isinstance(count, int)
        or isinstance(count, bool)
        or count < 0
        for key, count in states.items()
    ):
        _fail(f"{where}.transaction_states", "expected non-negative state counts")
    return value


def _validate_production_runtime_receipt(
    receipt: Mapping[str, Any],
    manifest: Mapping[str, Any],
    observations: Sequence[Mapping[str, Any]],
    dataset_sha256: str,
    where: str,
) -> None:
    schema_version = receipt.get("schema_version")
    if schema_version not in PRODUCTION_RUNTIME_RECEIPT_VERSIONS:
        _fail(
            f"{where}.schema_version",
            "expected production runtime receipt v4 through v9",
        )
    journal_bound = schema_version in {
        BUDGET_JOURNAL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
    }
    toolchain_bound = schema_version in {
        PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
    }
    scoped_recall_bound = schema_version in {
        PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
    }
    workspace_outcome_bound = schema_version in {
        PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
    }
    context_cache_bound = schema_version == PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION
    value = _object(
        receipt,
        where,
        (
            "schema_version",
            "protocol_id",
            "manifest_sha256",
            "observations_sha256",
            "dataset_sha256",
            "adapter_id",
            "adapter_revision",
            "model_id",
            "model_fingerprint",
            "harness_revision",
            "runner_sources",
            "arms",
            "graders",
            "execution_mode",
            "quality_evidence",
            "provider_id",
            "model_provider",
            "disallowed_provider_tools",
            *(("allowed_provider_tools", "ripgrep_binary_sha256") if toolchain_bound else ()),
            *(("ripgrep_snapshot_path",) if workspace_outcome_bound else ()),
            "metacodes_binary_sha256",
            "tinykg_binary_sha256",
            "budget",
            "provider_requests",
            "tool_network_isolation",
            "filesystem_isolation",
            "auto_compact_policy",
            "provider_billed_cost_usd",
            "estimated_cost_usd",
            "metered_tokens",
            "pricing_provenance",
            *(("budget_journal",) if journal_bound else ()),
            *(("context_cache_summary", "unconditional_memory_claim_eligible") if context_cache_bound else ()),
            "rollouts",
        ),
    )
    if value["protocol_id"] != PROTOCOL_ID:
        _fail(f"{where}.protocol_id", f"expected {PROTOCOL_ID!r}")
    expected_scalars = {
        "manifest_sha256": _canonical_sha256(manifest),
        "observations_sha256": _canonical_sha256(list(observations)),
        "dataset_sha256": dataset_sha256,
        "adapter_id": manifest["dataset"]["adapter_id"],
        "adapter_revision": manifest["dataset"]["adapter_revision"],
        "model_id": manifest["execution"]["model_id"],
        "model_fingerprint": manifest["execution"]["model_fingerprint"],
        "harness_revision": manifest["execution"]["harness_revision"],
    }
    for key, expected in expected_scalars.items():
        observed = _string(value[key], f"{where}.{key}")
        if key.endswith("sha256") or key.endswith("fingerprint"):
            _hash(observed, f"{where}.{key}")
        if observed != expected:
            _fail(f"{where}.{key}", "does not match the frozen manifest")
    if value["model_id"] != PRODUCTION_MODEL_ID:
        _fail(f"{where}.model_id", f"expected {PRODUCTION_MODEL_ID!r}")
    if value["execution_mode"] != PRODUCTION_EXECUTION_MODE:
        _fail(f"{where}.execution_mode", "unsupported production execution mode")
    if value["quality_evidence"] is not False:
        _fail(f"{where}.quality_evidence", "a small production pilot is not quality evidence")
    if value["provider_id"] != PRODUCTION_PROVIDER_ID:
        _fail(f"{where}.provider_id", "provider identity drift")
    if value["model_provider"] != PRODUCTION_MODEL_PROVIDER:
        _fail(f"{where}.model_provider", "model provider drift")
    if value["disallowed_provider_tools"] != list(PRODUCTION_DISALLOWED_PROVIDER_TOOLS):
        _fail(
            f"{where}.disallowed_provider_tools",
            "nested provider side-effect policy drift",
        )
    if toolchain_bound:
        if value["allowed_provider_tools"] != list(PRODUCTION_ALLOWED_PROVIDER_TOOLS):
            _fail(
                f"{where}.allowed_provider_tools",
                "provider-visible production tool policy drift",
            )
        _hash(value["ripgrep_binary_sha256"], f"{where}.ripgrep_binary_sha256")
        if workspace_outcome_bound:
            snapshot_path = _artifact_relative_path(
                value["ripgrep_snapshot_path"],
                f"{where}.ripgrep_snapshot_path",
            ).as_posix()
            if snapshot_path != PRODUCTION_RIPGREP_SNAPSHOT_PATH:
                _fail(
                    f"{where}.ripgrep_snapshot_path",
                    "does not name the canonical host snapshot",
                )
    if value["tool_network_isolation"] != PRODUCTION_TOOL_NETWORK_ISOLATION:
        _fail(
            f"{where}.tool_network_isolation",
            "must not claim unobserved Bash/subprocess network isolation",
        )
    if value["filesystem_isolation"] != PRODUCTION_FILESYSTEM_ISOLATION:
        _fail(
            f"{where}.filesystem_isolation",
            "must not claim unobserved host or cross-arm filesystem isolation",
        )
    if value["auto_compact_policy"] != PRODUCTION_AUTO_COMPACT_POLICY:
        _fail(f"{where}.auto_compact_policy", "production trace may compact")
    if value["provider_billed_cost_usd"] is not None:
        _fail(
            f"{where}.provider_billed_cost_usd",
            "must remain null when no provider bill is available",
        )
    if value["pricing_provenance"] != PRODUCTION_PRICING_PROVENANCE:
        _fail(f"{where}.pricing_provenance", "unknown pricing provenance")

    raw_sources = value["runner_sources"]
    if not isinstance(raw_sources, list):
        _fail(f"{where}.runner_sources", "expected an array")
    source_modules: List[str] = []
    source_paths: set[str] = set()
    for index, raw_source in enumerate(raw_sources):
        source_where = f"{where}.runner_sources[{index}]"
        source = _object(raw_source, source_where, ("module", "path", "sha256"))
        module = _identifier(source["module"], f"{source_where}.module")
        path = _artifact_relative_path(source["path"], f"{source_where}.path").as_posix()
        _hash(source["sha256"], f"{source_where}.sha256")
        if path != f"runner-sources/{module}.py":
            _fail(f"{source_where}.path", "does not match its runner module")
        if module in source_modules or path in source_paths:
            _fail(source_where, "duplicate runner source")
        source_modules.append(module)
        source_paths.add(path)
    expected_source_modules = {
        LEGACY_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION: LEGACY_PRODUCTION_RUNNER_SOURCE_MODULES,
        BUDGET_JOURNAL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION: PRE_QUERY_PLAN_PRODUCTION_RUNNER_SOURCE_MODULES,
        PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION: PRE_CONSOLIDATION_PRODUCTION_RUNNER_SOURCE_MODULES,
        PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION: PRODUCTION_RUNNER_SOURCE_MODULES,
        PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION: PRODUCTION_RUNNER_SOURCE_MODULES,
        PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION: PRODUCTION_RUNNER_SOURCE_MODULES,
    }[schema_version]
    if tuple(source_modules) != expected_source_modules:
        _fail(f"{where}.runner_sources", "does not bind the production host source set")

    if value["arms"] != manifest["execution"]["arms"]:
        _fail(f"{where}.arms", "runtime arm identities do not match the manifest")
    expected_graders = [
        {"case_id": case["id"], "fingerprint": case["grader"]["fingerprint"]}
        for case in manifest["cases"]
    ]
    if value["graders"] != expected_graders:
        _fail(f"{where}.graders", "runtime grader identities do not match the manifest")

    budget = _object(
        value["budget"],
        f"{where}.budget",
        (
            "max_total_cost_usd",
            "max_total_metered_tokens",
            "max_rollout_cost_usd",
            "max_rollout_metered_tokens",
            "max_output_tokens",
        ),
    )
    max_total_cost = _finite_number(
        budget["max_total_cost_usd"], f"{where}.budget.max_total_cost_usd"
    )
    max_rollout_cost = _finite_number(
        budget["max_rollout_cost_usd"], f"{where}.budget.max_rollout_cost_usd"
    )
    max_total_tokens = _integer(
        budget["max_total_metered_tokens"],
        f"{where}.budget.max_total_metered_tokens",
        minimum=1,
    )
    max_rollout_tokens = _integer(
        budget["max_rollout_metered_tokens"],
        f"{where}.budget.max_rollout_metered_tokens",
        minimum=1,
    )
    _integer(budget["max_output_tokens"], f"{where}.budget.max_output_tokens", minimum=1)
    if (
        max_total_cost <= 0
        or max_rollout_cost <= 0
        or max_total_cost > MAX_USER_AUTHORITY_USD
    ):
        _fail(f"{where}.budget", "invalid paid cost authority")

    rollouts = value["rollouts"]
    if not isinstance(rollouts, list) or len(rollouts) != len(observations):
        _fail(f"{where}.rollouts", f"expected exactly {len(observations)} entries")
    if max_rollout_cost * len(rollouts) >= max_total_cost:
        _fail(f"{where}.budget", "total cost cap lacks strict schedule headroom")
    if max_rollout_tokens * len(rollouts) >= max_total_tokens:
        _fail(f"{where}.budget", "total token cap lacks strict schedule headroom")
    budget_journal_value = (
        _validate_budget_journal_receipt(
            value["budget_journal"],
            where=f"{where}.budget_journal",
            manifest_sha256=_canonical_sha256(manifest),
            model_fingerprint=manifest["execution"]["model_fingerprint"],
            budget=budget,
        )
        if journal_bound
        else None
    )

    metacodes_sha = _hash(value["metacodes_binary_sha256"], f"{where}.metacodes_binary_sha256")
    tinykg_sha = _hash(value["tinykg_binary_sha256"], f"{where}.tinykg_binary_sha256")
    schedule = {entry["sequence"]: entry for entry in manifest["schedule"]}
    cases = {case["id"]: case for case in manifest["cases"]}
    arms_by_id = {arm["id"]: arm for arm in value["arms"]}
    seen_run_ids: set[str] = set()
    seen_budget_transaction_ids: set[str] = set()
    budget_transactions: List[Mapping[str, Any]] = []
    for index, raw_rollout in enumerate(rollouts):
        rollout_where = f"{where}.rollouts[{index}]"
        rollout = _object(
            raw_rollout,
            rollout_where,
            (
                "sequence",
                "case_id",
                "trial",
                "arm",
                "run_id",
                "task_fingerprint",
                "harness_fingerprint",
                "environment",
                "environment_fingerprint",
                "metacodes_binary_sha256",
                "tinykg_binary_sha256",
                "native_events_sha256",
                "result_sha256",
                "stderr_sha256",
                "cassette_sha256",
                "transcript_sha256",
                "workspace_sha256",
                "artifact_paths",
                "store_revision_before",
                "store_revision_after",
                "raw_store_digest_before",
                "raw_store_digest_after",
                "memory_backend",
                "memory_phase",
                "memory_state_before",
                "memory_state_after",
                "memory_components_before",
                "memory_components_after",
                "memory_read_events",
                "memory_write_events",
                "stop_reason",
                "provider_mode",
                "provider_requests",
                "tool_network_isolation",
                "filesystem_isolation",
                "provider_billed_cost_usd",
                "estimated_cost_usd",
                "metered_tokens",
                "pricing_provenance",
                "compact_event_count",
                "memory_auto_injected_bytes",
                "memory_tool_result_bytes",
                *(("context_cache",) if context_cache_bound else ()),
                "treatment_activation",
                *(("scoped_recall",) if scoped_recall_bound else ()),
                *(("consolidation",) if scoped_recall_bound else ()),
                *(("budget_transaction",) if journal_bound else ()),
                *(("sandbox",) if journal_bound else ()),
                "observation_sha256",
                "host_elapsed_ms",
            ),
        )
        sequence = _integer(rollout["sequence"], f"{rollout_where}.sequence")
        if sequence != index or sequence not in schedule:
            _fail(f"{rollout_where}.sequence", "must be contiguous and scheduled")
        scheduled = schedule[sequence]
        for key in ("case_id", "trial", "arm"):
            if rollout[key] != scheduled[key]:
                _fail(f"{rollout_where}.{key}", "does not match frozen schedule")
        case = cases[rollout["case_id"]]
        run_id = _string(rollout["run_id"], f"{rollout_where}.run_id")
        if run_id in seen_run_ids:
            _fail(f"{rollout_where}.run_id", "must be unique")
        seen_run_ids.add(run_id)
        if _hash(rollout["task_fingerprint"], f"{rollout_where}.task_fingerprint") != _canonical_sha256(case):
            _fail(f"{rollout_where}.task_fingerprint", "does not bind the frozen case")
        if _hash(rollout["metacodes_binary_sha256"], f"{rollout_where}.metacodes_binary_sha256") != metacodes_sha:
            _fail(f"{rollout_where}.metacodes_binary_sha256", "binary identity drift")

        runtime_arm = _production_runtime_arm(str(rollout["arm"]))
        tinykg_enabled = runtime_arm == "tinykg"
        expected_backend = {
            "codex_style": "none",
            "claude_style": "markdown",
            "tinykg": "tinykg_integrated",
        }[runtime_arm]
        if rollout["memory_backend"] != expected_backend:
            _fail(f"{rollout_where}.memory_backend", "does not match frozen arm")
        expected_harness_fingerprint = _production_harness_fingerprint(
            metacodes_binary_sha256=metacodes_sha,
            tinykg_binary_sha256=tinykg_sha if tinykg_enabled else None,
            harness_revision=value["harness_revision"],
            arm=arms_by_id[rollout["arm"]],
            runtime_arm=runtime_arm,
            runtime_budget=budget,
            runner_sources=raw_sources,
            allowed_provider_tools=(
                value["allowed_provider_tools"] if toolchain_bound else None
            ),
            ripgrep_binary_sha256=(
                value["ripgrep_binary_sha256"] if toolchain_bound else None
            ),
        )
        if _hash(
            rollout["harness_fingerprint"],
            f"{rollout_where}.harness_fingerprint",
        ) != expected_harness_fingerprint:
            _fail(f"{rollout_where}.harness_fingerprint", "does not bind runtime inputs")
        environment = _object(
            rollout["environment"],
            f"{rollout_where}.environment",
            (
                "platform",
                "python",
                "source_sha256",
                "tinykg_binary_sha256",
                "project_domain",
                "child_path",
                "auto_compact_policy",
                *(("ripgrep_binary_sha256",) if toolchain_bound else ()),
                *(("sandbox_backend", "sandbox_profile_sha256") if journal_bound else ()),
            ),
        )
        environment_fingerprint = _hash(
            rollout["environment_fingerprint"],
            f"{rollout_where}.environment_fingerprint",
        )
        if environment_fingerprint != _canonical_sha256(environment):
            _fail(f"{rollout_where}.environment_fingerprint", "does not bind environment claims")
        _string(environment["platform"], f"{rollout_where}.environment.platform")
        _string(environment["python"], f"{rollout_where}.environment.python")
        if _hash(environment["source_sha256"], f"{rollout_where}.environment.source_sha256") != dataset_sha256:
            _fail(f"{rollout_where}.environment.source_sha256", "dataset identity drift")
        _string(environment["project_domain"], f"{rollout_where}.environment.project_domain")
        if environment["child_path"] != PRODUCTION_CHILD_PATH:
            _fail(f"{rollout_where}.environment.child_path", "production environment is not minimal")
        if environment["auto_compact_policy"] != PRODUCTION_AUTO_COMPACT_POLICY:
            _fail(f"{rollout_where}.environment.auto_compact_policy", "production trace may compact")
        if toolchain_bound and environment["ripgrep_binary_sha256"] != value["ripgrep_binary_sha256"]:
            _fail(
                f"{rollout_where}.environment.ripgrep_binary_sha256",
                "does not bind the production toolchain",
            )
        if journal_bound:
            sandbox = _object(
                rollout["sandbox"],
                f"{rollout_where}.sandbox",
                (
                    "backend",
                    "profile_path",
                    "profile_sha256",
                    "probe_path",
                    "probe_sha256",
                ),
            )
            if sandbox["backend"] != PRODUCTION_SANDBOX_BACKEND:
                _fail(f"{rollout_where}.sandbox.backend", "sandbox backend drift")
            profile_sha256 = _hash(
                sandbox["profile_sha256"],
                f"{rollout_where}.sandbox.profile_sha256",
            )
            _hash(sandbox["probe_sha256"], f"{rollout_where}.sandbox.probe_sha256")
            profile_path = _artifact_relative_path(
                sandbox["profile_path"],
                f"{rollout_where}.sandbox.profile_path",
            ).as_posix()
            probe_path = _artifact_relative_path(
                sandbox["probe_path"],
                f"{rollout_where}.sandbox.probe_path",
            ).as_posix()
            if profile_path == probe_path:
                _fail(f"{rollout_where}.sandbox", "profile and probe paths must be distinct")
            if environment["sandbox_backend"] != PRODUCTION_SANDBOX_BACKEND:
                _fail(
                    f"{rollout_where}.environment.sandbox_backend",
                    "sandbox backend drift",
                )
            if environment["sandbox_profile_sha256"] != profile_sha256:
                _fail(
                    f"{rollout_where}.environment.sandbox_profile_sha256",
                    "does not bind the sandbox profile",
                )
        if tinykg_enabled:
            if _hash(rollout["tinykg_binary_sha256"], f"{rollout_where}.tinykg_binary_sha256") != tinykg_sha:
                _fail(f"{rollout_where}.tinykg_binary_sha256", "binary identity drift")
            if environment["tinykg_binary_sha256"] != tinykg_sha:
                _fail(f"{rollout_where}.environment.tinykg_binary_sha256", "binary identity drift")
        elif rollout["tinykg_binary_sha256"] is not None:
            _fail(f"{rollout_where}.tinykg_binary_sha256", "control arm must use null")
        elif environment["tinykg_binary_sha256"] is not None:
            _fail(f"{rollout_where}.environment.tinykg_binary_sha256", "control arm must use null")
        for key in (
            "native_events_sha256",
            "result_sha256",
            "stderr_sha256",
            "cassette_sha256",
            "transcript_sha256",
            "workspace_sha256",
        ):
            _hash(rollout[key], f"{rollout_where}.{key}")
        paths = _object(
            rollout["artifact_paths"],
            f"{rollout_where}.artifact_paths",
            (
                "native_events",
                "result",
                "stderr",
                "cassette",
                "transcript",
                "workspace",
                "store",
                "memory_state",
            ),
        )
        for key in ("native_events", "result", "stderr", "cassette", "transcript", "workspace"):
            _artifact_relative_path(paths[key], f"{rollout_where}.artifact_paths.{key}")
        if tinykg_enabled:
            _artifact_relative_path(paths["store"], f"{rollout_where}.artifact_paths.store")
        elif paths["store"] is not None:
            _fail(f"{rollout_where}.artifact_paths.store", "control arm must use null")
        if expected_backend == "none":
            if paths["memory_state"] is not None:
                _fail(f"{rollout_where}.artifact_paths.memory_state", "no-memory arm must use null")
        else:
            _artifact_relative_path(paths["memory_state"], f"{rollout_where}.artifact_paths.memory_state")

        if rollout["stop_reason"] not in {"end_turn", "max_turns", "tool_loop", "budget"}:
            _fail(f"{rollout_where}.stop_reason", "unsupported native stop reason")
        if rollout["provider_mode"] != "production-network":
            _fail(f"{rollout_where}.provider_mode", "must be production-network")
        provider_requests = _integer(
            rollout["provider_requests"], f"{rollout_where}.provider_requests", minimum=1
        )
        if rollout["tool_network_isolation"] != PRODUCTION_TOOL_NETWORK_ISOLATION:
            _fail(
                f"{rollout_where}.tool_network_isolation",
                "must not claim unobserved Bash/subprocess network isolation",
            )
        if rollout["filesystem_isolation"] != PRODUCTION_FILESYSTEM_ISOLATION:
            _fail(
                f"{rollout_where}.filesystem_isolation",
                "must not claim unobserved host or cross-arm filesystem isolation",
            )
        if rollout["provider_billed_cost_usd"] is not None:
            _fail(f"{rollout_where}.provider_billed_cost_usd", "must remain null")
        estimated_cost = _finite_number(
            rollout["estimated_cost_usd"], f"{rollout_where}.estimated_cost_usd"
        )
        metered_tokens = _integer(
            rollout["metered_tokens"], f"{rollout_where}.metered_tokens", minimum=1
        )
        if estimated_cost > max_rollout_cost or metered_tokens > max_rollout_tokens:
            _fail(rollout_where, "rollout exceeded its fixed production budget")
        if journal_bound:
            assert budget_journal_value is not None
            transaction = _validate_budget_transaction_receipt(
                rollout["budget_transaction"],
                where=f"{rollout_where}.budget_transaction",
                expected_run_id=run_id,
                expected_manifest_sha256=_canonical_sha256(manifest),
                expected_model_fingerprint=value["model_fingerprint"],
                expected_harness_fingerprint=expected_harness_fingerprint,
                expected_max_cost_usd=max_rollout_cost,
                expected_max_metered_tokens=max_rollout_tokens,
                expected_actual_cost_usd=estimated_cost,
                expected_actual_metered_tokens=metered_tokens,
            )
            if transaction["journal_id"] != budget_journal_value["journal_id"]:
                _fail(
                    f"{rollout_where}.budget_transaction.journal_id",
                    "does not match final journal",
                )
            transaction_id = str(transaction["transaction_id"])
            if transaction_id in seen_budget_transaction_ids:
                _fail(f"{rollout_where}.budget_transaction.transaction_id", "is duplicated")
            seen_budget_transaction_ids.add(transaction_id)
            budget_transactions.append(transaction)
        if rollout["pricing_provenance"] != PRODUCTION_PRICING_PROVENANCE:
            _fail(f"{rollout_where}.pricing_provenance", "unknown pricing provenance")
        compact_events = _integer(
            rollout["compact_event_count"],
            f"{rollout_where}.compact_event_count",
        )
        if compact_events != 0:
            _fail(
                f"{rollout_where}.compact_event_count",
                "production pilot requires an uncompacted trace",
            )
        auto_injected_bytes = _integer(
            rollout["memory_auto_injected_bytes"],
            f"{rollout_where}.memory_auto_injected_bytes",
        )
        tool_result_bytes = _integer(
            rollout["memory_tool_result_bytes"],
            f"{rollout_where}.memory_tool_result_bytes",
        )
        if context_cache_bound:
            context_cache = _object(
                rollout["context_cache"],
                f"{rollout_where}.context_cache",
                (
                    "normal_request_count",
                    "tool_less_finalization_request_count",
                    "cache_control",
                    "system_prompt_sha256",
                    "system_prompt_bytes",
                    "tools_schema_sha256",
                    "tools_schema_bytes",
                    "cacheable_prefix_sha256",
                    "prefix_stable",
                    "input_tokens",
                    "output_tokens",
                    "cache_read_tokens",
                    "cache_write_tokens",
                    "cache_break_count",
                    "compact_request_count",
                    "auto_compact_event_count",
                    "context_projection_count",
                    "context_projected_bytes",
                    "memory_exposed_tokens",
                    "original_context_preserved",
                ),
            )
            normal_requests = _integer(
                context_cache["normal_request_count"],
                f"{rollout_where}.context_cache.normal_request_count",
                minimum=1,
            )
            tool_less_requests = _integer(
                context_cache["tool_less_finalization_request_count"],
                f"{rollout_where}.context_cache.tool_less_finalization_request_count",
            )
            if normal_requests + tool_less_requests != provider_requests:
                _fail(f"{rollout_where}.context_cache", "request classification mismatch")
            if context_cache["cache_control"] != {"type": "ephemeral"}:
                _fail(f"{rollout_where}.context_cache.cache_control", "contract drift")
            _hash(
                context_cache["cacheable_prefix_sha256"],
                f"{rollout_where}.context_cache.cacheable_prefix_sha256",
            )
            for key in ("system_prompt_sha256", "tools_schema_sha256"):
                _hash(context_cache[key], f"{rollout_where}.context_cache.{key}")
            for key in ("system_prompt_bytes", "tools_schema_bytes"):
                _integer(
                    context_cache[key],
                    f"{rollout_where}.context_cache.{key}",
                    minimum=1,
                )
            if context_cache["prefix_stable"] is not True:
                _fail(f"{rollout_where}.context_cache.prefix_stable", "must be true")
            token_total = 0
            for key in (
                "input_tokens",
                "output_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
            ):
                token_total += _integer(
                    context_cache[key], f"{rollout_where}.context_cache.{key}"
                )
            if token_total != metered_tokens:
                _fail(f"{rollout_where}.context_cache", "usage total mismatch")
            for key in (
                "cache_break_count",
                "compact_request_count",
                "auto_compact_event_count",
                "context_projection_count",
                "context_projected_bytes",
                "memory_exposed_tokens",
            ):
                _integer(context_cache[key], f"{rollout_where}.context_cache.{key}")
            if context_cache["compact_request_count"] != compact_events:
                _fail(f"{rollout_where}.context_cache.compact_request_count", "drift")
            if context_cache["memory_exposed_tokens"] != (
                auto_injected_bytes + tool_result_bytes + 3
            ) // 4:
                _fail(f"{rollout_where}.context_cache.memory_exposed_tokens", "drift")
            # A paid summary request may be rejected by the no-savings gate;
            # that costs time/tokens and blocks the cache claim, but it does
            # not itself mutate the provider-visible conversation. Actual
            # loss is grounded only by committed compact/projection events.
            expected_preserved = (
                context_cache["auto_compact_event_count"] == 0
                and context_cache["context_projection_count"] == 0
            )
            if context_cache["original_context_preserved"] is not expected_preserved:
                _fail(f"{rollout_where}.context_cache.original_context_preserved", "drift")
            if (context_cache["context_projection_count"] == 0) != (
                context_cache["context_projected_bytes"] == 0
            ):
                _fail(f"{rollout_where}.context_cache.context_projected_bytes", "drift")
        _finite_number(rollout["host_elapsed_ms"], f"{rollout_where}.host_elapsed_ms")

        activation = _object(
            rollout["treatment_activation"],
            f"{rollout_where}.treatment_activation",
            (
                "runtime_arm",
                "system_prompt_sha256",
                "tool_names_sha256",
                "memory_prompt_active",
                "knowledge_graph_prompt_active",
                "tinykg_tools_active",
                "fingerprint",
            ),
        )
        if activation["runtime_arm"] != runtime_arm:
            _fail(f"{rollout_where}.treatment_activation.runtime_arm", "arm drift")
        _hash(activation["system_prompt_sha256"], f"{rollout_where}.treatment_activation.system_prompt_sha256")
        _hash(activation["tool_names_sha256"], f"{rollout_where}.treatment_activation.tool_names_sha256")
        expected_flags = {
            "codex_style": (False, False, []),
            "claude_style": (True, False, []),
            "tinykg": (True, True, ["KgContext", "KgRecall", "KgRemember"]),
        }[runtime_arm]
        observed_flags = (
            activation["memory_prompt_active"],
            activation["knowledge_graph_prompt_active"],
            activation["tinykg_tools_active"],
        )
        if observed_flags != expected_flags:
            _fail(f"{rollout_where}.treatment_activation", "treatment flags drift")
        activation_payload = {key: activation[key] for key in activation if key != "fingerprint"}
        if _hash(activation["fingerprint"], f"{rollout_where}.treatment_activation.fingerprint") != _canonical_sha256(activation_payload):
            _fail(f"{rollout_where}.treatment_activation.fingerprint", "does not bind activation")

        scoped_recall = rollout.get("scoped_recall") if scoped_recall_bound else None
        if tinykg_enabled and scoped_recall_bound:
            scoped_recall = _object(
                scoped_recall,
                f"{rollout_where}.scoped_recall",
                (
                    "trace_id",
                    "schema_version",
                    "status",
                    "query_sha256",
                    "result_count",
                    "injected_count",
                    "injected_bytes",
                    "injection_sha256",
                ),
            )
            if scoped_recall["schema_version"] != "metacodes-scoped-recall-v1":
                _fail(f"{rollout_where}.scoped_recall.schema_version", "unsupported receipt")
            _string(scoped_recall["trace_id"], f"{rollout_where}.scoped_recall.trace_id")
            if scoped_recall["status"] not in {
                "injected",
                "search_error",
                "no_hits",
                "below_floor",
            }:
                _fail(f"{rollout_where}.scoped_recall.status", "invalid ready-KG status")
            _hash(scoped_recall["query_sha256"], f"{rollout_where}.scoped_recall.query_sha256")
            _hash(scoped_recall["injection_sha256"], f"{rollout_where}.scoped_recall.injection_sha256")
            for key in ("result_count", "injected_count", "injected_bytes"):
                _integer(scoped_recall[key], f"{rollout_where}.scoped_recall.{key}")
            expected_query = hashlib.sha256(
                str(case["prompt"]).encode("utf-8")[:400]
            ).hexdigest()
            if scoped_recall["query_sha256"] != expected_query:
                _fail(f"{rollout_where}.scoped_recall.query_sha256", "does not bind case prompt")
            if scoped_recall["status"] == "injected":
                if scoped_recall["injected_count"] < 1 or scoped_recall["injected_bytes"] < 1:
                    _fail(f"{rollout_where}.scoped_recall", "injected receipt is empty")
                if auto_injected_bytes < scoped_recall["injected_bytes"]:
                    _fail(f"{rollout_where}.memory_auto_injected_bytes", "omits scoped recall")
            elif (
                scoped_recall["injected_count"] != 0
                or scoped_recall["injected_bytes"] != 0
                or scoped_recall["injection_sha256"] != "0" * 64
            ):
                _fail(f"{rollout_where}.scoped_recall", "non-injected receipt claims payload")
        elif scoped_recall_bound and scoped_recall is not None:
            _fail(f"{rollout_where}.scoped_recall", "control arm must use null")

        online = is_online_memory_case(case)
        consolidation = rollout.get("consolidation") if scoped_recall_bound else None

        observation = observations[sequence]
        expected_observation_schema = (
            OBSERVATION_SCHEMA_VERSION
            if workspace_outcome_bound
            else LEGACY_OBSERVATION_SCHEMA_VERSION
        )
        if observation.get("schema_version") != expected_observation_schema:
            _fail(
                f"{rollout_where}.observation.schema_version",
                f"expected {expected_observation_schema}",
            )
        if _hash(rollout["observation_sha256"], f"{rollout_where}.observation_sha256") != _canonical_sha256(observation):
            _fail(f"{rollout_where}.observation_sha256", "does not bind observation")
        trajectory = observation.get("trajectory")
        retrieval = observation.get("retrieval")
        cost = observation.get("cost")
        memory = observation.get("memory")
        graph = observation.get("graph")
        governance = observation.get("governance")
        evaluator = observation.get("evaluator")
        if not all(
            isinstance(item, dict)
            for item in (trajectory, retrieval, cost, memory, graph, governance, evaluator)
        ):
            _fail(f"{rollout_where}.observation", "missing production lifecycle fields")
        if workspace_outcome_bound:
            workspace = _object(
                observation.get("workspace"),
                f"{rollout_where}.observation.workspace",
                ("deterministic_success",),
            )
            consolidation_success = workspace.get("deterministic_success")
        else:
            consolidation_success = evaluator.get("deterministic_success")
        if scoped_recall_bound:
            consolidation = _validate_consolidation_receipt(
                consolidation,
                required=online and expected_backend != "none",
                tinykg_enabled=tinykg_enabled,
                native_events_sha256=rollout["native_events_sha256"],
                deterministic_success=consolidation_success,
                final_store_revision=rollout["store_revision_after"],
                final_raw_store_digest=rollout["raw_store_digest_after"],
                where=f"{rollout_where}.consolidation",
            )
        if _integer(trajectory.get("model_requests"), f"{rollout_where}.trajectory.model_requests", minimum=1) != provider_requests:
            _fail(f"{rollout_where}.provider_requests", "does not match native trajectory")
        memory_reads = _integer(rollout["memory_read_events"], f"{rollout_where}.memory_read_events")
        memory_writes = _integer(rollout["memory_write_events"], f"{rollout_where}.memory_write_events")
        if _integer(trajectory.get("tool_calls"), f"{rollout_where}.trajectory.tool_calls") < memory_reads + memory_writes:
            _fail(f"{rollout_where}.trajectory.tool_calls", "cannot be below memory activity")
        expected_exposed_tokens = (auto_injected_bytes + tool_result_bytes + 3) // 4
        if memory.get("exposed_tokens") != expected_exposed_tokens:
            _fail(
                f"{rollout_where}.observation.memory.exposed_tokens",
                "does not match raw memory exposure bytes",
            )
        if cost.get("cost_usd") != estimated_cost:
            _fail(f"{rollout_where}.estimated_cost_usd", "does not match observation cost")

        phase = _string(rollout["memory_phase"], f"{rollout_where}.memory_phase")
        if phase != case["split"]:
            _fail(f"{rollout_where}.memory_phase", "does not match frozen case")
        state_before = _string(rollout["memory_state_before"], f"{rollout_where}.memory_state_before")
        state_after = _string(rollout["memory_state_after"], f"{rollout_where}.memory_state_after")
        before_components = _object(
            rollout["memory_components_before"],
            f"{rollout_where}.memory_components_before",
            ("markdown", "tinykg"),
        )
        after_components = _object(
            rollout["memory_components_after"],
            f"{rollout_where}.memory_components_after",
            ("markdown", "tinykg"),
        )
        if expected_backend == "none":
            if (
                state_before != "none"
                or state_after != "none"
                or before_components != {"markdown": None, "tinykg": None}
                or after_components != {"markdown": None, "tinykg": None}
                or memory_reads != 0
                or memory_writes != 0
                or auto_injected_bytes != 0
                or tool_result_bytes != 0
            ):
                _fail(rollout_where, "no-memory arm has durable-memory activity")
        else:
            if expected_backend == "markdown":
                for components_where, components in (
                    ("memory_components_before", before_components),
                    ("memory_components_after", after_components),
                ):
                    _hash(components["markdown"], f"{rollout_where}.{components_where}.markdown")
                    if components["tinykg"] is not None:
                        _fail(f"{rollout_where}.{components_where}.tinykg", "Markdown arm must use null")
            else:
                for components_where, components in (
                    ("memory_components_before", before_components),
                    ("memory_components_after", after_components),
                ):
                    _hash(components["markdown"], f"{rollout_where}.{components_where}.markdown")
                    _hash(components["tinykg"], f"{rollout_where}.{components_where}.tinykg")
            if state_before != _canonical_sha256(before_components) or state_after != _canonical_sha256(after_components):
                _fail(rollout_where, "memory state does not bind its components")
        online = is_online_memory_case(case)
        expected_write_mode = "disabled" if expected_backend == "none" else "online" if online else "read_only"
        if memory.get("write_mode") != expected_write_mode:
            _fail(f"{rollout_where}.observation.memory.write_mode", "lifecycle mismatch")
        if scoped_recall_bound and online and expected_backend != "none":
            if state_before == state_after or before_components["markdown"] == after_components["markdown"]:
                _fail(
                    rollout_where,
                    "online memory arm did not durably consolidate Markdown state",
                )
            if tinykg_enabled and (
                before_components["tinykg"] == after_components["tinykg"]
                or rollout["raw_store_digest_before"] == rollout["raw_store_digest_after"]
            ):
                _fail(
                    rollout_where,
                    "online TinyKG arm did not durably consolidate graph bytes",
                )
        if not online and (memory_writes != 0 or state_before != state_after):
            _fail(rollout_where, "read-only phase changed durable memory state")
        if not online and governance.get("offline_write_events") != 0:
            _fail(f"{rollout_where}.observation.governance", "offline write leakage")
        host_recall_injected = bool(
            isinstance(scoped_recall, dict) and scoped_recall.get("status") == "injected"
        )
        if retrieval.get("enabled") is not bool(
            retrieval.get("query_variants") or host_recall_injected
        ):
            _fail(
                f"{rollout_where}.observation.retrieval",
                "activation is not grounded in observed queries or host recall",
            )
        markdown_activation_missing = bool(
            scoped_recall_bound
            and not online
            and expected_backend == "markdown"
            and auto_injected_bytes <= 0
            and tool_result_bytes <= 0
        )
        explicit_recall = bool(
            memory_reads > 0
            and tool_result_bytes > 0
            and isinstance(retrieval.get("query_variants"), list)
            and retrieval["query_variants"]
        )
        tinykg_activation_missing = bool(
            scoped_recall_bound
            and not online
            and tinykg_enabled
            and not host_recall_injected
            and not explicit_recall
        )
        if (markdown_activation_missing or tinykg_activation_missing) and evaluator.get(
            "status"
        ) != "invalid":
            _fail(
                f"{rollout_where}.observation.evaluator",
                "inactive memory treatment must be explicitly invalid",
            )

        store_before = _string(rollout["store_revision_before"], f"{rollout_where}.store_revision_before")
        store_after = _string(rollout["store_revision_after"], f"{rollout_where}.store_revision_after")
        raw_before = _string(rollout["raw_store_digest_before"], f"{rollout_where}.raw_store_digest_before")
        raw_after = _string(rollout["raw_store_digest_after"], f"{rollout_where}.raw_store_digest_after")
        if tinykg_enabled:
            for key, item in (
                ("store_revision_before", store_before),
                ("store_revision_after", store_after),
                ("raw_store_digest_before", raw_before),
                ("raw_store_digest_after", raw_after),
            ):
                _hash(item, f"{rollout_where}.{key}")
            if before_components["tinykg"] != store_before or after_components["tinykg"] != store_after:
                _fail(rollout_where, "integrated memory does not bind TinyKG revision")
            if not online and (store_before != store_after or raw_before != raw_after):
                _fail(rollout_where, "read-only phase changed TinyKG store")
            if graph.get("revision") != store_after:
                _fail(f"{rollout_where}.observation.graph.revision", "does not bind TinyKG state")
        elif (store_before, store_after, raw_before, raw_after) != ("none", "none", "none", "none"):
            _fail(rollout_where, "control arm must use none store digests")
        elif graph.get("revision") != state_after:
            _fail(f"{rollout_where}.observation.graph.revision", "does not bind memory state")

    if context_cache_bound:
        expected_context_cache_summary = _summarize_context_cache(rollouts)
        if value["context_cache_summary"] != expected_context_cache_summary:
            _fail(
                f"{where}.context_cache_summary",
                "does not equal the rollout-derived context/cache summary",
            )
        if value["unconditional_memory_claim_eligible"] is not False:
            _fail(
                f"{where}.unconditional_memory_claim_eligible",
                "a small production pilot cannot authorize an unconditional memory claim",
            )

    estimated_total = sum(float(item["estimated_cost_usd"]) for item in rollouts)
    metered_total = sum(int(item["metered_tokens"]) for item in rollouts)
    observed_estimated_total = _finite_number(
        value["estimated_cost_usd"], f"{where}.estimated_cost_usd"
    )
    observed_metered_total = _integer(
        value["metered_tokens"], f"{where}.metered_tokens", minimum=1
    )
    observed_provider_total = _integer(
        value["provider_requests"], f"{where}.provider_requests", minimum=1
    )
    if observed_estimated_total != estimated_total or estimated_total > max_total_cost:
        _fail(f"{where}.estimated_cost_usd", "does not equal bounded rollout total")
    if observed_metered_total != metered_total or metered_total > max_total_tokens:
        _fail(f"{where}.metered_tokens", "does not equal bounded rollout total")
    provider_total = sum(int(item["provider_requests"]) for item in rollouts)
    if observed_provider_total != provider_total:
        _fail(f"{where}.provider_requests", "does not equal rollout total")
    if journal_bound:
        assert budget_journal_value is not None
        committed_cost = sum(
            int(transaction["actual_cost_microusd"])
            for transaction in budget_transactions
        )
        committed_tokens = sum(
            int(transaction["actual_metered_tokens"])
            for transaction in budget_transactions
        )
        if (
            budget_journal_value["committed_cost_microusd"] != committed_cost
            or budget_journal_value["exposure_cost_microusd"] != committed_cost
            or budget_journal_value["committed_metered_tokens"] != committed_tokens
            or budget_journal_value["exposure_metered_tokens"] != committed_tokens
        ):
            _fail(f"{where}.budget_journal", "final exposure does not equal committed rollouts")
        states = budget_journal_value["transaction_states"]
        if set(states) - {"committed", "aborted_pre_request"}:
            _fail(f"{where}.budget_journal.transaction_states", "contains an unsettled state")
        if states.get("committed", 0) != len(rollouts):
            _fail(f"{where}.budget_journal.transaction_states", "committed count drift")
        if budget_transactions:
            final_transaction = budget_transactions[-1]
            if (
                final_transaction["journal_revision"] != budget_journal_value["revision"]
                or final_transaction["journal_head_sha256"]
                != budget_journal_value["head_sha256"]
            ):
                _fail(f"{where}.budget_journal", "final revision/head is not the last commit")


def validate_runtime_receipt(
    receipt: Mapping[str, Any],
    manifest: Mapping[str, Any],
    observations: Sequence[Mapping[str, Any]],
    dataset_sha256: str,
    where: str = "memory runtime receipt",
) -> None:
    schema_version = receipt.get("schema_version")
    if schema_version not in {REPLAY_SCHEMA_VERSION, *NATIVE_RUNTIME_RECEIPT_VERSIONS}:
        _fail(
            f"{where}.schema_version",
            "expected replay v1, native wiring v2, native lifecycle v3, or production v4-v9",
        )
    if schema_version in PRODUCTION_RUNTIME_RECEIPT_VERSIONS:
        _validate_production_runtime_receipt(
            receipt,
            manifest,
            observations,
            dataset_sha256,
            where,
        )
        return
    v2_fields = (
        "execution_mode",
        "quality_evidence",
        "metacodes_binary_sha256",
        "tinykg_binary_sha256",
        "external_network_calls",
        "paid_cost_usd",
        "estimated_cost_usd",
        "rollouts",
    )
    value = _object(
        receipt,
        where,
        (
            "schema_version",
            "protocol_id",
            "manifest_sha256",
            "observations_sha256",
            "dataset_sha256",
            "adapter_id",
            "adapter_revision",
            "model_id",
            "model_fingerprint",
            "harness_revision",
            *(("runner_sources",) if schema_version == RUNTIME_RECEIPT_SCHEMA_VERSION else ()),
            "arms",
            "graders",
            *(v2_fields if schema_version in NATIVE_RUNTIME_RECEIPT_VERSIONS else ()),
        ),
    )
    if value["protocol_id"] != PROTOCOL_ID:
        _fail(f"{where}.protocol_id", f"expected {PROTOCOL_ID!r}")
    expected_scalars = {
        "manifest_sha256": _canonical_sha256(manifest),
        "observations_sha256": _canonical_sha256(list(observations)),
        "dataset_sha256": dataset_sha256,
        "adapter_id": manifest["dataset"]["adapter_id"],
        "adapter_revision": manifest["dataset"]["adapter_revision"],
        "model_id": manifest["execution"]["model_id"],
        "model_fingerprint": manifest["execution"]["model_fingerprint"],
        "harness_revision": manifest["execution"]["harness_revision"],
    }
    for key, expected in expected_scalars.items():
        observed = _string(value[key], f"{where}.{key}")
        if key.endswith("sha256") or key.endswith("fingerprint"):
            _hash(observed, f"{where}.{key}")
        if observed != expected:
            _fail(f"{where}.{key}", f"expected {expected!r}, observed {observed!r}")

    expected_arms = {
        arm["id"]: arm["fingerprint"]
        for arm in manifest["execution"]["arms"]
    }
    if not isinstance(value["arms"], list):
        _fail(f"{where}.arms", "expected an array")
    observed_arms: Dict[str, str] = {}
    for index, raw_arm in enumerate(value["arms"]):
        arm_where = f"{where}.arms[{index}]"
        arm = _object(raw_arm, arm_where, ("id", "fingerprint"))
        arm_id = _identifier(arm["id"], f"{arm_where}.id")
        if arm_id in observed_arms:
            _fail(f"{arm_where}.id", "duplicate arm")
        observed_arms[arm_id] = _hash(arm["fingerprint"], f"{arm_where}.fingerprint")
    if observed_arms != expected_arms:
        _fail(f"{where}.arms", "runtime arm identities do not match the manifest")

    expected_graders = {
        case["id"]: case["grader"]["fingerprint"]
        for case in manifest["cases"]
    }
    if not isinstance(value["graders"], list):
        _fail(f"{where}.graders", "expected an array")
    observed_graders: Dict[str, str] = {}
    for index, raw_grader in enumerate(value["graders"]):
        grader_where = f"{where}.graders[{index}]"
        grader = _object(raw_grader, grader_where, ("case_id", "fingerprint"))
        case_id = _identifier(grader["case_id"], f"{grader_where}.case_id")
        if case_id in observed_graders:
            _fail(f"{grader_where}.case_id", "duplicate case")
        observed_graders[case_id] = _hash(
            grader["fingerprint"],
            f"{grader_where}.fingerprint",
        )
    if observed_graders != expected_graders:
        _fail(f"{where}.graders", "runtime grader identities do not match the manifest")

    if schema_version not in NATIVE_RUNTIME_RECEIPT_VERSIONS:
        return
    if schema_version in {
        RUNTIME_RECEIPT_SCHEMA_VERSION,
        LEGACY_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        BUDGET_JOURNAL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
    }:
        raw_sources = value["runner_sources"]
        if not isinstance(raw_sources, list):
            _fail(f"{where}.runner_sources", "expected an array")
        observed_modules: Dict[str, str] = {}
        observed_paths: set[str] = set()
        for index, raw_source in enumerate(raw_sources):
            source_where = f"{where}.runner_sources[{index}]"
            source = _object(raw_source, source_where, ("module", "path", "sha256"))
            module = _identifier(source["module"], f"{source_where}.module")
            path = _artifact_relative_path(source["path"], f"{source_where}.path").as_posix()
            digest = _hash(source["sha256"], f"{source_where}.sha256")
            if path != f"runner-sources/{module}.py":
                _fail(f"{source_where}.path", "does not match its runner module")
            if module in observed_modules:
                _fail(f"{source_where}.module", "duplicate runner module")
            if path in observed_paths:
                _fail(f"{source_where}.path", "duplicate runner source path")
            observed_modules[module] = digest
            observed_paths.add(path)
        if frozenset(observed_modules) not in {
            frozenset(LEGACY_RUNNER_SOURCE_MODULES),
            frozenset(RUNNER_SOURCE_MODULES),
        }:
            _fail(f"{where}.runner_sources", "does not bind the complete host runtime source set")
    expected_mode = (
        "native-agent-loop-scripted-wiring-smoke"
        if schema_version == LEGACY_RUNTIME_RECEIPT_SCHEMA_VERSION
        else "native-agent-loop-scripted-lifecycle-smoke"
    )
    if value["execution_mode"] != expected_mode:
        _fail(f"{where}.execution_mode", "unsupported native execution mode")
    if value["quality_evidence"] is not False:
        _fail(
            f"{where}.quality_evidence",
            "scripted native smoke must never claim memory-quality evidence",
        )
    metacodes_sha256 = _hash(
        value["metacodes_binary_sha256"],
        f"{where}.metacodes_binary_sha256",
    )
    tinykg_sha256 = _hash(
        value["tinykg_binary_sha256"],
        f"{where}.tinykg_binary_sha256",
    )
    external_network_calls = _integer(
        value["external_network_calls"],
        f"{where}.external_network_calls",
    )
    if external_network_calls != 0:
        _fail(f"{where}.external_network_calls", "scripted native smoke must be zero")
    paid_cost_usd = _finite_number(value["paid_cost_usd"], f"{where}.paid_cost_usd")
    if paid_cost_usd != 0.0:
        _fail(f"{where}.paid_cost_usd", "scripted native smoke must be zero")
    estimated_cost_usd = _finite_number(
        value["estimated_cost_usd"],
        f"{where}.estimated_cost_usd",
    )
    rollouts = value["rollouts"]
    if not isinstance(rollouts, list) or len(rollouts) != len(observations):
        _fail(f"{where}.rollouts", f"expected exactly {len(observations)} entries")
    schedule = {entry["sequence"]: entry for entry in manifest["schedule"]}
    cases_by_id = {case["id"]: case for case in manifest["cases"]}
    seen_sequences: set[int] = set()
    seen_run_ids: set[str] = set()
    for index, raw_rollout in enumerate(rollouts):
        rollout_where = f"{where}.rollouts[{index}]"
        rollout = _object(
            raw_rollout,
            rollout_where,
            (
                "sequence",
                "case_id",
                "trial",
                "arm",
                "run_id",
                "task_fingerprint",
                "metacodes_binary_sha256",
                "tinykg_binary_sha256",
                "native_events_sha256",
                "result_sha256",
                "stderr_sha256",
                "cassette_sha256",
                "transcript_sha256",
                "workspace_sha256",
                "artifact_paths",
                "store_revision_before",
                "store_revision_after",
                "raw_store_digest_before",
                "raw_store_digest_after",
                "stop_reason",
                "provider_mode",
                "provider_requests",
                "external_network_calls",
                "paid_cost_usd",
                "estimated_cost_usd",
                "observation_sha256",
                "host_elapsed_ms",
                *(
                    (
                        "memory_backend",
                        "memory_phase",
                        "memory_state_before",
                        "memory_state_after",
                        "memory_read_events",
                        "memory_write_events",
                    )
                    if schema_version == RUNTIME_RECEIPT_SCHEMA_VERSION
                    else ()
                ),
            ),
        )
        sequence = _integer(rollout["sequence"], f"{rollout_where}.sequence")
        if sequence != index or sequence in seen_sequences or sequence not in schedule:
            _fail(f"{rollout_where}.sequence", "must be unique, contiguous, and scheduled")
        seen_sequences.add(sequence)
        run_id = _string(rollout["run_id"], f"{rollout_where}.run_id")
        if run_id in seen_run_ids:
            _fail(f"{rollout_where}.run_id", "must be unique")
        seen_run_ids.add(run_id)
        scheduled = schedule[sequence]
        for key in ("case_id", "trial", "arm"):
            if rollout[key] != scheduled[key]:
                _fail(f"{rollout_where}.{key}", "does not match frozen schedule")
        case = cases_by_id[rollout["case_id"]]
        expected_task = _canonical_sha256(case)
        if _hash(rollout["task_fingerprint"], f"{rollout_where}.task_fingerprint") != expected_task:
            _fail(f"{rollout_where}.task_fingerprint", "does not bind the frozen case")
        if _hash(
            rollout["metacodes_binary_sha256"],
            f"{rollout_where}.metacodes_binary_sha256",
        ) != metacodes_sha256:
            _fail(f"{rollout_where}.metacodes_binary_sha256", "binary identity drift")
        tinykg_enabled = rollout["arm"] in {"tinykg", "tinykg_lexical"}
        observed_tinykg = rollout["tinykg_binary_sha256"]
        if tinykg_enabled:
            if _hash(observed_tinykg, f"{rollout_where}.tinykg_binary_sha256") != tinykg_sha256:
                _fail(f"{rollout_where}.tinykg_binary_sha256", "binary identity drift")
        elif observed_tinykg is not None:
            _fail(f"{rollout_where}.tinykg_binary_sha256", "control arm must use null")
        for key in (
            "native_events_sha256",
            "result_sha256",
            "stderr_sha256",
            "cassette_sha256",
            "transcript_sha256",
            "workspace_sha256",
        ):
            _hash(rollout[key], f"{rollout_where}.{key}")
        artifact_paths = _object(
            rollout["artifact_paths"],
            f"{rollout_where}.artifact_paths",
            (
                "native_events",
                "result",
                "stderr",
                "cassette",
                "transcript",
                "workspace",
                "store",
                *(('memory_state',) if schema_version == RUNTIME_RECEIPT_SCHEMA_VERSION else ()),
            ),
        )
        for key in ("native_events", "result", "stderr", "cassette", "transcript", "workspace"):
            _artifact_relative_path(
                artifact_paths[key],
                f"{rollout_where}.artifact_paths.{key}",
            )
        if tinykg_enabled:
            _artifact_relative_path(
                artifact_paths["store"],
                f"{rollout_where}.artifact_paths.store",
            )
        elif artifact_paths["store"] is not None:
            _fail(f"{rollout_where}.artifact_paths.store", "control arm must use null")
        expected_backend = (
            "tinykg"
            if tinykg_enabled
            else "markdown" if rollout["arm"] in {"markdown_memory", "claude_style"} else "none"
        )
        if schema_version == RUNTIME_RECEIPT_SCHEMA_VERSION:
            if rollout["memory_backend"] != expected_backend:
                _fail(f"{rollout_where}.memory_backend", "does not match the frozen arm")
            memory_artifact = artifact_paths["memory_state"]
            if expected_backend == "markdown":
                _artifact_relative_path(
                    memory_artifact,
                    f"{rollout_where}.artifact_paths.memory_state",
                )
            elif memory_artifact is not None:
                _fail(
                    f"{rollout_where}.artifact_paths.memory_state",
                    "only the Markdown arm has a separate memory tree",
                )
        if rollout["stop_reason"] not in {"end_turn", "max_turns", "tool_loop", "budget"}:
            _fail(f"{rollout_where}.stop_reason", "unsupported native stop reason")
        if rollout["provider_mode"] != "scripted-local":
            _fail(f"{rollout_where}.provider_mode", "must be scripted-local")
        provider_requests = _integer(
            rollout["provider_requests"],
            f"{rollout_where}.provider_requests",
            minimum=1,
        )
        rollout_external_calls = _integer(
            rollout["external_network_calls"],
            f"{rollout_where}.external_network_calls",
        )
        if rollout_external_calls != 0:
            _fail(f"{rollout_where}.external_network_calls", "must be zero")
        rollout_paid_cost = _finite_number(
            rollout["paid_cost_usd"],
            f"{rollout_where}.paid_cost_usd",
        )
        if rollout_paid_cost != 0.0:
            _fail(f"{rollout_where}.paid_cost_usd", "must be zero")
        _finite_number(
            rollout["estimated_cost_usd"],
            f"{rollout_where}.estimated_cost_usd",
        )
        _finite_number(rollout["host_elapsed_ms"], f"{rollout_where}.host_elapsed_ms")
        expected_observation = _canonical_sha256(observations[sequence])
        if _hash(
            rollout["observation_sha256"],
            f"{rollout_where}.observation_sha256",
        ) != expected_observation:
            _fail(f"{rollout_where}.observation_sha256", "does not bind observation")
        observation = observations[sequence]
        trajectory = observation.get("trajectory")
        retrieval = observation.get("retrieval")
        cost = observation.get("cost")
        if not isinstance(trajectory, dict):
            _fail(f"{rollout_where}.observation", "missing native trajectory")
        model_requests = _integer(
            trajectory.get("model_requests"),
            f"{rollout_where}.observation.trajectory.model_requests",
            minimum=1,
        )
        if model_requests != provider_requests:
            _fail(
                f"{rollout_where}.provider_requests",
                "does not match native observation trajectory",
            )
        memory_reads = (
            _integer(
                rollout["memory_read_events"],
                f"{rollout_where}.memory_read_events",
            )
            if schema_version == RUNTIME_RECEIPT_SCHEMA_VERSION
            else int(tinykg_enabled)
        )
        memory_writes = (
            _integer(
                rollout["memory_write_events"],
                f"{rollout_where}.memory_write_events",
            )
            if schema_version == RUNTIME_RECEIPT_SCHEMA_VERSION
            else 0
        )
        expected_retrieval = memory_reads > 0 if schema_version == RUNTIME_RECEIPT_SCHEMA_VERSION else tinykg_enabled
        if not isinstance(retrieval, dict) or retrieval.get("enabled") is not expected_retrieval:
            _fail(f"{rollout_where}.observation.retrieval", "arm activation mismatch")
        if expected_retrieval and not retrieval.get("query_variants"):
            _fail(
                f"{rollout_where}.observation.retrieval.query_variants",
                "native memory rollout did not execute an observable retrieval",
            )
        if not isinstance(cost, dict) or cost.get("cost_usd") != rollout["paid_cost_usd"]:
            _fail(f"{rollout_where}.paid_cost_usd", "does not match observation cost")
        before = _string(
            rollout["store_revision_before"],
            f"{rollout_where}.store_revision_before",
        )
        after = _string(
            rollout["store_revision_after"],
            f"{rollout_where}.store_revision_after",
        )
        raw_before = _string(
            rollout["raw_store_digest_before"],
            f"{rollout_where}.raw_store_digest_before",
        )
        raw_after = _string(
            rollout["raw_store_digest_after"],
            f"{rollout_where}.raw_store_digest_after",
        )
        online_memory = is_online_memory_case(case)
        if tinykg_enabled:
            _hash(before, f"{rollout_where}.store_revision_before")
            _hash(after, f"{rollout_where}.store_revision_after")
            _hash(raw_before, f"{rollout_where}.raw_store_digest_before")
            _hash(raw_after, f"{rollout_where}.raw_store_digest_after")
            if schema_version == RUNTIME_RECEIPT_SCHEMA_VERSION and online_memory:
                if memory_writes < 1 or before == after or raw_before == raw_after:
                    _fail(rollout_where, "online TinyKG phase did not change bound state")
            else:
                if before != after:
                    _fail(rollout_where, "read-only rollout changed TinyKG store revision")
                if raw_before != raw_after:
                    _fail(rollout_where, "read-only rollout changed raw TinyKG store bytes")
        elif (
            before != "none"
            or after != "none"
            or raw_before != "none"
            or raw_after != "none"
        ):
            _fail(rollout_where, "control arm must use none store digests")
        if schema_version == RUNTIME_RECEIPT_SCHEMA_VERSION:
            phase = _string(rollout["memory_phase"], f"{rollout_where}.memory_phase")
            if phase != case["split"]:
                _fail(f"{rollout_where}.memory_phase", "does not match the frozen case split")
            state_before = _string(
                rollout["memory_state_before"],
                f"{rollout_where}.memory_state_before",
            )
            state_after = _string(
                rollout["memory_state_after"],
                f"{rollout_where}.memory_state_after",
            )
            if expected_backend == "none":
                if (state_before, state_after, memory_reads, memory_writes) != ("none", "none", 0, 0):
                    _fail(rollout_where, "no-memory arm has durable-memory activity")
            else:
                _hash(state_before, f"{rollout_where}.memory_state_before")
                _hash(state_after, f"{rollout_where}.memory_state_after")
                if online_memory:
                    if memory_writes < 1 or state_before == state_after:
                        _fail(rollout_where, "online phase did not persist a new memory state")
                elif memory_writes != 0 or state_before != state_after:
                    _fail(rollout_where, "read-only phase changed durable memory state")
                if not online_memory and memory_reads < 1:
                    _fail(rollout_where, "read-only memory phase did not recall durable state")
                if expected_backend == "tinykg" and (state_before != before or state_after != after):
                    _fail(rollout_where, "TinyKG memory state does not bind its store revision")
            if expected_backend == "none":
                expected_reads, expected_writes = 0, 0
            elif expected_backend == "markdown":
                expected_reads, expected_writes = (0, 2) if online_memory else (1, 0)
            else:
                expected_reads, expected_writes = (2, 1) if online_memory else (2, 0)
            if (memory_reads, memory_writes) != (expected_reads, expected_writes):
                _fail(
                    rollout_where,
                    "memory event counts do not match the fixed lifecycle protocol",
                )
            tool_calls = _integer(
                trajectory.get("tool_calls"),
                f"{rollout_where}.observation.trajectory.tool_calls",
            )
            tool_errors = _integer(
                trajectory.get("tool_errors"),
                f"{rollout_where}.observation.trajectory.tool_errors",
            )
            if tool_calls != memory_reads + memory_writes:
                _fail(
                    f"{rollout_where}.observation.trajectory.tool_calls",
                    "scripted lifecycle reached an undeclared tool",
                )
            if tool_errors != 0:
                _fail(
                    f"{rollout_where}.observation.trajectory.tool_errors",
                    "scripted lifecycle contains a tool failure",
                )
            memory = observation.get("memory")
            graph = observation.get("graph")
            governance = observation.get("governance")
            if not isinstance(memory, dict) or not isinstance(graph, dict) or not isinstance(governance, dict):
                _fail(f"{rollout_where}.observation", "missing memory lifecycle fields")
            expected_write_mode = (
                "disabled"
                if expected_backend == "none"
                else "online"
                if online_memory
                else "read_only"
            )
            if memory.get("write_mode") != expected_write_mode:
                _fail(f"{rollout_where}.observation.memory.write_mode", "lifecycle mismatch")
            expected_inserts = 1 if online_memory and expected_backend != "none" else 0
            if memory.get("inserted_nodes") != expected_inserts:
                _fail(
                    f"{rollout_where}.observation.memory.inserted_nodes",
                    "does not match lifecycle inserts",
                )
            if graph.get("revision") != state_after:
                _fail(f"{rollout_where}.observation.graph.revision", "does not bind post-state")
            if not online_memory and governance.get("offline_write_events") != 0:
                _fail(f"{rollout_where}.observation.governance", "offline write leakage")
    estimated_total = sum(float(item["estimated_cost_usd"]) for item in rollouts)
    if not math.isfinite(estimated_total) or abs(estimated_cost_usd - estimated_total) > 1e-12:
        _fail(f"{where}.estimated_cost_usd", "does not equal rollout total")


def validate_runtime_artifacts(
    receipt: Mapping[str, Any],
    artifact_root: Path,
    where: str = "memory runtime artifacts",
    *,
    _query_plan_reanalysis: object | None = None,
) -> None:
    """Re-open every native artifact instead of trusting receipt-shaped hashes."""

    schema_version = receipt.get("schema_version")
    if schema_version not in NATIVE_RUNTIME_RECEIPT_VERSIONS:
        return
    if (
        _query_plan_reanalysis is not None
        and _query_plan_reanalysis is not _FAILED_RUN_QUERY_PLAN_REANALYSIS
    ):
        _fail(where, "unknown query-plan artifact policy")
    recompute_query_plans = (
        _query_plan_reanalysis is _FAILED_RUN_QUERY_PLAN_REANALYSIS
    )
    seen_paths: set[str] = set()
    query_plan_bound = _query_plan_source_bound(receipt, where)
    if recompute_query_plans and not query_plan_bound:
        _fail(
            f"{where}.runner_sources",
            "failed-run query-plan reanalysis requires a source-bound runtime",
        )
    checkpoint_transactions: Mapping[str, Mapping[str, Any]] | None = None
    if schema_version in {
        RUNTIME_RECEIPT_SCHEMA_VERSION,
        LEGACY_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        BUDGET_JOURNAL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
    }:
        raw_sources = receipt.get("runner_sources")
        if not isinstance(raw_sources, list):
            _fail(f"{where}.runner_sources", "expected an array")
        for index, raw_source in enumerate(raw_sources):
            source_where = f"{where}.runner_sources[{index}]"
            if not isinstance(raw_source, dict):
                _fail(source_where, "expected an object")
            relative = _artifact_relative_path(
                raw_source.get("path"),
                f"{source_where}.path",
            ).as_posix()
            if relative in seen_paths:
                _fail(f"{source_where}.path", "reuses another runtime artifact")
            seen_paths.add(relative)
            runner = _artifact_path(
                artifact_root,
                relative,
                f"{source_where}.path",
                directory=False,
            )
            try:
                observed_runner_sha = file_sha256(runner)
            except OSError as exc:
                raise ValidationError(f"{source_where}.sha256: cannot hash artifact: {exc}") from exc
            expected_runner_sha = _hash(raw_source.get("sha256"), f"{source_where}.sha256")
            if observed_runner_sha != expected_runner_sha:
                _fail(f"{source_where}.sha256", "runtime source mismatch")
    if schema_version in {
        PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
    }:
        snapshot_relative = _artifact_relative_path(
            receipt.get("ripgrep_snapshot_path"),
            f"{where}.ripgrep_snapshot_path",
        ).as_posix()
        if snapshot_relative != PRODUCTION_RIPGREP_SNAPSHOT_PATH:
            _fail(
                f"{where}.ripgrep_snapshot_path",
                "does not name the canonical host snapshot",
            )
        if snapshot_relative in seen_paths:
            _fail(f"{where}.ripgrep_snapshot_path", "reuses another runtime artifact")
        seen_paths.add(snapshot_relative)
        snapshot = _artifact_path(
            artifact_root,
            snapshot_relative,
            f"{where}.ripgrep_snapshot_path",
            directory=False,
        )
        snapshot_info = snapshot.lstat()
        if POSIX_MODE_BITS and stat.S_IMODE(snapshot_info.st_mode) != 0o500:
            _fail(
                f"{where}.ripgrep_snapshot_path",
                "snapshot permissions must remain 0500",
            )
        if file_sha256(snapshot) != receipt.get("ripgrep_binary_sha256"):
            _fail(f"{where}.ripgrep_snapshot_path", "snapshot identity drift")
    if schema_version in {
        BUDGET_JOURNAL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
    }:
        journal_receipt = receipt.get("budget_journal")
        if not isinstance(journal_receipt, dict):
            _fail(f"{where}.budget_journal", "expected an object")
        checkpoint_relative = _artifact_relative_path(
            journal_receipt.get("checkpoint_path"),
            f"{where}.budget_journal.checkpoint_path",
        ).as_posix()
        if checkpoint_relative in seen_paths:
            _fail(f"{where}.budget_journal.checkpoint_path", "reuses another artifact")
        seen_paths.add(checkpoint_relative)
        checkpoint = _artifact_path(
            artifact_root,
            checkpoint_relative,
            f"{where}.budget_journal.checkpoint_path",
            directory=False,
        )
        checkpoint_payload = checkpoint.read_bytes()
        if hashlib.sha256(checkpoint_payload).hexdigest() != journal_receipt.get(
            "checkpoint_sha256"
        ):
            _fail(f"{where}.budget_journal.checkpoint_sha256", "checkpoint bytes drifted")
        checkpoint_state = validate_checkpoint_payload(checkpoint_payload)
        checkpoint_transactions = checkpoint_state["transactions"]
        for receipt_key, checkpoint_key in (
            ("journal_id", "journal_id"),
            ("authority", "authority"),
            ("revision", "revision"),
            ("head_sha256", "head_sha256"),
        ):
            if journal_receipt.get(receipt_key) != checkpoint_state[checkpoint_key]:
                _fail(f"{where}.budget_journal.{receipt_key}", "checkpoint state drift")
        states: Dict[str, int] = {}
        committed_cost = 0
        committed_tokens = 0
        unsettled_cost = 0
        unsettled_tokens = 0
        for transaction in checkpoint_state["transactions"].values():
            state = str(transaction["state"])
            states[state] = states.get(state, 0) + 1
            if state == "committed":
                committed_cost += int(transaction["actual_cost_microusd"])
                committed_tokens += int(transaction["actual_metered_tokens"])
            elif state in {"reserved", "request_authorized"}:
                unsettled_cost += int(transaction["identity"]["max_cost_microusd"])
                unsettled_tokens += int(transaction["identity"]["max_metered_tokens"])
        expected_summary = {
            "committed_cost_microusd": committed_cost,
            "committed_metered_tokens": committed_tokens,
            "unsettled_max_cost_microusd": unsettled_cost,
            "unsettled_max_metered_tokens": unsettled_tokens,
            "exposure_cost_microusd": committed_cost + unsettled_cost,
            "exposure_metered_tokens": committed_tokens + unsettled_tokens,
            "transaction_states": states,
        }
        for key, expected in expected_summary.items():
            if journal_receipt.get(key) != expected:
                _fail(f"{where}.budget_journal.{key}", "checkpoint summary drift")
    rollouts = receipt.get("rollouts")
    if not isinstance(rollouts, list):
        _fail(where, "receipt rollouts are unavailable")
    file_specs = (
        ("native_events", "native_events_sha256"),
        ("result", "result_sha256"),
        ("stderr", "stderr_sha256"),
    )
    tree_specs = (
        ("cassette", "cassette_sha256"),
        ("transcript", "transcript_sha256"),
        ("workspace", "workspace_sha256"),
    )
    for index, raw_rollout in enumerate(rollouts):
        rollout_where = f"{where}.rollouts[{index}]"
        native_scoped_recalls: List[Mapping[str, Any]] | None = None
        observed_context_cache: Dict[str, Any] | None = (
            {} if schema_version == PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION else None
        )
        if not isinstance(raw_rollout, dict):
            _fail(rollout_where, "expected an object")
        if schema_version in {
            BUDGET_JOURNAL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
            PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
            PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
            PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
            PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
        }:
            assert checkpoint_transactions is not None
            transaction_receipt = raw_rollout.get("budget_transaction")
            if not isinstance(transaction_receipt, dict):
                _fail(f"{rollout_where}.budget_transaction", "expected an object")
            transaction_id = transaction_receipt.get("transaction_id")
            transaction = checkpoint_transactions.get(transaction_id)
            if transaction is None:
                _fail(
                    f"{rollout_where}.budget_transaction.transaction_id",
                    "is absent from the checkpoint",
                )
            identity = transaction["identity"]
            expected_transaction_receipt = {
                "transaction_id": transaction_id,
                "state": transaction["state"],
                "identity_sha256": transaction["identity_sha256"],
                "run_id": identity["run_id"],
                "manifest_sha256": identity["manifest_sha256"],
                "model_fingerprint": identity["model_fingerprint"],
                "harness_fingerprint": identity["harness_fingerprint"],
                "provider_identity": identity["provider_identity"],
                "max_cost_microusd": identity["max_cost_microusd"],
                "max_metered_tokens": identity["max_metered_tokens"],
                "reservation_revision": transaction["reservation_revision"],
                "reservation_head_sha256": transaction["reservation_head_sha256"],
                "authorization_revision": transaction["authorization_revision"],
                "authorization_head_sha256": transaction["authorization_head_sha256"],
                "commit_revision": transaction["commit_revision"],
                "commit_head_sha256": transaction["commit_head_sha256"],
                "actual_cost_microusd": transaction["actual_cost_microusd"],
                "actual_metered_tokens": transaction["actual_metered_tokens"],
            }
            for key, expected in expected_transaction_receipt.items():
                if transaction_receipt.get(key) != expected:
                    _fail(
                        f"{rollout_where}.budget_transaction.{key}",
                        "does not match the hash-chained checkpoint",
                    )
            sandbox = raw_rollout.get("sandbox")
            if not isinstance(sandbox, dict):
                _fail(f"{rollout_where}.sandbox", "expected an object")
            if sandbox.get("backend") != PRODUCTION_SANDBOX_BACKEND:
                _fail(f"{rollout_where}.sandbox.backend", "sandbox backend drift")
            sandbox_paths: Dict[str, Path] = {}
            for path_key, digest_key in (
                ("profile_path", "profile_sha256"),
                ("probe_path", "probe_sha256"),
            ):
                relative = _artifact_relative_path(
                    sandbox.get(path_key),
                    f"{rollout_where}.sandbox.{path_key}",
                ).as_posix()
                if relative in seen_paths:
                    _fail(
                        f"{rollout_where}.sandbox.{path_key}",
                        "reuses another runtime artifact",
                    )
                seen_paths.add(relative)
                path = _artifact_path(
                    artifact_root,
                    relative,
                    f"{rollout_where}.sandbox.{path_key}",
                    directory=False,
                )
                sandbox_paths[path_key] = path
                try:
                    observed = file_sha256(path)
                except OSError as exc:
                    raise ValidationError(
                        f"{rollout_where}.sandbox.{digest_key}: cannot hash artifact: {exc}"
                    ) from exc
                expected = _hash(
                    sandbox.get(digest_key),
                    f"{rollout_where}.sandbox.{digest_key}",
                )
                if observed != expected:
                    _fail(
                        f"{rollout_where}.sandbox.{digest_key}",
                        "sandbox artifact SHA-256 mismatch",
                    )
            environment = raw_rollout.get("environment")
            if not isinstance(environment, dict):
                _fail(f"{rollout_where}.environment", "expected an object")
            if environment.get("sandbox_backend") != sandbox.get("backend"):
                _fail(
                    f"{rollout_where}.environment.sandbox_backend",
                    "does not bind the sandbox receipt",
                )
            if environment.get("sandbox_profile_sha256") != sandbox.get(
                "profile_sha256"
            ):
                _fail(
                    f"{rollout_where}.environment.sandbox_profile_sha256",
                    "does not bind the sandbox receipt",
                )
            raw_evidence = _load_unique_json(
                sandbox_paths["probe_path"],
                f"{rollout_where}.sandbox.probe",
            )
            if not isinstance(raw_evidence, dict):
                _fail(f"{rollout_where}.sandbox.probe", "expected an object")
            probe_schema_version = raw_evidence.get("schema_version")
            legacy_probe = probe_schema_version == LEGACY_PRODUCTION_SANDBOX_PROBE_SCHEMA_VERSION
            read_only_probe = probe_schema_version in {
                READ_ONLY_PRODUCTION_SANDBOX_PROBE_SCHEMA_VERSION,
                PRODUCTION_SANDBOX_PROBE_SCHEMA_VERSION,
            }
            tinykg_probe = probe_schema_version == PRODUCTION_SANDBOX_PROBE_SCHEMA_VERSION
            if not legacy_probe and not read_only_probe:
                _fail(f"{rollout_where}.sandbox.probe.schema_version", "unsupported probe")
            evidence_fields = (
                "schema_version",
                "backend",
                "profile_sha256",
                "host_path_sha256",
                "host_content_sha256",
                "sibling_path_sha256",
                "sibling_content_sha256",
                "host_read_denied",
                "sibling_read_denied",
                "process_info_denied",
                "workspace_read_write_allowed",
            )
            if read_only_probe:
                evidence_fields += (
                    "read_only_roots_enforced",
                    "read_only_root_count",
                    "read_only_roots_sha256",
                )
            if tinykg_probe:
                evidence_fields += (
                    "tinykg_read_probe_performed",
                    "tinykg_store_info_sha256",
                    "tinykg_recall_sha256",
                    "tinykg_lock_path_clean",
                    "tinykg_store_unchanged",
                )
            evidence = _object(
                raw_evidence,
                f"{rollout_where}.sandbox.probe",
                evidence_fields,
            )
            if evidence["backend"] != PRODUCTION_SANDBOX_BACKEND:
                _fail(f"{rollout_where}.sandbox.probe.backend", "sandbox backend drift")
            if evidence["profile_sha256"] != sandbox.get("profile_sha256"):
                _fail(
                    f"{rollout_where}.sandbox.probe.profile_sha256",
                    "does not bind the sandbox profile",
                )
            for digest_key in (
                "host_path_sha256",
                "host_content_sha256",
                "sibling_path_sha256",
                "sibling_content_sha256",
            ):
                _hash(evidence[digest_key], f"{rollout_where}.sandbox.probe.{digest_key}")
            for claim in (
                "host_read_denied",
                "sibling_read_denied",
                "process_info_denied",
                "workspace_read_write_allowed",
            ):
                if evidence[claim] is not True:
                    _fail(f"{rollout_where}.sandbox.probe.{claim}", "probe did not pass")
            if read_only_probe:
                if evidence["read_only_roots_enforced"] is not True:
                    _fail(
                        f"{rollout_where}.sandbox.probe.read_only_roots_enforced",
                        "probe did not pass",
                    )
                read_only_root_count = _integer(
                    evidence["read_only_root_count"],
                    f"{rollout_where}.sandbox.probe.read_only_root_count",
                )
                _hash(
                    evidence["read_only_roots_sha256"],
                    f"{rollout_where}.sandbox.probe.read_only_roots_sha256",
                )
                expected_read_only_roots = 0
                if raw_rollout.get("memory_phase") != "online":
                    memory_backend = raw_rollout.get("memory_backend")
                    expected_read_only_roots = (
                        2
                        if memory_backend == "tinykg_integrated"
                        else 1
                        if memory_backend == "markdown"
                        else 0
                    )
                if read_only_root_count != expected_read_only_roots:
                    _fail(
                        f"{rollout_where}.sandbox.probe.read_only_root_count",
                        f"expected {expected_read_only_roots}",
                    )
            if tinykg_probe:
                expected_tinykg_probe = (
                    raw_rollout.get("memory_phase") != "online"
                    and raw_rollout.get("memory_backend") == "tinykg_integrated"
                )
                if evidence["tinykg_read_probe_performed"] is not expected_tinykg_probe:
                    _fail(
                        f"{rollout_where}.sandbox.probe.tinykg_read_probe_performed",
                        f"expected {expected_tinykg_probe}",
                    )
                if expected_tinykg_probe:
                    for digest_key in (
                        "tinykg_store_info_sha256",
                        "tinykg_recall_sha256",
                    ):
                        _hash(
                            evidence[digest_key],
                            f"{rollout_where}.sandbox.probe.{digest_key}",
                        )
                    for claim in ("tinykg_lock_path_clean", "tinykg_store_unchanged"):
                        if evidence[claim] is not True:
                            _fail(
                                f"{rollout_where}.sandbox.probe.{claim}",
                                "probe did not pass",
                            )
                elif any(
                    evidence[key] is not None
                    for key in (
                        "tinykg_store_info_sha256",
                        "tinykg_recall_sha256",
                        "tinykg_lock_path_clean",
                        "tinykg_store_unchanged",
                    )
                ):
                    _fail(
                        f"{rollout_where}.sandbox.probe",
                        "non-TinyKG rollout carries TinyKG read-probe claims",
                    )
        paths = raw_rollout.get("artifact_paths")
        if not isinstance(paths, dict):
            _fail(f"{rollout_where}.artifact_paths", "expected an object")
        memory_root: Path | None = None
        if (
            schema_version
            in {
                RUNTIME_RECEIPT_SCHEMA_VERSION,
                LEGACY_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                BUDGET_JOURNAL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
            }
            and paths.get("memory_state") is not None
        ):
            memory_root = _artifact_path(
                artifact_root,
                paths.get("memory_state"),
                f"{rollout_where}.artifact_paths.memory_state",
                directory=True,
            )
        for path_key, digest_key in file_specs:
            raw_path = paths.get(path_key)
            relative = _artifact_relative_path(
                raw_path,
                f"{rollout_where}.artifact_paths.{path_key}",
            ).as_posix()
            if relative in seen_paths:
                _fail(f"{rollout_where}.artifact_paths.{path_key}", "reuses another rollout artifact")
            seen_paths.add(relative)
            path = _artifact_path(
                artifact_root,
                relative,
                f"{rollout_where}.artifact_paths.{path_key}",
                directory=False,
            )
            try:
                observed = file_sha256(path)
            except OSError as exc:
                raise ValidationError(f"{rollout_where}.{digest_key}: cannot hash artifact: {exc}") from exc
            expected = _hash(raw_rollout.get(digest_key), f"{rollout_where}.{digest_key}")
            if observed != expected:
                _fail(f"{rollout_where}.{digest_key}", "raw artifact SHA-256 mismatch")
            if (
                path_key == "native_events"
                and schema_version in PRODUCTION_RUNTIME_RECEIPT_VERSIONS
            ):
                from .e2e_adapter import _native_trace_metrics

                native, native_error = _native_trace_metrics(path)
                if native_error is not None or native is None:
                    _fail(f"{rollout_where}.native_events", native_error or "invalid events")
                if (
                    not native.get("complete")
                    or native.get("starts") != 1
                    or native.get("finishes") != 1
                    or native.get("dropped_events_total") != 0
                ):
                    _fail(f"{rollout_where}.native_events", "production lifecycle is incomplete")
                metadata = native.get("metadata")
                if not isinstance(metadata, dict):
                    _fail(f"{rollout_where}.native_events", "run metadata is unavailable")
                grader_fingerprints = {
                    item["case_id"]: item["fingerprint"] for item in receipt["graders"]
                }
                expected_metadata = {
                    "run_id": raw_rollout.get("run_id"),
                    "trial": raw_rollout.get("trial"),
                    "task_id": raw_rollout.get("case_id"),
                    "task_fingerprint": raw_rollout.get("task_fingerprint"),
                    "task_fingerprint_provenance": "recorded_at_execution",
                    "model_provider": PRODUCTION_MODEL_PROVIDER,
                    "model_id": PRODUCTION_MODEL_ID,
                    "model_fingerprint": receipt.get("model_fingerprint"),
                    "runtime_model_provider": PRODUCTION_MODEL_PROVIDER,
                    "runtime_model_id": PRODUCTION_MODEL_ID,
                    "harness_revision": receipt.get("harness_revision"),
                    "harness_fingerprint": raw_rollout.get("harness_fingerprint"),
                    "environment_fingerprint": raw_rollout.get("environment_fingerprint"),
                    "grader_fingerprint": grader_fingerprints.get(raw_rollout.get("case_id")),
                    "permission_mode": "bypass_permissions",
                    "runtime_permission_mode": "bypass_permissions",
                    "max_metered_tokens": receipt["budget"]["max_rollout_metered_tokens"],
                    "max_cost_usd": receipt["budget"]["max_rollout_cost_usd"],
                }
                for key, expected in expected_metadata.items():
                    if metadata.get(key) != expected:
                        _fail(
                            f"{rollout_where}.native_events.metadata.{key}",
                            "does not match the production receipt",
                        )
                metrics = native["metrics"]
                raw_native_scoped = native.get("scoped_recalls")
                if not isinstance(raw_native_scoped, list) or any(
                    not isinstance(item, dict) for item in raw_native_scoped
                ):
                    _fail(
                        f"{rollout_where}.native_events",
                        "scoped recall evidence is malformed",
                    )
                native_scoped_recalls = raw_native_scoped
                metered_tokens = sum(
                    int(metrics[key])
                    for key in (
                        "input_tokens",
                        "output_tokens",
                        "cache_read_tokens",
                        "cache_write_tokens",
                    )
                )
                if metered_tokens != raw_rollout.get("metered_tokens"):
                    _fail(f"{rollout_where}.metered_tokens", "native event total mismatch")
                if metrics.get("model_request_count") != raw_rollout.get("provider_requests"):
                    _fail(f"{rollout_where}.provider_requests", "native event total mismatch")
                if metrics.get("compact_request_count") != raw_rollout.get("compact_event_count"):
                    _fail(
                        f"{rollout_where}.compact_event_count",
                        "native event total mismatch",
                    )
                observed_cost = float(metrics.get("cost_usd", -1.0))
                expected_cost = raw_rollout.get("estimated_cost_usd")
                if (
                    not isinstance(expected_cost, (int, float))
                    or isinstance(expected_cost, bool)
                    or abs(observed_cost - float(expected_cost)) > 1e-12
                ):
                    _fail(f"{rollout_where}.estimated_cost_usd", "native event total mismatch")
                if _native_pricing_provenance(path, f"{rollout_where}.native_events") != raw_rollout.get(
                    "pricing_provenance"
                ):
                    _fail(f"{rollout_where}.pricing_provenance", "native event provenance mismatch")
                if observed_context_cache is not None:
                    observed_context_cache.update(
                        {
                            "input_tokens": int(metrics["input_tokens"]),
                            "output_tokens": int(metrics["output_tokens"]),
                            "cache_read_tokens": int(metrics["cache_read_tokens"]),
                            "cache_write_tokens": int(metrics["cache_write_tokens"]),
                            "cache_break_count": int(metrics["cache_break_count"]),
                            "compact_request_count": int(metrics["compact_request_count"]),
                            "auto_compact_event_count": int(
                                metrics["auto_compact_event_count"]
                            ),
                            "context_projection_count": int(
                                metrics["context_projection_count"]
                            ),
                            "context_projected_bytes": int(
                                metrics["context_projected_bytes"]
                            ),
                        }
                    )
        for path_key, digest_key in tree_specs:
            raw_path = paths.get(path_key)
            relative = _artifact_relative_path(
                raw_path,
                f"{rollout_where}.artifact_paths.{path_key}",
            ).as_posix()
            if relative in seen_paths:
                _fail(f"{rollout_where}.artifact_paths.{path_key}", "reuses another rollout artifact")
            seen_paths.add(relative)
            path = _artifact_path(
                artifact_root,
                relative,
                f"{rollout_where}.artifact_paths.{path_key}",
                directory=True,
            )
            observed = _artifact_tree_digest(path, f"{rollout_where}.artifact_paths.{path_key}")
            expected = _hash(raw_rollout.get(digest_key), f"{rollout_where}.{digest_key}")
            if observed != expected:
                _fail(f"{rollout_where}.{digest_key}", "raw artifact tree mismatch")
            if (
                path_key == "transcript"
                and schema_version
                in {
                    PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                    PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                    PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                    PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                }
            ):
                ripgrep = path / ".metacodes" / "toolchain" / "rg"
                try:
                    info = ripgrep.lstat()
                except OSError as exc:
                    raise ValidationError(
                        f"{rollout_where}.ripgrep_binary_sha256: cannot stat artifact: {exc}"
                    ) from exc
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not info.st_mode & 0o111:
                    _fail(
                        f"{rollout_where}.ripgrep_binary_sha256",
                        "expected a private executable regular artifact",
                    )
                if file_sha256(ripgrep) != receipt["ripgrep_binary_sha256"]:
                    _fail(
                        f"{rollout_where}.ripgrep_binary_sha256",
                        "sealed ripgrep artifact identity drift",
                    )
            if path_key == "cassette" and schema_version in {
                RUNTIME_RECEIPT_SCHEMA_VERSION,
                LEGACY_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                BUDGET_JOURNAL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
            }:
                activity = _cassette_memory_activity(
                    path,
                    f"{rollout_where}.artifact_paths.cassette",
                    memory_root=memory_root,
                )
                if schema_version in {
                    PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                    PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                    PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                    PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                }:
                    _validate_production_provider_tool_schema(
                        path,
                        f"{rollout_where}.artifact_paths.cassette",
                        receipt["allowed_provider_tools"],
                    )
                if observed_context_cache is not None:
                    observed_context_cache.update(
                        _cassette_context_cache(
                            path,
                            PRODUCTION_MODEL_ID,
                            f"{rollout_where}.context_cache",
                        )
                    )
                if activity["provider_requests"] != raw_rollout.get("provider_requests"):
                    _fail(f"{rollout_where}.provider_requests", "raw cassette count mismatch")
                if (
                    schema_version in PRODUCTION_RUNTIME_RECEIPT_VERSIONS
                    and activity["uncontained_forbidden_provider_tool_attempts"] != 0
                ):
                    _fail(
                        f"{rollout_where}.artifact_paths.cassette",
                        "forbidden provider tool was not safely denied",
                    )
                if schema_version in {
                    PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                    PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                    PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                }:
                    if native_scoped_recalls is None:
                        _fail(
                            f"{rollout_where}.native_events",
                            "scoped recall evidence was not re-observed",
                        )
                    if len(native_scoped_recalls) == 0:
                        observed_scoped: Mapping[str, Any] | None = None
                    elif len(native_scoped_recalls) == 1:
                        observed_scoped = native_scoped_recalls[0]
                    else:
                        _fail(
                            f"{rollout_where}.native_events",
                            "multiple scoped recall receipts in one invocation",
                        )
                    if observed_scoped != raw_rollout.get("scoped_recall"):
                        _fail(
                            f"{rollout_where}.scoped_recall",
                            "does not match the native event",
                        )
                    injections = _cassette_scoped_recall_injections(
                        path,
                        f"{rollout_where}.artifact_paths.cassette.scoped_recall",
                    )
                    if observed_scoped is None:
                        if injections:
                            _fail(
                                f"{rollout_where}.scoped_recall",
                                "provider block exists without native receipt",
                            )
                    elif observed_scoped.get("status") == "injected":
                        if len(injections) != 1:
                            _fail(
                                f"{rollout_where}.scoped_recall",
                                "injected receipt requires one provider block",
                            )
                        payload = injections[0]
                        if (
                            observed_scoped.get("injected_bytes") != len(payload)
                            or observed_scoped.get("injection_sha256")
                            != hashlib.sha256(payload).hexdigest()
                        ):
                            _fail(
                                f"{rollout_where}.scoped_recall",
                                "provider block differs from native commitment",
                            )
                    elif injections:
                        _fail(
                            f"{rollout_where}.scoped_recall",
                            "non-injected receipt has a provider block",
                        )
                backend = raw_rollout.get("memory_backend")
                if backend == "tinykg":
                    expected_reads = activity["tinykg_reads"]
                    expected_writes = activity["tinykg_writes"]
                    foreign_activity = activity["markdown_reads"] + activity["markdown_writes"]
                elif backend == "markdown":
                    expected_reads = activity["markdown_reads"]
                    expected_writes = activity["markdown_writes"]
                    foreign_activity = activity["tinykg_reads"] + activity["tinykg_writes"]
                elif backend == "tinykg_integrated":
                    expected_reads = activity["tinykg_reads"] + activity["markdown_reads"]
                    expected_writes = activity["tinykg_writes"] + activity["markdown_writes"]
                    foreign_activity = 0
                else:
                    expected_reads = 0
                    expected_writes = 0
                    foreign_activity = sum(
                        activity[key]
                        for key in (
                            "tinykg_reads",
                            "tinykg_writes",
                            "markdown_reads",
                            "markdown_writes",
                        )
                    )
                if foreign_activity != 0:
                    _fail(f"{rollout_where}.memory_backend", "raw cassette used another memory backend")
                if expected_reads != raw_rollout.get("memory_read_events"):
                    _fail(f"{rollout_where}.memory_read_events", "raw cassette count mismatch")
                if expected_writes != raw_rollout.get("memory_write_events"):
                    _fail(f"{rollout_where}.memory_write_events", "raw cassette count mismatch")
                if recompute_query_plans:
                    # Failed-run reanalysis is allowed to reinterpret a
                    # source-bound legacy sidecar only from the immutable raw
                    # request cassette. The cassette tree digest above still
                    # binds the historical bytes; canonical replay keeps the
                    # strict sidecar equality path below.
                    build_query_plan_trace(
                        path,
                        run_id=str(raw_rollout.get("run_id")),
                        arm=str(raw_rollout.get("arm")),
                        memory_backend=str(raw_rollout.get("memory_backend")),
                        where=f"{rollout_where}.query_plan.recomputed",
                    )
                else:
                    load_and_verify_query_plan_sidecar(
                        path,
                        run_id=str(raw_rollout.get("run_id")),
                        arm=str(raw_rollout.get("arm")),
                        memory_backend=str(raw_rollout.get("memory_backend")),
                        required=query_plan_bound,
                        where=f"{rollout_where}.query_plan",
                    )
                if schema_version in PRODUCTION_RUNTIME_RECEIPT_VERSIONS:
                    runtime_arm = _production_runtime_arm(str(raw_rollout.get("arm")))
                    activation = _cassette_treatment_activation(
                        path,
                        runtime_arm,
                        PRODUCTION_MODEL_ID,
                        f"{rollout_where}.treatment_activation",
                    )
                    if activation != raw_rollout.get("treatment_activation"):
                        _fail(
                            f"{rollout_where}.treatment_activation",
                            "raw provider request does not match receipt",
                        )
                    expected_index = b""
                    if memory_root is not None and raw_rollout.get("memory_phase") != "online":
                        index_path = memory_root / "MEMORY.md"
                        if index_path.is_file():
                            try:
                                expected_index = index_path.read_bytes()
                            except OSError as exc:
                                raise ValidationError(
                                    f"{rollout_where}.artifact_paths.memory_state: "
                                    f"cannot read MEMORY.md: {exc}"
                                ) from exc
                    exposure = _cassette_memory_exposure(
                        path,
                        f"{rollout_where}.memory_exposure",
                        memory_root=memory_root,
                        expected_memory_index=expected_index,
                        count_graph_context=raw_rollout.get("memory_backend") == "tinykg_integrated",
                    )
                    if exposure["auto_injected_bytes"] != raw_rollout.get(
                        "memory_auto_injected_bytes"
                    ):
                        _fail(
                            f"{rollout_where}.memory_auto_injected_bytes",
                            "raw cassette count mismatch",
                        )
                    if exposure["tool_result_bytes"] != raw_rollout.get(
                        "memory_tool_result_bytes"
                    ):
                        _fail(
                            f"{rollout_where}.memory_tool_result_bytes",
                            "raw cassette count mismatch",
                        )
                    if observed_context_cache is not None:
                        exposed_bytes = int(exposure["auto_injected_bytes"]) + int(
                            exposure["tool_result_bytes"]
                        )
                        observed_context_cache["memory_exposed_tokens"] = (
                            exposed_bytes + 3
                        ) // 4
                        observed_context_cache["original_context_preserved"] = (
                            observed_context_cache["auto_compact_event_count"] == 0
                            and observed_context_cache["context_projection_count"] == 0
                        )
        if observed_context_cache is not None:
            if observed_context_cache != raw_rollout.get("context_cache"):
                _fail(
                    f"{rollout_where}.context_cache",
                    "does not match independently re-observed native events and cassette",
                )
        store_path = paths.get("store")
        tinykg_enabled = raw_rollout.get("tinykg_binary_sha256") is not None
        if tinykg_enabled:
            relative = _artifact_relative_path(
                store_path,
                f"{rollout_where}.artifact_paths.store",
            ).as_posix()
            path = _artifact_path(
                artifact_root,
                relative,
                f"{rollout_where}.artifact_paths.store",
                directory=True,
            )
            observed = _artifact_tree_digest(
                path,
                f"{rollout_where}.artifact_paths.store",
                ignore_lock_files=True,
            )
            expected = _hash(
                raw_rollout.get("raw_store_digest_after"),
                f"{rollout_where}.raw_store_digest_after",
            )
            if observed != expected:
                _fail(
                    f"{rollout_where}.raw_store_digest_after",
                    "current store tree no longer matches the lifecycle receipt",
                )
        elif store_path is not None:
            _fail(f"{rollout_where}.artifact_paths.store", "control arm must use null")
        if schema_version == RUNTIME_RECEIPT_SCHEMA_VERSION:
            memory_path = paths.get("memory_state")
            if raw_rollout.get("memory_backend") == "markdown":
                relative = _artifact_relative_path(
                    memory_path,
                    f"{rollout_where}.artifact_paths.memory_state",
                ).as_posix()
                path = _artifact_path(
                    artifact_root,
                    relative,
                    f"{rollout_where}.artifact_paths.memory_state",
                    directory=True,
                )
                observed = _artifact_tree_digest(
                    path,
                    f"{rollout_where}.artifact_paths.memory_state",
                )
                expected = _hash(
                    raw_rollout.get("memory_state_after"),
                    f"{rollout_where}.memory_state_after",
                )
                if observed != expected:
                    _fail(
                        f"{rollout_where}.memory_state_after",
                        "current Markdown tree no longer matches the lifecycle receipt",
                    )
            elif memory_path is not None:
                _fail(
                    f"{rollout_where}.artifact_paths.memory_state",
                    "only Markdown rollouts have a separate memory tree",
                )
        elif schema_version in PRODUCTION_RUNTIME_RECEIPT_VERSIONS:
            memory_path = paths.get("memory_state")
            backend = raw_rollout.get("memory_backend")
            if backend == "none":
                if memory_path is not None:
                    _fail(
                        f"{rollout_where}.artifact_paths.memory_state",
                        "no-memory rollout must use null",
                    )
            else:
                assert memory_root is not None
                observed_markdown = _artifact_tree_digest(
                    memory_root,
                    f"{rollout_where}.artifact_paths.memory_state",
                )
                components = raw_rollout.get("memory_components_after")
                if not isinstance(components, dict) or observed_markdown != components.get("markdown"):
                    _fail(
                        f"{rollout_where}.memory_components_after.markdown",
                        "current Markdown tree no longer matches the production receipt",
                    )
            if schema_version in {
                PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                PRE_CONTEXT_CACHE_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
            }:
                consolidation_required = bool(
                    raw_rollout.get("memory_phase") == "online" and backend != "none"
                )
                if consolidation_required:
                    if memory_root is None:
                        _fail(
                            f"{rollout_where}.artifact_paths.memory_state",
                            "online consolidation has no durable memory tree",
                        )
                    _validate_consolidation_artifacts(
                        raw_rollout,
                        memory_root,
                        rollout_where,
                    )
                elif raw_rollout.get("consolidation") is not None:
                    _fail(
                        f"{rollout_where}.consolidation",
                        "only online memory arms may consolidate",
                    )

    if schema_version == PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION:
        observed_summary = _summarize_context_cache(rollouts)
        if receipt.get("context_cache_summary") != observed_summary:
            _fail(
                f"{where}.context_cache_summary",
                "does not match independently re-observed rollout context/cache evidence",
            )
        if receipt.get("unconditional_memory_claim_eligible") is not False:
            _fail(
                f"{where}.unconditional_memory_claim_eligible",
                "must remain false for the production pilot",
            )


def summarize_runtime_query_plans(
    receipt: Mapping[str, Any],
    artifact_root: Path,
    where: str = "memory query-plan report",
) -> Dict[str, Any]:
    """Validate native artifacts, then summarize only host-verifiable plan traces."""

    validate_runtime_artifacts(receipt, artifact_root, f"{where}.artifacts")
    query_plan_bound = _query_plan_source_bound(receipt, where)
    rollouts = receipt.get("rollouts")
    if not isinstance(rollouts, list):
        _fail(where, "runtime receipt has no rollouts")
    traces: List[Mapping[str, Any] | None] = []
    host_recall_satisfied: List[bool] = []
    for index, rollout in enumerate(rollouts):
        rollout_where = f"{where}.rollouts[{index}]"
        if not isinstance(rollout, dict):
            _fail(rollout_where, "expected an object")
        paths = rollout.get("artifact_paths")
        if not isinstance(paths, dict):
            _fail(f"{rollout_where}.artifact_paths", "expected an object")
        relative = _artifact_relative_path(
            paths.get("cassette"),
            f"{rollout_where}.artifact_paths.cassette",
        ).as_posix()
        cassette = _artifact_path(
            artifact_root,
            relative,
            f"{rollout_where}.artifact_paths.cassette",
            directory=True,
        )
        trace = load_and_verify_query_plan_sidecar(
            cassette,
            run_id=str(rollout.get("run_id")),
            arm=str(rollout.get("arm")),
            memory_backend=str(rollout.get("memory_backend")),
            required=query_plan_bound,
            where=f"{rollout_where}.query_plan",
        )
        traces.append(trace)
        scoped_recall = rollout.get("scoped_recall")
        host_recall_satisfied.append(
            bool(
                isinstance(scoped_recall, dict)
                and scoped_recall.get("status") in {"injected", "no_hits"}
            )
        )
    return summarize_query_plan_traces(
        traces,
        host_recall_satisfied=host_recall_satisfied,
    )


def validate_manifest(manifest: Mapping[str, Any], where: str = "memory manifest") -> None:
    value = _object(
        manifest,
        where,
        (
            "schema_version",
            "protocol_id",
            "manifest_id",
            "dataset",
            "execution",
            "cases",
            "schedule",
        ),
    )
    if value["schema_version"] != REPLAY_SCHEMA_VERSION:
        _fail(f"{where}.schema_version", f"expected {REPLAY_SCHEMA_VERSION}")
    if value["protocol_id"] != PROTOCOL_ID:
        _fail(f"{where}.protocol_id", f"expected {PROTOCOL_ID!r}")
    _identifier(value["manifest_id"], f"{where}.manifest_id")

    dataset = _object(
        value["dataset"],
        f"{where}.dataset",
        ("id", "source_sha256", "adapter_id", "adapter_revision", "split_seed"),
    )
    _identifier(dataset["id"], f"{where}.dataset.id")
    _hash(dataset["source_sha256"], f"{where}.dataset.source_sha256")
    _identifier(dataset["adapter_id"], f"{where}.dataset.adapter_id")
    _string(dataset["adapter_revision"], f"{where}.dataset.adapter_revision")
    _integer(dataset["split_seed"], f"{where}.dataset.split_seed")

    execution = _object(
        value["execution"],
        f"{where}.execution",
        (
            "model_id",
            "model_fingerprint",
            "harness_revision",
            "arms",
            "trials",
            "retrieval_limits",
        ),
    )
    _string(execution["model_id"], f"{where}.execution.model_id")
    _hash(execution["model_fingerprint"], f"{where}.execution.model_fingerprint")
    _string(execution["harness_revision"], f"{where}.execution.harness_revision")
    trials = _integer(execution["trials"], f"{where}.execution.trials", minimum=1, maximum=100)
    if not isinstance(execution["arms"], list) or len(execution["arms"]) < 2:
        _fail(f"{where}.execution.arms", "expected at least two arms")
    arm_ids: set[str] = set()
    for index, raw_arm in enumerate(execution["arms"]):
        arm = _object(raw_arm, f"{where}.execution.arms[{index}]", ("id", "fingerprint"))
        arm_id = _identifier(arm["id"], f"{where}.execution.arms[{index}].id")
        if arm_id in arm_ids:
            _fail(f"{where}.execution.arms[{index}].id", "duplicate arm")
        arm_ids.add(arm_id)
        _hash(arm["fingerprint"], f"{where}.execution.arms[{index}].fingerprint")
    if "no_memory" not in arm_ids:
        _fail(f"{where}.execution.arms", "must include no_memory cold-start control")
    limits = _object(
        execution["retrieval_limits"],
        f"{where}.execution.retrieval_limits",
        ("max_k", "max_hops", "max_semantic_variants"),
    )
    _integer(limits["max_k"], f"{where}.execution.retrieval_limits.max_k", minimum=1, maximum=100)
    _integer(limits["max_hops"], f"{where}.execution.retrieval_limits.max_hops", minimum=1, maximum=16)
    _integer(
        limits["max_semantic_variants"],
        f"{where}.execution.retrieval_limits.max_semantic_variants",
        maximum=4,
    )

    if not isinstance(value["cases"], list) or not value["cases"]:
        _fail(f"{where}.cases", "expected at least one case")
    case_ids: set[str] = set()
    cases_by_id: Dict[str, Mapping[str, Any]] = {}
    family_splits: Dict[str, set[str]] = {}
    family_cases: Dict[str, List[str]] = {}
    for index, raw_case in enumerate(value["cases"]):
        case_where = f"{where}.cases[{index}]"
        case = _object(
            raw_case,
            case_where,
            (
                "id",
                "benchmark",
                "split",
                "prompt",
                "gold_answers",
                "expected_evidence_ids",
                "grader",
                "family_id",
            ),
        )
        case_id = _identifier(case["id"], f"{case_where}.id")
        if case_id in case_ids:
            _fail(f"{case_where}.id", "duplicate case")
        case_ids.add(case_id)
        cases_by_id[case_id] = case
        benchmark = _string(case["benchmark"], f"{case_where}.benchmark")
        if benchmark not in BENCHMARKS:
            _fail(f"{case_where}.benchmark", f"unsupported benchmark {benchmark!r}")
        split = _string(case["split"], f"{case_where}.split")
        if benchmark in {"episodic_recall", "multihop_retrieval"} and split != "test":
            _fail(f"{case_where}.split", "QA cases must use test")
        if benchmark == "procedural_transfer" and split not in {"online", "offline"}:
            _fail(f"{case_where}.split", "procedural cases must use online/offline")
        prompt = _string(case["prompt"], f"{case_where}.prompt")
        prompt_folded = prompt.casefold()
        leaked = {term for term in TREATMENT_LEAK_TERMS if term in prompt_folded}
        for arm_id in arm_ids:
            folded_arm = arm_id.casefold()
            if re.search(
                rf"(?<![a-z0-9_.:-]){re.escape(folded_arm)}(?![a-z0-9_.:-])",
                prompt_folded,
            ):
                leaked.add(folded_arm)
        leaked = sorted(leaked)
        if leaked:
            _fail(f"{case_where}.prompt", f"leaks treatment terms: {leaked}")
        gold = _string_list(
            case["gold_answers"],
            f"{case_where}.gold_answers",
            allow_empty=benchmark == "procedural_transfer",
        )
        supports = _string_list(
            case["expected_evidence_ids"],
            f"{case_where}.expected_evidence_ids",
            allow_empty=benchmark == "procedural_transfer",
        )
        if benchmark == "multihop_retrieval" and len(supports) < 2:
            _fail(f"{case_where}.expected_evidence_ids", "multi-hop cases require >=2 supports")
        grader = _object(case["grader"], f"{case_where}.grader", ("kind", "fingerprint"))
        grader_kind = _string(grader["kind"], f"{case_where}.grader.kind")
        _hash(grader["fingerprint"], f"{case_where}.grader.fingerprint")
        expected_grader = (
            "deterministic_validator"
            if benchmark == "procedural_transfer"
            else "normalized_exact_match"
        )
        if grader_kind != expected_grader:
            _fail(f"{case_where}.grader.kind", f"expected {expected_grader!r}")
        family_id = case["family_id"]
        if benchmark == "procedural_transfer":
            family = _identifier(family_id, f"{case_where}.family_id")
            family_splits.setdefault(family, set()).add(split)
            family_cases.setdefault(family, []).append(case_id)
            if gold:
                _fail(f"{case_where}.gold_answers", "procedural cases use validators, not answer gold")
        elif family_id is not None:
            _fail(f"{case_where}.family_id", "QA cases must use null")
    for family, splits in family_splits.items():
        if splits != {"online", "offline"}:
            _fail(
                f"{where}.cases",
                f"procedural family {family!r} must contain online and offline cases",
            )
        online_cases = [
            case_id
            for case_id in family_cases[family]
            if cases_by_id[case_id]["split"] == "online"
        ]
        if len(online_cases) != 1:
            _fail(
                f"{where}.cases",
                f"procedural family {family!r} must contain exactly one online case",
            )

    expected_count = trials * len(arm_ids) * len(case_ids)
    if expected_count > 100_000:
        _fail(f"{where}.execution", "schedule exceeds 100000 observations")
    if not isinstance(value["schedule"], list) or len(value["schedule"]) != expected_count:
        _fail(
            f"{where}.schedule",
            f"expected exactly {expected_count} case/trial/arm entries",
        )
    expected_schedule = {
        (case_id, trial, arm_id)
        for case_id in case_ids
        for trial in range(trials)
        for arm_id in arm_ids
    }
    scheduled: set[Tuple[str, int, str]] = set()
    schedule_positions: Dict[Tuple[str, int, str], int] = {}
    for index, raw_entry in enumerate(value["schedule"]):
        entry_where = f"{where}.schedule[{index}]"
        entry = _object(raw_entry, entry_where, ("sequence", "case_id", "trial", "arm"))
        sequence = _integer(entry["sequence"], f"{entry_where}.sequence")
        if sequence != index:
            _fail(f"{entry_where}.sequence", f"expected contiguous sequence {index}")
        case_id = _identifier(entry["case_id"], f"{entry_where}.case_id")
        trial = _integer(entry["trial"], f"{entry_where}.trial", maximum=trials - 1)
        arm_id = _identifier(entry["arm"], f"{entry_where}.arm")
        key = (case_id, trial, arm_id)
        if key not in expected_schedule:
            _fail(entry_where, f"unknown schedule tuple {key!r}")
        if key in scheduled:
            _fail(entry_where, f"duplicate schedule tuple {key!r}")
        scheduled.add(key)
        schedule_positions[key] = sequence
    missing_schedule = sorted(expected_schedule - scheduled)
    if missing_schedule:
        _fail(f"{where}.schedule", f"missing schedule tuples: {missing_schedule[:5]}")

    # Procedural transfer is only causal when the one online demonstration is
    # executed before every held-out sibling for each arm and trial.
    for family, case_ids_in_family in family_cases.items():
        online_case = next(
            case_id
            for case_id in case_ids_in_family
            if cases_by_id[case_id]["split"] == "online"
        )
        offline_cases = [
            case_id
            for case_id in case_ids_in_family
            if cases_by_id[case_id]["split"] == "offline"
        ]
        for trial in range(trials):
            for arm_id in arm_ids:
                online_position = schedule_positions[(online_case, trial, arm_id)]
                for offline_case in offline_cases:
                    if schedule_positions[(offline_case, trial, arm_id)] <= online_position:
                        _fail(
                            f"{where}.schedule",
                            f"procedural family {family!r} runs offline before online",
                        )


def _case_map(manifest: Mapping[str, Any]) -> Dict[str, Mapping[str, Any]]:
    return {case["id"]: case for case in manifest["cases"]}


def _arm_map(manifest: Mapping[str, Any]) -> Dict[str, Mapping[str, Any]]:
    return {arm["id"]: arm for arm in manifest["execution"]["arms"]}


def _schedule_map(manifest: Mapping[str, Any]) -> Dict[int, Mapping[str, Any]]:
    return {entry["sequence"]: entry for entry in manifest["schedule"]}


def _observation_shell(
    observation: Mapping[str, Any], where: str
) -> Mapping[str, Any]:
    if not isinstance(observation, dict):
        _fail(where, "expected an object")
    schema_version = observation.get("schema_version")
    if schema_version not in {
        LEGACY_OBSERVATION_SCHEMA_VERSION,
        OBSERVATION_SCHEMA_VERSION,
    }:
        _fail(
            f"{where}.schema_version",
            f"expected {LEGACY_OBSERVATION_SCHEMA_VERSION} or {OBSERVATION_SCHEMA_VERSION}",
        )
    return _object(
        observation,
        where,
        (
            "schema_version",
            "protocol_id",
            "case_id",
            "trial",
            "arm",
            "execution",
            *(("workspace",) if schema_version == OBSERVATION_SCHEMA_VERSION else ()),
            "evaluator",
            "prediction",
            "retrieval",
            "memory",
            "graph",
            "governance",
            "cost",
            "trajectory",
        ),
    )


def replay_observations(
    manifest: Mapping[str, Any],
    observations: Sequence[Mapping[str, Any]],
    *,
    dataset_source: Path,
    runtime_receipt: Mapping[str, Any],
    runtime_artifact_root: Path | None = None,
    _query_plan_reanalysis: object | None = None,
) -> List[Dict[str, Any]]:
    validate_manifest(manifest)
    try:
        observed_source_sha = file_sha256(dataset_source)
    except OSError as exc:
        raise ValidationError(f"cannot read memory replay dataset source: {exc}") from exc
    expected_source_sha = manifest["dataset"]["source_sha256"]
    if observed_source_sha != expected_source_sha:
        _fail(
            "memory replay dataset source",
            f"SHA-256 mismatch: expected {expected_source_sha}, observed {observed_source_sha}",
        )
    validate_runtime_receipt(
        runtime_receipt,
        manifest,
        observations,
        observed_source_sha,
    )
    if runtime_receipt.get("schema_version") in NATIVE_RUNTIME_RECEIPT_VERSIONS:
        if runtime_artifact_root is None:
            _fail(
                "memory runtime artifacts",
                "native replay requires the receipt directory for raw-artifact re-observation",
            )
        validate_runtime_artifacts(
            runtime_receipt,
            runtime_artifact_root,
            _query_plan_reanalysis=_query_plan_reanalysis,
        )

    cases = _case_map(manifest)
    arms = _arm_map(manifest)
    schedule = _schedule_map(manifest)
    trials = manifest["execution"]["trials"]
    limits = manifest["execution"]["retrieval_limits"]
    expected_schedule = {
        (entry["case_id"], entry["trial"], entry["arm"])
        for entry in schedule.values()
    }
    seen: set[Tuple[str, int, str]] = set()
    rows: List[Dict[str, Any]] = []
    workspace_success_by_key: Dict[Tuple[str, int, str], bool | None] = {}
    manifest_sha256 = _canonical_sha256(manifest)
    runtime_receipt_sha256 = _canonical_sha256(runtime_receipt)

    for index, raw_observation in enumerate(observations):
        where = f"memory observations[{index}]"
        observation = _observation_shell(raw_observation, where)
        observation_schema_version = observation["schema_version"]
        if observation["protocol_id"] != PROTOCOL_ID:
            _fail(f"{where}.protocol_id", f"expected {PROTOCOL_ID!r}")
        case_id = _identifier(observation["case_id"], f"{where}.case_id")
        if case_id not in cases:
            _fail(f"{where}.case_id", f"not present in manifest: {case_id!r}")
        sequence = index
        trial = _integer(observation["trial"], f"{where}.trial", maximum=trials - 1)
        arm_id = _identifier(observation["arm"], f"{where}.arm")
        if arm_id not in arms:
            _fail(f"{where}.arm", f"not present in manifest: {arm_id!r}")
        schedule_key = (case_id, trial, arm_id)
        if schedule_key in seen:
            _fail(where, f"duplicate schedule row {schedule_key!r}")
        scheduled_entry = schedule.get(sequence)
        if scheduled_entry is None:
            _fail(where, "observation extends beyond the frozen schedule")
        scheduled_key = (
            scheduled_entry["case_id"],
            scheduled_entry["trial"],
            scheduled_entry["arm"],
        )
        if schedule_key != scheduled_key:
            _fail(
                where,
                f"observation tuple {schedule_key!r} does not match sequence {sequence} "
                f"tuple {scheduled_key!r}",
            )
        seen.add(schedule_key)

        case = cases[case_id]
        execution = _object(
            observation["execution"],
            f"{where}.execution",
            ("status", "invalid_reason"),
        )
        execution_status = _string(execution["status"], f"{where}.execution.status")
        if execution_status not in {"completed", "invalid"}:
            _fail(f"{where}.execution.status", "must be completed or invalid")
        if execution_status == "completed" and execution["invalid_reason"] is not None:
            _fail(f"{where}.execution.invalid_reason", "completed execution must use null")
        if execution_status == "invalid":
            _string(execution["invalid_reason"], f"{where}.execution.invalid_reason")

        workspace_success: bool | None = None
        if observation_schema_version == OBSERVATION_SCHEMA_VERSION:
            workspace = _object(
                observation["workspace"],
                f"{where}.workspace",
                ("deterministic_success",),
            )
            workspace_success = workspace["deterministic_success"]
        workspace_success_by_key[schedule_key] = workspace_success

        evaluator = _object(
            observation["evaluator"],
            f"{where}.evaluator",
            ("status", "invalid_reason", "deterministic_success"),
        )
        evaluator_status = _string(evaluator["status"], f"{where}.evaluator.status")
        if evaluator_status not in {"ready", "invalid"}:
            _fail(f"{where}.evaluator.status", "must be ready or invalid")
        if evaluator_status == "invalid":
            _string(evaluator["invalid_reason"], f"{where}.evaluator.invalid_reason")
            if evaluator["deterministic_success"] is not None:
                _fail(f"{where}.evaluator.deterministic_success", "invalid evaluator must use null")
        elif evaluator["invalid_reason"] is not None:
            _fail(f"{where}.evaluator.invalid_reason", "ready evaluator must use null")

        grader_kind = case["grader"]["kind"]
        if observation_schema_version == OBSERVATION_SCHEMA_VERSION:
            if grader_kind == "normalized_exact_match":
                if workspace_success is not None:
                    _fail(
                        f"{where}.workspace.deterministic_success",
                        "answer success is not a workspace fact",
                    )
            elif execution_status == "completed":
                if not isinstance(workspace_success, bool):
                    _fail(
                        f"{where}.workspace.deterministic_success",
                        "completed deterministic validation must preserve a boolean workspace fact",
                    )
            elif workspace_success is not None:
                _fail(
                    f"{where}.workspace.deterministic_success",
                    "invalid execution has no workspace result",
                )
        if evaluator_status == "ready" and grader_kind == "normalized_exact_match":
            if evaluator["deterministic_success"] is not None:
                _fail(
                    f"{where}.evaluator.deterministic_success",
                    "answer success is recomputed from hidden manifest gold",
                )
        elif evaluator_status == "ready":
            if execution_status == "completed" and not isinstance(
                evaluator["deterministic_success"], bool
            ):
                _fail(
                    f"{where}.evaluator.deterministic_success",
                    "completed deterministic validation must report a boolean",
                )
            if execution_status == "invalid" and evaluator["deterministic_success"] is not None:
                _fail(
                    f"{where}.evaluator.deterministic_success",
                    "invalid execution has no procedural success result",
                )
            if (
                observation_schema_version == OBSERVATION_SCHEMA_VERSION
                and execution_status == "completed"
                and evaluator["deterministic_success"] != workspace_success
            ):
                _fail(
                    f"{where}.evaluator.deterministic_success",
                    "ready evaluator must match the host workspace fact",
                )

        retrieval = _object(
            observation["retrieval"],
            f"{where}.retrieval",
            (
                "enabled",
                "k",
                "hop_count",
                "query_variants",
                "retrieved_evidence_ids",
                "verified_evidence_ids",
                "graph_truncated",
            ),
        )
        k = retrieval.get("k")
        hops = retrieval.get("hop_count")
        variants = retrieval.get("query_variants")
        if isinstance(k, int) and not isinstance(k, bool) and k > limits["max_k"]:
            _fail(f"{where}.retrieval.k", "exceeds manifest max_k")
        if isinstance(hops, int) and not isinstance(hops, bool) and hops > limits["max_hops"]:
            _fail(f"{where}.retrieval.hop_count", "exceeds manifest max_hops")
        if isinstance(variants, list):
            semantic_count = sum(
                isinstance(item, dict) and item.get("kind") == "semantic"
                for item in variants
            )
            if semantic_count > limits["max_semantic_variants"]:
                _fail(
                    f"{where}.retrieval.query_variants",
                    "exceeds manifest semantic-variant cap",
                )

        prediction = _text(observation["prediction"], f"{where}.prediction")
        if execution_status == "completed" and evaluator_status == "ready":
            if grader_kind == "normalized_exact_match":
                success = normalized_exact_match(prediction, case["gold_answers"])
            else:
                success = bool(evaluator["deterministic_success"])
            outcome_status = "pass" if success else "fail"
        else:
            success = None
            outcome_status = "unscored"

        result: Dict[str, Any] = {
            "schema_version": RESULT_SCHEMA_VERSION,
            "protocol_id": PROTOCOL_ID,
            "benchmark": case["benchmark"],
            "case_id": case_id,
            "sequence": sequence,
            "trial": trial,
            "arm": arm_id,
            "split": case["split"],
            "identity": {
                "dataset_id": manifest["dataset"]["id"],
                "dataset_sha256": expected_source_sha,
                "adapter_id": manifest["dataset"]["adapter_id"],
                "adapter_revision": manifest["dataset"]["adapter_revision"],
                "split_seed": manifest["dataset"]["split_seed"],
                "manifest_sha256": manifest_sha256,
                "runtime_receipt_sha256": runtime_receipt_sha256,
                "task_fingerprint": _canonical_sha256(case),
                "model_id": manifest["execution"]["model_id"],
                "model_fingerprint": manifest["execution"]["model_fingerprint"],
                "harness_revision": manifest["execution"]["harness_revision"],
                "arm_fingerprint": arms[arm_id]["fingerprint"],
                "grader_fingerprint": case["grader"]["fingerprint"],
                "observation_sha256": _canonical_sha256(observation),
            },
            "execution": dict(execution),
            "evaluator": {
                "status": evaluator_status,
                "invalid_reason": evaluator["invalid_reason"],
            },
            "outcome": {
                "status": outcome_status,
                "success": success,
                "prediction": prediction,
                "gold_answers": list(case["gold_answers"]),
                "deterministic": True,
            },
            "retrieval": {
                **dict(observation["retrieval"]),
                "expected_evidence_ids": list(case["expected_evidence_ids"]),
            },
            "memory": dict(observation["memory"]),
            "graph": dict(observation["graph"]),
            "governance": dict(observation["governance"]),
            "cost": dict(observation["cost"]),
            "trajectory": dict(observation["trajectory"]),
        }
        validate_memory_row(result, f"{where} joined result")
        rows.append(result)

    missing = sorted(expected_schedule - seen)
    extras = sorted(seen - expected_schedule)
    if extras:
        _fail("memory observations", f"unexpected schedule rows: {extras[:5]}")
    if missing:
        _fail(
            "memory observations",
            f"incomplete schedule: missing {len(missing)} rows, first={missing[:5]}",
        )
    rows_by_key = {
        (row["case_id"], row["trial"], row["arm"]): row
        for row in rows
    }
    family_cases: Dict[str, List[Mapping[str, Any]]] = {}
    for case in cases.values():
        if case["benchmark"] == "procedural_transfer":
            family_cases.setdefault(case["family_id"], []).append(case)
    for family, members in family_cases.items():
        online_case = next(case for case in members if case["split"] == "online")
        offline_cases = [case for case in members if case["split"] == "offline"]
        for trial in range(trials):
            for arm_id in arms:
                if arm_id == "no_memory":
                    continue
                online = rows_by_key[(online_case["id"], trial, arm_id)]
                for offline_case in offline_cases:
                    offline = rows_by_key[(offline_case["id"], trial, arm_id)]
                    if offline["graph"]["revision"] != online["graph"]["revision"]:
                        _fail(
                            "memory observations",
                            f"procedural family {family!r} offline graph revision does not "
                            "match its online predecessor",
                        )
                    online_evaluator = online["evaluator"]
                    evaluator_only_query_plan_failure = (
                        online_evaluator["status"] == "invalid"
                        and isinstance(online_evaluator["invalid_reason"], str)
                        and online_evaluator["invalid_reason"].startswith(
                            QUERY_PLAN_INVALID_PREFIX
                        )
                        and workspace_success_by_key[
                            (online_case["id"], trial, arm_id)
                        ]
                        is True
                    )
                    online_usable = online["execution"]["status"] == "completed" and (
                        online_evaluator["status"] == "ready"
                        or evaluator_only_query_plan_failure
                    )
                    offline_scored = (
                        offline["execution"]["status"] == "completed"
                        and offline["evaluator"]["status"] == "ready"
                    )
                    if offline_scored and not online_usable:
                        _fail(
                            "memory observations",
                            f"procedural family {family!r} scores offline after an invalid "
                            "online predecessor",
                        )
    return sorted(rows, key=lambda row: row["sequence"])
