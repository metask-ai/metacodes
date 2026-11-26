# Learned-artifact gate: the evidence for activation and retirement

Status: design only, 2026-10-23. Nothing here is implemented, and no rollout
has been run or authorized. The external prior is EvoOntology
(ruc-datalab/EvoOntology, arXiv 2609.15779). Its ablation numbers come from
the paper and its weaknesses from a reading of its repository, both as
summarised when this work was commissioned; neither was re-read for this
design. Every statement about metacodes names a module or document on `main`
at c3e4dd38.

## 1. Problem

metacodes gates what a learned artifact may *do*. A provisional rule must
pass the closed spec IR (`project_rule_spec.validate`), a promoted rule must
pass the Lean lifecycle checker, the rule author sees only a generation window
while held-out results stay sealed (`ontology_rule_projection`), and a block
storm retracts every provisional rule. Nothing gates whether a learned
artifact *helps*. No mechanism compares the next attempt with the artifact
against the next attempt without it:

- **Lessons** reach the next attempt introduced as "written by the model
  after a host verdict on an earlier attempt; verified by nothing since"
  (`lesson.renderNote`; [LEARNING_TURN_DESIGN.md](LEARNING_TURN_DESIGN.md)
  §4). That is accurate: nothing verifies them.
- **Provisional rules and obligations** take effect at the next run's start.
  `self_evolution.loadProvisionalGate` merges them into the project rule gate
  and `obligation_gate.load` arms their nudges. Neither passes through the
  Lean promotion pipeline. The module header states this as a design choice.
- **Rule promotion and demotion exist but nothing in the product calls them.**
  `project_rule_bundle.promote` is called only by
  `scripts/project_harness_lifecycle_driver.zig` and component tests. The
  RuleImpact governance kernel (`invokeImpact`, `invokeImpactAggregate`) is
  called only by `scripts/rule_impact_driver.zig` and tests. A `demote` or
  `quarantine` verdict has nowhere to land: `rule_lifecycle` allows only
  `promoted → superseded`, a supersession needs a promoted replacement, and
  `project_rule_bundle` has no operation that removes a rule.
- **The RuleImpact promotion policy is absolute, not comparative.**
  `RuleImpactAggregateGovernance.lean` sums its members and sets
  `taskSuccess := windows.all`. Promotion therefore needs every member run to
  succeed, plus a minimum exposure count. Nothing asks what the same runs
  score without the rule. A useful rule exposed mostly on hard tasks is
  almost never promoted, and a useless rule exposed on easy tasks almost
  always is.
- **Retirement acts on one observation.** Obligation Rule B
  (`obligation_gate.needleRetired`) retires a needle after one round in which
  it was met with no reward gain afterwards. The block-storm breaker
  (`RETRACT_BLOCK_STORM_THRESHOLD = 8`) acts on one run.
- **The measurement that would decide any of this has not been made.**
  [learning-turn-v1](../evals/experiments/learning-turn-v1.md) is
  pre-registered and not run. The dev16 memory-accumulation arm measured a
  zero-recall null, and cross-roll baseline noise there (about ±0.13 mean
  reward) was as large as the treatment effects
  ([BENCHMARKS.md](BENCHMARKS.md) §3).

This design answers two questions for every kind of learned artifact: what
evidence moves it from candidate to active, and what evidence retires it.

### 1.1 The external prior

EvoOntology stores a data agent's semantic layer as versioned `ontology_vN`
directories. Each round runs diagnose → attribute → typed patch, and a
Candidate replaces its Parent only if it wins a paired comparison on a frozen
validation set. The paper's ablations on DDR-Bench, averaged over four
backbones:

| removed or changed step | score change (points) |
|---|---|
| the gate | −11.2 |
| attribution | −6.3 |
| diagnosis | −4.8 |
| typed patch replaced by free rewrite | −1.7 |
| an evolved store moved to another backbone | −6.6 to −10.9 |

By the layer that was edited, the Tool layer (manifest and exposure) accounts
for 57% of the gain, Content for 34% and Schema for 9%.

Three conclusions shape this design:

1. **The gate is the largest single contributor.** metacodes already has
   producers (the learning turn, the rule author, the obligation author) and
   no gate. The gate comes before any further learning mechanism.
2. **Exposure carries most of the gain.** The closest metacodes analogue to
   EvoOntology's Tool layer is the shape of the scoped-recall injection: which
   framing layers render, how much is truncated, how many items are shown.
   That is the first use case (§3.3, §10).
3. **Learned stores do not transfer across models for free.** Activation is
   keyed by model (§7).

Three weaknesses in its code are not copied:

- `EvaluationGate.decide_gt` accepts on a strict mean `>`. It has no margin,
  although the paper states one, and no significance test. Here, a decision
  is an exact test at a pre-registered level (§5).
- In plugin mode the agent supplies its own scores through
  `record_evolution_evaluation`, and only their shape is checked. Here, an
  outcome comes only from a host receipt (§6).
- A run must keep proposing candidates until one is accepted: 8 rounds, with
  at least 2 rejects before it may stop as incomplete. Every round reuses the
  same validation reserve, so the loop selects on noise. Here, a pool has a
  budget of looks, stopping without an Accept is a complete outcome, and an
  Accept retires the pool (§4.4, §5.5).

## 2. Terms

- **Artifact kind.** One of the four classes of §3.2.
- **Version.** An immutable, content-addressed record of everything that
  determines an artifact's behaviour (§4.7).
- **Parent, Candidate.** The active version for a (kind, model stratum), and
  a proposed replacement.
- **Model stratum.** The model identity under which a version was written and
  gated (§7).
- **Decision point.** A frozen state from which one attempt starts: the task,
  the workspace snapshot, the TinyKG store snapshot (by sha256) and the
  attempt index.
- **Exposure.** A decision point at which Parent and Candidate would put
  different bytes in front of the model. It is computed offline (§5.1).
- **Pair.** One Parent attempt and one Candidate attempt from the same
  decision point.
- **Unit.** A cluster of near-duplicate tasks. Units are the unit of
  independence (§4.2).
- **Pool.** A set of units sealed for validation, with a look budget.
- **Look.** One evaluation of one Candidate on a pool.

## 3. What the gate applies to

### 3.1 Gate the producer, not the per-task item

A lesson or an obligation binds one task. One task gives a handful of
attempts. An exact paired test at the levels of §5 needs at least 6
discordant units, all in the Candidate's favour, before it can accept
anything. No single per-task item can ever be validated on its own.

