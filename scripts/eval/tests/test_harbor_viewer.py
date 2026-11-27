"""Contract tests for the Harbor bench viewer (scripts/eval/harbor/viewer).

A synthetic jobs directory in Harbor's layout covers every outcome class; the
server is exercised over real HTTP, including requests that try to leave the
jobs directory.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch

from scripts.eval.harbor.bench import data, results
from scripts.eval.harbor.bench.workbench import Workbench, model_comparison
from scripts.eval.harbor.viewer import server


def _write(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # Bytes, not text mode: trial files come from Linux containers with LF
    # line ends, and Windows text mode would turn them into CRLF.
    path.write_bytes((value if isinstance(value, str) else json.dumps(value)).encode("utf-8"))


def _span(start: str, end: str) -> dict:
    return {"started_at": f"2026-11-16T08:{start}Z", "finished_at": f"2026-11-16T08:{end}Z"}


def _trial(job: Path, name: str, *, reward=None, exception=None, stop="end_turn",
           finished=True, tests=None, steps=None, final_text="done") -> Path:
    trial = job / name
    _write(trial / "config.json", {})
    if finished:
        _write(trial / "result.json", {
            "task_name": "terminal-bench/" + name.split("__")[0],
            "trial_name": name,
            "started_at": "2026-11-16T08:00:00Z",
            "finished_at": "2026-11-16T08:05:00Z",
            "environment_setup": _span("00:00", "00:10"),
            "agent_setup": _span("00:10", "00:20"),
            "agent_execution": _span("00:20", "04:20"),
            "verifier": _span("04:20", "05:00"),
            "agent_result": {"n_input_tokens": 1000, "n_cache_tokens": 800,
                             "n_output_tokens": 50, "cost_usd": 0.01},
            "verifier_result": {"rewards": {"reward": reward}} if reward is not None else None,
            "exception_info": {"exception_type": exception, "exception_message": "boom"} if exception else None,
        })
        _write(trial / "agent" / "metacodes-output.jsonl",
               json.dumps({"type": "text", "text": "x"}) + "\n"
               + json.dumps({"type": "result", "stop_reason": stop, "turns": 3, "tool_calls": 2,
                           "text": final_text}) + "\n")
    if tests is not None:
        _write(trial / "verifier" / "ctrf.json", {"results": {"tests": tests}})
    if steps is not None:
        _write(trial / "agent" / "trajectory.json", {"steps": steps, "final_metrics": {"total_steps": len(steps)}})
    return trial


def _job(root: Path, name: str, model: str, planned: int, finished: bool = True) -> Path:
    job = root / name
    _write(job / "config.json", {
        "agents": [{"name": "scripts.eval.harbor.metacodes_agent:MetacodesAgent", "model_name": model}],
        "datasets": [{"name": "terminal-bench/terminal-bench-2-1"}],
        "n_attempts": 1, "n_concurrent_trials": 2,
    })
    _write(job / "result.json", {
        "started_at": "2026-11-16T08:00:00Z",
        "finished_at": "2026-11-16T08:30:00Z" if finished else None,
        "n_total_trials": planned,
    })
    return job


class ClassifyTest(unittest.TestCase):
    def test_every_outcome_class(self):
        def result(reward=None, exc=None, finished=True, message=None):
            info = {"exception_type": exc} if exc else None
            if info and message is not None:
                info["exception_message"] = message
            return {
                "finished_at": "2026-11-16T08:00:00Z" if finished else None,
                "verifier_result": {"rewards": {"reward": reward}} if reward is not None else None,
                "exception_info": info,
            }

        cases = [
            (result(1.0), None, ("pass", None)),
            (result(0.5), None, ("partial", None)),
            (result(0.0), None, ("fail", None)),
            (result(0.0, "AgentTimeoutError"), None, ("timeout", "AgentTimeoutError")),
            (result(None, "AgentTimeoutError"), None, ("timeout", "AgentTimeoutError")),
            (result(1.0, "AgentTimeoutError"), None, ("pass", None)),
            (result(None, "VerifierTimeoutError"), "end_turn", ("invalid", "verifier: VerifierTimeoutError")),
            (result(0.0, "NonZeroAgentExitCodeError"), "api_error", ("invalid", "provider: NonZeroAgentExitCodeError")),
            (result(None, "ApiRateLimitError"), None, ("invalid", "provider: ApiRateLimitError")),
            (result(None, "EnvironmentStartError"), None, ("invalid", "environment: EnvironmentStartError")),
            (
                result(None, "RuntimeError", message="Docker compose command failed: all predefined address pools have been fully subnetted"),
                None,
                ("invalid", "environment: docker address pool exhausted"),
            ),
            (
                result(None, "RuntimeError", message="Docker compose command failed for environment foo."),
                None,
                ("invalid", "environment: docker compose (RuntimeError)"),
            ),
            (result(None, "RuntimeError", message="unexpected crash"), None, ("invalid", "RuntimeError")),
            (result(None), "end_turn", ("invalid", "no reward")),
            (result(None, finished=False), None, ("running", None)),
            (None, None, ("running", None)),
        ]
        for raw, stop, expected in cases:
            with self.subTest(raw=raw, stop=stop):
                self.assertEqual(data.classify(raw, stop), expected)

    def test_a_running_trial_takes_its_task_from_the_trial_config(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        configs = {"django__django-11099__Ab3dE5f": {"name": "swe-bench/django__django-11099"},
                   "tau3-bench__tau3-telecom-mms-is__Zx9Yw8v": {"path": "/data/tau3-bench__tau3-telecom-mms-issue-x"}}
        for trial, task in configs.items():
            _write(root / trial / "config.json", {"task": task})
        self.assertEqual([data.trial_row(root / t)["task"] for t in configs],
                         ["django__django-11099", "tau3-bench__tau3-telecom-mms-issue-x"])


class LibraryTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        job = _job(self.root, "glm-pilot", "tokenjoy/GLM5.3-Flash", planned=5, finished=False)
        _trial(job, "kv-store__aaa", reward=1.0,
               tests=[{"name": "t.py::test_a", "status": "passed"}, {"name": "t.py::test_b", "status": "passed"}],
               steps=[
                   {"step_id": 1, "source": "user", "message": "do it"},
                   {"step_id": 2, "source": "agent", "message": "",
                    "tool_calls": [{"tool_call_id": "c1", "function_name": "Bash", "arguments": {"command": "ls"}}],
                    "observation": {"results": [{"source_call_id": "c1", "content": "x" * 5000,
                                                 "extra": {"is_error": True}}]}},
               ])
        _trial(job, "compressor__bbb", reward=0.0, final_text="",
               tests=[{"name": "t.py::test_c", "status": "failed", "message": "assert"}])
        _trial(job, "torch__ccc", exception="VerifierTimeoutError")
        _trial(job, "provider__ddd", reward=0.0, exception="NonZeroAgentExitCodeError", stop="api_error")
        _trial(job, "running__eee", finished=False)
        _job(self.root, "qwen-pilot", "qwen/qwen3.8-max", planned=1)
        (self.root / "not-a-job").mkdir()
        self.library = data.Library([self.root])

    def test_overview_lists_only_jobs(self):
        names = [view["name"] for view in self.library.overview()]
        self.assertEqual(sorted(names), ["glm-pilot", "qwen-pilot"])

    def test_summary_keeps_invalid_out_of_the_pass_rate(self):
        view = data.job_view(self.library.job_dir("glm-pilot"))
        summary = view["summary"]
        self.assertEqual(summary["counts"]["pass"], 1)
        self.assertEqual(summary["counts"]["fail"], 1)
        self.assertEqual(summary["counts"]["invalid"], 2)
        self.assertEqual(summary["counts"]["running"], 1)
        self.assertEqual(summary["valid"], 2)
        self.assertEqual(summary["pass_rate"], 0.5)
        self.assertEqual(summary["invalid_causes"], {"verifier": 1, "provider": 1})
        self.assertEqual(summary["empty_final"], 1)
        self.assertEqual(view["model"], "tokenjoy/GLM5.3-Flash")
        self.assertEqual(view["agent"], "MetacodesAgent")
        self.assertTrue(view["running"])

    def test_remote_ttft_summaries_have_bounded_buckets_and_pool_the_exact_mean(self):
        row = data.job_view(self.library.job_dir("glm-pilot"))["rows"][0]
        samples = [100 + i / 13 for i in range(10000)]
        remote_row = {**row, "ttft_samples_ms": samples}
        remote = results.aggregate([remote_row])
        self.assertEqual(results.task_summaries([remote_row])[row["task"]], remote)
        self.assertNotIn("ttft_samples_ms", remote)
        self.assertLessEqual(len(remote["ttft_histogram"]), len(data.TTFT_BUCKETS_MS))
        self.assertEqual(sum(n for _, n in remote["ttft_histogram"]), len(samples))
        local = data.summarize([{**row, "ttft_samples_ms": [3.1, 90000]}])
        merged = data.merge_summaries([remote, local])
        pooled = samples + local["ttft_samples_ms"]
        self.assertAlmostEqual(merged["ttft_ms"], sum(pooled) / len(pooled))
        self.assertEqual(merged["ttft_count"], len(pooled))
        self.assertEqual(merged["ttft_histogram"], data.ttft_distribution(pooled)["ttft_histogram"])
        for q, field in ((.5, "ttft_p50_ms"), (.95, "ttft_p95_ms")):
            exact = data.percentile(pooled, q)
            self.assertGreaterEqual(merged[field], exact)
            self.assertLess(merged[field], exact * 1.1)

    def test_model_comparison_combines_worker_and_local_results_across_suites(self):
        row = next(r for r in data.job_view(self.library.job_dir("glm-pilot"))["rows"] if r["status"] == "pass")
        remote = results.aggregate([row])
        latest = {("suite-a", "m1", row["task"]): ({}, "remote", remote),
                  ("suite-b", "m1", row["task"]): ({}, "local", [row]),
                  ("suite-a", "m2", row["task"]): ({}, "other", [row])}
        models, common = model_comparison(latest)
        self.assertEqual(common, 1)
        self.assertEqual([model["summary"]["tasks_solved"] for model in models], [2, 1])
        self.assertEqual([model["common_summary"]["first_tasks"] for model in models], [1, 1])

    def test_row_fields(self):
        rows = {row["task"]: row for row in data.job_view(self.library.job_dir("glm-pilot"))["rows"]}
        row = rows["kv-store"]
        self.assertEqual(row["tests"], {"passed": 2, "failed": 0, "total": 2})
        self.assertEqual(row["phases"], {"environment": 10.0, "setup": 10.0, "agent": 240.0, "verifier": 40.0})
        self.assertAlmostEqual(row["cache_ratio"], 0.8)
        self.assertEqual((row["stop_reason"], row["turns"], row["tool_calls"]), ("end_turn", 3, 2))
        self.assertEqual(rows["running"]["status"], "running")
        self.assertTrue(rows["compressor"]["empty_final"])
        self.assertFalse(row["empty_final"])
        self.assertIsNotNone(rows["running"]["elapsed_s"])

    def test_row_heals_legacy_workbuddy_input_tokens_missing_cache(self):
        job = self.root / "workbuddy-legacy"
        trial = _trial(job, "legacy-cache__aaa", reward=1.0)
        result_path = trial / "result.json"
        result = json.loads(result_path.read_text(encoding="utf-8"))
        result["agent_result"] = {"n_input_tokens": 120, "n_cache_tokens": 80, "n_output_tokens": 30, "cost_usd": 0.01}
        _write(result_path, result)
        _write(
            trial / "agent" / "metacodes-output.jsonl",
            json.dumps({
                "type": "result",
                "stop_reason": "end_turn",
                "turns": 2,
                "tool_calls": 1,
                "input_tokens": 120,
                "output_tokens": 30,
                "cache_read_input_tokens": 80,
                "cache_creation_input_tokens": 10,
                "cost_usd": 0.01,
                "text": "done",
            }) + "\n",
        )
        row = data.trial_row(trial)
        self.assertEqual(row["input_tokens"], 210.0)
        self.assertEqual(row["cache_tokens"], 80.0)
        self.assertEqual(row["total_tokens"], 240.0)
        self.assertAlmostEqual(row["cache_ratio"], 80.0 / 210.0)

    def test_trial_detail_clips_long_content_and_counts_tools(self):
        detail = data.trial_detail(self.library.trial_dir("glm-pilot", "kv-store__aaa"))
        self.assertEqual(detail["tools"], [("Bash", 1)])
        observation = detail["steps"][1]["observations"][0]
        self.assertTrue(observation["is_error"])
        self.assertLess(len(observation["content"]), 4200)
        self.assertIn("more chars", observation["content"])

    def test_skill_counts_use_invocation_names_before_display_clipping(self):
        job = self.root / "glm-pilot"
        calls = [{"function_name": "Skill", "arguments": args} for args in (
            {"values": ["x" * 4000], "name": "review"}, {"name": "review"}, {"name": "audit"}, {})]
        calls.append({"function_name": "Read", "arguments": {"name": "review"}})
        trial = _trial(job, "skills__abc", steps=[{"tool_calls": calls}])
        self.assertEqual(data.trial_detail(trial)["skills"], [("review", 2), (None, 1), ("audit", 1)])
        self.assertEqual(data.trial_detail(job / "kv-store__aaa")["skills"], [])
        self.assertIsNone(data.trial_detail(job / "running__eee")["skills"])

    def test_names_outside_the_jobs_cannot_be_addressed(self):
        for job, trial in (("..", "x"), ("glm-pilot", ".."), ("glm-pilot", "../qwen-pilot"),
                           ("/etc", "passwd"), ("not-a-job", "x"), ("glm-pilot", "missing__zzz")):
            with self.subTest(job=job, trial=trial):
                self.assertIsNone(self.library.trial_dir(job, trial))
        self.assertIsNone(self.library.job_dir("../" + self.root.name))

    def test_csv_has_one_row_per_trial(self):
        lines = data.job_csv(data.job_view(self.library.job_dir("glm-pilot"))).strip().splitlines()
        self.assertEqual(len(lines), 6)
        self.assertTrue(lines[0].startswith("job,model,task,trial,status"))


class LeaderboardTest(unittest.TestCase):
    BOARD = {"suites": ["terminal-bench-2.1"], "title": "Public board",
             "source": {"name": "board", "url": "https://example.invalid/", "retrieved": "2026-11-22", "metric": "accuracy"},
             "entries": [{"harness": "Other", "model": "x", "score": 50.0}]}
    SUBSET = {**BOARD, "title": "First tasks", "tasks": ["task0", "task1"]}

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        full = _job(self.root, "full", "m", planned=72)
        for n in range(64):
            _trial(full, f"task{n}__aaa", reward=1.0 if n % 4 else 0.0)
        for n in range(64, 72):
            _trial(full, f"task{n}__aaa", exception="RewardFileNotFoundError")
        _trial(full, "task0__bbb", reward=0.5)
        _trial(_job(self.root, "sample", "m", planned=1), "task0__ccc", reward=1.0)
        _trial(_job(self.root, "live", "m", planned=2, finished=False), "task0__ddd", reward=1.0)
        patcher = patch("scripts.eval.harbor.suites.leaderboards.boards", return_value=[self.BOARD, self.SUBSET])
        patcher.start()
        self.addCleanup(patcher.stop)
        self.workbench = Workbench(data.Library([self.root]))

    def test_a_job_scores_mean_reward_over_finished_trials_counting_invalid_as_zero(self):
        board = self.workbench.leaderboard(None)
        self.assertEqual(board["suite"], "terminal-bench-2.1")
        self.assertEqual(board["task_count"], 89)
        whole, subset = board["boards"]
        jobs = {job["name"]: job for job in whole["jobs"]}
        self.assertEqual(sorted(jobs), ["full", "sample"])
        self.assertTrue(jobs["full"]["ranked"])
        self.assertEqual((jobs["full"]["trials"], jobs["full"]["tasks"]), (73, 72))
        self.assertAlmostEqual(jobs["full"]["score"], 48.5 / 73)
        self.assertFalse(jobs["sample"]["ranked"])
        self.assertEqual([job["name"] for job in board["unranked"]], ["sample"])

    def test_a_board_limited_to_some_tasks_scores_only_those(self):
        subset = self.workbench.leaderboard(None)["boards"][1]
        jobs = {job["name"]: job for job in subset["jobs"]}
        self.assertEqual((jobs["full"]["trials"], jobs["full"]["tasks"]), (3, 2))
        self.assertAlmostEqual(jobs["full"]["score"], 1.5 / 3)
        self.assertFalse(jobs["sample"]["ranked"])

    def test_a_suite_without_a_published_board_is_not_found(self):
        self.assertIsNone(self.workbench.leaderboard("aime"))

    def test_an_invalid_trial_counts_zero_even_with_a_reward(self):
        job = _job(self.root, "rewarded-crash", "m", planned=2)
        _trial(job, "task0__eee", reward=1.0, exception="NonZeroAgentExitCodeError", stop="api_error")
        _trial(job, "task1__eee", reward=0.0)
        jobs = {job["name"]: job for job in Workbench(data.Library([self.root])).leaderboard(None)["boards"][0]["jobs"]}
        self.assertEqual(jobs["rewarded-crash"]["score"], 0.0)

    def test_leaderboard_and_job_view_attach_profile_versions_and_keep_latest_per_profile(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root)
        for name, started, reward in (
            ("p1-old", "2026-11-24T08:00:00Z", 0.0),
            ("p1-new", "2026-11-25T08:00:00Z", 1.0),
            ("p2-run", "2026-11-25T09:00:00Z", 0.5),
            ("p1-partial", "2026-11-25T10:00:00Z", 1.0),
        ):
            job = _job(root, name, "same-model", planned=2)
            _write(job / "result.json", {"started_at": started, "finished_at": started, "n_total_trials": 2})
            _trial(job, "task0__aaa", reward=reward)
            if name != "p1-partial":
                _trial(job, "task1__aaa", reward=reward)
        profiles_dir = root / ".bench-profiles"
        _write(profiles_dir / "prof-a.json", {
            "id": "prof-a", "name": "v0.13.0-formal-gate", "status": "finished",
            "created_at": "2026-11-25T00:00:00Z", "features": ["formal-gate"],
            "metacodes": {"label": "0.13.0"},
            "items": [
                {"suite": "terminal-bench-2.1", "model": "same-model", "run": "p1-old", "status": "finished", "tasks": ["task0", "task1"]},
                {"suite": "terminal-bench-2.1", "model": "same-model", "run": "p1-new", "status": "finished", "tasks": ["task0", "task1"]},
                {"suite": "terminal-bench-2.1", "model": "same-model", "run": "p1-partial", "status": "finished", "tasks": ["task0"]},
            ],
        })
        _write(profiles_dir / "prof-b.json", {
            "id": "prof-b", "name": "v0.12.0-baseline", "status": "finished",
            "created_at": "2026-11-24T00:00:00Z", "features": [],
            "metacodes": {"label": "0.12.0"},
            "items": [
                {"suite": "terminal-bench-2.1", "model": "same-model", "run": "p2-run", "status": "finished", "tasks": ["task0", "task1"]},
            ],
        })
        wb = Workbench(data.Library([root]))
        self.addCleanup(wb.close)
        board = wb.leaderboard("terminal-bench-2.1")
        subset = board["boards"][1]
        ranked = [j for j in subset["jobs"] if j["ranked"]]
        self.assertEqual([j["name"] for j in ranked], ["p1-new", "p2-run"])
        self.assertEqual([j["profile_name"] for j in ranked], ["v0.13.0-formal-gate", "v0.12.0-baseline"])
        self.assertEqual([j["profile_version"] for j in ranked], ["0.13.0", "0.12.0"])
        self.assertEqual(ranked[0]["profile_features"], ["formal-gate"])
        self.assertEqual(board["unranked"], [])
        job_detail = wb.job("p1-new")
        self.assertEqual(job_detail["profile"], "prof-a")
        self.assertEqual(job_detail["profile_name"], "v0.13.0-formal-gate")
        self.assertEqual(job_detail["profile_version"], "0.13.0")
        self.assertEqual(job_detail["profile_features"], ["formal-gate"])


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        job = _job(self.root, "pilot", "m", planned=1)
        _trial(job, "task__aaa", reward=1.0, steps=[{"step_id": 1, "source": "agent", "message": "hi"}])
        self.server = server.make_server(Workbench(data.Library([self.root])), "127.0.0.1", 0)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def get(self, path):
        try:
            with urllib.request.urlopen(self.base + path, timeout=10) as response:
                return response.status, response.headers, response.read()
        except urllib.error.HTTPError as error:
            with error:
                return error.code, error.headers, error.read()

    def test_public_bind_serves_http_without_reverse_dns(self):
        with patch('socket.getfqdn', side_effect=AssertionError('startup must not depend on reverse DNS')):
            http = server.make_server(Workbench(data.Library([self.root])), '0.0.0.0', 0)
            self.addCleanup(http.server_close)
            self.assertEqual(http.server_name, '0.0.0.0')
            threading.Thread(target=http.serve_forever, daemon=True).start()
            self.addCleanup(http.shutdown)
            with urllib.request.urlopen(f'http://127.0.0.1:{http.server_port}/api/jobs', timeout=2) as response:
                self.assertEqual(response.status, 200)

    def test_page_and_assets_allow_annotation_overlays(self):
        for path, mime in (
            ("/", "text/html"),
            ("/index.html", "text/html"),
            ("/viewer.js", "text/javascript"),
            ("/viewer.css", "text/css"),
        ):
            with self.subTest(path=path):
                status, headers, body = self.get(path)
                self.assertEqual(status, 200)
                self.assertTrue(headers["Content-Type"].startswith(mime))
                self.assertNotIn("Content-Security-Policy", headers)
                self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
                self.assertEqual(headers["X-Frame-Options"], "DENY")
                self.assertTrue(body)

    def test_api(self):
        status, _, body = self.get("/api/jobs")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["jobs"][0]["summary"]["counts"]["pass"], 1)
        status, _, body = self.get("/api/trial?job=pilot&trial=task__aaa")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["steps"][0]["message"], "hi")
        status, headers, body = self.get("/api/job.csv?name=pilot")
        self.assertEqual(status, 200)
        self.assertIn("attachment", headers["Content-Disposition"])

    def test_escapes_and_unknown_paths_are_404(self):
        for path in ("/api/job?name=..", "/api/trial?job=pilot&trial=..%2F..%2Fetc",
                     "/api/trial?job=..&trial=pilot", "/../../etc/passwd", "/api/nothing",
                     "/server.py"):
            with self.subTest(path=path):
                status, _, body = self.get(path)
                self.assertEqual(status, 404)
                self.assertNotIn(str(self.root).encode(), body)


class ViewerLogicTest(unittest.TestCase):
    VIEWER_JS = Path(__file__).resolve().parents[1] / "harbor" / "viewer" / "static" / "viewer.js"

    def _run_js(self, script: str):
        node = shutil.which("node")
        if not node:
            self.skipTest("node is required to execute viewer.js unit tests")
        harness = f"""
