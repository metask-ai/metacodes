"""Storage Urls (reads its settings at import time)."""

from app import settings

SIGNED_URL_TTL_S = settings.get_int("storage.signed_url_ttl_s")


def describe():
    return "storage_urls"
