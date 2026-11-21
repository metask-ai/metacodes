"""Zero-provider integration evidence: real Git, stdio Codex and GitHub argv."""
from __future__ import annotations

from dataclasses import replace
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github"))

from pr_loop.adapters import Codex, GitHub, run
from pr_loop.controller import Controller, Store
from pr_loop.model import Binding, Busy, DEFAULT_REPO, LoopError, REQUIRED_CHECKS, State, validate_report

ROOT = Path(__file__).resolve().parents[2]


PASS = {"verdict": "pass", "summary": "No blocking findings", "findings": [], "question": ""}
FIX = {"verdict": "fix_required", "summary": "Incorrect result", "findings": [
    {"path": "app.txt", "line": 1, "reason": "The result is incorrect", "acceptance": "The file says fixed"}], "question": ""}

SERVER = r'''
import json, pathlib, sys, time
config, trace = map(pathlib.Path, sys.argv[1:])
def send(x):
    print(json.dumps(x), flush=True)
for line in sys.stdin:
    msg = json.loads(line)
    with trace.open("a") as f:
        f.write(json.dumps(msg) + "\n")
    if "id" not in msg:
        continue
    cfg = json.loads(config.read_text())
    method, params = msg["method"], msg["params"]
    result = {}
    if method == "thread/read":
        result = {"thread": {"cwd": cfg["cwd"], "status": {"type": cfg.get("worker_status", "idle")}}}
    if method == "thread/start":
        result = {"thread": {"id": "review-thread"}}
    if method == "turn/start":
        response = {"id": msg["id"], "result": {"turn": {"id": "turn-1"}}}
        if not cfg.get("early_notifications"):
            send(response)
        if cfg.get("hang"):
            time.sleep(60)
        if cfg.get("approval"):
            send({"id": 999, "method": "item/commandExecution/requestApproval", "params": {}})
            continue
        if "verdict" in params["outputSchema"]["properties"]:
            output = cfg["reports"].pop(0)
        else:
            output = cfg.get("worker_result", {"result": "updated", "summary": "Fixed the result", "question": ""})
            if output["result"] == "updated":
                text = cfg["worker_texts"].pop(0)
                path = pathlib.Path(params["cwd"]) / cfg.get("worker_path", "app.txt")
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
        config.write_text(json.dumps(cfg))
        send({"method": "item/completed", "params": {"item": {"type": "agentMessage", "text": json.dumps(output)}}})
        send({"method": "turn/completed", "params": {"turn": {"id": "turn-1", "status": "completed"}}})
        if cfg.get("early_notifications"):
            send(response)
        continue
    send({"id": msg["id"], "result": result})
'''


def git(cwd, *args):
    return run(["git", *args], cwd=cwd)


def hold_byte_lock(fd):
    if os.name == "nt":
        import msvcrt
        os.lseek(fd, 0, os.SEEK_SET)
        msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
    else:
        import fcntl
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)


def release_byte_lock(fd):
    if os.name == "nt":
        import msvcrt
        os.lseek(fd, 0, os.SEEK_SET)
        msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
    else:
        import fcntl
        fcntl.flock(fd, fcntl.LOCK_UN)


