"""Schema validation and JSONL I/O for metacodes evaluation artifacts."""

from __future__ import annotations

import json
import math
import os
import re
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Iterable, List, Optional


SCHEMA_VERSION = 1
LAYERS = frozenset({"E", "T", "C", "L", "O", "V", "G"})
ATTRIBUTION_SOURCES = LAYERS | {
    "model",
    "benchmark",
    "grader",
    "unattributed",
}
CHECK_TYPES = frozenset(
    {
        "file_exists",
        "file_absent",
        "contains",
        "contains_casefold",
        "contains_any",
        "not_contains",
        "not_contains_casefold",
        "min_lines",
        "log_contains",
        "log_not_contains",
        "debug_log_contains",
        "debug_log_not_contains",
        "debug_tool_input_contains",
        "debug_tool_input_not_contains",
        "assistant_contains",
        "validator",
    }
)


class ValidationError(ValueError):
    """The evaluation artifact is structurally invalid."""


def safe_posix_relative_path(value: Any, where: str) -> PurePosixPath:
    """Parse one canonical repository-relative POSIX path.

    Evaluation manifests are portable data, so accepting a host-native path on
    one machine and interpreting it differently on another is a contract bug.
    Reject normalization-sensitive spellings up front instead of waiting for
    the snapshot materializer to fail at execution time.
    """
    if not isinstance(value, str) or not value or "\\" in value:
        raise ValidationError(f"{where}: expected a canonical relative POSIX path")
    components = value.split("/")
    if any(component in {"", ".", ".."} for component in components):
        raise ValidationError(f"{where}: expected a canonical relative POSIX path")
    path = PurePosixPath(value)
    if path.is_absolute() or path.as_posix() != value:
        raise ValidationError(f"{where}: expected a canonical relative POSIX path")
    return path


def _is_safe_posix_relative_path(value: Any, where: str) -> bool:
    try:
        safe_posix_relative_path(value, where)
    except ValidationError:
        return False
    return True


def _validate_finite_numbers(value: Any, where: str) -> None:
    if isinstance(value, bool) or value is None:
        return
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValidationError(f"{where}: non-finite numbers are not valid evaluation data")
        return
    if isinstance(value, dict):
        for key, item in value.items():
            _validate_finite_numbers(item, f"{where}.{key}")
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            _validate_finite_numbers(item, f"{where}[{index}]")


def _validate_metric(
    metrics: Dict[str, Any], key: str, *, integer: bool = False
) -> None:
    value = metrics.get(key)
    if value is None:
        return
    if integer:
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise ValidationError(f"metrics.{key}: expected integer >= 0 or null")
        return
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(float(value))
        or value < 0
    ):
        raise ValidationError(f"metrics.{key}: expected finite number >= 0 or null")


def _require(mapping: Dict[str, Any], key: str, expected: type, where: str) -> Any:
    if key not in mapping:
        raise ValidationError(f"{where}: missing required field {key!r}")
    value = mapping[key]
    if not isinstance(value, expected):
        raise ValidationError(
            f"{where}.{key}: expected {expected.__name__}, got {type(value).__name__}"
        )
    return value


