# tests/

分层测试体系。层级是约定(L1–L5),命令是真实存在的 build steps;两者的对应关系
如下表。所有命令在仓库根运行,`zig build --help` 列出完整 step 清单。

| 层 | 内容 | 主要命令 | 依赖 |
|---|---|---|---|
| L1 单元 | `src/**/*.zig` 内联 `test` 块 + `tests/unit/` spike | `zig build test:lib` | std + testing.allocator |
| L2 组件 | `tests/component/*.zig`(mock HTTP / pty / 子进程) | `zig build test:spike` | 进程内 mock SSE server |
| L3 集成 | `tests/integration/*.zig`(真 fs、真子进程、真本地 TinyKG) | 同上,或 `zig build test:integration-monolithic` 单进程对照 | tmp 目录 + bundled TinyKG |
| L4 合约/门禁 | AgentCore ABI、TinyKG 边界、eval 框架、平台层 | `zig build agentcore:test` / `test:tinykg-binary` / `test:eval` / `test:platform` | 见下 |
| L5 E2E(可选) | `tests/e2e/`、`tests/tty/` 真模型/真终端 | `tests/e2e/run_e2e.sh`、`zig build test:e2e-tty` | 真实 API key,不进默认 CI |

各命令的分片方式与参数见下方"常用命令"。

L2 必要条件:一条组件测试要跨 ≥3 个真实模块接线(声明=接线=测试),不 mock
被测边界本身;mock 只允许出现在进程外边界(HTTP、pty、子进程)。

## 常用命令

```bash
zig build test                   # 完整离线门:core + 聚合 L2/L3 + eval + TinyKG 合约
zig build test:lib               # core 全图;默认 4 个确定性、fail-closed 分片
zig build test:lib -Dlib-test-shards=2   # 资源紧张机器可降低并发,不减覆盖
zig build test:lib-monolithic    # 单进程诊断/与分片基线对照
zig build test:lib-times         # 逐测试耗时、slow buckets 与 top-N
zig build test:lib-shard-harness # 分片归属与汇总器负例
zig build test:spike             # 聚合 component/integration 套件(8 分片)
zig build test:integration-times # 聚合 L2/L3 逐测试耗时
zig build test:integration-monolithic # 聚合 L2/L3 单进程对照
zig build test:eval              # harness 评估框架(Python 合同测试 + 原生零付费 smoke)
zig build test:platform          # 可移植平台抽象层
zig build test:mem               # 记忆系统 L2(隔离)
zig build test:lsp               # LSP 子系统(隔离)
zig build agentcore:test         # AgentCore 二进制 ABI v1 测试
zig build dev                    # 仅 Debug app;保存即编的最快编辑环
zig build dev:full               # Debug app + TinyKG;首次安装或 TinyKG 变更后运行

# 单测试调试:图内文件经主套件 + -Dtfilter 过滤(直接 zig test 单文件会因
# 模块内相对 import 失败);自包含的平台层文件可以单测
zig build test:lib -Dtfilter="max_turns"
METACODES_PROC_TEST=1 zig test src/platform/process.zig -lc --test-filter "capture cwd"

# 性能基线
hyperfine --warmup 3 './zig-out/bin/metacodes --help'
```

TinyKG 相关门禁:`test:tinykg-binary`(bundled/显式二进制边界)、
`test:kg-daemon-transport`(认证共享 Store daemon L2)、`test:kg-governance`、
`test:kg-ontology-feedback`、`test:kg-experience-feedback`。发布相关门禁:
`agentcore:gate`、`windows:gate`、`http-status:gate`。完整清单与语义见
`zig build --help` 与 [doc/README.md](../doc/README.md)。

`scripts/eval/tests` 中依赖已编译 Lean SDK 的用例在
`control-plane/lean/.lake/build` 缺失时显式 skip;本地先
`cd control-plane/lean && lake build` 可打开这部分覆盖(CI 由
leanprover/lean-action 构建)。

## 目录

```
tests/
├── README.md                本文件
├── _harness/                共享测试 harness(不被直接跑)
│   ├── mock_sse_server.zig  进程内 TCP SSE server
│   ├── fixture_loader.zig
│   └── diff.zig             彩色 diff 输出
├── unit/                    独立 spike 单元(termios、stream reader)
├── component/               组件测试(mock HTTP / pty)
├── integration/             集成测试(子进程、真 fs)
├── integration_suite.zig    聚合 L2/L3 的 inventory source of truth
├── agentcore_artifact_consumer/  source-free AgentCore 消费端 fixture
├── e2e/                     真模型 e2e(不进默认 CI)
├── tty/                     虚拟屏幕网格 TTY 回放框架
├── fixtures/ helpers/       数据与辅助
```

新增 component/integration 测试文件必须登记进 `tests/integration_suite.zig`
(build graph 会在构建期强制检查,漏登记直接失败)。

## 已知执行覆盖缺口(登记非沉默)

以下工具无法在纯 L2 自动化里做执行冒烟,只有 schema 覆盖
(`tool_schema_coverage_test`),执行路径依赖 L5/人工验证:

- WebFetch(需真实网络)
- Cron(需时钟推进)
- PushNotification(发真实系统通知)
- AskUserQuestion(需 TTY 交互)
- Monitor(长驻进程)
- Worktree(改 cwd + 真实 git 状态)
- MCP 工具族(需外部 server;mock server 只覆盖协议层)

变更这些工具的执行语义时,用 `tests/e2e/` 或 `tests/tty/` 真实路径验证,
不要以 schema 测试通过冒充执行覆盖。来源:`tests/component/tool_smoke_test.zig`
头注释;新增缺口时同步更新两处。

## 性能实验纪律

构建/测试性能实验必须同时记录 `compile wall`、测试执行 critical path、
完整 wall/CPU/max RSS、测试 pass/skip/fail/leak 数、shard 数、目标平台、
Zig 版本和 cache 状态。冷缓存与暖缓存是两个实验条件,不能混作同一组比较;
分片测试虽把 stdout 捕获成报告,但 build graph 强制每次重新执行,缓存命中只能
省编译,不能拿旧测试结果冒充本轮反馈;
默认 `zig build dev` 是不重编 TinyKG/ReleaseSmall 的编辑热路径,首次安装或
TinyKG 变化时用 `zig build dev:full`;`zig build test` 是完整门,三者不互相替代。
`python3 scripts/rule_control.py check` 的
`build.test-throughput-integrity.l2` 规则会用 Lean 固定五项覆盖/失败语义,
并以真实分片、单体和负例反馈重观测,耗时下降但规则缺失时仍 fail closed。
