# Project-specific Harness Evolution

Status: bounded end-to-end production pilot. Grounded tool observations can
produce governed candidates; durable build/replay/shadow evidence can be
promoted by a fixed Lean kernel into a hash-pinned active bundle; real tool
dispatch is gated before and after execution. Candidate discovery is not yet
automatic, and active supersession/TinyKG mutation remain future work.

## Direction

The useful end state is not one universal, prewritten rulebook. A metacodes
project gradually acquires a versioned, project-specific Harness as real work
reveals its failure modes:

```text
actual tool signals
  -> user correction / agent reflection / runtime counterexample
  -> candidate Lean rule
  -> isolated build + axiom audit + historical replay + shadow execution
  -> independent promotion
  -> hash-pinned project rule bundle
  -> runtime verdict
  -> actual tool signals and re-observation
```

“Dynamic Lean” means evolution across the lifetime of a project. It never
means that an agent writes a theorem during an action and immediately uses that
same theorem to authorize the action.

Lean starts deliberately small. A rule is worth formalizing only after the
project has produced a concrete correction, counterexample, or repeated
operational failure that makes the invariant stable enough to state precisely.

## Signal plane

Every actual tool dispatch needs a generic, UI-independent envelope at the one
real execution seam. The envelope identifies the tool use, requested and
actually dispatched names, origin, agent depth, input/result commitments,
outcome, error code, and elapsed time. A tool may add a versioned typed effect
when the generic envelope is insufficient.

Typed effects are added incrementally. The first pilot is `file_mutation_v1`,
which reports commitments and byte counts for the file state observed by
Write/Edit. It does not expose paths or contents, prove filesystem atomicity, or
authorize another mutation. Its path hash is a commitment rather than an
anonymity guarantee, and the pilot does not claim to enumerate auxiliary
effects such as parent-directory creation. Tool cards, TUI projection, and
model-facing tool schemas are separate consumers and cannot disable the signal
plane.

The first pre-dispatch project signal is deliberately narrower than a general
filesystem policy. `file_target_state` is one of `unobserved`, `missing`,
`regular_existing`, `other_existing`, or `unavailable`. Zig derives it from the
actual normalized `Write.file_path` with a no-follow final-component lookup;
the model cannot supply the classification. `TargetScope.existing_file` is
valid only for `Write`: it applies to `regular_existing`, admits only a proven
`missing` target as outside the scope, and fails closed for every ambiguous or
non-regular state. The same sensor and journal field run in signal-only,
shadow, and enforced arms. After an enforced gate admits a proven-missing
target, `Write` uses exclusive creation so a file appearing before open cannot
be truncated. This does not claim atomic parent-directory resolution or prove
the filesystem's power-loss model.

Speculative prefetch is marked separately from authoritative execution. A
discarded prefetch remains a real dispatch and therefore remains observable,
but it cannot be mistaken for the action selected by the completed model turn.

## Candidate sources and authority

The source is part of the candidate identity and cannot be rewritten during
promotion.

| Source | Meaning | Initial authority | May do |
| --- | --- | --- | --- |
| `user_correction` | An external correction or project constraint | high | prioritize a candidate and define acceptance examples |
| `agent_reflection` | An agent hypothesis formed after inspecting its work and signals | low | propose a falsifiable candidate and replay cases |
| `runtime_counterexample` | A concrete failed verdict, invariant breach, or execution mismatch | evidence | demonstrate that an existing contract is incomplete |

An agent reflection must bind the run identity, the observation interval used,
the proposed invariant, and at least one falsifier: a condition under which the
reflection should be rejected. It is a hypothesis, not testimony. The agent
that produced it cannot certify its truth, promote it, expand its own authority,
or use it to approve side effects in the same incident.

A user correction has greater semantic authority, but it still does not bypass
type checking, the axiom policy, replay, shadow execution, or runtime evidence.
For example, a correction can establish “never do X in this project”; it cannot
make a malformed checker artifact safe.

