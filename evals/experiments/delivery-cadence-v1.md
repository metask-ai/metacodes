# Delivery-cadence single-factor paired evaluation (v1)

Status: preregistered 2026-09-21, before any paid rollout of this suite.
Mechanism under test: PR #128 `--delivery-cadence` (turn-boundary bounded nudge
when a run keeps making exploration-only tool calls without creating or changing
any file). Product defaults 40 / 80 exploration calls.

## Hypothesis

H1 (primary): on open-ended investigation tasks whose deliverable is a report
file, enforcing the gate raises the rate of runs that have the deliverable on
disk when the runtime allowance ends (`file_exists report.md` check), compared
with the same binary in record-only mode.

H2 (secondary): correctness (`validator` check: exactly one finding line naming
the planted answer) does not drop under the gate.

H0 for the regression cohort: on ordinary tasks (00_smoke, 02_html_game) the
gate never fires (observation record `levels_reached = 0` in both arms) and
cost does not change.

## Design

- Single factor, paired by task and trial, order-balanced (`cli.py run-paired`
  alternating schedule). Same binary in both arms; the arms differ only by
  `--delivery-cadence` vs `--delivery-cadence-observe`.
- Dose: thresholds 10 / 20 exploration calls, scaled to this cohort's runtime
  allowance (see below); the product default 40 / 80 is calibrated to a
  1200 s / ~170-call regime and would not fire inside a 2.5M-token rollout.
  `--max-tokens 4096` in both arms keeps the per-request reserve small.
- Harness kill analogue: per-rollout runtime allowance 2,500,000 metered
  tokens / US$9 (guardrail rates). The binary stops with `stop_reason=budget`
  and exit 0, so the rollout is scored as it stands instead of becoming
  invalid. Both arms get the identical allowance.
- Cohort: `evals/suites/delivery-cadence-v1.json` — 3 hazard tasks over frozen
  synthetic snapshots (commit 4e838d43e5c7043819e2bd81c499c92ba9f9d711) and 2
  regression tasks copied from core-e2e.
- Trials: 2 per hazard task per arm (12 hazard rollouts), 1 per regression
  task per arm (4 rollouts).
  **Amendment, 2026-09-21 07:13 local, before the first paid rollout of the
  paired run:** hazard trials raised from 2 to 3 (18 hazard rollouts) after
  the two calibration rollouts showed large run-to-run variance (46-call
  loop with no report vs 10-call correct delivery on the same task). The
  preregistration text was committed with the old number and is corrected
  here rather than rewritten; every statistic below uses 3 trials.
- Model: glm-5.3-flash through the Metask route (provider profile `metask`,
  alias `anthropic`); one model only.
- Budget: cumulative cap US$80 nominal at the repository guardrail rates
  (US$3 / US$15 per Mtok; the provider's real bill for this model is far
  lower). Per-rollout cap as above.

## Analysis

- Primary: paired comparison of the `file_exists report.md` check and of the
  full outcome with `cli.py compare` (Wilson intervals, exact McNemar).
- Mechanism dose check: the `delivery_cadence` observation record per rollout
  (`exploration_calls`, `levels_reached`, `nudges`) — the treatment must show
  `nudges >= 1` on the hazard tasks for any effect to be attributable; the
  control shows the same crossings with `nudges = 0`.
- Cost, tool calls, turns, wall time reported alongside.

## Claim boundary

Internal single-factor evidence on a self-authored synthetic cohort with one
model. Directional only: 3 tasks x 2 trials cannot establish significance. It
says whether the mechanism fires and whether firing moves the deliverable
rate; it says nothing about external benchmarks.

---

## Results (run 2026-09-21, harness 36d9e781, model glm-5.3-flash via metask)

