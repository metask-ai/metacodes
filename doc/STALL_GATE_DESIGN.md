# Stall gate: in-run zero-information-gain breaker

Status: implemented (`src/core/stall_gate.zig`, Lean mirror
`control-plane/lean/MetaCodesControl/StallGate.lean`).

## Problem

The kernel governs safety and resources but had no in-run notion of
progress. The only behavioural backstop was `Options.max_turns = 400`. Runs
on long-context, flash-class models do not loop by sending malformed calls.
They loop by taking steps that return nothing new: polling a job that prints
nothing, re-running a command and getting identical output, or re-reading
something that has not changed. Soft reminders do not stop this. On
glm-5.3-flash at 400K–850K context, 76% of `[progress update]` nudges were
ignored.

Every tool call's input and result are already hashed for the observation
journal (`tool_exec.zig` `input_sha256` / `result_sha256`), but nothing read
those hashes during a run.

## Shape

The gate is modeled on `progress_updates.zig` (state, policy, bound, host
opt-in, terminal record) and on `check_gate.zig`, whose `streak` already
counts consecutive same-fingerprint failures.

### State

`stall_gate.State` is a value type with no allocator. The agent loop
heap-allocates it only when the gate is armed, because the memory is tens of
KB.

| field | meaning |
|---|---|
| `memory` | Novelty memory. Up to `SEEN_CAPACITY` (512) 64-bit evidence keys, each anchored to the newest tool_result block that carried it; least recently touched is evicted first. |
| `stretch` | A ring of `STRETCH_CAPACITY` (32) call keys, plus tool names for the report, holding the calls of the current stale stretch. |
| `stale_rounds` | Consecutive stale rounds. |
| `decisions` | Decisions so far, at most `MAX_STALL_DECISIONS` = 1. |
| counters | Rounds, progress rounds, peaks and forgotten keys, for the terminal record. |

### Sensor (once per executed tool round, after `executeSlots`)

A slot counts only if it ran (`decision == .run`, not pending, content
present). Denied, deferred and suspended slots never ran. This is the same
rule as the delivery-cadence and check-gate sensors.

Each counted slot yields:

* **call key** = `H(tool ‖ 0 ‖ input)`, appended to the stretch.
* **evidence key**:
  * An error result has none, because an error is not a non-error result.
  * A realized file mutation gets `H('A' ‖ tool ‖ 0 ‖ input)`. This is the
    action itself. The acknowledgement text carries nothing the model did not
    choose, and two different edits can return byte-identical
    acknowledgements, which would wrongly look like a repeat.
  * Any other result gets `H('O' ‖ tool ‖ 0 ‖ normalize(content))`.
    `normalize` drops the digits of numeric fields that are the host's own
    bookkeeping, not facts about the job; the field names stay in the key.
    These are BashOutput's `waited_ms` and its poll guard's
    `low_yield_polls` and `min_wait_ms`. Since #235 the guard raises the
    first and doubles the second on every low-yield poll, so all three change
    on every poll of a job that prints nothing. Without the normalization,
    each such poll would hash as new and the gate could never see a stuck
    one, guarded or not. The rest of the result is about the job and stays in
    the key: `returned_on`, `poll_guard.until`, the guard `note` (fixed per
    mode), the byte counters, and `pattern_searched_to`. A test in
    `tools/bash_output.zig` renders guarded polls with the tool's own writers
    and pins this split, so a new counter there cannot silently blind the
    gate.

A round is classified as:

* **progress** if some evidence key is not in `seen`;
* **stale** if it has counted slots but none is novel;
* **neutral** if nothing ran.

A novel key is admitted to the memory. A remembered key is refreshed.
Progress resets `stale_rounds` and clears the stretch. Stale adds 1 to
`stale_rounds`. Neutral changes nothing.

**The memory follows the view.** Novelty is relative to what the model can
still see, so re-reading a result that compaction removed is legitimate.
After the round's results are committed, every key the round touched is
anchored to its block in that message: message index, block index, and the
content slice's pointer and length. Before the next round, any key whose
anchor no longer holds is forgotten:

* the message fell behind the compaction boundary;
* the message is gone;
* the block's bytes were replaced (microcompaction clears and truncation
  both rewrite the slice).

Resetting everything on any reduction was considered and rejected. At
400K–850K context the conversation sits between the microcompact and
auto-compact thresholds, and microcompaction clears every result but the last
two, one more each round. A global reset would blind the gate in exactly the
regime it exists for. Anchoring to the *newest* copy keeps a tight loop stale
there, because its newest answer is always among the two kept.

**Exclusions.** The brief asked to exclude legitimately idempotent reads.
Here a repeat is excluded by its result, not by its tool name: re-running
tests after an edit, re-reading an edited file, or polling a job whose output
grew all return a new result, so the round is progress. Only an identical
answer counts against the run. The `(tool, result_sha)` window from the brief
is subsumed by `seen`: a result repeated inside any window is by definition
not novel.

### Policy (pure, `State.decide`, Lean `decide`)

