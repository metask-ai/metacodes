# AgentCore binary library ABI v1

The AgentCore bundle is a thin binary facade over the existing cc-zig
`AgentRuntime` / `AgentSession` / `AgentLoop`. Consumers do not add cc-zig
implementation source to their build graph, and the Host owns all UI.

## Build and verify

Use the repository-pinned Zig toolchain and the fixed v1 release target:

```sh
zig build agentcore:bundle -Dtarget=aarch64-macos.13.0 -Doptimize=ReleaseSafe
zig build agentcore:test
zig build agentcore:consumer -Dtarget=aarch64-macos.13.0 -Doptimize=ReleaseSafe
```

`--prefix /absolute/path` changes the bundle root. The installed files are:

```text
<prefix>/
├── lib/libmetacodes_agentcore.a
├── include/metacodes_agentcore.h
├── sdk/metacodes_agentcore.zig
├── sdk/metacodes_agentcore_types.zig
└── manifest.json
```

The manifest records source and toolchain identity, target/deployment
baseline, ABI version, required system link inputs, and SHA-256 for every
shipped file. Release bundles require an explicit `aarch64-macos.13.0` target.

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

ABI v1 deliberately does not add session persistence/restore, asynchronous UI
continuations, strict Workspace security, or additional platforms. Those are
separate contracts, not hidden behavior in the library facade.
