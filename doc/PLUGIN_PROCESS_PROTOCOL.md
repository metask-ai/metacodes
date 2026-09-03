# metacodes process plugin protocol v1

Status: implemented contract for `out_of_process` `host_tool` contributions,
including the optional `artifact_spool_v1` result transport extension. The
protocol is deliberately smaller than the full plugin capability vocabulary.

## Kernel invariants

Process plugins extend the immutable Runtime catalog; they do not replace or
wrap `AgentLoop`.  The kernel remains the sole owner of tool admission,
permission decisions, cancellation, Conversation history, TinyKG mutation/CAS,
Lean verdicts, budgets and self-evolution.  In v1 a process plugin receives only
its local tool name and the already-admitted JSON arguments.

`host_tool` is the only manifest-level active process capability.
`artifact_spool_v1` is a negotiated transport extension, not authority and not
a manifest capability. `provider`, `advisory_hook`,
`ui_backend`, `ontology_evidence`, `eval_pack` and the static-only `service`
capability remain fail-closed until each has a native end-to-end admission path.
Process packages cannot claim Skill or Agent bundles; those remain inert data
packages.

Every contributed tool is namespaced with the reversible plugin-id encoding and
is classified by the kernel as `execute`. A plugin cannot lower its permission
category, mark itself prefetch-safe, become a concurrent Host callback, or emit
a fatal AgentLoop control result.

Each staged tool also receives a non-zero 32-byte authority binding:
`SHA-256("metacodes-process-tool-authority-v1\0" || framed(plugin_id) ||
framed(version) || executable_sha256 || framed(global_name) ||
framed(validated_reserialized_input_schema_json))`, where `framed(x)` is an unsigned 64-bit
big-endian byte length followed by the exact bytes. Native Permission
provenance and AgentCore checkpoint restore use this binding, so a package,
binary or schema change cannot inherit remembered authority by reusing a tool
name.

## Explicit installation authority

Executable plugins are enabled through a distinct process-package source. A
data-package source can never become executable because of manifest contents.
The package root is canonicalized and the entrypoint must resolve inside it.
The final entrypoint cannot be a symlink, must be a regular executable file, and
is checked against the exact lower-case SHA-256 in `process.json` before staging
and before and after every call.

Process isolation is a crash/resource/lifecycle boundary, not an operating-system
sandbox. Enabling a process package therefore grants its pinned executable the
same OS account authority as metacodes. Package installation/update is a trusted,
quiescent operation: concurrent replacement during activation or invocation is
outside v1's trust model. Native metacodes policy is still final about whether a
tool invocation occurs, but it cannot revoke ambient filesystem authority that
the OS already grants the executable. A future sandbox capability must be a
separate, measured security boundary.

Loading channels are repeatable CLI `--process-plugin-dir`, source-level Zig
`AgentRuntime.process_plugins`, and AgentCore ABI revision 13
`runtime_create_with_plugins`. The AgentCore descriptor requires an absolute
root, one explicit layer, at most 64 sources, and zero reserved fields. All
three channels converge on the same transactional immutable snapshot and
executor; none is a second AgentLoop.

On POSIX the child receives an empty environment; no API keys or inherited
configuration are forwarded. Windows' current process primitive cannot supply a
custom environment block, so process plugins fail closed on Windows in v1.

## Package files

`.metacodes-plugin/plugin.json` uses the common strict manifest, parsed with
form `out_of_process`:

```json
{
  "schema_version": 1,
  "id": "acme.review",
  "version": "1.0.0",
  "capabilities": ["host_tool"]
}
```

`.metacodes-plugin/process.json` is also strict (unknown and duplicate fields
are rejected):

```json
{
  "schema_version": 1,
  "protocol_major": 1,
  "entrypoint": "bin/acme-review",
  "sha256": "<64 lower-case hex bytes>",
  "handshake_timeout_ms": 2000,
  "call_timeout_ms": 30000,
  "max_response_bytes": 1048576
}
```

Timeouts and response limits have kernel minimums and maximums. They are upper
bounds requested by the package, not authority to exceed Host limits.
One Runtime generation accepts at most 128 total plugin candidates across all
forms, so explicit package lists cannot create an unbounded handshake queue.

## Transport and lifecycle

The Host starts a fresh process for handshake and for each call. `argv[1]` is
respectively `handshake` or `call`; the child working directory is the canonical
package root. This stateless lifecycle prevents hidden mutable worker state from
leaking across Runtime generations or Sessions. The existing process primitive
creates an independent process group, polls `AbortSignal`, enforces the deadline
and combined stdout/stderr cap, terminates the group, and always reaps it.

