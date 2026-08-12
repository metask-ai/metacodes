# Calibration attempt 2 — fail-closed record

Attempt 2 stopped after rollout 4 of 18. Three trial-0 rollouts are valid;
the fourth rollout is an intentionally interrupted, invalid infrastructure
record. The incomplete Williams block is not a calibration result and cannot
support any comparative treatment claim. No promotion receipt was generated
and no confirmatory call ran.

## Observed budget

- completed/valid checkpoints: `3`
- invalid checkpoints: `1`
- attempt-2 cost: `$2.1616980`
- attempt-2 metered tokens: `2049026`
- attempt-1 carryover: `$1.1921154` and `170267` tokens
- cumulative calibration usage: `$3.3538134` and `2219293` tokens
- remaining stage budget: `$96.6461866` and `780707` tokens
- stage caps: `$100` and `3000000` tokens

The runner completed the full trial-0 row before the external budget guard
stopped trial 1. At that boundary cumulative stage usage was `2084024` tokens,
leaving `915976`. The scheduled fourth arm was `claude_style`; its preceding
rollout had used `1017497` tokens. The runner nevertheless started it because
the current budget check validates only already committed checkpoints and does
not reserve capacity for the next rollout. Continuing could therefore have
crossed the nominal 3M cap before the post-rollout check rejected it.

The operator sent `SIGTERM` to the just-started child after four successful
model requests. Incremental telemetry preserved `$0.1304838` and `135269`
tokens. The record is correctly marked invalid with
`readiness_failed` and `native_terminal_failure:end_turn,incomplete`; this is a
budget-control intervention, not a treatment failure.

## Trial-0 observations

| Arm | Outcome | Trajectory | Trustworthy | Requests | Compact requests | Tokens | Cost | Wall time |
|---|---|---|---:|---:|---:|---:|---:|---:|
| `codex_style` | pass | pass | yes | 19 | 6 | 449737 | `$0.4194198` | 191.950 s |
| `claude_style` | pass | fail | no | 55 | 28 | 1017497 | `$1.1208390` | 709.965 s |
| `tinykg` | pass | pass | yes | 15 | 3 | 446523 | `$0.4909554` | 315.574 s |

All three trial-0 workspaces passed the deterministic artifact checks. The
Claude-style trajectory exceeded both registered limits: 27 turns versus 24,
and 33 tool calls versus 24. It also recorded one recoverable
`Read:file_not_found`. Thus its successful final artifacts do not qualify as a
trustworthy success under the pre-registered trajectory contract.

The single trial-0 row is useful only as calibration evidence. It cannot
estimate an arm effect, and the three sequential wall times must not be treated
as a randomized comparison.

## Measurement and control findings

1. The attempt-1 casefold repair worked: the natural spelling `Retry ceiling`
   passed the deterministic grader in all complete trial-0 workspaces.
2. Incremental event persistence and compact metering worked. The complete
   Claude-style rollout records all 55 model requests, including 28 compact
   requests, and its native wall time of 709.965 seconds covers the enclosing
   execution rather than ending near the first invocation.
3. The optimistic preflight did not prevent repeated paid summaries whose
   realized result saved less than 5%. Across all four records, 37 of 93 model
   requests were compact requests and they consumed 585.826 seconds. The
   Claude-style trial alone spent 454.602 seconds in compact requests. A paid
   no-savings result needs closed-loop backoff based on its measured summary
   overhead, not another identical attempt on the next trigger.
4. A post-rollout cumulative check is not a hard budget cap. The runner needs
   a pre-rollout reserve and an execution-time meter that spans every user
   submission and compact request in the rollout. Missing, exhausted or
   unverifiable budget state must fail closed before another provider request.

These are calibration/infrastructure findings. They do not establish that
TinyKG, Codex-style or Claude-style treatment is better.

## Evidence identity

- `attempt-2/checkpoints/codex_style.jsonl`:
  `86f476e18b310ba9094e69b70e9b2907c7dd514da195ff7ee97a9ce9716b017b`
- `attempt-2/checkpoints/claude_style.jsonl`:
  `d4c328b40747cc91c381287e0ff86fb3c899d20e1dba5f20f7a7e1aff80c82db`
- `attempt-2/checkpoints/tinykg.jsonl`:
  `3fdc00eec9c5087ebe992f871d0154c0dc0f5a798d478845beaa99b48efd7db5`
- ignored local raw-trace archive:
  `artifacts/attempt-2-raw-traces.tar.gz`,
  `83f54ba463e3abb268fe5896232bd7ecd95340e107b5caf7f68b869f0994ebef`

The raw archive contains all four E2E run directories, including debug logs,
native events, transcripts, reports and output workspaces. It is excluded from
Git because it is a generated 1.4 MB compressed artifact; its identity is
committed in `SHA256SUMS`.
