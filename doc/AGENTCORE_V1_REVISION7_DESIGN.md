# AgentCore ABI v1 Revision 7 — MCP Runtime and Live Configuration

## Status and scope

Revision 7 is an explicit AgentCore ABI hard cut. It completes the library-side
MCP Runtime and public live-configuration control plane: a Host can add, change,
disable, remove, and test MCP server definitions without recreating the Runtime.
How a Host obtains configuration, observes changes, presents UI, or organizes
its own lifecycle is outside this AgentCore specification.

The AgentCore-owned path begins at the complete desired set supplied by the
Host:

```text
declarative DesiredMcpConfiguration
  -> serial Runtime reconcile
  -> exact-era ServerInstance
  -> era adapter
  -> copied canonical discovery values
  -> immutable CatalogGeneration
  -> Session value-only selection
  -> Run generation lease
  -> exact-instance dispatch lease
```

Revision 7 defines exactly one protocol/client/catalog lifecycle inside
AgentCore. It does not specify or evaluate a Host's internal implementation.

Out of scope: MCP Tasks, automatic replay, interactive connection affinity,
sampling/elicitation routing, credential lifecycle management, configurable
replacement policies, bounded drain and rollback, dynamic protocol adapter
plugins, cross-process pooling, and unrelated subsystems.

## Ownership

The Host owns:

- user and Workspace MCP definitions;
- credentials and OAuth state;
- trust and persistent permission decisions;
- physical stdio/HTTP transport resources and opaque Connector contexts;
- configuration change observation and UI feedback.

The AgentCore Runtime owns the logical lifecycle:

- protocol negotiation and exact-era reopen decisions;
- `ServerInstancePool` records and immutable catalog generations;
- serial declarative reconcile and blue/green publication;
- exact-instance dispatch and the no-replay boundary.

The Host allocates and releases physical transport resources through the
Connector contract. AgentCore decides when logical instances open, stop
admitting, cancel, and close. A Session never owns a Client, transport pointer,
or mutable catalog storage.

## Stable identity model

`IsolationDomain` is a Host-only key. It consists of the user/security
principal, Workspace identity, and policy boundary. It does not enter the ABI,
catalog, checkpoint, or permission identity. The Host maps one stable domain to
one AgentCore Runtime.

Within a Runtime:

```text
ServerDefinitionId = definition scope + canonical server identity

ServerInstanceKey =
    ServerDefinitionId
  + resolved configuration fingerprint
```

Configuration fingerprints never contain secret bytes or secret-derived
digests. When credentials or another connection-relevant input changes, the
Host supplies a new non-secret configuration fingerprint. Token refresh within
one unchanged Host Connector remains a Host transport concern.

`InstanceId` is a Runtime-local monotonic integer. It is never reused. Every
stdio process restart, HTTP re-initialize after session loss, or exact-era
reopen creates a new `InstanceId`. An ID is an opaque lookup key, never a
pointer, permission identity, or persisted value.

## Stable public protocol codes

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
its purpose and requested exact era for its lifetime. Streamable HTTP state is
Host-owned and is never shared between a disposable probe, an actual
connection, or an exact-era reopen. An existing connection never changes era
in place.

## Catalog generations

Catalog is the sole executable admission authority, but it does not own or
borrow instance memory. A `CatalogGeneration` contains only copied values in
its own arena:

- namespace, era, cache and diagnostic values;
- exact `InstanceId` provenance;
- copied canonical Tool identities, descriptions, schemas, and capabilities;
- stable model aliases and copied projection diagnostics.

It never contains a Client pointer, transport pointer, Connector context, or a
slice owned by a ServerInstance. A stale or retired `InstanceId` resolves to a
clean server-scoped failure, not use-after-free.

Discovery and execution are causally bound: a catalog entry can dispatch only
to the exact instance that produced it. It must never resolve a server name to
the newest instance. A restarted instance receives a new ID and must produce a
new catalog generation before it is executable.

## Session, Run, and dispatch leases

A Session persists only value selectors and permission state. It does not
retain a Runtime catalog generation between Runs.

Selection update and Run admission deliberately have different failure
semantics. An explicit Host selection update is strict and atomic: every
selected tool must exist and be fresh. Run admission is availability-tolerant:
selectors whose server is missing, expired, or schema-invalidated are omitted
from that Run and counted as invalidated authority. MCP unavailability may
shrink the Run tool surface but must never prevent the Conversation itself from
running.

At Run admission, AgentCore resolves the remaining Session selectors against
the current catalog generation and creates an immutable Run view. The Run
retains that generation, so its tool definitions and validation schema remain
stable. The next Run sees the latest published generation automatically.

Dispatch acquires a short lease for the exact `InstanceId` copied into the Run
generation. It retains that ServerInstance before writing the request and
releases it after the terminal result. Destruction order is Run and dispatch
leases, instance records, then catalog arenas.

Permission identity remains stable server binding identity + canonical Tool
name + schema fingerprint. `InstanceId`, catalog generation, and era are
provenance and never grant authority. A semantic schema change invalidates the
existing selection; a reconnect alone does not.

## Declarative configuration Apply

Every Apply supplies one complete `DesiredMcpConfiguration`. The control plane
does not expose command-style add/remove mutation:

