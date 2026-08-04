"""Repeated, order-balanced native E2E runner for paired harness experiments."""

from __future__ import annotations

import fnmatch
import hashlib
import math
import os
import subprocess
from collections import Counter
from pathlib import Path
from typing import Any, Dict, List, Mapping, Sequence, Tuple

from .e2e_adapter import comparison_fingerprints, import_run
from .experiment import (
    ARM_IDS,
    arm_config_ids,
    arm_runtime_env,
    counterbalanced_schedule,
    tinykg_binary_identity,
    validate_experiment,
)
from .model import ValidationError, load_rollouts, write_rollouts


TOKEN_METRICS = (
    "input_tokens",
    "output_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
)
RUNTIME_ENV_ALLOWLIST = frozenset(
    {
        "METACODES_LONG_HORIZON_ARM",
        "METACODES_FORCE_COMPACT_AT",
        "METACODES_FORCE_COMPACT_KEEP",
        "METACODES_MAX_TURNS",
        "METACODES_KG_BIN",
    }
)


class InfrastructureRunError(ValidationError):
    """E2E orchestration failed after producing one auditable run directory."""

    def __init__(self, variant: str, trial: int, returncode: int, run_dir: Path):
        self.variant = variant
        self.trial = trial
        self.returncode = returncode
        self.run_dir = run_dir
        super().__init__(
            f"{variant} trial {trial}: E2E runner exited {returncode}; "
            f"invalid evidence retained at {run_dir}"
        )


def _runner_env() -> Dict[str, str]:
    """Remove host treatment knobs before applying the frozen runtime env."""
    return {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("METACODES_")
        and not key.startswith("TINYKG_")
        and not key.startswith("E2E_")
        and not key.startswith("CLAUDE_CODE_")
        and key != "RG_BIN"
    }


def _require_budget(
    collected: Mapping[str, Sequence[Dict[str, Any]]],
    *,
    used_cost_usd: float,
    used_tokens: int,
    max_cumulative_cost_usd: float | None,
    max_cumulative_tokens: int | None,
) -> None:
    rollouts = [item for variant in collected.values() for item in variant]
    if max_cumulative_cost_usd is not None:
        missing_cost = [
            item.get("run_id", "unknown")
            for item in rollouts
            if item.get("metrics", {}).get("cost_usd") is None
        ]
        if missing_cost:
            raise ValidationError(
                f"cost budget telemetry missing for rollouts {missing_cost}; fail-closed"
            )
    if max_cumulative_tokens is not None:
        missing_tokens = [
            (item.get("run_id", "unknown"), key)
            for item in rollouts
            for key in TOKEN_METRICS
            if item.get("metrics", {}).get(key) is None
        ]
        if missing_tokens:
            raise ValidationError(
                f"token budget telemetry missing for rollouts {missing_tokens}; fail-closed"
            )
    cumulative_cost = used_cost_usd + sum(
        float(item.get("metrics", {}).get("cost_usd") or 0.0) for item in rollouts
    )
    cumulative_tokens = used_tokens + sum(
        int(item.get("metrics", {}).get(key) or 0)
        for item in rollouts
        for key in TOKEN_METRICS
    )
    if (
        max_cumulative_cost_usd is not None
        and cumulative_cost >= max_cumulative_cost_usd
    ):
        raise ValidationError(
            f"cumulative cost budget reached: ${cumulative_cost:.6f} >= "
            f"${max_cumulative_cost_usd:.6f}; fail-closed"
        )
    if max_cumulative_tokens is not None and cumulative_tokens >= max_cumulative_tokens:
        raise ValidationError(
            f"cumulative token budget reached: {cumulative_tokens} >= "
            f"{max_cumulative_tokens}; fail-closed"
        )


