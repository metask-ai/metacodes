# AgentCore binary library ABI v1

The AgentCore bundle is a thin binary facade over the existing internal
execution engine. Consumers do not add implementation source to their build
graph, and the Host owns all UI. AgentCore is versioned and distributed as an
independent component; this ABI does not expose or define any host product.

ABI v1 is an experimental in-process embedding contract for synchronous,
stateful AgentSession execution. It does not expose or define a host product
model.

**Status: experimental — freeze retracted on 2026-07-17.** V1 was frozen on
2026-07-17 and unfrozen the same week: consumer feedback exposed a design gap
in the callback identity surface (Host tools receive a `session_id`
correlation key that no v1 API lets the Host obtain, and callbacks do not
carry a unified admitted-Run context). Freezing a surface with a dangling
reference was premature; retracting the label now, while exposure is minimal,
was judged cheaper than carrying the flaw forever.

While experimental, v1 makes no stability promise: layouts, numeric values,
function-table order, and semantics may change incompatibly between commits.
Consumers must pin an exact bundle (the manifest records the source commit)
and treat every update as potentially breaking. No near-term re-freeze is
planned.

The current experimental bundle is **ABI v1 revision 3**. Revision 3 is an
in-place breaking namespace migration from revision 2. The 112-byte table and
RunContext behavior introduced by revision 2 remain intact, but all public C
identifiers now use the `metask_agentcore` / `METASK_AGENTCORE` namespace and
the discovery symbol is `metask_agentcore_get_api`:

- `metask_agentcore_api_v1` is 112 bytes and requires `abi_revision == 3`;
- event, UI, and Host-tool callbacks receive `const metask_agentcore_run_context_v1 *`;
- `METASK_AGENTCORE_CALLBACK_*` was removed in favor of `METASK_AGENTCORE_EVENT_*` (no aliases);
- Host tools may return `METASK_AGENTCORE_HOST_FATAL` and FAILED/REJECTED detail;
- `manifest.json` records `binary_abi_revision: 3`.

Consumers migrating from the pre-revision bundle must update the header and
library atomically, validate the stable `struct_size`/`abi_version` prefix
before reading later fields, then require exact revision equality. A 104-byte
table and a 112-byte table with any revision other than 3 are both rejected;
there is no compatibility fallback or old-name alias. Every per-Run callback must validate and
copy any retained `RunContext` fields during the callback, and Host registries
must bind/compare `session_id` atomically under their per-Session lock.

Re-freeze first requires closure of the open items tracked in
`doc/AGENTCORE_V1_EXPERIMENTAL_LEDGER.md` (every group A item closed; every
group B item given an explicit disposition, with B1/B3 fixed or formally
argued). Only then do the two independent gates apply:

1. **Reference-closure audit** — every identifier, handle, or key the ABI
   hands to the Host must have a documented way for the Host to obtain or
   resolve it. Any dangling reference fails the audit.
2. **Real-consumer gate** — at least one consumer not written by the library
   authors exercises the claimed capability matrix (multiple concurrent
   Sessions × runtime-level Host tools × cross-thread abort) against the
   candidate surface.

## Build and verify

Use the repository-pinned Zig toolchain and an explicit target. A cross-target
bundle build compiles and link-checks source-free Zig, C, and C++17 consumers
without trying to execute foreign binaries:

```sh
zig build agentcore:bundle \
  -Dtarget=x86_64-windows-msvc \
  -Doptimize=ReleaseSmall
```

On a matching native host, the delivery gate runs the ABI tests, creates the
bundle, links the source-free consumers, and executes them:

```sh
zig build agentcore:gate \
  -Dtarget=x86_64-windows-msvc \
  -Doptimize=ReleaseSmall
```

`agentcore:gate` and `agentcore:consumer` require an explicit target that can
run on the current host. They fail during graph construction for a foreign
target and direct cross-target validation to `agentcore:bundle`.

To keep a validation run isolated from previous output, use a new empty prefix.
For example, on a native macOS arm64 host:

```sh
prefix=$(mktemp -d)
zig build agentcore:gate --prefix "$prefix" \
  -Dtarget=aarch64-macos.13.0 \
  -Doptimize=ReleaseSafe \
  -Dagentcore-strip=true
```