Persistence does not authenticate a source label by itself. A stored
`user_correction` still needs a host-issued correction receipt at admission;
`runtime_counterexample` still needs the referenced verdict artifact. In
contrast, `agent_reflection` can already bind the exact completed observation
interval because that evidence is emitted by the runtime. Until the other
receipts exist, their hashes are immutable claims, not proof of authority.

The preferred reflection trigger is post-Run and event-driven. A separate
review call receives a bounded observation interval and proposes a candidate;
its output is not appended to the main Conversation and therefore does not
rewrite the provider-visible history or its warm cache prefix. It should run
after user correction, a failed/blocked Run, a formal counterexample, or a
repeated anomaly—not after every successful turn. The main actor may author
that hypothesis, but the later builder, shadow evaluator, and promoter remain
independent roles.

## Candidate lifecycle

The intended persistent states are:

```text
proposed
  -> built
  -> axiom_audited
  -> replay_passed
  -> shadow_passed
  -> promoted
  -> superseded

proposed/built/axiom_audited/replay_passed/shadow_passed -> rejected
```

Each transition appends evidence; it does not overwrite prior evidence. A
promotion receipt must bind all of the following:

- project identity and rule identifier;
- source kind and immutable source evidence;
- Lean source hash and compiled checker hash;
- approved axiom policy and axiom-audit result;
- replay corpus identity and results, including negative cases;
- shadow interval, observed decisions, and divergences;
- promoter identity, bundle revision, and previous bundle hash.

There is no direct `proposed -> promoted` transition. The proposal-producing
agent is never sufficient promotion authority. Runtime loads only promoted,
compiled, version-compatible, hash-pinned bundles. Missing artifacts, identity
drift, malformed receipts, or a checker protocol error fail closed.

Promotion does not prove that a natural-language belief is true. It establishes
that a particular executable decision rule passed the declared governance
process and that its runtime artifact is the one that was reviewed.

## Closed-loop responsibilities

- Tools emit actual signals and typed effects. They do not declare themselves
  compliant.
- Zig owns permission, dispatch ordering, durable observation transport,
  checker invocation, re-observation, and fail-closed actuation.
- Lean owns the small set of promoted transition and governance invariants. It
  does not prove `fsync`, locks, provider behavior, or semantic truth.
- TinyKG is the eventual versioned task/memory/audit plane. Canonical mutation
  waits for its dedicated snapshot/CAS/receipt/rollback primitive; ordinary
  multi-command writes must not emulate that transaction.
- The LLM proposes meanings, abstractions, repairs, and candidate rules. It
  never self-promotes them.

The loop is complete only when the verdict changes what the runtime may do and
the resulting environment is observed again. A theorem that is built in CI but
does not gate a real action is documentation, not a control loop.

## Current implementation boundary

The pilot now closes one real vertical slice:

```text
host-issued correction / completed-run reflection / blocked runtime verdict
  -> immutable RuleCandidate
  -> sandboxed Lean build + empty-axiom audit
  -> manifest-addressed durable build evidence
  -> positive/negative replay + side-effect-free shadow
  -> promotion request to the fixed hash-pinned Lean kernel
  -> crash-safe active bundle CAS
  -> executeOne pre gate
  -> real dispatch + typed effect + host re-observation
  -> executeOne post gate
  -> durable verdict and terminal observation
  -> runtime_counterexample source for a later candidate
```

The authority boundary is intentionally asymmetric. Candidate Lean source is
compiled and axiom-audited as proof evidence, but production authorization is
computed only by the fixed `metacodes-project-kernel` over bounded `RuleSpec`
data. A candidate can therefore evolve the project Harness without replacing
the trusted kernel or executing agent-generated code in the runtime.

Implemented runtime properties:

- `tool_exec.executeOne` is the single actual-dispatch seam and emits
  UI-independent start/finish events at every depth;
- Write/Edit attach `file_mutation_v1`; the host upgrades it to
  `file_mutation_v2` after a real post-action re-read;