Receipt-bound summary of `evals/runs/dc-v1/` (raw artifacts stay out of the
tree). Both arms ran the same binary through `#!/bin/sh` wrappers:
`--delivery-cadence[-observe] --delivery-cadence-thresholds 10,20 --max-tokens 4096`
with `METACODES_MAX_TURNS=40` as the identical harness-kill analogue.
22 rollouts, all valid, nominal cost US$6.47 at guardrail rates,
13 minutes wall clock in total.

### Hazard cohort (3 tasks x 3 trials, paired)

| | observe (control) | enforce (treatment) |
|---|---:|---:|
| deliverable on disk (`report.md`) | 9/9 | 9/9 |
| correct, preregistered validator | 7/9 | 5/9 |
| correct, post-hoc lenient (markdown prefix stripped) | 8/9 | 7/9 |
| rollouts crossing >= 1 threshold | 5/9 | 3/9 |
| nudges injected | 0 | 3 |
| mean tool calls | 25.0 | 13.7 |
| mean cost (nominal US$) | 0.315 | 0.290 |
| mean wall time (s) | 41 | 30 |

`cli.py compare` (factor harness, 9 pairs): trustworthy success 77.8% -> 55.6%
(Δ -22.2 pp), discordant pairs 4 regressions / 2 improvements, exact McNemar
p = 0.6875; paired cost Δ -0.025 US$ [95% CI -0.087, 0.037]; tool calls
Δ -11.3 [-28.9, 6.2]; wall Δ -11.0 s [-22.5, 0.6] (candidate faster in 8/9
pairs); frontier class `tradeoff`. Post-hoc lenient correctness: 1 improvement /
2 regressions / 6 ties (p = 1.0).

### Regression cohort (2 ordinary tasks x 1 trial, paired)

Both arms 2/2 pass; the gate never armed in either arm (the first tool call is a
Write, exploration count 0, zero nudges). Cost and call differences (02_html_game
6 vs 12 calls) are run-to-run variance with an inert gate; `compare` labels the
pair `candidate_dominated` on n = 2 with confidence intervals spanning zero.

### Per-rollout detail

| cohort | task | trial | arm | outcome | report.md | validator | lenient (post hoc) | exploration calls | levels | nudges | tool calls | turns | cost | wall s |
|---|---|---:|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| hazard | 90_dc_taint_trace | 0 | observe | pass | yes | yes | correct | 16 | 1 | 0 | 17 | 9 | 0.265 | 31 |
| hazard | 90_dc_taint_trace | 1 | observe | pass | yes | yes | correct | 5 | 0 | 0 | 6 | 7 | 0.225 | 22 |
| hazard | 90_dc_taint_trace | 2 | observe | fail | yes | no | one hop short | 15 | 1 | 0 | 16 | 9 | 0.256 | 28 |
| hazard | 91_dc_unused_setting | 0 | observe | pass | yes | yes | correct | 13 | 1 | 0 | 14 | 11 | 0.329 | 42 |
| hazard | 91_dc_unused_setting | 1 | observe | pass | yes | yes | correct | 5 | 0 | 0 | 11 | 10 | 0.299 | 37 |
| hazard | 91_dc_unused_setting | 2 | observe | pass | yes | yes | correct | 8 | 0 | 0 | 10 | 9 | 0.279 | 31 |
| hazard | 92_dc_invariant_break | 0 | observe | pass | yes | yes | correct | 8 | 0 | 0 | 43 | 14 | 0.380 | 41 |
| hazard | 92_dc_invariant_break | 1 | observe | pass | yes | yes | correct | 51 | 2 | 0 | 56 | 15 | 0.450 | 69 |
| hazard | 92_dc_invariant_break | 2 | observe | fail | yes | no | correct | 51 | 2 | 0 | 52 | 9 | 0.357 | 68 |
| hazard | 90_dc_taint_trace | 0 | enforce | fail | yes | no | one hop short | 16 | 1 | 1 | 17 | 9 | 0.242 | 20 |
| hazard | 90_dc_taint_trace | 1 | enforce | fail | yes | no | one hop short | 16 | 1 | 1 | 17 | 8 | 0.229 | 19 |
| hazard | 90_dc_taint_trace | 2 | enforce | pass | yes | yes | correct | 1 | 0 | 0 | 19 | 9 | 0.260 | 27 |
| hazard | 91_dc_unused_setting | 0 | enforce | pass | yes | yes | correct | 9 | 0 | 0 | 13 | 9 | 0.284 | 32 |
| hazard | 91_dc_unused_setting | 1 | enforce | pass | yes | yes | correct | 5 | 0 | 0 | 10 | 11 | 0.311 | 35 |
| hazard | 91_dc_unused_setting | 2 | enforce | pass | yes | yes | correct | 9 | 0 | 0 | 19 | 17 | 0.410 | 43 |
| hazard | 92_dc_invariant_break | 0 | enforce | fail | yes | no | correct | 7 | 0 | 0 | 8 | 9 | 0.270 | 26 |
| hazard | 92_dc_invariant_break | 1 | enforce | fail | yes | no | correct | 10 | 1 | 1 | 11 | 10 | 0.298 | 33 |
| hazard | 92_dc_invariant_break | 2 | enforce | pass | yes | yes | correct (2 lines) | 6 | 0 | 0 | 9 | 10 | 0.311 | 37 |
| regression | 00_smoke | 0 | observe | pass | yes | n/a | n/a | 0 | 0 | 0 | 2 | 3 | 0.125 | 4 |
| regression | 02_html_game | 0 | observe | pass | yes | n/a | n/a | 0 | 0 | 0 | 6 | 9 | 0.346 | 62 |
| regression | 00_smoke | 0 | enforce | pass | yes | n/a | n/a | 0 | 0 | 0 | 2 | 3 | 0.124 | 4 |
| regression | 02_html_game | 0 | enforce | pass | yes | n/a | n/a | 0 | 0 | 0 | 12 | 11 | 0.422 | 81 |

