# Development rule control plane

This directory turns selected development rules into executable feedback loops. Lean is the decision kernel, not a parallel specification:

```text
repository state
  -> versioned sensor observation
  -> Lean pre-feedback signal
  -> Zig L2 feedback actuator
  -> repository re-observation
  -> Lean release decision
  -> enforced / blocked report
```

A rule is enforced only when all six links are valid:

1. `target`: a measurable setpoint or invariant;
2. `sensor`: versioned facts observed from real repository files;
3. `decision`: the Lean kernel and named theorems governing its behavior;
4. `actuator`: an observed fail-closed build/CI release gate with remediation;
5. `feedback`: real Zig tests followed by re-observation;
6. `counterexample`: executable pass/block fixtures, including a formalization orphan.

Missing any link makes `Topology.complete = false`. The same Lean function used by the gate then returns `block_release`; Python does not reimplement the policy.

## Current vertical slices

`declaration.agentdef-task-required.l2` governs the runtime fields from `AgentDef` plus the required fields of the `Task` tool. The sensor derives declarations from Zig source and validates exact evidence bindings in `declaration-l2-evidence.json`:

- the component test exists and its exact `L2 ...` test name exists;
- configured observable/assertion markers occur inside that test;
- the test has a `std.testing` expectation;
- the test file is wired into `build.zig`;
- every governed declaration has exactly one binding;
- every exclusion is explicit, classified, and justified.

Static evidence is not enough. Lean first returns `run_feedback`; the controller runs its own fail-closed sensor tests and the focused Zig component tests, rejects non-zero exits and non-zero skipped-test summaries, observes the repository again, and only then asks Lean for the final decision. A changed sensor fingerprint during feedback blocks the run and requires a retry.

The actuator is also sensed, not trusted from `rules.json`. The controller must observe the `rule-check` Zig build dependency, the live `rule-control` CI job, its exact gate command and working directory, and an `always()` upload of the exact telemetry path that fails when the report is missing. It re-observes those files after feedback. Removing or disabling any executable link sets `Topology.actuator = false`, so the Lean kernel blocks before tests can masquerade as a release gate.

This repository-local sensor proves wiring through the CI check. Whether a hosting service's branch-protection policy marks that check as required is external state and must be audited separately; this control plane does not claim to formalize an unobserved server setting.

The first slice intentionally does not claim that all repository rules are formalized. Existing exclusions are visible debt, not silent coverage. New rule families should be added incrementally after this loop is stable.

`memory.evidence-freshness-governance.l2` is the second slice. Its dedicated
`memory_evidence_governance` adapter does not accept an evidence registry that
can certify itself. It observes fixed production paths and requires three
executable obligations:

- automatic recall renders each hit's real `node_id`, so `KgContext(node_id)`
  is callable without a second lexical guess;
- the system prompt and actual tool schema carry the candidate-only,
  provenance, evidence, supersession, contradiction, and current-state-check
  contract into a captured API request;
- `KgContext` derives a versioned `knowledge_governance` object from TinyKG
  node metadata plus the bounded graph, including historical-node omission,
  `deprecated_by`, evidence counts, truncation, and unknown freshness.

The feedback actuator runs `test:kg-governance` against a real TinyKG process.
Sensor unit tests remove the runtime ID, leave governance words only in a
comment, and disconnect the focused build step; each mutation is observed as a
deviation. Lean sees the same obligation counts, returns `run_feedback` only at
3/3, and admits release only after the focused feedback passes and the exact
source fingerprint is re-observed unchanged. Thus the prose describes the
loop, but cannot substitute for it.

`ontology.execution-grounded-projection.l2` is the third slice. It closes the
gap between model narration and repository reality with three independently
observed obligations:

- after permission and successful execution, the host resolves exactly one
  claimed `kg-*` task and records only bounded relation/resource labels;
  denied, pending, failed, ambiguous-task, raw command/query/body, and tool
  output paths are excluded;
- terminal `TaskUpdate`/`TaskStop` merges explicit fields with the host ledger,
  writes tentative ref edges, acknowledges only successful projections, and
  returns projected/failed/dropped/retained counts so partial writes can be
  retried instead of disappearing in logs;
- `test:kg-ontology-feedback` drives a real TinyKG process through claim,
  `tool_exec.executeSlots`, and terminal `TaskUpdate` without model-supplied
  ontology fields, while proving denial/failure exclusion, privacy, and task
  isolation.