- pre block prevents the dispatcher call; post block/fault occurs after the
  real outcome is re-observed and poisons the Run instead of hiding the effect;
- formal-decision schema v2 separates the kernel verdict from host actuation:
  production is always `enforced`, while an isolated experiment may use
  `shadow` to persist the identical verdict but project it to `admit` at the
  protocol boundary. Pre/post actuation must match, legacy v1 records are
  accepted only as enforced, and a shadow block cannot be promoted into an
  enforced runtime-counterexample receipt;
- `RuleSpec v2` can express the first real correction without banning new-file
  creation: existing regular-file `Write` is blocked, missing-file `Write` is
  admitted with exclusive creation, and `Edit` remains an available recovery;
- pre target state is recorded in both dispatch and formal-decision evidence,
  including blocked actions that never produce a dispatch-start event;
- all active rules for one phase are sent to one fixed-kernel batch call (up to
  1024 requests / 4 MiB), while every member keeps its own request, candidate,
  binding and verdict identity; batching changes process topology, not rule
  semantics;
- the durable journal validates exact `pre -> dispatch -> post -> finish`
  ordering, rejects duplicate candidate/phase decisions and dispatch-id reuse,
  requires one post verdict per admitted active rule unless a terminal
  post block/fault short-circuits the conjunction, and permits the explicit
  `pre block/fault -> no dispatch` terminal path;
- TUI, headless, suspended resume, Web, daemon, Skill CLI, synchronous Agent,
  and TaskBatch create a stable-address `RunControl` containing the journal and
  re-attested active gate;
- concurrent TaskBatch decisions are serialized inside the runtime gate;
- while rules are active, detached Agent, teammate/TeamCreate, Ctrl+B
  backgrounding, explicit background Bash, Monitor, and starting a governed Run
  beside an existing Bash/subagent background job or team fail closed;
- governed foreground Bash remains synchronous instead of taking the normal
  15-second auto-background path. Independent worker journals are required
  before any of these detached modes can be enabled safely.

Implemented lifecycle properties:

- correction and counterexample source labels are reopened against exact host
  transcript/journal/verdict evidence; cross-project relabeling is rejected;
- immutable candidate and lifecycle files are content addressed, single-link
  regular files with bounded strict schemas;
- build/axiom receipts are created only after the host verifies a real build
  bundle, persists its ten artifacts by manifest hash, and reopens that durable
  copy;
- promotion reopens the durable build bundle, current toolchain/SDK, replay and
  shadow artifacts, the exact completed Run, and every lifecycle predecessor;
- builder, auditor, replay evaluator, shadow evaluator, promoter, and proposer
  independence is checked before promotion;
- the fixed Lean kernel proves the bounded promotion and pre/post decision
  invariants; Zig never reimplements an alternative admission result;
- promotion serializes the full state-dependent transition, persists request,
  verdict, receipt, and bundle, then publishes `active.json` by revision/bundle
  CAS. Incomplete lock/temp markers poison runtime loading;
- extending an existing active bundle first re-executes its prior promotion
  request with the pinned kernel; a missing/tampered old request or verdict
  cannot be laundered into the next revision;
- candidate, source, evaluation, lifecycle, build, journal, verdict, bundle,
  and active-pointer publication use checked file flushes and parent-directory
  flushes where the platform exposes them; this is an observable durability
  boundary, not a claim about the filesystem's power-loss model;
- every Run re-attests the promotion request/verdict with the pinned kernel;
  artifact, receipt, project, revision, bundle, or kernel drift fails closed.

The checker is hashed before and after execution. This protects accidental
drift and ordinary replacement/tamper. A malicious process with the same OS
user can also mutate this process or win a precise path-to-exec race and is
outside the pilot threat model; solving that stronger boundary requires an
opened executable fd plus `fexecve`/platform equivalent or a separately
privileged kernel service. The project does not claim same-user adversarial
isolation.