### Instrument limitations recorded after the run

- The validators grade only the finding line (exactly one `FINDING:` /
  `UNUSED=` line after stripping nothing; a markdown header prefix fails).
  The justification and per-item notes the prompts request are ungraded by
  design; a report consisting of the single correct line passes. The
  post-hoc lenient column above strips markdown prefixes and is labelled as
  post hoc wherever it appears.
- The fixture snapshot is pinned to commit 4e838d43 on this branch. It stays
  reachable under the repository's merge-commit policy; a squash or rebase
  merge would orphan it and make the suite unrunnable from a fresh clone.
- **The Bash sensor at the time of the run silenced the gate on `rg`.** Its
  read-only roster was the permission layer's list, which has no `rg`; the
  first `rg` therefore counted as a mutation and disarmed the gate for the
  rest of the run. Replaying the 22 transcripts: in 6 of the 18 hazard
  rollouts (3 observe, 3 enforce; five on 91_dc_unused_setting, one on
  90_dc_taint_trace where `rg` was the second call) an `rg` ran before the
  first Write, so the recorded crossings (5/9 and 3/9) are a lower bound and
  the treatment dose was suppressed in a third of the hazard rollouts.
  `python3 -c` one-liners silenced 2 more by design (unprovable payload;
  unchanged after the fix). One `$(...)` occurred inside a `for` loop
  header and disarms under both the old and the corrected sensor; no
  `sed -i`, `>&file` or awk/sed write payload occurred. The sensor was
  corrected after the run (Codex review: substitutions, `>&file`, awk/sed
  write payloads, `sort -o`, `uniq in out`, `find -fprint`, `fd -x` now
  disarm; `rg`, `fd`, `tree`, `jq` and `git -C` count as exploration). A
  v1.1 re-run of the hazard cohort with the corrected sensor is recorded
  below when available.

### Reading