const fs = require('fs');
const vm = require('vm');
class FakeNode {{
  constructor(tag) {{
    this.tagName = tag;
    this.children = [];
    this.attrs = {{}};
    this.style = {{}};
    this.classList = {{ toggle() {{}} }};
    this._value = '';
    this._listeners = {{}};
  }}
  append(...items) {{
    for (const item of items) {{
      if (item === null || item === undefined || item === false) continue;
      if (item instanceof FakeNode || (item && typeof item === 'object' && !Array.isArray(item) && 'textContent' in item)) {{
        this.children.push(item);
      }} else {{
        this.children.push({{ textContent: String(item), children: [] }});
      }}
    }}
  }}
  replaceChildren(...items) {{ this.children = []; this.append(...items); }}
  setAttribute(k, v) {{ this.attrs[k] = v; if (k === 'value') this._value = v; if (k === 'selected') this.selected = true; if (k === 'checked') this.checked = true; }}
  addEventListener(type, fn) {{ (this._listeners[type] = this._listeners[type] || []).push(fn); }}
  dispatch(type) {{ for (const fn of this._listeners[type] || []) fn({{ target: this, currentTarget: this, stopPropagation() {{}} }}); }}
  get value() {{
    if (this.tagName === 'select') {{
      const picked = this.children.find((c) => c.selected) || this.children[0];
      return this._value || (picked ? picked._value : '');
    }}
    return this._value;
  }}
  set value(v) {{ this._value = v; }}
  get textContent() {{
    if (this._text !== undefined) return this._text;
    return this.children.map((c) => c.textContent || '').join('');
  }}
  set textContent(v) {{ this._text = String(v); }}
}}
const nodes = {{ '#title': new FakeNode('h1'), '#crumbs': new FakeNode('div'), '#create-run': new FakeNode('button') }};
const ctx = {{
  Node: FakeNode,
  URL: {{ createObjectURL: () => '', revokeObjectURL: () => {{}} }},
  Blob: class {{}},
  setTimeout, clearTimeout, setInterval: () => 0,
  location: {{ hash: '#/' }},
  history: {{ replaceState() {{}} }},
  window: {{ addEventListener() {{}}, scrollTo() {{}} }},
  document: {{
    createElement: (tag) => new FakeNode(tag),
    createTextNode: (t) => ({{ textContent: String(t), children: [] }}),
    querySelector: (sel) => nodes[sel] || null,
    querySelectorAll: () => [],
    addEventListener() {{}},
  }},
}};
vm.createContext(ctx);
vm.runInContext(fs.readFileSync({json.dumps(str(self.VIEWER_JS))}, 'utf8'), ctx);
{script}
"""
        proc = subprocess.run([node, "-"], input=harness, capture_output=True, text=True, encoding="utf-8", check=True)
        return json.loads(proc.stdout)

    def test_cross_profile_compare_dock_prefers_same_model_full_run_and_lists_all_jobs(self):
        result = self._run_js("""