def _require_scoring_rollout(rollout: Dict[str, Any], *, variant: str) -> None:
    if not rollout.get("judgement", {}).get("valid_for_scoring", False):
        task_id = rollout.get("task_id", "unknown")
        trial = rollout.get("trial", "unknown")
        reasons = rollout.get("execution", {}).get("invalid_reasons", [])
        evaluator = rollout.get("evaluator", {}).get("status", "unknown")
        raise ValidationError(
            f"{variant} rollout {(task_id, trial)!r} is not valid for scoring; "
            f"execution_reasons={reasons}, evaluator={evaluator}; fail-closed"
        )


def alternating_schedule(trials: int) -> List[Tuple[int, str]]:
    if trials <= 0:
        raise ValidationError("trials must be > 0")
    schedule: List[Tuple[int, str]] = []
    for trial in range(trials):
        order = ("baseline", "candidate") if trial % 2 == 0 else ("candidate", "baseline")
        schedule.extend((trial, variant) for variant in order)
    return schedule


def scenario_selector(task_ids: Sequence[str]) -> str:
    """Build the exact comma-separated selector understood by run_e2e.sh."""
    if not task_ids:
        raise ValidationError("scenario selector requires at least one task")
    if any("," in task_id for task_id in task_ids):
        raise ValidationError("scenario ids cannot contain commas")
    return ",".join(sorted(task_ids))


def _load_checkpoint(
    path: Path,
    *,
    variant: str,
    suite: Dict[str, Any],
    repo_root: Path,
    binary: Path,
    trials: int,
    expected_tasks: Mapping[str, Dict[str, Any]],
    model_provider: str,
    model_id: str,
    harness_revision: str,
    harness_config_id: str | None = None,
) -> List[Dict[str, Any]]:
    if not path.exists():
        return []
    rollouts = load_rollouts(path)
    keys = [(item["task_id"], item["trial"]) for item in rollouts]
    duplicates = sorted(key for key, count in Counter(keys).items() if count > 1)
    if duplicates:
        raise ValidationError(f"{variant} checkpoint has duplicate task/trial keys: {duplicates}")
    for rollout in rollouts:
        _require_scoring_rollout(rollout, variant=variant)
        task_id = rollout["task_id"]
        trial = rollout["trial"]
        if task_id not in expected_tasks or trial < 0 or trial >= trials:
            raise ValidationError(
                f"{variant} checkpoint contains out-of-scope key {(task_id, trial)!r}"
            )
        task = expected_tasks[task_id]
        expected_config_id = harness_config_id or variant
        identity = comparison_fingerprints(
            task,
            repo_root,
            model_provider=model_provider,
            model_id=model_id,
            harness_config_id=expected_config_id,
            harness_revision=harness_revision,
            permission_mode=task["constraints"]["permission_mode"],
            binary_path=binary,
        )
        actual_identity = {
            "suite_id": rollout.get("suite_id"),
            "task_fingerprint": rollout.get("task_fingerprint"),
            "task_fingerprint_provenance": rollout.get("task_fingerprint_provenance"),
            "model_provider": rollout.get("model", {}).get("provider"),
            "model_id": rollout.get("model", {}).get("id"),
            "model_fingerprint": rollout.get("model", {}).get("fingerprint"),
            "harness_config_id": rollout.get("harness", {}).get("config_id"),
            "harness_revision": rollout.get("harness", {}).get("revision"),
            "harness_fingerprint": rollout.get("harness", {}).get("fingerprint"),
            "permission_mode": rollout.get("harness", {}).get("permission_mode"),
            "environment_fingerprint": rollout.get("harness", {}).get("environment_fingerprint"),
            "grader_fingerprint": rollout.get("evaluator", {}).get("fingerprint"),
        }
        expected_identity = {
            "suite_id": suite["suite_id"],
            "task_fingerprint": identity["task_fingerprint"],
            "task_fingerprint_provenance": "recorded_at_execution",
            "model_provider": model_provider,
            "model_id": model_id,
            "model_fingerprint": identity["model_fingerprint"],
            "harness_config_id": expected_config_id,
            "harness_revision": harness_revision,
            "harness_fingerprint": identity["harness_fingerprint"],
            "permission_mode": identity["permission_mode"],
            "environment_fingerprint": identity["environment_fingerprint"],
            "grader_fingerprint": identity["grader_fingerprint"],
        }
        mismatches = sorted(
            key for key in expected_identity if actual_identity[key] != expected_identity[key]
        )
        if mismatches:
            raise ValidationError(
                f"{variant} checkpoint {(task_id, trial)!r} identity mismatch: {mismatches}"
            )
    return rollouts


