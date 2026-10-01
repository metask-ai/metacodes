"""The default install prefix is exactly the release executable and the TinyKG
bundle (#77, B1); `verify_install_prefix.py` is the gate that says so in CI."""
import tempfile
import unittest
from pathlib import Path

from scripts.verify_install_prefix import check, evaluate_daemon, evaluate_doctor, evaluate_kernels

# The doctor always reports both kernels and the daemon; unpinned and absent is
# the development-install shape.
KERNELS_ABSENT = [
    {"name": "formal_kernel", "resolved_path": None, "expected_sha256": None, "match": None, "source": None, "provenance": None},
    {"name": "project_kernel", "resolved_path": None, "expected_sha256": None, "match": None, "source": None, "provenance": None},
    {"name": "tinykgd", "resolved_path": None, "expected_sha256": None, "match": None, "source": None, "provenance": None},
]


RELEASE_FILES = (
    "bin/metacodes", "bin/rg", "share/licenses/ripgrep-LICENSE-MIT", "share/licenses/metacodes-LICENSE",
    "share/licenses/tinykg-LICENSE", "share/licenses/THIRD_PARTY_NOTICES.md", "share/doc/README.md",
    "share/licenses/lean4-LICENSE", "share/licenses/gmp-COPYING.LESSERv3", "share/licenses/gmp-COPYINGv3",
    "share/licenses/gmp-COPYINGv2", "share/licenses/libuv-LICENSE", "share/licenses/libuv-LICENSE-extra",
    "share/doc/CHANGELOG-0.2.0-dev.md", "vendor/tinykg/tinykg", "vendor/tinykg/tinykg.provenance.json",
    "vendor/tinykg/tinykgd", "vendor/tinykg/tinykgd.provenance.json",
    "libexec/metacodes/metacodes-formal-kernel", "libexec/metacodes/metacodes-formal-kernel.provenance.json",
    "libexec/metacodes/metacodes-formal-kernel.build-receipt.json",
    "libexec/metacodes/metacodes-project-kernel", "libexec/metacodes/metacodes-project-kernel.provenance.json",
)


def release_report(root, **overrides):
    """The doctor report of a healthy v2 release prefix; `overrides` maps a
    check name to the fields that differ."""
    shipped = {
        "ripgrep": "bin/rg",
        "tinykg": "vendor/tinykg/tinykg",
        "tinykgd": "vendor/tinykg/tinykgd",
        "formal_kernel": "libexec/metacodes/metacodes-formal-kernel",
        "project_kernel": "libexec/metacodes/metacodes-project-kernel",
    }
    checks = []
    for name, path in shipped.items():
        check = {"name": name, "resolved_path": str(root / path), "sha256": "ab" * 32, "expected_sha256": "ab" * 32,
                 "match": True, "source": "adjacent", "provenance": True if name.endswith("_kernel") else None}
        check.update(overrides.get(name, {}))
        checks.append(check)
    return {"checks": checks}


