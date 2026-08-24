# metacodes

Metacodes is an embeddable, low-resource agent core and coding CLI written in Zig.
It owns a fixed agent loop, deterministic provider projection, permission and
sandbox enforcement, durable tool-result artifacts, Lean-backed governance, and
optional TinyKG memory/task coordination. Hosts can extend tools, provider
dialects, UI, MCP, and process plugins without replacing those kernel boundaries.

> Repository status: pre-publication. The history has been extracted from the
> original monorepo, but the project license is still an owner decision. Keep the
> repository private until [OPEN_SOURCE_READINESS.md](OPEN_SOURCE_READINESS.md)
> is cleared.

## Why metacodes

- One native binary, no language runtime, fast startup, and explicit allocators.
- A built-in coding agent loop rather than a framework that delegates correctness
  to arbitrary hooks.
- Immutable plugin generations and append-only provider context, preserving prompt
  cache stability when the effective model-visible configuration is unchanged.
- Tool results share one typed inline/artifact/error data plane across CLI,
  plugins, MCP, and AgentCore embedding.
- Formal decisions stay in the kernel; TinyKG stores governed memory, task DAGs,
  receipts, and provenance but does not become the agent loop.
- Source-level Zig embedding and a source-free C ABI bundle for C, C++, Zig, Rust,
  Go, and other native hosts.

## Build

The checked-in toolchain contract currently requires Zig 0.16.0 or newer within
the 0.16 development line used by CI.

```sh
git clone https://github.com/shuzuan-org/metacodes.git
cd metacodes
zig build
./zig-out/bin/metacodes --help
```

The default build does not download or compile TinyKG. It selects one
manifest-pinned CLI from the checked-in cross-platform binary bundle and stages
it beside Metacodes. `highlight-zig` remains the only checked-in source
dependency. See [TinyKG integration](doc/TINYKG_INTEGRATION.md) for the supported
matrix, provenance contract, explicit override, and manual update procedure.

Common gates:

```sh
zig build test
zig build test:lib -Doptimize=ReleaseSafe
zig build agentcore:test -Doptimize=ReleaseSafe
zig build agentcore:gate -Dtarget=<native-target> -Doptimize=ReleaseSafe
```

Maintainers can audit a candidate binary instead of the bundled one:

```sh
tinykg_bin=/absolute/path/to/tinykg
tinykg_sha=$(shasum -a 256 "$tinykg_bin" | awk '{print $1}')
zig build test \
  -Dtinykg-bin="$tinykg_bin" \
  -Dtinykg-sha256="$tinykg_sha"
```

Normal tests use the native bundled artifact automatically. No build, test, or
release gate searches `PATH`, downloads TinyKG, inspects a sibling checkout, or
uses an old `zig-out` artifact.

## Supported surfaces

| Surface | Audience | Compatibility |
|---|---|---|
| CLI / headless / Web host | Operators and local products | Pre-1.0 command surface |
| `metacodes-core` Zig module | Same-toolchain Zig hosts | Source API, experimental |
| AgentCore C ABI v1 revision 13 | Source-free native hosts | Exact-revision bundle pinning |
| Static and process plugins | Trusted in-process and isolated tools | Versioned plugin contracts |
| Provider dialects | Model-family request/response adaptation | Deterministic, trusted plugins only |

Start at [doc/API.md](doc/API.md). The normative AgentCore ABI contract is
[doc/AGENTCORE_BINARY_ABI.md](doc/AGENTCORE_BINARY_ABI.md); the plugin contracts
are indexed in [doc/README.md](doc/README.md).

## Architecture

```text
Host / CLI / Web / native SDK
              |
      immutable Runtime generation
              |
  +-----------+--------------------+
  | fixed AgentLoop and Conversation|
  | permission / sandbox / budget   |
  | tool artifact and durable effect|
  | Lean governance / TinyKG boundary|
  +-----------+--------------------+
              |
  tools / MCP / plugins / provider dialects
```

The model-visible request is a deterministic projection of effective tools,
conversation state, and provider dialect. Plugin ids, load paths, generations,
timestamps, journals, and TinyKG receipts do not enter the prompt. An equivalent
runtime replacement therefore keeps provider-visible bytes stable; only a real
capability or context change invalidates the cache prefix.

## TinyKG boundary

TinyKG is a separately maintained executable and storage engine. Metacodes owns:

- when memory or task evidence is proposed;
- Lean/policy admission and re-observation;
- commit, rollback, budget, and user-visible receipts;
- runtime transport selection and degraded behavior.

TinyKG owns its binary/storage implementation, authenticated daemon protocol,
generation/CAS primitives, and graph persistence. Metacodes never imports TinyKG
source and never silently falls back from the daemon to a shared raw store.

## Contributing and security

Read [AGENTS.md](AGENTS.md) before changing code, then
[CONTRIBUTING.md](CONTRIBUTING.md). Security reports must follow
[SECURITY.md](SECURITY.md), not public issues. Paid benchmark runs require explicit
authorization and are never part of the default development loop.

## 中文简介

metacodes 是一个可嵌入、极低资源占用、内置 coding agent loop 的 Zig agent core。
插件可以扩展工具、MCP、provider 方言和宿主形态，但不能绕过权限、预算、形式化判定、
TinyKG 治理与因果边界。TinyKG 采用独立维护、跨平台、哈希锁定的二进制 bundle，
不再把源码复制进本仓库，也不会在构建时下载或隐式寻找开发目录。
项目目前处于开源发布前准备阶段；在许可证由项目所有者明确选定前，仓库应保持私有。