def _run_once(
    repo_root: Path,
    binary: Path,
    variant: str,
    trial: int,
    scenario_glob: str,
    model_provider: str,
    model_id: str,
    suite_path: Path,
    harness_revision: str,
    *,
    harness_config_id: str | None = None,
    runtime_env: Mapping[str, str] | None = None,
    allow_invalid_run: bool = False,
    timeout_seconds: int | None = None,
) -> Path:
    runs_dir = repo_root / "tests/e2e/runs"
    before = (
        {path.resolve() for path in runs_dir.iterdir() if path.is_dir()}
        if runs_dir.exists()
        else set()
    )
    if runtime_env is not None:
        unknown = sorted(set(runtime_env) - RUNTIME_ENV_ALLOWLIST)
        if unknown:
            raise ValidationError(f"runtime environment contains forbidden keys: {unknown}")
        if not all(isinstance(value, str) and value for value in runtime_env.values()):
            raise ValidationError("runtime environment values must be non-empty strings")
    if timeout_seconds is not None and (
        not isinstance(timeout_seconds, int)
        or isinstance(timeout_seconds, bool)
        or timeout_seconds <= 0
    ):
        raise ValidationError("E2E timeout must be an integer > 0")
    env = {
        **_runner_env(),
        "E2E_BIN_PATH": str(binary.resolve()),
        "E2E_KEEP": "all",
        "E2E_TRIAL": str(trial),
        # The model sees its cwd; embedding baseline/candidate/arm there would
        # disclose the experimental label outside the intended treatment.
        "E2E_RUN_LABEL": "evaluation",
        "E2E_HARNESS_CONFIG_ID": harness_config_id or variant,
        "E2E_MODEL_PROVIDER": model_provider,
        "E2E_MODEL": model_id,
        "E2E_EVAL_SUITE": str(suite_path.resolve()),
        "E2E_HARNESS_REVISION": harness_revision,
    }
    if runtime_env is not None:
        env.update(runtime_env)
    if timeout_seconds is not None:
        env["E2E_TIMEOUT"] = str(timeout_seconds)
    completed = subprocess.run(
        [str(repo_root / "tests/e2e/run_e2e.sh"), scenario_glob],
        cwd=repo_root,
        env=env,
        check=False,
    )
    after = {path.resolve() for path in runs_dir.iterdir() if path.is_dir()}
    created = sorted(after - before)
    # run_e2e.sh uses exit 2 specifically for deterministic EXPECT_HARD
    # failures.  That is a valid scored rollout (outcome=fail), not an
    # infrastructure failure.  The adapter still marks a timed-out/crashed
    # metacodes process invalid from the per-scenario exit code in REPORT.md.
    if completed.returncode not in (0, 2):
        if allow_invalid_run and len(created) == 1:
            raise InfrastructureRunError(variant, trial, completed.returncode, created[0])
        raise ValidationError(
            f"{variant} trial {trial}: E2E runner exited {completed.returncode}; "
            f"expected one evidence directory, found {created}"
        )
    if len(created) != 1:
        raise ValidationError(
            f"{variant} trial {trial}: expected one new run directory, found {created}"
        )
    return created[0]


def _require_sha256(path: Path, expected: str, label: str) -> None:
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected:
        raise ValidationError(
            f"{label} changed after experiment identity was frozen: "
            f"expected {expected}, observed {actual}"
        )


