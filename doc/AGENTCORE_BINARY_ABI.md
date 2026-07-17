# AgentCore binary library ABI v1

The AgentCore bundle is a thin binary facade over the existing metacodes
`AgentRuntime` / `AgentSession` / `AgentLoop`. Consumers do not add metacodes
implementation source to their build graph, and the Host owns all UI.

ABI v1 is the first stable in-process embedding contract for synchronous,
stateful AgentSession execution. It is not a generation label for
`metacodes-core`, and it does not define a Workbench product model.

## Build and verify

Use the repository-pinned Zig toolchain and an explicit target. The command
below is the currently verified native consumer configuration:

```sh
zig build agentcore:test
prefix=$(mktemp -d)
zig build agentcore:consumer --prefix "$prefix" \
  -Dtarget=aarch64-macos.13.0 -Doptimize=ReleaseSafe \
  -Dagentcore-strip=true
```

The final release check must use a new empty prefix and bind the manifest to
the clean commit being released:

```sh
commit=$(git rev-parse HEAD)
zig build agentcore:consumer --prefix /absolute/new/empty/prefix \
  -Dtarget=aarch64-macos.13.0 -Doptimize=ReleaseSafe \
  -Dagentcore-strip=true \
  -Dagentcore-require-clean-bundle=true \
  -Dagentcore-expected-commit="$commit"
```

`--prefix /absolute/path` changes the bundle root. The installed files are:

```text
<prefix>/
├── lib/<target static-library filename>
├── include/metacodes_agentcore.h
├── sdk/metacodes_agentcore.zig
├── sdk/metacodes_agentcore_protocol.zig
├── sdk/metacodes_agentcore_types.zig
└── manifest.json
```

The manifest records source and toolchain identity, resolved target,
architecture, OS, target ABI, optimization and strip settings, binary ABI
version, required system link inputs, and SHA-256 for every shipped file. The
source-free consumer validates those fields, the exact manifest file entries,
and the complete on-disk file/directory allowlist. Bundles require an explicit
`-Dtarget=<triple>` so an artifact cannot silently inherit the build host. Build
a distributable bundle into a new empty `--prefix`; a clean Git tree does not
make a reused output directory free of stale, unlisted files.

`agentcore:bundle` cross-compiles one bundle per explicit target and link-checks
source-free Zig and C consumers without running them. The static library
filename comes from Zig for that target (`.a` or `.lib`) and is recorded in the
manifest. `agentcore:consumer` additionally runs the resulting programs, so a
cross-target runtime check needs a compatible runner; native CI should run it
on every released platform. At present only macOS arm64 has completed that
native end-to-end verification. This is a validation status, not an ABI
restriction.

Schema version 1 is the first formal bundle layout. Earlier pre-release
development manifests are unsupported.

ReleaseSafe bundles strip DWARF by default; the explicit
`-Dagentcore-strip=true` in the release command pins that policy in build
automation. Debug symbols belong in a separately retained symbols artifact,
not in the consumer bundle.

## Typed Zig SDK

The shipped Zig SDK remains source-free. `metacodes_agentcore_types.zig`
contains the raw ABI declarations plus validated `Status` and `StopReason`
enums. `metacodes_agentcore_protocol.zig` owns the ABI v1 `CoreEvent`,
`UiRequest`, and `UiResponse` wire types, decoders, and the request-aware
response encoder. `metacodes_agentcore.zig` re-exports both layers beside raw
API-table access.

`decodeCoreEvent` returns an owned `ParsedCoreEvent` whose value is either
`known: CoreEvent` or `unknown: { tag, payload_json }`. This lets an older Host
ignore or retain a valid observation event added by a newer ABI-v1 library.
The common known-event path scans the top-level tag and performs one typed
parse; only an unknown tag pays for a dynamic JSON tree.
`decodeUiRequest` and `decodeUiResponse` remain strict because an unknown
control message cannot be answered safely. All decoded strings and arrays
remain valid until `deinit`; consumers must not copy an owner and deinitialize
both copies.

