#!/usr/bin/env python3
"""Where CI's macOS and Windows gates run: each platform's self-hosted
runner first, GitHub-hosted runners when it is off, full or not taking jobs
(doc/CI_DESIGN.md §6). Only pull requests opened by organization members
(and main's warm run) may use a self-hosted runner.

A self-hosted runner runs a platform's gates as one job, `Gates (<OS>) /
all`: on macOS the runner on the Mac Studio's `ci-host` account
(doc/CI_DESIGN.md §6); Windows stays hosted until AIPC has one. Hosted
runners run the gates as that platform's legs. Every
command here runs with the run's own read-only GITHUB_TOKEN (`actions:
read`), which a fork's pull request gets too; vars and secrets it does not
get, so the switch is a file in the tree: `.github/runner-pools.json`, one
entry per platform.

Commands, one per ci.yml job:

- `plan` (`runner-plan`): reads the switch, the pull request author's
  association and this repository's queued and running CI jobs, and writes, per platform, `<platform>_mode`
  (`self-hosted`, `hosted` or `both`) plus the pool's label, build jobs and
  limits. Any doubt is `hosted`; it always exits 0.
- `watch --platform P` (`<P> pool watch`): follows the run's pool job. A VM
  that takes it within the pickup timeout is followed to the end
  (`vm_result`); otherwise `fallback=true` hands the gates to the hosted legs.
- `stand-down --platform P` (the pool job's step after checkout): if the
  watch already finished, the hosted legs took over and the pool job reached
  a VM late, so it sets FAST_PATH=true and every later step skips;
  otherwise it carries the release fast path decision into FAST_PATH.
- `verdict --platform P` (the required `Gates (<OS>)` check): passes when the
  gates passed where they ran. It never waits for the pool job, which a pool
  that is down would keep queued for GitHub's 24 hours.

Python 3.9, stdlib only. Tests: scripts/tests/test_ci_pool_plan.py.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence, Tuple

ROOT = Path(__file__).resolve().parents[1]
SWITCH = ".github/runner-pools.json"
PLAN_JOB = "runner-plan"
# Labels every runner of a kind carries: a pool label must single its pool out.
GENERIC_LABELS = {"self-hosted", "macos", "linux", "windows", "x64", "arm64", "arm"}
LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
# A job of another run that holds or waits for a pool VM.
RUNNING = {"in_progress"}
WAITING = {"queued", "pending", "requested"}
MODES = ("self-hosted", "hosted", "both")
# A pull request's `author_association` that may use a self-hosted runner:
# organization members only. GitHub reports a member whose membership is
# private as COLLABORATOR when they have direct access to the repository, and
# this repository has no outside collaborators (doc/CI_DESIGN.md §6), so
# COLLABORATOR counts as a member. A private member without direct access
# shows as CONTRIBUTOR and stays on hosted runners until the membership is
# made public.
MEMBER_ASSOCIATIONS = {"OWNER", "MEMBER", "COLLABORATOR"}
POLL_SECONDS = 20
API_ERRORS_BEFORE_FALLBACK = 6


@dataclass(frozen=True)
class Platform:
    name: str
    pool_job: str     # the pool job's check name
    watch_job: str    # the watch job's check name
    watch_id: str     # the watch job's id in ci.yml
    hosted_id: str    # the hosted legs' job id in ci.yml
    max_slots: int    # macOS: two guests per Mac (Virtualization.framework)


PLATFORMS: Dict[str, Platform] = {
    "macos": Platform("macos", "Gates (macOS) / all", "macOS pool watch", "gates-macos-watch", "gates-macos", 2),
    "windows": Platform("windows", "Gates (Windows) / all", "Windows pool watch", "windows-gates-watch",
                        "windows-gates", 8),
}


@dataclass(frozen=True)
class Switch:
    self_hosted: bool
    label: str
    slots: int
    pickup_timeout_minutes: int
    zig_build_jobs: int
    timeout_minutes: int


SWITCH_FIELDS = {
    "self_hosted": (bool, None),
    "label": (str, None),
    "slots": (int, (1, 16)),
    "pickup_timeout_minutes": (int, (1, 60)),
    "zig_build_jobs": (int, (1, 64)),
    "timeout_minutes": (int, (10, 360)),
}


def parse_switch(value: object, platform: Platform) -> Switch:
    """One platform's entry, every field present, typed and in range."""
    if not isinstance(value, dict):
        raise ValueError(f"{platform.name}: the switch is not a JSON object")
    if set(value) != set(SWITCH_FIELDS):
        missing = sorted(set(SWITCH_FIELDS) - set(value))
        extra = sorted(set(value) - set(SWITCH_FIELDS))
        raise ValueError(f"{platform.name}: switch fields differ: missing {missing}, unknown {extra}")
    for name, (kind, bounds) in SWITCH_FIELDS.items():
        field = value[name]
        # bool is an int subclass: a number field must not accept true.
        if not isinstance(field, kind) or (kind is int and isinstance(field, bool)):
            raise ValueError(f"{platform.name}: {name} must be a {kind.__name__}")
        if bounds and not bounds[0] <= field <= bounds[1]:
            raise ValueError(f"{platform.name}: {name} must be within {bounds[0]}..{bounds[1]}")
    if value["slots"] > platform.max_slots:
        raise ValueError(f"{platform.name}: at most {platform.max_slots} slots")
    if not LABEL_RE.match(value["label"]) or value["label"].lower() in GENERIC_LABELS:
        raise ValueError(f"{platform.name}: label {value['label']!r} must be a dedicated runner label")
    return Switch(**value)


