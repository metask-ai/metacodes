# metacodes Plugin Contract v1

Status: contract frozen in TinyKG task 12710; kernel, active contribution
categories, embedding inventory, static effect ownership and typed service graph
implemented through tasks 12711–12713, 12727 and 12731.
Task 12714 has a passing zero-provider architecture/performance receipt and a
pre-registered paid coding pair. User authority is present, but the first
`1.2.0` paid attempt failed closed on an invalid provider trajectory; quality
therefore remains blocked pending a newly frozen complete cohort. This document
does not claim that every contribution category is active. See
`doc/PLUGIN_EVALUATION.md`.

## 1. Outcome

metacodes adopts DSH's strongest composition ideas—stable service identities,
declared dependencies, scoped contributions and reversible ownership—without
adopting DSH's replaceable agent loop. The architecture has three planes:

1. **Kernel plane** owns the agent loop, causal session ledger, model-visible
   history, tool ordering, cancellation, budgets, permission/sandbox monotonic
   guard, Lean verdicts, TinyKG CAS/provenance and checkpoint identity.
2. **Extension plane** contributes versioned capabilities to an immutable
   Runtime snapshot. Contributions carry `PluginId` provenance and cannot
   weaken a later kernel decision.
3. **Host plane** embeds that Runtime through the existing Zig API, C ABI,
   Rust SDK, Web backend or a versioned process protocol. Hosts observe events
   and answer typed requests; they do not mutate AgentLoop internals.

The kernel plane is deliberately not a plugin. There is no `agent_loop`,
`permission_guard`, `lean_verdict`, `tinykg_writer`, `budget_ledger` or
`checkpoint_store` capability.

## 2. Evidence and deliberate deviations from DSH

The DSH analysis is pinned to commit
`b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`. Its 246-workspace build/typecheck
and a focused 821-test suite pass locally. DSH's Cordis runtime demonstrates:

- service-definition/provider separation;
- plugin-owned effects that unwind in reverse order;
- ordered profile/bundle composition and scoped service resolution;
- a durable session log as model-context authority;
- native tool scheduling with model-order result commit;
- an extensible pre/around/post tool pipeline followed by a non-bypassable
  native guard.

metacodes keeps those patterns, but rejects two DSH choices:

- AgentLoop is not replaceable. metacodes' formal, ontology and self-evolution
  properties require one causal owner.
- Same-process model-authored code is not a security boundary. Untrusted code
  uses an out-of-process protocol; arbitrary Zig dynamic libraries are never
  loaded.

The TypeScript reference under `cc/src/utils/plugins/` supplies useful package
precedence, dependency and path-validation behavior. It is a data-package
loader, not the service runtime by itself.

No public coding-benchmark result is shipped in the pinned DSH repository.
Flexibility is therefore a source-backed fact; benchmark superiority remains a
paired-evaluation hypothesis for task 12714.

## 3. Identity, version and namespace

`src/plugin/contract.zig` is normative for value semantics:

- `PluginId`: 3–48 ASCII bytes; lowercase alphanumeric segments separated by
  dots, with internal hyphens allowed. Paths, underscores, empty segments and
  Unicode confusables are invalid.
- `Version`: SemVer 2.0. Manifest dependency `minimum_version` means same
  compatible line and greater than or equal to the minimum: `1.x`, `0.2.x`, or
  exact `0.0.x`.
- Provider tool name: collision-free encoding of `PluginId`, then `__`, then a
  local name. Dot encodes as `_d` and hyphen as `_h`; underscores are forbidden
  in `PluginId`, so encoding is reversible.
- Layer priority is Host-owned, never self-declared by a package.

Plugin IDs, component names and dependencies are unique inside one immutable
snapshot. Duplicate identities at the same layer, dependency cycles, missing
dependencies and namespace collisions fail the entire candidate snapshot.

## 4. Forms and trust boundaries

### `static_trusted`

Compiled into metacodes or supplied explicitly by an embedding Host. It may
provide typed in-process callbacks such as the existing `HostSyncTool`. Callback
contexts are Host-owned and must outlive the Runtime. This is the low-overhead
path for first-party and audited extensions. An optional typed activation runs
only while the immutable Snapshot is staging. It receives a borrowed registrar,
not Runtime/AgentLoop mutation authority, and may register synchronous cleanup
callbacks owned by that Snapshot. Static plugins may additionally declare the
`service` capability: a provider publishes a typed service during activation and
a consumer resolves it only when its descriptor explicitly depends on that
provider.

