"""Build a fail-closed paired WorkBuddy harness-treatment report.

The common layer binds independent budgets, official rewards, frozen task and
cache-prefix identity, cost, tokens and time. A named study profile then proves
that exactly its intended harness variable changed. No provider request,
TinyKG access, or actor-context mutation occurs here.
"""

from __future__ import annotations

import argparse
import json
import hashlib
import math
import re
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
    _cacheable_first_request_sha256,
    _canonical_sha256,
    _observed_json,
    _read_regular,
    _sha256_bytes,
    _validate_launch_manifest,
    _write_private_new,
)

# 跨 UTC 午夜的配对轮:actor 系统上下文里的日期行(harness 注入的
# currentDate)在两臂间相差一天,缓存前缀哈希因此不等(2026-08-18
# pov2-r2 实例)。豁免必须证据驱动:从 record_full_io 保留的 trial 工件
# 加载两臂真实首请求,先验证字节确与收据 pin 的前缀哈希一致,再把日期行
# 归一化后要求逐字节相等——只有"恰好差一天"这一种形状可被接受并披露。
_DATED_PREFIX_PATTERN = re.compile(
    r"Today's date is \d{4}/\d{2}/\d{2}"
)


REPORT_SCHEMA_VERSION = "metacodes-workbuddy-project-control-paired-report-v1"
CHECKPOINT_REPORT_SCHEMA_VERSION = (
    "metacodes-workbuddy-verification-checkpoint-paired-report-v1"
)
PROJECT_CONTROL = "project_control"
VERIFICATION_CHECKPOINT = "verification_checkpoint"
VERIFICATION_FINAL_GATE = "verification_final_gate"
MEMORY_ACCUMULATION = "memory_accumulation"
FULL_STACK = "full_stack"
STUDIES = {
    PROJECT_CONTROL,
    VERIFICATION_CHECKPOINT,
    VERIFICATION_FINAL_GATE,
    MEMORY_ACCUMULATION,
    FULL_STACK,
}
PROJECT_CONTROL_ARMS = {"baseline": "disabled", "treatment": "enforced"}
CHECKPOINT_ARMS = {"baseline": False, "treatment": True}
FINAL_GATE_REPORT_SCHEMA_VERSION = (
    "metacodes-workbuddy-verification-final-gate-paired-report-v1"
)
# Measurement symmetry: the baseline arm must run record-only observation so
# both arms carry the obligation outcome; only the treatment arm enforces.
FINAL_GATE_ARMS = {"baseline": False, "treatment": True}
FINAL_OBSERVE_ARMS = {"baseline": True, "treatment": False}
MEMORY_REPORT_SCHEMA_VERSION = (
    "metacodes-workbuddy-memory-accumulation-paired-report-v1"
)
# The memory study varies exactly one thing: whether the local TinyKG store
# accumulates across the arm's tasks. Both arms hold every verification
# treatment off so memory transfer is not confounded with gate actuation.
MEMORY_ARMS = {"baseline": False, "treatment": True}
FULL_STACK_REPORT_SCHEMA_VERSION = (
    "metacodes-workbuddy-full-stack-paired-report-v1"
)
# The full-stack study measures the merged control plane as one treatment:
# project rules enforced + verification final gate enforced + requirement
# ledger enforced, against a baseline with all actuation off. Measurement
# symmetry: the baseline arm runs the gate and ledger in record-only observe
# mode so both arms carry the obligation outcomes.
FULL_STACK_PROJECT_ARMS = {"baseline": "disabled", "treatment": "enforced"}
FULL_STACK_GATE_ARMS = {"baseline": False, "treatment": True}
FULL_STACK_OBSERVE_ARMS = {"baseline": True, "treatment": False}
FULL_STACK_LEDGER_ARMS = {"baseline": False, "treatment": True}
FULL_STACK_LEDGER_OBSERVE_ARMS = {"baseline": True, "treatment": False}


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
    results_root: Path | None = None,
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
    # resume_audit is optional: a receipt committed by launch_gate's audit
    # resumption path carries its instrument-succession disclosure inline.
    # resumes is optional: a receipt committed by resume-trials additionally
    # discloses which trials were rerun after a proven infrastructure
    # transient, with the tainted attempt-1 evidence hashes.
    if (
        set(receipt) - {"resume_audit", "resumes"} != required
        or receipt.get("schema_version") != RECEIPT_SCHEMA_VERSION
    ):
        raise LaunchError("paired WorkBuddy receipt schema is unsupported")
    if "resume_audit" in receipt and not isinstance(receipt["resume_audit"], dict):
        raise LaunchError("paired WorkBuddy receipt resume_audit disclosure is invalid")
    if "resumes" in receipt:
        resumes = receipt["resumes"]
        selected_for_resume = set(manifest["cohort"]["selected_tasks"])
        if (
            not isinstance(resumes, list)
            or not resumes
            # 与 launch_gate.MAX_RESUMED_TRIALS 锁步(测试断言相等,勿单改)
            or len(resumes) > 3
            or "resume_audit" not in receipt
        ):
            raise LaunchError("paired WorkBuddy resumes disclosure is invalid")
        resumed_names: set = set()
        for row in resumes:
            if (
                not isinstance(row, dict)
                or set(row)
                != {
                    "task",
                    "reason",
                    "result_sha256",
                    "requests_sha256",
                    "original_dir_rel",
                    "tainted_dir_rel",
                    "attempt1_usage",
                }
                or row["task"] not in selected_for_resume
                or row["task"] in resumed_names
                or not isinstance(row["reason"], str)
                or len(row["reason"]) > 2000
                or row["tainted_dir_rel"]
                != str(row["original_dir_rel"]) + ".tainted-a1"
            ):
                raise LaunchError(
                    "paired WorkBuddy resumes disclosure is invalid"
                )
            resumed_names.add(row["task"])
            _sha256(row["result_sha256"], "resumed trial evidence")
            _sha256(row["requests_sha256"], "resumed trial ledger")
        resumed_usage = (receipt.get("usage") or {}).get("resumed_attempts")
        if (
            not isinstance(resumed_usage, dict)
            or set(resumed_usage) != resumed_names
        ):
            raise LaunchError(
                "paired WorkBuddy resumes disclosure does not match the "
                "resumed-attempt usage"
            )
    elif "resumed_attempts" in (receipt.get("usage") or {}):
        raise LaunchError(
            "paired WorkBuddy receipt carries resumed-attempt usage without "
            "a resumes disclosure"
        )
    if (
        receipt.get("launch_manifest_content_sha256") != manifest["content_sha256"]
        or receipt.get("run_id") != manifest["run_id"]
        or receipt.get("cohort") != manifest["cohort"]
        or receipt.get("evaluation_treatment") != manifest["evaluation_treatment"]
        or receipt.get("comparison") != manifest["comparison"]
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
        # 提交额 = 计分 trial 之和 + attempt-1 真实花费(2026-08-18 对抗
        # 审查 F4:染污 attempt 的钱是真钱,不入账即自欺)。
        or _integer(transaction.get("actual_cost_microusd"), "actual cost")
        != _integer(usage.get("cost_microusd"), "usage cost")
        + sum(
            row.get("cost_microusd") or 0
            for row in (usage.get("resumed_attempts") or {}).values()
        )
        or _integer(transaction.get("actual_metered_tokens"), "actual tokens")
        != _integer(usage.get("metered_tokens"), "usage tokens")
        + sum(
            row.get("metered_tokens") or 0
            for row in (usage.get("resumed_attempts") or {}).values()
        )
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
        # revision-gap 绑定(2026-08-18 对抗审查 J3):授权与提交之间的账本
        # 事件恰为 trial-resume 授权(0 或 1 个)。藏匿 resumes 块 → gap=2
        # 与期望 3 不符;伪造 → gap=1 与期望 4 不符。字节重放已绑账本,
        # 这一算式把披露块也钉进同一条链。
        or _integer(transaction.get("commit_revision"), "commit revision", minimum=1)
        != 3 + (1 if "resumes" in receipt else 0)
        or _integer(transaction.get("journal_revision"), "journal revision", minimum=1)
        != 3 + (1 if "resumes" in receipt else 0)
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
    # resumes 内容绑定(2026-08-18 第二轮审查 C2):revision-gap 只绑事件
    # 计数;披露块的任务名/证据哈希/理由必须逐字节复现账本授权的
    # evidence_sha256——否则报告可以宣称一个从未被重跑的 trial 被重跑了。
    replayed_transaction = (replayed.get("transactions") or {}).get(
        str(transaction["transaction_id"])
    ) or {}
    journaled_resume_events = list(
        replayed_transaction.get("resume_events") or []
    )
    if "resumes" in receipt:
        if len(journaled_resume_events) != 1:
            raise LaunchError(
                "paired WorkBuddy resumes disclosure has no journaled "
                "authorization"
            )
        event = journaled_resume_events[0]
        plain_rows = sorted(
            (
                {
                    key: str(value)
                    for key, value in row.items()
                    if key != "attempt1_usage"
                }
                for row in receipt["resumes"]
            ),
            key=lambda row: row["task"],
        )
        if sorted(event.get("trials") or []) != [
            row["task"] for row in plain_rows
        ] or _canonical_sha256({"rows": plain_rows}) != event.get(
            "evidence_sha256"
        ):
            raise LaunchError(
                "paired WorkBuddy resumes disclosure does not match the "
                "journaled authorization"
            )
    elif journaled_resume_events:
        raise LaunchError(
            "paired WorkBuddy journal records a resume authorization the "
            "receipt does not disclose"
        )
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
    # Rewards are the primary outcome variable, and until now the only
    # receipt numbers with no cross-artifact binding: cost and tokens are
    # pinned to the journal-authenticated transaction above, while
    # verifier_reward had only intra-receipt consistency (harness review
    # 2026-08-17 finding: a post-processing bug touching cost is caught,
    # the same bug touching reward was invisible). Every current-era task
    # row names its trial result by content hash; re-read the artifact and
    # require the committed reward to match it exactly.
    reward_bound_rows = {
        task: row
        for task, row in usage["tasks"].items()
        if "trial_result_sha256" in row
    }
    if manifest.get("schema_version") == SCHEMA_VERSION and set(
        reward_bound_rows
    ) != set(usage["tasks"]):
        raise LaunchError(
            "paired WorkBuddy receipt lacks trial-result bindings for some tasks"
        )
    if reward_bound_rows:
        if results_root is not None:
            # Analysis-time override: the manifest pins the checkout's
            # absolute (typically tmp) path; after archival the same
            # receipts remain analyzable against the moved results tree.
            result_root = results_root / str(manifest["job"]["slug"])
        else:
            checkout_raw = (manifest.get("workbuddy") or {}).get("checkout")
            if not isinstance(checkout_raw, str) or not checkout_raw:
                raise LaunchError(
                    "paired WorkBuddy manifest lacks its checkout path for reward binding"
                )
            result_root = (
                Path(checkout_raw) / "results" / str(manifest["job"]["slug"])
            )
        by_sha: Dict[str, Path] = {}
        if result_root.exists():
            for candidate in result_root.rglob("result.json"):
                if candidate.is_file():
                    digest = hashlib.sha256(candidate.read_bytes()).hexdigest()
                    by_sha[digest] = candidate
        for task, row in reward_bound_rows.items():
            artifact_path = by_sha.get(str(row.get("trial_result_sha256")))
            if artifact_path is None:
                raise LaunchError(
                    f"paired WorkBuddy trial result artifact is missing: {task}"
                )
            try:
                artifact = json.loads(artifact_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise LaunchError(
                    f"paired WorkBuddy trial result artifact is unreadable: {task}"
                ) from exc
            verifier = artifact.get("verifier_result")
            rewards = (
                verifier.get("rewards") if isinstance(verifier, dict) else None
            )
            artifact_reward = (
                rewards.get("reward") if isinstance(rewards, dict) else None
            )
            if (
                not isinstance(artifact_reward, (int, float))
                or isinstance(artifact_reward, bool)
                or not math.isfinite(float(artifact_reward))
                or float(artifact_reward) != row.get("verifier_reward")
            ):
                raise LaunchError(
                    f"paired WorkBuddy committed reward disagrees with its trial artifact: {task}"
                )
    journal_identity = {
        "path": journal_locator,
        "bytes": len(checkpoint),
        "sha256": _sha256_bytes(checkpoint),
    }
    return receipt, receipt_identity, journal_identity


def _validate_study_treatment(
    manifests: Mapping[str, Mapping[str, Any]], study: str
) -> None:
    if study not in STUDIES:
        raise LaunchError(f"paired WorkBuddy study is unsupported: {study}")
    for arm, manifest in manifests.items():
        treatment = manifest["evaluation_treatment"]
        project_mode = treatment.get("project_control")
        checkpoint = treatment.get("verification_checkpoint")
        memory = treatment.get("memory_accumulation")
        if study == PROJECT_CONTROL:
            if (
                project_mode != PROJECT_CONTROL_ARMS[arm]
                or checkpoint not in {None, False}
                or memory not in {None, False}
                or treatment.get("requirement_ledger") not in {None, False}
            ):
                raise LaunchError(
                    f"paired WorkBuddy {arm} has the wrong project-control treatment"
                )
        elif study == VERIFICATION_CHECKPOINT:
            if (
                project_mode != "disabled"
                or checkpoint is not CHECKPOINT_ARMS[arm]
                or memory not in {None, False}
                or treatment.get("requirement_ledger") not in {None, False}
            ):
                raise LaunchError(
                    f"paired WorkBuddy {arm} has the wrong verification-checkpoint treatment"
                )
        elif study == FULL_STACK:
            if (
                project_mode != FULL_STACK_PROJECT_ARMS[arm]
                or checkpoint is not False
                or treatment.get("verification_final_gate")
                is not FULL_STACK_GATE_ARMS[arm]
                or treatment.get("verification_final_observe")
                is not FULL_STACK_OBSERVE_ARMS[arm]
                or treatment.get("requirement_ledger")
                is not FULL_STACK_LEDGER_ARMS[arm]
                or treatment.get("requirement_ledger_observe")
                is not FULL_STACK_LEDGER_OBSERVE_ARMS[arm]
                or memory is not False
            ):
                raise LaunchError(
                    f"paired WorkBuddy {arm} has the wrong full-stack treatment"
                )
        elif study == MEMORY_ACCUMULATION:
            if (
                project_mode != "disabled"
                or checkpoint is not False
                or treatment.get("verification_final_gate") is not False
                or treatment.get("verification_final_observe") is not False
                or memory is not MEMORY_ARMS[arm]
                or treatment.get("requirement_ledger") not in {None, False}
            ):
                raise LaunchError(
                    f"paired WorkBuddy {arm} has the wrong memory-accumulation treatment"
                )
        else:
            if (
                project_mode != "disabled"
                or checkpoint is not False
                or treatment.get("verification_final_gate")
                is not FINAL_GATE_ARMS[arm]
                or treatment.get("verification_final_observe")
                is not FINAL_OBSERVE_ARMS[arm]
                or memory not in {None, False}
                or treatment.get("requirement_ledger") not in {None, False}
            ):
                raise LaunchError(
                    f"paired WorkBuddy {arm} has the wrong final-gate treatment"
                )


def _lean_is_inactive(control: object) -> bool:
    if not isinstance(control, dict):
        return False
    lean = control.get("lean")
    if not isinstance(lean, dict) or lean.get("used") is not False:
        return False
    for name, value in lean.items():
        if name == "used":
            continue
        if isinstance(value, bool):
            return False
        if isinstance(value, int):
            if value != 0:
                return False
        elif isinstance(value, list):
            if value:
                return False
        elif isinstance(value, dict):
            if any(
                isinstance(item, bool)
                or not isinstance(item, int)
                or item != 0
                for item in value.values()
            ):
                return False
        else:
            return False
    return True


def _optional_progress_number(value: object, where: str) -> float | None:
    return None if value is None else _number(value, where)


def _progress_evidence(
    row: Mapping[str, Any], *, arm: str, task: str
) -> Dict[str, Any]:
    metrics = row.get("progress_metrics")
    control = row.get("control_metrics")
    if not isinstance(metrics, dict) or not isinstance(control, dict):
        raise LaunchError(f"paired WorkBuddy {task} {arm} lacks progress evidence")
    source = metrics.get("source")
    progress = metrics.get("progress")
    if (
        metrics.get("schema_version") != "metacodes-workbuddy-progress-analysis-v1"
        or source
        != {
            "transcript_sha256": control.get("source", {}).get("transcript_sha256"),
            "observation_journal_sha256": control.get("source", {}).get(
                "observation_journal_sha256"
            ),
        }
        or metrics.get("privacy")
        != {
            "tool_arguments_retained": False,
            "tool_results_retained": False,
            "paths_retained": False,
            "memory_text_retained": False,
        }
        or not isinstance(progress, dict)
    ):
        raise LaunchError(f"paired WorkBuddy {task} {arm} progress evidence is invalid")
    required_ints = (
        "tool_calls",
        "mutation_calls",
        "mutations_after_first_successful_verification",
        "verification_calls",
        "successful_verifications",
        "exact_repeated_tool_input_result_calls",
        "checkpoint_messages",
        "checkpoint_messages_after_successful_verification",
    )
    for name in required_ints:
        _integer(progress.get(name), f"{task} {arm} progress {name}")
    for name in (
        "first_mutation_call",
        "first_successful_verification_call",
        "calls_after_first_successful_verification",
    ):
        if progress.get(name) is not None:
            _integer(progress[name], f"{task} {arm} progress {name}", minimum=1 if name != "calls_after_first_successful_verification" else 0)
    for name in (
        "time_to_first_mutation_ms",
        "time_to_first_successful_verification_ms",
        "time_after_first_successful_verification_ms",
        "time_to_final_dispatch_ms",
    ):
        _optional_progress_number(progress.get(name), f"{task} {arm} progress {name}")
    first_green = progress.get("first_successful_verification_call")
    checkpoint_count = progress["checkpoint_messages"]
    checkpoint_after_green = progress[
        "checkpoint_messages_after_successful_verification"
    ]
    expected = 1 if arm == "treatment" and first_green is not None else 0
    if checkpoint_count != expected or checkpoint_after_green != expected:
        raise LaunchError(
            f"paired WorkBuddy {task} {arm} checkpoint actuation is inconsistent"
        )
    tool_calls = progress["tool_calls"]
    first_mutation = progress.get("first_mutation_call")
    after_green = progress.get("calls_after_first_successful_verification")
    if (
        (first_mutation is None) != (progress["mutation_calls"] == 0)
        or (first_green is None) != (after_green is None)
        or (first_mutation is not None and first_mutation > tool_calls)
        or (first_green is not None and first_green > tool_calls)
        or (after_green is not None and after_green > tool_calls - first_green)
        or progress["mutations_after_first_successful_verification"]
        > progress["mutation_calls"]
        or progress["successful_verifications"] > progress["verification_calls"]
    ):
        raise LaunchError(
            f"paired WorkBuddy {task} {arm} progress aggregate is inconsistent"
        )
    return {"source": source, "progress": progress}


def _progress_delta(
    baseline: Mapping[str, Any], treatment: Mapping[str, Any], name: str
) -> float | int | None:
    before = baseline.get(name)
    after = treatment.get(name)
    if before is None or after is None:
        return None
    return after - before


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


def _verify_instrument_succession(
    b_comparison: Mapping[str, Any],
    t_comparison: Mapping[str, Any],
    manifests: Mapping[str, Mapping[str, Any]],
    baseline_receipt_path: Path,
) -> Dict[str, object]:
    """Admit host-control-plane (auditor) covariate differences only with
    earned, per-module proof of measurement neutrality.

    The auditors are the measuring instrument, not treatment variables, but
    silently accepting a different instrument per arm would let measurement
    drift masquerade as treatment effect.  Succession is therefore earned,
    not declared, per differing module: (a) the current in-repo module must
    be byte-identical to the one that measured the treatment arm, and (b)
    the baseline side must be proven neutral either by the receipt's own
    resume-audit witness (the committed baseline receipt names the current
    instrument) or by reproducing the receipt's committed per-task metrics
    exactly from artifacts located by the receipt's content hashes.
    Modules with neither proof path stay fail-closed, and treatment
    identities (binary/bundle/overlay/model) admit no succession at all."""

    from .progress_analysis import analyze_progress

    b_cov = dict(b_comparison.get("covariates") or {})
    t_cov = dict(t_comparison.get("covariates") or {})
    diff_keys = {
        key
        for key in set(b_cov) | set(t_cov)
        if json.dumps(b_cov.get(key), sort_keys=True)
        != json.dumps(t_cov.get(key), sort_keys=True)
    }
    if diff_keys != {"host_control_plane"}:
        raise LaunchError("paired WorkBuddy frozen covariates differ between arms")
    b_host = dict(b_cov["host_control_plane"])
    t_host = dict(t_cov["host_control_plane"])
    inner = {
        key
        for key in set(b_host) | set(t_host)
        if json.dumps(b_host.get(key), sort_keys=True)
        != json.dumps(t_host.get(key), sort_keys=True)
    }
    # Every host-control-plane module is an auditor — part of the measuring
    # instrument, never the treatment (the treatment lives in the mounted
    # binary/bundle/overlay identities, which admit no succession at all).
    # Still, succession is earned per module, and modules with no earned
    # proof path stay fail-closed.
    AUDITOR_MODULES = {
        "progress_analysis",
        "workbuddy_trace",
        "launch_gate",
        "paired_analysis",
    }
    if not inner or not inner <= AUDITOR_MODULES:
        raise LaunchError("paired WorkBuddy frozen covariates differ between arms")
    from .launch_gate import HOST_CONTROL_PLANE_MODULES

    current_shas: Dict[str, str] = {}
    for module in sorted(inner):
        module_path = HOST_CONTROL_PLANE_MODULES[module]
        current_shas[module] = hashlib.sha256(
            module_path.read_bytes()
        ).hexdigest()
        if current_shas[module] != str(
            (t_host.get(module) or {}).get("sha256")
        ):
            raise LaunchError(
                "instrument succession requires the current auditor to be "
                f"the one that measured the treatment arm ({module})"
            )
    receipt, _receipt_sha, _receipt_bytes = _observed_json(baseline_receipt_path)
    resume_auditor = (
        (receipt.get("resume_audit") or {}).get("auditor")
        if isinstance(receipt.get("resume_audit"), Mapping)
        else None
    )
    directly_witnessed = {
        module
        for module in inner
        if isinstance(resume_auditor, Mapping)
        and resume_auditor.get(module) == current_shas[module]
    }
    needs_reproduction = inner - directly_witnessed
    if not needs_reproduction <= {"progress_analysis", "workbuddy_trace"}:
        raise LaunchError(
            "instrument succession has no earned proof for "
            f"{sorted(needs_reproduction - {'progress_analysis', 'workbuddy_trace'})}; "
            "commit the baseline through launch_gate resume-audit first"
        )
    reverified = {module: "resume_audit_witness" for module in directly_witnessed}
    if needs_reproduction:
        from .trace import load_control_metrics

        tasks = ((receipt.get("usage") or {}).get("tasks")) or {}
        if not isinstance(tasks, Mapping) or not tasks:
            raise LaunchError(
                "instrument succession requires baseline task evidence"
            )
        checkout = Path(str(manifests["baseline"]["workbuddy"]["checkout"]))
        result_root = checkout / "results" / str(manifests["baseline"]["job"]["slug"])
        by_sha: Dict[str, Path] = {}
        if result_root.exists():
            for transcript in result_root.rglob("metacodes-transcript.jsonl"):
                digest = hashlib.sha256(transcript.read_bytes()).hexdigest()
                by_sha[digest] = transcript
        analyzers = {
            "progress_analysis": ("progress_metrics", analyze_progress),
            "workbuddy_trace": ("control_metrics", load_control_metrics),
        }
        for module in sorted(needs_reproduction):
            metrics_key, recompute = analyzers[module]
            count = 0
            for task, row in tasks.items():
                committed = (row or {}).get(metrics_key)
                if not isinstance(committed, Mapping):
                    raise LaunchError(
                        f"instrument succession lacks committed {metrics_key} for {task}"
                    )
                source = committed.get("source") or {}
                transcript_sha = str(source.get("transcript_sha256"))
                observation_sha = str(source.get("observation_journal_sha256"))
                transcript_path = by_sha.get(transcript_sha)
                if transcript_path is None:
                    raise LaunchError(
                        f"instrument succession cannot locate baseline artifacts for {task}"
                    )
                observation_path = (
                    transcript_path.parent / "metacodes-tool-observations.jsonl"
                )
                if (
                    not observation_path.is_file()
                    or hashlib.sha256(observation_path.read_bytes()).hexdigest()
                    != observation_sha
                ):
                    raise LaunchError(
                        f"instrument succession cannot bind baseline observations for {task}"
                    )
                recomputed = recompute(transcript_path, observation_path)
                if json.dumps(recomputed, sort_keys=True) != json.dumps(
                    committed, sort_keys=True
                ):
                    raise LaunchError(
                        f"instrument succession changed baseline {metrics_key} for {task}"
                    )
                count += 1
            reverified[module] = f"reproduced_byte_identical:{count}"
    return {
        "covariate": "host_control_plane",
        "modules": {
            module: {
                "baseline_sha256": str((b_host.get(module) or {}).get("sha256")),
                "treatment_sha256": str((t_host.get(module) or {}).get("sha256")),
                "proof": reverified[module],
            }
            for module in sorted(inner)
        },
    }


def _first_request_body(
    manifest: Mapping[str, Any],
    row: Mapping[str, Any],
    task: str,
    results_root: Path | None,
) -> Mapping[str, Any]:
    """Load one arm's audited first request body for a task, bound by the
    receipt's own content hashes (trial result sha locates the directory,
    the cacheable prefix sha must recompute from the loaded bytes)."""
    if results_root is not None:
        result_root = results_root / str(manifest["job"]["slug"])
    else:
        result_root = (
            Path(str((manifest.get("workbuddy") or {}).get("checkout")))
            / "results"
            / str(manifest["job"]["slug"])
        )
    wanted = str(row.get("trial_result_sha256"))
    located = None
    if result_root.exists():
        for candidate in result_root.rglob("result.json"):
            if not candidate.is_file():
                continue
            if hashlib.sha256(candidate.read_bytes()).hexdigest() == wanted:
                located = candidate
                break
    if located is None:
        raise LaunchError(
            f"dated cache-prefix exemption cannot locate the trial artifact: {task}"
        )
    request_log = located.parent / "agent" / "requests.jsonl"
    try:
        first_line = next(
            line
            for line in _read_regular(
                request_log, maximum=64 * 1024 * 1024
            ).splitlines()
            if line.strip()
        )
        body = json.loads(first_line.decode("utf-8"))["request"]["body"]
    except (
        OSError,
        UnicodeError,
        StopIteration,
        KeyError,
        TypeError,
        json.JSONDecodeError,
    ) as exc:
        raise LaunchError(
            f"dated cache-prefix exemption cannot read the first request: {task}"
        ) from exc
    if not isinstance(body, Mapping) or _cacheable_first_request_sha256(
        body
    ) != str(row.get("cacheable_first_request_sha256")):
        raise LaunchError(
            "dated cache-prefix exemption first request does not match the "
            f"audited prefix hash: {task}"
        )
    return body


def _verify_dated_prefix_drift(
    task: str,
    manifests: Mapping[str, Mapping[str, Any]],
    b_row: Mapping[str, Any],
    t_row: Mapping[str, Any],
    results_root: Path | None,
) -> None:
    normalized = {}
    for arm, row in (("baseline", b_row), ("treatment", t_row)):
        body = dict(
            _first_request_body(manifests[arm], row, task, results_root)
        )
        body.pop("model", None)
        text = stable_json(body)
        if not _DATED_PREFIX_PATTERN.search(text):
            raise LaunchError(
                "dated cache-prefix exemption found no date line in the "
                f"{arm} first request: {task}"
            )
        normalized[arm] = _DATED_PREFIX_PATTERN.sub(
            "Today's date is 0000/00/00", text
        )
    if normalized["baseline"] != normalized["treatment"]:
        raise LaunchError(
            "dated cache-prefix exemption refused: the first requests "
            f"differ beyond the date line for {task}"
        )


def build_report(
    *,
    study: str = PROJECT_CONTROL,
    baseline_manifest_path: Path,
    baseline_receipt_path: Path,
    baseline_journal_path: Path,
    treatment_manifest_path: Path,
    treatment_receipt_path: Path,
    treatment_journal_path: Path,
    accept_progress_analyzer_succession: bool = False,
    results_root: Path | None = None,
    accept_dated_cache_prefix: Sequence[str] = (),
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
    _validate_study_treatment(manifests, study)
    if study in {VERIFICATION_CHECKPOINT, VERIFICATION_FINAL_GATE, FULL_STACK}:
        for arm, manifest in manifests.items():
            host_modules = manifest.get("host_control_plane")
            if not isinstance(host_modules, dict) or "progress_analysis" not in host_modules:
                raise LaunchError(
                    f"paired WorkBuddy {arm} does not bind its progress analyzer"
                )
    b_comparison = manifests["baseline"]["comparison"]
    t_comparison = manifests["treatment"]["comparison"]
    instrument_succession: Dict[str, object] | None = None
    if b_comparison.get("comparison_id") != t_comparison.get("comparison_id"):
        raise LaunchError("paired WorkBuddy frozen covariates differ between arms")
    if (
        b_comparison.get("covariates_sha256")
        != t_comparison.get("covariates_sha256")
        or b_comparison.get("covariates") != t_comparison.get("covariates")
    ):
        if not accept_progress_analyzer_succession:
            raise LaunchError("paired WorkBuddy frozen covariates differ between arms")
        instrument_succession = _verify_instrument_succession(
            b_comparison, t_comparison, manifests, baseline_receipt_path
        )

    receipt_observations = {
        "baseline": _receipt(
            baseline_receipt_path,
            baseline_journal_path,
            manifests["baseline"],
            results_root=results_root,
        ),
        "treatment": _receipt(
            treatment_receipt_path,
            treatment_journal_path,
            manifests["treatment"],
            results_root=results_root,
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
    accepted_dated = {str(name) for name in accept_dated_cache_prefix}
    dated_drift_tasks: list = []
    for task in manifests["baseline"]["cohort"]["selected_tasks"]:
        baseline = b_usage["tasks"][task]
        treatment = t_usage["tasks"][task]
        if baseline.get("task_checksum") != treatment.get("task_checksum"):
            raise LaunchError(
                f"paired WorkBuddy task/cache-prefix identity drifted for {task}"
            )
        if baseline.get("cacheable_first_request_sha256") != treatment.get(
            "cacheable_first_request_sha256"
        ):
            if task not in accepted_dated:
                raise LaunchError(
                    f"paired WorkBuddy task/cache-prefix identity drifted for {task}"
                )
            _verify_dated_prefix_drift(
                task, manifests, baseline, treatment, results_root
            )
            dated_drift_tasks.append(task)
        b_reward = _number(baseline.get("verifier_reward"), f"{task} baseline reward")
        t_reward = _number(treatment.get("verifier_reward"), f"{task} treatment reward")
        if max(b_reward, t_reward) > 1.0:
            raise LaunchError(f"paired WorkBuddy reward exceeds one for {task}")
        delta = t_reward - b_reward
        improved += int(delta > 0)
        regressed += int(delta < 0)
        unchanged += int(delta == 0)
        task_report: Dict[str, Any] = {
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
        if study == VERIFICATION_CHECKPOINT:
            if not _lean_is_inactive(baseline.get("control_metrics")) or not _lean_is_inactive(
                treatment.get("control_metrics")
            ):
                raise LaunchError(
                    f"paired WorkBuddy {task} checkpoint study contains Lean actuation"
                )
            b_progress = _progress_evidence(baseline, arm="baseline", task=task)
            t_progress = _progress_evidence(treatment, arm="treatment", task=task)
            task_report["progress"] = {
                "baseline": b_progress,
                "treatment": t_progress,
                "calls_after_first_successful_verification_delta": _progress_delta(
                    b_progress["progress"],
                    t_progress["progress"],
                    "calls_after_first_successful_verification",
                ),
                "mutations_after_first_successful_verification_delta": _progress_delta(
                    b_progress["progress"],
                    t_progress["progress"],
                    "mutations_after_first_successful_verification",
                ),
                "time_after_first_successful_verification_ms_delta": _progress_delta(
                    b_progress["progress"],
                    t_progress["progress"],
                    "time_after_first_successful_verification_ms",
                ),
            }
        tasks[task] = task_report

    b_quality = b_usage["quality"]
    t_quality = t_usage["quality"]
    quality_evidence = (
        receipts["baseline"]["quality_evidence"] is True
        and receipts["treatment"]["quality_evidence"] is True
    )
    # 陈旧豁免即拒:操作者点名的任务必须真的漂移,防止 flag 常驻脚本里
    # 静默吞掉未来其它任务的前缀漂移。
    unused_dated = accepted_dated - set(dated_drift_tasks)
    if unused_dated:
        raise LaunchError(
            "dated cache-prefix exemption named tasks that did not drift: "
            f"{sorted(unused_dated)}"
        )
    report: Dict[str, object] = {
        "schema_version": (
            REPORT_SCHEMA_VERSION
            if study == PROJECT_CONTROL
            else FINAL_GATE_REPORT_SCHEMA_VERSION
            if study == VERIFICATION_FINAL_GATE
            else MEMORY_REPORT_SCHEMA_VERSION
            if study == MEMORY_ACCUMULATION
            else FULL_STACK_REPORT_SCHEMA_VERSION
            if study == FULL_STACK
            else CHECKPOINT_REPORT_SCHEMA_VERSION
        ),
        **({"study": study} if study != PROJECT_CONTROL else {}),
        "quality_evidence": quality_evidence,
        "comparison_id": b_comparison["comparison_id"],
        "covariates_sha256": b_comparison["covariates_sha256"],
        **(
            {"instrument_succession": instrument_succession}
            if instrument_succession is not None
            else {}
        ),
        "arms": {
            arm: {
                "manifest": manifest_identities[arm],
                "receipt": receipt_identities[arm],
                "budget_journal": journal_identities[arm],
                "run_id": manifests[arm]["run_id"],
                "project_control": manifests[arm]["evaluation_treatment"][
                    "project_control"
                ],
                # 基础设施事件披露(非 treatment):哪些 trial 因已证实的
                # 瞬态被重跑。两臂并排给出,供解读者判断。
                "resumed_trials": [
                    row["task"] for row in receipts[arm].get("resumes", [])
                ],
                **(
                    {
                        "verification_checkpoint": manifests[arm][
                            "evaluation_treatment"
                        ].get("verification_checkpoint", False)
                    }
                    if study == VERIFICATION_CHECKPOINT
                    else {}
                ),
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
        "cache_prefix_equal_for_every_task": not dated_drift_tasks,
        "cache_prefix_dated_drift_tasks": sorted(dated_drift_tasks),
        "tasks": tasks,
        "claim_boundary": (
            "observed paired difference for this frozen task cohort and project-rule "
            "bundle; a single model sample per arm is not a causal effect estimate or "
            "evidence of general Lean/TinyKG superiority"
            if study == PROJECT_CONTROL
            else "observed paired difference for this frozen task cohort with only the "
            f"{study.replace('_', '-')} treatment intentionally changed; one model sample "
            "per arm is directional evidence, not a general causal effect estimate"
        ),
    }
    report["content_sha256"] = _canonical_sha256(report)
    return report


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--study", choices=sorted(STUDIES), default=PROJECT_CONTROL
    )
    parser.add_argument("--baseline-manifest", type=Path, required=True)
    parser.add_argument("--baseline-receipt", type=Path, required=True)
    parser.add_argument("--baseline-budget-journal", type=Path, required=True)
    parser.add_argument("--treatment-manifest", type=Path, required=True)
    parser.add_argument("--treatment-receipt", type=Path, required=True)
    parser.add_argument("--treatment-budget-journal", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--results-root",
        type=Path,
        default=None,
        help=(
            "Override the manifest-pinned checkout results directory for the "
            "reward-artifact binding (use after the checkout tree was "
            "archived or moved); expects the directory containing the "
            "<job-slug> result folders."
        ),
    )
    parser.add_argument(
        "--accept-progress-analyzer-succession",
        action="store_true",
        help=(
            "Admit a progress-analyzer difference between arms only after the "
            "current analyzer is proven byte-identical to the treatment's and "
            "reproduces every committed baseline progress metric exactly."
        ),
    )
    parser.add_argument(
        "--accept-dated-cache-prefix",
        action="append",
        default=[],
        metavar="TASK",
        help=(
            "Accept a cross-arm cache-prefix mismatch for TASK only after "
            "loading both arms' audited first requests and proving they "
            "differ solely in the injected current-date line (UTC-midnight "
            "rollover between arms). Disclosed in the report; a named task "
            "that did not drift fails closed."
        ),
    )
    args = parser.parse_args(argv)
    try:
        report = build_report(
            accept_progress_analyzer_succession=args.accept_progress_analyzer_succession,
            results_root=args.results_root,
            accept_dated_cache_prefix=args.accept_dated_cache_prefix,
            study=args.study,
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
