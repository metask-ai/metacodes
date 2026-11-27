"""Contract tests for the Bench evaluation store (scripts/eval/harbor/store).

The file-based projection (viewer/data.py over Harbor job directories) is
the reference: every view the page shows must be identical when it is read
from the store, including after the job directory is gone. Migration is
proven by row-for-row and blob-hash verification in both directions.

PostgreSQL cases run against a real server when METACODES_TEST_PG_DSN names
an empty database the test may create schemas in, e.g.
`postgresql://postgres@/postgres?host=/path/to/socket`; otherwise they skip.
"""
from __future__ import annotations

import contextlib
import datetime as dt
import hashlib
import io
import json
import os
import shutil
import sqlite3
import tempfile
import threading
import time
import types
import unittest
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from scripts.eval.harbor import cli, suites
from scripts.eval.harbor.store import config as store_config
from scripts.eval.harbor.store import ingest, library as library_module, migrate, schema
from scripts.eval.harbor.store.backend import Store, StoreError
from scripts.eval.harbor.store.library import StoreLibrary
from scripts.eval.harbor.bench import data, results
from scripts.eval.harbor.viewer import server
from scripts.eval.harbor.bench.runner import atomic_json
from scripts.eval.harbor.bench.workbench import Workbench
from scripts.eval.tests.test_harbor_viewer import _job, _trial, _write

FIXED = dt.datetime(2026, 11, 16, 8, 40, tzinfo=dt.timezone.utc)
PG_DSN = os.environ.get("METACODES_TEST_PG_DSN")


class _Frozen(dt.datetime):
    @classmethod
    def now(cls, tz=None):
        return FIXED.astimezone(tz) if tz else FIXED.replace(tzinfo=None)


FROZEN = types.SimpleNamespace(datetime=_Frozen, timezone=dt.timezone)


def frozen_time(test):
    for module in (data, library_module):
        patcher = patch.object(module, "dt", FROZEN)
        patcher.start()
        test.addCleanup(patcher.stop)


def normal(value):
    """What the HTTP layer sends: tuples become lists."""
    return json.loads(json.dumps(value, ensure_ascii=False, allow_nan=False))


def build_fixture(root: Path) -> None:
    """Every outcome class, request metrics, usage-only history, a killed
    trial, attempt ordering across offsets, an empty job and a running job."""
    job = _job(root, "glm-pilot", "tokenjoy/GLM5.3-Flash", planned=5, finished=False)
    _trial(job, "kv-store__aaa", reward=1.0,
           tests=[{"name": "t.py::test_a", "status": "passed"}, {"name": "t.py::test_b", "status": "passed"}],
           steps=[{"step_id": 1, "source": "user", "message": "do it"},
                  {"step_id": 2, "source": "agent", "message": "", "reasoning_content": "think",
                   "tool_calls": [{"tool_call_id": "c1", "function_name": "Bash", "arguments": {"command": "ls"}}],
                   "observation": {"results": [{"source_call_id": "c1", "content": "x" * 5000,
                                                "extra": {"is_error": True}}]}}])
    _trial(job, "compressor__bbb", reward=0.0, final_text="",
           tests=[{"name": "t.py::test_c", "status": "failed", "message": "assert"}])
    _trial(job, "torch__ccc", exception="VerifierTimeoutError")
    _trial(job, "provider__ddd", reward=0.0, exception="NonZeroAgentExitCodeError", stop="api_error")
    _trial(job, "running__eee", finished=False)
    _write(job / "kv-store__aaa" / "verifier" / "test-stdout.txt", "line\n" * 3000)
    _lifecycle(job, "kv-store__aaa", queued_at="07:50:00", prepare_started_at="07:58:00",
               prepare_finished_at="07:58:40", started_at="07:59:59", finished_at="08:05:01",
               prepare={"status": "prepared", "items": [
                   {"kind": "pull", "image": "alexgshaw/kv-store:1", "status": "pulled", "seconds": 38.5, "attempts": 2},
                   {"kind": "pull", "image": "alexgshaw/verifier:1", "status": "present", "seconds": 0.1,
                    "shared": True}]})
    _lifecycle(job, "compressor__bbb", queued_at="07:50:00", prepare_started_at="07:59:30",
               started_at="07:59:50", prepare_finished_at="08:00:00", finished_at="08:05:02",
               prepare={"status": "failed", "items": [
                   {"kind": "build", "image": "metacodes-prebuild-abc", "status": "failed", "seconds": 30,
                    "attempts": 3, "error": "pip install failed"},
                   {"kind": "pull", "image": "x", "status": "exploded"}]})
    _lifecycle(job, "torch__ccc", queued_at="07:59:00", started_at="08:00:00", finished_at="08:05:00",
               prepare={"status": "skipped"})
    _lifecycle(job, "running__eee", queued_at="08:30:00", started_at="08:35:00", prepare_started_at="08:35:00.200000",
               prepare_finished_at="08:36:00", prepare={"status": "present", "items": []})
    _lifecycle(job, "queued__zzz", queued_at="08:39:00")
    _write(job / data.LIFECYCLE_DIR / "provider__ddd.json", "{not json")
    _write(job / "kv-store__aaa" / "agent" / "metacodes-stderr.log", "warning: x\n")
    _job(root, "qwen-pilot", "qwen/qwen3.8-max", planned=1)

    metrics = _job(root, "metrics-job", "metask/model", 2)
    first = _trial(metrics, "same__first", reward=0)
    second = _trial(metrics, "same__second", reward=1)
    document = data.read_json(second / "result.json")
    document["started_at"] = "2026-11-16T09:00:00Z"
    _write(second / "result.json", document)
    offset = _trial(metrics, "same__offset", reward=1)
    document = data.read_json(offset / "result.json")
    document["started_at"] = "2026-11-16T09:00:00+02:00"
    _write(offset / "result.json", document)
    one = _trial(metrics, "one__aaa", reward=1)
    document = data.read_json(one / "result.json")
    document["agent_result"].update(n_input_tokens=1920, n_output_tokens=100)
    _write(one / "result.json", document)
    _write(one / "agent/metacodes-output.jsonl", "\n".join(json.dumps(v) for v in [
        {"type": "usage", "input_tokens": 100, "cache_read_input_tokens": 800, "cache_creation_input_tokens": 20,
         "output_tokens": 10},
        {"type": "result", "stop_reason": "end_turn", "text": "done"}]))
    _write(metrics / ".bench-metrics/one__aaa.jsonl", "\n".join(json.dumps(v) for v in [
        {"request": 1, "complete": True, "input_tokens": 920, "output_tokens": 10, "ttft_ms": 100,
         "generation_ms": 1000, "started_at": "2026-11-16T08:00:01Z", "http_status": 200},
        {"request": 2, "complete": True, "input_tokens": 1000, "output_tokens": 90, "ttft_ms": 300,
         "generation_ms": 3000},
        {"request": 3, "complete": False, "input_tokens": 5}]) + "\n{partial")
    killed = _trial(metrics, "killed__aaa", reward=0)
    _write(killed / "agent/metacodes-output.jsonl", json.dumps(
        {"type": "usage", "input_tokens": 100, "cache_read_input_tokens": 800, "output_tokens": 20}))
    _trial(metrics, "infra__one", exception="VerifierTimeoutError")
    # Unknown price for a model that used tokens: cost stays unknown.
    unknown = _trial(metrics, "free__zzz", reward=1)
    document = data.read_json(unknown / "result.json")
    document["agent_result"]["cost_usd"] = 0
    _write(unknown / "result.json", document)
    # A config.json older than any result: the fallback start time is its mtime.
    nostart = _trial(metrics, "nostart__x", finished=False)
    os.utime(nostart / "config.json", ns=(1_700_000_000_123_456_789, 1_700_000_000_123_456_789))
    del first


def _lifecycle(job: Path, trial: str, **fields) -> None:
    record = {"schema_version": 1, "trial": trial, "task": trial.split("__")[0], "queued_at": None,
              "prepare_started_at": None, "prepare_finished_at": None, "started_at": None, "finished_at": None,
              "prepare": None}
    for key, value in fields.items():
        record[key] = f"2026-11-16T{value}Z" if key.endswith("_at") else value
    _write(job / data.LIFECYCLE_DIR / (trial + ".json"), record)


def file_outputs(root: Path):
    library = data.Library([root])
    jobs = {name: data.job_view(path) for name, path in library.jobs().items()}
    trials = {f"{name}|{trial.name}": data.trial_detail(trial)
              for name, path in library.jobs().items() for trial in data.trial_dirs(path)}
    return {"overview": library.overview(), "jobs": jobs, "trials": trials,
            "csv": {name: data.job_csv(view) for name, view in jobs.items()},
            "summary": data.merge_summaries(view["summary"] for view in library.overview())}


def store_outputs(library: StoreLibrary):
    jobs = {name: library.job_view(name) for name in library.job_names()}
    trials = {}
    for name, view in jobs.items():
        for row in view["rows"]:
            trials[f"{name}|{row['trial']}"] = library.trial_detail(name, row["trial"])
    return {"overview": library.overview(), "jobs": jobs, "trials": trials,
            "csv": {name: data.job_csv(view) for name, view in jobs.items()},
            "summary": data.merge_summaries(view["summary"] for view in library.overview())}


def table_dump(store: Store):
    with store.read() as tx:
        return {table: sorted(tuple(migrate._comparable(table, row)) for row in tx.query(
            f"SELECT {', '.join(schema.COLUMNS[table])} FROM {table}")) for table, _ in schema.TABLES}


