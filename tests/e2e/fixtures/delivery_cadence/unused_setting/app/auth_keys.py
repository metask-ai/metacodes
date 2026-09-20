"""Auth Keys (reads its settings at import time)."""

from app import settings

JWKS_URL = settings.get("auth.jwks_url")
CLOCK_SKEW_S = settings.get_int("auth.clock_skew_s")


def describe():
    return "auth_keys"
