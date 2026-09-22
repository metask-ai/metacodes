"""Migrate (reads its settings at import time)."""

from app import settings

MIGRATE_ON_BOOT = settings.get_bool("db.migrate_on_boot")


def describe():
    return "migrate"