const chosen = [
  {
    id: 'prof-a', name: 'Profile A',
    items: [
      { submission: 's1', suite: 'fh', suite_name: 'FH', model: 'model-x', tasks: ['t1', 't2', 't3', 't4'],
        started_at: '2026-11-24T10:00:00Z', job: { name: 'a-x', planned: 4, started_at: '2026-11-24T10:00:00Z' } },
      { submission: 's2', suite: 'fh', suite_name: 'FH', model: 'model-y', tasks: ['t1', 't2', 't3', 't4'],
        started_at: '2026-11-24T11:00:00Z', job: { name: 'a-y', planned: 4, started_at: '2026-11-24T11:00:00Z' } },
      { submission: 's3', suite: 'fh', suite_name: 'FH', model: 'model-y', tasks: ['t1'],
        started_at: '2026-11-24T12:00:00Z', job: { name: 'a-retry', planned: 1, started_at: '2026-11-24T12:00:00Z' } },
    ],
  },
  {
    id: 'prof-b', name: 'Profile B',
    items: [
      { submission: 's1', suite: 'fh', suite_name: 'FH', model: 'model-x', tasks: ['t1', 't2', 't3', 't4'],
        started_at: '2026-11-24T10:30:00Z', job: { name: 'b-x', planned: 4, started_at: '2026-11-24T10:30:00Z' } },
    ],
  },
];
const dock = vm.runInContext('multiProfileCompareDock', ctx)(chosen);
const walk = (n, acc = []) => { acc.push(n); for (const c of n.children || []) walk(c, acc); return acc; };
const all = walk(dock);
const link = all.find((n) => n.tagName === 'a');
const selects = all.filter((n) => n.tagName === 'select');
const profASelect = selects[1];
const optionsA = profASelect.children.map((o) => o._value);
const defaultHref = link.href;
profASelect.value = 'a-y';
profASelect.dispatch('change');
const switchedHref = link.href;
console.log(JSON.stringify({ defaultHref, switchedHref, optionsA }));
""")
        self.assertEqual(result["defaultHref"], "#/compare/a-x,b-x")
        self.assertEqual(set(result["optionsA"]), {"a-x", "a-y", "a-retry"})
        self.assertEqual(result["switchedHref"], "#/compare/a-y,b-x")

    def test_compare_summary_uses_common_task_cost_delta_matching_frontier(self):
        result = self._run_js("""
