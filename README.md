# metacodes

> **s = super** —— 用 Zig 从零重写的 agentic 编码 CLI(Claude Code 同级),原生编译、零运行时、编译期类型安全。

单二进制、亚百毫秒启动的终端 agent:驱动 Anthropic / OpenAI / Gemini 模型跑工具循环,做真实的读写代码、执行命令、多 agent 协作。

## 状态

✅ **可用** —— 完整 agent 循环 + 工具系统 + 权限沙箱 + TUI + 多 provider,~1900 单测 + 组件/e2e 测试全绿。

## 构建与运行

```bash
git clone <repo>                             # 无 submodule:依赖源码已 vendored 在 lib/
cd metacodes
zig build                                     # 产出 zig-out/bin/metacodes + zig-out/vendor/tinykg/tinykg
./zig-out/bin/metacodes --api-key <KEY>
```

**零下载依赖**:`highlight-zig`(高亮)与 `tinykg`(KG 记忆引擎)的源码作为**快照 vendored 在 `lib/`**(非 submodule,因更新频度低——plain clone 即可构建)。`zig build` 从这份源随 `-Dtarget` **交叉编译**它们:tinykg 装到 `zig-out/vendor/tinykg/tinykg`。更新依赖用 `scripts/vendor-deps.sh`。跳过 tinykg 构建:`-Dtinykg=false`。

常用构建目标:

| 目标 | 作用 |
|------|------|
| `zig build` | 主二进制 `metacodes` |
| `zig build test` | 全量单测 + 组件测试 |
| `zig build test -Dtfilter="<子串>"` | 隔离单测 |
| `zig build test:lib` | 验证 `metacodes-core` 库的 UI 隔离(编译器证明) |
| `zig build agentcore:test` | AgentCore 二进制 ABI v1 契约测试 |

## 功能

- **Agent 循环** —— 多轮工具调用、流式 SSE、auto-compact、熔断
- **工具** —— Read / Write / Edit / Bash / Grep / Glob / WebSearch / WebFetch / MCP / LSP / NotebookEdit / Task(子 agent) 等
- **权限 + 沙箱** —— 6 模式 + Tool(specifier) 细粒度规则 + 5 层 settings;macOS Seatbelt 真沙箱拦 cwd 外写
- **TUI** —— 工具卡两态、diff 语法高亮、状态行、plan 审批、AskUserQuestion 向导、Ctrl+O inline 视图
- **多 provider** —— Anthropic / OpenAI / Gemini 经中立 Provider vtable + capability 门控,三家缓存范式归一
- **Agent swarm** —— teams / teammates,文件邮箱传消息 + tinykg DAG 协调任务;进程内线程 + 进程外 worktree 两种 teammate
- **形态** —— 交互 REPL / headless `-p` / `--web` 浏览器前端 / daemon serve;皆驱动同一 agent 循环
- **跨会话记忆** —— tinykg 图数据库集成(记忆 / 计划 / 任务 DAG)

## 架构

```
metacodes/
├── build.zig / build.zig.zon   # 构建 + 包清单
├── src/
│   ├── core/                   # agent 循环、协议、transcript、记忆…(库核心)
│   ├── tools/  tools.zig       # 工具实现 + 注册表
│   ├── permission/  sandbox/   # 权限决策链 + Seatbelt 沙箱
│   ├── api/  client.zig        # provider 客户端(HTTP + streaming)
│   ├── repl/                   # TUI / 输入 / 状态机(仅表达层)
│   ├── swarm/                  # teams / teammates 子系统
│   ├── daemon/  web/           # 进程外形态
│   ├── lsp/  mcp/  kg/         # 协议集成
│   ├── platform/               # 可移植系统抽象(POSIX + NT 双后端)
│   ├── agentcore/              # C ABI v1 边界(见下)
│   └── lib.zig                 # metacodes-core 库 root
├── lib/                        # vendored 依赖【源码快照】(非 submodule),build.zig 交叉编译
│   ├── highlight-zig/          #   纯 Zig 语法高亮库
│   └── tinykg/                 #   KG 记忆/计划/DAG 引擎(subprocess CLI)
├── sdk/                        # AgentCore C 头 + Zig SDK
└── example/                    # metacodes-core 库消费示例
```

## 库形态:两条消费路径

agent 循环核心可作为库被外部消费:

| 消费方 | 用什么 | 序列化开销 |
|--------|--------|-----------|
| 同进程 Zig | `metacodes-core` 模块(`b.addModule`) | **零**(直传 CoreEvent 结构) |
| source-free Zig | `metacodes_agentcore` 静态库 + typed Zig SDK | AgentCore protocol v1 JSON |
| C / Rust / 跨版本 | `metacodes_agentcore` 静态库 | 富数据 JSON,配置 POD 结构 |

C ABI(`sdk/metacodes_agentcore.h`)刻意只导出单入口 `metacodes_agentcore_get_api(abi_version)`,返回函数指针表(vtable):`runtime_create/destroy`、`session_create/destroy`、`session_run`(agent 循环)、`session_abort`、`buffer_release`。ABI v1 已于 2026-07-17 冻结，要求精确结构体大小与 reserved 全零；bug/security fix 必须保持 v1 可观察行为，任何扩展新增 v2 table，不能静默修改 v1。事件/UI JSON 由独立 AgentCore protocol v1 定义，不直接暴露内部 frontend/daemon `CoreEvent`；未知观察事件可忽略，UI/control 消息严格校验。完整契约见 `doc/AGENTCORE_BINARY_ABI.md`。

## 技术栈

| 组件 | 技术 |
|------|------|
| 语言 | Zig 0.16-dev |
| 内存 | 命名 allocators(gpa / arena / scratch / c_allocator) |
| 高亮 | highlight-zig(纯 Zig submodule,取代 tree-sitter) |
| 记忆 | tinykg 图数据库(子进程 CLI) |
| 沙箱 | macOS Seatbelt SBPL |
| 跨平台 | platform/ 抽象层(POSIX + NT),Windows 交叉编译门 |
