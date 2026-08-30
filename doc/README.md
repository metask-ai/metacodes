# Documentation index

Start here rather than reading design ledgers chronologically.

## Supported contracts

- [API overview](API.md) — supported entry points, ownership, and compatibility.
- [Source-level embedding](LIB_API.md) — Zig Runtime/Session and native delivery.
- [AgentCore binary ABI](AGENTCORE_BINARY_ABI.md) — normative revisioned C ABI.
- [TinyKG integration](TINYKG_INTEGRATION.md) — binary attestation and ownership.
- [Plugin architecture](PLUGIN_ARCHITECTURE.md) — immutable plugin generations.
- [Process plugin protocol](PLUGIN_PROCESS_PROTOCOL.md) — isolated tool packages.
- [Core hot-swap](CORE_PLUGIN_HOTSWAP.md) — first-party profiles and cache rules.

## Kernel design

- [Core reference](CORE_REFERENCE.md)
- [Memory system](MEMORY_SYSTEM_DESIGN.md)
- [Performance and memory principles](PERF_MEMORY_PRINCIPLES.md)
- [UI/backend boundary](UI_DECOUPLE_BACKEND_FRAMEWORK.md)
- [TUI state architecture](TUI_STATE_ARCHITECTURE.md)
- [Swarm design](SWARM_DESIGN.md)
- [Provider offers and control plane](PROVIDER_OFFER_ARCHITECTURE.md) — provider
  profiles, channels, model offers, typed credentials, routing, and persistence.
- [Session service design (U2)](U2_SESSIONSERVICE_DESIGN.md)
- [Daemon tier design (U9/U10)](U9_U10_DAEMON_TIER_DESIGN.md)

## Benchmarks and evaluation

- [Benchmarks](BENCHMARKS.md) — performance gates, internal paired evidence,
  and the external WorkBuddy-Bench mainline with current ladder status.
- [Plugin evaluation](PLUGIN_EVALUATION.md) — plugin kernel v1 evidence record.
- Framework details: [evals/README.md](../evals/README.md),
  [evals/ATTRIBUTION_EVAL.md](../evals/ATTRIBUTION_EVAL.md),
  [scripts/eval/workbuddy/README.md](../scripts/eval/workbuddy/README.md).

## Design history and open ledgers

- [AgentCore experimental ledger](AGENTCORE_V1_EXPERIMENTAL_LEDGER.md) — open
  items gating the future ABI stability freeze (live ledger).
- [MCP transport hard-cut](AGENTCORE_V1_MCP_TRANSPORT_HARDCUT_DESIGN.md)
- [Multi-session refactor](MULTI_SESSION_REFACTOR.md) (historical snapshot)
- [DeepSeek harness analysis](DEEPSEEK_HARNESS_ANALYSIS.md) (historical analysis)
- [Tree-sitter](TREE_SITTER.md) (historical; feature removed)
- `frommetawork/` — inbound consumer requirements behind the shipped
  `output_semantics`/`file_change` contracts.

Documents named `*_PLAN.md`, `*_DESIGN.md`, or `*_LEDGER.md` may describe a
specific implementation phase. They are evidence and rationale, not automatically
the current public contract. For API behavior prefer this index, `API.md`, the
current header/SDK, and executable L2 tests.

Superseded per-revision design iterations and dated progress transcripts are
periodically removed from the tree; recover them from git history when needed.
