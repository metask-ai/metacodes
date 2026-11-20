from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LINT = ROOT / "scripts" / "lint.py"

CLEAN_PY = "import os\n\nprint(os.sep)\n"
CLEAN_SH = "#!/usr/bin/env bash\nset -eu\necho \"$1\"\n"
CLEAN_WORKFLOW = """name: ci
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
"""


class LintTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        shutil.copy(ROOT / "ruff.toml", self.root / "ruff.toml")
        (self.root / ".github" / "workflows").mkdir(parents=True)
        shutil.copy(ROOT / ".github" / "actionlint.yaml", self.root / ".github" / "actionlint.yaml")
        self.write("pkg/clean.py", CLEAN_PY)
        self.write("scripts/clean.sh", CLEAN_SH)
        self.write(".github/workflows/ci.yml", CLEAN_WORKFLOW)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def lint(self, requirements=ROOT / "requirements-lint.txt"):
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True)
        return subprocess.run([sys.executable, str(LINT), "--root", str(self.root), "--requirements", str(requirements)],
                              capture_output=True, text=True, check=False)

    def assert_fails_with(self, result, *needles):
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, output)
        for needle in needles:
            self.assertIn(needle, output)

    def test_a_clean_checkout_passes(self):
        result = self.lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for tool in ("ruff", "shellcheck", "actionlint"):
            self.assertIn("==> %s" % tool, result.stdout)

    def test_ruff_fails_an_unused_import(self):
        self.write("pkg/bad.py", "import json\n")
        self.assert_fails_with(self.lint(), "F401", "pkg/bad.py", "ruff failed")

    def test_ruff_fails_two_statements_on_one_line(self):
        self.write("pkg/bad.py", "a = 1; b = 2\n")
        self.assert_fails_with(self.lint(), "E702", "pkg/bad.py")

    def test_shellcheck_fails_a_warning(self):
        self.write("scripts/bad.sh", "#!/bin/sh\ncd /tmp\nls\n")
        self.assert_fails_with(self.lint(), "SC2164", "scripts/bad.sh", "shellcheck failed")

    def test_shellcheck_lints_an_extensionless_script_by_its_shebang(self):
        self.write("bin/tool", "#!/usr/bin/env bash\ncd /tmp\nls\n")
        self.assert_fails_with(self.lint(), "SC2164", "bin/tool")

    def test_shellcheck_ignores_findings_below_warning(self):
        self.write("scripts/info.sh", "#!/bin/sh\nset -- a b\nprintf '%s\\n' $1\n")
        result = self.lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_actionlint_fails_an_invalid_workflow(self):
        self.write(".github/workflows/bad.yml", CLEAN_WORKFLOW.replace("runs-on: ubuntu-latest", "runs-on: ubuntu-latest\n    timeout-minutes: soon"))
        self.assert_fails_with(self.lint(), ".github/workflows/bad.yml", "actionlint failed")

    def test_actionlint_shellchecks_run_scripts_at_warning(self):
        self.write(".github/workflows/bad.yml", CLEAN_WORKFLOW.replace("run: echo ok", "run: unused=1"))
        self.assert_fails_with(self.lint(), "SC2034", "actionlint failed")

    def test_actionlint_ignores_run_script_findings_below_warning(self):
        self.write(".github/workflows/info.yml", CLEAN_WORKFLOW.replace("run: echo ok", "run: echo $HOME"))
        result = self.lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_fixtures_and_untracked_shell_scripts_are_not_linted(self):
        self.write("tests/fixtures/sample.sh", "#!/bin/sh\ncd /tmp\n")
        self.write("tests/e2e/fixtures/repo/x.py", "import json\n")
        result = self.lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_file_pinned_by_sha256_is_skipped_and_listed(self):
        path = self.write("pkg/frozen.py", "import json\n")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        self.write("evals/protocol.json", json.dumps({"pins": {"pkg/frozen.py": digest}}))
        result = self.lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("pkg/frozen.py", result.stdout)
        path.write_text("import json\nimport os\n", encoding="utf-8")
        self.assert_fails_with(self.lint(), "F401", "pkg/frozen.py")

    def test_a_tool_at_another_version_fails_closed(self):
        requirements = self.write("requirements.txt", "ruff==0.0.1\nshellcheck-py==0.11.0.1\nactionlint-py==1.7.12.25\n")
        result = self.lint(requirements)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("ruff==0.0.1", result.stderr)

    def test_a_requirements_file_without_a_tool_pin_fails_closed(self):
        requirements = self.write("requirements.txt", "ruff==0.17.3\n")
        result = self.lint(requirements)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("actionlint-py", result.stderr)

    def test_the_ruff_config_excludes_exactly_the_lint_fixtures(self):
        sys.path.insert(0, str(ROOT / "scripts"))
        try:
            import lint
        finally:
            sys.path.pop(0)
        config = (ROOT / "ruff.toml").read_text(encoding="utf-8")
        for prefix in lint.EXCLUDED_PREFIXES:
            self.assertIn('"%s"' % prefix.rstrip("/"), config)


if __name__ == "__main__":
    unittest.main()
