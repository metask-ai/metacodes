"""Audit permissions (raise path never acks)."""


def run(job, ctx):
    scope = job.payload.get("scope")
    if scope is None:
        raise ValueError("scope required")
    try:
        result = ctx.store.audit(scope)
    except ctx.store.Transient:
        raise
    job.ack()
    return result