def hold_byte_lock(fd):
    if os.name == "nt":
        import msvcrt
        os.lseek(fd, 0, os.SEEK_SET)
        msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
    else:
        import fcntl
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)


def release_byte_lock(fd):
    if os.name == "nt":
        import msvcrt
        os.lseek(fd, 0, os.SEEK_SET)
        msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
    else:
        import fcntl
        fcntl.flock(fd, fcntl.LOCK_UN)


class StoreCase(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.temp, True)
        self.root = self.temp / "jobs"
        self.root.mkdir()

    def sqlite(self, name="bench.sqlite3") -> Store:
        store = Store(store_config.SqliteConfig(self.temp / name))
        self.addCleanup(store.close)
        return store


class EquivalenceTest(StoreCase):
    def test_store_views_equal_file_views_and_survive_the_files(self):
        frozen_time(self)
        build_fixture(self.root)
        expected = normal(file_outputs(self.root))
        library = StoreLibrary(self.sqlite(), [self.root])
        library.sync()
        actual = normal(store_outputs(library))
        self.assertEqual(sorted(actual["jobs"]), ["glm-pilot", "metrics-job", "qwen-pilot"])
        self.assertEqual(len(actual["trials"]), 13)
        for key in ("overview", "jobs", "trials", "csv", "summary"):
            with self.subTest(key=key):
                self.assertEqual(actual[key], expected[key])
        # Spot checks that the comparison covers real metrics.
        metrics = actual["jobs"]["metrics-job"]
        row = next(r for r in metrics["rows"] if r["trial"] == "one__aaa")
        self.assertEqual((row["tps"], row["ttft_ms"], row["initial_input_tokens"]), (25, 200, 920))
        self.assertEqual(metrics["summary"]["first_pass_rate"], 0.75)
        lives = {r["trial"]: r["lifecycle"] for r in actual["jobs"]["glm-pilot"]["rows"]}
        ready = lives["kv-store__aaa"]
        self.assertEqual([ready[k] for k in ("queue_s", "prepare_s", "ready_wait_s", "unprepared_wait_s",
                                             "prepare_running_s", "total_s")], [480, 40, 79, None, None, 421])
        self.assertEqual(ready["prepare"], {"status": "prepared", "error": None, "items": [
            {"kind": "pull", "image": "alexgshaw/kv-store:1", "status": "pulled", "seconds": 38.5, "attempts": 2,
             "shared": False, "error": None},
            {"kind": "pull", "image": "alexgshaw/verifier:1", "status": "present", "seconds": 0.1, "attempts": None,
             "shared": True, "error": None}]})
        caught = lives["compressor__bbb"]
        self.assertEqual([caught[k] for k in ("queue_s", "prepare_s", "ready_wait_s", "prepare_running_s", "total_s")],
                         [570, 20, None, 10, 332])
        self.assertEqual([(i["status"], i["error"]) for i in caught["prepare"]["items"]],
                         [("failed", "pip install failed")])
        unprepared = lives["torch__ccc"]
        self.assertEqual([unprepared[k] for k in ("queue_s", "prepare_s", "ready_wait_s", "prepare_running_s",
                                                  "total_s")], [60, None, None, None, 300])
        self.assertEqual(unprepared["prepare"]["status"], "skipped")
        going = lives["running__eee"]
        self.assertEqual([going[k] for k in ("queue_s", "prepare_s", "ready_wait_s", "prepare_running_s", "total_s",
                                             "finished_at")], [300, None, None, 59.8, 300, None])
        self.assertIsNone(lives["provider__ddd"])
        self.assertNotIn("queued__zzz", lives)
        self.assertTrue(all(r["lifecycle"] is None for r in metrics["rows"]))
        detail = actual["trials"]["glm-pilot|kv-store__aaa"]
        self.assertEqual(detail["row"]["lifecycle"], ready)
        self.assertIn("more chars", detail["steps"][1]["observations"][0]["content"])
        self.assertTrue(detail["verifier_output"].startswith("…"))

        # The page reads the store: removing every file changes nothing.
        shutil.rmtree(self.root)
        self.root.mkdir()
        library.sync()
        self.assertEqual(normal(store_outputs(library)), actual)

    def test_http_serves_the_same_views_from_the_store(self):
        frozen_time(self)
        build_fixture(self.root)
        expected = normal(file_outputs(self.root))
        store = self.sqlite()
        http = server.make_server(Workbench(StoreLibrary(store, [self.root])), "127.0.0.1", 0)
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        base = f"http://127.0.0.1:{http.server_address[1]}"

        def get(path):
            with urllib.request.urlopen(base + path, timeout=10) as response:
                return response.read()

        def strip_pricing(document):
            return {k: v for k, v in document.items() if k not in ("pricing", "costs_by_schedule")}

        def labelled(view):
            # The service adds suite/category display fields (bench-suites)
            # and the profile and metacodes version of the launch (none here).
            return {**view, **suites.label(suites.infer(view.get("dataset"))), "profile": None, "metacodes": None}

        jobs = json.loads(get("/api/jobs"))
        self.assertEqual([strip_pricing(view) for view in jobs["jobs"]], [labelled(view) for view in expected["overview"]])
        self.assertIn("terminal-bench-2.1", {view.get("suite") for view in jobs["jobs"]})
        self.assertEqual(jobs["summary"], expected["summary"])
        self.assertEqual(jobs["storage"]["format"], "SQLite")
        self.assertEqual(jobs["storage"]["database"]["location"], str(self.temp / "bench.sqlite3"))
        shutil.rmtree(self.root / "metrics-job")  # served from the store now
        self.assertEqual(strip_pricing(json.loads(get("/api/job?name=metrics-job"))), labelled(expected["jobs"]["metrics-job"]))
        self.assertEqual(get("/api/job.csv?name=metrics-job").decode(), expected["csv"]["metrics-job"])
        shutil.rmtree(self.root / "glm-pilot")
        served = json.loads(get("/api/job?name=glm-pilot"))
        self.assertEqual(strip_pricing(served), labelled(expected["jobs"]["glm-pilot"]))
        self.assertEqual({r["trial"]: (r["lifecycle"] or {}).get("ready_wait_s") for r in served["rows"]}["kv-store__aaa"], 79)
        self.assertEqual(json.loads(get("/api/trial?job=glm-pilot&trial=compressor__bbb"))["row"]["lifecycle"]["prepare_running_s"], 10)
        detail = json.loads(get("/api/trial?job=metrics-job&trial=one__aaa"))
        file_row = next(r for r in expected["jobs"]["metrics-job"]["rows"] if r["trial"] == "one__aaa")
        self.assertEqual(strip_pricing(detail), {**expected["trials"]["metrics-job|one__aaa"], "row": file_row})


    def test_workbuddy_nested_runs_are_stored_identically(self):
        """bench-suites puts a WorkBuddy run's Harbor trials under
        <job>/workbuddy/<run>/<trial>; the store must find, classify and
        project them exactly like data.trial_dirs, and keep serving them
        after the files are gone."""
        frozen_time(self)
        job = _job(self.root, "bench-wb", "metask/session-model", planned=3)
        run_a = job / data.NESTED_RUNS / "metacodes-bench-wb"
        _write(run_a / "config.json", {"job_name": "metacodes-bench-wb"})
        _write(run_a / "result.json", {"started_at": "2026-11-16T08:00:00Z"})
        _trial(run_a, "bug_fix-easy-alpha__wb1", reward=1.0,
               tests=[{"name": "t.py::test_a", "status": "passed"}])
        _write(run_a / "bug_fix-easy-alpha__wb1" / "agent" / "metacodes-stderr.log", "warning\n")
        _trial(run_a, "data_quality-hard-beta__wb2", reward=0.0)
        _write(run_a / ".bench-metrics" / "bug_fix-easy-alpha__wb1.jsonl", json.dumps(
            {"request": 1, "complete": True, "input_tokens": 50, "output_tokens": 5, "ttft_ms": 120,
             "generation_ms": 500}))
        run_b = job / data.NESTED_RUNS / "metacodes-bench-wb-retry"
        _trial(run_b, "doc-easy-gamma__wb3", finished=False)
        _trial(job, "top__level", reward=1.0)  # a top-level trial still counts
        # Not a trial: no config.json, or not a <task>__<id> directory.
        _write(run_b / "half__made" / "result.json", {})
        _write(job / data.NESTED_RUNS / "notes.txt", "x")

        expected = normal(file_outputs(self.root))
        self.assertEqual(sorted(r["trial"] for r in expected["jobs"]["bench-wb"]["rows"]),
                         ["bug_fix-easy-alpha__wb1", "data_quality-hard-beta__wb2", "doc-easy-gamma__wb3",
                          "top__level"])
        store = self.sqlite()
        library = StoreLibrary(store, [self.root])
        library.sync()
        actual = normal(store_outputs(library))
        for key in ("overview", "jobs", "trials", "csv", "summary"):
            with self.subTest(key=key):
                self.assertEqual(actual[key], expected[key])
        row = next(r for r in actual["jobs"]["bench-wb"]["rows"] if r["trial"] == "bug_fix-easy-alpha__wb1")
        self.assertEqual((row["status"], row["ttft_ms"]), ("pass", 120))
        with store.read() as tx:
            kinds = dict(((relpath), (trial, kind)) for relpath, trial, kind in tx.query(
                "SELECT relpath, trial, kind FROM files WHERE job = ?", ("bench-wb",)))
        prefix = "workbuddy/metacodes-bench-wb/"
        # A trial is keyed by its directory relative to the job.
        trial_key = prefix + "bug_fix-easy-alpha__wb1"
        self.assertEqual(kinds[prefix + "bug_fix-easy-alpha__wb1/result.json"], (trial_key, "trial_result"))
        self.assertEqual(kinds[prefix + "bug_fix-easy-alpha__wb1/agent/metacodes-stderr.log"],
                         (trial_key, "agent_log"))
        self.assertEqual(kinds[prefix + ".bench-metrics/bug_fix-easy-alpha__wb1.jsonl"],
                         (trial_key, "request_metrics"))
        self.assertEqual(kinds[prefix + "config.json"], (None, "job_other"))
        self.assertEqual(kinds["workbuddy/metacodes-bench-wb-retry/half__made/result.json"], (None, "job_other"))

        # A finishing nested trial updates; then the store outlives the files.
        _trial(run_b, "doc-easy-gamma__wb3", reward=1.0)
        expected = normal(file_outputs(self.root))
        library.sync()
        self.assertEqual(normal(store_outputs(library))["jobs"], expected["jobs"])
        shutil.rmtree(self.root)
        self.root.mkdir()
        library.sync()
        self.assertEqual(normal(store_outputs(library))["jobs"], expected["jobs"])