```
none      if decisions ≥ MAX_STALL_DECISIONS
none      if stale_rounds = 0                          -- for ANY thresholds
repeating if stale_rounds ≥ repeat_rounds ∧ max_repeat(stretch) ≥ repeat_calls
stale     if stale_rounds ≥ stale_rounds_threshold
none      otherwise
```

The defaults are `repeat_rounds = 4`, `repeat_calls = 4` and
`stale_rounds = 8`.

* **Repeating** means the same call has returned an already-seen answer four
  times in a row (five identical calls in all, since the first was novel).
* **Stale** means eight rounds in which everything returned had already been
  seen, or failed.

The explicit `stale_rounds = 0` guard is what makes "a progress round is
never followed by a firing" hold for every configuration, rather than only
for well-chosen thresholds.

### Actuation: end the run with `StopReason.stalled`

Of the three options in the brief, ending the run is the only one whose
effect does not depend on the model complying:

* **Text** (another nudge) was measured at 24% compliance in this regime.
* **Restricting `tool_choice` for a turn** is advisory at compatibility
  gateways (see the comment above `conversationHasSuccessfulRequiredFirst` in
  `agent_loop.zig`). Changing it also invalidates the provider's message
  cache, and at 400K–850K context that is the most expensive miss available.
* **Requiring a plan or prediction before the next call** is gameable with
  one filler sentence. It would still need a terminal actuator behind it.
* **Host-side suppression of the repeated call** is evaded by perturbing one
  input byte (for example `wait_ms` 30000 → 30001).

Stopping hands the decision back to the one party who holds the global
intent, the same rule the environment-fault breaker follows. A false
positive costs one message from the user ("continue", or a new direction),
and the conversation is intact. A false negative costs up to 400 rounds at
full context.

The run ends after the round's results are committed to the conversation,
so a resumed run sees all the evidence. No host text is appended, so
provider-visible bytes are unchanged. `RunResult.stall` carries a value-type
report (cause, stale rounds, most-repeated tool and count).

| host | behaviour |
|---|---|
| REPL | prints the report and how to continue |
| headless | emits `"stop_reason":"stalled"`, exit code 0 (controlled stop, like `tool_loop`) |
| AgentCore ABI v1 | projects to `STOP_TOOL_LOOP`; the frozen wire enum does not grow |

### Bounds

* At most one decision per run. In enforce mode the decision ends the run.
  In observe mode the run continues and the record names the round where an
  enforced run would have stopped.
* No host injection, so `host_injection_meter` and its pinned cap are
  untouched.
* State is fixed-size: 512 remembered keys and 32 stretch entries.
  Forgetting (eviction, a block leaving the view, a key with no block) only
  makes keys look novel, so every approximation errs toward silence.

### Opt-in

`agent_loop.Options.stall_gate: ?stall_gate.Mode = null`, the same
host-contract shape as the sibling gates. Canonical `buildRunOptions` leaves
it off, so macro, skill and subagent runs are never stopped.

| host | default | flags |
|---|---|---|
| interactive REPL, web session | enforce (a person is present to resume) | `--no-stall-gate` turns it off; `--stall-gate-observe` records only |
| headless | off, because evaluation rollouts run there and their stop-reason sets are fixed | `--stall-gate` / `--stall-gate-observe` opt in |

When the gate was armed, one terminal `stall_gate` observation record is
written per run (`metacodes-stall-gate-v1`, validated by
`scripts/eval/workbuddy/trace.py`).

## Proofs (Lean mirror)

`StallGate.lean` transcribes the sensor's round classification over abstract
keys, the bounded call window and the policy. It models every way the memory
forgets (eviction, the view, unanchored keys) as an adversarial `forget`
event. It proves the following, using only `propext`:

* `decisions_bounded`: over any trace of rounds and forget events,
  `decisions ≤ maxDecisions`;
* `fresh_rounds_never_fire`: if every round carries an evidence key the
  gate's memory does not hold, no decision is ever made;
* `new_rounds_never_fire`: the same holds when every round carries a key that
  occurs in no earlier round, because memory ⊆ history however it forgets;
* `stale_stretch_fires`: the positive side. From a fresh budget, enough
  consecutive stale rounds always produce exactly one decision.

The constants `maxDecisions`, the default thresholds and the call-window capacity are
lockstep-checked against the Zig source and the trace parser by
`scripts/eval/tests/test_delivery_cadence_constants.py`.

## Known limits

* **Hash novelty is syntactic.** Near-identical experiment scripts whose
  outputs differ by a timestamp, or a job that prints a progress byte per
  poll, are new results to this gate.
* **Progress output is fixed in the tool, not here.** #235 removed
  BashOutput's any-byte wake-up: it waits for the exit by default, and its
  poll guard stops progress bytes from waking low-yield polls. A job that
  prints something new on every poll is still new to this gate. That is
  correct, because it is information, and the tool now makes such polls
  rare.
* **Semantic stagnation** (different edits, same failure) needs the TinyKG
  hypothesis ledger and JEV relation judging, which come later.
* **Deliberate repetition** (running a flaky test eight times, one call per
  round) trips the stale tier. Run it inside one command, or resume with one
  message.
