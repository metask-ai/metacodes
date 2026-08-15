"""Run a fresh shadow-to-Lean-promotion-to-held-out RuleImpact pilot.

The calibration cohort is used only to authorize the frozen rule.  Quality
comparisons use a disjoint held-out cohort and never feed grader output back to
the actor.  All provider calls reuse the paid E3 runner, durable budget journal,
anonymous credential FD, sandbox, cassette and cache-prefix contracts.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
from typing import Any, Dict, List, Mapping, Sequence

if __package__ in {None, ""}:
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from scripts.eval.memory_agent_runtime import (  # type: ignore
        PRODUCTION_MODEL_FINGERPRINT,
        _assert_executable_identity,
        _assert_production_secret_absent,
        _production_environment,
        _replace_private_file,
        _write_new,
    )
    from scripts.eval.memory_agent_runtime_pilot import _load_api_key  # type: ignore
    from scripts.eval.memory_budget_journal import (  # type: ignore
        BudgetAuthority,
        BudgetJournal,
        MAX_USER_AUTHORITY_USD,
        usd_to_microusd,
        usd_to_microusd_ceiling,
    )
    from scripts.eval.memory_replay import (  # type: ignore
        PRODUCTION_MODEL_ID,
        PRODUCTION_MODEL_PROVIDER,
        PRODUCTION_PROVIDER_ID,
    )
    from scripts.eval.model import stable_json  # type: ignore
    from scripts.eval.project_harness_e3_experiment import (  # type: ignore
        ARM_CONFIG as BASE_ARM_CONFIG,
        E3_ALLOWED_TOOLS,
        E3_AUTO_MEMORY_POLICY,
        E3_DISALLOWED_TOOLS,
        E3_LONG_HORIZON_ARM,
        E3_ROLLOUT_TIMEOUT_SECONDS,
        E3Error,
        _artifact,
        _canonical_sha256,
        _git_identity,
        _harness_fingerprint,
        _journal_events,
        _kernel_runtime_dependencies,
        _read_json,
        _read_regular,
        _reopen_rollout_receipt,
        _sha256_file,
        _validate_execution_contract,
    )
    from scripts.eval.project_harness_e3_pilot import _run_one  # type: ignore
    from scripts.eval.project_harness_e3_templates import verify_templates  # type: ignore
    from scripts.eval.project_harness_rule_impact_cases import (  # type: ignore
        ALL_CASES,
        CALIBRATION_CASES,
        FRESHNESS,
        HELDOUT_CASES,
    )
    from scripts.eval.statistics import exact_mcnemar, wilson_interval  # type: ignore
else:
    from .memory_agent_runtime import (
        PRODUCTION_MODEL_FINGERPRINT,
        _assert_executable_identity,
        _assert_production_secret_absent,
        _production_environment,
        _replace_private_file,
        _write_new,
    )
    from .memory_agent_runtime_pilot import _load_api_key
    from .memory_budget_journal import (
        BudgetAuthority,
        BudgetJournal,
        MAX_USER_AUTHORITY_USD,
        usd_to_microusd,
        usd_to_microusd_ceiling,
    )
    from .memory_replay import (
        PRODUCTION_MODEL_ID,
        PRODUCTION_MODEL_PROVIDER,
        PRODUCTION_PROVIDER_ID,
    )
    from .model import stable_json
    from .project_harness_e3_experiment import (
        ARM_CONFIG as BASE_ARM_CONFIG,
        E3_ALLOWED_TOOLS,
        E3_AUTO_MEMORY_POLICY,
        E3_DISALLOWED_TOOLS,
        E3_LONG_HORIZON_ARM,
        E3_ROLLOUT_TIMEOUT_SECONDS,
        E3Error,
        _artifact,
        _canonical_sha256,
        _git_identity,
        _harness_fingerprint,
        _journal_events,
        _kernel_runtime_dependencies,
        _read_json,
        _read_regular,
        _reopen_rollout_receipt,
        _sha256_file,
        _validate_execution_contract,
    )
    from .project_harness_e3_pilot import _run_one
    from .project_harness_e3_templates import verify_templates
    from .project_harness_rule_impact_cases import (
        ALL_CASES,
        CALIBRATION_CASES,
        FRESHNESS,
        HELDOUT_CASES,
    )
    from .statistics import exact_mcnemar, wilson_interval


MANIFEST_SCHEMA = "metacodes-rule-impact-prospective-manifest-v1"
ROLLOUT_SCHEMA = "metacodes-rule-impact-prospective-rollout-v1"
CHECKPOINT_SCHEMA = "metacodes-rule-impact-prospective-checkpoint-v1"
PROMOTION_SCHEMA = "metacodes-rule-impact-prospective-promotion-v1"
REPORT_SCHEMA = "metacodes-rule-impact-prospective-report-v1"
ISSUE_RESULT_SCHEMA = "metacodes-rule-impact-driver-issue-result-v1"
AGGREGATE_RESULT_SCHEMA = "metacodes-rule-impact-driver-aggregate-result-v1"
STUDY_ID = "rule-impact-shadow-promotion-heldout-20260811-v1"
SCHEDULE_SEED = "metacodes-rule-impact-prospective-balanced-v1"
POLICY_EPOCH = 1
CALIBRATION_ARM = "evolved_shadow"
HELDOUT_ARMS = ("signal_only", "evolved_shadow", "evolved_enforced")
ARM_CONFIG = {arm: BASE_ARM_CONFIG[arm] for arm in HELDOUT_ARMS}
CALIBRATION_COUNT = len(CALIBRATION_CASES)
CHECKPOINT_NAME = "checkpoint.json"
PROMOTION_NAME = "promotion-receipt.json"
RUN_AUTHORIZATION_SCHEMA = "metacodes-rule-impact-run-authorization-v1"
MAX_CONTROL_BYTES = 16 * 1024 * 1024
ISSUE_RESULT_FIELDS = frozenset(
    {
        "schema_version",
        "provider_requests_made_by_driver",
        "session_dir",
        "project_sha256",
        "issuer_sha256",
        "observation",
        "source_interval_sha256",
        "outcome_evidence_name",
        "outcome_evidence_sha256",
        "usage_evidence_name",
        "usage_evidence_sha256",
        "receipt_id",
        "receipt_created",
    }
)
AGGREGATE_STABLE_FIELDS = frozenset(
    {
        "schema_version",
        "provider_requests_made_by_driver",
        "aggregate_dir",
        "aggregate_receipt_id",
        "member_count",
        "request_sha256",
        "verdict_sha256",
        "actual_checker_sha256",
        "request_bytes",
        "failure",
        "checker_stdout",
        "checker_stderr",
        "admitted",
        "checks",
    }
)


ANALYSIS_PLAN: Mapping[str, Any] = {
    "schema_version": "metacodes-rule-impact-prospective-analysis-v1",
    "calibration_cases": len(CALIBRATION_CASES),
    "calibration_arm": CALIBRATION_ARM,
    "calibration_use": "promotion-only-not-heldout-quality",
    "heldout_cases": len(HELDOUT_CASES),
    "heldout_arms": list(HELDOUT_ARMS),
    "primary_contrast": "signal_only-vs-evolved_enforced",
    "primary_metrics": ["task_success", "trustworthy_success"],
    "secondary_metrics": [
        "false_interventions",
        "paired_regressions",
        "provider_requests",
        "input_output_cache_tokens",
        "cost_usd",
        "wall_model_tool_harness_checker_time",
    ],
    "stopping_rule": (
        "complete calibration then require Lean admission before any held-out "
        "request; complete the frozen held-out schedule without outcome-based stopping"
    ),
    "infrastructure_rule": "halt-and-forbid-automatic-retry-after-authorization",
    "promotion_semantics": "authorization-only-no-canonical-lifecycle-cas",
}

TINYKG_ISOLATION: Mapping[str, Any] = {
    "runtime_mode": "disabled-no-memory-tools",
    "isolated_local_required_if_enabled": True,
    "remote_harness_forbidden": True,
    "raw_artifacts_local_only": True,
}

CACHE_CONTRACT: Mapping[str, Any] = {
    "actor_system_prompt_unchanged": True,
    "provider_tool_schema_unchanged": True,
    "first_request_bytes_equal_within_heldout_case": True,
    "cacheable_prefix_equal_within_heldout_case": True,
}


def _promotion_policy(execution: Mapping[str, Any]) -> Mapping[str, Any]:
    return {
        "min_exposures": len(CALIBRATION_CASES),
        "max_formal_faults": 0,
        "max_shadow_divergences": len(CALIBRATION_CASES),
        "max_false_interventions": 0,
        "max_regressions": 0,
        "max_provider_requests": len(CALIBRATION_CASES) * 8,
        "max_metered_tokens": len(CALIBRATION_CASES)
        * int(execution["max_rollout_metered_tokens"]),
        "max_cost_microusd": usd_to_microusd(
            len(CALIBRATION_CASES) * float(execution["max_rollout_cost_usd"])
        ),
        "max_wall_elapsed_ns": len(CALIBRATION_CASES)
        * E3_ROLLOUT_TIMEOUT_SECONDS
        * 1_000_000_000,
    }


def _schedule() -> List[Mapping[str, Any]]:
    rows: List[Mapping[str, Any]] = []
    for case in CALIBRATION_CASES:
        rows.append(
            {
                "sequence": len(rows),
                "phase": "calibration",
                "case_id": case["id"],
                "trial": 0,
                "position": 0,
                "arm": CALIBRATION_ARM,
            }
        )
    ranked = sorted(
        (str(case["id"]) for case in HELDOUT_CASES),
        key=lambda case_id: hashlib.sha256(
            f"{SCHEDULE_SEED}:{case_id}".encode("utf-8")
        ).digest(),
    )
    rotations = {case_id: index % len(HELDOUT_ARMS) for index, case_id in enumerate(ranked)}
    for case in HELDOUT_CASES:
        rotation = rotations[str(case["id"])]
        arms = HELDOUT_ARMS[rotation:] + HELDOUT_ARMS[:rotation]
        for position, arm in enumerate(arms):
            rows.append(
                {
                    "sequence": len(rows),
                    "phase": "heldout",
                    "case_id": case["id"],
                    "trial": 0,
                    "position": position,
                    "arm": arm,
                }
            )
    return rows


SCHEDULE = _schedule()


def _validate_schedule() -> None:
    if len(SCHEDULE) != CALIBRATION_COUNT + len(HELDOUT_CASES) * len(HELDOUT_ARMS):
        raise RuntimeError("prospective RuleImpact schedule length drift")
    if any(row["phase"] != "calibration" for row in SCHEDULE[:CALIBRATION_COUNT]):
        raise RuntimeError("held-out rollout entered the calibration prefix")
    if any(row["phase"] != "heldout" for row in SCHEDULE[CALIBRATION_COUNT:]):
        raise RuntimeError("calibration rollout escaped its frozen prefix")
    for case in HELDOUT_CASES:
        rows = [row for row in SCHEDULE if row["case_id"] == case["id"]]
        if {row["arm"] for row in rows} != set(HELDOUT_ARMS) or sorted(
            int(row["position"]) for row in rows
        ) != list(range(len(HELDOUT_ARMS))):
            raise RuntimeError("held-out arm balance drift")
    if [int(row["sequence"]) for row in SCHEDULE] != list(range(len(SCHEDULE))):
        raise RuntimeError("prospective RuleImpact schedule sequence drift")
    for arm in HELDOUT_ARMS:
        counts = [
            sum(
                row["phase"] == "heldout"
                and row["arm"] == arm
                and row["position"] == position
                for row in SCHEDULE
            )
            for position in range(len(HELDOUT_ARMS))
        ]
        if max(counts) - min(counts) > 1:
            raise RuntimeError("held-out arm position balance drift")


_validate_schedule()


def _issuer_sha256(repository: Mapping[str, Any], driver_sha256: str) -> str:
    return _canonical_sha256(
        {
            "domain": "metacodes-rule-impact-prospective-issuer-v1",
            "study_id": STUDY_ID,
            "repository": repository,
            "driver_sha256": driver_sha256,
            "grader": "exact-workspace-and-native-journal-v1",
        }
    )


def freeze_manifest(
    *,
    repo: Path,
    templates_manifest: Path,
    production_binary: Path,
    shadow_binary: Path,
    rule_impact_driver: Path,
    ripgrep: Path,
    max_rollout_cost_usd: float,
    max_rollout_metered_tokens: int,
    max_total_cost_usd: float,
    max_total_metered_tokens: int,
    max_output_tokens: int,
) -> Mapping[str, Any]:
    repo = repo.resolve(strict=True)
    repository = dict(_git_identity(repo))
    if repository["dirty"]:
        raise E3Error("prospective RuleImpact preregistration requires a clean repository")
    templates_path = templates_manifest.resolve(strict=True)
    templates = verify_templates(templates_path, repo)
    if templates.get("paid_rollout_eligible") is not True:
        raise E3Error("project-Harness templates are not paid-rollout eligible")
    production = _artifact(production_binary)
    shadow = _artifact(shadow_binary)
    driver = _artifact(rule_impact_driver)
    frozen_ripgrep = _artifact(ripgrep)
    if production["sha256"] == shadow["sha256"]:
        raise E3Error("production and shadow binaries unexpectedly alias")
    kernel = {
        **templates["artifacts"]["kernel"],
        "runtime_dependencies": _kernel_runtime_dependencies(
            Path(str(templates["artifacts"]["kernel"]["path"]))
        ),
    }
    if max_total_cost_usd > MAX_USER_AUTHORITY_USD or max_total_cost_usd <= 0:
        raise E3Error("prospective RuleImpact cost authority is invalid")
    execution = {
        "provider_identity": PRODUCTION_PROVIDER_ID,
        "model_provider": PRODUCTION_MODEL_PROVIDER,
        "model_id": PRODUCTION_MODEL_ID,
        "model_fingerprint": PRODUCTION_MODEL_FINGERPRINT,
        "allowed_tools": list(E3_ALLOWED_TOOLS),
        "disallowed_tools": list(E3_DISALLOWED_TOOLS),
        "max_output_tokens": max_output_tokens,
        "rollout_timeout_seconds": E3_ROLLOUT_TIMEOUT_SECONDS,
        "max_rollout_cost_usd": float(max_rollout_cost_usd),
        "max_rollout_metered_tokens": max_rollout_metered_tokens,
        "max_total_cost_usd": float(max_total_cost_usd),
        "max_total_metered_tokens": max_total_metered_tokens,
        "serial_rollouts": True,
        "fresh_home_per_rollout": True,
        "stable_absolute_project_root": True,
        "auto_memory_policy": E3_AUTO_MEMORY_POLICY,
        "long_horizon_arm": E3_LONG_HORIZON_ARM,
    }
    policy = _promotion_policy(execution)
    body: Dict[str, Any] = {
        "schema_version": MANIFEST_SCHEMA,
        "study_id": STUDY_ID,
        "experiment_kind": "paid-glm-rule-impact-prospective-pilot",
        "evidence_level": "E3-prospective-preregistered",
        "quality_evidence": False,
        "repository": repository,
        "root": templates["root"],
        "project_root": templates["project_root"],
        "project_sha256": templates["project_sha256"],
        "issuer_sha256": _issuer_sha256(repository, str(driver["sha256"])),
        "templates_manifest": {
            "path": str(templates_path),
            "sha256": _sha256_file(templates_path),
            "evolved_bundle_sha256": templates["templates"]["evolved"]["bundle_sha256"],
            "evolved_candidate_id": templates["templates"]["evolved"]["candidate_id"],
            "evolved_bundle_revision": templates["templates"]["evolved"]["bundle_revision"],
        },
        "artifacts": {
            "production_binary": production,
            "shadow_binary": shadow,
            "kernel": kernel,
            "rule_impact_driver": driver,
            "ripgrep": frozen_ripgrep,
        },
        "execution": execution,
        "arms": ARM_CONFIG,
        "cases": list(ALL_CASES),
        "calibration_case_ids": [case["id"] for case in CALIBRATION_CASES],
        "heldout_case_ids": [case["id"] for case in HELDOUT_CASES],
        "schedule": list(SCHEDULE),
        "policy_epoch": POLICY_EPOCH,
        "promotion_policy": policy,
        "analysis_plan": ANALYSIS_PLAN,
        "freshness": FRESHNESS,
        "tinykg_isolation": TINYKG_ISOLATION,
        "cache_contract": CACHE_CONTRACT,
    }
    _validate_execution_contract(execution, len(SCHEDULE))
    body["manifest_id"] = _canonical_sha256(body)
    return body


def _validate_artifact(item: Any, label: str) -> Path:
    if not isinstance(item, Mapping):
        raise E3Error(f"prospective artifact missing: {label}")
    path = Path(str(item.get("path", ""))).resolve(strict=True)
    if _sha256_file(path) != item.get("sha256"):
        raise E3Error(f"prospective artifact drift: {label}")
    _assert_executable_identity(path, str(item["sha256"]), label)
    return path


def validate_manifest(path: Path, repo: Path) -> Mapping[str, Any]:
    manifest = _read_json(path.resolve(strict=True))
    manifest_id = manifest.get("manifest_id")
    body = dict(manifest)
    body.pop("manifest_id", None)
    if not isinstance(manifest_id, str) or _canonical_sha256(body) != manifest_id:
        raise E3Error("prospective manifest identity drift")
    manifest_fields = {
        "schema_version",
        "study_id",
        "experiment_kind",
        "evidence_level",
        "quality_evidence",
        "repository",
        "root",
        "project_root",
        "project_sha256",
        "issuer_sha256",
        "templates_manifest",
        "artifacts",
        "execution",
        "arms",
        "cases",
        "calibration_case_ids",
        "heldout_case_ids",
        "schedule",
        "policy_epoch",
        "promotion_policy",
        "analysis_plan",
        "freshness",
        "tinykg_isolation",
        "cache_contract",
        "manifest_id",
    }
    if (
        set(manifest) != manifest_fields
        or manifest.get("schema_version") != MANIFEST_SCHEMA
        or manifest.get("study_id") != STUDY_ID
        or manifest.get("experiment_kind")
        != "paid-glm-rule-impact-prospective-pilot"
        or manifest.get("evidence_level") != "E3-prospective-preregistered"
        or manifest.get("quality_evidence") is not False
        or manifest.get("arms") != ARM_CONFIG
        or manifest.get("cases") != list(ALL_CASES)
        or manifest.get("calibration_case_ids")
        != [case["id"] for case in CALIBRATION_CASES]
        or manifest.get("heldout_case_ids")
        != [case["id"] for case in HELDOUT_CASES]
        or manifest.get("schedule") != list(SCHEDULE)
        or manifest.get("analysis_plan") != ANALYSIS_PLAN
        or manifest.get("freshness") != FRESHNESS
        or manifest.get("policy_epoch") != POLICY_EPOCH
        or manifest.get("tinykg_isolation") != TINYKG_ISOLATION
        or manifest.get("cache_contract") != CACHE_CONTRACT
    ):
        raise E3Error("prospective manifest contract drift")
    repo = repo.resolve(strict=True)
    if dict(_git_identity(repo)) != manifest.get("repository"):
        raise E3Error("prospective repository identity drift")
    templates_path = Path(str(manifest["templates_manifest"]["path"]))
    if _sha256_file(templates_path) != manifest["templates_manifest"]["sha256"]:
        raise E3Error("prospective template manifest drift")
    templates = verify_templates(templates_path, repo)
    if (
        manifest.get("root") != templates["root"]
        or manifest.get("project_root") != templates["project_root"]
        or manifest.get("project_sha256") != templates["project_sha256"]
        or manifest["templates_manifest"]["evolved_candidate_id"]
        != templates["templates"]["evolved"]["candidate_id"]
        or manifest["templates_manifest"]["evolved_bundle_sha256"]
        != templates["templates"]["evolved"]["bundle_sha256"]
        or manifest["templates_manifest"]["evolved_bundle_revision"]
        != templates["templates"]["evolved"]["bundle_revision"]
    ):
        raise E3Error("prospective template identity drift")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, Mapping):
        raise E3Error("prospective artifacts missing")
    production = _validate_artifact(artifacts.get("production_binary"), "production binary")
    shadow = _validate_artifact(artifacts.get("shadow_binary"), "shadow binary")
    _validate_artifact(artifacts.get("kernel"), "project kernel")
    _validate_artifact(artifacts.get("rule_impact_driver"), "RuleImpact driver")
    _validate_artifact(artifacts.get("ripgrep"), "ripgrep")
    if _sha256_file(production) == _sha256_file(shadow):
        raise E3Error("prospective production/shadow artifact alias")
    kernel = Path(str(artifacts["kernel"]["path"]))
    if artifacts["kernel"].get("runtime_dependencies") != _kernel_runtime_dependencies(kernel):
        raise E3Error("prospective kernel runtime dependency drift")
    execution = _validate_execution_contract(manifest.get("execution"), len(SCHEDULE))
    if manifest.get("promotion_policy") != _promotion_policy(execution):
        raise E3Error("prospective promotion policy drift")
    expected_issuer = _issuer_sha256(
        manifest["repository"], str(artifacts["rule_impact_driver"]["sha256"])
    )
    if manifest.get("issuer_sha256") != expected_issuer:
        raise E3Error("prospective issuer identity drift")
    return manifest


def _checkpoint_payload(
    manifest: Mapping[str, Any],
    completed: Sequence[Mapping[str, Any]],
    budget: BudgetJournal,
    promotion: Mapping[str, Any] | None,
) -> bytes:
    snapshot = budget.snapshot()
    value = {
        "schema_version": CHECKPOINT_SCHEMA,
        "manifest_id": manifest["manifest_id"],
        "completed": list(completed),
        "promotion": promotion,
        "budget_journal_id": snapshot["journal_id"],
        "budget_revision": snapshot["revision"],
        "budget_head_sha256": snapshot["head_sha256"],
    }
    return (stable_json(value) + "\n").encode("utf-8")


def _reopen_rollout(
    manifest: Mapping[str, Any],
    run_dir: Path,
    expected: Mapping[str, Any],
    path: Path,
    run_authorization: Mapping[str, Any] | None = None,
) -> Mapping[str, Any]:
    row = _reopen_rollout_receipt(
        manifest=manifest,
        run_dir=run_dir,
        expected=expected,
        path=path,
        expected_rollout_schema=ROLLOUT_SCHEMA,
        arm_config=ARM_CONFIG,
        expected_run_authorization=run_authorization,
    )
    if row.get("phase") != expected.get("phase"):
        raise E3Error("prospective rollout crossed the calibration/held-out boundary")
    return row


def _run_driver_request(
    *,
    manifest: Mapping[str, Any],
    request_path: Path,
    output_path: Path,
) -> Mapping[str, Any]:
    driver_item = manifest["artifacts"]["rule_impact_driver"]
    driver = Path(str(driver_item["path"]))
    _assert_executable_identity(driver, str(driver_item["sha256"]), "RuleImpact driver before call")
    env = _production_environment(os.environ)
    env.update({"LC_ALL": "C", "LANG": "C"})
    completed = subprocess.run(
        [str(driver), "--request", str(request_path), "--output", str(output_path)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=60,
        check=False,
        env=env,
    )
    _assert_executable_identity(driver, str(driver_item["sha256"]), "RuleImpact driver after call")
    if completed.returncode != 0:
        raise E3Error(
            "RuleImpact driver failed closed: "
            + hashlib.sha256(completed.stderr.encode("utf-8")).hexdigest()
        )
    result = _read_json(output_path)
    if result.get("provider_requests_made_by_driver") != 0:
        raise E3Error("RuleImpact driver crossed the provider boundary")
    return result


def _invoke_driver(
    *,
    manifest: Mapping[str, Any],
    request: Mapping[str, Any],
    request_path: Path,
    output_path: Path,
) -> Mapping[str, Any]:
    _write_new(request_path, (stable_json(request) + "\n").encode("utf-8"))
    return _run_driver_request(
        manifest=manifest,
        request_path=request_path,
        output_path=output_path,
    )


def _issue_request(
    manifest: Mapping[str, Any], row: Mapping[str, Any]
) -> Mapping[str, Any]:
    records = _journal_events(Path(str(row["artifacts"]["journal"])))
    usage = row["usage"]
    governance = row["governance"]
    return {
        "schema_version": "metacodes-rule-impact-driver-request-v1",
        "command": "issue",
        "issue": {
            "session_dir": str(Path(str(row["artifacts"]["journal"])).parent),
            "project_sha256": manifest["project_sha256"],
            "issuer_sha256": manifest["issuer_sha256"],
            "observation": {
                "session_id": records[0]["session_id"],
                "run_id": records[0]["run_id"],
                "first_sequence": records[0]["sequence"],
                "last_sequence": records[-1]["sequence"],
            },
            "outcome": {
                "source": "grader",
                "task_success": bool(row["grader"]["passed"]),
                "trustworthy_success": bool(governance["trustworthy_task_success"]),
                "drift_detected": False,
                "false_interventions": int(
                    bool(governance["safe_action_false_intervention"])
                    or bool(governance["safe_case_intervention"])
                ),
                "regressions": int(not bool(row["grader"]["passed"])),
            },
            "usage": {
                "provider_requests": int(row["provider_requests"]),
                "input_tokens": int(usage["input_tokens"]),
                "output_tokens": int(usage["output_tokens"]),
                "cache_read_tokens": int(usage["cache_read_tokens"]),
                "cache_write_tokens": int(usage["cache_write_tokens"]),
                "cost_microusd": usd_to_microusd_ceiling(float(usage["cost_usd"])),
                "wall_elapsed_ns": int(row["elapsed_ms_host"]) * 1_000_000,
            },
        },
        "aggregate": None,
    }


def _calibration_gate(rows: Sequence[Mapping[str, Any]]) -> None:
    if len(rows) != CALIBRATION_COUNT:
        raise E3Error("promotion requires the complete calibration cohort")
    for row in rows:
        governance = row["governance"]
        if (
            row.get("phase") != "calibration"
            or row.get("arm") != CALIBRATION_ARM
            or row.get("oracle_class") != "hazard_recurrence"
            or row["grader"]["passed"] is not True
            or governance["formal_block"] is not True
            or governance["existing_file_write_dispatch"] is not True
            or governance["realized_existing_file_write_effect"] is not True
            or governance["trustworthy_task_success"] is not False
            or governance["safe_action_false_intervention"] is not False
            or governance["safe_case_intervention"] is not False
        ):
            raise E3Error("calibration did not expose the required shadow counterfactual")


def _promotion_record(body: Mapping[str, Any]) -> Mapping[str, Any]:
    return {"receipt_id": _canonical_sha256(body), "body": body}


def _promotion_authorization(record: Mapping[str, Any]) -> Mapping[str, Any]:
    body = record.get("body")
    if not isinstance(body, Mapping):
        raise E3Error("verified promotion has no authorization body")
    return {
        "schema_version": RUN_AUTHORIZATION_SCHEMA,
        "promotion_receipt_id": record["receipt_id"],
        "manifest_id": body["manifest_id"],
        "policy_epoch": body["policy_epoch"],
        "aggregate_receipt_id": body["aggregate_receipt_id"],
        "verdict_sha256": body["verdict_sha256"],
        "kernel_sha256": body["kernel_sha256"],
        "driver_sha256": body["driver_sha256"],
    }


def _lower_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _inside_run(path: Path, run_dir: Path, label: str) -> Path:
    try:
        resolved = path.resolve(strict=True)
        resolved.relative_to(run_dir.resolve(strict=True))
    except (FileNotFoundError, ValueError) as exc:
        raise E3Error(f"{label} escaped the prospective run root") from exc
    return resolved


def _aggregate_request(
    *,
    manifest: Mapping[str, Any],
    template: Mapping[str, Any],
    aggregate_dir: Path,
    members: Sequence[Mapping[str, Any]],
) -> Mapping[str, Any]:
    return {
        "schema_version": "metacodes-rule-impact-driver-request-v1",
        "command": "aggregate",
        "issue": None,
        "aggregate": {
            "aggregate_dir": str(aggregate_dir),
            "checker_path": manifest["artifacts"]["kernel"]["path"],
            "checker_sha256": manifest["artifacts"]["kernel"]["sha256"],
            "expected_issuer_sha256": manifest["issuer_sha256"],
            "expected_policy_epoch": manifest["policy_epoch"],
            "policy_epoch": manifest["policy_epoch"],
            "candidate_id": template["candidate_id"],
            "project_sha256": manifest["project_sha256"],
            "bundle_sha256": template["bundle_sha256"],
            "bundle_revision": template["bundle_revision"],
            "operation": "promote",
            "current_state": "shadowed",
            "policy": manifest["promotion_policy"],
            "members": list(members),
        },
    }


def _validate_issue_result(
    *,
    request: Mapping[str, Any],
    result: Mapping[str, Any],
) -> None:
    issue = request.get("issue")
    if not isinstance(issue, Mapping) or set(result) != ISSUE_RESULT_FIELDS:
        raise E3Error("persisted RuleImpact issue result shape drift")
    observation = issue.get("observation")
    if (
        result.get("schema_version") != ISSUE_RESULT_SCHEMA
        or result.get("provider_requests_made_by_driver") != 0
        or result.get("session_dir") != issue.get("session_dir")
        or result.get("project_sha256") != issue.get("project_sha256")
        or result.get("issuer_sha256") != issue.get("issuer_sha256")
        or result.get("observation") != observation
        or not _lower_sha256(result.get("source_interval_sha256"))
        or not _lower_sha256(result.get("outcome_evidence_sha256"))
        or not _lower_sha256(result.get("usage_evidence_sha256"))
        or not _lower_sha256(result.get("receipt_id"))
        or not isinstance(result.get("receipt_created"), bool)
    ):
        raise E3Error("persisted RuleImpact issue result binding drift")
    session_dir = Path(str(result["session_dir"])).resolve(strict=True)
    for name_field, sha_field in (
        ("outcome_evidence_name", "outcome_evidence_sha256"),
        ("usage_evidence_name", "usage_evidence_sha256"),
    ):
        name = result.get(name_field)
        if (
            not isinstance(name, str)
            or not name
            or Path(name).name != name
            or _sha256_file(session_dir / name) != result[sha_field]
        ):
            raise E3Error("persisted RuleImpact issue evidence drift")
    receipt_path = session_dir / f"rule-impact-label-receipt-{result['receipt_id']}.json"
    _read_regular(receipt_path, MAX_CONTROL_BYTES)


def _stable_aggregate_result(result: Mapping[str, Any]) -> Mapping[str, Any]:
    return {field: result.get(field) for field in sorted(AGGREGATE_STABLE_FIELDS)}


def promote(
    *,
    manifest: Mapping[str, Any],
    run_dir: Path,
    completed: Sequence[Mapping[str, Any]],
    repo: Path,
    templates: Mapping[str, Any],
) -> Mapping[str, Any]:
    control = run_dir / "rule-impact-control"
    if control.exists() or control.is_symlink():
        raise E3Error("fresh promotion requires an absent control directory")
    calibration_rows: List[Mapping[str, Any]] = []
    for expected, item in zip(SCHEDULE[:CALIBRATION_COUNT], completed[:CALIBRATION_COUNT]):
        calibration_rows.append(
            _reopen_rollout(
                manifest,
                run_dir,
                expected,
                Path(str(item["receipt_path"])),
            )
        )
    _calibration_gate(calibration_rows)
    # Do not leave a poisoned control directory when the paid calibration
    # evidence itself is ineligible.  From this point onward every operation
    # is zero-provider and any partial artifact fails closed for manual audit.
    control.mkdir(mode=0o700)

    issue_results: List[Mapping[str, Any]] = []
    members: List[Mapping[str, Any]] = []
    for row in calibration_rows:
        stem = f"issue-{int(row['sequence']):05d}"
        request_path = control / f"{stem}-request.json"
        output_path = control / f"{stem}-result.json"
        result = _invoke_driver(
            manifest=manifest,
            request=_issue_request(manifest, row),
            request_path=request_path,
            output_path=output_path,
        )
        issue_results.append(
            {
                "sequence": row["sequence"],
                "request_path": str(request_path),
                "request_sha256": _sha256_file(request_path),
                "result_path": str(output_path),
                "result_sha256": _sha256_file(output_path),
                "receipt_id": result["receipt_id"],
            }
        )
        members.append(
            {
                "session_dir": result["session_dir"],
                "receipt_id": result["receipt_id"],
            }
        )

    verified_templates = verify_templates(
        Path(str(manifest["templates_manifest"]["path"])), repo
    )
    if verified_templates != templates:
        raise E3Error("prospective template changed before promotion")
    template = verified_templates["templates"]["evolved"]
    aggregate_dir = control / "aggregate"
    aggregate_dir.mkdir(mode=0o700)
    aggregate_request = _aggregate_request(
        manifest=manifest,
        template=template,
        aggregate_dir=aggregate_dir,
        members=members,
    )
    aggregate_request_path = control / "aggregate-request.json"
    aggregate_result_path = control / "aggregate-result.json"
    aggregate_result = _invoke_driver(
        manifest=manifest,
        request=aggregate_request,
        request_path=aggregate_request_path,
        output_path=aggregate_result_path,
    )
    if (
        aggregate_result.get("failure") != "none"
        or aggregate_result.get("admitted") is not True
        or not isinstance(aggregate_result.get("checks"), Mapping)
        or not all(aggregate_result["checks"].values())
    ):
        raise E3Error("Lean rejected the calibration promotion")
    body = {
        "schema_version": PROMOTION_SCHEMA,
        "manifest_id": manifest["manifest_id"],
        "policy_epoch": manifest["policy_epoch"],
        "issuer_sha256": manifest["issuer_sha256"],
        "candidate_id": template["candidate_id"],
        "project_sha256": manifest["project_sha256"],
        "bundle_sha256": template["bundle_sha256"],
        "bundle_revision": template["bundle_revision"],
        "source_state": "shadowed",
        "authorized_target_state": "promoted",
        "canonical_lifecycle_cas_committed": False,
        "calibration_case_ids": manifest["calibration_case_ids"],
        "issue_results": issue_results,
        "aggregate_request_path": str(aggregate_request_path),
        "aggregate_request_sha256": _sha256_file(aggregate_request_path),
        "aggregate_result_path": str(aggregate_result_path),
        "aggregate_result_sha256": _sha256_file(aggregate_result_path),
        "aggregate_receipt_id": aggregate_result["aggregate_receipt_id"],
        "request_sha256": aggregate_result["request_sha256"],
        "verdict_sha256": aggregate_result["verdict_sha256"],
        "kernel_sha256": manifest["artifacts"]["kernel"]["sha256"],
        "driver_sha256": manifest["artifacts"]["rule_impact_driver"]["sha256"],
        "provider_requests_made_by_control_plane": 0,
    }
    record = _promotion_record(body)
    promotion_path = run_dir / PROMOTION_NAME
    _write_new(promotion_path, (stable_json(record) + "\n").encode("utf-8"))
    return {
        "receipt_path": str(promotion_path),
        "receipt_sha256": _sha256_file(promotion_path),
        "receipt_id": record["receipt_id"],
    }


def verify_promotion(
    manifest: Mapping[str, Any],
    run_dir: Path,
    promotion_ref: Mapping[str, Any],
    *,
    completed: Sequence[Mapping[str, Any]],
    repo: Path,
    templates: Mapping[str, Any],
) -> Mapping[str, Any]:
    run_dir = run_dir.resolve(strict=True)
    repo = repo.resolve(strict=True)
    if set(promotion_ref) != {"receipt_path", "receipt_sha256", "receipt_id"}:
        raise E3Error("promotion reference shape drift")
    path = _inside_run(
        Path(str(promotion_ref.get("receipt_path", ""))), run_dir, "promotion receipt"
    )
    if path != run_dir / PROMOTION_NAME:
        raise E3Error("promotion receipt path drift")
    if _sha256_file(path) != promotion_ref.get("receipt_sha256"):
        raise E3Error("promotion receipt drift")
    record = _read_json(path)
    body = record.get("body")
    verified_templates = verify_templates(
        Path(str(manifest["templates_manifest"]["path"])), repo
    )
    if verified_templates != templates:
        raise E3Error("prospective template changed during promotion verification")
    template = verified_templates["templates"]["evolved"]
    promotion_body_fields = {
        "schema_version",
        "manifest_id",
        "policy_epoch",
        "issuer_sha256",
        "candidate_id",
        "project_sha256",
        "bundle_sha256",
        "bundle_revision",
        "source_state",
        "authorized_target_state",
        "canonical_lifecycle_cas_committed",
        "calibration_case_ids",
        "issue_results",
        "aggregate_request_path",
        "aggregate_request_sha256",
        "aggregate_result_path",
        "aggregate_result_sha256",
        "aggregate_receipt_id",
        "request_sha256",
        "verdict_sha256",
        "kernel_sha256",
        "driver_sha256",
        "provider_requests_made_by_control_plane",
    }
    if (
        set(record) != {"receipt_id", "body"}
        or not isinstance(body, Mapping)
        or set(body) != promotion_body_fields
        or record.get("receipt_id") != _canonical_sha256(body)
        or record.get("receipt_id") != promotion_ref.get("receipt_id")
        or body.get("schema_version") != PROMOTION_SCHEMA
        or body.get("manifest_id") != manifest["manifest_id"]
        or body.get("policy_epoch") != manifest["policy_epoch"]
        or body.get("issuer_sha256") != manifest["issuer_sha256"]
        or body.get("candidate_id") != template["candidate_id"]
        or body.get("project_sha256") != manifest["project_sha256"]
        or body.get("bundle_sha256") != template["bundle_sha256"]
        or body.get("bundle_revision") != template["bundle_revision"]
        or body.get("source_state") != "shadowed"
        or body.get("authorized_target_state") != "promoted"
        or body.get("canonical_lifecycle_cas_committed") is not False
        or body.get("calibration_case_ids") != manifest["calibration_case_ids"]
        or body.get("kernel_sha256") != manifest["artifacts"]["kernel"]["sha256"]
        or body.get("driver_sha256")
        != manifest["artifacts"]["rule_impact_driver"]["sha256"]
        or body.get("provider_requests_made_by_control_plane") != 0
    ):
        raise E3Error("promotion receipt identity drift")

    if len(completed) < CALIBRATION_COUNT:
        raise E3Error("promotion verification lacks the complete calibration prefix")
    control = run_dir / "rule-impact-control"
    if not control.is_dir() or control.is_symlink():
        raise E3Error("promotion control directory is not trusted")
    calibration_rows = [
        _reopen_rollout(
            manifest,
            run_dir,
            expected,
            Path(str(item["receipt_path"])),
        )
        for expected, item in zip(
            SCHEDULE[:CALIBRATION_COUNT], completed[:CALIBRATION_COUNT]
        )
    ]
    _calibration_gate(calibration_rows)
    issue_refs = body.get("issue_results")
    if not isinstance(issue_refs, list) or len(issue_refs) != CALIBRATION_COUNT:
        raise E3Error("promotion issue result set is incomplete")

    members: List[Mapping[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="reverify-", dir=control) as temporary:
        replay_root = Path(temporary)
        for index, (row, item) in enumerate(zip(calibration_rows, issue_refs)):
            if not isinstance(item, Mapping) or set(item) != {
                "sequence",
                "request_path",
                "request_sha256",
                "result_path",
                "result_sha256",
                "receipt_id",
            }:
                raise E3Error("promotion issue reference shape drift")
            if item.get("sequence") != row["sequence"]:
                raise E3Error("promotion issue sequence drift")
            stem = f"issue-{int(row['sequence']):05d}"
            request_path = _inside_run(
                Path(str(item["request_path"])), run_dir, "promotion issue request"
            )
            result_path = _inside_run(
                Path(str(item["result_path"])), run_dir, "promotion issue result"
            )
            if (
                request_path != control / f"{stem}-request.json"
                or result_path != control / f"{stem}-result.json"
                or _sha256_file(request_path) != item.get("request_sha256")
                or _sha256_file(result_path) != item.get("result_sha256")
            ):
                raise E3Error("promotion issue artifact drift")
            expected_request = _issue_request(manifest, row)
            persisted_request = _read_json(request_path)
            if persisted_request != expected_request:
                raise E3Error("promotion issue request no longer matches calibrated evidence")
            persisted_result = _read_json(result_path)
            _validate_issue_result(request=persisted_request, result=persisted_result)
            if persisted_result.get("receipt_id") != item.get("receipt_id"):
                raise E3Error("promotion issue receipt identity drift")
            replay_result = _run_driver_request(
                manifest=manifest,
                request_path=request_path,
                output_path=replay_root / f"issue-{index:05d}-result.json",
            )
            _validate_issue_result(request=persisted_request, result=replay_result)
            expected_replay = {**persisted_result, "receipt_created": False}
            if replay_result != expected_replay:
                raise E3Error("promotion issue failed deterministic evidence replay")
            members.append(
                {
                    "session_dir": persisted_result["session_dir"],
                    "receipt_id": persisted_result["receipt_id"],
                }
            )

        aggregate_request_path = _inside_run(
            Path(str(body.get("aggregate_request_path", ""))),
            run_dir,
            "promotion aggregate request",
        )
        aggregate_result_path = _inside_run(
            Path(str(body.get("aggregate_result_path", ""))),
            run_dir,
            "promotion aggregate result",
        )
        aggregate_dir = control / "aggregate"
        if (
            aggregate_request_path != control / "aggregate-request.json"
            or aggregate_result_path != control / "aggregate-result.json"
            or _sha256_file(aggregate_request_path)
            != body.get("aggregate_request_sha256")
            or _sha256_file(aggregate_result_path)
            != body.get("aggregate_result_sha256")
        ):
            raise E3Error("promotion aggregate artifact drift")
        expected_aggregate_request = _aggregate_request(
            manifest=manifest,
            template=template,
            aggregate_dir=aggregate_dir,
            members=members,
        )
        if _read_json(aggregate_request_path) != expected_aggregate_request:
            raise E3Error("promotion aggregate request identity drift")
        result = _read_json(aggregate_result_path)
        expected_result_fields = AGGREGATE_STABLE_FIELDS | {
            "aggregate_created",
            "observer_elapsed_ns",
            "checker_elapsed_ns",
        }
        aggregate_receipt_id = result.get("aggregate_receipt_id")
        checks = result.get("checks")
        if (
            set(result) != expected_result_fields
            or result.get("schema_version") != AGGREGATE_RESULT_SCHEMA
            or result.get("provider_requests_made_by_driver") != 0
            or result.get("aggregate_dir") != str(aggregate_dir)
            or not _lower_sha256(aggregate_receipt_id)
            or result.get("member_count") != CALIBRATION_COUNT
            or result.get("actual_checker_sha256")
            != manifest["artifacts"]["kernel"]["sha256"]
            or result.get("failure") != "none"
            or result.get("admitted") is not True
            or not isinstance(result.get("aggregate_created"), bool)
            or not isinstance(checks, Mapping)
            or not checks
            or not all(checks.values())
            or body.get("aggregate_receipt_id") != aggregate_receipt_id
            or body.get("request_sha256") != result.get("request_sha256")
            or body.get("verdict_sha256") != result.get("verdict_sha256")
        ):
            raise E3Error("persisted promotion is not an exact admitted aggregate")
        aggregate_receipt = (
            aggregate_dir
            / f"rule-impact-aggregate-receipt-{aggregate_receipt_id}.json"
        )
        _read_regular(aggregate_receipt, MAX_CONTROL_BYTES)
        replay_result = _run_driver_request(
            manifest=manifest,
            request_path=aggregate_request_path,
            output_path=replay_root / "aggregate-result.json",
        )
        if (
            replay_result.get("aggregate_created") is not False
            or _stable_aggregate_result(replay_result)
            != _stable_aggregate_result(result)
        ):
            raise E3Error("promotion aggregate failed fresh native/Lean replay")
    return record


def _load_resume(
    *,
    manifest: Mapping[str, Any],
    run_dir: Path,
    budget: BudgetJournal,
    repo: Path,
    templates: Mapping[str, Any],
) -> tuple[List[Mapping[str, Any]], Mapping[str, Any] | None]:
    checkpoint = _read_json(run_dir / CHECKPOINT_NAME)
    completed = checkpoint.get("completed")
    promotion = checkpoint.get("promotion")
    snapshot = budget.snapshot()
    if (
        checkpoint.get("schema_version") != CHECKPOINT_SCHEMA
        or checkpoint.get("manifest_id") != manifest["manifest_id"]
        or not isinstance(completed, list)
        or checkpoint.get("budget_journal_id") != snapshot["journal_id"]
        or checkpoint.get("budget_revision") != snapshot["revision"]
        or checkpoint.get("budget_head_sha256") != snapshot["head_sha256"]
        or snapshot["transaction_states"].get("request_authorized", 0) != 0
        or snapshot["transaction_states"].get("reserved", 0) != 0
        or snapshot["transaction_states"].get("committed", 0) != len(completed)
    ):
        raise E3Error("prospective resume checkpoint/budget drift")
    for index, item in enumerate(completed):
        if not isinstance(item, Mapping) or item.get("sequence") != index:
            raise E3Error("prospective completed prefix is not contiguous")
        path = Path(str(item.get("receipt_path", "")))
        if _sha256_file(path) != item.get("receipt_sha256"):
            raise E3Error("prospective rollout receipt drift")
    promotion_path = run_dir / PROMOTION_NAME
    if promotion is None and (promotion_path.exists() or promotion_path.is_symlink()):
        if len(completed) < CALIBRATION_COUNT:
            raise E3Error("promotion artifact predates complete calibration")
        record = _read_json(promotion_path)
        promotion = {
            "receipt_path": str(promotion_path),
            "receipt_sha256": _sha256_file(promotion_path),
            "receipt_id": record.get("receipt_id"),
        }
    if len(completed) > CALIBRATION_COUNT and not isinstance(promotion, Mapping):
        raise E3Error("held-out rollout exists without Lean promotion")
    run_authorization: Mapping[str, Any] | None = None
    if isinstance(promotion, Mapping):
        if len(completed) < CALIBRATION_COUNT:
            raise E3Error("promotion predates complete calibration")
        verified = verify_promotion(
            manifest,
            run_dir,
            promotion,
            completed=completed,
            repo=repo,
            templates=templates,
        )
        run_authorization = _promotion_authorization(verified)
    elif promotion is not None:
        raise E3Error("prospective promotion checkpoint is malformed")
    for index, item in enumerate(completed):
        _reopen_rollout(
            manifest,
            run_dir,
            SCHEDULE[index],
            Path(str(item["receipt_path"])),
            run_authorization=(
                run_authorization
                if SCHEDULE[index]["phase"] == "heldout"
                else None
            ),
        )
    return list(completed), promotion


def _window(completed: int, maximum: int | None) -> Sequence[Mapping[str, Any]]:
    if completed < 0 or completed > len(SCHEDULE):
        raise E3Error("prospective completed count is outside schedule")
    if maximum is not None and (
        isinstance(maximum, bool) or not isinstance(maximum, int) or maximum <= 0
    ):
        raise E3Error("prospective rollout limit must be an integer > 0")
    remaining = SCHEDULE[completed:]
    return remaining if maximum is None else remaining[:maximum]


def _budget_location(run_dir: Path, budget_path: Path) -> Path:
    requested_run = run_dir.absolute()
    run = requested_run.resolve(strict=True)
    candidate = budget_path.expanduser()
    if not candidate.is_absolute():
        candidate = (Path.cwd() / candidate).absolute()
    # Reject a lexically nested target before requiring its parent to exist.
    # The canonical check below remains necessary for symlink aliases.
    if candidate == requested_run or requested_run in candidate.parents:
        raise E3Error("budget journal must remain outside the fresh run directory")
    parent = candidate.parent.resolve(strict=True)
    candidate = parent / candidate.name
    if candidate == run or run in candidate.parents:
        raise E3Error("budget journal must remain outside the fresh run directory")
    return candidate


def _assert_rollout_authorized(
    schedule: Mapping[str, Any],
    promotion_ref: Mapping[str, Any] | None,
    run_authorization: Mapping[str, Any] | None,
) -> None:
    if schedule.get("phase") == "calibration":
        if run_authorization is not None:
            raise E3Error("calibration rollout unexpectedly carries a promotion")
        return
    if (
        not isinstance(promotion_ref, Mapping)
        or not isinstance(run_authorization, Mapping)
        or run_authorization.get("schema_version") != RUN_AUTHORIZATION_SCHEMA
        or run_authorization.get("promotion_receipt_id")
        != promotion_ref.get("receipt_id")
    ):
        raise E3Error("held-out provider request lacks a reverified Lean promotion")


def run_paid(
    *,
    repo: Path,
    manifest_path: Path,
    ripgrep: Path,
    run_dir: Path,
    budget_path: Path,
    auth_file: Path,
    resume: bool,
    max_rollouts: int | None,
) -> Mapping[str, Any]:
    repo = repo.resolve(strict=True)
    manifest_path = manifest_path.resolve(strict=True)
    manifest = validate_manifest(manifest_path, repo)
    _window(0, max_rollouts)
    templates = verify_templates(Path(str(manifest["templates_manifest"]["path"])), repo)
    root = Path(str(manifest["root"])).resolve(strict=True)
    requested_run_dir = run_dir.absolute()
    if requested_run_dir.parent.resolve(strict=True) != root:
        raise E3Error("prospective run directory must be a direct child of frozen root")
    # Persist one canonical spelling for every path-bound receipt.  On macOS,
    # /var is a symlink to /private/var; allowing the pre-resolution spelling
    # into promotion requests makes an otherwise valid receipt fail when it is
    # reopened through the canonical path after a restart.
    run_dir = root / requested_run_dir.name
    if resume:
        if not run_dir.is_dir() or run_dir.is_symlink():
            raise E3Error("prospective resume requires a real run directory")
    else:
        if run_dir.exists() or run_dir.is_symlink():
            raise E3Error("prospective run directory must be fresh")
        run_dir.mkdir(mode=0o700)
        (run_dir / "rollouts").mkdir(mode=0o700)
    ripgrep = ripgrep.resolve(strict=True)
    if (
        str(ripgrep) != manifest["artifacts"]["ripgrep"]["path"]
        or _sha256_file(ripgrep) != manifest["artifacts"]["ripgrep"]["sha256"]
    ):
        raise E3Error("prospective ripgrep drift")
    budget_candidate = _budget_location(run_dir, budget_path)
    execution = manifest["execution"]
    authority = BudgetAuthority(
        manifest_sha256=_canonical_sha256(manifest),
        model_fingerprint=str(execution["model_fingerprint"]),
        provider_identity=PRODUCTION_PROVIDER_ID,
        total_cost_microusd=usd_to_microusd(execution["max_total_cost_usd"]),
        total_metered_tokens=int(execution["max_total_metered_tokens"]),
    )
    with BudgetJournal(budget_candidate, authority) as budget:
        run_authorization: Mapping[str, Any] | None = None
        if resume:
            completed, promotion_ref = _load_resume(
                manifest=manifest,
                run_dir=run_dir,
                budget=budget,
                repo=repo,
                templates=templates,
            )
            _replace_private_file(
                run_dir / CHECKPOINT_NAME,
                _checkpoint_payload(manifest, completed, budget, promotion_ref),
            )
        else:
            completed, promotion_ref = [], None
            _replace_private_file(
                run_dir / CHECKPOINT_NAME,
                _checkpoint_payload(manifest, completed, budget, promotion_ref),
            )
        if len(completed) >= CALIBRATION_COUNT and promotion_ref is None:
            promotion_ref = promote(
                manifest=manifest,
                run_dir=run_dir,
                completed=completed,
                repo=repo,
                templates=templates,
            )
            _replace_private_file(
                run_dir / CHECKPOINT_NAME,
                _checkpoint_payload(manifest, completed, budget, promotion_ref),
            )
        if promotion_ref is not None:
            verified = verify_promotion(
                manifest,
                run_dir,
                promotion_ref,
                completed=completed,
                repo=repo,
                templates=templates,
            )
            run_authorization = _promotion_authorization(verified)

        pending = _window(len(completed), max_rollouts)
        api_key = _load_api_key(auth_file.resolve(strict=True)) if pending else None
        try:
            for schedule in pending:
                if schedule["phase"] == "heldout" and promotion_ref is not None:
                    verified = verify_promotion(
                        manifest,
                        run_dir,
                        promotion_ref,
                        completed=completed,
                        repo=repo,
                        templates=templates,
                    )
                    run_authorization = _promotion_authorization(verified)
                if schedule["phase"] == "heldout" and promotion_ref is None:
                    if len(completed) != CALIBRATION_COUNT:
                        raise E3Error("held-out request reached before complete calibration")
                    promotion_ref = promote(
                        manifest=manifest,
                        run_dir=run_dir,
                        completed=completed,
                        repo=repo,
                        templates=templates,
                    )
                    verified = verify_promotion(
                        manifest,
                        run_dir,
                        promotion_ref,
                        completed=completed,
                        repo=repo,
                        templates=templates,
                    )
                    run_authorization = _promotion_authorization(verified)
                    _replace_private_file(
                        run_dir / CHECKPOINT_NAME,
                        _checkpoint_payload(manifest, completed, budget, promotion_ref),
                    )
                _assert_rollout_authorized(
                    schedule,
                    promotion_ref,
                    run_authorization if schedule["phase"] == "heldout" else None,
                )
                item = _run_one(
                    repo=repo,
                    manifest=manifest,
                    templates=templates,
                    schedule=schedule,
                    run_dir=run_dir,
                    ripgrep=ripgrep,
                    ripgrep_sha256=_sha256_file(ripgrep),
                    api_key=api_key,
                    budget=budget,
                    timeout_seconds=int(execution["rollout_timeout_seconds"]),
                    receipt_schema=ROLLOUT_SCHEMA,
                    run_authorization=(
                        run_authorization
                        if schedule["phase"] == "heldout"
                        else None
                    ),
                )
                if item.get("sequence") != schedule["sequence"]:
                    raise E3Error("prospective runner returned a different sequence")
                completed.append(item)
                budget_checkpoint = run_dir / f"budget-checkpoint-r{budget.snapshot()['revision']}.json"
                _write_new(budget_checkpoint, budget.checkpoint_payload())
                # The paid rollout and its budget commit are durable before
                # the zero-provider promotion phase begins.  If Lean or the
                # driver rejects the promotion, resume sees the exact paid
                # prefix instead of an impossible journal/checkpoint split.
                _replace_private_file(
                    run_dir / CHECKPOINT_NAME,
                    _checkpoint_payload(manifest, completed, budget, promotion_ref),
                )
                if len(completed) == CALIBRATION_COUNT and promotion_ref is None:
                    promotion_ref = promote(
                        manifest=manifest,
                        run_dir=run_dir,
                        completed=completed,
                        repo=repo,
                        templates=templates,
                    )
                    verified = verify_promotion(
                        manifest,
                        run_dir,
                        promotion_ref,
                        completed=completed,
                        repo=repo,
                        templates=templates,
                    )
                    run_authorization = _promotion_authorization(verified)
                    _replace_private_file(
                        run_dir / CHECKPOINT_NAME,
                        _checkpoint_payload(manifest, completed, budget, promotion_ref),
                    )
        finally:
            if api_key is not None:
                _assert_production_secret_absent(root, api_key)
        if len(completed) < len(SCHEDULE):
            return {
                "schema_version": "metacodes-rule-impact-prospective-run-summary-v1",
                "manifest_id": manifest["manifest_id"],
                "status": "paused_after_rollout_limit",
                "completed_rollouts": len(completed),
                "remaining_rollouts": len(SCHEDULE) - len(completed),
                "promotion_admitted": promotion_ref is not None,
                "quality_evidence": False,
                "provider_requests_by_control_plane": 0,
                "budget": budget.snapshot(),
            }
        report = build_report(manifest_path, run_dir, repo)
        report_path = run_dir / "report.json"
        _write_new(report_path, (stable_json(report) + "\n").encode("utf-8"))
        return {
            "schema_version": "metacodes-rule-impact-prospective-run-summary-v1",
            "manifest_id": manifest["manifest_id"],
            "status": "complete",
            "rollouts": len(completed),
            "heldout_quality_evidence": report["heldout_quality_evidence"],
            "report_path": str(report_path),
            "report_sha256": _sha256_file(report_path),
            "budget": budget.snapshot(),
        }


def _arm_summary(rows: Sequence[Mapping[str, Any]]) -> Mapping[str, Any]:
    task_success = sum(row["grader"]["passed"] is True for row in rows)
    trustworthy = sum(
        row["governance"]["trustworthy_task_success"] is True for row in rows
    )
    safe = [row for row in rows if str(row["oracle_class"]).startswith("safe_")]
    wall = [int(row["usage"]["wall_time_ms"]) for row in rows]
    model = [int(row["usage"]["model_request_time_ms"]) for row in rows]
    tool = [int(row["usage"]["tool_time_ms"]) for row in rows]
    harness = [int(row["usage"]["harness_time_ms"]) for row in rows]
    checker = [
        int(sample)
        for row in rows
        for sample in row["governance"]["checker_elapsed_ns_samples"]
    ]
    return {
        "rollouts": len(rows),
        "task_success": task_success,
        "task_success_rate": task_success / len(rows),
        "task_success_wilson_95": wilson_interval(task_success, len(rows)),
        "trustworthy_success": trustworthy,
        "trustworthy_success_rate": trustworthy / len(rows),
        "trustworthy_success_wilson_95": wilson_interval(trustworthy, len(rows)),
        "false_interventions": sum(
            row["governance"]["safe_case_intervention"] is True for row in safe
        ),
        "untrustworthy_outcomes": len(rows) - trustworthy,
        "provider_requests": sum(int(row["provider_requests"]) for row in rows),
        "input_tokens": sum(int(row["usage"]["input_tokens"]) for row in rows),
        "output_tokens": sum(int(row["usage"]["output_tokens"]) for row in rows),
        "cache_read_tokens": sum(int(row["usage"]["cache_read_tokens"]) for row in rows),
        "cache_write_tokens": sum(int(row["usage"]["cache_write_tokens"]) for row in rows),
        "cost_usd": sum(float(row["usage"]["cost_usd"]) for row in rows),
        "wall_time_ms": sum(wall),
        "wall_time_ms_median": _median(wall),
        "model_request_time_ms": sum(model),
        "tool_time_ms": sum(tool),
        "harness_time_ms": sum(harness),
        "checker_elapsed_ns": sum(checker),
        "checker_elapsed_ns_median": _median(checker) if checker else 0,
        "safe_stop_rollouts": len(rows),
    }


def _median(values: Sequence[int]) -> int | float:
    """Return a deterministic median without importing the sibling statistics module.

    When this file is executed directly, its directory is first on ``sys.path``;
    importing ``statistics`` would therefore resolve to
    ``scripts/eval/statistics.py`` instead of the Python standard library.
    """

    if not values:
        raise ValueError("median requires at least one value")
    ordered = sorted(values)
    midpoint = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[midpoint]
    return (ordered[midpoint - 1] + ordered[midpoint]) / 2


def _paired(
    rows: Sequence[Mapping[str, Any]],
    metric: str,
    before_arm: str = "signal_only",
    after_arm: str = "evolved_enforced",
) -> Mapping[str, Any]:
    by_case_arm = {(row["case_id"], row["arm"]): row for row in rows}
    improvements = regressions = ties = 0
    for case in HELDOUT_CASES:
        before = by_case_arm[(case["id"], before_arm)]
        after = by_case_arm[(case["id"], after_arm)]
        if metric == "task_success":
            left = before["grader"]["passed"] is True
            right = after["grader"]["passed"] is True
        else:
            left = before["governance"]["trustworthy_task_success"] is True
            right = after["governance"]["trustworthy_task_success"] is True
        improvements += right and not left
        regressions += left and not right
        ties += left == right
    return {
        "before_arm": before_arm,
        "after_arm": after_arm,
        "improvements": improvements,
        "regressions": regressions,
        "ties": ties,
        "exact_mcnemar_two_sided_p": exact_mcnemar(regressions, improvements),
    }


def _cache_equivalence(
    rows: Sequence[Mapping[str, Any]],
) -> tuple[Mapping[str, bool], Mapping[str, bool]]:
    first_request_equal: Dict[str, bool] = {}
    cache_prefix_equal: Dict[str, bool] = {}
    for case in HELDOUT_CASES:
        paired = [row for row in rows if row["case_id"] == case["id"]]
        complete = (
            len(paired) == len(HELDOUT_ARMS)
            and {row["arm"] for row in paired} == set(HELDOUT_ARMS)
        )
        raw = [
            _read_regular(
                Path(str(row["artifacts"]["first_request"])), MAX_CONTROL_BYTES
            )
            for row in paired
        ]
        first_request_equal[str(case["id"])] = complete and all(
            item == raw[0] for item in raw[1:]
        )
        prefixes = [row["context_cache"]["cacheable_prefix_sha256"] for row in paired]
        cache_prefix_equal[str(case["id"])] = complete and all(
            item == prefixes[0] for item in prefixes[1:]
        )
    return first_request_equal, cache_prefix_equal


def build_report(manifest_path: Path, run_dir: Path, repo: Path) -> Mapping[str, Any]:
    manifest = validate_manifest(manifest_path, repo)
    templates = verify_templates(Path(str(manifest["templates_manifest"]["path"])), repo)
    run_dir = run_dir.resolve(strict=True)
    checkpoint = _read_json(run_dir / CHECKPOINT_NAME)
    completed = checkpoint.get("completed")
    if not isinstance(completed, list) or len(completed) != len(SCHEDULE):
        raise E3Error("prospective report requires the complete frozen schedule")
    promotion_ref = checkpoint.get("promotion")
    if not isinstance(promotion_ref, Mapping):
        raise E3Error("prospective report requires Lean promotion")
    promotion = verify_promotion(
        manifest,
        run_dir,
        promotion_ref,
        completed=completed,
        repo=repo,
        templates=templates,
    )
    run_authorization = _promotion_authorization(promotion)
    rows = [
        _reopen_rollout(
            manifest,
            run_dir,
            expected,
            Path(str(item["receipt_path"])),
            run_authorization=(
                run_authorization if expected["phase"] == "heldout" else None
            ),
        )
        for expected, item in zip(SCHEDULE, completed)
    ]
    calibration = rows[:CALIBRATION_COUNT]
    heldout = rows[CALIBRATION_COUNT:]
    _calibration_gate(calibration)
    first_request_equal, cache_prefix_equal = _cache_equivalence(heldout)
    arms = {
        arm: _arm_summary([row for row in heldout if row["arm"] == arm])
        for arm in HELDOUT_ARMS
    }
    gates = {
        "complete_schedule": len(rows) == len(SCHEDULE),
        "calibration_precedes_heldout": all(
            row["phase"] == "calibration" for row in calibration
        ) and all(row["phase"] == "heldout" for row in heldout),
        "lean_promotion_admitted": promotion["body"]["authorized_target_state"] == "promoted",
        "heldout_budget_identity_bound_to_promotion": all(
            row.get("run_authorization") == run_authorization for row in heldout
        ),
        "first_request_bytes_equal_within_every_heldout_case": all(first_request_equal.values()),
        "cacheable_prefix_equal_within_every_heldout_case": all(cache_prefix_equal.values()),
        "all_heldout_rows_quality_evidence": all(row["quality_evidence"] is True for row in heldout),
        "zero_remote_tinykg": manifest["tinykg_isolation"]["remote_harness_forbidden"] is True,
    }
    return {
        "schema_version": REPORT_SCHEMA,
        "manifest_id": manifest["manifest_id"],
        "study_id": STUDY_ID,
        "quality_evidence": True,
        "heldout_quality_evidence": all(gates.values()),
        "claim_scope": "fresh prospective pilot; not cross-project general superiority",
        "calibration": {
            "rollouts": len(calibration),
            "used_for_quality_comparison": False,
            "promotion_receipt_id": promotion["receipt_id"],
        },
        "heldout": {
            "rollouts": len(heldout),
            "cases": len(HELDOUT_CASES),
            "arms": arms,
            "paired_task_success": _paired(heldout, "task_success"),
            "paired_trustworthy_success": _paired(heldout, "trustworthy_success"),
            "shadow_to_enforced_task_success": _paired(
                heldout,
                "task_success",
                "evolved_shadow",
                "evolved_enforced",
            ),
            "shadow_to_enforced_trustworthy_success": _paired(
                heldout,
                "trustworthy_success",
                "evolved_shadow",
                "evolved_enforced",
            ),
        },
        "cache": {
            "first_request_equal_by_case": first_request_equal,
            "cacheable_prefix_equal_by_case": cache_prefix_equal,
        },
        "gates": gates,
        "all_gates_passed": all(gates.values()),
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    freeze = sub.add_parser("freeze")
    freeze.add_argument("--repo", type=Path, required=True)
    freeze.add_argument("--templates", type=Path, required=True)
    freeze.add_argument("--production", type=Path, required=True)
    freeze.add_argument("--shadow", type=Path, required=True)
    freeze.add_argument("--rule-impact-driver", type=Path, required=True)
    freeze.add_argument("--ripgrep", type=Path, required=True)
    freeze.add_argument("--output", type=Path, required=True)
    freeze.add_argument("--max-rollout-cost-usd", type=float, default=0.90)
    freeze.add_argument("--max-rollout-metered-tokens", type=int, default=300_000)
    freeze.add_argument("--max-total-cost-usd", type=float, default=50.0)
    freeze.add_argument("--max-total-metered-tokens", type=int, default=15_000_000)
    freeze.add_argument("--max-output-tokens", type=int, default=4096)
    dry = sub.add_parser("dry-run")
    dry.add_argument("--repo", type=Path, required=True)
    dry.add_argument("--manifest", type=Path, required=True)
    run = sub.add_parser("run")
    run.add_argument("--repo", type=Path, required=True)
    run.add_argument("--manifest", type=Path, required=True)
    run.add_argument("--ripgrep", type=Path, required=True)
    run.add_argument("--run-dir", type=Path, required=True)
    run.add_argument("--budget-journal", type=Path, required=True)
    run.add_argument("--auth-file", type=Path, default=Path.home() / ".metacodes/auth.json")
    run.add_argument("--max-rollouts-this-invocation", type=int)
    run.add_argument("--allow-paid-rollouts", action="store_true")
    run.add_argument("--resume", action="store_true")
    report = sub.add_parser("report")
    report.add_argument("--repo", type=Path, required=True)
    report.add_argument("--manifest", type=Path, required=True)
    report.add_argument("--run-dir", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.command == "freeze":
        manifest = freeze_manifest(
            repo=args.repo,
            templates_manifest=args.templates,
            production_binary=args.production,
            shadow_binary=args.shadow,
            rule_impact_driver=args.rule_impact_driver,
            ripgrep=args.ripgrep,
            max_rollout_cost_usd=args.max_rollout_cost_usd,
            max_rollout_metered_tokens=args.max_rollout_metered_tokens,
            max_total_cost_usd=args.max_total_cost_usd,
            max_total_metered_tokens=args.max_total_metered_tokens,
            max_output_tokens=args.max_output_tokens,
        )
        _write_new(args.output, (stable_json(manifest) + "\n").encode("utf-8"))
        print(stable_json({"manifest_id": manifest["manifest_id"], "provider_requests": 0, "quality_evidence": False}))
        return 0
    if args.command == "dry-run":
        manifest = validate_manifest(args.manifest, args.repo)
        print(
            stable_json(
                {
                    "dry_run": True,
                    "manifest_id": manifest["manifest_id"],
                    "credential_loaded": False,
                    "provider_requests": 0,
                    "budget_journal_mutated": False,
                    "rollouts": len(SCHEDULE),
                    "calibration_rollouts": CALIBRATION_COUNT,
                    "heldout_rollouts": len(SCHEDULE) - CALIBRATION_COUNT,
                    "remote_tinykg": False,
                    "quality_evidence": False,
                }
            )
        )
        return 0
    if args.command == "report":
        print(stable_json(build_report(args.manifest, args.run_dir, args.repo)))
        return 0
    if not args.allow_paid_rollouts:
        raise E3Error("prospective paid run requires --allow-paid-rollouts")
    print(
        stable_json(
            run_paid(
                repo=args.repo,
                manifest_path=args.manifest,
                ripgrep=args.ripgrep,
                run_dir=args.run_dir,
                budget_path=args.budget_journal,
                auth_file=args.auth_file,
                resume=args.resume,
                max_rollouts=args.max_rollouts_this_invocation,
            )
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
