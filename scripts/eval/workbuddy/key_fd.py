"""Resolve a WorkBuddy host-proxy credential from an anonymous descriptor.

The model config continues to name an environment variable, but the variable's
value is only ``fd://<number>``.  The secret itself never enters argv, the
environment, generated proxy YAML, a receipt, or a benchmark artifact.
"""

from __future__ import annotations

import os
from typing import Dict


MAX_CREDENTIAL_BYTES = 16 * 1024
_FD_PREFIX = "fd://"
_FD_ONLY_ENV_SUFFIX = "_FD_REF"
_SECRET_CACHE: Dict[str, str] = {}


class CredentialFdError(ValueError):
    pass


def _read_exact_secret(descriptor: int) -> str:
    chunks: list[bytes] = []
    observed = 0
    try:
        while True:
            chunk = os.read(descriptor, min(4096, MAX_CREDENTIAL_BYTES + 1 - observed))
            if not chunk:
                break
            chunks.append(chunk)
            observed += len(chunk)
            if observed > MAX_CREDENTIAL_BYTES:
                raise CredentialFdError("provider credential exceeds 16384 bytes")
    except OSError as exc:
        raise CredentialFdError(f"cannot read provider credential descriptor: {exc}") from exc
    finally:
        try:
            os.close(descriptor)
        except OSError:
            pass
    payload = b"".join(chunks)
    if not payload:
        raise CredentialFdError("provider credential descriptor is empty")
    if b"\x00" in payload or b"\r" in payload or b"\n" in payload:
        raise CredentialFdError("provider credential contains a forbidden control byte")
    try:
        return payload.decode("utf-8", errors="strict")
    except UnicodeError as exc:
        raise CredentialFdError("provider credential is not UTF-8") from exc


def resolve_secret_env(direct: str, env_name: str) -> str:
    """Resolve normal WorkBuddy keys or consume a metacodes ``fd://N`` key.

    A cache is required because one proxy config can contain multiple routes
    backed by the same descriptor.  The descriptor is consumed and closed once;
    subsequent route construction reuses only the in-process value.
    """

    if direct:
        return direct
    if not env_name:
        return ""
    cached = _SECRET_CACHE.get(env_name)
    if cached is not None:
        return cached
    raw = os.environ.get(env_name, "")
    if not raw.startswith(_FD_PREFIX):
        if env_name.endswith(_FD_ONLY_ENV_SUFFIX):
            raise CredentialFdError(f"{env_name} requires an anonymous credential FD")
        return raw
    encoded = raw[len(_FD_PREFIX) :]
    if not encoded.isascii() or not encoded.isdigit():
        raise CredentialFdError(f"{env_name} has an invalid credential FD reference")
    descriptor = int(encoded, 10)
    if descriptor < 3:
        raise CredentialFdError(f"{env_name} credential FD must be greater than 2")
    secret = _read_exact_secret(descriptor)
    os.environ.pop(env_name, None)
    _SECRET_CACHE[env_name] = secret
    return secret
