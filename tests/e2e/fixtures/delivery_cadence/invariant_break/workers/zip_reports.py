"""Zip reports (guarded helper)."""

from workers import _base


def _work(ctx, scope):
    total = 0
    for item in ctx.store.list(scope):
        ctx.store.zip(item)
        total += 1
    return total


def run(job, ctx):
    return _base.guarded(job, _work, ctx, job.payload.get("scope", "*"))
