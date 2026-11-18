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

import datetime as dt
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
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from scripts.eval.harbor import cli
from scripts.eval.harbor.store import config as store_config
from scripts.eval.harbor.store import ingest, library as library_module, migrate, schema
from scripts.eval.harbor.store.backend import Store, StoreError
from scripts.eval.harbor.store.library import StoreLibrary
from scripts.eval.harbor.viewer import data, server
from scripts.eval.harbor.viewer.runner import atomic_json
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
        detail = actual["trials"]["glm-pilot|kv-store__aaa"]
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
        http = server.make_server(StoreLibrary(store, [self.root]), "127.0.0.1", 0)
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        base = f"http://127.0.0.1:{http.server_address[1]}"

        def get(path):
            with urllib.request.urlopen(base + path, timeout=10) as response:
                return response.read()

        jobs = json.loads(get("/api/jobs"))
        self.assertEqual(jobs["jobs"], expected["overview"])
        self.assertEqual(jobs["summary"], expected["summary"])
        self.assertEqual(jobs["storage"]["format"], "SQLite")
        self.assertEqual(jobs["storage"]["database"]["location"], str(self.temp / "bench.sqlite3"))
        shutil.rmtree(self.root / "metrics-job")  # served from the store now
        self.assertEqual(json.loads(get("/api/job?name=metrics-job")), expected["jobs"]["metrics-job"])
        self.assertEqual(get("/api/job.csv?name=metrics-job").decode(), expected["csv"]["metrics-job"])
        detail = json.loads(get("/api/trial?job=metrics-job&trial=one__aaa"))
        file_row = next(r for r in expected["jobs"]["metrics-job"]["rows"] if r["trial"] == "one__aaa")
        self.assertEqual(detail, {**expected["trials"]["metrics-job|one__aaa"], "row": file_row})


class IngestTest(StoreCase):
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
        atomic_json(records / "bench-live.json", {"name": "bench-live", "status": "finished", "model": "m",
                                                  "exit_code": 0})
        atomic_json(records / "bench-live.spec", {"name": "bench-live"})
        (records / "bench-live.log").write_text("worker log\n")
        beats = []
        sync.finish(lambda: beats.append(1))
        sync.record("bench-live")
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
        sync.finish(lambda: None)
        sync.record("x")
        self.assertTrue(sync.failed)


class SchemaTest(StoreCase):
    def test_migrations_are_recorded_once_and_newer_schemas_refused(self):
        store = self.sqlite()
        store.close()
        reopened = self.sqlite()
        with reopened.read() as tx:
            self.assertEqual(tx.query("SELECT version FROM schema_migrations"), [(schema.LATEST,)])
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


@unittest.skipUnless(os.name != "nt", "the fake Harbor executable is a POSIX script")
class WorkerEndToEndTest(StoreCase):
    def test_launched_worker_fills_the_configured_store_before_reporting_done(self):
        from scripts.eval.harbor.viewer.runner import RunManager
        from scripts.eval.tests.test_bench_workbench import fixture, wait_run

        config, binary_dir = fixture(self.temp)
        target = self.temp / "chosen.sqlite3"
        atomic_json(config, {**json.loads(config.read_text()), "store": {"backend": "sqlite", "path": str(target)}})
        env = {"PATH": str(binary_dir) + os.pathsep + os.environ.get("PATH", ""), "TOKENJOY_API_KEY": "private"}
        with patch.dict(os.environ, env):
            manager = RunManager(self.temp / "jobs", config)
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
