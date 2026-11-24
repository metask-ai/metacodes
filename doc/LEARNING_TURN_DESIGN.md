# Learning turn: post-verdict distillation and reconciliation

Status: all eight steps of §11 implemented 2026-10-17. The in-run path
(steps 1–4) lives in `src/core/learning_turn.zig`, `src/kg/lesson.zig`,
`src/core/agent_loop.zig`, `src/tools/kg_tools.zig` and
`src/kg/scoped_recall.zig`; the end-of-run form in
`src/core/learning_end_of_run.zig` and `src/core/host_check.zig`; the flags
in `apps/cli/src/main.zig` (`resolveLearningTurn`), `apps/cli/src/repl/loop.zig` and
`apps/cli/src/repl/headless.zig`; the proofs in
`control-plane/lean/MetaCodesControl/LearningTurn.lean`; the protocol in
[learning-turn-v1.md](../evals/experiments/learning-turn-v1.md), not yet run.
Tests: `tests/component/learning_turn_test.zig` and
`tests/component/learning_end_of_run_test.zig`; record validation in
`scripts/eval/workbuddy/trace.py`. §12 lists where the implementation
departs from the design text below; where they disagree, §12 and the code
are current. The design is the first of three borrowings from RSIAgent
(AetherLabsAI/RSIAgent, arXiv 2609.15364).

## 1. Problem

The kernel knows when a run was judged, and it already carries that judgement
forward, but what it carries forward is the *verdict*, never the *lesson*.

Today the path from a verdict to the next attempt is:

1. In-run, `check_gate` runs the pinned command when the model stops after a
   delivery-capable action. A clean failure continues the same conversation
   with the failing names and a cognitive-mode directive, at most
   `max_continuations` times. The verdict is recorded once per run
   (`metacodes-check-gate-v1`) and then forgotten.
2. At the end of a headless run, `host_check.runAndIngest` runs the same kind
   of pinned command and files a `task_outcome` row in TinyKG: reward,
   counts, failing names, the agent's final note, the best new-file artifact,
   provenance `host_run` or `host_run_tainted`.
3. The next attempt at the same task gets that row injected deterministically
   (`scoped_recall.sameTaskOutcomeNote`): the last verdict, the best
   historical attempt, a cognitive-mode section keyed on the failure streak,
   and a plateau cooler.
4. `self_evolution.endOfRun` may spend one isolated provider request to
   author a provisional rule or a task-scoped obligation, in a closed IR.

What is missing is the step RSIAgent calls memory distillation: nobody asks
the context that did the work *why* it failed or passed, under which
conditions the lesson holds, and what in the existing memory it contradicts.
The consequences are measurable in this repository's own evidence:

- `experience_packet` admits only completed, verified tasks. Failed attempts
  leave no reusable trace beyond the outcome row's failing names
  (`metacodes-agent-loop-diagnosis` memory, 2026-10-10).
- The outcome-note machinery in `scoped_recall.zig` has grown nine framing
  layers (best-attempt anchor, verbatim directive, solved silence, replay
  self-falsification, plateau cooling, mode escalation) because the row it
  injects is all the next attempt has. Those layers are the host guessing
  what the model should have concluded.
- The dev16 memory-accumulation arm measured a zero-recall null
  ([BENCHMARKS.md](BENCHMARKS.md) §3): memory that accumulates nothing but
  verdicts has nothing to recall.

RSIAgent's failure analysis names the risk on the other side: a lesson
written without its conditions becomes a rule that outlives its evidence
("rule scope loss", "uncertainty not enforced"). The design below takes the
mechanic and keeps metacodes' governance around it.

## 2. Shape

One **learning turn** after a grounded verdict, in two passes, both run by
the same conversation that produced the candidate:

| Pass | Question put to the model | Output |
|---|---|---|
| **Distill** | Given the verdict and the evidence you saw, what should a fresh attempt at this task, or at this project, know? Under what conditions does that hold, and what remains uncertain? | 0..4 **lesson** nodes written with `KgRemember` (type `lesson`, §2.3), plus one typed learning record |
| **Reconcile** | Here is every stored lesson for this task and the project lessons the distill pass touched. Which of them does today's evidence contradict, narrow, or supersede? Supersede or narrow them; do not append a contradiction beside them. | supersessions of existing lesson nodes (write the corrected lesson, name the one it replaces), within the turn's 4 lessons; the record gains a `reconciled` count |

