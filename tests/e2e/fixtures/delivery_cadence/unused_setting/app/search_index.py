"""Search Index (reads its settings at import time)."""

from app import settings

INDEX_NAME = settings.get("search.index_name")


def describe():
    return "search_index"
