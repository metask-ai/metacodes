# Long-horizon calibration preflight r2 — 2026-08-06

Status: technically ready for a fresh non-confirmatory calibration attempt.
This preflight made no paid/model/network calls. Program spend remains the
failed attempt-1 carryover: `$1.1921154` and `170267` metered tokens.

This directory is an immutable r2 input bundle. It repairs measurement defects
found by attempt 1; it is mechanism/calibration-readiness evidence, not a
calibration result and not confirmatory outcome evidence.

## Frozen contract

- metacodes revision: `2eb41508f891b05cb1ea323d0a09d98961919ffb`
- mechanism repair: `3179887` (`eval: preserve timeout telemetry and meter compaction`)
- budget-plan binding: `2eb4150` (`eval: bind budget carryover into dry-run plans`)
- experiment fingerprint: `6cb7cbc8a70e7007`
- plan fingerprint: `2bb74ba66f2c4623`
- planned schedule: 1 non-scoring task × 3 arms × 6 trials = 18 rollouts
- historical stage usage: `$1.1921154` and `170267` tokens
- remaining calibration cap: `$98.8078846` and `2829733` tokens
- remaining aggregate cap before promotion: `$998.8078846` and `29829733` tokens
- confirmatory paid rollout remains disabled
- execution still requires the independent CLI key `--allow-paid-rollouts`

The plan freezes the carryover values, so changing the attempt output directory
does not reset the intended stage or aggregate accounting. The actual runner
also applies `--budget-used-*` to both caps. Any attempt-2 command must use the
exact values recorded above.

## Attempt-1 defects repaired

1. The calibration grader now uses an explicit Unicode-casefold check for the
   natural Markdown spelling `Retry ceiling`; the former case-sensitive check
   produced a deterministic false negative.
2. Evaluation events are appended as complete NDJSON records during execution,
   not only at normal invocation teardown. A killed final invocation remains
   invalid but its already-complete usage, model, compact and tool events are
   preserved for the checkpoint. Partial final lines fail closed.
3. Compact summary calls now emit request count, outcome and latency telemetry.
   A local optimistic preview proves whether 5% savings are even possible before
   buying a summary, preventing the observed pay-discard-repeat loop.
4. Historical failed-attempt spend counts against both the current stage cap
   and the cross-stage aggregate cap, and the dry-run plan binds that carryover.

## Artifact and formal identity

Artifact hashes are in `SHA256SUMS`. The Lean binary remains byte-identical to
the original preflight:

```text
sha256 = 1fb436a9fdcc300f94519dfea7d999a1fd94a1dd1da9d8cf91fdb1b09450b838
bytes  = 6542888
```

Its r2 provenance produces formal artifact fingerprint
`773483ba89b7a9b87df006047132e9a74e16ef546a0a8058e6c6c1b69b3ea0a5`.
Only the TinyKG arm receives TinyKG/formal paths; baseline arms receive neither.

## Preflight verification

- clean detached worktree at the frozen revision
- `zig build`: passed
- `zig build test:eval`: 96 passed, 1 explicit native opt-in skip
- explicit native runtime evaluation test: 1 passed
- runtime arm smoke: codex_style/claude_style/tinykg passed with `paid=0`, `network=0`
- two independently generated 18-rollout plans: byte-identical
- dry-run plan SHA-256:
  `58c6cd5950100fa774754ae9a1cc7193bc0a74d9e77355938ef48819cfc991d7`
- shared-tree risk checks before freezing: `zig build`, `zig build test:lib`,
  and full `zig build test` all exited 0

Promotion remains fail-closed: all 18 fresh attempt-2 rollouts must be valid,
telemetry and identities must be complete, and total calibration usage includes
attempt 1. No attempt-1 rollout may be mixed into the r2 schedule. A promotion
receipt may be generated only from the three authoritative r2 checkpoints;
the 54-rollout confirmatory stage remains disabled.
