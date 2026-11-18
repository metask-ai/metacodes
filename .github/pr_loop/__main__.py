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
                head = getattr(args, "head", None)
                if args.command == "ship":
                    branch = git.branch()
                    if branch in ("main", "master"):
                        raise LoopError("ship a task branch, not main")
                    head = head_repository(git, args.remote).split("/")[0] + ":" + branch
                    git.git("push", args.remote, f"HEAD:refs/heads/{branch}")  # ordinary push, never force
                url = github.create(args.repo, git.worktree, head, args.title, args.body_file.resolve(), "main")
                match = re.search(r"/pull/(\d+)$", url)
                if not match:
                    raise LoopError("PR created but URL was not recognized; use bind with its number")
                number = int(match.group(1))
                print(url, flush=True)
            pr = github.snapshot(args.repo, number)
            if not pr.open or pr.merged or pr.base_branch != "main":
                raise LoopError("only an open PR targeting main can be registered")
            binding = Binding(args.repo, number, args.thread, str(git.worktree), git.branch(), pr.head_repo,
                              args.remote, args.timeout, args.agent, reviewer)
            git.verify(binding, pr)
            if binding.branch != pr.branch:
                raise LoopError("local branch does not match the PR")
            store.bind(binding)
            print(json.dumps({"registered": f"{args.repo}#{number}", "state": str(store.path)}))
        elif args.command == "approve":
            with store.lock():
                head = store.approve(args.repo, args.pr, args.sha, args.by)
            print(json.dumps({"approved": f"{args.repo}#{args.pr}", "head": head, "by": args.by}))
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
