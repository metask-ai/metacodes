# Documentation index

Start here rather than reading design ledgers chronologically.

Run `zig build gate:pr` to execute the single AGENTS.md pre-submit checklist.

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
- [Jev System-One memory advisor](JEV_SYSTEM_ONE.md) — optional judge for
  recall injection, recall evidence, memory relations and enumeration intent.
- [Performance and memory principles](PERF_MEMORY_PRINCIPLES.md)
- [UI/backend boundary](UI_DECOUPLE_BACKEND_FRAMEWORK.md)
- [TUI state architecture](TUI_STATE_ARCHITECTURE.md)
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
