#!/usr/bin/env python3
"""Decide whether a pull request may take CI's release fast path.

Design: doc/RELEASE_AUTOMATION_DESIGN.md §3, "CI fast path". A release or
reopen PR adds only what `scripts/release_cut.py` generates: the two version
files, the changelog heading and the fingerprint repin. When its merge commit
adds nothing else to a base commit whose full CI already passed on `main`,
running the suites again proves nothing new, so ci.yml lets the required jobs
report success without running them. Every other PR, and every doubt, takes
the full path.

Two facts decide it, both checked here:

1. Content. The paths that differ between the base and the candidate (the
   merge commit) are among the four generated files, and regenerating those
   files from the base with release_cut's own functions (`apply_version`,
   `rewrite_changelog` or `ensure_unreleased`, `repin_fingerprint`)
   reproduces the candidate byte for byte. A bare version over a `-dev` base
   is a cut; a `-dev` version over a bare base is a reopen.
2. Base. The `CI` workflow's push run for the base commit concluded
   `success`. A run that is still going (the reopen PR is opened while
   `main`'s run of the release merge is in progress) is waited for, up to
   `--wait-seconds`; anything else is the full path.

ci.yml: `release_fast_path.py --base HEAD^1 --candidate HEAD --repository
owner/repo --github-output "$GITHUB_OUTPUT"`. It writes `fast=true|false` and
`reason=...` and always exits 0: an error is reported and decides the full
path. Python 3.9, stdlib only; tests in scripts/tests/test_release_fast_path.py.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Callable, Optional, Sequence, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_cut  # noqa: E402  (same directory, stdlib only)

ROOT = Path(__file__).resolve().parents[1]
GENERATED = (release_cut.ZON, release_cut.VERSION_ZIG, release_cut.CHANGELOG, release_cut.PROTOCOL)
CI_WORKFLOW = "ci.yml"
POLL_SECONDS = 30


class NotABump(Exception):
    """The candidate is not exactly a generated release or reopen bump."""


def git(root: Path, *argv: str) -> bytes:
    proc = subprocess.run(["git", *argv], cwd=str(root), capture_output=True, check=False)
    if proc.returncode != 0:
        raise NotABump(f"git {' '.join(argv)} failed: {proc.stderr.decode('utf-8', 'replace').strip()}")
    return proc.stdout


def show(root: Path, rev: str, rel: str) -> bytes:
    return git(root, "show", f"{rev}:{rel}")


def zon_version(text: str) -> str:
    match = release_cut.ZON_VERSION_RE.search(text)
    if match is None:
        raise NotABump(f"{release_cut.ZON}: no .version declaration")
    return match.group(2)


def changelog_date(text: str, version: str) -> str:
    for line in text.splitlines():
        match = release_cut.RELEASE_HEADING_RE.match(line)
        if match and match.group(1) == version:
            return match.group(2)
    raise NotABump(f"{release_cut.CHANGELOG}: no '## {version} — <date>' heading")


def verify_bump(
    root: Path,
    base: str,
    candidate: str,
    repin: Callable[[Path], None] = release_cut.repin_fingerprint,
) -> Tuple[str, str]:
    """(kind, version) when `candidate` is exactly the cut or the reopen that
    release_cut generates from `base`; NotABump with the reason otherwise."""
    changed = [p for p in git(root, "diff", "--name-only", "--no-renames", base, candidate).decode("utf-8").splitlines() if p]
    if not changed:
        raise NotABump("the candidate changes nothing against the base")
    extra = sorted(set(changed) - set(GENERATED))
    if extra:
        shown = ", ".join(extra[:5]) + (f" and {len(extra) - 5} more" if len(extra) > 5 else "")
        raise NotABump(f"it changes files release_cut does not generate: {shown}")
    base_version = zon_version(show(root, base, release_cut.ZON).decode("utf-8"))
    version = zon_version(show(root, candidate, release_cut.ZON).decode("utf-8"))
    if base_version.endswith("-dev") and release_cut.TAG_RE.match(version):
        kind = "cut"
        date = changelog_date(show(root, candidate, release_cut.CHANGELOG).decode("utf-8"), version)
    elif release_cut.TAG_RE.match(base_version) and version.endswith("-dev"):
        kind = "reopen"
        date = ""
    else:
        raise NotABump(f"{base_version} -> {version} is neither a cut nor a reopen")

    with tempfile.TemporaryDirectory() as scratch:
        tree = Path(scratch) / "base"
        git(root, "worktree", "add", "--detach", "--quiet", str(tree), base)
        try:
            try:
                release_cut.apply_version(tree, version)
                text = release_cut.read(tree, release_cut.CHANGELOG)
                if kind == "cut":
                    text = release_cut.rewrite_changelog(text, version, date)[0]
                else:
                    text = release_cut.ensure_unreleased(text)
                release_cut.write(tree, release_cut.CHANGELOG, text)
                repin(tree)
            except release_cut.CutError as exc:
                raise NotABump(f"release_cut cannot generate it from the base: {exc}") from None
            for rel in GENERATED:
                if (tree / rel).read_bytes() != show(root, candidate, rel):
                    raise NotABump(f"{rel} differs from what release_cut generates from the base")
        finally:
            subprocess.run(["git", "worktree", "remove", "--force", str(tree)], cwd=str(root), capture_output=True, check=False)
    return kind, version


def base_ci_state(repository: str, sha: str) -> str:
    """`success`, `pending`, or `failure` for the CI workflow's push runs of
    `sha`. A missing run counts as pending: right after a merge GitHub may not
    have created it yet, and the wait is bounded."""
    proc = subprocess.run(
        ["gh", "api", f"repos/{repository}/actions/workflows/{CI_WORKFLOW}/runs?head_sha={sha}&event=push&per_page=20"],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"gh api failed: {proc.stderr.decode('utf-8', 'replace').strip()}")
    runs = json.loads(proc.stdout.decode("utf-8")).get("workflow_runs") or []
    if any(run.get("status") == "completed" and run.get("conclusion") == "success" for run in runs):
        return "success"
    if not runs or any(run.get("status") != "completed" for run in runs):
        return "pending"
    return "failure"


def wait_for_base(
    query: Callable[[], str],
    wait_seconds: float,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
    poll_seconds: float = POLL_SECONDS,
) -> str:
    deadline = clock() + wait_seconds
    while True:
        state = query()
        if state != "pending" or clock() >= deadline:
            return state
        sleep(min(poll_seconds, max(0.0, deadline - clock())))


def decide(
    root: Path,
    base: str,
    candidate: str,
    query: Callable[[str], str],
    wait_seconds: float,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
    repin: Callable[[Path], None] = release_cut.repin_fingerprint,
) -> Tuple[bool, str]:
    try:
        kind, version = verify_bump(root, base, candidate, repin)
    except NotABump as exc:
        return False, f"full path: {exc}"
    base_sha = git(root, "rev-parse", base).decode("utf-8").strip()
    state = wait_for_base(lambda: query(base_sha), wait_seconds, sleep, clock)
    if state != "success":
        return False, f"full path: the {kind} to {version} is a generated bump, but CI on its base {base_sha[:12]} is {state}"
    return True, f"fast path: the {kind} to {version} adds only release_cut's generated files to {base_sha[:12]}, whose full CI passed on main"


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--github-output")
    parser.add_argument("--wait-seconds", type=float, default=2700)
    parser.add_argument("--repo-root", default=str(ROOT))
    args = parser.parse_args(argv)
    try:
        fast, reason = decide(
            Path(args.repo_root),
            args.base,
            args.candidate,
            lambda sha: base_ci_state(args.repository, sha),
            args.wait_seconds,
        )
    except Exception as exc:  # any doubt is the full path, never a red job
        fast, reason = False, f"full path: the fast-path check failed: {exc}"
    reason = " ".join(reason.split())
    print(reason)
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.write(f"fast={'true' if fast else 'false'}\nreason={reason}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
