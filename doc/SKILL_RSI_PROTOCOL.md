# Procedural skill RSI, version 1

RSI is one opt-in feature combining offline instruction evolution and a
candidate-specific ridge router. It is independently switchable from
[HarnessMM runtime reuse](HARNESSMM_PROTOCOL.md). This protocol covers short
procedural instructions, not executable `SKILL.md` packages or EDG execution.
The offline host is `scripts/eval/skill_rsi.py`; the frozen product reader is
`src/skills/rsi.zig`. Neither feature replaces the AgentLoop or changes tool,
permission, sandbox, formal-verdict, TinyKG or artifact authority.
The design follows the instruction/router branch of
[HarnessMM](https://arxiv.org/abs/2610.32813), with a native metacodes artifact
and feature contract rather than a benchmark reproduction.

## Product switches

`--rsi-policy <file>` names a frozen UTF-8 JSON policy. `--rsi` enables the
complete feature; `--no-rsi` disables it. RSI defaults to off; the last
positive or negative occurrence wins.

When disabled, the policy is not opened and no procedural instruction is
added. When enabled, the selected evolved instruction is applied only when
its own router admits the task. Evolution and routing are internal parts of
RSI, not separate product switches.

If no evolved member exists, evolution uses the seed. An explicit empty
evolved instruction means that offline selection retained the original
harness. Missing router, model mismatch, out-of-support features and a score
below threshold abstain. Enabling RSI requires a policy path. Malformed,
oversized or hash-inconsistent policies fail startup before a model request.
The runtime switch does not run training or make an optimizer/selector request
at startup. The separate offline evolution/routing options below exist for
research ablations; an artifact without a router abstains in the product.

The CLI hosts (headless, REPL, web and daemon) pass the same immutable policy
to the kernel. Children do not inherit it. A newly admitted instruction is one
persisted host-origin user-role note after the current participant task:

```text
<procedural-skill>
the exact instruction bytes
</procedural-skill>
```

It is appended once per participant task, including across retries. Existing
messages, the system prompt and tool schemas are not rewritten. Policy paths,
hashes, router scores, training metadata and journals never enter this note.
The instruction is guidance only; it is never interpreted as a command,
permission rule or tool-policy frame. Previous task notes remain in history.

## Frozen policy

The root has exactly `schema_version` (1), `feature_schema`
(`metacodes-skill-text-v1`), `model` (exact actor request model), `seed`, and
optional/null `evolved`. Each candidate has:

- `instruction`: at most 4096 UTF-8 bytes; no NUL or nested note delimiters;
- `sha256`: lower-case SHA-256 of the exact instruction UTF-8 bytes;
- optional/null `router`: its own fitted gate, bound by
  `instruction_sha256` to the candidate's hash.

A router contains finite `intercept`, five finite `weights`, finite
`threshold`, and five-element `minimum` and `maximum` arrays. Bounds are
nonnegative and ordered. The model does not output a probability.
The shared consumer fixture is
[`sdk/fixtures/skill-rsi-v1.json`](../sdk/fixtures/skill-rsi-v1.json).
This adds no AgentCore C ABI field, SDK method or wire revision.
Zig embedders can use `skill_rsi.Loaded`, `Policy`, `Flags` and
`agent_loop.Options.rsi_policy` / `rsi`; they retain the policy for
the whole Run. CLI flags are not implicitly imported into AgentCore Sessions.

The five features, in array order, are:

1. UTF-8 byte length / 4096;
2. count of ASCII `[A-Za-z0-9_]+` words / 512;
3. presence of an ASCII single/double quote or a curly double quote;
4. an ASCII word equal, case-insensitively, to `before`, `after`, `between`,
   `within`, `left`, `right`, `above`, or `below`;
5. an ASCII word equal to `count`, `calculate`, `number`, `total`, `sum`,
   `many`, or `much`, or a literal occurrence of `多少`, `几个`, or `总数`.

The last three values are 0 or 1. The Python trainer and Zig reader share this
contract. Bounds apply to these normalized values. Only public task text is
used. The runtime computes `intercept + sum(weights[i] * features[i])` and
applies the instruction when the result is at least `threshold`.
An absolute tolerance of `1e-12` treats roundoff at the threshold as equality
in both implementations.

## Offline evolution and routing

Run the host on the execution machine, using `dx` from the Mac checkout:

```sh
dx python3 -m scripts.eval.skill_rsi --manifest /path/to/manifest.json \
  --output-dir /path/to/new-run --evolution --routing \
  --max-cost-usd 5 --max-tokens 100000 \
  --call-max-cost-usd 0.10 --call-max-tokens 4000
```

The paths in this command are execution-machine paths. A paid invocation still
requires explicit user authorization. Dollar values above illustrate syntax,
not an authorization to run. No provider-backed benchmark is part of tests.
`--no-evolution` trains the seed's router without invoking the proposer;
`--no-routing` evolves instructions without fitting any router. With both
offline stages off, the host exports the seed without any callback or task
execution. These are training ablations within RSI, not the two product
features (HarnessMM and RSI).

The manifest is an object with `model`, `seed_instruction`, `train`, and
`validation`. Each task has exactly `id`, `unit_id`, `prompt`, all nonempty
strings. IDs are unique across both splits; independent unit IDs must not
cross splits. Variants of the same training unit stay grouped. The trainer
rejects a `test` field. Manifest construction, native scorer integrity and
fresh workspace preparation belong to the trusted evaluation host, not to the
optimizer model.

For example, a small manifest starts with:

```json
{
  "model": "the-exact-actor-model",
  "seed_instruction": "Check the requested output paths before finishing.",
  "train": [
    {"id":"t1","unit_id":"u1","prompt":"First training task"},
    {"id":"t2","unit_id":"u2","prompt":"Second training task"}
  ],
  "validation": [
    {"id":"v1","unit_id":"uv1","prompt":"Held-out selection task"}
  ],
  "proposer_command": ["/path/to/trusted-proposer-adapter"],
  "evaluator_command": ["/path/to/trusted-native-evaluator-adapter"]
}
```

The lifecycle is:

1. Execute the original harness on all training tasks. Force each candidate
   instruction on all training tasks to acquire paired score/token differences.
2. When evolution is enabled, make `--rounds` TRAIN-only optimizer calls
   (default 2). The next proposal sees every earlier candidate and its measured
   training results. Empty proposals abstain; duplicate instructions reuse
   execution evidence. Nonempty proposals cite at least two distinct supplied
   training IDs and fit the frozen size/180-word limit. They are complete
   replacements, not additional stacked prompt layers.
3. When routing is enabled, independently fit each candidate's ridge head.
   Average features/outcomes within each independent unit; deterministically
   group units into folds (default 2). Each out-of-fold prediction is made by
   weights fitted without that unit. Choose a threshold with at least two
   supported units, no observed quality loss among them, and positive mean
   utility. Refit deployment weights on all training units. A failed gate
   produces no router, so deployment abstains.
4. The routing target is half native-score improvement plus half bounded
   relative token saving. Native scores are in [0,1]; relative saving is clipped
   to [-1,1]. Original and candidate observations include unsuccessful attempts.
5. Freeze all candidates and router parameters before validation. Compare
   routed or unconditional candidates, according to the offline routing
   ablation, against the original. Require actual application, no loss of aggregate
   native score, and an improvement in score or, at equal score, fewer tokens.
   Ties retain the incumbent. Select one instruction/router pair, or the empty
   baseline. Validation never reaches the proposer and does not refit a head.
6. Write `report.json`, then the deployable `policy.json`. The report contains
   all call requests/results, every candidate's instruction and own fitted
   router, fit/validation results, the deployment
   digest and the development budget checkpoint. TEST remains external.

These small lexical gates provide empirical applicability estimates, not a
guarantee of per-task benefit. Cross-fitting protects only the router fit;
candidate generation has seen training data. A separate held-out test is
needed to measure generalization. A zero-edit result is a completed search.

## Adapter and budget boundary

Commands are explicit argv arrays, never shell strings. One child consumes one
JSON request on stdin and returns one JSON object on stdout. `kind` is
`propose` or `evaluate`; every request includes `schema`
(`metacodes-skill-rsi-call-v1`), `model`, `phase` and `call_index`.
The command transport also supplies `budget_authorization` with the durable
transaction ID, `max_cost_microusd` and `max_metered_tokens`; adapters enforce
these caps before their own provider side effects.

- A proposal request includes `objective`, `iteration`, TRAIN `tasks`,
  `baseline` and `previous_candidates`. Its response adds `instruction` and
  `supporting_task_ids`.
- An evaluation request includes the public `task`, exact `instruction` and
  `instruction_sha256`. Its response adds an actual native `score` in [0,1]
  and optional `feedback`. The trusted evaluator must execute the unchanged
  harness in a fresh workspace and obtain this score from the native scorer;
  the proposer cannot supply it.
- Every response includes the matching `model`, measured `input_tokens`
  (cached input included), `output_tokens`, and integer `cost_microusd`.
  Missing usage/scores remain unknown and fail the run, never become zero.

Before every network-capable child starts, the existing `BudgetJournal`
reserves and fsyncs the per-call dollar/token exposure and authorization.
Completed usage and a request/response digest settle that call. A crash,
timeout, malformed response or missing usage leaves the reservation unresolved;
an authorized call cannot be silently retried. Optimizer, training and
validation expenses all count against the same explicit total cap. The
adapter remains responsible for enforcing its per-call bounds inside its own
provider requests; opaque child processes cannot be attested by this host.
The run directory is new and private; existing artifacts are never overwritten.