### Runtime surface coverage

The production boundary is deliberately explicit:

| Surface | Rule/evidence ownership |
| --- | --- |
| TUI, headless, suspended resume, Web, daemon, Skill CLI | create one durable `RunControl` before the provider request |
| synchronous Agent and TaskBatch | inherit the parent's gate and observation sink through `ToolContext` |
| stream prefetch | uses the same gate/journal and is marked `speculative_prefetch` |
| Bash/Monitor/background Agent/team workers | remain disabled while an active bundle is loaded |
| AgentCore embedding ABI | host-owned lifecycle; project-bundle adoption is not part of this pilot |

An active bundle is snapshotted and re-attested at Run start. A later promotion
governs future Runs; it does not retroactively change an in-flight Run. Because
detached workers do not yet own a durable RunControl, an operator must quiesce
them before an out-of-band promotion. The product prevents starting a governed
Run beside existing detached work and prevents creating new detached work from
one, but this pilot does not claim a machine-checked global quiescence protocol.

The pilot still does not implement:

- automatic LLM reflection/candidate generation after every trigger;
- automatic active-bundle removal or machine-checked supersession. The typed
  supersession topology exists, but no public API can publish it yet;
- detached worker-owned RunControl/journal lifetimes;
- AgentCore host integration or a global quiescence receipt for out-of-band
  promotion;
- authoritative adoption/discard receipts for speculative prefetch;
- TinyKG MemoryMigration snapshot/CAS/rollback integration;
- semantic proof that a natural-language correction or reflection is true.

These are explicit boundaries, not silently accepted paths. Lean starts with a
small fixed meta-kernel and a narrow rule vocabulary; each project grows rules
only as corrections, counterexamples, and reviewed reflections justify them.

## Evaluation and paper data

The artifacts are the primary paper dataset, not console logs:

| Question | Durable source |
| --- | --- |
| candidate source and provenance | `rule-candidate-*.json` plus source receipt |
| build isolation, toolchain, SDK, axiom policy, build latency | `project-rule-build-evidence-<manifest>-manifest.json` |
| replay cases and FP/FN | `rule-replay-corpus-*` and `rule-replay-result-*` |
| shadow cases, interval, divergence, side effects | `rule-shadow-trace-*` and `rule-shadow-result-*` |
| lifecycle acceptance/rejection and actors | `rule-stage-receipt-*` chain |
| promotion/kernel latency and artifact size | promoted receipt `checker_elapsed_ns/checker_bytes` |
| runtime checker calls/latency, blocks/faults | journal `formal_decision_batch` (or legacy `formal_decision`) events; deduplicate physical latency by checker-call hash |
| actual effect/re-observation outcome | paired journal dispatch events |
| active revision and provenance | `active.json`, bundle, promotion request/verdict |

Retain rejected candidates and failed lifecycle transitions as negative results;
do not publish only successful rules. The runtime journal records checker calls,
latency, binary bytes, phase, result, candidate, bundle revision, request and
verdict identity. Candidate/source/lifecycle artifacts preserve correction and
reflection provenance, replay FP/FN, shadow divergence and revision history.
External experiment manifests should add model/harness fingerprints, task arm,
human-review count, wall-clock proposal-to-promotion duration and cost; those
experiment labels are not authorization inputs and therefore do not belong in
the fixed kernel request.

### Causal evaluation protocol

The central empirical claim is narrower than “Lean improves agents”:

> After a project exposes a correction or counterexample, governed rule
> evolution reduces recurrence on later, unseen variants without an
> unacceptable loss of trustworthy task completion, context/cache reuse, or
> operating cost.

Evidence is cumulative and may not be promoted across levels by wording:

| Level | Question | Required evidence | Permitted claim |
| --- | --- | --- | --- |
| E0 theorem | Is the bounded transition predicate internally sound? | Lean build, axiom audit and mutation of rejected inputs | theorem boundary only |
| E1 mechanism | Does the real sidecar gate the real dispatcher and preserve shadow trajectories? | fixed kernel, `executeOne`, durable journal, typed effect and host re-observation | control wiring works |
| E2 evolution | Can a temporally prior real correction become the exact promoted bundle later loaded by runtime? | transcript/source/candidate/build/replay/shadow/promotion/active receipt chain | governed lifecycle works |
| E3 outcome | Does that evolved Harness improve later unseen model tasks at acceptable cost? | preregistered paired model trials with cache-prefix equality and statistical analysis | empirical project benefit |

E0 cannot establish E1, E1 cannot establish E2, and E2 cannot establish E3.
In particular, a scripted tool driver is useful for causal mechanism
calibration but is not a model-quality benchmark.

The experiment must preserve temporal direction.  An incident at time `t` may
create a candidate, but replay and evaluation cases at `t+1` must not be used to
author that candidate.  Fresh project/TinyKG stores per rollout prevent one arm
from learning the other arm's future.  Replaying the original incident is a
lifecycle check, not evidence of generalization.

Use four primary arms:

1. `signal_only`: actual tool signals and journal, no project rules;
2. `static_enforced`: a frozen, hand-written project rule set;
3. `evolved_shadow`: correction/reflection-derived governed rules evaluated
   but not allowed to change dispatch;
4. `evolved_enforced`: the identical evolved bundle actively gates dispatch.

`evolved_shadow` versus `evolved_enforced` isolates actuation.  `static_enforced`
versus `evolved_enforced` asks whether project learning adds value beyond a
generic rulebook.  `signal_only` measures the ungoverned task baseline.  Rules,
model, task/trial pairs, provider, tool/token/cost caps, initial filesystem and
provider-visible prompt/tool prefix are frozen before arm assignment.  Arm
order is randomized and every rollout uses a fresh local store and run
directory.

The first corpus should mix two evidence classes instead of pretending that
one benchmark answers everything:

- deterministic incident families with an executable oracle: prohibited
  dispatch, excessive input/depth, non-authoritative action, missing or
  mismatched file re-observation, stale/tampered binding, checker failure and
  crash/recovery faults;
- long-horizon project tasks containing later paraphrased or structurally
  shifted recurrences of earlier corrections, plus ordinary tasks on which a
  rule should remain silent.

The current bounded `RuleSpec v2` can only support claims about its narrow tool,
existing-file scope, and file-mutation vocabulary. New signal/effect types
expand the evaluated corpus only after a real L2 proves that the actual
dispatcher emits them and the host re-observes the claimed effect.

Pre-register three co-primary outcomes rather than hiding trade-offs in one
score:

- corrected-hazard recurrence rate on unseen post-correction cases;
- trustworthy task success (task success with valid execution evidence);
- false-intervention rate on oracle-safe actions.

Secondary outcomes expose the control-loop mechanism:

| Control question | Measure |
| --- | --- |
| observability | relevant incidents carrying sufficient typed pre/post signal |
| controllability | oracle-preventable incidents reaching a pre-side-effect gate |
| settling | later episodes and wall time from correction to first stable prevention |
| overshoot | repeated incidents after correction but before stable prevention |
| stability | rule churn, contradiction/supersession count, re-opened incidents |
| robustness | recurrence prevention on paraphrase, tool-order and project-state shifts |
| semantic learning | proposed/built/promoted/rejected candidates, replay FP/FN and shadow divergence |
| formal integration | illegal lifecycle/binding/protocol mutations rejected before dispatch |
| operating cost | proposal/review/build/checker time, model tokens, dollars and artifact bytes |
| runtime cost | physical checker calls, p50/p95 latency and peak resources by active-rule count |
| context/cache | provider-visible prefix SHA, cache breaks, cache read/write tokens and warm reuse ratio |

Lean's empirical contribution should not be inferred from task score alone.
Mutation and fault-injection tests measure whether every illegal transition in
the stated theorem boundary is rejected through the real Zig-to-sidecar path.
Task trials measure whether the *chosen invariant* is useful.  Lean can make a
bad invariant consistently enforceable; it cannot make that invariant
semantically wise.