`--prefix /absolute/path` changes the install prefix. The target-specific
bundle root is nested below it so different resolved targets cannot overwrite
each other:

```text
<prefix>/agentcore/<resolved-target>/
├── lib/<target static-library filename>
├── include/metask/agentcore.h
├── bindings/zig/
│   ├── build.zig
│   ├── build.zig.zon
│   └── src/{root,protocol,types}.zig
├── bindings/rust/
│   ├── Cargo.toml
│   ├── Cargo.lock
│   ├── link.cfg
│   ├── build.rs
│   ├── examples/link_probe.rs
│   └── src/{lib,raw}.rs
├── README.md
└── manifest.json
```

The manifest records vendor/component identity, package and source identity,
the package target plus producer Zig and Cargo targets, optimization and strip
settings, binary ABI status/version/revision, system link requirements, and
SHA-256 for every shipped file. The source-free consumer validates those fields,
the complete manifest file whitelist, and every declared payload hash, then
applies the declared link inputs to every language probe. Bundles require an
explicit `-Dtarget=<triple>` so an artifact cannot silently inherit the build
host. Files outside the manifest are local staging residue, not compatibility
surface: consumers ignore them and the archive command never includes them.

`agentcore:bundle` cross-compiles one bundle per explicit target and link-checks
source-free Zig, C, and C++17 consumers against the installed artifacts. The
static library filename comes from Zig `out_filename` for that target (`.a` or
`.lib`) and is recorded in the manifest. The Windows/MSVC archive also exports
the `unlink`, `mkdir`, `rmdir`, `access`, `chdir`, and `getcwd` CRT spelling
shims needed by the current implementation. These six link-visible support
symbols are not AgentCore ABI entry points and carry no consumer stability
promise; consumers must not call or otherwise depend on them.
`agentcore:consumer` additionally runs the resulting programs, while
`agentcore:gate` combines that native consumer check with the ABI test suite
and runs the Rust ABI link probe.

`agentcore:rust` builds and links the bundled `metask-agentcore-sys` link probe.
Its `build.rs` reads the generated `link.cfg` line format instead of parsing the
full bundle manifest; the manifest remains the source of the projected target
and system-link values.
The checked-in raw Rust declarations are regenerated with bindgen 0.72.1 using
the fixed `x86_64-unknown-linux-gnu` Clang layout target and hermetic minimal
standard-type headers, so regeneration does not inherit the build host target.
`agentcore:archive` creates a coordinate-rooted Windows zip or Unix tar.gz from
only the manifest whitelist plus `manifest.json`, and writes an adjacent
SHA-256 file; it rejects an existing coordinate instead of overwriting it.

Current delivery status is intentionally target-specific:

| Target | Bundle/archive | Native source-free consumption |
|---|---|---|
| `x86_64-windows-msvc` | verified | C/C++/Zig/Rust verified; currently usable |
| `x86_64-linux-gnu` | cross-build/link verified | pending native Linux gate |
| `x86_64-macos` | cross-build/link verified | pending native Intel macOS gate |
| `aarch64-macos` | cross-build/link verified | pending native re-verification after the Rust bundle addition |

Cross-build success is not a support claim. In particular, the empty macOS
framework list remains provisional until the corresponding native gates pass.
This validation status is not an ABI restriction.

Schema version 1 is the first formal bundle layout. Earlier pre-release
development manifests are unsupported.

ReleaseSafe bundles strip DWARF by default; the explicit
`-Dagentcore-strip=true` in the release command pins that policy in build
automation. Debug symbols belong in a separately retained symbols artifact,
not in the consumer bundle.

## Typed Zig SDK

The shipped Zig SDK remains source-free. `bindings/zig/src/types.zig`
contains the raw ABI declarations plus validated `Status` and `StopReason`
enums. `bindings/zig/src/protocol.zig` owns the ABI v1 `CoreEvent`,
`UiRequest`, and `UiResponse` wire types, decoders, and the request-aware
response encoder. `bindings/zig/src/root.zig` re-exports both layers beside raw
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
`metask_agentcore_owned_bytes_v1`, rejects response tags that do not match the request, and
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
persist, or ignore them; consuming an event never drives the core execution
loop.

