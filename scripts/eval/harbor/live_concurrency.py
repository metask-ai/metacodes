from __future__ import annotations

import os
import time
from pathlib import Path

from scripts.eval.harbor import trial_lifecycle

FILE_ENV = "METACODES_BENCH_CONCURRENCY_FILE"
POLL_SECONDS = 1.0


def read(path, fallback):
    try:
        value = int(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return fallback
    return value if value >= 1 else fallback


def write(path, value):
    path = Path(path)
    staging = path.with_name(path.name + ".tmp")
    staging.write_text(str(value), encoding="utf-8")
    os.replace(staging, path)


class LiveLimit:
    def __init__(self, path, fallback):
        self.path = path
        self.fallback = fallback
        self.limit = read(path, fallback)
        self.read_at = time.monotonic()

    def current(self):
        if time.monotonic() - self.read_at >= POLL_SECONDS:
            self.limit = read(self.path, self.fallback)
            self.read_at = time.monotonic()
        return self.limit


def install(queue_class, environ=os.environ):
    path = environ.get(FILE_ENV)
    if not path:
        return

    async def run_trial(queue, trial_config):
        if not hasattr(queue, "lifecycle"):
            queue.lifecycle = trial_lifecycle.Scheduler(LiveLimit(path, queue._n_concurrent).current,
                                                        lambda: POLL_SECONDS)
        return await queue.lifecycle.run(trial_config, queue._execute_trial_with_retries)

    queue_class._run_trial = run_trial