The gate unit is therefore anything whose effect spans many units: a
renderer, a policy that decides what gets written and what gets injected, or
a rule that applies across a project's tasks. A per-task item is active only
when the producer version that wrote it is active for the runtime's model
stratum. Within that, its own hygiene rules apply (supersession, Rule A/B,
`/kg forget`). These are cheap and need no statistics, because the item has
no proven status to lose (§8.1).

### 3.2 Objects

| kind | a version contains | gate unit | who writes a Candidate | exposure at a decision point | test (§5) | active scope | per-item hygiene |
|---|---|---|---|---|---|---|---|
| `injection_shape` | the scoped-recall renderer configuration: the outcome note's framing layers (best-attempt anchor, verbatim directive, solved silence, replay self-falsification, plateau cooling, cognitive-mode escalation), byte caps (`MAX_HIT_TEXT_BYTES` 320, `SHOWN_LESSON_BYTES` 320), counts (`TOP_K` 3, lessons `MAX_SHOWN` 3), the relevance floor | the version | a human or an author, from the design pool | the rendered injection block differs | additive: superiority; subtractive: non-inferiority | per model stratum, installation-wide | none |
| `lesson_policy` | the learning-turn distill/reconcile prompts, the envelope contract, the lesson selection and rendering rules | the version | as above | a lessons note would be injected at attempt k+1 | superiority | per model stratum | supersession, `/kg forget` |
| `obligation_policy` | the obligation author's prompt and needle rules, the nudge text and budget, the derived-obligation classifiers in `obligation_gate` | the version | as above | an obligation loads for the task | superiority | per model stratum | Rule A, Rule B, retraction |
| `provisional_rule` | one closed-IR rule (`spec_mod.Wire`) with its candidate receipt | the rule | the rule author (`rule_author`) | the rule makes a pre-dispatch decision (RuleImpact `exposures`) | superiority, and RuleImpact's safety policy | per project and model stratum (the project bundle) | block-storm breaker, quarantine |

A Candidate is **subtractive** if everything it renders is something the
Parent also renders in some state, and it never renders more. Dropping a
framing layer, lowering a byte cap or a count, and falling back from an
escalated variant to the base variant the Parent already shows elsewhere
all qualify. Every other change is **additive**, including one that mixes
removal with new text.
An additive Candidate must show benefit. A subtractive Candidate must show
that it costs no more than a pre-registered margin (§5.3).

### 3.3 Order, and why the injection shape comes first

The kinds are built in the order of the table. Cost and blast radius rise
down the table, and so does the authority the artifact holds over the model.
A wrong injection shape misleads the model. A wrong rule blocks it.

The first use case is the pending decision in
[LEARNING_TURN_DESIGN.md](LEARNING_TURN_DESIGN.md) §4. Two of the outcome
note's framing layers "should be removed only on evidence":

- the verbatim-artifact directive;
- the cognitive-mode escalation.

The reasons to start there:

1. **The decision is already owed.** §4 promised it and named no procedure.
   The gate supplies one.
2. **No authoring cost.** Both Candidates are host renderers fixed in
   advance. Diagnosis and design spend no provider request.
3. **Exposure is computable for free.** The note is a pure function of the
   store, the outcomes file and the renderer version. A census renders Parent
   and Candidate from each frozen store and marks the decision points where
   the bytes differ. Only those are run. Everywhere else the two arms would
   see identical prompts and would add variance, not information.
4. **Nothing the kernel enforces is touched.** No permission, no rule gate,
   no Lean admission. Rollback is a pointer swap.
5. **It is the analogue of EvoOntology's strongest layer.** In EvoOntology,
   how memory is exposed carried 57% of the gain.
6. **The layers are model-specific by origin.** Both were added after
   single-task forensics on one model (the `v37`/`v44` comments in
   `scoped_recall.zig` and `obligation_gate.zig`). Whether they help another
   model is exactly what per-stratum gating asks.

"Cheapest" means cheapest per informative pair, with the smallest blast
radius. It does not mean cheap. How many pairs a decision needs depends on
the effect size and on how many independent units exist, whatever the kind
(§5.4, §9).

## 4. Protocol

### 4.1 Checkpoint and frozen batch

A **checkpoint** is the gate receipt of the last decision for a (kind,
stratum), or that pair's genesis (the shipped default). The **batch** is
every decision point recorded in evaluation evidence since the checkpoint.