### `data_package`

A directory containing `.metacodes-plugin/plugin.json` plus conventional data
directories. Kernel-owned parsers read the content; package code never runs.
The frozen data-package layout reserves these declared directories:

- `skills/` for `skill_bundle`;
- `agents/` for `agent_bundle`;
- `ontology/` for inert evidence candidates (not accepted by the current CLI
  Host profile until the native provenance/promotion projector is wired);
- `evals/` for local evaluation definitions (not accepted until the frozen
  harness/receipt projector is wired).

Symlinks, path traversal, content outside the package root and undeclared
directories fail closed. Ontology content is evidence only; it cannot write
TinyKG or become an active rule without the existing provenance, Lean and CAS
promotion path.

### `out_of_process`

A versioned framed protocol for executable extensions. It must negotiate the
exact protocol major, capability subset, limits and cancellation behavior
before publication. The child receives capability-scoped Host services, not
raw kernel pointers. OS process/VM isolation is defense in depth; the native
permission/sandbox/formal guard remains authoritative.

Process protocol v1 is implemented for `host_tool` only. It uses an explicit
process-package loading channel, exact entrypoint SHA-256, exact-major
handshake, strict Content-Length framing, an empty POSIX environment, one fresh
process group per invocation, cancellation/deadline/output caps and mandatory
reaping. Every tool is kernel-classified as `execute`; the process cannot
declare a weaker category or a fatal AgentLoop result. Other process
capabilities remain fail-closed. Contract v1 never loads a Zig dylib. The exact
wire and threat model is `doc/PLUGIN_PROCESS_PROTOCOL.md`.

## 5. Manifest v1

The common manifest is strict JSON at
`.metacodes-plugin/plugin.json`:

```json
{
  "schema_version": 1,
  "id": "acme.review",
  "version": "1.2.0",
  "capabilities": ["skill_bundle", "agent_bundle"],
  "requires": [
    { "id": "acme.base", "minimum_version": "1.0.0" }
  ]
}
```

Unknown fields, unknown capabilities, duplicate capabilities/dependencies,
self-dependencies and incompatible forms are errors. Empty `requires` is the
default. Empty capabilities is invalid. No `priority`, permissions, sandbox
bypass, arbitrary settings or executable entrypoint exists in this schema. The
Host loading channel fixes the form; a data source cannot self-promote into
executable authority. A process package adds a separate strict
`.metacodes-plugin/process.json` containing the pinned entrypoint, SHA-256 and
bounded transport limits.

Static plugins use the same validated descriptor programmatically. Process
plugins use the common identity/dependency descriptor plus their process
configuration, whose fields are enforced end-to-end.

A static `host_tool` contribution has two disjoint executor declarations:
`tools` for bounded completed UTF-8 buffers and `stream_tools` for a borrowed
byte-zero sink committed by the kernel into Session CAS. Both are projected
through the same immutable snapshot and collision namespace; declaring the
same local name in both modes rejects the entire candidate generation.

## 6. Capability negotiation

Known capability names are:

| Capability | data | static | process | Authority after contribution |
|---|---:|---:|---:|---|
| `host_tool` | no | yes | yes | ToolCatalog advertises; kernel admits/guards/commits |
| `skill_bundle` | yes | yes | no | canonical Skill Runtime parses and activates |
| `agent_bundle` | yes | yes | no | AgentSet parses; subagent policy remains kernel-owned |
| `provider` | no | yes | yes | Provider vtable; AgentLoop owns request timing/logging |
| `advisory_hook` | no | yes | yes | may enrich/reject early; cannot override final guard |
| `ui_backend` | no | yes | yes | observes `CoreEvent`, answers typed `UiRequest` |
| `ontology_evidence` | yes | yes | yes | inert evidence only; Lean/TinyKG promotion is native |
| `eval_pack` | yes | yes | yes | frozen local harness with plugin provenance |
| `service` | no | yes | no | activation-time typed injection only; no kernel service or live registry access |
| `builtin_tool_bundle` | no | yes | no | first-party native ToolEntry bundle; kernel permission/category/dispatch remain authoritative |
| `provider_dialect` | no | yes | no | immutable model-prefix adapter below an existing transport; deterministic capability/request/response projection only |

