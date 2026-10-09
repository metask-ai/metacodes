import hashlib
import json
import math
import tempfile
import unittest
from pathlib import Path

from scripts.eval.jev_recall_order_pilot import (
    CONTROL_ARM,
    TREATMENT_ARM,
    analyze,
    eligible_cases,
    exact_mcnemar,
    main,
)
from scripts.eval.model import ValidationError


def _digest(question_id):
    return hashlib.sha256(question_id.encode("utf-8")).hexdigest()


class EligibleCasesTest(unittest.TestCase):
    def _slice(self):
        # Positions 0..203: only 200.. are holdout.
        manifest_cases, source_cases = [], []
        kinds = {
            200: ("multi-session", ["$1,200"]),
            201: ("single-session-preference", ["Target"]),
            202: ("temporal-reasoning", ["The user would prefer a quiet table near the window"]),
            203: ("knowledge-update", ["a much longer refusal sentence here", "Paris"]),
        }
        for position in range(204):
            question_type, golds = kinds.get(position, ("single-session-user", ["x"]))
            case_id = f"longmem:{question_type}:{position:032d}"
            manifest_cases.append({"id": case_id, "gold_answers": golds})
            source_cases.append(
                {"id": case_id, "question_type": question_type, "source_id_sha256": _digest(str(position))}
            )
        return {"cases": manifest_cases}, {"cases": source_cases}

    def test_holdout_rule_drops_preference_and_free_text_answers(self):
        manifest, source = self._slice()
        cases = eligible_cases(manifest, source)
        self.assertEqual([case["position"] for case in cases], [200, 203])
        self.assertEqual(cases[1]["question_type"], "knowledge-update")
        self.assertEqual(cases[0]["source_id_sha256"], _digest("200"))


class ShardTest(unittest.TestCase):
    def test_shard_keeps_exactly_the_chosen_upstream_records(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cases = [{"case_id": f"c{i}", "source_id_sha256": _digest(f"q{i}")} for i in range(4)]
            (root / "cases.json").write_text(
                json.dumps({"schema_version": "metacodes-jev-recall-order-pilot-cases-v1", "cases": cases}),
                encoding="utf-8",
            )
            upstream = [{"question_id": f"q{i}", "answer": i} for i in range(6)]
            (root / "upstream.json").write_text(json.dumps(upstream), encoding="utf-8")
            args = ["shard", "--cases", str(root / "cases.json"), "--upstream", str(root / "upstream.json")]
            main([*args, "--start", "1", "--count", "2", "--output", str(root / "shard.json")])
            kept = json.loads((root / "shard.json").read_text(encoding="utf-8"))
            self.assertEqual([record["question_id"] for record in kept], ["q1", "q2"])
            with self.assertRaises(ValidationError):
                main([*args, "--start", "3", "--count", "2", "--output", str(root / "past-end.json")])
            main([*args, "--indices", "3,0", "--output", str(root / "rerun.json")])
            rerun = json.loads((root / "rerun.json").read_text(encoding="utf-8"))
            self.assertEqual(sorted(record["question_id"] for record in rerun), ["q0", "q3"])
            for bad in (["--indices", "1,1"], ["--indices", "4"], ["--indices", "1", "--start", "0"]):
                with self.assertRaises(ValidationError):
                    main([*args, *bad, "--output", str(root / "bad.json")])


def _row(case_id, arm, *, success=True, verified=("s1",), cost=0.05):
    return {
        "case_id": case_id,
        "arm": arm,
        "outcome": {"success": success},
        "retrieval": {"expected_evidence_ids": ["s1"], "verified_evidence_ids": list(verified)},
        "cost": {"cost_usd": cost},
        "memory": {"exposed_tokens": 100},
    }


class AnalyzeTest(unittest.TestCase):
    def test_pairs_by_case_and_excludes_invalid_rows_from_both_tests(self):
        rows = [
            # treatment opens the gold evidence, control does not
            _row("a", CONTROL_ARM, verified=()),
            _row("a", TREATMENT_ARM),
            # both do
            _row("b", CONTROL_ARM),
            _row("b", TREATMENT_ARM, success=False),
            # control row invalid: the pair is out of both tests
            _row("c", CONTROL_ARM, success=None),
            _row("c", TREATMENT_ARM),
            # unmatched
            _row("d", TREATMENT_ARM, cost=0.2),
            # the cold-start control is reported, never tested
            _row("a", "no_memory", success=False, verified=()),
        ]
        summary = analyze(rows)
        self.assertEqual((summary["cases"], summary["valid_pairs"]), (4, 2))
        self.assertEqual(summary["invalid_rows"], {"no_memory": 0, CONTROL_ARM: 1, TREATMENT_ARM: 0})
        primary = summary["primary_verified_gold_evidence"]
        self.assertEqual((primary["control"], primary["treatment"]), (1, 2))
        self.assertEqual((primary["only_treatment"], primary["only_control"]), (1, 0))
        secondary = summary["secondary_exact_match"]
        self.assertEqual((secondary["only_treatment"], secondary["only_control"]), (0, 1))
        self.assertEqual(summary["diagnostics"][TREATMENT_ARM]["max_cost_usd"], 0.2)
        self.assertEqual(summary["diagnostics"]["no_memory"]["rows"], 1)
        self.assertEqual(summary["diagnostics"]["no_memory"]["exact_match"], 0)

    def test_rejects_foreign_arms_and_duplicate_rows(self):
        with self.assertRaises(ValidationError):
            analyze([_row("a", "tinykg_lexical")])
        with self.assertRaises(ValidationError):
            analyze([_row("a", CONTROL_ARM), _row("a", CONTROL_ARM)])

    def test_exact_mcnemar(self):
        self.assertAlmostEqual(exact_mcnemar(13, 4), 2 * sum(math.comb(17, i) for i in range(5)) / 2**17)
        self.assertEqual(exact_mcnemar(0, 0), 1.0)


if __name__ == "__main__":
    unittest.main()
