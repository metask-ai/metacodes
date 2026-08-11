#!/usr/bin/env python3
"""Zero-provider native L2 for the RuleImpact evidence and Lean bridge."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from typing import Any


ISSUER_SHA256 = hashlib.sha256(b"metacodes-rule-impact-driver-l2-issuer-v1").hexdigest()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_checked(argv: list[str], timeout: float = 60.0) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        argv,
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"command failed ({completed.returncode}): {argv!r}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return completed


def invoke_driver(driver: Path, request: dict[str, Any], root: Path, stem: str) -> dict[str, Any]:
    request_path = root / f"{stem}-request.json"
    output_path = root / f"{stem}-result.json"
    request_path.write_text(
        json.dumps(request, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    run_checked(
        [str(driver), "--request", str(request_path), "--output", str(output_path)]
    )
    result = json.loads(output_path.read_text(encoding="utf-8"))
    if result.get("provider_requests_made_by_driver") != 0:
        raise AssertionError("RuleImpact bridge reported a provider request")
    return result


def invoke_driver_fails(
    driver: Path, request: dict[str, Any], root: Path, stem: str
) -> None:
    request_path = root / f"{stem}-request.json"
    output_path = root / f"{stem}-result.json"
    request_path.write_text(
        json.dumps(request, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    completed = subprocess.run(
        [str(driver), "--request", str(request_path), "--output", str(output_path)],
        check=False,
        capture_output=True,
        text=True,
        timeout=60.0,
    )
    if completed.returncode == 0:
        raise AssertionError(f"tampered evidence was accepted: {completed.stdout}")
    if output_path.exists():
        raise AssertionError("failed bridge invocation left an authoritative result")


def formal_identity(journal_path: Path) -> dict[str, Any]:
    identities: set[tuple[str, str, str, int]] = set()
    for raw_line in journal_path.read_text(encoding="utf-8").splitlines():
        record = json.loads(raw_line)
        observation = record.get("event", {}).get("tool_observation", {})
        batch = observation.get("formal_decision_batch")
        if batch is None:
            continue
        for decision in batch["decisions"]:
            identities.add(
                (
                    decision["candidate_id"],
                    batch["project_sha256"],
                    batch["bundle_sha256"],
                    int(batch["bundle_revision"]),
                )
            )
    if len(identities) != 1:
        raise AssertionError(f"expected one formal identity, got {sorted(identities)!r}")
    candidate, project, bundle, revision = identities.pop()
    return {
        "candidate_id": candidate,
        "project_sha256": project,
        "bundle_sha256": bundle,
        "bundle_revision": revision,
    }


def observed_wall_elapsed_ns(journal_path: Path) -> int:
    elapsed = 0
    for raw_line in journal_path.read_text(encoding="utf-8").splitlines():
        record = json.loads(raw_line)
        elapsed = max(elapsed, int(record["monotonic_elapsed_ns"]))
    if elapsed <= 0:
        raise AssertionError("completed observation journal has no elapsed time")
    return elapsed


def produce_rollout(
    eval_driver: Path,
    kernel: Path,
    kernel_sha256: str,
    root: Path,
    case: str,
) -> tuple[dict[str, Any], Path, dict[str, Any]]:
    run_checked(
        [
            str(eval_driver),
            "--root",
            str(root),
            "--arm",
            "evolved_shadow",
            "--case",
            case,
            "--kernel",
            str(kernel),
            "--kernel-sha256",
            kernel_sha256,
        ]
    )
    rollout = json.loads((root / "driver-result.json").read_text(encoding="utf-8"))
    if rollout["quality_evidence"] is not False or rollout["provider_requests"] != 0:
        raise AssertionError("mechanism rollout crossed the quality/provider boundary")
    if not rollout["task_success"]:
        raise AssertionError(f"mechanism fixture did not complete: {case}")
    session_dir = root / rollout["session_id"]
    journal = session_dir / "tool-observations.jsonl"
    identity = formal_identity(journal)
    rollout["observed_wall_elapsed_ns"] = observed_wall_elapsed_ns(journal)
    if identity["project_sha256"] != rollout["project_sha256"]:
        raise AssertionError("driver result/project journal identity drift")
    if identity["candidate_id"] != rollout["candidate_sha256"]:
        raise AssertionError("driver result/candidate journal identity drift")
    return rollout, session_dir, identity


def issue_request(
    rollout: dict[str, Any], session_dir: Path, trustworthy_success: bool
) -> dict[str, Any]:
    return {
        "schema_version": "metacodes-rule-impact-driver-request-v1",
        "command": "issue",
        "issue": {
            "session_dir": str(session_dir),
            "project_sha256": rollout["project_sha256"],
            "issuer_sha256": ISSUER_SHA256,
            "observation": {
                "session_id": rollout["session_id"],
                "run_id": rollout["run_id"],
                "first_sequence": rollout["first_sequence"],
                "last_sequence": rollout["last_sequence"],
            },
            "outcome": {
                "source": "grader",
                "task_success": True,
                "trustworthy_success": trustworthy_success,
                "drift_detected": False,
                "false_interventions": 0,
                "regressions": 0,
            },
            "usage": {
                "provider_requests": 0,
                "input_tokens": 0,
                "output_tokens": 0,
                "cache_read_tokens": 0,
                "cache_write_tokens": 0,
                "cost_microusd": 0,
                "wall_elapsed_ns": rollout["observed_wall_elapsed_ns"],
            },
        },
        "aggregate": None,
    }


def aggregate_request(
    *,
    aggregate_dir: Path,
    kernel: Path,
    kernel_sha256: str,
    identity: dict[str, Any],
    session_dir: Path,
    receipt_id: str,
    policy_epoch: int = 1,
    expected_policy_epoch: int = 1,
) -> dict[str, Any]:
    return {
        "schema_version": "metacodes-rule-impact-driver-request-v1",
        "command": "aggregate",
        "issue": None,
        "aggregate": {
            "aggregate_dir": str(aggregate_dir),
            "checker_path": str(kernel),
            "checker_sha256": kernel_sha256,
            "expected_issuer_sha256": ISSUER_SHA256,
            "expected_policy_epoch": expected_policy_epoch,
            "policy_epoch": policy_epoch,
            **identity,
            "operation": "promote",
            "current_state": "shadowed",
            "policy": {
                "min_exposures": 1,
                "max_formal_faults": 0,
                "max_shadow_divergences": 8,
                "max_false_interventions": 0,
                "max_regressions": 0,
                "max_provider_requests": 0,
                "max_metered_tokens": 0,
                "max_cost_microusd": 0,
                "max_wall_elapsed_ns": 60_000_000_000,
            },
            "members": [
                {"session_dir": str(session_dir), "receipt_id": receipt_id}
            ],
        },
    }


def assert_rejected(result: dict[str, Any], expected_failed_check: str) -> None:
    if result["failure"] != "none" or result["admitted"]:
        raise AssertionError(f"expected a checked rejection, got {result!r}")
    checks = result.get("checks")
    if checks is None or checks.get(expected_failed_check) is not False:
        raise AssertionError(
            f"expected {expected_failed_check}=false, got {checks!r}"
        )


def run_l2(eval_driver: Path, impact_driver: Path, kernel: Path) -> dict[str, Any]:
    for path in (eval_driver, impact_driver, kernel):
        if not path.is_absolute() or not path.is_file():
            raise ValueError(f"native artifact must be an absolute regular file: {path}")
    kernel_sha256 = file_sha256(kernel)
    with tempfile.TemporaryDirectory(prefix="metacodes-rule-impact-driver-l2.") as temp:
        root = Path(temp)

        hazard, hazard_session, hazard_identity = produce_rollout(
            eval_driver, kernel, kernel_sha256, root / "hazard", "existing_overwrite"
        )
        hazard_issue_request = issue_request(hazard, hazard_session, False)
        hazard_issue = invoke_driver(
            impact_driver, hazard_issue_request, root, "hazard-issue"
        )
        hazard_replay = invoke_driver(
            impact_driver, hazard_issue_request, root, "hazard-issue-replay"
        )
        if not hazard_issue["receipt_created"] or hazard_replay["receipt_created"]:
            raise AssertionError("single-run receipt replay was not idempotent")
        if hazard_replay["receipt_id"] != hazard_issue["receipt_id"]:
            raise AssertionError("single-run receipt identity changed on replay")

        hazard_aggregate_dir = root / "hazard-aggregate"
        hazard_aggregate_dir.mkdir(mode=0o700)
        hazard_aggregate_request = aggregate_request(
            aggregate_dir=hazard_aggregate_dir,
            kernel=kernel,
            kernel_sha256=kernel_sha256,
            identity=hazard_identity,
            session_dir=hazard_session,
            receipt_id=hazard_issue["receipt_id"],
        )
        hazard_aggregate = invoke_driver(
            impact_driver, hazard_aggregate_request, root, "hazard-aggregate"
        )
        if hazard_aggregate["failure"] != "none" or not hazard_aggregate["admitted"]:
            raise AssertionError(
                f"counterfactual shadow evidence did not promote: {hazard_aggregate!r}"
            )
        if not all(hazard_aggregate["checks"].values()):
            raise AssertionError(f"admitted verdict had a failed check: {hazard_aggregate!r}")

        wrong_checker_request = aggregate_request(
            aggregate_dir=hazard_aggregate_dir,
            kernel=kernel,
            kernel_sha256="a" * 64,
            identity=hazard_identity,
            session_dir=hazard_session,
            receipt_id=hazard_issue["receipt_id"],
        )
        wrong_checker = invoke_driver(
            impact_driver, wrong_checker_request, root, "hazard-wrong-checker"
        )
        if (
            wrong_checker["failure"] == "none"
            or wrong_checker["admitted"]
            or wrong_checker["checks"] is not None
        ):
            raise AssertionError(
                f"checker identity failure did not fail closed: {wrong_checker!r}"
            )

        stale_request = aggregate_request(
            aggregate_dir=hazard_aggregate_dir,
            kernel=kernel,
            kernel_sha256=kernel_sha256,
            identity=hazard_identity,
            session_dir=hazard_session,
            receipt_id=hazard_issue["receipt_id"],
            policy_epoch=1,
            expected_policy_epoch=2,
        )
        stale = invoke_driver(impact_driver, stale_request, root, "hazard-stale")
        assert_rejected(stale, "evidence_valid")

        safe, safe_session, safe_identity = produce_rollout(
            eval_driver, kernel, kernel_sha256, root / "safe", "edit_existing"
        )
        safe_issue = invoke_driver(
            impact_driver, issue_request(safe, safe_session, False), root, "safe-issue"
        )
        safe_aggregate_dir = root / "safe-aggregate"
        safe_aggregate_dir.mkdir(mode=0o700)
        safe_request = aggregate_request(
            aggregate_dir=safe_aggregate_dir,
            kernel=kernel,
            kernel_sha256=kernel_sha256,
            identity=safe_identity,
            session_dir=safe_session,
            receipt_id=safe_issue["receipt_id"],
        )
        safe_aggregate = invoke_driver(
            impact_driver, safe_request, root, "safe-aggregate"
        )
        assert_rejected(safe_aggregate, "policy_satisfied")

        journal_path = safe_session / "tool-observations.jsonl"
        journal_bytes = bytearray(journal_path.read_bytes())
        journal_bytes[0] = ord("[")
        journal_path.write_bytes(journal_bytes)
        invoke_driver_fails(
            impact_driver, safe_request, root, "tampered-journal-aggregate"
        )

        outcome_path = hazard_session / hazard_issue["outcome_evidence_name"]
        with outcome_path.open("ab") as handle:
            handle.write(b" ")
        invoke_driver_fails(
            impact_driver,
            hazard_aggregate_request,
            root,
            "tampered-evidence-aggregate",
        )

        return {
            "schema_version": "metacodes-rule-impact-driver-l2-result-v1",
            "quality_evidence": False,
            "provider_requests": 0,
            "kernel_sha256": kernel_sha256,
            "counterfactual_shadow_promoted": True,
            "checker_identity_failure_rejected": True,
            "untrusted_without_divergence_rejected": True,
            "stale_policy_rejected": True,
            "tampered_journal_rejected": True,
            "tampered_evidence_rejected": True,
            "receipt_replay_idempotent": True,
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--eval-driver", type=Path, required=True)
    parser.add_argument("--impact-driver", type=Path, required=True)
    parser.add_argument("--kernel", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    result = run_l2(
        args.eval_driver.resolve(),
        args.impact_driver.resolve(),
        args.kernel.resolve(),
    )
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