1. **H1 is untested, not refuted.** The hazard the gate targets — a run that
   never writes its deliverable before the kill — did not occur in the control
   arm (9/9 delivered within the 40-turn cap), so the primary metric is tied
   9/9. The calibration rollout before the run did show the failure shape once
   (46 Bash calls, identical `for` loop repeated ~30 times, no report, budget
   kill), so the shape exists for this model; this cohort at this dose produced
   a base rate of 0/9. A cohort where the control fails to deliver in a
   meaningful fraction of runs is a precondition for any positive result.
2. **The mechanism works as specified.** It armed in 5/9 control runs (record
   only) and fired in 3/9 treatment runs; the nudged 92_dc_invariant_break run
   wrote the report on the very next turn (Write as the first tool of turn 9),
   with content correct, in 11 tool calls where the control spent 51-56 calls
   on the same task in two of three trials.
3. **No positive value demonstrated on quality; a directional cost.** Strict
   correctness dropped 2 net pairs (p = 0.69). Two of the three nudged runs
   (both 90_dc_taint_trace) named the sink one hop short of the shell call; the
   control made the same error once, un-nudged, so with three nudged runs the
   effect is not attributable. The third correctness loss is a markdown-header
   formatting miss the validator rejects by preregistered rule; the control
   also lost one rollout to it. Cost and wall time moved in the gate's favour
   (candidate faster in 8/9 pairs) but the intervals include zero.
4. **Decision.** Keep `--delivery-cadence` opt-in and off by default. Do not
   enable it in any WorkBuddy arm on this evidence. The next test that could
   show value needs (a) a cohort whose control arm fails to deliver at a
   non-trivial rate — longer tasks, or the observed loop pathology induced
   deliberately — and (b) a content-level grader that separates "wrong
   answer" from "wrong line format", registered before the run.

---

## Results v1.1 (re-run 2026-09-21, harness 66ed1be8, corrected sensor)

Same suite, arms, dose (10 / 20), turn cap (40) and model as v1; the only
change is the binary: commit 66ed1be8, whose Bash sensor counts `rg` as
exploration and rejects substitutions, `>&file`, awk/sed write payloads,
`sort -o`, `uniq in out`, `find -fprint` and `fd -x`. 18 hazard rollouts,
all valid, nominal US$5.35. The binary was rebuilt again at
08:47:47 local for the follow-up fixes, after the last v1.1 rollout finished
(08:45:40), so every v1.1 rollout ran the 66ed1be8 sensor; replaying the
transcripts also finds none of the shapes the later fixes cover.

| | observe (control) | enforce (treatment) |
|---|---:|---:|
| deliverable on disk (`report.md`) | 9/9 | 9/9 |
| correct, preregistered validator | 6/9 | 9/9 |
| rollouts crossing >= 1 threshold | 6/9 | 7/9 |
| nudges injected | 0 | 7 |
| mean tool calls | 15.9 | 17.2 |
| mean cost (nominal US$) | 0.285 | 0.309 |
| mean wall time (s) | 35 | 38 |

`cli.py compare` (9 pairs): trustworthy success 66.7% -> 100.0% (Δ +33.3 pp),
discordant pairs 0 regressions / 3 improvements, exact McNemar p = 0.25;
paired cost Δ +0.024 US$ [95% CI -0.012, 0.060]; tool calls Δ +1.3 [-13.8,
16.5]; wall Δ +3.1 s [-7.7, 13.9]; frontier class `tradeoff` (quality up,
cost not lower). With the roster fixed the gate crossed a threshold in 7/9
treatment runs (v1: 3/9) and fired 7 nudges; the control crossed in 6/9.

