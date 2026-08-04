# AgentCore binary library ABI v1

The AgentCore bundle is a thin binary facade over the existing internal
execution engine. Consumers do not add implementation source to their build
graph, and the Host owns all UI. AgentCore is versioned and distributed as an
independent component; this ABI does not expose or define any host product.

ABI v1 is an experimental in-process embedding contract for synchronous,
stateful AgentSession execution. It does not expose or define a host product
model.

**Status: experimental.** The premature 2026-07-17 freeze was retracted after
consumer feedback exposed a dangling callback-identity contract. Revision 6
now defines one exact hard-cut wire shape after Permission authority,
checkpoint/restore, durable budget, and MCP Runtime/Session seams were
implemented and tested; this is not a general v1 stability promise.

Consumers must pin an exact bundle (the manifest records the source commit)
and treat a different revision as incompatible. Layouts, numeric values,
function-table order, and semantics may change only through another explicit
revision cut while v1 remains experimental.

The current experimental bundle is **ABI v1 revision 6**. Revision 6 is a
hard-cut replacement for every earlier revision. In addition to the Revision
5 Session surface, it adds Session checkpoint/restore/describe, durable
admission budgets, Session Permission authority, and Runtime/Session MCP:

- `metask_agentcore_api_v1` is 216 bytes and requires `abi_revision == 6`;
- `RuntimeConfigV1`, `SessionHostConfigV1`, `SessionCreateConfigV1`,
  `SessionRestoreConfigV1`, `RunInputV1`, and `RunResultV1` are respectively
  96, 168, 64, 64, 104, and 72 bytes on the required 64-bit ABI;
- checkpoint, restore, describe, MCP refresh/describe/selection, Permission
  rule update, compact, and abort entries are mandatory;
- the exact required capability set is `0x7ffff`;
- `manifest.json` records revision 6, table size 216, and that exact capability
  set.

Revision 6 provides no earlier-revision compatibility, shim, dual dispatch, or old
table layout. Consumers update the header, SDK, manifest, and library
atomically, validate the stable
`struct_size`/`abi_version` prefix before reading later fields, then require
exact revision, table size, capability, reserved-field, and function-identity
matches. Every per-Run callback validates and copies any retained `RunContext`
fields during the callback, and Host registries bind/compare `session_id`
atomically under their per-Session lock.

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
`metask.skill-catalog/v1`. It validates the schema, the 1024-Skill limit,
identity forms, health and issue consistency, and each Skill argument schema.
Cross-record identity semantics deliberately remain outside the wire decoder:
AgentCore validates canonical IDs and uniqueness before publishing, while a
Host projection must independently reject duplicate IDs or invocation names
so it can preserve domain-specific diagnostics. Because decoded strings and
arrays are allocator-owned, the consumer may release the AgentCore descriptor
buffer immediately after decoding.
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

`on_event` is mandatory in Revision 6. To reconstruct final visible assistant
output, a Host accumulates only closed segments: `text_chunk` appends to the
current segment and `stream_done` closes it. `tool_start` and `tool_result` are
semantic boundaries that discard any unclosed segment and all previously
closed accumulated segments; consecutive boundaries are idempotent and
`tool_progress` is not a boundary. The final output is the concatenation of
all closed segments after the last boundary, or all closed segments when no
boundary occurred. This preserves max-token continuations while excluding
pre-tool drafts. Usage events are exact deltas and must use checked arithmetic.

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

