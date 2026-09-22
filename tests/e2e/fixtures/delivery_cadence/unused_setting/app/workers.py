"""Workers (reads its settings at import time)."""

from app import settings

WORKER_COUNT = settings.get_int("core.worker_count")
SHUTDOWN_GRACE_S = settings.get_int("core.shutdown_grace_s")


def describe():
    return "workers"
