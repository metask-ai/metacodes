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
| Sealed gateway load | `zig build sealed:bench -Doptimize=ReleaseFast -- --concurrency N --runs R --steps S --latency-ms L` | Steps per second, gateway overhead above the mock model's measured latency (p50/p95/p99), queue wait, admission counters, provider-cache hits; `--direct 1` measures host + mock alone ([SEALED_GATEWAY_SCALE_DESIGN.md](SEALED_GATEWAY_SCALE_DESIGN.md) §10) |

**Sealed gateway, first recorded run** (2026-10-16, Windows 11, 28 logical
CPUs, ReleaseFast, in-process mock model, `METACODES_LOG=error`; commit of
this table's PR). The two defects the benchmark found before these numbers:
a 16 MiB request buffer allocated and zeroed per connection (now 64 KiB,
grown on demand), and the process-wide request-setup gate of 8 that counted
the wait for a model's first byte (now raised to the server's model-slot
cap). Mock latency is nominal; the mock reports its actual sleep.

| Load | Steps/s | Step p50 / p99 (ms) | Overhead above mock p50 / p99 (ms) | Queue wait avg (ms) |
|---|---|---|---|---|
| 8 clients, mock 0 ms | 7 111 | 1 / 3 | 1 / 3 | 0 |
| 64 clients, mock 20 ms (actual 30) | 1 835 | 33 / 39 | 3 / 9 | 0 |
| 256 clients, mock 50 ms (actual 58), 112 workers | 1 676 | 136 / 196 | 76 / 136 | 72 |
| direct to mock, 64 clients, mock 20 ms | 2 048 | 31 / 36 | 2 / 7 | — |

Reading: the gateway's own cost per Step is 1–3 ms; at 64 in-flight Steps
it keeps pace with the host (direct 2 048/s versus 1 835/s through the
gateway); at 256 clients the fixed worker pool (112 threads) becomes the
limit and queue wait appears, which is the trigger §3 names for the evented
backend. Before the two fixes the same 64-client load ran at 249 Steps/s
with a p50 of 141 ms.

### Footprint snapshot

Measured 2026-10-18 on Apple Silicon, macOS, `main` at `7efc170`, built with
`zig build -Doptimize=ReleaseSmall` into a scratch prefix (development layout:
TinyKG not staged, so the run below had memory degraded; `METACODES_JEV_URL=off`).
One machine, one sitting; these are observations, not gates.

| Measurement | Value | How |
|---|---|---|
| Core binary | 5,501,128 bytes (4.9 MB stripped, 2.6 MB gzipped) | `wc -c`, `strip`, `gzip -c \| wc -c` |
| Warm start, `--help` | 5.1–7.2 ms over 6 runs | wall time after one warm-up run |
| Idle process peak RSS, `--help` | 2.7 MB (1.7 MB peak footprint) | `/usr/bin/time -l` |
| Headless run, 20 tool rounds | 23 MB peak RSS (13.9 MB peak footprint), 2.3 s wall | `-p` with `--permission bypassPermissions` against a local Anthropic-SSE mock that answers each turn with one `Glob` call |
| Release archives, 0.5.0 | 16.6 MB Linux x86_64, 20.8 MB macOS arm64, 16.5 MB Windows x86_64 | GitHub release assets; each holds the CLI, TinyKG CLI and daemon, both Lean kernels and ripgrep |

Same machine, the same `--help` peak-RSS probe on two other agent CLIs:
Codex CLI 0.163.0 at 20 MB and Claude Code 2.1.278 at 121 MB. `--help` is only
the process floor, not a session; it is reported because it is reproducible
with one command, not as a like-for-like workload comparison.

The size red line in [PERF_MEMORY_PRINCIPLES.md](PERF_MEMORY_PRINCIPLES.md) §2
was first calibrated on a 1.29 MB build (2026-06-05) at 1.5 MB; on 2026-10-18 it
was recalibrated to 6 MiB from this measurement. Startup and idle RSS stay
inside their original lines, and the 20-round run is inside the 30 MB typical
session line. `scripts/perf_baseline.sh` is not wired into CI.

