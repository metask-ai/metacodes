"""Deferred export scheduling (no execution here)."""

_QUEUE = []


def enqueue(plan):
    _QUEUE.append(plan)
    return len(_QUEUE)


def drain():
    items, _QUEUE[:] = list(_QUEUE), []
    return items
