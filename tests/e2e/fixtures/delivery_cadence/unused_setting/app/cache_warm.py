"""Warm the cache from a configured key list (computed setting name)."""

from app import settings

_SECTION = "cache"


def warm():
    names = ["warm_keys"]
    for name in names:
        raw = settings.get("%s.%s" % (_SECTION, name), "")
        for key in raw.split(","):
            if key.strip():
                yield key.strip()
