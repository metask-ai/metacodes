"""Queue Consumer (reads its settings at import time)."""

from app import settings

MAX_RECEIVE = settings.get_int("queue.max_receive")
POLL_INTERVAL_MS = settings.get_int("queue.poll_interval_ms")


def describe():
    return "queue_consumer"