class IngestTest(StoreCase):
    def test_a_held_jobs_lock_whose_file_is_empty_is_reported_busy_and_left_empty(self):
        path = self.root / ingest.ROOT_LOCK
        held = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        self.addCleanup(os.close, held)
        hold_byte_lock(held)
        with self.assertRaisesRegex(ValueError, "正在导入或同步"):
            with ingest.root_lock(self.root, wait=False):
                self.fail("took a jobs lock another process holds")
        self.assertEqual(path.stat().st_size, 0)
        release_byte_lock(held)
        with ingest.root_lock(self.root, wait=False):
            pass
        self.assertEqual(path.stat().st_size, 0)

    def test_reingest_is_a_noop_and_changes_update(self):
        build_fixture(self.root)
        store = self.sqlite()
        first = ingest.ingest_root(store, self.root)
        self.assertEqual({j.outcome for j in first.jobs}, {"new"})
        before = table_dump(store)
        again = ingest.ingest_root(store, self.root)
        self.assertEqual({j.outcome for j in again.jobs}, {"unchanged"})
        self.assertEqual(table_dump(store), before)
        verified = ingest.ingest_root(store, self.root, verify=True)
        self.assertEqual({j.outcome for j in verified.jobs}, {"unchanged"})

        # The running trial finishes; one file disappears; a new trial appears.
        running = self.root / "glm-pilot" / "running__eee"
        _trial(self.root / "glm-pilot", "running__eee", reward=1.0)
        (self.root / "glm-pilot" / "kv-store__aaa" / "agent" / "metacodes-stderr.log").unlink()
        _trial(self.root / "glm-pilot", "late__fff", reward=0.0)
        result = ingest.ingest_job(store, self.root / "glm-pilot")
        self.assertEqual(result.outcome, "updated")
        self.assertEqual(result.files_removed, 1)
        library = StoreLibrary(store)
        rows = {r["trial"]: r for r in library.job_view("glm-pilot")["rows"]}
        self.assertEqual(rows["running__eee"]["status"], "pass")
        self.assertIn("late__fff", rows)
        self.assertEqual(library.trial_detail("glm-pilot", "kv-store__aaa")["stderr"], "")
        frozen_time(self)
        self.assertEqual(normal(library.job_view("glm-pilot")), normal(data.job_view(self.root / "glm-pilot")))
        with store.read() as tx:
            self.assertEqual(tx.one("SELECT status, reward FROM trials WHERE job = ? AND name = ?",
                                    ("glm-pilot", running.name)), ("pass", 1.0))
            # Replaced content leaves no unreferenced blobs behind.
            orphans = tx.one("SELECT COUNT(*) FROM blobs WHERE sha256 NOT IN (SELECT sha256 FROM files "
                             "WHERE sha256 IS NOT NULL)")[0]
        self.assertEqual(orphans, 0)

    def test_partial_writes_converge_and_normalized_tables_hold_details(self):
        job = _job(self.root, "live", "m", planned=1, finished=False)
        trial = _trial(job, "task__a", finished=False)
        _write(trial / "result.json", '{"finished_at": "2026-11-16T08:05:00Z", "verifier_res')
        store = self.sqlite()
        ingest.ingest_root(store, self.root)
        library = StoreLibrary(store)
        self.assertEqual(library.job_view("live")["rows"][0]["status"], "running")
        _trial(job, "task__a", reward=0.5, tests=[{"name": "a", "status": "passed"},
                                                    {"name": "b", "status": "failed", "message": "m" * 900}])
        _write(job / ".bench-metrics/task__a.jsonl", json.dumps(
            {"request": 1, "complete": True, "output_tokens": 30, "ttft_ms": 12.5, "generation_ms": 300,
             "http_status": 200}) + "\n")
        _write(trial / "agent/metacodes-output.jsonl", json.dumps(
            {"type": "usage", "input_tokens": 7, "output_tokens": 3}) + "\n" + json.dumps(
            {"type": "result", "stop_reason": "end_turn", "text": "ok", "turns": 2, "tool_calls": 1}) + "\n")
        ingest.ingest_root(store, self.root)
        self.assertEqual(library.job_view("live")["rows"][0]["status"], "partial")
        with store.read() as tx:
            self.assertEqual(tx.query("SELECT request, complete, ttft_ms, generation_ms, output_tokens, http_status "
                                      "FROM requests"), [(1, 1, 12.5, 300.0, 30.0, 200)])
            self.assertEqual(tx.query("SELECT input_tokens, output_tokens FROM usage_events"), [(7.0, 3.0)])
            tests = tx.query("SELECT name, status, length(message) FROM verifier_tests ORDER BY seq")
            self.assertEqual(tests, [("a", "passed", 0), ("b", "failed", 900)])  # unclipped
            self.assertEqual(tx.one("SELECT status, reward, tests_passed, tests_total, turns, cost_source "
                                    "FROM trials"), ("partial", 0.5, 1, 2, 2, "metacodes_catalog_estimate"))
            kinds = dict(tx.query("SELECT relpath, kind FROM files"))
        self.assertEqual(kinds["task__a/result.json"], "trial_result")
        self.assertEqual(kinds[".bench-metrics/task__a.jsonl"], "request_metrics")
        self.assertEqual(kinds["task__a/verifier/ctrf.json"], "verifier")

    def test_symlinks_are_never_followed(self):
        secret = self.temp / "secret.txt"
        secret.write_text("TOP-SECRET-VALUE")
        job = _job(self.root, "linked", "m", planned=1)
        trial = _trial(job, "task__a", reward=1.0)
        try:
            (trial / "agent" / "leak.txt").symlink_to(secret)
            (job / "outside").symlink_to(self.temp, target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest("symlinks unavailable")
        store = self.sqlite()
        ingest.ingest_root(store, self.root)
        with store.read() as tx:
            paths = [row[0] for row in tx.query("SELECT relpath FROM files")]
            contents = [ingest.decode(e, c) for e, c in tx.query("SELECT encoding, content FROM blobs")]
        self.assertNotIn("task__a/agent/leak.txt", paths)
        self.assertFalse(any(p.startswith("outside/") for p in paths))
        self.assertFalse(any(b"TOP-SECRET-VALUE" in c for c in contents))

    def test_worker_reads_reproject_only_the_requested_archived_trial(self):
        frozen_time(self)
        job = _job(self.root, "worker-job", "m", planned=2)
        trial = _trial(job, "task__a", reward=1, steps=[{"tool_calls": [
            {"function_name": "Skill", "arguments": {"name": "review"}}]}])
        sibling = _trial(job, "task__b", reward=0, steps=[])
        _write(job / ".bench-metrics" / (trial.name + ".jsonl"), json.dumps(
            {"request": 1, "complete": True, "output_tokens": 5, "ttft_ms": 120, "generation_ms": 500}))
        store = self.sqlite()
        ingest.ingest_root(store, self.root)
        relpath = sibling.name + "/agent/trajectory.json"
        with store.read() as tx:
            original = tx.one("SELECT sha256 FROM files WHERE relpath = ?", (relpath,))[0]
        content = b'{"steps": 1}'
        digest = hashlib.sha256(content).hexdigest()
        with store.transaction() as tx:
            ingest.put_blob(tx, digest, content)
            tx.execute("UPDATE files SET sha256 = ? WHERE relpath = ?", (digest, relpath))
            tx.execute("UPDATE trials SET projection = 'old'")
            tx.execute("UPDATE trials SET detail_json = '{}' WHERE name = ?", (trial.name,))
        shutil.rmtree(job)
        node = types.SimpleNamespace(root=self.temp, cfg={"store": {"backend": "sqlite", "path": "bench.sqlite3"}})
        with patch.object(ingest, "project_trial", wraps=ingest.project_trial) as project, patch.object(
                ingest, "refresh_job_header", wraps=ingest.refresh_job_header) as header, patch.object(
                ingest, "stderr_log") as log:
            details = [results.worker_result(node, "trial", job, trial.name) for _ in range(5)]
            self.assertTrue(all(detail == details[0] for detail in details))
            self.assertEqual(details[0]["skills"], [["review", 1]])
            self.assertEqual(details[0]["row"]["ttft_ms"], 120)
            self.assertEqual([call.args[0].name for call in project.call_args_list], [trial.name])
            header.assert_not_called()
            log.assert_not_called()
            self.assertEqual(len(results.worker_result(node, "job", job)["rows"]), 2)
            self.assertEqual(results.worker_result(node, "trial", job, sibling.name)["row"]["reward"], 0)
            self.assertEqual(log.call_count, 2)
            self.assertIn(sibling.name, log.call_args.args[0])
            with store.read() as tx:
                self.assertEqual(tx.one("SELECT projection FROM trials WHERE name = ?", (sibling.name,)), ("old",))
            with store.transaction() as tx:
                tx.execute("UPDATE files SET sha256 = ? WHERE relpath = ?", (original, relpath))
            self.assertEqual(results.worker_result(node, "trial", job, sibling.name)["row"]["reward"], 0)
            self.assertEqual(log.call_count, 2)
        with store.read() as tx:
            self.assertEqual(tx.query("SELECT DISTINCT projection FROM trials"), [(ingest.PROJECTION,)])

    def test_worker_trial_resolves_nested_duplicate_names_like_library(self):
        job = _job(self.root, "nested", "m", planned=2)
        first = _trial(job / data.NESTED_RUNS / "a", "task__a", reward=1)
        _trial(job / data.NESTED_RUNS / "z", "task__a", reward=0)
        store = self.sqlite()
        ingest.ingest_root(store, self.root)
        expected = StoreLibrary(store).trial_detail(job.name, first.name)
        with store.transaction() as tx:
            tx.execute("UPDATE trials SET projection = 'old'")
        shutil.rmtree(job)
        node = types.SimpleNamespace(root=self.temp, cfg={"store": {"backend": "sqlite", "path": "bench.sqlite3"}})
        with patch.object(ingest, "project_trial", wraps=ingest.project_trial) as project:
            detail = results.worker_result(node, "trial", job, first.name)
        self.assertEqual(detail["row"]["reward"], expected["row"]["reward"])
        self.assertEqual(project.call_count, 1)
        with store.read() as tx:
            self.assertEqual(tx.query("SELECT name FROM trials WHERE projection = ?", (ingest.PROJECTION,)),
                             [(first.relative_to(job).as_posix(),)])

    def test_worker_trial_checks_source_before_refreshing(self):
        job = _job(self.root, "worker-job", "m", planned=1)
        trial = _trial(job, "task__a", reward=1)
        store = self.sqlite()
        ingest.ingest_root(store, self.root)
        with store.transaction() as tx:
            tx.execute("UPDATE jobs SET source_dir = ?, projection = 'old'", (str(self.temp / "other"),))
            tx.execute("UPDATE trials SET projection = 'old'")
        node = types.SimpleNamespace(root=self.temp, cfg={"store": {"backend": "sqlite", "path": "bench.sqlite3"}})
        with patch.object(ingest, "project_trial") as project, patch.object(ingest, "refresh_job_header") as header:
            for operation, name in (("trial", trial.name), ("job", None)):
                self.assertIsNone(results.worker_result(node, operation, job, name))
            project.assert_not_called()
            header.assert_not_called()

    def test_worker_trial_never_projects_an_unsafe_stored_key(self):
        job = _job(self.root, "worker-job", "m", planned=1)
        trial = _trial(job, "task__a", reward=1)
        store = self.sqlite()
        ingest.ingest_root(store, self.root)
        with store.transaction() as tx:
            tx.execute("UPDATE trials SET name = ?, projection = 'old'", ("../" + trial.name,))
        node = types.SimpleNamespace(root=self.temp, cfg={"store": {"backend": "sqlite", "path": "bench.sqlite3"}})
        with patch.object(ingest, "project_trial") as project, patch.object(ingest, "stderr_log") as log:
            self.assertEqual(results.worker_result(node, "trial", job, trial.name)["row"]["reward"], 1)
            project.assert_not_called()
            self.assertIn("unsafe path", log.call_args.args[0])

    def test_concurrent_worker_trial_reads_recheck_versions_under_lock(self):
        job = _job(self.root, "worker-job", "m", planned=1)
        trial = _trial(job, "task__a", reward=1)
        store = self.sqlite()
        ingest.ingest_root(store, self.root)
        with store.transaction() as tx:
            tx.execute("UPDATE jobs SET projection = 'old'")
            tx.execute("UPDATE trials SET projection = 'old'")
        shutil.rmtree(job)
        node = types.SimpleNamespace(root=self.temp, cfg={"store": {"backend": "sqlite", "path": "bench.sqlite3"}})
        barrier = threading.Barrier(2)
        root_lock = ingest.root_lock

        @contextlib.contextmanager
        def lock(root):
            barrier.wait(timeout=10)
            with root_lock(root):
                yield

        with patch.object(ingest, "root_lock", side_effect=lock), patch.object(
                ingest, "project_trial", wraps=ingest.project_trial) as project, patch.object(
                ingest, "refresh_job_header", wraps=ingest.refresh_job_header) as header:
            with ThreadPoolExecutor(max_workers=2) as pool:
                reads = [pool.submit(results.worker_result, node, "trial", job, trial.name) for _ in range(2)]
                self.assertEqual([read.result(timeout=15)["row"]["reward"] for read in reads], [1, 1])
            self.assertEqual(project.call_count, 1)
            self.assertEqual(header.call_count, 1)

    def test_worker_summary_and_final_still_reject_incomplete_ingestion(self):
        job = _job(self.root, "worker-job", "m", planned=1)
        node = types.SimpleNamespace(root=self.temp, cfg={"store": {"backend": "sqlite", "path": "bench.sqlite3"}})
        for operation in ("summary", "final"):
            for result in (ingest.JobResult(job.name, "skipped"),
                           ingest.JobResult(job.name, "updated", trials_failed=1)):
                with self.subTest(operation=operation, result=result), patch.object(
                        ingest, "ingest_job", return_value=result), self.assertRaisesRegex(ValueError, "尚未完整"):
                    results.worker_result(node, operation, job)

    def test_stale_projection_is_recomputed_from_stored_bytes(self):
        frozen_time(self)
        build_fixture(self.root)
        expected = normal(file_outputs(self.root)["jobs"])
        store = self.sqlite()
        ingest.ingest_root(store, self.root)
        shutil.rmtree(self.root)
        with store.transaction() as tx:
            tx.execute("UPDATE trials SET projection = 'old', row_json = '{}'")
            tx.execute("UPDATE jobs SET projection = 'old'")
        refreshed = ingest.refresh_projections(store)
        self.assertEqual(sorted(r.name for r in refreshed), ["glm-pilot", "metrics-job", "qwen-pilot"])
        library = StoreLibrary(store)
        self.assertEqual(normal({n: library.job_view(n) for n in library.job_names()}), expected)

    def test_conflicting_job_name_from_another_live_directory_is_skipped(self):
        _trial(_job(self.root, "dup", "first", planned=1), "task__a", reward=1.0)
        other = self.temp / "other"
        _trial(_job(other, "dup", "second", planned=1), "task__a", reward=0.0)
        store = self.sqlite()
        ingest.ingest_root(store, self.root)
        result = ingest.ingest_root(store, other)
        self.assertEqual(result.jobs[0].outcome, "skipped")
        self.assertEqual(StoreLibrary(store).job_view("dup")["model"], "first")

    def test_worker_sync_ingests_periodically_and_at_the_end(self):
        jobs = self.temp / "worker-jobs"
        spec = {"jobs_dir": str(jobs), "name": "bench-live",
                "store": {"backend": "sqlite", "path": str(self.temp / "worker.sqlite3")}}
        sync = ingest.WorkerSync(spec, interval=0.05)
        sync.start()
        job = _job(jobs, "bench-live", "m", planned=2, finished=False)
        _trial(job, "a__1", reward=1.0)
        store = self.sqlite("worker.sqlite3")
        library = StoreLibrary(store)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not library.job_names():
            time.sleep(0.05)
        self.assertEqual(library.job_names(), ["bench-live"])  # periodic, before the end
        _trial(job, "b__2", reward=0.0)
        _job(jobs, "bench-live", "m", planned=2, finished=True)
        records = jobs / ".bench-runs"
        atomic_json(records / "bench-live.json", {"name": "bench-live", "status": "running", "model": "m"})
        atomic_json(records / "bench-live.spec", {"name": "bench-live"})
        (records / "bench-live.log").write_bytes(b"worker log\n")
        beats = []
        sync.finish(lambda: beats.append(1), {"name": "bench-live", "status": "finished", "model": "m", "exit_code": 0})
        view = library.job_view("bench-live")
        self.assertFalse(view["running"])
        self.assertEqual(view["summary"]["counts"]["pass"], 1)
        self.assertEqual(library.run_record("bench-live")["status"], "finished")
        with store.read() as tx:
            log = tx.one("SELECT b.encoding, b.content FROM runs r JOIN blobs b ON b.sha256 = r.log_sha256")
        self.assertEqual(ingest.decode(*log), b"worker log\n")

    def test_worker_sync_failure_never_raises(self):
        sync = ingest.WorkerSync({"jobs_dir": str(self.temp), "name": "x",
                                  "store": {"backend": "sqlite", "path": str(self.temp / "dir-not-file")}})
        (self.temp / "dir-not-file").mkdir()
        _job(self.temp, "x", "m", planned=1)
        sync.finish(lambda: None, {"name": "x", "status": "failed"})
        self.assertTrue(sync.failed)


class SchemaTest(StoreCase):
    def test_migrations_are_recorded_once_and_newer_schemas_refused(self):
        store = self.sqlite()
        store.close()
        reopened = self.sqlite()
        with reopened.read() as tx:
            self.assertEqual(tx.query("SELECT version FROM schema_migrations ORDER BY version"),
                             [(version,) for version, _, _ in schema.MIGRATIONS])
        with reopened.transaction() as tx:
            tx.execute("INSERT INTO schema_migrations (version, description, applied_at) VALUES (?, ?, ?)",
                       (schema.LATEST + 1, "future", "now"))
        reopened.close()
        with self.assertRaisesRegex(StoreError, "newer"):
            Store(store_config.SqliteConfig(self.temp / "bench.sqlite3"))

    def test_illegal_states_are_rejected_by_the_database(self):
        store = self.sqlite()
        with store.transaction() as tx:
            tx.execute("INSERT INTO jobs (name, source_dir, header_json, inputs_digest, projection, ingested_at) "
                       "VALUES ('j', '/x', '{}', 'd', 'p', 'now')")
        base = dict(job="j", name="t", task="t", status="pass", reward=1.0, empty_final=False, tokens_partial=False,
                    cost_usd=None, cost_source="unavailable", requests=0, profiled_requests=0, row_json="{}",
                    detail_json="{}", inputs_digest="d", projection="p", ingested_at="now")
        bad = [dict(status="bogus"), dict(status="pass", reward=None), dict(cost_usd=1.0, cost_source="unavailable"),
               dict(cost_source="provider_bill"), dict(job="missing")]
        for override in bad:
            values = {**base, **override}
            with self.subTest(override=override), self.assertRaises(sqlite3.IntegrityError):
                with store.transaction() as tx:
                    tx.execute(f"INSERT INTO trials ({', '.join(values)}) VALUES ({', '.join('?' for _ in values)})",
                               list(values.values()))
        with self.assertRaises(sqlite3.IntegrityError):
            with store.transaction() as tx:
                tx.execute("INSERT INTO files (job, relpath, kind, size, mtime_ns, state, sha256) "
                           "VALUES ('j', 'a', 'job_other', 1, 1, 'stored', NULL)")
        with self.assertRaises(sqlite3.IntegrityError):
            with store.transaction() as tx:
                tx.execute("INSERT INTO runs (name, status, record_json, source_dir, ingested_at) "
                           "VALUES ('r', 'exploded', '{}', '/x', 'now')")


class ConfigTest(unittest.TestCase):
    def test_passwords_never_enter_the_configuration(self):
        for dsn in ("postgresql://bench:secret@db/bench", "postgresql://bench@db/bench?password=secret",
                    "host=db user=bench password=secret", "postgresql://bench:@db/bench"):
            with self.subTest(dsn=dsn), self.assertRaisesRegex(store_config.ConfigError, "password"):
                store_config.PostgresConfig(dsn)
        config = store_config.PostgresConfig("postgresql://bench@db:5432/bench", "BENCH_PG_PASSWORD")
        self.assertEqual(config.to_json(), {"backend": "postgres", "dsn": "postgresql://bench@db:5432/bench",
                                            "password_env": "BENCH_PG_PASSWORD"})
        with patch.dict(os.environ, {"BENCH_PG_PASSWORD": "s3cret"}):
            self.assertEqual(config.password(), "s3cret")
        with patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(store_config.ConfigError, "not set"):
            config.password()
        with self.assertRaises(store_config.ConfigError):
            store_config.PostgresConfig("postgresql://bench@db/bench", "lower-case")

    def test_dsn_targets_are_recognized_and_never_become_file_names(self):
        for target in ("POSTGRESQL://bench@db/bench", "Postgres://bench@db/bench", "host=db dbname=bench",
                       "  host=db user=bench sslmode=require"):
            with self.subTest(target=target):
                self.assertIsInstance(store_config.from_target(target), store_config.PostgresConfig)
        for target in ("host=db user=u password=s3cret", "POSTGRESQL://u:s3cret@h/db", "postgresql://u@h/d?PASSWORD=s3cret",
                       "user=u PassWord = s3cret host=db", "/tmp/password=s3cret.sqlite3", "mysql://u:s3cret@h/db"):
            with self.subTest(target=target), self.assertRaises(store_config.ConfigError) as caught:
                store_config.from_target(target)
            self.assertNotIn("s3cret", str(caught.exception))
        with self.assertRaises(store_config.ConfigError):
            store_config.SqliteConfig(Path("/tmp/host=db user=u"))
        with self.assertRaises(store_config.ConfigError):
            store_config.parse({"backend": "sqlite", "path": "dbname=x password=s3cret"}, Path("/tmp"))

    def test_postgres_without_psycopg_names_the_optional_dependency(self):
        with patch.dict("sys.modules", {"psycopg": None}), self.assertRaisesRegex(StoreError, "psycopg"):
            Store(store_config.PostgresConfig("postgresql://bench@db/bench"))

    def test_workbench_default_and_explicit_stores(self):
        base = Path(tempfile.gettempdir()).resolve() / "state" / "bench"
        config_path = base / "workbench.json"
        self.assertEqual(store_config.for_workbench({}, config_path),
                         store_config.SqliteConfig(base / "bench.sqlite3"))
        self.assertEqual(store_config.for_workbench({"store": {"backend": "sqlite", "path": "x.db"}}, config_path),
                         store_config.SqliteConfig(base / "x.db"))
        for bad in ({"backend": "mysql"}, {"backend": "sqlite"}, {"backend": "sqlite", "path": "a", "extra": 1},
                    {"backend": "postgres", "dsn": "postgresql://u:p@h/d"}, "sqlite"):
            with self.subTest(bad=bad), self.assertRaises(store_config.ConfigError):
                store_config.for_workbench({"store": bad}, config_path)
        self.assertIsInstance(store_config.from_target("postgresql://u@h/d"), store_config.PostgresConfig)
        self.assertIsInstance(store_config.from_target("~/x.sqlite3"), store_config.SqliteConfig)


class MigrationTest(StoreCase):
    def populated(self) -> Store:
        build_fixture(self.root)
        source = self.sqlite("source.sqlite3")
        ingest.ingest_root(source, self.root)
        records = self.root / ".bench-runs"
        atomic_json(records / "bench-1.json", {"name": "bench-1", "status": "failed", "exit_code": 7})
        (records / "bench-1.log").write_bytes(b"log " * 1000)
        atomic_json(records / "bench-1.spec", {"name": "bench-1", "key_env": "TOKENJOY_API_KEY"})
        ingest.ingest_runs(source, records)
        return source

    def test_copy_verify_resume_and_round_trip(self):
        source = self.populated()
        target = self.sqlite("target.sqlite3")
        with patch.object(migrate, "BATCH", 3), patch.object(migrate, "BLOB_BATCH", 2):
            original = migrate.Tx.executemany
            calls = []

            def interrupted(tx, sql, rows):
                calls.append(sql)
                if len(calls) == 4:
                    raise KeyboardInterrupt  # killed mid-migration
                return original(tx, sql, rows)

            with patch.object(migrate.Tx, "executemany", interrupted), self.assertRaises(KeyboardInterrupt):
                migrate.migrate(source, target)
            report = migrate.migrate(source, target)
        blobs = report.tables["blobs"]
        self.assertGreater(blobs.already_present, 0)  # resumed, not restarted
        self.assertEqual(blobs.copied + blobs.already_present, blobs.source)
        for name, table in report.tables.items():
            with self.subTest(table=name):
                self.assertEqual(table.verified, table.source)
                self.assertEqual(table.target_total, table.source)
        self.assertEqual(table_dump(target), table_dump(source))
        again = migrate.migrate(source, target)
        self.assertEqual(sum(t.copied for t in again.tables.values()), 0)

        back = self.sqlite("back.sqlite3")
        migrate.migrate(target, back)
        self.assertEqual(table_dump(back), table_dump(source))
        frozen_time(self)
        self.assertEqual(normal(store_outputs(StoreLibrary(back))), normal(store_outputs(StoreLibrary(source))))

    def test_conflicting_target_is_refused_untouched(self):
        source = self.populated()
        target = self.sqlite("target.sqlite3")
        migrate.migrate(source, target)
        with target.transaction() as tx:
            tx.execute("UPDATE trials SET reward = 0.25 WHERE name = 'kv-store__aaa'")
            tx.execute("DELETE FROM runs")
        before = table_dump(target)
        with self.assertRaisesRegex(migrate.MigrationConflict, "trials"):
            migrate.migrate(source, target)
        self.assertEqual(table_dump(target), before)
        with self.assertRaisesRegex(StoreError, "same database"):
            migrate.migrate(source, Store(store_config.SqliteConfig(self.temp / "source.sqlite3")))

    def test_verification_rehashes_target_blobs(self):
        source = self.populated()
        target = self.sqlite("target.sqlite3")
        migrate.migrate(source, target)
        with target.transaction() as tx:
            digest = tx.one("SELECT sha256 FROM blobs WHERE encoding = 'identity' LIMIT 1")[0]
            tx.execute("UPDATE blobs SET content = ? WHERE sha256 = ?", (b"tampered", digest))
        with self.assertRaisesRegex(StoreError, "content hash"):
            migrate.verify(source, target, migrate.Report({}, {}))


class CliTest(StoreCase):
    def bench(self, *argv):
        output = io.StringIO()
        with redirect_stdout(output):
            code = cli.main(["--state-root", str(self.temp / "state"), *argv])
        return code, output.getvalue()

    def test_worker_list_reads_its_original_jobs_without_manager_receipts(self):
        job = _job(self.root, "worker-run", "model", planned=1)
        _trial(job, "task__one", reward=1)
        config = store_config.SqliteConfig(self.temp / "state/bench/bench.sqlite3")
        with contextlib.closing(Store(config)) as store:
            ingest.ingest_job(store, job)
            with store.transaction() as tx:
                tx.execute("INSERT INTO worker_jobs (job, log_tail, ingested_at) VALUES (?, '', ?)",
                           (job.name, FIXED.isoformat()))
        other = self.temp / "other-jobs"
        other.mkdir()
        for root, names in ((self.root, [job.name]), (other, [])):
            code, output = self.bench("list", "--jobs-dir", str(root), "--json")
            self.assertEqual(code, 0, output)
            self.assertEqual([view["name"] for view in json.loads(output)["jobs"]], names)
            with contextlib.closing(cli.open_local(config, root)) as bench:
                self.assertEqual([view["name"] for view in bench.jobs()["jobs"]], names)
                self.assertEqual(bool(bench.job(job.name)), bool(names))
                self.assertEqual(bool(bench.trial(job.name, "task__one")), bool(names))

    def test_db_import_status_migrate_switch_and_list(self):
        frozen_time(self)
        build_fixture(self.root)
        code, out = self.bench("db", "import", "--jobs-dir", str(self.root), "--json")
        self.assertEqual(code, 0, out)
        imported = json.loads(out)
        self.assertEqual(len(imported["imports"][0]["jobs"]), 3)
        self.assertEqual(imported["database"]["location"], str((self.temp / "state/bench/bench.sqlite3").resolve()))
        config = settings_of(self.temp)
        self.assertNotIn("jobs_dir", config)  # import does not change the workbench's jobs directory
        code, out = self.bench("db", "status", "--json")
        status = json.loads(out)
        self.assertEqual((status["counts"]["jobs"], status["counts"]["trials"]), (3, 13))
        target = self.temp / "moved.sqlite3"
        code, out = self.bench("db", "migrate", "--to", str(target), "--switch", "--json")
        self.assertEqual(code, 0, out)
        self.assertTrue(json.loads(out)["switched"])
        self.assertEqual(settings_of(self.temp)["store"], {"backend": "sqlite", "path": str(target.resolve())})
        # `list` now reads the switched store, which holds the imported jobs.
        code, out = self.bench("list", "--json")
        listed = json.loads(out)["jobs"]
        self.assertEqual(sorted(j["name"] for j in listed), ["glm-pilot", "metrics-job", "qwen-pilot"])
        self.assertEqual(normal(listed), normal(file_outputs(self.root)["overview"]))

    def test_migrate_to_a_keyword_dsn_never_writes_or_prints_its_password(self):
        build_fixture(self.root)
        self.assertEqual(self.bench("db", "import", "--jobs-dir", str(self.root), "--json")[0], 0)
        before = sorted(p.name for p in self.temp.rglob("*"))
        for target in ("host=db user=u password=s3cret", "POSTGRESQL://u:s3cret@db/bench"):
            errors = io.StringIO()
            with self.subTest(target=target), contextlib.redirect_stderr(errors):
                code, out = self.bench("db", "migrate", "--to", target, "--switch", "--json")
            self.assertEqual(code, 1)
            self.assertNotIn("s3cret", out + errors.getvalue())
            self.assertNotIn("s3cret", json.dumps(settings_of(self.temp)))
            self.assertEqual(sorted(p.name for p in self.temp.rglob("*")), before)
        code, _ = self.bench("db", "status", "--store-sqlite", str(self.temp / "password-s3cret.sqlite3"))
        self.assertEqual(code, 1)
        code, _ = self.bench("db", "status", "--store-sqlite", "postgresql://u@db/bench")
        self.assertEqual(code, 1)
        self.assertNotIn("s3cret", json.dumps(settings_of(self.temp)))

    def test_store_flags_validate_and_persist(self):
        code, _ = self.bench("db", "status", "--store-postgres", "postgresql://u:pw@h/d")
        self.assertEqual(code, 1)
        self.assertNotIn("store", settings_of(self.temp))
        path = self.temp / "chosen.sqlite3"
        code, _ = self.bench("db", "status", "--store-sqlite", str(path))
        self.assertEqual(code, 0)
        self.assertEqual(settings_of(self.temp)["store"]["path"], str(path.resolve()))
        self.assertTrue(path.exists())
        with self.assertRaises(SystemExit):
            self.bench("db")
        with self.assertRaises(SystemExit):
            self.bench("list", "status")
        code, _ = self.bench("db", "migrate", "--to", str(path))
        self.assertEqual(code, 1)  # same database


def unstorable_job(root: Path) -> Path:
    """A job whose files carry text neither driver can bind as-is: a lone
    surrogate in a trajectory (a truncated emoji), NUL in a verifier
    message and in a stop reason."""
    job = _job(root, "odd-text", "m", planned=2)
    _trial(job, "emoji__a", reward=1.0, stop="end\u0000turn",
           tests=[{"name": "t::nul", "status": "failed", "message": "bad\u0000byte \ud83d"}],
           steps=[{"step_id": 1, "source": "agent", "message": "half an emoji \ud83d here"}])
    _trial(job, "plain__b", reward=0.0)
    return job


class TextSafetyTest(StoreCase):
    def test_unencodable_text_is_stored_and_served_like_the_files(self):
        frozen_time(self)
        unstorable_job(self.root)
        expected = normal(file_outputs(self.root))
        store = self.sqlite()
        result = ingest.ingest_root(store, self.root, log=lambda m: None)
        self.assertEqual([(j.name, j.outcome) for j in result.jobs], [("odd-text", "new")])
        library = StoreLibrary(store)
        actual = store_outputs(library)
        # The projections keep the exact text (JSON escapes); only the
        # normalized text columns replace what a database cannot hold.
        self.assertEqual(normal(actual["jobs"]), expected["jobs"])
        self.assertEqual(actual["trials"]["odd-text|emoji__a"]["steps"][0]["message"], "half an emoji \ud83d here")
        with store.read() as tx:
            self.assertEqual(tx.one("SELECT message FROM verifier_tests"), ("bad�byte �",))
            self.assertEqual(tx.one("SELECT stop_reason FROM trials WHERE name = 'emoji__a'"), ("end�turn",))
        # The page serves it as valid UTF-8 JSON.
        http = server.make_server(Workbench(library), "127.0.0.1", 0)
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        url = f"http://127.0.0.1:{http.server_address[1]}/api/trial?job=odd-text&trial=emoji__a"
        with urllib.request.urlopen(url, timeout=10) as response:
            served = json.loads(response.read().decode("utf-8"))
        self.assertEqual(served["steps"][0]["message"], "half an emoji \ud83d here")

    def test_non_utf8_file_name_is_stored(self):
        job = _job(self.root, "odd-name", "m", planned=1)
        _trial(job, "task__a", reward=1.0)
        try:
            (job / "task__a" / os.fsdecode(b"agent/log-\xff.txt")).write_bytes(b"x")
        except (OSError, UnicodeError):
            self.skipTest("this file system refuses non-UTF-8 names")
        store = self.sqlite()
        result = ingest.ingest_root(store, self.root, log=lambda m: None)
        self.assertEqual(result.jobs[0].outcome, "new")
        with store.read() as tx:
            names = {row[0] for row in tx.query("SELECT relpath FROM files")}
        self.assertIn("task__a/agent/log-�.txt", names)
        self.assertEqual(ingest.ingest_root(store, self.root).jobs[0].outcome, "unchanged")

    def test_one_failing_trial_never_drops_the_job(self):
        job = _job(self.root, "partly", "m", planned=2)
        _trial(job, "good__a", reward=1.0)
        _trial(job, "bad__b", reward=0.0)
        store = self.sqlite()
        original = ingest.project_trial

        def flaky(trial_dir):
            if trial_dir.name == "bad__b":
                raise UnicodeEncodeError("utf-8", "\ud83d", 0, 1, "surrogates not allowed")
            return original(trial_dir)

        logged = []
        with patch.object(ingest, "project_trial", flaky):
            result = ingest.ingest_root(store, self.root, log=logged.append)
        self.assertEqual((result.jobs[0].outcome, result.jobs[0].trials_derived, result.jobs[0].trials_failed),
                         ("new", 1, 1))
        self.assertTrue(any("bad__b" in line for line in logged), logged)
        library = StoreLibrary(store)
        self.assertEqual([r["trial"] for r in library.job_view("partly")["rows"]], ["good__a"])
        retried = ingest.ingest_root(store, self.root)  # the next pass derives it
        self.assertEqual(retried.jobs[0].trials_derived, 1)
        self.assertEqual(sorted(r["trial"] for r in library.job_view("partly")["rows"]), ["bad__b", "good__a"])

    def test_legacy_nul_rows_compare_equal_after_migration(self):
        """A SQLite file written before text was cleaned may hold NUL; the
        copy stores the cleaned text and verification accepts it."""
        unstorable_job(self.root)
        source = self.sqlite("source.sqlite3")
        ingest.ingest_root(source, self.root)
        raw = sqlite3.connect(str(self.temp / "source.sqlite3"))
        raw.execute("UPDATE verifier_tests SET message = ?", ("legacy\x00nul",))
        raw.commit()
        raw.close()
        target = self.sqlite("target.sqlite3")
        report = migrate.migrate(source, target)
        self.assertEqual(report.tables["verifier_tests"].verified, report.tables["verifier_tests"].source)
        with target.read() as tx:
            self.assertEqual(tx.one("SELECT message FROM verifier_tests"), ("legacy�nul",))


class PathSafetyTest(StoreCase):
    def crafted(self, relpath: str, job: str = "victim", database: str = "bench.sqlite3") -> Store:
        """A store as someone else could hand it over: a stale projection
        and a file row whose path climbs out of the job directory."""
        _trial(_job(self.root, "victim", "m", planned=1), "x__1", reward=1.0)
        store = self.sqlite(database)
        ingest.ingest_root(store, self.root)
        shutil.rmtree(self.root)
        with store.transaction() as tx:
            digest = tx.one("SELECT sha256 FROM files WHERE relpath = 'x__1/result.json'")[0]
            if job != "victim":
                tx.execute("INSERT INTO jobs (name, source_dir, header_json, inputs_digest, projection, ingested_at) "
                           "SELECT ?, source_dir, header_json, inputs_digest, 'old', ingested_at FROM jobs "
                           "WHERE name = 'victim'", (job,))
                tx.execute("INSERT INTO files (job, relpath, trial, kind, size, mtime_ns, state, sha256) "
                           "SELECT ?, relpath, trial, kind, size, mtime_ns, state, sha256 FROM files "
                           "WHERE job = 'victim'", (job,))
            tx.execute("INSERT INTO files (job, relpath, trial, kind, size, mtime_ns, state, sha256) "
                       "VALUES (?, ?, 'x__1', 'trial_other', 3, 1, 'stored', ?)", (job, relpath, digest))
            tx.execute("UPDATE jobs SET projection = 'old'")
            tx.execute("UPDATE trials SET projection = 'old'")
        return store

    def test_refresh_never_writes_outside_its_temporary_directory(self):
        scratch = self.temp / "scratch" / "a" / "b"
        scratch.mkdir(parents=True)
        crafted = ("x__1/../../../../escape.txt", "x__1/agent/../../../../escape.txt", "/abs/escape.txt",
                   "x__1\\..\\..\\escape.txt", "x__1//escape.txt", "x__1/nul\x00.txt")
        for index, relpath in enumerate(crafted):
            with self.subTest(relpath=relpath), patch.object(tempfile, "tempdir", str(scratch)):
                store = self.crafted(relpath, database=f"crafted-{index}.sqlite3")
                ingest.refresh_projections(store)
                self.assertEqual(sorted(p.name for p in self.temp.rglob("escape.txt")), [])
                self.assertEqual(StoreLibrary(store).job_view("victim")["rows"][0]["status"], "pass")

    def test_unsafe_job_names_and_paths_are_refused(self):
        scratch = self.temp / "s1" / "s2"
        scratch.mkdir(parents=True)
        with patch.object(tempfile, "tempdir", str(scratch)):
            store = self.crafted("x__1/ok.txt", job="../../evil")
            logged = []
            ingest.refresh_projections(store, logged.append)
        self.assertTrue(any("evil" in line for line in logged), logged)
        self.assertEqual(list(self.temp.rglob("evil")), [])
        with self.assertRaisesRegex(StoreError, "unsafe path"):
            ingest.materialize(self.temp, "job", [ingest.Entry("a/../../b", b"", 0)])
        with self.assertRaisesRegex(StoreError, "plain job name"):
            ingest.materialize(self.temp, "..", [])
        # A migration refuses to carry them into another database.
        with self.assertRaisesRegex(StoreError, "unsafe"):
            migrate.migrate(store, self.sqlite("target.sqlite3"))


class IncrementalTest(StoreCase):
    def test_job_result_rewrite_does_not_rederive_trials(self):
        job = _job(self.root, "live", "m", planned=3, finished=False)
        _trial(job, "a__1", reward=1.0)
        _trial(job, "b__2", reward=0.0)
        store = self.sqlite()
        ingest.ingest_root(store, self.root)
        with store.read() as tx:
            before = tx.query("SELECT name, ingested_at, inputs_digest FROM trials ORDER BY name")
        # Harbor rewrites the job's result.json after every trial.
        document = data.read_json(job / "result.json")
        document["n_total_trials"] = 4
        _write(job / "result.json", document)
        _trial(job, "c__3", reward=1.0)
        result = ingest.ingest_job(store, job)
        self.assertEqual((result.outcome, result.trials_derived), ("updated", 1))
        with store.read() as tx:
            after = tx.query("SELECT name, ingested_at, inputs_digest FROM trials ORDER BY name")
            self.assertEqual(tx.one("SELECT planned FROM jobs"), (4,))  # the header follows result.json
        self.assertEqual(after[:2], before)

    def test_a_lifecycle_record_rederives_only_its_own_trial(self):
        job = _job(self.root, "live", "m", planned=2, finished=False)
        _trial(job, "a__1", reward=1.0)
        _trial(job, "b__2", reward=0.0)
        _lifecycle(job, "a__1", queued_at="07:59:00", started_at="08:00:00")
        store = self.sqlite()
        library = StoreLibrary(store, [self.root])
        library.sync()
        with store.read() as tx:
            before = dict((name, stamp) for name, stamp in tx.query("SELECT name, inputs_digest FROM trials"))
        row = next(r for r in library.job_view("live")["rows"] if r["trial"] == "a__1")
        self.assertEqual((row["lifecycle"]["queue_s"], row["lifecycle"]["prepare"]), (60, None))
        _lifecycle(job, "a__1", queued_at="07:59:00", started_at="08:00:00", finished_at="08:05:00",
                   prepare={"status": "skipped"})
        result = ingest.ingest_job(store, job)
        self.assertEqual((result.outcome, result.trials_derived), ("updated", 1))
        with store.read() as tx:
            after = dict((name, stamp) for name, stamp in tx.query("SELECT name, inputs_digest FROM trials"))
        self.assertEqual(after["b__2"], before["b__2"])
        self.assertNotEqual(after["a__1"], before["a__1"])
        row = next(r for r in library.job_view("live")["rows"] if r["trial"] == "a__1")
        self.assertEqual((row["lifecycle"]["total_s"], row["lifecycle"]["prepare"]["status"]), (300, "skipped"))
        self.assertEqual(normal(row), normal(next(r for r in data.job_view(job)["rows"] if r["trial"] == "a__1")))

    def test_oversize_files_project_like_the_live_files(self):
        """Files over the stored size keep their size and tail: stderr
        tails and partial-token marks match the live view, also after the
        files are gone and the projection is rebuilt from the store."""
        frozen_time(self)
        job = _job(self.root, "big", "m", planned=1, finished=False)
        trial = _trial(job, "huge__a", finished=False)
        _write(trial / "agent/metacodes-stderr.log", "".join(f"line {i}\n" for i in range(4000)))
        _write(trial / "agent/metacodes-output.jsonl", "\n".join(json.dumps(
            {"type": "usage", "input_tokens": i, "output_tokens": 1}) for i in range(3000)))
        _write(trial / "verifier/test-stdout.txt", "ok\n" * 5000)
        with patch.object(ingest, "MAX_FILE_BYTES", 20_000), patch.object(data, "MAX_JSON_BYTES", 10_000):
            expected = normal(file_outputs(self.root))
            store = self.sqlite()
            library = StoreLibrary(store, [self.root])
            library.sync()
            with store.read() as tx:
                states = dict(tx.query("SELECT relpath, state FROM files WHERE relpath LIKE 'huge__a/%'"))
            self.assertEqual(states["huge__a/agent/metacodes-stderr.log"], "oversize")
            self.assertEqual(states["huge__a/agent/metacodes-output.jsonl"], "oversize")
            actual = normal(store_outputs(library))
            self.assertEqual(actual["jobs"], expected["jobs"])
            self.assertEqual(actual["trials"], expected["trials"])
            detail = actual["trials"]["big|huge__a"]
            self.assertTrue(detail["stderr"].endswith("line 3999\n"))
            self.assertTrue(detail["row"]["tokens_partial"])
            # The log grows: its new tail replaces the old one.
            with (trial / "agent/metacodes-stderr.log").open("a") as log:
                log.write("the very end\n")
            expected = normal(file_outputs(self.root))
            library.sync()
            self.assertEqual(normal(store_outputs(library))["trials"], expected["trials"])
            shutil.rmtree(self.root)
            self.root.mkdir()
            with store.transaction() as tx:
                tx.execute("UPDATE trials SET projection = 'old'")
            ingest.refresh_projections(store)
            self.assertEqual(normal(store_outputs(library))["trials"], expected["trials"])
            with store.read() as tx:
                orphans = tx.one("SELECT COUNT(*) FROM blobs WHERE sha256 NOT IN (SELECT sha256 FROM files WHERE "
                                 "sha256 IS NOT NULL) AND sha256 NOT IN (SELECT tail_sha256 FROM files WHERE "
                                 "tail_sha256 IS NOT NULL)")[0]
            self.assertEqual(orphans, 0)  # the replaced tail was collected

    def test_one_trial_name_in_two_workbuddy_runs_is_two_trials(self):
        frozen_time(self)
        job = _job(self.root, "bench-wb", "m", planned=2)
        first = _trial(job / data.NESTED_RUNS / "run-a", "same-task__x", reward=1.0)
        _trial(job / data.NESTED_RUNS / "run-b", "same-task__x", reward=0.0)
        expected = normal(file_outputs(self.root))
        self.assertEqual(len(expected["jobs"]["bench-wb"]["rows"]), 2)
        library = StoreLibrary(self.sqlite(), [self.root])
        library.sync()
        actual = normal(store_outputs(library))
        for key in ("overview", "jobs", "csv", "summary"):
            with self.subTest(key=key):
                self.assertEqual(actual[key], expected[key])
        # The trial page resolves the name like data.Library: first by path.
        self.assertEqual(normal(library.trial_detail("bench-wb", "same-task__x")), normal(data.trial_detail(first)))
        self.assertEqual(library.trial_detail("bench-wb", "task__x"), None)


class MigrationDuringRunTest(StoreCase):
    def test_source_changing_during_migration_verifies_and_resumes(self):
        job = _job(self.root, "live", "m", planned=2, finished=False)
        _trial(job, "a__1", finished=False)
        source = self.sqlite("source.sqlite3")
        ingest.ingest_root(source, self.root)
        target = self.sqlite("target.sqlite3")
        original = migrate._verify

        def ingest_meanwhile(source_tx, target_store, report):
            # A running job is ingested again between the copy and the
            # verification: the trial finishes, the job grows a trial.
            _trial(job, "a__1", reward=1.0)
            _trial(job, "b__2", reward=0.0)
            ingest.ingest_job(source, job)
            return original(source_tx, target_store, report)

        with patch.object(migrate, "_verify", ingest_meanwhile):
            report = migrate.migrate(source, target)
        self.assertEqual(report.tables["trials"].verified, 1)  # the snapshot that was copied

        # Run again (the job kept running): older rows of the same keys are
        # brought up to date instead of refused.
        _write(job / "a__1" / "agent" / "metacodes-stderr.log", "more\n")
        ingest.ingest_job(source, job)
        report = migrate.migrate(source, target)
        self.assertGreater(report.tables["trials"].updated, 0)
        self.assertGreater(report.tables["files"].updated + report.tables["files"].copied, 0)
        self.assertEqual(table_dump(target), table_dump(source))
        with target.read() as tx:
            self.assertEqual(tx.one("SELECT status FROM trials WHERE name = 'a__1'"), ("pass",))


@unittest.skipUnless(os.name != "nt", "the fake Harbor executable is a POSIX script")
class WorkerEndToEndTest(StoreCase):
    def test_launched_worker_fills_the_configured_store_before_reporting_done(self):
        from scripts.eval.harbor.bench.runner import RunManager
        from scripts.eval.tests.test_bench_workbench import fixture, offline_hugging_face, stop_profiles_and_workers, wait_run

        config, binary_dir = fixture(self.temp)
        offline_hugging_face(self)
        target = self.temp / "chosen.sqlite3"
        atomic_json(config, {**json.loads(config.read_text()), "store": {"backend": "sqlite", "path": str(target)}})
        env = {"PATH": str(binary_dir) + os.pathsep + os.environ.get("PATH", ""), "TOKENJOY_API_KEY": "private"}
        with patch.dict(os.environ, env):
            manager = RunManager(self.temp / "jobs", config)
            self.addCleanup(stop_profiles_and_workers, manager)
            run = manager.launch({"model": "tokenjoy/test-model", "tasks": ["fix-git"]})
            self.assertEqual(json.loads((manager.records / (run["name"] + ".spec")).read_text())["store"],
                             {"backend": "sqlite", "path": str(target.resolve())})
            self.assertEqual(wait_run(manager, run["name"])["status"], "finished")
        store = Store(store_config.SqliteConfig(target))
        self.addCleanup(store.close)
        library = StoreLibrary(store)  # no jobs directory: only what the worker stored
        view = library.job_view(run["name"])
        self.assertEqual((view["running"], view["summary"]["counts"]["pass"]), (False, 1))
        self.assertTrue(wait_for(lambda: (library.run_record(run["name"]) or {}).get("status") == "finished"))
        with store.read() as tx:
            stored = {row[0] for row in tx.query("SELECT relpath FROM files WHERE job = ?", (run["name"],))}
        self.assertIn("fix-git__fake/result.json", stored)
        self.assertIn("argv.json", stored)


def wait_for(predicate, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


def settings_of(temp: Path):
    path = temp / "state" / "bench" / "workbench.json"
    return json.loads(path.read_text()) if path.exists() else {}


def pg_dsn_with_schema(dsn: str, schema_name: str) -> str:
    parts = urlsplit(dsn)
    query = parse_qsl(parts.query) + [("options", f"-csearch_path={schema_name}")]
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment))


