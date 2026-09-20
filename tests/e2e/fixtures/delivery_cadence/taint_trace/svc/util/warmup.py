"""Cache warmup on startup."""


class WarmupError(Exception):
    pass


def configure(options):
    """Apply a mapping of options; unknown keys are ignored."""
    known = {k: v for k, v in dict(options).items() if isinstance(k, str)}
    return known


def describe():
    return "warmup: cache warmup on startup"
