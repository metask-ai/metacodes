# Learning turn paired evaluation (v1)

Status: preregistered 2026-10-17, before any rollout of the learning turn.
No paid run is authorized by this file (see Authorization). Mechanism under
test: the learning turn of [LEARNING_TURN_DESIGN.md](../../doc/LEARNING_TURN_DESIGN.md)
(in-run form, `--learning-turn`), from a binary that carries steps 1–8 of its
§11. This is the protocol of the design's §9, with the two configurations
registered separately.

## Claim

Across repeated attempts at the same task, a memory that carries the model's
own conditioned lessons raises the attempt-over-attempt improvement relative to
a memory that carries only verdicts, at a bounded cost per run.

The dev16 memory-accumulation arm measured a zero-recall null
([BENCHMARKS.md](../../doc/BENCHMARKS.md) §3); that is the baseline both
configurations must beat. A result that improves recall (lessons injected and
cited) without improving reward is a **negative** result for the design, not a
partial success.

## Why two configurations

In check-gate v1–v3 the pinned check was the task's visible suite and the grade
came from a validator with hidden cases; the pinned check finished red in 0 of
23 rollouts, and every validator failure came with a green pinned check
([check-gate-v3.md](check-gate-v3.md)). A learning turn fed by that check sees
only `passed` verdicts, so it can be measured there only on pass lessons. The
question "does a FAIL lesson help the next attempt" needs a check that fails,
which on this cohort means pinning the full validator — a contaminated
configuration by construction. Each configuration answers one question and is
reported on its own.

## Shared design

- **Arms.** Baseline `--learning-turn-observe`, treatment `--learning-turn`.
  One ReleaseSafe binary through two `#!/bin/sh` wrappers that differ only by
  that flag. Observe mode makes the same decision at the same boundary and
  records it (`metacodes-learning-turn-v1`, `enforced=false`), so the baseline
  measures how often the treatment would have acted.
- **Verdict source.** Both wrappers pass `--host-check <cmd>
  --check-gate-observe`: the check runs at every boundary after a
  delivery-capable action, never continues the run, and leaves the verdict the
  learning turn decides on. The check gate is in observe mode in both arms so
  the learning flag is the only difference.
- **Memory in both arms.** Both arms carry the same store across the chain
  (below), so the baseline is the dev16 memory-accumulation arm's treatment:
  an accumulating store with whatever the model wrote during its attempts.
  The treatment adds the lessons its learning turns write. The native E2E
  harness drives the REPL, where `host_check` and self-evolution do not run,
  so no `task_outcome` row is filed in either arm and the end-of-run form
  never runs (see the amendment below).
- **Chains.** A chain is K = 3 sequential attempts at one task in one arm, on
  one TinyKG store that starts empty at attempt 1 and persists across the
  chain, run by `scripts/eval/cli.py run-chained` with
  `METACODES_TASK_HINT=<task id>` on every attempt. Attempt 1 runs with no
  lesson in either arm; the treatment can act only from attempt 2. Every
  attempt level advances for all chains before the next, and the arm that
  goes first alternates by task and replicate. The per-arm hash-chained store
  ledger (`metacodes-chain-ledger-v1`) is part of the evidence.
- **Model and limits.** glm-5.3-flash through the Metask route, as in
  check-gate v1–v3. `METACODES_MAX_TURNS=60` in both wrappers.
- **Workspace.** Each attempt starts from the task's frozen snapshot; nothing
  but the store carries across attempts.

## Configuration D — development, validator pinned

Pinned command: the task's full validator (pristine visible plus hidden
tests). Deliberately contaminated, in the sense of RSIAgent's DRS practising
on the target itself: it measures whether a FAIL lesson helps the next attempt
at *this* task, and it is never a held-out claim.

- **Cohort.** check-gate v3's four specifications (`evals/suites/check-gate-v3.json`,
  snapshot commit 7a860ef558c45a9342e937c9ad7e37a8a4b9476e): the only tasks on
  record where the full validator failed for this model.
- **Primary.** Partial credit (fraction of validator tests passing in the final
  workspace) at attempt 2, paired by (task, replicate), over the pairs where
  attempt 1 ended with a `failed` host verdict in **both** arms. Attempt 1 is
  identical in distribution across arms (empty store), so the conditioning is
  pre-treatment. Report the mean paired difference, per-pair signs and an exact
  sign test over non-tied pairs.
- **Secondary.** The same comparison over every transition k → k+1 whose
  attempt k failed in both arms; full-validator pass at attempt K (exact
  McNemar).
- **Stage A.** One chain per task per arm, attempt 1 only (8 rollouts). The
  treatment's learning turn runs after each attempt 1 and is costed here.
