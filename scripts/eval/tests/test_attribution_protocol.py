from __future__ import annotations

import copy
from collections import Counter
import contextlib
import io
import json
from pathlib import Path
import unittest

from scripts.eval.attribution_protocol import (
    CELL_IDS,
    balanced_factorial_schedule,
    dry_run_plan,
    load_protocol,
    main,
    validate_protocol,
)
from scripts.eval.model import ValidationError


ROOT = Path(__file__).resolve().parents[3]
PROTOCOL_PATH = ROOT / "evals/experiments/tinykg-lean-attribution-v1.json"


class AttributionProtocolTest(unittest.TestCase):
    def setUp(self) -> None:
        self.protocol = load_protocol(PROTOCOL_PATH)

    def test_checked_in_protocol_is_valid_and_zero_paid(self) -> None:
        validate_protocol(self.protocol, ROOT)
        plan = dry_run_plan(self.protocol)
        self.assertEqual(0, plan["provider_requests"])
        self.assertFalse(plan["paid_rollouts_enabled"])
        self.assertFalse(plan["quality_evidence"])
        self.assertEqual(["s3_factorial_interaction"], plan["workbuddy_blocked_by"])

    def test_cli_dry_run_is_machine_readable_and_zero_paid(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(
                0,
                main(
                    [
                        "dry-run",
                        "--protocol",
                        str(PROTOCOL_PATH),
                        "--root",
                        str(ROOT),
                    ]
                ),
            )
        result = json.loads(output.getvalue())
        self.assertEqual(0, result["provider_requests"])
        self.assertFalse(result["paid_rollouts_enabled"])

    def test_zero_paid_gate_requires_all_three_real_wiring_paths(self) -> None:
        broken = copy.deepcopy(self.protocol)
        broken["stages"][0]["runners"].pop()
        with self.assertRaisesRegex(ValidationError, "memory, ontology-to-rule"):
            validate_protocol(broken, ROOT)

    def test_factorial_cells_must_be_complete_and_unconfounded(self) -> None:
        broken = copy.deepcopy(self.protocol)
        broken["factorial_cells"][3]["lean"] = False
        with self.assertRaisesRegex(ValidationError, "complete 2x2|does not encode"):
            validate_protocol(broken, ROOT)

    def test_workbuddy_cannot_precede_factorial_interaction(self) -> None:
        broken = copy.deepcopy(self.protocol)
        broken["stages"][-1]["predecessors"] = ["s1_tinykg_main_effect"]
        with self.assertRaisesRegex(ValidationError, "predecessor drift"):
            validate_protocol(broken, ROOT)

    def test_factorial_stage_binds_executor_and_analyzer(self) -> None:
        for field, value in (
            ("runner", "scripts/eval/tinykg_lean_factorial.py"),
            ("analyzer", "scripts/eval/tinykg_lean_factorial_block.py"),
        ):
            with self.subTest(field=field):
                broken = copy.deepcopy(self.protocol)
                broken["stages"][3][field] = value
                with self.assertRaisesRegex(
                    ValidationError, "unified native factorial executor|analyzer"
                ):
                    validate_protocol(broken, ROOT)

    def test_resolved_production_executor_gap_cannot_return(self) -> None:
        broken = copy.deepcopy(self.protocol)
        broken["known_gaps"].append("production executor still missing")
        with self.assertRaisesRegex(ValidationError, "resolved.*stale"):
            validate_protocol(broken, ROOT)

    def test_smoke_cannot_claim_quality_evidence(self) -> None:
        broken = copy.deepcopy(self.protocol)
        broken["stages"][0]["quality_evidence"] = True
        with self.assertRaisesRegex(ValidationError, "wiring smoke"):
            validate_protocol(broken, ROOT)

    def test_source_identity_drift_fails_closed(self) -> None:
        broken = copy.deepcopy(self.protocol)
        broken["datasets"]["episodic"]["pin_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValidationError, "source identity drift"):
            validate_protocol(broken, ROOT)

    def test_cache_contract_does_not_demand_impossible_tinykg_request_equality(self) -> None:
        broken = copy.deepcopy(self.protocol)
        broken["cache_contract"]["full_first_request_equal_when_tinykg_changes"] = True
        with self.assertRaisesRegex(ValidationError, "cache_contract"):
            validate_protocol(broken, ROOT)

    def test_budget_authority_and_preflight_remain_fail_closed(self) -> None:
        for field, value in (
            ("maximum_user_authority_usd", 2001.0),
            ("preflight_paid_rollouts_enabled", True),
            ("provider_retries", 1),
        ):
            with self.subTest(field=field):
                broken = copy.deepcopy(self.protocol)
                broken["budget"][field] = value
                with self.assertRaisesRegex(ValidationError, "budget"):
                    validate_protocol(broken, ROOT)

    def test_balanced_factorial_schedule_balances_positions_and_carryover(self) -> None:
        schedule = balanced_factorial_schedule(["case-d", "case-b", "case-a", "case-c"])
        self.assertEqual(list(range(16)), [row["sequence"] for row in schedule])
        positions = Counter((row["position"], row["cell"]) for row in schedule)
        self.assertEqual({1}, set(positions.values()))
        by_case: dict[str, list[str]] = {}
        for row in schedule:
            by_case.setdefault(row["case_id"], []).append(row["cell"])
        carryover = Counter(
            pair
            for order in by_case.values()
            for pair in zip(order, order[1:])
        )
        self.assertEqual(set(CELL_IDS), {cell for order in by_case.values() for cell in order})
        self.assertEqual(12, len(carryover))
        self.assertEqual({1}, set(carryover.values()))

    def test_factorial_schedule_rejects_partial_or_duplicate_blocks(self) -> None:
        for case_ids in (["a", "b"], ["a", "a", "b", "c"]):
            with self.subTest(case_ids=case_ids):
                with self.assertRaisesRegex(ValidationError, "blocks of four"):
                    balanced_factorial_schedule(case_ids)


if __name__ == "__main__":
    unittest.main()
