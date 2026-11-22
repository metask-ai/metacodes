"""Batches, per-request context composition, trial timing and the database page.

A batch freezes a metacodes bundle and runs several datasets through the real
HTTP -> RunManager -> worker -> fake Harbor path of test_bench_workbench; the
store and the page API are read back over HTTP. No provider or Docker calls.
"""
from __future__ import annotations

import io
import json
import os
import shutil
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.eval.harbor import cli, profiling
from scripts.eval.harbor.store.backend import Store
from scripts.eval.harbor.store import config as store_config
from scripts.eval.harbor.store import ingest
from scripts.eval.harbor.bench import batches, data, executors
from scripts.eval.harbor.viewer import server
from scripts.eval.harbor.bench.runner import RunManager, atomic_json
from scripts.eval.harbor.bench.setup import LoginManager
from scripts.eval.harbor.bench.workbench import Workbench
from scripts.eval.tests.posix_only import POSIX
from scripts.eval.tests.test_bench_workbench import fixture, offline_hugging_face, wait_run


def _write(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value if isinstance(value, str) else "\n".join(json.dumps(v) for v in value) + "\n"
                    if isinstance(value, list) else json.dumps(value), encoding="utf-8")


class CompositionTest(unittest.TestCase):
    def test_anthropic_messages_split_by_part(self):
        body = json.dumps({"system": "S" * 100, "tools": [{"name": "Bash", "input_schema": {}}],
                           "messages": [{"role": "user", "content": "task text"},
                                        {"role": "assistant", "content": [{"type": "tool_use", "id": "1", "name": "Bash", "input": {}}]},
                                        {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "1", "content": "R" * 50}]}]}).encode()
        shape = profiling.request_composition(body)
        self.assertEqual(shape["system"], 100)
        self.assertEqual(shape["user"], len("task text"))
        self.assertGreater(shape["tools"], 0)
        self.assertGreater(shape["assistant"], 0)
        self.assertGreater(shape["tool_results"], 50)
        self.assertEqual((shape["messages"], shape["tool_count"]), (3, 1))
        # Sizes only: no request text survives in the record.
        self.assertNotIn("task text", json.dumps(shape))

    def test_openai_chat_and_responses(self):
        chat = profiling.request_composition(json.dumps({"messages": [
            {"role": "system", "content": "sys"}, {"role": "user", "content": "hello"},
            {"role": "assistant", "content": None, "tool_calls": [{"id": "a"}]}, {"role": "tool", "content": "out"}]}).encode())
        self.assertEqual((chat["system"], chat["user"], chat["tool_results"]), (3, 5, 3))
        self.assertGreater(chat["assistant"], 0)
        responses = profiling.request_composition(json.dumps({"instructions": "abcd", "input": [
            {"type": "message", "role": "user", "content": "hi"}, {"type": "function_call", "name": "x", "arguments": "{}"},
            {"type": "function_call_output", "call_id": "c", "output": "12345"}]}).encode())
        self.assertEqual((responses["system"], responses["user"], responses["tool_results"]), (4, 2, 5))
        self.assertIsNone(profiling.request_composition(b"not json"))
        self.assertIsNone(profiling.request_composition(b"{}"))

    def test_input_tokens_are_apportioned_by_byte_share(self):
        tokens = data.composition_tokens({"system": 300, "tools": 100, "user": 0, "assistant": 0, "tool_results": 0}, 1000)
        self.assertEqual((tokens["system"], tokens["tools"], tokens["user"]), (750, 250, 0))
        self.assertIsNone(data.composition_tokens({"system": 0}, 1000))
        self.assertIsNone(data.composition_tokens({"system": 10}, None))


class TrialTimingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        job = Path(self.tmp.name) / "job"
        self.trial = job / "fix-git__abc"
        _write(self.trial / "config.json", {})
        _write(self.trial / "result.json", {
            "task_name": "terminal-bench/fix-git", "started_at": "2026-11-16T08:00:00Z", "finished_at": "2026-11-16T08:02:00Z",
            "agent_execution": {"started_at": "2026-11-16T08:00:10Z", "finished_at": "2026-11-16T08:01:50Z"},
            "verifier_result": {"rewards": {"reward": 1.0}}})
        _write(self.trial / "agent" / "metacodes-output.jsonl", [
            {"type": "tool_start", "id": "c1", "name": "Bash"},
            {"type": "tool_result", "id": "c1", "name": "Bash", "is_error": False, "elapsed_ms": 4000},
            {"type": "tool_start", "id": "c2", "name": "Read"},
            {"type": "tool_result", "id": "c2", "name": "Read", "is_error": True, "elapsed_ms": 1000},
            {"type": "result", "stop_reason": "end_turn", "turns": 2, "tool_calls": 2, "text": "ok"}])
        _write(self.trial / "agent" / "trajectory.json", {"steps": [{"step_id": 1, "source": "agent", "message": "",
            "tool_calls": [{"tool_call_id": "c1", "function_name": "Bash", "arguments": {"command": "ls"}}],
            "observation": {"results": [{"source_call_id": "c1", "content": "x"}]}}]})
        composition = {"system": 600, "tools": 400, "user": 0, "assistant": 0, "tool_results": 0, "messages": 1, "tool_count": 3}
        _write(job / ".bench-metrics" / "fix-git__abc.jsonl", [
            {"request": 2, "started_at": "2026-11-16T08:00:12+00:00", "complete": True, "http_status": 200, "duration_ms": 20000,
             "ttft_ms": 900, "generation_ms": 1000, "input_tokens": 2000, "output_tokens": 50, "cache_tokens": 0,
             "composition": composition},
            {"request": 3, "started_at": "2026-11-16T08:00:40+00:00", "complete": True, "http_status": 200, "duration_ms": 30000,
             "ttft_ms": 1100, "generation_ms": 2000, "input_tokens": 3000, "output_tokens": 80, "cache_tokens": 1800}])

    def test_row_and_detail_carry_composition_requests_and_time_split(self):
        row = data.trial_row(self.trial)
        self.assertEqual(row["initial_input_tokens"], 2000)
        self.assertEqual(row["initial_composition"]["system"], 1200)
        self.assertEqual(row["initial_composition"]["tools"], 800)
        detail = data.trial_detail(self.trial)
        self.assertEqual([r["seq"] for r in detail["requests"]], [1, 2])
        self.assertEqual(detail["requests"][1]["offset_s"], 28)
        self.assertIsNone(detail["requests"][1]["composition"])
        self.assertEqual(detail["requests"][0]["tool_count"], 3)
        split = detail["time_split"]
        self.assertEqual((split["agent_s"], split["model_s"], split["tool_s"], split["other_s"]), (100, 50, 5, 45))
        timing = {t["name"]: t for t in detail["tool_timing"]}
        self.assertEqual((timing["Bash"]["total_ms"], timing["Read"]["errors"]), (4000, 1))
        self.assertEqual(detail["steps"][0]["tool_calls"][0]["elapsed_ms"], 4000)
        summary = data.summarize([row, data.trial_row(self.trial)])
        self.assertEqual(summary["initial_composition_trials"], 2)
        self.assertEqual(summary["initial_composition_mean"]["system"], 1200)
        merged = data.merge_summaries([summary, data.summarize([])])
        self.assertEqual(merged["initial_composition_mean"]["tools"], 800)


