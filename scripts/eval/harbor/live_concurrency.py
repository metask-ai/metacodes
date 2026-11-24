from __future__ import annotations

import asyncio
import os
import time
from pathlib import Path

FILE_ENV = "METACODES_BENCH_CONCURRENCY_FILE"
MAX_CONCURRENCY = 16
POLL_SECONDS = 1.0


def read(path, fallback):
    try:
        value = int(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return fallback
    return value if 1 <= value <= MAX_CONCURRENCY else fallback


def write(path, value):
    path = Path(path)
    staging = path.with_name(path.name + ".tmp")
    staging.write_text(str(value), encoding="utf-8")
    os.replace(staging, path)


class LiveLimit:
    def __init__(self, path, fallback):
        self.path = path
        self.fallback = fallback
        self.running = 0
        self.limit = read(path, fallback)
        self.read_at = time.monotonic()

    def current(self):
        if time.monotonic() - self.read_at >= POLL_SECONDS:
            self.limit = read(self.path, self.fallback)
            self.read_at = time.monotonic()
        return self.limit

    async def __aenter__(self):
        while self.running >= self.current():
            await asyncio.sleep(POLL_SECONDS)
        self.running += 1

    async def __aexit__(self, *exc_info):
        self.running -= 1


def install(queue_class, environ=os.environ):
    path = environ.get(FILE_ENV)
    if not path:
        return

    async def run_trial(queue, trial_config):
        if not hasattr(queue, "live_limit"):
            queue.live_limit = LiveLimit(path, queue._n_concurrent)
        async with queue.live_limit:
            return await queue._execute_trial_with_retries(trial_config)

    queue_class._run_trial = run_trial
