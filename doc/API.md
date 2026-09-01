# API overview

Metacodes exposes several host shapes over one kernel. The fixed AgentLoop,
Conversation projection, permission/sandbox chain, budgets, formal verdicts,
artifact store, and TinyKG admission are not replaceable extensions.

## Compatibility matrix

| Interface | Entry point | Status | Compatibility rule |
|---|---|---|---|
| CLI | `zig-out/bin/metacodes` | pre-1.0 | flags may evolve with changelog notice |
| Provider control plane | `src/provider/` kernel API | experimental | schema-versioned documents and revisioned mutations |
| Zig source API | `@import("metacodes-core")` | experimental | pin repository commit and Zig toolchain |
| AgentCore C ABI | `metask_agentcore_get_api(1)` | experimental rev 15 | exact root/child layouts and bundle manifest |
| Process plugins | strict manifest + stdio protocol | versioned v1 | reject unknown fields and digest drift |
| Plugin inventory | `--dump-plugins`, Zig, Web state | versioned v1 | additive observation fields only where specified |
| TinyKG executable distribution | `vendor/tinykg/manifest.json` | bundle v1 | exact target, format, source commit, and SHA-256 pinning |

There is no general HTTP service API promise yet. The Web and daemon hosts are
product surfaces built over the same core protocols.

## Provider selection surface

Route selection is provider-owned data, not a model-name convention. See
[Provider offers and control plane](PROVIDER_OFFER_ARCHITECTURE.md) for the
normative model; the entry points are:

| Surface | Contract |
|---|---|
| `--provider <id\|alias>` / `METACODES_PROVIDER` | resolve the route through the provider registry instead of inferring a transport from the model name |
| `--channel <id>` | narrow to one endpoint/region/plan/account binding |
| `--offer <offer-id>` | pin one exact reproducible route |
| `--base-url <url>` | validated against the selected profile and route policy before any request URL is built |
| `--check-providers` | validate the configuration and print every route it produces, then exit; no credential is resolved and no request URL is built |
| `metacodes login --provider <id> --oauth-token-json <file>` | import an OAuth token into that provider's own store; refresh, single flight, and rotated-refresh persistence then run themselves |
| `~/.metacodes/config.json` | `schema_version`, `config_revision`, `providers` (with per-provider `credentials` by environment-variable reference), `custom_providers`, `provider_catalogs`, `aliases`, `global_selection`, `recent_operation_ids`; written atomically, other keys preserved |
| `<session_dir>/runtime-selection.json` | `session_selection`; a session-scoped choice never reaches `config.json` |
| `src/provider/control_plane.zig` | `model.list`, `model.describe`, `selection.validate`, `selection.resolve`, `selection.commit`, `quote.estimate`, replayable event journal |

Interactive surfaces: `Ctrl+O` and `/model` open the route picker (transcript
viewing moved to `Ctrl+X Ctrl+O`, also `/transcript`); `/providers` lists routes
and takes `refresh`, `enable <id>`, `disable <id>`, `remove <id>`; `/alias`
names a route (`pin`, `float`, `use`, `remove`); `/models` still selects the
account key.

A committed route is broadcast on the UI event stream as `config_changed` →
`route`, carrying provider, channel, protocol, wire model id, offer id,
credential *reference*, and scope. The model name alone cannot identify a route,
so a name-only broadcast would announce a change an out-of-process client cannot
tell apart from another; the credential reference travels and the secret does
not.

A newer `config.json` `schema_version` is rejected rather than merged. Sessions
that name no provider keep the historical Metask credential and model-inference
path unchanged.

## Session command surface (UI-neutral)

All three interactive hosts (terminal REPL, `--web`, `serve`/`serve --sessions N`)
share one input pipeline (`src/session_intent.zig` + `src/session_service.zig`):

    raw input → session_intent.parse → InputIntent
      → SessionService.dispatch (validate → mutate → optional RunPlan)
      → host submits the run via session_service.buildRunOptions

