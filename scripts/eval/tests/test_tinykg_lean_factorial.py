from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from scripts.eval.attribution_protocol import balanced_factorial_schedule
from scripts.eval.model import ValidationError, stable_json
from scripts.eval.tinykg_lean_factorial import (
    PROTOCOL_ID,
    REFERENCE_SCHEMA,
    ROLLOUT_SCHEMA,
    build_report,
    dry_run_plan,
    load_receipts,
)
from scripts.eval.tests.posix_only import requires_posix_mode_bits


CASES = ("factor-a", "factor-b", "factor-c", "factor-d")


def digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def projection(schedule: dict[str, object]) -> dict[str, object]:
    cell = str(schedule["cell"])
    tinykg = cell in {"memory_only", "combined"}
    lean = cell in {"lean_only", "combined"}
    first_request_class = "memory" if tinykg else "plain"
    success = cell in {"memory_only", "combined"}
    return {
        "sequence": schedule["sequence"],
        "case_id": schedule["case_id"],
        "position": schedule["position"],
        "cell": cell,
        "factors": {"tinykg": tinykg, "lean": lean},
        "identity": {
            "model_fingerprint": digest("glm-5.2"),
            "harness_revision": digest("harness"),
            "task_fingerprint": digest(f"task:{schedule['case_id']}"),
            "actor_prompt_sha256": digest(f"prompt:{schedule['case_id']}"),
            "tool_schema_sha256": digest("tools"),
            "stable_core_prefix_sha256": digest("core-prefix"),
            "first_request_sha256": digest(
                f"request:{schedule['case_id']}:{first_request_class}"
            ),
        },
        "treatment": {
            "tinykg": {
                "enabled": tinykg,
                "transport": "cli-exclusive" if tinykg else "disabled",
                "store_scope": "fresh-run-local" if tinykg else "none",
                "remote_writes": 0,
                "recall_receipt_verified": tinykg,
                "read_count": 1 if tinykg else 0,
                "store_revision_sha256": digest(
                    f"store:{schedule['sequence']}"
                )
                if tinykg
                else None,
            },
            "lean": {
                "enabled": lean,
                "bundle_loaded": lean,
                "checker_sha256": digest("checker") if lean else None,
                "bundle_sha256": digest("bundle") if lean else None,
                "checker_calls": 1 if lean else 0,
                "formal_decisions": 1 if lean else 0,
                "unsafe_false_interventions": 0,
            },
        },
        "outcomes": {
            "task_success": success,
            "trustworthy_success": success,
            "error_recurrence": cell in {"control", "memory_only"},
            "effective_intervention": lean,
            "false_intervention": False,
            "recovery_success": lean,
        },
        "usage": {
            "cost_microusd": 100 + int(schedule["sequence"]),
            "metered_tokens": 1000,
            "provider_requests": 2,
            "wall_time_ms": 500,
            "model_time_ms": 400,
            "tool_time_ms": 80,
            "checker_time_ns": 1_000_000 if lean else 0,
            "memory_exposed_tokens": 50 if tinykg else 0,
        },
        "quality_evidence": True,
    }


def write_evidence(root: Path, rows: list[dict[str, object]]) -> Path:
    references: list[dict[str, object]] = []
    for index, item in enumerate(rows):
        receipt = {
            "schema_version": ROLLOUT_SCHEMA,
            "protocol_id": PROTOCOL_ID,
            "projection_sha256": hashlib.sha256(
                stable_json(item).encode("utf-8")
            ).hexdigest(),
            "host_reopened_source_evidence": True,
            "raw_artifacts_local_only": True,
            "projection": item,
        }
        payload = (stable_json(receipt) + "\n").encode("utf-8")
        path = root / f"receipt-{index:05d}.json"
        path.write_bytes(payload)
        path.chmod(0o600)
        references.append(
            {
                "sequence": index,
                "path": path.name,
                "sha256": hashlib.sha256(payload).hexdigest(),
            }
        )
    references_path = root / "references.json"
    references_path.write_text(
        stable_json(
            {
                "schema_version": REFERENCE_SCHEMA,
                "protocol_id": PROTOCOL_ID,
                "receipts": references,
            }
        )
        + "\n",
        encoding="utf-8",
    )
    references_path.chmod(0o600)
    return references_path


