"""Search Topology (reads its settings at import time)."""

from app import settings

SHARDS = settings.get_int("search.shards")
REPLICAS = settings.get_int("search.replicas")


def describe():
    return "search_topology"
