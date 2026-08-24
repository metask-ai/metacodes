# API overview

Metacodes exposes several host shapes over one kernel. The fixed AgentLoop,
Conversation projection, permission/sandbox chain, budgets, formal verdicts,
artifact store, and TinyKG admission are not replaceable extensions.

## Compatibility matrix

| Interface | Entry point | Status | Compatibility rule |
|---|---|---|---|
| CLI | `zig-out/bin/metacodes` | pre-1.0 | flags may evolve with changelog notice |
| Zig source API | `@import("metacodes-core")` | experimental | pin repository commit and Zig toolchain |
| AgentCore C ABI | `metask_agentcore_get_api(1)` | experimental rev 13 | exact revision, sizes, capabilities, and bundle manifest |
| Process plugins | strict manifest + stdio protocol | versioned v1 | reject unknown fields and digest drift |
| Plugin inventory | `--dump-plugins`, Zig, Web state | versioned v1 | additive observation fields only where specified |

There is no general HTTP service API promise yet. The Web and daemon hosts are
product surfaces built over the same core protocols.

## Zig source embedding

`src/lib.zig` exports the UI-neutral core. A host constructs an `AgentRuntime` or
`RuntimeHost`, supplies a fixed provider/workspace/policy configuration, creates
`AgentSession` instances, consumes typed events/UI requests, and destroys sessions
before their owning runtime generation.

`RuntimeHost.replace` publishes a fully validated immutable generation for new
sessions. Existing sessions remain pinned to their old generation. Failed staging
does not consume a generation or mutate the active runtime.

Static trusted plugins can contribute typed tools, streaming tools, services,
advisory policies, and deterministic provider dialects. Process plugins can only
contribute isolated tools through the versioned wire protocol. Neither receives a
mutable AgentLoop, permission, formal, or TinyKG handle.

See [LIB_API.md](LIB_API.md) and `example/main.zig`.

## AgentCore binary embedding

The source-free bundle contains:

- `sdk/metask/agentcore.h` for C11/C++17;
- `sdk/zig` typed bindings;
- `sdk/rust` bindings and build integration;
- one target-specific static library;
- a manifest whose file allow-list and SHA-256 values are mandatory.

Consumers call only `metask_agentcore_get_api(METASK_AGENTCORE_ABI_VERSION)` and
must validate ABI revision 13, table size, capability bits, reserved zeros, and
the bundle manifest. Runtime/session, sync run, abort, event/UI callbacks,
checkpoint/restore, host streaming tools, MCP streaming, process plugins, and
durable journal profiles are covered by the current table.

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

## Errors and ownership

Public boundaries use tagged states or explicit error sets. Callback buffers are
borrowed only for the documented call duration; returned buffers identify their
release function. Hosts must not retain sink pointers, call mutating session APIs
reentrantly, or destroy a runtime with active sessions. The normative ownership
rules live beside each public header/type and its L2 consumer fixture.