def _validate_check(check: Dict[str, Any], where: str) -> None:
    kind = _require(check, "type", str, where)
    if kind not in CHECK_TYPES:
        raise ValidationError(f"{where}.type: unsupported check {kind!r}")
    if kind.startswith("file_") or kind in {
        "contains",
        "contains_casefold",
        "contains_any",
        "not_contains",
        "not_contains_casefold",
        "min_lines",
    }:
        path = _require(check, "path", str, where)
        try:
            safe_posix_relative_path(path, f"{where}.path")
        except ValidationError:
            raise ValidationError(f"{where}.path: must be a safe workspace-relative path")
    if kind in {
        "contains",
        "contains_casefold",
        "not_contains",
        "not_contains_casefold",
        "log_contains",
        "log_not_contains",
        "debug_log_contains",
        "debug_log_not_contains",
        "debug_tool_input_contains",
        "debug_tool_input_not_contains",
        "assistant_contains",
    }:
        _require(check, "text", str, where)
    if kind in {"debug_tool_input_contains", "debug_tool_input_not_contains"}:
        tool = _require(check, "tool", str, where)
        if not tool:
            raise ValidationError(f"{where}.tool: must not be empty")
    if kind == "contains_any":
        texts = _require(check, "texts", list, where)
        if not texts or not all(isinstance(item, str) and item for item in texts):
            raise ValidationError(f"{where}.texts: expected non-empty string list")
    if kind == "min_lines":
        minimum = _require(check, "minimum", int, where)
        if minimum < 0:
            raise ValidationError(f"{where}.minimum: must be >= 0")
    if kind == "validator":
        validator = _require(check, "validator", str, where)
        try:
            validator_path = safe_posix_relative_path(
                validator, f"{where}.validator"
            )
        except ValidationError:
            validator_path = PurePosixPath()
        if validator_path.parts[:2] != ("evals", "validators"):
            raise ValidationError(
                f"{where}.validator: must be a safe path below evals/validators"
            )
        timeout = check.get("timeout_seconds", 30)
        if not isinstance(timeout, int) or isinstance(timeout, bool) or not 1 <= timeout <= 120:
            raise ValidationError(
                f"{where}.timeout_seconds: expected integer in [1, 120]"
            )


