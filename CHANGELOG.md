# Changelog

The standalone repository is versioned per `build.zig.zon`; the first tagged
release is `0.1.0` (2026-08-29). Entries titled **"Historical —"** were
imported from the pre-extraction `cc-zig` line — their version numbers and
dates are historical labels, not release promises of this repository. Current
status, compatibility boundaries, and entry points are defined by
[README](README.md), [ROADMAP](ROADMAP.md), [doc/API.md](doc/API.md), and
[OPEN_SOURCE_READINESS.md](OPEN_SOURCE_READINESS.md).

## Unreleased

### Added

- Session goals at every entry point, and in AgentCore (issue #277).
  - **One set of rules.** `core.goal` owns the status table: pause needs an
    active goal, resuming a goal whose budget is used up is refused until the
    budget is raised (in the same update if wanted), a complete goal cannot be
    blocked. Refusals change nothing; objectives are 1-4000 code points.
  - **Accounting by the agent loop.** Each provider response's non-cached
    input plus output (automatic compaction included) is charged to the goal
    a Run began on while active, and the Run's time when it ends - a Run that
    ends in an error included. A budget used up mid-Run makes the goal
    `budget_limited` and asks the model once, at the next turn, to wrap up;
    the Run is not cut off.
  - **CLI.** REPL, web, daemon, forked Skills and headless all charge the
    session's goal (web, daemon and headless never did, though a resumed
    daemon session loaded it), and goal.json is written whenever it changes.
    `/goal resume` past a used-up budget now says so instead of reactivating.
  - **AgentCore Revision 23.** A sixth root table, `goal`, with `get` (JSON),
    `set`, `update` (objective, budget and action together or not at all)
    and `clear`; the root grows from 64 to 72 bytes. A
    `RUN_INPUT_GOAL_CONTINUATION` Run's input is written by the runtime from
    the goal. Status 30 `GOAL_CONFLICT`; the `goal_updated` event; a goal
    section in checkpoints (marker 10), admitted against the durable budget.
  - SDK 0.10.0-dev.
