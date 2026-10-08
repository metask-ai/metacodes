# Host check gate single-factor paired evaluation (v1)

Status: preregistered 2026-10-08, before any paid rollout of this suite.
Mechanism under test: `--check-gate` (host check gate, CheckGate.lean): when
the model ends its turn after changing the workspace, the host runs the
pinned check command itself, and a clean failure continues the same
conversation with the verdict, at most `--check-gate-max` times.

Motivation: arXiv 2610.02826 (Recursive Self-Rewrite) reports that a harness
which runs the task verifier when the model claims completion and asks it to
reflect and continue on failure (their RSRT) doubles a fixed model's
Terminal-Bench-Hard pass rate (33% → 66%). That comparison put the hidden
benchmark verifier inside the loop and ran once per harness. This
experiment measures the deployable version: the pinned check is the
workspace's own visible test runner, and the score comes from a validator
with hidden edge cases the check does not contain.

## Hypotheses

H1 (primary): on specification tasks whose workspace carries a visible test
runner, enforcing the gate raises the rate of runs whose final workspace
passes the full validator (visible plus hidden cases), compared with the
same binary in observe mode.

H2 (mechanism): the gate lowers the rate of runs that end with the pinned
check still failing (`check_gate.final_verdict = failed` in the terminal
record) — the hazard it targets.

H0 for cost: the gate's extra turns are bounded by the budget; report the
paired difference in cost, turns and wall time.

## Design

- Single factor, paired by task and trial, order-balanced (`cli.py
  run-paired` alternating schedule). Same binary in both arms; the arms differ
  only by `--check-gate` (candidate) vs `--check-gate-observe` (baseline),
  both with `--host-check 'sh run_tests' --check-gate-max 3`. Observe mode runs
  the identical check at the identical boundaries and records the verdict, so
  the baseline measures the hazard the candidate acts on.
- Harness kill analogue: `METACODES_MAX_TURNS=40` in both wrappers (stop
  reason `max_turns`, exit 0, workspace graded as it stands).
- Cohort: `evals/suites/check-gate-v1.json` — 6 self-authored specification
  tasks over frozen snapshots (commit
  2183730d818d04456979d8bf08a9c014df227e1c). The scenario prompt names only
  `README.md`; the visible tests and `run_tests` are discoverable in the
  workspace but not mentioned. Every validator rejects the stub and accepts a
  reference implementation kept outside the tree.
- Model: glm-5.3-flash through the Metask route; one model only.
- Stage A (calibration): 1 trial per task per arm (12 rollouts). Proceed to
  stage B only if the baseline arm shows the hazard at all — at least one
  baseline rollout with `final_verdict = failed`, or at least two baseline
  rollouts failing the validator. Otherwise stop and report H1 as untested at
  this dose for this model (the delivery-cadence lesson: a base rate of zero
  makes the primary metric uninformative).
- Stage B (paired run): 3 trials per task per arm (36 rollouts). Stage A
  rollouts are reported separately and not pooled.
- Budget: cumulative cap to be set by the owner's authorization (recorded
  below) at the repository guardrail rates (US$3 / US$15 per Mtok); no
  silent retries.

## Analysis

- Primary: paired comparison of the validator check with `cli.py compare`
  (Wilson intervals, exact McNemar), stage B only.
- Mechanism: per rollout, the `check_gate` observation record (`checks`,
  `continuations`, `final_verdict`, `unchecked_changes`). An effect is
  attributable only where the candidate shows `continuations >= 1`; the
  baseline must show `continuations = 0` throughout.
- Cost, tool calls, turns and wall time reported alongside.

## Claim boundary

Internal single-factor evidence on a self-authored synthetic cohort with one
model. 6 tasks × 3 trials cannot establish significance for a small effect;
the result says whether the hazard exists for this model, whether the gate
fires on it, and whether firing moves the validator rate. It says nothing
about external benchmarks, about workspaces without a test runner (no
regression cohort is included because the pinned command does not exist
there), or about the harness's Lean governance layer unless the run records a
kernel fingerprint.

## Authorization

Authorized by the owner on 2026-10-08, before any paid rollout: cumulative
cap US$30 nominal at the guardrail rates, covering stage A and stage B
together (stage B passes stage A's spend as the budget-used offset).
Per-rollout runaway cap 2,500,000 metered tokens / US$9, the same as the
delivery-cadence run. Both arms run one ReleaseSafe binary built from the
recorded harness revision through `#!/bin/sh` wrappers.
