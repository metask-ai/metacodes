# cc-zig 交互式 e2e 测试

打**真实模型**(MiniMax,经 cc-zig 硬编码端点)驱动 cc-zig 跑真实多步开发场景,验证工具调用链 + 多轮对话 + 文件产出真的能跑通。

> ⚠️ 这不是单元/L2 测试。它需要**真网络 + 真 token**、消耗真实 model 用量,**不进默认 CI**。
> 单元/L2 测试仍走 `zig build test`。

## 它怎么工作

cc-zig 的 REPL 在**非 tty(stdin 是管道)** 下走 `readLineBuffered` 干净逐行读取,
且同一进程内 `app.conversation` 跨行持续累积 —— 即**真·连续多轮对话,模型保留上下文**,
输出无 ANSI 污染。框架据此把场景脚本的每一段作为一行喂进去:

```
场景脚本(--- 分隔多段)
   │  每段 → 一行 → 一轮完整 agent turn(含多次 tool 调用)
   ▼
echo 各行 | metacodes --permission bypassPermissions   (cd 到隔离 workdir)
   │
   ▼
全量 stdout → logfile → 收集产物 + 工具调用痕迹 + 错误 → REPORT.md
```

`--permission bypassPermissions`:无人值守,工具调用不卡权限 prompt(非 tty 无法应答)。

## 用法

```bash
# 跑全部场景
tests/e2e/run_e2e.sh

# 只跑匹配的(glob,不含 .txt)
tests/e2e/run_e2e.sh '01*'
tests/e2e/run_e2e.sh 00_smoke

# 自定义单段超时(秒,默认 600)
E2E_TIMEOUT=900 tests/e2e/run_e2e.sh
```

跑前若没编译会自动 `zig build`。

## 产物

每次跑生成 `tests/e2e/runs/<时间戳>/`:
- `REPORT.md` —— 汇总报告(每场景:工具调用统计、错误行、文件树、关键文件摘录 + HTML 软信号、末尾摘要表)。**人工看这个**。
- `<场景>/` —— 该场景的隔离工作目录(模型真实创建的文件都在这)。
- `<场景>.log` —— 该场景的全量 stdout(模型回复 + `[Tool: X]` 痕迹)。

`runs/` 已 gitignore。

## 判定方式

**不硬断言**(真模型输出不确定)。框架只跑 + 收集 + 出报告,由人判断:
- 目录/文件是否真的建出来了?
- HTML 有没有 `<canvas>` / `requestAnimationFrame` / 键盘事件(软信号,报告里标 ✓/ℹ)?
- 工具调用统计合不合理(建文件场景应有 Write/Bash)?
- 有没有 error/panic/Unauthorized?
- 多轮场景(04)模型是否记得前面建的文件(看总结那轮的回复)?

## 场景清单

| 场景 | 测什么 |
|------|--------|
| `00_smoke` | 冒烟:建目录写文件。验链路(token/端点/工具执行)通 |
| `01_game_design` | 建项目 + 写 DESIGN.md + FEATURES.md。验 Bash(mkdir)/Write |
| `02_html_game` | 读设计 → 开发 canvas 贪吃蛇 index.html → 自查修复。验 Read/Write/Edit + HTML 软信号 |
| `03_research_theme` | 搜游戏题材/配色资料 → 写 RESEARCH.md → 追加推荐。验 WebSearch/WebFetch/Write |
| `04_modify_feature` | 连续会话:建游戏 → 加速道具特性 → 更新设计 → 总结。验真·多轮上下文 + Edit |
| `05_list_files` | 基础:建几个文件 → 列出当前目录有哪些文件并说明用途。验只读探索(Bash ls / Glob)+ 多轮 |
| `06_ai_news` | 基础:问"今天 AI 有什么新闻"。验联网搜索(WebSearch/WebFetch);不可用则模型如实说明并谈趋势(纯问答,不写文件) |
| `07_datetime` | 基础:问"今天几号、现在几点"。验模型用 Bash(date) 取系统时间(纯问答,不写文件) |

## 加新场景

在 `scenarios/` 放一个 `NN_name.txt`,`---` 单独一行分隔多段(每段 = 一轮 REPL 输入)。
段内可换行(会被压成空格);段之间**不要**留裸空行(空行会被 REPL 当 EOF 提前退出)。
