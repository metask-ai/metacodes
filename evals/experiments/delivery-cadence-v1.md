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
