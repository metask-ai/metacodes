"""Machine-verifiable long-horizon multi-arm experiment contract."""

from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Mapping, Sequence, Tuple

from .model import ValidationError, stable_json, validate_suite


EXPERIMENT_SCHEMA_VERSION = 1
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
        "experiment_id",
        "suite",
        "model",
        "trials",
        "arms",
        "common_runtime",
        "schedule",
        "grading",
        "invalid_policy",
        "budget",
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
    }
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
    suite_path = _non_empty_string(experiment.get("suite"), "experiment.suite")
    resolved_suite = (repo_root / suite_path).resolve()
    try:
        resolved_suite.relative_to(repo_root.resolve())
    except ValueError as exc:
        raise ValidationError("experiment.suite escapes repository root") from exc
    if not resolved_suite.is_file():
        raise ValidationError(f"experiment.suite does not exist: {suite_path}")
    validate_suite(suite, repo_root)
    if not 3 <= len(suite["tasks"]) <= 5:
        raise ValidationError("long-horizon experiment suite must contain 3-5 tasks")
    for task in suite["tasks"]:
        if task["grader"] != {
            "kind": "deterministic_workspace",
            "version": "long-horizon-v1",
        }:
            raise ValidationError(
                f"{task['id']}: long-horizon grader must be deterministic_workspace/long-horizon-v1"
            )
        observed_checks = {check["type"] for check in task["success"]["checks"]}
        if not observed_checks <= BLIND_WORKSPACE_CHECKS:
            raise ValidationError(
                f"{task['id']}: blind grading may inspect workspace artifacts only"
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
        "max_cumulative_cost_usd",
        "max_cumulative_tokens",
        "paid_rollouts_enabled",
    }:
        raise ValidationError("experiment.budget contains missing or unknown fields")
    max_cost = budget.get("max_cumulative_cost_usd")
    max_tokens = budget.get("max_cumulative_tokens")
    if (
        not isinstance(max_cost, (int, float))
        or isinstance(max_cost, bool)
        or not 0 < float(max_cost) <= 1000.0
    ):
        raise ValidationError("experiment budget must be within the $1000 hard ceiling")
    if not isinstance(max_tokens, int) or isinstance(max_tokens, bool) or max_tokens <= 0:
        raise ValidationError("experiment.budget.max_cumulative_tokens must be > 0")
    if not isinstance(budget.get("paid_rollouts_enabled"), bool):
        raise ValidationError("experiment.budget.paid_rollouts_enabled must be boolean")
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
        "experiment_id": experiment["experiment_id"],
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
        "rows": rows,
    }
    plan["plan_fingerprint"] = hashlib.sha256(
        stable_json(plan).encode("utf-8")
    ).hexdigest()[:16]
    return plan