When a gate run starts, the batch is frozen into a manifest. The manifest
lists, per decision point: unit id, task fingerprint, store snapshot sha256
(the chain ledger's `store_export_sha256`), journal interval sha256, attempt
index and first-seen time. The manifest's sha256 is the run's input.
Decision points recorded after the freeze belong to the next batch.

### 4.2 Units: merge near-duplicates first, then split by time

Units are formed over the whole batch before any split. A split taken first
lets near-copies of one task land on both sides, and validation then
measures recall of the design side. Two decision points join one unit when
any of the following holds:

- they have the same task identity (`self_evolution.taskIdentity` of the
  task hint), so every attempt and chain of a task is one unit;
- they have the same suite task fingerprint;
- the suite declares them one family (variants of one specification);
- their normalised task statements (lowercased, whitespace collapsed) have a
  word 5-gram Jaccard similarity ≥ 0.8. The threshold is written into the
  manifest, and the merge is union-find over the batch.

Units are then ordered by their earliest decision point. The earliest
fraction `f_design` (pre-registered, default 0.5) forms the **design pool**.
The rest form the **validation pool**. Time order matches deployment: a
Candidate designed from earlier work is judged on later work.

When the Candidate's content hash was committed before the first decision
point in the batch, it was designed from nothing in the batch. `f_design` may
then be 0, and the whole batch validates. The first use case is prospective
in this sense (§10).

The gate never draws from a cohort reserved for another purpose. On
WorkBuddy that means dev only: the promotion-A, promotion-B and sealed
cohorts belong to the external ladder ([BENCHMARKS.md](BENCHMARKS.md) §4).

### 4.3 Sealing the validation pool

Before any design packet is built, the validation pool's membership is
committed in the existing held-out shape:
`ontology_rule_projection.heldOutCommitmentSha256`, schema
`metacodes-held-out-window-commitment-v1`. Every design-side input is checked
against that commitment, and a packet that names a sealed member is refused.
Design-side inputs are an author packet, a learning-turn evidence packet, or
a diagnosis export for a human. The refusal is the no-leak check that the
self-evolution author packet already carries for its generation and held-out
windows.

The past outcomes recorded at validation decision points are sealed too. They
reveal which states are hard, which is design information.

### 4.4 Looks: what crosses from validation to design

Exactly one bit crosses per look: accept or not. Counts, p-values and
per-unit results stay in the sealed receipt (§6.2) until the pool retires.

- A pool has a **look budget** `L_max`, pre-registered with the pool
  (default 3). Every Candidate evaluated spends one look, whatever the
  result.
- **An Accept retires the pool.** The pool selected the new Parent, so the
  new Parent's score on it is inflated by selection. Judging the next
  Candidate against that Parent on the same pool would build in a bias
  against every challenger.
- **A pool with no looks left retires into design.** Its outcomes become
  diagnosable, and the next batch supplies a fresh pool.
- **Nothing obliges a run to produce an Accept.** "No Candidate accepted" is
  a complete, recorded result. Candidate design is a separate, budgeted
  activity, never a loop that runs until the gate opens.

### 4.5 Arms: same model, same budget, same decoding

Both arms run one binary through wrappers that differ only in the artifact
version selector. The selector is an environment variable on the runner's
allowlist (`RUNTIME_ENV_ALLOWLIST` in `paired_runner.py`) and is recorded in
the harness config id. Everything else is identical and checked:

- **Model.** The same canonical model and the same offer. An
  `ActualRouteEvent` that names a different offer (an `AutoRoute` fallback)
  voids the pair.
- **Decoding.** Every control the `RuntimeSelection` carries is
  byte-identical: max tokens, effort or thinking budget, and any sampling
  parameter.
- **Budget.** The per-rollout caps and `METACODES_MAX_TURNS` are identical.
  The turn cap is a scored stop, as in every paired protocol so far.
  Exhausting the runtime budget is an infrastructure fault and voids the
  pair. Caps sit far above actual cost, as in check-gate v3.
- **Fingerprints.** `e2e_adapter.comparison_fingerprints` with factor
  `harness` already rejects a pair whose task, grader, model or environment
  fingerprint differs.

The version id never enters a prompt. Only the rendered bytes differ.

### 4.6 Spine-and-fork pairing

For `injection_shape`, the pair is exact at the decision point:

- The **spine** is a chain under the Parent version. After every attempt the
  chain ledger (`metacodes-chain-ledger-v1`) archives the store.
- At each boundary, the census renders both versions from that store.
- At an exposed boundary, a **fork** imports the same tar and runs the next
  attempt under the Candidate. The ledger row records `fork_of` and the same
  `store_import_sha256`. The fork's store is discarded.
- The spine's own next attempt is the Parent arm of the pair.
- The fork and the spine attempt run back to back, and which goes first
  alternates by unit.

The two attempts share their prefix byte for byte and differ only in the
version. Each pair costs one extra rollout (§9).

For `lesson_policy` and `obligation_policy`, the treatment acts through what
an attempt writes, so a pair is two chains (one per arm) that start from a
common store at attempt 1. That is the learning-turn-v1 design.

### 4.7 Versions and activation

A version record (`metacodes-learned-artifact-version-v1`) holds:

- `kind`;
- `parent_version_sha256`;
- the kind-specific content as canonical JSON;
- `producer_version_sha256` (for model-written content);
- `model_stratum`.

Its id is the sha256 of the canonical body. It is persisted inert as
`learned-artifact-version-<sha>.json`, in the same way
`project-rule-bundle-<sha>.json` is.

The **active pointer** for a (kind, stratum) names:

- `version_sha256`;
- `previous_version_sha256`;
- `revision`;
- the `gate_receipt_id` that authorises it.

It is published only by CAS under a lease. The sequence is the one
`project_rule_bundle.promote` follows for `active.json`: lease, re-attest,
compare-and-swap. A missing pointer means the shipped default, which is
compiled into the binary and is today's constants. Rollback is a CAS back to
`previous_version_sha256`, and it needs its own receipt.

Pointers and versions live under the installation's state root, never under a
global path, so several installs on one machine stay independent. Rule
bundles stay where they are, in the project's rules directory.

## 5. Statistics and stopping rules

### 5.1 Unit of analysis

- **Pairs come only from exposed decision points.** The census renders
  Parent and Candidate offline from the frozen store. A decision point whose
  bytes are identical under both is not run.
- **The primary outcome is binary.** It is full pass of the attempt that
  started at the decision point, as graded by the host (§6.1). Partial
  credit is secondary.
- **Pairs must be independent.** The primary test takes **at most one pair
  per unit**: the first exposed decision point in spine order. This is fixed
  before any rollout. Further pairs from the same unit are secondary. They
  are reported with unit-cluster bootstrap intervals and never decide.

One consequence matters more than any rollout count: **units bound the
evidence, not rollouts.** At `α_j = 0.05/3` an Accept needs at least 6
improving units and no regressions. Every native suite under
`evals/suites/` has between 1 and 6 tasks. Check-gate v3, the cohort that
learning-turn-v1 uses, has 4. With 4 units, no unit-level test can reach a
p-value below 2⁻⁴ = 0.0625, however many rollouts are run. Learning-turn-v1
can still give the directional evidence its claim boundary describes, but it
cannot make a gate decision. The only cohort in the tree with enough units
is WorkBuddy dev (52 tasks).

### 5.2 Additive Candidates: exact one-sided McNemar

Let `c` count units where the Candidate passed and the Parent failed, and
`b` the reverse. Under H0 (no difference), `c ~ Bin(b + c, ½)`. The
one-sided p-value is `P(X ≥ c)`. When `c > b` it equals half of the
two-sided `statistics.exact_mcnemar(b, c)`, wherever that value is below its
cap of 1. When `c ≤ b` acceptance is impossible. The Candidate is accepted
when `p ≤ α_j`.

The smallest accepting `c` for `n_d = b + c` discordant units, at
`α_j = 0.05/3`:

| n_d | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
|---|---|---|---|---|---|---|---|---|---|---|
| min c | 6 | 7 | 8 | 9 | 9 | 10 | 11 | 11 | 12 | 13 |

Cost is a guard, not a mean comparison. The upper end of the paired cost
interval (`statistics.mean_confidence_interval_95` over per-pair US$ deltas)
must not exceed a pre-registered increase. The plugin kernel v1 evaluation
set that increase at US$0.02 per rollout ([PLUGIN_EVALUATION.md](PLUGIN_EVALUATION.md)).

### 5.3 Subtractive Candidates: non-inferiority with a margin

H0 says the Candidate is worse by at least the margin:
`P_parent − P_candidate ≥ δ`. Removal is accepted when the Tango score
statistic for the paired difference, evaluated at `δ`, falls below
`−z(1 − α_j)`. Equivalently, the one-sided upper confidence bound of
`P_parent − P_candidate` is below `δ`. At `δ = 0` the statistic is
McNemar's. On the grid of §5.4, its rejection rate when the true difference
sits exactly at the margin ranges from 0.010 to 0.017 against
`α_j = 0.0167`. For example, it is 0.0144 at N = 52, δ = 0.20,
discordance 0.3.

Two further outcomes are read from the same pairs:

- **keep-proven.** If the one-sided exact McNemar shows the Parent better at
  `α_j`, the layer is recorded as proven for the stratum: it now has evidence
  of its own.
- **undecided.** Neither test fires.

The margin is pre-registered, together with the census's **exposure rate**
`e`. Unexposed decision points cannot be affected, so the population-level
harm that an accepted removal allows is at most `δ·e`. On current cohorts a
margin much below the cross-roll noise (about 0.13) is not affordable (§5.4).

### 5.4 Sample sizes

These are units for power 0.8. They were computed by exact enumeration of the
paired trinomial at the stated rates; step 1 of §11 commits the calculation
with its tests. "disc" is the probability that a pair is discordant.

| test | α_j | assumed rates | units |
|---|---|---|---|
| superiority | 0.05 (`L_max` 1) | Δ +0.20, disc 0.30 | 52 |
| superiority | 0.05 | Δ +0.15, disc 0.25 | 76 |
| superiority | 0.05/3 (`L_max` 3) | Δ +0.20, disc 0.30 | 68 |
| superiority | 0.05/3 | Δ +0.20, disc 0.40 | 96 |
| superiority | 0.05/3 | Δ +0.15, disc 0.25 | 104 |
| superiority | 0.05/3 | Δ +0.15, disc 0.35 | 144 |
| non-inferiority | 0.05 | δ 0.15, disc 0.2 / 0.3 / 0.4 | 60 / 90 / 110 |
| non-inferiority | 0.05/3 | δ 0.15, disc 0.2 / 0.3 / 0.4 | 90 / 130 / 160 |
| non-inferiority | 0.05/3 | δ 0.10, disc 0.2 / 0.3 / 0.4 | 190 / 270 / 360 |

Power of non-inferiority at δ = 0.20 and `α_j = 0.05/3`, by unit count, when
the true difference is 0:

| units | disc 0.2 | disc 0.3 | disc 0.4 |
|---|---|---|---|
| 30 | 0.54 | 0.43 | 0.33 |
| 40 | 0.66 | 0.53 | 0.45 |
| 52 | 0.80 | 0.65 | 0.54 |

Discordance between two arms of the same model has a floor even with no
treatment effect: a task the model passes with probability p is discordant
with probability 2p(1 − p). The decision points that matter here are
repeatedly failed tasks, where p sits mid-range, so planning should assume
disc 0.3–0.4 until a census or pilot says otherwise.

### 5.5 Reusing a pool

A reject teaches the designer something about the pool: "this direction did
not work here". A designer who keeps proposing until something is accepted
is searching the pool, and any fixed per-look level then fails. The control
used here:

- **Only the bit crosses** (§4.4).
- **The first Accept stops the pool.**

Together these make the reachable Candidates a single chain: the j-th
Candidate is fixed by j − 1 rejects plus design-side information that is
independent of the pool. A union bound over the chain then gives:

```
P(some null Candidate is accepted during the pool's life) ≤ Σ_j α_j ≤ α
α_j = α / L_max,  α = 0.05 one-sided by default
```

Several Candidates fixed together before the first look (as in §10) are run
in one round, and each spends one look.

The bound fails if anything more than the bit crosses. Counts or per-unit
results make the reachable Candidates a tree. The receipt is therefore
sealed, and a pool whose results leak is retired at once. The same
reasoning is why the subtractive outcomes keep-proven and undecided are not
released separately: the designer sees "not accepted".

### 5.6 Stopping rules

- **N is fixed per look before any Candidate rollout is graded.** It is
  either a number taken from §5.4, or a rule that depends only on
  pre-treatment facts, such as "every exposed unit" in §10. Exposure is
  decided by the Parent prefix, so such a rule never sees a Candidate
  outcome. There is no optional continuation.
- **Futility curtailment is allowed.** A look stops once the Candidate could
  not reach acceptance even if every remaining pair went its way. This can
  only reduce false accepts.
- **Too few exposed units means no look.** If fewer units are exposed than
  the pre-registered minimum, the outcome is `unexposed`. No look is spent
  and no bit is released. The minimum is never below §5.2's floor of 6 at
  `α_j = 0.05/3`.
- **Invalid pairs void a look.** A pair is void when either rollout is
  invalid: an infrastructure fault, budget exhaustion, an offer fallback, or
  an actuation-witness mismatch (§6.3). If more than 10% of the pre-registered
  pairs are void, the look is void. The outcome is `void`, no bit is released
  and no look is spent. The spend is reported.
- **Some rules never decide.** A strict mean comparison, `analysis.gate`'s
  `trustworthy_success_regression <= 0` check, and picking the best of K
  Candidates on the pool are all excluded as decision rules.

### 5.7 Decision table

| outcome | condition | active pointer | pool | bit released |
|---|---|---|---|---|
| `accept` (additive) | one-sided exact p ≤ α_j, cost guard holds | CAS to Candidate | retired | accept |
| `remove` (subtractive) | Tango upper bound < δ at α_j, cost guard holds | CAS to Candidate | retired | accept |
| `reject` (additive) | otherwise | unchanged | one look spent | not accepted |
| `keep-proven` (subtractive) | Parent better, one-sided exact p ≤ α_j | unchanged; the Parent's layer is marked proven | one look spent | not accepted |
| `undecided` (subtractive) | neither | unchanged | one look spent | not accepted |
| `unexposed` | exposed units below the pre-registered minimum | unchanged | no look | none |
| `void` | > 10% of pairs void | unchanged | no look | none |

## 6. Evidence: host receipts only

### 6.1 What counts as an outcome

An outcome counts only if a host-side grader produced it after the attempt,
outside the model's reach. Three sources qualify:

- the suite's success check, which `import_run` runs on the final workspace
  after the chained runner has exported the store (`chained_runner.py`
  docstring);
- the WorkBuddy verifier, through the adapter;
- the host check's verdict, classified as `check_gate.runCheck` classifies
  it. `unavailable` voids the pair. `tainted` is a failure, because the
  trustworthy outcome was not met.

In `rule_impact_evidence.OutcomeSource` terms, the gate admits `grader` and
`task_audit`.

Never counted: anything the model wrote or a tool returned to it. That covers
its final note, lesson text, its own test runs, `KgRemember` content, an LLM
judge, and any score passed through a tool, which is EvoOntology's
`record_evolution_evaluation` pattern. No tool exists through which an
outcome could enter the gate. The runner reads outcomes from host artifacts,
never from the transcript.

### 6.2 The gate receipt

`metacodes-learning-gate-receipt-v1` is canonical JSON. Its id is the sha256
of the body. It is persisted content-addressed beside the version records and
holds:

- kind, model stratum, Parent and Candidate version sha256;
- batch manifest sha256, pool commitment sha256, look index `j`, `L_max`,
  `α_j`, and the test (`mcnemar_one_sided` or `tango_ni` with `δ`);
- per pair: unit id, decision point id, store import sha256, both rollout
  ids, each rollout's grader fingerprint, outcome evidence sha256, budget
  transaction id, and the scoped-recall `injection_sha256` beside the
  census's predicted value;
- counts `b`, `c`, ties, void pairs; the statistic and the decision;
- paired cost and turn deltas with their intervals;
- the exposure rate `e` with its Wilson interval.

### 6.3 Existing machinery the gate reuses

| need | existing mechanism |
|---|---|
| arms identical except for the version | `e2e_adapter.comparison_fingerprints`, factor `harness` |
| every rollout's spend authorised and committed | `memory_budget_journal`; `paired_runner._validate_checkpoint_budget_receipt` binds a rollout to its committed journal transaction |
| both arms started from the same store | chain ledger `metacodes-chain-ledger-v1`: import/export sha256, import witness |
| the arm saw the bytes it was meant to see (actuation witness) | scoped-recall receipt `metacodes-scoped-recall-v1`, `injection_sha256`, compared with the census prediction. This is the role `treatment_activation.py` plays for the TinyKG arm |
| validation never enters design | `ontology_rule_projection.heldOutCommitmentSha256` |
| a decision rebuilt from source rows, never trusted from a receipt alone | `promotion.validate_calibration_bundle` rebuilds the receipt from the checkpoints and requires equality |
| rule safety facts | `rule_impact_receipt`, `rule_impact_aggregate_receipt`, `RuleImpactGovernance.lean` |

### 6.4 Verification at load

At run start the binary:

1. reads the pointer for (kind, runtime stratum);
2. loads the receipt and checks its id hash, the Candidate version sha and
   that the receipt's stratum equals the runtime stratum;
3. re-runs the decision over the receipt's integer facts (`b`, `c`, N, `j`,
   `L_max`, and the id of the pinned acceptance table) in the Lean kernel.
   This is the role `project_rule_bundle.reattestPromotion` plays for rule
   bundles.