Activation is the intersection of descriptor claims, form-allowed capability,
Host-supported capability and policy. Partial activation is not implicit: an
unsupported required capability rejects the plugin so behavior cannot silently
degrade.

## 7. Discovery and precedence

Candidate roots are explicit and bounded. Low-to-high precedence is:

1. built-in compatibility plugins;
2. installed personal packages;
3. project packages;
4. session/CLI package directories;
5. managed enterprise policy, whose enable/disable decision is final.

Discovery never accesses the network. Marketplace/install/update is a separate
transaction that produces an immutable local package plus checksum/provenance.
Startup consumes only that cache. A higher layer may replace a lower descriptor
with the same `PluginId`; equal-layer duplicates are deterministic errors.
Dependencies are resolved only after the winning set is known.

## 8. Lifecycle and snapshot semantics

The loader performs `discover -> parse -> validate -> resolve -> project ->
activate -> publish`. Publication is atomic. `src/plugin/effect_scope.zig`
implements the trusted static-plugin effect owner as a typed state machine:
`staging -> active -> disposing -> disposed`. Every fallible descriptor,
filesystem, process-handshake and contribution projection step completes before
plugin activation. Static activations then run in dependency-topological order.
A failure destroys all registered effects in strict reverse registration order
and no Snapshot is returned.

The activation registrar is valid only in `staging`; retaining it cannot add an
effect after commit. Cleanup is synchronous and infallible, changes the Scope to
`disposing` before invoking plugin code, and is idempotent under repeat or
reentrant disposal. A cleanup callback owns its own context; the Scope owns and
copies only effect identity metadata. `AgentRuntime.destroy` refuses with
`RuntimeBusy` while any Session is alive, so callbacks and tool contexts cannot
be torn down beneath an admitted Session.

The same registrar implements the static service graph. A service key is the
pair `{provider PluginId, strict local service name}` plus exact Zig type
identity inside one compiled Host. `provide(T, name, pointer, cleanup)` binds the
service to an automatically owned effect. `require(T, provider, name)` succeeds
only for self-access or a descriptor-declared dependency and fails on missing,
duplicate or type-mismatched values. Consumers capture the resolved pointer
during dependency-ordered activation; the registry cannot be queried or mutated
after commit. No AgentLoop, Permission, Lean or TinyKG object is registered in
this graph.

A `static_trusted` plugin may also contribute one synchronous
`advisory_policy`. All published policies are intersected; AgentSession then
intersects that Snapshot ceiling with any facade/run policy. `allowsTool=false`
removes a definition from provider-visible schemas, while
`allowsInvocation=false` produces the ordinary paired native policy-denial
result before dispatch. Returning true grants nothing: native permission,
workspace, sandbox and formal gates retain final authority. Contract v1 does
not let this callback rewrite arguments, synthesize approvals, or transform
post-tool results.

Each snapshot published by one `RuntimeHost` has a monotonic `GenerationId`.
A Session retains the generation admitted at creation. Source-level Zig Hosts
may call `RuntimeHost.replace`: it stages a complete successor outside the
publication lock, atomically redirects new Session admission, and retires the
predecessor. Existing Sessions continue on their original catalog/effects; the
old Runtime self-reaps only after its last Session exits. Failed staging leaves
the active pointer and generation counter unchanged. This is immutable
generation replacement, not in-place plugin HMR or arbitrary dylib reload. No
operation mutates the tool/prompt/plugin inventory of an active Session.

Every contribution records `{plugin_id, plugin_version, generation_id,
contribution_id}`. Any contribution that can affect model-visible input is
recorded in the canonical session ledger before the request; any tool outcome
is recorded before it becomes model-visible.

## 9. Host services, events and requests

Plugins receive narrow services by capability:

- tool registration/dispatch descriptors, not ToolCatalog mutation;
- read-only workspace and run identity;
- typed event emission with plugin provenance;
- typed UI request forwarding;
- cancellation and monotonic resource budget views;
- evidence submission to native formal/ontology adapters.

They never receive mutable Conversation, PermissionContext, TinyKG writer,
formal verifier internals, JobRegistry or AgentLoop state. Plugin-defined event
payloads use a versioned opaque envelope and size limit. Core control events and
requests remain closed tagged unions; plugins cannot manufacture approvals,
tool commits or run-state transitions.

## 10. Monotonic safety pipeline

