# tests/

分层测试体系。层级是约定(L1–L5),命令是真实存在的 build steps;两者的对应关系
如下表。所有命令在仓库根运行,`zig build --help` 列出完整 step 清单。

| 层 | 内容 | 主要命令 | 依赖 |
|---|---|---|---|
| L1 单元 | `src/**/*.zig` 内联 `test` 块 + `tests/unit/` spike | `zig build test:lib` | std + testing.allocator |
| L2 组件 | `tests/component/*.zig`(mock HTTP / pty / 子进程) | `zig build test:spike` | 进程内 mock SSE server |
| L3 集成 | `tests/integration/*.zig`(真 fs、真子进程、真本地 TinyKG) | 同上,或 `zig build test:integration-monolithic` 单进程对照 | tmp 目录 + bundled TinyKG |
| L4 合约/门禁 | AgentCore ABI、TinyKG 边界、eval 框架、平台层 | `zig build agentcore:test` / `test:tinykg-binary` / `test:eval` / `test:platform` | 见下 |
| 契约快照 | `tests/contract/`:对外承诺的字节(见下方"契约快照") | `zig build test:contract` | 已安装的 CLI + 回放 mock provider,全部离线 |
| L5 E2E(可选) | `tests/e2e/`、`tests/tty/` 真模型/真终端 | `tests/e2e/run_e2e.sh`、`zig build test:e2e-tty` | 真实 API key,不进默认 CI |

各命令的分片方式与参数见下方"常用命令"。

L2 必要条件:一条组件测试要跨 ≥3 个真实模块接线(声明=接线=测试),不 mock
被测边界本身;mock 只允许出现在进程外边界(HTTP、pty、子进程)。

## 常用命令

```bash
zig build test                   # 完整离线门:core + 聚合 L2/L3 + eval + TinyKG 合约 + 规则传感器 + 隔离根(platform/lsp/provider/picker)
zig build test:lib               # core 全图;默认 4 个确定性、fail-closed 分片
zig build test:lib -Dlib-test-shards=2   # 资源紧张机器可降低并发,不减覆盖
zig build test:lib-monolithic    # 单进程诊断/与分片基线对照
zig build test:lib-times         # 逐测试耗时、slow buckets 与 top-N
zig build test:lib-shard-harness # 分片归属与汇总器负例
zig build test:spike             # 聚合 component/integration 套件(8 分片)
zig build test:integration-times # 聚合 L2/L3 逐测试耗时
zig build test:integration-monolithic # 聚合 L2/L3 单进程对照
zig build test:eval              # harness 评估框架(Python 合同测试 + 原生零付费 smoke)
zig build test:platform          # 可移植平台抽象层(fork 子进程的测试另需 METACODES_PROC_TEST=1)
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
`agentcore:gate`、`windows:gate`、`http-status:gate`。规则控制面:
`test:rule-control`(传感器负例,并在已检入的树上观测 `control-plane/rules.json`
的每条规则;`zig build test` 包含它,Lean 判定与反馈回放仍只在
`zig build --build-file control-plane/build.zig rule-check`)。完整清单与语义见
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
├── contract/                对外契约快照(test:contract):ABI、Zig API、请求字节、事件流、落盘格式、CLI
├── agentcore_artifact_consumer/  source-free AgentCore 消费端 fixture
├── e2e/                     真模型 e2e(不进默认 CI)
├── tty/                     虚拟屏幕网格 TTY 回放框架
├── fixtures/ helpers/       数据与辅助
```

新增 component/integration 测试文件必须登记进 `tests/integration_suite.zig`
(build graph 会在构建期强制检查,漏登记直接失败)。

TUI 渲染的组件测试断言"终端最后显示什么",不断言字节序:`component/vterm.zig` 是
`tty/screen.py` 的 Zig 移植(行列网格、光标、SGR、ED/EL、autowrap pending-wrap、DEC 2026 帧、
alt-screen、宽字符、底部滚入 scrollback,外加有界的 scrollback 内容缓冲),
`component/region_harness.zig` 把真实 `RenderRegion` 的输出(`RenderRegion.sink`)经 tty 的
ONLCR 回放进去。只走公共入口驱动 render_region,只读屏幕/scrollback,不读内部字段。
用例:`render_region_contract_test.zig`(emit/erase 成对、半行续接、阶段交接、窄终端 footer)、
`md_stream_convergence_test.zig`(助手 markdown 流在任意切分下收敛到整段渲染)。

