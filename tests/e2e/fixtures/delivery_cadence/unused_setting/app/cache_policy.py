"""Cache Policy (reads its settings at import time)."""

from app import settings

TTL_S = settings.get_int("cache.ttl_s")
MAX_ENTRIES = settings.get_int("cache.max_entries")


def describe():
    return "cache_policy"
