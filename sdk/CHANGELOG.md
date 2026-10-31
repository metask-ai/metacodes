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

### Added

- First formal AgentCore release. The Python and Node packages, the native
  libraries, the header and the Zig and Rust bindings now ship with every
  metacodes release under one final AgentCore version.

### Migration

- Release assets are now named `metask-agentcore-<version>-<target>` with a final
  `<version>`, no longer `<version>-dev+<commit>`. A Host that matched the old
  shape updates its pattern. The ABI's exact-revision rule is unchanged.
