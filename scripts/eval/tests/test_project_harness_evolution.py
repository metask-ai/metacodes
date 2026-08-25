from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest

from scripts.eval.project_harness_evolution import (
    EvolutionError,
    analyze_lifecycle,
    freeze_manifest,
    run_evolution,
)


_REPO = Path(__file__).resolve().parents[3]
_SDK_OLEAN = _REPO / "control-plane/lean/.lake/build/lib/MetaCodesControl/ProjectRule.olean"


class ProjectHarnessEvolutionTest(unittest.TestCase):
    def _require_built_lean_sdk(self) -> None:
        # freeze_manifest 冻结的是 checked-in 源加上已编译 SDK olean;干净 checkout
        # 未构建 control-plane/lean 时按环境缺失显式 skip,与本文件其它 native 门一致。
        # CI 在运行本套件前用 leanprover/lean-action 构建,不会走到这条 skip。
        if not _SDK_OLEAN.is_file():
            self.skipTest(
                "compiled Lean SDK not built "
                "(run `lake build` in control-plane/lean to enable)"
            )

    def test_manifest_freezes_e2_without_claiming_model_quality(self) -> None:
        self._require_built_lean_sdk()
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
            self.assertEqual("evolved", manifest["runtime_contract"]["rule_flavor"])
            self.assertEqual(str((root / "project").resolve()), manifest["runtime_contract"]["project_root"])
            self.assertEqual(str((root / "home").resolve()), manifest["runtime_contract"]["home_root"])

    def test_manifest_freezes_external_project_path_but_keeps_home_local(self) -> None:
        self._require_built_lean_sdk()
        repo = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root.parent / f"{root.name}-workspace"
            project.mkdir()
            self.addCleanup(shutil.rmtree, project, True)
            driver = root / "driver"
            kernel = root / "kernel"
            lake = root / "lake"
            builder = root / "builder.py"
            for path in (driver, kernel, lake, builder):
                path.write_bytes(path.name.encode("ascii"))
            manifest = freeze_manifest(
                repo,
                root,
                driver,
                kernel,
                lake,
                builder,
                project_root=project,
                home_root=root / "home",
                rule_flavor="static",
            )
            self.assertEqual("static", manifest["runtime_contract"]["rule_flavor"])
            self.assertEqual(str(project.resolve()), manifest["runtime_contract"]["project_root"])
            with self.assertRaises(EvolutionError):
                freeze_manifest(
                    repo,
                    root,
                    driver,
                    kernel,
                    lake,
                    builder,
                    project_root=project,
                    home_root=project / "home",
                    rule_flavor="static",
                )

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
            self.assertTrue(report["gates"]["lean_authorized_host_rewrite_reobserved"])
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

    def test_static_lifecycle_accepts_frozen_external_project_and_rejects_forgery(self) -> None:
        driver_raw = os.environ.get("METACODES_TEST_PROJECT_HARNESS_LIFECYCLE_DRIVER")
        kernel_raw = os.environ.get("METACODES_TEST_PROJECT_KERNEL_PATH")
        lake_raw = os.environ.get("METACODES_TEST_PROJECT_LAKE_PATH")
        if not driver_raw or not kernel_raw or not lake_raw:
            self.skipTest("native project-Harness lifecycle driver/kernel/lake not configured")
        repo = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory(prefix="metacodes-project-static-test-") as temporary:
            root = Path(temporary) / "evidence"
            project = Path(temporary) / "workspace"
            project.mkdir()
            report = run_evolution(
                repo,
                root,
                Path(driver_raw),
                Path(kernel_raw),
                Path(lake_raw),
                repo / "scripts/build_project_rule.py",
                project_root=project,
                home_root=root / "home",
                rule_flavor="static",
            )
            self.assertTrue(report["evolution_lifecycle_passed"])
            self.assertEqual("static", report["rule_flavor"])
            self.assertEqual(str(project.resolve()), report["project_root"])
            self.assertTrue(report["gates"]["bounded_write_admitted_by_static_rule"])
            self.assertTrue(report["gates"]["static_write_effect_reobserved"])
            self.assertNotIn("write_blocked_before_dispatch", report["gates"])

            final_path = root / "lifecycle-final.json"
            final = json.loads(final_path.read_text(encoding="utf-8"))
            final["runtime_blocked_before_dispatch"] = True
            final_path.write_text(json.dumps(final), encoding="utf-8")
            with self.assertRaises(EvolutionError):
                analyze_lifecycle(root / "manifest.json")
            final["runtime_blocked_before_dispatch"] = False
            final_path.write_text(json.dumps(final), encoding="utf-8")

            manifest_path = root / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["runtime_contract"]["project_root"] = str(root / "forged-workspace")
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaises(EvolutionError):
                analyze_lifecycle(manifest_path)


if __name__ == "__main__":
    unittest.main()
