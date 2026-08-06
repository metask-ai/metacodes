"""Release-gate evidence for location-independent shipped artifacts."""

from __future__ import annotations

import concurrent.futures
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


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


if __name__ == "__main__":
    unittest.main()