- **Intent classes.** `!cmd` is the shell lane; `/verb …` resolves against the
  built-in verb table (`session_intent.BUILTIN_VERBS`, built-ins win over
  same-named skills); an unknown `/head` is a skill candidate; anything else is
  a prompt. The verb table is the single registry — hosts do not parse slash
  commands themselves.
- **Service verbs** (equivalent across hosts): `/model use <id>`, `/mode
  [name]`, `/effort <level>`, `/compact`, `/add-dir <path>`, `/theme <v>`,
  `/vim`, `/retry`, `/commit`, `/review`, `/init`, plus prompt and `!cmd`
  submission. Web/daemon reach them via `POST /command` (queued to the driver
  thread; result arrives as a `command_result` journal event, run-producing
  commands then execute a normal agent run). Display-only verbs (`/help`,
  `/tools`, …) are terminal-rendered; web/daemon report them as unsupported.
- **Run assembly.** `session_service.buildRunOptions` is the only place App
  state is projected into `agent_loop.Options`; hosts add only host-specific
  fields (UI requester, run-control observers, budgets).
- Equivalence is locked by `tests/component/session_api_parity_test.zig`.

This is an internal-consistency contract, not yet a wire-protocol stability
promise: the HTTP endpoint shapes remain pre-1.0.

## CLI surface

`metacodes --help` enumerates the current flag set and is the authoritative
pre-1.0 surface; `metacodes --version` prints `metacodes <semver>`. The flag
surface is fail-closed: an unknown flag or positional argument exits with code
2 and names the offender — nothing is silently ignored, because evaluation
harnesses pass treatment configuration through this surface. Headless
automation uses `-p/--print` (or `-` for stdin) with `--json`/`--stream-json`
NDJSON output; introspection uses `--dump-prompt` and `--dump-plugins`. Flag
removals or semantic changes require a changelog entry.

### Model tiers

Subagent/skill model pins and `/model` accept tier names — `low`, `mid`,
`high` (legacy aliases `haiku`/`sonnet`/`opus` map to the same tiers) — which
resolve against the current provider's tier table in
`~/.metacodes/config.json`:

```json
"model_tiers": {
  "openai": {
    "low":  {"model": "gpt-5.6-mini", "effort": "medium"},
    "high": {"model": "gpt-5.6-sol",  "effort": "xhigh"}
  }
}
```

The table is keyed by provider kind (`anthropic`/`openai`/`gemini`) so one
user-level file serves any `--provider` session without cross-provider model
injection. An unconfigured tier inherits the session model and effort — there
are no built-in per-provider model IDs. A tier's optional `effort` is the
canonical `none|minimal|low|medium|high|xhigh` scale; each model family's
dialect translates it to its own wire format and level count (OpenAI
`reasoning.effort` full scale; GLM `reasoning_effort` pass-through; Kimi
K2.6/K3 three levels; DeepSeek two levels; MiniMax M3 three states
`disabled|adaptive|enabled` with M2.x always-on; Anthropic adaptive thinking
plus `output_config.effort`). Explicit `effort:` in an agent definition wins
over the tier's effort. The built-in `Explore` agent pins the `low` tier.

### Multimodal image input

User messages can carry first-class image content alongside text. Core
represents a conversation block as `Block.image {media_type, data}` (base64
payload, MIME at least `image/png` and `image/jpeg`), ordered freely between
text blocks; the projection to the provider request preserves that order.
Headless runs attach images with `--image <path>` (repeatable, order kept,
png/jpg/jpeg/gif/webp by extension, 3.75 MB raw per image); the prompt text
plus the images become one multimodal user message.

