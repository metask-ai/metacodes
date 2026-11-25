# Replaying the Linux test-ID baseline for PR #809

The first migration check for #809 lacked an exact baseline. The historical
control is the full main run that supplied it on the retry. The replay uses
the same PR artifact on both sides of the experiment and collects the base
again. This isolates the cost and correctness of replacing the manual main
run with Linux-only baseline collection.

| Input | Revision | Evidence |
| --- | --- | --- |
| PR test merge | `c952facb296f53a6ac2a0a3e8aef39aaa7dce9e0` | [Full-scope PR run](https://github.com/metask-ai/metacodes/actions/runs/45542782310) |
| First parent of that merge | `c6bb40f652d0d74bdf758a4e833c8999ce0be954` | [Full main run](https://github.com/metask-ai/metacodes/actions/runs/45544277057) |
| Fresh collection of that parent | tree `e6a94a9106fece86ebb10463e2902bad1cabf308` | [One-shot Linux replay](https://github.com/metask-ai/metacodes/actions/runs/45566140583) |

The replay checked out the first parent on each runner, including the
collector. It reused that revision's `units`, `product` and `checks` jobs,
toolchain and TTY inventory. Each test job had a 20-minute timeout.
The two decision jobs and the collector each had a three-minute timeout,
for a ceiling of 69 Linux runner-minutes. The original PR supplied the head
IDs, so the measurement isolates additional baseline work.

## Result

The historical main run and the Linux replay each collected 84 raw files
with matching per-leg source and shard counts. Their aggregate `test-ids.tsv`
files were byte-for-byte identical across all 9,402 rows (14,399 occurrences,
including TTY listings). Both had SHA-256
`7f1ab7890bc7b8177ee08d04c2fb6737db02cfd2426f76cb87751e5b5808eb32`.

The #809 PR head had 85 raw files. Its extra `checks` file recorded a second
execution of the same 29 layer-gate tests that `units` ran. Both baselines
passed this head and rejected the head with a test removed. Omitting one raw
integration shard from the replay failed the inventory check.

| Baseline collection | Linux runner time | macOS runner time | Windows runner time | Dispatch to IDs | Dispatch to last job |
| --- | ---: | ---: | ---: | ---: | ---: |
| Historical main dispatch | 100m07s | 69m04s | 122m14s | 16m07s | 34m23s |
| Pinned Linux replay | 33m15s | 0 | 0 | 14m02s | 14m02s |

The replay saved 258m10s of cumulative runner occupancy on this sample.
It ran separately from the historical head and deliberately exercised the
cache-miss path. A same-run production fallback still needs to verify a
complete baseline without relying on a historical control.

## Reproducing the comparison

From a repository checkout, set `artifacts` to the absolute path of an empty directory and run:

```sh
gh run download 45542782310 --name test-ids --dir "$artifacts/head"
gh run download 45544277057 --name test-ids --dir "$artifacts/control"
gh run download 45566140583 --name test-ids --dir "$artifacts/replay"
git fetch origin c952facb296f53a6ac2a0a3e8aef39aaa7dce9e0
git worktree add --detach "$artifacts/merge" FETCH_HEAD
```

Check each `test-ids-meta.json` against the table above. From the merge
checkout, `git rev-parse HEAD^1` gives the base and `git rev-parse HEAD^{tree}`
gives the expected head tree. The control and replay both reference the base.
Check the full scope, successful ID-producing jobs and the three raw artifact
sets before using their aggregate. The oracle for the replay's per-leg source
and shard counts is the archived full run of the same base.

```sh
cd "$artifacts/merge"
for baseline in control replay; do
    python3 scripts/test_ids.py compare --enforce --since HEAD^1 \
        --base "$artifacts/$baseline/test-ids.tsv" --head "$artifacts/head/test-ids.tsv"
done
```

## Failure cases

The original lookup now finds the exact base in the historical main run.
Its initial failure and the [subsequent passing comparison](https://github.com/metask-ai/metacodes/actions/runs/45542782310/job/138976281509)
provide evidence for the miss and hit on this pair. Removing a passing Python
test from a copy of the PR artifact makes the enforced comparison fail. The
existing narrowed-scope check rejects a partial migration head. A `fail`
record aborts baseline collection.

A partial **base** can hide a regression. Removing integration shard 0 of 8
from the base also removes its evidence for the `#467 L2` Anthropic stream
test. Removing that test from the head then passes the ID comparison when it
uses the partial base. With the complete base, the same removal fails. An
automatic fallback therefore needs an expected source and shard inventory
from the pinned base's test plan, checked before comparing IDs. Counting
three leg artifacts alone misses this case. This replay can check against the
archived complete run because both collections used exactly the same base.

## Historical cost

Runner times sum completed job durations by runner label, including the macOS
VM job. The migrated PR passed its retried ID check at 04:21:29 UTC and
its [last pre-merge check](https://github.com/metask-ai/metacodes/actions/runs/45542782309/job/138976827272)
finished at 04:36:58 UTC. This pair can demonstrate a difference in baseline
cost; it cannot establish a corresponding reduction in time to merge.