Run evaluation in four cost stages:

1. deterministic native L2 and mutation/fault injection, with zero provider
   requests;
2. side-effect-free shadow replay over frozen historical Runs;
3. a small paired model pilot to estimate variance and false interventions;
4. only after a written power analysis, a paid temporally ordered continual
   evaluation within the authorized budget.

The confirmatory E3 unit is a correction family, not an individual model
request. Each family freezes one earlier correction, later unseen recurrence
variants, oracle-safe negatives, initial filesystem, model/provider, harness
and tool schema, system/tool/cache prefix, token/turn limits and evaluator.
Every task/seed is run under all four arms in randomized order with fresh local
state. Primary analysis uses paired recurrence and trustworthy-success
differences; confidence intervals are clustered by correction family so a
large paraphrase family cannot masquerade as many independent discoveries.
False intervention is reported separately, not hidden inside a composite
score. The preregistration fixes sample size, exclusions, timeout treatment,
non-inferiority margin and stopping rule before the first confirmatory request.

Cache equality is causal-prefix equality, not an impossible demand that all
arms remain byte-identical after treatment. Provider-visible system text, tool
schema/order, task prompt and Conversation must be byte-identical through the
last common event before the first enforced intervention. A blocked tool result
and the model's recovery after it are treatment outcomes and may legitimately
fork the later Conversation. The cache regression gate therefore rejects only
control-plane-induced prefix changes (hidden rule prompts, schema reordering or
extra model-facing metadata) and reports post-actuation cache reuse separately.

Use paired task/trial analysis.  Report raw counts and confidence intervals;
use an exact paired binary test for success/hazard outcomes and bootstrap
paired deltas for latency, tokens and cost.  Freeze exclusions and stopping
rules before the paid run, and retain rejected candidates, timeouts and
fail-closed Runs.  A useful first production gate is: exact cache-prefix
identity through the pre-treatment boundary and zero control-plane-induced
cache breaks, p95 formal overhead below 100 ms at 64 active
rules, a pre-registered non-inferiority margin for trustworthy task success,
and a positive recurrence reduction whose interval is reported rather than
replaced by a hand-tuned composite score.

Memory quality and formal governance remain separate experiments.  Existing
`no_memory` / `markdown_memory` / `tinykg_lexical` benchmarks answer whether
memory helps recall and task performance.  The four arms above answer whether
project-specific formal evolution prevents recurrence.  A later reduced
factorial experiment may cross memory and governance, but doing so before each
main effect is established wastes paid samples and obscures causality.

Raw benchmark stores and rollouts stay in the isolated local experiment tree.
Only preregistered manifests, code/artifact identities, aggregate tables and
concise verified conclusions may enter the remote TinyKG control plane.

The 2026-08-09 local macOS arm64 ReleaseFast batch baseline used ten warm-file-
cache test processes over the real `executeOne -> pre checker -> dispatcher ->
post checker -> durable artifact/journal` path.  Execute-time p50/p95 was
17.659/17.943 ms at 1 rule, 18.161/18.506 ms at 4, 20.374/20.894 ms at 16 and
30.011/30.830 ms at 64.  This is mechanism overhead, not model-task outcome
evidence; the ignored raw report remains under `zig-out/reports`.

### Zero-provider four-arm mechanism calibration

`scripts/eval/project_harness_experiment.py` and the native
`metacodes-project-harness-eval` driver implement E1 without an LLM or provider.
Each rollout invokes the real `tool_exec.executeOne` seam, fixed compiled Lean
kernel and durable journal in a fresh local directory. The analyzer reopens a
single-link journal snapshot, verifies run/project/kernel/bundle/candidate/spec
identity and causal event order, and derives success and hazardous effects from
`dispatch_finished -> file_mutation_v2 -> reobservation`; it does not trust the
driver's metric fields. All artifacts are marked `quality_evidence=false`.

