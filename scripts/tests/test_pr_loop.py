"""Zero-provider integration evidence: real Git, stdio Codex and GitHub argv."""
from __future__ import annotations

from dataclasses import replace
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / ".github"))

from pr_loop.adapters import Claude, Codex, Git, GitHub, run
from pr_loop.controller import Controller, Store
from pr_loop.model import (Binding, Busy, DEFAULT_REPO, LoopError, ReadUnavailable, REQUIRED_CHECKS, State,
                           validate_report, validate_worker)
from pr_loop import risk
from pr_loop.timeline import snapshot


NORMAL = {"level": "normal", "reasons": []}
PASS = {"verdict": "pass", "summary": "No blocking findings", "findings": [], "followups": [], "question": "", "risk": NORMAL}
RETRY = {"verdict": "retry", "summary": "Repository tools timed out", "findings": [], "followups": [], "question": "", "risk": NORMAL}
FIX = {"verdict": "fix_required", "summary": "Incorrect result", "findings": [
    {"path": "app.txt", "line": 1, "reason": "The result is incorrect", "acceptance": "The file says fixed"}], "followups": [], "question": "", "risk": NORMAL}

import os
NO_SESSION = {k: v for k, v in os.environ.items() if k not in ("CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID")}
HIGH = {"level": "high", "reasons": ["Deletes persisted sessions without a migration"]}
DISPUTED = {"result": "disputed", "summary": "The finding misreads app.txt", "question": "",
            "rebuttals": [{"finding": 0, "argument": "bug is the specified output for this task"}]}
DECIDE = {"verdict": "needs_decision", "summary": "Scope unclear", "findings": [], "followups": [],
          "question": "Should app.txt keep the old output?", "risk": NORMAL}
LEGACY_FIX = {k: v for k, v in FIX.items() if k not in ("risk", "followups")}
FOLLOWUP = {"path": "lib.txt", "line": 3, "reason": "An existing parser drops CRLF", "acceptance": "CRLF parses"}

