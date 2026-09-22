"""Cache Backend (reads its settings at import time)."""

from app import settings

BACKEND = settings.get("cache.backend")
NAMESPACE = settings.get("cache.namespace")


def describe():
    return "cache_backend"
