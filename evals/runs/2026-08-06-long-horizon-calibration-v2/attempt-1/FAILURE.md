# Calibration attempt 1 — fail-closed record

Attempt 1 stopped after rollout 2 of 18. It is an invalid calibration attempt,
not a partial result and not evidence about comparative treatment quality. No
promotion receipt was generated and no TinyKG-arm or confirmatory rollout ran.

## Observed budget

- completed/valid checkpoints: 1
- invalid checkpoints: 1
- observed cost: `$1.1921154`
- observed metered tokens: `170267`
- stage caps: `$100` and `3000000` tokens

Codex-style trial 0 completed in 372.550 seconds, cost `$0.6732822`, used 98,097
metered tokens and produced a valid-for-scoring record. Claude-style trial 0 was
killed by the 900-second process timeout, cost `$0.5188332`, used 72,170 metered
tokens and was checkpointed as `invalid/nonzero_exit:124`. The runner then
aborted before another paid call, as required by the contract.

## Confirmed measurement defects

1. Both arms produced the correct five contract values in valid JSON and the
   operations note. The grader nevertheless failed both outcomes because the
   suite requested case-sensitive `contains("retry")`, while natural Markdown
   used `Retry ceiling`. This is a deterministic false negative.
2. The Claude E2E report counted 31 successful tool calls, while the native
   checkpoint recorded 12. The report observed 16 Read, 5 Write, 5 Bash,
   3 Edit and 2 Grep calls; checkpoint telemetry observed only 6 Read, 4 Write
   and 2 Bash calls. Cross-phase/native telemetry is therefore incomplete.
3. The timeout trace contains request id 66 while checkpoint telemetry reports
   only 10 model requests. Repeated `auto-compact skipped: summary savings below
   5%` warnings show that forced compaction can invoke summary work and then
   discard it without accounting for all request cost/latency in the rollout
   telemetry. The exact repair belongs to the next engineering revision.

The Claude process was killed while streaming a long final response after the
artifacts were already correct. Its checkpoint reports 450.309 seconds of
native wall time, materially below the 900-second enclosing process timeout;
this mismatch is additional evidence that the current event boundary does not
cover the complete multi-phase execution.

## Evidence identity

- `checkpoints/codex_style.jsonl`:
  `df1d7dc2ee52fb21f5eafbb42ccbac2054847b1cd5b669b6bdeea4461250e534`
- `checkpoints/claude_style.jsonl`:
  `abe4e913bbedfb7a56f6cf90f4434cc0b6fc8447714235a50f76df850cc08a55`
- ignored local raw-trace archive:
  `artifacts/attempt-1-raw-traces.tar.gz`,
  `c9041656f0f03a9c36af63ea8eab778322290b9113dc2b8995171aae33a26dbd`

The raw archive contains both complete E2E run directories, including debug
logs, native events, transcripts, reports and output workspaces. It is excluded
from Git because it is a generated 1.18 MB compressed artifact; its identity is
committed in `SHA256SUMS`.
