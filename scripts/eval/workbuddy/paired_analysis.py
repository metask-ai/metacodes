"""Build a fail-closed paired WorkBuddy project-control effect report.

The report compares two independently authorized official WorkBuddy waves that
share one preregistered covariate identity.  The baseline has the exact staged
project kernel/rule bytes present but disabled; the treatment enables them.
No provider request, TinyKG access, or actor-context mutation occurs here.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any, Dict, Mapping, Sequence

from ..model import ValidationError, stable_json
from ..memory_budget_journal import (
    reopen_checkpoint_transaction,
    usd_to_microusd_ceiling,
    validate_checkpoint_payload,
)
from .launch_gate import (
    COMPARISON_SCHEMA_VERSION,
    PAIRED_SCHEMA_VERSION,
    RECEIPT_SCHEMA_VERSION,
    SCHEMA_VERSION,
    LaunchError,
    _canonical_sha256,
    _observed_json,
    _read_regular,
    _sha256_bytes,
    _validate_launch_manifest,
    _write_private_new,
)


REPORT_SCHEMA_VERSION = "metacodes-workbuddy-project-control-paired-report-v1"
ARMS = {"baseline": "disabled", "treatment": "enforced"}


def _number(value: object, where: str, *, minimum: float = 0.0) -> float:
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(float(value))
        or float(value) < minimum
    ):
        raise LaunchError(f"paired WorkBuddy {where} is invalid")
    return float(value)


def _integer(value: object, where: str, *, minimum: int = 0) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        raise LaunchError(f"paired WorkBuddy {where} is invalid")
    return value


def _sha256(value: object, where: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise LaunchError(f"paired WorkBuddy {where} is invalid")
    return value


def _receipt(
    path: Path,
    journal_path: Path,
    manifest: Mapping[str, Any],
    *,
    expected_mode: str,
) -> tuple[Dict[str, Any], Dict[str, object], Dict[str, object]]:
    receipt, receipt_identity, _ = _observed_json(path)
    required = {
        "schema_version",
        "quality_evidence",
        "launch_manifest_content_sha256",
        "run_id",
        "cohort",
        "usage",
        "budget_transaction",
        "journal",
        "elapsed_seconds",
        "evaluation_treatment",
        "comparison",
    }
    if set(receipt) != required or receipt.get("schema_version") != RECEIPT_SCHEMA_VERSION:
        raise LaunchError("paired WorkBuddy receipt schema is unsupported")
    if (
        receipt.get("launch_manifest_content_sha256") != manifest["content_sha256"]
        or receipt.get("run_id") != manifest["run_id"]
        or receipt.get("cohort") != manifest["cohort"]
        or receipt.get("evaluation_treatment") != manifest["evaluation_treatment"]
        or receipt.get("comparison") != manifest["comparison"]
        or manifest["evaluation_treatment"].get("project_control") != expected_mode
    ):
        raise LaunchError("paired WorkBuddy receipt does not bind its launch arm")
    if not isinstance(receipt.get("quality_evidence"), bool):
        raise LaunchError("paired WorkBuddy receipt quality class is invalid")
    if (
        receipt["quality_evidence"] is True
        and manifest.get("quality_evidence_on_commit") is not True
    ):
        raise LaunchError("paired WorkBuddy receipt elevates unregistered quality evidence")
    usage = receipt.get("usage")
    if not isinstance(usage, dict) or not isinstance(usage.get("tasks"), dict):
        raise LaunchError("paired WorkBuddy receipt usage is incomplete")
    transaction = receipt.get("budget_transaction")
    journal = receipt.get("journal")
    identity = {
        "run_id": manifest["run_id"],
        "manifest_sha256": manifest["content_sha256"],
        "model_fingerprint": manifest["model"]["fingerprint"],
        "harness_fingerprint": manifest["harness_fingerprint"],
        "provider_identity": manifest["model"]["provider_identity"],
        "max_cost_microusd": manifest["budget"]["max_cost_microusd"],
        "max_metered_tokens": manifest["budget"]["max_metered_tokens"],
    }
    if (
        not isinstance(transaction, dict)
        or transaction.get("state") != "committed"
        or transaction.get("run_id") != manifest["run_id"]
        or transaction.get("manifest_sha256") != manifest["content_sha256"]
        or transaction.get("model_fingerprint") != manifest["model"]["fingerprint"]
        or transaction.get("provider_identity")
        != manifest["model"]["provider_identity"]
        or transaction.get("harness_fingerprint")
        != manifest["harness_fingerprint"]
        or _integer(transaction.get("actual_cost_microusd"), "actual cost")
        != _integer(usage.get("cost_microusd"), "usage cost")
        or _integer(transaction.get("actual_metered_tokens"), "actual tokens")
        != _integer(usage.get("metered_tokens"), "usage tokens")
        or _integer(transaction.get("max_cost_microusd"), "maximum cost", minimum=1)
        != manifest["budget"]["max_cost_microusd"]
        or _integer(transaction.get("max_metered_tokens"), "maximum tokens", minimum=1)
        != manifest["budget"]["max_metered_tokens"]
        or transaction["actual_cost_microusd"] > transaction["max_cost_microusd"]
        or transaction["actual_metered_tokens"] > transaction["max_metered_tokens"]
        or transaction.get("identity_sha256")
        != _canonical_sha256(identity)
        or not isinstance(journal, dict)
        or _sha256(transaction.get("journal_id"), "journal id")
        != journal.get("journal_id")
        or _integer(transaction.get("reservation_revision"), "reservation revision", minimum=1) != 1
        or _integer(transaction.get("authorization_revision"), "authorization revision", minimum=1) != 2
        or _integer(transaction.get("commit_revision"), "commit revision", minimum=1) != 3
        or _integer(transaction.get("journal_revision"), "journal revision", minimum=1) != 3
        or _sha256(transaction.get("transaction_id"), "transaction id")
        != _canonical_sha256(
            {
                "journal_id": transaction["journal_id"],
                "reservation_revision": 1,
                "identity": identity,
            }
        )
        or _sha256(transaction.get("reservation_head_sha256"), "reservation head")
        != transaction.get("reservation_head_sha256")
        or _sha256(transaction.get("authorization_head_sha256"), "authorization head")
        != transaction.get("authorization_head_sha256")
        or _sha256(transaction.get("commit_head_sha256"), "commit head")
        != transaction.get("commit_head_sha256")
        or transaction.get("commit_head_sha256")
        != transaction.get("journal_head_sha256")
        or journal.get("journal_id") != transaction.get("journal_id")
        or journal.get("revision") != transaction.get("journal_revision")
        or journal.get("head_sha256") != transaction.get("journal_head_sha256")
        or journal.get("transaction_states") != {"committed": 1}
    ):
        raise LaunchError("paired WorkBuddy receipt budget identity is inconsistent")
    journal_locator = str(journal_path.absolute())
    try:
        checkpoint = _read_regular(journal_path, maximum=8 * 1024 * 1024)
        replayed = validate_checkpoint_payload(checkpoint)
        reopened = reopen_checkpoint_transaction(
            checkpoint, str(transaction["transaction_id"])
        )
    except (OSError, ValidationError, ValueError) as exc:
        raise LaunchError("paired WorkBuddy budget journal cannot be replayed") from exc
    if (
        reopened != transaction
        or replayed.get("journal_id") != journal["journal_id"]
        or replayed.get("revision") != journal["revision"]
        or replayed.get("head_sha256") != journal["head_sha256"]
        or {
            state: sum(
                item.get("state") == state
                for item in replayed.get("transactions", {}).values()
            )
            for state in {item.get("state") for item in replayed.get("transactions", {}).values()}
        }
        != journal["transaction_states"]
    ):
        raise LaunchError("paired WorkBuddy receipt disagrees with its budget journal")
    _number(receipt.get("elapsed_seconds"), "elapsed time")
    selected = manifest["cohort"]["selected_tasks"]
    if set(usage["tasks"]) != set(selected):
        raise LaunchError("paired WorkBuddy receipt task set drifted")
    quality = usage.get("quality")
    if (
        not isinstance(quality, dict)
        or set(quality)
        != {"mean_verifier_reward", "full_passes", "task_count", "pass_rate"}
        or _integer(quality.get("task_count"), "quality task count", minimum=1)
        != len(selected)
        or _integer(quality.get("full_passes"), "quality full passes") > len(selected)
    ):
        raise LaunchError("paired WorkBuddy receipt quality summary is incomplete")
    mean_reward = _number(quality.get("mean_verifier_reward"), "mean reward")
    pass_rate = _number(quality.get("pass_rate"), "pass rate")
    if mean_reward > 1.0 or pass_rate > 1.0:
        raise LaunchError("paired WorkBuddy quality score exceeds one")
    task_rewards = []
    task_passes = 0
    task_costs = []
    task_tokens = 0
    task_requests = 0
    for task, row in usage["tasks"].items():
        if not isinstance(row, dict):
            raise LaunchError(f"paired WorkBuddy task usage is malformed: {task}")
        reward = _number(row.get("verifier_reward"), f"{task} verifier reward")
        if reward > 1.0 or row.get("full_pass") is not (reward == 1.0):
            raise LaunchError(f"paired WorkBuddy task reward is inconsistent: {task}")
        task_rewards.append(reward)
        task_passes += int(reward == 1.0)
        task_costs.append(_number(row.get("cost_usd"), f"{task} cost"))
        task_tokens += _integer(row.get("metered_tokens"), f"{task} tokens")
        task_requests += _integer(
            row.get("provider_requests"), f"{task} provider requests"
        )
    recomputed_mean = sum(task_rewards) / len(task_rewards)
    if (
        abs(mean_reward - recomputed_mean) > 1e-12
        or quality["full_passes"] != task_passes
        or abs(pass_rate - task_passes / len(task_rewards)) > 1e-12
        or _integer(usage.get("cost_microusd"), "total cost")
        != usd_to_microusd_ceiling(sum(task_costs))
        or _integer(usage.get("metered_tokens"), "total tokens") != task_tokens
        or _integer(usage.get("provider_requests"), "total provider requests")
        != task_requests
    ):
        raise LaunchError("paired WorkBuddy usage aggregate disagrees with task evidence")
    journal_identity = {
        "path": journal_locator,
        "bytes": len(checkpoint),
        "sha256": _sha256_bytes(checkpoint),
    }
    return receipt, receipt_identity, journal_identity


def _control_delta(
    baseline: Mapping[str, Any], treatment: Mapping[str, Any]
) -> Dict[str, object]:
    b = baseline["lean"]
    t = treatment["lean"]
    fields = (
        "checker_calls",
        "checker_elapsed_ns",
        "rule_filter_events",
        "active_rule_phases",
        "checker_rule_phases",
        "statically_pruned_rule_phases",
        "block",
        "fault",
        "enforced_blocks",
    )
    return {
        name: _integer(t.get(name, 0), f"treatment Lean {name}")
        - _integer(b.get(name, 0), f"baseline Lean {name}")
        for name in fields
    }


def build_report(
    *,
    baseline_manifest_path: Path,
    baseline_receipt_path: Path,
    baseline_journal_path: Path,
    treatment_manifest_path: Path,
    treatment_receipt_path: Path,
    treatment_journal_path: Path,
) -> Dict[str, object]:
    manifest_observations = {
        "baseline": _observed_json(baseline_manifest_path),
        "treatment": _observed_json(treatment_manifest_path),
    }
    manifests = {
        arm: _validate_launch_manifest(observation[0])
        for arm, observation in manifest_observations.items()
    }
    manifest_identities = {
        arm: observation[1] for arm, observation in manifest_observations.items()
    }
    for arm, manifest in manifests.items():
        if manifest.get("schema_version") not in {
            PAIRED_SCHEMA_VERSION,
            SCHEMA_VERSION,
        }:
            raise LaunchError("paired WorkBuddy analysis requires paired launch manifests")
        comparison = manifest.get("comparison")
        if (
            not isinstance(comparison, dict)
            or comparison.get("schema_version") != COMPARISON_SCHEMA_VERSION
        ):
            raise LaunchError("paired WorkBuddy comparison identity is missing")
        if manifest["evaluation_treatment"].get("project_control") != ARMS[arm]:
            raise LaunchError(f"paired WorkBuddy {arm} has the wrong treatment")
    b_comparison = manifests["baseline"]["comparison"]
    t_comparison = manifests["treatment"]["comparison"]
    if (
        b_comparison.get("comparison_id") != t_comparison.get("comparison_id")
        or b_comparison.get("covariates_sha256")
        != t_comparison.get("covariates_sha256")
        or b_comparison.get("covariates") != t_comparison.get("covariates")
    ):
        raise LaunchError("paired WorkBuddy frozen covariates differ between arms")

    receipt_observations = {
        "baseline": _receipt(
            baseline_receipt_path,
            baseline_journal_path,
            manifests["baseline"],
            expected_mode="disabled",
        ),
        "treatment": _receipt(
            treatment_receipt_path,
            treatment_journal_path,
            manifests["treatment"],
            expected_mode="enforced",
        ),
    }
    receipts = {arm: observation[0] for arm, observation in receipt_observations.items()}
    receipt_identities = {
        arm: observation[1] for arm, observation in receipt_observations.items()
    }
    journal_identities = {
        arm: observation[2] for arm, observation in receipt_observations.items()
    }
    if manifests["baseline"]["run_id"] == manifests["treatment"]["run_id"]:
        raise LaunchError("paired WorkBuddy arms must use distinct run ids")
    b_transaction = receipts["baseline"]["budget_transaction"]
    t_transaction = receipts["treatment"]["budget_transaction"]
    if b_transaction["transaction_id"] == t_transaction["transaction_id"]:
        raise LaunchError("paired WorkBuddy arms reused one budget transaction")
    if b_transaction["journal_id"] == t_transaction["journal_id"]:
        raise LaunchError("paired WorkBuddy arms must use independent budget journals")
    b_usage = receipts["baseline"]["usage"]
    t_usage = receipts["treatment"]["usage"]
    tasks: Dict[str, object] = {}
    improved = regressed = unchanged = 0
    for task in manifests["baseline"]["cohort"]["selected_tasks"]:
        baseline = b_usage["tasks"][task]
        treatment = t_usage["tasks"][task]
        if (
            baseline.get("task_checksum") != treatment.get("task_checksum")
            or baseline.get("cacheable_first_request_sha256")
            != treatment.get("cacheable_first_request_sha256")
        ):
            raise LaunchError(
                f"paired WorkBuddy task/cache-prefix identity drifted for {task}"
            )
        b_reward = _number(baseline.get("verifier_reward"), f"{task} baseline reward")
        t_reward = _number(treatment.get("verifier_reward"), f"{task} treatment reward")
        if max(b_reward, t_reward) > 1.0:
            raise LaunchError(f"paired WorkBuddy reward exceeds one for {task}")
        delta = t_reward - b_reward
        improved += int(delta > 0)
        regressed += int(delta < 0)
        unchanged += int(delta == 0)
        tasks[task] = {
            "task_checksum": baseline["task_checksum"],
            "cacheable_first_request_sha256": baseline[
                "cacheable_first_request_sha256"
            ],
            "baseline_reward": b_reward,
            "treatment_reward": t_reward,
            "reward_delta": delta,
            "baseline_full_pass": baseline.get("full_pass") is True,
            "treatment_full_pass": treatment.get("full_pass") is True,
            "cost_microusd_delta": usd_to_microusd_ceiling(
                _number(treatment.get("cost_usd"), f"{task} treatment cost")
            )
            - usd_to_microusd_ceiling(
                _number(baseline.get("cost_usd"), f"{task} baseline cost")
            ),
            "metered_tokens_delta": _integer(
                treatment.get("metered_tokens"), f"{task} treatment tokens"
            )
            - _integer(baseline.get("metered_tokens"), f"{task} baseline tokens"),
            "provider_requests_delta": _integer(
                treatment.get("provider_requests"), f"{task} treatment requests"
            )
            - _integer(baseline.get("provider_requests"), f"{task} baseline requests"),
            "cache_read_tokens_delta": _integer(
                treatment.get("cache_read_input_tokens"),
                f"{task} treatment cache read",
            )
            - _integer(
                baseline.get("cache_read_input_tokens"),
                f"{task} baseline cache read",
            ),
            "cache_creation_tokens_delta": _integer(
                treatment.get("cache_creation_input_tokens"),
                f"{task} treatment cache creation",
            )
            - _integer(
                baseline.get("cache_creation_input_tokens"),
                f"{task} baseline cache creation",
            ),
            "lean_delta": _control_delta(
                baseline["control_metrics"], treatment["control_metrics"]
            ),
        }

    b_quality = b_usage["quality"]
    t_quality = t_usage["quality"]
    quality_evidence = (
        receipts["baseline"]["quality_evidence"] is True
        and receipts["treatment"]["quality_evidence"] is True
    )
    report: Dict[str, object] = {
        "schema_version": REPORT_SCHEMA_VERSION,
        "quality_evidence": quality_evidence,
        "comparison_id": b_comparison["comparison_id"],
        "covariates_sha256": b_comparison["covariates_sha256"],
        "arms": {
            arm: {
                "manifest": manifest_identities[arm],
                "receipt": receipt_identities[arm],
                "budget_journal": journal_identities[arm],
                "run_id": manifests[arm]["run_id"],
                "project_control": ARMS[arm],
            }
            for arm in ("baseline", "treatment")
        },
        "task_count": len(tasks),
        "improved_tasks": improved,
        "regressed_tasks": regressed,
        "unchanged_tasks": unchanged,
        "baseline_mean_reward": b_quality["mean_verifier_reward"],
        "treatment_mean_reward": t_quality["mean_verifier_reward"],
        "mean_reward_delta": (
            float(t_quality["mean_verifier_reward"])
            - float(b_quality["mean_verifier_reward"])
        ),
        "baseline_pass_rate": b_quality["pass_rate"],
        "treatment_pass_rate": t_quality["pass_rate"],
        "pass_rate_delta": float(t_quality["pass_rate"])
        - float(b_quality["pass_rate"]),
        "cost_microusd_delta": _integer(
            t_usage.get("cost_microusd"), "treatment total cost"
        )
        - _integer(b_usage.get("cost_microusd"), "baseline total cost"),
        "metered_tokens_delta": _integer(
            t_usage.get("metered_tokens"), "treatment total tokens"
        )
        - _integer(b_usage.get("metered_tokens"), "baseline total tokens"),
        "provider_requests_delta": _integer(
            t_usage.get("provider_requests"), "treatment total requests"
        )
        - _integer(b_usage.get("provider_requests"), "baseline total requests"),
        "elapsed_seconds_delta": float(receipts["treatment"]["elapsed_seconds"])
        - float(receipts["baseline"]["elapsed_seconds"]),
        "cache_prefix_equal_for_every_task": True,
        "tasks": tasks,
        "claim_boundary": (
            "observed paired difference for this frozen task cohort and project-rule "
            "bundle; a single model sample per arm is not a causal effect estimate or "
            "evidence of general Lean/TinyKG superiority"
        ),
    }
    report["content_sha256"] = _canonical_sha256(report)
    return report


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-manifest", type=Path, required=True)
    parser.add_argument("--baseline-receipt", type=Path, required=True)
    parser.add_argument("--baseline-budget-journal", type=Path, required=True)
    parser.add_argument("--treatment-manifest", type=Path, required=True)
    parser.add_argument("--treatment-receipt", type=Path, required=True)
    parser.add_argument("--treatment-budget-journal", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        report = build_report(
            baseline_manifest_path=args.baseline_manifest,
            baseline_receipt_path=args.baseline_receipt,
            baseline_journal_path=args.baseline_budget_journal,
            treatment_manifest_path=args.treatment_manifest,
            treatment_receipt_path=args.treatment_receipt,
            treatment_journal_path=args.treatment_budget_journal,
        )
        _write_private_new(
            args.output, (json.dumps(report, sort_keys=True, indent=2) + "\n").encode()
        )
        print(stable_json({
            "quality_evidence": report["quality_evidence"],
            "mean_reward_delta": report["mean_reward_delta"],
            "pass_rate_delta": report["pass_rate_delta"],
            "content_sha256": report["content_sha256"],
        }))
        return 0
    except (LaunchError, OSError, ValueError) as exc:
        parser.error(str(exc))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
