# Changelog

The standalone repository is versioned per `build.zig.zon`; no release has
been tagged yet. Entries titled **"Historical —"** were imported from the
pre-extraction `cc-zig` line — their version numbers and dates are
historical labels, not release promises of this repository. Current status,
compatibility boundaries, and entry points are defined by
[README](README.md), [ROADMAP](ROADMAP.md), [doc/API.md](doc/API.md), and
[OPEN_SOURCE_READINESS.md](OPEN_SOURCE_READINESS.md).

## Unreleased

### Security

- Third-party GitHub Actions are pinned to full commit SHAs, and the Windows
  Rust bootstrap downloads a version-pinned `rustup-init` verified by SHA-256
  before execution — nothing unpinned executes on the persistent self-hosted
  runners.
- `scripts/verify_tinykg_binary.py` now inventories `vendor/tinykg/bin/`:
  an executable not declared by the manifest fails the gate (per-binary
  hashes cannot see extra files).
- The rule-control telemetry artifact no longer records the runner's absolute
  workspace path, and feedback child processes run with secret-shaped
  environment variables (`*API_KEY*`, `*TOKEN*`, `*SECRET*`, …) removed, so
  echoed child output cannot leak credentials into uploaded artifacts.

### Added

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

- CI migrated to self-hosted runners (Linux X64, macOS ARM64, Windows X64)
  with a pinned Lean toolchain build. No GitHub-hosted path remains in the
  workflows; restoring account billing would allow reintroducing hosted
  runners as a fallback matrix (tracked in ROADMAP M1). Pull-request jobs
  carry a fork-isolation guard, and Zig caches live in persistent per-runner
  storage so checkout's workspace clean no longer forces cold rebuilds.
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

## Unreleased — standalone extraction and embedding boundary

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