Each provider dialect translates the neutral image block to its native wire
form (`Dialect.serializeImagePart`): Anthropic emits a base64 `image` source
block, OpenAI-compatible endpoints emit an `image_url` data URL content part
(the Responses protocol emits `input_image`), and Gemini emits an
`inline_data` part. Capability is per-model data
(`ModelProfile.supports_image_input`, queryable as `Capability.image_input`):
a model without vision fails the request with `error.ImageInputUnsupported`
before any network I/O — images are never silently dropped, OCR'd, or
replaced with placeholder text. Image blocks round-trip through the JSONL
transcript and the AgentCore checkpoint (block tag 5), so restored sessions
resend the original bytes.

Embedders reach the same capability three ways: source-level hosts build
ordered `message.UserContentPart` slices and call `AgentSession.runUserParts`
(or `AdmittedRun.runUserParts`); AgentCore binary consumers submit
`RUN_INPUT_MULTIMODAL` with a `RunInputPartV1` array through
`session_run_input` (ABI revision 15, capability preflight status 28 — see
[doc/AGENTCORE_BINARY_ABI.md](AGENTCORE_BINARY_ABI.md)); the headless CLI
keeps `--image`.

Tool results can also carry an image: the `Read` tool returns
`{"type":"image","media_type":...,"data":...}` for image files, and every
protocol family now serializes that form natively instead of passing the raw
base64 JSON through as tool-result text. Anthropic keeps the base64 `image`
source block inside the `tool_result` content array (byte-identical to
before). OpenAI chat/completions sends a short pointer as the tool message
(tool message content officially accepts only text) and attaches the image in
an immediately following user message (`image_url` data URL, one text label
per image naming its `tool_call_id`). The OpenAI Responses protocol sends
`function_call_output.output` as an `input_image` content-part array (official
since 2025-09), pairing by `call_id`. Gemini 3 series uses the official
multimodal function response (`functionResponse.parts[].inlineData`,
`ModelProfile.supports_multimodal_function_response`); older Gemini models
receive the image as a sibling `inline_data` part in the same user turn after
all `functionResponse` parts.

Unlike first-class user images (which fail the request up front), a tool
result arrives after the tool already ran mid-conversation, so a model
without vision gets a short explicit placeholder text — `[image (<MIME>) was
read successfully but omitted: this model does not support image input]` —
never the multi-megabyte base64 payload and never a silently wedged session.

Prompt-cache note: a text-only conversation serializes byte-identically to
builds without this feature (OpenAI `content` stays a plain string unless the
message actually contains an image), so existing cache prefixes are
unaffected. Non-image tool results are also byte-identical to before on all
three protocol families.

An image tool result is exempt from the byte-length spilling that
`core/result_projection.zig` applies to oversized results. The per-result cap
is `clamp(window/8, 8 KB, 64 KB)` while the `Read` tool accepts images up to
3.75 MB, so without the carve-out essentially every real screenshot would be
replaced by an artifact envelope before any dialect could serialize it.
Detection reuses `dialect.extractImageResult` (the same single truth the wire
serializers use). Images stay bounded by `Read`'s `MAX_IMAGE_BYTES`, and the
per-turn budget charges one image at `IMAGE_TOKEN_ESTIMATE` rather than its
base64 length, so a screenshot no longer evicts unrelated tool results.

Both caps now come from one place, `core/result_budget.zig`, derived once per
turn from the provider window and handed to `ToolContext.result_budget` as
well as to `result_projection`. A tool that bounds its own output (Bash, whose
two channels share one allowance by max-min fairness) sizes its preview from
that value rather than from a private constant, and spends it in **encoded**
bytes so JSON escaping cannot double the rendered result. When a result is
spilled, its preview is sized from the same budget instead of a fixed 1536
bytes; when the envelope would be larger than the content it replaces, the
result is left inline. The per-turn budget lowers a single water line across
every oversized result rather than evicting the largest one. A result whose
preview was fixed by the streaming capture path is re-rendered against the
budget before commit, and re-inlined outright when the original fits. Text
results therefore no longer project byte-identically to builds before this
change; committed results are still never re-projected for a later request, so
prompt-cache prefixes are unaffected.