@unittest.skipUnless(PG_DSN, "set METACODES_TEST_PG_DSN to a PostgreSQL database to run these")
class PostgresTest(StoreCase):
    def pg(self) -> Store:
        import psycopg

        name = "bench_test_" + uuid.uuid4().hex[:12]
        with psycopg.connect(PG_DSN, autocommit=True) as connection:
            connection.execute(f"CREATE SCHEMA {name}")

        def drop():
            with psycopg.connect(PG_DSN, autocommit=True) as connection:
                connection.execute(f"DROP SCHEMA {name} CASCADE")

        self.addCleanup(drop)
        store = Store(store_config.PostgresConfig(pg_dsn_with_schema(PG_DSN, name)))
        self.addCleanup(store.close)
        return store

    def test_sqlite_to_postgres_and_back_preserves_every_view(self):
        frozen_time(self)
        build_fixture(self.root)
        expected = normal(file_outputs(self.root))
        sqlite_store = self.sqlite()
        ingest.ingest_root(sqlite_store, self.root)
        pg = self.pg()
        report = migrate.migrate(sqlite_store, pg)
        self.assertEqual({n: t.verified for n, t in report.tables.items()},
                         {n: t.source for n, t in report.tables.items()})
        self.assertEqual(table_dump(pg), table_dump(sqlite_store))
        pg_views = normal(store_outputs(StoreLibrary(pg)))
        for key in ("overview", "jobs", "csv", "summary"):
            self.assertEqual(pg_views[key], expected[key])
        back = self.sqlite("back.sqlite3")
        migrate.migrate(pg, back)
        self.assertEqual(table_dump(back), table_dump(sqlite_store))
        self.assertEqual(sum(t.copied for t in migrate.migrate(sqlite_store, pg).tables.values()), 0)

    def test_unstorable_text_reaches_postgres_directly_and_by_migration(self):
        frozen_time(self)
        unstorable_job(self.root)
        expected = normal(file_outputs(self.root))
        pg = self.pg()
        library = StoreLibrary(pg, [self.root])
        library.sync()
        self.assertEqual(normal(store_outputs(library))["jobs"], expected["jobs"])
        with pg.read() as tx:
            self.assertEqual(tx.one("SELECT message FROM verifier_tests"), ("bad�byte �",))
        # A SQLite file holding NUL (written before text was cleaned) still
        # migrates: the copy stores the cleaned text and verifies.
        sqlite_store = self.sqlite()
        ingest.ingest_root(sqlite_store, self.root)
        raw = sqlite3.connect(str(self.temp / "bench.sqlite3"))
        raw.execute("UPDATE verifier_tests SET message = ?", ("legacy\x00nul",))
        raw.commit()
        raw.close()
        target = self.pg()
        report = migrate.migrate(sqlite_store, target)
        self.assertEqual(report.tables["verifier_tests"].verified, 1)
        with target.read() as tx:
            self.assertNotIn("\x00", tx.one("SELECT message FROM verifier_tests")[0])

    def test_migration_from_a_postgres_store_that_keeps_ingesting(self):
        job = _job(self.root, "live", "m", planned=2, finished=False)
        _trial(job, "a__1", finished=False)
        pg = self.pg()
        ingest.ingest_root(pg, self.root)
        target = self.sqlite("target.sqlite3")
        original = migrate._verify

        def ingest_meanwhile(source_tx, target_store, report):
            _trial(job, "a__1", reward=1.0)
            _trial(job, "b__2", reward=0.0)
            ingest.ingest_job(pg, job)
            return original(source_tx, target_store, report)

        with patch.object(migrate, "_verify", ingest_meanwhile):
            self.assertEqual(migrate.migrate(pg, target).tables["trials"].verified, 1)
        report = migrate.migrate(pg, target)
        self.assertGreater(report.tables["trials"].updated, 0)
        self.assertEqual(table_dump(target), table_dump(pg))

    def test_postgres_ingests_directly_and_is_idempotent(self):
        frozen_time(self)
        build_fixture(self.root)
        pg = self.pg()
        library = StoreLibrary(pg, [self.root])
        library.sync()
        before = table_dump(pg)
        results = library.sync()
        self.assertEqual({j.outcome for r in results for j in r.jobs}, {"unchanged"})
        self.assertEqual(table_dump(pg), before)
        expected = normal(file_outputs(self.root))
        actual = normal(store_outputs(library))
        for key in ("overview", "jobs", "csv", "summary"):
            self.assertEqual(actual[key], expected[key])
        with pg.transaction() as tx, self.assertRaises(Exception):
            tx.execute("UPDATE trials SET status = 'bogus'")


if __name__ == "__main__":
    unittest.main()