A pointer whose receipt does not re-derive is refused, and the shipped
default loads. The Lean side compares integers against pinned tables (the
§5.2 table; a Tango table indexed by `(N, b, c, δ)`), so it needs no
floating point. The tables are generated and checked by exact enumeration in
Python tests.

The expensive re-derivation from raw rollouts happens before the CAS, in the
evaluation tooling, as `promotion.py` does for calibration receipts.

## 7. Model conditioning

- **The key.** The stratum is a domain-separated sha256 over the selected
  offer's `CanonicalModelId` ([PROVIDER_OFFER_ARCHITECTURE.md](PROVIDER_OFFER_ARCHITECTURE.md)),
  length-prefixed as `OfferId` is. When the canonical id is unknown, the
  stratum is the `OfferId` itself. Nothing parses any vendor's model naming,
  and nothing assumes a vendor's error or catalogue format. Two channels
  serving the same canonical model share a stratum. A gateway that changes
  behaviour is caught by the holdback (§8.3), not by the key.
- **Write.** Every version record carries `model_stratum`. So does every
  model-written artifact, together with the `producer_version_sha256` that
  wrote it. That needs new envelope versions:
  - the lesson header (`lesson-v1 verdict= task= run=`) gains a `model=`
    field bound by the host like the rest of the header;
  - the provisional-rule and obligation envelopes gain `model_stratum`.
