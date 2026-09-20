"""Db Replica (reads its settings at import time)."""

from app import settings

READ_REPLICA_DSN = settings.get("db.read_replica_dsn")


def describe():
    return "db_replica"
