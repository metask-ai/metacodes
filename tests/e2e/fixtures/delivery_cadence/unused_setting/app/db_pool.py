"""Db Pool (reads its settings at import time)."""

from app import settings

DSN = settings.get("db.dsn")
POOL_MIN = settings.get_int("db.pool_min")
POOL_MAX = settings.get_int("db.pool_max")


def describe():
    return "db_pool"
