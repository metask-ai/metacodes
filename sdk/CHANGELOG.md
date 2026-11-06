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