## Contract

`metask_agentcore_get_api(1)` is the only discovery symbol. ABI v1 exposes
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
only when `session_run` returns `METASK_AGENTCORE_STATUS_OK` and is one of `end_turn`,
`max_turns`, `aborted`, `tool_error`, `api_error`, or `tool_loop`. Internal
`suspended`, `backgrounded`, and `budget` states are not representable in v1;
if one becomes reachable through the facade it is an internal contract failure,
not a new public stop code. Because the stateful Run may already have committed
Conversation changes, that failure poisons the ABI facade and subsequent Run or
abort calls return `METASK_AGENTCORE_STATUS_INVALID_STATE`; destroy remains valid.

The synchronous `session_run` return is a quiescence boundary: every callback
started for that Run, and every paired release callback for its Host-owned
outputs, has completed before the call returns. Callbacks from the next Run on
the same Session therefore cannot overlap callbacks from the completed Run.
The facade keeps the Session call gate through result/diagnostic publication;
an overlapping Run or destroy returns `METASK_AGENTCORE_STATUS_BUSY`. Releasing that gate is
the completion linearization point, after which the completed call no longer
reads Session storage and destroy may free it. Matching `session_abort` bypasses
this gate so it can remain useful while the synchronous Run is active.

`run_id` is a non-zero `uint64_t` Run identifier assigned by the Host and
scoped to one Session. Each admitted Run must have a `run_id` strictly greater
than that of the previously admitted Run in the same Session. Values need not
be contiguous, and different Sessions may use the same values. An admitted
`run_id` is consumed even if that Run is later aborted or fails during
execution; it must never be reused or wrapped. Rejection before admission never
advances the Session's last admitted `run_id`. An otherwise valid proposed
value strictly greater than the last admitted ID therefore remains available
for retry; zero and stale values do not become valid through retry. After
admitting `UINT64_MAX`, the Session cannot admit another Run and the Host must
create a new Session.

Every per-Run callback receives a borrowed `metask_agentcore_run_context_v1`. Its `session`
is the original public Session handle, its `run_id` is the admitted Run ID, and
its non-empty `session_id` is stable for that Session's lifetime and distinct
from every other live Session. The context and its `session_id` bytes are valid
only until that callback returns. A Host that retains identity must deep-copy
the bytes; pointer identity across callbacks is never promised. A shared Host
registry must bind the first observed ID and compare all later IDs atomically
under the same per-Session lock. A missing/invalid ID, unknown Session handle,
wrong active Run ID, or binding mismatch is a fatal callback-channel failure.

Run admission is the lifecycle boundary. Validation failures
(`METASK_AGENTCORE_STATUS_INVALID_ARGUMENT` / `METASK_AGENTCORE_STATUS_RESOURCE_LIMIT`) and admission
failures (`METASK_AGENTCORE_STATUS_BUSY` / `METASK_AGENTCORE_STATUS_STALE_RUN`) do not mutate the
Conversation and leave the Session in its previous usable state. Once a Run is
admitted, `METASK_AGENTCORE_STATUS_OUT_OF_MEMORY`, `METASK_AGENTCORE_STATUS_CORE_ERROR`,
`METASK_AGENTCORE_STATUS_CALLBACK_FAILED`, or `METASK_AGENTCORE_STATUS_INTERNAL_ERROR` means execution may
have committed Conversation changes or external side effects, so the Session
is poisoned. Subsequent Run and abort calls return
`METASK_AGENTCORE_STATUS_INVALID_STATE`; destroy remains valid. `METASK_AGENTCORE_STATUS_OK`, including a
terminal `METASK_AGENTCORE_STOP_ABORTED`, returns the Session to idle. A too-late abort also
leaves the already-idle Session reusable.

Given a valid Session handle, the poisoned-state check takes precedence over
remaining `session_run` and `session_abort` argument validation. ABI v1 does
not define status precedence when multiple other input or admission errors are
present in the same call.