const jobs = {
  'job-a': {
    name: 'job-a', model: 'm', profile_name: 'Profile A', profile_version: '0.12.0', profile_features: [],
    running: false, suite_name: 'FH',
    summary: { cost_per_task: 0.0155, cost_per_pass: 0.0155, tasks_solved: 2, tasks_attempted: 2,
               total_tokens: 2000, token_trials: 2, cache_hit_rate: 0.5 },
    rows: [
      { task: 't1', trial: 't1__a', first_attempt: true, status: 'pass', cost_usd: 0.030, total_tokens: 1000, elapsed_s: 10 },
      { task: 't2', trial: 't2__a', first_attempt: true, status: 'pass', cost_usd: 0.001, total_tokens: 1000, elapsed_s: 10 },
    ],
  },
  'job-b': {
    name: 'job-b', model: 'm', profile_name: 'Profile B', profile_version: '0.13.0', profile_features: ['formal-gate'],
    running: false, suite_name: 'FH',
    summary: { cost_per_task: 0.020, cost_per_pass: 0.020, tasks_solved: 1, tasks_attempted: 1,
               total_tokens: 1000, token_trials: 1, cache_hit_rate: 0.6 },
    rows: [
      { task: 't1', trial: 't1__b', first_attempt: true, status: 'pass', cost_usd: 0.020, total_tokens: 1000, elapsed_s: 10 },
    ],
  },
};
ctx.api = async (url) => jobs[decodeURIComponent(url.split('name=')[1])];
(async () => {
  const root = await vm.runInContext('renderCompare', ctx)(['job-a', 'job-b'], null);
  const walk = (n, acc = []) => { acc.push(n); for (const c of n.children || []) walk(c, acc); return acc; };
  const tables = walk(root).filter((n) => n.tagName === 'table');
  const summaryRows = walk(tables[0]).filter((n) => n.tagName === 'tr').slice(1);
  const cells = summaryRows.map((tr) => tr.children.map((td) => td.textContent));
  console.log(JSON.stringify({ cells }));
})();
""")
        row_a, row_b = result["cells"]
        self.assertIn("$0.030", row_a[3])
        self.assertEqual(row_a[4], "")
        self.assertIn("$0.020", row_b[3])
        self.assertIn("-33%", row_b[3])
        self.assertNotIn("+29%", row_b[3])
        self.assertIn("前沿", row_b[4])
        self.assertIn("$0.015", row_a[5])
        self.assertIn("$0.020", row_b[5])

    def test_profile_overview_renders_each_feature_as_its_own_tag(self):
        result = self._run_js("""
