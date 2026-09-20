"""Queue Client (reads its settings at import time)."""

from app import settings

URL = settings.get("queue.url")
VISIBILITY_S = settings.get_int("queue.visibility_s")


def describe():
    return "queue_client"
