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

---

## Results — stage A (run 2026-10-08, harness c9f14ae3, model glm-5.3-flash via metask)

Receipt-bound summary of `evals/runs/cg-v3/stageA/`. One ReleaseSafe binary
(`metacodes 0.3.2-dev+c9f14ae3497d`, clean tree) through both wrappers. 8
rollouts, all valid, nominal cost US$5.61 (check-gate total US$12.22 of
US$30).

| task | arm | validator | partial credit | final pinned check | checks | continuations | model ran the tests | turns | cost |
|---|---|---|---:|---|---:|---:|---:|---:|---:|
| d1_cg3_cron | observe | pass | 1.000 | passed | 1 | 0 | 6 | 13 | 0.452 |
| d1_cg3_cron | enforce | pass | 1.000 | passed | 1 | 0 | 12 | 17 | 0.565 |
| d2_cg3_sheet | observe | fail | 0.986 | passed | 1 | 0 | 8 | 11 | 0.639 |
| d2_cg3_sheet | enforce | pass | 1.000 | passed | 1 | 0 | 16 | 22 | 1.136 |
| d3_cg3_calc | observe | pass | 1.000 | passed | 1 | 0 | 10 | 12 | 0.479 |
| d3_cg3_calc | enforce | pass | 1.000 | passed | 1 | 0 | 4 | 8 | 0.421 |
| d4_cg3_ranges | observe | fail | 0.969 | passed | 1 | 0 | 14 | 25 | 1.049 |
| d4_cg3_ranges | enforce | fail | 0.984 | passed | 1 | 0 | 10 | 18 | 0.870 |

### Reading

1. **The hazard did not occur and the gate never acted.** Every rollout in
   both arms finished with the visible suite green (0/8 red); the candidate
   made no continuation. The model ran the tests 4–16 times per rollout and
   stopped only on green — the same behaviour as v1 and v2 (0/15 baseline
   rollouts finished red across the three cohorts).
2. **The remaining failures are hidden cases the pinned check cannot see** (one
   sheet case in the baseline, two and one ranges cases), so the gate had no
   signal to act on. The candidate's +0.007 mean partial credit (2 up, 2 tied)
   is run-to-run variance with the mechanism idle, not a treatment effect.
3. **Stopping rule:** the baseline failed the full validator twice, which by
   the preregistered rule ("≥1 finished red, or ≥2 failing the validator")
   opens stage B. That second clause was meant as a proxy for finishing red;
   here every validator failure came with a green pinned check. Whether to run
   stage B as registered or stop with a documented deviation is left to the
   owner (decision recorded below).

**Stage B decision (owner, 2026-10-08):** run stage B as registered. Sizing
rule: 3 × US$5.61 × 1.25 = US$21.0 exceeds the remaining US$17.78, 2 ×
US$5.61 × 1.25 = US$14.0 fits, so 2 trials per task per arm (16 rollouts),
with stage A's US$5.609415 as the budget-used offset under the US$23.39 v3
cap. Same binary and harness revision (c9f14ae3) as stage A.

## Results — stage B (run 2026-10-08, same binary and revision as stage A)

Receipt-bound summary of `evals/runs/cg-v3/stageB/` (`compare.md` / `compare.json`
there). 16 rollouts, all valid, nominal cost US$10.14 (v3 total US$15.75;
check-gate total US$22.36 of US$30).

**Run note.** The first invocation stopped fail-closed after 14 rollouts: the
runner reserves the full per-rollout cap (US$9) before each rollout, and
US$14.60 used + US$9 exceeded the US$23.39 cap. The sizing rule above priced
stage A's actual cost, not that reservation. The two missing baseline rollouts
(calc and ranges, trial 1) were run by resuming the same command with the
per-rollout runaway cap lowered to US$8 — a guard far above any rollout's
actual cost (max US$1.14); the treatment, binary, model and every other
parameter were unchanged, and the cap is not part of the comparison identity.

| task | trial | observe: validator / credit | enforce: validator / credit | enforce continuations |
|---|---:|---|---|---:|
| d1_cg3_cron | 0 | fail / 0.982 | pass / 1.000 | 0 |
| d1_cg3_cron | 1 | pass / 1.000 | pass / 1.000 | 0 |
| d2_cg3_sheet | 0 | pass / 1.000 | fail / 0.986 | 0 |
| d2_cg3_sheet | 1 | pass / 1.000 | pass / 1.000 | 0 |
| d3_cg3_calc | 0 | pass / 1.000 | pass / 1.000 | 0 |
| d3_cg3_calc | 1 | fail / 0.980 | pass / 1.000 | 0 |
| d4_cg3_ranges | 0 | fail / 0.969 | fail / 0.969 | 0 |
| d4_cg3_ranges | 1 | pass / 1.000 | pass / 1.000 | 0 |

- **Primary (partial credit):** mean paired difference +0.003; 2 pairs up, 1
  down, 5 tied; exact sign test p = 1.0.
- **Secondary (full validator):** 62.5% → 75.0%, discordant pairs 1 regression
  / 2 improvements, exact McNemar p = 1.0.
- **Mechanism:** every rollout in both arms finished with the pinned check
  passing (0/8 baseline finished red); the candidate made no continuation. The
  arms differ only by the run-to-run variance of a model that ends every run on
  a green visible suite.
- **Cost:** +US$0.05 per pair (95% CI −0.09 to +0.19), +1.6 tool calls, wall
  time within noise.

### Conclusion (v1–v3)

H1 is not supported, and could not be: across all three cohorts the baseline
finished with the pinned check failing in **0 of 23** rollouts (v1 0/6, v2 0/5,
v3 0/12), and the enforced gate made **0** continuations in 23 rollouts. For
glm-5.3-flash, whenever a runnable visible suite exists, the model iterates on
it until it is green before stopping, so a gate that acts on "finished red" has
nothing to act on; its residual failures are behaviours the visible check does
not cover (hidden cases) or that make it pass dishonestly (v2: rewriting an
existing test). The gate costs nothing measurable when idle. Evidence for its
value would need a regime where runs end red — a weaker model, longer horizons,
or checks the model cannot run itself — and is not established here.
