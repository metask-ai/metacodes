"""scripts/ci_macos_plan.py and its wiring in ci.yml (doc/CI_DESIGN.md §6):
the macOS gates try the self-hosted VM pool first and fall back to the
hosted legs, and the required `Gates (macOS)` check never waits on the pool."""
from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import ci_macos_plan as plan  # noqa: E402

NOW = 1_800_000_000.0
ON = plan.Switch(self_hosted=True, label="metacodes-macos-vm", slots=2, pickup_timeout_minutes=5,
                 zig_build_jobs=8, timeout_minutes=60)
LABEL = ON.label


def iso(when: float) -> str:
    return datetime.fromtimestamp(when, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def job(status: str, created: float = NOW - 30, labels=(LABEL,), name: str = plan.POOL_JOB,
        conclusion: str = "") -> dict:
    return {"name": name, "status": status, "labels": list(labels), "created_at": iso(created),
            "conclusion": conclusion or None}


def decide(pool=plan.Occupancy(0, 0, 0.0), switch=ON, **kwargs):
    values = dict(fast_path="false", suites="true", warm_cache="false", pool=pool)
    values.update(kwargs)
    return plan.decide(switch, **values)


class SwitchTest(unittest.TestCase):
    def test_the_committed_switch_is_valid(self) -> None:
        switch = plan.load_switch(ROOT / plan.SWITCH)
        self.assertEqual(switch.label, "metacodes-macos-vm")
        self.assertLessEqual(switch.slots, 2)  # two macOS guests per Mac (doc/MACOS_VM_POOL.md)

    def test_a_bad_switch_is_refused(self) -> None:
        good = {"self_hosted": True, "label": "metacodes-macos-vm", "slots": 2, "pickup_timeout_minutes": 5,
                "zig_build_jobs": 8, "timeout_minutes": 60}
        self.assertEqual(plan.parse_switch(good), ON)
        for bad in ({k: v for k, v in good.items() if k != "slots"},
                    {**good, "extra": 1},
                    {**good, "slots": True},
                    {**good, "self_hosted": "true"},
                    {**good, "slots": 0},
                    {**good, "label": "self-hosted"},
                    {**good, "label": "macOS"},
                    {**good, "label": "bad label"},
                    []):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                plan.parse_switch(bad)


class OccupancyTest(unittest.TestCase):
    def test_only_pool_jobs_that_hold_or_wait_for_a_vm_count(self) -> None:
        jobs = [job("in_progress"), job("queued", created=NOW - 400), job("queued", created=NOW - 100),
                job("completed"), job("in_progress", labels=("macos-latest",)), job("waiting")]
        self.assertEqual(plan.occupancy(jobs, LABEL, NOW), plan.Occupancy(1, 2, 400.0))
        self.assertEqual(plan.occupancy([], LABEL, NOW), plan.Occupancy(0, 0, 0.0))


class DecideTest(unittest.TestCase):
    def test_a_free_slot_takes_the_gates(self) -> None:
        self.assertEqual(decide()[0], "self-hosted")
        self.assertEqual(decide(plan.Occupancy(1, 0, 0.0))[0], "self-hosted")

    def test_every_doubt_and_every_cheap_run_is_hosted(self) -> None:
        cases = {
            "switched off": decide(switch=plan.Switch(**{**ON.__dict__, "self_hosted": False})),
            "no switch": plan.decide(None, fast_path="", suites="", warm_cache="", pool=None, doubt="bad json"),
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
        # Within the pickup timeout a waiter is ordinary: one slot is still free.
        self.assertEqual(decide(plan.Occupancy(0, 1, 60.0))[0], "self-hosted")

    def test_mains_warm_run_fills_both_cache_lines(self) -> None:
        self.assertEqual(decide(warm_cache="true", pool=None)[0], "both")
        self.assertEqual(decide(warm_cache="true", switch=plan.FALLBACK_LIMITS)[0], "hosted")


class WatchTest(unittest.TestCase):
    TIMEOUT = 300

    def step(self, jobs, now=NOW, since=NOW - 10):
        return plan.watch_step(jobs, since, now, self.TIMEOUT)

    def test_a_vm_that_takes_the_job_is_followed_to_its_end(self) -> None:
        self.assertEqual(self.step([job("queued")])[0], "wait")
        self.assertEqual(self.step([job("in_progress", created=NOW - 3600)])[0], "wait")
        self.assertEqual(self.step([job("completed", conclusion="success")]), ("done", "success"))
        self.assertEqual(self.step([job("completed", conclusion="failure")]), ("done", "failure"))

    def test_no_vm_within_the_pickup_timeout_falls_back(self) -> None:
        self.assertEqual(self.step([job("queued", created=NOW - 301)])[0], "fallback")
        self.assertEqual(self.step([], since=NOW - 301)[0], "fallback")
        self.assertEqual(self.step([job("queued", name="Gates (macOS) / product")], since=NOW - 301)[0], "fallback")
        self.assertEqual(self.step([], since=NOW - 30)[0], "wait")


class StandDownTest(unittest.TestCase):
    def test_only_a_finished_watch_means_the_hosted_legs_took_over(self) -> None:
        self.assertTrue(plan.should_stand_down([job("completed", name=plan.WATCH_JOB)]))
        self.assertFalse(plan.should_stand_down([job("in_progress", name=plan.WATCH_JOB)]))
        self.assertFalse(plan.should_stand_down([job("queued", name=plan.WATCH_JOB)]))
        self.assertFalse(plan.should_stand_down([]))


def needs(mode="", plan_result="success", hosted="", watch="", fallback="", vm=""):
    value = {"macos-plan": {"result": plan_result, "outputs": {"mode": mode} if mode else {}},
             "gates-macos": {"result": hosted, "outputs": {}},
             "gates-macos-watch": {"result": watch, "outputs": {}}}
    if fallback or vm:
        value["gates-macos-watch"]["outputs"] = {"fallback": fallback, "vm_result": vm}
    return value


class VerdictTest(unittest.TestCase):
    def test_the_gates_pass_where_they_ran(self) -> None:
        cases = [
            (needs("hosted", hosted="success", watch="skipped"), True),
            (needs("hosted", hosted="failure", watch="skipped"), False),
            (needs("hosted", hosted="cancelled", watch="skipped"), False),
            (needs(plan_result="failure", hosted="success", watch="skipped"), True),  # no plan: hosted ran
            (needs(plan_result="failure", hosted="skipped", watch="skipped"), False),
            (needs("self-hosted", hosted="skipped", watch="success", fallback="false", vm="success"), True),
            (needs("self-hosted", hosted="skipped", watch="success", fallback="false", vm="failure"), False),
            (needs("self-hosted", hosted="skipped", watch="cancelled"), False),
            (needs("self-hosted", hosted="skipped", watch="failure", fallback="false", vm="success"), False),
            (needs("self-hosted", hosted="success", watch="success", fallback="true"), True),
            (needs("self-hosted", hosted="failure", watch="success", fallback="true"), False),
            (needs("both", hosted="success", watch="success", fallback="false", vm="success"), True),
            (needs("both", hosted="success", watch="success", fallback="true"), True),
            (needs("both", hosted="failure", watch="success", fallback="false", vm="success"), False),
            (needs("both", hosted="success", watch="success", fallback="false", vm="failure"), False),
            ({}, False),
        ]
        for value, passes in cases:
            with self.subTest(needs=value):
                self.assertEqual(plan.verdict(value)[0], passes, plan.verdict(value)[1])


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
       "GITHUB_API_URL": "https://api.example"}


class CommandTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.output = self.tmp / "out"
        self.switch = self.tmp / "switch.json"
        self.switch.write_text(json.dumps({**ON.__dict__}), encoding="utf-8")

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

    def test_plan_reads_the_other_runs_and_writes_every_output(self) -> None:
        api = FakeAPI(self.plan_routes([job("in_progress")]))
        code = self.run_main(["plan", "--switch", str(self.switch), "--github-output", str(self.output)],
                             api, env={"FAST_PATH": "false", "SUITES": "true"}, now=lambda: NOW)
        self.assertEqual(code, 0)
        got = self.outputs()
        self.assertEqual(got["mode"], "self-hosted")
        self.assertEqual((got["label"], got["zig_build_jobs"], got["timeout_minutes"], got["pickup_timeout_minutes"]),
                         ("metacodes-macos-vm", "8", "60", "5"))
        self.assertNotIn("actions/runs/99/jobs?per_page=100", [path for path, _ in api.seen])
        self.assertNotIn("actions/runs/6/jobs?per_page=100", [path for path, _ in api.seen])
        self.assertTrue(all(auth == "Bearer t" for _, auth in api.seen))

    def test_plan_falls_back_to_hosted_on_a_full_pool_or_any_doubt(self) -> None:
        full = FakeAPI(self.plan_routes([job("in_progress"), job("in_progress")]))
        self.run_main(["plan", "--switch", str(self.switch), "--github-output", str(self.output)], full, now=lambda: NOW)
        self.assertEqual(self.outputs()["mode"], "hosted")
        self.output.unlink()
        broken = FakeAPI({"actions/runs?status=queued&per_page=100": OSError("network down")})
        self.assertEqual(self.run_main(["plan", "--switch", str(self.switch), "--github-output", str(self.output)],
                                       broken, now=lambda: NOW), 0)
        self.assertEqual(self.outputs()["mode"], "hosted")
        self.assertIn("network down", self.outputs()["reason"])
        self.output.unlink()
        self.switch.write_text("{not json", encoding="utf-8")
        self.run_main(["plan", "--switch", str(self.switch), "--github-output", str(self.output)], now=lambda: NOW)
        got = self.outputs()
        self.assertEqual(got["mode"], "hosted")
        self.assertEqual(got["label"], plan.FALLBACK_LIMITS.label)  # every output stays defined

    def test_watch_follows_a_taken_job_to_its_end(self) -> None:
        jobs_path = "actions/runs/99/attempts/2/jobs?per_page=100"
        api = FakeAPI({jobs_path: [{"jobs": [job("queued")]}, {"jobs": [job("in_progress")]},
                                   {"jobs": [job("completed", conclusion="success")]}]})
        clock = iter(NOW + 20 * i for i in range(100))
        self.run_main(["watch", "--pickup-timeout-minutes", "5", "--github-output", str(self.output)], api,
                      now=lambda: next(clock), sleep=lambda _: None)
        self.assertEqual(self.outputs(), {"fallback": "false", "vm_result": "success"})

    def test_watch_hands_over_when_no_vm_comes(self) -> None:
        jobs_path = "actions/runs/99/attempts/2/jobs?per_page=100"
        api = FakeAPI({jobs_path: [{"jobs": [job("queued", created=NOW)]}]})
        clock = iter(NOW + 60 * i for i in range(100))
        self.run_main(["watch", "--pickup-timeout-minutes", "5", "--github-output", str(self.output)], api,
                      now=lambda: next(clock), sleep=lambda _: None)
        self.assertEqual(self.outputs()["fallback"], "true")

    def test_watch_hands_over_when_github_cannot_be_read(self) -> None:
        jobs_path = "actions/runs/99/attempts/2/jobs?per_page=100"
        api = FakeAPI({jobs_path: [OSError("timeout")]})
        self.run_main(["watch", "--pickup-timeout-minutes", "5", "--github-output", str(self.output)], api,
                      now=lambda: NOW, sleep=lambda _: None)
        self.assertEqual(self.outputs()["fallback"], "true")

    def test_stand_down_sets_fast_path(self) -> None:
        jobs_path = "actions/runs/99/attempts/2/jobs?per_page=100"
        for watch_status, release_fast_path, expected in (("completed", "false", "true"),
                                                          ("in_progress", "false", "false"),
                                                          ("in_progress", "true", "true")):
            with self.subTest(watch=watch_status, fast=release_fast_path):
                api = FakeAPI({jobs_path: {"jobs": [job(watch_status, name=plan.WATCH_JOB)]}})
                env_file = self.tmp / f"env-{watch_status}-{release_fast_path}"
                self.run_main(["stand-down", "--github-env", str(env_file)], api,
                              env={"RELEASE_FAST_PATH": release_fast_path})
                self.assertEqual(env_file.read_text(encoding="utf-8"), f"FAST_PATH={expected}\n")

    def test_verdict_exits_with_the_check(self) -> None:
        passing = needs("hosted", hosted="success", watch="skipped")
        self.assertEqual(self.run_main(["verdict"], env={"NEEDS": json.dumps(passing)}), 0)
        self.assertEqual(self.run_main(["verdict"], env={"NEEDS": "{}"}), 1)


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

    def test_the_plan_job_decides_from_the_scope_and_the_fast_path(self) -> None:
        spec = self.jobs["macos-plan"]
        self.assertEqual(spec["needs"], ["release-fast-path", "scope"])
        self.assertEqual(spec["if"], "${{ !cancelled() }}")
        step = next(s for s in spec["steps"] if s.get("id") == "plan")
        self.assertTrue(step["run"].startswith("python3 scripts/ci_macos_plan.py plan "))
        self.assertEqual(step["env"]["FAST_PATH"], "${{ needs.release-fast-path.outputs.fast }}")
        self.assertEqual(step["env"]["SUITES"], "${{ needs.scope.outputs.suites }}")
        for name in ("mode", "label", "zig_build_jobs", "timeout_minutes", "pickup_timeout_minutes", "reason"):
            self.assertEqual(spec["outputs"][name], "${{ steps.plan.outputs.%s }}" % name)
        self.assertEqual(self.workflow["permissions"]["actions"], "read")

    def test_the_pool_job_is_every_hosted_leg_in_one(self) -> None:
        pool, hosted = self.jobs["gates-macos-vm"], self.jobs["gates-macos"]
        self.assertEqual(pool["steps"], self.jobs["gates-linux"]["steps"])
        self.assertEqual(pool["runs-on"], "${{ needs.macos-plan.outputs.label }}")
        legs = pool["strategy"]["matrix"]["include"]
        self.assertEqual(len(legs), 1)
        flags = {key for leg in hosted["strategy"]["matrix"]["include"] for key, value in leg.items() if value is True}
        self.assertEqual({key for key, value in legs[0].items() if value is True}, flags)
        # The name the watch follows.
        self.assertEqual(pool["name"].replace("${{ matrix.leg }}", legs[0]["leg"]), plan.POOL_JOB)
        self.assertNotIn("FAST_PATH", pool["env"])  # the stand-down step sets it
        self.assertEqual(pool["env"]["POOL_JOB"], "true")
        self.assertEqual(pool["env"]["RELEASE_FAST_PATH"], "${{ needs.release-fast-path.outputs.fast }}")
        self.assertEqual(pool["env"]["ZIG_BUILD_JOBS"], "${{ needs.macos-plan.outputs.zig_build_jobs }}")
        self.assertEqual(pool["timeout-minutes"], "${{ fromJSON(needs.macos-plan.outputs.timeout_minutes) }}")
        self.assertIn("needs.macos-plan.outputs.mode == 'self-hosted'", pool["if"])
        self.assertIn("needs.macos-plan.outputs.mode == 'both'", pool["if"])

    def test_the_stand_down_step_follows_the_checkout_on_the_pool_job_only(self) -> None:
        steps = self.jobs["gates-linux"]["steps"]
        index = next(i for i, s in enumerate(steps) if s.get("name") == "Stand down if the hosted legs took over")
        self.assertTrue(steps[index - 1].get("uses", "").startswith("actions/checkout@"))
        self.assertEqual(steps[index]["if"], "env.POOL_JOB == 'true'")
        self.assertIn("ci_macos_plan.py stand-down", steps[index]["run"])
        # Every step after it that does work reads FAST_PATH.
        for step in steps[index + 1:]:
            if "FAST_PATH" in step.get("if", "") or step.get("name") == "Version state gate and release rehearsal":
                continue
            self.fail(f"{step.get('name') or step.get('uses')} runs even when the pool job stands down")

    def test_the_watch_follows_the_pool_job(self) -> None:
        spec = self.jobs["gates-macos-watch"]
        self.assertEqual(spec["name"], plan.WATCH_JOB)
        self.assertEqual(spec["runs-on"], "ubuntu-latest")
        self.assertEqual(spec["if"], self.jobs["gates-macos-vm"]["if"])
        step = next(s for s in spec["steps"] if s.get("id") == "watch")
        self.assertIn(f'--job "{plan.POOL_JOB}"', step["run"])
        self.assertEqual(spec["outputs"], {"fallback": "${{ steps.watch.outputs.fallback }}",
                                           "vm_result": "${{ steps.watch.outputs.vm_result }}"})

    def test_the_hosted_legs_run_unless_a_vm_took_the_gates(self) -> None:
        spec = self.jobs["gates-macos"]
        self.assertEqual(sorted(spec["needs"]), ["gates-macos-watch", "macos-plan", "release-fast-path", "scope"])
        self.assertEqual(spec["if"], "${{ !cancelled() && (needs.macos-plan.outputs.mode != 'self-hosted' "
                                     "|| needs.gates-macos-watch.outputs.fallback == 'true') }}")
        self.assertEqual(spec["runs-on"], "macos-latest")

    def test_the_required_check_never_waits_for_the_pool_job(self) -> None:
        spec = self.jobs["gates-macos-result"]
        self.assertEqual(spec["name"], "Gates (macOS)")
        self.assertEqual(spec["needs"], ["macos-plan", "gates-macos-watch", "gates-macos"])
        self.assertEqual(spec["if"], "${{ always() }}")
        self.assertEqual(spec["steps"][-1]["run"], "python3 scripts/ci_macos_plan.py verdict")
        self.assertEqual(spec["steps"][-1]["env"]["NEEDS"], "${{ toJSON(needs) }}")
        evidence = self.jobs["full-pr-evidence"]["needs"]
        self.assertIn("gates-macos-result", evidence)
        self.assertNotIn("gates-macos", evidence)

    def test_only_the_pool_job_runs_on_a_self_hosted_runner(self) -> None:
        for name in ("ci.yml", "release.yml", "release-tag.yml", "rule-control.yml", "agentcore-windows.yml"):
            workflow = self.workflow if name == "ci.yml" else load(name)
            for job_id, spec in workflow["jobs"].items():
                with self.subTest(workflow=name, job=job_id):
                    runs_on = json.dumps(spec.get("runs-on", ""))
                    self.assertNotIn("self-hosted", runs_on)
                    self.assertNotIn(LABEL, json.dumps(spec))
                    if (name, job_id) == ("ci.yml", "gates-macos-vm"):
                        self.assertIn("needs.macos-plan.outputs.label", runs_on)
                    else:
                        self.assertNotIn("macos-plan.outputs.label", runs_on)

    def test_the_conditions_name_only_real_modes(self) -> None:
        text = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        import re
        for mode in re.findall(r"outputs\.mode [!=]= '([^']+)'", text):
            self.assertIn(mode, plan.MODES)


if __name__ == "__main__":
    unittest.main()
