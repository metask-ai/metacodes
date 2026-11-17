"""New PR entry point: python3 -m tools.pr_loop submit|bind|run|status|answer."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
import time

from .adapters import Git, GitHub
from .controller import Controller, Store, default_state
from .model import Binding, DEFAULT_REPO, LoopError, REPO


def main(argv=None):
    parser = argparse.ArgumentParser(description="Opt-in PR review, repair and upstream merge-queue controller")
    parser.add_argument("--state", type=Path, default=default_state(), help="local SQLite state, outside Git")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("bind", "submit"):
        sub = commands.add_parser(name)
        sub.add_argument("--repo", default=DEFAULT_REPO)
        sub.add_argument("--thread", default=os.environ.get("CODEX_THREAD_ID"), required=not os.environ.get("CODEX_THREAD_ID"))
        sub.add_argument("--worktree", type=Path, default=Path.cwd())
        sub.add_argument("--remote", default="origin")
        sub.add_argument("--max-rounds", type=int, default=5)
        sub.add_argument("--max-agent-runs", type=int, default=16)
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
    answer = commands.add_parser("answer")
    answer.add_argument("--repo", default=DEFAULT_REPO)
    answer.add_argument("--pr", type=int, required=True)
    answer.add_argument("--text", required=True)
    answer.add_argument("--extra-rounds", type=int, default=0)
    answer.add_argument("--extra-agent-runs", type=int, default=0)
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
                        args.remote, args.max_rounds, args.max_agent_runs, args.timeout)
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
                              args.remote, args.max_rounds, args.max_agent_runs, args.timeout)
            git.verify(binding, pr)
            if binding.branch != pr.branch:
                raise LoopError("local branch does not match the PR")
            store.bind(binding)
            print(json.dumps({"registered": f"{args.repo}#{number}", "state": str(store.path)}))
        elif args.command == "answer":
            with store.lock():
                store.answer(args.repo, args.pr, args.text, args.extra_rounds, args.extra_agent_runs)
        elif args.command == "status":
            for row in store.rows():
                print(json.dumps({k: row[k] for k in ("repo", "number", "state", "rounds", "agent_runs", "reason")}, ensure_ascii=False))
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
