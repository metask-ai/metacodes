"""Repeated, order-balanced native E2E runner for paired harness experiments."""

from __future__ import annotations

import fnmatch
import hashlib
import math
import os
import subprocess
from collections import Counter
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Sequence, Tuple

from .e2e_adapter import comparison_fingerprints, import_run
from .experiment import (
    ARM_IDS,
    arm_config_ids,
    arm_runtime_env,
    counterbalanced_schedule,
    fixed_rollout_budget,
    formal_kernel_identity,
    tinykg_binary_identity,
    validate_experiment,
)
from .memory_budget_journal import (
    BudgetAuthority,
    BudgetJournal,
    BudgetTransaction,
    usd_to_microusd,
    usd_to_microusd_ceiling,
)
from .memory_agent_runtime_pilot import _load_api_key
from .model import ValidationError, load_rollouts, stable_json, write_rollouts
from .promotion import validate_calibration_bundle
from .treatment_activation import (
    attach_treatment_activation,
    reverify_treatment_activation,
)


TOKEN_METRICS = (
    "input_tokens",
    "output_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
)
BudgetFaultHook = Callable[[str, Mapping[str, Any]], None]
RUNTIME_ENV_ALLOWLIST = frozenset(
    {
        "METACODES_LONG_HORIZON_ARM",
        "METACODES_FORCE_COMPACT_AT",
        "METACODES_FORCE_COMPACT_KEEP",
        "METACODES_MAX_TURNS",
        "METACODES_KG_BIN",
        "METACODES_FORMAL_KERNEL_PATH",
        "METACODES_FORMAL_KERNEL_SHA256",
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


def _require_multi_budget(
    collected: Mapping[str, Sequence[Dict[str, Any]]],
    budget: Mapping[str, Any],
    *,
    stage_prior_cost_usd: float,
    stage_prior_tokens: int,
    aggregate_prior_cost_usd: float,
    aggregate_prior_tokens: int,
) -> None:
    """Enforce stage and aggregate caps including earlier failed attempts."""
    _require_budget(
        collected,
        used_cost_usd=stage_prior_cost_usd,
        used_tokens=stage_prior_tokens,
        max_cumulative_cost_usd=float(budget["max_stage_cost_usd"]),
        max_cumulative_tokens=int(budget["max_stage_tokens"]),
    )
    _require_budget(
        collected,
        used_cost_usd=aggregate_prior_cost_usd,
        used_tokens=aggregate_prior_tokens,
        max_cumulative_cost_usd=float(budget["max_aggregate_cost_usd"]),
        max_cumulative_tokens=int(budget["max_aggregate_tokens"]),
    )


def _remaining_multi_budget(
    collected: Mapping[str, Sequence[Dict[str, Any]]],
    budget: Mapping[str, Any],
    *,
    stage_prior_cost_usd: float,
    stage_prior_tokens: int,
    aggregate_prior_cost_usd: float,
    aggregate_prior_tokens: int,
) -> tuple[float, int]:
    """Return the smaller authenticated stage/aggregate allowance.

    Call only after `_require_multi_budget`: missing telemetry and exhausted
    caps must already have failed closed. The returned allowance is sealed into
    native runtime metadata so every invocation and compact request in the
    rollout shares one execution-time meter.
    """
    rollouts = [item for variant in collected.values() for item in variant]
    observed_cost = sum(float(item["metrics"]["cost_usd"]) for item in rollouts)
    observed_tokens = sum(
        int(item["metrics"][key]) for item in rollouts for key in TOKEN_METRICS
    )
    remaining_cost = min(
        float(budget["max_stage_cost_usd"])
        - stage_prior_cost_usd
        - observed_cost,
        float(budget["max_aggregate_cost_usd"])
        - aggregate_prior_cost_usd
        - observed_cost,
    )
    remaining_tokens = min(
        int(budget["max_stage_tokens"])
        - stage_prior_tokens
        - observed_tokens,
        int(budget["max_aggregate_tokens"])
        - aggregate_prior_tokens
        - observed_tokens,
    )
    if not math.isfinite(remaining_cost) or remaining_cost <= 0 or remaining_tokens <= 0:
        raise ValidationError("runtime rollout budget is exhausted; fail-closed")
    return remaining_cost, remaining_tokens


def _require_runtime_budget_provenance(
    rollout: Mapping[str, Any],
    *,
    max_metered_tokens: int,
    max_cost_usd: float,
    require_usage: bool = True,
) -> None:
    """Bind the normalized checkpoint to the cap sealed before execution."""
    actual = rollout.get("harness", {}).get("runtime_budget")
    expected = {
        "max_metered_tokens": max_metered_tokens,
        "max_cost_usd": float(max_cost_usd),
    }
    if actual != expected:
        raise ValidationError(
            "normalized rollout runtime budget does not match the sealed "
            f"execution allowance: expected {expected!r}, observed {actual!r}"
        )
    if not require_usage:
        return
    metrics = rollout.get("metrics", {})
    missing = [key for key in ("cost_usd", *TOKEN_METRICS) if metrics.get(key) is None]
    if missing:
        raise ValidationError(
            f"normalized rollout is missing runtime budget telemetry {missing}"
        )
    observed_cost = float(metrics["cost_usd"])
    observed_tokens = sum(int(metrics[key]) for key in TOKEN_METRICS)
    if (
        not math.isfinite(observed_cost)
        or observed_cost > float(max_cost_usd)
        or observed_tokens > max_metered_tokens
    ):
        raise ValidationError(
            "normalized rollout exceeded its sealed fixed budget: "
            f"cost_usd={observed_cost:.9f}/{float(max_cost_usd):.9f}, "
            f"tokens={observed_tokens}/{max_metered_tokens}"
        )


def _remaining_schedule_count(
    experiment: Mapping[str, Any],
    expected_tasks: Mapping[str, Mapping[str, Any]],
    completed_keys: Mapping[str, set[tuple[str, int]]],
) -> int:
    return sum(
        1
        for trial, arm_id in counterbalanced_schedule(ARM_IDS, experiment["trials"])
        for task_id in expected_tasks
        if (task_id, trial) not in completed_keys[arm_id]
    )


def _require_remaining_schedule_capacity(
    collected: Mapping[str, Sequence[Dict[str, Any]]],
    budget: Mapping[str, Any],
    *,
    remaining_rollouts: int,
    stage_prior_cost_usd: float,
    stage_prior_tokens: int,
    aggregate_prior_cost_usd: float,
    aggregate_prior_tokens: int,
) -> tuple[float, int]:
    """Prove the whole remaining schedule fits before another paid request."""
    fixed = fixed_rollout_budget(budget, required=True)
    assert fixed is not None
    rollout_cost_cap, rollout_token_cap = fixed
    remaining_cost, remaining_tokens = _remaining_multi_budget(
        collected,
        budget,
        stage_prior_cost_usd=stage_prior_cost_usd,
        stage_prior_tokens=stage_prior_tokens,
        aggregate_prior_cost_usd=aggregate_prior_cost_usd,
        aggregate_prior_tokens=aggregate_prior_tokens,
    )
    required_cost = rollout_cost_cap * remaining_rollouts
    required_tokens = rollout_token_cap * remaining_rollouts
    if remaining_cost <= required_cost or remaining_tokens <= required_tokens:
        raise ValidationError(
            "remaining multi-arm schedule is not budget-feasible before network: "
            f"rollouts={remaining_rollouts}, remaining_cost_usd={remaining_cost:.9f}, "
            f"required_cost_usd>{required_cost:.9f}, "
            f"remaining_tokens={remaining_tokens}, required_tokens>{required_tokens}"
        )
    return rollout_cost_cap, rollout_token_cap


def _canonical_sha256(value: Any) -> str:
    return hashlib.sha256(stable_json(value).encode("utf-8")).hexdigest()


def _multi_arm_budget_authority(
    experiment: Mapping[str, Any],
    suite: Mapping[str, Any],
    *,
    stage_prior_cost_usd: float,
    stage_prior_tokens: int,
    aggregate_prior_cost_usd: float,
    aggregate_prior_tokens: int,
) -> BudgetAuthority:
    """Bind one local journal to the exact stage, carryover, and authority."""

    budget = experiment["budget"]
    stage_limit_cost = usd_to_microusd(budget["max_stage_cost_usd"])
    aggregate_limit_cost = usd_to_microusd(budget["max_aggregate_cost_usd"])
    stage_prior_cost = usd_to_microusd_ceiling(stage_prior_cost_usd)
    aggregate_prior_cost = usd_to_microusd_ceiling(aggregate_prior_cost_usd)
    remaining_cost = min(
        stage_limit_cost - stage_prior_cost,
        aggregate_limit_cost - aggregate_prior_cost,
    )
    remaining_tokens = min(
        int(budget["max_stage_tokens"]) - stage_prior_tokens,
        int(budget["max_aggregate_tokens"]) - aggregate_prior_tokens,
    )
    if remaining_cost <= 0 or remaining_tokens <= 0:
        raise ValidationError("paid budget journal authority is exhausted; fail-closed")
    experiment_sha256 = _canonical_sha256(experiment)
    suite_sha256 = _canonical_sha256(suite)
    authority_manifest = {
        "contract": "metacodes-multi-arm-budget-authority-v1",
        "experiment_id": experiment["experiment_id"],
        "stage_id": experiment["stage"]["id"],
        "experiment_sha256": experiment_sha256,
        "suite_id": suite["suite_id"],
        "suite_sha256": suite_sha256,
        "stage_prior_cost_microusd": stage_prior_cost,
        "stage_prior_metered_tokens": stage_prior_tokens,
        "aggregate_prior_cost_microusd": aggregate_prior_cost,
        "aggregate_prior_metered_tokens": aggregate_prior_tokens,
        "effective_total_cost_microusd": remaining_cost,
        "effective_total_metered_tokens": remaining_tokens,
    }
    return BudgetAuthority(
        manifest_sha256=_canonical_sha256(authority_manifest),
        model_fingerprint=_canonical_sha256(experiment["model"]),
        provider_identity=str(experiment["model"]["provider"]),
        total_cost_microusd=remaining_cost,
        total_metered_tokens=remaining_tokens,
    )


def _multi_arm_budget_transaction(
    experiment: Mapping[str, Any],
    task: Mapping[str, Any],
    *,
    authority: BudgetAuthority,
    arm_id: str,
    trial: int,
    revision: str,
    config_id: str,
    metacodes_sha256: str,
    tinykg_sha256: str,
    formal_kernel_fingerprint: str,
    runtime_env: Mapping[str, str],
    max_cost_usd: float,
    max_metered_tokens: int,
) -> BudgetTransaction:
    run_id = (
        f"{experiment['experiment_id']}:{experiment['stage']['id']}:"
        f"{arm_id}:{task['id']}:{trial}"
    )
    harness_fingerprint = _canonical_sha256(
        {
            "contract": "metacodes-multi-arm-budget-transaction-v1",
            "experiment_id": experiment["experiment_id"],
            "stage_id": experiment["stage"]["id"],
            "arm_id": arm_id,
            "task_id": task["id"],
            "task_sha256": _canonical_sha256(task),
            "trial": trial,
            "revision": revision,
            "config_id": config_id,
            "metacodes_sha256": metacodes_sha256,
            "tinykg_sha256": tinykg_sha256,
            "formal_kernel_fingerprint": formal_kernel_fingerprint,
            "runtime_env": dict(sorted(runtime_env.items())),
            "max_cost_microusd": usd_to_microusd(max_cost_usd),
            "max_metered_tokens": max_metered_tokens,
        }
    )
    return BudgetTransaction(
        run_id=run_id,
        manifest_sha256=authority.manifest_sha256,
        model_fingerprint=authority.model_fingerprint,
        harness_fingerprint=harness_fingerprint,
        provider_identity=authority.provider_identity,
        max_cost_microusd=usd_to_microusd(max_cost_usd),
        max_metered_tokens=max_metered_tokens,
    )


def _require_external_budget_journal(path: Path, output_dir: Path) -> Path:
    journal_path = path.expanduser()
    if not journal_path.is_absolute():
        journal_path = (Path.cwd() / journal_path).absolute()
    output = output_dir.expanduser()
    if not output.is_absolute():
        output = (Path.cwd() / output).absolute()
    journal_path = journal_path.resolve(strict=False)
    output = output.resolve(strict=False)
    try:
        journal_path.relative_to(output)
    except ValueError:
        return journal_path
    raise ValidationError(
        "paid budget journal must be outside the multi-arm output directory"
    )


def _rollout_metered_tokens(rollout: Mapping[str, Any]) -> int:
    return sum(int(rollout["metrics"][key]) for key in TOKEN_METRICS)


def _validate_checkpoint_budget_receipt(
    rollout: Mapping[str, Any],
    *,
    journal: BudgetJournal,
    transaction: BudgetTransaction,
) -> str:
    stored = rollout.get("budget_transaction")
    if not isinstance(stored, dict):
        raise ValidationError(
            f"rollout {rollout.get('run_id', 'unknown')} is missing its paid budget receipt"
        )
    transaction_id = stored.get("transaction_id")
    if not isinstance(transaction_id, str):
        raise ValidationError("paid budget receipt transaction id is missing")
    live = journal.transaction_receipt(transaction_id)
    immutable_keys = set(live) - {"journal_revision", "journal_head_sha256"}
    mismatches = sorted(
        key for key in immutable_keys if stored.get(key) != live.get(key)
    )
    if mismatches:
        raise ValidationError(
            "paid budget receipt does not match the live journal transaction: "
            f"{mismatches}"
        )
    identity = transaction.record()
    identity_mismatches = sorted(
        key for key, expected in identity.items() if stored.get(key) != expected
    )
    if identity_mismatches:
        raise ValidationError(
            "paid budget receipt transaction identity drift: "
            f"{identity_mismatches}"
        )
    expected_cost = usd_to_microusd_ceiling(rollout["metrics"]["cost_usd"])
    expected_tokens = _rollout_metered_tokens(rollout)
    if (
        stored.get("state") != "committed"
        or stored.get("actual_cost_microusd") != expected_cost
        or stored.get("actual_metered_tokens") != expected_tokens
    ):
        raise ValidationError("paid budget receipt is not an exact committed usage record")
    if (
        stored.get("journal_revision") != stored.get("commit_revision")
        or stored.get("journal_head_sha256") != stored.get("commit_head_sha256")
    ):
        raise ValidationError(
            "paid budget receipt is not bound to its commit journal revision/head"
        )
    return transaction_id


def _require_no_orphan_budget_transactions(
    journal: BudgetJournal, checkpoint_transaction_ids: set[str]
) -> None:
    for receipt in journal.transaction_receipts():
        if receipt["state"] == "aborted_pre_request":
            continue
        if receipt["transaction_id"] not in checkpoint_transaction_ids:
            raise ValidationError(
                "paid budget journal contains an authorized, reserved, or committed "
                "transaction without a matching rollout checkpoint; replay is forbidden"
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


def _mark_runtime_budget_invalid(
    rollout: Dict[str, Any], detail: str
) -> None:
    execution = rollout.setdefault("execution", {})
    execution["status"] = "invalid"
    reasons = execution.setdefault("invalid_reasons", [])
    if "runtime_budget_contract_violation" not in reasons:
        reasons.append("runtime_budget_contract_violation")
    rollout.setdefault("judgement", {})["valid_for_scoring"] = False
    rollout["judgement"]["trustworthy_success"] = False
    rollout.setdefault("attribution", []).append(
        {
            "code": "runtime_budget_contract_violation",
            "source": "O",
            "count": 1,
            "confidence": 1.0,
            "detail": detail[:512],
        }
    )


def _mark_treatment_activation_invalid(
    rollout: Dict[str, Any], detail: str
) -> None:
    """Keep a failed treatment attestation as durable, unscorable evidence."""
    execution = rollout.setdefault("execution", {})
    execution["status"] = "invalid"
    reasons = execution.setdefault("invalid_reasons", [])
    if "treatment_activation_failed" not in reasons:
        reasons.append("treatment_activation_failed")
    judgement = rollout.setdefault("judgement", {})
    judgement["valid_for_scoring"] = False
    judgement["trustworthy_success"] = False
    attribution = rollout.setdefault("attribution", [])
    if not any(
        item.get("code") == "treatment_activation_failed"
        for item in attribution
        if isinstance(item, dict)
    ):
        attribution.append(
            {
                "code": "treatment_activation_failed",
                "source": "L",
                "count": 1,
                "confidence": 1.0,
                "detail": detail[:512],
            }
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
    require_runtime_budget: bool = False,
    treatment_verifier: tuple[Path, str] | None = None,
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
        if require_runtime_budget and not isinstance(
            rollout.get("harness", {}).get("runtime_budget"), dict
        ):
            raise ValidationError(
                f"{variant} checkpoint {(task_id, trial)!r} is missing "
                "runtime budget provenance"
            )
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
        if treatment_verifier is not None:
            verifier_binary, verifier_sha256 = treatment_verifier
            reverify_treatment_activation(
                rollout,
                variant,
                verifier_binary,
                verifier_sha256,
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
    max_metered_tokens: int | None = None,
    max_cost_usd: float | None = None,
    runtime_api_key: str | None = None,
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
    if (max_metered_tokens is None) != (max_cost_usd is None):
        raise ValidationError("runtime budget requires both token and cost caps")
    if max_metered_tokens is not None and (
        not isinstance(max_metered_tokens, int)
        or isinstance(max_metered_tokens, bool)
        or max_metered_tokens <= 0
    ):
        raise ValidationError("runtime max metered tokens must be an integer > 0")
    if max_cost_usd is not None and (
        not isinstance(max_cost_usd, (int, float))
        or isinstance(max_cost_usd, bool)
        or not math.isfinite(float(max_cost_usd))
        or float(max_cost_usd) <= 0
    ):
        raise ValidationError("runtime max cost must be finite and > 0")
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
    if max_metered_tokens is not None:
        env["E2E_MAX_METERED_TOKENS"] = str(max_metered_tokens)
    if max_cost_usd is not None:
        env["E2E_MAX_COST_USD"] = format(float(max_cost_usd), ".17g")
    credential_read_fd = -1
    credential_write_fd = -1
    subprocess_options: Dict[str, Any] = {}
    try:
        if runtime_api_key is not None:
            credential = runtime_api_key.encode("utf-8")
            if not credential or len(credential) > 16 * 1024:
                raise ValidationError(
                    "multi-arm provider credential must contain 1-16384 UTF-8 bytes"
                )
            credential_read_fd, credential_write_fd = os.pipe()
            pipe_buf = os.fpathconf(credential_write_fd, "PC_PIPE_BUF")
            if len(credential) > pipe_buf:
                raise ValidationError("multi-arm provider credential exceeds atomic pipe limit")
            if os.write(credential_write_fd, credential) != len(credential):
                raise ValidationError("multi-arm provider credential pipe write was short")
            os.close(credential_write_fd)
            credential_write_fd = -1
            env["E2E_API_KEY_FD"] = str(credential_read_fd)
            subprocess_options["pass_fds"] = (credential_read_fd,)
        completed = subprocess.run(
            [str(repo_root / "tests/e2e/run_e2e.sh"), scenario_glob],
            cwd=repo_root,
            env=env,
            check=False,
            **subprocess_options,
        )
    finally:
        if credential_write_fd >= 0:
            os.close(credential_write_fd)
        if credential_read_fd >= 0:
            os.close(credential_read_fd)
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


def _require_formal_identity(expected: Mapping[str, Any]) -> None:
    observed = formal_kernel_identity(Path(str(expected["path"])))
    if observed != dict(expected):
        raise ValidationError(
            "formal kernel artifact changed after experiment identity was frozen"
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
    max_metered_tokens: int,
    max_cost_usd: float,
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
        "runtime_budget": {
            "max_metered_tokens": max_metered_tokens,
            "max_cost_usd": float(max_cost_usd),
        },
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
    formal_kernel: Path,
    revision: str,
    output_dir: Path,
    suite_path: Path,
    allow_paid_rollouts: bool,
    promotion_receipt: Mapping[str, Any] | None = None,
    calibration_checkpoints: Mapping[str, Path] | None = None,
    budget_used_cost_usd: float = 0.0,
    budget_used_tokens: int = 0,
    budget_journal_path: Path | None = None,
    auth_file: Path | None = None,
    budget_fault_hook: BudgetFaultHook | None = None,
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
    # A live experiment must freeze one identical allowance for every arm and
    # schedule position. Legacy schema-v2 evidence remains reportable, but it
    # cannot start new paid work with order-dependent "all remaining budget".
    fixed = fixed_rollout_budget(experiment["budget"], required=True)
    assert fixed is not None
    fixed_rollout_cost_usd, fixed_rollout_tokens = fixed
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
    formal_identity = formal_kernel_identity(formal_kernel)
    receipt_cost_usd = 0.0
    receipt_tokens = 0
    if experiment["stage"]["id"] == "confirmatory":
        if promotion_receipt is None:
            raise ValidationError("confirmatory execution requires a calibration promotion receipt")
        if calibration_checkpoints is None:
            raise ValidationError(
                "confirmatory execution requires authoritative calibration checkpoints"
            )
        receipt_cost_usd, receipt_tokens = validate_calibration_bundle(
            promotion_receipt,
            experiment,
            repo_root,
            calibration_checkpoints,
            tinykg_binary=Path(tinykg_identity["path"]),
            metacodes_sha256=metacodes_sha256,
            tinykg_sha256=tinykg_identity["sha256"],
            formal_kernel_fingerprint=formal_identity["artifact_fingerprint"],
            revision=revision,
        )
    elif promotion_receipt is not None or calibration_checkpoints is not None:
        raise ValidationError(
            "calibration execution must not receive promotion evidence"
        )
    # CLI offsets represent paid work from earlier attempts of this same
    # stage, even when a fresh output directory is used. They therefore count
    # against both the stage cap and the experiment-wide aggregate cap.
    stage_prior_cost_usd = budget_used_cost_usd
    stage_prior_tokens = budget_used_tokens
    aggregate_prior_cost_usd = budget_used_cost_usd + receipt_cost_usd
    aggregate_prior_tokens = budget_used_tokens + receipt_tokens
    expected_tasks = {task["id"]: task for task in suite["tasks"]}
    config_ids = arm_config_ids(
        experiment,
        suite,
        metacodes_sha256,
        tinykg_identity["sha256"],
        formal_identity["artifact_fingerprint"],
    )
    budget = experiment["budget"]
    if budget_journal_path is None:
        raise ValidationError("multi-arm execution requires explicit --budget-journal")
    if auth_file is None:
        raise ValidationError("multi-arm execution requires explicit --auth-file")
    journal_path = _require_external_budget_journal(budget_journal_path, output_dir)
    authority = _multi_arm_budget_authority(
        experiment,
        suite,
        stage_prior_cost_usd=stage_prior_cost_usd,
        stage_prior_tokens=stage_prior_tokens,
        aggregate_prior_cost_usd=aggregate_prior_cost_usd,
        aggregate_prior_tokens=aggregate_prior_tokens,
    )
    with BudgetJournal(journal_path, authority) as budget_journal:
        return _run_multi_arm_locked(
            experiment,
            suite,
            repo_root,
            binary,
            budget_journal=budget_journal,
            budget_authority=authority,
            tinykg_identity=tinykg_identity,
            formal_identity=formal_identity,
            revision=revision,
            output_dir=output_dir,
            suite_path=suite_path,
            metacodes_sha256=metacodes_sha256,
            config_ids=config_ids,
            fixed_rollout_cost_usd=fixed_rollout_cost_usd,
            fixed_rollout_tokens=fixed_rollout_tokens,
            stage_prior_cost_usd=stage_prior_cost_usd,
            stage_prior_tokens=stage_prior_tokens,
            aggregate_prior_cost_usd=aggregate_prior_cost_usd,
            aggregate_prior_tokens=aggregate_prior_tokens,
            auth_file=auth_file,
            budget_fault_hook=budget_fault_hook,
        )


def _run_multi_arm_locked(
    experiment: Dict[str, Any],
    suite: Dict[str, Any],
    repo_root: Path,
    binary: Path,
    *,
    budget_journal: BudgetJournal,
    budget_authority: BudgetAuthority,
    tinykg_identity: Mapping[str, Any],
    formal_identity: Mapping[str, Any],
    revision: str,
    output_dir: Path,
    suite_path: Path,
    metacodes_sha256: str,
    config_ids: Mapping[str, str],
    fixed_rollout_cost_usd: float,
    fixed_rollout_tokens: int,
    stage_prior_cost_usd: float,
    stage_prior_tokens: int,
    aggregate_prior_cost_usd: float,
    aggregate_prior_tokens: int,
    auth_file: Path,
    budget_fault_hook: BudgetFaultHook | None,
) -> Dict[str, List[Dict[str, Any]]]:
    """Run the paid schedule while one exclusive journal lock is held."""

    expected_tasks = {task["id"]: task for task in suite["tasks"]}
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
            require_runtime_budget=True,
            treatment_verifier=(
                Path(str(tinykg_identity["path"])),
                str(tinykg_identity["sha256"]),
            ),
        )
        for arm_id in ARM_IDS
    }
    completed_keys = {
        arm_id: {(item["task_id"], item["trial"]) for item in collected[arm_id]}
        for arm_id in ARM_IDS
    }
    budget = experiment["budget"]
    checkpoint_transaction_ids: set[str] = set()
    for arm_id, rows in collected.items():
        runtime_env = arm_runtime_env(
            experiment,
            arm_id,
            Path(str(tinykg_identity["path"])),
            formal_identity,
        )
        for rollout in rows:
            _require_runtime_budget_provenance(
                rollout,
                max_metered_tokens=fixed_rollout_tokens,
                max_cost_usd=fixed_rollout_cost_usd,
            )
            transaction = _multi_arm_budget_transaction(
                experiment,
                expected_tasks[rollout["task_id"]],
                authority=budget_authority,
                arm_id=arm_id,
                trial=rollout["trial"],
                revision=revision,
                config_id=config_ids[arm_id],
                metacodes_sha256=metacodes_sha256,
                tinykg_sha256=str(tinykg_identity["sha256"]),
                formal_kernel_fingerprint=str(
                    formal_identity["artifact_fingerprint"]
                ),
                runtime_env=runtime_env,
                max_cost_usd=fixed_rollout_cost_usd,
                max_metered_tokens=fixed_rollout_tokens,
            )
            transaction_id = _validate_checkpoint_budget_receipt(
                rollout,
                journal=budget_journal,
                transaction=transaction,
            )
            if transaction_id in checkpoint_transaction_ids:
                raise ValidationError(
                    "paid budget transaction is attached to more than one rollout checkpoint"
                )
            checkpoint_transaction_ids.add(transaction_id)
    _require_no_orphan_budget_transactions(
        budget_journal, checkpoint_transaction_ids
    )
    _require_multi_budget(
        collected,
        budget,
        stage_prior_cost_usd=stage_prior_cost_usd,
        stage_prior_tokens=stage_prior_tokens,
        aggregate_prior_cost_usd=aggregate_prior_cost_usd,
        aggregate_prior_tokens=aggregate_prior_tokens,
    )
    remaining_rollouts = _remaining_schedule_count(
        experiment, expected_tasks, completed_keys
    )
    _require_remaining_schedule_capacity(
        collected,
        budget,
        remaining_rollouts=remaining_rollouts,
        stage_prior_cost_usd=stage_prior_cost_usd,
        stage_prior_tokens=stage_prior_tokens,
        aggregate_prior_cost_usd=aggregate_prior_cost_usd,
        aggregate_prior_tokens=aggregate_prior_tokens,
    )
    if remaining_rollouts == 0:
        return collected
    runtime_api_key = _load_api_key(auth_file.expanduser().resolve())
    output_dir.mkdir(parents=True, exist_ok=True)

    for trial, arm_id in counterbalanced_schedule(ARM_IDS, experiment["trials"]):
        runtime_env = arm_runtime_env(
            experiment,
            arm_id,
            Path(str(tinykg_identity["path"])),
            formal_identity,
        )
        for task_id in sorted(expected_tasks):
            if (task_id, trial) in completed_keys[arm_id]:
                continue
            _require_multi_budget(
                collected,
                budget,
                stage_prior_cost_usd=stage_prior_cost_usd,
                stage_prior_tokens=stage_prior_tokens,
                aggregate_prior_cost_usd=aggregate_prior_cost_usd,
                aggregate_prior_tokens=aggregate_prior_tokens,
            )
            runtime_max_cost_usd, runtime_max_metered_tokens = (
                _require_remaining_schedule_capacity(
                    collected,
                    budget,
                    remaining_rollouts=_remaining_schedule_count(
                        experiment, expected_tasks, completed_keys
                    ),
                    stage_prior_cost_usd=stage_prior_cost_usd,
                    stage_prior_tokens=stage_prior_tokens,
                    aggregate_prior_cost_usd=aggregate_prior_cost_usd,
                    aggregate_prior_tokens=aggregate_prior_tokens,
                )
            )
            _require_sha256(binary, metacodes_sha256, "metacodes binary")
            _require_sha256(
                Path(str(tinykg_identity["path"])),
                str(tinykg_identity["sha256"]),
                "TinyKG binary",
            )
            _require_formal_identity(formal_identity)

            transaction = _multi_arm_budget_transaction(
                experiment,
                expected_tasks[task_id],
                authority=budget_authority,
                arm_id=arm_id,
                trial=trial,
                revision=revision,
                config_id=config_ids[arm_id],
                metacodes_sha256=metacodes_sha256,
                tinykg_sha256=str(tinykg_identity["sha256"]),
                formal_kernel_fingerprint=str(
                    formal_identity["artifact_fingerprint"]
                ),
                runtime_env=runtime_env,
                max_cost_usd=runtime_max_cost_usd,
                max_metered_tokens=runtime_max_metered_tokens,
            )
            reserved = budget_journal.reserve(transaction)
            transaction_id = str(reserved["transaction_id"])
            authorization_started = False
            try:
                # Re-observe immutable executables after reservation and before
                # durable request admission. Any safe pre-request failure aborts
                # the reservation without exposing provider budget.
                _require_sha256(binary, metacodes_sha256, "metacodes binary")
                _require_sha256(
                    Path(str(tinykg_identity["path"])),
                    str(tinykg_identity["sha256"]),
                    "TinyKG binary",
                )
                _require_formal_identity(formal_identity)
                authorization_started = True
                authorization = budget_journal.authorize_request(
                    transaction_id,
                    expected_revision=int(reserved["journal_revision"]),
                    expected_head_sha256=str(reserved["journal_head_sha256"]),
                )
            except BaseException:
                if not authorization_started:
                    budget_journal.abort_pre_request(transaction_id)
                raise
            if budget_fault_hook is not None:
                budget_fault_hook("after_request_authorized", authorization)

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
                    runtime_env=runtime_env,
                    allow_invalid_run=True,
                    timeout_seconds=expected_tasks[task_id]["constraints"][
                        "timeout_seconds"
                    ],
                    max_metered_tokens=runtime_max_metered_tokens,
                    max_cost_usd=runtime_max_cost_usd,
                    runtime_api_key=runtime_api_key,
                )
            except InfrastructureRunError as exc:
                infrastructure_error = exc
                run_dir = exc.run_dir
            if budget_fault_hook is not None:
                budget_fault_hook(
                    "after_provider_return_before_commit", authorization
                )

            if infrastructure_error is None:
                # Catch replacement during the paid rollout, including the
                # final sample where there is no subsequent preflight.
                _require_sha256(binary, metacodes_sha256, "metacodes binary")
                _require_sha256(
                    Path(str(tinykg_identity["path"])),
                    str(tinykg_identity["sha256"]),
                    "TinyKG binary",
                )
                _require_formal_identity(formal_identity)
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
                    and rollout["task_fingerprint_provenance"]
                    == "recorded_at_execution"
                ]
            else:
                selected = [
                    rollout for rollout in imported if rollout["task_id"] == task_id
                ]
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
                    max_metered_tokens=runtime_max_metered_tokens,
                    max_cost_usd=runtime_max_cost_usd,
                )
            if len(selected) != 1:
                raise ValidationError(
                    f"{arm_id} trial {trial} task {task_id}: expected one "
                    "execution-grounded rollout"
                )

            runtime_budget_error: ValidationError | None = None
            try:
                _require_runtime_budget_provenance(
                    selected[0],
                    max_metered_tokens=runtime_max_metered_tokens,
                    max_cost_usd=runtime_max_cost_usd,
                    require_usage=infrastructure_error is None,
                )
            except ValidationError as exc:
                runtime_budget_error = exc
                _mark_runtime_budget_invalid(selected[0], str(exc))

            if infrastructure_error is None and runtime_budget_error is None:
                budget_receipt = budget_journal.commit(
                    transaction_id,
                    actual_cost_microusd=usd_to_microusd_ceiling(
                        selected[0]["metrics"]["cost_usd"]
                    ),
                    actual_metered_tokens=_rollout_metered_tokens(selected[0]),
                )
                selected[0]["budget_transaction"] = dict(budget_receipt)
                if budget_fault_hook is not None:
                    budget_fault_hook("after_budget_commit", budget_receipt)
            else:
                selected[0]["budget_transaction"] = dict(
                    budget_journal.transaction_receipt(transaction_id)
                )

            treatment_error: ValidationError | None = None
            if infrastructure_error is None and runtime_budget_error is None:
                try:
                    attach_treatment_activation(
                        selected[0],
                        arm_id,
                        Path(str(tinykg_identity["path"])),
                        str(tinykg_identity["sha256"]),
                    )
                except ValidationError as exc:
                    treatment_error = exc
                    _mark_treatment_activation_invalid(selected[0], str(exc))
            collected[arm_id].extend(selected)
            completed_keys[arm_id].add((task_id, trial))
            write_rollouts(outputs[arm_id], collected[arm_id])
            if budget_fault_hook is not None:
                budget_fault_hook(
                    "after_rollout_checkpoint", selected[0]["budget_transaction"]
                )
            if infrastructure_error is not None:
                raise infrastructure_error
            if runtime_budget_error is not None:
                raise runtime_budget_error
            if treatment_error is not None:
                raise treatment_error
            _require_scoring_rollout(selected[0], variant=arm_id)
            _require_multi_budget(
                collected,
                budget,
                stage_prior_cost_usd=stage_prior_cost_usd,
                stage_prior_tokens=stage_prior_tokens,
                aggregate_prior_cost_usd=aggregate_prior_cost_usd,
                aggregate_prior_tokens=aggregate_prior_tokens,
            )
    return collected
