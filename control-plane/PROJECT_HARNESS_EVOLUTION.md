# Project-specific Harness Evolution

Status: design contract plus grounded observation, durable journal, authentic
source receipt, immutable candidate, and non-authorizing lifecycle-evidence
pilots. This document does not claim that automatic Lean rule evolution or
runtime bundle admission is already implemented.

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

Implemented in the first pilot:

- `tool_exec.executeOne` emits start/finish observations around actual dispatch;
- observations are independent of UI projection and work at nested depth;
- observer rejection before dispatch prevents the dispatcher call;
- observer rejection after an effect poisons the Run instead of reporting an
  unobserved success;
- Write/Edit can publish `file_mutation_v1` evidence;
- synchronous subagents and TaskBatch inherit the observer;
- an L2 test covers model tool use through the real Write dispatch.

Implemented in the second pilot:

- normal TUI, headless, and suspended-resume Runs append observations to a
  session-side JSONL artifact outside the prompt and model-facing cache prefix;
- each complete record crosses a checked file-fsync boundary before the sink
  acknowledges it; this does not claim to prove filesystem power-loss semantics;
- an exclusive run lease rejects concurrent writers and is deliberately left
  behind after an unclosed Run so crash recovery requires explicit audit;
- replay admission checks session/run identity, sequence, run lifecycle, and
  exact start/finish pairing for every tool dispatch;
- corrupt, partial, oversized, semantically incomplete, or concurrently owned
  artifacts fail closed before tool dispatch.

Implemented as a proposal-only third pilot:

- `RuleCandidate` files are immutable and content-addressed beside the session;
- `user_correction`, `agent_reflection`, and `runtime_counterexample` remain
  distinct source variants rather than a mutable authority flag;
- reflections must carry a falsifier and bind an exact completed observation
  interval whose digest remains stable as later Runs append to the journal;
- candidate Lean source is bounded and persisted as untrusted input only;
- this API cannot build, promote, load, grant permission, or change prompts.

Implemented as a non-authorizing fourth pilot:

- `user_correction` requires a host-issued, content-addressed receipt grounded
  in an exact durable user transcript line; a source label alone is rejected;
- `runtime_counterexample` requires a completed observation interval and a
  blocked formal verdict receipt;
- build, axiom-audit, replay, shadow, rejection, promotion, and supersession
  evidence have immutable typed receipt schemas and exact predecessor links;
- a per-candidate cross-process lease plus durable head rejects concurrent or
  stale branches; a crash after receipt publication leaves the lease fail
  closed for explicit audit rather than silently advancing another branch;
- build/audit/replay/shadow evidence enforces bounded isolation, independent
  actors, positive and negative replay cases, and side-effect-free shadowing;
- the public proposal-side API cannot create `promoted` or `superseded`
  receipts. Those transitions remain reserved for the independent Lean
  admission path and therefore still have no runtime authority.

Not yet implemented:

- a hash-chain/receipt binding the observation journal to transcript and
  promoted rule candidates (the journal is durable evidence, not yet a receipt);
- journal ownership in Web/daemon/skills adapters;
- stable observer ownership for detached background subagents whose lifetime
  exceeds a synchronous Run;
- authoritative adoption/discard disposition for a speculative prefetch after
  the completed model turn is known;
- persisted build logs, compiled artifacts, axiom outputs, replay corpora, and
  shadow traces behind the hashes carried by lifecycle receipts;
- isolated candidate Lean compilation, replay, shadow, and promotion;
- independent Lean creation of promotion/supersession receipts;
- a project bundle loader or runtime verdict gate;
- TinyKG atomic MemoryMigration commit/rollback integration.

Consequently, the current milestone is a grounded observation and immutable
proposal foundation, not yet a self-evolving formal Harness.

## Evaluation and paper data

Retain event counts, dropped/rejected events, effect coverage by tool and depth,
observer latency, candidate source, correction/reflection provenance, build and
axiom-audit outcomes, replay false-positive/false-negative cases, shadow
divergences, promotion/rejection reasons, bundle hashes, runtime blocks, and
post-action re-observation results.

Compare at least:

1. no project rules;
2. static hand-written rules;
3. governed project-evolved rules.

Use matched tasks, models, tool/token/cost caps, and isolated local TinyKG data
for memory benchmarks. Report rule growth and maintenance cost as well as task
success; a safer Harness that destroys context/cache reuse or consumes more
maintenance budget than it saves is not an improvement.