The frozen 5-case x 4-arm calibration on 2026-08-09 produced:

| Arm | Prohibited dispatches | Realized hazardous effects | Safe false interventions | Recovery after block | Trustworthy successes |
| --- | ---: | ---: | ---: | ---: | ---: |
| `signal_only` | 3/3 | 2/3 | 0/2 | 0/1 | 2/5 |
| `static_enforced` | 3/3 | 2/3 | 0/2 | 0/1 | 2/5 |
| `evolved_shadow` | 3/3, with 3 counterfactual blocks | 2/3 | 0/2 | 0/1 | 2/5 |
| `evolved_enforced` | 0/3 | 0/3 | 0/2 | 1/1 | 4/5 |

The directory-target case reached the dispatcher in the first three arms but
the tool itself rejected it, so it counts as a prohibited dispatch and not a
realized mutation. This distinction prevents a failed low-level call from
inflating the hazardous-effect rate while still penalizing the missing
pre-side-effect control. The one non-success in `evolved_enforced` is the plain
overwrite case with no scripted recovery; the paired recovery case shows that
an admitted `Edit` can complete the task after `Write` is blocked.

This establishes the narrow mechanism claim only: enforced decisions actuate,
shadow decisions do not, safe negatives remain admitted and recovery remains
possible. It does not establish E2 because the active identity is synthetic,
and it does not establish E3 because tool choice is scripted and there are no
provider requests, cache measurements or model outcomes.

### Real correction-to-production E2 lifecycle

`scripts/eval/project_harness_evolution.py` and the native
`metacodes-project-harness-lifecycle` driver evaluate the next evidence level
without a provider. The orchestrator freezes the driver, fixed kernel, direct
Lean toolchain binary, isolated builder, SDK source/olean and repository
identity before running four separate phases:

```text
real transcript-backed user correction
  -> host source receipt + typed candidate
  -> Seatbelt/bubblewrap Lean build + empty-axiom audit
  -> replay + shadow + fixed-kernel promotion + active CAS
  -> production RunControl reload
  -> existing-file Write blocked before dispatch
  -> Edit admitted, executed and re-observed
  -> independent-process native audit
  -> independent Python artifact audit
```

The Python audit does not trust the driver's booleans. It reopens the source
transcript/receipt, content-addressed candidate, isolated build manifest,
lifecycle predecessor chain and actor identities, active pointer/bundle,
runtime journal and final file state. It independently checks the causal event
order `Write pre-block -> no Write dispatch` and
`Edit pre-admit -> dispatch -> post-admit -> successful re-observed effect`.
Journal tamper, hard-linked active state and a falsified final result are
negative regression cases and fail closed.

The retained 2026-08-09 local run under
`zig-out/reports/project-harness-e2-20260809` passed all nine E2 gates. Its
manifest SHA-256 is
`a21bc6d9cecb0da6ad71f830626e54a308e2b294b3c582323cdb93cfe1504b35`;
candidate identity is
`7b80afc89f841ac2f360f3e728f4d92dfe913e59885a4dd481f1bcb3cc6740d5`;
promoted bundle identity is
`d57ad4f1b891d900e72d6145428bd63cec752105f546c465a153a14694894c4c`.
Provider requests and paid cost were both zero. This permits the claim that
the governed correction-to-production lifecycle works for the bounded pilot.
It still does not establish semantic generalization, model-task benefit or
cache preservation; those remain E3 outcomes.

Report rule growth and maintenance cost as well as task success; a safer
Harness that destroys context/cache reuse or consumes more maintenance budget
than it saves is not an improvement.

This control plane never changes the provider-visible Conversation, system
prompt, tool schema, or tool ordering. Its journal and sidecar artifacts live
beside the session and are consumed by the host, so a promoted project rule
does not invalidate the model's warm prefix merely by being observed or
checked. Cache-prefix drift remains a release regression gate.