def parse_switches(value: object) -> Dict[str, Switch]:
    """Every platform's entry; one pool's label never selects the other's."""
    if not isinstance(value, dict) or set(value) != set(PLATFORMS):
        raise ValueError(f"the switch must hold exactly {sorted(PLATFORMS)}")
    switches = {name: parse_switch(value[name], platform) for name, platform in PLATFORMS.items()}
    if len({switch.label for switch in switches.values()}) != len(switches):
        raise ValueError("each pool needs a label of its own")
    return switches


def load_switches(path: Path) -> Dict[str, Switch]:
    return parse_switches(json.loads(path.read_text(encoding="utf-8")))


FALLBACK_LIMITS = {
    "macos": Switch(False, "metacodes-macos-vm", 2, 5, 8, 60),
    "windows": Switch(False, "metacodes-windows-vm", 2, 5, 8, 75),
}


@dataclass(frozen=True)
class Occupancy:
    running: int
    waiting: int
    oldest_wait_seconds: float


def parse_time(value: Optional[str]) -> Optional[float]:
    if not value:
        return None
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()


def occupancy(jobs: Sequence[dict], label: str, now: float) -> Occupancy:
    """How many pool jobs of other runs hold a VM or wait for one."""
    running = waiting = 0
    oldest = 0.0
    for job in jobs:
        if label not in (job.get("labels") or []):
            continue
        status = job.get("status")
        if status in RUNNING:
            running += 1
        elif status in WAITING:
            waiting += 1
            created = parse_time(job.get("created_at"))
            if created is not None:
                oldest = max(oldest, now - created)
    return Occupancy(running, waiting, oldest)


def is_member_pr(event: str, association: str) -> bool:
    """A pull request opened by a member of the organization."""
    return event == "pull_request" and association in MEMBER_ASSOCIATIONS


def decide(switch: Optional[Switch], *, fast_path: str, suites: str, warm_cache: str,
           pool: Optional[Occupancy], member_pr: bool, author: str = "",
           doubt: str = "") -> Tuple[str, str]:
    """(mode, reason). Every doubt is `hosted`: hosted runners always exist."""
    if switch is None:
        return "hosted", f"hosted: no usable switch ({doubt})"
    if not switch.self_hosted:
        return "hosted", f"hosted: the pool is switched off in {SWITCH}"
    if fast_path == "true":
        return "hosted", "hosted: release fast path, the gates only check out"
    if suites == "false":
        return "hosted", "hosted: documentation-only change, the gates only check out"
    if warm_cache == "true":
        return "both", "both: main's warm run fills the pool's and the hosted legs' cache lines"
    if not member_pr:
        return "hosted", (f"hosted: external contributor; only organization members' pull requests use "
                          f"the self-hosted runner ({author or 'not a pull request'})")
    if pool is None:
        return "hosted", f"hosted: the pool's occupancy is unknown ({doubt})"
    if pool.running + pool.waiting >= switch.slots:
        return "hosted", (f"hosted: the pool is full ({pool.running} running, {pool.waiting} waiting, "
                          f"{switch.slots} slots)")
    if pool.waiting and pool.oldest_wait_seconds > switch.pickup_timeout_minutes * 60:
        return "hosted", (f"hosted: a pool job has waited {pool.oldest_wait_seconds / 60:.0f} min "
                          "for a VM; the pool may be down")
    free = switch.slots - pool.running - pool.waiting
    return "self-hosted", f"self-hosted: {free} of {switch.slots} slots free"