const payload = {
  can_run: true,
  jobs: [],
  runs: [],
  profiles: [
    {
      id: 'prof-gates', name: 'profile-0.12.0-111110000', status: 'finished',
      created_at: '2026-11-27T01:00:00Z', last_run_at: '2026-11-27T01:29:00Z',
      metacodes: { label: '0.12.0' },
      models: ['metask/DeepSeek-V4.1-Flash-1017'],
      features: ['verification_final_gate', 'requirement_ledger', 'test_integrity', 'delivery_cadence', 'stall_gate'],
      items: [],
      summary: { first_pass_rate: 0.53, first_passed: 59, first_valid: 112, counts: { pass: 59 }, trials: 112, cost_per_task: 11.78, initial_input_tokens_mean: 16200 },
    },
    {
      id: 'prof-plain', name: 'profile-0.12.0-plain', status: 'finished',
      created_at: '2026-11-26T01:00:00Z', last_run_at: '2026-11-26T01:29:00Z',
      metacodes: { label: '0.12.0' },
      models: ['metask/DeepSeek-V4.1-Flash-1017'],
      features: [],
      items: [],
      summary: { first_pass_rate: 0.5, first_passed: 1, first_valid: 2, counts: { pass: 1 }, trials: 2, cost_per_task: 1.0, initial_input_tokens_mean: 1000 },
    },
  ],
};
ctx.api = async () => payload;
(async () => {
  const root = await vm.runInContext('renderOverview', ctx)();
  const walk = (n, acc = []) => { acc.push(n); for (const c of n.children || []) walk(c, acc); return acc; };
  const tagGroups = walk(root).filter((n) => n.className === 'pcard-tags');
  const tagsByCard = tagGroups.map((group) => group.children.map((child) => child.textContent));
  console.log(JSON.stringify({ tagsByCard }));
})();
""")
        self.assertEqual(result["tagsByCard"], [
            ["0.12.0", "verification_final_gate", "requirement_ledger", "test_integrity", "delivery_cadence", "stall_gate"],
            ["0.12.0", "默认功能"],
        ])

    def test_leaderboard_and_profile_render_pricing_alignment_and_schedule_pills(self):
        result = self._run_js("""