"Encoded" is the unit everywhere, including on the two paths that are exempt
from the spill pass and therefore have no second chance: a committed envelope
re-rendered against the budget, and `ReadArtifact`. Both cut their payload by
what it will cost once escaped, and the encoding chosen while budgeting is
carried to whatever renders it rather than being decided a second time.

The Conversation-level pressure valves bound results that entered under a
different budget - a `/resume`d transcript, or a switch to a smaller window.
Their generic head/tail truncation is a text edit, so an artifact envelope is
first offered to `result_projection.shrinkRecoverableEnvelope`, which
re-renders it in place with a smaller preview and every identity field intact.
Anything else structured — a Bash envelope, a non-recoverable fallback, any
tool's large JSON — keeps its shape by trimming only its long string values,
with the counters that describe a trimmed string corrected as they are written.
The short fields are what make a result actionable and are never what made it
oversized. Only a structured result that cannot be shrunk at all is left
oversized rather than mangled: `clearToolResultAt` already refuses to erase a
result's only recovery capability, and a truncation pass that quietly did so
instead would be worse than doing nothing.

Recovery has two primitives rather than one. `ReadArtifact` returns byte
ranges, which costs one round trip per `MAX_READ_BYTES` and cannot answer a
question about the content; `Grep` therefore accepts `artifact_id` in place of
`path` and searches the stored blob directly. The store path is never exposed:
filename output is suppressed, `files_with_matches` — whose entire output would
be that path — is rejected for artifact searches, and the child's stderr is
scrubbed of it before it can reach a tool error.

No staging path is model-visible, on any Bash channel. The prompt-cache
contract below lists staging paths and random ids among the things that never
are, and a JobRegistry spool path is both; a capture too large to publish is
therefore genuinely unrecoverable, and `<channel>_storage_error` says which of
the reasons it was rather than implying a handle exists.

Every budget derived from the context window resolves the model the request
will actually name, not the Provider's own. A subagent shares its parent's
Provider and differs from it only by `model_override`, so sizing a child's
results — or its auto-compact thresholds — against the parent's window is how a
200K parent hands a 32K child a history that endpoint rejects.

### PDF document input

A user message can also carry a PDF as first-class content. Core represents it
as `Block.document {media_type, data, title, pages}`: `data` is the base64
payload, `media_type` is `application/pdf` (the only admitted type today),
`title` is a stable host-supplied identity such as a file name — never a local
path, which would both leak the environment and break the provider cache
prefix — and `pages` is the counted page total, or null when the page tree
lives in a compressed object stream and is not determinable without a full
parser. It is never a guess.

Documents are modelled separately from images because the capability is
separate. `ModelProfile.supports_pdf_input` (queryable as
`Capability.pdf_input`) is its own truth: `supports_image_input` being true
never implies it. The first slice supports exactly one native path — Anthropic
Claude 3.5 and later, which emit a base64 `document` source block. Every other
provider/model fails the request with `error.DocumentInputUnsupported` before
any network I/O. A document is never silently replaced by extracted text, OCR,
a summary, or page images; any future conversion path has to be explicit about
its representation and information loss.

Admission runs before encoding and before any provider dispatch
(`core/pdf.zig`): a payload that is not really a PDF fails with
`InvalidPdfDocument`, a password-protected one with `EncryptedPdfUnsupported`,
one over 12 MB raw with `PdfTooLarge`, and one over 100 countable pages with
`PdfTooManyPages`. Token accounting charges a document by its page count
(`pdf.estimateTokens`), not by its base64 length, so one attachment cannot
push a turn past the auto-compaction threshold on byte size alone.

Document blocks round-trip through the JSONL transcript and the AgentCore
checkpoint (block tag 7), so a restored session resends the original bytes,
title, and page count with no dependence on the host file still existing or
being unchanged.

Embedders reach the capability the same three ways as images: source-level
hosts build `message.UserContentPart{ .document = ... }` slices;
AgentCore binary consumers submit `RUN_INPUT_PART_DOCUMENT` inside a
`RUN_INPUT_MULTIMODAL` parts array (ABI revision 16, capability preflight
status 29); the headless CLI takes `--pdf <path>` (repeatable, order kept).
The headless block order is prompt text, then each `--image` in command-line
order, then each `--pdf` in command-line order.

