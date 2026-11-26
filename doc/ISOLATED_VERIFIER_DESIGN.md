# Isolated verifier: a second verdict source for the check gate

Status: implemented on `main` for the in-run check gate and the end-of-run
host check, 2026-11-16 (design 2026-10-17); §12 lists what is implemented,
where it departs from this design, and what is still open. This is the
second of three borrowings from RSIAgent (AetherLabsAI/RSIAgent, arXiv
2609.15364). The first, the learning turn, is `doc/LEARNING_TURN_DESIGN.md`
and `packages/coding/src/core/learning_turn.zig`. When this design was written it lived in
[metask-ai/metacodes#292](https://github.com/metask-ai/metacodes/pull/292);
it has since reached `main`, but the verifier is not wired into it yet
(§12.3).

The RSIAgent properties this design borrows are the six named in §1.1. They
come from that repository's verifier charter
(`explore/charter.py`, `agent_harness_verifier_charter`) and its runtime
(`core/verifier_runtime.py`) as summarised when this work was commissioned.
Those files were not re-read for this design. Where metacodes departs from
them, the section says so.

## 1. Problem

Today a run has one verdict source: a check command that the host pins at
startup and runs itself. There are two places it runs:

- **In-run**, [`check_gate.zig`](../packages/coding/src/core/check_gate.zig) runs the pinned
  command when the model stops after a delivery-capable action. It classifies
  the result as `passed`, `failed`, `tainted` or `unavailable`. In enforce
  mode a clean failure continues the conversation.
- **At the end of a headless run**, [`host_check.zig`](../packages/coding/src/core/host_check.zig)
  runs `METACODES_HOST_CHECK` once. It files a `task-outcome-v1` row with
  provenance `host_run` or `host_run_tainted` (`verdict.composeOutcomesJson`).

The pinned check is deterministic and the model cannot rewrite it. Both
properties are what make it trustworthy. They also limit it: the check can
only see what it tests. The check-gate cohorts measured that limit
([check-gate-v3.md](../evals/experiments/check-gate-v3.md)):

- Across v1–v3, the baseline arm finished with the pinned check red in
  **0 of 23** rollouts.
- In v3, all **24** rollouts in both arms ended with the pinned check green.
  **8** of them still failed the full validator (cron 1, sheet 2, calc 1,
  ranges 4). Every one of those failures was a hidden case that the visible
  suite does not exercise.

So a green pinned check is the common case, and a large share of those greens
are false passes. The learning turn makes this more costly. A learning turn
grounded in such a verdict mostly distills lessons from false passes. Its
distill message can only say "a pass does not establish that every
requirement of the task was met" (`learning_turn.EVIDENCE_BOUNDARY`). It
cannot say *which* requirement is unmet.

RSIAgent names incomplete verification as a core failure mode. Its answer is a
Verifier Agent.

### 1.1 What is borrowed

| RSIAgent verifier property | Here |
|---|---|
| Fresh context | A new `Conversation` from `subagent.spawnAgentSink`, a frozen charter as its system prompt, and no memory (§2.1) |
| Cannot see the actor's transcript, handoff or memory | Withheld mechanically, not by instruction (§2.2) |
| Inspects a read-only or rollback-protected candidate | A disposable, git-isolated snapshot of the actor's working tree, bound to a tree id (§2.3) |
| Must find evidence that separates the required result from a nearby plausible substitute | A required evidence block that the host checks against the verifier's own tool calls (§3.2) |
| Returns a `VERDICT` token: PASS, FAIL or UNVERIFIED | Parsed only from the last line of the last assistant message (§3.1) |
| UNVERIFIED starts an actor-evidence-leads loop | One leads round, paid from the check gate's continuation budget (§6) |
| Infrastructure errors are never a verdict | `unavailable`, which falls back to the pinned verdict (§3.3) |

There is one deliberate departure: **the verifier can only demote.** A
verifier PASS adds no authority beyond the green pinned check it follows. A
verifier FAIL turns that green into a contested result (§4). This asymmetry
is the safety argument of the whole design (§8.2).

## 2. Mechanical isolation

The verifier is a subagent. The host spawns it in code at the check gate's
boundary. It is not an `AgentDef` that the `Agent` tool discovers from disk.
A project agent with the same name therefore cannot shadow it: `def.zig`
identifies agents by frontmatter `name`, and the verifier never goes through
that lookup. Its fields use `AgentDef`'s vocabulary (tools, model,
`max_turns`, `overrides`), but the host fixes the values.

### 2.1 Fresh context

`subagent.spawnAgentSink` already starts a child from an empty
`Conversation` plus one user message (`prebuilt_conversation = null`). The
verifier's `SpawnOptions` add the following:

| `SpawnOptions` field | Verifier value | Why |
|---|---|---|
| `system_prompt` | `VERIFIER_CHARTER`, a comptime constant; its SHA-256 goes in the record | Same charter on every run; charter drift shows up in the record |
| `prompt` | The verifier packet (§2.2) | The only user message |
| `kg` | `null` | `spawnAgentSink` would otherwise clone the parent's `KgClient` (`cloneForThread`). `KgRecall` and `KgContext` are not permanently disabled for subagents (`agents/filter.zig`), so they would reach outcome rows and lessons |
| `tool_defs_override` | `Bash`, `Read` | No file-writing tools, no `Agent`, no web or MCP tools, no Skills. `KgRemember` is permanently disabled for subagents anyway |
| `dyn_registry`, `mcp_sessions`, `host_services` | `null` | Skills and MCP servers can carry project memory and side channels |
| `read_state`, `file_change_journal`, `tool_result_metrics` | `null` (fresh) | Probe activity never enters the actor's read-before-write state or file-change evidence |
| `jobs`, `agent_jobs` | `null` | No background job outlives the verdict |
| `cwd_abs`, `project_dir` | The snapshot directory (§2.3) | |
| `resolve_relative_paths` | `true` | The same rule the `Agent` tool applies to a worktree-isolated child (`tools/agent.zig`) |
| `max_turns`, `cost_budget_usd` | §5 | |
| `model_override` | `--verifier-model`, else the actor's model | §8.1 |
| `overrides_override` | The parent's overrides with a distinct `prompt_cache_key` | §8.3 |
| `agent_depth` | 1 | |