class FixtureGitHub(GitHub):
    """Exercise production snapshot/check/merge encoding, without the network."""
    def __init__(self, bare, base):
        self.bare, self.base = bare, base
        self.calls = []
        self.queued = False
        self.merged = False
        self.strict = True
        self.require_queue = False
        self.race_on_merge = False
        self.check_state = "success"
        self.external_app = False
        self.change_on_snapshot = None
        self.change_target_on_snapshot = None
        self.base_branch = "main"
        self.snapshots = 0

    def api(self, path, method="GET", payload=None):
        self.calls.append((path, method, payload))
        head = git(self.bare, "rev-parse", "refs/heads/feature")
        if path.endswith("/pulls/7"):
            self.snapshots += 1
            if self.snapshots == self.change_on_snapshot:
                self.base = "b" * 40
            if self.snapshots == self.change_target_on_snapshot:
                self.base_branch = "release"
            return {"node_id": "PR_7", "head": {"sha": head, "ref": "feature", "repo": {"full_name": "example/source"}},
                    "base": {"sha": self.base, "ref": self.base_branch}, "title": "Fix app", "body": "Task details",
                    "html_url": f"https://github.com/{DEFAULT_REPO}/pull/7", "state": "open",
                    "merged": self.merged, "draft": False, "mergeable": True, "merge_commit_sha": "a" * 40}
        if path == "graphql":
            return {"data": {"repository": {"pullRequest": {"reviewDecision": None,
                "mergeQueueEntry": {"id": "queue-7"} if self.queued else None,
                "reviewThreads": {"nodes": [], "pageInfo": {"hasNextPage": False}}}}}}
        if path.endswith("/rules/branches/main"):
            rules = [{"type": "required_status_checks", "parameters": {
                "strict_required_status_checks_policy": self.strict,
                "required_status_checks": [{"context": name, "integration_id": 15368} for name in REQUIRED_CHECKS]}}]
            return rules + ([{"type": "merge_queue"}] if self.require_queue else [])
        if path.endswith("/pulls/7/merge"):
            self.assert_merge = payload
            if self.race_on_merge:
                self.base = "b" * 40
                raise LoopError("strict rules rejected stale base")
            if payload != {"sha": head, "merge_method": "merge"}:
                raise AssertionError(payload)
            self.merged = True
            return {"merged": True, "sha": "c" * 40}
        if "/check-runs?" in path:
            return {"check_runs": [{"id": i, "name": name, "app": {"id": 1 if self.external_app else 15368},
                "status": "in_progress" if self.check_state == "pending" else "completed",
                "conclusion": self.check_state, "html_url": "https://github.com/check/1"}
                for i, name in enumerate(REQUIRED_CHECKS)]}
        if "/statuses/" in path:
            return {}
        raise AssertionError((path, method, payload))


class LoopIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.work = self.root / "work"
        self.work.mkdir()
        self.bare = self.root / "remote.git"
        git(self.root, "init", "--bare", "-q", str(self.bare))
        git(self.work, "init", "-q", "-b", "main")
        git(self.work, "config", "user.name", "PR loop test")
        git(self.work, "config", "user.email", "pr-loop@example.invalid")
        # The persisted remote remains a canonical GitHub repository; Git's
        # transport rewrite sends real pushes to this fixture's bare remote.
        git(self.work, "remote", "add", "origin", "git@github.com:example/source.git")
        git(self.work, "config", f"url.{self.bare.as_uri()}.insteadOf", "git@github.com:example/source.git")
        (self.work / "app.txt").write_text("base\n")
        git(self.work, "add", ".")
        git(self.work, "commit", "-qm", "base")
        self.base = git(self.work, "rev-parse", "HEAD")
        git(self.work, "push", "-q", "origin", "main")
        git(self.work, "switch", "-qc", "feature")
        (self.work / "app.txt").write_text("bug\n")
        git(self.work, "commit", "-qam", "task")
        git(self.work, "push", "-q", "origin", "feature")
        self.head = git(self.work, "rev-parse", "HEAD")
        self.server = self.root / "server.py"
        self.server.write_text(SERVER)
        self.config = self.root / "server.json"
        self.trace = self.root / "trace.jsonl"
        self.configure(reports=[FIX, PASS], worker_texts=["fixed\n"])
        self.store = Store(self.root / "state.sqlite3")
        self.addCleanup(self.store.close)
        self.binding = Binding(DEFAULT_REPO, 7, "worker-7", str(self.work.resolve()), "feature", "example/source", timeout=10)
        self.store.bind(self.binding)
        self.github = FixtureGitHub(self.bare, self.base)
        self.codex = Codex((sys.executable, str(self.server), str(self.config), str(self.trace)))
        self.notifications = []
        self.controller = Controller(self.store, self.github, self.codex,
            lambda b, r: self.notifications.append(r),
            gate=(sys.executable, "-c", "from pathlib import Path; import subprocess; "
                  "assert not subprocess.check_output(['git','status','--porcelain']); "
                  "assert Path('app.txt').read_text() == 'fixed\\n'"))

    def configure(self, **fields):
        value = {"cwd": str(self.work.resolve()), "reports": [PASS], "worker_texts": []}
        value.update(fields)
        self.config.write_text(json.dumps(value))

    def row(self):
        return self.store.get(DEFAULT_REPO, 7)

    def requests(self, method):
        messages = [json.loads(s) for s in self.trace.read_text().splitlines()] if self.trace.exists() else []
        return [m for m in messages if m.get("method") == method]

    def test_review_repair_push_rereview_and_exact_head_merge(self):
        self.controller.once()
        fixed = git(self.bare, "rev-parse", "feature")
        self.assertNotEqual(fixed, self.head)
        self.assertEqual(git(self.work, "status", "--porcelain"), "")
        self.assertEqual(self.row()["state"], "pending")
        self.assertEqual(self.requests("thread/resume")[0]["params"]["threadId"], "worker-7")
        worker_turn = self.requests("turn/start")[1]["params"]
        self.assertIn("Incorrect result", worker_turn["input"][0]["text"])
        self.assertEqual(worker_turn["sandboxPolicy"]["type"], "workspaceWrite")
        self.controller.once()
        self.assertEqual(self.row()["state"], "merged")
        merges = [p for path, _, p in self.github.calls if path.endswith("/pulls/7/merge")]
        self.assertEqual(merges, [{"sha": fixed, "merge_method": "merge"}])
        self.assertTrue(any(f"commits/{fixed}/check-runs?" in path for path, _, _ in self.github.calls))
        self.assertFalse(worker_turn["sandboxPolicy"]["networkAccess"])
        self.assertEqual(len(self.requests("thread/start")), 2)  # independent reviewer each revision
        self.github.merged = True
        self.controller.once()
        self.assertEqual(self.row()["state"], "merged")
        self.assertEqual(self.notifications, [])

    def test_failed_local_gate_returns_to_worker_without_notifying(self):
        self.configure(reports=[FIX], worker_texts=["half fixed\n", "fixed\n"])
        self.controller.once()
        self.assertEqual(self.row()["rounds"], 2)
        self.assertEqual(self.row()["agent_runs"], 3)
        self.assertEqual(self.row()["state"], "pending")
        self.assertIn("local_gate_failure", self.requests("turn/start")[2]["params"]["input"][0]["text"])
        self.assertEqual(self.notifications, [])

    def test_pending_checks_reuse_report_and_do_not_merge(self):
        self.configure()
        self.github.check_state = "pending"
        self.controller.once()
        self.controller.once()
        self.assertEqual(self.row()["state"], "waiting")
        self.assertEqual(len(self.requests("turn/start")), 1)
        self.assertFalse(self.github.merged)

    def test_unknown_app_cannot_satisfy_required_ci_checks(self):
        self.configure()
        self.github.external_app = True
        self.controller.once()
        self.assertEqual(self.row()["state"], "waiting")
        self.assertFalse(self.github.queued)

    def test_distinct_push_url_is_checked_before_starting_an_agent(self):
        git(self.work, "config", "remote.origin.pushurl", "git@github.com:other/repository.git")
        self.controller.once()
        self.assertEqual(self.row()["state"], "needs_decision")
        self.assertIn("push remote", self.row()["reason"])
        self.assertEqual(self.requests("turn/start"), [])

    def test_ci_failure_is_returned_to_original_worker(self):
        self.configure(reports=[PASS], worker_texts=["fixed\n"])
        self.github.check_state = "failure"
        self.controller.once()
        self.assertEqual(self.row()["state"], "pending")
        self.assertIn("ci_failures", self.requests("turn/start")[1]["params"]["input"][0]["text"])

    def test_revision_change_discards_completed_review(self):
        self.configure()
        self.github.change_on_snapshot = 2
        self.controller.once()
        self.assertEqual(self.row()["state"], "pending")
        self.assertIsNone(self.row()["report"])
        self.assertFalse(self.github.queued)
        self.assertFalse(any(p.get("state") == "success" for _, _, p in self.github.calls if isinstance(p, dict)))

    def test_retarget_with_identical_shas_cannot_reuse_a_review(self):
        self.configure()
        self.github.change_target_on_snapshot = 2
        self.controller.once()
        self.assertEqual(self.row()["state"], "needs_decision")
        self.assertIn("identity changed", self.row()["reason"])
        self.assertFalse(self.github.queued)

    def test_gate_mutations_are_preserved_and_never_pushed(self):
        self.controller.gate = (sys.executable, "-c", "from pathlib import Path; Path('app.txt').write_text('gate mutation')")
        self.controller.once()
        self.assertEqual(self.row()["state"], "needs_decision")
        self.assertIn("dirty", self.row()["reason"])
        self.assertEqual(git(self.bare, "rev-parse", "feature"), self.head)
        self.assertEqual(len(self.requests("thread/resume")), 1)

    def test_crashed_in_flight_work_is_not_replayed(self):
        self.store.update(self.binding, State.PUSHING)
        self.controller.once()
        self.controller.once()
        self.assertEqual(self.row()["state"], "needs_decision")
        self.assertEqual(len(self.notifications), 1)
        self.assertEqual(self.requests("turn/start"), [])

    def test_worker_busy_does_not_spend_repair_budget(self):
        self.configure(reports=[FIX], worker_status="active")
        self.controller.once()
        self.assertEqual(self.row()["state"], "waiting")
        self.assertEqual(self.row()["rounds"], 0)
        self.assertEqual(self.row()["agent_runs"], 1)

    def test_notifications_before_turn_start_response_are_retained(self):
        self.configure(early_notifications=True)
        self.controller.once()
        self.assertEqual(self.row()["state"], "merged")

    def test_main_update_is_merged_gated_pushed_and_reviewed_again(self):
        self.configure(reports=[PASS])
        self.github.check_state = "pending"
        self.controller.once()
        git(self.work, "switch", "-q", "main")
        (self.work / "upstream.txt").write_text("new main\n")
        git(self.work, "add", ".")
        git(self.work, "commit", "-qm", "advance main")
        self.github.base = git(self.work, "rev-parse", "HEAD")
        git(self.work, "switch", "-q", "feature")
        self.controller.gate = (sys.executable, "-c", "from pathlib import Path; assert Path('upstream.txt').read_text() == 'new main\\n'")
        self.controller.once()
        merged_head = git(self.bare, "rev-parse", "feature")
        self.assertNotEqual(merged_head, self.head)
        self.assertEqual(git(self.work, "merge-base", merged_head, self.github.base), self.github.base)
        self.assertEqual(self.row()["state"], "pending")
        self.assertIsNone(self.row()["report"])
        self.assertEqual(self.requests("thread/resume"), [])
        self.configure(reports=[PASS])
        self.github.check_state = "success"
        self.controller.once()
        self.assertEqual(self.row()["state"], "merged")
        self.assertEqual(self.github.assert_merge["sha"], merged_head)
        self.assertEqual(len(self.requests("thread/start")), 2)

    def test_main_update_conflict_returns_prepared_merge_to_worker(self):
        git(self.work, "switch", "-q", "main")
        (self.work / "app.txt").write_text("upstream changed\n")
        git(self.work, "commit", "-qam", "advance main")
        self.github.base = git(self.work, "rev-parse", "HEAD")
        git(self.work, "switch", "-q", "feature")
        self.configure(worker_texts=["fixed\n"])
        self.controller.once()
        self.assertEqual(self.row()["state"], "pending")
        self.assertIn("merge_conflict", self.requests("turn/start")[0]["params"]["input"][0]["text"])
        self.assertEqual(git(self.work, "merge-base", "HEAD", self.github.base), self.github.base)

    def test_loose_rules_or_old_queue_never_allow_direct_merge(self):
        for field in ("strict", "require_queue"):
            with self.subTest(field=field):
                self.configure()
                self.store.update(self.binding, State.PENDING, report=None)
                self.github.strict = field != "strict"
                self.github.require_queue = field == "require_queue"
                self.controller.once()
                self.assertEqual(self.row()["state"], "needs_decision")
                self.assertFalse(self.github.merged)
                self.assertFalse(any(path.endswith("/pulls/7/merge") for path, _, _ in self.github.calls))

    def test_main_move_during_merge_retries_without_accepting_stale_checks(self):
        self.configure()
        self.github.race_on_merge = True
        self.controller.once()
        self.assertEqual(self.row()["state"], "pending")
        self.assertIsNone(self.row()["report"])
        self.assertFalse(self.github.merged)

    def test_a_watcher_that_finds_an_empty_lock_file_held_is_busy_and_writes_nothing_into_it(self):
        path = self.store.path.with_suffix(".lock")
        path.write_bytes(b"")
        with path.open("a+b") as held:
            hold_byte_lock(held.fileno())
            with self.assertRaises(Busy):
                with self.store.lock():
                    self.fail("acquired a controller lock another watcher holds")
            self.assertEqual(path.stat().st_size, 0)
            release_byte_lock(held.fileno())
        with self.store.lock():
            pass
        self.assertEqual(path.stat().st_size, 0)

    def test_second_watcher_cannot_own_the_same_database(self):
        second = Store(self.store.path)
        try:
            with self.store.lock():
                with self.assertRaises(Busy):
                    with second.lock():
                        self.fail("second watcher acquired the controller lock")
        finally:
            second.close()

    def test_policy_edits_are_preserved_but_never_validated_or_pushed(self):
        self.configure(reports=[FIX], worker_texts=["changed"], worker_path=".github/workflows/ci.yml")
        self.controller.once()
        self.assertEqual(self.row()["state"], "needs_decision")
        self.assertIn("policy", self.row()["reason"])
        self.assertEqual(git(self.bare, "rev-parse", "feature"), self.head)
        self.assertTrue((self.work / ".github/workflows/ci.yml").exists())

    def test_budget_is_durable_and_can_only_be_extended_explicitly(self):
        self.configure(reports=[FIX], worker_texts=["half fixed\n"])
        binding = replace(self.binding, max_rounds=1)
        with self.store.db:
            self.store.db.execute("UPDATE prs SET binding=?", (json.dumps(binding.__dict__),))
        self.controller.once()
        self.assertIn("budget exhausted", self.row()["reason"])
        self.assertEqual(git(self.bare, "rev-parse", "feature"), self.head)
        self.assertEqual(self.row()["checkpoint"], git(self.work, "rev-parse", "HEAD"))
        self.store.answer(DEFAULT_REPO, 7, "Continue with the same acceptance condition", extra_rounds=1)
        cfg = json.loads(self.config.read_text())
        cfg["worker_texts"] = ["fixed\n"]
        self.config.write_text(json.dumps(cfg))
        self.controller.once()
        self.assertEqual(self.row()["rounds"], 2)
        self.assertEqual(self.row()["state"], "pending")
        self.assertIsNone(self.row()["checkpoint"])

    def test_agent_call_budget_stops_before_another_provider_invocation(self):
        binding = replace(self.binding, max_agent_runs=1)
        with self.store.db:
            self.store.db.execute("UPDATE prs SET binding=?", (json.dumps(binding.__dict__),))
        self.controller.once()
        self.assertEqual(self.row()["state"], "needs_decision")
        self.assertIn("agent-run budget exhausted", self.row()["reason"])
        self.assertEqual(len(self.requests("turn/start")), 1)

    def test_approval_request_stops_and_notifies_once(self):
        self.configure(approval=True)
        self.controller.once()
        self.controller.once()
        self.assertEqual(self.row()["state"], "needs_decision")
        self.assertIn("approval", self.row()["reason"])
        self.assertEqual(len(self.notifications), 1)

    def test_timeout_stops_the_child_and_preserves_decision(self):
        self.configure(hang=True)
        with self.store.db:
            binding = replace(self.binding, timeout=1)
            self.store.db.execute("UPDATE prs SET binding=?", (json.dumps(binding.__dict__),))
        self.controller.once()
        self.assertEqual(self.row()["state"], "needs_decision")
        self.assertIn("timeout", self.row()["reason"])

    def test_cannot_bind_same_thread_or_checkout_twice(self):
        with self.assertRaisesRegex(LoopError, "already bound"):
            self.store.bind(replace(self.binding, number=8))
        self.store.bind(self.binding)  # repeated registration is idempotent

    def test_submit_creates_upstream_pr_and_persists_explicit_worker_and_limits(self):
        from pr_loop import __main__ as cli
        capture, shim = self.root / "create.json", self.root / "create.py"
        shim.write_text("import json,sys,pathlib; pathlib.Path(sys.argv[1]).write_text(json.dumps(sys.argv[2:])); print('https://github.com/metask-ai/metacodes/pull/7')")
        self.github.command = (sys.executable, str(shim), str(capture))
        body = self.root / "body.md"
        body.write_text("PR description\n")
        state = self.root / "submitted.sqlite3"
        with patch.object(cli, "GitHub", return_value=self.github):
            code = cli.main(["--state", str(state), "submit", "--thread", "worker-submit",
                "--worktree", str(self.work), "--head", "example:feature", "--title", "fix: result",
                "--body-file", str(body), "--max-rounds", "2", "--max-agent-runs", "7", "--timeout", "45"])
        self.assertEqual(code, 0)
        argv = json.loads(capture.read_text())
        self.assertEqual(argv[:4], ["pr", "create", "--repo", DEFAULT_REPO])
        self.assertEqual(argv[argv.index("--head") + 1], "example:feature")
        submitted = Store(state)
        try:
            binding = json.loads(submitted.get(DEFAULT_REPO, 7)["binding"])
            self.assertEqual((binding["thread"], binding["max_rounds"], binding["max_agent_runs"], binding["timeout"]),
                             ("worker-submit", 2, 7, 45))
        finally:
            submitted.close()