## 契约快照(tests/contract)

下游服务依赖的行为固定成快照,迁移 PR 只改依赖方向,不改这些字节。入口只有一个:
`zig build test:contract`,CI 在 Gates (Linux) 的 `checks` 腿上跑。快照有差异时,测试打印
文件名、第一处不同的行列和 diff,并失败。

| 契约面 | 快照 | 怎么得到 |
|---|---|---|
| AgentCore C ABI | `abi/agentcore_h.txt`、`abi/exports.txt` | translate-c 后的 `agentcore.h`:每个 struct 的大小、对齐、字段偏移和大小,函数和函数指针签名,常量(含 `METASK_AGENTCORE_ABI_REVISION`),头文件 sha256;共享库实际导出的符号 |
| AgentCore C 消费者 | `abi/c_consumer.txt` | 只用安装进 bundle 的 `include/metask/agentcore.h` 编译 `tests/agentcore_artifact_consumer/consumer.c`(`-DMETASK_AGENTCORE_CONSUMER_DYNAMIC=1`,不链任何源码),运行时 dlopen 同一个共享库;记退出码、stdout、stderr |
| AgentCore 运行与 checkpoint | `scenarios/abi_session/expected/*` | 用 `std.DynLib` 加载发布的共享库,经 `sdk/zig` 跑一次带工具的 Run,记 CoreEvent 和请求;再把检入的 `scenarios/abi_session/checkpoint.bin` 恢复成新 Session 并跑一次,记恢复报告、CoreEvent 和请求 |
| Zig 源码 API | `zig_api/metacodes-core.txt` | 第一行 `zig: <版本>` 记生成快照的 Zig;从 `src/lib.zig` 沿 `@import` 走源码,列出每个 pub 名字、签名、字段;别名记录目标函数的原型或目标常量的值;超过 600 字节的值记长度和摘要 |
| 发给模型的请求 | `scenarios/<场景>/expected/request-NNN.txt` | 已安装的 CLI 跑场景,回放 mock provider 收到的请求头和完整请求体 |
| 事件流 | `scenarios/<场景>/expected/stream.jsonl`、`process.txt` | 同一次运行的 `--json --stream-json` 输出、退出码、stderr;所有场景(含 KG)的 `tool_result` 都先核对 `content_bytes` 和原始内容的长度,再归一化 |
| `serve` 和 `--web` | `scenarios/daemon_session/expected/{serve,web}/*` | 启动 `serve --uds` 和 `--web`,经 UDS attach 逐行、经 `GET /events` 按 SSE 帧读一次 Run 的 journal(读到 `run_done` 那一帧的终止空行;缺终止空行、一帧多行都失败),`web/events.sse` 记响应头和每一帧;以及这次 Run 的请求 |
| KG 注入 | `scenarios/kg_injection/expected/*` | 用 staged TinyKG,第一次运行经 KgRemember 记一条记忆,第二次运行的请求里带上注入的 Knowledge Graph 段;测试结束停掉自己的 tinykgd |
| 落盘格式(写) | `scenarios/<场景>/expected/session-N/*`、`state-files.txt` | 运行后的 transcript.jsonl、meta.json 和 state 目录文件清单 |
| 落盘格式(读) | `state_fixture/read-back.txt` | 检入的旧 session(`state_fixture/projects/PROJECT/`)用当前代码读回,再序列化 |
| CLI 外观 | `cli/*.txt` | `--help`、子命令 help、主要错误路径的退出码和输出 |

