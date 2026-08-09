from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
import unittest

from scripts.eval.project_harness_evolution import (
    EvolutionError,
    analyze_lifecycle,
    freeze_manifest,
    run_evolution,
)


class ProjectHarnessEvolutionTest(unittest.TestCase):
    def test_manifest_freezes_e2_without_claiming_model_quality(self) -> None:
        repo = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            driver = root / "driver"
            kernel = root / "kernel"
            lake = root / "lake"
            builder = root / "builder.py"
            for path in (driver, kernel, lake, builder):
                path.write_bytes(path.name.encode("ascii"))
            manifest = freeze_manifest(repo, root, driver, kernel, lake, builder)
            self.assertEqual("E2", manifest["evidence_level"])
            self.assertFalse(manifest["quality_evidence"])
            self.assertFalse(manifest["outcome_superiority_claimed"])
            self.assertEqual("none", manifest["provider_mode"])
            self.assertEqual(0, manifest["external_network_calls_authorized"])
            self.assertFalse(manifest["cache_claim"]["provider_visible_prefix_measured"])

    def test_native_lifecycle_and_tamper_gate_when_explicitly_configured(self) -> None:
        driver_raw = os.environ.get("METACODES_TEST_PROJECT_HARNESS_LIFECYCLE_DRIVER")
        kernel_raw = os.environ.get("METACODES_TEST_PROJECT_KERNEL_PATH")
        lake_raw = os.environ.get("METACODES_TEST_PROJECT_LAKE_PATH")
        if not driver_raw or not kernel_raw or not lake_raw:
            self.skipTest("native project-Harness lifecycle driver/kernel/lake not configured")
        repo = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory(prefix="metacodes-project-evolution-test-") as temporary:
            root = Path(temporary)
            report = run_evolution(
                repo,
                root,
                Path(driver_raw),
                Path(kernel_raw),
                Path(lake_raw),
                repo / "scripts/build_project_rule.py",
            )
            self.assertTrue(report["evolution_lifecycle_passed"])
            self.assertFalse(report["quality_evidence"])
            self.assertTrue(report["gates"]["write_blocked_before_dispatch"])
            self.assertTrue(report["gates"]["edit_recovery_reobserved"])
            self.assertTrue(report["gates"]["provider_requests_zero"])
            final = json.loads((root / "lifecycle-final.json").read_text(encoding="utf-8"))
            self.assertEqual("evolved", final["rule_flavor"])
            self.assertTrue(final["runtime_task_succeeded"])
            self.assertTrue(final["runtime_recovery_succeeded"])

            journal_path = next(
                (root / "home/.metacodes/projects").glob(
                    "*/fedcba9876543210fedcba98/tool-observations.jsonl"
                )
            )
            journal_raw = journal_path.read_bytes()
            journal_path.write_bytes(journal_raw + b"tamper\n")
            with self.assertRaises(EvolutionError):
                analyze_lifecycle(root / "manifest.json")
            journal_path.write_bytes(journal_raw)

            active_path = next(
                (root / "home/.metacodes/projects").glob("*/project-rules/active.json")
            )
            extra_link = active_path.with_name("active-hardlink.json")
            os.link(active_path, extra_link)
            try:
                with self.assertRaises(EvolutionError):
                    analyze_lifecycle(root / "manifest.json")
            finally:
                extra_link.unlink()

            final_path = root / "lifecycle-final.json"
            final = json.loads(final_path.read_text(encoding="utf-8"))
            final["runtime_recovery_succeeded"] = False
            final_path.write_text(json.dumps(final), encoding="utf-8")
            with self.assertRaises(EvolutionError):
                analyze_lifecycle(root / "manifest.json")


if __name__ == "__main__":
    unittest.main()