ABI v1 provides no in-place recovery, Conversation export/import, or history
hydration for a poisoned Session. The Host must destroy it and create a new
Session; previously committed Conversation state cannot be restored through
ABI v1.

On a usable Session, `session_abort` requires a non-zero `run_id`; zero returns
`METASK_AGENTCORE_STATUS_INVALID_ARGUMENT`. While a Run is active, its exact `run_id`
requests cooperative abort and any other value returns
`METASK_AGENTCORE_STATUS_STALE_RUN`. While the Session is idle, the most recently admitted
`run_id` returns `METASK_AGENTCORE_STATUS_TOO_LATE` and any other value returns
`METASK_AGENTCORE_STATUS_STALE_RUN`. A poisoned Session returns
`METASK_AGENTCORE_STATUS_INVALID_STATE` regardless of the supplied ID.

Assistant text and other execution output are delivered through `on_event`.
`RunResultV1` is a terminal summary containing stop reason, turns, and tool
calls; it is not an output buffer. Its fields are defined only when
`session_run` returns `METASK_AGENTCORE_STATUS_OK`. On any non-OK status their contents are
unspecified and the Host must not inspect them. `on_event` is optional: without
it the Run still executes, but observation output is discarded. SDK-level
aggregation is a consumer convenience and does not change the ABI.

Relative paths supplied to `Read`, `Write`, `Edit`, `Glob`, and `Grep` resolve
against `workspace_root`; Bash also runs with that directory as its cwd.
`workspace_root` is an execution context, not a filesystem jail: absolute
paths remain usable unless the Host selects and configures a separate sandbox
policy. Invalid workspace paths, unavailable/duplicate selected tools, and a
shell tool selected under the disabled shell policy fail Session creation with
`METASK_AGENTCORE_STATUS_INVALID_ARGUMENT` and do not publish a Session handle.
`workspace_home` may be empty, in which case it defaults to the canonicalized
`workspace_root`; a non-empty value must be absolute.

ABI v1 has three ownership classes:

| Value | Owner and lifetime | Release |
|---|---|---|
| `metask_agentcore_bytes_view_v1` inputs and event/request views | Borrowed for the current synchronous call or callback | Never released |
| Host tool results and UI responses | Host-owned callback output | Canonical `{NULL,0}` is never released; every other descriptor is passed to its paired Host release callback exactly once, independent of status |
| AgentCore API diagnostics | Library-owned write-only output | Released only with the discovered `buffer_release` function |

Status controls whether callback output is consumed, not whether it is
released. `METASK_AGENTCORE_HOST_OK` consumes success text. `METASK_AGENTCORE_HOST_FAILED` and
`METASK_AGENTCORE_HOST_REJECTED` may consume UTF-8 detail for a model-visible ordinary tool
error; `METASK_AGENTCORE_HOST_FATAL` and unknown Host status codes ignore output after its
mandatory release and poison the Session. Only `METASK_AGENTCORE_UI_ANSWERED` consumes UI
response JSON. No callback or release callback has thread affinity.

The final `metask_agentcore_owned_bytes_v1 *` argument on AgentCore API calls is an optional,
write-only diagnostic output. AgentCore never reads or releases its previous
value; a Host must call `buffer_release` before reusing a variable that still
contains a diagnostic from an earlier call. Successful calls return canonical
empty. Diagnostic allocation is best-effort and never changes the primary
operation status. Host-owned callback output must never be passed to
`buffer_release`.

Host tool `execute` receives a borrowed `RunContext` and the provider-produced
tool arguments JSON. The context, its `session_id` view, and arguments view do
not remain valid after the callback returns.

### Callback and concurrency matrix

| Path | Concurrency/ordering | Failure semantics |
|---|---|---|
| `on_event` | Serialized within one Session; different Sessions may call shared Host state concurrently | Any value other than `METASK_AGENTCORE_EVENT_CONTINUE` aborts the Run and poisons the Session |
| Host tool `execute` | Different Sessions and parallel tool calls in one Session may invoke it concurrently | `METASK_AGENTCORE_HOST_FAILED`/`METASK_AGENTCORE_HOST_REJECTED` becomes a normal tool result; `METASK_AGENTCORE_HOST_FATAL` aborts and poisons without a model-visible tool result |
| `on_ui_request` | Synchronous in the Run path | `METASK_AGENTCORE_UI_UNAVAILABLE` is an ordinary reusable outcome; fatal/unknown status or invalid, mismatched, or oversized response aborts and poisons |
| release callbacks | Exactly once for every accepted Host-owned buffer; no thread affinity | Must not re-enter Run or destroy |
| `session_abort` | May run concurrently with the matching synchronous Run, including from a callback | Cooperative; callback or provider code that blocks can delay completion |