- **Read.** Pointers are looked up by (kind, runtime stratum), and a missing
  pointer means the shipped default. Lessons, obligations and provisional
  rules written under another stratum are not injected or loaded unless the
  active policy version of their kind for the runtime stratum allows it. For
  lessons that is a parameter of the `injection_shape`. Either way the
  setting is itself gated.
- **Transfer.** A version accepted on stratum A may be proposed as a
  Candidate on stratum B. Authoring costs nothing, but B's look does.
  EvoOntology's −6.6 to −10.9 on transfer is why it is not free.
- **Reporting.** Every result is per stratum. A pooled multi-model number
  decides nothing. `analysis.compare` already flags a comparison in which
  the model changed as unattributable (factor `joint`).
- **Silent model updates.** A provider can update the model behind an
  unchanged canonical id. The key cannot see it. The holdback can.

## 8. Retirement

### 8.1 Unproven and proven artifacts

A version is **proven** for a stratum once an `accept`, `remove` or
`keep-proven` receipt supports it there. Until then it is **unproven**.
Today nothing is proven. That includes the §4 framing layers, which were
added after single-task forensics, not through a gate.

Two things retire differently:

- **Items** are the lessons, obligations and provisional rules that a
  producer version writes. They are never proven individually (§3.1).
  Retiring one needs no statistics: it returns the system to its state
  before the item was written, under the same version.
- **Versions** include the shipped default. The shipped default holds its
  place by incumbency, not by evidence. Changing it, including removing one
  of its layers, is a Candidate like any other and goes through the gate.
  That is why §10 can end in `keep-proven`, and why removing an unproven
  layer is not free.

For a proven version:

- **Demotion needs evidence of harm** (§8.3), because demoting discards
  evidence.
- **Safety acts without waiting for statistics.**

### 8.2 Existing mechanisms and their place

| mechanism | trigger | evidence | role under this design |
|---|---|---|---|
| block-storm breaker (`self_evolution.writeImpactObservation`) | ≥ 8 enforced pre-dispatch blocks in one run | one run | safety. Stays unilateral and applies to proven rules too |
| RuleImpact `quarantine` | formal faults, shadow divergences or false interventions above policy | Lean-checked facts | safety. Should be immediate; today it has no caller (§8.4) |
| RuleImpact `demote` | drift, or regressions above policy | Lean-checked facts | the rules' demotion path, with `regressions` supplied by the holdback test (§8.3) |
| obligation Rule A (`INERT_NUDGE_ROUNDS` = 3) | nudged in 3 rounds, never dispatched | telemetry | item hygiene for needles. Loss-free by its own argument (`dispatched_never_inert`). Stays |
| obligation Rule B | met once, no reward gain afterwards | one round | item hygiene for needles, and weak at n = 1. It retires items, never a version. Its thresholds are part of the `obligation_policy` version, so their effect is gated with that version |
| lesson supersession, `/kg forget` | the model's reconcile pass, or a user | none | item hygiene for lessons. Stays |
| impact-row deprecation (`deprecateStaleOntologyRows`) | every run | n/a | bookkeeping, not retirement |

