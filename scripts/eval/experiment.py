"""Machine-verifiable long-horizon multi-arm experiment contract."""

from __future__ import annotations

import hashlib
import math
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Mapping, Sequence, Tuple

from .model import (
    ValidationError,
    load_json,
    safe_posix_relative_path,
    stable_json,
    validate_suite,
)


EXPERIMENT_SCHEMA_VERSION = 2
PROMOTION_RECEIPT_SCHEMA_VERSION = 1
ARM_IDS = ("codex_style", "claude_style", "tinykg")
TREATMENT_KEYS = (
    "transcript",
    "compact_summary",
    "memory_markdown",
    "tinykg",
    "task_dag",
    "swarm",
)
EXPECTED_TREATMENTS = {
    "codex_style": {
        "transcript": True,
        "compact_summary": True,
        "memory_markdown": False,
        "tinykg": False,
        "task_dag": False,
        "swarm": False,
    },
    "claude_style": {
        "transcript": True,
        "compact_summary": True,
        "memory_markdown": True,
        "tinykg": False,
        "task_dag": False,
        "swarm": False,
    },
    "tinykg": {
        "transcript": True,
        "compact_summary": True,
        "memory_markdown": True,
        "tinykg": True,
        "task_dag": True,
        "swarm": False,
    },
}
DEPENDENCY_PROBE_TIMEOUT_SECONDS = 20
EXPERIMENT_KEYS = frozenset(
    {
        "schema_version",
        "program_id",
        "experiment_id",
        "stage",
        "suite",
        "model",
        "trials",
        "arms",
        "common_runtime",
        "schedule",
        "grading",
        "invalid_policy",
        "budget",
        "promotion",
        "stop_rules",
    }
)
BLIND_WORKSPACE_CHECKS = frozenset(
    {
        "file_exists",
        "file_absent",
        "contains",
        "contains_any",
        "not_contains",
        "min_lines",
        "validator",
    }
)
CONFIRMATORY_PROMPT_LEAK_TERMS = (
    "tinykg",
    "codex",
    "claude",
    "long-horizon mechanism",
    "configured long-horizon",
    "memory mechanism",
    "arm identity",
)