class VerifyInstallPrefixTest(unittest.TestCase):
    def _make(self, names):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        for name in names:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        return root

    def test_matching_prefix(self):
        root = self._make(("bin/metacodes", "bin/rg", "share/licenses/ripgrep-LICENSE-MIT", "vendor/tinykg/tinykg", "vendor/tinykg/tinykg.provenance.json"))
        self.assertEqual(check(root), [])

    def test_prefix_without_vendored_ripgrep_is_accepted_only_when_asked(self):
        root = self._make(("bin/metacodes", "vendor/tinykg/tinykg", "vendor/tinykg/tinykg.provenance.json"))
        self.assertIn("missing: bin/rg", check(root))
        self.assertIn("missing: share/licenses/ripgrep-LICENSE-MIT", check(root))
        self.assertEqual(check(root, ripgrep=False), [])

    def test_extra_and_missing_are_named(self):
        root = self._make(("bin/metacodes", "bin/rg", "share/licenses/ripgrep-LICENSE-MIT", "vendor/tinykg/tinykg", "extra.txt"))
        findings = check(root)
        self.assertIn("missing: vendor/tinykg/tinykg.provenance.json", findings)
        self.assertIn("unexpected: extra.txt", findings)

    def test_windows_names(self):
        root = self._make(("bin/metacodes.exe", "bin/rg.exe", "share/licenses/ripgrep-LICENSE-MIT", "vendor/tinykg/tinykg.exe", "vendor/tinykg/tinykg.provenance.json"))
        self.assertEqual(check(root), [])

    def test_a_missing_ripgrep_is_named(self):
        root = self._make(("bin/metacodes", "bin/rg", "share/licenses/ripgrep-LICENSE-MIT", "vendor/tinykg/tinykg", "vendor/tinykg/tinykg.provenance.json"))
        self.assertEqual(check(root), [])
        (root / "bin/rg").unlink()
        self.assertIn("missing: bin/rg", check(root))

    def test_doctor_report_accepts_the_adjacent_matching_tinykg(self):
        root = self._make(("bin/metacodes", "bin/rg", "share/licenses/ripgrep-LICENSE-MIT", "vendor/tinykg/tinykg", "vendor/tinykg/tinykg.provenance.json"))
        report = {
            "checks": [
                {"name": "ripgrep", "resolved_path": "/usr/bin/rg", "sha256": "ab", "expected_sha256": None, "match": None, "source": "path"},
                {"name": "tinykg", "resolved_path": str(root / "vendor" / "tinykg" / "tinykg"), "sha256": "cd", "expected_sha256": "cd", "match": True, "source": "adjacent"},
                *KERNELS_ABSENT,
            ]
        }
        self.assertEqual(evaluate_doctor(report, root), [])

    def test_release_doctor_requires_adjacent_ripgrep(self):
        root = self._make(RELEASE_FILES)
        self.assertEqual(evaluate_doctor(release_report(root), root, release=True), [])
        report = release_report(root, ripgrep={"source": "path", "expected_sha256": None, "match": None})
        findings = evaluate_doctor(report, root, release=True)
        self.assertEqual(len(findings), 2)
        self.assertTrue(any("expected 'adjacent'" in finding for finding in findings))
        # Without --release the ripgrep shape passes: a development install
        # resolves rg from PATH first.
        self.assertEqual(evaluate_doctor(report, root), [])

    def test_doctor_report_names_every_deviation(self):
        root = self._make(("bin/metacodes", "bin/rg", "share/licenses/ripgrep-LICENSE-MIT", "vendor/tinykg/tinykg", "vendor/tinykg/tinykg.provenance.json"))
        report = {
            "checks": [
                {"name": "tinykg", "resolved_path": "/elsewhere/tinykg", "sha256": "cd", "expected_sha256": "ef", "match": False, "source": "env"},
            ]
        }
        findings = evaluate_doctor(report, root)
        self.assertEqual(len(findings), 7)
        self.assertTrue(any("no ripgrep check" in finding for finding in findings))
        self.assertTrue(any("no formal_kernel check" in finding for finding in findings))
        self.assertTrue(any("no project_kernel check" in finding for finding in findings))
        self.assertTrue(any("no tinykgd check" in finding for finding in findings))
        self.assertTrue(any("not under" in finding for finding in findings))
        self.assertTrue(any("expected 'adjacent'" in finding for finding in findings))
        self.assertTrue(any("expected true" in finding for finding in findings))
        self.assertEqual(evaluate_doctor({"nope": 1}, root), ["doctor: report has no checks array"])

    def test_release_prefix_carries_licences_docs_kernels_daemon_and_manifest(self):
        root = self._make(RELEASE_FILES)
        self.assertEqual(check(root, release=True), [])
        self.assertIn("unexpected: share/licenses/metacodes-LICENSE", check(root))
        self.assertIn("unexpected: libexec/metacodes/metacodes-project-kernel", check(root))
        (root / "manifest.json").write_text("{}", encoding="utf-8")
        self.assertEqual(check(root, release=True), [])
        (root / "share/doc/CHANGELOG-0.2.0-dev.md").unlink()
        self.assertIn("missing: share/doc/CHANGELOG-<version>.md", check(root, release=True))
        (root / "vendor/tinykg/tinykgd").unlink()
        (root / "libexec/metacodes/metacodes-formal-kernel.build-receipt.json").unlink()
        findings = check(root, release=True)
        self.assertIn("missing: vendor/tinykg/tinykgd", findings)
        self.assertIn("missing: libexec/metacodes/metacodes-formal-kernel.build-receipt.json", findings)

    def test_windows_release_prefix_names_exe_kernels_and_their_sidecars(self):
        renames = {
            "bin/metacodes": "bin/metacodes.exe", "bin/rg": "bin/rg.exe", "vendor/tinykg/tinykg": "vendor/tinykg/tinykg.exe",
            "vendor/tinykg/tinykgd": "vendor/tinykg/tinykgd.exe",
        }
        files = []
        for name in RELEASE_FILES:
            name = renames.get(name, name)
            for stem in ("metacodes-formal-kernel", "metacodes-project-kernel"):
                name = name.replace(f"libexec/metacodes/{stem}", f"libexec/metacodes/{stem}.exe")
            files.append(name)
        root = self._make(files)
        self.assertEqual(check(root, release=True), [])

    def _kernel_report(self, root, **kernel):
        base = [
            {"name": "ripgrep", "resolved_path": str(root / "bin/rg"), "match": True, "source": "adjacent"},
            {"name": "tinykg", "resolved_path": str(root / "vendor/tinykg/tinykg"), "match": True, "source": "adjacent"},
        ]
        entry = {"name": "project_kernel", "resolved_path": None, "sha256": None, "expected_sha256": None, "match": None, "source": None, "provenance": None}
        entry.update(kernel)
        return {"checks": base + [{"name": "formal_kernel", "resolved_path": None, "expected_sha256": None, "provenance": None}, entry, KERNELS_ABSENT[2]]}

    def test_an_unpinned_absent_kernel_is_fine_in_development_only(self):
        root = self._make(("bin/metacodes", "bin/rg", "share/licenses/ripgrep-LICENSE-MIT", "vendor/tinykg/tinykg", "vendor/tinykg/tinykg.provenance.json"))
        self.assertEqual(evaluate_doctor(self._kernel_report(root), root), [])
        findings = evaluate_doctor(self._kernel_report(root, expected_sha256="ab" * 32), root)
        self.assertEqual(len(findings), 1)
        self.assertIn("project_kernel is pinned", findings[0])
        self.assertIn("not shipped", findings[0])
        # A release prefix ships both kernels and the daemon: absent is a finding.
        findings = evaluate_doctor(release_report(root, project_kernel={"resolved_path": None, "expected_sha256": None}, tinykgd={"resolved_path": None, "expected_sha256": None}), root, release=True)
        self.assertEqual(len(findings), 2)
        self.assertTrue(any("ships project_kernel" in finding for finding in findings))
        self.assertTrue(any("ships tinykgd" in finding for finding in findings))
        findings = evaluate_doctor(release_report(root, tinykgd={"expected_sha256": None, "match": None}), root, release=True)
        self.assertTrue(any("does not pin the tinykgd it ships" in finding for finding in findings))

    def test_a_shipped_kernel_needs_a_matching_digest_and_an_accepted_sidecar(self):
        root = self._make(("bin/metacodes", "bin/rg", "share/licenses/ripgrep-LICENSE-MIT", "vendor/tinykg/tinykg", "vendor/tinykg/tinykg.provenance.json", "libexec/metacodes/metacodes-project-kernel"))
        shipped = dict(resolved_path=str(root / "libexec/metacodes/metacodes-project-kernel"), sha256="ab" * 32, expected_sha256="ab" * 32, match=True, source="adjacent", provenance=True)
        self.assertEqual(evaluate_doctor(self._kernel_report(root, **shipped), root), [])
        # The 2026-09-21 failure shape: everything matches, the sidecar was
        # read with the wrong kernel's loader.
        findings = evaluate_doctor(self._kernel_report(root, **dict(shipped, provenance=False)), root)
        self.assertEqual(len(findings), 1)
        self.assertIn("project_kernel provenance is False", findings[0])
        self.assertIn("project_kernel loader", findings[0])
        # Every deviation is named, not just the first.
        findings = evaluate_doctor(self._kernel_report(root, **dict(shipped, resolved_path="/elsewhere/metacodes-project-kernel", source="env", match=False, provenance=None)), root)
        self.assertEqual(len(findings), 4)
        self.assertTrue(any("expected 'adjacent'" in f for f in findings))
        self.assertTrue(any("not under" in f for f in findings))
        self.assertTrue(any("match is False" in f for f in findings))
        self.assertTrue(any("provenance is None" in f for f in findings))

    def test_kernel_evaluation_covers_both_kernels_and_requires_their_presence(self):
        root = self._make(("bin/metacodes",))
        # A report without the kernel checks is not this doctor's report.
        self.assertEqual(evaluate_kernels({}, root), ["doctor: no formal_kernel check", "doctor: no project_kernel check"])
        by_name = {
            "formal_kernel": {"resolved_path": None, "expected_sha256": "cd" * 32},
            "project_kernel": {"resolved_path": None, "expected_sha256": "ef" * 32},
        }
        findings = evaluate_kernels(by_name, root)
        self.assertEqual([f.split(" ")[1] for f in findings], ["formal_kernel", "project_kernel"])

    def test_a_pinned_daemon_must_ship_beside_the_cli(self):
        root = self._make(("bin/metacodes", "vendor/tinykg/tinykg", "vendor/tinykg/tinykgd"))
        self.assertEqual(evaluate_daemon({}, root), ["doctor: no tinykgd check"])
        self.assertEqual(evaluate_daemon({"tinykgd": KERNELS_ABSENT[2]}, root), [])
        pinned_absent = dict(KERNELS_ABSENT[2], expected_sha256="ab" * 32)
        findings = evaluate_daemon({"tinykgd": pinned_absent}, root)
        self.assertEqual(len(findings), 1)
        self.assertIn("tinykgd is pinned", findings[0])
        shipped = {"name": "tinykgd", "resolved_path": str(root / "vendor/tinykg/tinykgd"), "sha256": "ab" * 32, "expected_sha256": "ab" * 32, "match": True, "source": "adjacent", "provenance": None}
        self.assertEqual(evaluate_daemon({"tinykgd": shipped}, root), [])
        findings = evaluate_daemon({"tinykgd": dict(shipped, resolved_path="/elsewhere/tinykgd", source="env", match=False)}, root)
        self.assertEqual(len(findings), 3)
