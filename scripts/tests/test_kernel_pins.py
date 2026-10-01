"""scripts/kernel_pins.py prints pins only for kernels that agree with their
sidecars. Python 3.9, stdlib only."""
from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts import kernel_pins


def _stage(prefix: Path, stem: str, body: bytes, recorded: str | None = None, exe: bool = False) -> str:
    base = prefix / "libexec" / "metacodes"
    base.mkdir(parents=True, exist_ok=True)
    binary = base / (stem + (".exe" if exe else ""))
    binary.write_bytes(body)
    digest = hashlib.sha256(body).hexdigest()
    sidecar = binary.with_name(binary.name + ".provenance.json")
    sidecar.write_text(json.dumps({"binary_sha256": recorded or digest}), encoding="utf-8")
    return digest


class KernelPinsTest(unittest.TestCase):
    def test_prints_both_pins_in_build_option_form(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            prefix = Path(directory)
            formal = _stage(prefix, "metacodes-formal-kernel", b"formal")
            project = _stage(prefix, "metacodes-project-kernel", b"project", exe=True)
            self.assertEqual(
                [f"-Dformal-kernel-sha256={formal}", f"-Dproject-kernel-sha256={project}"],
                kernel_pins.pins(prefix),
            )

    def test_refuses_a_missing_kernel(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            prefix = Path(directory)
            _stage(prefix, "metacodes-formal-kernel", b"formal")
            with self.assertRaisesRegex(ValueError, "kernels:stage"):
                kernel_pins.pins(prefix)

    def test_refuses_a_kernel_its_sidecar_does_not_describe(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            prefix = Path(directory)
            _stage(prefix, "metacodes-formal-kernel", b"formal", recorded="0" * 64)
            _stage(prefix, "metacodes-project-kernel", b"project")
            with self.assertRaisesRegex(ValueError, "differs from its sidecar"):
                kernel_pins.pins(prefix)
            self.assertEqual(1, kernel_pins.main(["kernel_pins.py", str(prefix)]))
            self.assertEqual(2, kernel_pins.main(["kernel_pins.py"]))


if __name__ == "__main__":
    unittest.main()