### 2.2 What the verifier sees and what is withheld

The packet holds four things and nothing else:

1. **The task statement**: the user message that started this run, verbatim.
   In a headless run this is the run's prompt. In the REPL it is the user turn
   that opened the current Run. Earlier chat turns are excluded.
2. **The pinned check**: the command string and its counts ("passed 37/37").
   This tells the verifier what has already been established, so it looks
   past it.
3. **The snapshot**: its path, and the two refs `base` and `candidate` (§2.3),
   so `git diff base candidate` shows exactly what the run changed.
4. **Prior failing probes**: only at a second boundary, and only the probe
   commands from the previous verifier's FAIL (§6.2). This is
   verifier-to-verifier information, never the actor's.

The verifier never receives:

- the actor's transcript;
- the actor's final message (the handoff);
- the actor's task list;
- outcome rows, lessons or memdir notes (`kg = null`, and no memdir path);
- the learning turn's output;
- the actor's commit messages. The snapshot has two host-written commits and
  no history (§2.3), so `git log` cannot replay the actor's narrative.

The only channel from the actor to the verifier is the leads round (§6). It
is bounded, restricted to pointers, and marked as untrusted claims.

### 2.3 The candidate snapshot

`agents/isolation.zig` cannot be reused as it is. `Worktree.create` bases
the worktree on `git rev-parse HEAD`. The candidate the pinned check just
judged is the **working tree**, which is usually uncommitted. A worktree at
`HEAD` would grade the wrong code. It also shares the actor repository's refs:
a linked worktree that runs `git stash` or `git branch -D` writes the same
stash stack and branch namespace.

The snapshot takes the lifecycle shape of `Worktree` (create under
`<state_root>`, git through the same capped and timed spawn as
`isolation.gitOutput`, a `finalize` that reports cleanup) with three changes:

1. **Snapshot the working tree without touching it.** The host copies the
   actor's index file (`git rev-parse --git-path index`) to
   `<state_root>/verify/<id>/index` and runs, with that file as
   `GIT_INDEX_FILE`:
   - `git add -A`
   - `git write-tree` → **T**
   - `git commit-tree T` with a fixed host message → `candidate`
   - `git commit-tree` of the run-start `HEAD`'s tree with a fixed message
     → `base`, so `candidate`'s parent is `base`

   The actor's index, `HEAD`, refs and stash are never written. The object
   database only gains blobs and trees, which is append-only.
   - Tracked files and untracked files that are not ignored are included.
   - Ignored files are excluded (build outputs, virtualenvs, `node_modules`).
     See the limits below.
   - Submodules are recorded as gitlinks only.

   The run-start `HEAD` is recorded when the check gate is armed.

   Host Git invocations use `util/controller_git.zig` to disable hooks,
   fsmonitor and configured clean/smudge/process filters, including drivers
   from included configuration. The overrides apply only to the invocation;
   repository configuration is preserved. Candidate scripts are never run
   by snapshot creation, checkout or the final tree recheck. An incomplete
   filter query or excessive driver set makes the snapshot unavailable.

2. **A separate repository, not a linked worktree.** `git init` the
   directory, point `objects/info/alternates` at the actor's object
   directory, set `refs/heads/base` and `refs/heads/candidate`, and check out
   `candidate`. Objects resolve read-only through alternates. Every ref, the
   stash and any objects the verifier writes stay in the snapshot repository,
   so no git command the verifier runs can reach the actor's refs. No ref is
   added to the actor's repository. The snapshot commits stay unreferenced
   there for the few minutes they are needed, which is well inside git's
   default prune expiry. A checkout that fails because objects are missing is
   `unavailable`.

