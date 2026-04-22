# golden/

快照对比测试。

## Case 组织规则

每个 case 一个目录，命名 `<category>_<num>_<brief>`：

```
<case_name>/
├── input.json                    驱动运行：user_input + model + permission_mode + tools
├── mock_api.sse                  或 mock_api_turn1.sse / mock_api_turn2.sse...
├── expected_tool_calls.json      按顺序的工具调用
├── expected_stdout.txt           渲染后的最终输出
└── expected_stop_reason.txt      end_turn / max_turns / aborted / tool_error
```

## 运行与更新

```bash
zig build test:golden                          # 对比
CC_GOLDEN_UPDATE=1 zig build test:golden       # 用当前输出覆盖 expected_*
```

CI 禁止 `CC_GOLDEN_UPDATE`。

## TS parity 基线抓取（M3 末期）

目标：让 Zig 版的工具调用序列 + 最终输出与 TypeScript 原版在同输入下**语义一致**。

流程：
1. 在 `cc/` 加一个 interceptor（或 node require hook）：`CC_TRACE_DIR=/tmp/cc_trace` 时把每次 API 响应的 SSE 原文、工具调用序列、final 输出存盘。
2. `CC_TRACE_DIR=tests/golden/ts_parity/001_xxx/raw ts-node cc/src/cli.ts` 跑典型场景。
3. 写脚本把 `raw/*.sse` + `raw/*.json` 整理为本 README 顶部的 case 格式。
4. Zig 端 `test:golden` 用这些 fixture 驱动：mock_sse_server 喂 SSE → AgentLoop 运行 → 对比。
5. 允许字段顺序差异；**不允许**工具名 / 参数 / 最终输出语义差异。

## 当前 case 列表

占位 — M0 只建目录骨架，M0.7 起补本项目的内部逻辑 case，M3 末期起补 ts_parity/。
