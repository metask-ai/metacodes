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
- [Swarm design](SWARM_DESIGN.md)

Documents named `*_PLAN.md`, `*_DESIGN.md`, or `*_LEDGER.md` may describe a
specific implementation phase. They are evidence and rationale, not automatically
the current public contract. For API behavior prefer this index, `API.md`, the
current header/SDK, and executable L2 tests.
