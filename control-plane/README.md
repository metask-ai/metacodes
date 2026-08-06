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

`build.test-throughput-integrity.l2` is the build/test slice. It keeps performance
work inside the same feedback discipline without pretending that a theorem can
predict host wall time. Zig and the operating system measure wall/CPU/RSS;
Lean decides whether the measurement came from an admissible test topology.
Its five fixed obligations are:

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
  negative-harness, and full-test paths remain separately callable.

`buildTestSignal` fixes that surface at 5/5. The sensor also refuses aggregate
inventory shrinkage below the measured 2026-08-06 baseline of 67 files. Real
feedback runs the negative shard harness, the four-shard core graph, and the
single-process aggregate integration graph, then re-observes all test sources.
A lower elapsed time with missing coverage, hidden failure/leak semantics, a
changed source graph during measurement, or a weakened 4/4 adapter is blocked.
Cold and warm measurements must still be labelled separately in experiment
data; Lean validates the governance facts supplied by sensors, not the
physical truth of an unobserved cache claim.

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

The full run always writes `zig-out/reports/rule-control.json` before returning a blocked exit status. The report contains both observations, Lean decisions, counterexample verdicts, Zig feedback results, source hashes, violations, and remediation context.

## Adding a rule

Add a versioned entry to `rules.json` with all six links, implement a deterministic sensor that emits small facts rather than asking Lean to parse the repository, state the policy in `MetaCodesControl/`, and add both positive and negative fixtures. A rule must demonstrate:

- its decision function is the one proved in Lean;
- a representative repository violation reaches the sensor;
- the Lean signal blocks that violation;
- the actuator is observed in the real build and CI path and has an observable effect;
- a successful correction is re-observed before release;
- removing any loop link creates a blocked formalization orphan.

`sorry`, `admit`, and `axiom` are rejected by the controller. Sensor/schema mismatch, missing Lean, failed proof build, missing telemetry, failed or skipped Zig tests, unstable re-observation, and malformed reports all fail closed.