3. **Always delete.** `Worktree.finalize` keeps a changed worktree ("绝不误删
   agent 产物"). For the verifier that rule is inverted: the probes it writes
   are not products. The directory is removed after the verdict whatever it
   contains. A failed removal is logged and recorded and does not affect the
   verdict.

### 2.4 Why the verifier's probes cannot mutate the graded workspace

The verdict is bound to **T**. It is not bound to the live workspace. The
host enforces the boundary in three layers:

1. **Prevention by construction.**
   - The verifier has no file-writing tool.
   - Its only write vector is `Bash`, whose working directory is the snapshot.
   - Its git commands operate on a repository whose refs are not the actor's.
2. **Prevention by sandbox, where available.** On macOS and Linux the
   verifier's `Bash` runs under a derived `SandboxSettings`: `allowWrite`
   covers the snapshot and a temporary directory, and `denyWrite` covers the
   actor's root. `sandbox/exec.zig` confines it with Seatbelt on macOS and
   with bubblewrap on Linux (`sandbox/bwrap.zig`, when a bwrap that can
   create user namespaces is installed). On Windows, and on a Linux host
   without a usable bwrap, layer 2 is absent, and the design does not claim
   prevention there.
3. **Detection, on every platform.**
   - After the verifier returns (and after a leads round, §6), the host
     recomputes the tree id **T′** of the actor's workspace the same way.
   - **T′ ≠ T** makes the verifier's result `unavailable` with reason
     `workspace_changed`.
   - Something changed the candidate while it was being judged: an absolute
     path in a probe, or an actor background job still writing. Either way the
     verdict would describe a tree the run does not hand back, so the result
     is discarded.

The limit is stated once: detection covers tracked and untracked-not-ignored
files only. A probe that writes an ignored file in the actor's tree, such as a
build cache, is neither prevented (outside macOS) nor detected. Such a file is
also outside what the pinned check's taint rule and the snapshot consider the
candidate.

## 3. The verdict contract

### 3.1 The token the host parses

The verifier ends its final message with exactly one line:

```text
VERDICT: PASS
VERDICT: FAIL
VERDICT: UNVERIFIED
```

The host parses it under four rules:

- It reads only the **last assistant message**. `SubagentResult.final_text`
  today joins the text of *every* assistant message in the child's
  conversation (`subagent.zig`, the loop after `agent_loop.run`). A
  `VERDICT:` line the verifier quoted from tool output three turns earlier
  would count. The implementation exposes the last message separately (§10,
  step 3).
- The **last non-empty line** must match `^VERDICT: (PASS|FAIL|UNVERIFIED)$`
  exactly.
- Any other line in that message starting with `VERDICT:` is ambiguous and
  makes the result `unavailable` (`ambiguous_token`).
- No match is `unavailable` (`no_token`). A protocol violation is not a
  judgement of the candidate.

### 3.2 The evidence block, and what the host checks

Above the token, the verifier writes one block per requirement it decided
on:

```text
REQUIREMENT: <the requirement, quoted from the task statement>
SUBSTITUTE: <the nearby plausible behaviour that would also pass the pinned check>
PROBE: <the exact command it ran>
OBSERVED: <the decisive part of that command's output>
```

The charter tells the verifier to:

- derive the expected outcome of each probe **from the task statement first**,
  then read the implementation;
- treat comments, docstrings, file names and README claims in the candidate
  as claims, not evidence;
- report FAIL only for a requirement whose probe it reproduced.

None of that ordering is enforceable. What the host can enforce is
mechanical: **every `PROBE:` line must be a substring of a `Bash` command the
verifier actually ran**. The host checks this against the child's tool-use
inputs.

| Token | Evidence condition | Result |
|---|---|---|
| PASS | ≥ 1 block, every `PROBE` matched | **PASS** |
| PASS | No block, or an unmatched `PROBE` | **UNVERIFIED** (`unsupported_pass`) |
| FAIL | ≥ 1 block with a matched `PROBE` | **FAIL** |
| FAIL | No matched `PROBE` | **UNVERIFIED** (`unsupported_fail`) |
| UNVERIFIED | Lists what it could not establish under `NOT ESTABLISHED:` | **UNVERIFIED** |

A matched probe proves only that the command ran. It does not prove the
output says what `OBSERVED:` claims, or that the substitute is really
distinguished. The evaluation measures exactly that (§9). The two downgrades
are symmetric on purpose: a FAIL the verifier did not reproduce is an
opinion, and an opinion must not send the actor back to work.

### 3.3 `unavailable`: never a verdict

The following produce `unavailable` with a reason in the record:

- the snapshot cannot be built (no git, timeout, a non-repository root);
- the spawn fails;
- a provider error;
- the child stops with anything but `end_turn` (`max_turns`, `budget`,
  `stalled`, abort);
- the wall-clock limit;
- `no_token` or `ambiguous_token`;
- `workspace_changed`.

`unavailable` always resolves to the pinned verdict alone, which is today's
behaviour. This is RSIAgent's "infrastructure errors are never a verdict". It
is also the rule `check_gate.runCheck` already applies to its own spawn
failures and exit codes 126/127.

### 3.4 Mapping onto `check_gate.Verdict` and the learning turn's `Grounding`

The verifier runs only when the pinned check returned `passed` (§5.1), so
every row of this table starts from a green, untainted pinned check:

| Verifier result | `check_gate.Outcome.verdict`, enforce | `Outcome.verdict`, observe | `check_gate.decide`, enforce | `learning_turn.Grounding` |
|---|---|---|---|---|
| PASS | `passed` | `passed` | `finish_passed` | `passed` |
| FAIL | `failed`, `source = .verifier` | `passed` (verifier recorded only) | `continue_run` within budget and verifier bound, else `finish_exhausted` | `contested` (new) |
| UNVERIFIED, after the leads round or with no budget for one | `passed` | `passed` | `finish_passed` | `passed`, with the `NOT ESTABLISHED` list quoted |
| `unavailable` | `passed` | `passed` | `finish_passed` | `passed` |

Four consequences:

- **`check_gate.Verdict` and `CheckGate.lean` are unchanged.** A verifier
  FAIL enters `decide` as `failed`, so every continuation it causes is
  counted by the same `continuations` and bounded by the same
  `continuations_bounded` theorem. `Outcome` gains `source: enum { pinned,
  verifier }` and an optional verifier report.
  - `noteVerdict`'s fingerprint for a verifier failure hashes the
    `REQUIREMENT` lines, so repeated verifier failures advance the same
    cognitive-mode streak.
  - `renderContinuation` gains a verifier form. It quotes the evidence
    blocks, never the verifier's other text.
- **Observe mode changes nothing the conversation sees.** That includes the
  learning turn's grounding, so the observe arm stays a clean control. This
  is the same contract as the check gate's observe mode.
- **`Grounding` gains `contested`.** It means "the pinned check passed and an
  isolated verifier reproduced a failure". `decide(.contested, ready)` is
  `distill` with lesson verdict `failed`, so the lesson header stays
  `lesson-v1 verdict=failed …` and `lesson.Verdict` keeps its two values.
  - The variant exists so the record and the distill message can say where
    the failure came from. The distill message carries a second
    evidence-boundary sentence: "this failure was found by a model verifier
    that reproduced it with the probe quoted; it is not a test suite".
  - `groundingOf` takes the outcome's source as well as its verdict.
- **UNVERIFIED feeds `uncertain:`.** For a pass lesson, the `NOT
  ESTABLISHED` list is the concrete version of "what the check did not
  cover" that the distill message already asks for. This is the most direct
  thing the verifier contributes to the learning turn.

The end-of-run form (`host_check.runAndIngest`) has no conversation to
continue. There, a verifier result annotates the row only (§4), and the leads
round does not exist.

## 4. Provenance rank

[`verdict.zig`](../packages/coding/src/core/verdict.zig) orders provenance as `self_claim` <
`host_run_tainted` < `host_run` < `external_oracle` < `user`. The best-attempt
selector compares rows lexicographically by (reward, rank, recency). This is
proven in
[`VerdictProvenance.lean`](../control-plane/lean/MetaCodesControl/VerdictProvenance.lean)
(`reward_dominates`, `tainted_never_beats_clean`, `self_never_beats_oracle`).

**The verifier does not get a provenance tier, and it never writes a reward.**
Three facts in the code decide this:

1. **An unknown provenance string parses as `external_oracle`.**
   `Provenance.parse` falls back to `.external_oracle` for any unknown tag, so
   that legacy rows without a `provenance` field stay truthful. A new tag such
   as `"verifier"` written by a new binary would be read by every older binary
   as rank 3, above `host_run`. Adding a tier string would be an authority
   escalation for every reader that predates it.
2. **A verifier has no reward to give.** Reward is `passed / total` of a
   pinned check. A verifier verdict is one binary judgement about requirements
   the check does not cover. Putting it on the same axis would let a single
   model judgement outweigh a deterministic count, and `reward_dominates`
   would then let a verifier PASS beat a better-tested attempt.
3. **The cohort's false passes tie on reward.** Every v3 validator failure
   scored 1.0 on the visible suite, the same as the validator passes. The
   selector can only separate them on the tie-breaker, which is where the
   qualifier acts.

The verifier result is therefore a **qualifier** on a `host_run` row: a new
field `"verifier": "pass" | "fail" | "unverified" | "unavailable"` with the
tree id **T**. The `provenance` string stays `host_run`. Older binaries ignore
the field and read the row exactly as they read it today. New binaries
compute an effective rank:

```text
self_claim  <  host_run_tainted  <  host_run ∧ verifier=fail  <  host_run  <  external_oracle  <  user
                                    (contested)                 (verifier pass, unverified,
                                                                 unavailable or absent)
```

The verifier's position is therefore:

- **Relative to `host_run`: at or below, never above.** A verifier FAIL
  demotes a green host run to *contested*, below every uncontested host run
  at equal reward. A verifier PASS leaves the row exactly where `host_run`
  puts it. Reward still dominates: a contested 1.0 still beats a clean 0.97.
  This is the "authority breaks ties, it does not veto progress" rule that
  `reward_dominates` already states.
- **Relative to `external_oracle`: strictly below.** This follows from the
  above. Separately, the verifier never reads `external_oracle` or `user`
  rows (`kg = null`), so a held-out grade cannot reach a verifier and be
  laundered into a contested row. That is the same leak boundary as the
  learning turn's §5.

`VerdictProvenance.lean` gains a `Qualifier` and `effectiveRank` with the
following theorems, each naming its Zig mirror:

- `verifier_never_raises`: `effectiveRank r ≤ rank r.tier` for every
  qualifier;
- `contested_never_beats_clean`: at equal reward, a contested `host_run` row
  never beats an uncontested one;
- `contested_below_oracle`: at equal reward, no qualified row beats
  `external_oracle`.

`reward_dominates` and `irreflexive` must still hold over the extended
`better`.

## 5. Bounds and cost

### 5.1 When it runs: only after a green pinned check

The verifier runs at a check-gate boundary only when all of these hold:

- the gate is armed, at `depth == 0`;
- the pinned verdict is `passed` (not `failed`, `tainted` or `unavailable`);
- the run has verifier boundaries left (§5.2).

The reasons:

- **Red is already a verdict.** A red pinned check is deterministic,
  reproducible evidence, and the verifier can only demote (§4). Running it
  after red spends money to confirm something nobody doubts.
- **Tainted must not be laundered.** The run edited its own judge. A model
  verdict on top would invite reading "verifier PASS" as rehabilitation.
- **Unavailable means no pinned check.** A verifier as the *only* source
  would hold authority it is not given here. Verifier-only mode is out of
  scope (§11).
- **Green is where the false passes are.** In v3 that was 24 of 24 rollouts
  green, 8 of them false.

The verifier always runs on green, not on a sample. The v3 data gives no
cheaper trigger that would have caught the 8: every false green looked like
every true one to the host.

### 5.2 Caps

| Bound | Value | Why |
|---|---|---|
| Verifier boundaries per run | `MAX_VERIFIER_BOUNDARIES = 2` | A FAIL can send the actor back once under its own verifier bound, on top of the shared continuation budget. The second boundary's verdict is final |
| Spawns per boundary | ≤ 2 (one verifier, plus one after a leads round) | §6 |
| Spawns per run | ≤ 4 | 2 × 2 |
| Model turns per spawn | `VERIFIER_MAX_TURNS = 12` | Read the specification and the diff, write and run probes. v3 actors used 8–25 turns for the whole task. `AgentDef`'s default `max_turns` is 20 |
| Cost per spawn | `VERIFIER_MAX_COST_USD = 0.20` via `SpawnOptions.cost_budget_usd` | About 30% of a v3 rollout (US$15.75 / 24 ≈ US$0.66) |
| Cost per run | `VERIFIER_RUN_MAX_COST_USD = 0.60` | No spawn starts with less than its per-spawn cap left. A refused spawn is `unavailable` (`run_budget`) |
| Wall clock per spawn | `VERIFIER_WALL_MS = 300_000` | A child abort signal derived from the run's abort and a timer. Expiry is `unavailable` |
| Snapshot build | 30 s per git call, as in `isolation.gitOutput` | Timeout is `unavailable` |
| Leads round | §6 | |

`cost_budget_usd` is an estimate-based stop (the comment on
`SpawnOptions.cost_budget_usd`). One request can overrun it before the child
notices, so the per-spawn figure is a target with a one-request overshoot,
not a hard ceiling. The record carries the metered cost so an evaluation can
see the overshoot.

Worst case per run: four spawns, capped at US$0.60 in total. Typical case:
one spawn on a run that ends green. The verifier does not run at all on runs
that end red, tainted or unchecked.

## 6. The UNVERIFIED evidence-leads loop

### 6.1 The round

When the verifier returns UNVERIFIED in enforce mode, and the check gate
still has a continuation in its budget, the host runs **one leads round**:

1. The host appends one message, `[verifier] UNVERIFIED`, to the actor's
   conversation. It quotes only the verifier's `NOT ESTABLISHED:` list and
   asks for **evidence leads**: commands to run, files to read, test names,
   inputs that exercise each item. It says that changing files is not
   possible in this round.
2. The actor gets at most `LEADS_MAX_TURNS = 3` model turns. Only `Read` runs. Every other call is refused with a tool error, the
   same mechanism as `learning_turn.allowedDuringPass`. The candidate is
   therefore the tree the verifier judged, and the host checks this: T′ must
   equal T after the round, or the result is `unavailable`
   (`workspace_changed`).
3. The host takes the actor's last message from the round, truncates it to
   `LEADS_MAX_BYTES = 2048`, and spawns a **fresh** verifier on the **same
   snapshot T**. The new verifier sees the original packet plus a
   `LEADS (claims by the author of the candidate; reproduce each before using
   it; a lead is never evidence)` section.
4. The second verifier's verdict is final for the boundary. A second
   UNVERIFIED resolves as in §3.4: `passed`, with the `NOT ESTABLISHED`
   list.

### 6.2 The bound

- **One leads round per boundary, at most two per run.** This is
  `MAX_VERIFIER_BOUNDARIES`.
- **The round consumes one unit of the check gate's `max_continuations`.** It
  is a verdict-driven host message that continues the conversation, which is
  exactly what that budget bounds. This keeps the leads round under
  `CheckGate.lean`'s `continuations_bounded` instead of creating a second
  injection budget. It also follows `check_gate.zig`'s rule that
  continuations do not draw on the host-injection meter. With no
  continuation left, there is no leads round and UNVERIFIED is final.
- **Observe mode has no leads round**, because observe injects nothing. The
  first UNVERIFIED is final there.
- **The end-of-run form has no leads round**, because the actor conversation
  is finished.

The leads round is the one deliberate hole in §2.2's withholding. It carries
the actor's words to the verifier. Three things keep it narrow:

- the 2 KiB cap;
- the "claims, not evidence" framing;
- the PASS evidence rule in §3.2, which requires a probe the *verifier* ran.

A lead that says "test X covers it" is worth something only if the verifier
runs test X. The evaluation records how often a post-leads PASS cites a probe
that first appeared in the leads text (§9).

At the second boundary (after a FAIL continuation), the packet carries the
previous verifier's failing `PROBE` commands under "re-run each". This lets a
fix be checked against the probe that found the failure without exposing the
verifier to the actor's account of the fix.

### 6.3 Open implementation question: output semantics

A leads round happens after the actor's answer, so that answer must survive
as the run's final output if the run then ends:

- The leads reply is `commentary`.
- The pre-leads answer is closed as `final` only when the run actually ends
  without further work.

Today's continuation path closes the answer as `commentary` before
continuing. The learning turn instead seals the channel after closing
`final`. Neither fits a round that may be followed by more work or by the
end of the run. The ledger needs a "held final" segment, or the round has to
retain the answer text and close it at `finishRun`. This is unresolved, and
it is step 4's main risk.

## 7. Record

The verifier writes one terminal observation record per armed run,
`metacodes-isolated-verifier-v1`, beside `check_gate` and `learning_turn`.

| Field | Meaning |
|---|---|
| `enforced` | Treatment-actuation witness |
| `boundaries` | Verifier boundaries reached (0..2) |
| `spawns`, `leads_rounds` | Counts (≤ 4, ≤ 2) |
| `verdicts` | Per boundary: `pass` / `fail` / `unverified` / `unavailable`, with the reason (`unsupported_pass`, `no_token`, `workspace_changed`, `run_budget`, …) |
| `tree` | Per boundary: the snapshot tree id **T** |
| `charter_sha256`, `model`, `same_model` | Which verifier judged |
| `turns`, `cost_microusd`, `wall_ms` | Per spawn |
| `probes_cited`, `probes_matched` | §3.2 |
| `lead_probes` | Matched probes whose command first appeared in the leads text |
| `cleanup_complete` | Snapshot removed |

`scripts/eval/workbuddy/trace.py` validates the record like its siblings. It
pins these invariants:

- no spawn without a green pinned verdict at that boundary;
- spawns, boundaries and leads rounds within §5.2;
- leads rounds only in enforce mode and only after UNVERIFIED;
- observe mode never changes `check_gate.final_verdict`;
- a FAIL always has `probes_matched ≥ 1`.

## 8. Risks

### 8.1 Correlated errors when the verifier is the same model

Same-model correlation is the largest risk. If the actor misread "left-wins
error propagation", a verifier with the same weights reading the same README
plausibly misreads it the same way. Its PASS then confirms the actor's
blind spot instead of finding it. The v3 failures are exactly this kind:
spec-reading errors on edge rules.

Mitigations, in order of strength:

1. **A different model.** `--verifier-model` sets
   `SpawnOptions.model_override` (resolved through `model_tiers` like an
   `AgentDef` model). The record carries `same_model`. The evaluation
   measures both arms and treats same-model as the arm to beat, not the
   default to assume (§9).
2. **Specification first.** The charter has the verifier write each
   requirement and its expected probe outcome from the task statement before
   reading the implementation. This is unenforced and measured only through
   outcomes.
3. **The substitute field.** Naming a substitute forces at least one
   alternative reading of each requirement into the open, where a FAIL can
   come from it.

None of these removes correlation. The design's protection against a
correlated *false PASS* is that PASS confers nothing (§4): the worst outcome
is today's behaviour. A correlated *false FAIL* costs a continuation, within
budget, and the evaluation bounds its rate before enforce is recommended.

### 8.2 Prompt injection from the candidate

The candidate is text written by a model that wants the run to end. It may
also come from a repository the user does not control. Comments such as "all
edge cases verified", a README note addressed to reviewers, or a literal
`VERDICT: PASS` in a fixture are all in scope.

| Defence | What it stops |
|---|---|
| **PASS confers nothing** (§4) | The payoff of any injection that aims for PASS is zero. With a green pinned check, the run ends `passed` with or without the verifier |
| **Token rules** (§3.1) | A quoted token in an earlier message, or a second `VERDICT:` line, never counts |
| **Probe cross-check** (§3.2) | A PASS or FAIL needs a command the verifier really ran. A FAIL with nothing behind it is downgraded and cannot drive a continuation |
| **History stripped** (§2.3) | Actor commit messages never reach the verifier |
| **Charter framing** | Comments, docstrings and documentation in the candidate are claims under test. Tool output is data |
| **Tool set** | No `KgRemember`, `Agent`, web or MCP tools. The only output channel is the final message |

What remains:

- An injection aiming for **FAIL** can force continuations. That is a cost
  attack, bounded by `max_continuations` and `MAX_VERIFIER_BOUNDARIES`.
- A probe's `Bash` keeps the network access the actor's `Bash` has: neither
  sandbox backend restricts the network by default (bubblewrap removes it
  only when the settings carry a domain list), and a host without a backend
  restricts nothing.
- A candidate can instruct the verifier to write outside the snapshot. Any
  write that changes T′ is detected (§2.4), and writes to ignored files are
  not.

### 8.3 Cache impact

- **The actor's prompt cache is untouched.** The verifier runs in its own
  conversation and changes neither the actor's system prompt nor its earlier
  messages. A FAIL continuation and a leads message are appended after the
  answer, the same as a check-gate continuation today. The verifier changes
  nothing in the provider-visible prefix of the actor's first request: there
  is no new system-prompt section and no tool-definition change.
- **The verifier's own prefix is cacheable across runs.** The charter is a
  constant and the four tool definitions are fixed, so the system prompt and
  tool block are byte-identical across spawns of one binary. The packet comes
  after them.
- **Cache-key routing needs a distinct key.** `spawnAgentSink` merges a
  child's `overrides` with the parent's and keeps parent cache and routing
  knobs it does not override ("Preserve parent cache/routing knobs"). A
  verifier that inherits the actor's `prompt_cache_key` sends a different
  prefix under the same key. On providers that route by key, that competes
  with the actor's cached prefix. The verifier therefore sets its own key,
  derived as `<parent key>:verifier`. With a different `--verifier-model`
  there is no sharing either way.
- **Build caches are cold.** The snapshot excludes ignored files, so a probe
  that builds starts without the actor's build outputs. That is wall time,
  not tokens, and `VERIFIER_WALL_MS` bounds it. The evaluation reports
  verifier wall time separately from tokens.

## 9. Pre-registered evaluation on the check-gate v3 cohort

This section is the protocol. No rollout or verifier run has been made. The
check-gate authorization (US$30, of which US$22.36 is spent) does not cover
it. Each stage below needs the owner's authorization before any paid call.

### 9.1 Question

On candidates where the pinned check is green, how many full-validator
failures does the verifier catch, how many validator passes does it wrongly
fail, and at what cost?

### 9.2 Cohort

`evals/suites/check-gate-v3.json` at snapshot
7a860ef558c45a9342e937c9ad7e37a8a4b9476e: four tasks, with the reference
implementations and hidden cases kept outside the tree. The candidates are
the **final workspaces of the 24 v3 rollouts** (stage A and stage B, both
arms), all with a green pinned check:

- **8 validator failures** (cron 1, sheet 2, calc 1, ranges 4): the
  false-PASS set **F**;
- **16 validator passes**: the true-PASS set **P**.

**Stage R0 (no model cost)** checks that each workspace is still present
under `evals/runs/cg-v3/` on the evaluation host. It also checks that its
validator result reproduces the recorded partial credit. A candidate that
fails either check is dropped and listed. If more than 2 of **F** are
dropped, the cohort is regenerated with the v3 observe-arm wrapper. That
needs its own authorization, priced at v3's US$0.66 per rollout.

### 9.3 Arms

Each candidate gets **3** independent verifier spawns per arm:

| Arm | Verifier model | Role |
|---|---|---|
| `same` | glm-5.3-flash, the v3 actor model | The correlated case |
| `cross` | A different model, named in the experiment file before any run | The mitigation of §8.1 |

The run is replay: the harness spawns the verifier exactly as §2 specifies
against a snapshot of each final workspace. The task statement is the v3
prompt and the pinned check is `sh run_tests`. There is no actor, so there is
no leads round, and UNVERIFIED is final. Replay measures the verifier. It
does not measure the in-run loop.

### 9.4 Metrics

A candidate's verdict is the **majority of its 3 spawns**. A tie, or a
majority of `unavailable`, counts as UNVERIFIED.

- **Primary, false-PASS reduction.** Sensitivity on **F**: the fraction of
  **F** whose majority is FAIL. The pinned-check baseline is 0/8, since every
  member of **F** is a pinned PASS.
- **Primary, guard on false FAIL.** The false-FAIL rate on **P**: the
  fraction of **P** whose majority is FAIL. Sensitivity alone would reward a
  verifier that fails everything, so both sides are pre-registered.
- **Discrimination validity.** For each FAIL on **F**, the harness re-runs
  every matched `PROBE` command against the **reference implementation** in
  a copy of the same workspace. A FAIL is *discriminating* when at least one
  probe's output differs between candidate and reference. Only discriminating
  FAILs count toward sensitivity. A non-discriminating FAIL on **F** is a
  right answer for a wrong reason, and is reported separately.
- **Cost.** Per spawn: metered tokens, US$, turns and wall time (median and
  p90), reported against v3's mean actor rollout cost (US$0.66).
- **Guards.** The `unavailable` rate per arm (above 10% makes the arm
  invalid, not negative); the `unsupported_pass` and `unsupported_fail`
  downgrade counts; the UNVERIFIED rate; and `cleanup_complete` on every
  spawn.
- **Secondary.** Agreement between `same` and `cross` on **F**, a direct read
  of correlation. Spawn-level variance: how often the 3 spawns disagree.

### 9.5 Decision rule (fixed now)

A verifier arm is **recommended for an in-run enforce stage** only if all of
the following hold:

1. it catches **at least 4 of 8** members of **F** with discriminating
   FAILs;
2. it fails **at most 2 of 16** members of **P** (≤ 12.5%);
3. its median spawn cost is **at most US$0.20**, and its p90 is at most
   US$0.40;
4. its `unavailable` rate is at most 10%.

An arm that meets (1)–(2) only with `cross` makes `--verifier-model`
mandatory for enforce. An arm that fails (2) stays observe-only whatever its
sensitivity, because a false FAIL in enforce sends a correct candidate back
to work.

### 9.6 Cost reservation

The worst case is 24 candidates × 3 spawns × 2 arms = 144 spawns at
US$0.20, or **US$28.80**. As in v3's run note, the harness reserves the full
per-spawn cap before each spawn and stops fail-closed at the authorized
total. Expected spend is lower, but no estimate is pre-registered as a
claim.

### 9.7 Claim boundary

- This is internal evidence on four self-authored tasks and 8 false passes.
  It can show that the verifier catches *some* false passes at a measured
  price. It cannot establish a rate with a useful interval.
- Replay does not measure whether a caught failure gets fixed. That is the
  in-run stage: observe against enforce, paired, partial credit as in v3. It
  runs only if §9.5 recommends an arm, and it is pre-registered separately in
  `evals/experiments/isolated-verifier-v1.md`.
- The verifier never sees hidden tests or reference implementations. Both
  stay outside the snapshot, and the reference is used only by the harness
  for the discrimination check.

## 10. Implementation sketch (as designed; see §12 for the state)

| Step | Files | Evidence that closes it |
|---|---|---|
| 1. Snapshot: temp-index tree id, `base`/`candidate` commits, alternates-backed repository, always-delete finalize, T′ recheck | `packages/coding/src/agents/isolation.zig` (a `Snapshot` beside `Worktree`) | Tests: the actor's index, `HEAD`, refs and stash are byte-identical before and after; untracked files are in, ignored files out; T′ ≠ T after a write; a `git stash` in the snapshot leaves the actor's stash untouched |
| 2. Verifier core: charter constant and hash, packet render, token parse, evidence cross-check, result mapping, bounds `State` | `packages/coding/src/core/isolated_verifier.zig` | Unit tests per row of the §3.2 table and every §3.3 reason |
| 3. Last-message and tool-input access for a spawned child | `packages/coding/src/core/subagent.zig` | A test where an earlier assistant message carries `VERDICT: PASS` and the last does not: the result is `no_token` |
| 4. Wiring at the check-gate boundary: verifier after `passed`, FAIL continuation, leads round with the read-only gate, output-segment handling (§6.3) | `packages/coding/src/core/agent_loop.zig`, `packages/coding/src/core/check_gate.zig` | Component tests with a mock provider for each §3.4 row; observe arm byte-identical to the gate without the verifier |
| 5. `Grounding.contested` and the verifier evidence sentence | `packages/coding/src/core/learning_turn.zig` (after #292) | Tests mirroring a `contested_learns_failed` theorem |
| 6. End-of-run qualifier: `"verifier"` field and tree id on the `host_run` row; effective rank in the selector | `packages/coding/src/core/host_check.zig`, `packages/coding/src/core/verdict.zig`, history readers | Tests: an old-format row reads as before; a contested row loses only at equal reward |
| 7. Lean: `Qualifier`, `effectiveRank` and §4's theorems; an `IsolatedVerifier.lean` with `infra_never_verdict`, `pass_never_promotes`, `spawns_bounded` and `leads_bounded` | `control-plane/lean/MetaCodesControl/` | `zig build test` with the kernel |
| 8. Flags `--verifier`, `--verifier-observe` and `--verifier-model`, with `METACODES_VERIFIER` for the adapter. Requires an armed check gate, else a parse error | `apps/cli/src/main.zig` | CLI tests as for `--check-gate` without `--host-check` |
| 9. Record, `trace.py` validation, replay driver, experiment file | `packages/guard/src/tools/observation.zig`, `scripts/eval/`, `evals/experiments/isolated-verifier-v1.md` | Fixtures; the §9 protocol |

Steps 1–3 can be done and tested without a provider. Step 9's replay driver
is all §9 needs: it uses steps 1–3 directly and does not depend on steps 4–8.

## 11. Deliberately not in this design

- **Verifier-only mode.** This would use the verifier as the sole verdict
  source when no pinned check exists. It would make a model judgement
  authoritative, and §4's monotone-down argument would no longer hold.
- **Verifier PASS raising rank.** This is excluded for the injection reason
  in §8.2, and because §4's third fact shows nothing to gain on the cohort's
  ties.
- **In-run verifier ensembles or voting.** The majority-of-3 is an
  evaluation device for measuring variance, not a runtime mechanism. If §9
  shows a single spawn is too noisy, that is a finding for the next design.
- **User-defined verifiers.** No `AgentDef.isolation: snapshot` value and no
  disk-discovered verifier until the built-in one has evidence.
- **Verifier memory.** The verifier writes nothing to TinyKG or memdir. Its
  findings reach memory only through the learning turn, as the actor's
  lesson, under the actor's header.
- **Running on red, tainted or unavailable pinned verdicts.** See §5.1.

## 12. Implementation state

### 12.1 Implemented

| Step | Where | Evidence |
|---|---|---|
| 1. Snapshot | `isolation.Snapshot` in [`agents/isolation.zig`](../packages/coding/src/agents/isolation.zig): a temporary index seeded from the run-start `HEAD`, `git add -A`, `write-tree` → **T**, `base`/`candidate` written by `commit-tree` with a fixed identity and date, a separate repository whose objects resolve through `objects/info/alternates`, `workspaceUnchanged` (T′ = T), an always-delete `finalize` | Unit test: untracked in, ignored out, two host commits and no actor history, the actor's status, refs, stash and `HEAD` byte-identical, a `git stash` in the snapshot never reaches the actor, T′ ≠ T after a write, the directory removed |
| 2. Verifier core | [`core/isolated_verifier.zig`](../packages/coding/src/core/isolated_verifier.zig): `CHARTER` and `charterSha256Hex`, `renderPacket`, `parseToken`, `parseEvidence`, `crossCheck`, `judge`, `compose`, the §5.2 constants, `Gate` | Unit tests per row of the §3.2 table, the §3.1 token rules, the demote-only composition |
| 3. Last message and tool inputs | `subagent.ChildTranscript` / `SpawnOptions.transcript_out` | Unit test: an earlier `VERDICT: PASS` is not the last message |
| 4. Check-gate wiring | `agent_loop.zig` (`Options.isolated_verifier`, `verifierSpawn`, `verifierConclude`, `verifierAfterLeads`), `check_gate.State.noteVerifierFail` and `Source` | Component tests in [`apps/cli/tests/component/isolated_verifier_test.zig`](../apps/cli/tests/component/isolated_verifier_test.zig): FAIL → continuation → fixed → PASS; FAIL in observe mode changes nothing; PASS leaves the verdict; an ambiguous token is `unavailable`; the leads round refuses a write and feeds a fresh verifier; a project agent named `verifier` cannot shadow the charter |
| 6. End-of-run qualifier | `verdict.VerifierQualifier`, `verdict.effectiveRank`, `ComposeOptions.verifier`; `host_check.runAndIngestVerified`; the ` verifier=<q>` token in `self_evolution` rows; `scoped_recall.rowProvenanceRank` | Unit tests for the three §4 properties; a component test: a standalone FAIL composes a `host_run` row with `"verifier":"fail"` that loses to an uncontested row of equal reward |
| 8. Flags | `--verifier`, `--verifier-observe`, `--verifier-model <model or tier>`, and `METACODES_VERIFIER=enforce\|observe` in print mode (`main.resolveVerifier`) | A verifier with no pinned check, `--verifier-model` alone, or a verifier beside `--learning-turn` is a parse error |
| 9. Record | `isolated_verifier` observation (`metacodes-isolated-verifier-v1`) in [`tools/observation.zig`](../packages/guard/src/tools/observation.zig); `scripts/eval/workbuddy/trace.py` validates it | `WorkBuddyIsolatedVerifierRecordTest` |

The standalone entry point is `isolated_verifier.verify(gpa, Deps, VerifyRequest) → VerifyResult`.
It holds no check-gate state, so a teamwork runtime can call it after an
implementer finishes. `VerifyRequest` carries the task statement, a
`Workspace` (`.git` = snapshot this repository, or `.snapshot` = a snapshot
the caller keeps), an optional `PinnedCheck`, a `Budget` and an optional
model. `VerifyResult.outcome` is `pass: Report`, `fail: Report`,
`unverified: Unverified` (downgrade and `NOT ESTABLISHED` list) or
`unavailable: Unavailable`; `VerifyResult.record` carries the charter hash,
the tree id, the model, turns, metered cost, wall time and probe counts.
`Deps` has no field for a KG client, memory, MCP, Skills, host services or a
transcript, so none can reach the verifier.

### 12.2 Departures from the design

- **The leads round's output (§6.3).** The answer before the round is
  closed `final` and the channel is sealed for the round, so the leads reply
  is commentary and the answer survives if the run ends. A post-leads FAIL
  that continues the run unseals the channel; the next answer is a second
  `final` segment that supersedes the first.
- **Layer 2 of §2.4 (a derived Seatbelt profile) is not built.** The
  verifier inherits the actor's sandbox, with the snapshot as its working
  directory. Detection (T′ = T) runs on every platform.
- **Permissions.** The verifier runs under the actor's permission mode with
  path rules resolved against the snapshot. A host that asks before `Bash`
  and cannot ask a person in a subagent gets denied probes, which surface as
  UNVERIFIED, not as a verdict.
- **The end-of-run verifier runs only when the in-run gate is not armed**,
  and writes the qualifier only in enforce mode: an observe arm's next
  attempt sees the same rows as without the verifier.
- **Snapshot refs** are written as plain files and the work tree is filled
  with `read-tree -u --reset candidate` instead of `update-ref` and
  `checkout`: on a loaded test host each ref transaction took up to 15 s,
  and no hook from any configuration runs. A host whose default ref format
  is not `files` gets `unavailable` (`snapshot_failed`).
- **The record** carries the first 16 hex digits of each boundary's tree and
  run totals for turns, cost and wall time rather than per-spawn lists.

### 12.3 Not implemented

- **Step 5, the learning turn's `contested` grounding.** Until it exists,
  `--verifier` and `--learning-turn` are refused together.
- **Step 7, the Lean model.** `effectiveRank` and the §4 theorems have Zig
  unit tests only; `VerdictProvenance.lean` and an `IsolatedVerifier.lean`
  are still to be written.
- **Step 9's replay driver and `evals/experiments/isolated-verifier-v1.md`**,
  and every run of §9. No paid run has been made.
- **Teamwork integration** (#516): the runtime that calls `verify` after a
  manager claims completion, uses `ORIGINAL_REQUEST.md` as the task
  statement, and routes a first FAIL to a fix round.