```zig
var parsed = try sdk.decodeCoreEvent(allocator, event_json);
defer parsed.deinit();
switch (parsed.value) {
    .known => |event| consume(event),
    .unknown => |event| retainOrIgnore(event.tag, event.payload_json),
}
```

Known payloads accept additive fields. Multiple tags, duplicate tags, malformed
JSON, and invalid known payloads are rejected. Adding an optional field or a new
observation tag is compatible; removing a tag, changing a required field, or
adding a UI request/response tag is breaking and requires a new ABI. Opaque
JSON-bearing strings are not recursively interpreted by the SDK.

`encodeUiResponse` returns an allocator-owned buffer suitable for
`mc_owned_bytes_v1`, rejects response tags that do not match the request, and
validates the answer count for `ask_question`.

The public `CoreEvent` schema is not the internal frontend/daemon union.
`src/agentcore/protocol_v1.zig` exhaustively maps internal events to the
v1 DTO before serialization. Presentation hints (`set_current_tool`,
`clear_current_tool`), implementation diagnostics (`diag_*`), and
App/daemon coordination events (`config_changed`, `session_lifecycle`,
`agent_lifecycle`, `tasks_changed`, `ui_request_pending`) do not cross the
ABI. Future internal event additions fail the adapter compilation until they
are explicitly mapped or excluded.

The v1 observation set is:

| Event | Meaning |
|---|---|
| `text_chunk` | Assistant text delta |
| `stream_done` | One provider stream completed |
| `tool_start` | Tool invocation identity, name, and input |
| `tool_progress` | Incremental progress text for one tool call |
| `progress` | Current 1-based turn and cumulative tool-call progress |
| `tool_result` | Completed tool result, error flag, and elapsed time |
| `usage` | Token-usage delta |
| `context_warning` | Context-pressure thresholds and level |
| `auto_compact` | Conversation compaction summary |
| `retry_notice` | Provider retry attempt and delay |

Events describe observations, not commands. A Host may render, aggregate,
persist, or ignore them; consuming an event never drives `AgentLoop`.

## Contract

`metacodes_agentcore_get_api(1)` is the only discovery symbol. ABI v1 exposes
opaque Runtime and Session handles, synchronous text Runs, abort, built-in and
synchronous Host tools, tagged CoreEvent JSON, and synchronous Host UI JSON.
Runtime copies Host tool metadata and callback references and must outlive every
Session. The Host retains ownership of each Host tool `ctx` and keeps it valid
until Runtime destruction succeeds. Session owns provider credentials,
workspace inputs, tool selection, Conversation, permission memory, jobs, and
Run state. Session callback descriptors are copied at creation; the Host retains
their `ctx` and keeps it valid until Session destruction succeeds.

One Session accepts one active Run at a time. A successful Run returns to idle
and the Host may start another Run on the same stateful Conversation. `Status`
describes whether the ABI call itself succeeded. `StopReason` is meaningful
only when `session_run` returns `MC_STATUS_OK` and is one of `end_turn`,
`max_turns`, `aborted`, `tool_error`, `api_error`, or `tool_loop`. Internal
`suspended`, `backgrounded`, and `budget` states are not representable in v1;
if one becomes reachable through the facade it is an internal contract failure,
not a new public stop code. Because the stateful Run may already have committed
Conversation changes, that failure poisons the ABI facade and subsequent Run or
abort calls return `MC_STATUS_INVALID_STATE`; destroy remains valid.