The adapter reads the production call chain and focused build wiring after
stripping comments. Its negative fixtures disconnect the tool-exec sensor,
replace runtime markers with comments, bypass TaskUpdate consumption, and
remove the build dependency. Feedback with a non-zero exit or any reported
skip is also rejected. Lean fixes this slice at three obligations and proves
that admission entails coverage of all three. The actual runtime kernel is
`executionProjectionSignal`, which blocks a weakened 2/2 sensor before
feedback; the controller rejects substituting the generic kernel for this
rule. A manifest or prompt cannot manufacture an observed execution fact.

`ontology.experience-feedback.l2` is the fourth slice and closes the read side
of that ontology loop. It fixes five non-substitutable obligations:

- the claimed task text drives one bounded exact BM25 probe with `kind=task`
  pushed into TinyKG before truncation; this is
  explicitly lexical, and an empty result is not treated as proof of absence;
- only current-generation completed tasks with current verification evidence
  and untruncated task/neighbor packets can contribute associations, while
  tentative and confirmed edge states remain distinct;
- the packet is appended at the unified successful `TaskUpdate` result boundary
  after claim, and again when `TaskGet` recovers a claimed task after restart or
  compaction, before the next model request can perform work;
- because TinyKG has no vector search, the system and task contracts require the
  model to derive 2-4 separate semantic variants when the exact probe is
  insufficient, while the host executes that fixed batch, deduplicates node ids,
  and keeps recalled text as untrusted data;
- `test:kg-experience-feedback` drives a real TinyKG process and proves that a
  verified completed task enters the new claim result, while an unfinished
  lexically close decoy is rejected, then proves the packet is serialized into
  the next provider request while bounded paper telemetry is emitted.

The adapter derives these obligations from fixed production paths after
stripping comments. Its negative fixtures remove the retrieval source, weaken
the lifecycle/evidence gate, disconnect the tool-result actuator, remove the
semantic-expansion contract, leave the same words only in comments, and remove
focused build wiring. Lean fixes this slice at five obligations through
`experienceFeedbackSignal`; even a self-consistent weakened 4/4 sensor is
blocked, and the controller rejects the
generic three-obligation kernel for this rule. This proves that persisted
ontology edges reach a later decision surface; it does not claim that a
candidate changed the model's chosen action or improved task quality, which
requires controlled rollout evidence.

`build.test-throughput-integrity.l2` is the build/test slice. It keeps performance
work inside the same feedback discipline without pretending that a theorem can
predict host wall time. Zig and the operating system measure wall/CPU/RSS;
Lean decides whether the measurement came from an admissible test topology.
Its seven fixed obligations are:

- a diagnostic runner reports every compiled test, slow buckets/top-N, total
  time, failures, skips, and allocator leaks with checked duration arithmetic;
- deterministic process shards reset per-test allocator/I/O state and carry a
  versioned name partition plus full/selected commutative fingerprints;
  captured reports are explicitly side-effecting so a later gate cannot reuse
  an earlier successful execution from Zig's build cache;
- the aggregate verifier rejects duplicate/missing shards, count drift,
  fingerprint drift, failures, leaks, malformed time, and arithmetic overflow;
- component/integration source inventory is scanned at build-graph creation,
  every aggregate test is imported exactly once, and the dedicated AgentCore
  ABI test remains on its independent artifact gate;
- `dev` installs only Debug for the edit loop; `dev:full` explicitly adds
  TinyKG without ReleaseSmall, while the monolithic, sharded, timing,
  negative-harness, and full-test paths remain separately callable;
- shipped TinyKG artifacts strip location-bearing debug symbols, and a real
  feedback test concurrently rebuilds the same source with different-length
  cache/prefix paths, requires byte-identical SHA-256 results, then executes
  both binaries. A source-order claim or a single successful build is not
  reproducibility evidence.
- the formal checker publishes a time-independent v3 artifact manifest and a
  separately hashed, time-bearing build receipt. Two complete builder runs
  must produce identical executable bytes, manifest bytes, and artifact
  fingerprints; the runtime still requires, binds, and rehashes the full
  receipt so excluding build time from treatment identity does not weaken
  tamper detection.

`buildTestSignal` fixes that surface at 7/7. The sensor also refuses aggregate
inventory shrinkage below the measured 2026-08-06 baseline of 67 files. Real
feedback runs the negative shard harness, the four-shard core graph, and the
eight-shard fail-closed aggregate integration graph plus the isolated TinyKG
double build and complete formal double build, then re-observes all test
sources. The monolithic and per-test
timing paths remain explicit diagnostic gates rather than taxing every release.
A lower elapsed time with missing coverage, hidden failure/leak semantics, a
changed source graph during measurement, or a weakened 6/6 adapter is blocked.
Cold and warm measurements must still be labelled separately in experiment
data; Lean validates the governance facts supplied by sensors, not the
physical truth of an unobserved cache claim.

