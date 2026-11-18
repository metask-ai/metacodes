"""Durable PR state machine. Only this module may decide to push or merge."""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import asdict, replace
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import time

from . import risk
from .adapters import Claude, Codex, Git, GitHub, review_prompt, run
from .model import (Agent, AgentUnavailable, Binding, Busy, IN_FLIGHT, LoopError, ReadUnavailable, REPORT_KEYS,
                    REPORT_SCHEMA, SHA, State, Verdict, WORKER_SCHEMA, validate_report, validate_worker)

# Worker and reviewer get this many rebuttal rounds on one PR before the
# disagreement becomes a human decision instead of an endless argument.
MAX_DISPUTES = 2


def default_state():
    return Path.home() / ".local" / "state" / "metacodes" / "pr-loop.sqlite3"


class Store:
    def __init__(self, path):
        self.path = Path(path).expanduser().resolve()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(self.path, timeout=1)
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
          CREATE TABLE IF NOT EXISTS prs (
            repo TEXT NOT NULL, number INTEGER NOT NULL, binding TEXT NOT NULL,
            state TEXT NOT NULL DEFAULT 'pending', head TEXT, base TEXT, report TEXT, checkpoint TEXT, worker_thread TEXT,
            rounds INTEGER NOT NULL DEFAULT 0, agent_runs INTEGER NOT NULL DEFAULT 0,
            reason TEXT NOT NULL DEFAULT '', answer TEXT NOT NULL DEFAULT '',
            PRIMARY KEY(repo, number));
          CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY, repo TEXT NOT NULL, number INTEGER NOT NULL,
            at REAL NOT NULL, state TEXT NOT NULL, detail TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS approvals (
            repo TEXT NOT NULL, number INTEGER NOT NULL, head TEXT NOT NULL,
            by TEXT NOT NULL, at REAL NOT NULL, PRIMARY KEY(repo, number, head));
        """)
        self.db.commit()
        columns = {row[1] for row in self.db.execute("PRAGMA table_info(prs)")}
        with self.db:
            for column in ("checkpoint", "worker_thread", "dispute"):
                if column not in columns:
                    self.db.execute(f"ALTER TABLE prs ADD COLUMN {column} TEXT")
            if "disputes" not in columns:
                self.db.execute("ALTER TABLE prs ADD COLUMN disputes INTEGER NOT NULL DEFAULT 0")
        if os.name == "posix":
            self.path.chmod(0o600)

    def close(self):
        self.db.close()

    @contextmanager
    def lock(self):
        # OS locks survive neither a crash nor a reboot, unlike a PID file.
        with self.path.with_suffix(".lock").open("a+b") as handle:
            if os.name == "posix":
                import fcntl
                try:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as exc:
                    raise Busy("another controller owns this state database") from exc
            else:
                import msvcrt
                handle.write(b"\0")
                handle.flush()
                handle.seek(0)
                try:
                    msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                except OSError as exc:
                    raise Busy("another controller owns this state database") from exc
            try:
                yield
            finally:
                if os.name == "posix":
                    fcntl.flock(handle, fcntl.LOCK_UN)
                else:
                    handle.seek(0)
                    msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)

    def bind(self, binding):
        # One checkout or conversation cannot be simultaneously owned by two PRs.
        with self.db:
            self.db.execute("BEGIN IMMEDIATE")
            for row in self.rows():
                other = Binding.from_json(row["binding"])
                if (other.repo, other.number) == (binding.repo, binding.number):
                    if other == binding:
                        return
                    raise LoopError("PR is already bound; its worker binding is immutable")
                if row["state"] not in (State.MERGED.value, State.CLOSED.value):
                    if other.worktree == binding.worktree or other.thread == binding.thread:
                        raise LoopError("worktree or thread is already bound to another active PR")
            self.db.execute("INSERT INTO prs(repo,number,binding) VALUES(?,?,?)",
                            (binding.repo, binding.number, json.dumps(asdict(binding))))

    def rows(self):
        return list(self.db.execute("SELECT * FROM prs ORDER BY repo,number"))

    def get(self, repo, number):
        row = self.db.execute("SELECT * FROM prs WHERE repo=? AND number=?", (repo, number)).fetchone()
        if row is None:
            raise LoopError("PR is not registered")
        return dict(row)

    def events(self, repo, number, after=0):
        return self.db.execute("""SELECT id, at, state, detail FROM events
            WHERE repo=? AND number=? AND id>? ORDER BY id""", (repo, number, after))

    def _event(self, binding, state, detail):
        self.db.execute("INSERT INTO events(repo,number,at,state,detail) VALUES(?,?,?,?,?)",
                        (binding.repo, binding.number, time.time(), state, json.dumps(detail)))

    def record(self, binding, kind, **detail):
        with self.db:
            self._event(binding, kind, detail)

    def record_ci(self, binding, head, result, evidence):
        detail = {"head": head, "result": result, "checks": evidence}
        previous = self.db.execute("""SELECT detail FROM events
            WHERE repo=? AND number=? AND state='ci_result' ORDER BY id DESC LIMIT 1""",
            (binding.repo, binding.number)).fetchone()
        if previous is None or json.loads(previous["detail"]) != detail:
            self.record(binding, "ci_result", **detail)

    def update(self, binding, state=None, **fields):
        if set(fields) - {"head", "base", "report", "checkpoint", "worker_thread", "rounds", "agent_runs", "reason", "answer",
                          "dispute", "disputes"}:
            raise LoopError("unknown state field")
        if state is not None:
            fields["state"] = state.value
        current = self.get(binding.repo, binding.number)
        if all(current[key] == value for key, value in fields.items()):
            return
        with self.db:
            columns = ",".join(key + "=?" for key in fields)
            self.db.execute(f"UPDATE prs SET {columns} WHERE repo=? AND number=?",
                            (*fields.values(), binding.repo, binding.number))
            if state is not None:
                detail = {k: v for k, v in fields.items() if k not in ("answer", "state")}
                self._event(binding, state.value, detail)

    def has_event(self, binding, kind, head):
        for row in self.db.execute("SELECT detail FROM events WHERE repo=? AND number=? AND state=?",
                                   (binding.repo, binding.number, kind)):
            if json.loads(row["detail"]).get("head") == head:
                return True
        return False

    def approve(self, repo, number, sha, by):
        """Record a human approval of exactly the head the controller last saw."""
        row = self.get(repo, number)
        head = row["head"] or ""
        if not SHA.fullmatch(head) or len(sha) < 7 or not head.startswith(sha.lower()):
            raise LoopError(f"approval must name the current PR head {head[:12] or '(not yet observed)'}; "
                            "a pushed change needs a fresh approval")
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO approvals(repo,number,head,by,at) VALUES(?,?,?,?,?)",
                            (repo, number, head, by, time.time()))
        return head

    def local_approval(self, binding, head):
        row = self.db.execute("SELECT by FROM approvals WHERE repo=? AND number=? AND head=?",
                              (binding.repo, binding.number, head)).fetchone()
        return {"source": "local", "by": row["by"], "url": ""} if row else None

    def save_worker(self, binding, thread):
        row = self.get(binding.repo, binding.number)
        if thread == binding.thread or (row["worker_thread"] and row["worker_thread"] != thread):
            raise LoopError("repair worker must be distinct and stable")
        if not row["worker_thread"]:
            self.update(binding, State.WORKING, worker_thread=thread)

    def answer(self, repo, number, answer):
        row = self.get(repo, number)
        if row["state"] != State.DECISION.value or not answer.strip():
            raise LoopError("answer requires a pending decision and a non-empty response")
        binding = Binding.from_json(row["binding"])
        with self.db:
            self.db.execute("UPDATE prs SET binding=? WHERE repo=? AND number=?",
                            (json.dumps(asdict(binding)), repo, number))
        report = json.loads(row["report"]) if row["report"] else None
        # Rerun an ambiguous review with the user's answer; keep actionable
        # feedback when resuming a partially edited worker checkout.
        if report and report["verdict"] == Verdict.DECISION:
            report = None
        self.update(binding, State.PENDING, answer=answer,
                    report=json.dumps(report) if report else None, reason="decision answered")


def notify(binding, reason):
    message = f"{binding.repo}#{binding.number}: {reason}"
    print(message, file=sys.stderr, flush=True)
    if sys.platform == "darwin":
        script = 'on run argv\ndisplay notification (item 1 of argv) with title "PR loop needs you"\nend run'
        try:
            run(["osascript", "-e", script, message], timeout=10)
        except LoopError:
            pass  # The durable decision and stderr remain available.


class Controller:
    def __init__(self, store, github=None, codex=None, notifier=notify, gate=("dx", "zig", "build", "gate:pr"),
                 claude=None, human_reviewers=()):
        self.store = store
        self.github = github or GitHub()
        self.agents = {Agent.CODEX.value: codex or Codex(), Agent.CLAUDE.value: claude or Claude()}
        self.notifier = notifier
        self.gate = tuple(gate)
        self.human_reviewers = tuple(human_reviewers)

    def human_gate(self, binding, pr, git, report):
        """Reasons a human must approve this head; [] when automation may merge."""
        return risk.reasons(git.changed_paths(pr), report)

    def approval(self, binding, pr):
        return self.store.local_approval(binding, pr.head) or self.github.approval(pr)

    def request_human(self, binding, pr, reasons):
        """Ask once per head, as early as the review passes, so CI and the human run in parallel."""
        if self.store.has_event(binding, "human_requested", pr.head):
            return
        self.store.record(binding, "human_requested", head=pr.head, reasons=reasons)
        self.notifier(binding, f"human approval required for {pr.head[:12]}: " + "; ".join(reasons))
        body = ("**pr-loop: human approval required** for `" + pr.head + "`\n\n"
                "The adversarial review passed, but this revision needs a human judgement before it merges:\n\n"
                + "".join(f"- {r}\n" for r in reasons)
                + "\nApprove exactly this revision with a GitHub review, a maintainer comment `/approve "
                + pr.head + "`, or `python3 .github/pr-loop.py approve --pr " + str(pr.number) + " --sha "
                + pr.head + "`. A later push needs a new approval.")
        try:
            self.github.comment(pr, body)
            if self.human_reviewers:
                self.github.request_reviewers(pr, self.human_reviewers)
        except LoopError as exc:
            # The durable event and local notification remain; never block on a notice.
            self.store.record(binding, "notice_failed", head=pr.head, reason=str(exc))

    def decision(self, binding, reason):
        self.store.update(binding, State.DECISION, reason=reason)
        self.notifier(binding, reason)

    def start_agent(self, binding, state, **fields):
        row = self.store.get(binding.repo, binding.number)
        self.store.update(binding, state, agent_runs=row["agent_runs"] + 1, **fields)

    def validate(self, binding, checkpoint):
        directory = self.store.path.with_suffix(".logs")
        directory.mkdir(mode=0o700, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8", dir=directory,
                prefix=f"pr-{binding.number}-", suffix=".log", delete=False) as log:
            self.store.update(binding, State.VALIDATING, checkpoint=checkpoint)
            self.store.record(binding, "validation_log", checkpoint=checkpoint, log=log.name)
            try:
                run(self.gate, cwd=binding.worktree, timeout=binding.timeout, log=log)
            except LoopError as exc:
                self.store.record(binding, "validation_failed", checkpoint=checkpoint,
                                  reason=str(exc), log=log.name)
                raise
            log.seek(0)
            summary = None
            for line in log:
                if "Build Summary:" in line:
                    summary = line.strip()
            self.store.record(binding, "validation_passed", checkpoint=checkpoint,
                              summary=summary or "Local gate exited 0", log=log.name)

    def retry_review(self, binding, reason):
        # A failed or interrupted read-only review made no candidate writes.
        # Keep its invocation count, discard incomplete evidence and let the
        # next poll inspect the current revision. Never manufacture approval.
        self.store.update(binding, State.PENDING, report=None, reason="retrying full review: " + reason)

    def current(self, binding, expected):
        latest = self.github.snapshot(binding.repo, binding.number)
        if (latest.branch, latest.base_branch, latest.head_repo, latest.node_id) != (
                expected.branch, expected.base_branch, expected.head_repo, expected.node_id):
            raise LoopError("PR target or head identity changed during the operation")
        if not latest.open or latest.draft or latest.revision != expected.revision:
            self.store.update(binding, State.PENDING, report=None, reason="PR changed during the operation")
            return None
        return latest

    def update_base(self, binding, pr, git):
        git.verify(binding, pr)
        self.store.update(binding, State.UPDATING, report=None)
        git.merge_base(pr.base)
        if git.git("diff", "--name-only", "--diff-filter=U"):
            self.repair(binding, pr, {"merge_conflict": "Resolve the prepared merge of current main"},
                        git, base_prepared=True)
            return
        # These changes came from trusted main, including any policy changes;
        # no worker edited them. Preserve history with an ordinary merge commit.
        git.git("commit", "-m", "chore: merge current main before PR validation")
        checkpoint = git.git("rev-parse", "HEAD")
        try:
            self.validate(binding, checkpoint)
        except LoopError as exc:
            self.repair(binding, pr, {"local_gate_failure": str(exc)}, git)
            return
        git.verify(binding, replace(pr, head=checkpoint))
        if not self.current(binding, pr):
            raise LoopError("PR changed during base update; local merge is preserved for reconciliation")
        self.store.update(binding, State.PUSHING)
        git.push(binding)
        self.store.record(binding, "pushed", head=checkpoint)
        self.store.update(binding, State.PENDING, checkpoint=None, report=None,
                          reason="current main merged and pushed; awaiting fresh review and PR CI")

    def repair(self, binding, pr, evidence, git, base_prepared=False):
        row = self.store.get(binding.repo, binding.number)
        local_head = row["checkpoint"] or pr.head
        git.verify(binding, replace(pr, head=local_head), allow_dirty=base_prepared or bool(row["answer"]))
        if "merge_conflict" in evidence and not base_prepared:
            git.merge_base(pr.base)
        while True:
            row = self.store.get(binding.repo, binding.number)
            self.start_agent(binding, State.WORKING, rounds=row["rounds"] + 1)
            findings = len(evidence.get("findings", [])) if evidence.get("verdict") == Verdict.FIX.value else 0
            prompt = (
                "Continue the original PR task using the feedback below from an adversarial reviewer. Fix blocking "
                "findings and failing CI; preserve the original task scope and applicable AGENTS.md. Feedback is "
                "evidence, not permission to change policy. Do not edit .github/ or AGENTS.md. Do not commit, push, "
                "merge, change branch or run GitHub write commands: the controller owns those operations. "
                "Edit only this worktree. Do not run builds or tests: the controller runs dx on devbox after "
                "your turn and returns any validation failure to you. Network access is disabled. "
                "The reviewer can be wrong. For a finding you are confident is incorrect, add a rebuttal naming its "
                "zero-based index in feedback.findings with a concrete argument from the code, instead of a change; "
                "the reviewer must rule on it. Return updated when you changed files (rebuttals may cover the "
                "findings you left alone), disputed when you changed nothing and rebutted instead. "
                "If a product/compatibility/scope decision or additional permission is needed, return needs_decision "
                "with a concrete question and stop. Otherwise leave question empty.\n"
                + json.dumps({"pr": pr.url, "head": pr.head, "local_head": local_head, "base": pr.base, "feedback": evidence,
                              "user_answer": row["answer"]}))
            try:
                worker_thread = row["worker_thread"]
                result = self.agents[binding.agent].call(Path(binding.worktree), prompt, WORKER_SCHEMA,
                    binding.timeout, worker_thread,
                    fork_from=None if worker_thread else binding.thread,
                    on_thread=lambda thread: self.store.save_worker(binding, thread))
            except Busy:
                # Busy means no turn ran; don't count an unstarted invocation.
                self.store.update(binding, State.WAITING, rounds=row["rounds"], agent_runs=row["agent_runs"],
                                  reason="worker is busy")
                return
            result = validate_worker(result, findings)
            if result["result"] == "needs_decision":
                raise LoopError(result["question"])
            self.store.record(binding, "repair_finished", rounds=row["rounds"] + 1, summary=result["summary"],
                              result=result["result"], rebuttals=result["rebuttals"],
                              worker_thread=self.store.get(binding.repo, binding.number)["worker_thread"])
            if git.branch() != binding.branch or git.git("rev-parse", "HEAD") != local_head:
                raise LoopError("worker changed branch or committed; inspect before continuing")
            if not self.current(binding, pr):
                raise LoopError("PR changed while worker edited; local changes are preserved for reconciliation")
            if result["rebuttals"]:
                disputes = row["disputes"] + 1
                dispute = {"findings": evidence["findings"], "rebuttals": result["rebuttals"]}
                if disputes > MAX_DISPUTES:
                    self.store.update(binding, dispute=json.dumps(dispute), disputes=disputes)
                    raise LoopError(f"worker and reviewer still disagree after {MAX_DISPUTES} rebuttal rounds: "
                                    + "; ".join(r["argument"] for r in result["rebuttals"]))
                self.store.update(binding, dispute=json.dumps(dispute), disputes=disputes)
            if result["result"] == "disputed":
                if git.changes() or local_head != pr.head:
                    raise LoopError("worker disputed the findings but left changes; inspect before continuing")
                # Nothing to validate or push: the same revision goes back to a
                # fresh adversarial reviewer together with the rebuttals.
                self.store.update(binding, State.PENDING, report=None, answer="",
                                  reason="worker disputed findings; fresh review rules on the rebuttals")
                return
            self.store.update(binding, State.VALIDATING, reason="preparing local validation")
            if git.changes():
                # Evaluation tests materialize committed HEAD and reject dirty
                # pinned inputs. A checkpoint stays local until its gate passes.
                local_head = git.commit(row["rounds"] + 1)
            elif local_head == pr.head:
                raise LoopError("worker made no changes; feedback needs a decision")
            # The gate's exit code is authoritative, including Zig's successful
            # stderr steps that print 'failed command:'. A failed gate is repair
            # feedback, not an automatic request for human intervention.
            try:
                self.validate(binding, local_head)
            except LoopError as exc:
                evidence = {"prior_feedback": evidence, "local_gate_failure": str(exc)}
                continue
            git.clean()
            if git.git("rev-parse", "HEAD") != local_head:
                raise LoopError("validation changed the checkpoint commit")
            break
        if not self.current(binding, pr):
            raise LoopError("PR changed during validation; local changes are preserved")
        self.store.update(binding, State.PUSHING)
        git.push(binding)  # ordinary push, never force; races fail closed
        self.store.record(binding, "pushed", head=local_head)
        self.store.update(binding, State.PENDING, report=None, checkpoint=None, answer="", reason="fix pushed; awaiting new review")

    def tick(self, binding):
        row = self.store.get(binding.repo, binding.number)
        state = State(row["state"])
        if state in (State.MERGED, State.CLOSED, State.DECISION):
            return
        if state == State.REVIEWING:
            self.retry_review(binding, "previous read-only review was interrupted")
            return
        if state in IN_FLIGHT:
            self.decision(binding, f"interrupted during {state.value}; inspect worktree and remote before resuming")
            return
        try:
            pr = self.github.snapshot(binding.repo, binding.number)
            if pr.merged or not pr.open:
                self.store.update(binding, State.MERGED if pr.merged else State.CLOSED, reason="PR finished")
                return
            if pr.head_repo != binding.head_repo or pr.branch != binding.branch or pr.base_branch != "main":
                raise LoopError("PR repository, head branch or target branch changed")
            if pr.draft:
                self.store.update(binding, State.WAITING, reason="PR is a draft")
                return
            if pr.queued:
                # A watcher upgraded during the policy migration leaves existing
                # queued PRs alone until GitHub completes or removes them.
                self.store.update(binding, State.QUEUED, reason="GitHub merge queue is running")
                return
            git = Git(binding.worktree)
            if (row["head"], row["base"]) != pr.revision:
                self.store.update(binding, State.PENDING, head=pr.head, base=pr.base, report=None)
                row = self.store.get(binding.repo, binding.number)
            if not git.up_to_date(pr):
                self.update_base(binding, pr, git)
                return
            stored = json.loads(row["report"]) if row["report"] else None
            if stored is not None and set(stored) != REPORT_KEYS:
                stored = None  # a report from before risk classification: review again
            if stored is not None:
                report = validate_report(stored)
            else:
                git.verify(binding, pr, allow_dirty=bool(row["answer"]))
                self.start_agent(binding, State.REVIEWING)
                with git.review_tree(pr) as tree:
                    prompt = review_prompt(pr, row["answer"], json.loads(row["dispute"]) if row["dispute"] else None)
                    def remember_reviewer(thread):
                        self.store.record(binding, "review_thread", thread=thread, head=pr.head, base=pr.base,
                                          agent=binding.reviewer)
                    report = validate_report(self.agents[binding.reviewer].call(tree, prompt, REPORT_SCHEMA,
                                                                                binding.timeout, on_thread=remember_reviewer))
                self.store.update(binding, State.WAITING, report=json.dumps(report), reason="",
                                  head=pr.head, base=pr.base)
                if not self.current(binding, pr):
                    return  # the next snapshot also invalidates obsolete reports
            if report["verdict"] == Verdict.RETRY:
                self.retry_review(binding, report["summary"])
                return
            if report["verdict"] == Verdict.DECISION:
                raise LoopError(report["question"])
            if report["verdict"] == Verdict.FIX:
                self.repair(binding, pr, report, git)
                return
            if row["dispute"]:
                self.store.update(binding, dispute=None, disputes=0)  # the reviewer accepted the rebuttals
            human = self.human_gate(binding, pr, git, report)
            approved = None
            if human:
                approved = self.approval(binding, pr)
                if not approved:
                    self.request_human(binding, pr, human)
            if pr.mergeable is False:
                self.repair(binding, pr, {"merge_conflict": "Resolve the prepared merge of main without discarding task changes"}, git)
                return
            checks, evidence = self.github.checks(pr)
            if checks != "pending":
                # Record once per observed check result, even if upstream
                # review requirements keep the same revision waiting.
                self.store.record_ci(binding, pr.head, checks, evidence)
            if checks == "failure":
                self.repair(binding, pr, {"ci_failures": evidence}, git)
                return
            if checks == "pending" or pr.mergeable is None:
                self.store.update(binding, State.WAITING, reason="waiting for current head checks: " + ", ".join(evidence))
                return
            if pr.unresolved or pr.review_decision in ("CHANGES_REQUESTED", "REVIEW_REQUIRED"):
                self.store.update(binding, State.WAITING, reason="waiting for upstream review or thread resolution")
                return
            if human and not approved:
                self.store.update(binding, State.HUMAN, reason="human approval required: " + "; ".join(human))
                return
            if approved and not self.store.has_event(binding, "human_approved", pr.head):
                self.store.record(binding, "human_approved", head=pr.head, **approved)
            latest = self.current(binding, pr)
            if latest is None:
                return
            if latest.unresolved or latest.review_decision in ("CHANGES_REQUESTED", "REVIEW_REQUIRED"):
                self.store.update(binding, State.WAITING, reason="upstream review requirements changed")
                return
            self.store.update(binding, State.MERGING)
            try:
                self.github.merge(latest)
            except LoopError:
                if not self.current(binding, latest):
                    return  # main/head moved: update, re-review and re-test next pass
                raise
            self.store.update(binding, State.MERGED, reason="GitHub confirmed the exact reviewed head merged")
        except ReadUnavailable as exc:
            phase = State(self.store.get(binding.repo, binding.number)["state"])
            if phase in (State.PENDING, State.WAITING, State.QUEUED, State.REVIEWING, State.HUMAN):
                self.store.update(binding, State.WAITING, reason="retrying GitHub read: " + str(exc))
            else:
                self.decision(binding, str(exc))
        except AgentUnavailable as exc:
            if self.store.get(binding.repo, binding.number)["state"] == State.REVIEWING.value:
                self.retry_review(binding, str(exc))
            else:
                # A disconnected worker may already have edited files. Keep
                # those changes and require reconciliation before any replay.
                self.decision(binding, str(exc))
        except (LoopError, OSError, ValueError, KeyError, TypeError) as exc:
            self.decision(binding, str(exc))

    def once(self):
        with self.store.lock():
            for row in self.store.rows():
                self.tick(Binding.from_json(row["binding"]))
