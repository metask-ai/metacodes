"""Input validation helpers. Every function raises on unsafe input."""

import re

SAFE_TOKEN = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
SAFE_FORMAT = ("pdf", "png", "svg", "txt")


class UnsafeInput(ValueError):
    pass


def assert_relative(path):
    if path.startswith("/") or ".." in path.split("/"):
        raise UnsafeInput(path)
    return path


def assert_token(value):
    if not SAFE_TOKEN.match(value or ""):
        raise UnsafeInput(value)
    return value


def assert_format(value):
    if value not in SAFE_FORMAT:
        raise UnsafeInput(value)
    return value


def assert_int(value, low, high):
    number = int(value)
    if number < low or number > high:
        raise UnsafeInput(value)
    return number
