"""Db Query (reads its settings at import time)."""

from app import settings

STATEMENT_TIMEOUT_MS = settings.get_int("db.statement_timeout_ms")


def describe():
    return "db_query"
