# AgentCore binary library ABI v1

The AgentCore bundle is a thin binary facade over the existing internal
execution engine. Consumers do not add implementation source to their build
graph, and the Host owns all UI. AgentCore is versioned and distributed as an
independent component; this ABI does not expose or define any host product.

ABI v1 is an experimental in-process embedding contract for synchronous,
stateful AgentSession execution. It does not expose or define a host product
model.

**Status: experimental.** The premature 2026-07-17 freeze was retracted after
consumer feedback exposed a dangling callback-identity contract. Revision 13
now defines one exact hard-cut wire shape after Permission authority,
checkpoint/restore, durable budget, MCP Runtime/Session seams, Workspace Skill
source/identity/policy binding, independent text Completion, explicit
hash-pinned process-tool package configuration, Host/MCP byte-zero Tool Result
streaming, and the optional active-Run intent/result journal were implemented
and tested. This is not a general v1 stability promise.

Consumers must pin an exact bundle (the manifest records the source commit)
and treat a different revision as incompatible. Layouts, numeric values,
function-table order, and semantics may change only through another explicit
revision cut while v1 remains experimental.

The current experimental bundle is **ABI v1 revision 13**. Revision 13 is a
hard-cut replacement for every earlier revision. It retains Revision 12's
mandatory, distinct MCP `tools/call` stream operation and adds an explicit
Session durability mode for the unified provider/tool journal. The function
table, `RuntimeConfigV1`, and the 168-byte `SessionHostConfigV1` size remain
unchanged; revision 13 assigns the former Host-config reserved bytes at offsets
136..143 to `run_journal_mode_code` plus a required-zero `reserved0`:

- `metask_agentcore_api_v1` is 280 bytes and requires `abi_revision == 13`;
- `RuntimeConfigV1`, `SessionHostConfigV1`, `SessionCreateConfigV1`,
  `SessionRestoreConfigV1`, `RunInputV1`, and `RunResultV1` are respectively
  96, 168, 64, 64, 104, and 72 bytes on the required 64-bit ABI;
- `ProcessPluginSourceV1` and `RuntimePluginConfigV1` are respectively 48 and
  72 bytes; `HostResultSinkV1` and `HostStreamToolV1` are respectively 56 and
  96 bytes; `runtime_create_with_plugins` is mandatory while the original
  `runtime_create` remains valid for a Runtime with no process packages;
- `McpConnectorV1` and `McpServerV1` are respectively 88 and 232 bytes;
  `McpResponseV1` is 40 bytes and carries the final HTTP status beside its
  Host-owned bounded control-frame body;
  `request` remains the bounded control-frame operation and
  `request_tool_stream` is mandatory for `tools/call`;
- checkpoint, restore, describe, MCP refresh/describe/apply/selection,
  Permission rule update, compact, abort, and all eight Completion entries are mandatory;
- `SkillSourceV1`, `SkillPolicyV1`, and `SkillCatalogQueryV1` are respectively
  64, 56, and 80 bytes; `CompletionConfigV1`, `CompletionMessageV1`,
  `CompletionRequestV1`, `CompletionResultV1`, `CompletionInfoV1`, and
  `CompletionEventV1` are respectively 88, 40, 72, 72, 48, and 80 bytes;
- the exact required capability set is `0x3ffffff`, including
  `CAP_MCP_TOOL_STREAM = 1 << 24` and `CAP_ACTIVE_RUN_JOURNAL = 1 << 25`;
- `manifest.json` records revision 13, table size 280, and that exact capability
  set.

Revision 13 provides no earlier AgentCore revision compatibility, shim, dual dispatch, or old
table layout. Consumers update the header, SDK, manifest, and library
atomically, validate the stable
`struct_size`/`abi_version` prefix before reading later fields, then require
exact revision, table size, capability, reserved-field, and function-identity
matches. Every per-Run callback validates and copies any retained `RunContext`
fields during the callback, and Host registries bind/compare `session_id`
atomically under their per-Session lock.

Revision 13 deliberately exposes explicit process-package sources, their
namespaced `host_tool` contributions, and explicit Host stream-tool
descriptors. It does not expose the generic
data/static plugin grouping model or `metacodes.plugin-inventory/v1`; those
remain available through the source-level Zig Runtime plus CLI/Web JSON Host
interfaces. Projecting generic inventory into this binary table requires a
later explicit ABI revision. A revision-13 consumer must not infer plugin
identity from tool or Skill names, and every reserved field remains zero.

A future stability freeze first requires closure of the open items tracked in
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
and runs the Rust ABI link probe plus crate unit tests. macOS bundles are
repacked from their object members with Apple `ar`/`libtool` before manifest
hashing; this preserves bundled `compiler_rt` while satisfying Apple `ld`'s
8-byte Mach-O archive-member alignment. A non-macOS build host therefore fails
closed instead of publishing a macOS AgentCore archive it cannot normalize.

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
| `x86_64-windows-msvc` | previously verified; current Homebrew Zig host cannot re-link without Windows SDK/import libraries | earlier revision-12 C/C++/Zig/Rust source-free evidence retained; revision 13 not revalidated on this host |
| `x86_64-windows-gnu` | previous revision-12 ReleaseSafe source-free bundle and full CLI cross-build/link verified | revision 13 pending cross-build and native Windows gate |
| `x86_64-linux-gnu` | previous revision-12 ReleaseSafe source-free bundle and full CLI cross-build/link verified | revision 13 pending cross-build and native Linux gate |
| `x86_64-macos` | previous revision-12 ReleaseSafe source-free bundle cross-build/link verified | revision 13 pending cross-build and native Intel macOS gate |
| `aarch64-macos` | verified | revision 13 C/C++/Zig/Rust source-free ReleaseSafe gate passed, including durable journal creation across fresh/restore and continued Runs |

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
`UiRequest`, `UiResponse`, and Skill-catalog wire types, their typed decoders,
the request-aware UI response encoder, and the bounded Skill-arguments
encoder. `bindings/zig/src/root.zig` re-exports both layers beside raw API-table
access.

`decodeCoreEvent` returns an owned `ParsedCoreEvent` whose value is either
`known: CoreEvent` or `unknown: { tag, payload_json }`. This lets an older Host
ignore or retain a valid observation event added by a newer ABI-v1 library.
The common known-event path scans the top-level tag and performs one typed
parse; only an unknown tag pays for a dynamic JSON tree.
`decodeUiRequest` and `decodeUiResponse` remain strict because an unknown
control message cannot be answered safely. All decoded strings and arrays
remain valid until `deinit`; consumers must not copy an owner and deinitialize
both copies.

`decodeSkillCatalog` returns an owned `ParsedSkillCatalog` for
`metask.skill-catalog/v1`. Revision 13 hard-cuts the current experimental shape
of that schema: every earlier unreleased experimental shape bearing the same
token is void, and consumers must interpret the descriptor only with the exact
Revision 13 bundle they pin. The decoder validates the
schema, the 1024-Skill limit, identity forms, duplicate concrete `skill_id` or
`skill_policy_key` records, health and issue consistency, and each Skill
argument schema. AgentCore remains the canonical producer and independently
enforces those uniqueness invariants before publication. Because decoded
strings and arrays are allocator-owned, the consumer may release the AgentCore
descriptor buffer immediately after decoding.
`encodeSkillArguments` accepts positional UTF-8 values, enforces the 64-value
and encoded 1 MiB limits, and returns the allocator-owned canonical
`{"values":[...]}` representation accepted by `sessionRunSkill`.

