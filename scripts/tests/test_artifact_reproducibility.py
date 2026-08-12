"""Release-gate evidence for location-independent shipped artifacts."""

from __future__ import annotations

import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from scripts.eval.experiment import formal_kernel_identity


PROJECT_ROOT = Path(__file__).resolve().parents[2]


class TinyKgArtifactReproducibilityTest(unittest.TestCase):
    def test_two_isolated_vendor_builds_are_byte_identical_and_runnable(self) -> None:
        zig = os.environ.get("METACODES_ZIG") or shutil.which("zig")
        self.assertIsNotNone(zig, "zig is required for artifact reproducibility evidence")

        # Different-length cache and prefix paths are intentional.  An unstripped
        # ReleaseSafe Mach-O records those paths in N_OSO/N_SO symbols, which then
        # perturbs LC_UUID and the linker-generated ad-hoc signature.
        with tempfile.TemporaryDirectory(prefix="metacodes-repro-a-") as first_dir, tempfile.TemporaryDirectory(
            prefix="metacodes-repro-deliberately-longer-b-"
        ) as second_dir:
            roots = (Path(first_dir), Path(second_dir))

            def build(root: Path) -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    [
                        str(zig),
                        "build",
                        "vendor:tinykg",
                        "--cache-dir",
                        str(root / "cache"),
                        "--prefix",
                        str(root / "out"),
                        "-j2",
                        "--summary",
                        "none",
                    ],
                    cwd=PROJECT_ROOT,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    timeout=300,
                    check=False,
                )

            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
                results = list(executor.map(build, roots))
            for result in results:
                self.assertEqual(0, result.returncode, result.stdout)

            executable = "tinykg.exe" if os.name == "nt" else "tinykg"
            artifacts = [root / "out" / "vendor" / "tinykg" / executable for root in roots]
            payloads = [artifact.read_bytes() for artifact in artifacts]
            self.assertGreater(len(payloads[0]), 0)
            self.assertEqual(
                hashlib.sha256(payloads[0]).hexdigest(),
                hashlib.sha256(payloads[1]).hexdigest(),
                "same-source TinyKG builds changed with cache/prefix location",
            )
            self.assertEqual(payloads[0], payloads[1])

            versions = [
                subprocess.run(
                    [str(artifact), "version"],
                    cwd=PROJECT_ROOT,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    timeout=30,
                    check=False,
                )
                for artifact in artifacts
            ]
            for result in versions:
                self.assertEqual(0, result.returncode, result.stdout)
                self.assertIn("tinykg", result.stdout.lower())
            self.assertEqual(versions[0].stdout, versions[1].stdout)


class FormalKernelArtifactIdentityReproducibilityTest(unittest.TestCase):
    def test_two_isolated_complete_builds_share_identity_and_bind_time_receipts(
        self,
    ) -> None:
        bash = shutil.which("bash")
        self.assertIsNotNone(bash, "bash is required for formal artifact evidence")
        lake = os.environ.get("LAKE") or str(Path.home() / ".elan/bin/lake")
        self.assertTrue(
            Path(lake).is_file() and os.access(lake, os.X_OK),
            f"lake is required for formal artifact evidence: {lake}",
        )
        build_script = PROJECT_ROOT / "scripts/build-formal-kernel.sh"

        with tempfile.TemporaryDirectory(
            prefix="metacodes-formal-repro-a-"
        ) as first_dir, tempfile.TemporaryDirectory(
            prefix="metacodes-formal-repro-deliberately-longer-b-"
        ) as second_dir:
            roots = (Path(first_dir), Path(second_dir))
            artifacts = []
            for root in roots:
                (root / "scripts").mkdir()
                shutil.copy2(build_script, root / "scripts/build-formal-kernel.sh")
                shutil.copytree(
                    PROJECT_ROOT / "control-plane/lean",
                    root / "control-plane/lean",
                    ignore=shutil.ignore_patterns(".lake"),
                )
                artifacts.append(root / "out/metacodes-formal-kernel")
            results = []
            for artifact in artifacts:
                env = os.environ.copy()
                env["LAKE"] = lake
                isolated_script = artifact.parents[1] / "scripts/build-formal-kernel.sh"
                results.append(
                    subprocess.run(
                        [str(bash), str(isolated_script), str(artifact)],
                        cwd=artifact.parents[1],
                        env=env,
                        text=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                        timeout=300,
                        check=False,
                    )
                )
            for result in results:
                self.assertEqual(0, result.returncode, result.stdout)

            payloads = [artifact.read_bytes() for artifact in artifacts]
            manifests = [
                Path(f"{artifact}.provenance.json").read_bytes()
                for artifact in artifacts
            ]
            identities = [formal_kernel_identity(artifact) for artifact in artifacts]
            self.assertEqual(payloads[0], payloads[1])
            self.assertEqual(
                hashlib.sha256(payloads[0]).hexdigest(),
                hashlib.sha256(payloads[1]).hexdigest(),
            )
            self.assertEqual(manifests[0], manifests[1])
            self.assertEqual(
                identities[0]["artifact_fingerprint"],
                identities[1]["artifact_fingerprint"],
            )

            for artifact, identity in zip(artifacts, identities):
                manifest = json.loads(
                    Path(identity["provenance_path"]).read_text(encoding="utf-8")
                )
                receipt = json.loads(
                    Path(identity["build_receipt_path"]).read_text(encoding="utf-8")
                )
                self.assertNotIn("built_at_utc", manifest)
                self.assertEqual(
                    "metacodes-formal-build-receipt-v1", receipt["schema_version"]
                )
                self.assertEqual(
                    identity["provenance_sha256"],
                    receipt["artifact_manifest_sha256"],
                )
                self.assertEqual(
                    hashlib.sha256(artifact.read_bytes()).hexdigest(),
                    receipt["binary_sha256"],
                )


if __name__ == "__main__":
    unittest.main()
