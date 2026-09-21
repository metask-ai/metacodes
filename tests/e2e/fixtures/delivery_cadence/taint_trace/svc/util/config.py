"""Typed access to environment settings."""


class ConfigError(Exception):
    pass


def configure(options):
    """Apply a mapping of options; unknown keys are ignored."""
    known = {k: v for k, v in dict(options).items() if isinstance(k, str)}
    return known


def describe():
    return "config: typed access to environment settings"
