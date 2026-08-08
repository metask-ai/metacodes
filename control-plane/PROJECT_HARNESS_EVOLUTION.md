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
| runtime checker calls/latency, blocks/faults | journal `formal_decision` events |
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

Compare at least:

1. no project rules;
2. static hand-written rules;
3. governed project-evolved rules.

Use matched tasks, models, tool/token/cost caps, and isolated local TinyKG data
for memory benchmarks. Report rule growth and maintenance cost as well as task
success; a safer Harness that destroys context/cache reuse or consumes more
maintenance budget than it saves is not an improvement.

This control plane never changes the provider-visible Conversation, system
prompt, tool schema, or tool ordering. Its journal and sidecar artifacts live
beside the session and are consumed by the host, so a promoted project rule
does not invalidate the model's warm prefix merely by being observed or
checked. Cache-prefix drift remains a release regression gate.
