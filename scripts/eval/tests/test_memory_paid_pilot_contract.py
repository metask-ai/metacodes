import hashlib
import json
import sys
import unittest
from pathlib import Path

from scripts.eval.memory_agent_runtime import ProductionRuntimeConfig
from scripts.eval.memory_procedural_adapter import adapt_procedural, artifact_bytes
from scripts.eval.memory_replay import load_manifest


ROOT = Path(__file__).resolve().parents[3]
PILOT = ROOT / "evals/memory/pilots/procedural-glm52-v19"
TEST_RIPGREP = Path(sys.executable).resolve()
TEST_RIPGREP_SHA256 = hashlib.sha256(TEST_RIPGREP.read_bytes()).hexdigest()


class PaidPilotContractTest(unittest.TestCase):
    def test_v19_is_reproducible_balanced_and_resume_bound(self):
        contract = json.loads((PILOT / "pilot-contract.json").read_text(encoding="utf-8"))
        source = json.loads((PILOT / "source.json").read_text(encoding="utf-8"))
        manifest = load_manifest(PILOT / "manifest.json")
        execution = json.loads((PILOT / "execution.json").read_text(encoding="utf-8"))

        for name, identity in contract["artifacts"].items():
            payload = (PILOT / name).read_bytes()
            self.assertEqual(len(payload), identity["bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), identity["sha256"])

        fixture = ROOT / contract["generation"]["source_path"]
        self.assertEqual(
            hashlib.sha256(fixture.read_bytes()).hexdigest(),
            contract["generation"]["expected_upstream_sha256"],
        )
        self.assertEqual(
            [family["id"] for family in source["families"]],
            contract["generation"]["family_ids"],
        )
        regenerated = adapt_procedural(
            fixture,
            execution,
            expected_source_sha256=contract["generation"]["expected_upstream_sha256"],
            limit_families=contract["generation"]["limit_families"],
            split_seed=contract["generation"]["split_seed"],
        )
        for value, name in zip(
            regenerated,
            ("source.json", "validators.json", "manifest.json"),
        ):
            self.assertEqual(artifact_bytes(value), (PILOT / name).read_bytes())

        self.assertEqual(manifest["execution"], execution)
        self.assertEqual(manifest["manifest_id"], "coding-intent-families-2026080820-4")
        self.assertEqual(len(manifest["schedule"]), 144)
        self.assertNotEqual(
            hashlib.sha256((PILOT / "manifest.json").read_bytes()).hexdigest(),
            hashlib.sha256(
                (
                    ROOT
                    / "evals/memory/pilots/procedural-glm52-v18/manifest.json"
                ).read_bytes()
            ).hexdigest(),
        )

        positions = {}
        cases = {case["id"]: case for case in manifest["cases"]}
        offline_by_arm = {}
        for offset in range(0, len(manifest["schedule"]), 3):
            for position, row in enumerate(manifest["schedule"][offset : offset + 3]):
                positions[(row["arm"], position)] = (
                    positions.get((row["arm"], position), 0) + 1
                )
                if cases[row["case_id"]]["split"] == "offline":
                    offline_by_arm[row["arm"]] = offline_by_arm.get(row["arm"], 0) + 1
        self.assertEqual(set(positions.values()), {16})
        self.assertEqual(set(offline_by_arm.values()), {32})
        rows = [
            [item["sequence"], item["case_id"], item["trial"], item["arm"]]
            for item in manifest["schedule"]
        ]
        ordered_tsv = "".join("\t".join(str(value) for value in row) + "\n" for row in rows)
        self.assertEqual(
            hashlib.sha256(ordered_tsv.encode("utf-8")).hexdigest(),
            contract["schedule"]["ordered_tsv_sha256"],
        )

        guard = contract["incident_guard"]
        self.assertFalse(guard["v16_transaction_reuse"])
        self.assertFalse(guard["v17_transaction_reuse"])
        self.assertFalse(guard["v18_transaction_reuse"])
        self.assertEqual(
            [
                (item["pilot_id"], item["status"], item["uncertain_authorized_transactions"])
                for item in contract["predecessor_attempts"]
            ],
            [
                ("procedural-glm52-v16", "halted-runner-misclassification", 0),
                ("procedural-glm52-v17", "halted-evidence-validator-protocol-drift", 0),
                ("procedural-glm52-v18", "halted-provider-authentication-rejected", 1),
            ],
        )
        self.assertIn("explicit --resume-paid-run", contract["resume_contract"]["activation"])
        self.assertIn("before credential loading", contract["resume_contract"]["credential_gate"])
        self.assertIn("exactly match", contract["resume_contract"]["journal_binding"])
        self.assertIn("blocks replay", contract["resume_contract"]["commit_to_checkpoint_ambiguity"])

        budget = contract["budget_authority"]
        self.assertEqual(budget["prior_conservative_cost_usd"], 20.1836198)
        self.assertEqual(budget["prior_conservative_metered_tokens"], 18635513)
        self.assertLessEqual(
            budget["prior_conservative_cost_usd"] + budget["max_total_cost_usd"],
            budget["user_authorization_max_cost_usd"],
        )
        ProductionRuntimeConfig(
            api_key="test-only",
            allow_paid_rollouts=True,
            max_total_cost_usd=budget["max_total_cost_usd"],
            max_total_metered_tokens=budget["max_total_metered_tokens"],
            max_rollout_cost_usd=budget["max_rollout_cost_usd"],
            max_rollout_metered_tokens=budget["max_rollout_metered_tokens"],
            max_output_tokens=budget["max_output_tokens"],
            ripgrep_binary=TEST_RIPGREP,
            ripgrep_binary_sha256=TEST_RIPGREP_SHA256,
        ).validate(len(manifest["schedule"]))


if __name__ == "__main__":
    unittest.main()
