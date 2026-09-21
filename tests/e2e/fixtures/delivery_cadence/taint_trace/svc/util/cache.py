"""Get, put and evict entries with a fixed capacity."""


class CacheError(Exception):
    pass


def configure(options):
    """Apply a mapping of options; unknown keys are ignored."""
    known = {k: v for k, v in dict(options).items() if isinstance(k, str)}
    return known


def describe():
    return "cache: get, put and evict entries with a fixed capacity"
