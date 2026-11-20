"""scripts/ci_pool_plan.py and its wiring in ci.yml (doc/CI_DESIGN.md §6): the
macOS and Windows gates try their self-hosted VM pool first and fall back to
the hosted legs, and the required `Gates (<OS>)` checks never wait on a pool."""
from __future__ import annotations

import io
import json
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import ci_pool_plan as plan  # noqa: E402

NOW = 1_800_000_000.0
MACOS, WINDOWS = plan.PLATFORMS["macos"], plan.PLATFORMS["windows"]
ON = plan.Switch(self_hosted=True, label="metacodes-macos-vm", slots=2, pickup_timeout_minutes=5,
                 zig_build_jobs=8, timeout_minutes=60)
LABEL = ON.label
# ci.yml's job ids per platform.
JOBS = {"macos": ("gates-macos", "gates-macos-vm", "gates-macos-watch", "gates-macos-result", "Gates (macOS)"),
        "windows": ("windows-gates", "windows-gates-vm", "windows-gates-watch", "gates-windows-result",
                    "Gates (Windows)")}


def iso(when: float) -> str:
    return datetime.fromtimestamp(when, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def job(status: str, created: float = NOW - 30, labels=(LABEL,), name: str = MACOS.pool_job,
        conclusion: str = "") -> dict:
    return {"name": name, "status": status, "labels": list(labels), "created_at": iso(created),
            "conclusion": conclusion or None}


def decide(pool=plan.Occupancy(0, 0, 0.0), switch=ON, **kwargs):
    values = dict(fast_path="false", suites="true", warm_cache="false", pool=pool, member_pr=True)
    values.update(kwargs)
    return plan.decide(switch, **values)


SWITCHES = {name: {**limits.__dict__, "self_hosted": True} for name, limits in plan.FALLBACK_LIMITS.items()}


class SwitchTest(unittest.TestCase):
    def test_the_committed_switch_is_valid(self) -> None:
        switches = plan.load_switches(ROOT / plan.SWITCH)
        self.assertEqual(set(switches), {"macos", "windows"})
        self.assertEqual(switches["macos"].label, "metacodes-macos-vm")
        self.assertEqual(switches["windows"].label, "metacodes-windows-vm")
        self.assertLessEqual(switches["macos"].slots, 2)  # two macOS guests per Mac (doc/VM_POOLS.md)

    def test_a_bad_switch_is_refused(self) -> None:
        self.assertEqual(plan.parse_switches(SWITCHES)["macos"], ON)
        good = SWITCHES["macos"]
        for bad in ({k: v for k, v in good.items() if k != "slots"},
                    {**good, "extra": 1},
                    {**good, "slots": True},
                    {**good, "self_hosted": "true"},
                    {**good, "slots": 0},
                    {**good, "slots": 3},                 # three macOS guests on one Mac
                    {**good, "label": "self-hosted"},
                    {**good, "label": "macOS"},
                    {**good, "label": "bad label"},
                    []):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                plan.parse_switches({**SWITCHES, "macos": bad})
        self.assertEqual(plan.parse_switches({**SWITCHES, "windows": {**SWITCHES["windows"], "slots": 4}})["windows"].slots, 4)
        for bad in ({"macos": good},                                                          # a platform missing
                    {**SWITCHES, "linux": good},                                              # an unknown one
                    {**SWITCHES, "windows": {**SWITCHES["windows"], "label": good["label"]}}):  # a shared label
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                plan.parse_switches(bad)


class OccupancyTest(unittest.TestCase):
    def test_only_the_pools_jobs_that_hold_or_wait_for_a_vm_count(self) -> None:
        jobs = [job("in_progress"), job("queued", created=NOW - 400), job("queued", created=NOW - 100),
                job("completed"), job("in_progress", labels=("macos-latest",)), job("waiting"),
                job("in_progress", labels=("metacodes-windows-vm",))]
        self.assertEqual(plan.occupancy(jobs, LABEL, NOW), plan.Occupancy(1, 2, 400.0))
        self.assertEqual(plan.occupancy(jobs, "metacodes-windows-vm", NOW), plan.Occupancy(1, 0, 0.0))
        self.assertEqual(plan.occupancy([], LABEL, NOW), plan.Occupancy(0, 0, 0.0))


class DecideTest(unittest.TestCase):
    def test_a_free_slot_takes_the_gates(self) -> None:
        self.assertEqual(decide()[0], "self-hosted")
        self.assertEqual(decide(plan.Occupancy(1, 0, 0.0))[0], "self-hosted")

    def test_every_doubt_and_every_cheap_run_is_hosted(self) -> None:
        cases = {
            "switched off": decide(switch=plan.FALLBACK_LIMITS["macos"]),
            "no switch": plan.decide(None, fast_path="", suites="", warm_cache="", pool=None, member_pr=True,
                                     doubt="bad json"),
            "not a member's pull request": decide(member_pr=False, author="someone is CONTRIBUTOR"),
            "release fast path": decide(fast_path="true"),
            "documentation only": decide(suites="false"),
            "unknown occupancy": decide(pool=None, doubt="HTTP 500"),
            "full": decide(plan.Occupancy(2, 0, 0.0)),
            "full with a waiter": decide(plan.Occupancy(1, 1, 10.0)),
        }
        for case, (mode, reason) in cases.items():
            with self.subTest(case=case):
                self.assertEqual(mode, "hosted", reason)
                self.assertTrue(reason.startswith("hosted: "))

    def test_a_pool_that_stopped_taking_jobs_is_avoided(self) -> None:
        mode, reason = decide(plan.Occupancy(0, 1, 6 * 60.0))
        self.assertEqual(mode, "hosted")
        self.assertIn("may be down", reason)
        self.assertEqual(decide(plan.Occupancy(0, 1, 60.0))[0], "self-hosted")

    def test_mains_warm_run_fills_both_cache_lines(self) -> None:
        self.assertEqual(decide(warm_cache="true", pool=None)[0], "both")
        self.assertEqual(decide(warm_cache="true", switch=plan.FALLBACK_LIMITS["macos"])[0], "hosted")
        self.assertEqual(decide(warm_cache="true", pool=None, member_pr=False)[0], "both")

    def test_only_organization_members_pull_requests_go_self_hosted(self) -> None:
        for event, association, member in (("pull_request", "MEMBER", True),
                                           ("pull_request", "OWNER", True),
                                           ("pull_request", "COLLABORATOR", True),  # a private member
                                           ("pull_request", "CONTRIBUTOR", False),
                                           ("pull_request", "FIRST_TIME_CONTRIBUTOR", False),
                                           ("pull_request", "NONE", False),
                                           ("pull_request", "", False),
                                           ("pull_request_target", "MEMBER", False),
                                           ("merge_group", "", False),
                                           ("workflow_dispatch", "", False)):
            with self.subTest(event=event, association=association):
                self.assertEqual(plan.is_member_pr(event, association), member)
        mode, reason = decide(member_pr=False, author="stranger is CONTRIBUTOR")
        self.assertEqual(mode, "hosted")
        self.assertIn("stranger is CONTRIBUTOR", reason)


class WatchTest(unittest.TestCase):
    TIMEOUT = 300

    def step(self, jobs, now=NOW, since=NOW - 10, name=MACOS.pool_job):
        return plan.watch_step(jobs, since, now, self.TIMEOUT, name)

    def test_a_vm_that_takes_the_job_is_followed_to_its_end(self) -> None:
        self.assertEqual(self.step([job("queued")])[0], "wait")
        self.assertEqual(self.step([job("in_progress", created=NOW - 3600)])[0], "wait")
        self.assertEqual(self.step([job("completed", conclusion="success")]), ("done", "success"))
        self.assertEqual(self.step([job("completed", conclusion="failure")]), ("done", "failure"))

    def test_no_vm_within_the_pickup_timeout_falls_back(self) -> None:
        self.assertEqual(self.step([job("queued", created=NOW - 301)])[0], "fallback")
        self.assertEqual(self.step([], since=NOW - 301)[0], "fallback")
        # Another platform's pool job is not this one.
        self.assertEqual(self.step([job("queued", name=WINDOWS.pool_job)], since=NOW - 301)[0], "fallback")
        self.assertEqual(self.step([], since=NOW - 30)[0], "wait")


class StandDownTest(unittest.TestCase):
    def test_only_a_finished_watch_means_the_hosted_legs_took_over(self) -> None:
        for platform in plan.PLATFORMS.values():
            with self.subTest(platform=platform.name):
                self.assertTrue(plan.should_stand_down([job("completed", name=platform.watch_job)], platform.watch_job))
                self.assertFalse(plan.should_stand_down([job("in_progress", name=platform.watch_job)], platform.watch_job))
                self.assertFalse(plan.should_stand_down([], platform.watch_job))
        other = plan.PLATFORMS["windows"].watch_job
        self.assertFalse(plan.should_stand_down([job("completed", name=other)], MACOS.watch_job))


def needs(platform, mode="", plan_result="success", hosted="", watch="", fallback="", vm=""):
    value = {plan.PLAN_JOB: {"result": plan_result, "outputs": {f"{platform.name}_mode": mode} if mode else {}},
             platform.hosted_id: {"result": hosted, "outputs": {}},
             platform.watch_id: {"result": watch, "outputs": {}}}
    if fallback or vm:
        value[platform.watch_id]["outputs"] = {"fallback": fallback, "vm_result": vm}
    return value


class VerdictTest(unittest.TestCase):
    def test_the_gates_pass_where_they_ran(self) -> None:
        for platform in plan.PLATFORMS.values():
            def n(*args, **kwargs):
                return needs(platform, *args, **kwargs)

            cases = [
                (n("hosted", hosted="success", watch="skipped"), True),
                (n("hosted", hosted="failure", watch="skipped"), False),
                (n("hosted", hosted="cancelled", watch="skipped"), False),
                (n(plan_result="failure", hosted="success", watch="skipped"), True),  # no plan: hosted ran
                (n(plan_result="failure", hosted="skipped", watch="skipped"), False),
                (n("self-hosted", hosted="skipped", watch="success", fallback="false", vm="success"), True),
                (n("self-hosted", hosted="skipped", watch="success", fallback="false", vm="failure"), False),
                (n("self-hosted", hosted="skipped", watch="cancelled"), False),
                (n("self-hosted", hosted="skipped", watch="failure", fallback="false", vm="success"), False),
                (n("self-hosted", hosted="success", watch="success", fallback="true"), True),
                (n("self-hosted", hosted="failure", watch="success", fallback="true"), False),
                (n("both", hosted="success", watch="success", fallback="false", vm="success"), True),
                (n("both", hosted="success", watch="success", fallback="true"), True),
                (n("both", hosted="failure", watch="success", fallback="false", vm="success"), False),
                (n("both", hosted="success", watch="success", fallback="false", vm="failure"), False),
                ({}, False),
            ]
            for value, passes in cases:
                with self.subTest(platform=platform.name, needs=value):
                    self.assertEqual(plan.verdict(value, platform)[0], passes, plan.verdict(value, platform)[1])
        # One platform's outputs never decide the other's check.
        self.assertFalse(plan.verdict(needs(MACOS, "self-hosted", hosted="skipped", watch="success",
                                            fallback="false", vm="success"), WINDOWS)[0])


class FakeAPI:
    """urllib.request.urlopen over a dict of path -> JSON (or an exception)."""

    def __init__(self, routes):
        self.routes, self.seen = routes, []

    def __call__(self, request, timeout=None):
        path = request.full_url.split("/repos/o/r/", 1)[1]
        self.seen.append((path, request.get_header("Authorization")))
        value = self.routes[path]
        if isinstance(value, list):
            value = value.pop(0) if len(value) > 1 else value[0]
        if isinstance(value, Exception):
            raise value
        return io.BytesIO(json.dumps(value).encode())


ENV = {"GH_TOKEN": "t", "GITHUB_REPOSITORY": "o/r", "GITHUB_RUN_ID": "99", "GITHUB_RUN_ATTEMPT": "2",
       "GITHUB_API_URL": "https://api.example", "GITHUB_EVENT_NAME": "pull_request",
       "AUTHOR_ASSOCIATION": "MEMBER", "PR_AUTHOR": "member"}
ATTEMPT_JOBS = "actions/runs/99/attempts/2/jobs?per_page=100"


class CommandTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.output = self.tmp / "out"
        self.switch = self.tmp / "switch.json"
        self.switch.write_text(json.dumps({**SWITCHES, "windows": {**SWITCHES["windows"], "self_hosted": False}}),
                               encoding="utf-8")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def outputs(self) -> dict:
        return dict(line.split("=", 1) for line in self.output.read_text(encoding="utf-8").splitlines())

    def run_main(self, argv, api=None, env=None, **kwargs):
        with mock.patch("urllib.request.urlopen", api or FakeAPI({})), redirect_stdout(io.StringIO()):
            return plan.main(argv, env={**ENV, **(env or {})}, **kwargs)

    def plan_routes(self, jobs_of_other_run):
        return {
            "actions/runs?status=queued&per_page=100": {"workflow_runs": []},
            "actions/runs?status=in_progress&per_page=100": {"workflow_runs": [
                {"id": 99, "path": ".github/workflows/ci.yml"},       # this run: skipped
                {"id": 5, "path": ".github/workflows/ci.yml"},
                {"id": 6, "path": ".github/workflows/release.yml"},   # another workflow: skipped
            ]},
            "actions/runs/5/jobs?per_page=100": {"jobs": jobs_of_other_run},
        }

    def plan(self, api=None, env=None):
        return self.run_main(["plan", "--switch", str(self.switch), "--github-output", str(self.output)],
                             api, env=env, now=lambda: NOW)

    def test_plan_decides_each_platform_and_writes_every_output(self) -> None:
        api = FakeAPI(self.plan_routes([job("in_progress")]))
        self.assertEqual(self.plan(api, env={"FAST_PATH": "false", "SUITES": "true"}), 0)
        got = self.outputs()
        self.assertEqual((got["macos_mode"], got["windows_mode"]), ("self-hosted", "hosted"))
        self.assertEqual((got["macos_label"], got["macos_zig_build_jobs"], got["macos_timeout_minutes"],
                          got["macos_pickup_timeout_minutes"]), ("metacodes-macos-vm", "8", "60", "5"))
        self.assertEqual(got["windows_label"], "metacodes-windows-vm")
        self.assertIn("switched off", got["windows_reason"])
        paths = [path for path, _ in api.seen]
        self.assertNotIn("actions/runs/99/jobs?per_page=100", paths)
        self.assertNotIn("actions/runs/6/jobs?per_page=100", paths)
        self.assertTrue(all(auth == "Bearer t" for _, auth in api.seen))

    def test_plan_reads_nothing_while_every_pool_is_off(self) -> None:
        self.switch.write_text(json.dumps({name: {**v, "self_hosted": False} for name, v in SWITCHES.items()}),
                               encoding="utf-8")
        api = FakeAPI({})
        self.plan(api)
        self.assertEqual(api.seen, [])
        self.assertEqual((self.outputs()["macos_mode"], self.outputs()["windows_mode"]), ("hosted", "hosted"))

    def test_plan_keeps_other_authors_and_events_on_hosted_runners_without_reading_github(self) -> None:
        for env in ({"AUTHOR_ASSOCIATION": "CONTRIBUTOR", "PR_AUTHOR": "stranger"},
                    {"AUTHOR_ASSOCIATION": "NONE"},
                    {"GITHUB_EVENT_NAME": "merge_group", "AUTHOR_ASSOCIATION": ""}):
            with self.subTest(env=env):
                api = FakeAPI({})
                self.plan(api, env={"FAST_PATH": "false", "SUITES": "true", **env})
                self.assertEqual(api.seen, [])
                got = self.outputs()
                self.assertEqual((got["macos_mode"], got["windows_mode"]), ("hosted", "hosted"))
                self.assertIn("external contributor", got["macos_reason"])
                self.output.unlink()
        self.plan(FakeAPI({}), env={"AUTHOR_ASSOCIATION": "CONTRIBUTOR", "PR_AUTHOR": "stranger"})
        self.assertIn("stranger is CONTRIBUTOR", self.outputs()["macos_reason"])

    def test_plan_falls_back_to_hosted_on_a_full_pool_or_any_doubt(self) -> None:
        self.plan(FakeAPI(self.plan_routes([job("in_progress"), job("in_progress")])))
        self.assertEqual(self.outputs()["macos_mode"], "hosted")
        self.output.unlink()
        self.assertEqual(self.plan(FakeAPI({"actions/runs?status=queued&per_page=100": OSError("network down")})), 0)
        self.assertEqual(self.outputs()["macos_mode"], "hosted")
        self.assertIn("network down", self.outputs()["macos_reason"])
        self.output.unlink()
        self.switch.write_text("{not json", encoding="utf-8")
        self.plan()
        got = self.outputs()
        self.assertEqual((got["macos_mode"], got["windows_mode"]), ("hosted", "hosted"))
        self.assertEqual(got["windows_label"], plan.FALLBACK_LIMITS["windows"].label)  # every output stays defined

    def test_watch_follows_a_taken_job_to_its_end(self) -> None:
        api = FakeAPI({ATTEMPT_JOBS: [{"jobs": [job("queued", name=WINDOWS.pool_job)]},
                                      {"jobs": [job("in_progress", name=WINDOWS.pool_job)]},
                                      {"jobs": [job("completed", name=WINDOWS.pool_job, conclusion="success")]}]})
        clock = iter(NOW + 20 * i for i in range(100))
        self.run_main(["watch", "--platform", "windows", "--pickup-timeout-minutes", "5",
                       "--github-output", str(self.output)], api, now=lambda: next(clock), sleep=lambda _: None)
        self.assertEqual(self.outputs(), {"fallback": "false", "vm_result": "success"})

    def test_watch_hands_over_when_no_vm_comes_or_github_cannot_be_read(self) -> None:
        clock = iter(NOW + 60 * i for i in range(100))
        self.run_main(["watch", "--platform", "macos", "--pickup-timeout-minutes", "5", "--github-output",
                       str(self.output)], FakeAPI({ATTEMPT_JOBS: [{"jobs": [job("queued", created=NOW)]}]}),
                      now=lambda: next(clock), sleep=lambda _: None)
        self.assertEqual(self.outputs()["fallback"], "true")
        self.output.unlink()
        self.run_main(["watch", "--platform", "macos", "--pickup-timeout-minutes", "5", "--github-output",
                       str(self.output)], FakeAPI({ATTEMPT_JOBS: [OSError("timeout")]}), now=lambda: NOW,
                      sleep=lambda _: None)
        self.assertEqual(self.outputs()["fallback"], "true")

    def test_stand_down_sets_fast_path(self) -> None:
        for platform in plan.PLATFORMS.values():
            for watch_status, release_fast_path, expected in (("completed", "false", "true"),
                                                              ("in_progress", "false", "false"),
                                                              ("in_progress", "true", "true")):
                with self.subTest(platform=platform.name, watch=watch_status, fast=release_fast_path):
                    api = FakeAPI({ATTEMPT_JOBS: {"jobs": [job(watch_status, name=platform.watch_job)]}})
                    env_file = self.tmp / f"env-{platform.name}-{watch_status}-{release_fast_path}"
                    self.run_main(["stand-down", "--platform", platform.name, "--github-env", str(env_file)], api,
                                  env={"RELEASE_FAST_PATH": release_fast_path})
                    self.assertEqual(env_file.read_text(encoding="utf-8"), f"FAST_PATH={expected}\n")

    def test_verdict_exits_with_the_check(self) -> None:
        passing = needs(WINDOWS, "hosted", hosted="success", watch="skipped")
        self.assertEqual(self.run_main(["verdict", "--platform", "windows"], env={"NEEDS": json.dumps(passing)}), 0)
        self.assertEqual(self.run_main(["verdict", "--platform", "macos"], env={"NEEDS": json.dumps(passing)}), 1)
        self.assertEqual(self.run_main(["verdict", "--platform", "windows"], env={"NEEDS": "{}"}), 1)


def load(name: str) -> dict:
    try:
        import yaml
    except ImportError:  # requirements-dev.txt
        raise unittest.SkipTest("PyYAML is not installed")
    return yaml.safe_load((ROOT / ".github" / "workflows" / name).read_text(encoding="utf-8"))


class WorkflowTest(unittest.TestCase):
    def setUp(self) -> None:
        self.workflow = load("ci.yml")
        self.jobs = self.workflow["jobs"]

    def test_the_plan_job_decides_both_platforms(self) -> None:
        spec = self.jobs[plan.PLAN_JOB]
        self.assertEqual(spec["needs"], ["release-fast-path", "scope"])
        self.assertEqual(spec["if"], "${{ !cancelled() }}")
        step = next(s for s in spec["steps"] if s.get("id") == "plan")
        self.assertTrue(step["run"].startswith("python3 scripts/ci_pool_plan.py plan "))
        self.assertEqual(step["env"]["FAST_PATH"], "${{ needs.release-fast-path.outputs.fast }}")
        self.assertEqual(step["env"]["SUITES"], "${{ needs.scope.outputs.suites }}")
        self.assertEqual(step["env"]["AUTHOR_ASSOCIATION"], "${{ github.event.pull_request.author_association }}")
        for platform in plan.PLATFORMS:
            for name in ("mode", "label", "zig_build_jobs", "timeout_minutes", "pickup_timeout_minutes", "reason"):
                key = f"{platform}_{name}"
                self.assertEqual(spec["outputs"][key], "${{ steps.plan.outputs.%s }}" % key)
        self.assertEqual(self.workflow["permissions"]["actions"], "read")

    def test_each_pool_job_is_every_hosted_leg_in_one(self) -> None:
        for name, (hosted_id, pool_id, watch_id, _, _) in JOBS.items():
            with self.subTest(platform=name):
                pool, hosted = self.jobs[pool_id], self.jobs[hosted_id]
                self.assertEqual(pool["steps"], hosted["steps"])
                self.assertEqual(pool["runs-on"], "${{ needs.runner-plan.outputs.%s_label }}" % name)
                legs = pool["strategy"]["matrix"]["include"]
                self.assertEqual(len(legs), 1)
                flags = {key for leg in hosted["strategy"]["matrix"]["include"] for key, value in leg.items() if value is True}
                self.assertEqual({key for key, value in legs[0].items() if value is True}, flags)
                # The name the watch follows.
                self.assertEqual(pool["name"].replace("${{ matrix.leg }}", legs[0]["leg"]), plan.PLATFORMS[name].pool_job)
                self.assertNotIn("FAST_PATH", pool["env"])  # the stand-down step sets it
                self.assertEqual(pool["env"]["POOL_JOB"], "true")
                self.assertEqual(pool["env"]["RELEASE_FAST_PATH"], "${{ needs.release-fast-path.outputs.fast }}")
                self.assertEqual(pool["env"]["ZIG_BUILD_JOBS"], "${{ needs.runner-plan.outputs.%s_zig_build_jobs }}" % name)
                self.assertEqual(pool["timeout-minutes"],
                                 "${{ fromJSON(needs.runner-plan.outputs.%s_timeout_minutes) }}" % name)
                self.assertIn(f"needs.runner-plan.outputs.{name}_mode == 'self-hosted'", pool["if"])
                self.assertIn(f"needs.runner-plan.outputs.{name}_mode == 'both'", pool["if"])
                self.assertEqual(self.jobs[watch_id]["if"], pool["if"])

    def test_the_stand_down_step_follows_the_checkout_on_the_pool_job_only(self) -> None:
        for name, (hosted_id, _, _, _, _) in JOBS.items():
            with self.subTest(platform=name):
                steps = self.jobs[hosted_id]["steps"]
                index = next(i for i, s in enumerate(steps) if s.get("name") == "Stand down if the hosted legs took over")
                self.assertTrue(steps[index - 1].get("uses", "").startswith("actions/checkout@"))
                self.assertTrue(steps[index]["if"].startswith("env.POOL_JOB == 'true'"))
                self.assertIn(f"ci_pool_plan.py stand-down --platform {name}", steps[index]["run"])
                # Every later step that does work reads FAST_PATH.
                for step in steps[index + 1:]:
                    if "FAST_PATH" in step.get("if", "") or step.get("name") == "Version state gate and release rehearsal":
                        continue
                    self.fail(f"{step.get('name') or step.get('uses')} runs even when the pool job stands down")

    def test_each_watch_follows_its_pool_job(self) -> None:
        for name, (_, _, watch_id, _, _) in JOBS.items():
            with self.subTest(platform=name):
                spec = self.jobs[watch_id]
                self.assertEqual(spec["name"], plan.PLATFORMS[name].watch_job)
                self.assertEqual(spec["runs-on"], "ubuntu-latest")
                step = next(s for s in spec["steps"] if s.get("id") == "watch")
                self.assertIn(f"watch --platform {name} ", step["run"])
                self.assertEqual(spec["outputs"], {"fallback": "${{ steps.watch.outputs.fallback }}",
                                                   "vm_result": "${{ steps.watch.outputs.vm_result }}"})
                # The watch outlives the pool job's own limit.
                limit = plan.load_switches(ROOT / plan.SWITCH)[name]
                self.assertGreater(spec["timeout-minutes"], limit.timeout_minutes + limit.pickup_timeout_minutes)

    def test_the_hosted_legs_run_unless_a_vm_took_the_gates(self) -> None:
        for name, (hosted_id, _, watch_id, _, _) in JOBS.items():
            with self.subTest(platform=name):
                spec = self.jobs[hosted_id]
                self.assertEqual(sorted(spec["needs"]), sorted([watch_id, "runner-plan", "release-fast-path", "scope"]))
                self.assertEqual(spec["if"], "${{ !cancelled() && (needs.runner-plan.outputs.%s_mode != 'self-hosted' "
                                             "|| needs.%s.outputs.fallback == 'true') }}" % (name, watch_id))

    def test_the_required_checks_never_wait_for_a_pool_job(self) -> None:
        for name, (hosted_id, _, watch_id, result_id, check) in JOBS.items():
            with self.subTest(platform=name):
                spec = self.jobs[result_id]
                self.assertEqual(spec["name"], check)
                self.assertEqual(spec["needs"], ["runner-plan", watch_id, hosted_id])
                self.assertEqual(spec["if"], "${{ always() }}")
                self.assertEqual(spec["steps"][-1]["run"], f"python3 scripts/ci_pool_plan.py verdict --platform {name}")
                self.assertEqual(spec["steps"][-1]["env"]["NEEDS"], "${{ toJSON(needs) }}")
                evidence = self.jobs["full-pr-evidence"]["needs"]
                self.assertIn(result_id, evidence)
                self.assertNotIn(hosted_id, evidence)

    def test_only_the_pool_jobs_run_on_a_self_hosted_runner(self) -> None:
        labels = {switch.label for switch in plan.load_switches(ROOT / plan.SWITCH).values()}
        pool_jobs = {("ci.yml", "gates-macos-vm"), ("ci.yml", "windows-gates-vm")}
        for workflow_name in ("ci.yml", "release.yml", "release-tag.yml", "rule-control.yml", "agentcore-windows.yml"):
            workflow = self.workflow if workflow_name == "ci.yml" else load(workflow_name)
            for job_id, spec in workflow["jobs"].items():
                with self.subTest(workflow=workflow_name, job=job_id):
                    runs_on = json.dumps(spec.get("runs-on", ""))
                    self.assertNotIn("self-hosted", runs_on)
                    for label in labels:
                        self.assertNotIn(label, json.dumps(spec))
                    if (workflow_name, job_id) in pool_jobs:
                        self.assertIn("needs.runner-plan.outputs.", runs_on)
                    else:
                        self.assertNotIn("_label", runs_on)

    def test_the_conditions_name_only_real_modes(self) -> None:
        text = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        modes = re.findall(r"outputs\.(?:macos|windows)_mode [!=]= '([^']+)'", text)
        self.assertTrue(modes)
        for mode in modes:
            self.assertIn(mode, plan.MODES)


if __name__ == "__main__":
    unittest.main()
