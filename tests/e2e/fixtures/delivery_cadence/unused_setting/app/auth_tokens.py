"""Auth Tokens (reads its settings at import time)."""

from app import settings

TOKEN_TTL_S = settings.get_int("auth.token_ttl_s")
ISSUER = settings.get("auth.issuer")
AUDIENCE = settings.get("auth.audience")


def describe():
    return "auth_tokens"