Callbacks may request abort. A callback attempt to re-enter Run or destroy on
the same handle returns `METASK_AGENTCORE_STATUS_BUSY`; callers must not spin or wait for that
operation from inside the callback. The Host must serialize create/destroy and
all operations other than matching abort on the same handle. C++ exceptions,
`longjmp`, and other non-local control transfers must never cross an AgentCore
callback or release-callback boundary.

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

V1 applies these limits to inputs or identities that amplify library
allocations or unbounded work:

| Limit | Value |
|---|---:|
| total Runtime tools; selected Session tools | 1024 |
| one Host tool schema | 1 MiB |
| Host tool schema nesting | 32 levels |
| top-level schema properties/required entries | 1024 |
| one synchronous UI response | 1 MiB |
| one raw Host tool success result or failure/rejection detail | 16 MiB |
| one encoded model-visible Host tool error payload | 1 MiB |
| one Session ID | 64 bytes |
| one Runtime/Session metadata string | 1 MiB |
| total Runtime metadata | 16 MiB |
| total Session metadata | 4 MiB |
| one Run | 1000 turns |

Configuration and pre-admission Run limits return
`METASK_AGENTCORE_STATUS_RESOURCE_LIMIT`. An oversized UI response is released exactly once,
returns `METASK_AGENTCORE_STATUS_CALLBACK_FAILED`, and poisons the Session because the Host
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

FAILED/REJECTED detail enters structured JSON only through AgentCore's
serializer. After decoding that JSON, the detail equals the Host's original
UTF-8 text, including quotes, backslashes, newlines, and control characters.
The 1 MiB error-payload limit is measured after escaping and serialization. If
the complete encoded payload would exceed it, AgentCore releases the Host
buffer and emits a bounded generic ordinary tool error instead; this does not
upgrade the outcome to fatal. Hosts must not place credentials in detail.
An encoded Host error payload is semantic model input: generic tool-result
persistence and per-message bulk-result budgets must not replace it with a
persisted or truncated envelope.

All empty `metask_agentcore_owned_bytes_v1` values use the canonical `{NULL, 0}` form. Host
UI fatal/invalid responses are infrastructure failures: they abort the active
Run, poison the Session, and surface as `METASK_AGENTCORE_STATUS_CALLBACK_FAILED` (or
`METASK_AGENTCORE_STATUS_OUT_OF_MEMORY` when response processing exhausts memory).

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
`struct_size`; every reserved field must be zero. During the current unfrozen
experimental period, a breaking v1 bundle increments `abi_revision` and
consumers accept only the exact revision they were built against. Reserved
storage is not permission to infer compatibility. After v1 is genuinely
re-frozen, later layout, function-table, or control-message extensions require
`metask_agentcore_get_api(2)` and v2 types.

Revision 2's published POD offsets and sizes require a 64-bit pointer ABI.
The header rejects 32-bit consumers at compile time; a future 32-bit contract
would need separately specified layouts and consumer gates.

`capabilities` reports the API surface implemented by the returned library
table. It is not per-Runtime or per-Session negotiation; concrete Runtime and
Session configuration still determines which tools and callbacks are active.

ABI v1 deliberately does not add session persistence/restore, asynchronous UI
continuations, ABI-level asynchronous operations, resume/checkpoint, strict Workspace
security, Workbench `Output`/`FileChange`/plan-progress models, or a
multi-platform universal bundle. Those are separate contracts, not hidden
behavior in the library facade. This does not remove Bash's existing
tool-managed background jobs, which remain reachable synchronously through
`Bash`, `BashOutput`, and `KillShell`.
