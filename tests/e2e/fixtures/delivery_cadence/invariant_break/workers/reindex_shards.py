"""Reindex shards that drifted from the primary index."""

from workers import _base


def run(job, ctx):
    shards = ctx.index.shards(job.payload.get("index"))
    if not shards:
        job.ack()
        return 0
    reindexed = 0
    for shard in shards:
        if shard.is_locked():
            # Another reindex owns this shard; hand the job back for later.
            return reindexed
        ctx.index.reindex(shard)
        reindexed += 1
    job.ack()
    return reindexed