- Host-scheduled teams in AgentCore and at the Swarm entry points (issue #277).
  - **Host scheduler.** With `enable_teams`, a lead Session delegates with
    `SpawnTeammate` by recording a spawn request instead of starting an
    in-process thread; the embedding Host creates and runs each member
    Session. `TeamCreate`, `TeamDelete`, `SendMessage` and `SpawnTeammate` are
    Session-owned team builtins, admitted only by the flag. Team membership is
    Host-supplied at create and restore and carries no checkpoint state.
  - **AgentCore Revision 24.** A seventh root table, `team`, with `describe`
    (team roster and pending spawns as JSON) and `poll` (the lead's next queued
    input, marked read); the root grows from 72 to 80 bytes.
    `RuntimeConfigV1.enable_teams` admits the team tools and
    `SessionHostConfigV1.team` (`TeamConfigV1`, lead or member) joins a Session
    to a team.
  - SDK 0.11.0-dev.
- Date and time zone for the model at every entry point (issue #276).
  - **CLI.** The user-context message always states the date the session
    started on, with its time zone - without CLAUDE.md, memory or KG, and
    with `CLAUDE_CODE_DISABLE_CLAUDE_MDS` set - as
    `Today's date is 2026-10-17 (Saturday). Time zone: Asia/Shanghai (UTC+08:00).`
    The zone is the process's: libc `localtime_r` on POSIX (honours `TZ`,
    `/etc/localtime` and daylight saving), the dynamic time-zone information
    on Windows. When neither answers, the date is in UTC and the text says
    the zone is unknown.
  - **Crossing midnight.** The first Run on a later local date gets one
    "The date has changed" notice after its input, in that turn's history.
    The system prompt and the first message do not change, so the prompt
    cache survives midnight. A notice that compaction, trimming or `/clear`
    removed is given again.
  - **AgentCore Revision 22.** `RunOptionsV1.time_context_code` and
    `utc_offset_minutes` take the first remaining reserved word, so the
    layout is unchanged at 40 bytes. By default each Run's context starts
    with a `currentDate` block in the process's zone.
    `TIME_CONTEXT_UTC_OFFSET` dates it in a Host-given offset (UTC±14:00)
    instead, and `TIME_CONTEXT_OFF` drops it.
  - **Host precedence.** A Host block labelled `currentDate` replaces the
    runtime's. Combined with an explicit offset it is refused as
    `INVALID_ARGUMENT`.
  - **Source-level Hosts** build the same block with `core.time_context`.
  - SDK 0.9.0-dev.
- Learning turn, kernel side ([doc/LEARNING_TURN_DESIGN.md](doc/LEARNING_TURN_DESIGN.md)):
  `agent_loop.Options.learning_turn` (enforce or observe). When the host
  check gate's verdict ends a root run, the same conversation gets one
  distill message carrying the verdict and the stored lessons for the task,
  and writes up to four conditioned lessons with `KgRemember` kind `lesson`
  (`holds_when:`, `uncertain:`, `lesson:`, optional `supersedes:`); a
  reconcile message follows only when a lesson was accepted and stored
  lessons exist. The lesson header (`lesson-v1 verdict= task= run=`) is
  host-bound: `KgRemember` refuses kind `lesson` outside a learning turn
  and any header that differs from the verdict the host saw. During a pass
  only Read, Grep, Glob, KgRecall, KgContext and KgRemember run, process
  gates neither sense nor end it, and the attempt's answer stays the final
  result. Each pass is capped at six model turns. Tainted, unavailable and
  unchecked verdicts teach nothing, and neither does a run with no ready
  TinyKG store (`none_unstorable`). The next attempt at a hinted task sees
  the newest unsuperseded lessons in the scoped-recall injection (no
  lessons, byte-identical injection). One terminal `learning_turn`
  observation record per armed run (`metacodes-learning-turn-v1`, validated
  by `scripts/eval/workbuddy/trace.py`).
- Learning turn, host side (design steps 5–8): `--learning-turn` /
  `--learning-turn-observe`, and `METACODES_LEARNING_TURN=enforce|observe` in
  print mode (a flag wins). The flags need a verdict source and are refused
  without one, like `--check-gate` without `--host-check`: the check gate
  (REPL and print mode; it arms the in-run turn, with
  `METACODES_TASK_HINT` as the task and the journal run id in lesson
  headers), or in print mode the self-evolution host check
  (`METACODES_HOST_CHECK` with `METACODES_SELF_EVOLUTION=1` and a task hint).
  After that host check, when the attempt ended on its own and the in-run
  turn had no verdict, the end-of-run form spends one no-tools provider
  request under the self-evolution author caps (tokens and cost, checked on
  the provider's reported usage) and writes the lessons its response carries
  through the same header binding `KgRemember` enforces; every envelope that
  claims another header counts as refused. `LearningTurn.lean` mirrors the
  policy and proves, over any event trace, at most two passes and two host
  messages, at most six turns per pass and four lessons, reconcile only after
  an accepted lesson, no message in observe mode, and the answer closed
  before any learning message. `evals/experiments/learning-turn-v1.md`
  preregisters the paired evaluation (development configuration with the
  validator pinned, held-out configuration with the visible suite pinned,
  stopping rules); nothing has been run.
- Chained-attempt evaluation runner: `scripts/eval/cli.py run-chained` runs
  K sequential attempts per task, per arm and per replicate on one TinyKG
  store that starts empty and is carried from attempt to attempt
  (`tests/e2e/lib.sh` `import_kg_store` extracts the previous attempt's
  exported store into the fresh fake HOME before the session and writes an
  import witness outside the workspace), with `METACODES_TASK_HINT` set to
  the task id. Rollouts keep the `run-paired` format
  (`trial = replicate × attempts + attempt − 1`); a per-arm hash-chained
  ledger (`metacodes-chain-ledger-v1`) links each attempt's import to the
  previous export and fails closed on any break, changed archive, missing
  witness or ledger/checkpoint disagreement. The store is exported before the
  offline grade runs. `learning-turn-v1.md` records its launch prerequisites
  as met except a pinned full-validator command for configuration D, and an
  amendment: the REPL harness files no outcome rows, so the baseline is the
  accumulating store without lessons.
- Sealed Skills: the §8.5 disclosure screen keeps two corpora under their
  own policies — the Skill's instructions and its `sealed/` references —
  so `egress.disclosure` is one word for both or
  `{"body": "redact", "references": "off"}`. A documentation Skill whose
  references were being replaced by `[sealed]` when cited (seen with the
  Browser Use Cloud reference skill) sets `references` to `off` and keeps
  its instructions screened; the install summary shows both policies.
- AgentCore Revision 21: Host model-capability declarations (issue #273).
  `SessionHostConfigV1.model_capabilities` / `model_capability_count` (two
  former reserved words; the struct stays 168 bytes) carry up to 256 40-byte
  `ModelCapabilityV1` entries, each saying whether one model takes image input
  (`CAPABILITY_SUPPORTED` / `CAPABILITY_UNSUPPORTED`). A declaration outranks
  the provider catalog and the built-in model-family table for the Session's
  model, every `set_model` target and its tool-scoped providers, and a restore
  uses the current Host's declarations. `describe` reports
  `"image_input":{"supported":…,"source":"host"|"catalog"|"model_family"|"unknown"}`.
  Source-level hosts pass the same through `SessionConfig.model_capabilities`;
  `Provider.imageInput` answers with the source. The OpenAI and Gemini clients
  now apply a catalog's `image_input` declaration too (only the Anthropic
  client did), and the CLI hands them the Metask catalog. SDK 0.8.0-dev.
- Sealed gateway at scale ([doc/SEALED_GATEWAY_SCALE_DESIGN.md](doc/SEALED_GATEWAY_SCALE_DESIGN.md)):
  `metacodes sealed serve` runs a bounded worker pool with a queue and a cap
  on in-flight model calls, refuses over-capacity requests before reading
  them (HTTP 503 + `Retry-After`, or JSON-RPC `rate_limited` with
  `retry_after_ms`), answers Steps as SSE with keepalive comments, and lends
  each client's provider from a route-keyed cache so consecutive Steps do
  not rebuild it (`--workers`, `--queue-depth`, `--max-model-calls`,
  `--keepalive-ms`, `--provider-cache-ms`). The client resends a refused Step
  unchanged after the named wait. `zig build sealed:bench` measures Steps per
  second and gateway overhead against a mock upstream; its first runs removed
  a 16 MiB per-connection buffer and raised the process-wide request-setup
  gate (`connection_gate.raiseProcessLimit`) for the server, taking 64
  concurrent clients from 249 to 1 835 Steps/s.
- Sealed Skills: the §8.5 disclosure screen. Before a Step leaves the
  gateway, its `final` text, every call input of a `tool_calls` batch and
  any question pass a screen built from the Skill's sealed material (the
  body and the `sealed/` files): every run of eight consecutive tokens that
  also occurs there is replaced by `[sealed]`, the Step carries
  `disclosure.redactions`, and the client logs it, records it in the ledger
  and tells the user once; the brain's own conversation keeps the original.
  The manifest's new `egress.disclosure` chooses `redact` (default), `fail`
  (the run ends as `failed` / `disclosure`) or `off`. Numbers, names, short
  phrases and paraphrases pass; the document says so.
- Sealed Skills: `egress.classes` is enforced at run time. A call whose
  result class the client can tell from the tool (`Read`/`Grep`/`Edit`/
  `NotebookEdit` → `file_contents`, `Glob` → `repository_structure`,
  `Bash`/`BashOutput` → `command_output`, `WebFetch`/`WebSearch` →
  `page_snapshot`) is refused unexecuted as a `policy_violation` when the
  pinned manifest does not declare that class, and counted toward the
  three-violation cancel like an allowlist refusal. The sealed fork's
  system prompt carries the codebase context (the CLAUDE.md chain and git
  status) only when the manifest declares `repository_structure`; the
  install consent now says what travels with each run besides tool results.
- Sealed Skills: a `Glob` or `Grep` whose target lies under the Skill's
  `sealed/` directory is answered on the gateway inside the Step, by the
  client's own tool implementation run against the package with every path
  it prints rewritten to the client's view; before, the call went to the
  client, which has no such directory and answered with no matches. The
  gateway serves `Read`, `Glob` and `Grep` on sealed files only for a tool
  the manifest admits, forwarding the call otherwise so the client refuses
  it; the manifest's tool rules are now one shared function
  (`protocol.manifestAllowsTool`).
- Sealed Skill chain and state: every Step derived from a `runs.continue`
  carries `results_digest`, the digest of the results array the gateway
  received, inside its digested body; the client computes the same digest
  before sending, checks the echo and ends the run on a mismatch (§8.3).
  The provider route and credential are re-read from the session's provider
  before every gateway request. `run_state` carries only the conversation's
  active window plus the compaction summary, restored as the first
  assistant turn, instead of every message ever exchanged. §8.4 now states
  what a stateless gateway does and does not prevent about replay.
- Sealed Skill audit and trace: the ledger now records every call's id and
  name per Step and a `results` record per `runs.continue` with the SHA-256,
  size and flags of each result as sent (§6.6); the client logs every
  gateway exchange and every Step at info level under `sealed`, and the
  gateway logs each Step it emits with its number.
- Sealed Skills run as a shadow of the client's fork on the client's own
  model account ([doc/SEALED_SKILL_PROTOCOL.md](doc/SEALED_SKILL_PROTOCOL.md)
  §8.1, §9): the gateway has no provider of its own; `runs.start` carries
  the fork's system prompt, tools, model and request parameters plus the
  client's provider route, and the credential travels in the
  `Sealed-Provider-Credential` header of each request. The gateway's brain
  is the real agent loop with a capturing dispatcher — every tool use
  suspends the loop and becomes a Step, the loop's continuation travels in
  `run_state`, and the gateway keeps nothing between Steps. The shadow's
  model request is byte-identical to a local fork's (an L2 asserts it);
  narration between calls stays on the gateway. Packages gain `sealed/`
  reference files read on the gateway and public assets installed under the
  pin directory (`sealed/skills.asset`). `metacodes sealed serve` drops its
  provider flags. Kernel seams: `Provider.route()`,
  `agent_loop.Options.suspend_all_pending` with `resumeRunWithResults`, and
  `transcript.Writer.renderMessageJson` / `parseMessageJson`.
- Sealed Skills, client side of the three §9.1 gaps: a call marked
  `confirm: true` is approved interactively whatever the permission mode,
  through a tightening-only confirm gate on the child's permission context
  (a remembered "allow always" does not answer it); credential references
  are bound per Skill with `metacodes sealed bind|unbind` in
  `<state root>/sealed-credentials.json`, substituted into the call's input
  and redacted from its result before it leaves the machine, an unbound one
  refusing the call with `permission_denied` and the bind command; an
  `input_required` Step is asked through the session's dialog and the answer
  continues the run. The reference gateway maps the brain's
  `AskUserQuestion` to `input_required` and annotates calls with the
  credential references their inputs name.
- Sealed Skill Protocol (SSP/1, [doc/SEALED_SKILL_PROTOCOL.md](doc/SEALED_SKILL_PROTOCOL.md)):
  a Skill whose body stays on a gateway while every tool call it needs is
  executed, approved and paid for on the client. `metacodes sealed install`
  pins a gateway manifest after showing the allowlist, egress classes and
  price; the pinned Skill runs as a fork whose model is the gateway, with a
  per-run cost cap (`METACODES_SEALED_MAX_COST_MICROS`) and a usage ledger
  (`metacodes sealed ledger`). `metacodes sealed serve` is the reference
  gateway: stateless, AEAD-sealed run state, metering per Step.
- AgentCore ABI v1 revision 20 (#270): `session->submit_input` hands an active
  Run more user text. It may be called from any thread or from inside the
  Run's own callbacks, like `session_abort`, and never waits for the Run. Each
  input carries a non-zero Host `input_id` (unique within the Run) and gets a
  1-based acceptance `sequence` in its receipt. The Run appends every pending
  input verbatim, in acceptance order, as its own user record at its next turn
  boundary — never into a request already sent, never at a `max_tokens`
  continuation boundary — and emits `input_adopted {input_id, sequence, turn}`
  for each. Input waits while a Permission or question request is pending and
  never answers it. A Run that ends before another boundary leaves its pending
  input unadopted. `RunResultV1.input_accepted_count` and
  `input_adopted_count` are defined on every `session_run_input` return,
  failures and poisoning ones included: adoption is always a prefix of
  acceptance, so the counts tell the Host exactly which inputs reached the
  Conversation even when an event was lost. Limits: 64 inputs and 16 MiB of
  text per Run (`MAX_SUBMITTED_INPUTS_V1`, `MAX_SUBMITTED_INPUT_BYTES_V1`);
  each input reserves its checkpoint bytes against the durable budget, counts
  with the root input toward `input_cap_bytes`, must leave room for one whole
  provider operation, and is refused with `CHECKPOINT_BUDGET_REQUIRED` —
  without ending the Run — when it does not fit. Once a Run is aborting (an
  abort, or a callback the Host failed) it adopts nothing more. A refused
  submission changes nothing; a stale id is `STALE_RUN`, a Run that ended or
  is ending `TOO_LATE`, a forked Skill Run `INVALID_STATE`.
  Adopted input is ordinary Conversation state and survives checkpoint and
  restore. The Session table grows by one slot to 48 bytes and `RunResultV1`
  turns its first reserved word into the two counts; the header, Zig and Rust
  SDKs (`raw.rs` regenerated), both source-free consumers, the bundle manifest
  and the docs move to revision 20, SDK package `0.7.0-dev`. Source-level
  Hosts use `AgentSession.submitInput` / `runInputReconciliation`.

- Skills and MCP servers configured for Claude Code and Codex now work in
  metacodes, next to its own `<state root>/skills` and `config.json`
  ([doc/SKILLS_AND_MCP.md](doc/SKILLS_AND_MCP.md)). Skills come from
  `~/.agents/skills`, `~/.claude/skills`, `~/.codex/skills`, the managed
  directories, every project level from the repository root to the working
  directory, and `--add-dir`; MCP servers from `mcpServers` in metacodes'
  config, `~/.claude.json`, an approved `.mcp.json`, and Codex's
  `config.toml` (trusted projects only for project layers).
- MCP 2026-07-28: `server/discover`, per-request `_meta`, `resultType`, and
  input-required retries (MRTR), with the `initialize` handshake (2025-11-25
  down to 2024-11-05) as fallback; Streamable HTTP servers (JSON and SSE
  responses, session headers, `Mcp-Method` / `Mcp-Name` / `x-mcp-header`,
  bearer token from an environment variable); `tools/list` pagination; answers
  to server `ping`s; `notifications/cancelled` on interrupt or tool timeout.
- Typing `/` suggests Skills alongside the built-in commands (with
  `argument-hint`); the menu scrolls with the selection. `/skills` and `/mcp`
  show where each Skill or server came from and why anything did not load.
- Two more Session settings a source-level Host can change while idle.
  `SessionConfig.reasoning_effort` and `AgentSession.setReasoningEffort` set
  the effort every provider request carries; `setModel` keeps it, and a
  provider without an effort control refuses a non-null value at create.
  `WorkspaceConfig.additional_dirs` and `AgentSession.setAdditionalDirectories`
  give a Session further working directories (existing directories only):
  `accept_edits` approves
  Write/Edit/NotebookEdit there and a sandboxed shell may write there, exactly
  as for the workspace root. A replacement is validated before the Session
  changes. doc/API.md now tabulates which settings are idle-mutable, which
  need a new Runtime generation, and which are fixed at create.
- `protocol.wire`: versioned JSON lines for Hosts that carry a Session across
  a process or network boundary. `writeEvent`, `writeRequest` and
  `writeRequestClosed` produce `{"v":1,"type":...}` lines; `parseResponse`
  reads a client's answer back, treating anything malformed as a cancellation
  (closed as `malformed`) and an answer that races an interrupt as cancelled
  (also in `--web`). Hosts previously ran `std.json` over kernel structs, so a
  renamed field changed their clients silently. One pinned line per event
  tag and request kind lives in `tests/fixtures/wire/v1`.
- `session_host.SessionHost`: the multi-session service a network Host puts
  behind its own transport. Sessions open and close by id (fresh, or resumed
  from their transcript), submissions and configuration commands run in one
  FIFO per Session on its driver thread, every event lands in a replayable
  journal as wire lines with `run_id`/`trace_id`, UI requests are answered by
  id, `interrupt` also releases a pending prompt, a poisoned Session is
  reported and refuses work, and `close` frees the id at once while holders
  keep a readable shell until they release it. A cloud
  Host had rebuilt this by hand with a 5-minute watchdog, an interrupt that
  could not reach a pending prompt and a fresh session that resumed the old
  transcript; this is the kernel-side version. `EventJournal` moved from
  `web/` to `core/event_journal.zig` and is exported.
- `GET /health` on `--web`, `serve` and `serve --sessions` (#251): `200
  {"status":"ok","version":"<v>","sessions":N}`, unauthenticated and
  independent of any session, for container liveness and readiness probes.
  `version` is exactly what `metacodes --version` prints first, so an
  orchestrator can check the running release against the one it pinned.
- Bearer-token authentication for that HTTP surface (#252):
  `METACODES_WEB_TOKEN` (or `--web-token`, visible in `ps`) makes every route
  but `/health` require `Authorization: Bearer <token>`; a GET may pass
  `?token=` (EventSource, opening the browser UI), a POST may not. A wrong or
  missing token is `401` with `WWW-Authenticate: Bearer`, decided before any
  request body is read and compared in constant time. The bundled UI is
  opened as `/?token=<token>`; it drops the token from the address bar and
  sends it on every request. Without a token, requests whose `Host` is not a
  loopback name are now refused (DNS rebinding), and a POST's `Origin` is
  compared with its own `Host` (`[::1]` and TLS-terminating proxies work).
  Unset, local use is unchanged. The `--uds` transport keeps its 0600
  socket-file access control.
- `--web-bind <addr>` / `METACODES_WEB_BIND` (#253): bind the HTTP surface to
  any IPv4 or IPv6 literal (`0.0.0.0`, `::` dual-stack, `::1`, ...) instead of
  only `127.0.0.1`; the startup line shows the address actually bound. A
  non-loopback address without a token exits 2 unless `--web-allow-unauth` is
  given. Normative rules: [doc/API.md](doc/API.md#web-and-daemon-http-surface);
  trust model: [SECURITY.md](SECURITY.md#web-and-daemon-trust-model).
- A `--web`/`serve` message can carry its turn's configuration (#255):
  `POST /message` (`/s/<id>/message` under `serve --sessions N`) and the UDS
  `message` op take optional `model` and `permission_mode` beside `text`. The
  session applies them right before that message's turn — the model for this
  session only, without writing the login's saved selection as `/model` does —
  and journals one `config_changed` line per given field ahead of the turn's
  `user_message`. A bad `permission_mode` is refused with 400 before anything
  is queued; a model the provider cannot serve, or a mode the settings
  disable, applies neither field, runs no turn and journals
  `message_rejected`. A control plane no longer has to send
  `/command`, poll `/state` and race a busy session before each message.
  `/state`'s `seq`, `permission_mode` and `pending_request_id` are documented
  for reconnecting clients (doc/API.md).
- Dynamic sessions in the multi-session daemon (#254): `GET /sessions` lists
  the live sessions (`generating`, `model`, `permission_mode`,
  `pending_request_id`); `POST /sessions/create` (`{"session_id"?,
  "resume"?}`) starts one, under the caller's id or a generated one, and with
  `"resume":true` rebuilds its conversation from the transcript persisted under
  the state root, so a session survives a container rebuild;
  `POST /sessions/<id>/resume` answers 200 when the session is live and 404
  otherwise; `POST /sessions/<id>/destroy` aborts its run and stops its
  background agent jobs, teammates and background shells, joins them all,
  ends every SSE stream and UDS attach with `session_lifecycle.closed`, and
  returns. `serve --sessions 0` starts with no session, and
  `--max-sessions M` (default 32) caps live sessions, answering 429 beyond it.
  Requests now hold a counted lease on the session they address for as long
  as they run (an SSE stream or UDS attach for its whole life); a destroy
  never waits for one and frees the session after the last is returned; until
  then its id is refused to a create (409 `session is still closing`). A
  create holds its connection while the session starts; after a timed-out
  create, check `GET /sessions`. Normative rules:
  [doc/API.md](doc/API.md#web-and-daemon-http-surface).

- The `--json` result line carries `continuations`: how many times the Run
  asked the model to continue an answer the provider cut at its output-token
  limit (`max_tokens`). The continued text is one seamless concatenation and
  the line still reads `end_turn`, so before this a headless consumer could not
  tell the answer had been truncated. Source-level Hosts read the same count
  from `RunResult.continuations` (issue #269).

### Changed

- AgentCore provider requests now carry a `currentDate` context block in each
  Run's user record unless the Host supplies one or sets `TIME_CONTEXT_OFF`
  (Revision 22, issue #276). Hosts that byte-compare requests should set
  `TIME_CONTEXT_OFF` or pass their own block. The CLI's date moved from a UTC
  `YYYY/MM/DD` to a local `YYYY-MM-DD (Weekday)` with the zone named.

- An image Run for a model that no Host declaration, provider catalog entry or
  built-in model family covers now returns AgentCore status 29
  `IMAGE_INPUT_CAPABILITY_UNKNOWN` instead of 28 `IMAGE_INPUT_UNSUPPORTED`; 28
  now means a source says the model does not take images. Both still refuse
  before any provider request: an unknown route can drop an image without an
  error, so it is not sent on a guess (issue #273). Hosts that treated 28 as
  "pick another model" should treat 29 as "declare the model, or pick another".

- The Sealed Skill Protocol document says everywhere what the code does:
  the gateway holds no inference account. Roles and identities (§1.2: the
  subscriber's own provider account; the inference-gateway identity relays,
  meters and signs, owns nothing), `discover` (§3.1: `client_provider` MUST
  be `true`; `billing` bills the Skill fee, never the model), the budget as
  a cap on the estimate (§3.4), Step usage (§4.3, §8.2: the provider's token
  counts and the gateway's estimate both travel; model usage is billed on
  the client's own account, the gateway account owes only the Skill fee),
  the disclosure channel (§1.1, §8.5) and creator payment (§12).
  `doc/SKILLS_AND_MCP.md` no longer says usage is charged to the gateway
  account.
- `agent_loop.run` refuses provider server tools: a tool definition with
  `server_type` (in `tool_defs` or `Options.tool_defs`) returns
  `error.ServerToolsUnsupported` before any request (`resumeRun` and
  `resumeRunWithResults` before they append the resumed tool results). The
  loop keeps no server_tool_use or server result blocks, so a turn the
  server pauses (`pause_turn`) could only be truncated. `AgentSession`'s
  tool catalog already rejected them; only direct source-level callers of
  `run` are affected. For the same reason a Sealed Skill gateway refuses a
  `runs.start` whose `provider_tools` is not empty with `invalid params`
  naming the field, before any model call; the client's fork never sends
  one.
- `--web`/`serve`: `user_message` is journaled by the session when the
  message's turn starts, no longer by the transport when the message is
  queued, so it always means "this turn started with this text". A message
  sent while a turn runs now appears after that turn's `run_done`; the bundled
  page shows it as queued until then. Over UDS, the `message` text is trimmed
  and must not be empty, as over HTTP: an empty text is refused instead of
  queued and dropped, and a missing one is reported as `empty message` (was
  `missing text`).
- `config_changed` on the `--web`/`serve` stream is a `protocol.wire` v1 line,
  `{"v":1,"type":"config_changed","data":{...}}`, instead of
  `{"config_changed":{...}}`. The bundled page now updates its model and mode
  display from it; a client reading the stream directly must follow.
- `serve --sessions 1` now runs the multi-session daemon (one startup session
  under `/s/<id>/`, plus the `/sessions` routes), as doc/API.md already
  described; it used to fall back to the single-session `serve`. Plain `serve`
  is unchanged. `--sessions` takes a count of 0 or more and rejects anything
  else (it used to read a bad value as 1), and `--sessions`, `--max-sessions`
  and `--uds` without `serve` are argument errors (exit 2) instead of being
  ignored.
- Destroying or shutting down a daemon session now also cancels its in-flight
  provider request, so a session whose provider stopped sending stops at once
  instead of after the stream idle limit (up to 120 s by default). Stopping a
  background agent job or a swarm teammate (session close, App teardown) now
  cancels its in-flight provider request too, instead of waiting out that
  limit.
- MCP tools are named `mcp__<server>__<tool>` (Claude Code's form, so its
  permission rules and `allowed-tools` lists match); invalid characters become
  `_` and over-long or colliding names get a stable hash suffix. A subagent
  `tools:` list, a Skill's `allowed-tools` or a permission rule that still uses
  the old `<server>__<tool>` name keeps selecting the tool. The
  per-server `<server>__list_resources` / `__read_resource` tools are no longer
  registered; `ListMcpResourcesTool` / `ReadMcpResourceTool` serve resources.
- A Skill name clash now resolves enterprise > personal > project, as in Claude
  Code (it was project-first). Compat Skills reference their live directory —
  only `SKILL.md` and `agents/openai.yaml` are read at startup — and the
  activation result starts with `Base directory for this skill: <dir>`.
- A forked Skill's `agent:` runs it under that subagent's prompt, tool set,
  permission mode and model in the CLI (it used to make the Skill unavailable).
- AgentCore's MCP parser treats an absent 2026-07-28 `resultType` as
  `complete` and accepts the specification's `{method, params}` input
  requests, as the final 2026-07-28 schema requires.
- The `--web` event stream sends the `protocol.wire` v1 lines. Kernel events
  were `{"core_event":{"<tag>":...}}` and UI requests
  `{"ui_request":{"id":N,"request":{"<kind>":...}}}`; they are now
  `{"v":1,"type":"<tag>","data":...}` and
  `{"v":1,"type":"ui_request","id":N,"kind":"<kind>","request":...}`, with
  `ui_request_closed` replacing `ui_request_done`/`ui_request_cancelled` and
  `multi_select` replacing `multi` in questions. The bundled page follows;
  a client reading the stream directly must follow too.
- Breaking for source-level embedders: `transcript.Writer.init` and
  `transcript.listSessions` take the state root as a `StateRoot`
  (`util/state_root.zig`) instead of a `[]const u8`, so a bare path no longer
  compiles there; take the value from `WorkspacePolicy.stateRoot()`. On 2026-10-01 the third
  `Writer.init` parameter changed meaning from home to state root while keeping
  its type, so a Host that still passed `$HOME` compiled and wrote transcripts
  one level off from where it resumed them. New `transcript.sessionDir` and
  `transcript.projectDir` are the only definitions of the layout, and
  `WorkspacePolicy.stateRoot()` returns the root an `AgentSession` resolved;
  doc/LIB_API.md shows the write and resume paths.
- Release and reopen PRs no longer re-run the full CI. A `Release fast path`
  job (`scripts/release_fast_path.py`) checks that the PR's merge commit adds
  only what `scripts/release_cut.py` generates from its base, regenerated in a
  scratch worktree and compared byte for byte, and that the base's push run of
  CI on `main` succeeded (waiting up to 45 minutes for one still in progress).
  Then the four required checks report success without the suites; the
  version state gate still runs. Any other change, a red or missing base run,
  or an error in the check itself takes the full path.
- The Jev `recall_evidence` surface is retired: `KgRecall` no longer consults
  the System-One judge. It appended each hit's relevance percent, an
  evidence-sufficiency score and usage guidance, which in the paid
  attribution pilot cancelled the recall gate's gain in gold evidence the
  model opened (34/60 against 42/60 for the gate alone). A redesign that
  only reordered rows inside the gate's BM25 band put gold first more often
  offline (LongMemEval-S turn-level holdout 272 of 288 against 258,
  p = 0.0005) but showed no gain in a paid paired pilot on 139 cases (gold
  memory opened 56 against 53 of 125 pairs, p = 0.72, after a post hoc
  re-validation; the pre-registered analysis was voided because reordering
  breaks the merge order the evaluator checks), so it was removed too.
  Configuration that still names `recall_evidence` keeps working: the name is
  skipped with a warning and the other surfaces stay advised; a list naming
  only it is refused like an empty list. Records:
  `evals/memory/pilots/longmem-recall-order-glm52-v1` and
  doc/JEV_SYSTEM_ONE.md §6.4-§6.5.

### Removed

- Plan mode. `PermissionMode.plan`, the `EnterPlanMode`/`ExitPlanMode` tools,
  the `<proposed_plan>` protocol and the per-session plan file under
  `<state root>/plans/` are gone, and so is the `plan_approval` UI request:
  `UiRequest`/`UiResponse`, `protocol.wire` (not yet released) and the `--web`
  page no longer carry it. `--permission plan`, `/mode plan` and an agent file
  with `permissionMode: plan` are now rejected as unknown values instead of
  selecting a read-only mode; Shift+Tab cycles default ↔ acceptEdits. The
  built-in Explore and Plan subagents are read-only by their tool allowlists
  (Read/Grep/Glob, plus KgRecall/KgContext for Plan), which also cap dispatch,
  instead of by a permission mode; Explore loses Bash, which plan mode denied
  unless a settings allow rule matched. The AgentCore ABI never exposed plan mode; its
  checkpoint byte 2 stays reserved and decodes as corrupt. Breaking for
  source-level embedders that name `.plan` or `.plan_approval`. A plan
  approved through ExitPlanMode was the only producer of a TinyKG plan graph
  (`kg/plan_commit.zig`), which has no production caller now; existing
  `kg_root` pointers are still read.

### Fixed

- `SessionHost`: an interrupt or close of a Run waiting on a UI prompt could
  fail to stop it. The prompt was released before the kernel abort was
  requested, so the Run took the cancelled prompt as a denied tool, sent its
  next request, and - against a fast provider - ended normally first; the
  interrupt then reported `too_late` (seen once on Windows CI). The abort is
  now in force before the prompt is released; an answer racing the
  interrupt is still discarded.
- MiniMax-M3 takes image input: the model table now says so (MiniMax's
  OpenAI-compatible Chat Completions documentation lists image understanding
  for M3), so AgentCore and the CLI no longer refuse its images (issue #273).
- `AgentSession.setModel` rebuilt the provider without the Session's
  `auth_scheme`, so a route authenticated with `x-api-key` or a custom header
  fell back to `authorization: Bearer` after a model switch.
- doc/API.md said images are never replaced with placeholder text while a
  later paragraph documents the placeholder for image tool results; the first
  statement now covers images in user input only.

- `metacodes sealed serve` stops cleanly. Ctrl+C (SIGINT; also SIGTERM and
  SIGHUP, or the console closing on Windows) now only raises the process-wide
  shutdown flag, and the main thread stops the HTTP server, joins its accept
  loop, frees the Gateway and exits 0 within a 50 ms poll tick. Before,
  `serve` slept forever and looked at no signal, so the console's default
  handler was all that ended it; on Windows that handler runs on its own
  thread while the accept loop is still running, and a gateway left behind
  this way kept `zig-out/bin/metacodes.exe` and its port. A second `serve`
  on a port in use is refused with `BindFailed` rather than sharing it
  (`platform/net.zig` binds with SO_EXCLUSIVEADDRUSE on Windows and
  SO_REUSEADDR elsewhere, neither of which admits a second listener); a
  platform test and an L2 now assert it.
- A provider stream that ends before it reports how it stopped is no longer
  taken for a finished answer (issue #269). A clean end of the connection, or a
  bare `[DONE]`, without Anthropic's `message_delta.stop_reason`, OpenAI chat's
  `finish_reason`, the Responses `response.completed`/`response.incomplete`
  event or Gemini's `finishReason` used to come back as `end_turn`; when the
  lost bytes were the ones carrying `max_tokens`/`length`, a truncated answer
  read as complete and the continuation that should have followed never ran.
  Such a stream is now a mid-stream failure: its text is discarded and the turn
  re-issued within `max_stream_turn_retries` (two in headless mode), and with
  none left the Run ends in `api_error`. A stream that reported its stop and
  lost only the frame tail after it (`message_stop`, `[DONE]`, a trailing usage
  chunk) still finishes normally, and its stop — `max_tokens` included — still
  drives the continuation; a frame tail without a stop report before it is
  incomplete. An Anthropic tool_use block still open when the stream ends was
  silently dropped and now makes the stream incomplete. Gemini's stop report is
  read from the candidate and `promptFeedback` themselves, so a `finishReason`
  key inside a function call's arguments no longer passes for one. An empty
  200 body is incomplete too, rather than an empty answer. Gemini
  `CONTINUATION` (the answer reached the per-request limit but is not finished)
  now drives the same continuation as `max_tokens`.
- `WebSearch` no longer passes off a search the server paused as a complete
  one. Its internal search request is the only one that carries a server tool,
  and when Anthropic stops it with `pause_turn` (the server-side search loop
  reached its iteration limit) the result now starts with a note that it may
  be incomplete; with nothing returned yet it fails as `WebSearchIncomplete`
  rather than saying "No search results found". The search is not resumed:
  resuming means sending the paused response back verbatim, server blocks
  included, which this request does not keep. The agent loop's own requests
  carry no server tools (see the `agent_loop.run` change above), so they
  never end in `pause_turn`.
- OpenAI Chat Completions streams no longer drop text (issue #258). metacodes
  always asks for `stream_options.include_usage`, under which every ordinary
  chunk carries `"usage": null`; the parser took any chunk containing the key
  `usage` for the usage report and returned before reading the rest, so the
  chunk's text, reasoning, tool-call deltas and `finish_reason` were lost. A
  Host or AgentCore SDK consumer could receive no text at all, tool calls never
  formed, and the stop reason came back unknown. Usage now counts only when its
  value is an object (at the top level, or inside a choice where some
  compatible endpoints put it), its numbers are read from that object alone,
  and a chunk that carries both content and a usage object yields both,
  content first. The Responses API and Gemini paths had the same presence test:
  a `null` `response.usage` or `usageMetadata` was reported as a measured zero,
  and Responses read token counts from the whole terminal event, where an
  echoed tool schema with an `input_tokens` property could supply them. Both
  now read only the usage object and report nothing when there is none.
- The daemon end-to-end tests (`tests/e2e/daemon_serve_e2e.sh`,
  `daemon_serve_multi_e2e.sh`) run again and now run in `zig build test` on
  POSIX hosts. They still sent `/mode plan`, which no longer exists, and
  used fixed ports; they now use `/mode dont-ask`, kernel-picked ports, an
  isolated state root with TinyKG autostart off, and also cover `/health`, the
  token, an IPv6 bind and the non-loopback refusal.
- **SIGPIPE no longer interrupts blocking calls with EINTR.**
  - **Cause:** `metacodes` ignores SIGPIPE at startup, but every `std.Io.Threaded.init` swapped that for a do-nothing handler installed without SA_RESTART. Its `deinit` put back whatever it had found, so overlapping lifetimes could leave another instance's handler in place.
  - **Effect:** a handler, unlike SIG_IGN, gets the signal delivered. On macOS a write to a closed socket signals the whole process, so any thread's blocked `recv`/`poll`/`accept`/`waitpid` could return EINTR:
    - the web server reads `recv <= 0` as the end of a request and dropped it;
    - the TinyKG autostart probe once took it for "no answer".
  - **Fix:** every `std.Io.Threaded` is now created through `platform.signal.threadedIo`, which keeps SIGPIPE ignored when the process asked for it, and in tests. A library embedded by a host keeps std's behavior; the host owns its signal policy.
  - **Children:** they get the default SIGPIPE back before `execve`. An ignored disposition survives exec, and without the reset a child pipeline such as `yes | head` would see EPIPE errors instead of ending normally.
  - **Enforcement:** `zig build test` fails on a direct `std.Io.Threaded.init` call (`test:io-threaded`).
- `/mode` could switch a session into a permission mode its settings disable
  (`disableBypassPermissionsMode`, `disableAutoMode`): they were enforced only
  when the settings were loaded. `/mode` now refuses such a mode on every
  surface (terminal, `--web`/`serve` `POST /command`), leaving the mode
  unchanged, and a `--web`/`serve` message asking for it is refused with
  `message_rejected` before anything else in it is applied.
- Work could still run under a permission mode the settings disable
  (`disableBypassPermissionsMode`, `disableAutoMode`) without passing a mode
  switch: an AgentDef's `permissionMode` (Task subagents, background jobs,
  in-process teammates) and a forked Skill bound to such an agent applied it
  as is, so a project `.claude/agents/x.md` with `permissionMode:
  bypassPermissions` ran a subagent in bypass. Such a spawn now runs as
  `default`, logs a warning and says so in its result
  (`permission_mode_notice` on the Task result; a leading line on the forked
  Skill's result; `/agents` marks the mode). Every permission decision now
  runs under `default` when the mode on its context is disabled, whatever
  put it there, including the ApplyPatch path gate and the AgentCore
  external-Tool fallback. `AgentSession.setPermissionMode` and AgentCore
  `update_permission_mode` refuse such a mode with
  `error.PermissionModeDisabled` / `INVALID_ARGUMENT`; an AgentCore Session's
  settings are the Host-imported rules, which cannot disable a mode, so
  today the Host owns which modes it offers.
- `zig build eval:rule-author-build` and `eval:project-rule-mac-pilot` build
  again. Both had stopped compiling on 2026-10-01, when the state root became
  an explicit parameter. The rule-author probe passes no state root, so a
  missing `METACODES_API_KEY_FD` fails it instead of a stored login paying.
  The pilot's simulated TinyKG daemon was also stale against the client: it
  reported store format 2 instead of 3, and lacked the `set-node-property`
  project binding that snapshots need since 2026-08-18. It now reads the
  expected versions from `src/kg/client.zig` and checks the binding before
  serving a snapshot. `zig build test` compiles both drivers on POSIX hosts
  and runs the zero-paid pilot on macOS.
- **The production release gate's calibration can no longer go stale silently.**
  - **What went wrong:** `cli.py gate --thresholds evals/gates/default.json` had refused every release since the evaluation contract moved to v4 (2026-08-23). Its calibration still named contract v3 and a release-contract fingerprint that suite repins had since changed. CI stayed green because every gate test repaired the calibration before using it.
  - **What changed:**
    - A calibration is now either `production` and current, or `stale` with a `stale_reason` that the gate prints when it refuses.
    - `test_checked_in_calibration_is_current_or_marked_stale` checks the committed calibration, using `release_calibration_drift`.
    - The release contract now names glm-5.3-flash.
  - **Recalibrated for contract v4:** 0.5.0 against the candidate, both suites × 6 trials, 132 rollouts (US$27.51). All nine checks pass with unchanged thresholds. The candidate is 100% trustworthy against 0.5.0's 89%, US$0.009 cheaper and 3.6 s faster per rollout. The calibration records the four rollout files' SHA-256; the rollouts themselves stay out of Git.
- The AgentDef release suite no longer fails `42_agentdef_isolation` on how
  the model spells a fact. Its "modified worktree is kept" check looked for
  the literal `worktree_kept=true` in the model's proof file, so a model that
  copied the same Task result as `worktree_kept: true` failed: 7 of 12
  rollouts in a 2026-10-14 paired run, while in all 12 the worktree was kept,
  held the subagent's file and nothing leaked. The check is now the validator
  `evals/validators/42_agentdef_isolation.py`, which grades the Task tool's own
  structured result and the kept worktree on disk (grader
  `agentdef-release-v2`); the suite fingerprint is repinned.
- Sockets no longer leak into child processes. The `--web`, OAuth callback
  and UDS daemon listeners, and every connection they accepted, were
  inheritable, so each later Bash command, hook, MCP server or browser launch
  took them along. A process that outlived metacodes (a job left running
  after a crash, or one started with `nohup … &`) kept the `--web` port
  bound, so the next `--web` on it failed to bind, and kept the browser's
  event stream open after metacodes closed it, so the page never saw it end.
  Every socket the platform layer creates, the TinyKG service's included, is
  now close-on-exec from creation (Linux `SOCK_CLOEXEC` and `accept4`; on
  macOS `fcntl` under the fork serial lock, and straight after `accept`) and
  non-inheritable on Windows.
- A stdio MCP server no longer outlives a metacodes that crashed or was
  killed. The pipe ends metacodes keeps were inheritable, so every process it
  spawned afterwards, above all the TinyKG service that stays up between
  sessions, held the server's stdin open and the server never saw end-of-file
  (on `main` too). Every pipe the process layer creates is now close-on-exec.
  The same fix stops a permission hook, formal kernel or plugin call that is
  fed on stdin from waiting behind an unrelated child spawned at that moment,
  and keeps each MCP server's log from being held open by the other servers.
- Tests and evaluation harnesses that run metacodes under a throwaway HOME no
  longer pick up the caller's Codex setup. `CODEX_HOME` is an absolute path
  that the throwaway HOME does not move, so with it exported every App a test
  built loaded the caller's Codex Skills and started the MCP servers in its
  `config.toml`, and the tests still passed (one App-building test run directly
  started a probe server 14 times). `zig build` now removes it from every step
  it runs, and `tests/e2e/lib.sh`, the TTY driver, the session-memory and
  runtime-arm smokes, the memory-agent runtime's scripted arms, and the plugin
  gate and pair runner drop it from the child environment themselves.
- Skills that Claude Code and Codex load no longer vanish: a symlinked Skill
  directory or skills root (one unreadable root used to empty the whole
  catalog), YAML frontmatter with folded or multi-line descriptions, block
  lists, quotes or CRLF, non-ASCII names, and Skills carrying a virtualenv or
  large assets (which exceeded the snapshot limits). `disable-model-invocation`
  Skills are no longer listed to the model.
- MCP stdio servers started with an empty environment and without a `PATH`
  lookup, so `npx`, `uvx` or `python3` commands never ran; an unresponsive
  server blocked startup forever; a server `ping` got `method_not_found`; tool
  names with `.` broke provider requests; failures were visible only with
  `METACODES_LOG=warn`.
- A `--web` client that reconnects after the host restarted gets the new
  session's events instead of silence. Event sequence numbers restart at 0
  with every journal, and a cursor from the previous one (`since=41`) made the
  server wait until the new journal reached 41, dropping everything before.
  Each journal now has an epoch: SSE ids are `<epoch>-<seq>`, `/state`
  reports `epoch` next to `seq`, and a cursor from another epoch, one naming
  a position without an epoch, or one past the journal's end is answered with
  `event: resync`
  (`{"reason":"epoch_changed"|"epoch_unknown"|"cursor_ahead","epoch","from"}`)
  and a replay from the oldest kept event. Evictions report
  `"reason":"evicted"`. The bundled page reconnects with `?since=&epoch=` and
  starts its view over (DOM and render state) on a resync. Clients that send
  `?since=N` without the epoch now get a replay instead of a continuation.
- An embedded `AgentSession` keeps "allow always" in the Session. Answering
  a Host permission prompt with `allow_always` also appended a whole-tool
  grant to `<workspace>/.claude/settings.local.json`, a file no AgentSession
  reads but the next CLI started in that workspace does, so one click in a
  web or cloud UI became a lasting grant for every later CLI session there.
  `PermissionContext.always_allow` now defaults to `session`; only the App
  (CLI, TUI, `--web`) opts into `settings_file`.
- EnterWorktree moves the session into the worktree, not just the process.
  It used to chdir and record the entry while the session's working root
  stayed put, so Bash (and every tool working from that root) kept running
  in the original checkout for the rest of the session while relative file
  paths followed the process: two trees at once. Now the root moves with it:
  every later tool call in the same Run starts from the worktree, the next
  Run's options and system prompt name it, the permission working-directory
  check covers it, and ExitWorktree brings all of it back. A tool call after
  EnterWorktree or ExitWorktree in the same response is no longer started
  ahead of it by the stream prefetch. The worktree stack lived in the
  EnterWorktree call's scratch memory, so ExitWorktree read freed memory and
  quitting freed it a second time (a crash in debug builds); it is the
  session's own now. EnterWorktree and ExitWorktree refuse before touching
  git or the directory when the host cannot track a worktree (a subagent, or
  a session moved to the background with Ctrl+B, which shares the process
  with the foreground), and a failed step puts the directory back. With the
  sandbox on, a command in a linked worktree may write the main repository's
  `.git`, so `git commit` works there. Project settings are not reloaded
  from the worktree.
- The installer no longer downgrades an install silently. `scripts/install.sh`
  passes `--upgrade` on every run and fetches whatever GitHub labels the latest
  release, and `metacodes install --upgrade` replaced any other version, so a
  rerun moved an install backwards whenever that label pointed at an older
  version. An older unit now replaces a newer install only with
  `--allow-downgrade` (`install.sh --allow-downgrade`, `install.ps1
  -AllowDowngrade`) or `--force`, and an allowed downgrade says so. The unit
  being installed makes the check; for a release up to 0.5.0, which predates
  it, `install.sh` and `install.ps1` make the same check before running the
  unit, in the same version order, and pass `--allow-downgrade` only to a unit
  that knows it. Only running such an older unit's `bin/metacodes install
  --upgrade` by hand still replaces a newer install.
- A launcher name held by another metacodes install is reported as such:
  `install failed (LinkOwnedByAnotherInstall)` names that launcher's install
  prefix and version, and says how to update it, install side by side or take
  the name over. Before, a release install over a development install's
  `metacodes` launcher failed with a bare "the launcher name is taken". This
  install's own launcher in an older form is now replaced instead of refused.
- `zig build test` no longer leaves TinyKG services running. A session that
  needs TinyKG starts its install's service, which outlives the session on
  purpose, and three test entry points ran the real binary in a throwaway
  HOME: the native REPL tests, the headless protocol smoke and the memory
  runtime smoke's HTTPS environment regression (macOS only). Each run left
  `metacodes --state-dir <deleted temp dir> kgd` processes and their
  `tinykgd` children behind, six pairs per run on macOS (a developer machine
  had 148). Those tests now set `METACODES_KG_AUTOSTART=0` and fail if a
  service is still running under their temporary directory
  (`scripts/eval/kgd_processes.py`), and every e2e scenario run through
  `tests/e2e/lib.sh` stops the service its fake HOME started once the session
  ends, leaving other state roots' services alone. Both recognise a service
  started with `--config <path>` (a `METACODES_KG_CONFIG` file) as well.
- A TinyKG service of another state root no longer locks an install out of
  its own. Every state root used to provision port 8799, so while one
  install's service was down a test run in a temporary home could provision
  and bind the very port that install's `daemon.json` pins, and its sessions
  then met a service that refused their key: `auth_failed` until that service
  was killed (seen for two days on a developer machine). A new configuration
  now prefers a port derived from its own path (20000-32767) and takes a free
  one when that is held. Autostart asks the configured port for readiness
  with the install's key and never takes a service that refuses it for the
  install's own: the default configuration moves to a free port with a new
  key (the old one was presented to that service; any local user can bind a
  loopback port) and the same store, and starts its service there, while a
  `METACODES_KG_CONFIG`
  file is left as written and the conflict is logged. A session whose
  readiness probe meets such a service now asks the host to do that, and the
  `auth_failed` hint in `doctor` names the cause.
- Paid memory evaluations: the runner's loopback proxy for a Jev arm's judge
  now reaches the judge directly, as the CLI does. It honoured `HTTP(S)_PROXY`
  and the macOS system proxy, so behind a proxy that could not reach the judge
  an unreachable judge was recorded as the proxy's 503 instead of 502, and a
  proxy that could reach it measured a path the CLI never takes.
- The port-ownership probe from the previous entry retries a call a signal
  interrupted. A session's process runs `std.Io` threads whose signals make a
  blocked `recv` return `EINTR`; the probe read that as "no answer", judged a
  squatting service "unknown" and left the install behind it (about one in
  forty runs of its component test under load, and once on macOS CI). It now
  retries interrupted connects, sends and reads within its 2 s, and on POSIX
  no longer opens and closes a connection before the request. A TinyKG
  service that fails to start after `tinykgd` has answered no longer leaks
  the bridge's read buffer: the supervisor stopped the copy it moved from.
- The TinyKG startup/resume smoke (`tests/e2e/process_dag_resume_smoke.sh`)
  works again and runs in `zig build test` on POSIX hosts. It still seeded
  tasks into the store the command-line transport uses, which sessions stopped
  reading when the local service became their path, so it failed before its
  check on every run and left a `kgd` behind. It now starts the state root's
  service itself (`kg install` + `kgd`), seeds through the service's
  `/api/run` (`tests/e2e/kgd_api.py`), runs the sessions with autostart off and
  every `METACODES_KG_*` override removed, stops the service on exit and fails
  if any TinyKG process is left.

## 0.5.0 — 2026-10-11

### Added

- AgentCore ABI v1 revision 19 (#236): `session_control->update_permission_mode`
  changes an existing Session's permission mode in place while it is idle.
  The handle, logical Session ID and Conversation stay; there is no export,
  destroy and restore. The first permission decision after the call uses the
  new mode. A change starts a new policy generation and revokes every Session
  grant (`allow_session` and `deny_session`), as a rule update does; setting
  the current mode changes nothing. A Run (including one suspended in a
  Permission callback), compaction, checkpoint export, another mutation or a
  draining Provider cancel makes it return `BUSY`; a poisoned Session returns
  `INVALID_STATE` and an unknown code `INVALID_ARGUMENT`; none of them changes
  mode, generation or grants. `describe` reports `permission_mode` beside
  `policy_generation`, and the policy fingerprint after a change is the one a
  Session created with the new mode would have, so an export holds no revoked
  grant and a restore under the same mode keeps the generation. The Session
  Control table grows by one slot to 80 bytes; the header, Zig and Rust SDKs
  (`raw.rs` regenerated), both source-free consumers, the bundle manifest
  and the docs move to revision 19, SDK package `0.6.0-dev`.

## 0.4.0 — 2026-10-10

### Added

- Stall gate: a run whose tool rounds keep returning nothing new is stopped
  with the new stop reason `stalled` and handed back to the person, instead
  of looping until `max_turns`. A round is stale when every slot that ran
  either failed or returned an answer the model has already seen. Answers are
  keyed by tool and result bytes, without the host's own counters
  (BashOutput's `waited_ms`, and the poll guard's `low_yield_polls` and
  `min_wait_ms`, which change on every guarded poll of a silent job); a
  realized file change is keyed by its action. Remembered answers follow the
  model's view, so a result cleared by compaction or microcompaction counts as
  new when fetched again. The run stops after 8 consecutive stale rounds, or
  after 4 stale rounds in which one identical call was made 4 times. A round
  that brings anything new resets the stretch. The round's results are
  committed first, and nothing is injected into the conversation. The REPL
  names the cause, the repeated call and how to continue. Headless reports
  `"stop_reason":"stalled"` (exit 0) and prints the same notice on stderr.
  AgentCore v1 reports it as `tool_loop`. The REPL and web sessions enforce
  it by default (`--no-stall-gate` turns it off); print mode only with
  `--stall-gate`; `--stall-gate-observe` only records. Each armed run writes
  one `stall_gate` tool-observation record (`metacodes-stall-gate-v1`). The
  policy is proven in `control-plane/lean/MetaCodesControl/StallGate.lean`
  (propext only): decisions bounded over any trace, no decision after a
  round with a new answer or when every round brings a never-seen one, and
  a long enough stale stretch always decides exactly once. Design note:
  [doc/STALL_GATE_DESIGN.md](doc/STALL_GATE_DESIGN.md).
- Host check gate (`--host-check <cmd>` with `--check-gate` or
  `--check-gate-observe`, budget `--check-gate-max <n>`, 1–8, default 3). When
  the model ends its turn after changing the workspace, the host runs the
  pinned check command itself and turns the result into a verdict: passed,
  failed, tainted (the run changed the program the check executes or a test
  file a result names, or the check passed while tests that existed before the
  run are weakened — read from the test-integrity sensor below, so appending
  tests no longer taints a pass — or a file tool changed an existing test file
  that git ignores) or unavailable (spawn failure, 180 s timeout, or exit
  126/127).
  In enforce mode a clean failure continues the same conversation with the
  verdict — failing names and reasons from the JUnit/pytest codecs, and the
  output tail — plus an escalating reading from the cognitive-mode schedule,
  until the check passes or the budget is spent; a turn with no new change is
  never checked, so a question-and-answer turn never runs the suite. Observe
  mode runs the same checks and only records them. Each run with the gate
  armed writes one `check_gate` tool-observation record
  (`metacodes-check-gate-v1`: checks, continuations, final verdict, whether
  changes after the last check went unchecked, the command's SHA-256). The
  policy — clean boundaries never checked, only a clean failure continues,
  observe never continues, continuations within budget, Stop-hook blocks
  within theirs, and at most one check per continuation of either kind plus
  one over any trace — is proven in
  `control-plane/lean/MetaCodesControl/CheckGate.lean` (propext only). The
  continuation budget is separate from the host-injection meter: it is driven
  by a verdict, not advice. Headless and the primary REPL run honour the
  flags; macro runs and embedders do not.
- Test integrity obligation (`--test-integrity`, or `--test-integrity-observe`
  to record only). Tests that existed when a run started are the user's
  record of behavior that callers rely on. At run start the host records the
  commit `HEAD` and the content of every test-suite file that is already
  modified or untracked (it writes nothing to the repository); when the model
  ends its turn after using a tool, it compares every suite file below the
  working directory with that baseline, ignoring whitespace and line order. A
  test case file is weakened when an existing non-blank, non-import,
  non-comment line is gone or a skip/xfail/only marker was added — appending
  tests is fine; any change to another suite file (`conftest.py`, runners,
  data under `tests/`) and any deletion is weakening. The sensor reads the
  workspace, not tool events, so Bash edits, subagents and commits are all
  seen, and restoring the lines disarms it. In enforce mode the first stop
  with weakened tests earns one message that names the files and the removed
  lines and asks the model to restore them unless the request explicitly
  requires the change, in which case it must quote that sentence in its final
  answer. Either way the host reports the end state to the user: a `⚠` line
  after the REPL run, a stderr line in headless text mode, a `test_integrity`
  object in `--json` output. Each armed run writes one `test_integrity`
  tool-observation record (`metacodes-test-integrity-v1`: outcome
  `clean`/`restored`/`kept_cited`/`kept_silent`/`observed`, counts only, no
  paths). The policy — pristine tests never messaged, observe never messages,
  at most one message per run, and composed with the check gate the check
  still runs at most budget + 5 + 1 times — is proven in
  `control-plane/lean/MetaCodesControl/TestIntegrity.lean` (propext only).
  The budget sits outside the host-injection meter, so advisory nudges cannot
  use it up. Headless and the primary REPL run honour the flags; macro runs
  and embedders do not.
- Stop hooks can keep the run going, with Claude Code semantics: exit code 2
  or stdout `{"decision":"block","reason":…}` appends
  `Stop hook feedback:\n<reason>` (the reason defaults to the exit-2 stderr)
  and continues instead of finishing; the hook's stdin carries
  `stop_hook_active`, true once a Stop hook has already sent this run back.
  The host caps this at 5 continuations per run (`stop_blocks_bounded`), where
  Claude Code leaves it to the script. Any hook command can now set
  `"timeout": <seconds>` (capped at 600), and the event budget widens to the
  sum of its commands' timeouts, so a Stop hook can run a test suite.

### Fixed

- On Windows, a session that has to start the TinyKG service no longer waits
  30 s before it renders. Autostart checks that the service is up by
  connecting and closing at once. WSAPoll reports that close as POLLHUP
  without POLLRDNORM, and the socket readiness check looked only at
  POLLRDNORM, so the single-threaded service kept polling the closed
  connection until its 30 s request deadline. A fresh install's first
  session, or the first one after a reboot, took over 30 s to show its
  prompt; it now takes a few seconds. The readiness check now treats a hang-up
  or error as readable, as the writability check already did. The TTY
  harness also no longer starts a TinyKG service in the temporary home of
  each case. Each one outlived its case, and on Windows the leftover service
  kept the home from being deleted.
- On Windows, a session that has to start the TinyKG service now shows its
  prompt in about 0.35 s instead of about 6.7 s. Windows does not refuse a
  connection to a loopback port nobody listens on at once: it resends the SYN
  and gives up after about 2 s. The session paid that three times before it
  started the service: twice for the `store-info` read, which is retried,
  and once more for the autostart check. Both now read the kernel's TCP
  listener table instead of connecting, so when nothing listens the service
  is started right away, and the readiness checks while it comes up cost
  nothing. A running service is never handed an empty probe connection,
  including a service left running by an older release. On other platforms a
  refused connection already returns at once, and the checks still connect
  there.
- An AgentCore session no longer poisons itself when a compact or Run is
  aborted from another thread. The aborted operation could return while the
  abort was still inside `Provider.cancel`; Core answers BUSY to everything
  until that call returns, so the facade's terminal usage measurement failed
  and poisoned the session (the Linux 0.3.1 release job hit it in
  `agentcore_abi_test`). A compact's borrowed provider, which lives on the
  facade's stack, could also go out of scope while `cancel` still used it.
  The facade now waits for in-flight cancels to drain before terminal
  bookkeeping and before returning from a compact.
- The release cut (`scripts/release_cut.py`) runs on a Chinese Windows
  without `PYTHONUTF8=1`. It decoded git's UTF-8 output with the locale's
  GBK codec. On Windows the decode error is raised in subprocess's reader
  thread and only printed, so the commit list came back `None` and the cut
  crashed. It now decodes git, gh and Python children as UTF-8. Characters
  its own output pipe cannot encode, such as `µ` and `✓`, are escaped instead
  of failing the dry run. `scripts/check_version_state.py` read HEAD's commit
  subject the same way and is fixed too.
- The end-of-run host check no longer downgrades verdicts to
  `host_run_tainted` when the run only changed the module under test:
  `verdict.taintedByWorkspaceEdits` matched paths as substrings, so editing
  `semver.py` tainted every result naming `tests/test_semver.py`. Paths now
  match by component (equal, or one ends with `/` plus the other), and
  untracked directories, both ends of a rename and quoted paths count.
- After Ctrl+B the agent tree and the switcher list the main session that
  moved to the background again, and the switcher can stop it (#219). The job
  keeps the session it left, as the session boundary requires, and since
  0.2.0 the tree showed only jobs of the current session, which Ctrl+B had
  just replaced; the prompt promised a tree that could not show the job. The
  new foreground now also shows the sessions it handed off; `/resume` drops
  them, because the resumed conversation is not their successor. Model-facing
  routing (TaskOutput, TaskStop) still sees one session only.
- A model picker opened while a reply streams stays open when the reply ends,
  with its filter, stage, cursor and any sign-in in progress (#220). Each
  phase draws its own region, and the open state went away with the
  generation one. A queued message that starts the next reply keeps it open
  too.
- On Windows, a refused, unreachable or timed-out connection to the model
  endpoint is retried like on the other platforms, and the error says what
  happened (#221). Zig 0.16.0 reports those connect failures on Windows as
  `error.Unexpected`, which ended the request after one attempt as
  `RequestFailed`; request setup now names it `ConnectFailed`. Debug builds no
  longer print std's stack trace for unmapped system errors, which Esc during
  a reply drew over the TUI.
- The offline TTY suite runs in CI on Linux and Windows (#222). It ran
  nowhere, so twelve agent-tree cases had failed since 0.2.0 unnoticed: the
  `/agent-test*` commands created agents that belonged to no session (#218).
  The two TTY backends now end a case the same way, a real-model case skipped
  offline reports a skip instead of a pass, cases delete the directories they
  create, and a binary that does not exit after its terminal closes fails the
  case instead of hanging the run. The replay server those cases use read
  directory entries with the macOS `dirent` layout and found no cassette on
  Linux; it now lists them portably. The TinyKG service end-to-end tests run on
  Windows except the one that needs a POSIX symlink.
- The transcript parser can no longer silently drift from the writer or
  quietly flip persisted flags. `parseMessageLine` now dispatches on the
  `Block` tag (`stringToEnum` + exhaustive `switch`), so adding a block
  variant without a parse arm is a compile error instead of the runtime
  asymmetry that once made every extended-thinking session unresumable
  (`"document"` keeps its distinct `WithdrawnDocumentBlock` rejection). The
  boolean transcript fields — message-level `delivered`, `tool_result`'s
  `is_error`/`delivered` — now reject a present-but-non-boolean value as
  `InvalidTranscript` instead of silently reading it as `false`: a coerced
  flag survives into memory and the next `/retry`/compact full rewrite would
  persist the flipped semantics to disk. An absent field still defaults to
  `false` for older transcripts.

## 0.3.1 — 2026-10-07

### Fixed

- The macOS release build passes the AgentCore gate again. Since bundles ship
  a shared library next to the static archive, Apple ld resolved
  `metask-agentcore-sys`'s `-lmetask_agentcore` to the `.dylib`, so the
  crate's own unit tests linked it dynamically and failed to load it
  (`Library not loaded: @rpath/libmetask_agentcore.dylib`); 0.3.0 was tagged
  but never published because of it. The build script now links the archive
  from a directory that holds only it. Crates depending on the SDK were not
  affected: rustc bundles the archive into their rlib.

## 0.3.0 — 2026-10-07

### Added

- The Jev System-One advisor is configured in the install's
  `<state root>/config.json` (`"jev": {"url", "mode", "timeout_ms", "model",
  "decisions"}`) instead of only the environment; each `METACODES_JEV_*`
  variable still overrides its field, so evaluation harnesses that inject them
  per arm are unchanged. An unknown key, a mistyped value or an invalid
  setting disables the advisor with a warning. `metacodes doctor` reports the
  advisor's state, URL and whether it came from the file, the environment or
  both (never part of `--strict`).
- `metacodes doctor` reads like a report at a terminal: the version, install
  prefix and state root, one line per runtime component (paths relative to
  the install, a digest only when it does not match), the TinyKG service, and
  a closing verdict, in colour unless `NO_COLOR`. A service that a session
  would start shows as not running rather than as a warning. `--plain`, and
  any output that is not a terminal, keep the one-line-per-check form
  scripts parse; `--json` is unchanged. `doctor` now also validates the
  TinyKG staging receipts (`tinykg.provenance.json`, `tinykgd.provenance.json`)
  against the binaries beside them, and a receipt that does not describe its
  binary fails `--strict`; release and install-prefix verification require
  both receipts to be accepted.
- The TinyKG service starts by itself. A CLI session whose readiness probe
  finds the install's service unconfigured or not listening provisions it
  (as `kg install`, on 8799 or a free port when that is taken) and starts
  `metacodes kgd` in the background (own session, log in
  `<state root>/kg/kgd.log`), under a cross-process lock per state root.
  `METACODES_KG_AUTOSTART=0` turns it off; explicit `METACODES_KG_URL`
  services and missing `METACODES_KG_CONFIG` files are left alone; the
  shared `unconfigured`/`daemon_unreachable` repair hints say so. The core
  only exposes `KgClient.Autostart`; the host decides how to start it.
  `kgd` now stops cleanly on SIGTERM/SIGHUP as well.
- Hosts customize the system prompt per Session (#184, phase 2). AgentCore
  ABI v1 moves to **revision 18**: `SessionCreateConfigV1.prompt_profile`
  edits the kernel's named prompt sections — replace `metacodes:identity`,
  add `host:*` sections at any order, replace or remove optional guidance —
  while the safety policy and system rules stay locked and the environment
  facts stay kernel-generated. Replacing the identity also drops the
  sentences that belong to it (the environment product line, the doing-tasks
  framing and help bullets), so the prompt names neither MetaCode nor
  software engineering. An invalid profile is refused whole with a diagnostic
  naming the entry and the rule (locked/generated targets, duplicate or
  malformed ids, limits, strict `{{model}}`/`{{workspace_root}}`/`{{platform}}`
  interpolation). The profile is frozen into the Session and its checkpoints;
  the new `session_control->set_prompt_profile` replaces it while idle, one
  prompt-cache boundary per effective change. Subagent and fork-Skill prompts
  inherit it through the replaceable `metacodes:subagent`. Each Run reports
  its prompt — section ids, orders, origins, classes and digests, and the
  prompt digest — in the journal's `run_started` record, in a new
  `prompt_manifest` observation event when it differs from the previous Run's,
  and in `describe` (`prompt.profile`, `prompt.manifest`).
  `RunOptionsV1.context_blocks` gives one text or multimodal Run volatile Host
  facts as a leading `<system-reminder>` text part of its user record, so they
  extend the cached history instead of moving the system prompt. The Session
  Control table grows to 72 bytes; `SessionCreateConfigV1` and `RunOptionsV1`
  keep their sizes. A checkpoint without a profile keeps the marker-8 envelope
  byte for byte; one with a profile is marker 9 and older libraries refuse it
  as incompatible. Without a profile every prompt is byte-identical to before.
  The source-level Zig API offers the same through
  `SessionConfig.prompt_profile` and `AgentSession.setPromptProfile`. SDK
  package version `0.5.0-dev`.
- `metacodes --dump-prompt --sections` lists the CLI's system prompt section
  by section (id, order, class, origin, size, digest) and checks the joined
  digest against the prompt it built.
- Every AgentCore bundle ships a shared library beside the static one
  (#182): `lib/libmetask_agentcore.so`, `lib/libmetask_agentcore.dylib`, or
  `lib/metask_agentcore.dll`, for Hosts that can only load a library at run
  time (Python `ctypes`, Node FFI, JNA, .NET P/Invoke). It exports only
  `metask_agentcore_get_api` (plus inert toolchain names on PE and Mach-O),
  macOS uses `@rpath/libmetask_agentcore.dylib`, and the manifest pins its
  SHA-256 and records `shared_library` (path, entry point, load name, needed
  libraries read from the image). Bundle assembly refuses a shared library
  with any other export or a dependency a clean OS installation lacks (an
  MSVC DLL may need the Visual C++ runtime, which the manifest lists), and the
  native gate runs the C consumer through `dlopen`/`LoadLibraryEx` with no
  AgentCore link input.

- Installation as isolated, coexisting installs (doc/INSTALL_DESIGN.md).
  `metacodes install --prefix <dir>` copies the release unit it belongs to,
  re-verifies every file against the release manifest, writes
  `<dir>/etc/metacodes/install.json`, creates the install's own state root
  (`<dir>/state`, or `--state-dir`), optionally places the AgentCore SDK under
  `<dir>/sdk/agentcore/` (`--sdk`) and a launcher on PATH (`--link`,
  `--link-name`), and ends with the installed `doctor --strict`. It refuses a
  prefix holding foreign files unless `--force`, and another version unless
  `--upgrade` (or `--force`); replacing a version removes the files the old
  manifest listed and the new one does not, and keeps the state root. A taken
  launcher name is refused before any file is written.
  `scripts/install.sh` (macOS/Linux) and `scripts/install.ps1` (Windows)
  unpack an archive, check its `.sha256`, and call it.
- One-line install and a side-by-side development install:
  `curl -fsSL …/scripts/install.sh | sh` downloads the latest release for the
  host (or `--version`), checks it against the release's SHA256SUMS, installs
  it with its AgentCore SDK, and upgrades in place when rerun.
  `scripts/install.sh --dev` builds the checkout's release unit (kernels,
  pins, `release:verify`, SDK) and installs it with its own state root: the
  main checkout as `metacodes-dev`, a linked worktree as
  `metacodes-dev-<worktree directory>`, so a worktree under test never
  replaces the main checkout's install. `--uninstall` removes an install
  (never one a process still runs from, never a launcher it did not write).
  A release that predates `metacodes install` (manifest v1) is refused
  instead of run. A rerun needs none of the first run's options: the
  installer keeps the state root the install record names unless
  `--state-dir` is given, the script keeps the launcher name that already
  points at the install, and a development install's prefix follows its
  checkout rather than its launcher name.
- The release unit is complete on every platform (manifest schema 2): it
  ships the TinyKG daemon and both Lean governance kernels, built natively on
  each release runner and pinned into the executable, with the licence texts
  of the Lean runtime, GMP and libuv the kernels statically link
  (`vendor/lean-runtime/`, `THIRD_PARTY_NOTICES.md`).
- `zig build kernels:stage` builds both kernels from the checkout into
  `<prefix>/libexec/metacodes`, and `zig build test` uses them whenever a Lean
  toolchain is present, so every kernel-gated test runs with no
  configuration; `-Dlean-kernels=on|off` forces or disables that.
  `scripts/kernel_pins.py` prints the `-D…-kernel-sha256` pins for a staged
  prefix.
- `metacodes doctor` reports the state root, its source and any resolution
  error; `--strict` fails on one.

### Changed

- The CLI consults the Jev System-One advisor by default: with nothing in
  config.json or the environment it uses the team's `metask-jev-4b` at
  `http://58.211.6.133:10420` in `advisory` mode (plain HTTP over the public
  network). `"jev": false` in config.json, or `METACODES_JEV_URL=off`, turns
  it off; library embedders get the default only by setting
  `Config.jev_builtin_default`. The build exports `METACODES_JEV_URL=off` to
  every step, and the memory-agent evaluation harness starts every arm with
  it, so tests and unadvised arms never reach the service. `doctor` reports
  `source=default`.
- The built-in Jev default advises `scoped_recall` only, the configuration
  doc/JEV_SYSTEM_ONE.md §7 recommends: in the paired pilots the `KgRecall`
  annotation cancelled the recall gate's gain in verified evidence (34/60 vs
  42/60), the relation judge was never consulted in any pilot, and the
  enumeration judge never crossed its threshold in 55 consultations while
  each consultation is a synchronous round trip. `"decisions"` in config.json
  (or `METACODES_JEV_DECISIONS`) still selects any subset; a `url` of one's
  own still starts from every surface in `shadow`.
- The system prompt is assembled from named sections (#184, phase 1):
  stable `metacodes:*` ids, sparse orders, and a class per section (identity
  and the tool guidance replaceable, the safety policy and system rules
  locked, tone/efficiency/progress removable, environment/memory/Skills/
  subagents/TinyKG generated). The former intro is now `metacodes:identity`
  plus `metacodes:safety-policy`. Prompts are byte-identical to before; a test
  renders 160 tool-set/Skill/memory/TinyKG/deferred combinations against the
  frozen previous concatenation.
- AgentCore ABI v1 moves to **revision 17** (#173): `allow_session` on a
  built-in `Write` or `Edit` now covers later calls of the same Tool on the
  same file, whatever their content or edit strings, instead of only an
  identical call. The Permission callback's `candidate` gains the scope
  `file_target` and a `target` field naming the canonical file (null for
  `exact_arguments`, which every other eligible Tool keeps). The target is
  derived exactly as the tool derives the file it opens, and only when a
  strict JSON parse agrees with the tool's own argument reading; a grant is
  bound to its Tool and Session and ranks where Session grants always ranked.
  Checkpoints record the scope: an older AgentCore refuses one that holds a
  file grant, and checkpoints without one are unchanged. Layouts, tables and
  status codes are unchanged. Revision 16 is skipped because it named the
  withdrawn PDF input; SDK package version `0.4.0-dev`.
- User state lives under a state root instead of a hard-coded
  `~/.metacodes`: `--state-dir` (first argument to cover subcommands), then
  `METACODES_HOME`, then the install record beside the executable, then
  `~/.metacodes`, which development builds and older installs keep. A broken
  install record or a relative override stops the CLI instead of falling
  back to another install's state. Project-scoped `<project>/.metacodes/` and
  `~/.claude/` are unchanged.
- Embedding API: metacodes-core no longer reads the user's home to find
  state. `ToolContext`, `agent_loop.Options` and the subagent, job and
  teammate snapshots carry `state_root`; `WorkspaceConfig.state_root`
  configures an `AgentSession` (default `<home>/.metacodes`, so AgentCore
  hosts are unchanged); `KgClient.ResolveOptions.home` is now `state_root`;
  `auth`, `provider_oauth.Session.initHome`, `config_store.Store.initHome`,
  `metask_ledger`, `AgentSet.loadFromStandardPathsWithPluginSources`,
  `skills.runtime.catalog.defaultSources` and `context_caps`
  (`configureStateRoot`) take the root explicitly.
- The swarm team-directory removal guard requires a strict
  `<state_root>/teams/` prefix instead of a `/.metacodes/teams/` substring.
- A relative `METACODES_KG_STORE` or config `kg_store` is completed against
  the state root, no longer against `$HOME`: with the default root,
  `kg/my.kg` that meant `~/kg/my.kg` now means `~/.metacodes/kg/my.kg`. Use
  an absolute path to keep a store outside the root.
- Learned context caps (`context_caps.json`) persist only where the host
  configures a state root; the CLI does, embedding hosts now keep them in
  memory unless they call `context_caps.configureStateRoot`.
- An install record wins over `$HOME`: a harness that isolates a run by
  setting `HOME` must also set `METACODES_HOME` (or use a development build)
  when it points at an installed executable.

### Fixed

- A long session no longer keeps every buffer it ever allocated. The
  interactive REPL, headless, web, `serve` and teammate modes ran on the
  process arena, which frees nothing: each request body, streamed response,
  tool result and every growth step of a growing buffer stayed committed
  until exit, about six times the bytes sent to the provider. Multi-day
  sessions reached 14 and 31 GB of committed memory and exhausted the
  system commit limit. Sessions now use the general-purpose allocator
  (`serve --sessions N` included); on a scripted 30-turn session, growth fell
  from 40 MiB to 1.9 MiB. Running on a real allocator surfaced a
  use-after-free in `App.deinit` (it read the freed `App` after destroying
  it), now fixed. `zig build test` runs `scripts/session_memory_smoke.py`
  against both binaries: memory growth must stay below the bytes sent, and
  the Debug binary must exit the REPL with no allocator report.
- Tasks left `in_progress` no longer crowd out the current one. A model that
  opens a task per attempt and never closes the last one piled up stale
  in-progress tasks, and the code took the *first* in-progress task as the
  current one: the compaction task anchor named the oldest three with
  "continue the tasks above" (a long session's anchor revived three
  superseded attempts and left out the one in progress), and `KgRemember`
  attached `derived_from` provenance to the oldest. Both now follow the most
  recently claimed task (a claim sequence kept in the degraded-mode task
  mirror, not a clock: the monotonic clock restarts at boot); the anchor names
  the three most recent and lists older open ids with a request to close the
  ones later work finished or replaced. Closing a task (TaskUpdate completed,
  deleted or failed, TaskStop) now lists the other tasks still in progress in
  its result, oldest claim first, so they are reviewed at the moment one ends.
  Each claim now records who made it and when (the same identity the agent
  uses for TinyKG leases, declared by the agent loop), and the anchor, the
  closing list and provenance leave out work another agent still holds: the
  degraded-mode mirror is shared by every session in the repository and by
  swarm teammates, and the startup rebuild of persistent tasks keeps each
  lease's real holder. In the degraded mirror another agent's claim expires
  after two hours (TinyKG's default lease). Like an expired TinyKG lease, it
  can then be claimed again, and both the anchor and the closing list say so
  separately: they never name it as work to continue or suggest closing it
  directly. Persistent `kg-*` tasks follow TinyKG's own lease. A new process
  gets a new identity unless it resumes the session, so after a plain
  restart (or Ctrl+B) the previous process's claims count as another
  agent's until their lease lapses, just as with TinyKG leases. Rows whose
  claimer is unknown (written before this change) are treated as the
  agent's own, as before. When the task panel overflows it keeps the most
  recently claimed tasks instead of the oldest, and a completed task reloaded
  from the mirror after a reboot no longer stays on the panel indefinitely
  (its timestamp is from the previous boot's clock).
- The WorkBuddy installed-adapter suites run in CI: the Linux and macOS gates
  provision the pinned WorkBuddy-Bench checkout
  (`scripts/eval/workbuddy/provision_checkout.sh`: pinned commit, this
  repository's overlay, `uv sync --frozen`) and `zig build test` inherits
  `METACODES_WORKBUDDY_CHECKOUT`. They had always skipped, and the memory
  continuity test had gone stale behind them: its stub container never wrote
  the export probe verdict the v42 export gate requires, so every trial
  degraded. The native REPL smoke (`test_native_runtime.py`) now gets the
  installed product on POSIX instead of skipping.
- The native project-Harness suites (E3 runtime and templates, E2 evolution,
  the calibration matrix) run in `zig build test` whenever the project kernel
  is built (POSIX); they had skipped everywhere, and three regressions had
  piled up behind them. The lifecycle driver wrote its correction session
  under `<home>` instead of the state root since the per-install state root
  (finalize refused every prepare); its static replay still expected an
  oversized verify-only Write to be blocked, although bounds have been an
  envelope rather than a verdict since August; and both project-Harness
  analyzers stood at formal batch schema v5 while the product emits v6, so
  every real rollout failed as "schema drift" or "mixed legacy/current".
  Both analyzers now keep v5 bindings checked, require v6's `within_root`,
  and are pinned to the Zig emitter by a test.
- `zig build eval:jev-recall-driver` compiles again (it still called the
  runtime's removed `fromEnv`); `zig build test` now compiles it.
- The Jev relation judge for `KgRemember` broke whenever a new memory had two
  or three related ones: `n = @min(len, 3)` was inferred as `u2`, so `2 * n`
  overflowed — a panic in Debug builds, and in the ReleaseSmall executable a
  request with no questions. Only the one-related-memory case worked, which
  may have skewed any evidence gathered on the `memory_relation` surface.
- KgRecall failed after any write in a store holding one node whose text has
  no tokens, and reported "TinyKG daemon 不可达" while the daemon was up. On a
  stale full-text index TinyKG's JSON search refuses such a node
  (`Unsupported`); `kgd` now rebuilds the index before serving a retrieval.
  The daemon's `tinykgd: error: <Name>` stderr is now parsed, so its refusals
  are classified and shown instead of being reported as an unreachable
  daemon, and auto-scoping a custom type (`schema-scope --if-absent`, which
  tinykgd answers without a commit receipt) no longer fences every later
  write of the session as an ambiguous commit.
- `--version` and the release manifest disagreed on whether a tree with an
  untracked file is dirty (the executable ignored untracked files, the
  manifest counted them), so `release:verify`, and with it
  `install.sh --dev`, failed on any checkout holding one. Both now count
  untracked files and ignore ignored ones.
- The macOS Lean kernels linked Homebrew's `libgmp` and `libuv`, so they ran
  only where Homebrew had installed them. Both kernel scripts now link the
  static libraries of the Lean toolchain, and every kernel build ends in
  `scripts/check_kernel_self_contained.py`, which refuses any dependency
  outside the OS.
- The coverage-gap L2 leaked the file-change records `executeOne` returned;
  it only ran against a real project kernel, which no CI job provided.

- A release PR could fail its own CI. The version state gate recognises the
  release PR by its title and its `release` label, and `ci.yml` took the
  labels from the `opened` event. `gh pr create --label` adds the label after
  it creates the PR, so that event can be recorded without it: 0.2.1's was,
  and the PR had to be closed and reopened to get a new event. The gate now
  reads the PR's labels when it runs.

## 0.2.1 — 2026-09-30

### Fixed

- The release automation's first real run (0.2.0) hit two bugs. The cut
  (`scripts/release_cut.py`) put the whole changelog section into the
  release PR body, and GitHub refuses a body over 65,536 characters (0.2.0's
  section was 90,841), so it stopped after pushing the branch and left the
  checkout on it. A body over the limit now points to the section's
  `CHANGELOG.md` diff and shortens the bump-derivation lists with a count;
  the size is checked before anything is pushed, and the checkout always
  ends on `main`. `scripts/release_notes.py` likewise stops notes over
  GitHub's 125,000-character release body at the last whole entry and points
  to the full section. The tag job (`release-tag.yml`) looked the tag up
  through an endpoint that answers 404 when it is missing, and `gh` prints
  that error body on stdout, which read as an existing tag: the job failed
  without tagging, and 0.2.0 was tagged by hand at its merge commit. It now
  uses `git/matching-refs`, which answers an empty list.
- The Linux release build could not compile the AgentCore C consumer
  (`tests/agentcore_artifact_consumer/consumer.c`). It used `PATH_MAX`, which
  glibc declares only under a POSIX feature macro, and the consumer is built
  with `-std=c11`. The step runs only in tag builds (pull requests run the
  AgentCore gate on Windows alone), so 0.2.0's build was the first to reach
  it: 0.2.0 is tagged but was never published, and 0.2.1 is the first release
  that carries its changes. The consumer now falls back to Linux's 4096, as it
  already fell back to `MAX_PATH` on Windows.
- The x86_64 Windows/GNU AgentCore archive could not be linked by MinGW's GNU
  ld, so the Rust bindings' cargo builds failed with undefined references to
  `roundq`. std.json's integer parsing calls it; the bundled compiler_rt
  defines it only weakly, GNU ld does not load an archive member for a weak
  definition, and MinGW's libraries do not provide it. The archive now
  carries a strong `roundq` (`src/agentcore/windows_gnu_crt_shims.c`), a
  support symbol like the MSVC CRT shims. The release job's AgentCore gate
  also gets the five-minute test watchdog the Windows CI already uses: at
  the one-minute default it killed a slow unit test.

## 0.2.0 — 2026-09-30

### Changed

- Stream liveness no longer counts gateway keepalives as progress: the body
  idle clock is restarted only by SSE lines that carry model output
  (`api/stream.zig isKeepaliveLine`), while transport bytes of any kind only
  refresh a "last byte" stamp that the stall report uses to say whether the
  gateway was pinging over a dead upstream or the connection itself died.
  The body-phase cap drops from 60 to 30 minutes (`STREAM_BODY_IDLE_CAP_MS`);
  a catalog `max_tokens` of 131072 had pushed the tolerated silence to the
  old cap. (2026-09-23 incident: 55 minutes of pings, zero output.)
- `tool_error`: `Aborted` is now `category: interrupted`, `recoverable: true`
  (new category). A user or host interrupt is neither the model's fault nor
  an environment fault; it no longer counts toward the `environment_fault`
  breaker.
- Zig source API: `PermissionContext` and `permission/decision.Context`
  replace `sandbox_enabled` / `auto_allow_bash_if_sandboxed` with
  `sandbox: ?*const SandboxSettings`, the same settings the Bash tool wraps
  commands with, so the permission verdict and the execution cannot
  disagree. On Windows (PowerShell/cmd) no Bash command is auto-allowed or
  run concurrently as read-only: the classification models POSIX `sh` only.

### Added

- Optional System-One (Jev) memory-plane advisor (`src/jev/`,
  [doc/JEV_SYSTEM_ONE.md](doc/JEV_SYSTEM_ONE.md)), off unless
  `METACODES_JEV_URL` is set; `METACODES_JEV_MODE` is `shadow` by default
  (consult and journal, provider-visible bytes unchanged) or `advisory`, and
  `METACODES_JEV_DECISIONS` narrows it to a subset of its surfaces. It
  advises four existing memory decisions and never gates a tool, permission,
  budget or TinyKG write: scoped recall ranks the BM25-plausible part of an
  8-hit pool (score at least half the top, the baseline's own band) by judge
  probability plus normalized BM25 once the BM25 floor has passed (the judge is
  not consulted below it), `KgRecall` gains a relevance/sufficiency block,
  `KgRemember` a same/contradicts relations block, and the enumeration judge
  arms only the soft coverage reminder. Judge failures fall back to the
  unadvised path without retries (30 s–5 min breaker); a user interrupt stays
  `Aborted`; a different model or a priced tariff is refused. Every
  consultation emits `system_one_decision`
  (`metacodes-system-one-decision-v1`): the scoped-recall decision on the
  evaluation stream, which the evaluation adapters validate, and the
  tool-surface decisions in the tool-observation journal.
  The paid memory runner gains `tinykg_jev`, the attribution arm
  `tinykg_jev_recall` (recall gate only) and the injection-only arms
  `tinykg_inject` / `tinykg_jev_inject` (TinyKG tools withheld, turn-level
  store) behind a loopback judge proxy, and
  `zig build eval:jev-recall-driver` replays LongMemEval-S candidate pools
  through the production recall policies with no provider.
- Release automation (`doc/RELEASE_AUTOMATION_DESIGN.md`): `scripts/release_cut.py`
  derives the next version from the Conventional-Commit types since the last
  tag, rewrites `build.zig.zon` / `src/version.zig` / this file in one release
  PR and reopens `-dev` afterwards; `release-tag.yml` tags a merged release PR
  and dispatches `release.yml`; `release.yml` also runs on a bare `X.Y.Z` tag,
  drafts with the CHANGELOG section as notes, updates an existing draft on
  rerun and never publishes a non-tag ref; `scripts/check_version_state.py`
  (in `doc:check`) closes the window between a release merging and reopen.

### Fixed

- The TinyKG web transport could report a timeout before `timeout_ms` on
  Windows. Its deadline was one sleep on the awake clock, which
  `std.Io.Threaded` turns into a relative NT wait; the kernel services that
  wait on clock-interrupt ticks, so it can end up to one tick (15.625 ms by
  default) early. The 35 s default and the readiness probe's 2 s are whole
  numbers of ticks, so a wait that started part-way into a tick ended early
  by up to that offset: a write could report `AmbiguousCommit`, which blocks
  every later write, before the daemon had its full timeout, and a read
  could spend the leftover milliseconds on a second request. The deadline
  now waits until the awake clock has passed it (`util/time.sleepAtLeast`),
  as the System-One client's does.
- `util/file_lock` could let two contenders hold one lock after its holder
  died. Both judged the dead holder's record stale; the first renamed it away
  and created a fresh lock, and the second's rename then moved that fresh
  lock away instead and created its own, so both went on to rewrite the
  shared file. Takeover is now single-winner per stale record: a contender
  first creates that record's claim file
  (`<path>.lock.claim.<fingerprint>.<generation>`, `O_EXCL`) and deletes the
  lock only if it still holds the record it judged stale, so a fresh lock is
  never moved or deleted. A claimant that dies mid-takeover leaves a claim
  that goes stale after `stale_ms`, and the next generation takes over. The
  lock guards the swarm mailbox and team config, the task-list mirror,
  provider config, transcripts and the TinyKG migration lock.
- The task-list mirror's temporary file was named from the monotonic clock
  alone (`<path>.tmp.<ns>`) and is created with `O_EXCL` on every write.
  macOS `CLOCK_MONOTONIC` ticks in 1 µs (Windows QPC commonly in 100 ns), so
  two writes in one tick would get the same name. It is now
  `<path>.tmp.<pid>.<ns>.<seq>` with a process-wide atomic sequence. The
  mirror lock already serializes its writers and no failure was observed;
  the name no longer depends on that lock to stay unique.
- Three maintainer rule-control sensors had drifted from the code they read
  and failed closed on a correct tree. The TinyKG bundle rule still required
  `metacodes.tinykg-bundle/v1` after the bundle moved to v2; it now reads the
  schema the bundle builder writes (`stage_tinykg_binary.BUNDLE_SCHEMA`). The
  paid-budget lock and treatment-resume rules looked for `O_NOFOLLOW` and the
  reattestation call where refactors had moved them into shared helpers
  (`model.open_nofollow`, `_validate_checkpoint_rows`); they now check each
  hop. `zig build test` runs the rule-control suite (`test:rule-control`),
  which observes every rule on the checked-in tree, so this kind of drift
  fails its own pull request.
- The maintainer rule-control gate also failed closed on a skipped test: the
  paid-budget rule's feedback runs `scripts/eval/workbuddy_release_suite.py`,
  whose roster of WorkBuddy tests that need an external checkout missed the
  one #110 added. The roster lists all ten again, and `zig build test` now
  checks that it is exactly the adapter tests that read
  `METACODES_WORKBUDDY_CHECKOUT` (`roster_violations`), where the old check
  only required the listed names to exist.
- Bash auto-allow no longer runs writes without a prompt. The read-only
  auto-allow (default, acceptEdits and auto mode) keyed on the first word of
  the whole command, so `cd / && rm -rf *`, `echo x > ~/.bashrc`,
  `sed -i …`, `find . -delete` and `ls; curl … -o x; sh x` ran unprompted.
  `permission/bash_readonly.zig` now lexes the command the way `sh` does
  (after the Bash tool's own JSON unescape) and accepts it only when every
  simple command is read-only: no substitution, background job, subshell or
  heredoc; output redirection only to `/dev/null` or a descriptor; write
  options refused per command (`sed -i`/`w`/`e`, `find -delete`/`-exec`,
  `sort -o`, `uniq IN OUT`, `awk` redirects and `system()`, `file -C`,
  `rg --pre`, `git --output`/`branch NAME`/`config` writes, `printf -v`,
  including GNU long-option abbreviations and quoting that spells them;
  `git remote show` needs `-n`, since without it git queries the remote);
  wrappers (`timeout`, `time`, `nice`, `stdbuf`, `xargs`, `command`) parsed
  with their real options; `env`, `exec`, `nohup` and `cd … && git …` ask.
  Anything it cannot parse asks. The concurrency gate
  (`tools.isConcurrencySafeInput`, which also governs stream prefetch) uses
  the same verdict. `rg` joins the read-only roster.
- `autoAllowBashIfSandboxed` allowed every Bash call whenever the setting
  was on, although off macOS (no Seatbelt), for `excludedCommands` and for
  `dangerouslyDisableSandbox` the command runs outside the sandbox. It now
  allows only a call `sandbox_exec.plan` says will run sandboxed, and a host
  without a sandbox backend logs a warning at load.
- `dangerouslyDisableSandbox` (not in the Bash schema) was honored even
  under `allowUnsandboxedCommands: false`, the setting AgentCore's sandboxed
  shell policy uses; it now takes effect only where that setting allows it.
  A sandbox profile that cannot be written no longer makes Bash or Monitor
  run the command unsandboxed; the call fails instead.
- Bash `deny` and `ask` permission rules now match a compound command when
  any segment matches (after wrapper stripping): `Bash(rm *)` catches
  `ls && rm x`, `ls; rm x`, `ls | rm x` and a newline-separated `rm x`. They
  used to require every segment to match, like `allow`, so a harmless prefix
  defeated the rule: `bypassPermissions` and `autoAllowBashIfSandboxed` ran
  the command, and `default` asked instead of denying. `allow` rules still
  need every segment (`permission/rule_spec.zig matchesBashCompound`). Rules
  are now matched against the command the shell receives (the Bash tool's
  own field lookup and JSON unescape), so `\n`, `\u0026\u0026` and `\"`
  are real separators and quotes: `Bash(npm *)` no longer auto-allows
  `npm test\nrm x`. Heredoc bodies are not parsed, so each of their lines
  is a segment of its own.
- Legacy `permission_rules` in `~/.metacodes/config.json`
  (`permission/rule_matcher.zig`) now split compound commands too. Their
  `command_prefix` was a `startsWith` over the whole, still JSON-escaped
  `command`, so an `allow` for `git ` approved `git status && rm -rf ~` (and
  `git status\nrm -rf ~`), and a `deny` for `rm ` missed `ls && rm x`. The
  command is now unescaped as the Bash tool does it and split into segments.
  These rules are first-match-wins in array order, so the first matching rule
  is taken for every segment, and for the whole command so that a prefix
  spanning a separator still matches, and the strictest result wins: any
  `deny` denies, otherwise any `ask` asks, otherwise the command is allowed
  only when every segment is, and the mode decides the rest. An earlier
  `ask` no longer hides a later `deny` on another segment, and an `allow`
  exception listed before a general `deny` still covers its own segment. A
  command inside a wrapper (`timeout`, `nohup`, `env`, ...) is matched again,
  but only its `deny` and `ask` count: `env LD_PRELOAD=... git status` is not
  allowed by `git `. A command that cannot be split (out of memory) gets the
  strictest result the rules could reach.
- A Bash `allow` rule in settings.json approved commands it does not name.
  Every rule kind was matched against `bash_parser.stripWrappers`, which drops
  `env` together with its `KEY=VAL` arguments and drops `xargs`, so
  `Bash(git *)` allowed `env LD_PRELOAD=/tmp/x.so git status`,
  `env PATH=/tmp/evil:$PATH git status` and `xargs git rm`. Since `allow` is
  evaluated before `ask`, such a match also hid the user's `ask` rules, under
  `bypassPermissions` too. An `allow` rule now matches a segment as written,
  or the command inside a wrapper that only changes how it runs (`timeout`,
  `time [-p]`, `nice`, `ionice`, `nohup`, `stdbuf`, `command [-p]`, `exec`),
  parsed with that wrapper's real options (`bash_parser.peelBenignWrapper`):
  `Bash(npm test)` still allows `timeout 30 npm test`. `deny` and `ask` rules
  still see through every wrapper, and now also match the command as written
  and each wrapper layer: `Bash(xargs *)` catches `xargs rm`, `Bash(env *)`
  catches `env X=1 make`, and `timeout -s KILL 5 rm x` triggers `Bash(rm *)`.
- The compound splitter behind Bash permission rules
  (`bash_parser.splitCompound`) cut descriptor redirections at their `&`:
  `npm test 2>&1 | tail -20` became the segments `npm test 2>`, `1` and
  `tail -20`, so `Bash(npm test *)` did not allow `npm test 2>&1` (the `1`
  segment matches nothing) and one of the most common agent commands asked.
  An `&` right after an unquoted, unescaped `>` or `<` (`2>&1`, `>&2`, `<&3`,
  `>&-`) and a `|` right after `>` (`>|`) now belong to the redirection;
  `&&`, a lone `&`, `|&`, `;`, `|` and newline still separate. `&>` and `&>>`
  still split at the `&`, the way dash reads them (a background job, then a
  command that is only a redirection); under bash they redirect both
  streams, and the extra `> file` segment only makes an `allow` rule ask.
- Injected memory lines are cut on a UTF-8 boundary. Scoped recall's 320-byte
  `firstLine`, the KG startup summary's `firstLineTrunc` and the REPL's
  `firstLine` backed off while the last kept byte was a continuation byte,
  which strands the lead byte of a character cut at the limit: a CJK memory
  reached the provider with a trailing U+FFFD and the scoped recall receipt
  hashed different bytes than the provider received. All three use
  `util/utf8.prefixEnd`.
- Paid memory pilots could not run a TinyKG arm since TinyKG storage v3: an
  online (read-write) rollout store's sibling daemon-ownership lock
  (`<store>.tinykg-daemon.lock`) was outside the production Seatbelt
  profile, so every TinyKG command in the child got `PermissionDenied`, KG
  degraded, and treatment activation refused the arm. The carve-out that
  sealed offline stores already had now covers read-write stores as one
  literal path. The memory runner and replay also split JSONL on LF only:
  `str.splitlines()` cut records at U+2028/U+0085 that stay raw inside
  LongMemEval chat text.
- A Ctrl+C/Esc while the provider stream read was blocked was reported as a
  model API error: `provider.cancel` shuts the socket, the read wakes with
  `ReadFailed`, and the stream clients classified that before consulting the
  abort signal. All three clients (and `agent_loop` as a backstop) now report
  `Aborted`, keep the streamed prefix as partial text, and the REPL resets the
  abort signal at every run boundary instead of only after `.aborted`, so a
  stale flag no longer kills the next queued message on its first millisecond.
- `environment_fault` is emitted after the `tool_result` it belongs to, so the
  TUI prints the warning under the right tool card.
- Bash-tool children (`platform/process.spawnToFiles`) get `/dev/null` on
  stdin instead of inheriting the controlling terminal: a child in its own
  process group that read the tty (`ssh` without `-n`) was stopped by SIGTTIN
  and never exited.

- A context-window rejection from the provider is now a measurement and a real
  compaction, not a one-pair shave. `recoverContextWindowExceeded` reads the
  server's numbers from the error body (Anthropic, OpenAI-compatible/GLM and
  Gemini wordings; `error_class.parseContextWindowNumbers`), records the wall
  per (endpoint, model) in `~/.metacodes/context_caps.json`
  (`core/context_caps.zig`, override with `METACODES_CONTEXT_CAPS_FILE`), marks
  the conversation full, runs the summary compaction once per turn and retries
  the same turn; trimming the oldest pair is only the fallback when nothing is
  compactable. Thresholds derive from `min(catalog window, learned cap)` and
  the 13K/20K/3K buffers scale with the window above 200K. Automatic
  compaction keeps the user's requests verbatim in the summary (20K-token
  budget, bounded to a quarter of the dropped prefix, first request always;
  `compact_kernel.Options.preserve_user_prompts_tokens`, off for manual and
  public compaction) and its fallback without a model summary keeps them too.
  Both UI
  backends render the two `context_window_exceeded_*` causes as recovery.
  Before this, a catalog window above the real wall (Metask glm-5.3-flash:
  917,504 derived vs ≈883K observed) pinned a session at the edge: 75
  rejections in 21 minutes, two messages dropped per turn, the prompt cache
  broken every turn, the original task dropped with no summary.
- `UiEvent.queue_message` and `UiEvent.interrupt` were declared by the UI
  protocol and produced by `TuiBackend.poll`, but no production path ever
  called `UiBackend.poll` (#115): the CLI implemented queued messages entirely
  at the REPL layer, so a message typed during a Run could not reach the
  Conversation until the whole Run had finished, and a source-level embedder of
  `metacodes-core` had no way to steer an active Run. The agent loop now
  drains `poll` at every turn boundary (previous tool_results appended, next
  provider request not yet built; never during a stream, and not at the
  boundary right after a max_tokens truncation, so a continuation stays one
  answer): a `queue_message` is appended as a user message and rides the very
  next request of the same Run (blank messages are dropped; the slice is freed
  with the Run's allocator, so in-process backends allocate it with that
  allocator), and an `interrupt` ends the Run there as `aborted`
  (`evaluation_budget` → `budget`) without replacing AbortSignal's mid-stream
  interruption. `TuiBackend.poll` hands over plain prompts only: `/commands`,
  `!shell` and `exit` stay queued in order for the REPL to dispatch after the
  Run, a consumed message is echoed (`❯ …`, same layout as the between-Run
  echo) and added to the readline history, and a message taken just as Esc
  aborts the Run is put back so it is resubmitted afterwards as before. The
  queue preview now renders under the queue lock instead of from borrowed
  slices. Messages still queued when a Run ends become the next Run's input
  exactly as before, the web backend keeps its between-Run semantics, and the
  AgentCore binary ABI is unchanged: it has no active-Run input operation, its
  backend poll returns null, and `doc/AGENTCORE_BINARY_ABI.md` now states the
  Host-side queueing contract. `tests/component/ui_queue_message_test.zig`
  proves the queued text appears in the second request of the same Run after
  the tool_result, that a boundary interrupt stops before a second request,
  that whitespace is dropped, and that the continuation boundary is not
  polled; `ui_backend_test.zig` covers the command gating and the history.
- Windows: `platform.fs.realpath` resolved paths lexically (`_fullpath`), so a
  `metacodes.exe` started through an NTFS symlink or junction reported the
  invoking path as its physical path and every adjacent lookup (`bin/rg.exe`,
  `libexec/metacodes/<kernel>.exe`, `vendor/tinykg/`) searched beside the link
  (#140). A new `platform.fs.finalPath` resolves an existing path through a
  handle (`CreateFileW` + `GetFinalPathNameByHandleW`, `\\?\` and `\\?\UNC\`
  prefixes stripped; null when the path cannot be opened, like POSIX
  `realpath`) and `selfExeRealPath` uses it. `realpath` itself stays lexical
  on Windows on purpose — callers compare its output against paths they built
  themselves (workspace root, permission rules, memory directories), and the
  physical form (on-disk case, long names, mapped drives expanded to UNC)
  would stop matching — but it is now the wide `_wfullpath`, so CJK
  components survive. The `paths.zig` symlink test runs on Windows when the
  runner may create symlinks, a junction variant (`mklink /J`, no privilege
  needed) was added at unit and process level, and `adjacent_symlink_test`
  starts the real `selfexe_probe.exe` through a symlink and through a junction.
- Windows: path-taking CRT calls decoded UTF-8 paths with the process ANSI
  code page (#121). File creation (`_open`) and every directory creation
  (`_mkdir`) were narrow while the existence checks, `statPath`, unlink and
  rename were wide, so one path string named two filesystem objects: `Write`
  could pass its must-read-first check on `测试.txt` and then truncate the
  code-page counterpart (`娴嬭瘯.txt` under CP936), and CJK parent directories
  were created under the wrong names. `platform.fs` now converts to UTF-16
  for every path-taking entry point — `open` (`_wopen`, `_O_BINARY` kept),
  new `mkdir`/`rmdir`/`chdir`/`chmod`/`fopen`/`getCwd` (`_wmkdir`, `_wrmdir`,
  `_wchdir`, `_wchmod`, `_wfopen`, `GetCurrentDirectoryW`), `realpath`
  (`_wfullpath`) — and every production `std.c.unlink`/`rename`/`access`/
  `chdir`/`fopen`/`mkdir`/`rmdir`/`chmod` call in `src/` goes through those
  wrappers, so a file created wide is also deleted, renamed and probed wide
  (the file lock, suspend state, goal file, the kgd install temp holding an
  API key, `.git` and `MEMORY.md` discovery, the KG pointer files). The input
  side is fixed with it: `homeDir`/`tempDir` read the environment through
  `GetEnvironmentVariableW` and `getCwd` through `GetCurrentDirectoryW`, so a
  CJK user profile or working directory reaches the wrappers as UTF-8 instead
  of ANSI bytes the strict conversion would reject. `Write`, `ApplyPatch` and
  the worktree tool share one `mkdir -p` walker (`util.fs.mkdirAll`, with a
  fast path when the directory already exists). `NOFOLLOW`/`isSymlink` decide
  by reparse *tag* (symlink or junction), so OneDrive placeholders and other
  reparse-tagged regular files are no longer refused as links. errno is no
  longer converted with a bare `@enumFromInt` (a value `std.c.E` does not name
  panicked in Debug/ReleaseSafe): callers compare integers (`lastErrnoIs`) or
  look the name up (`errnoTag`/`errnoName`); the wrapper sets errno and
  `GetLastError` itself when it refuses an operation (`ENAMETOOLONG`/`EINVAL`
  for an over-long or invalid path, `ELOOP` for a `NOFOLLOW` open of a link);
  `unlinkPath` reports `NotFound` separately so idempotent cleanup no longer
  guesses with a second `exists()` (logout reported success while the
  credentials file remained when both calls failed for a permission reason).
  Tests create `测试目录/测试.txt` through the wrappers and verify the exact
  names through `std.Io` and directory enumeration, drive `chdir`/`getCwd`/
  `fopen`/`chmod` through a CJK directory, read a CJK environment value back
  as UTF-8, and on Windows seed the ANSI-decoded counterpart and prove `Write`
  leaves it untouched.
- Adjacent-artifact resolution disagreed across resolvers when `metacodes` was
  started through a symlink (the common `ln -s <prefix>/bin/metacodes
  ~/bin/metacodes` install): macOS reports the invoked symlink as the
  executable path, so the release-layout lookups for `bin/rg` and both Lean
  kernels landed in `~/bin` — rg silently fell back to a PATH copy with a
  non-matching digest and the pinned kernels were unresolved (`doctor --strict`
  red, project-rule activation failing closed) — while the TinyKG lookup, which
  already applied `realpath`, resolved. All three now derive their prefix from
  one helper, `platform.paths.selfExeRealPath` (self-exe path resolved through
  `realpath`; a relative invoked path is refused outright, and the fallback to
  the invoked path applies only when `realpath` fails). The REPL's TinyKG client no longer receives an
  `argv[0]`-derived executable directory (forgeable, empty for a bare-name
  `PATH` start, and a second basis next to the OS-reported one); it uses the
  same helper.
  A new process-level harness (`selfexe_probe`) is copied into a staged prefix
  and started through a symlink in another directory to prove rg and both
  kernels resolve beside the physical binary.
- Image input was rejected locally (`image_input_unsupported`, status 28, no
  HTTP request) for non-Claude vision models reached through an Anthropic
  Messages-compatible endpoint, because the Anthropic profile only granted
  vision to names containing `claude` (#112). `provider_kind: anthropic`
  selects the wire format, not the model family: vision is now resolved in
  two layers — the catalog's per-model `image_input` declaration wins when it
  names the model, otherwise one route-independent family table
  (`model_adapter.knownVisionFamily`: Claude 3+, OpenAI GPT-4o/4.1/4.5/5 and
  o-series, Gemini, Qwen VL, GLM-V) shared by the Anthropic and
  OpenAI-compatible profiles — so `gpt-5.6-sol` gets the same answer on both
  routes and the image goes out as an Anthropic base64 `image` source block.
  Text models and unknown names on either route still fail closed before any
  network I/O. The AgentCore ABI suite now proves the positive path end to
  end: a multimodal Run on the Anthropic route for `gpt-5.6-sol` is admitted
  and the provider receives exactly one request carrying the image bytes.
- Stream liveness killed legitimate long tool calls: the idle clock was reset
  per parsed event, so a tool call's `input_json_delta` frames, SSE pings and
  unknown events counted as silence, and the flat 120 s limit also applied to
  the body phase, where a gateway may generate an entire 20-40 KB tool call
  before writing a byte of it (a 126 s call died as `StreamStalled` although
  bytes arrived every second). All three transports now reset the clock on
  every transport read (`LivenessReader`), the request switches from the strict
  head-phase limit (`METACODES_STREAM_IDLE_TIMEOUT_MS`) to a body-phase limit
  scaled by `max_tokens` (`METACODES_STREAM_BODY_IDLE_TIMEOUT_MS`, default
  `clamp(max_tokens × 100 ms, 10 min, 1 h)`) once the response head is
  accepted, and a body-phase stall records the idle time and limit so the TUI
  prints `正文空闲超时: N ms 内无任何字节(上限 M ms)` instead of the generic
  "重试耗尽 / 后端错误 / 上下文超限" guess.
- Child agents could inherit a provider default instead of the lead's current
  effort: the parent logged `none` while a GLM-5.2 child logged `default` and
  consequently enabled thinking. Child resolution now follows AgentDef
  `effort`, explicit Task model-tier effort, inherited parent effort when the
  model is unchanged, then the selected model's default; this also preserves
  an explicit `.none`.
- Per-call providers could fall back to unrelated hard-coded limits. The
  provider factory now passes `ModelLimitsSource`: registries own immutable
  catalog snapshots and App refreshes them after catalog changes, avoiding
  worker races with `/model` rebuilds and probes. OpenAI/Gemini resolve input
  windows through ModelContext; their output limit and `--max-tokens` semantics
  remain unchanged (the override applies only to Anthropic).
- Model routing, capability, pricing, catalog, and context-window matching is
  now ASCII case-insensitive through `model_name.zig`; the model string sent
  on the wire remains unchanged. The GLM-5.2 note also records that the
  2026-07 historical 262144 window became 1048576 on 2026-09-05 (1,001,205
  input tokens succeeded; 1,101,379 was rejected).

### Changed

- CI, AgentCore Windows, Release and Maintainer rule control all run on
  GitHub-hosted runners (`ubuntu-latest`, `macos-latest`, `windows-latest`):
  the repository is public, hosted standard runners are free for public
  repositories, and organization policy keeps public repositories off the
  self-hosted fleet. Runner-specific machinery is gone — the fork-isolation
  `if:` guards, the persistent per-machine Zig/Lean cache directories, the
  per-machine `concurrency` lanes, `-j6`/`-j12` sized for the old boxes, and
  `release.yml`'s `runner_pool` input. In their place: `mlugg/setup-zig`'s
  `use-cache` for the Zig cache, `actions/cache` for `~/.elan` and
  `control-plane/lean/.lake`, `scripts/ci/install-elan.sh` (elan from a
  pinned release asset with a pinned SHA-256; a no-op on a cache hit),
  `requirements-dev.txt` installed on every leg, and `cargo install
  bindgen-cli --version 0.72.1 --locked` in the release jobs. Job timeouts are
  45 min for the gates (cold hosted runners compile the whole tree) and
  unchanged elsewhere. `doc/RELEASE_RUNNER.md` now describes the hosted
  release pipeline; the dedicated `metacodes-release` pool is no longer
  planned.

- Vendored ripgrep moves from 14.1.1 to 15.2.0 (#86): the four existing
  targets are replaced by the upstream 15.2.0 release binaries and
  `rg-linux-aarch64` (upstream's `aarch64-unknown-linux-musl`, static-pie,
  first published in 15.x) joins `vendor/ripgrep/manifest.json`, so
  `aarch64-linux` satisfies the `elf-static` contract that #79 fails closed
  on. Glob/Grep pass only `--files`, `--no-messages`, `--glob`, `--type`,
  `--no-filename` and `--multiline-dotall`; the 15.x notes change none of
  them. Every asset digest was checked against the GitHub Releases API.

### Added

- Progress updates during multi-stage tasks (#114). The shared Core forwarded
  and classified whatever visible text the model produced, but a model that
  called tools round after round without writing a word left the user with
  nothing but tool lifecycle events, and the default prompt's brevity rules
  pushed in that direction. Two provider-neutral changes. The default system
  prompt gains a short "Progress updates on longer tasks" section that defines
  the expectation (a sentence or two at natural milestones — stage, findings,
  next step — outranking the brevity rules on multi-stage work; never for
  single-step tasks, never per tool call, never private reasoning); this
  changes the static prompt prefix once, so the prompt cache is intentionally
  invalidated one time on upgrade and stable afterwards. The agent loop gains
  a bounded progress-update obligation shaped like the delivery-cadence gate:
  a silent stretch — consecutive tool rounds with no visible model text
  (whitespace and host-rendered decorations do not count; text the loop
  continued past, or that max_tokens cut off, does) — that is long enough in
  both rounds and wall-clock time (`Options.progress_update_thresholds`,
  defaults 3 rounds and 10 s) earns one host message at the turn boundary
  asking for a short progress note in the same reply, then the continuation.
  At most two decisions per Run, counted by the shared host-injection meter
  (cap 11 → 13, mirrored in Lean and now pinned by a comptime `cap = Σ`
  assertion), the stretch restarting after each decision. It is a
  host-contract field like its siblings: off in `agent_loop.Options`, left off
  by canonical `buildRunOptions` (macro runs, skill runs and AgentCore hosts
  are not nudged), switched on by hosts with a reader — the interactive REPL,
  the web session and `--stream-json` print mode — and only for a Run whose
  commentary a person can read (`event_projection`); `--no-progress-updates`
  turns it off, `--progress-updates-observe` records decisions without
  injecting. A terminal `progress_updates` observation record (decisions,
  nudges, longest stretch, thresholds) is emitted for the eval trace parser,
  whose policy check is lockstep-tested against the Zig bound and the new
  `ProgressUpdates.lean` policy model (narration resets, below either
  threshold never fires, decisions bounded over any trace). Host-injected user
  records are no longer mistaken for the user's own words: `latestUserText`
  (web-search display query), the transcript viewer and `/recap` skip or
  label them. The reply is ordinary `commentary` (or the final answer if the
  model ends the turn); the output-segment protocol is untouched.
  `tests/component/progress_updates_test.zig` drives the loop through silent,
  narrated, continued-text, whitespace, bounded, time-floored, observe, off,
  subagent and single-step shapes and asserts on the real request bytes,
  segment dispositions and the terminal record;
  `session_api_parity_test.zig` pins the canonical exclusion.

- `providers.<id>.oauth_client_id` in `~/.metacodes/config.json` (#87): the
  OAuth client an installation registered for a built-in profile that declares
  none. `metacodes login --provider <id>`, `/login <id>` and the picker's
  credential stage present it without `--client-id`; precedence is
  `--client-id`, then the configured client, then the profile's declaration,
  and the winner is recorded with the login as before. Built-in profiles keep
  declaring none.

- `.github/workflows/release.yml` (#82, #47 stage 7): `workflow_dispatch` with
  `tag`, `dry_run` and `runner_pool`; one job per platform on the dedicated
  `metacodes-release` runner label (the CI pool only for dry runs) running the
  attested-asset checks, the ReleaseSafe suite, `release:verify`,
  `agentcore:gate`, both archives and a byte-for-byte reproducibility check;
  a `publish` job — the only one with `contents: write` — joins the checksums
  and creates a *draft* GitHub Release with `--verify-tag`. The tag trigger
  stays off until the runners exist; `doc/RELEASE_RUNNER.md` is their design.

- `zig build release:archive` writes the immutable CLI release archive
  (`metacodes-<version>-<target-id>.tar.gz` / `.zip` plus `.sha256`) from the
  verified prefix, byte-identical across runs (fixed gzip name and mtime, no
  owners or timestamps in members); `release:sums` joins the sidecars into
  `metacodes-<version>-SHA256SUMS`. The archive core moved from
  `package_agentcore.py` to `scripts/release_archive.py --kind agentcore|cli`;
  a stable version archives only from a clean tree tagged with the bare
  `X.Y.Z`, a pre-release from any commit, and the SDK keeps its historical
  refusal text (#81, #47 stage 6).

- The CLI release unit (#80, #47 stage 5): `zig build release:stage` installs
  the product files plus `share/licenses/{metacodes-LICENSE, tinykg-LICENSE,
  THIRD_PARTY_NOTICES.md}` and `share/doc/{README.md, CHANGELOG-<version>.md}`;
  `release:manifest` writes `manifest.json` (`release/manifest.schema.json`,
  `release/manifest_contract.zig`, `release/LAYOUT.md`) from git, the vendored
  manifests and the installed files; `release:check` runs the static checks
  and `release:verify` also the executable-running ones on the native target
  (`scripts/verify_release_bundle.py`). A version without a pre-release part is
  the stable channel and requires a clean tree tagged with the bare `X.Y.Z`;
  main now carries `0.2.0-dev`, and `--version` reports `0.2.0-dev+<commit12>`
  exactly as the manifest does. The repository gains its MIT `LICENSE`.

- The default install stages the vendored ripgrep beside the executable as
  `bin/rg[.exe]` with its MIT notice under `share/licenses/`, and the new
  `zig build release:stage -Drelease-layout=true` installs the release layout,
  failing closed for a target without vendored runtime assets (aarch64-linux
  until #86). Under the release layout the executable resolves rg as `RG_BIN`
  → its own directory → `PATH` (the development order is unchanged), and
  `verify_install_prefix.py --release --doctor` proves it on the installed
  prefix in CI (#79, #47 stage 4, B2).

- `metacodes --version` prints the build identity after its unchanged first
  line, and `--version --json` emits it as one document: commit and dirty
  state, Zig, target, optimize mode, release layout, AgentCore ABI version and
  revision, config schema version, and the ripgrep / TinyKG versions with the
  digests pinned for the target. `build.zig` fixes every value at configure
  time from its source (`-Dbuild-commit` names the commit for an exported
  tree; `-Drelease-layout` records the layout), and the runtime smoke checks
  the document against `sdk/zig/types.zig` and the vendored manifests with
  the real binary. `metacodes doctor [--json] [--strict]` reports where ripgrep
  and TinyKG resolve from and whether their digests match the pinned ones;
  `verify_install_prefix.py --doctor` runs it on the installed prefix in CI
  (#78, #47 stage 3).

- The model picker signs in without leaving the overlay (#67): a commit that
  fails for want of a credential on an OAuth-capable provider runs the kernel
  login on a worker thread, draws the authorization URL or device code in the
  picker, cancels on `Esc`, and commits the chosen route once the login lands.
  The OAuth loopback wait and the device-code poll honour an `AbortSignal`
  (`platform/net.pollReadable`), so a login abandoned in the TUI no longer
  blocks until its timeout.

### Changed

- The default `zig build` installs only the release executable and the TinyKG
  bundle (B1, #77): `metacodes-debug` comes from `zig build dev`, and
  `mock_mcp_server` / `replay_server` from the new `zig build test:harness`;
  the TTY and e2e steps depend on those installs explicitly.
  `scripts/verify_install_prefix.py` asserts the exact prefix contents and runs
  in CI on every platform.

### Fixed

- AgentCore child agents (Task / fork / model-invoked Skill) no longer exhaust
  the Session durable budget with bytes the checkpoint never stores. The child
  ran on the parent's `BudgetedProvider` and a `ToolEnvironment` bound to the
  parent's `Controller`, and every child assistant increment and tool result
  settled as durable — yet the child's Conversation is discarded when it
  returns and only its final text re-enters the Session. A subagent-heavy Run
  therefore reached `budget_exhausted` (hosts render it as a budget stop, the
  Task result carries `checkpoint_budget_exhausted`) while the real checkpoint
  was far below `hard_bytes`; reported on a GLM-5.2 session whose subagents
  were verbose enough to trip it. `session_budget.DurableScope` now separates
  the two: a `.transient` operation still reserves its request and payload cap
  while in flight and an oversized child result is still a resource limit, but
  settle adds nothing to `estimated_usage_bytes`. The fork-root final text is
  charged once through `Controller.commitDurable` before `runIsolated` appends
  it (a commit that does not fit withholds the text and ends the Run
  `.budget`); the model-tool child's final text is already charged as the
  parent's tool result.

- `scripts/eval/tests/test_plugin_release_gate.py` did not import on the macOS
  system python3 (3.9): a `list | None` parameter annotation is evaluated at
  definition time (`type.__or__` is Python 3.10) in a module that does not
  defer annotations, so the eval-suite discovery in `zig build test` died at
  collection while CI's newer interpreter never saw it. The module now opens
  with `from __future__ import annotations` like the rest of scripts/, and
  `scripts/tests/test_python_floor.py` reports every PEP 604 union in an
  annotation of a module without that import, and every `X | None` outside an
  annotation (a type alias, an `isinstance` argument), which the import does
  not defer.

- Headless `--stream-json` and `--json` NDJSON lines are always valid UTF-8.
  The stream backend and the `result` line encoded strings with
  `std.json.Stringify.encodeJsonString`, which passes bytes 0x80–0xFF through
  untouched, so a `tool_result` carrying binary tool output (a ReportLab PDF's
  `%\x93\x8c\x8b\x9e` marker read with `Read`, observed on the 2026-09-05
  WorkBuddy office cohort) reached stdout as raw bytes and a strict UTF-8
  consumer rejected the whole file. Every string field now goes through the
  repository's canonical encoder (`util/json.zig`, invalid bytes → U+FFFD;
  `content_bytes`/`input_bytes` still count the raw payload), a `text` or
  `thinking` delta cut inside a multi-byte character is held back and rejoined
  losslessly with the next delta of the same kind, and a character the block
  ends without completing is emitted as one explicit U+FFFD line.

- The Bash tool's spilled stdout/stderr are sealed during execution as attachments
  of its inline result and published by the batch commit boundary, like every
  other tool result since #45/#65; a fatal sibling in the same batch leaves no
  blob, and a channel whose publication fails has its artifact id withdrawn from
  the JSON (`<channel>_artifact_id: null`, `<channel>_storage_error`,
  `<channel>_recoverable: false`) instead of dangling. `tool_result.SealedHandles`
  carries up to two handles per result through `tool_exec` and the prefetch;
  `artifact_store.sealFileCopy` seals a copy of a foreign private file. Callers
  without a batch boundary (`!cmd`, embedders) keep the execution-time resolution
  through `bash.execute`. The MCP projector's above-frame-limit result range
  (`mcp_result_stream.publishRange`, classic client and AgentCore runtime alike)
  and the AgentCore durable-budget promotion (`promoteInline`) seal too, so no
  producer publishes a tool result into the CAS during execution any more; a
  publication that fails at the boundary for a result above the retention ceiling
  is the bounded `ArtifactPublishFailed` tool error (#73).

- `scripts/build-project-harness-kernel.sh` failed its first smoke on every
  platform (`invalid project harness request: expected ,`, exit 64): the
  kernel has read `within_root` after `file_mutating` in every pre-decision
  signal since 33cf238 (2026-08-17), the script's hand-written canonical
  requests never gained the field, and no CI job ran the script. The smoke
  requests now carry `within_root`, two escape probes assert that a target
  outside the project root blocks under both the effect-class rule and the
  existing-file scope, and the `gates` job builds and smokes the kernel on
  Linux and macOS right after `lake build`.

- The paid plugin runner observed and executed the live checkout, so a pinned
  input replaced during a provider request and restored before the after-request
  check went unnoticed (#61, the paid-path form of the #49 gap). `run_paid_pair`,
  `--freeze` and the analysis now read the protocol once, refuse a pinned input
  that is modified in the working tree, materialize Git HEAD into a private
  directory and observe and execute there; each run directory is moved under
  the output directory before its evidence is imported.

### Added

- `THIRD_PARTY_NOTICES.md` is rendered by `scripts/gen_third_party_notices.py`
  from the dependency manifests (ripgrep, TinyKG, highlight-zig, the Lean
  toolchain) plus `release/notices.static.md`; `--check` fails with a diff when
  the committed file is stale, as `zig build release:notices` (part of
  `doc:check`) and a Linux CI step. The rows now carry the pinned commits and
  upstream revision. Stage 1 of #47.

- The pre-submit checklist has one source, AGENTS.md "Before submitting":
  `zig build gate:pr` runs it, `CONTRIBUTING.md` and the pull-request template
  point at it instead of repeating it, and `scripts/tests/test_gate_manifest.py`
  asserts that every checklist command has a CI step (CI gained the
  `git diff --check` step it lacked). Stage 1 of #47.

- `/login <provider> [--device-code] [--no-browser] [--client-id <client>]`
  in the REPL runs the kernel OAuth flow and stores the login where
  `metacodes login --provider` does. Both entry points share
  `src/api/provider_login.zig`: `prepareProfile` makes every refusal a typed
  error before anything is contacted, `Prepared.run` runs the grant and the
  one durable import. A picker commit that fails for want of a credential on
  an OAuth-capable provider now names `/login <provider>` (#33; the picker's
  own credential stage and the built-in OpenAI client id are #67).

- Metask now has a JSON device-code OAuth provider (`login --provider metask`)
  with rotating refresh-token persistence, gateway-derived model routing for
  Anthropic Messages and OpenAI Chat, one-shot replay for pre-stream
  `token_expired` responses, case-insensitive `X-Metask-Request-Id` capture,
  and the opt-in-path `metacodes ledger metask` NDJSON billing ledger. See
  `METASK_SITE_URL`, `METASK_GATEWAY_URL`, `METACODES_OAUTH_DIR`, and
  `METACODES_LEDGER_DIR`.

- `scripts/check_doc_facts.py` with the registry `release/doc_facts.json`: a
  fail-closed documentation fact gate. Each registered fact names one in-tree
  authority (the AgentCore ABI revision in `sdk/zig/types.zig`, the CLI version
  in `build.zig.zon`, the TinyKG and ripgrep versions in their manifests) and
  the documents that state it; every match must equal the authority, and a
  pattern that no longer matches anything fails as a detached sensor rather
  than switching the check off. Runs in CI and as `zig build doc:check`. The
  README, ROADMAP and plugin documents that still said ABI revision 13 or 14
  now state the declared revision, and the two `## 0.1.0` headings below are
  merged into one. (#47, stage 0)
- The provider-offer capability vocabulary's comptime coverage guard now binds
  the real runtime capability enum instead of a hand-copied duplicate, so the
  next runtime capability added without an offer mapping is a compile error
  rather than a silent gap.

### Fixed

- MCP results above the frame limit, host stream tool artifacts and process-plugin
  external spools (`ExternalSpool.seal`) are sealed during execution and published
  only at the batch commit boundary, like native tool results since #45: a fatal
  sibling in the same batch leaves no unreferenced blob in the CAS (#65). Bash's
  stdout/stderr import and the AgentCore-side producers still publish during
  execution and are tracked in #73.

- The fingerprint refresh wrote its staging file with `Path.write_text(newline=)`,
  a Python 3.10 call, so every suite whose setUp repins failed on the macOS
  system python3 (3.9); it now uses `open(..., newline="\n")`, and the 82 test
  fixtures that made the same call go through `scripts/eval/tests/textio.py`.
  The floor (3.9) and PyYAML are declared in `requirements-dev.txt`, an older
  interpreter or a missing PyYAML fails with a clear message, and
  `scripts/tests/test_python_floor.py` keeps every script parseable at the floor
  and free of that call (#59).

- Restored the invariant that a fatal batch does not persist a completed transient
  result (#45). Large captures now seal during execution and publish at the batch
  commit boundary, keeping the envelope reference and CAS publication atomic.
  Failures use the existing inline fallback policy or a bounded
  `ArtifactPublishFailed` tool error; other execution-time producers are tracked
  separately in #65.

### Changed

- Embedding AgentCore is described once: `doc/LIB_API.md` §3/§4 and the
  AgentCore section of `doc/API.md` keep a lead-in and the fact-gated
  sentences and point at `doc/AGENTCORE_BINARY_ABI.md`; `README.md` points at
  `sdk/README.md` for the bundle and gate commands. Stage 1 of #47.

- Superseded design documents (the revision-14 plugin ABI plan, the MCP
  transport hard-cut, the multi-session refactor, the DeepSeek harness analysis,
  the U2 and U9/U10 designs) and the inbound requirements formerly under
  `doc/frommetawork/` now live under `doc/history/`: records, not contracts,
  outside `release/doc_facts.json`. `doc/TREE_SITTER.md` is deleted (the feature
  was removed on 2026-07-13). Stage 1 of #47.

- `ReadArtifact` recovery reads are bounded per turn. Recovery results stay
  exempt from projection (spilling one would recurse), so nothing could trim
  them: nine parallel reads on a 200K window cost 225,000 bytes against a
  204,800-byte turn and squeezed every sibling to its minimum. The agent loop
  now charges each `ReadArtifact` call its upper bound
  (`result_budget.recoveryReadCost`) in slot order before execution and defers
  every call past half the turn budget (`recoveryAllowanceBytes`): a deferred
  call gets a bounded `recovery_allowance_exhausted` body carrying its
  artifact id and offset instead of data, and a `policy_decision` event with
  source `recovery_allowance`. Slot order at the upper bound keeps the
  decision independent of thread timing, so provider-visible bytes do not
  depend on scheduling. (#40)

- The zero-provider plugin release gate now runs validation, pin hashing, and
  subprocesses from a private `git archive HEAD` materialized checkout;
  uncommitted pinned-input edits are refused up front and the checkout is
  revalidated before receipt emission (issue #49).

- MCP tool results decide inline-vs-publish from the caller's
  `result_budget.Budget.per_result_bytes` on both MCP paths — the classic
  `McpClient` and the AgentCore `mcp_result_stream` projector — the same number
  the native tools have used since #41, instead of a private 64KB constant in
  AgentCore that merely coincided with it, and an unconditional inline of every
  response below the classic client's 1MB frame limit (issue #43). `McpClient.callToolBodyAbortable` /
  `listResourcesBodyAbortable` / `readResourceBodyAbortable`,
  `mcp_result_stream.project` and `mcp_runtime.Client.callToolBody` take that
  budget as a required parameter; embedders pass `ctx.result_budget` verbatim.
  This is a breaking signature change for library consumers.

### Removed

- First-class PDF document input is withdrawn (issue #25). Agent Core carries
  cross-format, cross-provider, cross-host input modalities; parsing a
  container format, judging its pages, encryption and structure, and
  attributing budget from that judgement are not Core's job — and a lexical
  scan could not answer those questions correctly anyway, which is how it
  produced three ways to reject a valid document. Removed: the `document`
  block and its neutral IR, `core/pdf.zig`, `supports_pdf_input` /
  `Capability.pdf_input`, the dialect document serializer, transcript and
  checkpoint persistence, `RUN_INPUT_PART_DOCUMENT`, and the headless `--pdf`
  flag. The `Read` tool description stays corrected: it still does not claim
  PDF reading or a `pages` parameter.
  Compatibility: a transcript or checkpoint recorded with a document block is
  refused explicitly rather than partially read — the transcript loader is now
  atomic and reports a dedicated error with an actionable message, and the
  checkpoint decoder reports `UNSUPPORTED` (not `CORRUPT`) for an intact
  checkpoint carrying the permanently reserved block tag `7`, and only after
  its digest has been verified. While the observation channel stays usable, the
  terminal `run_state` snapshot is published exactly once from the Run's final
  result: a post-admission cleanup failure closes it as `poisoned`, an abort accepted from
  the `finalizing` callback is reflected as `aborted` (it used to leave a
  `completed` snapshot beside `STOP_ABORTED`), Runs that never ran the loop — a
  clean failure, a Skill aborted during activation, a synthetic completion —
  no longer stay at `starting`, degraded tool-set observation no longer
  suppresses the closure, and a Host that rejects the terminal snapshot — or
  any callback failure the Session already recorded — fails the Run with the
  recorded callback status and poisons the Session instead of being reported a
  successful Run.
- AgentCore ABI v1 returns to **revision 15**; `RUN_INPUT_PART_DOCUMENT`,
  `MAX_RUN_INPUT_DOCUMENT_DATA_BYTES_V1` and status
  `DOCUMENT_INPUT_UNSUPPORTED` are gone. No bundle was ever published from a
  revision-16 tree (the only release, `0.1.0`, is revision 14, has no assets,
  and no workflow publishes or uploads a bundle), so revision 15 keeps a single meaning and
  the codes need no tombstone. SDK package version returns to `0.2.0-dev`.

### Fixed

- Unhinted `ReadMcpResourceTool` no longer reports a local MCP storage failure
  (`resource_limit` on a full session quota) as `resource_not_found`: the MCP
  client classifies it as `system_error` and the read loop returns it instead
  of trying other servers. Remote errors still fall through to
  `resource_not_found`, which now carries the last server's error detail
  (issue #56).
- A CAS publication failure (a full session quota, for example) no longer turns
  a bounded MCP result into a tool error. All three publishers — the native
  spool, the classic `McpClient` and the AgentCore projector — share
  `result_budget.retainInlineAfterFailedPublish` and keep the bytes inline up to
  their own materialization ceiling (64KB for the two that would have to read
  from disk, the 1MB frame limit for the classic client, which already holds
  the bytes), so the conversation projection renders its bounded head/tail
  envelope with `storage_error` exactly as it did before the threshold change.
- AgentCore's request preflight (`canonicalRequestBytes`) charges image tool
  results as native bytes only when the configured model accepts image
  input; on a text-only route the estimate is exactly the placeholder request
  the serializer sends. Previously the full base64 length was added back
  unconditionally, so a few large image results on deepseek-chat / glm-5.2
  returned `checkpoint_budget_exhausted` for a request of a few hundred
  bytes, and repeated it on every later run because those results are
  non-trimmable.
- Image results now have a wire-size safety net: they bypass the byte
  budgets, so five parallel 3.75 MB pictures could produce a request no
  provider accepts. `types.MAX_IMAGE_RESULT_BYTES_PER_REQUEST` (16 MiB) caps
  the base64 image bytes per request: the projection spills the largest
  images of the current turn beyond the cap into artifact envelopes, and the
  agent loop stubs the oldest already-delivered image results before each
  request until the history fits (first-class user images count against
  the allowance and a fresh tool turn is projected against what they leave;
  the block-level watermark is persisted in the transcript, so a resumed
  session trims exactly the pictures earlier requests delivered natively and
  reports explicitly when only non-trimmable images exceed the cap).
  Gemini 3 function responses embed only
  PNG/JPEG/WebP; `image/gif` results now go out as a sibling `inline_data`
  part instead of being rejected. The stream handle reports the exact
  tool_use ids whose image went out as a placeholder, so a plugin dialect
  that serializes some MIME types natively and refuses others no longer pins
  the natively-sent pictures.
- OpenAI chat/completions and Gemini dropped every text block that shared a
  message with tool results: the PostToolUse `additionalContext`, the
  verification checkpoint, the requirement-ledger prompt and similar host
  text that the agent loop appends to the tool-result user message never
  reached those providers (Anthropic and the OpenAI Responses protocol were
  unaffected). The chat serializer now re-sends that text as a user message
  after the tool messages (or as the last part of the image follow-up
  message), and Gemini appends it as trailing text parts of the same user
  content. Covered by serializer tests and by the hook-pipeline component
  test, which now asserts the context on the wire.
- The image projection exemption (issue #26, below) is covered end to end by
  an agent-loop test that reads an 80 KiB-base64 PNG through the real `Read`
  tool and asserts the image block on the wire, and the same exemption now
  also holds at the two other layers that rewrite a tool result before
  serialization: microcompact no longer clears an image
  result under the recent-N pressure valve (a `Read(image)` with two parallel
  siblings was cleared before the provider ever saw it), and the AgentCore
  `ToolEnvironment` no longer promotes an image above `tool_result_cap_bytes`
  to an artifact (the payload cap is charged at the vision estimate, the
  durable budget at the real bytes). In exchange the shared predicate
  `extractImageResult` only accepts the canonical Read shape: allowlisted
  media type (`image/png|jpeg|gif|webp`), standard base64, at most
  `MAX_IMAGE_BYTES` of payload, exactly the three keys in any order with only
  whitespace after the closing brace, so a plugin cannot obtain an unbounded
  exemption by prefixing arbitrary output with `{"type":"image"`. `result_projection.Stats.projected_bytes` stays a
  real byte count; the turn-budget decision moved to a new `budget_bytes`.
  The predicate is structural (any field order, standard JSON whitespace,
  exactly the three keys, raw content bounded by `MAX_IMAGE_RESULT_BYTES`),
  so surrounding whitespace cannot smuggle an oversized payload past the
  budget and a JSON serializer that does not escape `/` still produces an
  image. Microcompact protects only images that have not yet been delivered
  to the provider, where delivery is an explicit per-message watermark
  (`Message.delivered`) advanced by the agent loop once the provider has
  accepted a request for streaming — and, for messages holding an image
  result, only when the serializer actually sent native image parts (a
  non-vision model only received the placeholder; the serializer reports the
  affected tool_use ids back on `StreamHandle.image_placeholder_ids`, and the
  flag lives on each tool_result block) — never inferred from a locally
  appended assistant message; delivered
  images clear like any result, so the pressure valve keeps working on
  image-heavy history, and images are never truncated. AgentCore `settleSuccess` now counts live
  sibling reservations against the hard budget, so an inline image whose
  durable bytes exceed its own reservation is refused instead of consuming
  the space a parallel tool had already reserved.
- Transcript resume no longer treats a failed `read` as end-of-file: `EINTR` (a
  Ctrl+C or terminal resize during `/resume`) is retried, and any other read error
  makes `loadTranscript` and the compact-state meta loader fail with `ReadFailed`
  instead of silently restoring a truncated or empty history. The `/resume`
  listing keeps skipping a session whose `meta.json` cannot be read. Surfaced by
  the Codex cross-review on #46.
- Restoring a persisted compact projection is all-or-nothing: `restoreCompactState`
  allocates the summary before touching either field, so an allocation failure
  during resume leaves a genuine full replay rather than an advanced boundary with
  no summary (and no dangling summary pointer).
- A KG client that owns no Store can no longer create one (issue #30).
  `KgClient.store_path` was a single `[]const u8` carrying two meanings — a
  real path under the CLI transport, and the marker `"daemon-owned"` under the
  daemon transport, meaning *this client owns no Store*. Nothing in the type
  stopped the marker from reaching a call that treats it as a path, and
  `cloneForThread` did exactly that: it guarded on `transport == .daemon`,
  while the marker is set for `.daemon` **and** `.unconfigured`, so an
  unconfigured parent fell through to the CLI reconstruction, which re-resolved
  a real `bin_path` and then ran `tinykg init daemon-owned`. Because the marker
  is relative, the Store materialised in the process's current directory — for
  the TTY e2e suite, the git worktree, as untracked `daemon-owned/` and
  `daemon-owned.tinykg-daemon.lock` that no `.gitignore` rule covered.
  The field is now `store: StoreRef`, a union of `.owned` (an absolute path)
  and `.unowned`; `argvSlot()` serves the argv slot the wire protocol
  reserves, and `fsPath()` returns an optional that every filesystem call must
  unwrap. A relative store path from config or `METACODES_KG_STORE` is
  completed against `home` rather than taken as given, so no configuration can
  steer the Store — or the five sibling artifacts derived from it — into the
  current directory. **Breaking for source-level consumers:** `store_path` is
  replaced by `store`.
- `zig build --build-file control-plane/build.zig rule-check` passes again. It
  demanded that every discovered test be imported into `tests/integration_suite.zig`
  while build.zig panics if a *dedicated* test appears there, so the reported
  omission was unfixable as stated: satisfying the rule aborted the build and
  took seven rules down with it. The sensor kept a hand-written copy of
  build.zig's `aggregate_test_exclusions` that had gained neither the second
  entry nor a way to notice; it now parses that list from build.zig, and
  additionally requires each excluded test to have its own `root_source_file`,
  so being excluded from the aggregate means having a home rather than merely
  having a file.
- The OpenAI Responses protocol now replays reasoning items across tool
  continuations (issue #23). Requests use `store:false`, so the server keeps no
  copy of the response and reasoning context survives only if the client sends
  the server's own `reasoning` items — `id`, `summary`, `encrypted_content` —
  back verbatim; previously they were parsed away and the next request carried
  only the function call and its result. Items are captured from
  `response.output_item.done` **and** from the terminal response's `output`
  array, deduplicated by id so an item present in both is replayed exactly
  once, and emitted first among their message's `input` items, matching the
  server's own output order. Replay is model-scoped: after a mid-session model
  switch the stale encrypted state is dropped rather than sent to a model that
  would reject it. Reasoning items persist through the JSONL transcript and the
  AgentCore checkpoint (block tag 6). A conversation without reasoning items
  serializes byte-identically to before.
- Image tool results are no longer spilled into artifact envelopes before the
  dialect layer can serialize them (issue #26). `result_projection` rewrote any
  tool result above a `clamp(window/8, 8 KB, 64 KB)` threshold, while the
  `Read` tool accepts images up to 3.75 MB — so essentially every real
  screenshot became an envelope and the native image serialization added in
  #24 never ran on it, on every provider. Image-shaped results (detected with
  the existing `dialect.extractImageResult`, not a second sniffer) are now
  exempt from byte-length spilling in both projection passes, and the per-turn
  budget charges an image at `IMAGE_TOKEN_ESTIMATE` instead of its base64
  length, so one screenshot no longer evicts unrelated tool results. Images
  stay bounded by `MAX_IMAGE_BYTES`, and non-image results project
  byte-identically to before.

- Image tool results (the `Read` tool's
  `{"type":"image","media_type":...,"data":...}` form) are now serialized
  natively on every protocol family instead of being passed to the model as a
  multi-megabyte base64 text string on OpenAI and Gemini. Vision models get
  the image itself: OpenAI chat/completions sends a short pointer in the tool
  message and the image in an immediately following user message (tool
  message content officially accepts text only); the OpenAI Responses
  protocol sends `function_call_output.output` as an official `input_image`
  parts array; Gemini 3 uses the official multimodal function response
  (`functionResponse.parts[].inlineData`), older Gemini models get a sibling
  `inline_data` part in the same user turn. A model without vision gets a
  short explicit placeholder — never the raw base64 — including text models
  behind Anthropic-compatible gateways, which previously received an `image`
  source block they reject. Non-image tool results and Claude vision
  serialization stay byte-identical (prompt-cache prefixes unaffected).

### Added

- Provider profiles, model offers, and a UI-independent runtime control plane
  (issue #16, delivery slice P0 plus the Z.AI GLM Coding Plan provider).
  `ProviderProfile → ChannelDescriptor → ModelOffer → RuntimeSelection`
  replaces "a model name identifies the route": relays, regions, plans,
  accounts, and BYOK bindings now produce distinct offers for the same visible
  model, and `OfferId` is a domain-separated digest over the normalized stable
  binding so a metadata refresh moves `offer_revision` without moving a pinned
  selection. Adding a vendor is one `src/provider/profiles/<vendor>.zig` file
  plus one line in `BUILTIN_PROFILES`; the transport is selected by the offer's
  protocol, which retires `main.zig`'s model-name prefix guessing for every
  session that names a provider. New CLI flags `--provider`, `--channel`, and
  `--offer`; a model matching several routes reports the candidate offer ids
  instead of guessing, and a `--base-url` override is validated against the
  profile and route policy before any request URL is constructed. Ships
  `metask`, `openai`, `gemini`, and `zai-coding-plan` profiles — the last with
  all four documented China/global × OpenAI/Anthropic-wire routes, its own
  credential kind, `ZAI_API_KEY`/`GLM_API_KEY`/`Z_AI_API_KEY` aliases, and a
  forbidden-path rule that makes silent fallback to the general
  `/api/paas/v4` surface unrepresentable. Credentials become typed, secret-free
  `CredentialRef`s resolved in provider scope, so a Metask key can no longer
  authenticate an OpenAI or Z.AI route; the transports materialize a
  provider-declared `AuthScheme` (bearer, `x-api-key`, custom header) instead of
  a hard-coded bearer header. Metadata is conservative throughout: distinct
  context/input/output limits with fail-closed admission, tri-state
  capabilities, `unknown` (never zero) prices, and per-field provenance.
  `~/.metacodes/config.json` gains a schema-versioned, monotonically revisioned
  provider map written under a cross-process lock via temp-file + fsync +
  rename, with idempotent retries and deterministic revision conflicts. See
  [doc/PROVIDER_OFFER_ARCHITECTURE.md](doc/PROVIDER_OFFER_ARCHITECTURE.md),
  including its explicit list of deferred slices.
  Endpoint policy refuses two whole classes of URL rather than pattern-matching
  them: a percent-encoded host or path (a substring rule over encoded bytes is
  not a rule while the server still decodes it) and any URL carrying userinfo
  (that string becomes `ModelOffer.endpoint_ref` and flows into `model.list`,
  events, and setup output, none of which redact it). The control plane guards
  its mutable state and hands `model.list` results into a caller-owned buffer,
  so two clients cannot invalidate each other's page; `events.replay` copies
  under the lock. `config_store` is the single authority for `config_revision`
  — the kernel mirrors it through `adoptConfigRevision` rather than keeping a
  second counter — and idempotency keys are a bounded ring, so a retry is still
  recognized after other commits have landed.

- Cross-UI model picker, durable selection at startup, and built-in pricing
  (issue #16, further P1 slices). `Ctrl+O` and `/model` open one picker —
  provider → canonical model → channel/offer → options → commit — that reads
  offers from the control plane and mutates only through it. Offers are grouped
  by canonical id, never by visible name, so two channels serving "GLM-4.6"
  over different protocols, regions, or prices stay separate rows showing their
  endpoint, wire model id, limits, price, and health. The picker is modal for
  the keyboard and not for the session: typing filters, the draft in the input
  box is untouched, a reply keeps streaming, and a mid-stream commit takes
  effect on the next turn. Session is the default scope and `Tab` cycles to
  `global`/`once`, so a durable write is always an explicit act the footer
  spells out before Enter. Transcript viewing moves to `Ctrl+X Ctrl+O` — same
  letter, on the existing `Ctrl+X` prefix — with `/transcript` as the
  documented equivalent; TTY regressions cover both paths, including their
  Kitty CSI-u forms. `/model use <id>` now resolves against the offer catalog
  first, so a model served by another provider or protocol switches in place; a
  name carried by several routes reports their offer ids instead of guessing,
  and an offer id is accepted verbatim. `/models` keeps account-key selection,
  which is a credential choice rather than a route.
  A selection committed with `global` scope is now read back at startup:
  `applyPersistedGlobalSelection` applies it before model-name inference, and a
  stored pin the catalog no longer offers is a startup error naming the offer
  and the way out — never a silent fallback to another vendor. Session scope
  gets its own document and its own file (`<session>/runtime-selection.json`)
  rather than sharing the global key, so one session's choice cannot become
  everyone's. The `metask` profile ships a real quote derived from
  `util/pricing.zig` — the same table `/cost` reports with, asserted equal
  field by field — while `zai-coding-plan` deliberately stays `unknown` because
  a Coding Plan subscription is not billed per token. `Quote` gains a cache-write
  rate so an estimate over a cached turn is not silently low.
  New gate `zig build test:picker` compiles the picker from a root reaching the
  provider kernel and the terminal theme and nothing else.

- User-defined providers (issue #16, P1). A `custom_providers` section in
  `~/.metacodes/config.json` defines provider instances that go through the same
  registration and validation as a built-in profile, so the picker, `--provider`,
  `model.list`, `quote.estimate`, and token admission treat them identically.
  The schema is declarative and cannot execute anything: there is no field for
  code, a callback, a shell command, or a request template, and unknown keys are
  ignored rather than interpreted. A protocol is a *wire* plus an optional
  request path — what relays and gateways actually differ by — so a relay needs
  no adapter, while a genuinely novel wire is rejected rather than guessed.
  Declared limits, capabilities, prices, and controls carry
  `user_config` provenance and a configured price is marked estimated, because a
  number the user typed is a declaration and not a vendor observation. New
  `--check-providers` dry run validates the configuration and prints every route
  it produces — provider, channel, protocol, endpoint, wire model id, context,
  price — with no credential resolved and no request URL built.

- Provider catalog adapters and the events they enable (issue #16, P1).
  `src/provider/openrouter.zig` parses model and endpoint documents
  *separately* — a model with three endpoints becomes three offers, because a
  model name is not a route — and merges them so an endpoint's own values win
  while an absent one inherits with `inherited` provenance instead of becoming
  free or unlimited. An endpoint that never reported a status has `unknown`
  health, not healthy; a price string that is not a number is an error, not a
  zero. Provider preferences compile into `RoutePolicy` with `only`/`ignore` and
  the numeric ceilings as hard constraints and `order`/`sort` as preferences
  that never reject, and `PriceConstraint` gained per-direction ceilings because
  a router's price limit is per direction. Router metadata folds usage, cost,
  latency, and fallback attempts into the `ActualRouteEvent` the kernel derived
  without rewriting what was requested. Ingesting a catalog moves the catalog
  revision and emits `catalog.updated`, `pricing.updated`, and
  `provider.degraded`; `auth.changed` and `credential.expiring` gained kernel
  producers. Catalogs are named by a `provider_catalogs` section in
  `config.json` and read from disk, so no transport dependency enters the
  provider subsystem.

- Provider-scoped OAuth lifecycle (issue #16, P1). `provider/oauth.zig` runs
  refresh, single flight, and rotated-refresh persistence for any profile that
  declares an OAuth credential kind and a token endpoint — OpenAI and Codex
  first; Metask keeps its historical `core/auth.zig` path byte for byte. N turns
  discovering an expired token at once perform exactly one refresh, because with
  a rotating refresh token the losers of that race would present a token the
  server already invalidated. The rotated token is persisted atomically (temp
  file + fsync + rename, 0600) *before* it becomes the live one: a provider that
  rotated has already killed the old token, so "used but not saved" locks the
  user out while "saved but not yet live" is recovered by the next load. Refresh
  triggers a margin before expiry, since a token that expires mid-flight fails
  the request it was attached to, and `invalid_grant` is terminal rather than a
  transport error a retry loop would chew on. The module performs no I/O — the
  exchange is a function pointer, with `api/oauth_exchange.zig` as the
  production `refresh_token` grant — so every lifecycle test drives a fake and
  none needs a network. `metacodes login --provider <id> --oauth-token-json
  <file>` imports the first token into that provider's own store.

- Selection scope, auth-scheme inheritance, and the query-auth decision
  (issue #16). A `session`-scoped commit is now written to the session's own
  `runtime-selection.json` and restored by `/resume`; because session scope is
  narrower than global, a resumed session continues on the route it was using
  rather than whatever became global meanwhile, and a stored route that no
  longer resolves is reported instead of silently replaced. The resolved route's
  auth scheme now reaches swarm teammates and `AgentSession` as well as `App`
  and background subagent jobs — a worker sending bearer at an `x-api-key`
  endpoint has the right key and the wrong header — and a route switch moves the
  swarm context with it so a teammate spawned afterwards cannot dial the
  previous provider. `AgentJobRegistry.setRoute` moves key, endpoint, transport,
  and scheme together for the same reason.
  `AuthScheme.api_key_query` is **removed** rather than implemented. A secret in
  a query string lands in server access logs, proxy logs, and referrer headers,
  and it would flow into the endpoint strings this subsystem already refuses to
  let carry credentials — the endpoint policy rejects userinfo URLs for exactly
  that reason.

- Credential pools: several accounts per provider, each its own route
  (issue #16, P2). A `credentials` list on a configured provider declares
  accounts **by reference** — id, environment-variable name, kind, priority —
  so no secret enters `config.json`, which several tools read and which is not
  mode 0600; a literal `secret` key is rejected at parse time. A bound
  credential participates in the offer id, so each account becomes its own offer
  and appears as its own row in the picker with an `account=` column. That also
  removes the need for a separate credential stage: the accounts already are
  offers. Because the offer names the credential, binding uses that member
  rather than the pool's highest-priority one — resolving to a different account
  would make the offer id identify a route the request does not take. Selection
  among unbound members is deterministic (priority, then id) so configuration
  order cannot make a failover irreproducible, and members that are invalid,
  cooling down, expired, or empty are skipped. `noteFailure` maps a
  provider-classified failure to the right state: a rate limit earns a cooldown,
  an authentication failure marks the credential invalid, and a transient
  network error changes nothing. The pool is consulted after every existing
  source, so a single-credential setup resolves exactly as before.
  `credential.expiring` and `auth.changed` now have producers on the OAuth path,
  which is the only thing that knows a credential's expiry.

- TinyKG decision audit plane (issue #16). Control-plane events are projected
  into an append-only record under `metacodes/provider-decisions` at the turn
  boundary — accepted and rejected selections with the catalog and config
  revisions that make them reproducible, actual routes with fallback attempts
  and cost/latency aggregates, failovers, catalog and pricing refreshes, and
  credential status changes. `provider.degraded` health samples are deliberately
  excluded: the requirement names high-frequency observations as something that
  must not accumulate in the graph. The projection is safe by construction —
  event payloads are ids and enums with no free-form field — and a test asserts
  no recorded line contains a quote, a URL, `Bearer`, or `sk-`. The plane is
  optional: nothing on the request path calls it, and a TinyKG outage is counted
  rather than propagated into routing.

- Catalog fetching and learned credential failover (issue #16). Provider
  catalogs may now be fetched (`models_url`, `endpoint_urls`, optional
  `credential_env`) as well as read from disk, with `/providers refresh` driving
  it; a refresh that fails leaves the previous catalog in place, because a stale
  catalog is a better answer than an empty one and every pin stays resolvable.
  The fetch lives in `api/catalog_fetch.zig` rather than in the provider
  subsystem, which must not depend on a transport. `/providers` also lists every
  route with its account, context, and price. Credential failure state is now
  learned and durable: a rate limit records a cooldown and an authentication
  failure records an invalidation, through the same lock, revision, and atomic
  write as every other mutation, so the next process skips the credential
  instead of rediscovering the limit by hitting it. The class is the provider's
  own classification, and a transient network failure records nothing.

- Local route aliases (issue #16, P2 follow-up). `AliasEntry` was a declared
  record with no producer or consumer; `/alias` now creates, lists, resolves,
  and removes them. A **pinned** alias stores the offer and revision and means
  the same route across catalog refreshes — reporting an error when that route
  is gone rather than resolving to a neighbour, because a pin that quietly moves
  is not a pin. A **floating** alias stores the selector and re-resolves, and
  records what it landed on so a route stays attributable after the fact; a
  selector matching several routes is an error listing the candidates, not a
  guess. Either policy produces a *pinned* runtime selection, since the alias
  already decided and leaving it auto would let it re-resolve mid-turn against a
  catalog the user never saw.

- Provider lifecycle through the control plane, and a five-vendor capability
  fixture (issue #16). `/providers enable|disable|remove <id>` manages a
  provider instance without editing `config.json` by hand; disabling preserves
  its configuration and credential references — the difference from removing it
  — and excludes it from the *catalog*, so "disabled" is true in the picker,
  `model.list`, and `--provider` at once instead of being re-checked at three
  call sites. A new capability-matrix fixture declares DeepSeek V4, GLM-5.3,
  Kimi K3, GPT-5.6, and MiniMax M3 with timestamped, provider-declared
  capabilities and four different control vocabularies, and asserts what no
  name-inference rule could get right: reasoning supported / unsupported /
  unknown across three models, GLM's peer `reasoning_content` as a separate
  capability, a latency tier on one model and a service tier on another, and
  channel-specific limits narrowing a model's own. New L2 coverage proves a
  control change alters the bytes actually sent (and that leaving it unset
  smuggles no default onto the wire), and that a provider's opaque control
  metadata round-trips through `model.list` into the picker without any core,
  TUI, or Web change.
  A committed route is also broadcast on the existing UI event stream as a
  `config_changed` → `route` event carrying provider, channel, protocol, wire
  model id, offer id, credential reference, and scope — the model name alone
  would announce a change an out-of-process client cannot tell apart from
  another, since one visible name can come from several providers, channels,
  protocols, and accounts. The credential reference travels; the secret does
  not.

- AgentCore ABI v1 revision 15: `session_run_input` gains
  `RUN_INPUT_MULTIMODAL` — an ordered `RunInputPartV1` array of text and
  base64 image parts (per image capped at the Read tool's 3.75 MB raw limit,
  total bounded by the 16 MiB input cap) that becomes one first-class
  multimodal user record with the exact-reservation admission invariant, full
  checkpoint/restore round-trip, and a pre-admission image-capability
  preflight returning the new status
  `METASK_AGENTCORE_STATUS_IMAGE_INPUT_UNSUPPORTED` (28) before any Provider
  request. C header, Zig SDK (`runMultimodal`, `textPart`/`imagePart`), Rust
  bindings, and both source-free consumers move to revision 15 atomically;
  source embedders get `AgentSession.runUserParts` /
  `Conversation.appendUserParts` and the example gains `METACODES_IMAGE`.
  Fixed en route: the provider-neutral canonical request projection (durable
  budget accounting, journal request identity, token estimates) no longer
  re-applies per-model image capability — previously any image run on a
  vision model whose name lacks `claude` (every OpenAI/Gemini model) failed
  inside accounting with `ImageInputUnsupported` before the real request was
  sent (`json.serializeCanonicalRequestProjection`).
- Model tiers (issue #11 core-side fix): subagent/skill model pins and
  `/model` now resolve tier names — `low`/`mid`/`high`, with legacy aliases
  `haiku`/`sonnet`/`opus` mapping to the same tiers — against a per-provider
  table in `~/.metacodes/config.json` (`model_tiers`, keyed by provider kind,
  each tier an optional `{model, effort}`). An unconfigured tier inherits the
  session model/effort; the hardcoded alias→Anthropic-ID map is gone, so a
  tier or alias can never inject a cross-provider model ID — the mechanism
  that made Explore subagents send `claude-3-5-haiku-20241022` to
  OpenAI-compatible relays and fail with an opaque 503 while the parent
  session worked. The built-in `Explore` agent now pins tier `low`
  (previously `haiku`); `/model <tier>` applies the configured tier model and
  keeps the existing cross-provider guard for unresolved literals. Tier
  `effort` rides the existing per-family dialect translation, which now also
  covers MiniMax: M3 gets the native three-state
  `thinking:{type: disabled|adaptive|enabled}` mapping (compat
  `reasoning.effort` strings are accepted upstream but do not tune depth, so
  they are not sent), and M2.x — where thinking is always on — sends only
  `reasoning_split:true` so reasoning arrives as `reasoning_content`.
  OpenAI/Anthropic/GLM/Kimi/DeepSeek translations were already built in.

### Changed

- Language server integration is **on by default**; the new `--no-lsp` turns it
  off (issue #17 follow-on). `--lsp` still works and now simply reasserts the
  default, so existing command lines keep running; the last of `--lsp` /
  `--no-lsp` on the line wins.
  - *Why flip it.* Since `1515b34` removed tree-sitter, `CodeMap`,
    `FindSymbol`, `Read(outline: true)` and Edit/Write post-write diagnostics
    all source symbols from LSP, so an opt-in flag meant the default
    configuration ran four features in a degraded state. The flag was also a
    redundant second gate: the real gate is and remains runtime — a registered
    server for the extension, its binary actually installed, the file inside a
    git workspace, a `root_marker` hit — followed by lazy spawn keyed by
    `server_id+root`, a 10-minute idle reaper, a client-count ceiling and the
    broken-set. On a machine with no language server installed, enabling it
    starts no process at all.
  - *What it costs.* The one newly-involuntary path is post-write diagnostics.
    Measured on this repository with zls: 112 ms cold, 52 ms warm per write.
    The 14 s/26 s constants in `lsp/service.zig` are ceilings for heavier
    servers, not typical values; the disk write itself is never blocked and the
    wait is Ctrl+C-interruptible.
  - *Escape hatch reaches subprocesses.* `--no-lsp` propagates to
    out-of-process teammates, which would otherwise start their own servers
    against the lead's explicit choice.
  - *Not closed by this change.* Subagents still run without LSP:
    `agent_loop.Options.lsp` is deliberately not threaded into child loops
    because `lsp/client.zig` requires `sendRequest`/`sendNotification` from a
    single caller thread while subagents run on background threads, so lifting
    it needs send-side serialization in the Client, not a one-line passthrough.
    For the same reason independent sessions cannot share a `Service`, so each
    out-of-process teammate and each `--serve-multi` daemon session starts its
    own servers; `--no-lsp` is the lever meanwhile.
  - *Rejected.* Enabling by project size — `root_markers` already encode "this
    is a real project", and large trees are exactly where indexing is most
    expensive, so size-as-eagerness is backwards. Auto-installing language
    servers — it contradicts the repository's binary policy, spans six
    unrelated install channels, would execute npm `postinstall` outside the
    permission and sandbox layers, and a version-mismatched server is worse
    than an absent one because nothing signals the error.

### Fixed

- `~/.metacodes/config.json` writes no longer delete other writers' keys. The
  config writer serialized only its own five fields, so any theme change
  silently dropped `mcp_servers`, `permission_rules`, and `model_tiers`. It now
  merges through an order-preserving JSON merge, refuses to overwrite a document
  it cannot parse, and treats a failed read as an error rather than as an empty
  document — descriptor exhaustion or a transient I/O error would otherwise
  truncate the whole file.

- The language server binary lookup is platform-correct, so the LSP subsystem
  is no longer unconditionally dead on Windows. `lsp/servers.zig`'s `which`
  hardcoded three POSIX assumptions — split `PATH` on `:`, join with `/`,
  test executability with `access(X_OK)` — and every one of them fails on
  Windows: `C:\bin;C:\other` split on `:` yields `C`, `\bin;C`, `\other`
  (none of them a directory), and executability there is decided by the
  `PATHEXT` extension list while every registered `ServerDef.binary` is an
  extensionless name (`zls`, `gopls`, `clangd`). Both consumers flow through
  that one function, so they failed together: `Service.getOrSpawn` could never
  start a server, and the issue #17 capability gate `servers.binaryAvailable`
  reported "the '<binary>' language server is not installed (not found in
  PATH)" for every language even when it was installed. This predates issue
  #17; that work only made the failure legible. The lookup now lives in the
  portable layer as `platform.exe_lookup` (separator, joiner, `PATHEXT`
  probing with the cmd.exe default list, quoted `PATH` segments,
  drive-relative names, and no extension appended to a name that already
  carries one), and `which` is a one-line delegation. `realProbe` also stops
  accepting a *directory* as an executable, which plain `access(X_OK)` did on
  POSIX. Empty `PATH` segments are still skipped rather than searching the
  working directory, which POSIX would allow but is a PATH-injection surface.
- `zig build test:platform` ran **zero** tests, and `windows:gate` depends on
  it — so the "Native Windows platform gate" step was passing vacuously for
  its entire unit-test half. `src/platform/platform.zig` aggregated the
  submodules as `pub const x = @import(...)` with no `test` block referencing
  them, and Zig only collects tests from files it analyzes. Adding the block
  turns up 52 tests (43 pass / 9 environment-skipped) that had never run. The
  LSP suite (`test:lsp`) now also runs on that gate, and the workflow's path
  filter covers `src/lsp/**`, since server lookup is native-platform logic.
  Independently of that gate, `ci.yml`'s per-module `zig test
  src/platform/<module>.zig` loops — the unfiltered ones that run on every PR,
  on POSIX and on the Windows runner — now include the new module, so the
  Windows-semantics assertions run on both.

- The new lookup's parsing is a pure function over an explicit `Style` plus a
  supplied `PATH`/`PATHEXT` string, so Windows semantics are asserted on
  **every** host — including the regression case that splitting `C:\bin;C:\other`
  on `:` shreds it — instead of behind a `SkipZigTest` on non-Windows machines.
  `lsp/servers.zig`'s own `which` test likewise stopped skipping on Windows and
  now asserts against `cmd`/`cmd.exe` there and `sh` on POSIX.
  Windows support for the subsystem as a whole is **not** claimed: process
  spawn, pipes, polling and termination already have real Windows
  implementations, but `workspace.isInsideWorkspace` only accepts `/` as a
  path boundary (so every file is judged outside the workspace),
  `client.pathToUri` emits `file://C:\proj\a.zig` where LSP requires
  `file:///c%3A/proj/a.zig`, and `CreateProcess` cannot launch the `.cmd`
  shims npm installs for `typescript-language-server`. Those three are
  enumerated in the status table at the top of `src/lsp/lsp.zig`, which is the
  single place that states Windows readiness.

- Symbol capability gaps no longer masquerade as "symbol not defined"
  (issue #17). `FindSymbol` returned a bare `[]` whenever `--lsp` was on but
  the language server binary was missing, because the *decide* predicate
  (`symbol_provider.hasSymbolsFor`) consulted only the compile-time
  `SERVERS` extension table while the *use* predicate
  (`lsp.Service.getOrSpawn`) additionally resolved the binary, spawned it,
  and consulted the broken-set — a two-state type (`!Symbols`) squeezing a
  three-state reality. The shape was inherited from the tree-sitter era, when
  statically linked grammars made "extension registered" equivalent to
  "capability available"; commit `1515b34` changed the dependency to an
  external runtime process without updating the capability contract.
  The predicate is now single-sourced and runtime-aware
  (`lsp.servers.binaryAvailable`), and the symbol path carries an explicit
  third state (`lsp/capability.zig` `Unavailable{reason, detail}`,
  `symbol_provider.Outcome`, `lsp.Service.fetchSymbols`) with one shared
  wording table. `FindSymbol` now appends a qualifier naming the missing
  binary (and flags partial results when only some candidate files were
  skipped), `CodeMap` prints the specific reason instead of `(no symbols)`,
  and `Read(outline: true)` explains why it fell back to a full read rather
  than degrading silently. When a scan spans several languages the reported
  reason is the most *actionable* one rather than the first encountered — rg
  walks in parallel, so a README that merely mentions the name could otherwise
  make the answer "no language server is registered for this file type" and
  bury the "pyright is not installed" that the caller can act on. The
  per-file capability answer is memoized for the duration of one scan
  (`symbol_provider.CapabilityCache`, caller-owned, no global state): the
  predicate costs a PATH scan — measured at 36–43 µs with a 30-entry PATH —
  and FindSymbol asks it once per candidate file, up to ~3200, for at most
  seven distinct answers. Regression tests cover the **server-absent** side
  unconditionally — synthetic `ServerDef`s with absolute-path binaries make
  that side reachable on any machine, replacing the
  `if (which("zls") == null) return error.SkipZigTest` pattern that had
  skipped exactly the half where the defect lived.

## 0.1.0 — 2026-08-29

### Security

- Third-party GitHub Actions are pinned to full commit SHAs, and the Windows
  Rust bootstrap downloads a version-pinned `rustup-init` verified by SHA-256
  before execution — the action set and the installer are no longer mutable at
  fetch time. (The Rust `stable` toolchain itself stays rustup-managed behind
  the presence guard: it installs once and is not re-resolved per run.)
- `scripts/verify_tinykg_binary.py` now inventories `vendor/tinykg/bin/`:
  an executable not declared by the manifest fails the gate (per-binary
  hashes cannot see extra files).
- The rule-control telemetry artifact no longer records the runner's absolute
  workspace path, and feedback child processes run with secret-named
  environment variables removed (name denylist: `*API_KEY*`, `*ACCESS_KEY*`,
  `*PRIVATE_KEY*`, `*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*CREDENTIAL*`), so
  echoed child environments do not carry those variables into uploaded
  artifacts.
- Prepared the extracted history for removal of a legacy hard-coded provider token
  before any remote publication. Public visibility remains blocked on an
  independent full-history scan and owner-selected project license.

### Added

- The AgentCore bundle now ships ripgrep as a manifest runtime asset
  (issue #8 follow-up): `vendor/ripgrep/` grows a TinyKG-style manifest-pinned
  cross-platform set of upstream official 14.1.1 release binaries
  (macos-aarch64/x86_64, linux-x86_64 musl static, the existing
  windows-x86_64; `aarch64-windows` explicitly maps to the x86_64 executable
  via Windows-on-ARM x64 emulation), verified fail-closed by
  `scripts/verify_ripgrep_binary.py` (SHA-256, format magic, exact `bin/`
  inventory) in CI. `zig build agentcore:bundle` stages the target's binary as
  `bin/rg[.exe]` (SHA-verified by `scripts/stage_ripgrep_binary.py`), records
  it in the manifest `files` allowlist plus a new `runtime_assets` declaration
  (name/version/revision/path/upstream/license/role), and ships the MIT text
  as `bin/ripgrep-LICENSE-MIT`; the source-free consumer validates the asset
  hash and declaration, and a target with no vendored ripgrep fails bundle
  assembly. The toolchain resolver's stale `./vendor/ripgrep/rg` fallback now
  points at the real per-target vendored binaries, so dev/CI checkouts resolve
  rg without a system installation.
- UI-neutral session command surface (issue #3): all raw input now flows
  through one typed pipeline (`session_intent.parse` →
  `SessionService.dispatch` → `RunPlan`), shared verbatim by the terminal
  REPL, `--web`, and the daemon. Web/daemon gain `/commit` `/review` `/init`
  `/retry` `/mode` and `!cmd` over `POST /command` (single- and multi-session
  daemons previously answered 501; they now serve the rich `/state` snapshot
  too), the REPL gains `/mode [name]`, and run-option assembly collapses into
  one canonical `session_service.buildRunOptions` — fixing silent capability
  loss where skill-triggered and injected runs were missing
  agents/skills/MCP/cron wiring, and web runs were missing
  LSP/swarm/background-request wiring. Locked by
  `tests/component/session_api_parity_test.zig`.
- Explicit OpenAI Responses API support: `--openai-protocol
  chat_completions|responses` (alias `chat`; env `METACODES_OPENAI_PROTOCOL`)
  selects the OpenAI wire protocol — never inferred from `--base-url` or the
  model name, and invalid values fail closed. `responses` speaks
  `/v1/responses`: typed SSE events (`response.output_text.delta`,
  `response.output_item.added`, `response.function_call_arguments.*`,
  `response.completed`/`incomplete`/`failed`), `input` items with
  `function_call`/`function_call_output` call_id round-trip, top-level
  `instructions`, flat tools, `reasoning:{effort}` (capped at `high`), and
  `store:false`. Subagents and teammates inherit the parent's protocol choice.
- `metacodes --version` prints `metacodes <semver>`; help banner now names the
  project instead of the legacy internal product name. The semver has one
  in-source authority (`src/version.zig`, consumed by the CLI, `lib.VERSION`,
  and the MCP clientInfo handshake), and `zig build test` asserts the real
  binary's `--version` output against `build.zig.zon` end to end.
- `scripts/eval/plugin_release_gate.py --refresh-implementation-fingerprint`:
  the supported repin path after intentional changes to pinned implementation
  files (previously a hand-patched hex edit); validate paths stay fail-closed.
- `scripts/check_doc_links.py` runs over git-tracked markdown, understands
  link titles/angle destinations and CommonMark fence pairing, and is wired
  into `scripts/test_all_gates.sh` and the AGENTS.md pre-submit list, not just
  CI.
- [ROADMAP.md](ROADMAP.md): project status tracked as milestones with exit
  criteria and evidence links.
- [doc/BENCHMARKS.md](doc/BENCHMARKS.md): consolidated benchmark index —
  local performance gates, internal paired evidence, and the external
  WorkBuddy-Bench mainline with ladder status.

### Changed

- `tools.ToolDispatcher` now resolves every per-name execution metadata query
  through one required `metadataFn` returning `?ToolMeta` (executor kind,
  permission category, replay declaration, prefetch flag); the five per-field
  callbacks (`prefetchSafeFn`/`hostSyncFn`/`builtinFn`/`categoryFn`/
  `replayDeclarationFn`) are removed. Dispatch and metadata share one entry
  lookup, so builtin identity, classification, replay and scheduling flags can
  no longer drift apart across the AgentCore wrapper layers
  (budget/Skill/MCP). Consistency consequences: builtin file tools keep their
  `file_refs`/file-change evidence and Read resolves to a `.read_only` replay
  through wrapped Run surfaces, and Host/MCP tools carry their declared
  executable categories through wrappers (ask in default mode, deny in plan,
  instead of a silent name-based allow). With a Session dispatcher present, a
  name the directory cannot resolve now conservatively classifies as
  `.execute` — never the legacy unknown-name read fallback — and dispatching
  it still fails as UnknownTool. The AgentCore C ABI is unaffected.
- ToolDispatcher metadata hardening: `validateMetadataCoverage()` walks the
  advertised directory and reports the first dispatchable name lacking
  metadata (asserted in Debug at the composed Run surface, so a wrapper that
  adds a name but forgets the metadata branch fails loudly); the session
  budget layer now classifies Tool-vs-MCP operations from the same metadata
  resolution dispatch uses instead of the unfiltered MCP view (a
  selected-but-expired alias no longer reserves under MCP caps while dispatch
  answers UnknownTool; `ToolEnvironment.mcp_view` is removed). The MCP-class
  boundary is now the `.external` executor kind, which also covers the Skill
  overlay tool — with the default equal caps this changes nothing, and the
  taxonomy question is tracked as ledger item E12. The Skill overlay also
  refuses to build over a base surface that already advertises a tool named
  `Skill` (`error.SkillToolNameCollision`) instead of silently shadowing it
  while sending duplicate definitions to the provider.
- CI migrated to self-hosted runners (Linux X64, macOS ARM64, Windows X64)
  with a pinned Lean toolchain build. No GitHub-hosted path remains in the
  workflows; restoring account billing would allow reintroducing hosted
  runners as a fallback matrix (tracked in ROADMAP M1). Pull-request jobs
  carry a fork-isolation guard, and Zig caches live in persistent per-runner
  storage so checkout's workspace clean no longer forces cold rebuilds.
- The CI workflow runs one consolidated `Gates (<platform>)` job per platform
  instead of three jobs queueing on each platform's single runner (the macOS
  test job previously waited ~5 minutes behind its sibling jobs), and Lean
  `.lake` build products persist per runner alongside the Zig caches so the
  kernel stops cold-building every run.
- `leanprover/lean-action` removed from all workflows: on every run it
  executed an unpinned installer streamed from elan's `master` branch on the
  persistent runners (the same class of mutable-fetch-and-execute the rustup
  bootstrap fix closed), cost ~40 s, and the per-run elan reinstall
  invalidated Lake's traces so the kernel rebuilt despite the restored
  `.lake`. elan is now a presence-checked runner prerequisite and CI drives
  `lake build` directly; this also removes two per-run action-tarball
  downloads from job setup, which the macOS runner's GitHub connectivity made
  expensive (a single action download was measured at 2m16s).
- Eight paid-runner L2 cases (seven in
  `scripts/eval/tests/test_memory_budget_runtime.py`, one v7-receipt case in
  `test_memory_agent_runtime.py`) that exercise the production macOS Seatbelt
  runner now skip explicitly off macOS (previously they errored on non-macOS
  hosts, and the child-signal case was mis-gated to POSIX). The macOS CI leg
  still executes them, and the maintainer rule-control gate fails closed on
  any skipped test.
- Documentation governance pass: superseded per-revision AgentCore design
  iterations, dated TUI progress transcripts, and unreferenced U-series drafts
  removed (recoverable from git history); doc index now covers the living
  document set; dangling references from source comments to removed docs
  repaired; `tests/README.md` rewritten to match the real build-step surface.
- `zig build test` now passes on a clean checkout without a Lean toolchain:
  eval cases that require the compiled Lean SDK skip explicitly when
  `control-plane/lean/.lake` is absent. CI builds Lean and sets
  `METACODES_TEST_REQUIRE_LEAN_SDK=1`, which turns that skip into a failure so
  an olean path drift cannot become a permanent silent skip; the guard path
  itself is imported from `project_harness_evolution.SDK_OLEAN_RELATIVE`.
- Extracted `metacodes` as a history-preserving standalone repository whose
  primary branch is `main`.
- Replaced vendored TinyKG source compilation with a manually maintained native
  binary contract: explicit absolute path, operator-observed SHA-256, exact CLI
  version, fresh-store format/schema probe, atomic staging, and deterministic
  provenance receipt.
- Removed ambient TinyKG discovery from runtime and tests. TinyKG-dependent gates
  now fail closed or skip explicitly when no attested binary is injected.
- Added public API, contribution, security, governance, support, third-party, and
  open-source readiness documentation.
- Removed generated evaluation-run artifacts from the published source tree;
  local copies remain ignored and recoverable from the pre-extraction history.

### Fixed

- Glob/Grep runtime dependencies now participate in tool availability
  validation (issue #8): catalog admission probes that the ripgrep executable
  actually resolves (`RG_BIN` → `PATH` → next to the host executable → system
  fallbacks), so Runtime creation fails with a typed
  `error.ToolDependencyUnavailable` — surfaced through the AgentCore ABI as
  `STATUS_INVALID_ARGUMENT` with a diagnostic naming the missing executable
  and the provisioning options — instead of advertising tools to the Provider
  that fail their first invocation with `RipgrepNotFound`. Hosts without `rg`
  select a tool set omitting `Glob`/`Grep` (probe available as
  `util_toolchain.ripgrepPath()`); dependency-free selections are unaffected.
  Locked by deterministic negative/positive tests at the toolchain, catalog,
  Runtime, and ABI layers.
- Plan-mode classification escape on the CLI (no-dispatcher) path: a model
  emitting a case-variant builtin name (e.g. `bash`) was classified by the
  unknown-name read fallback and allowed in plan mode, then deterministically
  repaired to `Bash` at dispatch and really executed. Permission
  classification and rule matching now normalize with the same resolver the
  dispatcher uses, so plan mode denies what will actually run; truly unknown
  names keep the read fallback and the UnknownTool guidance.
- `/retry` after an auto-compact could roll the conversation back past the
  compact boundary, leaving the active window projecting empty (the request
  contained only the compact summary — no user message — and later turns
  stayed hidden behind the stale boundary). The rollback now clamps the
  boundary to the retried user message under the snapshot lock.
- OpenAI streaming hardening (adversarial review of the Responses work): SSE
  lines longer than the 8KB transfer buffer no longer kill the stream with
  `StreamTooLong` — `OpenAIStream` now falls back to the same 16MB-capped
  overflow accumulation the Anthropic path uses, so Responses terminal events
  carrying the full accumulated payload (`response.output_text.done`,
  `response.completed`, `response.function_call_arguments.done`) parse instead
  of forcing a discarded, re-billed turn. Under `protocol=responses`,
  `--response-format` (as top-level `text.format`), `--prompt-cache-key`, and
  `--parallel-tool-calls` are serialized instead of silently no-oping.
  Streamed tool-call `arguments` fragments (chat and Responses) accumulate as
  raw escaped bytes and decode exactly once at flush, so a `\uXXXX` surrogate
  pair split across two deltas no longer becomes two U+FFFD. Responses event
  dispatch no longer trusts the first `"type"` in the raw event (a server
  serializing `item` before the top-level `type` previously dropped the
  function call), and parallel/interleaved Responses tool calls are covered by
  a cassette test.
- Transcript persistence survives `/retry`: the writer's append-only
  assumption broke on rollback (flushed count is monotonic), so a retry that
  shrank and regrew the conversation left the regenerated turn unpersisted
  and resuming the session revived the discarded pre-retry turn. Prefix-
  destroying mutations (retry rollback, compact's wholesale replacement) now
  bump a shrink epoch and the writer atomically rewrites the transcript.
  Semantics note: the transcript is a live-state mirror — after a rewrite,
  tool results that microcompact/truncation had already stubbed in memory
  are stubbed on disk too (resume reproduces what the model actually saw;
  previously microcompacted outputs came back verbatim on resume, and
  combined with a retry rollback the restored history could misalign). A
  no-op retry (nothing rolled back, no boundary clamp) does not trigger a
  rewrite.
- Ctrl+B (background the current session) now rotates the foreground to a
  fresh session id, transcript writer, and cleared goal state. Previously
  the fresh conversation kept the old session's writer and corrupted the
  old transcript (misaligned appends; after the rewrite fix, a prior
  retry/compact in the old session would have made the next flush replace
  it wholesale). The old session's transcript is now sealed as-is and
  stays resumable.
- Task-obligation tracking survives case-variant tool names end to end:
  both the dispatch-side accounting and the result-side met-confirmation
  now key on the canonical name / pending id (a lowercase `bash` call that
  really executed previously left the obligation unmet with a bounded
  spurious nudge).
- `/resume` now clears the active skill before switching session identity:
  previously the next run in the resumed session (e.g. an immediate
  `/retry`) executed under the previous session's skill tool policy, and the
  old skill execution state leaked (unregistered under the wrong id).
- Headless (`-p`) runs now carry the real session id into the agent loop
  (previously the default `single`), so KG task claims/leases from
  concurrent headless processes sharing a store no longer collide on one
  identity.
- `--response-format json_schema` now serializes the API-required
  `format.name` (constant `"response"`) on both the Chat Completions and
  Responses wires; both previously omitted it, so json_schema requests were
  rejected server-side with "Missing required parameter".
- OpenAI-compatible streaming now decodes the JSON string escapes of SSE
  fragments: `delta.content` and `reasoning_content` (GLM/Kimi/DeepSeek/Qwen/
  Mistral) previously reached the conversation and thinking stream as raw
  escaped bytes, so `\n`/`\t`/`\uXXXX` rendered as literals. Both paths (and
  streamed tool-call `arguments`) now share one unescaping extractor in
  `util/json.zig`.

## Historical — Stage 3 parity (2026-05-29, cc-zig line)

REPL / TUI 体验追齐。

### Added
- **History JSONL**：历史改 JSONL（每行一个 JSON 字符串），多行命令可安全 round-trip；自动迁移旧版纯文本。
- **代码块语法高亮**：render.zig 对 fenced code block 做轻量 token 高亮（关键字/字符串/数字/注释），通用关键字集覆盖 zig/c/ts/js/py/rust/go。
- **TAB 补全**：行首 slash 命令补全 + 路径补全（complete.zig）；唯一直接补全，多个列出 + 补到公共前缀。
- **Ctrl+R 反向历史搜索**：实时匹配 + Enter 接受 / Esc 取消。
- **粘贴检测 + 外部存储**：bracketed paste mode；大粘贴（>12 行或 >1600 字节）存 `~/.cc-zig/pastes/<N>.txt` + 插入 `[Pasted text #N +M lines]` 占位符，提交前展开为真实内容（paste.zig）。
- **`/agents` / `/permissions` / `/memory`**：列 sub-agent 能力 / 显示权限模式+规则 / 跨 session 记忆（`~/.cc-zig/memory.md`，`/memory add`）。

## Historical — Stage 2 parity (2026-05-29, cc-zig line)

工具层 P1 语义对齐。

### Added
- **Read 图像**：`.png/.jpg/.jpeg/.gif/.webp` 读为 base64 + media_type，api/request.zig 序列化时发成真正的 image content block（非文本 dump）；3.75MB 上限。
- **Read 设备路径黑名单**：`/dev/zero` `/dev/random` `/dev/fd/*` 等会 hang 的路径直接拒绝。
- **Edit/Write structuredPatch + gitDiff**：返回结构化 hunk（LCS diff，core/patch.zig）+ 标准 unified diff，不再只有 `{"success":true}`。
- **Edit 安全限制**：`MAX_EDIT_FILE_SIZE` 1 GiB 拒绝 + smart-quote 归一化 fallback（文件弯引号 “ ” ‘ ’ ↔ old_string 直引号）。
- **Write 自动建父目录**（mkdir -p 语义）。
- **Skill `allowed_tools` 软约束**：激活带 allowed_tools 的 skill 时在指令顶部注入工具白名单声明（硬隔离待 forked-subagent）。
- **MCP `resources/list` + `resources/read`**：client 方法 + `<server>__list_resources` / `<server>__read_resource` 工具。

## Historical — Stage 0+1 parity (2026-05-29, cc-zig line)

macOS 移植 + Phase A/B 残留补齐（当时的 survey 文档已移出仓库，见 git 历史）。

### Fixed
- **macOS 编译**：`job_registry.zig` 的 `std.c.getrandom`（macOS libc 无此调用）改为读 `/dev/urandom`。
- **macOS 崩溃**：`read_state.zig` 的 `statFd`/`statPath` 之前硬用 Linux `statx`，在 macOS 上对任何已存在文件做 Write/Edit 会 `signal SYS`。改为按 OS comptime 分支（Linux statx / 其它 fstat）。
- 测试中的 `/etc/hostname`（macOS 不存在）改为 `/etc/hosts`。
- **452→459 测试在 macOS 全绿。**

### Added
- **Headless 模式**：`-p "prompt"` / `--print` 单次运行后退出；`-` 从 stdin 读 prompt。
- **`--json`**：headless 下输出 NDJSON result 事件（stop_reason/turns/tool_calls/usage/text）。
- **`/model [name]`**：无参列当前 + 服务端 catalog；有参切换并重建 system prompt + 重算 max_tokens。
- **Grep 全局分页**：`offset` + 全局 `head_limit`（替代之前每文件 `-m`）+ `appliedLimit` 翻页提示。

## Historical — cc-zig v1.0.0 (2026-04-20, legacy internal numbering)

cc-zig 线的首个内部可用版本；该版本号属于历史 cc-zig 项目，与本仓库的
`0.1.0` semver 无关。从 TypeScript 版 Claude Code 移植到当时的 Zig dev 工具链
（现行工具链契约见 `build.zig.zon`）。

### Highlights

- **真流式 SSE**：基于 `std.Io.Reader.takeDelimiter`，首字节延迟与网络实时性一致；不再有 4MB 一次性加载
- **AbortSignal**：Ctrl+C 在 ≤ 250ms 内切断 HTTP stream 和正在运行的子进程（SIGTERM → 2s → SIGKILL，setpgid 防孤儿）
- **6 个内建工具**：Read / Write / Edit / Glob / Bash / Grep，全部对齐 TS 版参数
- **MCP 客户端**：stdio transport + JSON-RPC 2.0，动态注册到 registry
- **Skills 体系**：`~/.cc-zig/skills/<name>/SKILL.md` + 项目级覆盖 + system prompt 注入 + Skill 工具按需激活
- **REPL 增强**：termios raw mode、行编辑（↑↓←→/Home/End/Ctrl+A/E/U/K）、命令历史文件持久化、多行输入（`\` 续行 / `"""` 块）、Markdown 渲染
- **配置持久化**：`~/.cc-zig/config.json`
- **Subagent**：嵌套 agent 执行接口
- **Compact**：对话历史压缩（诚实 MVP：丢最老一半，不假摘要）

### 数据

| 指标 | 值 |
|---|---|
| 测试 | **294/294 绿** |
| ReleaseSmall 二进制 | **588K** |
| 启动时间 | < 10ms |
| 代码行数 | 7434 行 |
| 源文件数 | 44 |
| main.zig | 121 行 |

### 里程碑回顾

| M | 成果 |
|---|---|
| M0 结构重组 | 2432 行单体 → 27 文件分层，消除 `__TOOL_RESULT__:` hack，修复 `unescapeString` 内存 bug |
| M1 真流式 + Abort | EventIterator、AbortSignal、SIGINT、setpgid 子进程清理 |
| M2 工具参数对齐 | ToolContext 签名改造、Read offset/limit、Grep 9 参数、Bash timeout、Edit MultipleMatches |
| M3 权限 | 骨架就绪（M0.6），完整实现延后到沙箱阶段 |
| M4 REPL 增强 | 行编辑、历史、Markdown、多行、/retry / /compact |
| M5 MCP + Skills | stdio transport + JSON-RPC 2.0 + DynRegistry；SKILL.md 加载 + 发现 + 激活 + /skills |
| M6 配置 + Subagent + Compact | config.json 持久化、spawnAgent API、Conversation.compact |
| M7 v1.0 发布 | 全测试绿、文档更新 |

### 已知限制

- 权限系统只做 bypass/plan/deny-dangerous 骨架，完整决策树延后到沙箱版本
- Compact 采用"丢最老一半"策略，不调 API 生成摘要
- 分页（less 风格）未实现
- 语法高亮、文件名 Tab 补全未实现
- Windows/macOS 未验证（开发环境 Linux only）

### 参考

当时引用的架构计划、工作记忆与 TypeScript 原版参考均属 pre-extraction
monorepo,已不在本仓库;需要时从提取前的历史仓库查阅。