The host does three things and no more: it decides *whether* the turn runs
(a pure policy over the verdict and budgets), it supplies the verdict and the
stored lessons as evidence, and it records what the model wrote. It never
authors a lesson, never grades one, and never turns a lesson into authority.
That is the same division as RSIAgent's "the Actor owns memory; the harness
only moves and audits it", and the same division `self_evolution.zig` already
states for provisional rules ("author calls only after the Run, never touch
the actor Conversation").

### 2.1 Where it attaches

Two verdict sources exist; the turn attaches to both, with one policy.

**In-run (`check_gate`, REPL and headless).** The gate's stop boundary in
`agent_loop.zig` already appends host text and continues the conversation
when the verdict is a clean failure with budget left. The learning turn is
the *terminal* boundary: after `decide` returns any `finish*` decision for a
checked boundary, and before `finishRun`, the loop appends the distill
prompt as one user message and runs one more turn group. The conversation,
tools and permission context are the actor's own, so the model writes lessons
with `KgRemember` and long-form notes with `Write` into memdir, exactly as it
can today. The reconcile prompt follows as a second user message only when
the distill pass produced at least one accepted lesson.

**End-of-run (`host_check`, headless only).** `host_check.runAndIngest` runs
after `agent_loop.run` has returned, so the actor conversation is finished
but still in memory (`app.conversation` is persisted after this point). The
learning turn here is one bounded, no-tools provider request in the pattern
of `self_evolution.endOfRun`: a frozen role prompt, a packet built from the
verdict row plus the stored lessons, hard caps on tokens and cost, and the
response treated as evidence. The host then performs the lesson writes the
response asks for, through `KgClient.remember` with type `lesson`, never
through the file tools; the two forms produce byte-compatible nodes.

The in-run form is preferred wherever `check_gate` is armed, because the
model keeps its tools and its full context. The end-of-run form exists for
the evaluation harness, where `check_gate` is off by default and the verdict
arrives from `METACODES_HOST_CHECK`. When both are armed in one run, only the
in-run turn fires; `host_check` still files its outcome row.

### 2.2 What the turn is told

The distill prompt is one host message with a fixed marker
(`[learning turn]`) and four sections, all of them already computable today:

1. **Verdict**: the `check_gate.Outcome` (verdict, counts, failing names and
   reasons, output tail) or the `task_outcome` row, rendered by the same
   writers `renderContinuation` and `composeOutcomesJson` use. A `tainted`
   verdict is passed with its taint stated; an `unavailable` verdict does
   not start a learning turn at all (§3).
2. **Evidence boundary**: a sentence stating what the verdict establishes and
   what it does not ("the pinned check reports which named checks failed; it
   does not report why your approach failed, and a pass does not establish
   that the task statement was fully met"). This is RSIAgent's "the Verifier
   establishes what was or was not verified; it does not establish why".
3. **Existing lessons for this task**: the `lesson` nodes whose envelope
   names this task hint (recalled the way `sameTaskOutcomeRow` recalls
   outcome rows) and the latest `task_outcome` row, so the model reconciles
   against what is already stored instead of re-deriving it. In a REPL
   session with no task hint the section holds the project-wide lessons the
   ordinary recall would have surfaced for the run's first message.
4. **The contract for a lesson** (§2.3).

The turn never receives: the external grader's score or any
`external_oracle` row (§5), the user's chat history outside this run, or any
host guess about the cause.

### 2.3 The lesson contract

A lesson is a TinyKG node written with `KgRemember` (`type: lesson`, an
`observation` node with the custom schema type, the same admission path a
project's own types use). It is not a memdir file, for two reasons that the
existing channels decide:

- the evaluation harness carries the **store** across trials
  (`kg-store-continuity`), not the memdir directory, so a lesson that lived
  only in a file would not reach the next attempt there;
- the deterministic same-task injection already reads TinyKG by a lexical
  marker (`task-outcome-v1 task=<hint>`); a lesson node with the same shape
  of marker is found by the same `recallTyped` call, with no new retrieval
  path.

Long-form narrative still goes to memdir, per the routing the memory section
already states (short atomic facts → `KgRemember`, investigation write-ups →
a memory file). A lesson is the short atomic kind.

The node text is an envelope with a fixed first line and three labelled
lines, in this order:

```text
lesson-v1 verdict=<passed|failed> task=<hint or -> run=<run id>
holds_when: <the condition under which this lesson applies>
uncertain: <what the evidence did not settle>
lesson: <the lesson itself, one paragraph>
supersedes: <node id, optional>
```

The contract the prompt states, and `KgRemember` checks mechanically
before it writes anything (a refused envelope is a tool error naming what to
fix; nothing lands):

- **The header is the host's.** Kind `lesson` is accepted only inside a
  learning turn, and only when the first line equals the header the host
  bound to the verdict, task and run byte for byte. A FAIL verdict therefore
  never yields a lesson stored as a pass. The prose is not sniffed for
  success claims; the distill message forbids them.
- **A lesson carries its condition.** `holds_when:` and `uncertain:` are
  required and non-empty. This is the field RSIAgent's failure analysis says
  was missing when a rule outlived its evidence.
- **A lesson is bounded.** At most 4 accepted lessons per learning turn, at
  most 2 KiB each; a `supersedes:` line must name a lesson node for the same
  task that exists in the current store.
- **A lesson is not a rule.** Nothing in a lesson changes permissions, tool
  dispatch, the project rule gate or the provider-visible system prompt. Its
  only reader is the next attempt's recall injection.

The last point is the boundary that separates this design from
`self_evolution`'s provisional rules. Rules are closed-IR, kernel-enforced,
Lean-mirrored and retractable; lessons are prose, advisory and verified only
by the next attempt. Both exist because they fail differently: a wrong rule
blocks the model, a wrong lesson misleads it. Keeping them in separate
channels with separate lifetimes is what lets a bad lesson be superseded or
forgotten by the model that reads it (`supersedes:`, `/kg forget`) without
touching anything the kernel enforces.

## 3. Policy

`learning_turn.State` is a value type; `decide` is pure and mirrored in Lean
(§7).

```
none        if the run was not checked (no verdict, or verdict unavailable)
none        if decisions ≥ MAX_LEARNING_TURNS (= 1 per run)
none        if the verdict is `tainted`                         -- see below
distill     if verdict ∈ {passed, failed}
reconcile   only after a distill pass that produced ≥ 1 accepted lesson

observe mode makes the same decision, records it as `would_<decision>`,
and injects nothing.
```

- **One learning turn per run.** The check gate may continue the run up to
  `max_continuations` times; each continuation is the same attempt. The
  learning turn fires once, at the terminal boundary, with the final verdict.
- **A pass learns too.** RSIAgent defaults to learning on FAIL and makes PASS
  learning opt-in; this design learns on both, because the check-gate cohorts
  show the dominant failure as "quietly wrong": across v1–v3 the pinned check
  finished red in 0 of 23 rollouts while every full-validator failure came
  with a green pinned check
  ([check-gate-v3.md](../evals/experiments/check-gate-v3.md)). A pass lesson
  with `uncertain` filled in is the only place that doubt can be written
  down. A pass lesson is bounded to the same 4 lessons.
- **Tainted verdicts do not teach.** The model edited the check or weakened
  the tests; a lesson drawn from that verdict would launder the taint into
  memory. The record names the taint as the reason, so a cohort can count
  how often a lesson was refused on those grounds.
- **No turn on `unavailable`.** No verdict, no grounding, no lesson. This is
  the same rule as RSIAgent's "infrastructure failure is unscored" and
  BENCHMARKS.md's "invalid, not fail".
- **No turn when the run ended by abort, `stalled`, `budget` or
  `max_turns`.** Those stop reasons mean the host interrupted the attempt;
  the verdict, if any, is of an unfinished candidate.

### 3.1 Bounds

| bound | value | why |
|---|---|---|
| learning turns per run | 1, at agent depth 0 only | one verdict, one lesson set; subagents never learn on their own |
| passes per turn | 2 (distill, reconcile) | reconcile is conditional on distill writing |
| host messages appended | ≤ 2 | one per pass |
| model turns per pass | ≤ `LEARNING_PASS_MAX_TURNS` = 6 | a pass is a few reads and writes, not a new task |
| accepted lessons per turn | ≤ 4, ≤ 2 KiB each | bounded recall surface |
| end-of-run provider request | 1, under `self_evolution`'s caps | reuse `AUTHOR_MAX_*` |

The two host messages are **one-time protocol injections** in the sense of
`host_injection_meter.zig`'s exclusion ①: unconditional by construction, at
most one each, fired after the run's answer is final. They do not draw from
`MAX_HOST_INJECTIONS_PER_RUN`, so the comptime cap assertion in
`agent_loop.zig` is unchanged. Each carries its own marker so transcript
consumers can separate them from user text (`HOST_TEXT_MARKERS`).

### 3.2 Output semantics

The actor's answer is already final when the learning turn starts; the turn
must not change it. `output_semantics.Ledger` closes the final segment before
the distill prompt is appended, and every assistant text the learning passes
produce is closed as `commentary`. `RunResult.stop_reason` is the reason the
*attempt* stopped (`end_turn`), not the learning turn's; a learning pass that
hits its own turn cap sets `RunResult.learning.truncated` and nothing else.

## 4. How a lesson reaches the next attempt

No new injection point. `scoped_recall.sameTaskOutcomeNote` already renders
the deterministic same-task block; it gains one section, **"Lessons from
earlier attempts (written by the model, verified by nothing yet)"**, that
lists the accepted lesson nodes for this task, newest first, at most 3,
skipping any node a later lesson supersedes, each as its `holds_when:` line
plus the first 320 bytes of `lesson:`. The query is the lesson marker plus
the hint, the exact-needle filter and the newest-node rule are those of
`sameTaskOutcomeRow`. Project-wide lessons (`task=-`) ride the ordinary BM25
recall with no special treatment.

The framing matters more than the content: a lesson is presented as a prior
hypothesis to test against the workspace, not as a verdict. The wording
reuses the memory section's existing sentence ("reflect what was true when
written; verify before relying on it") rather than a new doctrine.

Two of the nine framing layers in `sameTaskOutcomeNote` become candidates for
removal once lessons exist, and should be removed only on evidence:

- the **verbatim-artifact directive** (v37/v44), which exists because the
  model re-derived a proven artifact from scratch. A lesson that says "the
  proven artifact is at X; patch it, do not rewrite" is the model's own
  version of that directive;
- the **cognitive-mode escalation** text, which guesses at the model's
  reading. A reconcile pass that must confront "this failure set has come
  back three times, and here is what you concluded last time" is the direct
  form of the same pressure.

Neither is removed in this design; the record (§6) is what decides.

## 5. Leak boundary

RSIAgent seals the official evaluator behind the learning loop: the grader
runs once, after the loop returns, and its output never enters memory. This
repository already files external grades into TinyKG between trials
(`METACODES_TASK_OUTCOMES`, provenance `external_oracle`) as a deliberate
two-pass protocol. The learning turn does not widen that:

- the turn consumes only `host_run` and `host_run_tainted` verdicts, which
  come from a command the model could run itself;
- `external_oracle` and `user` rows are excluded from the evidence packet by
  provenance rank, so a held-out grader's failing names cannot be rewritten
  into a lesson;
- the end-of-run form keeps the `self_evolution` generation/held-out window
  split: the learning packet is generation evidence and carries the same
  held-out commitment, so the no-leak proof covers it.

Whether a two-pass protocol *should* let the external grade feed the next
pass is an evaluation design question already answered there; it is not
reopened here.

## 6. Record

One terminal `learning_turn` observation record per armed run,
`metacodes-learning-turn-v1`, beside `check_gate` and `test_integrity`:

| field | meaning |
|---|---|
| `enforced` | treatment-actuation witness: a pass could run |
| `grounding` | `unchecked` / `passed` / `failed` / `tainted` / `unavailable` at the terminal boundary |
| `decision` | `distill`, or the `none_*` reason (`none_unfinished` when the run never reached its terminal boundary) |
| `passes` | 0, 1 (distill) or 2 (distill and reconcile) |
| `distill_turns`, `reconcile_turns` | model turns spent per pass |
| `lessons_accepted`, `lessons_refused` | counts; node ids and text stay out |
| `reconciled` | lessons accepted during the reconcile pass |
| `truncated` | a pass hit its turn cap |

`scripts/eval/workbuddy/trace.py` validates it like the sibling records. The
invariants it pins: a pass only after a `distill` decision in enforce mode,
and an enforced `distill` always runs one; `distill` only on a passed or
failed grounding, each `none_*` reason matching its grounding; no turns or
lessons without a pass; reconcile turns only with two passes, and two passes
only after a distill pass that accepted a lesson; every bound of §3.1.

## 7. Proofs (Lean mirror)

`LearningTurn.lean` transcribes `decide` over abstract verdicts and the two
budgets, in the style of `CheckGate.lean`:

- `turns_bounded`: over any trace of terminal boundaries, learning turns ≤ 1;
- `unavailable_never_learns`: no verdict, no decision;
- `reconcile_requires_lesson`: a reconcile pass is preceded by an accepted
  distill lesson in the same turn;
- `tainted_never_learns`: a tainted verdict decides `none` in both modes;
- `observe_never_injects`: observe mode produces a record and no message;
- `answer_is_final`: the attempt's final segment is closed before any
  learning message (stated as an ordering invariant on the trace).

Each theorem names the Zig test that mirrors it, as the sibling files do.

## 8. Opt-in and defaults

`agent_loop.Options.learning_turn: ?learning_turn.Mode = null`, the sibling
contract shape. Canonical `buildRunOptions` leaves it off, so macro, skill and
subagent runs never learn on their own.

| host | default | flags |
|---|---|---|
| interactive REPL | off | `--learning-turn` / `--learning-turn-observe` |
| headless | off | same flags; `METACODES_LEARNING_TURN=enforce|observe` for the eval adapter |

It requires a verdict source: without `--host-check` (or `METACODES_HOST_CHECK`
under self-evolution) the flag is a parse error, the same rule
`main.zig` applies to `--check-gate` without a command.

## 9. Evaluation

The claim this design makes is narrow and testable with the existing control
plane: *across repeated attempts at the same task, a lesson-bearing memory
raises the attempt-over-attempt improvement relative to verdict-only memory,
at a bounded cost per run.*

One fact about the existing cohorts shapes the protocol. In check-gate v1–v3
the pinned check was the task's visible suite and the grade came from a
validator with hidden cases; the pinned check finished red in 0 of 23
rollouts, and every validator failure came with a green pinned check. A
learning turn fed by that pinned check would see only `passed` verdicts and
could be measured only on pass lessons. The protocol therefore runs two
configurations, pre-registered separately:

- **Development, validator pinned.** The task's full validator is the host
  check. This is deliberately contaminated, in the same sense as RSIAgent's
  DRS practising on the target itself: it measures whether a FAIL lesson
  helps the next attempt at *this* task, and it is never a held-out claim.
  Arms: `learning=observe` (record only; the conversation sees exactly
  today's outcome note) against `learning=enforce`, both under
  `memory_accumulation` with the same continuity seed, same model, same
  pinned command. Primary: reward at attempt k+1 given a failing verdict at
  attempt k, paired. Cohort: check-gate v3's four hard specifications, which
  are the only tasks on record where the full validator failed for this
  model.
- **Held-out, visible suite pinned.** The check-gate v3 configuration
  unchanged. This measures pass lessons only: whether a lesson that records
  `uncertain` after a green check changes the full-validator pass rate on a
  later attempt. Primary: full-validator pass at attempt k+1, paired; the
  dev16-style sign test on partial credit as secondary.

Guard metrics for both: learning-turn cost per run (tokens, wall), lesson
count growth per task, the stall-gate and check-gate records unchanged in
the attempt phase, and `lessons_rejected` (a FAIL lesson that claimed
success) as a direct read of the contract's bite. Stopping rule as in
check-gate v1–v3: if no attempt in the cohort reaches the verdict the
configuration needs (a failing verdict for the first, a validator failure
for the second), its paired stage does not run.

The dev16 result (memory accumulation a zero-recall null) is the baseline
both must beat; a result that improves recall without improving reward is a
negative result for the design, not a partial success.

## 10. What is deliberately not in this design

- **No curriculum, no practice tasks.** RSIAgent's broad-then-deep
  exploration is the third borrowing and stands on its own; the learning
  turn is what makes practice worth anything, so it comes first.
- **No LLM verifier.** The verdict source stays the pinned command. An
  isolated verifier agent is the second borrowing; when it exists it plugs
  into the same `source` field.
- **No free-form memory authority.** Lessons never become rules, obligations
  or prompt sections. Promotion of a lesson into anything enforced goes
  through the existing candidate → Lean → replay pipeline or not at all.
- **No memory-revisit nudges.** RSIAgent prompts the actor to re-read memory
  at fold, recovery and stagnation boundaries. This repository's data says
  text nudges are ignored at long context (`STALL_GATE_DESIGN.md`); the
  learning turn puts the lesson into the next attempt's deterministic
  injection instead.
- **No change to `experience_packet`.** It remains a verified-task packet;
  lessons from failed tasks travel as `lesson` nodes through the outcome note.

## 11. Implementation sketch

| step | files | evidence that closes it |
|---|---|---|
| 1. **Done.** `learning_turn.zig`: `Mode`, `State`, pure `decide`, prompt renderers; `kg/lesson.zig`: envelope parser, binding, selection, note | `src/core/learning_turn.zig`, `src/kg/lesson.zig` | unit tests named after §7 theorems; an envelope test per contract violation |
| 2. **Done.** In-run attach after the check-gate terminal decision; output-ledger closure; record emission | `src/core/agent_loop.zig`, `src/tools/observation.zig` | component test with a mock provider: failed verdict → distill message → a `KgRemember` of type `lesson` → reconcile message; passed verdict → distill only; tainted → no message, record says so; observe → no message, record carries `would_distill` |
| 3. **Done** (without the memory-section change, §12). `lesson` envelope and acceptance on the `KgRemember` path | `src/tools/kg_tools.zig` | component test: an accepted envelope is stored with schema type `lesson` and recalled by its marker; a refused one is not stored |
| 4. **Done.** Same-task lesson section in the outcome note | `src/kg/scoped_recall.zig` | injection test: newest 3 unsuperseded lessons, 320-byte bodies, byte-identical note when no lesson exists |
| 5. **Done.** End-of-run form | `src/core/host_check.zig`, `src/core/self_evolution.zig` | headless test: `METACODES_LEARNING_TURN=enforce` with a pinned failing check → one provider request → ≥ 1 `remember` call; caps honoured |
| 6. **Done** (no `doctor` line, §12). Flags, parse errors, `doctor` line | `apps/cli/src/main.zig` | CLI tests like `--check-gate` without `--host-check` |
| 7. **Done.** `LearningTurn.lean`; trace validation; CHANGELOG | `control-plane/lean/...`, `scripts/eval/workbuddy/trace.py` | `zig build test` with the kernel; `trace.py` fixtures |
| 8. **Done** (not run). Pre-registered experiment file | `evals/experiments/learning-turn-v1.md` | the protocol of §9 |

Steps 1–4 are the in-run path and are independently useful; 5 exists for the
harness; 7–8 are the proof and the measurement. Nothing here changes the
cacheable first request: every learning message is appended after the
attempt's answer, and the system prompt is byte-for-byte what it was.

## 12. Implementation notes (2026-10-17)

Where the implemented steps 1–4 depart from the text above, and why:

- **A pass runs read tools and `KgRemember` only.** Every other tool call is
  refused with `LearningTurnToolUnavailable`, so the workspace the check
  judged is the workspace the run returns. Long-form memdir notes are
  therefore not written in a learning turn; the model can still write them
  during the attempt.
- **Lessons are refused, not stored-and-ignored.** `KgRemember` refuses kind
  `lesson` outside a learning turn and any header that is not the host's,
  so every stored `lesson` node is attested. The design's prose check for
  success claims is replaced by this header binding.
- **Reconcile needs something to reconcile against.** The reconcile pass
  runs only when the distill pass accepted a lesson *and* stored lessons for
  the task existed; with none stored it would be a request with no work.
- **The run token is the host's.** `Options.run_label` (the journal run id
  in headless runs) names the run in lesson headers; without a valid label
  the trace id does.
- **The lessons note is its own block.** It follows the outcome note as a
  separate `<system-reminder>` instead of a section inside it, so it reaches
  the next attempt whether or not an outcome row exists, and the outcome
  note's many return paths are untouched.
- **No memory-section change.** Naming kind `lesson` in the `# Memory`
  system-prompt section would change the provider-visible prefix of every
  session; the distill message carries the format instead.
- **A learning pass is outside the attempt.** Process sensors (delivery
  cadence, check gate, test integrity, stall gate) neither sense nor end it,
  its faults do not count toward the environment breaker, and queued input,
  backgrounding, job notifications and advisory nudges wait for the next
  run. The output channel is sealed when the pass starts, so even an abort
  inside it cannot make learning text the run's result.
- **`none_unfinished`.** A run that stops before its terminal boundary
  (abort, stall, budget, turn cap) records that decision rather than a
  grounding-derived one.
- **`none_unstorable`.** A passed or failed verdict with no ready TinyKG
  store runs no pass: every write would fail, so the pass would only spend
  model requests. The once-per-run counter of §3 is gone; the terminal
  boundary is reached at most once, so the policy is a function of the
  grounding and the store alone.
- **`RunResult.learning` on every exit.** The report rides the run-wide
  counters, so a pass that is aborted or cut still reports its decision and
  lessons.

### Steps 5–8 (2026-10-17)

- **The verdict source is the check gate, not `--host-check` alone.** The
  in-run turn grounds on the check gate's verdict at the terminal boundary,
  so `--learning-turn` with `--host-check` but no `--check-gate[-observe]`
  would record `none_unchecked` forever; it is refused. The in-run options
  are armed only where the check gate is (`learning_turn.inRunOptions`).
- **The end-of-run source needs its whole chain.** It counts only in print
  mode and only with `METACODES_SELF_EVOLUTION` on, a pinnable
  `METACODES_HOST_CHECK` and a task hint, because `host_check.runAndIngest`
  runs nothing without the hint (`host_check.endOfRunArmedFromEnv`).
  `METACODES_LEARNING_TURN` is likewise read in print mode only, so a REPL
  started from an evaluation shell is not refused for it.
- **End-of-run eligibility.** The form runs after an attempt that ended on its
  own (`end_turn`) and only when the in-run turn did not decide on a verdict:
  unarmed, or `none_unchecked` because the model changed nothing after the
  last check. A tainted, unavailable or unstorable in-run decision stands; a
  second check must not re-litigate it (`learning_end_of_run.modeFor`).
- **One request, one pass.** The end-of-run packet lists the stored lessons
  and asks for corrections as `supersedes:` lessons, so distill and reconcile
  share the single request the bounds allow; the report counts one pass and
  `reconciled = 0`.
- **Every claimed envelope is judged.** The response is cut at every line that
  starts with the lesson marker, whatever header it claims, so a lesson
  claiming another verdict is counted in `lessons_refused` instead of being
  ignored as prose.
- **Caps on both sides of the request.** Before sending: the provider's
  `max_tokens` must not exceed the author output cap, and the packet is
  bounded in bytes below the input cap. After: the reported usage and its
  cost at the author pricing must fit the caps, or nothing is stored. Like the
  self-evolution author, the request goes straight to the provider, outside
  the evaluation request gate.
- **Evidence classes are the check gate's.** `host_check` grades its run for
  the learning turn the way `check_gate.runCheck` does: exit 126/127 or an
  unparseable run is `unavailable`, a pass is exit 0 with no failing result,
  the git-status taint wins; a refused pin is `unavailable`. The verdict is
  quoted with the same renderer as the in-run turn.
- **The end-of-run report is a log line.** The journal is sealed before the
  host check runs, so the end-of-run form cannot append a
  `metacodes-learning-turn-v1` record; it logs the same fields at warn level
  (with the request's token usage). Its durable effect is the lesson nodes. A
  journal record for it would need the host check moved before the seal.
- **No `doctor` line.** None of the sibling gates (check gate, test
  integrity, stall gate) has one; the flags are per-run treatment switches,
  not installation state.
- **Lean.** `LearningTurn.lean` transcribes `decide` and `afterDistill` and
  proves the pure properties, then models the loop as a trace of events
  (terminal boundary, pass turn, accepted lesson, pass end) and proves over
  any trace: at most two passes and two host messages (`turns_bounded`), the
  per-pass turn cap, the lesson cap, reconcile only after an accepted lesson,
  no message in observe mode, and the final segment closed before any
  learning message. The bounded theorems depend on `propext` and
  `Quot.sound` (from `omega`), as `ProgressUpdates.lean`'s do.
