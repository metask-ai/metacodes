# Benchmarks

This is the index of how metacodes is measured: fast local performance gates,
the internal evaluation control plane, the internal paired experiments run so
far, and the external WorkBuddy-Bench mainline. Every claim below is bound to a
receipt, manifest, or checked-in protocol file; anything without that binding is
listed as *not yet run*, never as an implied result.

Measurement doctrine, in one paragraph: agent results are properties of
`model × harness`, so comparisons freeze one factor; a rollout that failed for
infrastructure reasons is `invalid`, not `fail`; paid runs happen only behind a
persistent budget journal with per-request authorization and zero silent
retries; and benchmark trials always use a fresh, isolated local TinyKG store —
never the operator's canonical store. See [evals/README.md](../evals/README.md)
for the full framework.

## 1. Local performance gates (zero cost, run anytime)

| Gate | Command | What it checks |
|---|---|---|
| Binary/startup/RSS baseline | `scripts/perf_baseline.sh [--build]` | ReleaseSmall size, warm `--help` latency, peak RSS against the red lines in [PERF_MEMORY_PRINCIPLES.md](PERF_MEMORY_PRINCIPLES.md) |
| Plugin snapshot regression | `zig build plugin:bench` | Zero-provider immutable plugin snapshot benchmark |
| Test-throughput integrity | `python3 scripts/rule_control.py check` | Lean-pinned five-point coverage/failure semantics for the sharded test graph |

Build/test performance experiments must record compile wall, test critical
path, wall/CPU/max RSS, pass/skip/fail/leak counts, shard count, platform, Zig
version, and cache state; cold and warm cache are different experimental
conditions ([tests/README.md](../tests/README.md)).

## 2. Internal evaluation control plane

[evals/README.md](../evals/README.md) documents the rollout data model
(execution/outcome/trajectory/evaluator status, `trustworthy_success`), Wilson
intervals and exact McNemar pairing, order-balanced paired runners, budget
contracts, and the fail-closed release gate. The machine-readable attribution
ladder — native wiring → single-factor TinyKG → single-factor Lean → 2×2
factorial → WorkBuddy acceptance — is
[evals/ATTRIBUTION_EVAL.md](../evals/ATTRIBUTION_EVAL.md) plus
[evals/experiments/tinykg-lean-attribution-v1.json](../evals/experiments/tinykg-lean-attribution-v1.json).

Memory-specific benchmarks (LongMemEval-S, HotpotQA distractor, procedural
intent families) are pinned under `evals/memory/pins/` and governed by
[evals/memory/MEMORY_MATURATION_V1.md](../evals/memory/MEMORY_MATURATION_V1.md).

## 3. Internal paired evidence to date

Raw run artifacts stay outside the published tree (`evals/runs/` is ignored);
the numbers below are the receipt-bound summaries recorded in checked-in
protocol/evaluation documents.

**Plugin kernel v1 paid pairs** (2026-08-22/23, GLM-5.2, 18 pairs × 2 arms;
[PLUGIN_EVALUATION.md](PLUGIN_EVALUATION.md)): both arms 18/18 outcome success
and 17/18 trustworthy success; the candidate was **rejected** because its mean
cost increase (US$0.0648/rollout) exceeded the preregistered US$0.02 gate.
Significant improvement was not established, and no external benchmark claim is
permitted from these runs.

**WorkBuddy code/dev16 development campaign** (2026-08-17 onward, preregistered
in
[workbuddy-dev16-gatev2-memory-v1.json](../evals/experiments/workbuddy-dev16-gatev2-memory-v1.json)
and
[workbuddy-dev16-fullstack-v1.json](../evals/experiments/workbuddy-dev16-fullstack-v1.json)):
single-treatment pairs measured each control-plane lever alone — verification
final gate mean reward +0.068 (6 up / 2 down / 8 tied, p ≈ 0.29), converging
+0.068 → +0.018 → −0.061 across three rounds as instruments healed; memory
accumulation a zero-recall null; cross-roll baseline noise ≈ ±0.13 mean reward,
the same magnitude as the treatment effects. These are directional
instrument-development results on the dev cohort only — one model, no causal
effect sizes, never a held-out claim.

