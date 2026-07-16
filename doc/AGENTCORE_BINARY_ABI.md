# AgentCore binary library ABI v1

The AgentCore bundle is a thin binary facade over the existing metacodes
`AgentRuntime` / `AgentSession` / `AgentLoop`. Consumers do not add metacodes
implementation source to their build graph, and the Host owns all UI.

## Build and verify

Use the repository-pinned Zig toolchain and the fixed v1 release target:

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
├── lib/libmetacodes_agentcore.a
├── include/metacodes_agentcore.h
├── sdk/metacodes_agentcore.zig
├── sdk/metacodes_agentcore_protocol.zig
├── sdk/metacodes_agentcore_types.zig
└── manifest.json
```

The manifest records source and toolchain identity, target/deployment
baseline, optimization and strip settings, ABI version, required system link inputs, and SHA-256 for every
shipped file. The source-free consumer validates those fields, the exact
manifest file keys, and the complete on-disk file/directory allowlist. Release
bundles require an explicit `aarch64-macos.13.0` target. Build a distributable
bundle into a new empty `--prefix`; a clean Git tree does not make a reused
output directory free of stale, unlisted files.

ReleaseSafe bundles strip DWARF by default; the explicit
`-Dagentcore-strip=true` in the release command pins that policy in build
automation. Debug symbols belong in a separately retained symbols artifact,
not in the consumer bundle.

## Typed Zig SDK

The shipped Zig SDK remains source-free. `metacodes_agentcore_types.zig`
contains the raw ABI declarations plus validated `Status` and `StopReason`
enums. `metacodes_agentcore_protocol.zig` owns the ABI v1 `CoreEvent`,
`UiRequest`, and `UiResponse` wire types, strict decoders, and the
request-aware response encoder. `metacodes_agentcore.zig` re-exports both
layers beside raw API-table access.

`decodeCoreEvent` and `decodeUiRequest` return standard `std.json.Parsed`
owners. Their strings and arrays remain valid until `deinit`; consumers must
not copy an owner and deinitialize both copies. `encodeUiResponse` returns an
allocator-owned buffer suitable for `mc_owned_bytes_v1`, rejects response
tags that do not match the request, and validates the answer count for
`ask_question` requests.

Unknown status/stop codes, top-level tags, multiple or duplicate tags, and
invalid known payloads are rejected. Additive fields inside a known payload
are ignored for forward compatibility. Opaque JSON-bearing string fields are
not recursively interpreted by the SDK. Adding a top-level tag or changing an
existing required field is an ABI v1 breaking change and requires a new ABI.

The public `CoreEvent` schema is not the internal frontend/daemon union.
`src/agentcore/protocol_v1.zig` exhaustively maps internal events to the
frozen v1 DTO before serialization. Internal `config_changed`,
`session_lifecycle`, `agent_lifecycle`, `tasks_changed`, and
`ui_request_pending` events are not exported by ABI v1 because the facade
exposes neither mutable Session config, Task/KG/process-agent capabilities,
nor asynchronous UI continuations. Future internal event additions fail
the adapter compilation until they are explicitly mapped or excluded.

## Contract

`metacodes_agentcore_get_api(1)` is the only discovery symbol. ABI v1 exposes
opaque Runtime and Session handles, synchronous text Runs, abort, built-in and
synchronous Host tools, tagged CoreEvent JSON, and synchronous Host UI JSON.
Runtime owns Host tool callback references and must outlive every Session.
Session owns provider credentials, workspace inputs, tool selection,
Conversation, permission memory, jobs, and Run state.

Event/request views are borrowed for the callback duration. Host tool results
and answered UI responses remain Host-owned until their paired release
callback is invoked exactly once. Callbacks may request abort but must not
re-enter Run or destroy. Different Sessions may invoke shared Host callbacks
concurrently, so the Host owns synchronization of shared callback state.

ABI v1 UI response JSON is one of:

```json
{"answers":["choice per question"]}
{"permission":"allow_once"}
{"plan_approval":"approve_default"}
{"custom":"renderer-specific JSON string"}
```

Permission also accepts `allow_always`, `deny_once`, and
`deny_tool_session`; plan approval also accepts `approve_accept_edits` and
`reject`. Host tool input schemas use the existing AgentCore object-schema
subset: `type`, `properties`, and `required`.

ABI v1 supports these built-in tools: `Read`, `Write`, `Edit`, `Glob`, `Grep`,
`Bash`, `BashOutput`, `KillShell`, and `AskUserQuestion`. Runtime creation
rejects process-level tools whose dependencies are not owned by AgentSession,
including Task, Cron, KG, MCP, worktree, and notification tools. Adding those
requires a future explicit Host capability contract; they are not silently
advertised with missing state.

All empty `mc_owned_bytes_v1` values use the canonical `{NULL, 0}` form. Host
UI fatal/invalid responses are infrastructure failures: they abort the active
Run, poison the Session, and surface as `MC_STATUS_CALLBACK_FAILED` (or
`MC_STATUS_OUT_OF_MEMORY` when response processing exhausts memory).

ABI v1 deliberately does not add session persistence/restore, asynchronous UI
continuations, strict Workspace security, or additional platforms. Those are
separate contracts, not hidden behavior in the library facade.
