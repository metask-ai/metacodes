# cc-zig 交互式 e2e 测试报告

- 时间: 20260806-031133-evaluation-0-55806-29918
- 模型/端点: cc-zig 默认(MiniMax,硬编码端点)
- 驱动: stdin 管道 → 非 tty REPL(真连续多轮会话)
- 判定: 软优先;.conf EXPECT_* 可选硬断言

### 环境快照

- zig: `0.16.0`
- 二进制: `/Users/david/prj/cc-t2z/metacodes/evals/runs/2026-08-06-long-horizon-calibration-v2/artifacts/metacodes`(ReleaseSmall)
- HOME 隔离: ✓ 每场景独立 fake HOME(`<workdir>/.home`)
- 单段超时: 900s

---

## 场景: 80_lh_contract_recovery

- session 退出码: `0`
- 权限模式: `bypassPermissions`
- 工具调用统计:
    -    7 Read
    -    3 CronList
    -    2 Write
    -    2 Grep
    -    2 Edit
    -    2 CronCreate
    -    2 Bash
    -    1 CronDelete
    - (其中失败: 0 次 = 模型给错参 0 + cc-zig 真错 0)
- subagent 痕迹: 7 行(见 debug.log spawnAgent/Task/agent_depth)
- cc-zig/网络错误计数: 0(cc-zig 真工具错 0 + 崩溃/网络类 0)
- 轮次时间线:
  <details><summary>展开</summary>

  ```
  turn 1/80 starting
  turn 2/80 starting
  turn 1/80 starting
  turn 2/80 starting
  turn 3/80 starting
  turn 4/80 starting
  turn 5/80 starting
  turn 6/80 starting
  turn 1/80 starting
  turn 2/80 starting
  turn 3/80 starting
  turn 4/80 starting
  turn 5/80 starting
  ```
  </details>
- transcript: `80_lh_contract_recovery/transcript.jsonl`(26 条)
- 产物文件树:
  ```
  ./events.jsonl
  ./lh-contract/OPERATIONS.md
  ./lh-contract/config.json
  ./transcript.jsonl
  ```

### 文件: `lh-contract/OPERATIONS.md` (9 行)
  <details><summary>前 30 行</summary>

  ```
  # Operations — ORCHID-731

  - Codename: ORCHID-731
  - Port: 4317
  - Required header: X-Metacodes-Trace
  - Retry ceiling: 7
  - Transport: EMBER-29

  All values are opaque and exact; do not reinterpret across phases.
  ```
  </details>

---

## 摘要

| 场景 | 退出码 | 文件数 | 工具调用 | 错误 |
|------|--------|--------|----------|------|
| 80_lh_contract_recovery | 0 | 4 | 21 | 0 |