def _mark_infrastructure_invalid(
    rollout: Dict[str, Any],
    *,
    task: Dict[str, Any],
    repo_root: Path,
    binary: Path,
    variant: str,
    trial: int,
    returncode: int,
    model_provider: str,
    model_id: str,
    harness_config_id: str,
    harness_revision: str,
    suite_id: str,
) -> None:
    """Normalize runner failure into an auditable, unscorable checkpoint."""
    identity = comparison_fingerprints(
        task,
        repo_root,
        model_provider=model_provider,
        model_id=model_id,
        harness_config_id=harness_config_id,
        harness_revision=harness_revision,
        permission_mode=task["constraints"]["permission_mode"],
        binary_path=binary,
    )
    rollout["run_id"] = f"{variant}:{task['id']}:{trial}:infrastructure"
    rollout["suite_id"] = suite_id
    rollout["task_id"] = task["id"]
    rollout["task_fingerprint"] = identity["task_fingerprint"]
    rollout["task_fingerprint_provenance"] = "runner_frozen_before_execution"
    rollout["trial"] = trial
    rollout["model"] = {
        "provider": model_provider,
        "id": model_id,
        "fingerprint": identity["model_fingerprint"],
    }
    rollout["harness"] = {
        "config_id": harness_config_id,
        "revision": harness_revision,
        "fingerprint": identity["harness_fingerprint"],
        "permission_mode": identity["permission_mode"],
        "environment_fingerprint": identity["environment_fingerprint"],
    }
    rollout["evaluator"]["fingerprint"] = identity["grader_fingerprint"]
    rollout["readiness"]["status"] = "fail"
    rollout["readiness"]["checks"].append(
        {
            "name": "e2e_runner_exit",
            "passed": False,
            "detail": f"runner_exit_code={returncode}",
        }
    )
    rollout["execution"]["status"] = "invalid"
    rollout["execution"]["exit_code"] = returncode
    reasons = rollout["execution"].setdefault("invalid_reasons", [])
    reason = f"e2e_runner_exit:{returncode}"
    if reason not in reasons:
        reasons.append(reason)
    rollout["judgement"]["valid_for_scoring"] = False
    rollout["judgement"]["trustworthy_success"] = False
    rollout["attribution"].append(
        {
            "source": "L",
            "code": "e2e_runner_infrastructure_failure",
            "count": 1,
            "confidence": 1.0,
        }
    )


def _infrastructure_import_failure(
    task: Dict[str, Any], run_dir: Path, detail: str
) -> Dict[str, Any]:
    """Create a schema-valid invalid record when partial artifacts cannot import."""
    return {
        "schema_version": 1,
        "run_id": "pending-infrastructure-normalization",
        "suite_id": "pending",
        "task_id": task["id"],
        "task_fingerprint": "pending",
        "task_fingerprint_provenance": "runner_frozen_before_execution",
        "trial": 0,
        "layers": task["layers"],
        "model": {"provider": "pending", "id": "pending"},
        "harness": {"config_id": "pending", "revision": "pending"},
        "readiness": {
            "status": "fail",
            "checks": [
                {
                    "name": "evidence_import",
                    "passed": False,
                    "detail": detail,
                }
            ],
        },
        "execution": {
            "status": "invalid",
            "exit_code": None,
            "invalid_reasons": ["evidence_import_failed"],
        },
        "outcome": {"status": "unscored", "checks": []},
        "trajectory": {"status": "unscored", "checks": [], "tool_failures": []},
        "evaluator": {
            "status": "invalid",
            "kind": task["grader"]["kind"],
            "version": task["grader"]["version"],
            "fingerprint": "pending",
            "errors": [detail],
        },
        "judgement": {"valid_for_scoring": False, "trustworthy_success": False},
        "metrics": {},
        "attribution": [],
        "artifacts": {"run_dir": str(run_dir)},
    }


