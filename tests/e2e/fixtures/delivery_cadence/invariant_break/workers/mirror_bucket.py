"""Mirror bucket."""


def run(job, ctx):
    items = ctx.store.list(job.payload.get("scope", "*"))
    if not items:
        job.ack()
        return 0
    done = 0
    for item in items:
        ctx.store.mirror(item)
        done += 1
    job.ack()
    return done
