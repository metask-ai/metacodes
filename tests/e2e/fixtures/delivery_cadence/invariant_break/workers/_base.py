"""Shared helpers for workers."""


def ack_and_return(job, value):
    job.ack()
    return value


def guarded(job, fn, *args):
    """Run fn; ack once whether or not it did any work."""
    try:
        return fn(*args)
    finally:
        job.ack()
