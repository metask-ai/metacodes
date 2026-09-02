# Changelog

The standalone repository is versioned per `build.zig.zon`; the first tagged
release is `0.1.0` (2026-08-29). Entries titled **"Historical —"** were
imported from the pre-extraction `cc-zig` line — their version numbers and
dates are historical labels, not release promises of this repository. Current
status, compatibility boundaries, and entry points are defined by
[README](README.md), [ROADMAP](ROADMAP.md), [doc/API.md](doc/API.md), and
[OPEN_SOURCE_READINESS.md](OPEN_SOURCE_READINESS.md).

## Unreleased

### Fixed

- Image tool results larger than the per-result projection bound (64 KiB of
  base64, roughly a 48 KiB picture) reached the provider as a
  `metacodes.tool-result-projection` artifact envelope instead of an image:
  the one-shot tool-result projection ran before the provider dialects and
  spilled the `{"type":"image",...}` payload like any oversized text, so
  `extractImageResult` never matched and Anthropic, OpenAI, and Gemini
  received a base64 preview string. Image-shaped results are now exempt from
  both projection passes and charged against the turn budget at the vision
  token estimate (`IMAGE_TOKEN_ESTIMATE`, the same figure auto-compact uses)
  rather than their base64 length, so one screenshot no longer evicts every
  text sibling from the turn or reports the budget as permanently exhausted.
  Covered end to end by an agent-loop test that reads an 80 KiB-base64 PNG
  through the real `Read` tool and asserts the image block on the wire.
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

## 0.1.0 — standalone extraction and embedding boundary

### Changed

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

### Security

- Prepared the extracted history for removal of a legacy hard-coded provider token
  before any remote publication. Public visibility remains blocked on an
  independent full-history scan and owner-selected project license.

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