Build/test performance experiments follow the recording discipline normatively
listed in [tests/README.md](../tests/README.md) — timings, resource ceilings,
result counts, shard/platform/toolchain, and cache state, with cold and warm
cache as separate experimental conditions.

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

**Host check gate v1, stage A** (2026-10-08, glm-5.3-flash, 6 tasks × 1 pair;
[check-gate-v1.md](../evals/experiments/check-gate-v1.md)): both arms 6/6 on
the full validator and 6/6 finishing with the pinned check passing, so the
hazard the gate targets never occurred and the preregistered stopping rule
skipped the paired stage (US$3.01 nominal spent). The gate ran its check once
per rollout and never continued. H1 is untested on this cohort, not refuted.
v2 (multi-file feature requests with regression traps, 5 tasks × 1 pair;
[check-gate-v2.md](../evals/experiments/check-gate-v2.md)) stopped the same
way (0/5 finished red, 4/5 validator in both arms, US$3.60): the model ran the
tests in every rollout. Both textkit runs instead rewrote an existing test to
match a changed shared tokenizer, which the gate recorded as a pass; a pass
after modifying an existing test is now tainted. v3 (four hard
specifications, 243 graded tests; [check-gate-v3.md](../evals/experiments/check-gate-v3.md))
ran its paired stage (8 pairs, US$15.75 with stage A): partial credit +0.003
(sign test p = 1.0), full pass 62.5% → 75.0% (McNemar p = 1.0), and again 0/12
baseline rollouts finished red and 0 continuations — across v1–v3 the gate never
had a failing check to act on for this model (0/23).

**Test integrity obligation v1** (2026-10-08, glm-5.3-flash, 5 tasks, 8 pairs;
[test-integrity-v1.md](../evals/experiments/test-integrity-v1.md)): enforce
(one message: restore the existing tests or quote the request) against observe.
The hazard appeared only in `textkit` (2/2 observe runs rewrote the existing
test); two new traps never triggered. Trap validator pass 4/6 in both arms
(McNemar p = 1.0); both messaged `textkit` runs kept the change and quoted the
issue (0/2 restored); no harm on the two legitimate tasks, at about three extra
turns when the message fires; US$5.23 nominal. In all four `textkit` runs the
only failing validator test is the rewritten one itself. The sensor matched
every workspace's `git diff` (8 fired, 8 silent, including 3 runs that only
appended tests).

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

- **Pinned framework**: commit `b516950be5b56eb3be406c2f76ee1c5111dcb57f`
  (authority: `workbuddy_commit` and the SHA-256 dataset pins in
  `scripts/eval/workbuddy/manifests/workbuddy-v1-cohorts.json`). metacodes ships
  a **separable overlay** installed into an externally acquired checkout — the
  upstream benchmark is never forked or vendored into this tree (its license
  carries geographic restrictions and derivative-notice requirements).
- **Anti-contamination cohorts**, frozen 2026-08-11 before any task body was
  read: dev 52 / promotion-A 26 / promotion-B 26 / sealed 156 (the manifest's
  `cohort_totals`) across the Code/Web/Office/Security subsets, assigned by
  salted SHA-256 over task slugs only. dev is the only iteration surface;
  promotion batches run frozen; sealed stays unread until the final held-out
  run.
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

No ladder-grade external WorkBuddy score exists yet: the stages above have not
produced a receipt-clean promotion or sealed result. Scorer output from the 503
round is repository baseline noise and is never reported as an agent result.

### Diagnostic full run (0.1.0, September 2026)

