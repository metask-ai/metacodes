from __future__ import annotations

import asyncio
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.eval.harbor import live_concurrency, trial_lifecycle
from scripts.eval.harbor.bench import data, images, remote
from scripts.eval.tests.posix_only import POSIX, requires_posix_exec
from scripts.eval.tests.test_bench_images import FAKE_DOCKER, write_task


class FakeQueue:
    def __init__(self, n_concurrent):
        self._n_concurrent = n_concurrent
        self.running = 0
        self.seen = []

    async def _execute_trial_with_retries(self, trial_config):
        self.running += 1
        self.seen.append(self.running)
        await asyncio.sleep(0.05)
        self.running -= 1
        return trial_config

    async def _run_trial(self, trial_config):
        raise AssertionError("the fixed semaphore must not run")


class LiveLimitTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "run.concurrency"
        poll = patch.object(live_concurrency, "POLL_SECONDS", 0.01)
        poll.start()
        self.addCleanup(poll.stop)

    def test_trial_queue_follows_the_file_while_trials_wait(self):
        class Queue(FakeQueue):
            pass

        live_concurrency.install(Queue, {live_concurrency.FILE_ENV: str(self.path)})
        queue = Queue(2)

        async def main():
            trials = [asyncio.ensure_future(queue._run_trial(n)) for n in range(40)]
            await asyncio.sleep(0.2)
            before = max(queue.seen)
            live_concurrency.write(self.path, 5)
            await asyncio.sleep(0.2)
            raised = max(queue.seen)
            live_concurrency.write(self.path, 1)
            await asyncio.sleep(0.1)
            mark = len(queue.seen)
            results = await asyncio.gather(*trials)
            return before, raised, queue.seen[mark:], results

        before, raised, lowered, results = asyncio.run(main())
        self.assertEqual(before, 2)
        self.assertEqual(raised, 5)
        self.assertTrue(lowered)
        self.assertEqual(set(lowered), {1})
        self.assertEqual(results, list(range(40)))

    def test_without_the_variable_harbor_keeps_its_own_queue(self):
        class Queue(FakeQueue):
            pass

        original = Queue._run_trial
        live_concurrency.install(Queue, {})
        self.assertIs(Queue._run_trial, original)

    def test_unreadable_or_out_of_range_values_keep_the_fallback(self):
        self.assertEqual(live_concurrency.read(self.path, 3), 3)
        for text in ("x", "0", "-1"):
            self.path.write_text(text)
            self.assertEqual(live_concurrency.read(self.path, 3), 3)
        live_concurrency.write(self.path, 64)
        self.assertEqual(live_concurrency.read(self.path, 3), 64)


class RecordingQueue:
    def __init__(self, n_concurrent, seconds=0.02):
        self._n_concurrent = n_concurrent
        self.seconds = seconds
        self.started = []
        self.active = 0
        self.peak = 0

    async def _execute_trial_with_retries(self, trial_config):
        self.started.append(trial_config.trial_name)
        self.active += 1
        self.peak = max(self.peak, self.active)
        await asyncio.sleep(getattr(trial_config, "seconds", self.seconds))
        self.active -= 1
        return trial_config.trial_name

    async def _run_trial(self, trial_config):
        raise AssertionError("the fixed semaphore must not run")


class LifecycleCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.limit = self.root / "run.concurrency"
        self.job = self.root / "jobs" / "job"
        self.dataset = self.root / "dataset"
        poll = patch.object(live_concurrency, "POLL_SECONDS", 0.01)
        poll.start()
        self.addCleanup(poll.stop)

    def trial(self, name, task=None, seconds=None):
        task = task or name.split("__")[0]
        if not (self.dataset / task).exists():
            write_task(self.dataset, task, "registry.example/" + task + ":1")
        config = types.SimpleNamespace(trial_name=name, trials_dir=self.job,
                                       task=types.SimpleNamespace(path=self.dataset / task, git_url=None))
        if seconds is not None:
            config.seconds = seconds
        return config

    def queue(self, concurrency, operations, seconds=0.02):
        class Queue(RecordingQueue):
            pass

        patcher = patch.object(trial_lifecycle, "docker_operations", operations)
        patcher.start()
        self.addCleanup(patcher.stop)
        live_concurrency.install(Queue, {live_concurrency.FILE_ENV: str(self.limit)})
        return Queue(concurrency, seconds)

    def record(self, name):
        return json.loads(trial_lifecycle.record_path(self.job, name).read_text(encoding="utf-8"))