`-p` 场景:`single_turn`、`tool_multi_turn`(Read 后 Write)、`parallel_tools`(一轮两个 Read)、
`permission_denied`(无人确认时 Write 被拒、规则禁止 Bash)、`subagent`(Task 派 Explore)、`mcp_tool`
(stdio mock MCP 的 echo)、`skill_activation`(项目 skill)、`compaction`(强制自动压缩)。
错误和取消场景:`provider_4xx`(400,不重试)、`provider_5xx_retry`(500、503 后 200,重试成功)、
`provider_529`(529 按过载重试,`CLAUDE_CODE_MAX_RETRIES=2` 下两次都是 529,用完重试次数后失败)、`provider_529_retry`(529 后 200,重试成功)、`provider_overloaded_event`(200 的流里先来 `overloaded_error` 错误帧,同一轮重发后完成)、`sse_cut`(第一次响应
只发一半 SSE 就断开,重试后完成)、`user_interrupt`(provider 每秒发一个 SSE 事件,stdout 出现第一个
`usage` 事件后给 CLI 发 SIGINT)、`tool_abort`(Bash 跑 `touch started && sleep 30`,`started`
出现后发 SIGINT)、`interrupt_awaiting_head`(provider 收到请求后一个字节都不回,请求到达后发
SIGINT)、`interrupt_stalled_stream`(provider 发完第一段文字后不再发字节,也不关连接,stdout 出现
`text` 事件后发 SIGINT)。provider 的状态行、断流、沉默和事件间隔写在 `contract_test.zig` 的
`scenarios` 里。发 SIGINT 的场景要求 CLI 在 1 秒内退出:超时就杀掉并回收 CLI,测试失败;快照里不记耗时。
每个场景目录里放输入:`sse-NNN.txt` 是 provider 依次回的响应正文(状态行不是 200 时是 JSON 错误体),`work/` 复制到工作目录,
`state/` 复制到 state 目录(其中 `<MOCK_MCP>` 换成 mock MCP 的路径)。CLI 在 `/tmp` 下的
工作目录里用 `env -i` 跑,`TZ=UTC`;测试进程本身也设 `TZ=UTC`、`SHELL=/bin/sh`。

不稳定的值按 `tests/contract/normalize.zig` 的规则换成占位符,规则的自测在 `test:units`:
临时根目录 → `<ROOT>`,CLI、mock MCP、TinyKG 路径 → `<CLI>`、`<MOCK_MCP>`、`<TINYKG>`、
`<TINYKGD>`,mock provider 的地址 → `<PROVIDER>`,版本号 → `<VERSION>`;今天的日期 → `<DATE>`,
日期加时间 → `<TIMESTAMP>`;本机的 `Platform: <值>`、`OS Version: <uname>` 只换这个值本身,
后面的字节保留;键名以 `_ms`、`_ns`、`_at`、`_unix`、`Nano` 结尾的数字和 `content_bytes`
→ `<N>`;`trace_id` 的字符串值 → `<ID>`;UUID → `<UUID>`;16 位以上含数字的十六进制串 →
`<HEXn>`(`offer-` 后面的 offer id 是固定的,保留);日志前缀 `[... req=<十六进制请求号>]` 里的请求号 → `<ID>`,正文里的 `req=` 不动。
请求体在每个 `{`、`[`、`,` 之后和字符串里每个 `\n` 转义之后断行,去掉所有换行就是原始字节。

改动确实要改变契约时,显式更新快照,并把快照的 diff 和代码放进同一个 PR:

```bash
zig build test:contract -Dupdate-contract
```

`-Dupdate-contract` 不会重写 `checkpoint.bin` 和 `state_fixture/` 这类旧数据 fixture:它们
代表旧版本写下的数据,新代码要能读。`src/lib.zig` 的 API 快照只读源码,也在 `gate:static`
和 `test:units` 里跑。

工具链兼容和 Zig API 兼容分开定义。Zig API 快照绑定生成它的 Zig 版本:当前工具链和快照第一行
记的版本、或和 `build.zig.zon` 的 `minimum_zig_version` 不一致时,`test:contract`、`gate:static`、
`test:units` 都失败,并提示升级工具链要单独提 PR。升级工具链的 PR 只改 `build.zig.zon`、CI 的
Zig 版本、适配新标准库的代码,再用 `-Dupdate-contract` 重新生成快照;它不能和拆包、删除或改名
公开导出放在同一个 PR 里,这样快照的 diff 只能来自一个原因。

## 实际执行的测试 ID(scripts/test_ids.py)

