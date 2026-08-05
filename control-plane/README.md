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
4. `actuator`: a fail-closed release gate with remediation;
5. `feedback`: real Zig tests followed by re-observation;
6. `counterexample`: executable pass/block fixtures, including a formalization orphan.

Missing any link makes `Topology.complete = false`. The same Lean function used by the gate then returns `block_release`; Python does not reimplement the policy.

## Current vertical slice

`declaration.agentdef-task-required.l2` governs the runtime fields from `AgentDef` plus the required fields of the `Task` tool. The sensor derives declarations from Zig source and validates exact evidence bindings in `declaration-l2-evidence.json`:

- the component test exists and its exact `L2 ...` test name exists;
- configured observable/assertion markers occur inside that test;
- the test has a `std.testing` expectation;
- the test file is wired into `build.zig`;
- every governed declaration has exactly one binding;
- every exclusion is explicit, classified, and justified.

Static evidence is not enough. Lean first returns `run_feedback`; the controller runs its own fail-closed sensor tests and the focused Zig component tests, rejects non-zero exits and non-zero skipped-test summaries, observes the repository again, and only then asks Lean for the final decision. A changed sensor fingerprint during feedback blocks the run and requires a retry.

The first slice intentionally does not claim that all repository rules are formalized. Existing exclusions are visible debt, not silent coverage. New rule families should be added incrementally after this loop is stable.

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
- the actuator has an observable effect;
- a successful correction is re-observed before release;
- removing any loop link creates a blocked formalization orphan.

`sorry`, `admit`, and `axiom` are rejected by the controller. Sensor/schema mismatch, missing Lean, failed proof build, missing telemetry, failed or skipped Zig tests, unstable re-observation, and malformed reports all fail closed.