The target tool execution order is:

`schema -> plugin advisory prehooks -> native permission/settings/protected
paths -> sandbox/resource gate -> Lean/project-rule gate -> dispatch -> plugin
advisory posthooks -> native result normalization/journal -> ordered commit`.

An earlier plugin may deny or narrow. It cannot convert a later deny into allow,
increase a budget, suppress provenance, bypass sandboxing or publish an
unverified ontology/rule mutation. Timeout, malformed response, worker death or
budget exhaustion becomes a structured failure; safety-relevant uncertainty
fails closed. Contract v1 currently admits static Host tools and a static
synchronous advisory execution ceiling into this native pipeline. Input
rewriting, around-dispatch replacement and post-result transformation remain
outside the descriptor-activated surface.

## 11. Self-iteration

Plugin self-improvement is a promotion pipeline, not live self-modifying code:

1. a plugin or model proposes an inert candidate;
2. TinyKG records source, task, observations and candidate identity;
3. the local harness evaluates a frozen candidate against baseline;
4. Lean/native formal checks produce a provenance-bound verdict;
5. TinyKG CAS promotes only the exact reviewed hash;
6. a new immutable plugin generation is staged and published;
7. regressions drain/rollback to the previous generation.

The existing provisional rule path remains advisory until this promotion gate
is connected. No candidate may auto-promote merely because it was generated by
the agent that will consume it.

## 12. Compatibility and delivery gates

The source-level dynamic tool boundary uses the same typed result data plane as
the immutable Runtime catalog. `DynExecutor` is a closed tagged union:
`legacy_inline` owns the explicit compatibility lift from an owned `[]u8`, and
`result_body` transfers `inline`, `artifact`, or `structured_error` without
flattening. A `DynToolEntry` cannot contain both callbacks or neither. New
registrars use `registerBody`, `registerMcpBody`, or
`registerBorrowedDefinitionBody`; the older registration functions remain
source-compatible adapters for Skills and integrations that still produce one
completed buffer. CLI process tools use the typed path, so a byte-zero process
spool stays an artifact receipt through `DynRegistry`, AgentLoop projection,
Conversation, and `ReadArtifact` recovery.

- Contract and manifest major versions are exact-match and fail closed.
- Additive wire work still requires capability negotiation; no struct-size
  guessing or silent downgrade.
- Existing direct built-ins and `HostSyncTool` remain compatibility fast paths;
  pluginization wraps their composition, not their execution hot path.
- Every manifest/config field must have L2 proof from input to request or
  behavior. Unsupported fields are rejected, not stored for appearance.
- Release requires unit negatives, L2 fixtures, `test:lib`, ReleaseSafe, coverage
  audit, ABI consumer tests, resource/leak tests and paired benchmark receipts.

## 13. Staged implementation matrix

