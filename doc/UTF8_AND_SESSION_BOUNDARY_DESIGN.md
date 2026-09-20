# UTF-8, bytes, transcript, and session boundary design

Status: approved design, implemented on branch `codex/utf8-session-boundary`.

## Problem

External command output, background-agent output, web/PDF data, previews, and
provider payloads currently meet as `[]const u8`. Some paths truncate those
bytes at an arbitrary offset and some paths pass them to the standard JSON
stringifier. A single incomplete UTF-8 sequence can therefore be persisted in
`transcript.jsonl`; the next `/resume` strictly parses the file and reports
`SyntaxError`. The same missing boundary contract also lets child-agent route
identity fall back to `SessionId.single`.

The concrete incidents are the 120-byte command preview in
`core/job_registry.zig`, the byte-capped `TaskOutput` output, and raw tool
payloads entering `core/transcript.zig`. They are independent producers of
the same bytes/text failure.

## Invariants

1. External data starts as raw bytes. It becomes text only after an explicit
   encoding policy and UTF-8 validation.
2. Valid UTF-8 does not by itself establish that data is semantically text;
   source kind and media type are part of the payload contract.
3. Text truncation ends on a Unicode code-point boundary. UI grapheme-boundary
   truncation is a separate operation.
4. Raw binary is stored as an artifact or an explicit base64 envelope, never
   as a JSON text string.
5. JSON, XML-like notification, Markdown, and terminal output each use their
   own escaping layer.
6. Durable writers accept typed messages, serialize a complete record, and
   never append an unchecked `[]const u8` as a string.
7. A child inherits its parent `SessionId` explicitly. `agent_ident` remains a
   separate child coordination identity. `.single` is never an implicit
   production fallback.
8. A background job keeps its origin session and cannot follow the currently
   visible session after Ctrl+B or `/resume`.
9. A persisted team records `leadSessionId` and every member's `sessionId`.
   Process-mode members also carry a per-spawn `leaseId` and the expected
   `cwd/worktree`. The child validates all four values at startup and before
   consuming mailbox work; legacy records without them fail closed instead of
   routing by name alone.

## Data and boundary API

The shared utility boundary now provides raw-byte offsets, UTF-8-safe
truncation, malformed-byte repair, and streaming adapters that retain up to
three pending bytes across input chunks. An incomplete tail is decided only at
`finish()`.

Every bounded result carries its source byte range, `next_offset`, total source
bytes, truncation state, encoding, and stream generation. Cursors are source
byte offsets; replacement, JSON escaping, and base64 lengths never become
cursors. A page must make progress even when its limit is smaller than one
code point.

The source adapter returns either validated text or an artifact-backed binary
payload. A lossy display preview may use U+FFFD, but the original bytes and the
lossy flag remain available. Artifact identifiers are content-addressed and
must not include timestamps or runtime paths.

## Producers and persistence

Command previews, `TaskOutput`, web/PDF reads, provider payloads, transcript
blocks, metadata titles, notification summaries, and the host-facing NDJSON/
ABI adapters all use the boundary API. Hand-written JSON uses the repository
canonical writer; generic serializers at a transport boundary pass through the
UTF-8 repair adapter. Internal content-addressed records still serialize typed
validated values directly, while binary branches remain explicit base64 or
artifact envelopes. The lossy sanitizer is a final defense, not the
source-of-truth text model.

The implementation keeps the current transcript format for compatibility but
hardens it: serialize complete records, serialize flushes under a writer lock,
handle short writes, fsync before advancing durable counters, require a final
newline, and report line/byte diagnostics. A failed append marks the writer for
full rebuild before retry, so a partial write cannot be duplicated. A torn final
tail is treated as uncommitted; after the complete prefix validates, the source
is replaced atomically and the original bytes are retained as
`transcript.jsonl.corrupt`. Legacy records containing only invalid UTF-8 are
repaired with U+FFFD using the same atomic replacement. Metadata reads are
bounded and repair invalid UTF-8 before publishing the `/resume` index. Middle
JSON structure corruption remains a hard, actionable error.

A future framed segment/manifest journal can strengthen torn-write guarantees;
it is deliberately separate from the UTF-8 fix so this change does not alter
the public transcript format without a migration.

## Session propagation

Make session propagation explicit through synchronous Task, background Task,
TaskBatch, `SpawnParams`, `JobInput`, and Ctrl+B. The spawn constructor updates
both `ToolContext.session` and the copied `PermissionContext.session`; these
two routing keys must not diverge. Registry entries retain their origin
session/agent identity, and snapshots, output, abort, notification, and UI
events filter by that scope. `/resume` changes the foreground session only and
never rebinds existing jobs.

Process-mode teammate startup binds `--parent-session-id` before `App.init`, so
KG identity, provider-visible context, plan paths, permissions, and transcript
all use the same parent session from the first request. Team names are
canonicalized before path construction. Each spawn receives a fresh lease and
the child refuses a changed or missing worktree; it never falls back to the
lead cwd. A child is terminated and reaped if publication of its process record
fails.

## Verification

The implementation includes unit tests for UTF-8 boundaries, malformed-byte
progress, streaming chunk partitions, pagination cursor monotonicity, JSON
round-trips, malformed/torn transcript records, durable legacy repair, and
parent/child session routing. Existing L2 coverage exercises Bash
notification, background TaskOutput, Web/PDF artifact output, transcript
reload, Ctrl+B, `/resume`, and concurrent children.

Repository gates remain the definition of done: `zig fmt --check`, the library
and full Zig test suites, coverage audit, documentation checks, and
`git diff --check`.
