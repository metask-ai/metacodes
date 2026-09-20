"""Shell quoting helpers."""

import shlex


def shell_quote(value):
    return shlex.quote(str(value))


def join(parts):
    return " ".join(shell_quote(p) for p in parts)