Run admission is the lifecycle boundary. Validation failures
(`MC_STATUS_INVALID_ARGUMENT` / `MC_STATUS_RESOURCE_LIMIT`) and admission
failures (`MC_STATUS_BUSY` / `MC_STATUS_STALE_RUN`) do not mutate the
Conversation and leave the Session in its previous usable state. Once a Run is
admitted, `MC_STATUS_OUT_OF_MEMORY`, `MC_STATUS_CORE_ERROR`,
`MC_STATUS_CALLBACK_FAILED`, or `MC_STATUS_INTERNAL_ERROR` means execution may
have committed Conversation changes or external side effects, so the Session
is poisoned. Subsequent Run and abort calls return
`MC_STATUS_INVALID_STATE`; destroy remains valid. `MC_STATUS_OK`, including a
terminal `MC_STOP_ABORTED`, returns the Session to idle. A too-late abort also
leaves the already-idle Session reusable.

Assistant text and other execution output are delivered through `on_event`.
`RunResultV1` is a terminal summary containing stop reason, turns, and tool
calls; it is not an output buffer. `on_event` is optional: without it the Run
still executes, but observation output is discarded. SDK-level aggregation is
a consumer convenience and does not change the ABI.

Relative paths supplied to `Read`, `Write`, `Edit`, `Glob`, and `Grep` resolve
against `workspace_root`; Bash also runs with that directory as its cwd.
`workspace_root` is an execution context, not a filesystem jail: absolute
paths remain usable unless the Host selects and configures a separate sandbox
policy. Invalid workspace paths, unavailable/duplicate selected tools, and a
shell tool selected under the disabled shell policy fail Session creation with
`MC_STATUS_INVALID_ARGUMENT` and do not publish a Session handle.

ABI v1 has three ownership classes:

| Value | Owner and lifetime | Release |
|---|---|---|
| `mc_bytes_view_v1` inputs and event/request views | Borrowed for the current synchronous call or callback | Never released |
| Host tool results and UI responses | Host-owned callback output | Canonical `{NULL,0}` is never released; every other descriptor is passed to its paired Host release callback exactly once, independent of status |
| AgentCore API diagnostics | Library-owned write-only output | Released only with the discovered `buffer_release` function |

Status controls whether callback output is consumed, not whether it is
released. Only `MC_HOST_OK` consumes Host tool text and only `MC_UI_ANSWERED`
consumes UI response JSON; output returned with any other status is ignored.
No callback or release callback has thread affinity.

The final `mc_owned_bytes_v1 *` argument on AgentCore API calls is an optional,
write-only diagnostic output. AgentCore never reads or releases its previous
value; a Host must call `buffer_release` before reusing a variable that still
contains a diagnostic from an earlier call. Successful calls return canonical
empty. Diagnostic allocation is best-effort and never changes the primary
operation status. Host-owned callback output must never be passed to
`buffer_release`.

Host tool `execute` receives two borrowed views: the current AgentSession
identifier and the provider-produced tool arguments JSON. Neither remains valid
after the callback returns.

### Callback and concurrency matrix

| Path | Concurrency/ordering | Failure semantics |
|---|---|---|
| `on_event` | Serialized within one Session; different Sessions may call shared Host state concurrently | Any value other than `MC_CALLBACK_CONTINUE` aborts the Run and poisons the Session |
| Host tool `execute` | Different Sessions and parallel tool calls in one Session may invoke it concurrently | `MC_HOST_FAILED`/`MC_HOST_REJECTED` becomes a normal tool result and does not by itself poison the Session |
| `on_ui_request` | Synchronous in the Run path | Fatal, invalid, mismatched, or oversized responses abort the Run and poison the Session |
| release callbacks | Exactly once for every accepted Host-owned buffer; no thread affinity | Must not re-enter Run or destroy |
| `session_abort` | May run concurrently with the matching synchronous Run, including from a callback | Cooperative; callback or provider code that blocks can delay completion |

Callbacks may request abort but must not re-enter Run or destroy. The Host must
serialize create/destroy and all operations other than matching abort on the
same handle.

ABI v1 UI response JSON is one of:

```json
{"answers":["choice per question"]}
{"permission":"allow_once"}
```

