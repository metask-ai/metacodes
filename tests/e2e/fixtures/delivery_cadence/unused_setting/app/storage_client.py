"""Storage Client (reads its settings at import time)."""

from app import settings

BUCKET = settings.get("storage.bucket")
REGION = settings.get("storage.region")
PREFIX = settings.get("storage.prefix")


def describe():
    return "storage_client"