class LoginStatusTest(unittest.TestCase):
    def test_device_code_from_an_earlier_service_is_not_shown(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "workbench.json"
            atomic_json(config, {})
            (Path(tmp) / "login.log").write_text("METASK_VERIFICATION_URI=https://example.invalid/device\nMETASK_USER_CODE=ABCD-1234\n")
            status = LoginManager(config).status()
            self.assertIsNone(status["verification_uri"])
            self.assertIsNone(status["user_code"])
            self.assertFalse(status["running"])


@unittest.skipUnless(POSIX, 'fake executable and worker signal test are POSIX')
class BatchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.config, binary_dir = fixture(self.root)
        offline_hugging_face(self)
        self.env = patch.dict(os.environ, {'PATH': str(binary_dir) + os.pathsep + os.environ.get('PATH', ''),
                                          'TOKENJOY_API_KEY': 'private-test-value'})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.manager = RunManager(self.root / 'jobs', self.config)
        self.workbench = Workbench(data.Library([self.manager.jobs_dir]), self.manager)
        self.http = server.make_server(self.workbench, '127.0.0.1', 0)
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        self.addCleanup(self.http.server_close)
        self.addCleanup(self.http.shutdown)
        self.client = cli.Client(f'http://127.0.0.1:{self.http.server_address[1]}/')

    def request(self, **override):
        return {'model': 'tokenjoy/test-model', 'attempts': 1, 'concurrency': 4, 'name': '回归',
                'items': [{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']},
                          {'suite': 'terminal-bench-2.0', 'tasks': ['fix-git']}], **override}

    def wait_batch(self, batch_id, statuses=('finished', 'cancelled'), timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.manager.batches.advance()
            record = self.manager.batches.get(batch_id)
            if record['status'] in statuses:
                return record
            time.sleep(.1)
        raise AssertionError('batch did not reach ' + str(statuses) + ': ' + json.dumps(record))

    def test_batch_freezes_the_bundle_and_runs_each_dataset_in_order(self):
        created = self.client.request('api/batches', self.request())
        self.assertNotIn('request', json.dumps(created['items']))
        frozen = Path(created['metacodes']['bundle'])
        original = self.root / 'bundle'
        self.assertNotEqual(frozen, original)
        self.assertEqual(frozen.parent, self.root / 'bundles' / 'frozen')
        self.assertEqual(batches.frozen_digest(frozen), created['metacodes']['digest'])
        # Frozen files are read-only, and rebuilding the configured bundle
        # in place does not reach the batch.
        self.assertFalse(os.access(frozen / 'bin' / 'metacodes', os.W_OK))
        built = (original / 'bin' / 'metacodes').read_bytes()
        (original / 'bin' / 'metacodes').write_bytes(b'rebuilt')
        record = self.wait_batch(created['id'])
        self.assertEqual(record['status'], 'finished')
        self.assertEqual([i['status'] for i in record['items']], ['finished', 'finished'])
        runs = {r['name']: r for r in self.manager.runs()}
        first, second = (runs[i['run']] for i in record['items'])
        self.assertLess(first['created_at'], second['created_at'])
        for item in record['items']:
            run = runs[item['run']]
            self.assertEqual(run['batch'], created['id'])
            self.assertEqual(run['metacodes']['digest'], created['metacodes']['digest'])
            spec = json.loads((self.manager.records / (run['name'] + '.spec')).read_text())
            self.assertEqual(spec['bundle'], str(frozen))
            self.assertEqual(json.loads((self.manager.jobs_dir / run['name'] / 'argv.json').read_text())
                             .count('bundle=' + str(frozen)), 1)
        # The page: batch view with per-task groups, scoped dashboard.
        view = self.client.request('api/batch?id=' + created['id'])
        self.assertEqual(view['summary']['trials'], 2)
        self.assertEqual(view['progress'], {'done': 2, 'planned': 2})
        self.assertEqual([(t['suite'], t['task'], t['first_status']) for t in view['tasks']],
                         [('terminal-bench-2.1', 'fix-git', 'pass'), ('terminal-bench-2.0', 'fix-git', 'pass')])
        self.assertEqual(view['tasks'][0]['attempts'][0]['trial'], 'fix-git__fake')
        scoped = self.client.request('api/jobs?batch=' + created['id'])
        self.assertEqual(sorted(j['name'] for j in scoped['jobs']), sorted(i['run'] for i in record['items']))
        self.assertEqual(scoped['summary']['trials'], 2)
        self.assertEqual(scoped['batches'][0]['id'], created['id'])
        self.assertEqual(self.client.request('api/jobs?batch=none')['jobs'], [])
        # The store holds the batch record.
        store = self.client.request('api/store')
        self.assertEqual(store['counts']['batches'], 1)
        # A second batch of the same bundle reuses the frozen copy.
        (original / 'bin' / 'metacodes').write_bytes(built)
        again = self.client.request('api/batches', self.request(items=[{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']}]))
        self.assertEqual(again['metacodes']['bundle'], str(frozen))
        self.wait_batch(again['id'])

    def test_chosen_features_reach_every_trial_of_the_batch(self):
        listed = [f['id'] for f in self.client.request('api/workbench')['features']]
        self.assertIn('verification_final_gate', listed)
        self.assertIn('execute_code', listed)
        created = self.client.request('api/batches', self.request(features=['execute_code', 'verification_final_gate']))
        self.assertEqual(created['features'], ['verification_final_gate', 'execute_code'])
        record = self.wait_batch(created['id'])
        self.assertEqual([i['status'] for i in record['items']], ['finished', 'finished'])
        runs = {r['name']: r for r in self.manager.runs()}
        for item in record['items']:
            self.assertEqual(runs[item['run']]['features'], ['verification_final_gate', 'execute_code'])
            argv = json.loads((self.manager.jobs_dir / item['run'] / 'argv.json').read_text())
            self.assertIn('features=verification_final_gate,execute_code', argv)
        plain = self.client.request('api/batches', self.request(items=[{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']}]))
        self.assertEqual(plain['features'], [])
        run = self.wait_batch(plain['id'])['items'][0]['run']
        self.assertNotIn('features', next(r for r in self.manager.runs() if r['name'] == run))
        argv = json.loads((self.manager.jobs_dir / run / 'argv.json').read_text())
        self.assertFalse([a for a in argv if a.startswith('features=')])

    def test_a_batch_can_be_renamed_while_running_and_after_it_ends(self):
        one = self.request(items=[{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']}])
        created = self.client.request('api/batches', one)
        self.assertEqual(self.client.request('api/batch/rename', {'id': created['id'], 'name': '  回归  '}),
                         {'id': created['id'], 'name': '回归'})
        record = self.wait_batch(created['id'])
        self.assertEqual((record['name'], record['status']), ('回归', 'finished'))
        self.client.request('api/batch/rename', {'id': created['id'], 'name': ''})
        self.assertIsNone(self.client.request('api/batch?id=' + created['id'])['name'])
        with self.assertRaisesRegex(ValueError, '最多'):
            self.client.request('api/batch/rename', {'id': created['id'], 'name': 'x' * 81})
        with self.assertRaisesRegex(ValueError, '不存在'):
            self.client.request('api/batch/rename', {'id': 'batch-missing', 'name': 'x'})
        self.assertTrue(self.client.request('api/jobs?batch=all')['can_run'])

    def test_features_are_refused_for_a_workbuddy_suite(self):
        with self.assertRaisesRegex(ValueError, 'WorkBuddy 评测暂不支持选择高级功能'):
            self.client.request('api/runs', {'suite': 'workbuddy-code', 'model': 'tokenjoy/test-model', 'tasks': ['x'],
                                             'attempts': 1, 'concurrency': 1, 'features': ['execute_code']})

    def test_single_launch_waits_and_cancel_skips_remaining_datasets(self):
        with patch.dict(os.environ, {'FAKE_BENCH_DELAY': '10'}):
            created = self.client.request('api/batches', self.request())
            deadline = time.monotonic() + 10
            while not (self.manager.batches.get(created['id'])['items'][0]['run']) and time.monotonic() < deadline:
                self.manager.batches.advance()
                time.sleep(.05)
            with self.assertRaisesRegex(ValueError, '批次|已有评测'):
                self.client.request('api/runs', {'model': 'tokenjoy/test-model', 'tasks': ['fix-git'], 'attempts': 1, 'concurrency': 1})
            with self.assertRaisesRegex(ValueError, '先取消'):
                self.client.request('api/batch/delete', {'id': created['id']})
            self.client.request('api/batch/cancel', {'id': created['id']})
            record = self.wait_batch(created['id'])
        self.assertEqual(record['status'], 'cancelled')
        self.assertEqual([i['status'] for i in record['items']], ['cancelled', 'skipped'])
        self.assertIsNone(record['items'][1]['run'])

    def test_deleting_a_batch_removes_its_runs_results_and_rows(self):
        one = self.request(items=[{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']}])
        doomed = self.wait_batch(self.client.request('api/batches', one)['id'])
        kept = self.wait_batch(self.client.request('api/batches', one)['id'])
        run = doomed['items'][0]['run']
        atomic_json(self.manager.records / 'launch-failed.json', {'name': 'launch-failed', 'status': 'failed',
                                                                  'batch': doomed['id'], 'error': 'OSError'})
        self.client.request('api/batch?id=' + doomed['id'])
        before = self.client.request('api/store')['counts']
        self.assertEqual((before['batches'], before['jobs'], before['runs']), (2, 2, 3))

        deleted = self.client.request('api/batch/delete', {'id': doomed['id']})

        self.assertEqual(deleted['runs'], sorted([run, 'launch-failed']))
        self.assertFalse(self.manager.batches.path(doomed['id']).exists())
        self.assertEqual(list(self.manager.records.glob(run + '.*')), [])
        self.assertFalse((self.manager.records / 'launch-failed.json').exists())
        self.assertFalse((self.manager.jobs_dir / run).exists())
        with self.assertRaises(ValueError):
            self.client.request('api/batch?id=' + doomed['id'])
        counts = self.client.request('api/store')['counts']
        self.assertEqual((counts['batches'], counts['jobs'], counts['runs']), (1, 1, 1))
        listing = self.client.request('api/jobs?batch=all')
        self.assertEqual([b['id'] for b in listing['batches']], [kept['id']])
        self.assertEqual([j['name'] for j in listing['jobs']], [kept['items'][0]['run']])
        with self.assertRaisesRegex(ValueError, '不存在'):
            self.client.request('api/batch/delete', {'id': doomed['id']})
        with self.workbench.library.store.read() as tx:
            orphans = tx.query("SELECT sha256 FROM blobs WHERE sha256 NOT IN (SELECT sha256 FROM files WHERE sha256 IS NOT NULL) "
                               "AND sha256 NOT IN (SELECT tail_sha256 FROM files WHERE tail_sha256 IS NOT NULL) "
                               "AND sha256 NOT IN (SELECT spec_sha256 FROM runs WHERE spec_sha256 IS NOT NULL) "
                               "AND sha256 NOT IN (SELECT log_sha256 FROM runs WHERE log_sha256 IS NOT NULL)")
            spec = tx.one("SELECT b.encoding, b.content FROM runs r JOIN blobs b ON b.sha256 = r.spec_sha256 WHERE r.name = ?",
                         (kept['items'][0]['run'],))
        self.assertEqual(orphans, [])
        self.assertEqual(json.loads(ingest.decode(*spec))['name'], kept['items'][0]['run'])

    def test_a_batch_whose_files_cannot_be_removed_stays_for_a_retry(self):
        if os.geteuid() == 0:
            self.skipTest('root ignores directory permissions')
        one = self.request(items=[{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']}])
        batch = self.wait_batch(self.client.request('api/batches', one)['id'])
        job = self.manager.jobs_dir / batch['items'][0]['run']
        job.chmod(0o500)
        try:
            with self.assertRaisesRegex(ValueError, '可以重试'):
                self.client.request('api/batch/delete', {'id': batch['id']})
            self.assertTrue(self.manager.batches.path(batch['id']).exists())
            self.assertEqual(self.client.request('api/batch?id=' + batch['id'])['id'], batch['id'])
        finally:
            job.chmod(0o700)
        self.client.request('api/batch/delete', {'id': batch['id']})
        self.assertFalse(job.exists())
        self.assertEqual(self.client.request('api/store')['counts']['batches'], 0)

    def test_a_batch_whose_receipts_cannot_be_listed_stays_for_a_retry(self):
        if os.geteuid() == 0:
            self.skipTest('root ignores directory permissions')
        one = self.request(items=[{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']}])
        batch = self.wait_batch(self.client.request('api/batches', one)['id'])
        run = batch['items'][0]['run']
        self.manager.records.chmod(0o300)
        try:
            with self.assertRaisesRegex(ValueError, '可以重试'):
                self.client.request('api/batch/delete', {'id': batch['id']})
        finally:
            self.manager.records.chmod(0o700)
        self.assertTrue((self.manager.jobs_dir / run).is_dir())
        self.assertTrue((self.manager.records / (run + '.json')).exists())
        self.client.request('api/batch/delete', {'id': batch['id']})
        self.assertEqual(list(self.manager.records.glob(run + '.*')), [])
        self.assertEqual(self.client.request('api/store')['counts']['runs'], 0)

    def test_a_failed_database_delete_keeps_the_ended_manifest_for_a_retry(self):
        one = self.request(items=[{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']}])
        batch = self.wait_batch(self.client.request('api/batches', one)['id'])
        self.client.request('api/batch?id=' + batch['id'])
        stale = json.dumps({**batch, 'status': 'queued'})
        with self.workbench.library.store.transaction() as tx:
            tx.execute("UPDATE batches SET status = 'queued', record_json = ? WHERE id = ?", (stale, batch['id']))
        with patch.object(ingest, 'collect_garbage', side_effect=RuntimeError('database is locked')):
            with self.assertRaisesRegex(RuntimeError, 'locked'):
                self.workbench.delete_batch(batch['id'])
        self.assertTrue(self.manager.batches.path(batch['id']).exists())
        self.client.request('api/batch/delete', {'id': batch['id']})
        self.assertFalse(self.manager.batches.path(batch['id']).exists())
        self.assertEqual(self.client.request('api/store')['counts']['batches'], 0)

    def test_a_batch_deleted_by_its_owner_meanwhile_is_not_deleted_again(self):
        one = self.request(items=[{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']}])
        batch = self.wait_batch(self.client.request('api/batches', one)['id'])
        run = batch['items'][0]['run']
        self.client.request('api/batch?id=' + batch['id'])
        other = RunManager(self.root / 'jobs-b', self.config)
        shutil.copytree(self.manager.jobs_dir / run, other.jobs_dir / run)
        bench = Workbench(data.Library([other.jobs_dir]), other)
        self.addCleanup(bench.close)
        seen = bench.batch_records()
        self.client.request('api/batch/delete', {'id': batch['id']})
        with patch.object(bench, 'batch_records', return_value=seen):
            with self.assertRaisesRegex(ValueError, '不存在'):
                bench.delete_batch(batch['id'])
        self.assertTrue((other.jobs_dir / run).is_dir())

    def test_imports_syncs_and_deletions_of_a_jobs_directory_exclude_each_other(self):
        one = self.request(items=[{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']}])
        batch = self.wait_batch(self.client.request('api/batches', one)['id'])
        library = self.workbench.library
        lock = self.manager.jobs_dir / ingest.ROOT_LOCK
        with ingest.root_lock(self.manager.jobs_dir):
            lock.chmod(0o400)
            importer = threading.Thread(target=ingest.ingest_root, args=(library.store, self.manager.jobs_dir))
            outcome = {}

            def sync_back():
                try:
                    executors.sync_run(self.manager.jobs_dir, 'missing-run', log=lambda text: None)
                except ValueError as exc:
                    outcome['error'] = str(exc)

            syncer = threading.Thread(target=sync_back)
            importer.start()
            syncer.start()
            with self.assertRaisesRegex(ValueError, '稍后重试'):
                self.workbench.delete_batch(batch['id'])
            time.sleep(.3)
            self.assertTrue(importer.is_alive())
            self.assertTrue(syncer.is_alive())
        importer.join(10)
        syncer.join(10)
        self.assertIn('运行不存在', outcome['error'])
        self.assertTrue(self.manager.batches.path(batch['id']).exists())
        self.client.request('api/batch/delete', {'id': batch['id']})
        self.assertEqual(self.client.request('api/store')['counts']['batches'], 0)

    def test_a_partly_removed_launch_failure_keeps_its_receipt_for_a_retry(self):
        one = self.request(items=[{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']}])
        batch = self.wait_batch(self.client.request('api/batches', one)['id'])
        atomic_json(self.manager.records / 'launch-failed.json', {'name': 'launch-failed', 'status': 'failed',
                                                                  'batch': batch['id'], 'error': 'OSError'})
        for suffix in ('.log', '.spec'):
            (self.manager.records / ('launch-failed' + suffix)).write_text('x')
        unlink = Path.unlink

        def failing_unlink(path, missing_ok=False):
            if path.name == 'launch-failed.log':
                raise PermissionError('denied')
            unlink(path, missing_ok=missing_ok)

        with patch.object(Path, 'unlink', failing_unlink):
            with self.assertRaisesRegex(ValueError, '可以重试'):
                self.workbench.delete_batch(batch['id'])
        self.assertTrue((self.manager.records / 'launch-failed.json').exists())
        deleted = self.workbench.delete_batch(batch['id'])
        self.assertIn('launch-failed', deleted['runs'])
        self.assertEqual(list(self.manager.records.glob('launch-failed.*')), [])

    def test_a_batch_from_another_jobs_directory_is_refused(self):
        one = self.request(items=[{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']}])
        batch = self.wait_batch(self.client.request('api/batches', one)['id'])
        run = batch['items'][0]['run']
        self.client.request('api/batch?id=' + batch['id'])
        other = RunManager(self.root / 'jobs-b', self.config)
        shutil.copytree(self.manager.jobs_dir / run, other.jobs_dir / run)
        bench = Workbench(data.Library([other.jobs_dir]), other)
        self.addCleanup(bench.close)
        with self.assertRaisesRegex(ValueError, '请在那个 jobs 目录'):
            bench.delete_batch(batch['id'])
        self.assertTrue((other.jobs_dir / run).is_dir())
        self.assertTrue((self.manager.jobs_dir / run).is_dir())
        self.assertTrue(self.manager.batches.path(batch['id']).exists())
        self.assertEqual(self.client.request('api/store')['counts']['batches'], 1)

    def test_a_modified_frozen_bundle_is_refused(self):
        # The server's scheduler would race the tampering below (create()
        # wakes it); advance by hand instead (wait_batch does).
        self.manager.batches.stop()
        self.manager.batches._thread.join(5)
        created = self.client.request('api/batches', self.request(items=[{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']}]))
        target = Path(created['metacodes']['bundle']) / 'bin' / 'metacodes'
        target.chmod(0o755)
        target.write_bytes(b'tampered')
        record = self.wait_batch(created['id'])
        self.assertEqual(record['items'][0]['status'], 'failed')
        self.assertIn('已被修改', record['items'][0]['error'])
        self.assertEqual(self.manager.runs(), [])

    def git_unit(self, commit, repo):
        from scripts.eval.harbor.bench import builds
        unit = builds.unit_path(self.root, commit)
        shutil.copytree(self.root / 'bundle', unit)
        atomic_json(unit / 'manifest.json', {'target': {'os': 'linux'}, 'source': {'commit': commit, 'dirty': False}})
        atomic_json(unit.parent / (unit.name + '.json'),
                    {'ref': 'main', 'commit': commit, 'version': '0.0.0-dev', 'built_at': 'now',
                     'source_id': builds.source_id(repo), 'trust_policy': builds.TRUST_POLICY})
        return unit.name

    def test_git_bundle_is_offered_only_while_its_repository_is_configured(self):
        unit = self.git_unit('a' * 40, 'https://example.com/fork.git')
        cfg = json.loads(self.config.read_text())

        def listed():
            return [b['id'] for b in self.client.request('api/workbench')['bundles']]

        atomic_json(self.config, {**cfg, 'source_repo': 'https://example.com/fork.git'})
        self.assertIn(unit, listed())
        atomic_json(self.config, {**cfg, 'source_repo': 'https://example.com/official.git'})
        self.assertNotIn(unit, listed())
        with self.assertRaisesRegex(ValueError, '版本'):
            self.client.request('api/batches', self.request(bundle=unit))
        self.assertFalse((self.root / 'bundles' / 'frozen').exists())
        atomic_json(self.config, {**cfg, 'source_repo': 'https://example.com/fork.git'})
        created = self.client.request('api/batches', self.request(bundle=unit))
        self.assertEqual(Path(created['metacodes']['bundle']).parent, self.root / 'bundles' / 'frozen')

    def test_default_git_bundle_is_checked_before_a_single_run_is_recorded(self):
        unit = self.git_unit('b' * 40, 'https://example.com/fork.git')
        cfg = json.loads(self.config.read_text())
        atomic_json(self.config, {**cfg, 'bundle': str(self.root / 'bundles' / unit),
                                  'source_repo': 'https://example.com/official.git'})
        run = {'model': 'tokenjoy/test-model', 'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']}
        with self.assertRaisesRegex(ValueError, 'source_repo 没有验证'):
            self.client.request('api/runs', run)
        self.assertEqual(self.manager.runs(), [])

    def test_a_verified_git_bundle_alone_runs_a_batch(self):
        unit = self.git_unit('c' * 40, 'https://example.com/fork.git')
        cfg = {k: v for k, v in json.loads(self.config.read_text()).items() if k != 'bundle'}
        atomic_json(self.config, {**cfg, 'source_repo': 'https://example.com/fork.git'})
        catalog = self.client.request('api/workbench')
        self.assertEqual(catalog['harbor_reasons'], [])
        self.assertEqual([b['id'] for b in catalog['bundles']], [unit])
        created = self.client.request('api/batches', self.request(bundle=unit))
        final = self.wait_batch(created['id'])
        self.assertEqual(final['status'], 'finished', final)
        frozen = created['metacodes']['bundle']
        for item in final['items']:
            spec = json.loads((self.manager.jobs_dir / '.bench-runs' / (item['run'] + '.spec')).read_text())
            self.assertEqual(spec['bundle'], frozen)

    def test_frozen_git_bundle_runs_after_the_original_is_archived(self):
        unit = self.git_unit('d' * 40, 'https://example.com/fork.git')
        cfg = {k: v for k, v in json.loads(self.config.read_text()).items() if k != 'bundle'}
        atomic_json(self.config, {**cfg, 'source_repo': 'https://example.com/fork.git'})
        created = self.client.request('api/batches', self.request(bundle=unit))
        archive = self.root / 'archive'
        archive.mkdir()
        for path in (self.root / 'bundles').glob(unit + '*'):
            path.rename(archive / path.name)
        final = self.wait_batch(created['id'])
        self.assertEqual(final['status'], 'finished', final)
        self.assertEqual([i['status'] for i in final['items']], ['finished', 'finished'])

    def test_frozen_git_bundle_is_refused_after_a_repository_switch(self):
        self.manager.batches.stop()
        self.manager.batches._thread.join(5)
        unit = self.git_unit('e' * 40, 'https://example.com/fork.git')
        cfg = json.loads(self.config.read_text())
        atomic_json(self.config, {**cfg, 'source_repo': 'https://example.com/fork.git'})
        created = self.client.request('api/batches', self.request(bundle=unit))
        atomic_json(self.config, {**cfg, 'source_repo': 'https://example.com/official.git'})
        final = self.wait_batch(created['id'], statuses=('finished', 'failed', 'cancelled'))
        self.assertTrue(all('source_repo 没有验证' in (i['error'] or '') for i in final['items']), final)
        self.assertEqual(self.manager.runs(), [])

    def test_default_bundle_is_judged_by_its_resolved_path(self):
        unit = self.git_unit('f' * 40, 'https://example.com/fork.git')
        link = self.root / 'current-bundle'
        link.symlink_to(self.root / 'bundles' / unit)
        cfg = json.loads(self.config.read_text())
        atomic_json(self.config, {**cfg, 'bundle': str(link), 'source_repo': 'https://example.com/official.git'})
        run = {'model': 'tokenjoy/test-model', 'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']}
        with self.assertRaisesRegex(ValueError, 'source_repo 没有验证'):
            self.client.request('api/runs', run)
        self.assertEqual(self.manager.runs(), [])

    def test_default_git_bundle_is_named_by_its_own_manifest(self):
        new = '1' * 40
        unit = self.git_unit(new, 'https://example.com/fork.git')
        cfg = json.loads(self.config.read_text())
        atomic_json(self.config, {**cfg, 'bundle': str(self.root / 'bundles' / unit),
                                  'source_repo': 'https://example.com/fork.git',
                                  'bundle_source': {'kind': 'checkout-overlay', 'commit': '0' * 12,
                                                    'base_release': '0.12.0'}})
        listed = self.client.request('api/workbench')['bundles']
        self.assertEqual([(b['id'], b['commit'], b['current']) for b in listed], [(unit, new, True)])
        run = self.client.request('api/runs', {'model': 'tokenjoy/test-model', 'suite': 'terminal-bench-2.1',
                                               'tasks': ['fix-git']})
        self.assertEqual(run['metacodes']['commit'], new)
        wait_run(self.manager, run['name'])
        created = self.client.request('api/batches', self.request())
        self.assertEqual((created['metacodes']['commit'], created['metacodes']['git']['commit']), (new, new))

    def test_run_record_names_the_bundle_the_worker_uses(self):
        new = '2' * 40
        unit = self.root / 'bundles' / self.git_unit(new, 'https://example.com/fork.git')
        link = self.root / ('metacodes-dev-' + '0' * 12 + '-overlay')
        link.symlink_to(unit)
        cfg = json.loads(self.config.read_text())
        run = {'model': 'tokenjoy/test-model', 'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']}
        with patch.dict(os.environ, {'HOME': str(self.root)}):
            for default in (str(link), '~/bundles/' + unit.name):
                with self.subTest(default=default):
                    atomic_json(self.config, {**cfg, 'bundle': default, 'source_repo': 'https://example.com/fork.git'})
                    record = self.client.request('api/runs', run)
                    self.assertEqual((record['metacodes']['commit'], record['metacodes']['bundle']), (new, str(unit)))
                    spec = json.loads((self.manager.jobs_dir / '.bench-runs' / (record['name'] + '.spec')).read_text())
                    self.assertEqual(spec['bundle'], str(unit))
                    wait_run(self.manager, record['name'])

    def test_bundle_flag_drops_the_previous_bundle_source(self):
        state = self.root / 'cli-state'
        (state / 'bench').mkdir(parents=True)
        atomic_json(state / 'bench' / 'workbench.json',
                    {'bundle_source': {'kind': 'checkout-overlay', 'commit': '0' * 12}})
        with patch('sys.stdout', io.StringIO()):
            cli.main(['info', '--state-root', str(state), '--bundle', str(self.root / 'bundle'), '--json'])
        saved = json.loads((state / 'bench' / 'workbench.json').read_text())
        self.assertEqual(saved['bundle'], str((self.root / 'bundle').resolve()))
        self.assertNotIn('bundle_source', saved)
        source = {'kind': 'checkout-overlay', 'commit': 'worktree', 'base_release': '0.12.0'}
        atomic_json(state / 'bench' / 'workbench.json', {**saved, 'bundle_source': source})
        with patch('sys.stdout', io.StringIO()):
            cli.main(['info', '--state-root', str(state), '--bundle', str(self.root / 'bundle'), '--json'])
        self.assertEqual(json.loads((state / 'bench' / 'workbench.json').read_text())['bundle_source'], source)

    def test_invalid_batches_are_refused_before_anything_is_written(self):
        for override in ({'items': []}, {'items': [{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']}] * 2},
                         {'items': [{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git;rm -rf /']}]},
                         {'items': [{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git'], 'bundle': '/tmp/x'}]},
                         {'bundle': '../elsewhere'}, {'model': 'unknown'}, {'attempts': 9}, {'extra': 1},
                         {'name': 'x' * 81}, {'features': ['bogus']}, {'features': 'execute_code'}):
            with self.subTest(override=override), self.assertRaises(ValueError):
                self.client.request('api/batches', self.request(**override))
        self.assertEqual(self.manager.batches.records(), [])
        self.assertFalse((self.root / 'bundles' / 'frozen').exists())

    def test_database_page_tests_switches_and_migrates(self):
        run = self.client.request('api/runs', {'model': 'tokenjoy/test-model', 'tasks': ['fix-git'], 'attempts': 1, 'concurrency': 1})
        wait_run(self.manager, run['name'])
        before = self.client.request('api/jobs')
        self.assertEqual(len(before['jobs']), 1)
        status = self.client.request('api/store')
        self.assertEqual(status['database']['backend'], 'sqlite')
        self.assertTrue(status['can_edit'])
        target = self.root / 'other' / 'bench.sqlite3'
        probe = self.client.request('api/store', {'action': 'test', 'store': {'backend': 'sqlite', 'path': str(target)}})
        self.assertEqual((probe['ok'], probe['exists']), (True, False))
        self.assertFalse(target.exists())
        with self.assertRaisesRegex(ValueError, 'password'):
            self.client.request('api/store', {'action': 'test', 'store': {'backend': 'postgres', 'dsn': 'postgresql://u:secret@db/x'}})
        switched = self.client.request('api/store', {'action': 'apply', 'migrate': True,
                                                      'store': {'backend': 'sqlite', 'path': str(target)}})
        self.assertTrue(switched['switched'])
        self.assertEqual(switched['migrated']['tables']['jobs']['verified'], 1)
        self.assertEqual(json.loads(self.config.read_text())['store'], {'backend': 'sqlite', 'path': str(target)})
        self.assertEqual(self.client.request('api/store')['database']['location'], str(target))
        after = self.client.request('api/jobs')
        self.assertEqual([j['name'] for j in after['jobs']], [run['name']])
        # The new file is what the page reads from now on.
        store = Store(store_config.SqliteConfig(target))
        try:
            self.assertEqual(store.counts()['jobs'], 1)
        finally:
            store.close()
        same = self.client.request('api/store', {'action': 'apply', 'store': {'backend': 'sqlite', 'path': str(target)}})
        self.assertTrue(same['unchanged'])


if __name__ == '__main__':
    unittest.main()