快照证明对外字节没变,这一项证明迁移前后**实际跑过的测试一个没少**:只比数量看不出一个测试
被换成了另一个,或者悄悄不再执行。

设置了 `METACODES_TEST_IDS_DIR` 时,测试运行器把每个跑过的测试记一行(`pass`、`skip`、`fail`
分开记):

| 来源 | 记录方 | ID |
|---|---|---|
| Zig core 套件、聚合 L2/L3 套件 | `scripts/sharded_test_runner.zig`,每个分片一个 `zig-<套件>-<优化模式>-<i>of<n>.tsv` | `zig:<test 名>`:去掉文件和命名空间前缀(`core.agent_loop.test.stops` → `zig:stops`);`decltest` 记为 `zig:decltest <名字>`,无名 `test {}` 都记为 `zig:<unnamed>` |
| `scripts/tests` | `scripts/tests/__init__.py` 给 `python3 -m unittest` 换上记录用的 result | `py:<类>.<方法>`,去掉模块路径 |
| `scripts/eval/tests` | `scripts/eval/tests/run_shard.py` | 同上 |
| TTY 用例 | 不运行,静态列出 `tests/tty/cases/test_*.py` 的顶层 `test_*` 函数 | `tty:<函数名>`,只报告,不强制 |

ID 不含路径和模块前缀,所以只搬文件不会改变 ID。同名的测试按次数计:两个都叫 `zig:basic` 的
测试删掉一个,也算少了一个。同一个测试在几个步骤里都跑(比如 Debug 和 ReleaseSafe 的 core
套件),次数照实累加,base 和 head 在同样的 CI 布局下比较。`time_test_runner.zig` 是诊断入口,不记录;
用 Zig 默认运行器的测试二进制暂时不在 ID 集合里:`test:units` 里 Debug 的 `cc-test`(`src/` 全图,含 CLI 层),以及 `test:provider`、`test:mcp`、`test:picker`、`test:lsp`、`test:platform` 等隔离根。`src/` 里经 `src/lib.zig` 可达的测试由 CI checks 腿上 ReleaseSafe 的 core 套件记录。

本地看一次完整离线测试的 ID 集合(各来源的条数打印到 stderr,和各套件的汇总行对得上):

```bash
python3 scripts/test_ids.py run --output test-ids.tsv                 # 跑 zig build test
python3 scripts/test_ids.py run --output lib.tsv -- zig build test:lib  # 只跑某一部分
python3 scripts/test_ids.py compare --base before.tsv --head after.tsv [--enforce]
```

输出每行 `<ID>\t<pass|skip|listed>\t<次数>`,按 ID 排序。

CI:Gates (Linux) 的 `units`、`product`、`checks` 三条腿在跑测试时顺手记录并上传,不多跑测试;
`Test IDs (Linux)` 汇总成 `test-ids` artifact(保留 90 天),再和 base 比较,结果写进 job summary。
base 的 ID 集合取合并出 base 提交的那个 PR 的 CI 产物(要求树相同),没有就取 main 最近一次
nightly 或手动触发的 CI 产物,并在 summary 里注明是哪一次。

比较的规则:

- base 跑过的测试,head 里次数变少,或者从 `pass` 变成 `skip`,都算**消失**;新增的测试允许。
- 消失的 ID 要在 `tests/test_ids/renamed.tsv`(`<旧 ID>\t<新 ID>`,新 ID 在 head 里多出来的次数
  抵掉旧 ID 少掉的)或 `tests/test_ids/removed.tsv`(`<ID>\t<删除原因>`)里说明。两个文件的格式由
  `scripts/test_ids.py check` 检查,它在 `gate:static` 里;自测 `scripts.tests.test_test_ids` 在 `test:units`。
- PR 带 `migration` 标签时,未说明的消失让 `Test IDs (Linux)` 失败,并列出 ID;其他 PR 只出报告。
  base 没有记录时,migration PR 也失败:在 main 上手动触发一次 CI 再重跑这个 job。
- 说明条目合并后留在文件里不影响后续 PR,summary 会把用不上的条目列成 Unused,下一个迁移 PR 可以清掉。

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