# A stand-in for `claude -p`: records argv/stdin, knows which sessions exist,
# answers with the schema the controller asked for, and edits only as a worker.
CLAUDE = r'''
import json, pathlib, sys
config, trace = map(pathlib.Path, sys.argv[1:3])
argv = sys.argv[3:]
prompt = sys.stdin.read()
cfg = json.loads(config.read_text())
with trace.open("a") as f:
    f.write(json.dumps({"argv": argv, "stdin": prompt, "cwd": str(pathlib.Path.cwd().resolve())}) + "\n")
sessions = cfg.setdefault("sessions", ["worker-7"])
def save():
    config.write_text(json.dumps(cfg))
if "--session-id" in argv:
    session = argv[argv.index("--session-id") + 1]
    if cfg.get("fail_launch"):
        cfg["fail_launch"] -= 1
        save()
        print("launch failed before the session existed", file=sys.stderr)
        sys.exit(2)
    sessions.append(session)
else:
    session = argv[argv.index("--resume") + 1]
    if session not in sessions:
        save()
        print(f"No conversation found with session ID: {session}", file=sys.stderr)
        sys.exit(1)
schema = json.loads(argv[argv.index("--json-schema") + 1])
if "verdict" in schema["properties"]:
    output = cfg["claude_reports"].pop(0)
else:
    output = {"result": "updated", "summary": "Claude fixed it", "question": "", "rebuttals": []}
    pathlib.Path("app.txt").write_text(cfg["worker_texts"].pop(0))
save()
print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "session_id": session,
                  "structured_output": output}))
'''

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
    if method == "thread/fork":
        result = {"thread": {"id": "repair-7", "cwd": cfg["cwd"]}}
    if method == "turn/start":
        response = {"id": msg["id"], "result": {"turn": {"id": "turn-1"}}}
        if not cfg.get("early_notifications"):
            send(response)
        if cfg.get("hang"):
            time.sleep(60)
        if cfg.get("drop_worker") and "verdict" not in params["outputSchema"]["properties"]:
            (pathlib.Path(params['cwd']) / 'app.txt').write_text('partial worker edit\n')
            sys.exit(1)
        if cfg.get("approval"):
            send({"id": 999, "method": "item/commandExecution/requestApproval", "params": {}})
            continue
        if "verdict" in params["outputSchema"]["properties"]:
            output = cfg["reports"].pop(0)
        else:
            output = cfg.get("worker_result", {"result": "updated", "summary": "Fixed the result", "question": "", "rebuttals": []})
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
        self.read_unavailable = False
        self.reviews, self.comments, self.posted, self.requested, self.created = [], [], [], [], []
        self.roles = {}
        self.forks = {"example/source": DEFAULT_REPO}

    def api(self, path, method="GET", payload=None):
        self.calls.append((path, method, payload))
        head = git(self.bare, "rev-parse", "refs/heads/feature")
        if path.endswith("/pulls/7"):
            if self.read_unavailable:
                raise ReadUnavailable('GitHub read: Bad Gateway')
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
        if path == f"repos/{DEFAULT_REPO}/pulls" and method == "POST":
            self.created.append(payload)
            return {"html_url": f"https://github.com/{DEFAULT_REPO}/pull/7"}
        if path.startswith("repos/") and path.count("/") == 2 and method == "GET":
            name = path.removeprefix("repos/")
            return {"fork": name in self.forks, "source": {"full_name": self.forks.get(name, name)}}
        if "/pulls/7/reviews?" in path:
            return self.reviews
        if "/issues/7/comments" in path:
            if method == "POST":
                self.posted.append(payload["body"])
                return {}
            return self.comments
        if "/collaborators/" in path:
            login = path.split("/collaborators/")[1].split("/")[0]
            if login not in self.roles:
                raise LoopError("gh exited 1: HTTP 404 Not Found")
            return {"role_name": self.roles[login]}
        if path.endswith("/pulls/7/requested_reviewers"):
            self.requested.append(payload)
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
        self.assertEqual(self.requests("thread/fork")[0]["params"]["threadId"], "worker-7")
        self.assertEqual(self.requests("thread/resume"), [])
        self.assertEqual(self.row()["worker_thread"], "repair-7")
        worker_turn = self.requests("turn/start")[1]["params"]
        self.assertEqual(worker_turn["threadId"], "repair-7")
        self.assertIn("Incorrect result", worker_turn["input"][0]["text"])
        self.assertEqual(worker_turn["sandboxPolicy"]["type"], "workspaceWrite")
        self.controller.once()
        self.assertEqual(self.row()["state"], "merged")
        merges = [p for path, _, p in self.github.calls if path.endswith("/pulls/7/merge")]
        self.assertEqual(merges, [{"sha": fixed, "merge_method": "merge"}])
        self.assertTrue(any(f"commits/{fixed}/check-runs?" in path for path, _, _ in self.github.calls))
        self.assertFalse(worker_turn["sandboxPolicy"]["networkAccess"])
        self.assertEqual(len(self.requests("thread/start")), 2)  # independent reviewer each revision
        self.assertTrue(all(r['params']['ephemeral'] is False for r in self.requests('thread/start')))
        self.assertTrue(all(r['params']['sandbox'] == 'read-only' for r in self.requests('thread/start')))
        self.github.merged = True
        self.controller.once()
        self.assertEqual(self.row()["state"], "merged")
        self.assertEqual(self.notifications, [])
        self.assertFalse(any('/statuses/' in path for path, _, _ in self.github.calls))
        view = snapshot(self.store, DEFAULT_REPO, 7, 0)
        events = view["events"]
        reports = [e["detail"]["report"] for e in events if e["detail"].get("report")]
        self.assertEqual(reports, [FIX, PASS])
        self.assertEqual([e["detail"]["summary"] for e in events if e["state"] == "repair_finished"],
                         ["Fixed the result"])
        gate = next(e for e in events if e["state"] == "validation_passed")
        self.assertTrue(Path(gate["detail"]["log"]).is_file())
        self.assertEqual(gate["detail"]["checkpoint"], fixed)
        for kind in ("pushed", "ci_result", "merged"):
            self.assertEqual(sum(e["state"] == kind for e in events), 1)
        self.assertEqual(snapshot(self.store, DEFAULT_REPO, 7, view["cursor"])["events"], [])

    def test_unavailable_review_automatically_retries_then_repairs_without_status_gate(self):
        self.configure(reports=[RETRY, FIX, PASS], worker_texts=['fixed\n'])
        self.controller.once()
        self.assertEqual(self.row()['state'], 'pending')
        self.assertIsNone(self.row()['report'])
        self.assertEqual((self.row()['agent_runs'], self.row()['rounds']), (1, 0))
        self.assertEqual(self.notifications, [])
        self.assertEqual(git(self.bare, 'rev-parse', 'feature'), self.head)
        self.controller.once()
        fixed = git(self.bare, 'rev-parse', 'feature')
        self.assertNotEqual(fixed, self.head)
        self.controller.once()
        self.assertEqual(self.row()['state'], 'merged')
        self.assertEqual((self.row()['agent_runs'], self.row()['rounds']), (4, 1))
        self.assertEqual(self.notifications, [])
        self.assertFalse(any('/statuses/' in path for path, _, _ in self.github.calls))

    def test_interrupted_readonly_review_recovers_without_resetting_count(self):
        self.store.update(self.binding, State.REVIEWING, agent_runs=1)
        self.controller.once()
        self.assertEqual(self.row()['state'], 'pending')
        self.assertEqual(self.row()['agent_runs'], 1)
        self.assertEqual(self.requests('turn/start'), [])
        self.configure()
        self.controller.once()
        self.assertEqual(self.row()['state'], 'merged')
        self.assertEqual(self.row()['agent_runs'], 2)
        self.assertEqual(self.notifications, [])

    def test_review_retries_continue_past_old_call_cap(self):
        self.store.update(self.binding, agent_runs=16)
        self.configure(reports=[RETRY, RETRY, PASS])
        self.controller.once()
        self.assertEqual(self.row()['state'], 'pending')
        self.controller.once()
        self.assertEqual(self.row()['state'], 'pending')
        self.controller.once()
        self.assertEqual(self.row()['state'], 'merged')
        self.assertEqual(self.row()['agent_runs'], 19)
        self.assertEqual(len(self.requests('turn/start')), 3)
        self.assertEqual(self.notifications, [])

    def test_worker_transport_failure_preserves_candidate_and_stops_for_reconciliation(self):
        self.configure(reports=[FIX], drop_worker=True)
        self.controller.once()
        self.assertEqual(self.row()['state'], 'needs_decision')
        self.assertEqual(git(self.bare, 'rev-parse', 'feature'), self.head)
        self.assertEqual((self.work / 'app.txt').read_text(), 'partial worker edit\n')
        self.assertIn('app-server ended', self.row()['reason'])

    def test_failed_local_gate_returns_to_worker_without_notifying(self):
        self.configure(reports=[FIX], worker_texts=["half fixed\n", "fixed\n"])
        self.controller.once()
        self.assertEqual(self.row()["rounds"], 2)
        self.assertEqual(self.row()["agent_runs"], 3)
        self.assertEqual(self.row()["state"], "pending")
        self.assertIn("local_gate_failure", self.requests("turn/start")[2]["params"]["input"][0]["text"])
        self.assertEqual(self.notifications, [])
        self.assertEqual(len(self.requests("thread/fork")), 1)
        self.assertEqual([r["params"]["threadId"] for r in self.requests("thread/resume")], ["repair-7"])

    def test_pending_checks_reuse_report_and_do_not_merge(self):
        self.configure()
        self.github.check_state = "pending"
        self.controller.once()
        self.controller.once()
        self.assertEqual(self.row()["state"], "waiting")
        self.assertEqual(len(self.requests("turn/start")), 1)
        self.assertFalse(self.github.merged)

    def test_github_read_outage_recovers_without_spending_an_agent_invocation(self):
        self.configure()
        self.github.read_unavailable = True
        self.controller.once()
        self.assertEqual(self.row()['state'], 'waiting')
        self.assertEqual(self.row()['agent_runs'], 0)
        self.assertEqual(self.notifications, [])
        self.github.read_unavailable = False
        self.controller.once()
        self.assertEqual(self.row()['state'], 'merged')

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
        self.assertEqual(len(self.requests("thread/fork")), 1)

    def test_crashed_in_flight_work_is_not_replayed(self):
        self.store.update(self.binding, State.PUSHING)
        self.controller.once()
        self.controller.once()
        self.assertEqual(self.row()["state"], "needs_decision")
        self.assertEqual(len(self.notifications), 1)
        self.assertEqual(self.requests("turn/start"), [])

    def test_worker_busy_does_not_count_an_unstarted_repair(self):
        self.configure(reports=[FIX], worker_status="active")
        self.store.update(self.binding, worker_thread="repair-7")
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

    def test_legacy_capped_registration_resumes_checkpoint_and_keeps_evidence(self):
        (self.work / 'app.txt').write_text('half fixed\n')
        git(self.work, 'commit', '-qam', 'preserved local checkpoint')
        checkpoint = git(self.work, 'rev-parse', 'HEAD')
        self.store.update(self.binding, State.DECISION, head=self.head, base=self.base,
                          checkpoint=checkpoint, report=json.dumps(LEGACY_FIX), agent_runs=16,
                          rounds=5, reason='agent-run budget exhausted (16)')
        legacy = dict(self.binding.__dict__, max_rounds=5, max_agent_runs=16)
        with self.store.db:
            self.store.db.execute('UPDATE prs SET binding=?', (json.dumps(legacy),))
        self.configure(reports=[PASS], worker_texts=['fixed\n'])
        restarted = Store(self.store.path)
        try:
            restarted.bind(self.binding)  # old count caps do not change worker identity
            restarted.answer(DEFAULT_REPO, 7, 'Remove fixed call and repair-round caps')
            self.assertEqual(json.loads(self.row()['report']), LEGACY_FIX)
            self.assertEqual(self.row()['checkpoint'], checkpoint)
            self.assertEqual((self.row()['agent_runs'], self.row()['rounds']), (16, 5))
            self.assertNotIn('max_agent_runs', json.loads(self.row()['binding']))
            self.assertNotIn('max_rounds', json.loads(self.row()['binding']))
            controller = Controller(restarted, self.github, self.codex,
                lambda b, r: self.notifications.append(r), gate=self.controller.gate)
            controller.once()
            fixed = git(self.bare, 'rev-parse', 'feature')
            self.assertNotEqual(fixed, self.head)
            self.assertEqual(self.row()['rounds'], 6)
            self.assertIsNone(self.row()['checkpoint'])
            self.assertEqual(git(self.work, 'status', '--porcelain'), '')
            controller.once()
            self.assertEqual(self.row()['state'], 'merged')
            self.assertEqual(self.row()['agent_runs'], 18)
            self.assertEqual(len(self.requests('turn/start')), 2)  # saved finding -> repair -> fresh review
            self.assertEqual(self.github.assert_merge, {'sha': fixed, 'merge_method': 'merge'})
            self.assertEqual(self.notifications, [])
        finally:
            restarted.close()

    def test_review_and_repair_continue_past_both_old_caps(self):
        self.store.update(self.binding, agent_runs=16, rounds=5)
        self.controller.once()
        fixed = git(self.bare, 'rev-parse', 'feature')
        self.assertNotEqual(fixed, self.head)
        self.assertEqual((self.row()['agent_runs'], self.row()['rounds']), (18, 6))
        self.controller.once()
        self.assertEqual(self.row()['state'], 'merged')
        self.assertEqual(self.row()['agent_runs'], 19)
        self.assertEqual(self.notifications, [])

    def test_approval_request_stops_and_notifies_once(self):
        self.configure(approval=True)
        self.controller.once()
        self.controller.once()
        self.assertEqual(self.row()["state"], "needs_decision")
        self.assertIn("approval", self.row()["reason"])
        self.assertEqual(len(self.notifications), 1)

    def test_readonly_timeout_stops_child_and_retries_full_review(self):
        self.configure(hang=True)
        with self.store.db:
            binding = replace(self.binding, timeout=1)
            self.store.db.execute("UPDATE prs SET binding=?", (json.dumps(binding.__dict__),))
        self.controller.once()
        self.assertEqual(self.row()["state"], "pending")
        self.assertIn("timeout", self.row()["reason"])
        self.assertEqual(self.row()['agent_runs'], 1)
        self.assertEqual(self.notifications, [])
        self.configure()
        self.controller.once()
        self.assertEqual(self.row()['state'], 'merged')

    def test_cannot_bind_same_thread_or_checkout_twice(self):
        with self.assertRaisesRegex(LoopError, "already bound"):
            self.store.bind(replace(self.binding, number=8))
        self.store.bind(self.binding)  # repeated registration is idempotent

    def test_submit_creates_upstream_pr_with_worker_and_timeout_without_count_caps(self):
        from pr_loop import __main__ as cli
        body = self.root / "body.md"
        body.write_text("PR description\n")
        state = self.root / "submitted.sqlite3"
        with patch.object(cli, "GitHub", return_value=self.github), patch.dict("os.environ", NO_SESSION, clear=True):
            code = cli.main(["--state", str(state), "submit", "--thread", "worker-submit",
                "--worktree", str(self.work), "--head", "example:feature", "--title", "fix: result",
                "--body-file", str(body), "--timeout", "45"])
        self.assertEqual(code, 0)
        self.assertEqual(self.github.created[0]["head"], "example:feature")
        self.assertEqual(self.github.created[0]["head_repo"], "example/source")
        submitted = Store(state)
        try:
            binding = json.loads(submitted.get(DEFAULT_REPO, 7)["binding"])
            self.assertEqual((binding['thread'], binding['timeout']), ('worker-submit', 45))
            self.assertFalse(binding['attended'])  # no live session ran it
            self.assertNotIn('max_rounds', binding)
            self.assertNotIn('max_agent_runs', binding)
        finally:
            submitted.close()

    def commit_feature(self, path, text):
        target = self.work / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        git(self.work, "add", path)
        git(self.work, "commit", "-qm", "touch " + path)
        git(self.work, "push", "-q", "origin", "feature")
        return git(self.work, "rev-parse", "HEAD")

    def rebind(self, **fields):
        self.binding = replace(self.binding, **fields)
        with self.store.db:
            self.store.db.execute("UPDATE prs SET binding=?", (json.dumps(self.binding.__dict__),))

    def test_core_path_waits_for_exact_head_human_approval_then_merges(self):
        head = self.commit_feature("src/core/agent_loop.zig", "// changed\n")
        self.configure(reports=[PASS])
        self.controller.human_reviewers = ("wayfind",)
        self.controller.once()
        self.assertEqual(self.row()["state"], "needs_human")
        self.assertIn("core runtime", self.row()["reason"])
        self.assertFalse(self.github.merged)
        self.assertEqual(len(self.notifications), 1)
        self.assertIn(head[:12], self.notifications[0])
        self.assertEqual(len(self.github.posted), 1)  # the gate notice is posted even without mirroring
        self.assertIn(f"/approve {head}", self.github.posted[0])
        self.assertEqual(self.github.requested, [{"reviewers": ["wayfind"]}])
        self.controller.once()  # polling neither re-reviews nor re-notifies
        self.assertEqual(len(self.requests("turn/start")), 1)
        self.assertEqual((len(self.notifications), len(self.github.posted)), (1, 1))
        with self.assertRaisesRegex(LoopError, "current PR head"):
            self.store.approve(DEFAULT_REPO, 7, self.head[:12], "dev")
        self.store.approve(DEFAULT_REPO, 7, head[:12], "dev")
        self.controller.once()
        self.assertEqual(self.row()["state"], "merged")
        events = snapshot(self.store, DEFAULT_REPO, 7, 0)["events"]
        approved = [e["detail"] for e in events if e["state"] == "human_approved"]
        self.assertEqual(approved, [{"head": head, "source": "local", "by": "dev", "url": ""}])

    def test_approval_comment_must_name_the_full_current_head(self):
        self.configure(reports=[dict(PASS, risk=HIGH)])
        self.github.roles = {"dev": "maintain", "outsider": "write"}
        self.github.comments = [
            {"user": {"login": "outsider"}, "body": f"/approve {self.head}"},   # not a maintainer
            {"user": {"login": "dev"}, "body": f"/approve {self.head[:12]}"},   # an abbreviation could drift
            {"user": {"login": "dev"}, "body": "/approve " + "0" * 40},         # another revision
            {"user": {"login": "stranger"}, "body": f"/approve {self.head}"},   # not a collaborator
        ]
        self.controller.once()
        self.assertEqual(self.row()["state"], "needs_human")
        self.assertIn("reviewer: Deletes persisted sessions", self.row()["reason"])
        self.github.comments.append({"user": {"login": "dev"}, "body": f" /approve {self.head} ",
                                     "html_url": "https://github.com/c/1"})
        self.controller.once()
        self.assertEqual(self.row()["state"], "merged")

    def test_github_review_approves_only_the_commit_it_reviewed(self):
        head = self.commit_feature("vendor/tinykg/bin/manifest.json", "{}\n")
        self.configure(reports=[PASS])
        self.github.roles = {"wayfind": "write"}
        self.github.reviews = [{"state": "APPROVED", "commit_id": self.head, "user": {"login": "wayfind"}}]
        self.controller.once()
        self.assertEqual(self.row()["state"], "needs_human")
        self.github.reviews.append({"state": "APPROVED", "commit_id": head, "user": {"login": "wayfind"}})
        self.controller.once()
        self.assertEqual(self.row()["state"], "merged")

    def test_script_a_base_workflow_runs_needs_a_human(self):
        git(self.work, "switch", "-q", "main")
        (self.work / ".github/workflows").mkdir(parents=True)
        (self.work / ".github/workflows/ci.yml").write_text("steps:\n  - run: python3 scripts/ci_scope.py --pr\n")
        git(self.work, "add", ".")
        git(self.work, "commit", "-qm", "workflow")
        git(self.work, "push", "-q", "origin", "main")
        self.github.base = git(self.work, "rev-parse", "HEAD")
        git(self.work, "switch", "-q", "feature")
        git(self.work, "merge", "-q", "--no-edit", "main")
        self.commit_feature("scripts/ci_scope.py", "SKIP_EVERYTHING = True\n")
        self.configure(reports=[PASS])
        self.controller.once()
        self.assertEqual(self.row()["state"], "needs_human")
        self.assertIn("CI entry point run by a workflow: scripts/ci_scope.py", self.row()["reason"])

    def test_normal_risk_merges_without_human_or_notice(self):
        self.commit_feature("src/repl/hint.zig", "// ok\n")
        self.configure(reports=[PASS])
        self.controller.once()
        self.assertEqual(self.row()["state"], "merged")
        self.assertEqual((self.notifications, self.github.posted), ([], []))

    def test_private_decisions_never_leave_the_machine(self):
        self.rebind(mirror=True)
        marker = "INCIDENT-4471 customer data was exposed"
        echo = dict(PASS, summary=f"Per the developer: {marker}.", risk=dict(HIGH, reasons=[marker]))
        self.configure(reports=[DECIDE, echo])
        self.controller.once()
        self.assertEqual(self.row()["state"], "needs_decision")
        self.store.answer(DEFAULT_REPO, 7, marker)
        self.controller.once()
        self.assertEqual(self.row()["state"], "needs_human")
        outbound = json.dumps([p for _, m, p in self.github.calls if m == "POST"])
        self.assertNotIn("INCIDENT-4471", outbound)
        self.assertIn("[private decision]", outbound)
        self.assertIn(marker, self.row()["report"])  # local evidence keeps it

    def test_mirror_posts_the_whole_conversation_to_the_pr(self):
        self.rebind(mirror=True)
        self.configure(reports=[FIX, dict(PASS, followups=[FOLLOWUP])], worker_texts=["fixed\n"])
        self.controller.once()
        self.controller.once()
        self.assertEqual(self.row()["state"], "merged")
        fixed = git(self.bare, "rev-parse", "feature")
        posted = self.github.posted
        self.assertIn("**fix_required**", posted[0])
        self.assertIn("`app.txt:1`: The result is incorrect", posted[0])
        self.assertIn("repair round 1 (codex, unattended fork): **updated**", posted[1])
        self.assertIn(f"Pushed `{fixed}`", posted[1])
        self.assertIn("**pass**", posted[2])
        self.assertIn("Follow-ups", posted[2])
        followups = [e for e in snapshot(self.store, DEFAULT_REPO, 7, 0)["events"] if e["state"] == "followups"]
        self.assertEqual(followups[0]["detail"]["followups"], [FOLLOWUP])

    def test_worker_rebuttal_goes_to_a_fresh_review_without_a_push(self):
        self.configure(reports=[FIX, PASS], worker_result=DISPUTED)
        self.controller.once()
        self.assertEqual(self.row()["state"], "pending")
        self.assertEqual(git(self.bare, "rev-parse", "feature"), self.head)  # nothing validated or pushed
        self.assertEqual(self.row()["disputes"], 1)
        self.controller.once()
        second_review = self.requests("turn/start")[2]["params"]["input"][0]["text"]
        self.assertIn("bug is the specified output for this task", second_review)
        self.assertIn("Rule on each rebuttal", second_review)
        self.assertEqual(self.row()["state"], "merged")
        self.assertEqual((self.row()["dispute"], self.row()["disputes"]), (None, 0))
        self.assertEqual(self.notifications, [])

    def test_answered_dispute_goes_to_a_fresh_reviewer_with_the_ruling(self):
        self.configure(reports=[FIX, FIX, FIX, PASS], worker_result=DISPUTED)
        for _ in range(3):
            self.controller.once()
        self.assertEqual(self.row()["state"], "needs_decision")
        self.assertIn("still disagree", self.notifications[-1])
        self.assertEqual(git(self.bare, "rev-parse", "feature"), self.head)
        workers = len(self.requests("thread/fork")) + len(self.requests("thread/resume"))
        self.store.answer(DEFAULT_REPO, 7, "Keep the current output; the worker is right.")
        self.controller.once()
        self.assertEqual(self.row()["state"], "merged")
        self.assertEqual(len(self.requests("thread/fork")) + len(self.requests("thread/resume")), workers)
        last_review = self.requests("turn/start")[-1]["params"]["input"][0]["text"]
        self.assertIn("Keep the current output", last_review)
        self.assertIn("bug is the specified output", last_review)

    def test_missing_reviewer_executable_retries_without_a_decision(self):
        self.controller.agents["codex"] = Codex(("/nonexistent/codex", "app-server"))
        self.controller.once()
        self.assertEqual(self.row()["state"], "pending")
        self.assertIn("retrying full review", self.row()["reason"])
        self.assertEqual(self.notifications, [])
        self.controller.agents["codex"] = self.codex
        self.configure(reports=[PASS])
        self.controller.once()
        self.assertEqual(self.row()["state"], "merged")

    def test_report_from_before_risk_classification_is_reviewed_again(self):
        legacy = {k: v for k, v in PASS.items() if k not in ("risk", "followups")}
        self.store.update(self.binding, State.WAITING, head=self.head, base=self.base, report=json.dumps(legacy))
        self.configure(reports=[PASS])
        self.controller.once()
        self.assertEqual(len(self.requests("turn/start")), 1)
        self.assertEqual(self.row()["state"], "merged")

    # ---- attended: the developer's own session is the worker ----------------------

    def test_attended_feedback_waits_for_the_session_then_validates_and_pushes(self):
        from pr_loop import __main__ as cli
        self.rebind(attended=True, mirror=True)
        self.configure(reports=[FIX, PASS])
        self.controller.once()
        self.assertEqual(self.row()["state"], "awaiting_session")
        self.assertEqual((self.requests("thread/fork"), self.requests("thread/resume")), ([], []))
        self.assertIn("waiting in your session", self.notifications[-1])
        shown = cli.render_feedback(self.row(), 7)
        self.assertIn("[0] app.txt:1", shown)
        self.controller.once()  # still waiting: nothing else happens
        self.assertEqual(self.row()["state"], "awaiting_session")
        (self.work / "app.txt").write_text("fixed\n")  # the live session edits in front of the developer
        with self.assertRaisesRegex(LoopError, "existing finding"):
            self.store.set_reply(DEFAULT_REPO, 7, dict(DISPUTED, rebuttals=[{"finding": 4, "argument": "x"}]))
        state = str(self.store.path)
        self.assertEqual(cli.main(["--state", state, "reply", "--pr", "7", "--result", "updated",
                                   "--summary", "Wrote the fixed output"]), 0)
        self.controller.once()
        fixed = git(self.bare, "rev-parse", "feature")
        self.assertNotEqual(fixed, self.head)
        self.assertIn("repair round 1 (codex, your session): **updated**", self.github.posted[1])
        self.controller.once()
        self.assertEqual(self.row()["state"], "merged")
        lines = [cli.inbox_line(e, 7) for e in snapshot(self.store, DEFAULT_REPO, 7, 0)["events"]]
        self.assertTrue(any("feedback waiting for your session" in l for l in lines))
        self.assertTrue(any("repair updated: Wrote the fixed output" in l for l in lines))

    def test_attended_gate_failure_returns_to_the_session(self):
        self.rebind(attended=True)
        self.configure(reports=[FIX, PASS])
        self.controller.once()
        (self.work / "app.txt").write_text("almost\n")
        self.store.set_reply(DEFAULT_REPO, 7, {"result": "updated", "summary": "try", "question": "", "rebuttals": []})
        self.controller.once()
        self.assertEqual(self.row()["state"], "awaiting_session")
        self.assertIn("local_gate_failure", self.row()["feedback"])
        self.assertEqual(git(self.bare, "rev-parse", "feature"), self.head)  # the failed checkpoint stays local
        (self.work / "app.txt").write_text("fixed\n")
        self.store.set_reply(DEFAULT_REPO, 7, {"result": "updated", "summary": "fixed", "question": "", "rebuttals": []})
        self.controller.once()
        self.controller.once()
        self.assertEqual(self.row()["state"], "merged")

    def test_attended_session_survives_a_moved_main(self):
        self.rebind(attended=True)
        self.configure(reports=[FIX, PASS])
        self.controller.once()
        (self.work / "app.txt").write_text("fixed\n")  # editing in progress
        self.github.base = "b" * 40  # main moved meanwhile
        self.controller.once()
        self.assertEqual(self.row()["state"], "awaiting_session")
        self.assertEqual(self.notifications[-1].count("decision"), 0)

    def test_silent_session_falls_back_to_an_unattended_fork(self):
        self.rebind(attended=True, attended_timeout=60)
        self.configure(reports=[FIX, PASS], worker_texts=["fixed\n"])
        self.controller.once()
        with self.store.db:
            self.store.db.execute("UPDATE events SET at=at-120 WHERE state='awaiting_session'")
        self.controller.once()
        self.assertEqual(self.requests("thread/fork")[0]["params"]["threadId"], "worker-7")
        self.assertNotEqual(git(self.bare, "rev-parse", "feature"), self.head)
        events = [e["state"] for e in snapshot(self.store, DEFAULT_REPO, 7, 0)["events"]]
        self.assertIn("attended_timeout", events)

    def test_only_the_source_session_can_attach(self):
        with self.assertRaisesRegex(LoopError, "source session"):
            self.store.attach(DEFAULT_REPO, 7, "someone-else", True)
        binding = self.store.attach(DEFAULT_REPO, 7, "worker-7", True, mirror=True)
        self.assertTrue(binding.attended and binding.mirror)
        self.assertFalse(self.store.attach(DEFAULT_REPO, 7, None, False).attended)

    # ---- Claude Code ------------------------------------------------------------------

    def claude_controller(self, reviewer):
        fake, ctrace = self.root / "claude.py", self.root / "claude.jsonl"
        fake.write_text(CLAUDE)
        claude = Claude((sys.executable, str(fake), str(self.config), str(ctrace)))
        self.rebind(agent="claude", reviewer=reviewer)
        self.controller.agents["claude"] = claude
        return ctrace

    def claude_calls(self, ctrace):
        return [json.loads(line) for line in ctrace.read_text().splitlines()]

    def test_claude_session_forks_once_then_resumes_and_codex_reviews(self):
        ctrace = self.claude_controller("codex")
        self.configure(reports=[FIX, PASS], worker_texts=["still bug\n", "fixed\n"])
        self.controller.once()   # the first repair fails the gate, so the same worker repairs again
        calls = self.claude_calls(ctrace)
        reserved = self.row()["worker_thread"]
        # The reserved ID is tried first; it does not exist yet, so the fork creates it.
        self.assertEqual(calls[0]["argv"][calls[0]["argv"].index("--resume") + 1], reserved)
        fork = calls[1]["argv"]
        self.assertEqual(fork[fork.index("--session-id") + 1], reserved)
        self.assertIn("--fork-session", fork)
        self.assertIn("worker-7", fork)
        again = calls[2]["argv"]
        self.assertEqual(again[again.index("--resume") + 1], reserved)
        self.assertNotIn("--fork-session", again)
        self.assertIn("local_gate_failure", calls[2]["stdin"])
        self.assertEqual(fork[fork.index("--tools") + 1], "Read,Edit,Write,Glob,Grep")
        for flag in ("--strict-mcp-config", "--setting-sources"):
            self.assertIn(flag, fork)
        self.assertEqual(fork[fork.index("--setting-sources") + 1], "user")
        self.assertNotIn("--allowedTools", fork)
        self.assertEqual(fork[fork.index("--permission-prompts") + 1], "none")
        self.assertIn("Incorrect result", calls[1]["stdin"])
        self.assertEqual(calls[1]["cwd"], str(self.work.resolve()))
        self.controller.once()
        self.assertEqual(self.row()["state"], "merged")
        self.assertEqual(len(self.requests("thread/start")), 2)  # the Codex reviewer judged both revisions

    def test_claude_fork_that_never_launched_is_created_on_the_next_repair(self):
        ctrace = self.claude_controller("codex")
        self.configure(reports=[FIX, PASS], worker_texts=["fixed\n"], fail_launch=1)
        self.controller.once()
        self.assertEqual(self.row()["state"], "needs_decision")
        reserved = self.row()["worker_thread"]
        self.store.answer(DEFAULT_REPO, 7, "The launcher is fixed; continue.")
        self.controller.once()
        self.assertEqual(self.row()["worker_thread"], reserved)
        last = self.claude_calls(ctrace)[-1]["argv"]
        self.assertEqual(last[last.index("--session-id") + 1], reserved)
        self.assertIn("--fork-session", last)
        self.assertNotEqual(git(self.bare, "rev-parse", "feature"), self.head)

    def test_claude_reviewer_is_read_only_and_adversarial(self):
        ctrace = self.claude_controller("claude")
        self.configure(claude_reports=[PASS])
        self.controller.once()
        self.assertEqual(self.row()["state"], "merged")
        call = self.claude_calls(ctrace)[0]
        argv = call["argv"]
        self.assertNotIn("--resume", argv)
        self.assertEqual(argv[argv.index("--permission-mode") + 1], "default")
        self.assertEqual(argv[argv.index("--tools") + 1], "Read,Glob,Grep")
        self.assertIn("adversarial reviewer", call["stdin"])
        self.assertIn("pr.diff", call["stdin"])
        tree = Path(call["cwd"])
        self.assertNotEqual(tree, self.work.resolve())  # a detached review snapshot
        self.assertEqual(Path(argv[argv.index("--add-dir") + 1]).resolve(), tree.parent)
        self.assertEqual(self.requests("turn/start"), [])

    # ---- ship -------------------------------------------------------------------------

    def test_ship_pushes_the_confirmed_branch_then_opens_and_registers_it(self):
        from pr_loop import __main__ as cli
        local = self.commit_feature("app.txt", "shipped\n")
        git(self.bare, "update-ref", "refs/heads/feature", self.head)  # the new commit is not on GitHub yet
        body = self.root / "body.md"
        body.write_text("PR description\n")
        state = self.root / "shipped.sqlite3"
        env = {"CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "0f0e0d0c-aaaa-bbbb-cccc-000000000001"}
        with patch.object(cli, "GitHub", return_value=self.github), patch.dict("os.environ", env, clear=False):
            code = cli.main(["--state", str(state), "ship", "--worktree", str(self.work),
                             "--title", "fix: result", "--body-file", str(body)])
        self.assertEqual(code, 0)
        self.assertEqual(git(self.bare, "rev-parse", "feature"), local)
        self.assertEqual(self.github.created, [{"title": "fix: result", "body": "PR description\n", "base": "main",
                                                "head": "example:feature", "head_repo": "example/source"}])
        shipped = Store(state)
        try:
            binding = json.loads(shipped.get(DEFAULT_REPO, 7)["binding"])
            self.assertEqual((binding["agent"], binding["reviewer"], binding["thread"]),
                             ("claude", "codex", env["CLAUDE_CODE_SESSION_ID"]))
            self.assertTrue(binding["attended"] and binding["mirror"])
        finally:
            shipped.close()

    def test_ship_refuses_a_head_outside_the_upstream_network_before_pushing(self):
        from pr_loop import __main__ as cli
        local = self.commit_feature("app.txt", "shipped\n")
        git(self.bare, "update-ref", "refs/heads/feature", self.head)
        self.github.forks = {}
        body = self.root / "body.md"
        body.write_text("x\n")
        with patch.object(cli, "GitHub", return_value=self.github):
            code = cli.main(["--state", str(self.root / "s.sqlite3"), "ship", "--thread", "t1", "--worktree",
                             str(self.work), "--title", "t", "--body-file", str(body)])
        self.assertEqual(code, 1)
        self.assertNotEqual(git(self.bare, "rev-parse", "feature"), local)
        self.assertEqual(self.github.created, [])

    def test_ship_refuses_main(self):
        from pr_loop import __main__ as cli
        git(self.work, "switch", "-q", "main")
        body = self.root / "body.md"
        body.write_text("x\n")
        with patch.object(cli, "GitHub", return_value=self.github):
            code = cli.main(["--state", str(self.root / "s.sqlite3"), "ship", "--thread", "t1", "--worktree",
                             str(self.work), "--title", "t", "--body-file", str(body)])
        self.assertEqual(code, 1)
        self.assertEqual(git(self.bare, "rev-parse", "feature"), self.head)
        self.assertFalse(any(m == "POST" for _, m, _ in self.github.calls))


class BoundaryTest(unittest.TestCase):
    def test_timeout_reaps_descendants_holding_the_pipes(self):
        import time
        start = time.monotonic()
        # The launcher exits at once; its child keeps stdout open in the same group.
        launcher = "import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])"
        with self.assertRaisesRegex(LoopError, "timeout"):
            run([sys.executable, "-c", launcher], timeout=1)
        # A descendant in its own session escapes the group: collection is abandoned, not awaited.
        escaped = ("import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'],"
                   "start_new_session=True); import time; time.sleep(60)")
        with tempfile.TemporaryFile(mode="w+") as log:
            with self.assertRaisesRegex(LoopError, "timeout"):
                run([sys.executable, "-c", escaped], timeout=1, log=log)
            log.seek(0)
            self.assertIn("abandoned", log.read())
        self.assertLess(time.monotonic() - start, 20)

    def test_risk_rules_cover_kernel_boundaries_but_not_ordinary_code(self):
        hits = risk.classify(["src/core/agent_loop.zig", "src/permission/rule.zig", "src/api/oauth_login.zig",
                              ".github/pr_loop/risk.py", "doc/AGENTS.md", "src/repl/hint.zig", "doc/guide.md"])
        flagged = sorted(p for paths in hits.values() for p in paths)
        self.assertEqual(flagged, [".github/pr_loop/risk.py", "doc/AGENTS.md", "src/api/oauth_login.zig",
                                   "src/core/agent_loop.zig", "src/permission/rule.zig"])
        self.assertEqual(risk.reasons(["doc/guide.md"], PASS), [])

    def test_high_risk_and_rebuttals_have_one_legal_shape(self):
        with self.assertRaisesRegex(LoopError, "high-risk"):
            validate_report(dict(PASS, risk={"level": "high", "reasons": []}))
        with self.assertRaisesRegex(LoopError, "invalid report"):
            validate_report({k: v for k, v in PASS.items() if k != "risk"})
        with self.assertRaisesRegex(LoopError, "existing finding"):
            validate_worker(dict(DISPUTED, rebuttals=[{"finding": 1, "argument": "x"}]), 1)
        with self.assertRaisesRegex(LoopError, "existing finding"):
            validate_worker(DISPUTED, 0)  # CI or gate feedback has nothing to rebut
        with self.assertRaisesRegex(LoopError, "at least one rebuttal"):
            validate_worker(dict(DISPUTED, rebuttals=[]), 1)
        validate_worker(DISPUTED, 1)
    def test_only_transient_read_failures_are_retryable(self):
        with tempfile.TemporaryDirectory() as temp:
            script = Path(temp) / 'gh.py'
            script.write_text("import sys; print(sys.argv[1],file=sys.stderr); sys.exit(1)")
            github = GitHub((sys.executable, str(script), 'Bad Gateway'))
            with self.assertRaises(ReadUnavailable):
                github.api('repos/example/source')
            with self.assertRaises(ReadUnavailable):
                github.api('graphql', 'POST', {'query': 'query { viewer { login } }'})
            for path, method, payload in [('repos/example/source/merge', 'PUT', {}),
                    ('graphql', 'POST', {'query': 'mutation { doSomething }'})]:
                with self.assertRaises(LoopError) as caught:
                    github.api(path, method, payload)
                self.assertNotIsInstance(caught.exception, ReadUnavailable)
            github = GitHub((sys.executable, str(script), 'HTTP 403 Forbidden'))
            with self.assertRaises(LoopError) as caught:
                github.api('repos/example/source')
            self.assertNotIsInstance(caught.exception, ReadUnavailable)

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
        with self.assertRaisesRegex(LoopError, 'retry verdict'):
            validate_report(dict(FIX, verdict='retry'))

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