- **Stopping rule.** If no attempt-1 rollout in either arm ends with a `failed`
  host verdict, stage B does not run and the configuration is reported as
  untested at this dose for this model.
- **Stage B.** Full chains (K = 3), replicates per task per arm = the largest
  of 3 or 2 for which replicates × K × stage A cost per rollout × 1.25 fits in
  the remaining budget; if not even 2 fit, stop and ask the owner. Stage A
  rollouts are reported separately and not pooled.

## Configuration H — held out, visible suite pinned

Pinned command: `sh run_tests` (the visible suite), as in check-gate v3. The
full validator runs offline after each attempt for grading only; its output
never enters the store or any prompt. This measures pass lessons: whether a
lesson that records `uncertain:` after a green check changes the full-validator
pass rate of a later attempt.

- **Cohort.** The same four check-gate v3 specifications.
- **Primary.** Full-validator pass at attempt 2, paired by (task, replicate),
  over the pairs where attempt 1 failed the full validator in both arms;
  exact McNemar.
- **Secondary.** The dev16-style sign test on partial credit at attempt 2 over
  the same pairs; the same comparisons at attempt K.
- **Stage A.** One chain per task per arm, attempt 1 only (8 rollouts).
- **Stopping rule.** If no attempt-1 rollout in either arm fails the full
  validator, stage B does not run and the configuration is reported as untested.
- **Stage B.** As in configuration D.

## Mechanism and guard metrics (both configurations)

- **Treatment-actuation witness.** One `learning_turn` record per rollout,
  validated by `scripts/eval/workbuddy/trace.py`: `enforced` matches the arm;
  in the treatment, `decision = distill` runs a pass. An effect at attempt k+1
  is attributable only where the treatment accepted ≥ 1 lesson at an earlier
  attempt of the chain and the next attempt's scoped-recall receipt shows the
  lessons note injected.
- **Contract bite.** `lessons_refused` per rollout, and in configuration D the
  count of refused envelopes that claimed `verdict=passed` after a failed
  verdict (a direct read of the header binding).
- **Cost.** Learning-pass turns (`distill_turns`, `reconcile_turns`), tokens
  and wall time per rollout, reported separately from the attempt.
- **Growth.** Stored lessons per task after each attempt (bounded by
  4 × attempts), superseded count.
- **Attempt phase unchanged.** The `check_gate`, `stall_gate` and
  `test_integrity` records of the attempt phase are compared between arms; a
  learning pass must not change them (§12: a pass is outside the attempt).
- **Unchecked boundaries.** Count of treatment rollouts where the in-run turn
  decided `none_unchecked` (the model changed nothing after the last check);
  in the REPL harness these learn nothing.

## Claim boundary

Internal single-factor evidence on four self-authored tasks with one model;
4 tasks × at most 3 replicates cannot establish significance for a small
effect. Configuration D is contaminated by design and supports no held-out
claim. Configuration H can show whether pass lessons move hidden-case
failures; a null there is the expected result if the lessons cannot see what
the visible check does not cover. Neither configuration says anything about
the end-of-run form, external benchmarks or other models.

## Launch prerequisites

1. **A chained runner. Met (2026-10-18).** `cli.py run-chained`
   (`scripts/eval/chained_runner.py`) runs the chains above;
   `scripts/eval/tests/test_chained_runner.py` proves the store carries
   across the attempts of a chain and never across chains, replicates or
   arms, and that a broken ledger, a changed archive or a missing import
   witness stops the run before another paid attempt.
2. **Offline grading for configuration H. Met.** The suite's success check
   already runs the full validator on each attempt's final workspace after
   the session; its output lands only in the rollout record, and the runner
   exports the store before that check runs.
3. **A pinned full-validator command for configuration D. Not met.** The
   check command is fixed per wrapper, so it needs a dispatcher that runs the
   validator of the task named by `METACODES_TASK_HINT` against the
   workspace.
4. **Owner authorization** with a dollar cap and the durable budget journal
   (AGENTS.md). Until then nothing here runs.

## Amendment (2026-10-18, before any rollout)

The shared design first said both arms would run with
`METACODES_SELF_EVOLUTION=1` and `METACODES_HOST_CHECK`, so every attempt
would file a `task_outcome` row ("verdict-only memory"). That cannot happen
in the native E2E harness these cohorts run in: it drives the REPL, and the
self-evolution host check and the end-of-run learning form exist only in
print mode. The baseline is therefore the accumulating store without
lessons, which is the dev16 memory arm this protocol already named as the
baseline to beat. No rollout had run when this was changed.

## Authorization

None yet. To be recorded here by the owner, with the cap, before stage A of
either configuration.
