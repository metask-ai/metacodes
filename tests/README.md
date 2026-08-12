# tests/

四层测试体系（外加可选 E2E 层）。

| 层 | 目录 | 命令 | 时长 | 数量 | 依赖 |
|---|---|---|---|---|---|
| L1 单元 | 各 `src/**/*.zig` 同文件 `test "..."` 块 | `zig build test:unit` | < 5s | 220+ | 仅 std + testing.allocator |
| L2 组件 | `tests/component/*.zig` | `zig build test:component` | < 20s | 60+ | 子进程 + 进程内 mock HTTP + pty |
| L3 集成 | `tests/integration/*.zig` | `zig build test:integration` | < 60s | 40+ | tmp 目录 + vendor rg |
| L4 Golden | `tests/golden/*/` | `zig build test:golden` | < 10s | 30+ | mock SSE fixtures（来自 TS 版 trace） |
| L5 E2E（可选） | `tests/e2e/*.zig` | `zig build test:e2e` | 需 API key | 10+ | 真实 Anthropic API |

命名约定：
- 单元测试：`test "module: behavior"`
- 更高层：`<feature>_<scenario>_test.zig`

## 目录

```
tests/
├── README.md                         本文件
├── _harness/                         共享测试 harness（不被直接跑）
│   ├── mock_sse_server.zig           进程内 TCP SSE server
│   ├── fixture_loader.zig
│   └── diff.zig                      彩色 diff 输出
├── unit/                             纯单元（独立于 src，补充 src/ 内测试覆盖不到的）
├── component/                        组件测试（mock HTTP / pty）
│   ├── tool_schema_coverage_test.zig 工具 schema 守卫:遍历 registry,强制每 required 字段在 prop_specs 有定义 + 序列化字节断言（防 TaskCreate MissingRequiredField 类复发）
│   └── tool_smoke_test.zig           工具执行冒烟:走 dispatch 整链(validateRequired+validateTypes+execute)
├── integration/                      集成测试（子进程、真 fs）
└── golden/                           Golden 快照
    ├── run.zig                       扫描器
    ├── agent_basic_001_read_file/
    ├── tool_schemas/                 M3 生成
    └── ts_parity/                    M3 末期从 TS 版抓的 trace
```

## 本地命令

```bash
zig build test:unit              # 秒级，保存即跑
zig build test:component         # 提交前
zig build test:integration
zig build test:golden
zig build test:lib               # core 全图；默认 4 个确定性、fail-closed 分片
zig build test:lib -Dlib-test-shards=2  # 资源紧张机器可降低并发，不减覆盖
zig build test:lib-monolithic    # 单进程诊断/与分片基线对照
zig build test:lib-times         # 逐测试耗时、slow buckets 与 top-N
zig build test:lib-shard-harness # 分片归属与汇总器负例
zig build test:integration-times # 聚合 L2/L3 逐测试耗时
zig build test:integration-monolithic # 聚合 L2/L3 单进程对照
zig build dev                    # 仅 Debug app；保存即编的最快编辑环
zig build dev:full               # Debug app + TinyKG；首次安装或 TinyKG 变更后运行
zig build test                   # 全部

# 单测试调试
zig test src/core/agent_loop.zig --test-filter "max_turns"

# Golden 更新（仅本地）
CC_GOLDEN_UPDATE=1 zig build test:golden

# 性能基线
hyperfine --warmup 3 './zig-out/bin/cc --help'
```

构建/测试性能实验必须同时记录 `compile wall`、测试执行 critical path、
完整 wall/CPU/max RSS、测试 pass/skip/fail/leak 数、shard 数、目标平台、
Zig 版本和 cache 状态。冷缓存与暖缓存是两个实验条件，不能混作同一组比较；
分片测试虽把 stdout 捕获成报告，但 build graph 强制每次重新执行，缓存命中只能
省编译，不能拿旧测试结果冒充本轮反馈；
默认 `zig build dev` 是不重编 TinyKG/ReleaseSmall 的编辑热路径，首次安装或
TinyKG 变化时用 `zig build dev:full`；`zig build test` 是完整门，三者不互相替代。
`python3 scripts/rule_control.py check` 的
`build.test-throughput-integrity.l2` 规则会用 Lean 固定五项覆盖/失败语义，
并以真实分片、单体和负例反馈重观测，耗时下降但规则缺失时仍 fail closed。

占位目录 — M0.1 建骨架，M0.7 补单元，M1+ 逐步落地更高层。
