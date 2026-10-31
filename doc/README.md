# Documentation index

Start here rather than reading design ledgers chronologically.

## Start here

- **Using metacodes:** [Getting started](GETTING_STARTED.md) — install,
  providers, Metask OAuth, build from source; [Terminal setup](TERMINAL_SETUP.md)
  — Shift+Enter for a newline in Apple Terminal and VS Code.
- **Embedding it in your program:** [API overview](API.md), then
  [LIB_API](LIB_API.md) for Zig hosts or the
  [AgentCore binary ABI](AGENTCORE_BINARY_ABI.md) and [SDK](../sdk/README.md)
  for C, C++, Rust and FFI hosts.
- **Contributing:** [CONTRIBUTING](../CONTRIBUTING.md) for where to start,
  [AGENTS](../AGENTS.md) for the engineering contract, and
  [tests/README](../tests/README.md) for the test layers.
- **Evaluating it:** [Benchmarks](BENCHMARKS.md) and the evaluation framework
  in [evals/README.md](../evals/README.md).

Run `zig build gate:pr` to execute the single AGENTS.md pre-submit checklist.

## Supported contracts

- [API overview](API.md) — supported entry points, ownership, and compatibility.
- [Source-level embedding](LIB_API.md) — Zig Runtime/Session and native delivery.
- [AgentCore binary ABI](AGENTCORE_BINARY_ABI.md) — normative revisioned C ABI.
- [Wire protocol v1](WIRE_PROTOCOL.md) — versioned JSON lines for cross-process
  frontends, the capability exchange, and the additive/breaking change policy.
- [Observability](OBSERVABILITY.md) — OpenTelemetry span tree per Run (GenAI
  semantic conventions), OTLP/HTTP export from the standard `OTEL_*`
  variables, the session span store and the web trace view.
- [TinyKG integration](TINYKG_INTEGRATION.md) — binary attestation and ownership.
- [Plugin architecture](PLUGIN_ARCHITECTURE.md) — immutable plugin generations.
- [Process plugin protocol](PLUGIN_PROCESS_PROTOCOL.md) — isolated tool packages.
- [Core hot-swap](CORE_PLUGIN_HOTSWAP.md) — first-party profiles and cache rules.
- [Skills and MCP servers](SKILLS_AND_MCP.md) — Skill and MCP discovery from
  metacodes, Claude Code and Codex directories; MCP 2026-07-28 client.
- [Sealed Skill Protocol](SEALED_SKILL_PROTOCOL.md) — SSP/1: a Skill that
  runs on a gateway with its tool calls executed, approved and paid for on
  the client; `metacodes sealed install|list|bind|unbind|ledger|serve`.

## Kernel design

- [Sealed gateway at scale](SEALED_GATEWAY_SCALE_DESIGN.md) — worker pool,
  admission, route-keyed provider cache, SSE keepalive, the load benchmark
  and the numbers that are the claim.
- [Core reference](CORE_REFERENCE.md)
- [Stall gate](STALL_GATE_DESIGN.md) — the in-run breaker for tool rounds that
  keep returning nothing new.
- [Isolated verifier](ISOLATED_VERIFIER_DESIGN.md) — design only: an LLM
  verifier in a fresh context on a git-isolated snapshot as a second verdict
  source after a green pinned check; demote-only provenance and the
  pre-registered check-gate v3 replay.
- [Memory system](MEMORY_SYSTEM_DESIGN.md)
- [Learning turn](LEARNING_TURN_DESIGN.md) — post-verdict
  distill-and-reconcile turn that turns a check verdict into conditioned
  lessons; in-run path implemented, CLI flags pending.
- [Learned-artifact gate](LEARNED_ARTIFACT_GATE_DESIGN.md) — design only:
  the paired, model-stratified evidence a lesson policy, recall shape,
  obligation or provisional rule needs to become active or to retire, with
  the pre-registration draft for the first use case.
