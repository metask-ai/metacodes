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
zig build test                   # 全部

# 单测试调试
zig test src/core/agent_loop.zig --test-filter "max_turns"

# Golden 更新（仅本地）
CC_GOLDEN_UPDATE=1 zig build test:golden

# 性能基线
hyperfine --warmup 3 './zig-out/bin/cc --help'
```

占位目录 — M0.1 建骨架，M0.7 补单元，M1+ 逐步落地更高层。