def instant(log=None, seconds=0.0, status="pulled"):
    def operations(task_dir):
        def run():
            if log is not None:
                log.append(task_dir.name)
            time.sleep(seconds)
            return {"status": status, "attempts": 1}
        return [trial_lifecycle.Operation("pull:" + task_dir.name, "pull", "registry.example/" + task_dir.name + ":1", run)]
    return operations


class LifecycleTest(LifecycleCase):
    def test_slots_go_to_the_oldest_waiting_trial(self):
        for concurrency in (1, 3):
            queue = self.queue(concurrency, instant(), seconds=0.1)
            names = [f"task{n}__{concurrency}" for n in range(12)]

            async def main():
                return await asyncio.gather(*(queue._run_trial(self.trial(name)) for name in names))

            with self.subTest(concurrency=concurrency):
                self.assertEqual(asyncio.run(main()), names)
                slots = [self.record(name)["started_at"] for name in names]
                self.assertEqual(slots, sorted(slots))
                self.assertEqual(sorted(queue.started), sorted(names))
                if concurrency == 1:
                    self.assertEqual(queue.started, names)
                self.assertEqual(queue.peak, concurrency)

    def test_only_the_next_wave_prepares_while_it_waits(self):
        release = threading.Event()
        self.addCleanup(release.set)
        queue = self.queue(2, instant(), seconds=0)
        names = [f"task{n}__x" for n in range(8)]
        trials = [self.trial(name) for name in names]

        async def held(trial_config):
            while not release.is_set():
                await asyncio.sleep(0.005)
            return trial_config.trial_name

        queue._execute_trial_with_retries = held

        async def settled(started, prepared):
            deadline = time.monotonic() + 20
            await asyncio.sleep(0)
            while True:
                records = [self.record(name) for name in names]
                if (sum(bool(r["started_at"]) for r in records) >= started
                        and sum(bool(r["prepare_finished_at"]) for r in records) >= prepared):
                    await asyncio.sleep(0.1)
                    return [self.record(name) for name in names]
                if time.monotonic() > deadline:
                    return records
                await asyncio.sleep(0.01)

        async def main():
            tasks = [asyncio.ensure_future(queue._run_trial(trial)) for trial in trials]
            first = await settled(2, 4)
            live_concurrency.write(self.limit, 3)
            raised = await settled(3, 6)
            release.set()
            await asyncio.gather(*tasks)
            return first, raised

        first, raised = asyncio.run(main())
        self.assertEqual([bool(r["started_at"]) for r in first], [True, True] + [False] * 6)
        self.assertEqual([bool(r["prepare_finished_at"]) for r in first], [True] * 4 + [False] * 4)
        self.assertEqual([r["prepare"] for r in first[4:]], [None] * 4)
        self.assertEqual([bool(r["started_at"]) for r in raised], [True] * 3 + [False] * 5)
        self.assertEqual([bool(r["prepare_finished_at"]) for r in raised], [True] * 6 + [False] * 2)
        self.assertTrue(all(self.record(name)["finished_at"] for name in names))

    def test_trials_of_one_image_share_one_operation(self):
        pulls = []
        queue = self.queue(4, instant(pulls, seconds=0.2))
        names = [f"same__{n}" for n in range(4)] + ["other__0"]

        async def main():
            return await asyncio.gather(*(queue._run_trial(self.trial(name)) for name in names))

        asyncio.run(main())
        self.assertEqual(sorted(pulls), ["other", "same"])
        items = [self.record(name)["prepare"]["items"][0] for name in names]
        self.assertEqual([item["status"] for item in items], ["pulled"] * 5)
        self.assertEqual([item.get("shared", False) for item in items], [False, True, True, True, False])

    def test_no_more_than_four_operations_run_at_once(self):
        lock = threading.Lock()
        active, peak = [0], [0]

        full = threading.Event()
        self.addCleanup(full.set)

        def operations(task_dir):
            def run():
                with lock:
                    active[0] += 1
                    peak[0] = max(peak[0], active[0])
                    if active[0] >= trial_lifecycle.PREPARE_PARALLEL:
                        full.set()
                full.wait(20)
                time.sleep(0.05)
                with lock:
                    active[0] -= 1
                return {"status": "pulled"}
            return [trial_lifecycle.Operation("pull:" + task_dir.name, "pull", task_dir.name, run)]

        queue = self.queue(12, operations)

        async def main():
            return await asyncio.gather(*(queue._run_trial(self.trial(f"task{n}__x")) for n in range(12)))

        asyncio.run(main())
        self.assertEqual(peak[0], trial_lifecycle.PREPARE_PARALLEL)

    def test_a_trial_ready_before_its_turn_waits_and_then_runs_at_once(self):
        queue = self.queue(1, instant(seconds=0.02))

        async def main():
            return await asyncio.gather(queue._run_trial(self.trial("first__a", seconds=0.4)),
                                        queue._run_trial(self.trial("second__b")))

        asyncio.run(main())
        first, second = self.record("first__a"), self.record("second__b")
        self.assertLessEqual(first["queued_at"], first["started_at"])
        self.assertLessEqual(first["started_at"], first["prepare_started_at"])
        self.assertLess(second["prepare_started_at"], second["prepare_finished_at"])
        self.assertLess(second["prepare_finished_at"], second["started_at"])
        self.assertLessEqual(first["finished_at"], second["started_at"])
        self.assertEqual(second["prepare"]["status"], "prepared")
        self.write_trial_dirs("first__a", "second__b")
        rows = {r["trial"]: r["lifecycle"] for r in data.job_view(self.job)["rows"]}
        self.assertIsNone(rows["first__a"]["prepare_s"])
        self.assertGreater(rows["first__a"]["prepare_running_s"], 0)
        self.assertIsNone(rows["second__b"]["prepare_running_s"])
        self.assertGreater(rows["second__b"]["ready_wait_s"], 0.2)
        self.assertGreater(rows["second__b"]["prepare_s"], 0)

    def test_a_trial_whose_turn_comes_while_preparing_keeps_preparing_in_its_slot(self):
        def operations(task_dir):
            seconds = 0.5 if task_dir.name == "second" else 0.0
            return instant(seconds=seconds)(task_dir)

        queue = self.queue(1, operations)
        entered = {}
        execute = queue._execute_trial_with_retries

        async def timed(trial_config):
            entered[trial_config.trial_name] = trial_lifecycle.utc_now()
            return await execute(trial_config)

        queue._execute_trial_with_retries = timed

        async def main():
            return await asyncio.gather(queue._run_trial(self.trial("first__a", seconds=0.1)),
                                        queue._run_trial(self.trial("second__b")))

        self.assertEqual(asyncio.run(main()), ["first__a", "second__b"])
        second = self.record("second__b")
        self.assertLess(second["prepare_started_at"], second["started_at"])
        self.assertLess(second["started_at"], second["prepare_finished_at"])
        self.assertLessEqual(second["prepare_finished_at"], entered["second__b"])
        self.write_trial_dirs("second__b")
        life = data.job_view(self.job)["rows"][0]["lifecycle"]
        self.assertGreater(life["prepare_s"], 0.05)
        self.assertGreater(life["prepare_running_s"], 0.2)
        self.assertIsNone(life["ready_wait_s"])
        self.assertGreaterEqual(life["prepare_s"] + life["prepare_running_s"], 0.5)

    def write_trial_dirs(self, *names):
        for name in names:
            (self.job / name).mkdir(parents=True, exist_ok=True)
            (self.job / name / "config.json").write_text("{}")
        (self.job / "config.json").write_text("{}")
        (self.job / "result.json").write_text("{}")

    def test_a_preparation_that_fails_or_raises_still_runs_the_trial(self):
        def operations(task_dir):
            if task_dir.name == "undiscoverable":
                raise ValueError("任务缺少 task.toml：" + task_dir.name)

            def run():
                if task_dir.name == "exploding":
                    raise OSError("docker: command not found")
                return {"status": "failed", "attempts": 3, "error": "manifest unknown"}
            return [trial_lifecycle.Operation("pull:" + task_dir.name, "pull", task_dir.name, run)]

        queue = self.queue(1, operations)
        names = ["undiscoverable__a", "exploding__b", "broken__c"]

        async def main():
            return await asyncio.gather(*(queue._run_trial(self.trial(name)) for name in names))

        self.assertEqual(asyncio.run(main()), names)
        undiscoverable, exploding, broken = (self.record(name)["prepare"] for name in names)
        self.assertEqual((undiscoverable["status"], undiscoverable["items"]), ("skipped", []))
        self.assertIn("task.toml", undiscoverable["error"])
        self.assertEqual((exploding["status"], exploding["items"][0]["status"]), ("failed", "failed"))
        self.assertIn("docker: command not found", exploding["items"][0]["error"])
        self.assertEqual(broken["items"][0], {"kind": "pull", "image": "broken", "status": "failed",
                                              "seconds": broken["items"][0]["seconds"], "attempts": 3,
                                              "error": "manifest unknown"})
        self.assertTrue(all(self.record(name)["finished_at"] for name in names))

    def test_a_trial_without_a_local_task_directory_is_not_prepared(self):
        called = []
        queue = self.queue(1, lambda task_dir: called.append(task_dir) or [])
        package = types.SimpleNamespace(trial_name="hub__a", trials_dir=self.job,
                                        task=types.SimpleNamespace(path=None, name="terminal-bench/fix-git"))
        missing = types.SimpleNamespace(trial_name="gone__b", trials_dir=self.job,
                                        task=types.SimpleNamespace(path=self.dataset / "gone", git_url=None))

        async def main():
            return await asyncio.gather(queue._run_trial(package), queue._run_trial(missing))

        self.assertEqual(asyncio.run(main()), ["hub__a", "gone__b"])
        self.assertEqual(called, [])
        for name, task in (("hub__a", "fix-git"), ("gone__b", "gone")):
            record = self.record(name)
            self.assertEqual((record["task"], record["prepare"]), (task, {"status": "skipped"}))
            self.assertEqual((record["prepare_started_at"], record["prepare_finished_at"]), (None, None))
            self.assertTrue(record["queued_at"] <= record["started_at"] <= record["finished_at"])
        self.assertEqual(sorted(p.name for p in (self.job / trial_lifecycle.DIRECTORY).iterdir()),
                         ["gone__b.json", "hub__a.json"])

    def test_cancelling_the_job_does_not_wait_for_a_pull(self):
        stuck = threading.Event()
        self.addCleanup(stuck.set)

        def operations(task_dir):
            return [trial_lifecycle.Operation("pull:" + task_dir.name, "pull", task_dir.name,
                                              lambda: stuck.wait(60) and {"status": "pulled"})]

        queue = self.queue(2, operations)

        async def main():
            tasks = [asyncio.ensure_future(queue._run_trial(self.trial(f"task{n}__x"))) for n in range(6)]
            await asyncio.sleep(0.1)
            for task in tasks:
                task.cancel()
            return await asyncio.gather(*tasks, return_exceptions=True)

        started = time.monotonic()
        results = asyncio.run(main())
        self.assertLess(time.monotonic() - started, 5)
        self.assertTrue(all(isinstance(result, asyncio.CancelledError) for result in results))
        self.assertEqual(queue.started, [])
        self.assertEqual((queue.lifecycle.running, len(queue.lifecycle.waiting)), (0, 0))

    def test_cancelling_every_task_stops_a_trial_that_prepares_in_its_slot(self):
        stuck = threading.Event()
        self.addCleanup(stuck.set)

        def operations(task_dir):
            return [trial_lifecycle.Operation("pull:" + task_dir.name, "pull", task_dir.name,
                                              lambda: stuck.wait(60) and {"status": "pulled"})]

        queue = self.queue(2, operations, seconds=30)

        async def main():
            tasks = [asyncio.ensure_future(queue._run_trial(self.trial(f"task{n}__x"))) for n in range(4)]
            await asyncio.sleep(0)
            for task in asyncio.all_tasks() - {asyncio.current_task()}:
                task.cancel()
            done, pending = await asyncio.wait(tasks, timeout=5)
            for task in pending:
                task.cancel()
            return len(done), len(pending)

        self.assertEqual(asyncio.run(main()), (4, 0))
        self.assertEqual(queue.started, [])
        self.assertEqual((queue.lifecycle.running, len(queue.lifecycle.waiting)), (0, 0))

    def test_a_job_directory_that_cannot_be_written_never_stops_a_trial(self):
        queue = self.queue(1, instant())
        self.job.parent.mkdir(parents=True)
        self.job.write_text("a file where the job directory should be")

        async def main():
            return await queue._run_trial(self.trial("task__a"))

        self.assertEqual(asyncio.run(main()), "task__a")