stdin and stdout each contain exactly one frame:

```text
Content-Length: <decimal byte length>\r\n
\r\n
<UTF-8 JSON body>
```

The header spelling is exact. Length overflow, duplicate/trailing frames,
truncated bodies, output beyond the configured cap, non-zero exit, timeout,
abort, malformed JSON and schema/identity mismatch all fail closed. Request
frames are capped at 2048 bytes so the current small-stdin capture primitive
cannot block before its abort/timeout poll begins.

## Handshake

The Host request binds protocol, contract, package identity and requested
capabilities. The response must echo the exact schema, operation, protocol
major and plugin id/version; its capability set must contain `host_tool` and
may additionally contain the requested `artifact_spool_v1`. Protocol major
negotiation is exact in v1.

The Host requests `host_tool` plus optional `artifact_spool_v1`. A legacy
plugin may echo only `host_tool`; a spool-aware plugin echoes both. The
response contains one or more tools:

```json
{
  "schema": "metacodes.plugin-process/v1",
  "operation": "handshake",
  "protocol_major": 1,
  "plugin_id": "acme.review",
  "plugin_version": "1.0.0",
  "capabilities": ["host_tool", "artifact_spool_v1"],
  "limits": {
    "max_request_frame_bytes": 2048,
    "max_response_bytes": 1048576
  },
  "cancellation": "terminate_process_group",
  "tools": [{
    "name": "lint",
    "description": "Run the package linter",
    "input_schema": {
      "type": "object",
      "properties": {"path": {"type": "string"}},
      "required": ["path"],
      "additionalProperties": false
    }
  }]
}
```

Local names, descriptions, tool count, schema depth/property count, required
references and duplicates are bounded and validated before the immutable
snapshot is published.

The `input_schema` root accepts `type` (which must be `"object"`),
`properties`, `required`, and a boolean `additionalProperties`; any other root
keyword fails the handshake. That set is the one Core can represent and
propagate to the Provider request unchanged — a boundary that accepted a
constraint it then dropped would advertise a tool contract the model never
sees. `"additionalProperties": {...}` has no such representation and is
therefore refused rather than silently discarded. The authority binding hashes
the declared schema as written, so adding or removing the keyword is a schema
change and cannot inherit remembered authority.

## Call

The Host request is normally:

```json
{
  "schema": "metacodes.plugin-process/v1",
  "operation": "call",
  "protocol_major": 1,
  "plugin_id": "acme.review",
  "plugin_version": "1.0.0",
  "tool": "lint",
  "arguments": {"path": "src/main.zig"}
}
```

If handshake negotiated `artifact_spool_v1` and this Session has artifact
storage, the same request also contains a kernel-created private sink:

```json
"result_spool": {
  "schema_version": 1,
  "path": "/kernel-owned/session/spool/external-….tmp",
  "max_bytes": 134217728
}
```

The path is selected and pre-created by the kernel; a plugin never supplies an
artifact id or an import path. The plugin may open the offered path and stream
from byte zero, while keeping its stdout frame small. On success it returns:

```json
{
  "schema": "metacodes.plugin-process/v1",
  "operation": "call_result",
  "protocol_major": 1,
  "plugin_id": "acme.review",
  "plugin_version": "1.0.0",
  "tool": "lint",
  "status": "artifact",
  "media_type": "text/plain; charset=utf-8"
}
```

`media_type` is optional and allow-listed to UTF-8 text, JSON, or binary.
`content` is forbidden for `artifact`. The kernel inspects size, SHA-256 and
head/tail preview, enforces the 128 MiB artifact and 1 GiB Session quotas,
publishes into the Session CAS, and removes the temporary file. An invalid,
changed, oversized or missing sink fails closed.

The strict response is:

```json
{
  "schema": "metacodes.plugin-process/v1",
  "operation": "call_result",
  "protocol_major": 1,
  "plugin_id": "acme.review",
  "plugin_version": "1.0.0",
  "tool": "lint",
  "status": "ok",
  "content": "result bytes"
}
```

`status` is `ok`, `artifact`, `failed`, or `rejected`. `content` is required
for `ok`, forbidden for `artifact`, and optional for the two failure forms. A
process plugin cannot request `fatal`. Inline and artifact results re-enter the
same typed result, observation, budget and Conversation paths; the plugin has
no direct handle to any of them. For byte-zero spool results, observation sees
the bounded deterministic artifact envelope because the full raw value never
exists in kernel memory.
