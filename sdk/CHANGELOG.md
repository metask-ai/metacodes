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

- No change a Host can see. The inputs moved for a fix in the CLI's plain headless
  output (#417), which AgentCore does not use.
- The library is rebuilt from a kernel that can edit a user message and rerun
  from it (#432): the shared Conversation gains a rewind that drops a user
  message and everything after it. ABI revision 26 does not expose it, so no
  Host-visible behaviour, layout or status changes; a Session's checkpoint and
  Runs are as before.

### Fixed

- OpenAI Chat Completions, OpenAI Responses and Gemini Runs now retry a
  transient connect failure, a 429 or a 500/502/503 before the response head,
  as Anthropic Messages Runs did: the same request, the same attempt limit and
  backoff, and the same `retry_notice` events (#434).
- A Run cancelled while the response head is awaited stops as cancelled on every
  provider, and an HTTP context-limit rejection from OpenAI or Gemini goes
  through the same context recovery as on Anthropic, so a Run that can shrink
  its request continues instead of stopping with `model_error`
  `context_window` (#434). No ABI or configuration change.

## 0.13.0 — 2026-10-31

### Added

- First formal AgentCore release. The Python and Node packages, the native
  libraries, the header and the Zig and Rust bindings now ship with every
  metacodes release under one final AgentCore version.

### Migration

- Release assets are now named `metask-agentcore-<version>-<target>` with a final
  `<version>`, no longer `<version>-dev+<commit>`. A Host that matched the old
  shape updates its pattern. The ABI's exact-revision rule is unchanged.
