"""Expire links (loop with continue)."""


def run(job, ctx):
    processed = 0
    for item in ctx.store.list(job.payload.get("scope", "*")):
        if item.stale():
            continue
        ctx.store.expire(item)
        processed += 1
    job.ack()
    return processed
