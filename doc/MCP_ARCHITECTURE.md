# MCP architecture

There is one MCP protocol client, `McpClient` in `src/mcp/client.zig`. The CLI,
source-level library consumers and the AgentCore public facade all run it. A fix
to shared protocol behaviour changes that one implementation and is verified
across its consumers. The migration that produced this layout is issue #405; the
inventory below is the record that nothing was dropped on the way.

## Layout

| Layer | Files | Owns |
|---|---|---|
| Shared MCP module | `src/mcp/canonical.zig`, `json_admission.zig`, `wire.zig`, `era_modern.zig`, `era_classic.zig`, `negotiation.zig`, `schema.zig`, `result_stream.zig`, `protocol.zig`, `client.zig` | Protocol models, version negotiation, response validation, request correlation, cancellation, error classification, tool and resource requests, input continuation, result projection |
| Transport adapters | `transport.zig`, `transport_stdio.zig`, `transport_http.zig`, `transport_sse.zig`, `host_transport.zig`, `oauth.zig`, `url.zig` | stdio, Streamable HTTP, HTTP+SSE, a Host connection. One message-stream interface |
| Connection and catalog management | `runtime.zig`, `instance_pool.zig`, `catalog.zig` | A connected server with its canonical catalog, leases, immutable generations, refresh, expiry, declarative apply |
| Shared runtime integration | `core/tool_exec` (the kernel), `tool_invocation.zig`, `agentcore/mcp_session.zig`, `registry_bridge.zig` | Tool selection, permission, budget, result admission. Every call ends in `McpClient.invokeTool` under the same kernel |
| CLI/App | `src/app.zig`, `src/app/mcp_startup.zig`, `src/app/mcp_cli.zig`, `src/mcp/config.zig`, `launch.zig`, `naming.zig`, `param_headers.zig` | Configuration imports, startup policy, status presentation |
| AgentCore facade | `src/agentcore/abi_v1.zig`, `mcp_session.zig`, `mcp_checkpoint.zig` | Public contracts, handles, ABI conversion, callback bridging, Session selection, checkpoints |

`zig build test:mcp` builds and runs the shared module alone, and
`zig build subsystem:boundary` enforces its import closure: it cannot reach the
AgentLoop, the App, the REPL or AgentCore. `src/mcp/conformance.zig` is the shared
protocol suite: an in-memory peer behind the Host adapter, under both profiles.

## Entry-point differences

Everything that separates the entry points is a value of `client.Profile` or a
trait of the transport adapter. There is no entry-point branch in the state
machine. Each row is pinned by the named test.

| Difference | CLI (`Profile.product`) | AgentCore (`Profile.hostContract`) | Why retained | Test |
|---|---|---|---|---|
| Conformance | `interop`: frame without `jsonrpc`, error with a null `id`, `initialize` without `serverInfo` accepted | `strict`: all refused with a typed diagnostic | Real servers vs a stated public contract | conformance: "profiles differ: a frame short of the specification" |
| Revision window | 2026-07-28, 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05 | The first three (`Era.inStrictWindow`) | The ABI names three eras; widening it is an ABI change | conformance: "profiles differ: revision window" |
| Selection below the offer | Adopted on the same connection | Connection closed, exact era reopened once | Existing ABI contract | negotiation: "interop adopts…"; runtime: "AUTO promotes only the final exact 2025-06 connection" |
| Probe fallback | Any completed non-Modern answer falls back | Only validated evidence does | Same | negotiation: "interop falls back…" |
| Probe connection | `reuse`: one child, one TLS handshake | `disposable`: `purpose` tells the Host | The Connector contract; the CLI's cost | conformance: "profiles differ: who owns the discovery probe's connection" |
| Input continuation | On, with the host's elicitation handler (declined when none) | Off: terminal `input_required_unsupported`, one request, client unaffected | The ABI has no way to carry an elicitation; turning it on is a separate public API extension | conformance: "input continuation is a policy" (both positions) |
| Declared capabilities | `elicitation` | None | Follows from the row above | wire: "encodeRequest…" |
| Catalog bound | 2048 tools, 100 pages, truncates | `max_tools`, fails the server | Admission is all-or-nothing under the ABI | conformance: "profiles differ: the catalog bound…" |
| Catalog admission | Lenient: a malformed tool is skipped with a warning | Canonical: projected, fingerprinted, issue reported | The CLI registers what a server lists; AgentCore binds permission to a schema fingerprint | registry_bridge tests; catalog: "Catalog excludes broken Provider projections…" |
| Model-facing name | Readable `mcp__<server>__<tool>` | Opaque hashed alias | Provider-visible bytes are a cache contract, on both sides | mcp_session: "the same server through the product registry and the AgentCore overlay…" |
| Catalog lifetime | Published once at startup; `tools_changed` recorded for `/mcp` | Refresh, expiry, immutable generations, apply | CLI startup policy is the App's. The manager is shared and available to it | catalog tests; mcp_http_test: "a stale answer is skipped…" |
| Failure presentation | Remote error is a tool error carrying its frame; a failure of the request is the transport's error plus "may have executed" | `host_failed` JSON (`code`, `phase`, `rpc_code`) | The diagnostics are documented public output | tool_invocation test; agentcore_abi_test: "L2 public MCP wire failures…" |
| Failed-publication ceiling | Up to 1 MiB for a frame already in memory | `PER_RESULT_MAX_BYTES` | Existing commitment on each side | conformance: "profiles differ: the failed-publication ceiling…" |
| Cancellation | stdio, HTTP+SSE: `notifications/cancelled`. Streamable HTTP closes the stream | The connector polls the cancellation it holds | A property of the transport (`Transport.cancelsItself`) | mcp_protocol_test: "a timed-out call is cancelled…"; conformance: "cancellation before the send…" |