def validate_suite(data: Dict[str, Any], root: Path) -> List[str]:
    """Validate Stage 1 task grounding and return non-fatal readiness warnings."""
    if data.get("schema_version") != SCHEMA_VERSION:
        raise ValidationError(
            f"suite.schema_version: expected {SCHEMA_VERSION}, got {data.get('schema_version')!r}"
        )
    _require(data, "suite_id", str, "suite")
    tasks = _require(data, "tasks", list, "suite")
    if not tasks:
        raise ValidationError("suite.tasks: at least one grounded task is required")

    seen = set()
    warnings: List[str] = []
    for index, task in enumerate(tasks):
        where = f"suite.tasks[{index}]"
        if not isinstance(task, dict):
            raise ValidationError(f"{where}: expected object")
        task_id = _require(task, "id", str, where)
        if task_id in seen:
            raise ValidationError(f"{where}.id: duplicate task id {task_id!r}")
        seen.add(task_id)
        scenario = _require(task, "scenario", str, where)
        scenario_path = (root / scenario).resolve()
        try:
            scenario_path.relative_to(root.resolve())
        except ValueError as exc:
            raise ValidationError(f"{where}.scenario: escapes repository root") from exc
        if not scenario_path.is_file():
            raise ValidationError(f"{where}.scenario: file does not exist: {scenario}")

        layers = _require(task, "layers", list, where)
        if not layers or any(layer not in LAYERS for layer in layers):
            raise ValidationError(f"{where}.layers: expected non-empty subset of {sorted(LAYERS)}")
        if len(set(layers)) != len(layers):
            raise ValidationError(f"{where}.layers: duplicate layer")

        environment = _require(task, "environment", dict, where)
        _require(environment, "reset", str, f"{where}.environment")
        snapshot = environment.get("repository_snapshot")
        if snapshot is not None:
            if not isinstance(snapshot, dict) or set(snapshot) != {
                "revision",
                "prefix",
                "paths",
            }:
                raise ValidationError(
                    f"{where}.environment.repository_snapshot: expected exactly "
                    "revision, prefix, and paths"
                )
            revision = snapshot.get("revision")
            if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
                raise ValidationError(
                    f"{where}.environment.repository_snapshot.revision: "
                    "expected a full lowercase Git commit id"
                )
            prefix = snapshot.get("prefix")
            if prefix != ".":
                try:
                    safe_posix_relative_path(
                        prefix,
                        f"{where}.environment.repository_snapshot.prefix",
                    )
                except ValidationError:
                    raise ValidationError(
                        f"{where}.environment.repository_snapshot.prefix: "
                        "expected '.' or a safe repository-relative path"
                    )
            paths = snapshot.get("paths")
            if (
                not isinstance(paths, list)
                or not paths
                or len(paths) > 64
                or not all(
                    _is_safe_posix_relative_path(
                        item,
                        f"{where}.environment.repository_snapshot.paths",
                    )
                    for item in paths
                )
                or len(set(paths)) != len(paths)
            ):
                raise ValidationError(
                    f"{where}.environment.repository_snapshot.paths: expected "
                    "1-64 distinct safe paths relative to prefix"
                )
        fixtures = environment.get("fixtures", [])
        if not isinstance(fixtures, list) or not all(
            isinstance(item, str) and item for item in fixtures
        ):
            raise ValidationError(
                f"{where}.environment.fixtures: expected repo-relative path list"
            )
        for fixture in fixtures:
            fixture_path = (root / fixture).resolve()
            try:
                fixture_path.relative_to(root.resolve())
            except ValueError as exc:
                raise ValidationError(
                    f"{where}.environment.fixtures: path escapes repository root: {fixture}"
                ) from exc
            if not fixture_path.is_file():
                raise ValidationError(
                    f"{where}.environment.fixtures: file does not exist: {fixture}"
                )
        tools = _require(task, "tools", dict, where)
        _require(tools, "profile", str, f"{where}.tools")
        required_tools = _require(tools, "required", list, f"{where}.tools")
        if not all(isinstance(item, str) and item for item in required_tools):
            raise ValidationError(f"{where}.tools.required: expected tool-name strings")
        allowed_tools = tools.get("allowed")
        if allowed_tools is not None:
            if (
                not isinstance(allowed_tools, list)
                or not allowed_tools
                or not all(isinstance(item, str) and item for item in allowed_tools)
                or len(set(allowed_tools)) != len(allowed_tools)
            ):
                raise ValidationError(
                    f"{where}.tools.allowed: expected distinct tool-name strings"
                )
            missing_required = sorted(set(required_tools) - set(allowed_tools))
            if missing_required:
                raise ValidationError(
                    f"{where}.tools.allowed: missing required tools {missing_required}"
                )
        constraints = _require(task, "constraints", dict, where)
        timeout = _require(constraints, "timeout_seconds", int, f"{where}.constraints")
        if timeout <= 0:
            raise ValidationError(f"{where}.constraints.timeout_seconds: must be > 0")
        _require(constraints, "permission_mode", str, f"{where}.constraints")
        success = _require(task, "success", dict, where)
        checks = _require(success, "checks", list, f"{where}.success")
        if not checks:
            raise ValidationError(f"{where}.success.checks: deterministic outcome checks required")
        for check_index, check in enumerate(checks):
            if not isinstance(check, dict):
                raise ValidationError(f"{where}.success.checks[{check_index}]: expected object")
            _validate_check(check, f"{where}.success.checks[{check_index}]")
            if check.get("type") == "validator":
                validator_path = (root / check["validator"]).resolve()
                try:
                    validator_path.relative_to(root.resolve())
                except ValueError as exc:
                    raise ValidationError(
                        f"{where}.success.checks[{check_index}].validator: "
                        "escapes repository root"
                    ) from exc
                if not validator_path.is_file() or validator_path.is_symlink():
                    raise ValidationError(
                        f"{where}.success.checks[{check_index}].validator: "
                        f"regular file does not exist: {check['validator']}"
                    )
        grader = _require(task, "grader", dict, where)
        _require(grader, "kind", str, f"{where}.grader")
        _require(grader, "version", str, f"{where}.grader")

        trajectory = task.get("trajectory_constraints", {})
        if not isinstance(trajectory, dict):
            raise ValidationError(f"{where}.trajectory_constraints: expected object")
        if not trajectory:
            raise ValidationError(
                f"{where}.trajectory_constraints: at least one trajectory check is required"
            )
        for key, value in trajectory.items():
            if key not in {
                "max_turns",
                "max_tool_calls",
                "max_model_tool_errors",
                "max_harness_tool_errors",
                "max_permission_denials",
                "min_permission_denials",
                "required_tools",
                "forbidden_tools",
                "min_tool_counts",
            }:
                raise ValidationError(f"{where}.trajectory_constraints: unknown field {key!r}")
            if key in {"required_tools", "forbidden_tools"}:
                if not isinstance(value, list) or not all(
                    isinstance(item, str) and item for item in value
                ):
                    raise ValidationError(
                        f"{where}.trajectory_constraints.{key}: expected tool-name list"
                    )
            elif key == "min_tool_counts":
                if not isinstance(value, dict) or not value or not all(
                    isinstance(tool_name, str)
                    and tool_name
                    and isinstance(count, int)
                    and not isinstance(count, bool)
                    and count > 0
                    for tool_name, count in value.items()
                ):
                    raise ValidationError(
                        f"{where}.trajectory_constraints.{key}: expected non-empty "
                        "tool-name to positive integer object"
                    )
            elif not isinstance(value, int) or value < 0:
                raise ValidationError(f"{where}.trajectory_constraints.{key}: expected integer >= 0")

        rationales = _require(task, "trajectory_rationale", dict, where)
        missing_rationales = sorted(
            key
            for key in trajectory
            if not isinstance(rationales.get(key), str) or not rationales[key].strip()
        )
        if missing_rationales:
            raise ValidationError(
                f"{where}.trajectory_rationale: missing product rationale for {missing_rationales}"
            )
        extra_rationales = sorted(set(rationales) - set(trajectory))
        if extra_rationales:
            raise ValidationError(
                f"{where}.trajectory_rationale: no matching constraint for {extra_rationales}"
            )

        if "O" not in layers:
            warnings.append(f"{task_id}: no Observability coverage tag")
        if "V" not in layers:
            warnings.append(f"{task_id}: no Verification coverage tag")
    return warnings


