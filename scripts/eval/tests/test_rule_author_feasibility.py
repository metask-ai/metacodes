import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.eval.run_rule_author_feasibility import child_error_code


REPO = Path(__file__).resolve().parents[3]


def _write_executable(path: Path, source: str) -> None:
    path.write_text(source, encoding="utf-8")
    path.chmod(0o700)


def _auth_file(root: Path) -> Path:
    path = root / "auth.json"
    path.write_text(json.dumps({"api_key": "test-rule-author-key"}), encoding="utf-8")
    path.chmod(0o600)
    return path


def _run(root: Path, binary: Path, *, paid: bool) -> subprocess.CompletedProcess[str]:
    journal = root / "budget" / "journal.json"
    artifacts = root / "artifacts"
    env = dict(os.environ)
    env["METACODES_AUTH_FILE"] = str(root / "auth.json")
    command = [
        sys.executable,
        "-m",
        "scripts.eval.run_rule_author_feasibility",
        "--binary",
        str(binary),
        "--journal",
        str(journal),
        "--artifact-parent",
        str(artifacts),
    ]
    if paid:
        command.append("--execute-paid")
    return subprocess.run(
        command,
        cwd=REPO,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )


def _child_source(journal: Path, result: str) -> str:
    return f"""#!/usr/bin/env python3
import json, os, sys
fd = int(os.environ["METACODES_API_KEY_FD"])
assert os.read(fd, 65536) == b"test-rule-author-key"
with open({str(journal)!r}, "r", encoding="utf-8") as stream:
    document = json.load(stream)
assert document["events"][-1]["action"] == "request_authorized"
assert len(sys.argv) == 3 and len(sys.argv[2]) == 64
print({result!r})
"""


class RuleAuthorFeasibilityRunnerTest(unittest.TestCase):
    def test_structured_child_error_is_bounded_and_strict(self) -> None:
        self.assertEqual(
            child_error_code(
                '{"schema_version":"metacodes-rule-author-feasibility-failure-v1",'
                '"error_code":"InvalidAuthorResponse"}\n'
            ),
            "InvalidAuthorResponse",
        )
        self.assertIsNone(child_error_code("error: InvalidAuthorResponse\n"))
        self.assertIsNone(
            child_error_code(
                '{"schema_version":"metacodes-rule-author-feasibility-failure-v1",'
                '"error_code":"InvalidAuthorResponse","raw":"forbidden"}'
            )
        )

    def test_dry_run_reads_no_credential_and_mutates_no_budget_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "fake-child"
            _write_executable(binary, "#!/bin/sh\nexit 99\n")
            completed = _run(root, binary, paid=False)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertFalse((root / "auth.json").exists())
            self.assertFalse((root / "budget").exists())
            self.assertFalse((root / "artifacts").exists())
            self.assertFalse(json.loads(completed.stdout)["execute_paid"])

    def test_child_observes_durable_authorization_before_commit(self) -> None:
        result = json.dumps(
            {
                "schema_version": "metacodes-rule-author-feasibility-v1",
                "quality_evidence": False,
                "model": "glm-5.2",
                "decision": "abstain",
                "receipt_id": "a" * 64,
                "candidate_id": None,
                "candidate_binding_verified": False,
                "input_tokens": 10,
                "output_tokens": 20,
                "cache_read_input_tokens": 0,
                "cache_creation_input_tokens": 0,
                "metered_tokens": 30,
                "cost_microusd": 42,
                "provider_elapsed_ns": 1,
            },
            separators=(",", ":"),
            sort_keys=True,
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _auth_file(root)
            journal = root / "budget" / "journal.json"
            binary = root / "fake-child"
            _write_executable(binary, _child_source(journal, result))
            completed = _run(root, binary, paid=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            document = json.loads(journal.read_text(encoding="utf-8"))
            self.assertEqual(
                [event["action"] for event in document["events"]],
                ["reserved", "request_authorized", "committed"],
            )
            summary_path = Path(json.loads(completed.stdout)["artifact"])
            self.assertTrue(summary_path.is_file())
            self.assertEqual(stat.S_IMODE(summary_path.stat().st_mode), 0o600)

    def test_malformed_child_result_remains_authorized_and_is_not_retried(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _auth_file(root)
            journal = root / "budget" / "journal.json"
            binary = root / "fake-child"
            _write_executable(binary, _child_source(journal, "{}"))
            completed = _run(root, binary, paid=True)
            self.assertNotEqual(completed.returncode, 0)
            document = json.loads(journal.read_text(encoding="utf-8"))
            self.assertEqual(
                [event["action"] for event in document["events"]],
                ["reserved", "request_authorized"],
            )


if __name__ == "__main__":
    unittest.main()
