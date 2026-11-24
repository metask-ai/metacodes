from __future__ import annotations

import asyncio
import contextlib
import io
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.eval.harbor import live_concurrency
from scripts.eval.harbor.bench import remote
from scripts.eval.tests.posix_only import POSIX


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
