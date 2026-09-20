# Worker contract

Every module under `workers/` exposes `run(job, ctx)`.

1. `job.ack()` MUST be called exactly once on every path that returns
   normally, including early returns and paths that skip the work.
2. A path that raises MUST NOT call `job.ack()` (the queue redelivers).
3. Helpers may perform the ack on behalf of `run` as long as rule 1 holds
   for the combined control flow.

The queue treats a missing ack as a redelivery after the visibility
timeout, so a worker that returns without acking duplicates its side
effects forever.