def validate_treatment_activation_receipt(
    value: Any,
    where: str = "treatment_activation",
    *,
    expected_arm: Optional[str] = None,
) -> None:
    """Validate the versioned proof-carrying treatment receipt.

    This is deliberately structural.  The authoritative verifier in
    ``treatment_activation.py`` recomputes transcript/native hashes and the
    TinyKG task packet; schema validation alone never admits a rollout.
    """
    if not isinstance(value, dict):
        raise ValidationError(f"{where}: expected object")
    expected_keys = {
        "schema_version",
        "contract",
        "arm_id",
        "expectation",
        "status",
        "execution",
        "artifacts",
        "trace",
        "task",
        "store",
    }
    if set(value) != expected_keys:
        raise ValidationError(
            f"{where}: expected exactly {sorted(expected_keys)}"
        )
    if value.get("schema_version") != 1:
        raise ValidationError(f"{where}.schema_version: expected 1")
    if value.get("contract") != "metacodes-treatment-activation-v1":
        raise ValidationError(f"{where}.contract: unsupported contract")
    arm_id = value.get("arm_id")
    if arm_id not in {"codex_style", "claude_style", "tinykg"}:
        raise ValidationError(f"{where}.arm_id: unknown arm")
    if expected_arm is not None and arm_id != expected_arm:
        raise ValidationError(
            f"{where}.arm_id: expected {expected_arm!r}, observed {arm_id!r}"
        )
    if value.get("status") != "verified":
        raise ValidationError(f"{where}.status: expected verified")

    execution = value.get("execution")
    execution_keys = {
        "run_id",
        "suite_id",
        "task_id",
        "trial",
        "harness_config_id",
    }
    if not isinstance(execution, dict) or set(execution) != execution_keys:
        raise ValidationError(
            f"{where}.execution: expected exactly {sorted(execution_keys)}"
        )
    for key in ("run_id", "suite_id", "task_id", "harness_config_id"):
        if not isinstance(execution.get(key), str) or not execution[key]:
            raise ValidationError(f"{where}.execution.{key}: expected non-empty string")
    trial = execution.get("trial")
    if not isinstance(trial, int) or isinstance(trial, bool) or trial < 0:
        raise ValidationError(f"{where}.execution.trial: expected integer >= 0")

    artifacts = value.get("artifacts")
    artifact_keys = {
        "events_sha256",
        "transcript_sha256",
        "tinykg_binary_sha256",
    }
    if not isinstance(artifacts, dict) or set(artifacts) != artifact_keys:
        raise ValidationError(
            f"{where}.artifacts: expected exactly {sorted(artifact_keys)}"
        )
    for key in artifact_keys:
        digest = artifacts.get(key)
        if (
            not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None
        ):
            raise ValidationError(f"{where}.artifacts.{key}: invalid SHA-256")

    trace = value.get("trace")
    if not isinstance(trace, list):
        raise ValidationError(f"{where}.trace: expected array")
    store = value.get("store")
    if not isinstance(store, dict):
        raise ValidationError(f"{where}.store: expected object")
    if arm_id == "tinykg":
        if value.get("expectation") != "persistent_task_lifecycle":
            raise ValidationError(
                f"{where}.expectation: TinyKG arm requires persistent task lifecycle"
            )
        task = value.get("task")
        if (
            not isinstance(task, dict)
            or set(task) != {"id", "kind", "status"}
            or not isinstance(task.get("id"), int)
            or isinstance(task.get("id"), bool)
            or task["id"] <= 0
            or task.get("kind") != "task"
            or task.get("status") != "completed"
        ):
            raise ValidationError(f"{where}.task: invalid completed task identity")
        if len(trace) != 3:
            raise ValidationError(f"{where}.trace: expected three lifecycle events")
        phases = []
        prior_finish = -1
        trace_keys = {
            "phase",
            "tool_use_id",
            "started_sequence",
            "finished_sequence",
            "input_sha256",
            "result_sha256",
        }
        for index, item in enumerate(trace):
            if not isinstance(item, dict) or set(item) != trace_keys:
                raise ValidationError(
                    f"{where}.trace[{index}]: invalid lifecycle event schema"
                )
            phases.append(item.get("phase"))
            if not isinstance(item.get("tool_use_id"), str) or not item["tool_use_id"]:
                raise ValidationError(
                    f"{where}.trace[{index}].tool_use_id: expected non-empty string"
                )
            started = item.get("started_sequence")
            finished = item.get("finished_sequence")
            if (
                not isinstance(started, int)
                or isinstance(started, bool)
                or not isinstance(finished, int)
                or isinstance(finished, bool)
                or started <= prior_finish
                or finished <= started
            ):
                raise ValidationError(
                    f"{where}.trace[{index}]: lifecycle sequences are not ordered"
                )
            prior_finish = finished
            for key in ("input_sha256", "result_sha256"):
                if (
                    not isinstance(item.get(key), str)
                    or re.fullmatch(r"[0-9a-f]{64}", item[key]) is None
                ):
                    raise ValidationError(
                        f"{where}.trace[{index}].{key}: invalid SHA-256"
                    )
        if phases != ["created", "claimed", "completed"]:
            raise ValidationError(
                f"{where}.trace: expected created, claimed, completed"
            )
        store_keys = {
            "present",
            "relative_path",
            "manifest_sha256",
            "packet_schema",
            "packet_sha256",
            "verification_node_ids",
        }
        if set(store) != store_keys or store.get("present") is not True:
            raise ValidationError(f"{where}.store: invalid persistent store receipt")
        if store.get("relative_path") != ".home/.metacodes/kg/store.kg":
            raise ValidationError(f"{where}.store.relative_path: unexpected path")
        if store.get("packet_schema") != "tinykg-agent-retrieval-v1":
            raise ValidationError(f"{where}.store.packet_schema: unsupported schema")
        for key in ("manifest_sha256", "packet_sha256"):
            if (
                not isinstance(store.get(key), str)
                or re.fullmatch(r"[0-9a-f]{64}", store[key]) is None
            ):
                raise ValidationError(f"{where}.store.{key}: invalid SHA-256")
        verification_ids = store.get("verification_node_ids")
        if (
            not isinstance(verification_ids, list)
            or not verification_ids
            or any(
                not isinstance(node_id, int)
                or isinstance(node_id, bool)
                or node_id <= 0
                for node_id in verification_ids
            )
            or verification_ids != sorted(set(verification_ids))
        ):
            raise ValidationError(
                f"{where}.store.verification_node_ids: invalid node id set"
            )
    else:
        if value.get("expectation") != "persistent_tinykg_lifecycle_absent":
            raise ValidationError(
                f"{where}.expectation: baseline arm must prove treatment absence"
            )
        if trace or value.get("task") is not None or store != {"present": False}:
            raise ValidationError(
                f"{where}: baseline arm contains persistent treatment evidence"
            )


