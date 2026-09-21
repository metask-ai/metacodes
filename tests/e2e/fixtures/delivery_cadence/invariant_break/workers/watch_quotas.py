"""Watch quotas (ack through a helper)."""

from workers import _base


def run(job, ctx):
    scope = job.payload.get("scope")
    if scope is None:
        return _base.ack_and_return(job, 0)
    count = ctx.store.count(scope)
    if count == 0:
        return _base.ack_and_return(job, 0)
    ctx.store.watch(scope)
    return _base.ack_and_return(job, count)
