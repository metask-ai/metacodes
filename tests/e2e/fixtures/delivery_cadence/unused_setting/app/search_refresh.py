"""Search Refresh (reads its settings at import time)."""

from app import settings

REFRESH_INTERVAL_S = settings.get_int("search.refresh_interval_s")


def describe():
    return "search_refresh"