| task | trial | arm | outcome | report.md | validator | exploration calls | levels | nudges | tool calls | turns | cost | wall s |
|---|---:|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| 90_dc_taint_trace | 0 | observe | pass | yes | yes | 6 | 0 | 0 | 7 | 8 | 0.235 | 21 |
| 90_dc_taint_trace | 1 | observe | pass | yes | yes | 16 | 1 | 0 | 17 | 10 | 0.278 | 32 |
| 90_dc_taint_trace | 2 | observe | pass | yes | yes | 18 | 1 | 0 | 19 | 8 | 0.252 | 31 |
| 91_dc_unused_setting | 0 | observe | pass | yes | yes | 9 | 0 | 0 | 10 | 9 | 0.269 | 29 |
| 91_dc_unused_setting | 1 | observe | fail | yes | no | 10 | 1 | 0 | 11 | 10 | 0.282 | 32 |
| 91_dc_unused_setting | 2 | observe | pass | yes | yes | 11 | 1 | 0 | 12 | 11 | 0.318 | 37 |
| 92_dc_invariant_break | 0 | observe | fail | yes | no | 6 | 0 | 0 | 7 | 7 | 0.264 | 37 |
| 92_dc_invariant_break | 1 | observe | fail | yes | no | 48 | 2 | 0 | 49 | 11 | 0.358 | 56 |
| 92_dc_invariant_break | 2 | observe | pass | yes | yes | 10 | 1 | 0 | 11 | 10 | 0.310 | 40 |
| 90_dc_taint_trace | 0 | enforce | pass | yes | yes | 6 | 0 | 0 | 7 | 8 | 0.230 | 18 |
| 90_dc_taint_trace | 1 | enforce | pass | yes | yes | 13 | 1 | 1 | 16 | 7 | 0.228 | 25 |
| 90_dc_taint_trace | 2 | enforce | pass | yes | yes | 16 | 1 | 1 | 17 | 10 | 0.281 | 32 |
| 91_dc_unused_setting | 0 | enforce | pass | yes | yes | 10 | 1 | 1 | 13 | 12 | 0.319 | 35 |
| 91_dc_unused_setting | 1 | enforce | pass | yes | yes | 10 | 1 | 1 | 11 | 11 | 0.298 | 31 |
| 91_dc_unused_setting | 2 | enforce | pass | yes | yes | 10 | 1 | 1 | 11 | 10 | 0.298 | 28 |
| 92_dc_invariant_break | 0 | enforce | pass | yes | yes | 9 | 0 | 0 | 12 | 11 | 0.329 | 42 |
| 92_dc_invariant_break | 1 | enforce | pass | yes | yes | 13 | 1 | 1 | 14 | 12 | 0.385 | 55 |
| 92_dc_invariant_break | 2 | enforce | pass | yes | yes | 15 | 1 | 1 | 54 | 12 | 0.416 | 78 |

### Reading, both runs together

- Deliverable rate is tied 9/9 in all four arm-runs: on this cohort the
  control never fails to write the report inside 40 turns, so the hazard the
  gate was built for has a base rate of zero here and H1 remains untested.
- Strict correctness, kept separate by sensor version because the delivered
  dose differed: v1 (roster silenced the gate on `rg` in 6/18 rollouts)
  4 regressions / 2 improvements, p = 0.69; v1.1 (corrected sensor)
  0 regressions / 3 improvements, p = 0.25. Neither run shows an effect
  distinguishable from noise. The pooled figure (4 / 5 over 18 pairs,
  p ≈ 1.0) is a descriptive sensitivity check only, not a single treatment
  estimate: the two runs are not comparable pairs. The v1.1 direction
  matches what the mechanism is designed to do (a nudged run writes, then
  keeps improving in place; all nine treatment reports were correct), which
  is a reason to run a confirmatory study, not evidence of causation — the
  control delivered 9/9 in both runs, so H1 is untested either way.
- Cost: v1 lower with the gate, v1.1 slightly higher; both intervals span
  zero. The gate neither saves nor costs money at this cohort's scale.
- Decision unchanged: keep `--delivery-cadence` opt-in and off by default.
  The evidence now justifies one more step, not a rollout: a confirmatory
  run of the same design with ~18 pairs and a content-level grader
  registered up front, which would put a 3/0-per-9 effect at p ≈ 0.03 if it
  holds. It still would not test H1; that needs a cohort where the control
  actually fails to deliver.
