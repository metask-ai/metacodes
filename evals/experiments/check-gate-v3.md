# Host check gate single-factor paired evaluation (v3, hard specifications)

Status: preregistered 2026-10-08, before any paid rollout of this suite.
Mechanism under test: unchanged ([check-gate-v1.md](check-gate-v1.md)), now
from a binary that also taints a pass after an existing test was modified
(8dca4cd8).

## Why a v3

v1 (single-module specifications) and v2 (multi-file feature requests with
regression traps) never produced the hazard: glm-5.3-flash finished with the
pinned check passing in 11/11 baseline rollouts, because it runs the tests and
keeps going until they are green. The gate can only matter where reaching green
is hard enough that a run ends red. arXiv 2610.02826 saw its continuation
harness help most on its hardest set (TB-Hard 33% → 66%, verifier in the loop).
Terminal-Bench itself is not run here: no Docker on the evaluation host, its
verifiers are hidden from the agent (so the only pinned check would be the
oracle), and its task length exceeds the remaining budget.

## Cohort

`evals/suites/check-gate-v3.json` (snapshot commit
7a860ef558c45a9342e937c9ad7e37a8a4b9476e): four self-authored single-module
specifications chosen for many interacting rules and no standard-library
shortcut.

| task | visible / hidden tests | what makes it hard |
|---|---|---|
| d1_cg3_cron | 37 / 20 | steps on names and values, the day-of-month / day-of-week "either" rule, leap days, never-firing schedules |
| d2_cg3_sheet | 49 / 22 | unary minus above `^`, error values and left-wins propagation, cycles and their dependents, empty-cell semantics, whole-number results, decimal-text rounding |
| d3_cg3_calc | 30 / 21 | right-associative power under prefix signs, decimal-text rounding, positioned error messages, parse-before-run |
| d4_cg3_ranges | 37 / 27 | caret/tilde/x-range desugaring, hyphen ranges with partials, the pre-release exclusion rule |

The prompt is "Implement … in `<module>` so that it follows the specification
in `README.md`." Expected values come from reference implementations kept
outside the tree; they pass all 243 validator cases and the stubs fail all but
one.

## Hypotheses

H1 (primary): enforcing the gate raises the final **partial credit** — the
fraction of validator tests (pristine visible plus hidden) that pass in the
final workspace — compared with observe mode.

H1b (secondary): the gate raises the full-validator pass rate.

H2 (mechanism): the gate lowers the rate of runs that end with the pinned check
failing (`check_gate.final_verdict = failed`).

H0 for cost: report the paired difference in cost, turns and wall time.

## Design

- Single factor, paired by task and trial, order-balanced (`cli.py
  run-paired`); one ReleaseSafe binary through two `#!/bin/sh` wrappers that
  differ only by `--check-gate` / `--check-gate-observe`, both with
  `--host-check 'sh run_tests' --check-gate-max 3` and `METACODES_MAX_TURNS=60`
  (raised from 40: these tasks take longer, and a turn-cap stop before the
  final turn would leave the gate no boundary to act at).
- Model: glm-5.3-flash through the Metask route, as in v1 and v2.
- Stage A: 1 trial per task per arm (8 rollouts). Proceed to stage B if the
  baseline shows the hazard: at least one baseline rollout with
  `final_verdict = failed`, or at least two failing the full validator.
- Stage B: trials per task per arm = the largest of 3 or 2 for which
  trials × stage A cost × 1.25 fits in the remaining budget; if not even 2 fit,
  stop and ask the owner before spending more. Stage A rollouts are reported
  separately.

## Analysis

- Primary: per (task, trial) pair, candidate minus baseline partial credit;
  report the mean paired difference, the per-pair signs and an exact sign test
  over non-tied pairs. Partial credit is recomputed after the run by running
  the validator on each final workspace (deterministic) and reading its
  `<failed> failed, <passed> passed` line.
- Secondary: full-validator pass with `cli.py compare` (Wilson, exact McNemar).
- Mechanism: the `check_gate` record per rollout (`checks`, `continuations`,
  `final_verdict`, `unchecked_changes`); credit changes are attributable only
  where the candidate shows `continuations >= 1`.
- Cost, turns and wall time alongside.

## Claim boundary

Internal single-factor evidence on a self-authored cohort with one model; 4
tasks × at most 3 trials cannot establish significance for a small effect.
Because the pinned check is the visible suite and the grade includes hidden
tests, a gain measures deployable continuation on a visible check, not an oracle
in the loop.

## Authorization

Within the owner's 2026-10-08 authorization of US$30 nominal across the
check-gate experiments: v1 spent US$3.01 and v2 US$3.60, leaving US$23.39 for
v3. Stage B passes stage A's spend as the budget-used offset. Per-rollout
runaway cap 2,500,000 metered tokens / US$9.