def validate_rollout(data: Dict[str, Any], where: str = "rollout") -> None:
    if data.get("schema_version") != SCHEMA_VERSION:
        raise ValidationError(f"{where}.schema_version: expected {SCHEMA_VERSION}")
    for key in ("run_id", "suite_id", "task_id"):
        _require(data, key, str, where)
    task_fingerprint = _require(data, "task_fingerprint", str, where)
    if not task_fingerprint:
        raise ValidationError(f"{where}.task_fingerprint: must not be empty")
    provenance = _require(data, "task_fingerprint_provenance", str, where)
    if provenance not in {
        "recorded_at_execution",
        "runner_frozen_before_execution",
        "inferred_from_current_suite",
    }:
        raise ValidationError(
            f"{where}.task_fingerprint_provenance: unsupported provenance {provenance!r}"
        )
    trial = _require(data, "trial", int, where)
    if isinstance(trial, bool) or trial < 0:
        raise ValidationError(f"{where}.trial: must be >= 0")
    execution = _require(data, "execution", dict, where)
    if execution.get("status") not in {"completed", "invalid"}:
        raise ValidationError(f"{where}.execution.status: expected completed|invalid")
    outcome = _require(data, "outcome", dict, where)
    if outcome.get("status") not in {"pass", "fail", "unscored"}:
        raise ValidationError(f"{where}.outcome.status: expected pass|fail|unscored")
    trajectory = _require(data, "trajectory", dict, where)
    if trajectory.get("status") not in {"pass", "fail", "unscored"}:
        raise ValidationError(f"{where}.trajectory.status: expected pass|fail|unscored")
    evaluator = _require(data, "evaluator", dict, where)
    if evaluator.get("status") not in {"ready", "invalid"}:
        raise ValidationError(f"{where}.evaluator.status: expected ready|invalid")
    _require(evaluator, "fingerprint", str, f"{where}.evaluator")
    readiness = _require(data, "readiness", dict, where)
    if readiness.get("status") not in {"pass", "fail"}:
        raise ValidationError(f"{where}.readiness.status: expected pass|fail")
    judgement = _require(data, "judgement", dict, where)
    valid_for_scoring = _require(
        judgement, "valid_for_scoring", bool, f"{where}.judgement"
    )
    trustworthy_success = _require(
        judgement, "trustworthy_success", bool, f"{where}.judgement"
    )
    expected_valid = execution["status"] == "completed" and evaluator["status"] == "ready"
    if valid_for_scoring != expected_valid:
        raise ValidationError(
            f"{where}.judgement.valid_for_scoring: inconsistent with execution/evaluator"
        )
    expected_trustworthy = (
        expected_valid
        and outcome["status"] == "pass"
        and trajectory["status"] == "pass"
    )
    if trustworthy_success != expected_trustworthy:
        raise ValidationError(
            f"{where}.judgement.trustworthy_success: inconsistent with component statuses"
        )
    if evaluator["status"] == "invalid" and outcome["status"] != "unscored":
        raise ValidationError(
            f"{where}.outcome.status: invalid evaluator requires unscored outcome"
        )
    metrics = _require(data, "metrics", dict, where)
    _validate_finite_numbers(metrics, f"{where}.metrics")
    for key in (
        "input_tokens",
        "output_tokens",
        "cache_read_tokens",
        "cache_write_tokens",
        "model_request_count",
        "compact_request_count",
        "tool_calls",
        "tool_successes",
        "model_tool_errors",
        "harness_tool_errors",
        "harness_errors",
        "network_errors",
        "permission_denials",
        "policy_violations",
        "policy_decisions",
        "retries",
        "turns",
    ):
        _validate_metric(metrics, key, integer=True)
    for key in (
        "cost_usd",
        "wall_time_ms",
        "model_header_latency_ms",
        "model_request_time_ms",
        "compact_request_time_ms",
        "tool_time_ms",
        "tool_stage_time_ms",
        "tool_parallelism_factor",
        "harness_time_ms",
    ):
        _validate_metric(metrics, key)
    model = _require(data, "model", dict, where)
    harness = _require(data, "harness", dict, where)
    _require(model, "provider", str, f"{where}.model")
    _require(model, "id", str, f"{where}.model")
    _require(harness, "config_id", str, f"{where}.harness")
    _require(harness, "revision", str, f"{where}.harness")
    runtime_budget = harness.get("runtime_budget")
    if runtime_budget is not None:
        if not isinstance(runtime_budget, dict):
            raise ValidationError(
                f"{where}.harness.runtime_budget: expected object or null"
            )
        expected_budget_keys = {"max_metered_tokens", "max_cost_usd"}
        if set(runtime_budget) != expected_budget_keys:
            raise ValidationError(
                f"{where}.harness.runtime_budget: expected exactly "
                f"{sorted(expected_budget_keys)}"
            )
        max_metered_tokens = runtime_budget["max_metered_tokens"]
        max_cost_usd = runtime_budget["max_cost_usd"]
        if (
            not isinstance(max_metered_tokens, int)
            or isinstance(max_metered_tokens, bool)
            or max_metered_tokens <= 0
        ):
            raise ValidationError(
                f"{where}.harness.runtime_budget.max_metered_tokens: "
                "expected integer > 0"
            )
        if (
            not isinstance(max_cost_usd, (int, float))
            or isinstance(max_cost_usd, bool)
            or not math.isfinite(float(max_cost_usd))
            or max_cost_usd <= 0
        ):
            raise ValidationError(
                f"{where}.harness.runtime_budget.max_cost_usd: "
                "expected finite number > 0"
            )
    attribution = _require(data, "attribution", list, where)
    for index, item in enumerate(attribution):
        if not isinstance(item, dict):
            raise ValidationError(f"{where}.attribution[{index}]: expected object")
        source = _require(item, "source", str, f"{where}.attribution[{index}]")
        if source not in ATTRIBUTION_SOURCES:
            raise ValidationError(f"{where}.attribution[{index}].source: unknown {source!r}")
        count = item.get("count", 1)
        if not isinstance(count, int) or isinstance(count, bool) or count < 0:
            raise ValidationError(
                f"{where}.attribution[{index}].count: expected integer >= 0"
            )
        confidence = item.get("confidence")
        if confidence is not None and (
            not isinstance(confidence, (int, float))
            or isinstance(confidence, bool)
            or not math.isfinite(float(confidence))
            or confidence < 0
            or confidence > 1
        ):
            raise ValidationError(
                f"{where}.attribution[{index}].confidence: expected finite number in [0, 1]"
            )
    if "treatment_activation" in data:
        validate_treatment_activation_receipt(
            data["treatment_activation"], f"{where}.treatment_activation"
        )