| Stage | Frozen now | Runtime status |
|---|---|---|
| Contract types/kernel boundary | yes | `src/plugin/contract.zig` |
| Strict data manifest/discovery/dependencies | yes | implemented in `plugin/manifest.zig` + `plugin/runtime.zig` |
| Static Host tool compatibility plugin | yes | implemented through `AgentRuntime`; Host effect metadata reaches native permission guard |
| Static effect ownership | yes | typed `EffectScope`; dependency-order activation, staging-only registrar, reverse/idempotent cleanup, activation-failure rollback, and `RuntimeBusy` Session pinning have L2 proof |
| Static typed service graph | yes | `service` capability; provider/local key + exact type identity, declared-dependency access, activation-time injection, automatic effect ownership and real Host-tool L2 |
| Static advisory hook | yes | `advisory_hook` capability; immutable Snapshot intersection + per-Run Host-policy intersection; provider visibility/argument denial L2 and plan-mode non-bypass L2 |
| First-party core capability packs | yes for Zig Runtime | `builtin_tool_bundle`; `none`/`minimal`/`offline-coding`/`coding`/`coding-interactive`, native fast path, inventory provenance and RuntimeHost generation replacement L2 |
| Immutable Runtime replacement | yes | source-level `RuntimeHost`; transactional stage/publish, failed-stage preservation, old/new Session generation pinning and last-Session effect cleanup have one provider-facing L2 |
| Provider dialect contribution | yes for Zig Runtime | `provider_dialect`; static-trusted, Snapshot-scoped longest-prefix resolver below existing transports, typed request-visible capability + request/profile/response adaptation, duplicate-key rejection and cache-stable equivalent replacement L2 |
| Skill/Agent package directories | yes | implemented through repeatable `--plugin-dir`; both are namespaced and reach one App/provider-request L2 |
| Process Host tools | yes | implemented through explicit `--process-plugin-dir`, Zig `RuntimeConfig.process_plugins`, and AgentCore v1 revision 13 `runtime_create_with_plugins`; hash-pinned, namespaced, exact-handshake, native `execute` permission/authority binding, abort/timeout/cap/reap L2; CLI `DynRegistry` preserves typed artifacts |
| Static Host tools | yes | implemented through AgentRuntime; namespaced, attributed and guarded by the native permission pipeline |
| Provider transport contribution | semantic boundary yes | descriptor activation rejected; embedding Hosts use the existing borrowed Provider override vtable |
| Advisory policy/hook | synchronous ceiling yes | static descriptor activates monotonic `ToolExecutionPolicy`; it can hide/deny but never grant or rewrite; process/input-rewrite/around/post variants remain fail closed |
| UI backend | semantic boundary yes | descriptor activation rejected; Host plane uses typed `EventSink`/`UiRequester` without entering AgentLoop |
| Ontology evidence | directory/authority boundary yes | descriptor activation rejected until inert source → provenance/Lean/TinyKG promotion is wired |
| Eval pack | directory/receipt boundary yes | descriptor activation rejected until frozen harness + receipt consumption is wired |
| Process transport/resource controls | yes for `host_tool` | strict one-shot v1 implemented; provider/hook/UI/evidence/eval/service capabilities remain fail closed |
| Unified Tool Result data plane | yes | closed typed executor unions for static/dynamic tools; public Host sink, process plugin, MCP stdio/AgentCore connector and eight high-output native tools spool from byte zero into one Session CAS; inline promotion and path-free recovery envelope preserve the frozen tool schema |
| Plugin inventory through Host interfaces | yes | implemented as immutable `metacodes.plugin-inventory/v1`: Zig `AgentRuntime.describePlugins`, CLI `--dump-plugins`, Web `/state.plugin_inventory` |
| Paired coding/security/performance verdict | evaluation rules yes | deterministic receipt passes; first `1.2.0` paid attempt failed closed after 9/36 rows, so no paired verdict exists yet |

`src/plugin/support.zig` is the executable status matrix. It exhaustively maps
every `(HostProfile, Form, Capability)` to active Runtime support, an existing
Host-plane seam, a governed-native-only boundary, or planned fail-closed work.
`plugin/runtime.zig` additionally rejects a capability whose descriptor has no
concrete projector, even if a caller accidentally advertises that capability
as supported. This is the implementation form of “declaration = wiring = L2.”

The independent Zig fixture in `example/main.zig` composes and inventories a
static plugin, replaces the first-party core profile from minimal to coding,
and inventories both generations before optionally running a stateful
`AgentSession`. The exact core capability/Host support matrix is
`doc/CORE_PLUGIN_HOTSWAP.md`. The
source-free AgentCore C/C++/Zig/Rust bundle is ABI v1 revision 13. Its explicit
`runtime_create_with_plugins` constructor loads strict process packages and
binds their executable/package/schema digest into native Permission and
checkpoint identity. The original `runtime_create` remains the no-process path
with an unchanged 96-byte `RuntimeConfigV1`. Revision 13 additionally exposes a
distinct `HostStreamToolV1` descriptor whose borrowed write-only sink spools
from byte zero into the Session CAS, and makes the distinct
`McpConnectorV1.request_tool_stream` callback mandatory for byte-zero MCP
`tools/call` responses. Both paths converge on the same typed result/CAS/
`ReadArtifact` kernel. It still does not claim
generic data/static plugin grouping or inventory; adding those fields requires
another explicit revision, and reserved fields are not an informal extension
channel.

Revision 13 also lets an embedded Host select the kernel-owned durable Run
journal. Process, MCP, Host, built-in, and fork-Skill dispatches all emit into
that same provider/tool intent-result plane; plugin metadata remains only a
candidate replay declaration and cannot grant automatic replay authority.
Journal records are outside Conversation/request projection, preserving prompt
cache identity. Crash-prefix classification is implemented; in-place active-Run
resume remains outside the current public ABI.
