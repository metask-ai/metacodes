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

## 0.13.0 — 2026-10-31

### Added

- First formal AgentCore release. The Python and Node packages, the native
  libraries, the header and the Zig and Rust bindings now ship with every
  metacodes release under one final AgentCore version.

### Migration

- Release assets are now named `metask-agentcore-<version>-<target>` with a final
  `<version>`, no longer `<version>-dev+<commit>`. A Host that matched the old
  shape updates its pattern. The ABI's exact-revision rule is unchanged.