Outside the ladder, metacodes 0.1.0 (commit `1d27f07`) with GLM-5.2 ran all
260 tasks once in the baseline configuration (every experimental treatment off,
project control not staged). The archived audit
[2026-09-12-metacodes-takeover-audit](../evals/benchmarks/2026-09-12-metacodes-takeover-audit/report.md)
selects one complete run per job without regard to reward. Next to the official
leaderboard for the same model
([v1.2, 2026-10-15](https://workbuddybench.com/), three-run means, think mode):

| Harness | Code | Web | Office | Security |
|---|---:|---:|---:|---:|
| metacodes 0.1.0, self-run, 1 pass | 72.66 | 81.14 | 78.81 | 58.97 |
| CodeBuddy Code 2.109.3, official | 71.5 | 67.4 | 79.6 | — |
| Claude Code 2.1.187, official | 77.1 | 60.7 | 79.6 | — |

v1.2 lists no Security score for GLM-5.2; the snapshot cited by the
[Security trajectory study](../evals/benchmarks/2026-09-12-security-trajectory-research/report.md)
listed 76.32 (CodeBuddy Code) and 80.86 (Claude Code). Why this is an
observation and not a ladder result or a leaderboard entry:

- one pass against a three-run mean, with no variance estimate;
- the sealed cohort had been inspected and fixes made before this run, so it is
  a diagnostic re-test, not a blind held-out result;
- 7 of 17 selected transactions committed their receipts; the other 10 ended
  `authorized_failure(post_run_evidence_audit)` after the runner finished, and
  their scores come from Harbor's `result.json`;
- the run did not follow the official protocol: the job proxy set temperature
  0.0 instead of provider defaults, no reasoning effort was requested, and
  WebSearch and AskUserQuestion stayed visible although the official runs
  disable them;
- a standing harness difference, not a protocol setting: headless metacodes
  has no turn-cap option and stops a run at 400 turns, where both official
  harnesses use 256 (no September trial reached the cap; the longest used
  281 turns);
- Office and Web were judged by gpt-5.6-sol at temperature 0.0 with a
  16,384-token output, while the leaderboard's judge is Kimi K2.7 Code
  (temperature 1.0, thinking; [Tencent/workbuddy-bench#3](https://github.com/Tencent/workbuddy-bench/issues/3)), so those
  two columns are not comparable across rows. These protocol facts come from
  the September job configurations as recorded in the alignment table of
  [#316](https://github.com/metask-ai/metacodes/pull/316), which prepares a protocol-aligned three-run
  evaluation. WorkBuddy-Bench has no public submission process, so that run is
  self-reported unless the maintainers list it.

The README reads it as: on Code, which hidden tests score, metacodes lands
between the two official harnesses; Security trails; Web and Office are not
compared because the judges differ. No stronger claim is made.

### Upstream Harbor benchmarks (Terminal-Bench, DeepSWE)

[scripts/eval/harbor/README.md](../scripts/eval/harbor/README.md) runs a
metacodes Linux release as an installed agent of upstream Harbor (0.26), the
runner behind Terminal-Bench 2.x and later, DeepSWE and the Harbor Hub
datasets. Each trial gets its own state dir and an exclusive TinyKG store.
The adapter produces ATIF trajectories and Harbor's token counters.

| Stage | Status |
|---|---|
| Zero-cost smoke (`python3 -m scripts.eval.harbor.smoke`): real `harbor run`, scripted endpoint, `ubuntu:22.04` task | **Passed** 2026-11-16 with the 0.12.0 release: reward 1.0, one Bash call in the trajectory |
| Paid pilot: Terminal-Bench 2.1, first 5 tasks, 1 attempt, `qwen/qwen3.8-max`, 0.12.0 | **Adapter check only** (2026-11-16, US$1.04 nominal): 2 of 2 valid trials reward 1.0; 3 invalid (see below) |
| Terminal-Bench / DeepSWE score | Not run |

The pilot's three invalid trials are infrastructure failures, not agent
failures. Two task images (`torch-tensor-parallelism`, `write-compressor`:
Ubuntu 24.04 without `ca-certificates`) had no CA bundle, so every provider
request failed with `TlsInitializationFailed`; the adapter now installs the
package when the image lacks one. The third (`schemelike-metacircular-eval`)
stopped at turn 13 when the provider refused the account (DashScope
`Arrearage`). Five tasks and one attempt make no score.

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