const boardPayload = {
  suite: 'frontier-harness-eval-1.1',
  suite_name: 'FrontierHarness Eval v1.1',
  description: 'desc',
  task_count: 62,
  ranked_coverage: 0.8,
  suites: [{ suite: 'frontier-harness-eval-1.1', suite_name: 'FrontierHarness Eval v1.1' }],
  pricing: { schedule: 'auto', label: '跟随榜单口径', schedules: [] },
  boards: [{
    suites: ['frontier-harness-eval-1.1'],
    title: 'FrontierHarness Eval v1.1 排行榜',
    model_filter: true,
    default_model: 'All models',
    source: { name: 'FH', url: 'https://frontierharness.org/', retrieved: '2026-11-22' },
    pricing: { schedule: 'auto', default_schedule: 'baseten', effective_schedule: 'baseten', label: 'Baseten 挂牌价', aligned: true },
    entries: [{ harness: 'ZCode', model: 'DeepSeek-V4.1-Flash-1017', score: 69.0, cost_per_task_usd: 0.153 }],
    jobs: [{
      name: 'fh-job', model: 'metask/DeepSeek-V4.1-Flash-1017', score: 0.65, tasks: 62, trials: 62,
      ranked: true, cost_per_task: 2.2125,
      costs_by_schedule: { openrouter: 2.205, baseten: 2.2125, recorded: 24.0 },
    }],
  }],
  unranked: [],
};
const profilePayload = {
  id: 'p1', name: 'DeepSeek Profile', status: 'finished', can_run: false,
  metacodes: { label: '0.12.0' }, features: [], items: [], tasks: [], by_model: [],
  models: ['metask/DeepSeek-V4.1-Flash-1017'], suites: ['frontier-harness-eval-1.1'],
  pricing: { schedule: 'openrouter', label: 'OpenRouter 报价', schedules: [] },
  costs_by_schedule: {
    openrouter: { label: 'OpenRouter 报价', cost_per_task: 2.205 },
    baseten: { label: 'Baseten 挂牌价', cost_per_task: 2.2125 },
    recorded: { label: '运行记录原价', cost_per_task: 24.0 },
  },
  summary: {
    counts: { pass: 1, partial: 0, fail: 0, timeout: 0, invalid: 0, running: 0 },
    trials: 1, valid: 1, one_shot_pass_rate: 1, first_pass_rate: 1, first_passed: 1, first_valid: 1,
    solved_rate: 1, tasks_solved: 1, tasks_attempted: 1, cost_per_task: 2.205, cost_per_pass: 2.205,
    initial_input_tokens_mean: 1000, cache_hit_rate: 0.5,
  },
};
const walk = (n, acc = []) => { acc.push(n); for (const c of n.children || []) walk(c, acc); return acc; };
(async () => {
  ctx.api = async (url) => url.startsWith('/api/leaderboard') ? boardPayload : profilePayload;
  const boardRoot = await vm.runInContext('renderLeaderboard', ctx)('frontier-harness-eval-1.1');
  const pricingBadges = walk(boardRoot).filter((n) => (n.className || '').includes('board-pricing')).map((n) => n.textContent);
  const profileRoot = await vm.runInContext('renderProfile', ctx)('p1');
  const pills = walk(profileRoot).filter((n) => (n.className || '').includes('price-pill')).map((n) => n.textContent);
  console.log(JSON.stringify({ pricingBadges, pills }));
})();
""")
        self.assertEqual(result["pricingBadges"], ["成本口径：Baseten 挂牌价（已对齐榜单）"])
        self.assertEqual(len(result["pills"]), 3)
        self.assertIn("OpenRouter 报价", result["pills"][0])
        self.assertIn("Baseten 挂牌价", result["pills"][1])
        self.assertIn("运行记录原价", result["pills"][2])

    def test_profile_expand_and_filters_redraw_locally_without_refetching(self):
        result = self._run_js("""