The `Read` tool does **not** read PDFs. It has no extraction or page-rendering
path and no `pages` parameter, and its description now says so; native PDF
*input* does not imply local PDF *reading*.

### Provider reasoning continuity (OpenAI Responses)

The Responses protocol is used with `store:false`: the server keeps no copy of
the response, so reasoning context survives only if the client sends the
server's own `reasoning` items back on the next request. Core models one as
`Block.reasoning_item {model, json}` — `json` is the item exactly as the
server emitted it (`id`, `summary`, `encrypted_content`), replayed byte for
byte, and `model` is the model that produced it.

This is not `Block.thinking`. A thinking block is readable assistant
reasoning that the UI displays and the Anthropic dialect replays as a
`thinking` block; a reasoning item is opaque provider state that is never
displayed, never enters a compaction summary, and never becomes assistant
text. Every dialect other than OpenAI Responses skips it.

Capture is event-independent: the same item may arrive in
`response.output_item.done`, in the terminal `response.completed`'s
`response.output` array, or in both. Both paths extract it and a per-stream
key (the item `id`) keeps it replayed exactly once. On the next request the
items are emitted first among that message's `input` items, matching the
server's own `output` order (reasoning → message/function_call).

Replay is model-scoped: encrypted reasoning state belongs to the model that
produced it, so after a mid-session model switch the stale items are dropped
rather than sent to a model that would reject them. Reasoning items round-trip
through the JSONL transcript and the AgentCore checkpoint (block tag 6), so a
resumed session keeps the continuity. A conversation with no reasoning items
serializes byte-identically to before.

## Zig source embedding

`src/lib.zig` exports the UI-neutral core. In a consumer, these types are reached
through the module namespaces `mc.agent_session.AgentRuntime`,
`mc.agent_session.RuntimeHost`, and `mc.agent_session.AgentSession` (where
`mc = @import("metacodes-core")`). A host supplies a fixed
provider/workspace/policy configuration, creates sessions, consumes typed events/UI
requests, and destroys sessions before their owning runtime generation.

`RuntimeHost.replace` publishes a fully validated immutable generation for new
sessions. Existing sessions remain pinned to their old generation. Failed staging
does not consume a generation or mutate the active runtime.

Runtime creation validates tool availability, not only tool names: built-ins
that execute through an external binary (`Glob`/`Grep` → ripgrep) fail
creation with `error.ToolDependencyUnavailable` when that executable cannot be
resolved, instead of entering the catalog and failing on their first
invocation. A host can probe the dependency up front with
`mc.util_toolchain.ripgrepPath()` and select a tool set without `Glob`/`Grep`
when it is absent.

The recommended high-level lifecycle is:

```zig
const mc = @import("metacodes-core");

const host = try mc.agent_session.RuntimeHost.create(allocator, .{});
defer host.destroy() catch unreachable; // after all Session defers below
const session = try host.createSession(.{
    .provider_kind = .anthropic,
    .api_key = api_key,
    .model = model,
    .workspace = .{ .root = workspace_root },
    .allowed_tools = &.{ "Read", "Write" },
});
defer session.destroy() catch unreachable;
const result = try session.runText(1, "Summarize the workspace", 4, sink);
_ = result.stop_reason;
```

`EventSink` is a synchronous callback value (`.{ .ctx = ..., .emit = ... }`). Keep
its context, the provider credentials, and `workspace_root` alive until the Session
is destroyed. Use `RuntimeHost.replace` for a staged generation change; do not
mutate a live Session's tool catalog directly.

Static trusted plugins can contribute typed tools, streaming tools, services,
advisory policies, and deterministic provider dialects. Process plugins can only
contribute isolated tools through the versioned wire protocol. Neither receives a
mutable AgentLoop, permission, formal, or TinyKG handle.

