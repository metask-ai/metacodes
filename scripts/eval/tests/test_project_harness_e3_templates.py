from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from scripts.eval.project_harness_e3_templates import (
    TemplateError,
    _project_identity,
    _tree_digest,
    build_templates,
    verify_templates,
)


class ProjectHarnessE3TemplatesTest(unittest.TestCase):
    def test_project_identity_uses_the_host_domain_separator(self) -> None:
        path = Path("/tmp/metacodes-project-identity-fixture")
        import hashlib

        expected = hashlib.sha256(
            b"metacodes-project-identity-v1\x00" + os.fsencode(str(path))
        ).hexdigest()
        self.assertEqual(expected, _project_identity(path))

    def test_tree_digest_rejects_links(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for index in range(5):
                (root / f"entry-{index}").write_text(str(index), encoding="utf-8")
            digest = _tree_digest(root)
            self.assertEqual(5, digest["files"])

            symlink = root / "symlink"
            symlink.symlink_to(root / "entry-0")
            with self.assertRaises((TemplateError, RuntimeError)):
                _tree_digest(root)
            symlink.unlink()

            hardlink = root / "hardlink"
            os.link(root / "entry-0", hardlink)
            with self.assertRaises(TemplateError):
                _tree_digest(root)

    def test_native_templates_and_fail_closed_gates_when_explicitly_configured(self) -> None:
        driver_raw = os.environ.get("METACODES_TEST_PROJECT_HARNESS_LIFECYCLE_DRIVER")
        kernel_raw = os.environ.get("METACODES_TEST_PROJECT_KERNEL_PATH")
        lake_raw = os.environ.get("METACODES_TEST_PROJECT_LAKE_PATH")
        if not driver_raw or not kernel_raw or not lake_raw:
            self.skipTest("native E3 template driver/kernel/lake not configured")
        repo = Path(__file__).resolve().parents[3]
        driver = Path(driver_raw)
        kernel = Path(kernel_raw)
        lake = Path(lake_raw)
        builder = repo / "scripts/build_project_rule.py"
        with tempfile.TemporaryDirectory(prefix="metacodes-project-e3-templates-") as temporary:
            root = Path(temporary) / "setup"
            result = build_templates(
                repo=repo,
                root=root,
                driver=driver,
                kernel=kernel,
                lake=lake,
                builder=builder,
                allow_dirty=True,
            )
            manifest_path = root / "templates-manifest.json"
            self.assertFalse(result["quality_evidence"])
            self.assertEqual(not result["repository"]["dirty"], result["paid_rollout_eligible"])
            self.assertEqual({"static", "evolved"}, set(result["templates"]))
            self.assertNotEqual(
                result["templates"]["static"]["bundle_sha256"],
                result["templates"]["evolved"]["bundle_sha256"],
            )
            self.assertEqual(
                Path(f"{kernel.resolve()}.provenance.json"),
                Path(result["artifacts"]["kernel"]["provenance_path"]),
            )
            verify_templates(manifest_path, repo, require_clean=False)

            static_rules = Path(result["templates"]["static"]["rules_dir"])
            active = static_rules / "active.json"
            active_raw = active.read_bytes()
            active.write_bytes(active_raw + b"tamper")
            with self.assertRaises((TemplateError, RuntimeError)):
                verify_templates(manifest_path, repo, require_clean=False)
            active.write_bytes(active_raw)

            manifest_raw = manifest_path.read_bytes()
            manifest = json.loads(manifest_raw)
            manifest["templates"]["static"]["flavor"] = "evolved"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaises(TemplateError):
                verify_templates(manifest_path, repo, require_clean=False)
            manifest_path.write_bytes(manifest_raw)

            manifest = json.loads(manifest_raw)
            manifest["project_sha256"] = "0" * 64
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaises(TemplateError):
                verify_templates(manifest_path, repo, require_clean=False)
            manifest_path.write_bytes(manifest_raw)

            manifest = json.loads(manifest_raw)
            manifest["artifacts"]["kernel"]["provenance_sha256"] = "0" * 64
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaises(TemplateError):
                verify_templates(manifest_path, repo, require_clean=False)
            manifest_path.write_bytes(manifest_raw)

            legacy_manifest = json.loads(manifest_raw)
            legacy_manifest["artifacts"]["kernel"] = {
                "path": legacy_manifest["artifacts"]["kernel"]["path"],
                "sha256": legacy_manifest["artifacts"]["kernel"]["sha256"],
            }
            legacy_path = root / "legacy-templates-manifest.json"
            legacy_path.write_text(json.dumps(legacy_manifest), encoding="utf-8")
            verify_templates(
                legacy_path,
                repo,
                require_clean=False,
                require_kernel_provenance=False,
            )

            manifest_link = root / "templates-manifest-link.json"
            manifest_link.symlink_to(manifest_path)
            with self.assertRaises(RuntimeError):
                verify_templates(manifest_link, repo, require_clean=False)

            evidence = Path(temporary) / "binding-evidence"
            project = Path(temporary) / "binding-project"
            home = Path(temporary) / "binding-home"
            evidence.mkdir()
            prepare = subprocess.run(
                [
                    str(driver),
                    "--phase", "prepare",
                    "--root", str(evidence),
                    "--project-root", str(project),
                    "--home-root", str(home),
                    "--rule-flavor", "static",
                ],
                cwd=repo,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(0, prepare.returncode, prepare.stderr.decode("utf-8", "replace"))
            wrong_project = Path(temporary) / "wrong-project"
            wrong_project.mkdir()
            rejected = subprocess.run(
                [
                    str(driver),
                    "--phase", "finalize",
                    "--root", str(evidence),
                    "--project-root", str(wrong_project),
                    "--home-root", str(home),
                    "--rule-flavor", "static",
                    "--repo", str(repo),
                    "--build-dir", str(Path(temporary)),
                    "--lake", str(lake),
                    "--kernel", str(kernel),
                    "--kernel-sha256", result["artifacts"]["kernel"]["sha256"],
                ],
                cwd=repo,
                env={
                    "PATH": os.defpath,
                    "LANG": "C",
                    "LC_ALL": "C",
                    "METACODES_PROJECT_KERNEL_PATH": str(kernel),
                    "METACODES_PROJECT_KERNEL_SHA256": result["artifacts"]["kernel"]["sha256"],
                },
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(0, rejected.returncode)
            self.assertIn("InvalidPrepareResult", rejected.stderr.decode("utf-8", "replace"))


if __name__ == "__main__":
    unittest.main()
