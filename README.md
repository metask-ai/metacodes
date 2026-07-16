# metacodes

> **s = super** —— 用 Zig 从零重写的 agentic 编码 CLI(Claude Code 同级),原生编译、零运行时、编译期类型安全。

单二进制、亚百毫秒启动的终端 agent:驱动 Anthropic / OpenAI / Gemini 模型跑工具循环,做真实的读写代码、执行命令、多 agent 协作。

## 状态

✅ **可用** —— 完整 agent 循环 + 工具系统 + 权限沙箱 + TUI + 多 provider,~1900 单测 + 组件/e2e 测试全绿。

## 构建与运行

```bash
git clone --recurse-submodules <repo>        # highlight-zig 走 submodule
# 或已 clone 后:
git submodule update --init metacodes/lib/highlight-zig

cd metacodes
zig build                                    # 产出 zig-out/bin/metacodes
./zig-out/bin/metacodes --api-key <KEY>
```

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
├── lib/
│   └── highlight-zig/          # git submodule:纯 Zig 语法高亮库
├── sdk/                        # AgentCore C 头 + Zig SDK
├── vendor/                     # 冻结第三方(ripgrep / tinykg 二进制)
└── example/                    # metacodes-core 库消费示例
```

## 库形态:两条消费路径

agent 循环核心可作为库被外部消费:

| 消费方 | 用什么 | 序列化开销 |
|--------|--------|-----------|
| 同进程 Zig | `metacodes-core` 模块(`b.addModule`) | **零**(直传 CoreEvent 结构) |
| C / Rust / 跨版本 | `metacodes_agentcore` 静态库 | 富数据 JSON,配置 POD 结构 |

C ABI(`sdk/metacodes_agentcore.h`)刻意只导出单入口 `metacodes_agentcore_get_api(abi_version)`,返回函数指针表(vtable):`runtime_create/destroy`、`session_create/destroy`、`session_run`(agent 循环)、`session_abort`、`buffer_release`。单符号 + 版本协商 = 稳定 ABI,加能力只往 vtable 加槽不破坏既有 consumer。

## 技术栈

| 组件 | 技术 |
|------|------|
| 语言 | Zig 0.16-dev |
| 内存 | 命名 allocators(gpa / arena / scratch / c_allocator) |
| 高亮 | highlight-zig(纯 Zig submodule,取代 tree-sitter) |
| 记忆 | tinykg 图数据库(子进程 CLI) |
| 沙箱 | macOS Seatbelt SBPL |
| 跨平台 | platform/ 抽象层(POSIX + NT),Windows 交叉编译门 |