See [LIB_API.md](LIB_API.md) for the dependency/build wiring and
`example/main.zig` for a complete consumer fixture.

## AgentCore binary embedding

The source-free bundle contains:

- `sdk/metask/agentcore.h` for C11/C++17;
- `sdk/zig` typed bindings;
- `sdk/rust` bindings and build integration;
- one target-specific static library;
- the manifest-pinned ripgrep runtime asset (`bin/rg[.exe]`) that `Glob`/`Grep`
  execute through — deploy it next to the Host executable or via `RG_BIN`;
- a manifest whose file allow-list, runtime-asset declaration, and SHA-256
  values are mandatory.

Consumers call only `metask_agentcore_get_api(METASK_AGENTCORE_ABI_V1)` and
must validate ABI revision 15, the exact 64-byte root, all five mandatory typed
tables, reserved zeros, function slots, and the schema-1 bundle manifest.
Runtime/Session, sync run, abort, event/UI callbacks, checkpoint/restore, Host
streaming tools, MCP streaming, process plugins, and durable journal profiles
are covered. `SessionHostConfigV1` combines `provider_kind_code`,
`protocol_kind_code`, `base_url`, and the create/restore model binding. Protocol
zero preserves each provider's existing default; OpenAI consumers may select
`OPENAI_PROTOCOL_RESPONSES` explicitly to send Responses `input` requests and
parse typed Responses SSE. Anthropic and Gemini currently accept only the
default protocol code. Invalid provider/protocol pairs fail before network I/O,
and neither URL nor model names select a protocol. `on_event` is the
per-Session serialized, non-durable Run
observation stream. Its typed events include authoritative visible-output
segment boundaries and `commentary` / `final` / `continued` / `partial` /
`discarded` classifications, plus structured `file_changes` evidence for
typed file tools, as additive Revision 15 observation tags.
Independent Completion is deliberately not part of AgentCore: a
Host owns product-level model calls and exposes only semantically bounded Tools
when an Agent must invoke one.

The ABI is experimental: there is no compatibility shim between revisions. Pin a
bundle, not only a semantic version. See [AGENTCORE_BINARY_ABI.md](AGENTCORE_BINARY_ABI.md).

## Tool result contract

All tool origins converge on the same typed result:

```zig
const ToolResultBody = union(enum) {
    @"inline": InlineResult,
    artifact: ArtifactReceipt,
    structured_error: StructuredToolError,
};
```

Unknown or large producers should begin a kernel-owned capture before byte zero.
The capture computes SHA-256, bounded previews, quotas, and CAS publication while
streaming. Conversation receives deterministic inline bytes or an artifact
envelope; `ReadArtifact` restores bounded slices. UI and post-tool observation can
consume the original result without changing model-visible projection.

## Prompt-cache contract

For equivalent effective configuration, one provider request must be a byte prefix
of the next request until deliberate compaction. These are never model-visible:

- plugin generation/id/path and activation bookkeeping;
- operation journals, telemetry, TinyKG receipts, timestamps, and random ids;
- staging paths for artifacts or external binaries.

A real tool schema, system instruction, dialect output, conversation append, or
compaction may change the cache key. Tests compare serialized provider requests,
not internal object identity.

Selecting, staging, or explicitly overriding a TinyKG executable does not change
provider-visible bytes. TinyKG receipts and bundle identities remain execution
metadata; only governed memory content deliberately appended at a checkpoint can
change the subsequent request.

## Errors and ownership

Public boundaries use tagged states or explicit error sets. Callback buffers are
borrowed only for the documented call duration. Returned buffers always have a
documented paired release API: AgentCore-owned byte buffers are released with
`api->buffer_release`, while callback-owned buffers are released by the host's
registered release function. Hosts must not retain sink pointers, call mutating
session APIs reentrantly, or destroy a runtime with active sessions. The normative
ownership rules live beside each public header/type and its consumer fixture.
