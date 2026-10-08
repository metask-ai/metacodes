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

---

## Results — stage A (run 2026-10-08, harness e78affa4, model glm-5.3-flash via metask)

Receipt-bound summary of `evals/runs/cg-v1/stageA/` (raw artifacts stay out
of the tree). Both arms ran one ReleaseSafe binary (sha256 `60a99570…86f6`,
`metacodes 0.3.2-dev+e78affa49d14`, clean tree) through `#!/bin/sh`
wrappers. 12 rollouts, all valid, nominal cost US$3.01 at guardrail rates.

| task | arm | validator | final pinned check | checks | continuations | model ran the tests | turns | cost |
|---|---|---|---|---:|---:|---:|---:|---:|
| 93_cg_semver | observe | pass | passed | 1 | 0 | 2 | 8 | 0.300 |
| 93_cg_semver | enforce | pass | passed | 1 | 0 | 2 | 7 | 0.236 |
| 94_cg_duration | observe | pass | passed | 1 | 0 | 4 | 8 | 0.241 |
| 94_cg_duration | enforce | pass | passed | 1 | 0 | 2 | 5 | 0.176 |
| 95_cg_csvline | observe | pass | passed | 1 | 0 | 0 | 5 | 0.173 |
| 95_cg_csvline | enforce | pass | passed | 1 | 0 | 0 | 4 | 0.154 |
| 96_cg_roman | observe | pass | passed | 1 | 0 | 6 | 11 | 0.325 |
| 96_cg_roman | enforce | pass | passed | 1 | 0 | 10 | 16 | 0.448 |
| 97_cg_intervals | observe | pass | passed | 1 | 0 | 4 | 8 | 0.216 |
| 97_cg_intervals | enforce | pass | passed | 1 | 0 | 4 | 8 | 0.218 |
| 98_cg_wrap | observe | pass | passed | 1 | 0 | 0 | 11 | 0.307 |
| 98_cg_wrap | enforce | pass | passed | 1 | 0 | 4 | 7 | 0.220 |

"model ran the tests" counts Bash commands that invoked the visible runner
(`run_tests`, `tests/run.py`, unittest or pytest).

### Reading

1. **The stage A stopping rule fired: stage B was not run.** The baseline
   arm finished with the pinned check passing in 6/6 rollouts and passed the
   full validator (visible plus hidden cases) in 6/6, so the hazard the gate
   targets did not occur. H1 is untested on this cohort with this model, not
   refuted. The remaining US$27 of the authorization was not spent.
2. **The mechanism ran as specified in the real REPL path.** Every rollout
   in both arms ran the pinned check exactly once (`checks = 1`), the
   baseline never continued, and the candidate had nothing to continue on
   (`continuations = 0`, `unchecked_changes = false`). The terminal record was
   present and well-formed in all 12 journals.
3. **The cohort is too easy for this model.** In three rollouts the model
   never ran the tests and still produced an implementation that passes every
   hidden case, including the exact-decimal duration and the full semver
   precedence chain. A cohort where the control arm finishes with a failing
   check in a meaningful fraction of runs — harder or larger tasks, or a
   weaker model, as in the paper's 27B setting — is a precondition for any
   positive result.
4. Cost and turns do not separate the arms here (candidate mean 7.8 turns /
   US$0.24 vs baseline 8.5 / US$0.26); with the gate idle this is
   run-to-run variance, not a treatment effect.
