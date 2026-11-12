# metacodes wire protocol v1

Status: implemented contract. Normative for every Host that carries a Session
across a process or network boundary: the bundled `--web`/`serve` HTTP
surface (`src/web/`), `SessionHost` behind an embedder's transport
(`src/core/session_host.zig`), and any Host in another language. The
encoder and parser are `src/core/protocol/wire.zig`; routing by declared
capabilities is `src/core/protocol/frontend_capabilities.zig`. Conformance
vectors: `tests/fixtures/wire/v1`. Evidence that a declaration changes what a
frontend is asked: `tests/component/frontend_capabilities_test.zig` (HTTP
surface and `SessionHost`) and `tests/e2e/frontend_capabilities_e2e.py` (the
installed `serve` with a second-process frontend).
[API.md](API.md#wire-lines-for-out-of-process-hosts) summarizes the same
contract for embedders.

In-process frontends (the TUI, headless runs, the AgentCore C ABI's
`on_ui_request` callback) consume the typed `CoreEvent` / `UiRequest` values
directly. They never serialize, never declare capabilities, and behave as
before this exchange existed.

## 1. Lines

Every line is one JSON object with the schema version `v` (currently `1`) and
a `type`. Core to frontend:

```text
{"v":1,"type":"<CoreEvent tag>","data":<payload or null>}
{"v":1,"type":"<CoreEvent tag>","run_id":N,"trace_id":"...","data":...}
{"v":1,"type":"<HostEvent tag>","data":{...}}
{"v":1,"type":"ui_request","id":N,"kind":"permission|ask_question|custom","request":{...}}
{"v":1,"type":"ui_request_closed","id":N,"outcome":"answered|cancelled|malformed","by":"..."}
{"v":1,"type":"ui_request_unavailable","kind":"...","custom_kind":"...","reason":"..."}
{"v":1,"type":"capabilities_accepted",...}
{"v":1,"type":"capabilities_refused","reason":"..."}
```

Frontend to core: the answer to UI request N (`{"choice":...}`,
`{"answers":[...]}`, `{"result":...}`, read by `wire.parseResponse`; a
malformed answer is never a grant), which may name who gave it (`"by"`,
§1.4), and the capability frame of §2. Payload shapes are spelled out in
`wire.zig`'s module comment and pinned by the fixtures. `ui_request_closed`
carries `by` only when the answer it closed on named someone (§1.4).

A Host journals these lines and nothing else. The bundled `--web`/`serve`
host writes every journal line through `wire.zig`, its host events and
`session_lifecycle` included (#444). Two tests refuse any line that is not
one of these: `tests/component/web_message_config_test.zig` reads a whole
session journal of both drivers through a Run with a permission prompt, and
the wire leg of `tests/e2e/daemon_serve_multi_e2e.sh` does the same for the
installed `serve`'s SSE stream and UDS attachment.

### 1.1 Host events

What a Host adds around the kernel's events, as
`{"v":1,"type":"<HostEvent tag>","data":{...}}`:

| `type` | `data` | Written by |
|---|---|---|
| `user_message` | `run_id`, `trace_id`, `text`, `replaces`; `source`, `kind`, `idempotency_key`, `attributes` when given | both Hosts: a Run's first line |
| `run_done` | `run_id`, `trace_id`, `stop_reason`, `error_name`, `model_error` | both Hosts: a Run's last line |
| `command_result` | `command`, `ok`, `error_name`, `message` | both Hosts |
| `message_rejected` | `message`, `text`, `model`, `permission_mode` | `--web`/`serve` |
| `session_poisoned` | `error_name`, `dropped` | `SessionHost` |
| `run_resumed` | `run_id`, `trace_id`, `request_id` | `SessionHost`: the first line of a Run that resumes a suspended one (§1.4) |

- `run_done` has `stop_reason` when the Run returned and `error_name` when it
  failed without returning (a refused rewind, a run the `--web`/`serve` run
  control refused). A Run that stopped on the model (`api_error`,
  `max_tokens_exhausted`) carries the detail in `model_error`, whose
  `message` is the text to show; otherwise `model_error` is `null`.
- `command_result.command` names the command: `SessionHost`'s `Command` tag
  (`set_model`, …), or the verb of a `--web`/`serve` `/command` line (`mode`,
  `edit`, `compact`, …; the name of a skill, `shell` for `!cmd`, `prompt` for
  plain text). `error_name` is set exactly when `ok` is false. On
  `--web`/`serve` it is the error the command failed with, if it has one;
  `CommandUnsupported` for a line that surface does not run (a terminal verb
  such as `/help`, a skill, a listing such as `/model` alone); and
  `CommandRefused` for a refusal stated only in words. `message` holds those
  words, or the outcome (`queued for run`, a shell command's output) for a
  person. `SessionHost` writes `null` there. `message` was appended under
  §4's additive rule 2.
- `message_rejected` (added under §4's rule 1) is a `--web`/`serve` message
  whose `model` or `permission_mode` was refused. Neither is applied, its
  `text` stays out of the conversation, no Run starts, and the line takes
  the place of the message's `user_message`. `model` and `permission_mode`
  repeat what the message asked for: `null` when not given, the mode as
  `/state` spells it. `message` says why.

The `user_message` host event carries `replaces`, appended under §4's
additive rule 2: `null` when the Run's text was appended after the whole
conversation, or the 1-based position `n` of the user message it replaced
(edit-and-rerun, [API.md](API.md#edit-and-rerun)). With `n`, messages `n` and
later left the conversation before the Run, which saw messages `1..n-1` and
the text, unless that Run's `run_done` names the refusal in `error_name`
(`PositionOutOfRange`, `NotUserMessage` or `PositionCompacted`), in which case
nothing changed.

```text
{"v":1,"type":"user_message","data":{"run_id":6,"trace_id":null,"text":"...","replaces":6}}
```

A typed submission (#447) appends `source`, `kind`, `idempotency_key` and
`attributes` to its `user_message` under §4's additive rule 2. Each is
written only when the submission had it, so the line of any other submission
keeps its bytes; a reader takes an absent field as not given. `attributes`
is one JSON object of string values, in the order submitted. `text` stays
the submitted text when a submission template shaped what the provider saw
([API.md](API.md#sessionhost-a-multi-session-service-for-network-hosts)).
Only `SessionHost` takes typed submissions so far: `--web` and `serve`
refuse an `idempotency_key` and never write these fields.

```text
{"v":1,"type":"user_message","data":{"run_id":8,"trace_id":null,"text":"heart rate high","replaces":null,"source":"device:hr-01","kind":"telemetry","idempotency_key":"hr-01:seq-42","attributes":{"bpm":"132","unit":"bpm"}}}
```

### 1.2 Runs

A Host numbers the Runs of a Session 1, 2, … in the order they start. A
restored or rebuilt Session starts again at 1 in a new journal, so the
journal epoch tells the two apart. A Run's lines run from its
`user_message` to its `run_done`, and each carries its `run_id`:

```text
{"v":1,"type":"user_message","data":{"run_id":2,"trace_id":null,"text":"write the file","replaces":null}}
{"v":1,"type":"tool_start","run_id":2,"data":{"id":"tu_w","name":"Write","input":"..."}}
{"v":1,"type":"ui_request","id":1,"kind":"permission","request":{"tool":"Write","args":"..."}}
{"v":1,"type":"ui_request_closed","id":1,"outcome":"answered"}
{"v":1,"type":"tool_result","run_id":2,"data":{"id":"tu_w","name":"Write",...}}
{"v":1,"type":"run_done","data":{"run_id":2,"trace_id":null,"stop_reason":"end_turn","error_name":null,"model_error":null}}
```

- Every kernel event journaled while the Run is in progress has `run_id`
  after `type`, and `trace_id` when the submission had one. Events between
  Runs have neither: `session_lifecycle`, `config_changed` from a command or
  from a message's `model` and `permission_mode` (journaled before its
  `user_message`), and a background agent's `agent_lifecycle` reaped after
  `run_done`.
- UI request and capability lines carry no `run_id`. A request belongs to
  the Run in progress when it is announced.
- No other host line falls inside a Run: `command_result` and
  `message_rejected` are journaled between Runs. A `--web`/`serve`
  `/command` that plans a Run (a prompt, `/edit`, `/retry`, `/commit`, …)
  journals its `command_result` first. The Run begins once every queued
  command has run, so commands queued together that plan a Run share one,
  and its `user_message` lines follow. A macro or `/retry` journals none, so
  its Run starts with a kernel event.
- `trace_id` is the opaque ID the caller attached to the submission
  (`SessionHost`'s `Submission.trace_id`). `--web` and `serve` take none:
  their host lines say `null` and their kernel events omit it. Where the two
  Hosts overlap they write the same bytes.

- A Run that resumes a suspended one (`SessionHost`'s suspend mode, §1.4)
  has no `user_message`: its first line is `run_resumed`, right after the
  `ui_request_closed` of the request the suspended Run waited for. The
  suspended Run itself ended with `run_done` and `"stop_reason":"suspended"`.

### 1.3 Transport frames

A journal holds only wire lines. A transport adds frames of its own, which
are not journal lines: they carry no `v`, take no seq and are never
replayed.

| Transport | Frames |
|---|---|
| SSE (`GET /events`) | `retry: 1000` first; `: keepalive` comments; `event: resync` when a cursor cannot be continued; `event: session_closed` once the journal is closed. A journal line is a frame with `id: <epoch>-<seq>` and no `event:`. |
| UDS `attach` | `{"type":"keepalive"}` after 15 s without a line; `{"type":"session_closed"}` once the journal is closed, after which the stream ends. |

A UDS reader tells them apart by `v`: a line with `v` is a journal line and
advances its cursor (its next `since`), and a line without one is the
transport's. They stay unversioned on purpose. They signal the connection,
not the session: SSE sends the same two signals as a comment and a named
event, outside its journal frames. A `v` would also make them look like
journal lines, which a reader would then count.

### 1.4 UI requests: approvers, expiry, suspended Runs

Added in #446 under §4's additive rules 1 and 2; a frontend that ignores them
behaves as before.

**Approver.** An answer may name who gave it: `"by":"<approver>"`, a JSON
string of 1 to 256 bytes (`wire.MAX_APPROVER_BYTES`), next to the answer's
own fields. The request's `ui_request_closed` then carries it, appended after
`outcome`, when it closes on that answer (`answered` or `malformed`); a
request cancelled by an interrupt, a close or its expiry names nobody, even
if an answer raced it. `by` never changes how the answer is read. `by` is
**self-reported and unauthenticated**: it is whatever the answering side says
about itself, and core records it as given. A Host that needs a verified
approver takes the identity from its own authentication (an HTTP token, a UDS
peer credential, an IM platform's user id), and either fills `by` itself
instead of passing the client's through, or records the verified identity
separately; it never trusts `by` from an answer body for authorization. `SessionHost.respond` refuses a `by` that is not such a
string (`error.InvalidApprover`) and the request stays open. `--web` and
`serve`, whose `respond` has only the 409, record a valid `by` and ignore
another, applying the answer as before.

```text
{"v":1,"type":"ui_request_closed","id":1,"outcome":"answered","by":"alice@example.com"}
```

**Expiry** (`SessionHost.Options.ui_request_expiry`, with
`ui_request_timeout_ms`). Every policy closes a request with an outcome v1
already has: `cancel` (the default, as before) closes it `"cancelled"` with
its safe answer and the Run goes on; `interrupt` does the same and stops the
Run, which ends `"stop_reason":"aborted"`; `re_announce` writes the request's
`ui_request` line again, the same bytes under the same id, every period until
it is answered, interrupted or closed. A frontend shows a repeated
announcement once, as it already does after replaying a journal.
`re_announce` needs a period: `SessionHost.open` refuses it with a zero
`ui_request_timeout_ms` (`error.InvalidUiRequestTimeout`).

**Suspended Runs** (`SessionHost.Options.ui_request_wait = .suspend`). A
question or custom UI request does not hold the Session: its Run ends
`"stop_reason":"suspended"` with the request still open, and the Session's
directory keeps it. A Session opened again under the id, also after a
restart, announces the request again under the same id in its new journal,
and the answer then resumes the Run once:

```text
{"v":1,"type":"ui_request","id":1,"kind":"ask_question","request":{...}}
{"v":1,"type":"run_done","data":{"run_id":1,"trace_id":"t","stop_reason":"suspended","error_name":null,"model_error":null}}
   … the Host restarts; the Session is opened again under its id …
{"v":1,"type":"ui_request","id":1,"kind":"ask_question","request":{...}}
{"v":1,"type":"ui_request_closed","id":1,"outcome":"answered","by":"alice@example.com"}
{"v":1,"type":"run_resumed","data":{"run_id":1,"trace_id":"t","request_id":1}}
   … the resumed Run's events …
{"v":1,"type":"run_done","data":{"run_id":1,"trace_id":"t","stop_reason":"end_turn","error_name":null,"model_error":null}}
```

The resumed Run keeps the suspended Run's `trace_id` and turn limit. An open
that finds the suspended call already answered in the Session's transcript
(the resumed Run was written, then the Host stopped) does not announce the
request again: it was applied once and is not applied twice. Request
ids are never reused for a Session in this mode, across restarts too, so a
late answer cannot reach a newer request: an answer to a request that is no
longer open changes nothing (`error.NoSuchRequest`), and a second answer to
one that already took an answer it has not yet applied changes nothing
either (`error.AlreadyAnswered`). A permission request is never suspended:
the kernel's permission gate takes a `pending` answer for no answer and
denies the tool, so under this mode a permission request blocks as before,
and does not survive a close. Beside a suspended question it has an id of its
own, and an answer goes to the request its id names and to no other. A
Session whose request file the Host cannot read (corrupt, or written by a
later version) keeps the file as it is and blocks instead of suspending,
still under ids it never used before.

## 2. Capability exchange

A frontend states what it can render with one **capability frame**, the first
frame it sends on the channel. It is an envelope, not a blocking handshake:
core never waits for it, events flow before it arrives, and a frontend that
never sends one keeps the legacy behavior of §2.4.

```json
{"v":1,"type":"capabilities",
 "ui_requests":["permission","ask_question"],
 "custom":["video_timeline@1","diff_review@2"],
 "events":["text_chunk","tool_start","tool_result","stream_done"]}
```

| Field | Rule |
|---|---|
| `v` | Required; must equal core's `SCHEMA_VERSION`. Absent or different refuses the frame (`SchemaVersionMismatch`). |
| `type` | Required; `"capabilities"` (`NotCapabilities` otherwise). |
| `ui_requests` | Required array of strings: the named `UiRequest` kinds the frontend renders (`permission`, `ask_question`). `"custom"` is refused (`CustomInUiRequests`): custom kinds are declared one by one in `custom`. A name this core does not know is ignored and reported (§2.1). At most 32 entries. |
| `custom` | Optional array of versioned custom kinds (§3), default empty. An entry that is not `<name>@<major>` refuses the frame (`InvalidCustomKind`). At most 64 entries. |
| `events` | Optional array of `CoreEvent` tags the frontend consumes. Diagnostics only: it is echoed in the acknowledgement and `/state`, it never filters the journal (other readers share it) and never changes routing. Absent means not stated. Unknown tags are ignored and reported. At most 256 entries. |

Any other top-level field is ignored, and `custom` or `events` given as
`null` count as absent. A field of the wrong JSON type, or a name longer than
128 bytes, is `InvalidField`; a list over its bound is `TooManyEntries`; a
frame over 64 KiB is `FrameTooLarge`; a body that is not one JSON object is
`NotAnObject`. Duplicates collapse.

### 2.1 Acknowledgement

An accepted frame replaces the Session's declaration as a whole and is
answered, and journaled, with:

```json
{"v":1,"type":"capabilities_accepted","ui_requests":["ask_question","permission"],"custom":["video_timeline@1"],"events":["text_chunk","stream_done"],"ignored":{"ui_requests":["form"],"events":["future_event"]}}
```

`ui_requests` and `events` are in core's declaration order (`UiRequest` and
`CoreEvent` tag order), `custom` in the frame's order with duplicates removed,
`events` is `null` when the frame did not state it, and `ignored` lists the
names this core did not recognize. The declaration is installed, then its
line is journaled. Each request is routed by the declaration in force when it
is made, so a request made while a frame is being installed may be journaled
on either side of that frame's line.

A refused frame changes nothing (the previous declaration, or none, stays in
force) and is answered, not journaled, with the core's version so a frontend
of another version learns what it is talking to:

```json
{"v":1,"type":"capabilities_refused","reason":"SchemaVersionMismatch"}
```

`reason` is one of `NotAnObject`, `FrameTooLarge`, `SchemaVersionMismatch`,
`NotCapabilities`, `InvalidField`, `CustomInUiRequests`, `InvalidCustomKind`,
`TooManyEntries` (`wire.RefusalError`).

### 2.2 Routing

Before a UI request is announced, core asks the declaration whether the
frontend can render it:

| Request | Declared frontend | Undeclared frontend |
|---|---|---|
| `permission`, `ask_question` | announced if the kind is in `ui_requests`, else unavailable (`kind_not_declared`) | announced |
| `custom` with kind `k@N` | announced if `k@N` is in `custom`, else unavailable (`custom_kind_not_declared`) | announced |
| `custom` with an unversioned kind | unavailable (`custom_kind_unversioned`) | announced |

An unavailable request is never announced and takes no request id: core
journals

```json
{"v":1,"type":"ui_request_unavailable","kind":"custom","custom_kind":"video_timeline@2","reason":"custom_kind_not_declared"}
```

(`custom_kind` only for `custom`) and returns `RequestOutcome.unrenderable` to
the caller at once, with no round trip. That outcome is not `unavailable` (no
UI at all): a frontend is there, and nobody was asked. The caller fails as it
would without a UI, but tells the model why, never as the user's answer:

- `ask_question` — `AskUserQuestion` fails with `FrontendCannotRender`
  (`code` `capability_unsupported`): *"AskUserQuestion was not shown: the
  frontend connected to this session cannot render questions (it declared
  that it does not render ask_question requests). This is not an answer or a
  refusal from the user. Ask the question in plain text in your reply
  instead."*
- `custom` — `ToolContext.requestUiCustom` returns `error.CustomUiUnsupported`
  as before, so the tool falls back; if it does not, the model reads *"The
  custom UI '<kind>' was not shown: the frontend connected to this session did
  not declare that it renders this kind. This is not a decision by the
  user."*
- `permission` — the gate fails closed: the call is denied at once, with no
  terminal or answer-queue fallback (a terminal is not the declared
  frontend), and the model reads *"'<tool>' was denied without asking: the
  frontend connected to this session cannot render permission prompts (it
  declared that it does not render permission requests). This is not the
  user's decision; the user never saw the request."* Declaring capabilities
  can never grant a permission.

Every other path keeps its wording: no UI at all is still `NotATty` /
`CustomUiUnsupported`, and a user who refuses a prompt is still *"user
declined '<tool>' via prompt"*.

A declaration applies to requests made after it is installed. A request
already announced stays pending and is answered or cancelled as before.

### 2.3 Transports

| Host | Frame in | Reply |
|---|---|---|
| `--web`, `serve` | `POST /capabilities` | `200` `capabilities_accepted`, `400` `capabilities_refused` |
| `serve --sessions N` | `POST /s/<id>/capabilities` | the same, per Session |
| `SessionHost` | `HostedSession.declareCapabilities(allocator, frame)` | the acknowledgement line, or a `DeclareError` |
| UDS (`serve --uds`) | the frame itself as one NDJSON line, with the routing fields beside it: `{"op":"capabilities","session":"<id>","v":1,"type":"capabilities",...}` | the acknowledgement line |

UDS is a full UI frontend: it carries answers too. `{"op":"respond","session":
"<id>","id":N,...}` answers UI request `N` with the same answer fields
`POST /respond` takes beside the routing fields (`{"ok":true}`; a stale or
unknown id is `{"ok":false,"error":"no pending request with this id"}`, the 409
of the HTTP surface), so a UDS-only frontend needs no HTTP side channel.
Evidence: `tests/component/serve_sessions_test.zig` (the `uds respond` /
`uds capabilities` cases) and the UDS leg of
`tests/e2e/daemon_serve_multi_e2e.sh`.

`GET /state` reports the declaration in force as `frontend_capabilities`: the
last `capabilities_accepted` object, or `null` while undeclared. The bundled
browser UI declares `permission` and `ask_question` (no custom kinds) when it
loads.

### 2.4 Compatibility

- **Undeclared frontend.** A frontend that never sends a frame is a v1
  frontend from before this exchange: every request is announced, exactly as
  before, including custom kinds it may not render. This is the defined
  legacy rule, not a silent default: the state is visible (`/state` reports
  `frontend_capabilities: null`) and a frontend opts out of it by declaring.
- **One declaration per Session.** It belongs to the Session, not to a
  connection: it holds until the next accepted frame, across reconnects and
  for every reader. A Host that multiplexes several frontends onto one Session
  declares what the frontend that answers requests can render. There is no
  undeclare; a frontend that renders nothing declares `"ui_requests":[]`.
- **Version mismatch.** A frame whose `v` is not core's is refused with
  core's `v`; the frontend downgrades or disconnects. Core never guesses.
- **Newer frontend, older core.** Unknown kinds and event tags are ignored and
  listed in `ignored`, so a frontend can declare kinds a newer core would have
  and still be routed correctly by this one.
- **In-process backends** never declare: the TUI keeps answering `custom`
  with `error.CustomUiUnsupported`, a run without a requester keeps getting
  `unavailable`, and the C ABI keeps its own synchronous `UI_UNAVAILABLE`.

## 3. Versioned custom kinds

A custom kind names its own payload and result schema, which core never reads
(`payload_json` in, `result` out). Across processes the two sides must agree on
that schema, so the kind string carries its version:

```text
<name>@<major>    name: [a-z0-9][a-z0-9_.-]{0,63}    major: 1..4294967295, no leading zero
```

`video_timeline@1` and `video_timeline@2` are different kinds; a frontend that
renders both declares both, and core matches the exact string. Within one
major, payload and result may only gain optional fields the other side
ignores; anything else is a new major. A kind's major is independent of
`SCHEMA_VERSION`: changing a custom schema never bumps the wire. An
unversioned kind still reaches undeclared frontends, as before, but can never
be declared, so a tool that wants a declared frontend to render it must
version its kind.

## 4. Additive and breaking changes

`SCHEMA_VERSION` versions the line grammar of §1 and §2. A change is
**additive** — no bump, existing v1 frontends keep working — when it is one of:

1. A new `CoreEvent` or `HostEvent` tag, or a new line `type`. Frontends must
   ignore a `type` they do not know (the bundled UI does).
2. A new optional field appended to an object payload or frame. Readers must
   ignore unknown fields; core ignores unknown frame fields.
3. A new named `UiRequest` kind, with its answer grammar in `parseResponse`
   and a fail-closed `cancelResponse`. Declared frontends never receive it
   until they list it; undeclared frontends receive it as an unknown kind,
   which their answer cannot grant (a malformed answer takes the safe answer).
4. A new value that core *accepts* from frontends in an enumerated field
   (a new permission `choice`, a new capability field).

A change is **breaking** — `SCHEMA_VERSION` + 1, a new
`tests/fixtures/wire/v<N>` directory, and old fixtures kept until v<N-1> is
dropped — when it:

1. Removes or renames a tag, kind, line `type` or field.
2. Changes a field's JSON type, unit or meaning, or the shape of a payload.
3. Makes a frontend-supplied field required, or stops writing a field core
   always wrote.
4. Emits a new value in an enumerated field frontends switch on
   (`ui_request_closed.outcome`, `ui_request_unavailable.reason`,
   `capabilities_refused.reason`).
5. Changes what `parseResponse` accepts for an existing kind, or reads an
   accepted answer differently.

A change to a safe answer that grants more than before is not a version
question: it is refused.

**Fixtures.** `tests/fixtures/wire/v1` pins, byte for byte
(`tests/component/wire_contract_test.zig`), one line per event tag, request
kind, close outcome and unavailable reason, and the capability frames
(`capability_frames.jsonl`) with core's reply to each
(`capability_replies.jsonl`), which cover every refusal reason but
`FrameTooLarge` (a 64 KiB vector; `wire.zig` tests it). An additive change adds
lines or appends a field to an existing line and nothing else; a diff that
alters any other byte of an existing line is breaking by definition.