## Replay

Three things look alike and are not. `Disposition` in `canonical.zig` carries the
distinction to the caller.

| Case | Examples | Behaviour |
|---|---|---|
| Valid protocol continuation | MRTR retry with `inputResponses` and `requestState`; SSE resumption with `Last-Event-ID`; a POST a 401 refused, repeated after refreshing the token | Completes the one logical request. Never reaches a caller as a failure |
| Known not delivered (`not_delivered`) | Interrupted before the send; a POST whose body was never fully written; a pooled connection that failed on write; a 401/403 refusal | May be sent again. The client does so only for a pooled-connection write failure |
| Indeterminate (`indeterminate`) | No answer after the request left: timeout, dropped connection, server exit, HTTP 5xx, a connector's `indeterminate` | **Never replayed.** Reported with its cause; the product tells the model the call may have executed |

Streamable HTTP adds one trap: a reused connection that closes before any response
byte usually means the server dropped an idle connection, and is retried, but
nothing on the wire distinguishes it from a server that read the request and died.
A `tools/call` is therefore retried only when its body was not fully written, and
to keep the race rare it does not reuse a connection idle longer than
`TOOL_CALL_REUSE_IDLE_MS` (1 s). Other methods this client sends are repeatable and
keep the existing retry.

## Capability inventory

The migration's starting point: `src/mcp/client.zig` (CLI) and
`src/agentcore/mcp_*.zig` (AgentCore) at the base of #405. Disposition: **kept**
(behaviour unchanged, one implementation now), **policy** (a retained difference
above), **corrected** (see "Behaviour changes"), **evolve** (out of scope, separate).

