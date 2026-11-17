# HarnessMM runtime reuse, version 1

HarnessMM is the runtime EDG, Guarded Decision Reuse (GDR) and Certified
Callback Substitution (CCS) feature. RSI combines offline instruction evolution
and per-instruction ridge routing; its contract is in
[SKILL_RSI_PROTOCOL.md](SKILL_RSI_PROTOCOL.md). The two features have independent
CLI switches, default off, with the last positive or negative occurrence winning.

| HarnessMM | RSI | Runtime behavior |
|---|---|---|
| off | off | Original native model/tool loop; no policy file opened. |
| on | off | Allow guarded EDG reuse and certificate recording. |
| off | on | Route the frozen evolved instruction; use the original callback loop. |
| on | on | Apply both mechanisms. |

Use `--harnessmm` / `--no-harnessmm` and `--rsi` / `--no-rsi`.
RSI additionally requires `--rsi-policy <file>`. These switches are wired in
headless, REPL, web and daemon CLI hosts. Zig consumers use
`agent_loop.Options.harnessmm`, `rsi` and `rsi_policy` (retaining the immutable
policy for the Run). There is no C ABI layout or SDK wire revision change.
Child agents do not inherit these switches implicitly.

## Authoring and admission

With HarnessMM on, the host appends the constant `<harnessmm-authoring>`
contract once per participant task. Existing history, system prompt and tool
schemas are preserved. The slow actor can include exactly one graph envelope
in its assistant text alongside exactly one native root Bash tool call:

```text
<HARNESSMM_PLAN>{"schema_version":1,"root":{"tool":"Bash","arguments":{"command":"printf root"}},"nodes":[{"id":"A","after":"root","tool":"Bash","arguments":{"command":"printf one"},"guard":{"kind":"stdout_equals","literal":"root"}}]}</HARNESSMM_PLAN>
```

The [SDK fixture](../sdk/fixtures/harnessmm-plan-v1.json) has a three-node
chain. Only a newly committed participant assistant response can author a
graph. Host notes and tool outputs cannot. The graph root arguments must match
the accompanying native call after structural whitespace normalization; member
order remains significant. The original plan remains in conversation history.

This first adapter supports native Bash only. A graph is bounded to 16384
bytes and 8 future nodes; each argument object is at most 4096 bytes. Every
node has a unique 1–32 character ASCII alphanumeric/underscore ID other than
`root`, and depends on `root` or an earlier node. Arguments must be fully
determined literal JSON objects with a nonempty command. Background execution
is unsupported. The controller performs no interpolation, output prediction,
semantic inference or extra selector-model request.

Malformed, cyclic, oversized, unsupported or root-mismatched plans retain the
ordinary callback loop. Graphs live only within the current Run; a resumed or
new Run needs a fresh slow-actor plan.

## Guarded reuse through the native dispatcher

After each actual native receipt, the controller recognizes
`metacodes.bash-result.v2` with integer exit code zero. Guards are:

- `exit_zero`: successful native exit;
- `stdout_equals`: stdout exactly equals a nonempty literal of at most 1024 bytes;
- `stdout_contains`: stdout contains that literal.

The latter two also require complete, untruncated UTF-8 stdout. Receipt bytes
are bounded to 128 KiB. Unknown, failed, partial or unsupported observations
return control to the actor. A failed guard makes its node ineligible. The
controller substitutes a callback only when there is exactly one eligible
node. Ambiguity returns to the actor without choosing a branch heuristically.

The latest conversation message must still be exactly the preceding actual
tool result with the same call ID and content hash. New user input or host
context invalidates reuse. Bash must remain in the effective tool definitions.
Runs requiring PreToolUse hooks, a provider response-admission observer,
pending required-first tool activation, a learning pass or an active verifier
lead retain slow callbacks. A generated call ID that already exists in history
also retains the callback.

Each reused action enters the same native argument admission, tool slots,
permissions, sandbox, formal verdicts, budgets, artifact storage and dispatch as
a model-issued action. Permission denial and execution failure are real tool
results and stop further graph reuse. Logical turns are still counted; outer
turn, abort and cost checks still apply. No physical provider request, retry,
usage sample, token charge or model-response event is fabricated for an omitted
callback. The host-origin tool call and its real result remain in history for
the next slow callback.

## Durable substitution certificates

Enabling HarnessMM requires a writable absolute native session artifact root.
The host opens and syncs `harnessmm.jsonl` there before execution. For each
substituted action it appends and syncs a
`metacodes-harnessmm-substitution-v1` record containing:

- graph SHA-256, root call ID and decision ID;
- predecessor call ID and SHA-256 of its exact receipt content;
- literal native arguments, their SHA-256, guard kind and optional literal;
- actual native call ID, receipt SHA-256, native error flag and omitted logical
  callback turn.

These certificates bind observed receipts to the retained literal decision and
the native attempt. They are not a proof of task success or a counterfactual
token-saving estimate. Native refusals are recorded too. Journal failures fail
the Run rather than silently dropping evidence; a tool effect completed before
a journal failure cannot be rolled back. Certificate files are host artifacts
and are never appended to provider prompts.

## Validation

The native consumer test runs all four switch combinations against a local
mock provider. A root plus three successors yields the same four Bash receipts;
HarnessMM reduces physical model calls from five to two and writes three
hash-checked certificates. Tests cover false guards, ambiguous branches,
invalid dependencies, unsupported tools, negative switches and native permission
denial. Component tests check the native logical turn limit. No paid benchmark
or claim of paper-level benchmark performance is part of these checks.