- [Jev System-One memory advisor](JEV_SYSTEM_ONE.md) — optional judge for
  recall injection, memory relations and enumeration intent.
- [Jev × Harness 接入方案](JEV_HARNESS_INTEGRATION_DESIGN.md) — historical
  Codex proposal (JevTree-style next-action advisor) that JEV_SYSTEM_ONE.md §5
  adopts, defers or rejects point by point; not the current behaviour.
- [Performance and memory principles](PERF_MEMORY_PRINCIPLES.md)
- [UI/backend boundary](UI_DECOUPLE_BACKEND_FRAMEWORK.md)
- [TUI state architecture](TUI_STATE_ARCHITECTURE.md)
- [TUI viewport ownership](TUI_VIEWPORT_OWNERSHIP.md) — ADR: only the
  Renderer erases the screen or writes past the inline region; ED 0 only,
  no saved cursor, the half-line snapshot; enforced by
  `zig build test:scrollback`.
- [Swarm design](SWARM_DESIGN.md)
- [Provider offers and control plane](PROVIDER_OFFER_ARCHITECTURE.md) — provider
  profiles, channels, model offers, typed credentials, routing, and persistence.

## Benchmarks and evaluation

- [Benchmarks](BENCHMARKS.md) — performance gates, internal paired evidence,
  and the external WorkBuddy-Bench mainline with current ladder status.
- [Plugin evaluation](PLUGIN_EVALUATION.md) — plugin kernel v1 evidence record.
- Framework details: [evals/README.md](../evals/README.md),
  [evals/ATTRIBUTION_EVAL.md](../evals/ATTRIBUTION_EVAL.md),
  [scripts/eval/workbuddy/README.md](../scripts/eval/workbuddy/README.md).

## Build, CI and release

- [CI design](CI_DESIGN.md) — required checks, the change scope that skips
  suites a change cannot affect, and the merge queue that tests a batch of
  PRs once.
- [Release automation](RELEASE_AUTOMATION_DESIGN.md) — version bumping,
  cutting, tagging, publishing, and the CI fast path for release PRs.
- [`metacodes update`](UPDATE_DESIGN.md) — bring an install up to date from
  where it came from (a release, a recorded mirror, or its checkout) by
  delegating to that source's own installer; running sessions, the TinyKG
  pin, Windows, convergence after a failed run.

## History

- `doc/history/AGENTCORE_V1_REVISION14_PLUGIN_ABI_PLAN.md` — revision 14 plugin ABI plan.
- `doc/history/AGENTCORE_V1_MCP_TRANSPORT_HARDCUT_DESIGN.md` — MCP transport hard-cut design.
- `doc/history/MULTI_SESSION_REFACTOR.md` — multi-session refactor design.
- `doc/history/DEEPSEEK_HARNESS_ANALYSIS.md` — DeepSeek harness analysis.
- `doc/history/U2_SESSIONSERVICE_DESIGN.md` — U2 session service design.
- `doc/history/U9_U10_DAEMON_TIER_DESIGN.md` — U9/U10 daemon tier design.
- `doc/history/inbound/` — inbound consumer requirements (formerly `doc/frommetawork/`)
  behind the shipped `output_semantics`/`file_change` contracts.

History files are records, not contracts; they are outside `release/doc_facts.json`, and no supported entry point may cite them as authority.

## Design history and open ledgers

- [AgentCore experimental ledger](AGENTCORE_V1_EXPERIMENTAL_LEDGER.md) — open
  items gating the future ABI stability freeze (live ledger).

Documents named `*_PLAN.md`, `*_DESIGN.md`, or `*_LEDGER.md` may describe a
specific implementation phase. They are evidence and rationale, not automatically
the current public contract. For API behavior prefer this index, `API.md`, the
current header/SDK, and executable L2 tests.

Superseded per-revision design iterations and dated progress transcripts are
periodically removed from the tree; recover them from git history when needed.
