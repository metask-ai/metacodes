"""Audit log."""

_LOG = []


def record(action, detail):
    _LOG.append((action, str(detail)[:200]))


def entries():
    return list(_LOG)
