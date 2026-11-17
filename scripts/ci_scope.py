#!/usr/bin/env python3
"""Decide which of CI's suites a change can affect.

Design: doc/CI_DESIGN.md §2, "Change scope". The gate legs, TTY shards and
the result jobs over them (the required checks) always run and report under
their own names; the legs' and shards' expensive steps read the scope decided
here, so a change that cannot affect a suite does not pay for it. Skipping
whole jobs instead would leave a matrix job unnamed and a required check
pending or, for a skipped result job, passing (the `on.pull_request.paths`
filter of #134 blocked PRs the same way).

Scopes, narrowest first:

- `docs`: every changed path is documentation that no build, test or release
  layout reads: `doc/**`, and the top-level Markdown files other than the
  ones build.zig installs into the release layout (README.md, CHANGELOG.md,
  THIRD_PARTY_NOTICES.md). Only the documentation, version-state and
  gate-manifest checks run; `suites=false` and `tty=false`. A *deleted*
  documentation file is not documentation-only: pins elsewhere name doc
  paths (evals/plugin-v1/protocol.json `implementation_paths`, which
  `zig build test` resolves), so removing or moving one is the full scope.
- `eval`: every changed path is documentation or the Python evaluation
  harness (`scripts/eval/**`, `evals/**`). The gates run in full, since
  `zig build test` runs the harness's suites and smokes against the built
  binary; the TTY suites, which drive the interactive binary and read
  neither, report success without running: `suites=true`, `tty=false`.
- `full`: anything else, every manual run, an empty diff, and any
  error: `suites=true`, `tty=true`.

Pushes compare against the event's `before` SHA, covering every pushed
commit. A narrow push also requires successful CI on that base: unchanged
suites inherit its evidence. A pending, failed, cancelled or missing base
run takes the full scope, preserving the release fast path's base guarantee.

ci.yml: `ci_scope.py --event "$GITHUB_EVENT_NAME" --base <rev> --candidate
HEAD --github-output "$GITHUB_OUTPUT"`, with the base `HEAD^1` on a pull
request (the merge commit's base) and the group's `base_sha` in a merge
queue. It writes `scope=`, `suites=`, `tty=`, `native=` and `reason=`;
`native` is used by the Windows workflow on pushes. It always exits 0: a
doubt is the full scope, never a red job. Python 3.9, stdlib only; tests in
scripts/tests/test_ci_scope.py.
"""
from __future__ import annotations

import argparse
import html
import os
import subprocess
import sys
from pathlib import Path
from typing import Callable, Optional, Sequence, Tuple

ROOT = Path(__file__).resolve().parents[1]
# Manual and unknown events always run in full.
DIFF_EVENTS = ("pull_request", "merge_group", "push")
# Top-level Markdown that the release layout installs (build.zig, share/doc
# and share/licenses); scripts/tests/test_ci_scope.py checks the list against
# build.zig.
RELEASE_DOCS = ("README.md", "CHANGELOG.md", "THIRD_PARTY_NOTICES.md")
EVAL_PREFIXES = ("scripts/eval/", "evals/")
SHOWN = 5


def is_docs(path: str) -> bool:
    if path.startswith("doc/"):
        return True
    return "/" not in path and path.endswith(".md") and path not in RELEASE_DOCS


def is_eval(path: str) -> bool:
    return path.startswith(EVAL_PREFIXES)


def _shown(paths: Sequence[str]) -> str:
    listed = ", ".join(paths[:SHOWN])
    return listed + (f" and {len(paths) - SHOWN} more" if len(paths) > SHOWN else "")


def classify(paths: Sequence[str], deleted: Sequence[str] = ()) -> Tuple[str, str]:
    """(scope, reason) for the changed `paths`, of which `deleted` were
    removed or changed type (a rename is a removal plus an addition)."""
    if not paths:
        return "full", "full scope: the change has no paths"
    removed_docs = [path for path in deleted if is_docs(path)]
    if removed_docs:
        return "full", f"full scope: {_shown(removed_docs)} removed or changed type; pins and links elsewhere can name a documentation path"
    if all(is_docs(path) for path in paths):
        return "docs", f"docs scope: only documentation changed ({_shown(paths)})"
    outside = [path for path in paths if not (is_docs(path) or is_eval(path))]
    if not outside:
        return "eval", "eval scope: only documentation and the evaluation harness changed; the TTY suites are skipped"
    return "full", f"full scope: {_shown(outside)} can affect every suite"


Change = Tuple[str, str]  # (git status letter, path)


