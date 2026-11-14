# AgentCore changelog

AgentCore's own release notes, apart from the main project's `CHANGELOG.md`. It
versions independently (`sdk/VERSION`, SemVer `MAJOR.MINOR.PATCH`), and
`sdk/agentcore-releases.json` maps each release to its binary ABI revision and to
the main-project releases that carry it.

Note a change a Host can see under `## Unreleased`, in `### Added`, `### Changed`,
`### Deprecated`, `### Removed`, `### Fixed` or `### Security`, and what a Host
must do about it under `### Migration`. `scripts/release_cut.py` turns the block
into the release's section and the release notes print it. A cut whose AgentCore
changed refuses an empty block, and one that moves the ABI revision refuses an
empty `### Migration`.

## Unreleased

### Changed

- No change a Host can see. The inputs moved for the Zig `SessionHost`'s model
  resolution and submission journal (#445: tier names and the provider guard
  through `Options.models`, `config_changed` lines, a worded
  `message_rejected`), which the main project's daemon and network Hosts use
  and ABI revision 28 does not expose; the CLI's `/model` and the daemon's
  messages now share that rule (`api/model_availability.zig`).
- No change a Host can see. The Zig `SessionHost` now journals
  `config_changed` for its accepted configuration commands, as the daemon's
  config sink does (#445); ABI revision 28 does not expose `SessionHost`.
- No change a Host can see. The Zig `RuntimeConfig.enable_cron` admits the
  cron tools into a Zig Runtime, and the Zig `SessionHost` fires their
  prompts as Runs (#445); `RuntimeConfigV1` has no such flag, and the cron
  tools stay out of the tools an ABI Runtime admits.
- No change a Host can see. The Zig `SessionHost` reports a Session's cron
  jobs in its `Snapshot`, cancels them by command, and keeps fired cron
  prompts within `max_queued` (#493); ABI revision 28 exposes neither
  `SessionHost` nor the cron tools.
- No change a Host can see. The Zig `SessionConfig.run_control` gives an
  embedded Session's Runs the daemon's project rule gate and abandoned-Run
  policy (#445); `SessionConfigV1` has no such field, and an ABI Session's
  Runs open the journal as before.

### Fixed

- A tool call whose arguments name a key twice (#494), such as `Grep` with
  `"-i"` twice or `Read` with `file_path` twice, no longer ends as
  `permission_denied` (`safety`, `recoverable: false`) in every permission
  mode. It runs nothing and its result is `invalid_args` (`user_error`,
  `recoverable: true`), as are arguments that are not one JSON object; the
  Host's permission callback is not called for it. Whitespace around a
  colon (`"path" : "target.ts"`) now names the same argument for the tool
  as for the permission check: `Grep` searched the whole Workspace for
  that spelling. A key that appears only inside another value, or inside
  an escaped key, is no longer read as a built-in tool's argument, so a
  `Write`/`Edit` call spelled that way now gets the `file_target`
  candidate for the file it really writes.
- A Run on `kimi-for-coding` (the Kimi Code subscription's K2.8 Preview) over
  the OpenAI chat wire sends the thinking parameter Kimi Code documents
  (#487): an active reasoning effort goes out as the top-level
  `reasoning_effort` in Kimi's `low` / `high` / `max`, and no effort, `none`
  or `minimal` sends nothing, so the server's own default applies. It used to
  send K2.7-code's `"thinking":{"type":"enabled","keep":"all"}` and no
  effort. `kimi-for-coding-highspeed` and the Moonshot open platform's
  models send the bytes they did. No ABI change.

## 0.15.0 — 2026-11-13

### Added

- Edit and rerun (#441): `session_control->rewind_to_user_message(session,
  position, out_error)`, idle-only. It drops the user message at the 1-based
  `position` (counted over the full history, as `describe`'s
  `conversation.message_count` counts; a Run's own message is `message_count +
  1` read just before it) and everything after it: later prompts, replies,
  tool calls and tool results. The next Run's input takes its place after
  exactly the context before it, so its request is a prefix of the earlier ones
  plus the new input. Only the Conversation changes: files and other effects of
  the dropped turns stay, and model, permission policy, grants, Skill, MCP,
  goal and prompt profile are untouched. A checkpoint exported afterwards holds
  the edited Conversation, and a restored Session continues from it.
- Statuses 31 `MESSAGE_POSITION_OUT_OF_RANGE`, 32 `NOT_USER_MESSAGE` (an
  assistant reply, a tool result or runtime-written text) and 33
  `MESSAGE_POSITION_COMPACTED` (behind the compact boundary) refuse a position
  and change nothing; zero is `INVALID_ARGUMENT`, a Run or other facade call in
  progress `BUSY`.
- Python `Session.rewind_to_user_message(position)` and Node
  `Session.rewindToUserMessage(position)`.
- A stream retry budget (#452): `RunOptionsV1.stream_retry_budget`, 0 to
  `MAX_STREAM_RETRY_BUDGET_V1` (8), default 0. A Run may send the same request
  again that many times when its accepted stream broke off without an answer
  (a stall, a dropped connection, a stream that ended before its stop report),
  after it had already shown output too; an error the server declared in the
  stream and a local decode failure are never re-sent. The budget is the
  Run's, across its turns, and comes on top of each request's own re-send
  (see Changed).
  A value above 8 is `RESOURCE_LIMIT`, a nonzero `reserved0` beside it
  `INVALID_ARGUMENT`, both before admission. A re-sent attempt never finds the
  abandoned attempt's speculative tool results: a call it repeats runs, even
  under the same id.
- The `thinking_discarded` observation event: `{index, turn, group, bytes}`
  names the thinking a re-sent attempt showed while segment `index` was open,
  for the Host to take back as it drops that segment's `discarded` text. Each
  such re-send also emits `retry_notice` (`attempt` = this request's streams
  broken off so far, `max` = the most attempts the request may make,
  `delay_ms` = the backoff before the re-send) and the `retrying` RunState
  phase. `model_error.attempts` counts re-sends like connection retries.
- Python `Session.run(..., stream_retry_budget=)` / `stream(...)` and Node
  `run(prompt, { streamRetryBudget })` / `stream(...)`.

### Changed

- Every model request is sent once more by itself after a transient stream
  interruption, with no budget set (#461). When an accepted stream broke off
  without an answer (a stall, a dropped connection, a stream that ended before
  its stop report) and the failed response had not started a tool call, not
  even one whose arguments were still streaming, the Run discards everything
  the attempt produced, text and thinking alike, and sends the identical
  request again. The allowance is the request's, not the Run's: an earlier
  turn's re-send never uses up a later one's, and it replaces the one re-send
  per Run an attempt that showed nothing used to get. A re-send of an attempt
  that showed output is announced like a budgeted one (`discarded` segment,
  `thinking_discarded`, `retry_notice`) and waits a short backoff (500 ms,
  `retry_notice.delay_ms`), during which an abort ends the Run `aborted`
  without sending it. Before, a zeroed `RunOptionsV1` ended such a Run with
  `api_error` and `attempts: 1`; when the re-send is cut too, `attempts` is
  now 2. An error the server declared, a local decode failure and a cut
  during a tool call are still sent once. Budgeted re-sends now wait the same
  backoff, and their `retry_notice` counts this request's streams.

### Fixed

- A Run whose accepted stream ended cleanly before it said how it stopped (no
  stop reason, finish reason or terminal event) now delivers `model_error` with
  `category` `stream_interrupted` and `retry` `retryable`, that response's
  `http_status` and `request_id`, and the message "The response stream ended
  before it reported how it stopped." (#451). It used to be `unknown` /
  `unknown` with "The response stream could not be read: StreamIncomplete."
  The same-turn resend when nothing had been shown, `attempts`, and the absence
  of a `model_error` after a resend that succeeds are unchanged. No ABI change.

### Migration

- ABI revision 27. The Session Control table grows from 80 to 88 bytes with
  `rewind_to_user_message` as its last slot, and discovery requires it, so a
  Host built for revision 26 is refused at the revision check. Rebuild against
  the revision 27 header and bindings; nothing else changes for a Host that
  does not call the new slot.
- ABI revision 28. `RunOptionsV1` stays 40 bytes; its last reserved word is now
  `uint32_t stream_retry_budget` (offset 32) and a zero `uint32_t reserved0`
  (offset 36). A Host built for revision 27 is refused at the revision check;
  rebuild against the revision 28 header and bindings. A Host that does not
  set the budget still sees `thinking_discarded` and `retry_notice` when a
  request's own re-send (#461) withdraws an attempt that showed output; drop
  the `discarded` segment's text and the thinking `thinking_discarded` names.

## 0.14.0 — 2026-11-06

### Changed

- A Run now compacts its own Conversation and continues under the same Run ID
  when context pressure would otherwise stop it (#430): the model's input
  window, a provider's context-window refusal, and checkpoint capacity
  (`soft_bytes`, or a request that would not fit under `hard_bytes`). The
  summary request is budgeted and accounted like any request; the replacement
  commits only if its checkpoint fits beside every live reservation. Recovery is
  bounded and stops with `STOP_API_ERROR` (`model_error` category
  `context_window`) or the checkpoint budget terminal, whose terminal
  `run_state` phase is `failed` (only a cancellation is `aborted`). Committed
  tool results are never cleared or truncated in place. `auto_compact` reports
  the new causes `durable_capacity_threshold` and `durable_capacity_recovery`.
- No change a Host can see. The inputs moved for a fix in the CLI's plain headless
  output (#417), which AgentCore does not use.
- The library is rebuilt from a kernel that can edit a user message and rerun
  from it (#432): the shared Conversation gains a rewind that drops a user
  message and everything after it. ABI revision 26 does not expose it, so no
  Host-visible behaviour, layout or status changes; a Session's checkpoint and
  Runs are as before.
- No change a Host can see. The inputs moved for the native Amazon Bedrock
  transport (#423), which ABI revision 26 does not expose: `provider` never
  reports it, and Runs on the exposed wires send the bytes they did.

### Fixed

- A Run on MiniMax, Kimi or DeepSeek over the OpenAI chat wire sends the thinking
  parameters those vendors document today (2026-11): MiniMax M3 `thinking.type`
  `adaptive` instead of `enabled`, M3.1 its `reasoning_effort`, every MiniMax
  model `reasoning_split`; no `effort` inside Kimi K2.6's `thinking` object, and
  never `disabled` to K2.7-code; DeepSeek `low` as `low`. A Run on Kimi K2 with no
  reasoning effort set no longer crashes. Other models' requests are unchanged.
  No ABI change.
- A Run on DeepSeek, Kimi or MiniMax M3 and later sends the model's earlier
  reasoning back (#421). The request after a tool call used to drop it, so
  DeepSeek in thinking mode answered HTTP 400 and Kimi and MiniMax lost their
  reasoning. On OpenAI chat they now get `reasoning_content` on assistant
  messages; a route declaring DeepSeek on the Anthropic wire gets its thinking
  blocks. Other models' requests are unchanged, and Claude is never sent an
  unsigned thinking block. No ABI change.
- A Run on a Mistral model over the OpenAI chat wire asks for reasoning in the
  model's `reasoning_effort` vocabulary (Small 2603 and Medium 3.5 `none` /
  `high`, Large 4 `low` / `medium` / `high`), streams its ThinkChunks as thinking
  instead of dropping them and the first answer text that arrives with them, and
  sends earlier reasoning back as ThinkChunks (#437). Other models' requests are
  unchanged. No ABI change.
- OpenAI Chat Completions, OpenAI Responses and Gemini Runs now retry a
  transient connect failure, a 429 or a 500/502/503 before the response head,
  as Anthropic Messages Runs did: the same request, the same attempt limit and
  backoff, and the same `retry_notice` events (#434).
- A Run cancelled while the response head is awaited stops as cancelled on every
  provider, and an HTTP context-limit rejection from OpenAI or Gemini goes
  through the same context recovery as on Anthropic, so a Run that can shrink
  its request continues instead of stopping with `model_error`
  `context_window` (#434). No ABI or configuration change.

### Migration

- A Host that compacted and replayed the instruction after a context-window
  stop no longer needs to; it should accept `auto_compact` events (and the
  `compacting` RunState phase) inside a Run and causes it does not know.

## 0.13.0 — 2026-10-31

### Added

- First formal AgentCore release. The Python and Node packages, the native
  libraries, the header and the Zig and Rust bindings now ship with every
  metacodes release under one final AgentCore version.

### Migration

- Release assets are now named `metask-agentcore-<version>-<target>` with a final
  `<version>`, no longer `<version>-dev+<commit>`. A Host that matched the old
  shape updates its pattern. The ABI's exact-revision rule is unchanged.