Permission also accepts `allow_always`, `deny_once`, and
`deny_tool_session`. ABI v1 does not expose plan mode or plan approval because
AgentSession does not own the complete `EnterPlanMode`/`ExitPlanMode`
lifecycle. KG counts and Workbench plan-progress state are likewise not part
of this protocol. There is no unversioned `custom` escape hatch. Host tool
input schemas use the AgentCore object-schema subset: `type`, `properties`,
and `required`.

Session permission modes are `default`, `accept_edits`, `auto`, `dont_ask`,
and `bypass_permissions`, represented by the corresponding public constants.

ABI v1 supports these built-in tools: `Read`, `Write`, `Edit`, `Glob`, `Grep`,
`Bash`, `BashOutput`, `KillShell`, and `AskUserQuestion`. Runtime creation
rejects process-level tools whose dependencies are not owned by AgentSession,
including Task, Cron, KG, MCP, worktree, and notification tools. Adding those
requires a future explicit Host capability contract; they are not silently
advertised with missing state.

### Resource limits

V1 limits only Host inputs that amplify library allocations or unbounded work:

| Limit | Value |
|---|---:|
| total Runtime tools; selected Session tools | 1024 |
| one Host tool schema | 1 MiB |
| Host tool schema nesting | 32 levels |
| top-level schema properties/required entries | 1024 |
| one synchronous UI response | 1 MiB |
| one Host tool result | 16 MiB |
| one Runtime/Session metadata string | 1 MiB |
| total Runtime metadata | 16 MiB |
| total Session metadata | 4 MiB |
| one Run | 1000 turns |

Configuration and pre-admission Run limits return
`MC_STATUS_RESOURCE_LIMIT`. An oversized UI response is released exactly once,
returns `MC_STATUS_CALLBACK_FAILED`, and poisons the Session because the Host
UI transport violated its callback contract. An oversized Host tool result is
released exactly once and becomes an ordinary Host tool failure. Events are
never silently truncated. V1 does not impose a universal prompt or event-size
cap.

Runtime metadata includes built-in names and Host tool names, descriptions, and
schemas. Session metadata includes credentials, model/base URL, workspace
paths, and selected tool names. These budgets bound copied configuration; they
do not classify the same-process Host as untrusted.

Host tool results are UTF-8 text. Invalid UTF-8 is released exactly once and
becomes an ordinary Host tool failure. Binary output requires an explicit
textual encoding such as base64 or a future attachment contract; arbitrary
bytes must not be smuggled through JSON strings.

All empty `mc_owned_bytes_v1` values use the canonical `{NULL, 0}` form. Host
UI fatal/invalid responses are infrastructure failures: they abort the active
Run, poison the Session, and surface as `MC_STATUS_CALLBACK_FAILED` (or
`MC_STATUS_OUT_OF_MEMORY` when response processing exhausts memory).

### Sensitive data

Provider credentials are copied into Session-owned storage and must never
appear in CoreEvent JSON, diagnostics, or error buffers. Prompts, assistant
text, tool inputs/results, and UI payloads are potentially sensitive by
default; the Host owns storage, logging, retention, and redaction. Diagnostic
buffers are human-readable, unstable text and must not be parsed as a machine
protocol. V1 deliberately does not add a `sensitive` boolean that would imply
reliable automatic classification.

### ABI evolution

All v1 POD descriptors and the API table require their exact documented
`struct_size`; every reserved field must be zero. Reserved storage is not
permission to extend v1 layouts. Any layout, function-table, or control-message
extension requires `metacodes_agentcore_get_api(2)` and v2 types.

`capabilities` reports the API surface implemented by the returned library
table. It is not per-Runtime or per-Session negotiation; concrete Runtime and
Session configuration still determines which tools and callbacks are active.

ABI v1 deliberately does not add session persistence/restore, asynchronous UI
continuations, background operations, resume/checkpoint, strict Workspace
security, Workbench `Output`/`FileChange`/plan-progress models, or a
multi-platform universal bundle. Those are separate contracts, not hidden
behavior in the library facade.
