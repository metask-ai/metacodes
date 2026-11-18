"""PR commands exposed by python3 .github/pr-loop.py."""
from __future__ import annotations

import argparse
from datetime import timedelta, timezone
import getpass
import json
import os
from pathlib import Path
import re
import sys
import time

from .adapters import Git, GitHub
from .controller import Controller, Store, default_state
from .model import Agent, Binding, DEFAULT_REPO, LoopError, REPO


def invoking_agent():
    """The agent CLI running this command, so a session can register itself."""
    if os.environ.get("CLAUDECODE") == "1" and os.environ.get("CLAUDE_CODE_SESSION_ID"):
        return Agent.CLAUDE.value, os.environ["CLAUDE_CODE_SESSION_ID"]
    if os.environ.get("CODEX_THREAD_ID"):
        return Agent.CODEX.value, os.environ["CODEX_THREAD_ID"]
    return None, None


def head_repository(git, remote):
    # The configured URL, as Git.verify checks it; `get-url` applies insteadOf rewrites.
    try:
        url = git.git("config", "--get", f"remote.{remote}.pushurl")
    except LoopError:
        url = git.git("config", "--get", f"remote.{remote}.url")
    url = url.removesuffix(".git")
    match = re.fullmatch(r"(?:git@github\.com:|https://github\.com/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)", url)
    if not match:
        raise LoopError(f"push remote {remote!r} is not a GitHub repository")
    return match.group(1)
from .timeline import html_fragment, snapshot


def render_feedback(row, number):
    if row["state"] != "awaiting_session" or not row["feedback"]:
        return f"No feedback is waiting for PR #{number} (state: {row['state']})."
    evidence = json.loads(row["feedback"])
    lines = [f"PR #{number}, repair round {row['rounds']}: feedback for your session", ""]
    if evidence.get("verdict"):
        lines += [f"Adversarial review: {evidence['verdict']}", evidence["summary"], ""]
        for i, f in enumerate(evidence.get("findings", [])):
            lines += [f"[{i}] {f['path']}:{f['line']}", f"    {f['reason']}", f"    acceptance: {f['acceptance']}"]
        for f in evidence.get("followups", []):
            lines += [f"[follow-up, not blocking] {f['path']}:{f['line']}: {f['reason']}"]
    for key in ("ci_failures", "local_gate_failure", "merge_conflict", "prior_feedback"):
        if key in evidence:
            lines += [f"{key}:", json.dumps(evidence[key], ensure_ascii=False, indent=2)[:6000]]
    lines += ["", "Edit the worktree (do not commit or push), then answer with:",
              f"  python3 .github/pr-loop.py reply --pr {number} --result updated|disputed "
              "--summary '...' [--rebuttal 'INDEX:argument']"]
    return "\n".join(lines)


def inbox_line(event, number):
    detail, kind = event["detail"], event["state"]
    report = detail.get("report")
    if report:
        text = (f"review {report['verdict']}: {len(report['findings'])} finding(s), "
                f"{len(report.get('followups', []))} follow-up(s), risk {report.get('risk', {}).get('level', '?')}"
                f" — {report['summary']}")
    elif kind == "feedback_sent":
        text = f"feedback waiting for your session — python3 .github/pr-loop.py feedback --pr {number}"
    elif kind == "repair_finished":
        text = f"repair {detail.get('result')}: {detail.get('summary')}"
    else:
        text = detail.get("reason") or detail.get("summary") or detail.get("result") or ""
        if detail.get("head"):
            text = f"{detail['head'][:12]} {text}".strip()
    return f"#{number} [{event['id']}] {kind}: {text}"[:600]