**Three-arm long-horizon PK v2** (`codex_style` vs `claude_style` vs `tinykg`,
[evals/README.md §5.1](../evals/README.md)): three calibration attempts all
ended fail-closed (grader defect, budget-reserve defect, treatment-attestation
defect); the original token contract was empirically falsified and
re-registered at 25M/65M. No promotion receipt exists and no comparative
treatment claim can be made yet.

**TinyKG × Lean 2×2 factorial**: protocol frozen
([tinykg-lean-attribution-v1.json](../evals/experiments/tinykg-lean-attribution-v1.json));
factorial runner still calibration-only — no headline effect numbers exist.

## 4. External mainline: WorkBuddy-Bench

WorkBuddy-Bench (Tencent) is the primary external benchmark, replacing
AgentIF-OneDay (decision 2026-08-11). The operational integration lives in
[scripts/eval/workbuddy/README.md](../scripts/eval/workbuddy/README.md); the
protocol facts:

- **Pinned framework**: commit `b516950be5b56eb3be406c2f76ee1c5111dcb57f`;
  dataset archives pinned by SHA-256 in
  `scripts/eval/workbuddy/manifests/workbuddy-v1-cohorts.json`. metacodes ships
  a **separable overlay** installed into an externally acquired checkout — the
  upstream benchmark is never forked or vendored into this tree (its license
  carries geographic restrictions and derivative-notice requirements).
- **Anti-contamination cohorts**, frozen 2026-08-11 before any task body was
  read: dev 52 / promotion-A 26 / promotion-B 26 / sealed 156 across the
  Code/Web/Office/Security subsets, assigned by salted SHA-256 over task slugs
  only. dev is the only iteration surface; promotion batches run frozen;
  sealed stays unread until the final held-out run.
- **Budget doctrine**: every provider request requires a persistent
  `request_authorized` journal entry; `WBBENCH_PROXY_MAX_RETRIES=0`;
  concurrency starts at 1; a 503/crash after authorization writes an
  authorized-failure receipt with `retry_allowed=false` instead of retrying.
- **Attribution boundary**: the adapter hardwires the isolated local TinyKG on;
  the exposed toggle is the project Lean control plane
  (`METACODES_PROJECT_CONTROL_MODE`). External paired rounds therefore measure
  the *Lean-on-top-of-memory* increment, not a 2×2 decomposition — TinyKG main
  effects come from the internal factorial only.

### Ladder status

| Stage | Scope | Status |
|---|---|---|
| W0 synthetic | adapter, Docker split-mount, ATIF, verifier I/O; zero network | **Passed** (`run_w0.py`) |
| W0.5 real control | official Harbor path, real binaries, scripted local provider, real TinyKG + Lean gate, receipt audit | **Passed** (`run_w05.py`; mechanism evidence, `quality_evidence=false`) |
| W1 Code canary (3 dev tasks) | first paid runner→provider→scorer chain | **Blocked**: three 2026-08-12 attempts each saw all provider requests return HTTP 503 with zero tokens; offline authorized-failure receipts recorded; two wiring gaps found and fixed (project Lean rules not passed to the formal Code job; missing failure receipt on post-run audit). Paid retries require renewed authorization and provider health. |
| W2–W6 dev (52) | per-subset regression and fix loop | Not started |
| W7–W8 promotion (26+26) | frozen-candidate unseen batches | Not started |
| W9 sealed (156 × 3) | final held-out evidence | Sealed, unread |
| W10 full (260 × 3) | optional official leaderboard convention | Not started |

No external WorkBuddy quality score exists yet; scorer output from the 503
round is repository baseline noise and is never reported as an agent result.

## 5. Rules for running and reporting

1. Paid or model-backed runs never happen in ordinary development or CI; they
   require explicit owner authorization with a dollar cap and durable receipts
   ([CONTRIBUTING.md](../CONTRIBUTING.md)).
2. Benchmark trials use fresh HOME/workspace and an isolated local TinyKG;
   remote TinyKG stores only roadmap and aggregated provenance, never task
   bodies or trajectories.
3. Development iterates on dev cohorts only. Sealed cohorts are one-shot; a
   result obtained after peeking is reported as contaminated, not held-out.
4. Report quality together with cost, wall time, tokens, cache behavior,
   stability, and failure attribution — a pass rate alone is not a result.
5. `invalid` (infrastructure/grader failure) never becomes `fail`, and
   `unscored` never becomes `pass`.
