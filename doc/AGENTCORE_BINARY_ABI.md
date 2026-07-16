# AgentCore binary library ABI v1

The AgentCore bundle is a thin binary facade over the existing metacodes
`AgentRuntime` / `AgentSession` / `AgentLoop`. Consumers do not add metacodes
implementation source to their build graph, and the Host owns all UI.

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

Relative paths supplied to `Read`, `Write`, `Edit`, `Glob`, and `Grep` resolve
against `workspace_root`; Bash also runs with that directory as its cwd.
`workspace_root` is an execution context, not a filesystem jail: absolute
paths remain usable unless the Host selects and configures a separate sandbox
policy. Invalid workspace paths, unavailable/duplicate selected tools, and a
shell tool selected under the disabled shell policy fail Session creation with
`MC_STATUS_INVALID_ARGUMENT` and do not publish a Session handle.

Event/request views are borrowed for the callback duration. Host tool results
and answered UI responses remain Host-owned until their paired release
callback is invoked exactly once. Callbacks may request abort but must not
re-enter Run or destroy. Different Sessions may invoke shared Host callbacks
concurrently, so the Host owns synchronization of shared callback state.
The Host may call abort concurrently with the matching synchronous Run; it
must serialize create/destroy and all other operations on the same handle.

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
continuations, strict Workspace security, or a multi-platform universal
bundle. Those are separate contracts, not hidden behavior in the library
facade.