def main(argv=None):
    parser = argparse.ArgumentParser(description="Opt-in PR review, repair and upstream merge controller")
    parser.add_argument("--state", type=Path, default=default_state(), help="local SQLite state, outside Git")
    commands = parser.add_subparsers(dest="command", required=True)
    detected_agent, detected_thread = invoking_agent()
    for name in ("bind", "submit", "ship"):
        sub = commands.add_parser(name, help="push the committed branch, open the PR and register it; run only "
                                  "after the developer confirmed" if name == "ship" else None)
        sub.add_argument("--repo", default=DEFAULT_REPO)
        sub.add_argument("--agent", choices=[a.value for a in Agent], default=detected_agent or Agent.CODEX.value,
                         help="the local agent whose session repairs review findings")
        sub.add_argument("--thread", default=detected_thread, required=not detected_thread,
                         help="the worker's Codex thread or Claude Code session ID")
        sub.add_argument("--reviewer", choices=[a.value for a in Agent],
                         help="adversarial reviewer backend (default: the other agent)")
        sub.add_argument("--worktree", type=Path, default=Path.cwd())
        sub.add_argument("--remote", default="origin")
        sub.add_argument("--timeout", type=int, default=1800)
        sub.add_argument("--attended", action=argparse.BooleanOptionalAction, default=bool(detected_thread),
                         help="send review feedback to this live session (default when run from one)")
        sub.add_argument("--mirror", action=argparse.BooleanOptionalAction, default=True,
                         help="mirror reviews, replies and gate events to the PR conversation")
        if name == "bind":
            sub.add_argument("--pr", type=int, required=True)
        else:
            sub.add_argument("--title", required=True)
            sub.add_argument("--body-file", type=Path, required=True)
            if name == "submit":
                sub.add_argument("--head", required=True, help="OWNER:BRANCH, already pushed")
    watch = commands.add_parser("run")
    watch.add_argument("--once", action="store_true")
    watch.add_argument("--interval", type=int, default=60)
    watch.add_argument("--human-reviewer", action="append", default=[],
                       help="GitHub login to request when a head needs human approval (repeatable)")
    approve = commands.add_parser("approve", help="approve one exact high-risk head for merge")
    approve.add_argument("--repo", default=DEFAULT_REPO)
    approve.add_argument("--pr", type=int, required=True)
    approve.add_argument("--sha", required=True, help="the PR head you reviewed (at least 7 hex digits)")
    approve.add_argument("--by", default=getpass.getuser())
    commands.add_parser("status")
    timeline = commands.add_parser("timeline", help="read recorded review, repair, validation and delivery events")
    timeline.add_argument("--repo", default=DEFAULT_REPO)
    timeline.add_argument("--pr", type=int, required=True)
    timeline.add_argument("--after", type=int, default=0, help="only include events after this cursor")
    timeline.add_argument("--format", choices=("json", "html"), default="json")
    timeline.add_argument("--utc-offset", type=int, default=0, help="display offset in minutes for HTML")
    timeline.add_argument("--follow", action="store_true", help="stream newly recorded events as JSON")
    for name, text in (("feedback", "print the review feedback waiting for this session"),
                       ("inbox", "one line per loop event, for a session to watch")):
        sub = commands.add_parser(name, help=text)
        sub.add_argument("--repo", default=DEFAULT_REPO)
        sub.add_argument("--pr", type=int, required=True)
        if name == "inbox":
            sub.add_argument("--after", type=int, default=0)
            sub.add_argument("--follow", action="store_true")
    reply = commands.add_parser("reply", help="answer the waiting feedback after editing the worktree")
    reply.add_argument("--repo", default=DEFAULT_REPO)
    reply.add_argument("--pr", type=int, required=True)
    reply.add_argument("--result", choices=("updated", "disputed", "needs_decision"), required=True)
    reply.add_argument("--summary", required=True)
    reply.add_argument("--rebuttal", action="append", default=[], metavar="INDEX:ARGUMENT")
    reply.add_argument("--question", default="")
    attach = commands.add_parser("attach", help="route a PR's feedback to its live source session, or detach")
    attach.add_argument("--repo", default=DEFAULT_REPO)
    attach.add_argument("--pr", type=int, required=True)
    attach.add_argument("--thread", default=detected_thread)
    attach.add_argument("--off", action="store_true", help="detach: unattended fork repairs")
    attach.add_argument("--mirror", action=argparse.BooleanOptionalAction, default=None)
    answer = commands.add_parser("answer")
    answer.add_argument("--repo", default=DEFAULT_REPO)
    answer.add_argument("--pr", type=int, required=True)
    answer.add_argument("--text", required=True)
    args = parser.parse_args(argv)
    store = Store(args.state)
    try:
        if args.command in ("bind", "submit", "ship"):
            if not REPO.fullmatch(args.repo):
                raise LoopError("repository must be OWNER/REPO")
            reviewer = args.reviewer or (Agent.CODEX.value if args.agent == Agent.CLAUDE.value else Agent.CLAUDE.value)
            git = Git(args.worktree)
            git.clean()
            github = GitHub()
            number = getattr(args, "pr", None)
            if args.command in ("submit", "ship"):
                # Validate local arguments before writing anything to GitHub.
                Binding(args.repo, 1, args.thread, str(git.worktree), git.branch(), args.repo,
                        args.remote, args.timeout, args.agent, reviewer)
                if args.command == "ship":
                    branch = git.branch()
                    if branch in ("main", "master"):
                        raise LoopError("ship a task branch, not main")
                    head_repo = head_repository(git, args.remote)
                    github.check_head_repository(args.repo, head_repo)  # before anything is pushed
                    git.git("push", args.remote, f"HEAD:refs/heads/{branch}")  # ordinary push, never force
                else:
                    owner, _, branch = args.head.partition(":")
                    if not owner or not branch:
                        raise LoopError("--head must be OWNER:BRANCH")
                    # A fork may be renamed: the push remote names the real repository.
                    head_repo = head_repository(git, args.remote)
                    if head_repo.split("/")[0] != owner:
                        raise LoopError(f"--head owner {owner} does not own the push remote {head_repo}")
                    github.check_head_repository(args.repo, head_repo)
                url = github.create(args.repo, head_repo, branch, args.title, args.body_file.resolve(), "main")
                match = re.search(r"/pull/(\d+)$", url)
                if not match:
                    raise LoopError("PR created but URL was not recognized; use bind with its number")
                number = int(match.group(1))
                print(url, flush=True)
            pr = github.snapshot(args.repo, number)
            if not pr.open or pr.merged or pr.base_branch != "main":
                raise LoopError("only an open PR targeting main can be registered")
            binding = Binding(args.repo, number, args.thread, str(git.worktree), git.branch(), pr.head_repo,
                              args.remote, args.timeout, args.agent, reviewer,
                              attended=args.attended, mirror=args.mirror)
            git.verify(binding, pr)
            if binding.branch != pr.branch:
                raise LoopError("local branch does not match the PR")
            store.bind(binding)
            print(json.dumps({"registered": f"{args.repo}#{number}", "state": str(store.path)}))
        elif args.command == "approve":
            with store.lock():
                head = store.approve(args.repo, args.pr, args.sha, args.by)
            print(json.dumps({"approved": f"{args.repo}#{args.pr}", "head": head, "by": args.by}))
        elif args.command == "feedback":
            print(render_feedback(store.get(args.repo, args.pr), args.pr))
        elif args.command == "reply":
            rebuttals = []
            for item in args.rebuttal:
                index, _, argument = item.partition(":")
                if not index.strip().isdigit():
                    raise LoopError("--rebuttal takes INDEX:ARGUMENT")
                rebuttals.append({"finding": int(index), "argument": argument.strip()})
            store.set_reply(args.repo, args.pr, {"result": args.result, "summary": args.summary,
                                                 "question": args.question, "rebuttals": rebuttals})
            print(json.dumps({"replied": f"{args.repo}#{args.pr}", "result": args.result}))
        elif args.command == "inbox":
            cursor = args.after
            while True:
                view = snapshot(store, args.repo, args.pr, cursor)
                for event in view["events"]:
                    print(inbox_line(event, args.pr), flush=True)
                cursor = view["cursor"]
                if not args.follow or view["state"] in ("merged", "closed"):
                    break
                time.sleep(3)
        elif args.command == "attach":
            if not args.off and not args.thread:
                raise LoopError("run attach from the PR's source session, or pass --thread")
            binding = store.attach(args.repo, args.pr, args.thread, not args.off, args.mirror)
            print(json.dumps({"pr": f"{args.repo}#{args.pr}", "attended": binding.attended, "mirror": binding.mirror}))
        elif args.command == "answer":
            with store.lock():
                store.answer(args.repo, args.pr, args.text)
        elif args.command == "status":
            for row in store.rows():
                print(json.dumps({k: row[k] for k in ("repo", "number", "state", "rounds", "agent_runs", "reason")}, ensure_ascii=False))
        elif args.command == "timeline":
            if args.follow and args.format != "json":
                raise LoopError("--follow requires JSON output")
            cursor = args.after
            view = snapshot(store, args.repo, args.pr, cursor)
            if args.format == "html":
                print(html_fragment(view, timezone(timedelta(minutes=args.utc_offset))), end="")
            else:
                print(json.dumps(view, ensure_ascii=False), flush=True)
                while args.follow and view["state"] not in ("merged", "closed"):
                    cursor = view["cursor"]
                    time.sleep(2)
                    view = snapshot(store, args.repo, args.pr, cursor)
                    if view["events"]:
                        print(json.dumps(view, ensure_ascii=False), flush=True)
        else:
            if args.interval < 1:
                raise LoopError("poll interval must be positive")
            controller = Controller(store, human_reviewers=args.human_reviewer)
            while True:
                controller.once()
                if args.once:
                    break
                time.sleep(args.interval)
        return 0
    except (LoopError, OSError, ValueError, KeyError) as exc:
        print(f"pr-loop: {exc}", file=sys.stderr)
        return 1
    finally:
        store.close()


if __name__ == "__main__":
    raise SystemExit(main())