const summary = {
  counts: { pass: 1, partial: 0, fail: 1, timeout: 0, invalid: 0, running: 0 },
  trials: 2, valid: 2, one_shot_pass_rate: 0.5,
  first_passed: 1, first_valid: 2, first_pass_rate: 0.5,
  tasks_solved: 1, tasks_attempted: 2, solved_rate: 0.5,
  cost_per_task: 0.5, cost_per_pass: 1.0, total_tokens: 2000,
  initial_input_tokens_mean: 500, cache_hit_rate: 0.5,
  tps: 20, ttft_ms: 100, ttft_p95_ms: 200, non_pass_cost_share: 0.5,
};
const profile = {
  id: 'prof-live', name: 'profile-0.12.0', status: 'running', can_run: true,
  concurrency: 32, auto_rerun_invalid: false,
  created_at: '2026-11-27T01:00:00Z', last_run_at: '2026-11-27T02:00:00Z',
  metacodes: { label: '0.12.0' }, features: ['stall_gate'],
  models: ['model-a', 'model-b'],
  summary,
  by_model: [
    { model: 'model-a', tasks: 1, summary },
    { model: 'model-b', tasks: 1, summary },
  ],
  items: [
    { submission: 's1', suite: 'suite-a', suite_name: 'Suite A', model: 'model-a', status: 'finished',
      tasks: ['t1'], run: 'run-1', job: { name: 'run-1', planned: 1, running: false, wall_s: 10, summary } },
    { submission: 's2', suite: 'suite-b', suite_name: 'Suite B', model: 'model-b', status: 'running',
      tasks: ['t2'], run: 'run-2', job: { name: 'run-2', planned: 1, running: true, wall_s: 5, summary } },
  ],
  tasks: [
    { suite: 'suite-a', suite_name: 'Suite A', model: 'model-a', task: 't1', job: 'run-1',
      first_status: 'pass', passed: 1, valid: 1, mean_total_tokens: 1000, mean_turns: 2, mean_elapsed_s: 5,
      attempts: [{ attempt_number: 1, trial: 't1__1', status: 'pass', total_tokens: 1000, elapsed_s: 5 }] },
    { suite: 'suite-b', suite_name: 'Suite B', model: 'model-b', task: 't2', job: 'run-2',
      first_status: 'fail', passed: 0, valid: 1, mean_total_tokens: 1000, mean_turns: 3, mean_elapsed_s: 6,
      attempts: [{ attempt_number: 1, trial: 't2__1', status: 'fail', total_tokens: 1000, elapsed_s: 6 }] },
  ],
};
let fetches = 0;
ctx.api = async () => {
  fetches += 1;
  if (fetches > 1) throw new TypeError('Failed to fetch');
  return profile;
};
const walk = (n, acc = []) => { acc.push(n); for (const c of n.children || []) walk(c, acc); return acc; };
(async () => {
  const root = await vm.runInContext('renderProfile', ctx)('prof-live');
  vm.runInContext('state.busy = true', ctx);
  const expandBtn = () => walk(root).find((n) => n.tagName === 'button' && n.attrs['aria-expanded'] !== undefined);
  const hasExpanded = () => walk(root).some((n) => n.className === 'profile-expanded');
  const before = { expanded: hasExpanded(), aria: expandBtn().attrs['aria-expanded'], label: expandBtn().textContent };

  expandBtn().dispatch('click');
  const opened = {
    expanded: hasExpanded(),
    aria: expandBtn().attrs['aria-expanded'],
    label: expandBtn().textContent,
    hasQueue: walk(root).some((n) => n.textContent.includes('作业队列')),
    hasSettings: walk(root).some((n) => n.textContent.includes('Profile 设置与冻结信息')),
  };

  const failPill = walk(root).find((n) => n.tagName === 'button' && (n.className || '').includes('stat-pill') && n.textContent.includes('失败'));
  failPill.dispatch('click');
  const failRows = walk(walk(root).find((n) => n.className === 'task-table')).filter((n) => n.tagName === 'tr').slice(1).map((tr) => tr.textContent);

  const modelChip = walk(root).find((n) => n.tagName === 'button' && n.className === 'chip' && n.textContent === 'model-a');
  modelChip.dispatch('click');
  const afterModelChip = vm.runInContext('state.profileModel', ctx);

  expandBtn().dispatch('click');
  const closed = { expanded: hasExpanded(), aria: expandBtn().attrs['aria-expanded'], label: expandBtn().textContent };

  console.log(JSON.stringify({ fetches, before, opened, failRows, afterModelChip, closed }));
})();
""")
        self.assertEqual(result["fetches"], 1)
        self.assertFalse(result["before"]["expanded"])
        self.assertEqual(result["before"]["aria"], "false")
        self.assertIn("展开作业 (2)", result["before"]["label"])
        self.assertTrue(result["opened"]["expanded"])
        self.assertEqual(result["opened"]["aria"], "true")
        self.assertIn("收起作业", result["opened"]["label"])
        self.assertTrue(result["opened"]["hasQueue"])
        self.assertTrue(result["opened"]["hasSettings"])
        self.assertEqual(len(result["failRows"]), 1)
        self.assertIn("t2", result["failRows"][0])
        self.assertEqual(result["afterModelChip"], "model-a")
        self.assertFalse(result["closed"]["expanded"])
        self.assertEqual(result["closed"]["aria"], "false")

    def test_overview_job_compare_and_leaderboard_controls_redraw_locally(self):
        result = self._run_js("""
