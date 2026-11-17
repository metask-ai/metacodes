# Teamwork Manager MCP protocol

This is the normative Manager MCP boundary for teamwork (#522). Any MCP client,
including Claude Code, can drive the same runtime as the built-in SWE manager.
The manager does not implement review, auditing, budgeting, sandboxing or merge.
Those remain runtime and driver responsibilities.

The MCP client owns the Manager process and its model billing. The runtime's
dollar cap covers the workers and audit it launches. It does not account for
the MCP client's own model usage. Choose the Manager by running the client
(for example Claude Code); configure worker harnesses independently in the
teamwork policy. Automatically launching a Manager from `seats.manager` is
not part of this stdio adapter.

## Host authorization and ownership

The host obtains user approval, loads the configuration and dependencies, and
starts `runtime.Run` with the original approved request. Then it calls:

```zig
var server = mcp_server.Server.init(gpa, run);
try server.serve();
```

`Server.init(gpa: std.mem.Allocator, run: *runtime.Run) Server` borrows the run.
The host keeps the run and its configuration alive until serving ends and
destroys the run afterward. There is no `teamwork_start` or approval tool.
Neither initialization nor any tool accepts a new request, configuration,
budget, check command, state root, run id or workspace. Unknown tool arguments
are rejected before any runtime operation. Dispatch instructions are optional
manager notes; they cannot replace the approved request or configured check.
The runtime also rejects instructions naming its run state and paths.

One thread drives the server and run. The host may concurrently trip only the
run's shared `abort` signal. It owns signal handling and the process-wide
broken-pipe policy. All host and driver diagnostics must go to stderr; stdout
belongs exclusively to MCP. This adapter never changes drivers or sandbox
policy.

The built teamwork CLI does not discover or start outbound MCP servers. In
particular, importing a Claude Code user configuration containing this endpoint
must not recursively start another copy. Native built-in tools are published
before seats are constructed. Claude Code Workers also receive an explicit
empty strict MCP configuration; the Manager channel is not inherited by them.

## Transport and lifecycle

`Server.handle(self, gpa, line) error{OutOfMemory}!?[]u8` processes one JSON-RPC
message without a newline. A non-null response is allocated with the supplied
allocator and must be freed by the caller. Null means no response. The server
retains neither input nor output buffers. The transport-independent engine can
be embedded in another host without starting a process.

`Server.serve(self) !void` reads stdin and writes stdout.
`Server.serveFds(self, input: platform.fs.Fd, output: platform.fs.Fd) !void`
uses host-owned descriptors and does not close them. Both use newline-delimited
UTF-8 JSON, accept CRLF, retry interrupted POSIX reads and use the platform's
complete-write routine. No Content-Length framing is used. EOF cancels a live
run; terminal states remain terminal. Transport failure attempts cancellation
before returning the error. A final frame without a newline is rejected and
never executed.

Requests are limited to 1 MiB excluding the delimiter; responses to 4 MiB
excluding the delimiter. Oversized input is drained through the next newline,
produces one error, and processing resumes. Invalid JSON also produces an error
without ending the session. Response overflow produces an internal error with
the request id; an operation may already have taken effect, so query status
before retrying it. Out-of-memory and transport errors are returned to the host.

The client sends `initialize` with object `capabilities`, string
`protocolVersion` and `clientInfo` containing string `name` and `version`.
The server declares only `tools: {"listChanged": false}` and identifies itself
as `metacodes-teamwork`, version `1.0.0`. It implements the classic
`2025-11-25` MCP protocol and accepts classic `2025-06-18`, `2025-03-26` and
`2024-11-05` requests at their requested version. For other requested versions
it selects `2025-11-25`; the client must decide whether it supports that version.
Modern MCP tasks and server-initiated requests are not advertised.

After the initialize response, the client sends
`notifications/initialized`. Tool requests before this notification fail with
`-32000`. Repeated initialization fails. `ping` returns an empty object even
before initialization. Notifications never execute tools, including malformed
or id-less `tools/call` messages. Unknown notifications and client responses are
ignored. An initialized notification with non-object params has no effect.
Request ids must be strings or integers and are echoed exactly. Batches are
unsupported. `tools/list` returns all four tools without a pagination cursor.

## Tools

All argument schemas are objects with `additionalProperties: false`. The same
restrictions are enforced by the engine, independently of schema enforcement
in the client. No-argument tools accept omitted arguments or an empty object.

| Tool | Arguments | Runtime operation |
| --- | --- | --- |
| `teamwork_status` | none | `Run.status()` |
| `teamwork_dispatch` | required `role`: `implementer` or `reviewer`; optional string `instructions` | `Run.dispatch(role, instructions)` |
| `teamwork_request_completion` | none | `Run.requestCompletion()` |
| `teamwork_cancel` | none | `Run.cancel()` |

Dispatch and completion are **synchronous**. One request runs until its runtime
operation returns; stdio does not read another call during that time. Clients
must allow a timeout appropriate to the configured seat limits. Cancellation
through `teamwork_cancel` takes effect between calls. During an active operation
the host can trip the shared abort signal, which runtime drivers already
observe. A queued MCP cancellation notification does not preempt synchronous
work. The adapter does not claim MCP task or progress support.

Completion without current verified reviewer approval returns `NotApproved`.
The runtime rechecks approval against the current tree, independently audits,
then merges the audited work into the original user workspace, uncommitted.
An unavailable auditor yields `failed/audit_unavailable`, never `done`.
Stale approval or a first failed audit can request review or repair; callers
must inspect the returned state. Only `snapshot.state.kind == "done"` means
completion. Cancel is idempotent on ended runs and retains unfinished work.

## Results and errors

Tool results include MCP `content` with one text item and `structuredContent`.
The text is the JSON encoding of the same structured object:

```json
{
  "snapshot": {
    "run_id": "run-example",
    "goal": "The first line of the approved request",
    "state": {"kind": "approved", "detail": null},
    "seats": [],
    "budget": {"cap_usd": 5, "spent_usd": 0, "remaining_usd": 5, "charges": 0},
    "open_issues": 0,
    "audit": {"used": 0, "max": 2, "last": null},
    "max_rounds": 8,
    "worktree": "/host-selected/run/worktree",
    "merge_conflicts": 0
  },
  "operation": {"kind": "status"},
  "error": null
}
```

Every value comes from the actual `Run.status()` snapshot; the adapter does not
invent progress or a passing audit. Runtime tagged unions use `{kind, detail}`
to retain their discriminators. Seat entries contain string `id`, `role`,
`harness`, `status` and a nullable tagged `result`. Review and seat failure
details retain their nested union tags. Budget, audit, issue and conflict
counts are runtime values. Tree ids are hash strings, without backing-buffer
padding. When supplied by the runtime, each seat's optional `charter_sha256`
field is forwarded unchanged. Paths are observations, never writable parameters.
Dispatch adds `operation.seat_id`; completion adds a tagged
`operation.outcome`; cancellation reports `operation.kind == "cancel"`.

Runtime errors produce `isError: true`, a symbolic `error` string (for example
`NotApproved` or `RunEnded`), and a fresh actual snapshot. Completion outcomes
`failed`, `budget_exhausted` and `cancelled` also set `isError: true`; review or
repair requests are successful operations that have not completed the run.
Dispatch may return a failed seat in the snapshot even when the operation
itself returned normally. Never treat `isError: false` as proof of completion.

JSON-RPC failures use `-32700` for parse/truncated-frame errors, `-32600` for
invalid envelopes and oversized frames, `-32601` for unknown methods,
`-32602` for invalid parameters or unknown tools, and `-32603` for response
overflow. Parse errors and invalid ids use null response ids. A valid
notification receives no response and cannot cause a runtime mutation.

## Claude Code configuration

The [example configuration](../examples/teamwork/claude-code-mcp.json) uses
Claude Code's `mcpServers` stdio format. Replace the two absolute placeholder
paths with the installed executable and a file containing the user-approved
request. The launch command is
`metacodes teamwork mcp --request-file <approved-request> --approve --budget-usd 5`.
That command belongs to the host's CLI integration; the engine itself neither
parses those flags nor grants approval. The human-configured `--approve` is
not an MCP argument, tool or manager decision. Keep the host's validated
configuration and original request fixed for the run. The fixture contains no
proprietary manager prompt and requires no particular manager harness.

Protocol references: [MCP stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports),
[MCP lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle),
[MCP tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools),
[Claude Code MCP configuration](https://code.claude.com/docs/en/mcp).