@requires_posix_exec
class DockerPreparationTest(LifecycleCase):
    def setUp(self):
        super().setUp()
        write_task(self.dataset, "cached", "alexgshaw/cached:1")
        write_task(self.dataset, "missing", "alexgshaw/missing:1")
        write_task(self.dataset, "flaky", "alexgshaw/flaky:1")
        write_task(self.dataset, "broken", "alexgshaw/broken:1")
        write_task(self.dataset, "built")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        (bin_dir / "docker").write_text(FAKE_DOCKER)
        (bin_dir / "docker").chmod(0o755)
        self.docker_log = self.root / "docker.log"
        self.present = self.root / "images"
        self.present.write_text("alexgshaw/cached:1\n")
        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "FAKE_DOCKER_LOG": str(self.docker_log),
               "FAKE_DOCKER_IMAGES": str(self.present), "FAKE_DOCKER_FLAKY": "alexgshaw/flaky:1",
               "FAKE_DOCKER_BROKEN": "alexgshaw/broken:1"}
        for patcher in (patch.dict(os.environ, env), patch.object(images, "PULL_BACKOFF", (0, 0)),
                        patch.object(trial_lifecycle, "report", lambda _text: None)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def docker_calls(self, verb):
        lines = self.docker_log.read_text().splitlines() if self.docker_log.exists() else []
        return [line for line in lines if line.split(" ", 1)[0] == verb]

    def test_a_present_image_is_a_hit_and_a_missing_one_is_pulled_from_the_source(self):
        class Queue(RecordingQueue):
            pass

        live_concurrency.install(Queue, {live_concurrency.FILE_ENV: str(self.limit)})
        queue = Queue(2)
        names = ["cached__a", "missing__b", "missing__c", "flaky__d", "broken__e", "built__f", "built__g"]

        async def main():
            return await asyncio.gather(*(queue._run_trial(self.trial(name)) for name in names))

        self.assertEqual(asyncio.run(main()), names)
        prepared = {name: self.record(name)["prepare"] for name in names}
        self.assertEqual({name: prepared[name]["status"] for name in names if name not in ("missing__c", "built__g")},
                         {"cached__a": "present", "missing__b": "prepared", "flaky__d": "prepared",
                          "broken__e": "failed", "built__f": "prepared"})
        self.assertEqual(sorted(self.docker_calls("pull")),
                         ["pull alexgshaw/broken:1"] * images.PULL_ATTEMPTS
                         + ["pull alexgshaw/flaky:1", "pull alexgshaw/flaky:1", "pull alexgshaw/missing:1"])
        self.assertEqual((prepared["cached__a"]["items"][0]["status"], prepared["missing__b"]["items"][0]["status"]),
                         ("present", "pulled"))
        for follower, did in (("missing__c", "pulled"), ("built__g", "built")):
            item = prepared[follower]["items"][0]
            self.assertIn((item["status"], item.get("shared", False)), (("present", False), (did, True)), follower)
        self.assertEqual((prepared["flaky__d"]["items"][0]["status"], prepared["flaky__d"]["items"][0]["attempts"]),
                         ("pulled", 2))
        self.assertIn("manifest unknown", prepared["broken__e"]["items"][0]["error"])
        built = prepared["built__f"]["items"][0]
        self.assertEqual((built["kind"], built["status"]), ("build", "built"))
        self.assertTrue(built["image"].startswith(images.BUILD_TAG))
        self.assertEqual(len(self.docker_calls("compose")), 1)

    def test_operations_follow_what_bench_pull_does_for_the_task(self):
        found = trial_lifecycle.docker_operations(self.dataset / "missing")
        self.assertEqual([(o.key, o.kind, o.image) for o in found],
                         [("pull:alexgshaw/missing:1", "pull", "alexgshaw/missing:1")])
        self.assertEqual(trial_lifecycle.measured(found[0])["status"], "pulled")
        self.assertEqual(trial_lifecycle.measured(found[0])["status"], "present")
        self.assertEqual(self.docker_calls("pull"), ["pull alexgshaw/missing:1"])
        self.assertEqual(subprocess.run(["docker", "image", "inspect", "alexgshaw/missing:1"]).returncode, 0)


class Credential:
    def __init__(self):
        self.values = []
        self.pushes = 0

    def set(self, value):
        self.values.append(value)
        self.pushes += 1


@unittest.skipUnless(POSIX, "the remote driver signals Harbor's process group")
class RemoteControlTest(unittest.TestCase):
    def test_concurrency_line_writes_the_limit_and_leaves_the_credential(self):
        with tempfile.TemporaryDirectory() as tmp:
            limit = Path(tmp) / "concurrency"
            credential = Credential()
            lines = b'{"concurrency": 3}\n{"concurrency": "9"}\n{"credential": "fresh"}\n'
            stdin = types.SimpleNamespace(buffer=io.BytesIO(lines))
            hung_up = threading.Event()
            with patch.object(sys, "stdin", stdin), contextlib.redirect_stdout(io.StringIO()):
                remote.supervise({}, [sys.executable, "-c", "pass"], None, credential, threading.Event(), hung_up,
                                 limit_path=limit)
                hung_up.wait(5)
                deadline = time.monotonic() + 5
                while not credential.values and time.monotonic() < deadline:
                    time.sleep(0.01)
            self.assertEqual(limit.read_text(), "3")
            self.assertEqual(credential.values, ["fresh"])


if __name__ == "__main__":
    unittest.main()