def run_paired(
    suite: Dict[str, Any],
    repo_root: Path,
    baseline_binary: Path,
    candidate_binary: Path,
    *,
    trials: int,
    scenario_glob: str,
    model_provider: str,
    model_id: str,
    baseline_output: Path,
    candidate_output: Path,
    baseline_revision: str,
    candidate_revision: str,
    suite_path: Path | None = None,
    budget_used_cost_usd: float = 0.0,
    budget_used_tokens: int = 0,
    max_cumulative_cost_usd: float | None = None,
    max_cumulative_tokens: int | None = None,
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    if (
        not math.isfinite(budget_used_cost_usd)
        or budget_used_cost_usd < 0
        or budget_used_tokens < 0
    ):
        raise ValidationError("budget usage offsets must be non-negative")
    if max_cumulative_cost_usd is not None and (
        not math.isfinite(max_cumulative_cost_usd) or max_cumulative_cost_usd <= 0
    ):
        raise ValidationError("max cumulative cost must be > 0")
    if max_cumulative_tokens is not None and max_cumulative_tokens <= 0:
        raise ValidationError("max cumulative tokens must be > 0")
    for binary in (baseline_binary, candidate_binary):
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValidationError(f"binary is not executable: {binary}")
    binaries = {"baseline": baseline_binary, "candidate": candidate_binary}
    effective_suite_path = suite_path or (repo_root / "evals/suites/core-e2e.json")
    if not effective_suite_path.is_file():
        raise ValidationError(f"evaluation suite file does not exist: {effective_suite_path}")
    expected_tasks = {
        task["id"]: task for task in suite["tasks"] if fnmatch.fnmatch(task["id"], scenario_glob)
    }
    if not expected_tasks:
        raise ValidationError(f"scenario glob matches no scored suite tasks: {scenario_glob}")
    revisions = {
        "baseline": baseline_revision.strip(),
        "candidate": candidate_revision.strip(),
    }
    for variant, revision in revisions.items():
        if not revision:
            raise ValidationError(f"{variant} revision must be non-empty")
    outputs = {"baseline": baseline_output, "candidate": candidate_output}
    collected = {
        variant: _load_checkpoint(
            outputs[variant],
            variant=variant,
            suite=suite,
            repo_root=repo_root,
            binary=binaries[variant],
            trials=trials,
            expected_tasks=expected_tasks,
            model_provider=model_provider,
            model_id=model_id,
            harness_revision=revisions[variant],
        )
        for variant in ("baseline", "candidate")
    }
    completed_keys = {
        variant: {(item["task_id"], item["trial"]) for item in collected[variant]}
        for variant in ("baseline", "candidate")
    }
    _require_budget(
        collected,
        used_cost_usd=budget_used_cost_usd,
        used_tokens=budget_used_tokens,
        max_cumulative_cost_usd=max_cumulative_cost_usd,
        max_cumulative_tokens=max_cumulative_tokens,
    )
    for trial, variant in alternating_schedule(trials):
        for task_id in sorted(expected_tasks):
            if (task_id, trial) in completed_keys[variant]:
                continue
            _require_budget(
                collected,
                used_cost_usd=budget_used_cost_usd,
                used_tokens=budget_used_tokens,
                max_cumulative_cost_usd=max_cumulative_cost_usd,
                max_cumulative_tokens=max_cumulative_tokens,
            )
            run_dir = _run_once(
                repo_root,
                binaries[variant],
                variant,
                trial,
                scenario_selector([task_id]),
                model_provider,
                model_id,
                effective_suite_path,
                revisions[variant],
                timeout_seconds=expected_tasks[task_id]["constraints"]["timeout_seconds"],
            )
            rollouts = import_run(suite, repo_root, run_dir)
            selected = [
                rollout
                for rollout in rollouts
                if rollout["task_id"] == task_id
                and rollout["trial"] == trial
                and rollout["task_fingerprint_provenance"] == "recorded_at_execution"
            ]
            if len(selected) != 1:
                raise ValidationError(
                    f"{variant} trial {trial} task {task_id}: expected one "
                    "execution-grounded rollout"
                )
            collected[variant].extend(selected)
            completed_keys[variant].add((task_id, trial))
            # Single-task, atomic checkpoint: completed paid rollouts survive interruption.
            write_rollouts(outputs[variant], collected[variant])
            # Preserve the invalid evidence above, then stop before another
            # paid rollout.  Resume also fails closed in _load_checkpoint.
            _require_scoring_rollout(selected[0], variant=variant)
            _require_budget(
                collected,
                used_cost_usd=budget_used_cost_usd,
                used_tokens=budget_used_tokens,
                max_cumulative_cost_usd=max_cumulative_cost_usd,
                max_cumulative_tokens=max_cumulative_tokens,
            )
    return collected["baseline"], collected["candidate"]


def run_multi_arm(
    experiment: Dict[str, Any],
    suite: Dict[str, Any],
    repo_root: Path,
    binary: Path,
    *,
    tinykg_binary: Path,
    revision: str,
    output_dir: Path,
    suite_path: Path,
    allow_paid_rollouts: bool,
    budget_used_cost_usd: float = 0.0,
    budget_used_tokens: int = 0,
) -> Dict[str, List[Dict[str, Any]]]:
    """Execute a resumable three-arm experiment from its frozen contract."""
    validate_experiment(experiment, repo_root, suite)
    if not allow_paid_rollouts:
        raise ValidationError("multi-arm execution requires explicit --allow-paid-rollouts")
    if not experiment["budget"]["paid_rollouts_enabled"]:
        raise ValidationError(
            "experiment contract has paid_rollouts_enabled=false; deterministic gates "
            "must pass before editing the contract"
        )
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValidationError(f"binary is not executable: {binary}")
    revision = revision.strip()
    if not revision:
        raise ValidationError("multi-arm revision must be non-empty")
    if not suite_path.is_file():
        raise ValidationError(f"evaluation suite file does not exist: {suite_path}")
    expected_suite_path = (repo_root / experiment["suite"]).resolve()
    if suite_path.resolve() != expected_suite_path:
        raise ValidationError(
            "multi-arm suite path does not match the frozen experiment contract"
        )
    if (
        not math.isfinite(budget_used_cost_usd)
        or budget_used_cost_usd < 0
        or budget_used_tokens < 0
    ):
        raise ValidationError("budget usage offsets must be non-negative")

    metacodes_sha256 = hashlib.sha256(binary.read_bytes()).hexdigest()
    tinykg_identity = tinykg_binary_identity(tinykg_binary)
    expected_tasks = {task["id"]: task for task in suite["tasks"]}
    config_ids = arm_config_ids(
        experiment, suite, metacodes_sha256, tinykg_identity["sha256"]
    )
    outputs = {arm_id: output_dir / f"{arm_id}.jsonl" for arm_id in ARM_IDS}
    collected = {
        arm_id: _load_checkpoint(
            outputs[arm_id],
            variant=arm_id,
            suite=suite,
            repo_root=repo_root,
            binary=binary,
            trials=experiment["trials"],
            expected_tasks=expected_tasks,
            model_provider=experiment["model"]["provider"],
            model_id=experiment["model"]["id"],
            harness_revision=revision,
            harness_config_id=config_ids[arm_id],
        )
        for arm_id in ARM_IDS
    }
    completed_keys = {
        arm_id: {(item["task_id"], item["trial"]) for item in collected[arm_id]}
        for arm_id in ARM_IDS
    }
    budget = experiment["budget"]
    _require_budget(
        collected,
        used_cost_usd=budget_used_cost_usd,
        used_tokens=budget_used_tokens,
        max_cumulative_cost_usd=float(budget["max_cumulative_cost_usd"]),
        max_cumulative_tokens=int(budget["max_cumulative_tokens"]),
    )
    output_dir.mkdir(parents=True, exist_ok=True)
    for trial, arm_id in counterbalanced_schedule(ARM_IDS, experiment["trials"]):
        for task_id in sorted(expected_tasks):
            if (task_id, trial) in completed_keys[arm_id]:
                continue
            _require_budget(
                collected,
                used_cost_usd=budget_used_cost_usd,
                used_tokens=budget_used_tokens,
                max_cumulative_cost_usd=float(budget["max_cumulative_cost_usd"]),
                max_cumulative_tokens=int(budget["max_cumulative_tokens"]),
            )
            _require_sha256(binary, metacodes_sha256, "metacodes binary")
            _require_sha256(
                Path(tinykg_identity["path"]),
                tinykg_identity["sha256"],
                "TinyKG binary",
            )
            infrastructure_error: InfrastructureRunError | None = None
            try:
                run_dir = _run_once(
                    repo_root,
                    binary,
                    arm_id,
                    trial,
                    scenario_selector([task_id]),
                    experiment["model"]["provider"],
                    experiment["model"]["id"],
                    suite_path,
                    revision,
                    harness_config_id=config_ids[arm_id],
                    runtime_env=arm_runtime_env(
                        experiment, arm_id, Path(tinykg_identity["path"])
                    ),
                    allow_invalid_run=True,
                    timeout_seconds=expected_tasks[task_id]["constraints"]["timeout_seconds"],
                )
            except InfrastructureRunError as exc:
                infrastructure_error = exc
                run_dir = exc.run_dir
            if infrastructure_error is None:
                # Catch replacement during the paid rollout, including the
                # final sample where there is no subsequent preflight.
                _require_sha256(binary, metacodes_sha256, "metacodes binary")
                _require_sha256(
                    Path(tinykg_identity["path"]),
                    tinykg_identity["sha256"],
                    "TinyKG binary",
                )
            import_error: ValidationError | None = None
            try:
                imported = import_run(suite, repo_root, run_dir)
            except ValidationError as exc:
                if infrastructure_error is None:
                    raise
                imported = []
                import_error = exc
            if infrastructure_error is None:
                selected = [
                    rollout
                    for rollout in imported
                    if rollout["task_id"] == task_id
                    and rollout["trial"] == trial
                    and rollout["task_fingerprint_provenance"] == "recorded_at_execution"
                ]
            else:
                selected = [rollout for rollout in imported if rollout["task_id"] == task_id]
                if len(selected) != 1:
                    detail = (
                        str(import_error)
                        if import_error is not None
                        else f"expected one partial rollout, observed {len(selected)}"
                    )
                    selected = [
                        _infrastructure_import_failure(
                            expected_tasks[task_id], run_dir, detail
                        )
                    ]
                _mark_infrastructure_invalid(
                    selected[0],
                    task=expected_tasks[task_id],
                    repo_root=repo_root,
                    binary=binary,
                    variant=arm_id,
                    trial=trial,
                    returncode=infrastructure_error.returncode,
                    model_provider=experiment["model"]["provider"],
                    model_id=experiment["model"]["id"],
                    harness_config_id=config_ids[arm_id],
                    harness_revision=revision,
                    suite_id=suite["suite_id"],
                )
            if len(selected) != 1:
                raise ValidationError(
                    f"{arm_id} trial {trial} task {task_id}: expected one "
                    "execution-grounded rollout"
                )
            collected[arm_id].extend(selected)
            completed_keys[arm_id].add((task_id, trial))
            write_rollouts(outputs[arm_id], collected[arm_id])
            if infrastructure_error is not None:
                raise infrastructure_error
            _require_scoring_rollout(selected[0], variant=arm_id)
            _require_budget(
                collected,
                used_cost_usd=budget_used_cost_usd,
                used_tokens=budget_used_tokens,
                max_cumulative_cost_usd=float(budget["max_cumulative_cost_usd"]),
                max_cumulative_tokens=int(budget["max_cumulative_tokens"]),
            )
    return collected
