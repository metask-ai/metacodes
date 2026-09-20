"""Settings access. `get("section.key")` is the only read path."""

import configparser
import os

_PARSER = configparser.ConfigParser()
_PARSER.read(os.environ.get("APP_SETTINGS", "conf/settings.ini"))


def get(dotted, default=None):
    section, _, key = dotted.partition(".")
    if _PARSER.has_option(section, key):
        return _PARSER.get(section, key)
    return default


def get_int(dotted, default=0):
    value = get(dotted)
    return int(value) if value is not None else default


def get_bool(dotted, default=False):
    value = get(dotted)
    return value.lower() in ("1", "true", "yes") if value is not None else default