def load_json(path: Path) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValidationError(f"{path}: top-level JSON value must be an object")
    return value


def load_rollouts(path: Path) -> List[Dict[str, Any]]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ValidationError(f"cannot read rollout JSONL {path}: {exc}") from exc
    return parse_rollouts(text, str(path))


def parse_rollouts(text: str, where: str) -> List[Dict[str, Any]]:
    """Validate rollout JSONL already in memory. Callers that must hash the
    exact bytes they judged (a receipt) parse those bytes rather than read
    the file a second time."""
    result = []
    for line_no, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValidationError(f"{where}:{line_no}: invalid JSON: {exc}") from exc
        if not isinstance(value, dict):
            raise ValidationError(f"{where}:{line_no}: expected object")
        validate_rollout(value, f"{where}:{line_no}")
        result.append(value)
    if not result:
        raise ValidationError(f"{where}: no rollouts")
    return result


def write_rollouts(path: Path, rollouts: Iterable[Dict[str, Any]]) -> None:
    materialized = list(rollouts)
    for index, rollout in enumerate(materialized):
        validate_rollout(rollout, f"rollouts[{index}]")
    path.parent.mkdir(parents=True, exist_ok=True)
    text = "".join(json.dumps(item, ensure_ascii=False, sort_keys=True) + "\n" for item in materialized)
    temp_path: Optional[Path] = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temp_path = Path(handle.name)
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, path)
        temp_path = None
    finally:
        if temp_path is not None:
            try:
                temp_path.unlink()
            except FileNotFoundError:
                pass


def task_map(suite: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    return {task["id"]: task for task in suite["tasks"]}


def stable_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
