"""Repeated, order-balanced native E2E runner for paired harness experiments."""

from __future__ import annotations

import os
import subprocess
import fnmatch
from collections import Counter
from pathlib import Path
from typing import Any, Dict, List, Mapping, Sequence, Tuple

from .e2e_adapter import comparison_fingerprints, import_run
from .model import ValidationError, load_rollouts, write_rollouts


TOKEN_METRICS = (
    "input_tokens",
    "output_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
)


def _require_budget(
    collected: Mapping[str, Sequence[Dict[str, Any]]],
    *,
    used_cost_usd: float,
    used_tokens: int,
    max_cumulative_cost_usd: float | None,
    max_cumulative_tokens: int | None,
) -> None:
    rollouts = [item for variant in collected.values() for item in variant]
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
        identity = comparison_fingerprints(
            task,
            repo_root,
            model_provider=model_provider,
            model_id=model_id,
            harness_config_id=variant,
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
            "harness_config_id": variant,
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
) -> Path:
    runs_dir = repo_root / "tests/e2e/runs"
    before = {path.resolve() for path in runs_dir.iterdir() if path.is_dir()} if runs_dir.exists() else set()
    env = {
        **os.environ,
        "E2E_BIN_PATH": str(binary.resolve()),
        "E2E_KEEP": "all",
        "E2E_TRIAL": str(trial),
        "E2E_RUN_LABEL": variant,
        "E2E_HARNESS_CONFIG_ID": variant,
        "E2E_MODEL_PROVIDER": model_provider,
        "E2E_MODEL": model_id,
        "E2E_EVAL_SUITE": str(suite_path.resolve()),
        "E2E_HARNESS_REVISION": harness_revision,
    }
    completed = subprocess.run(
        [str(repo_root / "tests/e2e/run_e2e.sh"), scenario_glob],
        cwd=repo_root,
        env=env,
        check=False,
    )
    # run_e2e.sh uses exit 2 specifically for deterministic EXPECT_HARD
    # failures.  That is a valid scored rollout (outcome=fail), not an
    # infrastructure failure.  The adapter still marks a timed-out/crashed
    # metacodes process invalid from the per-scenario exit code in REPORT.md.
    if completed.returncode not in (0, 2):
        raise ValidationError(
            f"{variant} trial {trial}: E2E runner exited {completed.returncode}"
        )
    after = {path.resolve() for path in runs_dir.iterdir() if path.is_dir()}
    created = sorted(after - before)
    if len(created) != 1:
        raise ValidationError(
            f"{variant} trial {trial}: expected one new run directory, found {created}"
        )
    return created[0]


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
    if budget_used_cost_usd < 0 or budget_used_tokens < 0:
        raise ValidationError("budget usage offsets must be non-negative")
    if max_cumulative_cost_usd is not None and max_cumulative_cost_usd <= 0:
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
                    f"{variant} trial {trial} task {task_id}: expected one execution-grounded rollout"
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
