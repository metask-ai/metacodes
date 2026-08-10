# AgentCore ABI v1 Revision 7 — MCP Protocol Runtime Completion

## Status and scope

Revision 7 is an explicit AgentCore ABI hard cut. It completes the MCP Runtime
architecture without replacing `McpRuntime` wholesale and without modifying
the product MCP stack or `src/core/agent_loop.zig`.

The owned path is:

```text
Host transport
  -> Negotiator
  -> exact-era connection
  -> era adapter
  -> canonical discovered server
  -> Catalog admission
  -> lightweight immutable Snapshot
  -> Session-selected materialization
  -> Run authority and dispatch
```

Out of scope: MCP Tasks, notification pumps, automatic replay, dynamic adapter
registries, CLI MCP merging, product-agent integration, and unrelated Memory
or Harness changes.

## Stable public codes

Existing Revision 6 meanings are retained exactly:

| Contract | Code | Meaning |
|---|---:|---|
| `auto` | 1 | Modern probe, then bounded Classic negotiation |
| `modern_only` | 2 | exact `2026-07-28` |
| `legacy_only` | 3 | exact `2025-11-25` |
| `legacy_2025_06_only` | 4 | exact `2025-06-18` |
| era `2026-07-28` | 1 | Modern |
| era `2025-11-25` | 2 | Classic |
| era `2025-06-18` | 3 | Classic |

## Negotiation invariants

- A disposable Modern probe never becomes the operational connection.
- Valid Modern advertisements select an exact supported era.
- Valid `MethodNotFound` enters Classic under `auto`.
- Stdio timeout or child exit may enter Classic; HTTP transient, auth,
  network, or server failure never downgrades.
- Classic initialize parsing reports the selected known era and does not make
  policy decisions.
- An AUTO 2025-11 request selecting 2025-06 closes and reopens exact 2025-06
  once. Exact policies reject mismatches.
- Only the final exact handshake contributes capabilities.
- No indeterminate `tools/call` is replayed.

Each successful Host Connector `open` binds one opaque connection context to
its purpose and requested exact era for its entire lifetime. Streamable HTTP
state is Host-owned: after initialization the Host supplies the matching
`MCP-Protocol-Version`, retains any `MCP-Session-Id`, and never shares that
state between a disposable probe, an actual connection, or an exact-era
reopen. AgentCore, not the Host, decides when a mismatch requires close and
reopen; an existing connection never changes era in place.

## Era adapters and capabilities

`mcp_modern.zig` owns 2026 behavior. `mcp_classic.zig` is parameterized by a
`ClassicProfile` for 2025-11 and 2025-06. Each adapter interprets its own
capability shape before producing `CanonicalCapabilities`.

Classic `capabilities.tools` controls whether `tools/list` is legal. Modern
discovery does not reuse that Classic rule. Canonical state retains only
`tool_catalog_available`; raw capability JSON is diagnostic data.

Execution modes normalize to `ordinary`, `task_optional`, or `task_required`.
2025-06 is ordinary. Optional task support remains callable as an ordinary
request. Required-task tools are unavailable because Revision 7 does not
implement MCP Tasks.

## Catalog and Session ownership

Catalog is the only executable admission authority. For each admitted Tool the
Snapshot stores a canonical pointer, stable model alias, and compact copied
projection diagnostics. The full provider schema parse uses temporary storage
and is released after inspection.

Session selection resolves only admitted entries. It lazily materializes a
`PreparedTool` for selected entries using the same schema logic. A non-OOM
disagreement is `AdmissionInvariantViolation`, not a second admission outcome.
View destruction releases prepared tools before releasing its retained
Snapshot.

Permission identity remains server binding identity + canonical Tool name +
schema fingerprint. Era is provenance and does not change that identity.

## Failure boundaries

- Runtime-local allocation failure aborts refresh and preserves the prior
  Snapshot.
- Server transport, protocol, and remote resource failures become
  server-scoped catalog issues and do not suppress healthy peers.
- Schema and required-task rejection become tool-scoped issues and are absent
  from discovery and selection.
- Budget and Permission checks remain before external Tool dispatch.

## Persistence and ABI

The AgentCore API is exactly ABI v1 Revision 7. C, Zig, Rust, manifests, and
source-free consumers reject Revision 6 tables.

The MCP value section writes `R7MCP` revision 2 and accepts only exact
`R6MCP` revision 1 or `R7MCP` revision 2 pairs. Era values are append-only.
No credentials, connections, capabilities, transport state, or live handles
are persisted. The outer AgentCore checkpoint remains Revision-7-only.

## Verification gates

- per-era adapter parsing and canonical parity;
- deterministic probe/open/close/notify/release traces;
- exact 2025-06 and AUTO 11-to-06 public Host connector tests;
- no-tools and required-task zero-call negatives;
- rejected schemas are undiscoverable and unselectable;
- immutable generation and admitted Run stability;
- R6MCP1 to R7MCP2 decoder migration tests;
- strict C/Zig/Rust ABI and source-free consumers;
- full AgentCore test, bundle, archive, diff, and scope gates.