def watch_step(jobs: Sequence[dict], since: float, now: float, timeout_seconds: float,
               name: str) -> Tuple[str, str]:
    """One look at this run's pool job: ("wait" | "done" | "fallback", detail).
    A job a VM took is followed to its end; one that waited past the pickup
    timeout, or never appeared, falls back."""
    job = next((job for job in jobs if job.get("name") == name), None)
    if job is None:
        return ("fallback", "the pool job never appeared") if now - since > timeout_seconds else ("wait", "")
    status = job.get("status")
    if status == "completed":
        return "done", job.get("conclusion") or "failure"
    if status == "in_progress":
        return "wait", f"running on {job.get('runner_name') or 'a VM'}"
    queued = parse_time(job.get("created_at")) or since
    if now - queued > timeout_seconds:
        return "fallback", f"no VM took the pool job in {timeout_seconds / 60:.0f} min"
    return "wait", "queued"


def should_stand_down(jobs: Sequence[dict], watch: str) -> bool:
    """The watch finishes successfully before the pool job starts only when it fell back."""
    return any(
        job.get("name") == watch
        and job.get("status") == "completed"
        and job.get("conclusion") == "success"
        for job in jobs
    )


def can_recover_watch_failure(needs: Dict[str, dict], platform: Platform) -> bool:
    """True only when the watch failed without fallback or vm_result in a
    self-hosted or both run."""
    plan = needs.get(PLAN_JOB) or {}
    outputs = plan.get("outputs") or {}
    mode = outputs.get(f"{platform.name}_mode", "") if plan.get("result") == "success" else ""
    if mode not in ("self-hosted", "both"):
        return False
    watch = needs.get(platform.watch_id) or {}
    watched = watch.get("outputs") or {}
    return (
        watch.get("result") == "failure"
        and watched.get("fallback") != "true"
        and watched.get("vm_result", "") == ""
    )


def pool_job_passed_after_watch_failure(jobs: Sequence[dict], platform: Platform) -> Tuple[bool, str]:
    """When the watch failed without writing vm_result (e.g. lost hosted runner),
    verify via this attempt's jobs whether the pool job started before the watch
    ended and completed with success."""
    pool = next((job for job in jobs if job.get("name") == platform.pool_job), None)
    if pool is None:
        return False, "pool job missing"
    if pool.get("status") != "completed":
        return False, f"pool job {pool.get('status') or 'unknown'}"
    if pool.get("conclusion") != "success":
        return False, f"pool job {pool.get('conclusion') or 'unknown'}"
    watch = next((job for job in jobs if job.get("name") == platform.watch_job), None)
    if watch is None or watch.get("status") != "completed":
        return False, "watch job completion time unknown"
    try:
        pool_started = parse_time(pool.get("started_at"))
        watch_completed = parse_time(watch.get("completed_at"))
    except ValueError:
        return False, "job timestamps invalid"
    if pool_started is None or watch_completed is None:
        return False, "job timestamps missing"
    if pool_started >= watch_completed:
        return False, "pool job did not start before watch ended"
    return True, "pool job success (verified via GitHub API after watch failure)"


def verdict(needs: Dict[str, dict], platform: Platform,
            recovered_pool: Optional[Tuple[bool, str]] = None) -> Tuple[bool, str]:
    """The required `Gates (<OS>)` check over the plan, the watch and the
    hosted legs (never the pool job itself)."""
    plan = needs.get(PLAN_JOB) or {}
    outputs = plan.get("outputs") or {}
    mode = outputs.get(f"{platform.name}_mode", "") if plan.get("result") == "success" else ""
    hosted = (needs.get(platform.hosted_id) or {}).get("result", "")
    watch = needs.get(platform.watch_id) or {}
    watched = watch.get("outputs") or {}
    fallback = watched.get("fallback") == "true"
    vm = watched.get("vm_result", "")
    if mode == "self-hosted":
        if fallback:
            return hosted == "success", f"self-hosted, fell back to the hosted legs: {hosted or 'none'}"
        if watch.get("result") == "failure" and vm == "" and recovered_pool is not None:
            passed, detail = recovered_pool
            return passed, f"self-hosted: {detail}, watch failure"
        passed = watch.get("result") == "success" and vm == "success"
        return passed, f"self-hosted: pool job {vm or 'unknown'}, watch {watch.get('result') or 'none'}"
    if mode == "both":
        if not fallback and watch.get("result") == "failure" and vm == "" and recovered_pool is not None:
            pool_passed, detail = recovered_pool
            passed = hosted == "success" and pool_passed
            return passed, f"both: hosted legs {hosted or 'none'}, {detail}, watch failure"
        passed = hosted == "success" and (vm == "success" or fallback)
        return passed, f"both: hosted legs {hosted or 'none'}, pool job {vm or ('not taken' if fallback else 'unknown')}"
    return hosted == "success", f"hosted ({mode or 'no plan'}): hosted legs {hosted or 'none'}"