| Capability | CLI before | AgentCore before | Production wiring | Tests | Now |
|---|---|---|---|---|---|
| Probe and handshake | `probeModern`, `initializeClassic` | `DriverState`, `negotiation.negotiate` | App startup; `Manager.buildSnapshot` | mcp_protocol_test; runtime tests; ABI L2 | One `Negotiator` driving `negotiateWith`. **policy** |
| Eras | 5 versions, static strings | 3, `canonical.Era` | | | One `Era` with 5 values, strict window of 3. **policy** |
| Request encoding | `wireParams`, `serializeRequest` | DTO encoders per era | | wire, era tests | One `wire.encodeRequest`. **kept** |
| Response parsing | Hand-written field scanners (`protocol.parseResponse`) | `wire.parseEnvelope` | | wire tests | One `wire.parseResponseEnvelopeWith`. Scanners deleted. **corrected** |
| Correlation, stale answers | Skip by id | One exchange per request | | mcp_protocol_test | `exchangeEncoded`, `Transport.singleResponse`. **kept** |
| Server requests: ping, elicitation | `handleServerRequest` | None (no such frames) | Stream transports | mcp_e2e_test, mcp_http_test | **kept** |
| `tools/list_changed` | Recorded | None | `/mcp` | New: mcp_http_test | **kept**, now tested |
| Pagination | Bounded, truncates | Bounded, fails | | mcp_http_test; runtime tests | One `paginateTools` with a page consumer. **policy** |
| Tool call (materialized) | `callToolAbortable` | `Client.callTool` | Source-level | mcp_e2e_test; runtime tests | One `exchange`. **kept** |
| Tool call (byte zero) | `requestBody` | `Client.callToolBody` | Registry; `Environment.dispatch` | mcp_e2e_test, ABI 17 MiB L2 | One `invokeTool`. **corrected** |
| Resources | list, read, both APIs | None | `ListMcpResourcesTool`, `ReadMcpResourceTool` | mcp_e2e_test; new: conformance | Available on every transport. Public AgentCore resource API: **evolve** |
| Prompts | Capability bit only | None | | | **kept**, `prompts/get` still unimplemented: **evolve** |
| Input continuation | MRTR rounds, elicitation, roots | Validated, reported unsupported | App (handler unset, declines) | mcp_protocol_test; runtime test | One code path. **policy** |
| Cancellation | AbortSignal, `notifications/cancelled` | `Cancellation` callback to connector | | mcp_protocol_test; ABI L2 | One `AbortSignal`, adapter bridges to the callback. **kept** |
| Error classification | Zig errors | `CallFailure` | | | One `failureOf`, adding `Disposition`. **corrected** |
| Timeouts | Startup, probe, per request | One per exchange | | mcp_protocol_test | **kept**, per adapter |
| Connection retirement | None | On a connector contract failure | | runtime test | In the client, for every transport. **kept** |
| Result projection, sealing | Two paths split at 1 MiB | `project` always | Commit boundary | result_stream, mcp_e2e_test | `project` for both, after frame classification. **corrected** |
| Resource limits | Line and frame caps | `canonical.Limits` | ABI limits struct | runtime test | `Profile.limits`. **policy** |
| Connection and catalog ownership | `McpSession`, App | `instance_pool`, `catalog.Manager` | | catalog, pool tests | Moved to `src/mcp`. CLI publishes at startup. **policy** |
| Refresh, expiry, immutable snapshots, apply | None | `catalog.Manager` | `metask_agentcore` MCP table | catalog tests; ABI L2 | **kept** |
| Identity and permission binding | Name-based rules | `permissionBinding`, fingerprints (#389) | | ABI L2 | **kept** |
| Auth context | Headers, per-server OAuth store | Host-owned connector | | mcp_sse_oauth_test; ABI L2 | **kept**; new: catalog "two servers keep separate…" |
| HTTP session, routing headers, `Mcp-Param-*` | `transport_http` | Host-owned | | mcp_http_test | **kept** |
| HTTP+SSE, SSE resumption, OAuth login (#410) | `transport_sse`, `oauth`, `mcp_cli` | Host-owned | | mcp_sse_oauth_test | **kept** |

### What remains separate

- `classic.parseCallToolResponse` and `modern.parseCallToolResponse`, and their
  `parseListToolsResponse`, are similar and stay per era: they are the era adapters.
- `registry_bridge` and `agentcore/mcp_session.zig` both turn a catalog into a tool
  surface. They differ by the rows above, and both call `McpClient.invokeTool`.
- `resources/list` over the byte-zero API reads one page. Paginating it changes what
  the model sees, so it is left as a separate change.

## Behaviour changes

Internal consolidation changed no ABI, no wire struct and no public protocol code;
`ABI_REVISION` is unchanged. What did change:

### Corrections to the CLI

1. A tool's `isError: true` is a tool error at every size. A result under 1 MiB used
   to reach the model as a success containing `"isError":true`; over 1 MiB it was
   already an error.
2. A `tools/call` without `content` is accepted at every size. Over 1 MiB it used to
   be refused.
3. A `result` that is not an object is refused. It used to pass as a value.
4. Arguments that are not one JSON object are refused locally (`McpInvalidParams`).
5. A `tools/call` is not retried after its body went out, and does not reuse a
   connection idle over 1 s (see "Replay"). A failure after the request left tells
   the model the call may have executed. New error: `McpOutcomeIndeterminate`.
6. The materialized APIs (`callTool`, `listResources`, `readResource`) return the
   result re-encoded from the parsed frame: whitespace differs, numbers do not.
7. Requests on a closed client fail with `McpInstanceUnavailable` instead of writing
   to a closed pipe (`McpServerCrashed`).
8. Frames over 1 MiB get the wider limits of smaller ones (depth 256, 8 M nodes).
   They used to be refused above depth 64 or 131 072 nodes.

### Corrections to AgentCore

1. The byte-zero path no longer refuses a result whose content holds an escaped
   control character such as `\u001b[31m`. `canonical.validateJsonValue`, which the
   materialized path uses, already allowed it. Protocol text (`jsonrpc`, `resultType`,
   error messages, envelope keys) is still refused.
2. `callToolBody` on a retired client reports `instance_unavailable`, as `callTool`
   did, rather than reaching a closed connection.

### Source-level API (`metacodes-core`)

- Modules moved: `agentcore/mcp_*` to `mcp/*`. `abi_v1.mcp_catalog`, `mcp_runtime`,
  `mcp_canonical` and friends still resolve. `abi_v1.mcp_protocol` is gone: use
  `core.mcp_protocol`, which now holds that namespace.
- `mcp_protocol` no longer offers `parseResponse`, `findObjectField`, `extractMethod`,
  `parseUintField`, `initializeParams` or `serializeRequest`.
- `mcp_runtime.Client.callTool` and `callToolBody` take `?*const AbortSignal` rather
  than a `Cancellation`. A Host connector still receives a `Cancellation`.
- New: `McpClient.invokeTool`, `client.establish`, `client.Profile`,
  `canonical.Disposition`, `mcp_client.structuredMcpError`.

No supported-version change for AgentCore. No public API extension: resources and
input continuation are available to source-level consumers and not through the ABI.