One Session accepts one active Run at a time. A successful Run returns to idle
and the Host may start another Run on the same stateful Conversation. `Status`
describes whether the ABI call itself succeeded. `StopReason` is meaningful
only when `session_run_input` returns `METASK_AGENTCORE_STATUS_OK` and is one of `end_turn`,
`max_turns`, `aborted`, `tool_error`, `api_error`, or `tool_loop`. Internal
`suspended`, `backgrounded`, and `budget` states are not representable in v1;
if one becomes reachable through the facade it is an internal contract failure,
not a new public stop code. Because the stateful Run may already have committed
Conversation changes, that failure poisons the ABI facade and subsequent Run or
abort calls return `METASK_AGENTCORE_STATUS_INVALID_STATE`; destroy remains valid.

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
Host must destroy that physical handle. Revision 6 checkpoint/restore creates
a new handle from a previously exported committed checkpoint; it does not
reconstruct state that was never successfully exported or resume an active
Run.

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
Conversation maintenance operation. Revision 6 has no Host-supplied target
token budget and does not guarantee that the result fits the context window of
the current or a future model. `session_set_model` and `session_compact` are
independent primitives, not a compound model-migration transaction.

On `METASK_AGENTCORE_STATUS_OK`, `CompactResultV1.before_context_tokens` and
`after_context_tokens` are context-size estimates for UI and policy decisions;
they are not provider billing values. The four provider usage-delta fields are
semantically separate. `METASK_AGENTCORE_COMPACT_DEGRADED` exposes no structured
reason in Revision 6, and a Host must not infer one by parsing diagnostics.

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

### Skill catalog and typed input

`runtime_query_skill_catalog` is independent of Session lifetime so a Host may
render a Skill menu before creating its first Task or Session. A successful
query returns both an immutable catalog handle and a library-owned descriptor
using schema `metask.skill-catalog/v1`. The descriptor contains a Runtime-local
`catalog_scope_id`, content-derived `catalog_revision`, health, valid
`skills[]`, and typed `issues[]`; it never contains Skill bodies, physical
paths, policy internals, or execution mode. Isolated invalid slots produce
`OK + degraded`; failure to prove the whole snapshot returns
`SKILL_CATALOG_INVALID` and no partial handle or descriptor.

An `invalid_resource` issue always carries a typed `reason`; every other issue
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

Default AgentCore discovery reads exactly
`<workspace_home>/.agents/skills` and `<workspace_root>/.agents/skills`, with
the project root winning an invocation-name collision. It does not implicitly
read `/etc/metacodes/skills`, `.claude/skills`, or `.metacodes/skills`.
Product adapters may apply their own source policy through the shared Skill
Runtime; those product defaults are not AgentCore filesystem authority.

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
`skill_catalog_release`. Session create and idle-only refresh retain their own
reference, so the Host may release its handle immediately after either call
succeeds. A catalog must belong to the same Runtime and canonical Workspace
binding. Refresh atomically replaces the bound snapshot and does not modify
Conversation or `run_id`.

`session_run_input` accepts exactly one tagged input:

- `RUN_INPUT_TEXT`: only `text` is non-empty; it is bounded to 16 MiB before
  pointer access or UTF-8 decoding. Slash-looking text has no special meaning.
- `RUN_INPUT_SKILL`: `text` is canonical empty and the Session must have a
  bound catalog. `skill_id`, `catalog_revision`, and `arguments_json` identify
  an explicit Host invocation. Arguments are canonical empty or
  `{"values":["..."]}`, with at most 64 values and 1 MiB encoded JSON.

Malformed identity is `INVALID_ARGUMENT`; a mismatched pinned revision is
`STALE_CATALOG`; missing Skill, invalid arguments, static policy failure, and
unavailable execution capability use their dedicated statuses. These failures
occur before Run admission and do not advance `run_id` or mutate Conversation.
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

1. During draft creation, query a catalog and render its descriptor.
2. Create a Session bound to that catalog.
3. Release the Host's catalog handle; the Session retains its own reference.
4. Submit `RUN_INPUT_SKILL` with an identity and revision from that descriptor.
5. On `STALE_CATALOG`, query again, re-resolve the identity from the new
   descriptor, wait until the Session is idle, refresh it, release the new Host
   handle, and retry with the same `run_id` because the rejected Run was never
   admitted.

Changing source files alone does not mutate a Session's immutable snapshot.
`STALE_CATALOG` means that the input revision differs from the revision
currently bound to the Session. If the new descriptor removes the Skill or
reports it as an issue, the consumer must not blindly retry.

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