### 8.3 Demoting a proven artifact: the holdback

After an artifact is promoted, before/after comparisons are confounded by
task mix and by model drift. Detecting harm needs a concurrent comparator:

- **Holdback.** In evaluation campaigns that run anyway, a fixed fraction
  `h` of exposed decision points (default 0.1) forks an attempt under the
  previous version, using the §4.6 mechanics.
- **Windows.** Pairs accumulate into non-overlapping windows of W units.
- **Test.** Each window is tested one-sided, exact McNemar, previous version
  better than the active one, at `α_d = 0.05`. A rejection demotes: CAS back
  to the previous version with a demotion receipt.
- **Re-promotion** needs a fresh pool.

A false demotion only reverts to a version that was itself gated, so `α_d`
is not divided across windows. The expected false-demotion count per proven
artifact is `α_d` times the number of windows. W is chosen so that windows
are few (one per release is the intended cadence), and the count is
reported. The same windows detect a model updated behind an unchanged
canonical id.

### 8.4 What wiring promote and demote into the product path still lacks

Live sessions only *consume* the active pointer. They cannot produce paired
evidence: a user's turn cannot be run twice. The evidence comes from
evaluation campaigns, or later from practice replays on snapshots (§12).
Between the two, the following is missing:

1. **Versions and pointers for anything but rules.** Only project rules have
   a content-addressed store and a CAS pointer (`project_rule_bundle`).
   Lessons, obligations, injection shapes and provisional rules have neither
   version nor status. Provisional rules and obligations are TinyKG
   envelopes, live from the moment they are written.
2. **Model stratum and producer version in artifact headers** (§7).
3. **A gate receipt, its verifier at load, and its Lean mirror**
   (`LearningGate.lean`, §6.4).
4. **Harness support.** Each of these is missing:
   - fork pairing in the chain ledger;
   - a census tool that renders both versions from a store tar;
   - a version selector on the runner allowlist;
   - a headless chain vehicle. Outcome rows exist only in headless runs, and
     only under `METACODES_SELF_EVOLUTION`, which gates both `ingestOutcomes`
     and the obligation and provisional-rule loads (`repl/headless.zig`).
5. **The statistics.** A one-sided exact acceptance table, the Tango bound,
   and a per-pool look ledger. `statistics.py` has only the two-sided
   `exact_mcnemar` and Wilson.
6. **A comparator in RuleImpact.** The governance facts have no Parent arm.
   Either the facts gain paired fields (`b`, `c`, exposed units, stratum), or
   promotion requires a learning-gate receipt beside the RuleImpact verdict.
   The second keeps RuleImpact as the safety half and the gate as the benefit
   half, and is the recommendation here. Nothing in the product calls
   `promote` today. The product needs a command that takes a gate receipt and
   performs the CAS.
7. **A place for `demote` and `quarantine` to land.** This needs two pieces:
   - a `rule_lifecycle` transition `promoted → retired` that does not need a
     replacement;
   - a `project_rule_bundle` operation that publishes a new revision without
     the rule, under the same lease and CAS.

   Quarantine should run at the end of the run that produced its facts, not
   wait for a driver.
8. **Provisional loads that obey the pointer.** Outside an experiment arm
   that explicitly runs the Candidate, a provisional rule or obligation whose
   producer version is not active for the stratum should load in shadow,
   recorded but not enforced. Inside the self-evolution arms of today's
   experiments, immediate enforcement is the Candidate treatment, and that is
   what it should be called.
9. **A durable record for the end-of-run learning form.** It logs its report
   at warn level because the journal is sealed before the host check runs
   ([LEARNING_TURN_DESIGN.md](LEARNING_TURN_DESIGN.md) §12). Gating
   `lesson_policy` on headless runs needs that record as a receipt.

## 9. Cost

### 9.1 Per-rollout cost on record

Nominal cost at the repository guardrail rates (US$3 / US$15 per Mtok):

| cohort | model | per rollout |
|---|---|---|
| check-gate v1 ([check-gate-v1.md](../evals/experiments/check-gate-v1.md)) | glm-5.3-flash | US$3.01 / 12 ≈ US$0.25 |
| check-gate v2 ([check-gate-v2.md](../evals/experiments/check-gate-v2.md)) | glm-5.3-flash | mean US$0.35–0.37 |
| check-gate v3 ([check-gate-v3.md](../evals/experiments/check-gate-v3.md)), four hard specifications | glm-5.3-flash | US$15.75 / 24 ≈ US$0.66; maximum US$1.14 |
| delivery cadence v1 ([delivery-cadence-v1.md](../evals/experiments/delivery-cadence-v1.md)) | glm-5.3-flash | US$6.47 / 22 ≈ US$0.29 |
| test integrity v1 ([test-integrity-v1.md](../evals/experiments/test-integrity-v1.md)) | glm-5.3-flash | maximum US$0.41 |
| WorkBuddy dev16 memory study ([protocol](../evals/experiments/workbuddy-dev16-gatev2-memory-v1.json)) | as run | about US$45 expected for 4 arms × 16 tasks ≈ US$0.70 |

