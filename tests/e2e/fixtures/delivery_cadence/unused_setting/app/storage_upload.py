"""Storage Upload (reads its settings at import time)."""

from app import settings

MULTIPART_CHUNK_MB = settings.get_int("storage.multipart_chunk_mb")


def describe():
    return "storage_upload"
