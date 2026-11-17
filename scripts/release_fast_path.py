#!/usr/bin/env python3
"""Decide whether a generated release/reopen bump may reuse full PR CI.

Both the generated-content check and exact-tree evidence are required.
Regenerating release_cut's files must reproduce the candidate byte for byte.
The base must be the merge commit of a PR whose successful ci.yml run
uploaded full-scope, non-fast-path evidence for that exact Git tree.
Main push runs and head-only status checks are not evidence. Missing or
expired artifacts, errors and all other doubts take the full path.

ci.yml passes HEAD^1 as the PR base; the legacy merge_group migration handler
uses its group base_sha. The optional evidence wait defaults to zero.
Python >= 3.9; doc/RELEASE_AUTOMATION_DESIGN.md section 3.
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
import agentcore_contract  # noqa: E402  (same directory, stdlib only)
import agentcore_release  # noqa: E402
import release_cut  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
GENERATED = (release_cut.ZON, release_cut.VERSION_ZIG, release_cut.CHANGELOG, release_cut.PROTOCOL, *agentcore_contract.GENERATED)
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


def sdk_changelog_date(root: Path, candidate: str, version: str) -> str:
    """The date of AgentCore's section in the candidate. A reuse does not use it,
    and a built release without the section regenerates to different bytes."""
    text = show(root, candidate, agentcore_contract.SDK_CHANGELOG).decode("utf-8")
    for line in text.splitlines():
        match = release_cut.RELEASE_HEADING_RE.match(line)
        if match and match.group(1) == version:
            return match.group(2)
    return ""


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

    sdk_version = show(root, candidate, agentcore_contract.SDK_VERSION).decode("utf-8").strip()
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
                if kind == "cut":
                    agentcore_release.apply_cut(tree, sdk_version, version, sdk_changelog_date(root, candidate, sdk_version))
                else:
                    agentcore_release.apply_reopen(tree, sdk_version)
                repin(tree)
            except release_cut.CutError as exc:
                raise NotABump(f"release_cut cannot generate it from the base: {exc}") from None
            for rel in GENERATED:
                if (tree / rel).read_bytes() != show(root, candidate, rel):
                    raise NotABump(f"{rel} differs from what release_cut generates from the base")
        finally:
            subprocess.run(["git", "worktree", "remove", "--force", str(tree)], cwd=str(root), capture_output=True, check=False)
    return kind, version


def github_json(path: str):
    proc = subprocess.run(["gh", "api", path], capture_output=True, check=True)
    return json.loads(proc.stdout)


def base_ci_state(repository: str, sha: str, tree: str) -> str:
    """Only a full PR run proving this exact merged tree is reusable.

    A green head check alone is insufficient: it does not identify the base
    used by the PR's synthetic merge. Main push CI is no longer required.
    Missing/expired evidence always takes the full path.
    """
    pending = False
    page = 1
    while True:
        pulls = github_json(f"repos/{repository}/commits/{sha}/pulls?per_page=100&page={page}")
        for pr in pulls:
            if (not pr.get("merged_at") or pr.get("merge_commit_sha") != sha
                    or pr["base"]["ref"] != "main" or pr["base"]["repo"]["full_name"] != repository):
                continue
            runs = github_json(f"repos/{repository}/actions/workflows/{CI_WORKFLOW}/runs?head_sha={pr['head']['sha']}&event=pull_request&per_page=100")["workflow_runs"]
            for run in runs:
                if (run.get("event") != "pull_request" or run.get("head_sha") != pr["head"]["sha"]):
                    continue
                if run.get("status") != "completed":
                    pending = True
                    continue
                if run.get("conclusion") != "success":
                    continue
                with tempfile.TemporaryDirectory(prefix="metacodes-ci-evidence-") as tmp:
                    proc = subprocess.run(["gh", "run", "download", str(run["id"]), "--repo", repository,
                                           "--name", "pr-ci-evidence", "--dir", tmp], capture_output=True, check=False)
                    if proc.returncode:
                        continue
                    try:
                        proof = json.loads((Path(tmp) / "pr-ci-evidence.json").read_text(encoding="utf-8"))
                    except (OSError, ValueError):
                        continue
                    if (proof.get("schema") == 1 and proof.get("repository") == repository
                            and proof.get("run_id") == run["id"] and proof.get("attempt") == run.get("run_attempt")
                            and proof.get("head") == pr["head"]["sha"] and proof.get("tree") == tree
                            and proof.get("scope") == "full"):
                        return "success"
        if len(pulls) < 100:
            break
        page += 1
    return "pending" if pending else "failure"


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
    return True, f"fast path: the {kind} to {version} adds only release_cut's generated files to {base_sha[:12]}, whose exact tree passed full PR CI"


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--github-output")
    parser.add_argument("--wait-seconds", type=float, default=0)
    parser.add_argument("--repo-root", default=str(ROOT))
    args = parser.parse_args(argv)
    try:
        fast, reason = decide(
            Path(args.repo_root),
            args.base,
            args.candidate,
            lambda sha: base_ci_state(args.repository, sha, git(Path(args.repo_root), "rev-parse", sha + "^{tree}").decode().strip()),
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