Every paid runner reserves the whole per-rollout cap before each rollout
(check-gate v3 run note), so a cumulative cap must equal expected spend plus
one per-rollout cap. A request also reserves the model's whole output
allowance. glm-5.3-flash's default of 131,072 tokens reserves US$1.97 per
request, which is why test-integrity v1 had to set `--max-tokens` (the
experiment's amendment).

Producer-side costs add to this:

- the self-evolution author call is capped at `AUTHOR_MAX_COST_MICROUSD`,
  US$0.40 worst case per run;
- the end-of-run learning form shares that cap;
- the in-run learning turn is bounded at 2 passes × 6 turns, and its real
  cost is unmeasured until learning-turn-v1 stage A runs.

### 9.2 Per Candidate

With a spine that already exists, a pair costs one fork rollout. With two
fresh arms, it costs two. Using US$0.66 per rollout (repeatedly failed tasks
are where the §10 layers fire, and check-gate v3 is the nearest record of
such tasks):

| decision | units (§5.4) | rollouts (fork / two arms) | nominal US$ |
|---|---|---|---|
| superiority, Δ +0.20, disc 0.30, `L_max` 3 | 68 | 68 / 136 | 45 / 90 |
| superiority, Δ +0.15, disc 0.25, `L_max` 3 | 104 | 104 / 208 | 69 / 137 |
| non-inferiority, δ 0.15, disc 0.3, `L_max` 3 | 130 | 130 / 260 | 86 / 172 |
| non-inferiority, δ 0.10, disc 0.3, `L_max` 3 | 270 | 270 / 540 | 178 / 356 |

Dollars are not the binding constraint. Units are: a decision at these
levels needs 50–270 independent tasks, and WorkBuddy is the only task set in
the tree with more than 6.

### 9.3 Standing cost

The holdback adds `h` × (exposed attempts in campaigns) fork rollouts. At
`h = 0.1` that is 10% of the exposed share of campaign spend.

## 10. First use case: pre-registration draft

This section is the protocol draft for
`evals/experiments/learned-gate-recall-shape-v1.md`. No rollout has been run.
No authorization exists, and each stage needs the owner's, with a dollar cap
and the durable budget journal.

### 10.1 Question

On one model stratum, named in the experiment file before any run: can the
verbatim-artifact directive and the cognitive-mode escalation each be removed
from the same-task outcome note? Removal is acceptable only if, at the
decision points where the layer fires, the next attempt's full-pass rate
drops by less than δ.

### 10.2 Parent and Candidates

- **P**: the shipped renderer, every layer as on `main`.
- **C_v**: P without the verbatim-artifact directive. The directive has two
  carriers, and both go:
  - the `FIRST EDIT` line from `scoped_recall.appendVerbatimDirective`;
  - the derived artifact obligations from
    `obligation_gate.appendArtifactFirst` (`ARTIFACT_FIRST_REASON`,
    `ARTIFACT_REF_REASON`).

  The quoted artifact itself stays. Removing one carrier and keeping the other
  is not the Candidate §4 names.
- **C_m**: P with the cognitive-mode schedule fixed at `verify`
  (`cognitive_mode.schedule` returns `.verify` for every streak). The
  per-point listing stays. An Accept of C_m also changes what
  `CognitiveMode.lean` must prove for the active version: `reaches_union` no
  longer holds of it.

Both Candidates are subtractive. Their content hashes are committed in the
experiment file before the first spine attempt, so the batch has no design
pool (`f_design = 0`, §4.2). The pool's `L_max` is 3, and C_v and C_m spend
two looks, so `α_j = 0.05/3`. The third look is reserved for a follow-up.

### 10.3 Exposure and vehicle

- **C_v is exposed** when P's note at the boundary carries the directive, or
  when a derived artifact obligation loads. Either needs an earlier attempt
  whose row carries a best-attempt artifact.
- **C_m is exposed** when some failing point has a streak ≥ 2, which needs
  two earlier rows naming it. A two-pass protocol never exposes C_m.

The vehicle must file outcome rows between attempts. Only headless runs
under `METACODES_SELF_EVOLUTION` do (§8.4 item 4). There are two strata:

- **Stratum A, runnable once the prerequisites exist.** WorkBuddy dev, 52
  tasks, through the two-pass adapter, extended to 4 passes. The adapter
  sets no host check, and its outcome rows carry provenance
  `external_oracle`, which the learning turn refuses as evidence
  (LEARNING_TURN_DESIGN §5). This stratum therefore has no lessons.
- **Stratum B, lessons present.** This is the premise of §4. It needs native
  headless chains with a pinned host check and the end-of-run learning form,
  on a cohort of at least about 50 tasks. No such cohort exists in the tree.
  Stratum B is not pre-registered here.

Stratum A is the conservative reading of §4. Lessons are meant to stand in
for these layers. If the note is no worse without a layer when no lesson can
stand in for it, the layer carries no weight for this model that the margin
can detect. This assumes lessons substitute for the layers rather than
interact with them. A removal rejected in stratum A says nothing about
stratum B.

Self-evolution also loads provisional rules and obligations, and runs its
author after each attempt. Both arms load the same ones, because they come
from the shared store. The author call runs after the graded workspace is
final, and its cost is part of the per-rollout cost.

### 10.4 Arms and pairing

Spine-and-fork (§4.6) over a 4-pass spine under P, with WorkBuddy's
arm-level store continuity. At every exposed boundary, one fork per exposed
Candidate imports the spine's store tar for that boundary and runs the next
attempt. Fork and spine attempt run back to back, with order alternating by
task. The two arms differ only in the renderer version selector (§4.5).

### 10.5 Metrics

- **Primary.** Full pass on the WorkBuddy verifier for the attempt that
  started at the decision point, one pair per task: the first exposed
  boundary in spine order for that Candidate.
- **Secondary.**
  - partial credit (verifier reward), paired mean difference with a t
    interval;
  - all exposed boundaries, at most 3 per task per Candidate, with
    task-cluster bootstrap intervals;
  - injected bytes per exposed attempt (deterministic);
  - cost, turns and wall time.
- **Exposure.** The rate `e` per Candidate over all spine boundaries, with
  its Wilson interval. It turns δ into the population bound `δ·e`.
- **Actuation witness.** Each pair's scoped-recall `injection_sha256` must
  equal the census prediction for its arm. A mismatch voids the pair.

### 10.6 Decision rule (fixed now)

The margin is **δ = 0.20**. A smaller one does not fit 52 units: δ = 0.15
needs 90–160 units for power 0.8 (§5.4), and with 52 its power is at most
0.54. For each Candidate, on the primary pairs:

1. `remove` if the Tango upper bound of `P_P − P_C` is below 0.20 at
   `α_j = 0.05/3`, and the upper end of the paired cost interval is at most
   US$0.10 per pair. Over 8 pairs, check-gate v3's paired cost interval ran
   from −US$0.09 to +US$0.19. At about 50 pairs it should be roughly 2.5
   times narrower, so a guard of US$0.10 catches a real increase without
   failing on noise;
2. otherwise `keep-proven` if the one-sided exact McNemar shows P better at
   `α_j`;
3. otherwise `undecided`.

Only `remove` moves the pointer.

### 10.7 Stages and stopping rules

- **S0 (no model cost).** Purity check. On a loopback-provider chain (as
  `scripts/eval/chained_memory_smoke.py` runs one), and on archived dev
  stores where they exist, the census's rendering of P must equal the
  binary's recorded `injection_sha256`. If it does not, the census cannot
  predict exposure, and nothing proceeds.
- **S1 (paid).** The spine, with the census at every boundary and primary
  forks run as exposed boundaries occur. The secondary forks are
  pre-registered as droppable and run only within the authorized cap.
- **Stop.** A Candidate with fewer than 30 exposed tasks when the spine
  completes is reported `unexposed`: no look, no bit. At 30 tasks the power
  at δ = 0.20 is 0.33–0.54 (§5.4), which is not worth a look. Void pairs
  above 10% void the look (§5.6).

Planned power at δ = 0.20 with every task exposed: 0.54–0.80 for
discordance 0.4–0.2. At discordance above 0.3, this dose is underpowered.
The only larger cohort in the tree adds promotion-A and promotion-B (104
tasks), and spending those is the owner's decision because they belong to
the ladder.

### 10.8 Cost reservation

At US$0.70 per WorkBuddy rollout (§9.1):

| part | rollouts | nominal US$ |
|---|---|---|
| spine, 52 tasks × 4 passes | 208 | 146 |
| primary forks, ≤ 52 per Candidate × 2 | ≤ 104 | ≤ 73 |
| secondary forks, ≤ 2 more per task per Candidate | ≤ 208 | ≤ 146 |
| headroom: one per-rollout cap, set in the experiment file (dev16 budgeted about US$1.6 per rollout) | — | ≈ 1.6 |

The primary decision costs at most about US$220. Everything pre-registered
costs at most about US$365. If a dev campaign that runs 4 passes under P is
already planned for another reason, the spine is sunk, and the marginal cost
of the decision is the forks alone: at most about US$73 for the primary.

### 10.9 Claim boundary

- This is internal evidence on WorkBuddy dev (the iteration surface), for
  one model stratum, without lessons. It supports no external claim.
  Promotion and sealed cohorts are untouched.
- An accepted removal bounds the harm at exposed decision points below 20
  points of full-pass rate, and below `0.20·e` overall. It does not show the
  layer is useless.
- `keep-proven` is the first evidence that either layer helps, for this
  model only.
- Stratum B is untested.

### 10.10 Prerequisites

1. Renderer versions: `scoped_recall` and `obligation_gate` take a shape
   value. The shipped default is byte-identical to `main` (a golden test),
   and C_v and C_m are selectable.
2. The census tool: it ingests an outcomes file into a scratch copy of a
   store tar and renders P, C_v and C_m.
3. The WorkBuddy adapter: a 4-pass schedule, a store snapshot per task
   boundary, and fork import recorded in the ledger.
4. The statistics and the gate receipt (§11 steps 1–2).
5. Owner authorization, with the cap and the durable budget journal.

## 11. Implementation sketch (not started)

| step | files | evidence that closes it |
|---|---|---|
| 1. Statistics: one-sided exact McNemar and its acceptance table, Tango score bound, power by exact enumeration | `scripts/eval/statistics.py` | Tests: the table against brute force; Tango size at the margin ≤ α_j on a grid; Tango at δ = 0 equals McNemar's z |
| 2. Gate core: batch manifest, unit merge, time split, pool commitment, look ledger, decision, receipt | `scripts/eval/learning_gate.py` | Tests: a near-duplicate never straddles the split; a second Accept on a retired pool is refused; a leaked receipt retires its pool; `unexposed` and `void` spend no look |
| 3. Versions and per-(kind, stratum) pointer with lease and CAS; receipt verification at load | `packages/coding/src/core/learned_artifact.zig` | Component tests in the `project_rule_bundle` style: a tampered receipt loads the default; a stratum mismatch loads the default; a lost CAS race leaves no orphan pointer |
| 4. Model stratum; `model=` in the lesson header; `model_stratum` in provisional and obligation envelopes | `packages/coding/src/core/model_stratum.zig`, `packages/coding/src/kg/lesson.zig`, `packages/coding/src/core/self_evolution.zig` | Tests: old envelopes still parse as unproven; a cross-stratum lesson is not injected under the default shape |
| 5. Renderer versions for the scoped-recall note and the derived obligations | `packages/coding/src/kg/scoped_recall.zig`, `packages/coding/src/core/obligation_gate.zig` | Golden test: the default shape is byte-identical to today's note; C_v and C_m differ only in their layer |
| 6. Census and fork pairing | `scripts/eval/chained_runner.py`, the WorkBuddy adapter | Fixture test: the census prediction equals the binary's `injection_sha256` for both arms from one tar |
| 7. `LearningGate.lean`: `no_accept_below_min_discordant`, `accept_retires_pool`, `looks_bounded`, `unexposed_never_decides`, `stratum_mismatch_never_activates` | `control-plane/lean/MetaCodesControl/` | `zig build test` with the kernel |
| 8. Retirement: `promoted → retired` in `rule_lifecycle`; `project_rule_bundle.retire`; quarantine at end of run; promotion requires a gate receipt beside the RuleImpact verdict | `packages/coding/src/core/rule_lifecycle.zig`, `packages/coding/src/core/project_rule_bundle.zig`, `packages/coding/src/core/self_evolution.zig` | Component tests: a demote verdict publishes a revision without the rule; a promote without a gate receipt is refused |
| 9. Experiment file from §10 | `evals/experiments/learned-gate-recall-shape-v1.md` | The protocol above, with the owner's authorization recorded |

Steps 1, 2 and 5 need no provider and no kernel change. With step 6 they are
everything §10 needs. Steps 3, 4, 7 and 8 are what the product path needs
before any pointer moves outside an experiment.

## 12. Deliberately not in this design

- **No live A/B in user sessions.** A turn cannot be run twice, and
  unpaired online assignment has neither the power nor a host grader. Live
  sessions only consume pointers.
- **No practice replays.** Re-running past tasks from snapshots to produce
  pairs outside campaigns would be the evidence source a product could own.
  It belongs with practice tasks, RSIAgent's third borrowing
  (LEARNING_TURN_DESIGN §10), and stands on its own.
- **No propose-until-accept loop.** Candidate design is budgeted and
  separate. The gate never asks for another Candidate.
- **No per-item statistics for lessons or obligations.** §3.1.
- **No LLM-judged outcomes and no self-reported scores.** §6.1.
- **No pooling across models, and no transfer without the target stratum's
  own look.** §7.
- **No change to the safety breakers.** They stay unilateral. The gate adds
  a benefit test. It does not slow a safety retraction.
- **No use of WorkBuddy promotion or sealed cohorts without the owner.** The
  gate's decisions are internal and never an external claim.
- **No adaptive allocation** (bandits, Bayesian stopping) in v1. Fixed N per
  look keeps the error statement a sentence long.