`eval.budget-checkpoint-durability.l2` governs the paid long-horizon runner's
failure ordering. `DurableAbort.lean` defines the reusable four-phase state
machine and `BudgetCheckpoint.lean` applies it to runtime budget violations:

```text
observed → invalidMarked → checkpointCommitted → aborted
```

There is no legal transition from `observed` or `invalidMarked` directly to
`aborted`. Lean proves that reaching `aborted` requires a committed checkpoint,
that publication requires the invalid marker, that the canonical trace reaches
the terminal state, and that `markInvalid → abort` is rejected. The repository
sensor then binds that model to six real obligations: identical two-dimensional
caps for every arm/order position, full remaining-schedule capacity before
network, normalized usage bound to the sealed cap, invalid marking before
publication, publication before the raised abort, and promotion-time
revalidation of the same cap and usage.

This rule intentionally requires a disk-backed counterexample: the feedback
creates an over-cap rollout, observes `run_multi_arm` raise, then reloads the
checkpoint and verifies its invalid reason. Static source order or a pure
marker-function unit test cannot satisfy the rule. A separate counterexample
proves an infeasible complete schedule invokes no paid runner, and promotion
tests reject both cap drift and measured overrun. The Python L2 is still
actuated by the same Lean-backed `rule-check` build/CI release gate and is
re-observed before admission.

Here “committed” means the writer validated every row, flushed and `fsync`ed a
same-directory temporary file, atomically replaced the checkpoint, returned,
and the caller could reload it after the process-level abort. The rule does not
claim power-loss durability of the parent directory on every filesystem.

`eval.treatment-activation.l2` governs whether the three-arm experiment really
activated the mechanism it claims to compare. Its eight fixed obligations bind
the treatment prompt to the TinyKG arm only; require exact native-event and
transcript call identities/hashes; admit one create→claim→complete lifecycle
only after frozen-binary `task-packet` readback and `verified_by` evidence; use
the shared durable-abort protocol for attestation failures; reverify checkpoints
before resumed paid work; recompute receipts from raw artifacts during
promotion/reporting; retain real TinyKG plus mutation counterexamples; and
require multi-invocation native traces plus cryptographic commitments for tool
results removed from the model-facing context.

Native `sequence` is intentionally local to one agent-loop invocation, while a
single scored rollout can append several invocations. The attester therefore
proves contiguous invocation ids and per-trace sequences before deriving one
append-order lifecycle. Context clearing/truncation may replace result bytes in
the model projection, but it must preserve the original byte count and SHA-256;
the unauthenticated legacy placeholder is rejected. A real `run_multi_arm`
counterexample checkpoints a three-invocation baseline receipt, so a single-run
fixture or helper-only parser test cannot satisfy this obligation.

The treatment failure feedback exercises both halves of the storage boundary.
One real `run_multi_arm` test injects an attestation failure, observes the raised
error, and reloads the invalid JSONL checkpoint. A second makes checkpoint
publication itself fail and proves that storage error wins: the original
treatment abort cannot pass an uncommitted checkpoint. Resume tests prove zero
next runner calls when raw artifacts no longer attest, while promotion rereads
all 18 calibration rollouts and rejects transcript mutation. Thus Lean owns the
legal ordering and admission cardinality, while executable sensors establish
the actual I/O and TinyKG facts represented by those abstract events.
The feedback topology also requires `python3 scripts/verify_tinykg_binary.py`
before the Python L2 command. A clean checkout verifies the native target from
the checked-in manifest-pinned bundle; maintainers may instead inject an explicit
binary path and observed SHA-256. Neither route can turn missing native coverage
into a machine-local skip or silently consume an ambient artifact.

`eval.memory-local-store-isolation.l2` makes the memory-benchmark storage
boundary a release rule rather than a convention. Its seven fixed obligations
require:

- direct invocation of an explicit hash-pinned TinyKG binary, with no import
  or execution path through the TinyKG skill harness;
- a sealed child `HOME`/temporary directory and removal of every `TINYKG_*`
  and ambient `METACODES_KG_*` variable, including both Skill-remote and
  Metacodes-daemon URL/key/build/config authority, before injecting the
  explicit isolated CLI binding;
- a previously absent run directory whose stores, batches, home, temporary
  files, and output remain below that owned directory;
- an unnormalized digest of every non-lock store file and directory before and
  after search, traversal, and store inspection, independently of the
  normalized logical graph revision used for reproducible trace identity;
- graph-materialization tests for HotpotQA, LongMemEval-S, and coding
  procedural transfer, plus a real vendored-TinyKG test that poisons remote
  configuration, preserves external sentinels, and rejects read-time writes,
  binary drift, preexisting runs, and output escape;