def _non_empty_string(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValidationError(f"{where}: expected non-empty string")
    return value


def _dependency_env() -> Dict[str, str]:
    """Keep host treatment knobs out of readiness probes."""
    return {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("METACODES_") and not key.startswith("TINYKG_")
    }


def _run_dependency_command(binary: Path, args: Sequence[str], label: str) -> str:
    try:
        completed = subprocess.run(
            [str(binary), *args],
            env=_dependency_env(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=DEPENDENCY_PROBE_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ValidationError(f"{label} readiness probe failed: {exc}") from exc
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()[-1000:]
        raise ValidationError(
            f"{label} readiness probe exited {completed.returncode}: {detail}"
        )
    return completed.stdout


def tinykg_binary_identity(binary: Path) -> Dict[str, str]:
    """Freeze and exercise the exact TinyKG executable used by every arm."""
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValidationError(f"TinyKG binary is not executable: {binary}")
    resolved = binary.resolve()
    sha256 = hashlib.sha256(resolved.read_bytes()).hexdigest()
    version = _run_dependency_command(resolved, ("version",), "TinyKG").strip()
    if not version.startswith("tinykg "):
        raise ValidationError(f"TinyKG version probe returned unexpected output: {version!r}")

    with tempfile.TemporaryDirectory(prefix="metacodes-eval-tinykg-") as directory:
        store = Path(directory) / "readiness.kg"
        _run_dependency_command(resolved, ("init", str(store)), "TinyKG init")
        store_info = _run_dependency_command(
            resolved, ("store-info", str(store)), "TinyKG store-info"
        )
    fields = dict(
        line.split("=", 1)
        for line in store_info.splitlines()
        if "=" in line
    )
    if fields.get("storage_format_version") != "2" or fields.get("schema_version") != "3":
        raise ValidationError(
            "TinyKG readiness requires storage_format_version=2 and schema_version=3; "
            f"observed storage={fields.get('storage_format_version')!r} "
            f"schema={fields.get('schema_version')!r}"
        )
    final_sha256 = hashlib.sha256(resolved.read_bytes()).hexdigest()
    if final_sha256 != sha256:
        raise ValidationError("TinyKG binary changed during its readiness probe")
    return {"path": str(resolved), "sha256": sha256, "version": version}


def counterbalanced_schedule(
    arm_ids: Sequence[str], trials: int
) -> List[Tuple[int, str]]:
    """Return complete Williams-style blocks with position/carryover balance."""
    if len(arm_ids) < 2 or len(set(arm_ids)) != len(arm_ids):
        raise ValidationError("multi-arm schedule requires distinct arm ids")
    block_size = 2 * len(arm_ids)
    if trials <= 0 or trials % block_size != 0:
        raise ValidationError(
            f"trials must be a positive multiple of {block_size} for a complete "
            "counterbalanced block"
        )
    base = tuple(arm_ids)
    reverse = (base[0],) + tuple(reversed(base[1:]))
    rows: List[Tuple[str, ...]] = []
    for seed in (base, reverse):
        rows.extend(seed[offset:] + seed[:offset] for offset in range(len(seed)))
    schedule: List[Tuple[int, str]] = []
    for trial in range(trials):
        row = rows[trial % block_size]
        schedule.extend((trial, arm_id) for arm_id in row)
    return schedule


def validate_experiment(
    experiment: Dict[str, Any], repo_root: Path, suite: Dict[str, Any]
) -> None:
    if set(experiment) != EXPERIMENT_KEYS:
        raise ValidationError(
            "experiment must freeze exactly the registered top-level fields; "
            f"missing={sorted(EXPERIMENT_KEYS - set(experiment))}, "
            f"unknown={sorted(set(experiment) - EXPERIMENT_KEYS)}"
        )
    if experiment.get("schema_version") != EXPERIMENT_SCHEMA_VERSION:
        raise ValidationError(
            f"experiment.schema_version: expected {EXPERIMENT_SCHEMA_VERSION}"
        )
    _non_empty_string(experiment.get("experiment_id"), "experiment.experiment_id")
    _non_empty_string(experiment.get("program_id"), "experiment.program_id")
    stage = experiment.get("stage")
    if not isinstance(stage, dict) or set(stage) != {"id", "purpose", "scoring"}:
        raise ValidationError("experiment.stage must freeze exactly id, purpose, and scoring")
    stage_id = stage.get("id")
    if stage_id == "calibration":
        expected_stage = {
            "id": "calibration",
            "purpose": "infrastructure_calibration",
            "scoring": "non_confirmatory",
        }
    elif stage_id == "confirmatory":
        expected_stage = {
            "id": "confirmatory",
            "purpose": "held_out_repository_pk",
            "scoring": "confirmatory",
        }
    else:
        raise ValidationError("experiment.stage.id must be calibration or confirmatory")
    if stage != expected_stage:
        raise ValidationError(f"experiment.stage does not match the {stage_id} contract")
    suite_path = _non_empty_string(experiment.get("suite"), "experiment.suite")
    resolved_suite = (repo_root / suite_path).resolve()
    try:
        resolved_suite.relative_to(repo_root.resolve())
    except ValueError as exc:
        raise ValidationError("experiment.suite escapes repository root") from exc
    if not resolved_suite.is_file():
        raise ValidationError(f"experiment.suite does not exist: {suite_path}")
    validate_suite(suite, repo_root)
    if stage_id == "calibration":
        if len(suite["tasks"]) != 1:
            raise ValidationError("calibration suite must contain exactly one non-scoring task")
    elif not 3 <= len(suite["tasks"]) <= 5:
        raise ValidationError("confirmatory repository suite must contain 3-5 tasks")
    for task in suite["tasks"]:
        expected_grader = {
            "kind": "deterministic_workspace",
            "version": (
                "long-horizon-v1"
                if stage_id == "calibration"
                else "long-horizon-repository-v1"
            ),
        }
        if task["grader"] != expected_grader:
            raise ValidationError(
                f"{task['id']}: grader does not match the {stage_id} stage"
            )
        observed_checks = {check["type"] for check in task["success"]["checks"]}
        if not observed_checks <= BLIND_WORKSPACE_CHECKS:
            raise ValidationError(
                f"{task['id']}: blind grading may inspect workspace artifacts only"
            )
        if stage_id == "confirmatory":
            if task.get("environment", {}).get("repository_snapshot") is None:
                raise ValidationError(
                    f"{task['id']}: confirmatory task must freeze a repository snapshot"
                )
            scenario_text = (repo_root / task["scenario"]).read_text(
                encoding="utf-8"
            ).lower()
            leaked = [term for term in CONFIRMATORY_PROMPT_LEAK_TERMS if term in scenario_text]
            if leaked:
                raise ValidationError(
                    f"{task['id']}: confirmatory prompt leaks treatment/evaluation terms {leaked}"
                )

    model = experiment.get("model")
    if not isinstance(model, dict):
        raise ValidationError("experiment.model: expected object")
    if model != {"provider": "anthropic", "id": "glm-5.2"}:
        raise ValidationError(
            "long-horizon experiment must lock model exactly to anthropic/glm-5.2"
        )

    trials = experiment.get("trials")
    if not isinstance(trials, int) or isinstance(trials, bool):
        raise ValidationError("experiment.trials: expected integer")
    counterbalanced_schedule(ARM_IDS, trials)

    arms = experiment.get("arms")
    if not isinstance(arms, list) or len(arms) != len(ARM_IDS):
        raise ValidationError("experiment.arms must define exactly three arms")
    observed = []
    for index, arm in enumerate(arms):
        where = f"experiment.arms[{index}]"
        if not isinstance(arm, dict):
            raise ValidationError(f"{where}: expected object")
        if set(arm) != {"id", "treatment"}:
            raise ValidationError(f"{where}: expected exactly id and treatment")
        arm_id = _non_empty_string(arm.get("id"), f"{where}.id")
        observed.append(arm_id)
        treatment = arm.get("treatment")
        if not isinstance(treatment, dict):
            raise ValidationError(f"{where}.treatment: expected object")
        if set(treatment) != set(TREATMENT_KEYS):
            raise ValidationError(
                f"{where}.treatment must freeze exactly {list(TREATMENT_KEYS)}"
            )
        if treatment != EXPECTED_TREATMENTS.get(arm_id):
            raise ValidationError(f"{where}.treatment does not match arm {arm_id!r}")
    if tuple(observed) != ARM_IDS:
        raise ValidationError(f"experiment arms must be ordered exactly as {ARM_IDS}")

    runtime = experiment.get("common_runtime")
    if not isinstance(runtime, dict):
        raise ValidationError("experiment.common_runtime: expected object")
    if set(runtime) != {
        "agent_teams",
        "forced_compact_at_tokens",
        "forced_compact_keep_recent",
        "max_turns",
    }:
        raise ValidationError("experiment.common_runtime contains missing or unknown fields")
    if runtime.get("agent_teams") is not False:
        raise ValidationError("first-stage three-arm experiment must keep agent_teams=false")
    compact_at = runtime.get("forced_compact_at_tokens")
    keep_recent = runtime.get("forced_compact_keep_recent")
    max_turns = runtime.get("max_turns")
    for key, value in (
        ("forced_compact_at_tokens", compact_at),
        ("forced_compact_keep_recent", keep_recent),
        ("max_turns", max_turns),
    ):
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
            raise ValidationError(f"experiment.common_runtime.{key}: expected integer > 0")

    schedule = experiment.get("schedule")
    if schedule != {
        "kind": "balanced_williams",
        "complete_blocks_only": True,
        "task_order": "sorted",
    }:
        raise ValidationError("experiment.schedule must freeze the balanced_williams contract")
    grading = experiment.get("grading")
    if grading != {"blind": True, "arm_identity_visible_to_grader": False}:
        raise ValidationError("experiment grading must be blind to arm identity")
    invalid = experiment.get("invalid_policy")
    if invalid != {"exclude_from_scoring": True, "abort_after_invalid": True}:
        raise ValidationError("experiment invalid_policy must exclude and abort fail-closed")

    budget = experiment.get("budget")
    if not isinstance(budget, dict):
        raise ValidationError("experiment.budget: expected object")
    if set(budget) != {
        "max_stage_cost_usd",
        "max_stage_tokens",
        "max_aggregate_cost_usd",
        "max_aggregate_tokens",
        "paid_rollouts_enabled",
    }:
        raise ValidationError("experiment.budget contains missing or unknown fields")
    max_stage_cost = budget.get("max_stage_cost_usd")
    max_aggregate_cost = budget.get("max_aggregate_cost_usd")
    for key, value in (
        ("max_stage_cost_usd", max_stage_cost),
        ("max_aggregate_cost_usd", max_aggregate_cost),
    ):
        if (
            not isinstance(value, (int, float))
            or isinstance(value, bool)
            or not math.isfinite(float(value))
            or float(value) <= 0
        ):
            raise ValidationError(f"experiment.budget.{key} must be finite and > 0")
    if float(max_aggregate_cost) > 1000.0 or float(max_stage_cost) > float(max_aggregate_cost):
        raise ValidationError("experiment aggregate budget must be <= $1000 and cover its stage")
    max_stage_tokens = budget.get("max_stage_tokens")
    max_aggregate_tokens = budget.get("max_aggregate_tokens")
    for key, value in (
        ("max_stage_tokens", max_stage_tokens),
        ("max_aggregate_tokens", max_aggregate_tokens),
    ):
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
            raise ValidationError(f"experiment.budget.{key} must be > 0")
    if max_stage_tokens > max_aggregate_tokens:
        raise ValidationError("aggregate token budget must cover its stage")
    if not isinstance(budget.get("paid_rollouts_enabled"), bool):
        raise ValidationError("experiment.budget.paid_rollouts_enabled must be boolean")
    promotion = experiment.get("promotion")
    if not isinstance(promotion, dict) or set(promotion) != {
        "requires_receipt",
        "source_experiment_id",
        "source_experiment",
        "source_experiment_fingerprint",
        "gate",
    }:
        raise ValidationError(
            "experiment.promotion must freeze its receipt, source manifest, fingerprint, and gate"
        )
    expected_rollouts = len(suite["tasks"]) * int(trials) * len(ARM_IDS)
    if stage_id == "calibration":
        expected_gate = {
            "required_valid_rollouts": expected_rollouts,
            "max_invalid_rollouts": 0,
            "require_complete_schedule": True,
            "require_cost_telemetry": True,
            "require_token_telemetry": True,
        }
        if promotion != {
            "requires_receipt": False,
            "source_experiment_id": None,
            "source_experiment": None,
            "source_experiment_fingerprint": None,
            "gate": expected_gate,
        }:
            raise ValidationError("calibration promotion gate is not frozen correctly")
    else:
        if (
            promotion.get("requires_receipt") is not True
            or not isinstance(promotion.get("source_experiment_id"), str)
            or not promotion["source_experiment_id"].strip()
            or not isinstance(promotion.get("source_experiment"), str)
            or not promotion["source_experiment"].strip()
            or not isinstance(promotion.get("source_experiment_fingerprint"), str)
            or len(promotion["source_experiment_fingerprint"]) != 16
            or any(
                char not in "0123456789abcdef"
                for char in promotion["source_experiment_fingerprint"]
            )
            or promotion.get("gate") is not None
        ):
            raise ValidationError(
                "confirmatory stage must freeze one calibration manifest and receipt"
            )
        try:
            source_relative = safe_posix_relative_path(
                promotion["source_experiment"],
                "experiment.promotion.source_experiment",
            )
        except ValidationError as exc:
            raise ValidationError(
                "experiment.promotion.source_experiment must be a safe repository-relative path"
            ) from exc
        source_path = (repo_root / Path(*source_relative.parts)).resolve()
        try:
            source_path.relative_to(repo_root.resolve())
        except ValueError as exc:
            raise ValidationError(
                "experiment.promotion.source_experiment escapes repository root"
            ) from exc
        if source_path.is_symlink() or not source_path.is_file():
            raise ValidationError(
                "experiment.promotion.source_experiment must be a regular file"
            )
        source_experiment = load_json(source_path)
        source_suite_value = source_experiment.get("suite")
        try:
            source_suite_relative = safe_posix_relative_path(
                source_suite_value, "calibration source experiment suite"
            )
        except ValidationError as exc:
            raise ValidationError(
                "calibration source experiment has no safe repository-relative suite"
            ) from exc
        source_suite_path = (
            repo_root / Path(*source_suite_relative.parts)
        ).resolve()
        try:
            source_suite_path.relative_to(repo_root.resolve())
        except ValueError as exc:
            raise ValidationError(
                "calibration source experiment suite escapes repository root"
            ) from exc
        if source_suite_path.is_symlink() or not source_suite_path.is_file():
            raise ValidationError(
                "calibration source experiment suite must be a regular file"
            )
        source_suite = load_json(source_suite_path)
        validate_experiment(source_experiment, repo_root, source_suite)
        source_fingerprint = experiment_fingerprint(
            source_experiment, source_suite
        )
        if (
            source_experiment.get("stage", {}).get("id") != "calibration"
            or source_experiment.get("program_id") != experiment["program_id"]
            or source_experiment.get("experiment_id")
            != promotion["source_experiment_id"]
            or source_fingerprint != promotion["source_experiment_fingerprint"]
        ):
            raise ValidationError(
                "confirmatory promotion source manifest identity or fingerprint mismatch"
            )
    stop_rules = experiment.get("stop_rules")
    if stop_rules != {
        "on_budget_reached": "stop_before_next_rollout",
        "on_invalid_rollout": "checkpoint_then_abort",
        "on_infrastructure_failure": "mark_invalid_then_abort",
    }:
        raise ValidationError("experiment.stop_rules must freeze fail-closed semantics")


def experiment_fingerprint(
    experiment: Mapping[str, Any], suite: Mapping[str, Any]
) -> str:
    payload = stable_json({"experiment": experiment, "suite": suite})
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


def validate_promotion_receipt(
    receipt: Mapping[str, Any],
    experiment: Mapping[str, Any],
    *,
    metacodes_sha256: str,
    tinykg_sha256: str,
    revision: str,
    source_experiment_fingerprint: str,
) -> Tuple[float, int]:
    """Validate a calibration receipt before any confirmatory paid rollout."""
    expected_keys = {
        "schema_version",
        "program_id",
        "source_experiment_id",
        "source_experiment_fingerprint",
        "stage",
        "eligible",
        "gate",
        "usage",
        "source_budget",
        "identity",
        "checkpoint_sha256",
    }
    if set(receipt) != expected_keys:
        raise ValidationError("promotion receipt contains missing or unknown fields")
    if receipt.get("schema_version") != PROMOTION_RECEIPT_SCHEMA_VERSION:
        raise ValidationError("promotion receipt schema version is unsupported")
    if experiment["stage"]["id"] != "confirmatory":
        raise ValidationError("promotion receipts are only valid for confirmatory execution")
    if (
        receipt.get("program_id") != experiment["program_id"]
        or receipt.get("source_experiment_id")
        != experiment["promotion"]["source_experiment_id"]
        or receipt.get("stage") != "calibration"
        or receipt.get("eligible") is not True
    ):
        raise ValidationError("promotion receipt does not authorize this experiment program")
    source_fingerprint = receipt.get("source_experiment_fingerprint")
    if source_fingerprint != source_experiment_fingerprint:
        raise ValidationError("promotion receipt source fingerprint mismatch")
    identity = receipt.get("identity")
    if identity != {
        "metacodes_sha256": metacodes_sha256,
        "tinykg_sha256": tinykg_sha256,
        "harness_revision": revision,
    }:
        raise ValidationError("promotion receipt binary or revision identity mismatch")
    gate = receipt.get("gate")
    if not isinstance(gate, dict) or set(gate) != {
        "required_valid_rollouts",
        "valid_rollouts",
        "invalid_rollouts",
        "complete_schedule",
        "cost_telemetry_rollouts",
        "token_telemetry_rollouts",
    }:
        raise ValidationError("promotion receipt gate fields are invalid")
    required = gate.get("required_valid_rollouts")
    if (
        not isinstance(required, int)
        or isinstance(required, bool)
        or required <= 0
        or gate.get("valid_rollouts") != required
        or gate.get("invalid_rollouts") != 0
        or gate.get("complete_schedule") is not True
        or gate.get("cost_telemetry_rollouts") != required
        or gate.get("token_telemetry_rollouts") != required
    ):
        raise ValidationError("promotion receipt calibration gate did not pass")
    usage = receipt.get("usage")
    if not isinstance(usage, dict) or set(usage) != {"cost_usd", "tokens"}:
        raise ValidationError("promotion receipt usage fields are invalid")
    cost = usage.get("cost_usd")
    tokens = usage.get("tokens")
    if (
        not isinstance(cost, (int, float))
        or isinstance(cost, bool)
        or not math.isfinite(float(cost))
        or float(cost) < 0
        or not isinstance(tokens, int)
        or isinstance(tokens, bool)
        or tokens < 0
    ):
        raise ValidationError("promotion receipt usage must be finite and non-negative")
    source_budget = receipt.get("source_budget")
    if not isinstance(source_budget, dict) or set(source_budget) != {
        "max_stage_cost_usd",
        "max_stage_tokens",
    }:
        raise ValidationError("promotion receipt source budget fields are invalid")
    source_cost_cap = source_budget.get("max_stage_cost_usd")
    source_token_cap = source_budget.get("max_stage_tokens")
    if (
        not isinstance(source_cost_cap, (int, float))
        or isinstance(source_cost_cap, bool)
        or not math.isfinite(float(source_cost_cap))
        or float(source_cost_cap) <= 0
        or not isinstance(source_token_cap, int)
        or isinstance(source_token_cap, bool)
        or source_token_cap <= 0
        or float(cost) >= float(source_cost_cap)
        or tokens >= source_token_cap
    ):
        raise ValidationError("promotion receipt exceeds its calibration stage budget")
    budget = experiment["budget"]
    if (
        float(source_cost_cap) + float(budget["max_stage_cost_usd"])
        > float(budget["max_aggregate_cost_usd"])
        or source_token_cap + int(budget["max_stage_tokens"])
        > int(budget["max_aggregate_tokens"])
    ):
        raise ValidationError("calibration and confirmatory stage caps exceed aggregate budget")
    checkpoint_sha = receipt.get("checkpoint_sha256")
    if not isinstance(checkpoint_sha, dict) or set(checkpoint_sha) != set(ARM_IDS):
        raise ValidationError("promotion receipt must bind all three checkpoints")
    for value in checkpoint_sha.values():
        if (
            not isinstance(value, str)
            or len(value) != 64
            or any(char not in "0123456789abcdef" for char in value)
        ):
            raise ValidationError("promotion receipt checkpoint SHA-256 is invalid")
    return float(cost), tokens


def arm_config_ids(
    experiment: Mapping[str, Any],
    suite: Mapping[str, Any],
    metacodes_sha256: str,
    tinykg_sha256: str,
) -> Dict[str, str]:
    for label, sha256 in (
        ("metacodes", metacodes_sha256),
        ("TinyKG dependency", tinykg_sha256),
    ):
        if len(sha256) != 64 or any(
            char not in "0123456789abcdef" for char in sha256
        ):
            raise ValidationError(f"{label} SHA-256 must contain 64 hex characters")
    fingerprint = experiment_fingerprint(experiment, suite)
    experiment_id = str(experiment["experiment_id"])
    return {
        arm_id: (
            f"{experiment_id}:{arm_id}:{fingerprint}:"
            f"mc-{metacodes_sha256}:kg-{tinykg_sha256}"
        )
        for arm_id in ARM_IDS
    }


def arm_runtime_env(
    experiment: Mapping[str, Any], arm_id: str, tinykg_binary: Path
) -> Dict[str, str]:
    if arm_id not in ARM_IDS:
        raise ValidationError(f"unknown long-horizon arm: {arm_id!r}")
    runtime = experiment["common_runtime"]
    env = {
        "METACODES_LONG_HORIZON_ARM": arm_id,
        "METACODES_FORCE_COMPACT_AT": str(runtime["forced_compact_at_tokens"]),
        "METACODES_FORCE_COMPACT_KEEP": str(runtime["forced_compact_keep_recent"]),
        "METACODES_MAX_TURNS": str(runtime["max_turns"]),
    }
    # All config identities bind the dependency hash, but exposing the path to
    # a baseline would let Bash bypass the typed treatment.
    if arm_id == "tinykg":
        env["METACODES_KG_BIN"] = str(tinykg_binary.resolve())
    return env


def build_dry_run_plan(
    experiment: Dict[str, Any],
    suite: Dict[str, Any],
    *,
    binary: Path,
    tinykg_binary: Path,
    revision: str,
) -> Dict[str, Any]:
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValidationError(f"binary is not executable: {binary}")
    revision = revision.strip()
    if not revision:
        raise ValidationError("multi-arm revision must be non-empty")
    binary_sha256 = hashlib.sha256(binary.read_bytes()).hexdigest()
    tinykg_identity = tinykg_binary_identity(tinykg_binary)
    config_ids = arm_config_ids(
        experiment, suite, binary_sha256, tinykg_identity["sha256"]
    )
    tasks = {task["id"]: task for task in suite["tasks"]}
    task_ids = sorted(tasks)
    schedule = counterbalanced_schedule(ARM_IDS, experiment["trials"])
    rows: List[Dict[str, Any]] = []
    for sequence, (trial, arm_id) in enumerate(schedule):
        order_position = sequence % len(ARM_IDS)
        for task_id in task_ids:
            rows.append(
                {
                    "sequence": len(rows),
                    "trial": trial,
                    "order_position": order_position,
                    "arm_id": arm_id,
                    "task_id": task_id,
                    "timeout_seconds": tasks[task_id]["constraints"]["timeout_seconds"],
                    "harness_config_id": config_ids[arm_id],
                    "runtime_env": arm_runtime_env(
                        experiment, arm_id, Path(tinykg_identity["path"])
                    ),
                }
            )
    plan = {
        "schema_version": 1,
        "program_id": experiment["program_id"],
        "experiment_id": experiment["experiment_id"],
        "stage": experiment["stage"],
        "experiment_fingerprint": experiment_fingerprint(experiment, suite),
        "model": experiment["model"],
        "execution_identity": {
            "metacodes": {
                "path": str(binary.resolve()),
                "sha256": binary_sha256,
            },
            "tinykg": tinykg_identity,
            "revision": revision,
        },
        "trials": experiment["trials"],
        "task_ids": task_ids,
        "arm_config_ids": config_ids,
        "rollout_count": len(rows),
        "paid_rollouts_enabled": experiment["budget"]["paid_rollouts_enabled"],
        "promotion_receipt_required": experiment["promotion"]["requires_receipt"],
        "rows": rows,
    }
    plan["plan_fingerprint"] = hashlib.sha256(
        stable_json(plan).encode("utf-8")
    ).hexdigest()[:16]
    return plan
