# Host check gate single-factor paired evaluation (v2, multi-file tasks)

Status: preregistered 2026-10-08, before any paid rollout of this suite.
Mechanism under test: unchanged from [check-gate-v1.md](check-gate-v1.md)
(`--check-gate` vs `--check-gate-observe`, `--host-check 'sh run_tests'`,
`--check-gate-max 3`).

## Why a v2

v1's stage A found no hazard: on six single-module specification tasks
glm-5.3-flash finished with the pinned check passing 6/6 and passed every
hidden case 6/6, often verifying with its own `python3 -c` assertions instead
of the repository's tests. Such self-made checks cover the change the model
just made, not the modules it did not look at. v2 therefore uses feature
requests over small multi-module packages where the natural implementation
breaks an existing test elsewhere:

| task | issue | regression trap |
|---|---|---|
| c1_cg2_receipts | discount codes, accounting-style discount line | changing the shared `money.format_cents` breaks refunds, CSV export and money tests |
| c2_cg2_todo | `todo list` by urgency, export stays in id order | changing the shared `ordering.sort_tasks` breaks store and export tests |
| c3_cg2_textkit | contractions/compounds as single words, search unchanged | changing the shared tokenizer breaks tokenizer and search tests |
| c4_cg2_events | IANA time zones, DST-correct UTC occurrences | requiring `tz` on load breaks the legacy file; changing the UTC ICS form breaks its test |
| c5_cg2_library | premium tier: loan period and fees | widening `due_date` / `late_fee` / `Member` without defaults breaks their callers' tests |

Each workspace (commit 2958e6efaaa301b4e6032350fad311fd29f48cf0) has
ISSUE.md, the package, its existing unit tests plus one acceptance test for
the issue, and `sh run_tests`. The scenario prompt is "Implement the change
described in `ISSUE.md`." The validator runs the pristine visible tests plus
hidden tests derived from ISSUE.md over a copy of the workspace with its own
tests replaced. Verified outside the tree before any rollout: the base fails
only the acceptance test, a reference implementation passes everything, and a
naive implementation passes the acceptance test while breaking regression
tests in other modules.

## Hypotheses

H1 (primary): enforcing the gate raises the rate of runs whose final
workspace passes the full validator, compared with observe mode.

H2 (mechanism): the gate lowers the rate of runs that end with the pinned
check still failing (`check_gate.final_verdict = failed`).

H0 for cost: report the paired difference in cost, turns and wall time.

## Design

- Single factor, paired by task and trial, order-balanced (`cli.py
  run-paired`); one ReleaseSafe binary through two `#!/bin/sh` wrappers that
  differ only by `--check-gate` / `--check-gate-observe`;
  `METACODES_MAX_TURNS=40` in both.
- Model: glm-5.3-flash through the Metask route, as in v1.
- Stage A: 1 trial per task per arm (10 rollouts). Proceed to stage B only if
  the baseline shows the hazard: at least one baseline rollout with
  `final_verdict = failed`, or at least two failing the validator. Otherwise
  stop and report H1 as untested.
- Stage B: trials per task per arm = 3 if 3 × stage A's cost × 1.25 fits in
  the remaining budget, else 2 if that fits, else stop. Stage A rollouts are
  reported separately and not pooled.

## Analysis

As in v1: paired validator comparison with `cli.py compare` (Wilson, exact
McNemar) on stage B; mechanism from the `check_gate` record per rollout
(attributable only where the candidate shows `continuations >= 1`); cost,
turns and wall time alongside. Additionally, per rollout: which visible test
files failed at the end (from the record's final verdict and the workspace),
to separate regression repairs from acceptance repairs.

## Claim boundary

Internal single-factor evidence on a self-authored cohort with one model.
5 tasks × at most 3 trials cannot establish significance for a small effect.
It says whether the hazard exists on multi-file work for this model, whether
the gate fires on it and whether firing moves the validator rate; nothing
about external benchmarks or workspaces without a test runner.

## Authorization

The owner asked for this v2 on 2026-10-08 after v1's stage A, within the
same day's authorization: cumulative cap US$30 nominal at guardrail rates
across v1 and v2, of which v1 spent US$3.01, leaving US$26.99 for v2 (stage
B passes stage A's spend as the budget-used offset). Per-rollout runaway cap
2,500,000 metered tokens / US$9.
