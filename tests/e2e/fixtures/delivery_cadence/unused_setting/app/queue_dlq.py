"""Queue Dlq (reads its settings at import time)."""

from app import settings

DEAD_LETTER_URL = settings.get("queue.dead_letter_url")


def describe():
    return "queue_dlq"