Fork children cannot suspend for Host UI interaction in Revision 6. Their UI
requester is unavailable, so a child question or permission request fails
closed as an ordinary fork/tool failure attributed to the outer Run. Inline
execution may use the outer Run's synchronous UI callback.

AgentCore exposes no slash parser, Command registry, route field, or
product-specific command. A consumer resolves its own Commands first, maps a
catalog hit to typed Skill input, and treats an unresolved slash as its own
product decision.

### MCP Runtime catalog and Session view

Revision 6 accepts only MCP `2026-07-28` as the primary era and
`2025-11-25` as the single compatibility era. Runtime owns negotiation,
transport, canonical catalogs, cache expiry, and immutable generations;
Session owns only a filtered selection, while each Run pins an admitted Tool
environment. Credentials, live connections, and request state never enter a
Session checkpoint.

`runtime_describe_mcp` returns `agentcore.mcp-catalog/v1`. Every server entry
contains `server_binding_identity`, namespace, negotiated protocol,
fingerprint, `cache_scope`, `fresh`, `ttl_remaining_ms`, and its Tool range.
Modern TTL is capped by Runtime policy; the legacy adapter receives a
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

Canonical MCP schemas are retained losslessly, but Revision 6 advertises only
a bounded local validation profile. References, header projection,
`uniqueItems: true`, numeric constraints, and numeric or structural
`enum`/`const` are unavailable rather than approximately validated. Container,
node, and work-unit budgets fail closed. This is not a claim of complete JSON
Schema 2020-12 support.
`format` is admitted as an annotation, exact JSON number lexemes survive
validation and `tools/call` encoding, and `outputSchema` is applied only to a
successful result. An `isError=true` Tool business error may omit
`structuredContent` without losing its typed content.

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

ABI v1 has three ownership classes:

| Value | Owner and lifetime | Release |
|---|---|---|
| `metask_agentcore_bytes_view_v1` inputs and event/request views | Borrowed for the current synchronous call or callback | Never released |
| Host tool results and UI responses | Host-owned callback output | Canonical `{NULL,0}` is never released; every other descriptor is passed to its paired Host release callback exactly once, independent of status |
| AgentCore catalog descriptors and API diagnostics | Library-owned output | Released only with the discovered `buffer_release` function |

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
| MCP local-schema container entries / validation work units | 256 / 65536 |
| MCP legacy default TTL / maximum accepted TTL | 30 s / 300 s |
| one Run | 1000 turns |

MCP schema and invocation JSON cross the depth/node/container/work admission
gate before a dynamic JSON tree is allocated. Invocation number lexemes are
retained exactly; JSON Schema `integer` means a mathematical integer (`1.0`
and `1e3` included), not merely a value that fit Zig's i64 parser.

Configuration and pre-admission Run limits return
`METASK_AGENTCORE_STATUS_RESOURCE_LIMIT`. An oversized UI response is released exactly once,
returns `METASK_AGENTCORE_STATUS_CALLBACK_FAILED`, and poisons the Session because the Host
UI transport violated its callback contract. An oversized Host tool result is
released exactly once and becomes an ordinary Host tool failure. Events are
never silently truncated. Event JSON has no universal size cap.

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
`struct_size`; every reserved field must be zero. Revision 6 freezes one exact
experimental cut. A later breaking v1 bundle must increment `abi_revision`,
and consumers accept only the exact revision they were built against.
Reserved storage is not permission to infer compatibility. After v1 is
genuinely stabilized, later layout, function-table, or control-message
extensions require `metask_agentcore_get_api(2)` and v2 types.
In particular, assigning a meaning or non-zero value to a Revision 6 reserved
field is a new wire contract and requires another explicit revision cut.

Revision 6's published POD offsets and sizes require a 64-bit pointer ABI.
The header rejects 32-bit consumers at compile time; a future 32-bit contract
would need separately specified layouts and consumer gates.

`capabilities` reports the API surface implemented by the returned library
table. Revision 6 consumers require exact equality with
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