def changed_paths(root: Path, base: str, candidate: str) -> Tuple[Change, ...]:
    proc = subprocess.run(
        ["git", "diff", "--name-status", "--no-renames", "-z", base, candidate],
        cwd=str(root),
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"git diff failed: {proc.stderr.decode('utf-8', 'replace').strip()}")
    fields = [field for field in proc.stdout.decode("utf-8").split("\0") if field]
    if len(fields) % 2:
        raise RuntimeError("git diff --name-status output is not status/path pairs")
    return tuple((fields[i][:1], fields[i + 1]) for i in range(0, len(fields), 2))


def decide(
    event: str,
    base: str,
    candidate: str,
    changes: Callable[[str, str], Sequence[Change]],
    base_ci: Optional[Callable[[str], str]] = None,
) -> Tuple[str, str]:
    if event not in DIFF_EVENTS:
        return "full", f"full scope: {event or 'unknown'} run"
    if not base:
        return "full", f"full scope: no base for the {event} run"
    try:
        found = list(changes(base, candidate))
        # Only an addition or an edit leaves a path where pins expect it; a
        # removal or a type change (a file turned into a symlink, which
        # plugin_release_gate refuses) widens the scope.
        scope, reason = classify([path for _, path in found], [path for status, path in found if status not in ("A", "M")])
        if event == "push" and scope != "full":
            state = base_ci(base) if base_ci else "unknown"
            if state != "success":
                return "full", f"full scope: {reason}; CI on the push base {base[:12]} is {state}"
            reason += f"; unchanged suites inherit successful CI on push base {base[:12]}"
        return scope, reason
    except Exception as exc:  # any doubt is the full scope, never a red job
        return "full", f"full scope: the scope check failed: {exc}"


def outputs(scope: str) -> Tuple[bool, bool]:
    """(suites, tty) for `scope`."""
    return scope != "docs", scope == "full"


def write_summary(destination: str, event: str, base: str, candidate: str,
                  scope: str, reason: str, changes: Sequence[Change]) -> None:
    """Explain the decision without treating Git paths as Markdown or HTML."""
    def cell(value: str) -> str:
        escaped = html.escape(" ".join(value.split()), quote=True)
        for char in "\\|`[]*_~":
            escaped = escaped.replace(char, f"&#{ord(char)};")
        return escaped

    suites, tty = outputs(scope)
    lines = ["### CI change attribution", "", f"Scope: **{scope}**", "", cell(reason), "",
             f"Event: {cell(event)}; base: {cell(base or '(none)')}; candidate: {cell(candidate)}", "",
             "| Checks | Decision |", "|---|---|",
             "| Documentation, version state, gate manifest, whitespace | Run |",
             f"| Build, unit, integration, product, release | {'Run' if suites else 'Skip'} |",
             f"| TTY and SDK | {'Run' if tty else 'Skip'} |"]
    if event == "push":
        lines.append(f"| Native Windows | {'Run' if tty else 'Skip'} |")
    lines.extend(["", "| Status | Changed path | Path scope |", "|---|---|---|"])
    for status, path in changes[:200]:
        path_scope, _ = classify([path], [path] if status not in ("A", "M") else [])
        lines.append(f"| {cell(status)} | {cell(path)} | {path_scope} |")
    if len(changes) > 200:
        lines.extend(["", f"Showing 200 of {len(changes)} changed paths; the decision uses all paths."])
    with open(destination, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--event", required=True)
    parser.add_argument("--base", default="")
    parser.add_argument("--candidate", default="HEAD")
    parser.add_argument("--github-output")
    parser.add_argument("--github-summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--repo-root", default=str(ROOT))
    args = parser.parse_args(argv)
    root = Path(args.repo_root)
    observed = []

    def changes(base: str, candidate: str) -> Sequence[Change]:
        observed.extend(changed_paths(root, base, candidate))
        return observed

    def base_ci(sha: str) -> str:
        if not args.repository:
            return "unknown"
        # Same successful push-run evidence the release fast path consumes.
        # Lazy import: PRs and local classification need neither gh nor its token.
        from release_fast_path import base_ci_state
        resolved = subprocess.check_output(["git", "rev-parse", sha], cwd=str(root), text=True).strip()
        return base_ci_state(args.repository, resolved)

    scope, reason = decide(args.event, args.base, args.candidate, changes, base_ci)
    suites, tty = outputs(scope)
    reason = " ".join(reason.split())
    print(reason)
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.write(
                f"scope={scope}\nsuites={'true' if suites else 'false'}\n"
                f"tty={'true' if tty else 'false'}\nnative={'true' if tty else 'false'}\nreason={reason}\n"
            )
    if args.github_summary:
        write_summary(args.github_summary, args.event, args.base, args.candidate, scope, reason, observed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
