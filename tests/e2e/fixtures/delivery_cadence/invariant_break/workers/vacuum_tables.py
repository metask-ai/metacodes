"""Vacuum tables (ack in finally)."""


def run(job, ctx):
    handled = 0
    try:
        for item in ctx.store.list(job.payload.get("scope", "*")):
            if ctx.policy.skip(item):
                continue
            ctx.store.vacuum(item)
            handled += 1
        return handled
    finally:
        job.ack()