class TinyKgLeanFactorialTest(unittest.TestCase):
    def rows(self) -> list[dict[str, object]]:
        return [projection(dict(item)) for item in balanced_factorial_schedule(CASES)]

    def test_dry_run_freezes_complete_zero_paid_williams_block(self) -> None:
        plan = dry_run_plan(CASES)
        self.assertEqual(0, plan["provider_requests"])
        self.assertFalse(plan["paid_rollouts_enabled"])
        self.assertFalse(plan["quality_evidence"])
        self.assertEqual(16, plan["rollouts"])
        self.assertEqual(list(range(16)), [row["sequence"] for row in plan["schedule"]])

    def test_authenticated_receipts_admit_all_cells_and_compute_interaction(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            references = write_evidence(root, self.rows())
            reopened = load_receipts(
                references_path=references,
                evidence_root=root,
                case_ids=CASES,
            )
            report = build_report(
                reopened.projections,
                CASES,
                evidence=reopened,
            )
        self.assertTrue(report["quality_evidence"])
        self.assertTrue(report["all_gates_passed"])
        self.assertFalse(report["confirmatory_claim_eligible"])
        self.assertEqual(4, report["cells"]["combined"]["outcomes"]["task_success"])
        self.assertEqual(
            0.0,
            report["contrasts"]["factorial_interaction"]["outcome_rate_delta"][
                "task_success"
            ],
        )
        self.assertEqual(16, report["evidence"]["receipt_count"])
        self.assertEqual(
            [0.0, 0.0, 0.0, 0.0],
            report["contrasts"]["factorial_interaction"]["paired_calibration"][
                "outcomes"
            ]["task_success"]["paired_values"],
        )

    def test_lean_must_not_change_first_request_within_memory_level(self) -> None:
        rows = self.rows()
        target = next(row for row in rows if row["cell"] == "lean_only")
        target["identity"]["first_request_sha256"] = digest("hidden-lean-prefix")
        with self.assertRaisesRegex(ValidationError, "Lean changed the no-memory first request"):
            build_report(rows, CASES)

    def test_remote_tinykg_or_fake_off_treatment_fails_closed(self) -> None:
        for field, value, message in (
            ("remote_writes", 1, "remote TinyKG writes"),
            ("transport", "daemon", "TinyKG treatment was not proven"),
        ):
            with self.subTest(field=field):
                rows = self.rows()
                target = next(row for row in rows if row["cell"] == "memory_only")
                target["treatment"]["tinykg"][field] = value
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    references = write_evidence(root, rows)
                    with self.assertRaisesRegex(ValidationError, message):
                        load_receipts(
                            references_path=references,
                            evidence_root=root,
                            case_ids=CASES,
                        )

    def test_receipt_tamper_and_zero_checker_calls_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            references = write_evidence(root, self.rows())
            receipt = root / "receipt-00000.json"
            receipt.write_bytes(receipt.read_bytes() + b" ")
            with self.assertRaisesRegex(ValidationError, "SHA-256 drift"):
                load_receipts(
                    references_path=references,
                    evidence_root=root,
                    case_ids=CASES,
                )

        rows = self.rows()
        for row in rows:
            if row["factors"]["lean"]:
                row["treatment"]["lean"]["checker_calls"] = 0
                row["usage"]["checker_time_ns"] = 0
        with self.assertRaisesRegex(ValidationError, "no real checker call"):
            build_report(rows, CASES)

    @requires_posix_mode_bits
    def test_smoke_rows_and_unsafe_receipt_files_cannot_claim_quality(self) -> None:
        unauthenticated = build_report(self.rows(), CASES)
        self.assertFalse(unauthenticated["quality_evidence"])
        self.assertFalse(unauthenticated["gates"]["authenticated_receipt_bundle"])

        rows = self.rows()
        rows[0]["usage"]["provider_requests"] = 0
        with self.assertRaisesRegex(ValidationError, "real paid provider activity"):
            build_report(rows, CASES)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            references = write_evidence(root, self.rows())
            references.chmod(0o644)
            with self.assertRaisesRegex(ValidationError, "permissions must be 0600"):
                load_receipts(
                    references_path=references,
                    evidence_root=root,
                    case_ids=CASES,
                )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            references = write_evidence(root, self.rows())
            target = root / "references-target.json"
            references.rename(target)
            references.symlink_to(target.name)
            with self.assertRaisesRegex(ValidationError, "must not be a symlink"):
                load_receipts(
                    references_path=references,
                    evidence_root=root,
                    case_ids=CASES,
                )

    def test_negative_outcome_remains_quality_evidence_but_cannot_promote(self) -> None:
        rows = self.rows()
        for row in rows:
            if row["cell"] == "control":
                row["outcomes"]["task_success"] = True
                row["outcomes"]["trustworthy_success"] = True
            if row["cell"] == "combined":
                row["outcomes"]["trustworthy_success"] = False
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            references = write_evidence(root, rows)
            reopened = load_receipts(
                references_path=references,
                evidence_root=root,
                case_ids=CASES,
            )
            report = build_report(reopened.projections, CASES, evidence=reopened)
        self.assertTrue(report["quality_evidence"])
        self.assertTrue(report["evidence_gates_passed"])
        self.assertFalse(report["promotion_gates_passed"])
        self.assertFalse(report["all_gates_passed"])


if __name__ == "__main__":
    unittest.main()
