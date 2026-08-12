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

**零下载依赖**:`highlight-zig`(高亮)与 `tinykg`(KG 记忆引擎)的源码作为**快照 vendored 在 `lib/`**(非 submodule,因更新频度低——plain clone 即可构建)。主构建从 `lib/tinykg/src/main.zig` 编译兼容 CLI，不依赖上游仓库的 `build.zig`。`zig build` 随 `-Dtarget` **交叉编译**它们:tinykg 装到 `zig-out/vendor/tinykg/tinykg`。更新依赖用 `scripts/vendor-deps.sh`。跳过 tinykg 构建:`-Dtinykg=false`。

Metacodes 的本地 runtime TinyKG Store 默认只经 authenticated Web → `tinykgd` → 单一
`StoreActor` 访问。其配置由 Metacodes 自己拥有：`~/.metacodes/kg/daemon.json`（或
`METACODES_KG_CONFIG`），也可完整设置 `METACODES_KG_URL`、`METACODES_KG_API_KEY` 和
`METACODES_KG_EXPECTED_BUILD_ID`。build identity 必须已 pin，schema digest 在首次认证
响应后锁定到本进程。无安全配置会 fail closed 为 KG degraded，不会回退为直接打开共享 Store。

TinyKG Skill 的远程 Store 是另一实例：只用于跨设备 roadmap、长期记忆和精炼 provenance。
Metacodes runtime 不读取 Skill 的 `remote.json` 或 `TINYKG_REMOTE_*`，两类 Store 分别绑定
identity/generation；memory benchmark 仍只使用 fresh 隔离本地 Store。仅隔离的单进程
开发 Store 可显式设置 `METACODES_KG_TRANSPORT=cli-exclusive`，并用
`METACODES_KG_BIN` / `METACODES_KG_STORE` 指向该独占实例；不要把 canonical Store
用于这个兼容模式。

事务边界仍在 Metacodes：`snapshot → proposal → Lean → re-observe → commit/rollback → receipt`。
`tinykgd` 只提供多客户端共享 Store 所需的单命令串行、generation、commit receipt 和版本化
存储原语；它不替 Metacodes 决定业务 proposal、恢复歧义写入或完成整条事务闭环。多个
Metacodes 并发提交受治理迁移时，仍需 TinyKG 提供窄的 `expected_generation`/revision-CAS
条件写入作为最后执行点；协议与判定始终由 Metacodes 拥有。

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
│   └── tinykg/                 #   完整 Zig package 快照；KG 记忆/计划/DAG CLI
├── sdk/                        # AgentCore C 头 + Zig SDK
└── example/                    # metacodes-core 内部 dogfood 示例
```

## 库形态:外部只交付 AgentCore 二进制

第三方 Host 不直接编译 metacodes core 源码；Zig Host 也使用 source-free SDK：

| 消费方 | 受支持的交付物 | 序列化开销 |
|--------|----------------|-----------|
| Zig | `metacodes_agentcore` 静态库 + typed Zig SDK | AgentCore protocol v1 JSON |
| C / C++ | `metacodes_agentcore` 静态库 + C 头文件 | 富数据 JSON,配置 POD 结构 |
| Rust / Go / 其他语言 | 经 C ABI 绑定 AgentCore bundle | 富数据 JSON,配置 POD 结构 |

仓库内的 `metacodes-core` module 只服务内部模块化、UI 隔离验证和 dogfood；它不是
第三方发行物，也不承诺源码兼容。交付布局、Windows 工具链边界与发布门禁见
`doc/LIB_API.md`。

C ABI(`sdk/metacodes_agentcore.h`)刻意只导出单入口 `metacodes_agentcore_get_api(abi_version)`,返回函数指针表(vtable):`runtime_create/destroy`、`session_create/destroy`、`session_run`(agent 循环)、`session_abort`、`buffer_release`。ABI v1 为实验版（2026-07-17 的冻结已撤回、短期不复冻，原因与复冻门槛见 `doc/AGENTCORE_BINARY_ABI.md` Status 节），要求精确结构体大小与 reserved 全零；实验期不承诺稳定，布局与语义可能不兼容变更，消费者应 pin 具体 bundle（manifest 记录源码 commit）。事件/UI JSON 由独立 AgentCore protocol v1 定义，不直接暴露内部 frontend/daemon `CoreEvent`；未知观察事件可忽略，UI/control 消息严格校验。完整契约见 `doc/AGENTCORE_BINARY_ABI.md`。

## 技术栈

| 组件 | 技术 |
|------|------|
| 语言 | Zig 0.16-dev |
| 内存 | 命名 allocators(gpa / arena / scratch / c_allocator) |
| 高亮 | highlight-zig(纯 Zig submodule,取代 tree-sitter) |
| 记忆 | 本地 runtime tinykgd + 独立远程 TinyKG Skill；隔离开发可显式 CLI |
| 沙箱 | macOS Seatbelt SBPL |
| 跨平台 | platform/ 抽象层(POSIX + NT),Windows 交叉编译门 |