const walk = (n, acc = []) => { acc.push(n); for (const c of n.children || []) walk(c, acc); return acc; };
const summary = {
  counts: { pass: 1, partial: 0, fail: 1, timeout: 0, invalid: 0, running: 0 },
  trials: 2, valid: 2, one_shot_pass_rate: 0.5,
  first_passed: 1, first_valid: 2, first_pass_rate: 0.5,
  tasks_solved: 1, tasks_attempted: 2, solved_rate: 0.5,
  cost_per_task: 0.02, cost_per_pass: 0.04, total_tokens: 2000, token_trials: 2,
  initial_input_tokens_mean: 500, cache_hit_rate: 0.5, mean_reward: 0.5,
  invalid_causes: {}, empty_final: 0, input_tokens: 1500, output_tokens: 500, cache_tokens: 750,
};
let overviewCalls = 0;
ctx.api = async () => {
  overviewCalls += 1;
  if (overviewCalls > 1) throw new TypeError('Failed to fetch');
  return {
    can_run: true, jobs: [], runs: [],
    profiles: [
      { id: 'p1', name: 'P1', status: 'finished', models: ['m1'], features: [], metacodes: { label: '0.12' },
        items: [{ submission: 's1', suite: 'fh', suite_name: 'FH', model: 'm1', tasks: ['t1'], job: { name: 'j1', planned: 1 } }],
        summary },
      { id: 'p2', name: 'P2', status: 'running', models: ['m2'], features: [], metacodes: { label: '0.13' },
        items: [{ submission: 's1', suite: 'fh', suite_name: 'FH', model: 'm2', tasks: ['t1'], job: { name: 'j2', planned: 1 } }],
        summary },
    ],
  };
};
(async () => {
  const ov = await vm.runInContext('renderOverview', ctx)();
  for (const box of walk(ov).filter((n) => n.tagName === 'input' && n.attrs.type === 'checkbox')) {
    box.checked = true;
    box.dispatch('change');
  }
  const hasDock = walk(ov).some((n) => n.className === 'compare-dock');
  walk(ov).find((n) => n.tagName === 'button' && n.textContent === '清空').dispatch('click');
  const clearedDock = !walk(ov).some((n) => n.className === 'compare-dock');

  let jobCalls = 0;
  ctx.api = async () => {
    jobCalls += 1;
    if (jobCalls > 1) throw new TypeError('Failed to fetch');
    return {
      name: 'j1', running: false, planned: 2, wall_s: 10, summary,
      rows: [
        { task: 't1', trial: 't1__a', first_attempt: true, attempt_number: 1, status: 'pass', reward: 1, phases: { agent: 4 }, elapsed_s: 4 },
        { task: 't2', trial: 't2__a', first_attempt: true, attempt_number: 1, status: 'fail', reward: 0, phases: { agent: 6 }, elapsed_s: 6 },
      ],
    };
  };
  const jobRoot = await vm.runInContext('renderJob', ctx)('j1');
  walk(jobRoot).find((n) => n.tagName === 'button' && n.textContent.includes('失败')).dispatch('click');
  const jobFiltered = walk(jobRoot).filter((n) => n.tagName === 'tbody')[0].children.map((tr) => tr.textContent);

  let cmpCalls = 0;
  const cmpJobs = {
    j1: { name: 'j1', model: 'm1', running: false, summary, rows: [
      { task: 't1', trial: 't1__a', first_attempt: true, status: 'fail', cost_usd: 0.02, total_tokens: 1000, elapsed_s: 4 },
    ] },
    j2: { name: 'j2', model: 'm1', running: false, summary, rows: [
      { task: 't1', trial: 't1__b', first_attempt: true, status: 'pass', cost_usd: 0.02, total_tokens: 1000, elapsed_s: 4 },
    ] },
  };
  ctx.api = async (url) => {
    cmpCalls += 1;
    if (cmpCalls > 2) throw new TypeError('Failed to fetch');
    return cmpJobs[decodeURIComponent(url.split('name=')[1])];
  };
  const cmpRoot = await vm.runInContext('renderCompare', ctx)(['j1', 'j2'], null);
  walk(cmpRoot).find((n) => n.tagName === 'button' && n.textContent === '设为基准').dispatch('click');
  const cmpBaseline = vm.runInContext('state.compareBaseline', ctx);

  let boardCalls = 0;
  ctx.api = async () => {
    boardCalls += 1;
    if (boardCalls > 1) throw new TypeError('Failed to fetch');
    return {
      suite: 'tb', suite_name: 'TB', task_count: 10, ranked_coverage: 0.8,
      suites: [{ suite: 'tb', suite_name: 'TB' }], unranked: [],
      boards: [{
        suites: ['tb'], title: 'Board', source: { name: 'src', url: 'https://example.invalid', retrieved: '2026-11-27' },
        entries: [{ harness: 'Other', model: 'm1', score: 50 }],
        jobs: [
          { name: 'j1', profile_name: 'P1', model: 'm1', score: 0.6, ranked: true, tasks: 10, cost_per_task: 1 },
          { name: 'j2', profile_name: 'P2', model: 'm1', score: 0.7, ranked: true, tasks: 10, cost_per_task: 1 },
        ],
      }],
    };
  };
  const lbRoot = await vm.runInContext('renderLeaderboard', ctx)('tb');
  const boardTables = () => walk(lbRoot).filter((n) => n.tagName === 'table' && n.className === 'board');
  const boardInitialTables = boardTables().length;
  const boardInitialHasOther = boardTables().some((t) => t.textContent.includes('Other'));
  const stripBox = walk(lbRoot).find((n) => n.tagName === 'input' && n.attrs.type === 'checkbox');
  stripBox.checked = false;
  stripBox.dispatch('change');
  const boardAfterStripTables = boardTables().length;
  const boardAfterStripHasOther = boardTables().some((t) => t.textContent.includes('Other'));
  const boardSelectedAfterStrip = vm.runInContext("state.boardSelected['tb'].size", ctx);
  const tableBox = walk(boardTables()[0]).find((n) => n.tagName === 'input' && n.attrs.type === 'checkbox');
  tableBox.checked = !tableBox.checked;
  tableBox.dispatch('change');
  const boardAfterTableTables = boardTables().length;
  const boardSelectedAfterTable = vm.runInContext("state.boardSelected['tb'].size", ctx);

  console.log(JSON.stringify({
    overviewCalls, hasDock, clearedDock,
    jobCalls, jobFiltered,
    cmpCalls, cmpBaseline,
    boardCalls, boardInitialTables, boardInitialHasOther,
    boardAfterStripTables, boardAfterStripHasOther, boardSelectedAfterStrip,
    boardAfterTableTables, boardSelectedAfterTable,
  }));
})();
""")
        self.assertEqual(result["overviewCalls"], 1)
        self.assertTrue(result["hasDock"])
        self.assertTrue(result["clearedDock"])
        self.assertEqual(result["jobCalls"], 1)
        self.assertEqual(len(result["jobFiltered"]), 1)
        self.assertIn("t2", result["jobFiltered"][0])
        self.assertEqual(result["cmpCalls"], 2)
        self.assertEqual(result["cmpBaseline"], "j2")
        self.assertEqual(result["boardCalls"], 1)
        self.assertEqual(result["boardInitialTables"], 1)
        self.assertTrue(result["boardInitialHasOther"])
        self.assertEqual(result["boardAfterStripTables"], 1)
        self.assertTrue(result["boardAfterStripHasOther"])
        self.assertEqual(result["boardSelectedAfterStrip"], 1)
        self.assertEqual(result["boardAfterTableTables"], 1)
        self.assertEqual(result["boardSelectedAfterTable"], 2)


if __name__ == "__main__":
    unittest.main()