class BoundaryTest(unittest.TestCase):
    def test_github_launcher_can_reconcile_from_another_working_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state = root / "state.sqlite3"
            result = subprocess.run([sys.executable, str(ROOT / ".github/pr-loop.py"),
                                     "--state", str(state), "run", "--once"],
                                    cwd=root, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(state.exists())
            store = Store(state)
            try:
                self.assertEqual(store.rows(), [])
            finally:
                store.close()

    def test_contradictory_review_cannot_pass(self):
        with self.assertRaisesRegex(LoopError, "passing"):
            validate_report(dict(FIX, verdict="pass"))
        with self.assertRaisesRegex(LoopError, "question"):
            validate_report(dict(PASS, verdict="needs_decision"))

    def test_github_uses_json_stdin_and_does_not_interpret_pr_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shim, capture = root / "gh.py", root / "capture.json"
            shim.write_text("import json,sys,pathlib; pathlib.Path(sys.argv[1]).write_text(json.dumps({'argv':sys.argv[2:],'stdin':sys.stdin.read()})); print('{}')")
            gh = GitHub((sys.executable, str(shim), str(capture)))
            text = "literal `touch nope` $(touch nope)\nsecond line"
            gh.api("repos/metask-ai/metacodes/statuses/abc", "POST", {"description": text})
            actual = json.loads(capture.read_text())
            self.assertEqual(json.loads(actual["stdin"])["description"], text)
            self.assertEqual(actual["argv"][-2:], ["--input", "-"])
            self.assertFalse((root / "nope").exists())


if __name__ == "__main__":
    unittest.main()