- one provenance-complete pinned native trace for each adapter, including
  binary/source/manifest/batch/graph/trace identities and explicit zero counts
  for skill-harness calls, remote API calls, and remote-store writes.

`memoryIsolationSignal` fixes this surface at 7/7, so a weakened 6/6 sensor is
blocked even if its surviving checks agree. Feedback first builds the vendored
TinyKG binary, then runs both the sensor counterexamples and the real local
TinyKG module; any native-environment skip is treated as failure. The
repository and actuator are re-observed before the final Lean decision. This
rule proves the observed execution boundary and fail-closed tests—it does not
turn a smoke trace into evidence of memory quality.

`eval.paid-budget-journal-authorization.l2` governs the current production
memory pilot's single-machine paid-request boundary. It intentionally does not
model a future cross-machine swarm lease and does not introduce SQLite or a
second memory store. Its nine fixed obligations cover the hash-chained journal
state machine and complete identity, durable authorization publication, one
exclusive runner lock around credential and schedule access, the real
authorization-before-provider call chain, both authorized crash windows,
two-dimensional exposure and exact commit replay, fail-closed file/CAS checks,
checkpoint-bound receipts plus explicit paid-schedule resume, and dry-run plus
one-physical-attempt regressions. Resume accepts only a fully revalidated
contiguous rollout prefix whose live journal exactly matches the recorded
revision/head; rejected resume runs fail before credential loading, and an
extra authorized or committed transaction is never replayed.

`PaidBudgetJournal.lean` proves the legal lifecycle, authorized maximum
exposure, no authorized rollback/re-authorization, exact committed replay,
provider denial without a matching persisted authorization receipt, complete
identity/authority binding, and cost/token authority preservation for accepted
transitions. The repository sensor and L2—not Lean—establish that the host uses
POSIX `flock`, calls `fsync`/atomic rename/parent `fsync` in the observed order,
and reaches the provider only after that code path. A loopback MockServer opens
the on-disk journal when the request arrives; fault injection covers crashes
both immediately after authorization and after provider return but before
commit. Recovered authorized requests retain maximum exposure and cannot be
implicitly retried. A separate post-commit fault test proves that already
checkpointed rollouts are skipped, while the commit-to-checkpoint ambiguity is
detected and blocked rather than claimed recoverable. The rule is a release
gate for the pilot mechanism, not proof of filesystem power-loss semantics or
memory quality.

`tinykg.daemon-transport.l2` governs how Metacodes shares TinyKG: every process
must use the Metacodes-owned local authenticated, build-pinned Web transport to
one daemon-owned StoreActor — never the remote TinyKG Skill configuration and
never a shared raw-Store fallback. Its sensor is the real two-process L2 in
`scripts/test_kg_daemon_transport.py` (session-pinned schema, generation-bound
queries, zero transport-level write retries, the cross-session ambiguity fence,
and content-bound Markdown uploads).

This section enumerates every active rule; keep it in sync with
`control-plane/rules.json` when adding or retiring one.

## Commands

From `metacodes/`:

```bash
# Human/machine sensor output; non-zero means missing or invalid evidence.
scripts/test_coverage_audit.sh
scripts/test_coverage_audit.sh --json

# Full control loop through a Zig build entry point.
zig build --build-file control-plane/build.zig rule-check

# Control-plane unit tests only.
zig build --build-file control-plane/build.zig test

# Direct equivalent, useful for diagnostics.
python3 scripts/rule_control.py check
```

The main build's `zig build test` runs the same unit tests (as `test:rule-control`), including an observation of every rule in `rules.json` against the checked-in tree, so a change that moves code a sensor reads fails in its own pull request. Lean decisions, counterexamples, and feedback replay run only in `rule-check`.

The full run always writes `zig-out/reports/rule-control.json` before returning a blocked exit status. The report contains both observations, Lean decisions, counterexample verdicts, Zig feedback results, source hashes, violations, and remediation context.

## Adding a rule

Add a versioned entry to `rules.json` with all six links, implement a deterministic sensor that emits small facts rather than asking Lean to parse the repository, state the policy in `MetaCodesControl/`, and add both positive and negative fixtures. A rule must demonstrate:

- its decision function is the one proved in Lean;
- its sensor closes on the checked-in tree, not only on fixtures written to match it;
- a representative repository violation reaches the sensor;
- the Lean signal blocks that violation;
- the actuator is observed in the real build and CI path and has an observable effect;
- a successful correction is re-observed before release;
- removing any loop link creates a blocked formalization orphan.

`sorry`, `admit`, and `axiom` are rejected by the controller. Sensor/schema mismatch, missing Lean, failed proof build, missing telemetry, failed or skipped Zig tests, unstable re-observation, and malformed reports all fail closed.