```text
DesiredMcpConfiguration {
    desired_revision,
    complete server set,
}
```

The Runtime computes unchanged, added, changed, and removed servers from stable
binding identity and the Host-supplied configuration fingerprint. Apply calls
are synchronous and serialized. A later caller waits for the in-flight Apply,
then its monotonic desired revision is evaluated against the published state.
No permanent AgentCore background thread and no Host tick are required.

Unchanged healthy servers retain their exact instance. A configuration-equal
Apply is a no-op only when the current catalog contains every desired server;
otherwise missing servers are reconnected. Added or changed servers are built
off-side. If a strict candidate fails, the current configuration and catalog
remain last-known-good. A successful candidate is published atomically and the
old generation retires through ordinary reference ownership.

Reconcile serialization and published-state synchronization are separate
mechanisms. Connector open/request/notify/close callbacks execute without any
Manager mutex held. A reconcile mutex serializes mutation; a separate
current-state mutex atomically publishes the catalog pointer and
desired/active/convergence values. Description retains the published generation
under the current-state mutex, then copies and encodes it after unlocking, so a
network handshake cannot block observation. Reentry from the reconcile owner
thread fails deterministically before waiting.

Apply terminal results are:

- `applied`: the desired set was processed and published or proved a complete
  no-op;
- `superseded`: a newer desired revision is already authoritative;
- `rejected`: candidate failed and the last-known-good configuration remains;

Apply and refresh must not be called reentrantly from a Connector callback.
Such calls fail deterministically instead of waiting on their own reconcile.

Runtime description is safe concurrently with Apply and reports desired and
active revisions plus value-only `converged` or `rejected` state.

## Era adapters and canonical capabilities

`mcp_modern.zig` owns 2026 behavior. `mcp_classic.zig` is parameterized by a
`ClassicProfile` for 2025-11 and 2025-06. Each adapter interprets its own
capability shape before producing copied canonical values.

Classic `capabilities.tools` controls whether `tools/list` is legal. Modern
discovery does not reuse that Classic rule. Execution modes normalize to
`ordinary`, `task_optional`, or `task_required`. Optional task support remains
callable as an ordinary request. Required-task tools remain unavailable because
Revision 7 does not implement MCP Tasks.

## Host integration boundary

AgentCore neither reads nor watches Host configuration. The Host resolves its
policy and configuration layers into the complete desired set and supplies
opaque Connector contexts. Secret values remain Host-owned and must never enter
configuration fingerprints, diagnostics, logs, or checkpoints.

The Host invokes Apply synchronously from a thread on which Connector callbacks
are legal, while other threads may query Runtime description concurrently. An
existing Session rematerializes its value selectors against the current catalog
on its next Run. Apply never expands Session authority implicitly: newly added
tools become available only after the Host explicitly updates that Session's
MCP selection through `session_update_mcp`.

Host behavior before configuration reaches Apply and after AgentCore returns a
result is outside the Revision 7 ABI contract and its verification gates.

## ABI contract

Revision 7 keeps the existing exact protocol-era codes and checkpoint value
identity while completing the public MCP control plane. Runtime creation may
provide an initial complete server set. The final Revision 7 table provides:

- declarative complete-set MCP Apply;
- refresh of the current desired set;
- value-only Runtime description and convergence status;
- Session value-selection updates;
- Connector context retain/release ownership.

IsolationDomain, InstanceId, live handles, credentials, transport session
state, and internal refcounts are not public or persisted.

The MCP checkpoint section writes `R7MCP` revision 2 and accepts exact
`R6MCP` revision 1 or `R7MCP` revision 2 pairs. It persists value-only Session
selection and permission identity. The outer AgentCore checkpoint remains
Revision-7-only.

C, Zig, Rust, manifests, link probes, component fixtures, and source-free
consumers are updated together and reject Revision 6 tables.

## Verification gates

- per-era adapter parsing, negotiation, and canonical parity;
- deterministic probe/open/close/notify/release traces;
- exact 2025-06 and AUTO 11-to-06 public Connector tests;
- Catalog generations contain no Client or transport pointers;
- exact InstanceId dispatch, no ABA, and no old-catalog/new-instance drift;
- add/change/remove/no-op complete-set Apply;
- concurrent Apply serialization and reentrant callback rejection;
- blue/green failure preserves last-known-good;
- reapplying an unchanged set reconnects servers missing from the catalog;
- schema changes invalidate grants while reconnects preserve identity;
- configuration, diagnostics, logs, and checkpoints contain no secrets;
- Runtime description is safe during Apply and exposes no internal IDs;
- strict C/Zig/Rust ABI, source-free consumers, bundle/archive/diff gates, and
  the full AgentCore component suite pass.

Revision 7 freezes only after the AgentCore gates above pass and the final
architecture and implementation reviews converge.

## Deferred supervisor capabilities

The ownership boundaries above intentionally permit a later general-purpose
MCP supervisor, but Revision 7 does not expose placeholders for unimplemented
behavior. Interactive affinity, sampling/elicitation routing, dedicated
credential principal/epoch identity, latest-wins coalescing, configurable
drain deadlines, singleton stop-then-start, forced cancellation, rollback, and
degraded generations require separate product needs, implementations, and ABI
review before they become normative contracts.
