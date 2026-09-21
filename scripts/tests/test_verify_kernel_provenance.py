"""`verify_kernel_provenance.py` is the CI step that runs a real kernel sidecar
through the product's own loader (via `doctor`); this proves its judgement."""
import tempfile
import unittest
from pathlib import Path

from scripts.verify_kernel_provenance import KINDS, evaluate, sha256_file


class VerifyKernelProvenanceTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.kernel = Path(directory.name) / "metacodes-project-kernel"
        self.kernel.write_bytes(b"kernel")
        self.digest = sha256_file(self.kernel)
        self.kernels = {"project": (self.kernel, self.digest)}

    def _report(self, **override):
        check = {"name": "project_kernel", "resolved_path": str(self.kernel), "sha256": self.digest, "expected_sha256": self.digest, "match": True, "source": "env", "provenance": True}
        check.update(override)
        return {"checks": [{"name": "ripgrep", "resolved_path": None}, check]}

    def test_an_accepted_sidecar_has_no_findings(self):
        self.assertEqual(evaluate(self._report(), self.kernels), [])

    def test_a_rejected_sidecar_is_named_with_its_loader(self):
        findings = evaluate(self._report(provenance=False), self.kernels)
        self.assertEqual(len(findings), 1)
        self.assertIn("provenance is False", findings[0])
        self.assertIn("rejected by the project_kernel loader", findings[0])

    def test_the_pair_digest_must_be_what_doctor_holds_the_file_to(self):
        findings = evaluate(self._report(expected_sha256=None, match=None), self.kernels)
        self.assertEqual(len(findings), 1)
        self.assertIn("holds the file to None with match=None", findings[0])
        findings = evaluate(self._report(match=False), self.kernels)
        self.assertEqual(len(findings), 1)
        self.assertIn("match=False", findings[0])

    def test_every_deviation_is_named(self):
        findings = evaluate(self._report(resolved_path="/elsewhere/kernel", source="adjacent", sha256="00" * 32, match=False, provenance=None), self.kernels)
        self.assertEqual(len(findings), 5)
        self.assertTrue(any("expected 'env'" in f for f in findings))
        self.assertTrue(any("doctor hashed" in f for f in findings))
        self.assertTrue(any("resolved to" in f for f in findings))
        self.assertTrue(any("provenance is None" in f for f in findings))

    def test_a_missing_check_and_a_malformed_report_are_findings(self):
        self.assertEqual(evaluate({"checks": []}, self.kernels), ["project_kernel: doctor reports no such check"])
        self.assertEqual(evaluate({"nope": 1}, self.kernels), ["doctor: report has no checks array"])

    def test_both_kernels_are_addressable(self):
        self.assertEqual(set(KINDS), {"formal", "project"})
        self.assertEqual(KINDS["formal"][0], "formal_kernel")
