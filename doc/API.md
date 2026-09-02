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
| `~/.metacodes/config.json` | `schema_version`, `config_revision`, `providers`, `aliases`, `global_selection`, `last_operation_id`; written atomically, other keys preserved |
| `src/provider/control_plane.zig` | `model.list`, `model.describe`, `selection.validate`, `selection.resolve`, `selection.commit`, replayable event journal |

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
base64 JSON through as tool-result text. Only the canonical shape counts as
an image (`dialect.extractImageResult`): one JSON object with exactly those
three keys in any order, `type` equal to `image`, a media type from
`types.SUPPORTED_IMAGE_MEDIA_TYPES` (`image/png`, `image/jpeg`, `image/gif`,
`image/webp`), standard base64 of at most `types.MAX_IMAGE_BYTES` of payload,
and only whitespace after the closing brace. Standard JSON whitespace between
tokens does not matter; extra, duplicate or missing keys, JSON escapes (so a
serializer that writes `image\/png` does not produce an image), or more than
`types.MAX_IMAGE_RESULT_BYTES` of raw content do.
Anything else is ordinary text and is bounded by the tool-result projection
like any other result. A canonical image result is exempt from that
projection, from microcompact clearing while it has not yet been delivered
to the provider (delivery is an explicit per-message watermark set by the
agent loop once the provider has accepted a request for streaming, i.e. a
stream handle was returned; a request the provider rejects with an HTTP
error does not deliver, a locally appended assistant message is not
delivery, a resumed transcript starts undelivered until the next accepted
request, and a request through a model without image input, which only
carries the placeholder, does not deliver messages holding an image result —
that decision is the serializer's own, carried back on the accepted stream
handle (`StreamHandle.image_results_native`) rather than re-derived, so it
always matches the bytes sent; messages behind the compact boundary and
orphan image results the normalizer strips are delivered regardless, since no
later request can carry them), from `truncateLargeToolResults`, and from the AgentCore
artifact promotion above the operation's cap (`tool_result_cap_bytes` for
built-in and host tools, `mcp_result_cap_bytes` for external tools), so the
picture itself reaches the provider. Two different units apply: context estimation charges one image at
`types.IMAGE_TOKEN_ESTIMATE` (1,600 tokens); the projection turn budget and
the AgentCore payload cap charge it at `IMAGE_RESULT_BUDGET_BYTES` (6,400
budget bytes, four bytes per token). The AgentCore durable budget is charged
the real bytes. Because images bypass the byte budgets, the bytes they put
on the wire are capped separately at `types.MAX_IMAGE_RESULT_BYTES_PER_REQUEST`
(16 MiB, under every wired provider's inline-image request limit): the
projection spills the largest images of the current turn beyond the cap into
artifact envelopes, and before each request the agent loop stubs the oldest
already-delivered image results until the active history fits
(`agent_loop.Options.image_request_bytes_cap`). On Gemini 3, `image/gif`
results travel as a sibling `inline_data` part rather than inside the
multimodal function response, whose `inlineData` accepts only PNG, JPEG and
WebP. A profile whose cap for that operation kind is below 6,400
rejects images of that kind with `checkpoint_payload_resource_limit`. Anthropic keeps the base64 `image`
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
