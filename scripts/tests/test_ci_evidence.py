"""Real merge-tree evidence and fail-closed release reuse of PR CI."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import ci_evidence
import release_fast_path as fp

ROOT = Path(__file__).resolve().parents[2]


class EvidenceWriterTest(unittest.TestCase):
    def test_real_merge_commit_produces_exact_tree_and_rejects_wrong_event_revision(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, text=True, stderr=subprocess.DEVNULL).strip()
            git("init", "-q", "-b", "main")
            git("config", "user.name", "evidence test")
            git("config", "user.email", "test@example.invalid")
            (root / "app").write_text("base")
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            git("switch", "-qc", "feature")
            (root / "app").write_text("changed")
            git("commit", "-qam", "feature")
            head = git("rev-parse", "HEAD")
            git("switch", "-q", "main")
            git("merge", "--no-ff", "-qm", "test merge", "feature")
            event = root / "event.json"
            event.write_text(json.dumps({"pull_request": {"base": {"sha": base}, "head": {"sha": head}}}))
            output = root / "pr-ci-evidence.json"
            env = dict(os.environ, GITHUB_EVENT_NAME="pull_request", GITHUB_EVENT_PATH=str(event),
                       GITHUB_SHA=git("rev-parse", "HEAD"), GITHUB_REPOSITORY="o/r",
                       GITHUB_RUN_ID="17", GITHUB_RUN_ATTEMPT="2")
            # Run the same executable that the workflow runs, not a schema-only check.
            subprocess.run([sys.executable, str(ROOT / "scripts/ci_evidence.py"), "--output", str(output)],
                           cwd=root, env=env, capture_output=True, check=True)
            proof = json.loads(output.read_text())
            self.assertEqual((proof["head"], proof["base"], proof["tree"], proof["run_id"], proof["attempt"]),
                             (head, base, git("rev-parse", "HEAD^{tree}"), 17, 2))
            for change in ({"GITHUB_EVENT_NAME": "push"}, {"GITHUB_SHA": head}):
                with self.assertRaises(ValueError):
                    ci_evidence.write_evidence(root, output, dict(env, **change))
            event.write_text(json.dumps({"pull_request": {"base": {"sha": base}, "head": {"sha": base}}}))
            with self.assertRaises(ValueError):
                ci_evidence.write_evidence(root, output, env)

    def test_main_moved_past_the_merge_base_records_the_base_github_merged_onto(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, text=True, stderr=subprocess.DEVNULL).strip()
            git("init", "-q", "-b", "main")
            git("config", "user.name", "evidence test")
            git("config", "user.email", "test@example.invalid")
            (root / "app").write_text("base")
            git("add", ".")
            git("commit", "-qm", "base")
            merge_base = git("rev-parse", "HEAD")
            git("switch", "-qc", "feature")
            (root / "app").write_text("changed")
            git("commit", "-qam", "feature")
            head = git("rev-parse", "HEAD")
            git("switch", "-q", "main")
            (root / "other").write_text("main moved")
            git("add", ".")
            git("commit", "-qm", "main moved")
            tip = git("rev-parse", "HEAD")
            git("merge", "--no-ff", "-qm", "test merge", "feature")
            event = root / "event.json"
            event.write_text(json.dumps({"pull_request": {"base": {"sha": merge_base}, "head": {"sha": head}}}))
            output = root / "pr-ci-evidence.json"
            env = dict(os.environ, GITHUB_EVENT_NAME="pull_request", GITHUB_EVENT_PATH=str(event),
                       GITHUB_SHA=git("rev-parse", "HEAD"), GITHUB_REPOSITORY="o/r",
                       GITHUB_RUN_ID="17", GITHUB_RUN_ATTEMPT="1")
            ci_evidence.write_evidence(root, output, env)
            proof = json.loads(output.read_text())
            self.assertEqual((proof["head"], proof["base"], proof["tree"]),
                             (head, tip, git("rev-parse", "HEAD^{tree}")))


class EvidenceReaderTest(unittest.TestCase):
    def setUp(self):
        self.pull = {"merged_at": "2026-11-17", "merge_commit_sha": "a" * 40,
                     "base": {"ref": "main", "repo": {"full_name": "o/r"}}, "head": {"sha": "b" * 40}}
        self.run = {"id": 17, "run_attempt": 2, "event": "pull_request", "head_sha": "b" * 40,
                    "status": "completed", "conclusion": "success"}
        self.proof = {"schema": 1, "repository": "o/r", "run_id": 17, "attempt": 2,
                      "head": "b" * 40, "tree": "c" * 40, "scope": "full"}
        self.calls = []

    def query(self, path):
        self.calls.append(path)
        return [self.pull] if "/pulls?" in path else {"workflow_runs": [self.run]}

    def download(self, argv, **kwargs):
        self.assertEqual(argv[:4], ["gh", "run", "download", "17"])
        self.assertEqual(argv[4:8], ["--repo", "o/r", "--name", "pr-ci-evidence"])
        (Path(argv[-1]) / "pr-ci-evidence.json").write_text(json.dumps(self.proof))
        return subprocess.CompletedProcess(argv, 0)

    def state(self):
        with patch.object(fp, "github_json", side_effect=self.query), patch.object(fp.subprocess, "run", side_effect=self.download):
            return fp.base_ci_state("o/r", "a" * 40, "c" * 40)

    def test_reuses_only_the_merged_prs_full_run_for_the_exact_tested_tree(self):
        self.assertEqual(self.state(), "success")
        self.assertIn("event=pull_request", self.calls[1])
        self.assertIn("head_sha=" + "b" * 40, self.calls[1])

    def test_wrong_tree_head_run_attempt_scope_or_repository_cannot_be_reused(self):
        original = copy.deepcopy(self.proof)
        for change in ({"tree": "d" * 40}, {"head": "d" * 40}, {"run_id": 99},
                       {"attempt": 1}, {"scope": "docs"}, {"repository": "other/r"}):
            self.proof = dict(original, **change)
            with self.subTest(change=change):
                self.assertEqual(self.state(), "failure")

    def test_unmerged_or_different_merge_commit_is_not_evidence(self):
        for key, value in (("merged_at", None), ("merge_commit_sha", "d" * 40)):
            original = self.pull[key]
            self.pull[key] = value
            self.assertEqual(self.state(), "failure")
            self.pull[key] = original

    def test_push_success_and_pending_or_failed_pr_runs_are_not_full_evidence(self):
        self.run["event"] = "push"
        self.assertEqual(self.state(), "failure")
        self.run["event"] = "pull_request"
        self.run["status"] = "in_progress"
        self.assertEqual(self.state(), "pending")
        self.run.update(status="completed", conclusion="failure")
        self.assertEqual(self.state(), "failure")

    def test_missing_or_expired_artifact_falls_back_to_full_ci(self):
        with patch.object(fp, "github_json", side_effect=self.query), patch.object(fp.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)):
            self.assertEqual(fp.base_ci_state("o/r", "a" * 40, "c" * 40), "failure")