```zig
var parsed = try sdk.decodeCoreEvent(allocator, event_json);
defer parsed.deinit();
switch (parsed.value) {
    .known => |event| consume(event),
    .unknown => |event| retainOrIgnore(event.tag, event.payload_json),
}

var catalog = try sdk.decodeSkillCatalog(allocator, descriptor_json);
defer catalog.deinit();

const arguments_json = try sdk.encodeSkillArguments(
    allocator,
    &.{ "src/main.zig", "deep" },
);
defer allocator.free(arguments_json);
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
| `thinking_chunk` | Model reasoning delta, separate from visible assistant text and final-output reconstruction |
| `stream_done` | One provider stream completed |
| `tool_start` | Tool invocation identity, name, and input |
| `tool_progress` | Incremental progress text for one tool call |
| `progress` | Current 1-based turn and cumulative tool-call progress |
| `tool_result` | Completed tool result, error flag, elapsed time, and optional successful file observations |
| `usage` | Token-usage delta |
| `context_warning` | Context-pressure thresholds and level |
| `auto_compact` | Conversation compaction summary |
| `retry_notice` | Provider retry attempt and delay |
| `run_state` | Root Run phase snapshot, per-Run transition sequence, turn/tool-call sample, and owned in-flight tool identities |
| `permission_provenance` | Final Permission decision, canonical source, request binding, generation, and typed callback outcome |

Events describe observations, not commands. A Host may render, aggregate,
persist, or ignore them; consuming an event never drives the core execution
loop.

`on_event` is mandatory in Revision 13. `run_state` is emitted for admitted-run
start, phase/tool-set/turn/tool-call changes, and terminal closure; it is not a
mirror of text or usage deltas. Its `transition_seq` starts at 1 for each Run
and advances only for emitted RunState snapshots. Usage remains authoritative
in the existing usage event stream. To reconstruct final visible assistant
output, a Host accumulates only closed segments: `text_chunk` appends to the
current segment and `stream_done` closes it. `tool_start` and `tool_result` are
semantic boundaries that discard any unclosed segment and all previously
closed accumulated segments; consecutive boundaries are idempotent and
`tool_progress` and `thinking_chunk` are not boundaries. The final output is
the concatenation of all closed segments after the last boundary, or all closed
segments when no boundary occurred. This preserves max-token continuations
while excluding pre-tool drafts. `thinking_chunk` never contributes to the
current segment or final output. Usage events are exact deltas and must use
checked arithmetic.

`thinking_chunk` is an additive ABI-v1 observation event. An older Host may
decode it through the `unknown` observation path and ignore or retain it in
accordance with the forward-compatibility rules above.

`tool_result.file_refs` is an optional Revision 13 observation field. It is
present only for successful selected built-in file-tool executions and contains
at most 32 entries. Each entry has one locator union (`workspace_path`,
`absolute_path`, or `uri`), an open-ended bounded `kind` string, a bounded
title, and an optional range whose `start`/`end` each contain 1-based `line`
and UTF-16 `column` positions (half-open). The v1 limits are 4096
bytes per path, 8192 bytes per URI, 256 bytes per title, and 64 bytes per kind.
The field is evidence only: the Host decides whether and how to open a target;
an absolute locator does not grant authorization. Failed, denied, rejected,
unobserved, or unavailable executions do not emit write-class references.

## Contract

`metask_agentcore_get_api(1)` is the only discovery symbol. ABI v1 exposes
opaque Runtime, Session, and Skill-catalog handles, synchronous typed Runs,
abort, built-in and synchronous Host tools, tagged CoreEvent JSON, and
synchronous Host UI JSON.
Runtime copies Host tool metadata and callback references and must outlive every
Session. The Host retains ownership of each Host tool `ctx` and keeps it valid
until Runtime destruction succeeds. Session owns provider credentials,
workspace inputs, tool selection, Conversation, permission memory, jobs, and
Run state and an optional retained catalog snapshot. Session callback
descriptors are copied at creation; the Host retains
their `ctx` and keeps it valid until Session destruction succeeds.

### Process-plugin Runtime configuration

Revision 13 uses `runtime_create_with_plugins(runtime_config, plugin_config,
out_runtime, out_diagnostic)`. Both config pointers are required; an empty,
well-formed `RuntimePluginConfigV1` creates the same no-process Runtime shape as
the original `runtime_create`. Descriptor arrays and path bytes are borrowed
only until the call returns. A successful Runtime owns an immutable copy of all
published plugin/tool state, while a failed call publishes no Runtime.

`RuntimePluginConfigV1` accepts at most 64 `ProcessPluginSourceV1` records and
at most 1024 Host stream tools subject to the Runtime-wide tool ceiling. Each
source has an absolute UTF-8 package root and one exact layer code:
`BUILTIN`, `PERSONAL`, `PROJECT`, `SESSION`, or `MANAGED`. Higher layers win for
the same PluginId; duplicates at one layer, invalid dependencies, contribution
collisions, relative paths, symlinked package roots, malformed/reserved fields,
or any strict manifest/process/handshake failure reject Runtime creation. A
non-empty process source set fails closed on Windows in process protocol v1.

### Host byte-zero Tool Result streaming

`HostStreamToolV1` is a distinct descriptor rather than optional fields on
`HostToolV1`; one tool therefore cannot inhabit both the completed-buffer and
streaming states. The descriptor metadata is borrowed only during Runtime
creation and copied into the immutable Runtime. Its `ctx` remains Host-owned
until Runtime destruction succeeds.

For each admitted invocation AgentCore creates a private Session spool before
calling `execute_stream`. The callback receives one synchronous, borrowed,
write-only `HostResultSinkV1`. It may call `write` sequentially with arbitrary
byte slices, including empty slices, but must not retain the sink, use it from
another thread, or call it after `execute_stream` returns. AgentCore alone owns
commit and rollback authority. The sink reports exact `HOST_SINK_*` status:
aborted, over the 128 MiB artifact maximum, failed I/O, and closed are latched,
so later writes and an attempted successful return cannot hide an earlier
failure.

`HOST_OK` requires a known non-zero media code, canonical empty detail, and a
healthy sink. It always commits an artifact receipt—even when the payload is
small—so this registration type has one deterministic result shape. The
Conversation receives only the stable content-addressed envelope, SHA-256,
length, media type, and fixed head/tail preview; no temporary or machine-local
path enters model input. Equal byte streams therefore produce equal model
input, and `ReadArtifact` is frozen into the Session tool directory before the
first provider request, preserving the prompt-cache prefix.

`HOST_FAILED`, `HOST_REJECTED`, `HOST_FATAL`, malformed status/media/detail,
callback errors, cancellation, and sink failures discard every partial byte
and publish no CAS object. Failure/rejection detail follows the existing
bounded UTF-8 ownership contract and is released exactly once; success detail
is illegal. A callback should stop producing immediately after a non-OK sink
status. `session_run_input` remains the callback quiescence boundary.

Each contributed provider name is the reversible namespaced global tool name,
is classified as native `execute`, and remains subject to Session selection,
Permission, budget and abort. Permission identity uses the existing public
`host` namespace plus a non-zero 32-byte binding derived from plugin id,
version, pinned executable SHA-256, global tool name and validated reserialized
input schema.
The binding—not the display name alone—enters Permission provenance and
checkpoint authority resolution. Process tools deliberately have no
`allow_session`/`deny_session` candidate in revision 13, so a Host may answer
only the offered one-shot choices unless an independent native rule decides
first. Changing executable/package/schema authority invalidates a restored
binding instead of silently reauthorizing the new implementation.

The child protocol, empty-environment behavior, entrypoint containment/hash
checks, handshake, framing, timeout/output caps, process-group cancellation and
reaping rules are normative in `PLUGIN_PROCESS_PROTOCOL.md`. This ABI is a
configuration path into that kernel-owned executor; it does not turn the child
into a Host callback or expose a raw kernel pointer.

One Session accepts one active Run at a time. A successful Run returns to idle
and the Host may start another Run on the same stateful Conversation. `Status`
describes whether the ABI call itself succeeded. `StopReason` is meaningful
only when `session_run_input` returns `METASK_AGENTCORE_STATUS_OK` and is one of `end_turn`,
`max_turns`, `aborted`, `tool_error`, `api_error`, `tool_loop`,
`checkpoint_budget_exhausted`, or `checkpoint_resource_limit`. The last two are
the public durable-budget terminals
`METASK_AGENTCORE_STOP_CHECKPOINT_BUDGET_EXHAUSTED` and
`METASK_AGENTCORE_STOP_CHECKPOINT_RESOURCE_LIMIT`; their detailed outcome is
also reported through `RunResultV1.checkpoint_outcome_code` and result flags.
Internal `suspended`, `backgrounded`, and a raw unprojected Core `budget` stop
remain unrepresentable in v1. If one of those internal states reaches the
facade it is a contract failure, not an additional public stop code. Because
the stateful Run may already have committed Conversation changes, that failure
poisons the ABI facade and subsequent Run or abort calls return
`METASK_AGENTCORE_STATUS_INVALID_STATE`; destroy remains valid.

The synchronous `session_run_input` return is a quiescence boundary: every callback
started for that Run, and every paired release callback for its Host-owned
outputs, has completed before the call returns. Callbacks from the next Run on
the same Session therefore cannot overlap callbacks from the completed Run.
The facade keeps the Session call gate through result/diagnostic publication;
an overlapping Run or destroy returns `METASK_AGENTCORE_STATUS_BUSY`. Releasing that gate is
the completion linearization point, after which the completed call no longer
reads Session storage and destroy may free it. Matching `session_abort` bypasses
this gate so it can remain useful while the synchronous Run is active.
That exception permits overlap only with the matching Run. It does not permit
any later Session call to overlap an in-flight abort call.

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

Run admission is the `run_id` lifecycle boundary. Validation failures
(`METASK_AGENTCORE_STATUS_INVALID_ARGUMENT` /
`METASK_AGENTCORE_STATUS_RESOURCE_LIMIT`) and admission failures
(`METASK_AGENTCORE_STATUS_BUSY` / `METASK_AGENTCORE_STATUS_STALE_RUN`) do not
mutate the Conversation or consume `run_id`. Skill materialization occurs
after admission but before Conversation mutation: failure there consumes
`run_id`, cleans the activation, and returns the Session to idle. Once
Conversation mutation or provider/tool execution begins,
`METASK_AGENTCORE_STATUS_OUT_OF_MEMORY`,
`METASK_AGENTCORE_STATUS_CORE_ERROR`,
`METASK_AGENTCORE_STATUS_CALLBACK_FAILED`, or
`METASK_AGENTCORE_STATUS_INTERNAL_ERROR` poisons the Session because execution
may have committed Conversation changes or external side effects. Subsequent
Run and abort calls then return `METASK_AGENTCORE_STATUS_INVALID_STATE`;
destroy remains valid. `METASK_AGENTCORE_STATUS_OK`, including a terminal
`METASK_AGENTCORE_STOP_ABORTED`, returns the Session to idle. A too-late abort
also leaves the already-idle Session reusable.

Durable pre-admission uses exact canonical records that are available without
effects: a Text prompt or a typed Skill invocation record. Skill body
rendering can read files or execute admitted shell injection, so it remains
after Run admission. Its exact durable delta is reconciled atomically before
Conversation mutation; input-cap excess becomes a resource-limit terminal and
insufficient durable capacity becomes budget-exhausted. AgentCore never moves
materialization or shell execution before admission merely to estimate bytes,
and it does not reserve the entire configured input cap for every Skill.

Given a valid Session handle, the poisoned-state check takes precedence over
remaining `session_run_input` and `session_abort` argument validation. ABI v1 does
not define status precedence when multiple other input or admission errors are
present in the same call.

ABI v1 provides no in-place recovery or mutation of a poisoned Session. The
Host must destroy that physical handle. Revision 13 checkpoint/restore creates
a new handle from a previously exported committed checkpoint; it does not
reconstruct state that was never successfully exported or resume an active
Run.

When facade poison occurs after Core has returned to an inspectable idle state,
`session_describe` succeeds and reports lifecycle `poisoned`; it must not report
`idle`. An active ordinary Session activity makes `session_describe` return
`METASK_AGENTCORE_STATUS_BUSY`, so a successful Revision 13 description does not
emit lifecycle `busy`.

A checkpoint is resumable model state, not a raw transcript archive. Before
compact it contains the complete Conversation. After compact it contains the
summary plus active messages and omits the hidden raw prefix already replaced
by that summary. Restore materializes the summary as leading assistant context,
so continued Runs and later compaction preserve the same model-visible state.
The checkpoint `max_messages` limit counts that materialized summary as one
message in addition to the encoded active-message count.
Hosts that require verbatim historical audit must persist the event/transcript
stream separately. This projection is what allows compact to reduce durable
usage for a near-hard Session.

On a usable Session, `session_abort` requires a non-zero `run_id`; zero returns
`METASK_AGENTCORE_STATUS_INVALID_ARGUMENT`. While a Run is active, its exact `run_id`
requests cooperative abort and any other value returns
`METASK_AGENTCORE_STATUS_STALE_RUN`. While the Session is idle, the most recently admitted
`run_id` returns `METASK_AGENTCORE_STATUS_TOO_LATE` and any other value returns
`METASK_AGENTCORE_STATUS_STALE_RUN`. A poisoned Session returns
`METASK_AGENTCORE_STATUS_INVALID_STATE` regardless of the supplied ID.

### Manual compact

`session_compact` runs the canonical default compact policy as a best-effort
Conversation maintenance operation. Revision 13 has no Host-supplied target
token budget and does not guarantee that the result fits the context window of
the current or a future model. `session_set_model` and `session_compact` are
independent primitives, not a compound model-migration transaction.

On `METASK_AGENTCORE_STATUS_OK`, `CompactResultV1.before_context_tokens` and
`after_context_tokens` are context-size estimates for UI and policy decisions;
they are not provider billing values. The four provider usage-delta fields are
semantically separate. `METASK_AGENTCORE_COMPACT_DEGRADED` exposes no structured
reason in Revision 13, and a Host must not infer one by parsing diagnostics.

Assistant text and other execution output are delivered through `on_event`.
`RunResultV1` is a terminal summary containing stop reason, turns, and tool
calls; it is not an output buffer. Its fields are defined only when
`session_run_input` returns `METASK_AGENTCORE_STATUS_OK`. On any non-OK status
their contents are unspecified and the Host must not inspect them.

Relative paths supplied to `Read`, `Write`, `Edit`, `Glob`, and `Grep` resolve
against `workspace_root`; Bash also runs with that directory as its cwd.
`workspace_root` is an execution context, not a filesystem jail: absolute
paths remain usable unless the Host selects and configures a separate sandbox
policy. Invalid workspace paths, unavailable/duplicate selected tools, and a
shell tool selected under the disabled shell policy fail Session creation with
`METASK_AGENTCORE_STATUS_INVALID_ARGUMENT` and do not publish a Session handle.
`workspace_home` may be empty, in which case it defaults to the canonicalized
`workspace_root`; a non-empty value must be absolute.

### Active-Run intent/result journal

`SessionHostConfigV1.run_journal_mode_code` is part of the exact revision-13
wire contract and accepts only:

- `METASK_AGENTCORE_RUN_JOURNAL_EPHEMERAL` (`0`): the default, zero-journal-I/O
  embedded profile;
- `METASK_AGENTCORE_RUN_JOURNAL_DURABLE_WORKSPACE` (`1`): append and fsync the
  unified journal under
  `<workspace_home>/.metacodes/agentcore/sessions/<session_id>/`.

The durable profile writes the Run start before provider/tool execution, one
intent/result pair for every physical provider attempt and actual tool
dispatch, then the terminal Run record. Failed provider attempts remain
billable evidence even when no assistant message is committed; absence of a
provider usage object is encoded as unknown, not synthetic zero. Built-in,
Host, process-plugin, MCP, and fork-Skill tools converge on the same journal.
Replay classification is kernel-owned: read-only built-ins may be classified
safe, while Host/plugin declarations without an invocation-bound receipt are
downgraded to never.

The journal is outside Conversation and provider request projection. Enabling
it therefore does not insert prompt bytes, reorder history, or invalidate a
warm prompt-cache prefix. An unfinished pair or retained crash marker fails
closed; revision 13 does **not** expose in-place active-Run resume, automatic
tool replay, or exactly-once external effects. It provides durable evidence
and deterministic recovery classification for a later explicit recovery API,
not authority to guess whether an external side effect occurred.

### Skill catalog and typed input

`runtime_query_skill_catalog` is independent of Session lifetime so a Host may
render a Skill menu before creating its first Task or Session. It resolves one
Workspace authority; it is not a directory-scan mode switch. The safe Zig SDK
therefore deliberately aliases this raw table slot as
`resolveWorkspaceSkillCatalog`.

A successful query returns both an immutable catalog handle and a
library-owned descriptor using schema `metask.skill-catalog/v1`. The descriptor
contains a Runtime-local `catalog_scope_id`, content-derived
`catalog_revision`, health, valid `skills[]`, and typed `issues[]`; it never
contains Skill bodies, physical paths, policy internals, or execution mode.
Isolated invalid slots produce `OK + degraded`. Failure to prove the whole
snapshot complete returns `SKILL_CATALOG_INCOMPLETE`, a null handle, and an
empty descriptor. Structural/resource-limit failures use their dedicated
statuses and likewise publish no partial snapshot.

Every issue carries `kind = invalid | unavailable | conflict`, its typed code,
logical `skill_policy_key`, and provider/source provenance. An
`invalid_resource` issue always carries a typed `reason`; every other issue
code carries `reason: null`. The resource reasons are `file_too_large`,
`skill_too_large`, `too_many_files`, `too_many_entries`,
`directory_too_deep`, `path_too_long`, `unsupported_entry`,
`resource_unavailable`, and `resource_changed`. A failing selected Skill never
falls back to a lower-priority candidate with the same invocation name.

An absent source root contributes no candidates. Any other failure to open,
enumerate, or prove the stability of a source root is a catalog-global
discovery failure. Failure to open or stably inspect one entry below that root
is a failed candidate: it remains subject to normal
invocation-name precedence and, if selected, produces a local resource issue.
An uncertain higher-priority candidate therefore never silently exposes a
lower-priority Skill with the same invocation name.

`SkillCatalogQueryV1.reserved0` must be zero. Default discovery merges exactly
`<workspace_home>/.agents/skills` as User scope and
`<workspace_root>/.agents/skills` as Workspace scope; Workspace wins across
scopes. If the canonical paths are equal, AgentCore registers only the
Workspace contribution, avoiding a synthetic self-conflict.

The Host may add at most 64 `SkillSourceV1` local directories. Each source has
scope `SKILL_SOURCE_USER` or `SKILL_SOURCE_WORKSPACE` and a 1..128 byte stable
ASCII `source_instance_id` using letters, digits, `.`, `_`, `:`, or `-`.
Duplicate canonical roots or source ids are invalid. Additional sources have
the same precedence as defaults in their declared scope; two same-scope
candidates with one invocation name are a conflict, never registration-order
override. There is no public numeric priority.

Resource accounting includes every regular file below the selected Skill root,
including `SKILL.md` and hidden files; no ignore file is applied. Every regular
file counts toward entry, traversal, file, and content limits. Directories and
special entries count only toward the per-Skill entry and catalog traversal
limits. Symlinks and other special entries produce `unsupported_entry`.
Relative paths use UTF-8 bytes, `/` separators, no Unicode normalization, and
no case folding. MiB means `1024 * 1024` bytes. The initial source enumeration
defines the candidates for one query; later additions are observed by a
subsequent query. Atomicity means that the completed immutable snapshot is
published once, not that the Host filesystem is transactional.

AgentCore does not implicitly read `/etc/metacodes/skills`, `.claude/skills`,
`.codex/skills`, or `.metacodes/skills`. A Host may explicitly register any
local directory only when its contents already use the canonical Agent Skill
format. Directory names do not select a parser; Revision 13 has no Claude/Codex
format adapter or public Provider Registry. The projected provider id is
`agents.directory`.

Each valid `skills[]` entry exposes separate identities:

- `skill_policy_key`: the logical invocation slot, equal to
  `invocation_name` in Revision 13;
- `provider_id`, `source_scope`, `source_instance_id`, and `contribution_id`:
  source identity;
- `content_revision`: body/resources identity;
- `skill_id`: the concrete source + contribution + content execution identity.

`skill_id`, `contribution_id`, `content_revision`, and `catalog_revision` are
64-character lowercase hexadecimal digests. A content change creates a new
`content_revision` and `skill_id`. Policy and execution never authorize a bare
logical name.

Each valid `skills[]` entry contains this fixed argument-schema shape:

```json
{
  "argument_schema": {
    "schema": "metask.skill-arguments/v1",
    "max_values": 64,
    "names": ["target", "scope"]
  }
}
```

`names[]` supplies ordered positional labels for consumer UI:
`arguments_json.values[i]` corresponds to `names[i]`. Names do not declare
required arity. A caller may submit zero through `max_values` strings, including
values beyond `names.len`; `max_values` is the wire upper bound.

`workspace_epoch` is an opaque byte token supplied by the Host. It is compared
only for byte equality inside one canonical Workspace scope and need not be
parseable, monotonic, or comparable across Hosts. Canonical empty `{NULL,0}`
means that the Host has no external Workspace generation. The Host changes the
token when its external Workspace binding generation changes. The token enters
the catalog-revision hash, so changing it produces a new revision and may make
an input prepared for a differently bound Session return `STALE_CATALOG`.

The Host releases its catalog handle exactly once with
`skill_catalog_release`. Session create and idle-only rebind retain their own
reference, so the Host may release its handle immediately after either call
succeeds. A catalog must belong to the same Runtime and canonical Workspace
binding.

`SkillPolicyV1` is default-deny and lists only granted concrete `skill_id`
values. Empty means deny all. Session create/restore require Catalog and Policy
to be both present or both absent. The raw `session_update_skills` slot (safe
SDK alias `sessionBindSkillPolicy`) jointly validates the replacement Catalog
and Policy and atomically commits them only while idle. Any failure preserves
the complete previous binding; it never partially disables exceptions or
unbinds the old catalog. Rebind does not modify Conversation or `run_id`.

`session_run_input` accepts exactly one tagged input:

- `RUN_INPUT_TEXT`: only `text` is non-empty; it is bounded to 16 MiB before
  pointer access or UTF-8 decoding. Slash-looking text has no special meaning.
- `RUN_INPUT_SKILL`: `text` is canonical empty and the Session must have a
  bound catalog. `skill_id`, `catalog_revision`, and `arguments_json` identify
  an explicit Host invocation. Arguments are canonical empty or
  `{"values":["..."]}`, with at most 64 values and 1 MiB encoded JSON.

Observable validation order is fixed: malformed wire/identity is
`INVALID_ARGUMENT`; mismatched pinned revision is `STALE_CATALOG`; an unknown
concrete id is `SKILL_NOT_FOUND`; an ungranted concrete id is
`SKILL_POLICY_VIOLATION`; malformed values are `INVALID_SKILL_ARGUMENTS`; and
unavailable execution is `SKILL_UNAVAILABLE`. These failures occur before Run
admission and do not advance `run_id` or mutate Conversation.
Materialization begins only after admission, is private to that activation,
and is removed before terminal return. A Skill can only narrow the Session's
tool, shell, and permission authority.

Text input and typed Skill input share one root-record admission invariant.
Text reserves its exact prompt record; Skill reserves its exact canonical
invocation record before admission. Skill body rendering may read referenced
files or run declared shell injection, so it remains inside the admitted Run.
Before Conversation mutation, AgentCore atomically replaces the invocation-only
estimate with the exact generated root records. Input-cap failure becomes a
bounded resource-limit outcome and durable-budget shortage becomes a
budget-exhausted outcome. AgentCore neither reserves the entire input cap as a
fictional Skill payload nor moves effectful materialization before admission.

The Session configuration owns the provider model binding. Skill metadata
cannot replace it: inline Skills ignore `model`, fork Skills with an empty
model or `inherit` use the Session model, and any other fork model is
unavailable in AgentCore. An explicit typed invocation returns
`SKILL_UNAVAILABLE` before admission, so it does not consume `run_id`,
materialize, mutate Conversation, or send a provider request. The Run-local
`Skill` tool reports the same condition as an ordinary structured tool error
with code `ModelOverrideUnavailable`; it does not create a child Run or poison
the outer Run. Every admitted fork child therefore sends the Session model.

A consumer normally uses the Skill ABI in this order:

1. During draft creation, resolve a complete Workspace catalog and render its
   descriptor. On `SKILL_CATALOG_INCOMPLETE`, retain the last-good result.
2. Build a default-deny Policy from concrete descriptor ids and create a
   Session bound to Catalog + Policy.
3. Release the Host's catalog handle; the Session retains its own reference.
4. Submit `RUN_INPUT_SKILL` with an identity and revision from that descriptor.
5. On `STALE_CATALOG`, query again, re-resolve and re-authorize the concrete
   identity from the new descriptor, wait until the Session is idle, atomically
   rebind Catalog + Policy, release the new Host handle, and retry with the same
   `run_id` because the rejected Run was never admitted.

Changing source files alone does not mutate a Session's immutable snapshot;
the old body and resources remain pinned and executable until rebind.
`STALE_CATALOG` means that the input revision differs from the revision
currently bound to the Session. If the new descriptor removes the Skill or
reports it as an issue, the consumer must not blindly retry.

The internal Workspace scope-identity domain remains
`metask-agentcore/abi-v1/revision-5`. It identifies the scope algorithm first
introduced in Revision 5 and is intentionally independent of the current ABI
revision so compatible checkpoint Workspace bindings remain stable.

When a bound snapshot contains at least one model-invocable Skill, AgentCore
adds one Run-local provider tool named `Skill` to both Text Runs and explicit
Skill Runs. It is an internal projection, not another ABI entry point. Its
input is exactly `{"name":"<invocation_name>","values":["..."]}`; `values` is
optional, `origin` and all other fields are invalid, and names resolve only in
the snapshot pinned by that Session. The tool schema and description omit
`disable-model-invocation` Skills. Guessing such a name still fails closed as
an ordinary tool result and never falls back to prompt text.

Inline and fork calls reuse the same typed activation, materialization, and
immutable PolicyFrame lineage as explicit input. Nested activation starts
from the current frame and therefore cannot restore authority removed by an
outer Skill. `Skill` is a serialization boundary: no later tool call in the
same provider response may be speculatively executed before its policy change.
Inline materializations live until Run quiescence; fork execution is
synchronous within the same Host Run and projects its public text and usage
through the ordinary event stream. The provider tool name `Skill` is reserved:
Runtime creation rejects a Host tool with that name.

Fork children cannot suspend for Host UI interaction in Revision 13. Their UI
requester is unavailable, so a child question or permission request fails
closed as an ordinary fork/tool failure attributed to the outer Run. Inline
execution may use the outer Run's synchronous UI callback.

AgentCore exposes no slash parser, Command registry, route field, or
product-specific command. A consumer resolves its own Commands first, maps a
catalog hit to typed Skill input, and treats an unresolved slash as its own
product decision.

### MCP Runtime catalog and Session view

Revision 13 supports exact MCP `2026-07-28`, `2025-11-25`, and `2025-06-18`
connections. Public negotiation codes preserve Revision 6 meanings:
`auto=1`, `modern_only=2`, and exact `legacy_only=3`; exact
`legacy_2025_06_only=4` is appended. Runtime owns negotiation,
transport, canonical catalogs, cache expiry, and immutable generations;
Session owns only a filtered selection, while each Run pins an admitted Tool
environment. Credentials, live connections, and request state never enter a
Session checkpoint.

`auto` probes Modern first. A validated `MethodNotFound` may enter Classic;
stdio probe timeout or child exit may also enter Classic. For Streamable HTTP,
a completed response is reported as `MCP_EXCHANGE_RESPONSE` with its final HTTP
status and body. A bare HTTP 400 from the disposable `server/discover` probe is
Classic evidence; a complete, request-id-matching JSON-RPC response overrides
that default. Strictly valid `-32022` data contributes its `supported` versions,
and malformed typed `-32022`, other JSON-RPC errors, 401/403, every status other
than 2xx/400, and transport failures do not downgrade. No body-shape or string
heuristic is used. Classic starts with an exact 2025-11 request. If that response
selects 2025-06, Runtime closes the connection and reopens exact 2025-06 once.
Only the final exact-era handshake may publish capabilities or create the
operational client.

The Host-owned Connector is also the MCP transport compliance boundary. Every
successful `open` must create a connection context permanently bound to the
provided purpose and exact `requested_era_code`. For Streamable HTTP, the Host
must retain response headers and attach the exact era as
`MCP-Protocol-Version` to every request after successful initialization; when
the server returns `MCP-Session-Id`, the Host must retain it in that connection
context and send it on subsequent HTTP requests. Disposable probes, actual
connections, and connections reopened for another era must not share
`MCP-Session-Id` values or other connection-scoped mutable protocol state.
Host-configured credentials, including authentication cookies, may be reused
only within the same authentication context. The Host must never change an
existing connection's era after inspecting an initialize response: AgentCore
closes a mismatch and performs the exact-era reopen itself.

The `metask_agentcore_mcp_cancellation_v1` descriptor, its `ctx`, and its poll
callback are borrowed only for the synchronous request or notification callback
invocation. A Host must not retain the descriptor or poll it after that callback
returns.

| Responsibility | Owner |
|---|---|
| Candidate selection and validation of the server-selected protocol | AgentCore |
| Closing a mismatch and performing an exact-era reopen | AgentCore |
| JSON-RPC request bodies and Classic lifecycle ordering | AgentCore |
| Probe HTTP status gate, JSON-RPC validation, and era selection | AgentCore |
| HTTP headers, authentication, cookies, session IDs, and connection pooling | Host Connector |
| Reporting every completed HTTP response's final status and body | Host Connector |
| Binding one connection context to `purpose_code` and `requested_era_code` | Host Connector |

Revision 13 separates MCP control and result traffic in the type system.
`McpConnectorV1.request` writes a 40-byte `McpResponseV1` only for bounded
discovery/initialize/catalog control frames. Stdio responses use
`http_status == 0`; Streamable HTTP completed responses use their final status
in the range 200..599. Non-response outcomes use status zero and an empty body.
`release_response` keeps its signature: canonical `{NULL,0}` is never released;
for every other body token AgentCore calls it exactly once with
`&response.body`, including an invalid `{ ptr != NULL, len == 0 }` token. On
actual connections, stdio and HTTP 2xx enter the era parser, HTTP 401/403 map
to `auth_error`, and every other HTTP status maps to `server_error` before
protocol parsing. These failures never switch era or replay `tools/call`.
`MCP_EXCHANGE_FATAL` permanently retires the connection from dispatch; a later
catalog refresh must open a replacement.

`request_tool_stream` is the sole `tools/call` operation: AgentCore creates a
private Session capture before the callback, lends a synchronous
`HostResultSinkV1`, and requires the Host to write the complete JSON-RPC
response from byte zero. The sink advertises a 129MiB response-frame ceiling;
the final model-visible result remains subject to the 128MiB artifact ceiling.

After the callback returns `MCP_EXCHANGE_RESPONSE`, AgentCore seals the private
capture and performs streaming UTF-8/JSON, depth, node, duplicate-key,
JSON-RPC version/id, exact-era result, `content`, `isError`, `_meta`, and
`structuredContent` checks. Only the exact successful top-level `result` byte
range is copied into CAS; the JSON-RPC wrapper is not model-visible. Small
results remain inline. Large successful results become the same path-free,
content-addressed envelope used by Host/process/native tools and are recovered
with `ReadArtifact`. Remote JSON-RPC errors, `isError=true` business results,
malformed frames, cancellation, overflow, and partial connector failures are
bounded structured errors or typed call failures and never publish the private
capture. A connector must not retain the borrowed sink or call it after return.

`metask_agentcore_mcp_notify_fn_v1` has only two outcomes:
`MCP_NOTIFY_OK` means the notification was committed, and `MCP_NOTIFY_FAILED`
means it was not. AgentCore does not branch on a Host-side failure category and
does not retry or replay a failed notification; detailed transport outcomes
belong to `open` and `request`, where AgentCore can act on them.

`runtime_describe_mcp` returns `agentcore.mcp-catalog/v1`. Every server entry
contains `server_binding_identity`, namespace, negotiated protocol,
fingerprint, `cache_scope`, `fresh`, `ttl_remaining_ms`, and its Tool range.
Modern TTL is capped by Runtime policy; Classic adapters receive a
conservative default TTL. A fresh Session selection fails when its server is
expired, restore degrades and invalidates that authority, and a newly admitted
Run never receives stale MCP Tools. An already admitted Run keeps its immutable
environment until terminal completion.

One server's transport, protocol, or catalog resource-limit failure produces a
server-scoped issue and does not suppress healthy servers in the same refresh.
Only Runtime-local failures such as allocation exhaustion abort the refresh.
Modern `tools/list` cache metadata is required; `server/discover` may omit both
cache fields. Each server TTL starts when that server's discovery completes,
not when the multi-server refresh began.

Canonical MCP schemas are retained losslessly and dialect-transparently.
Absent `$schema`, explicit JSON Schema 2020-12, explicit Draft-07, and any
other string dialect declaration do not by themselves affect Tool
availability. AgentCore validates bounded JSON structure and the MCP input
object envelope, then projects the common `type`/`properties`/`required` shape
to model providers; root `$schema` and non-projected root keywords remain only
in the canonical record. This is not a claim that AgentCore implements any
complete JSON Schema dialect.

Provider projection must nevertheless be structurally complete. A `$ref` or
`$dynamicRef` inside the projected `properties` tree is unavailable with
`provider_critical_projection_loss`, because the common Provider Tool shape
does not carry the canonical root `$defs`; AgentCore does not silently emit a
dangling reference or resolve it locally. Root `required` entries must be
unique and name projected properties. These are projection-integrity checks,
not JSON Schema instance validation.

Before `tools/call`, AgentCore validates that arguments are a bounded JSON
object and applies Permission, Skill restrictions, and canonical Tool identity.
The MCP server remains authoritative for JSON Schema semantics. AgentCore does
not locally reject an invocation for `required`, property type, `enum`/`const`,
reference, or other schema-constraint mismatch. When `outputSchema` is present,
a successful result must still carry `structuredContent`, but its schema
semantics are server-owned. An `isError=true` Tool business error may omit
`structuredContent` without losing its typed content.

Catalog is the sole executable admission authority. A Snapshot stores only a
canonical Tool and stable model alias for each admitted entry. Structurally
invalid, over-budget, or projection-incomplete schemas and tools requiring MCP
Tasks are visible only as catalog issues and cannot be found or selected;
dialect and semantic keywords alone never create such an issue. Session
materializes a provider
`PreparedTool` only for selected admitted entries; a non-allocation disagreement
with the recorded envelope admission is an invariant violation. View
destruction releases materialized tools before releasing the retained
Snapshot. MCP Tasks, notification pumping, and automatic request replay remain
outside Revision 13.

The value-only MCP checkpoint section has one current `MCPSEL` format and no
independent revision axis. Its decoder rejects every earlier `R6MCP`/`R7MCP`
encoding. Era remains provenance rather than a selection fingerprint input.
The outer AgentCore ABI Revision 13 remains the sole compatibility boundary.

### Model-visible MCP diagnostics

MCP Tool failures currently reach the model as compact JSON with `code`,
`phase`, and nullable `rpc_code`. These strings are diagnostic output, not C ABI
`Status` values or a stable ABI control vocabulary; Hosts must not branch
on their spelling or use them to broaden Tool authority. The current uncertain
delivery code is `indeterminate`. Stabilizing this vocabulary requires a later
explicit contract decision rather than treating leaked enum names as wire API.

### Permission authority and provenance

Permission response tokens are `deny_once`, `deny_session`, `allow_once`, and
`allow_session`; Session grants never mean cross-Session persistence. Every
final decision carries its canonical source, matching rule when present,
logical Session/Run/tool identity, canonical argument digest, policy
generation, and typed callback outcome in a `permission_provenance` event.
The exact source vocabulary is `core_safety`, `active_skill`, `explicit_deny`,
`session_deny`, `explicit_ask`, `explicit_allow`, `session_allow`,
`builtin_classification`, `mode_fallback`, and `callback`. Explicit settings
deny, shared Core safety, active Skill narrowing, and existing shared Session denial are authority
ceilings: the AgentCore Session seam observes them for provenance but cannot
replace their result.
Host callback response and final authorization are separate facts. Audit
storage is prepared before a Session grant can be added, then the same receipt
is committed only when the authoritative `policy_decision` event supplies the
actual execution result. If durable grant reservation fails, provenance keeps
the Host response but records the final deny; an audit allow/public deny split
is forbidden. Receipt commit performs no allocation.
Publication uses the same Run EventSink as all other public events. If the Host
returns an event-fatal result, the Run terminates with callback failure and the
Session is poisoned; AgentCore must not silently convert that failure into a
permission deny.

AgentCore sets `no_interactive_prompt` as an absolute input-ownership boundary.
After an unavailable, cancelled, or failed UI callback it never reads a process
answer queue or stdin. Public provenance preserves the typed callback outcome.
The current shared bool prompt seam still renders non-answered permission
outcomes to the model as the same ordinary deny Tool result; consumers that
need the distinction must use `permission_provenance` until a shared typed
prompt-outcome contract replaces that seam.

### Independent text Completion

Revision 13 exposes Completion as an opaque handle independent of Runtime,
Session, Conversation, AgentLoop, Host tools, and MCP. `completion_create`
copies provider kind, API key, base URL, and model before returning; the Host
may release or overwrite every configuration buffer immediately afterward.
`completion_describe` reports only the configured provider kind and a
library-owned copy of the handle model. There is no request-level model
override, token-limit promise, or general Provider capability projection.

A request contains one or more user/assistant UTF-8 text messages and an
optional system string. It has no tools, tool choice, attachments, structured
output, deadline, or product semantics. `completion_complete` consumes the
same internal stream path as public streaming and returns library-owned text,
usage counters, and a typed stop reason. Tool-use or server-tool output is not
concatenated into text; it returns
`METASK_AGENTCORE_STATUS_COMPLETION_UNSUPPORTED_RESPONSE`.

`completion_stream_start` borrows request descriptors and bytes only during
that synchronous call. Before success returns, AgentCore has serialized and
sent the complete request body; the Host may then poison or release the
request buffers while continuing to read the stream. Each successful
`completion_stream_next` returns one typed event: text, thinking, usage, or
done. Text/thinking payloads are library-owned and released with
`buffer_release`; usage and done use canonical empty payloads. Done is the
single terminal observation. A subsequent `next` returns `TOO_LATE`.

One Completion handle admits only one active complete or stream operation;
overlap and destroy while active return `BUSY`. A stream has one reader:
concurrent `next` calls are invalid. `completion_stream_abort` may be called
from another thread while `next` is blocked and causes that reader to return
an aborted terminal observation. `completion_stream_destroy` must not run
concurrently with `next` or abort. After stream destroy releases the owning
Completion gate, that Completion may be reused or destroyed.

ABI v1 has three ownership classes:

| Value | Owner and lifetime | Release |
|---|---|---|
| `metask_agentcore_bytes_view_v1` inputs and event/request views | Borrowed for the current synchronous call or callback | Never released |
| Host tool results and UI responses | Host-owned callback output | Canonical `{NULL,0}` is never released; every other descriptor is passed to its paired Host release callback exactly once, independent of status |
| MCP response bodies | Host-owned callback output inside `metask_agentcore_mcp_response_v1` | Canonical `{NULL,0}` is never released; every other body is passed as `&response.body` to `release_response` exactly once, independent of exchange status or descriptor validity |
| AgentCore catalog descriptors, Completion model/text/event payloads, and API diagnostics | Library-owned output | Released only with the discovered `buffer_release` function |

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
operation status. Diagnostic text is human-readable, non-normative, and
unstable; consumers must not parse it or branch on its wording. Host-owned
callback output must never be passed to `buffer_release`.

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
| `session_abort_compact` | May run concurrently only with the matching synchronous compact | Cancellation propagates to in-flight provider I/O |
| `completion_complete` / `completion_stream_start` | Mutually exclusive per Completion handle | Overlap or destroy while active returns `BUSY` |
| `completion_stream_next` | One blocking reader per stream | After the terminal done observation, later reads return `TOO_LATE` |
| `completion_stream_abort` | May run from another thread concurrently with the one blocking `next` | Produces an aborted terminal observation; destroy is not concurrent-safe |

Callbacks may request abort. A callback attempt to re-enter Run or destroy on
the same handle returns `METASK_AGENTCORE_STATUS_BUSY`; callers must not spin or wait for that
operation from inside the callback. Matching abort is the only concurrency
exception to ordinary Session operations. The Host must wait for every
`session_abort` and `session_abort_compact` call to return before issuing any
subsequent call on the same handle, including a new Run, compact, mutation, or
destroy. A successful destroy invalidates the handle; calling any API with that
pointer afterward is invalid Host behavior. C++ exceptions,
`longjmp`, and other non-local control transfers must never cross an AgentCore
callback or release-callback boundary.

ABI v1 UI response JSON is one of:

```json
{"answers":[{"values":["choice per question"]}]}
{"permission":"allow_once"}
```

Permission also accepts `allow_session`, `deny_once`, and
`deny_session`. ABI v1 does not expose plan mode or plan approval because
AgentSession does not own the complete `EnterPlanMode`/`ExitPlanMode`
lifecycle. KG counts and Workbench plan-progress state are likewise not part
of this protocol. There is no unversioned `custom` escape hatch. Host tool
input schemas use the AgentCore object-schema subset: `type`, `properties`,
and `required`.

Session permission modes are `default`, `accept_edits`, `auto`, `dont_ask`,
and `full_access`, represented by the corresponding public constants.

ABI v1 supports these built-in tools: `Read`, `Write`, `Edit`, `Glob`, `Grep`,
`Bash`, `BashOutput`, `KillShell`, `WebSearch`, `WebFetch`, and
`AskUserQuestion`. The kernel-owned `ReadArtifact` recovery tool is also
present in every Runtime generation and is automatically selected for every
AgentCore Session; it is not a fallback that admits any other unselected
built-in. `WebSearch` uses the Session's configured internal web
service/provider; it is an ordinary function tool rather than a
provider-specific server-tool descriptor. The Host may select `WebSearch` in
`builtin_tools`, but does not provide or register an executor callback for it.
`WebFetch` is also Session-available, but it currently uses the tool's direct
HTTP/subprocess implementation rather than the Session provider; its network
and redirect policy remains the owning tool's contract. Existing WebFetch
permission-rule and streaming-prefetch behavior also remains in force; Hosts
that need domain restriction must provide the corresponding `WebFetch(domain:…)`
rule. Runtime creation
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
| explicit process-plugin sources per Runtime | 64 |
| one Host tool schema | 1 MiB |
| Host tool schema nesting | 32 levels |
| top-level schema properties/required entries | 1024 |
| one synchronous UI response | 1 MiB |
| one raw Host callback success result or failure/rejection detail | 16 MiB |
| default durable Tool/MCP result cap before artifact promotion | 2 MiB |
| one Tool Result artifact / one Session artifact CAS | 128 MiB / 1 GiB |
| one `ReadArtifact` chunk | 32 KiB |
| one encoded model-visible Host tool error payload | 1 MiB |
| one Session ID | 64 bytes |
| one Runtime/Session metadata string | 1 MiB |
| total Runtime metadata | 16 MiB |
| total Session metadata | 4 MiB |
| one TextInput prompt | 16 MiB |
| Skill invocation slots per catalog | 1024 |
| one Skill argument array / JSON | 64 values / 1 MiB |
| one catalog descriptor | 4 MiB |
| one Skill file / total content per Skill | 16 MiB / 32 MiB |
| files / entries per Skill | 1024 / 4096 |
| total catalog content / files | 64 MiB / 16384 |
| catalog traversal entries | 65536 |
| Skill directory depth / relative path | 64 / 4096 UTF-8 bytes |
| retained Skill catalog snapshots per Runtime | 256 MiB resident bytes |
| active materializations per Runtime | 256 MiB |
| MCP Runtime servers / canonical tools | 64 / 1024 |
| MCP schema/arguments JSON container entries / admission work units | 256 / 65536 |
| MCP legacy default TTL / maximum accepted TTL | 30 s / 300 s |
| one Run | 1000 turns |
| one tool_result file_refs array / path / URI / title / kind | 32 / 4096 / 8192 / 256 / 64 bytes |

MCP schema and invocation JSON cross the depth/node/container/work admission
gate before a dynamic JSON tree is allocated. Invocation JSON must have an
object root; AgentCore does not interpret its values against the retained JSON
Schema.

AgentCore releases every Host callback buffer exactly once. A successful
inline Tool or MCP result larger than its configured durable result cap is
first promoted into the Session CAS and only the bounded recovery envelope is
settled against the durable budget; the raw success is not discarded before
artifact projection. The 16 MiB completed-buffer callback boundary remains an
ABI safety cap: legacy synchronous Host results beyond it cannot enter the
library and therefore cannot be recovered. Native/process tools and
`HostStreamToolV1` callbacks that use the byte-zero spool avoid constructing
that raw buffer at all; only their optional failure/rejection detail uses the
completed-buffer cap.

Every AgentCore Session stores artifacts under
`<workspace.home|root>/.metacodes/agentcore/sessions/<logical_session_id>`.
Checkpoint restore preserves the logical Session ID and therefore resolves the
same CAS. `ReadArtifact` is frozen into the provider-visible tool directory
from request one, so a later spill changes neither system prompt nor tool
schema and does not invalidate the prompt-cache prefix.

Configuration and pre-admission Run limits return
`METASK_AGENTCORE_STATUS_RESOURCE_LIMIT`. An oversized UI response is released exactly once,
returns `METASK_AGENTCORE_STATUS_CALLBACK_FAILED`, and poisons the Session because the Host
UI transport violated its callback contract. An oversized Host callback result
at the 16 MiB ABI boundary is released exactly once and becomes an ordinary
Host tool failure. Events are never silently truncated. Event JSON has no
universal size cap.

Runtime metadata includes built-in names and Host tool names, descriptions, and
schemas. Session metadata includes credentials, model/base URL, workspace
paths, and selected tool names. These budgets bound copied configuration; they
do not classify the same-process Host as untrusted.

Completed-buffer Host tool results are UTF-8 text. Invalid UTF-8 is released exactly once and
becomes an ordinary Host tool failure. Binary output requires an explicit
textual encoding such as base64. `HostStreamToolV1` is the explicit exception:
it can declare binary media and stream arbitrary bytes into CAS without
smuggling them through a JSON string.

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
`struct_size`; every reserved field must be zero. While Revision 13 remains
unreleased and experimental, an explicitly approved hard cut may replace its
wire shape in place only when the library, headers, SDKs, consumers, tests, and
documentation move atomically; the replaced bundle is void and no compatibility
path is provided. Consumers must therefore pin the exact bundle they were built
against. After a revision is formally released, a later breaking v1 bundle must
increment `abi_revision`. Reserved storage is not permission to infer
compatibility. After v1 is genuinely stabilized, later layout, function-table,
or control-message extensions require `metask_agentcore_get_api(2)` and v2
types. Assigning a meaning or non-zero value to a reserved field is always an
explicit wire-contract decision, never an inferred compatible extension.

Revision 13's published POD offsets and sizes require a 64-bit pointer ABI.
The header rejects 32-bit consumers at compile time; a future 32-bit contract
would need separately specified layouts and consumer gates.

`capabilities` reports the API surface implemented by the returned library
table. Revision 13 consumers require exact equality with
`METASK_AGENTCORE_REQUIRED_CAPABILITIES_V1`; it is not an extensible superset
check. It is not per-Runtime or per-Session negotiation; concrete Runtime and
Session configuration still determines which tools and callbacks are active.

ABI v1 deliberately does not add a slash/Command ABI, in-place active-Run
resume, asynchronous UI continuations, ABI-level asynchronous operations,
strict Workspace security, Workbench `Output`/`FileChange`/plan-progress models, or a
multi-platform universal bundle. Those are separate contracts, not hidden
behavior in the library facade. This does not remove Bash's existing
tool-managed background jobs, which remain reachable synchronously through
`Bash`, `BashOutput`, and `KillShell`.
