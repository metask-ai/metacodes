"""PR commands exposed by python3 .github/pr-loop.py."""
from __future__ import annotations

import argparse
from datetime import timedelta, timezone
import json
import os
from pathlib import Path
import re
import sys
import time

from .adapters import Git, GitHub
from .controller import Controller, Store, default_state
from .model import Binding, DEFAULT_REPO, LoopError, REPO
from .timeline import html_fragment, snapshot


def main(argv=None):
    parser = argparse.ArgumentParser(description="Opt-in PR review, repair and upstream merge controller")
    parser.add_argument("--state", type=Path, default=default_state(), help="local SQLite state, outside Git")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("bind", "submit"):
        sub = commands.add_parser(name)
        sub.add_argument("--repo", default=DEFAULT_REPO)
        sub.add_argument("--thread", default=os.environ.get("CODEX_THREAD_ID"), required=not os.environ.get("CODEX_THREAD_ID"))
        sub.add_argument("--worktree", type=Path, default=Path.cwd())
        sub.add_argument("--remote", default="origin")
        sub.add_argument("--timeout", type=int, default=1800)
        if name == "bind":
            sub.add_argument("--pr", type=int, required=True)
        else:
            sub.add_argument("--title", required=True)
            sub.add_argument("--body-file", type=Path, required=True)
            sub.add_argument("--head", required=True, help="OWNER:BRANCH, already pushed")
    watch = commands.add_parser("run")
    watch.add_argument("--once", action="store_true")
    watch.add_argument("--interval", type=int, default=60)
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
        if args.command in ("bind", "submit"):
            if not REPO.fullmatch(args.repo):
                raise LoopError("repository must be OWNER/REPO")
            git = Git(args.worktree)
            git.clean()
            github = GitHub()
            number = getattr(args, "pr", None)
            if args.command == "submit":
                # Validate local arguments before creating anything on GitHub.
                Binding(args.repo, 1, args.thread, str(git.worktree), git.branch(), args.repo,
                        args.remote, args.timeout)
                url = github.create(args.repo, git.worktree, args.head, args.title, args.body_file.resolve(), "main")
                match = re.search(r"/pull/(\d+)$", url)
                if not match:
                    raise LoopError("PR created but URL was not recognized; use bind with its number")
                number = int(match.group(1))
                print(url, flush=True)
            pr = github.snapshot(args.repo, number)
            if not pr.open or pr.merged or pr.base_branch != "main":
                raise LoopError("only an open PR targeting main can be registered")
            binding = Binding(args.repo, number, args.thread, str(git.worktree), git.branch(), pr.head_repo,
                              args.remote, args.timeout)
            git.verify(binding, pr)
            if binding.branch != pr.branch:
                raise LoopError("local branch does not match the PR")
            store.bind(binding)
            print(json.dumps({"registered": f"{args.repo}#{number}", "state": str(store.path)}))
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
            controller = Controller(store)
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