# ------------------------------------------------------------------ GitHub


class GitHub:
    def __init__(self, token: str, api: str, repository: str, opener: Optional[Callable] = None) -> None:
        self.token, self.api, self.repository, self.opener = token, api.rstrip("/"), repository, opener

    def get(self, path: str) -> dict:
        request = urllib.request.Request(f"{self.api}/repos/{self.repository}/{path}", headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {self.token}",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        with (self.opener or urllib.request.urlopen)(request, timeout=15) as response:
            return json.loads(response.read().decode("utf-8"))

    def other_runs_jobs(self, run_id: str, workflow_path: str) -> List[dict]:
        runs: Dict[int, dict] = {}
        for status in ("queued", "in_progress"):
            for run in self.get(f"actions/runs?status={status}&per_page=100").get("workflow_runs", []):
                runs[run["id"]] = run
        jobs: List[dict] = []
        for run in runs.values():
            if str(run["id"]) == str(run_id) or run.get("path", workflow_path) != workflow_path:
                continue
            jobs.extend(self.get(f"actions/runs/{run['id']}/jobs?per_page=100").get("jobs", []))
        return jobs

    def this_attempt_jobs(self, run_id: str, attempt: str) -> List[dict]:
        return self.get(f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100").get("jobs", [])


def github_from_env(env: Dict[str, str]) -> GitHub:
    return GitHub(env["GH_TOKEN"], env.get("GITHUB_API_URL", "https://api.github.com"), env["GITHUB_REPOSITORY"])


def write_lines(path: Optional[str], values: Dict[str, str]) -> None:
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        for key, value in values.items():
            handle.write(f"{key}={' '.join(str(value).split())}\n")


# ---------------------------------------------------------------- commands


def cmd_plan(args: argparse.Namespace, env: Dict[str, str], now: Callable[[], float]) -> int:
    switches: Dict[str, Switch] = {}
    jobs: Optional[List[dict]] = None
    doubt = ""
    association = env.get("AUTHOR_ASSOCIATION", "")
    member_pr = is_member_pr(env.get("GITHUB_EVENT_NAME", ""), association)
    author = f"{env.get('PR_AUTHOR') or 'the author'} is {association}" if association else ""
    try:
        switches = load_switches(Path(args.switch))
        # Nothing to read when no platform could go self-hosted.
        if any(switch.self_hosted for switch in switches.values()) and (member_pr or env.get("WARM_CACHE") == "true"):
            jobs = github_from_env(env).other_runs_jobs(env["GITHUB_RUN_ID"], args.workflow_path)
    except Exception as exc:  # any doubt is hosted, never a red job
        doubt = f"{type(exc).__name__}: {exc}"
    values: Dict[str, str] = {}
    summary = ["### Runner plan", ""]
    for name in PLATFORMS:
        switch = switches.get(name)
        pool = occupancy(jobs, switch.label, now()) if switch is not None and jobs is not None else None
        mode, reason = decide(switch, fast_path=env.get("FAST_PATH", ""), suites=env.get("SUITES", ""),
                              warm_cache=env.get("WARM_CACHE", ""), pool=pool, member_pr=member_pr,
                              author=author, doubt=doubt)
        # Without a usable switch the mode is hosted and the pool job never
        # runs; the defaults only keep every output defined.
        limits = switch or FALLBACK_LIMITS[name]
        values.update({f"{name}_mode": mode, f"{name}_reason": reason, f"{name}_label": limits.label,
                       f"{name}_zig_build_jobs": str(limits.zig_build_jobs),
                       f"{name}_timeout_minutes": str(limits.timeout_minutes),
                       f"{name}_pickup_timeout_minutes": str(limits.pickup_timeout_minutes)})
        print(f"{name}: {reason}")
        summary.append(f"- **{name}**: {mode}. {reason}")
    write_lines(args.github_output, values)
    if args.github_summary:
        with open(args.github_summary, "a", encoding="utf-8") as handle:
            handle.write("\n".join(summary) + "\n")
    return 0


def cmd_watch(args: argparse.Namespace, env: Dict[str, str], now: Callable[[], float],
              sleep: Callable[[float], None]) -> int:
    platform = PLATFORMS[args.platform]
    github = github_from_env(env)
    since, errors = now(), 0
    timeout = args.pickup_timeout_minutes * 60
    while True:
        try:
            jobs = github.this_attempt_jobs(env["GITHUB_RUN_ID"], env.get("GITHUB_RUN_ATTEMPT", "1"))
            errors = 0
        except (urllib.error.URLError, OSError, ValueError) as exc:
            errors += 1
            print(f"watch: GitHub API error {errors}: {exc}")
            if errors >= API_ERRORS_BEFORE_FALLBACK:
                write_lines(args.github_output, {"fallback": "true", "vm_result": ""})
                print("watch: falling back to the hosted legs after repeated API errors")
                return 0
            sleep(POLL_SECONDS)
            continue
        state, detail = watch_step(jobs, since, now(), timeout, platform.pool_job)
        if detail:
            print(f"watch: {state}: {detail}")
        if state == "done":
            write_lines(args.github_output, {"fallback": "false", "vm_result": detail})
            # Fail with the pool job so `gh run rerun --failed` reruns this
            # watch too; a passing watch would keep the old vm_result.
            return 0 if detail == "success" else 1
        if state == "fallback":
            write_lines(args.github_output, {"fallback": "true", "vm_result": ""})
            return 0
        sleep(POLL_SECONDS)


def cmd_stand_down(args: argparse.Namespace, env: Dict[str, str]) -> int:
    platform = PLATFORMS[args.platform]
    release_fast_path = env.get("RELEASE_FAST_PATH", "")
    try:
        jobs = github_from_env(env).this_attempt_jobs(env["GITHUB_RUN_ID"], env.get("GITHUB_RUN_ATTEMPT", "1"))
        stand_down = should_stand_down(jobs, platform.watch_job)
    except Exception as exc:  # unknown: do the work; the verdict decides what counts
        print(f"stand-down: could not read this run's jobs ({exc}); running the gates")
        stand_down = False
    if stand_down:
        print("stand-down: the hosted legs took over before a VM took this job; skipping every step")
    write_lines(args.github_env, {"FAST_PATH": "true" if stand_down else release_fast_path})
    return 0


def cmd_verdict(args: argparse.Namespace, env: Dict[str, str]) -> int:
    platform = PLATFORMS[args.platform]
    needs = json.loads(env.get("NEEDS") or "{}")
    recovered_pool: Optional[Tuple[bool, str]] = None
    if can_recover_watch_failure(needs, platform):
        try:
            jobs = github_from_env(env).this_attempt_jobs(
                env["GITHUB_RUN_ID"], env.get("GITHUB_RUN_ATTEMPT", "1")
            )
            recovered_pool = pool_job_passed_after_watch_failure(jobs, platform)
        except Exception as exc:
            recovered_pool = (False, f"pool job unknown (GitHub API lookup failed: {exc})")
    passed, reason = verdict(needs, platform, recovered_pool=recovered_pool)
    print(("pass: " if passed else "fail: ") + reason)
    return 0 if passed else 1


def main(argv: Optional[Sequence[str]] = None, env: Optional[Dict[str, str]] = None,
         now: Callable[[], float] = time.time, sleep: Callable[[float], None] = time.sleep) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    plan = commands.add_parser("plan")
    plan.add_argument("--switch", default=str(ROOT / SWITCH))
    plan.add_argument("--workflow-path", default=".github/workflows/ci.yml")
    plan.add_argument("--github-output")
    plan.add_argument("--github-summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    watch = commands.add_parser("watch")
    watch.add_argument("--platform", choices=sorted(PLATFORMS), required=True)
    watch.add_argument("--pickup-timeout-minutes", type=int, required=True)
    watch.add_argument("--github-output")
    stand = commands.add_parser("stand-down")
    stand.add_argument("--platform", choices=sorted(PLATFORMS), required=True)
    stand.add_argument("--github-env", required=True)
    judge = commands.add_parser("verdict")
    judge.add_argument("--platform", choices=sorted(PLATFORMS), required=True)
    args = parser.parse_args(argv)
    env = dict(os.environ if env is None else env)
    if args.command == "plan":
        return cmd_plan(args, env, now)
    if args.command == "watch":
        return cmd_watch(args, env, now, sleep)
    if args.command == "stand-down":
        return cmd_stand_down(args, env)
    return cmd_verdict(args, env)


if __name__ == "__main__":
    sys.exit(main())
