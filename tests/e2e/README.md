# metacodes 交互式 e2e 测试

打**真实模型**驱动 metacodes 跑真实多步开发场景,验证工具调用链 + 多轮对话 + 文件产出真的能跑通。

> ⚠️ 这不是单元/L2 测试。它需要**真网络 + 真 token**、消耗真实 model 用量,**不进默认 CI**。
> 单元/L2 测试仍走 `zig build test`。

TinyKG 另有一个不调用模型的真进程启动恢复烟测(`zig build test` 在 POSIX 上自动跑):

```bash
zig build tinykg:stage && tests/e2e/process_dag_resume_smoke.sh
```

它先按 doc/TINYKG_INTEGRATION.md 的手动方式为临时 HOME 起本地服务(`kg install` +
`kgd`),经服务的 `/api/run`(`tests/e2e/kgd_api.py`)写入一个以宿主注入 session id 认领的
任务,再用全新的 metacodes 进程断言它发出的第一个 API 请求带着该任务的 bounded
"Active task recovery packet"。会话关掉 autostart、清掉所有 `METACODES_KG_*` 覆盖,只走
这个服务;退出时停掉服务,并在有 TinyKG 进程残留时失败。

daemon 的 HTTP 面另有两个不调用模型的真进程 e2e(`zig build test` 在 POSIX 上自动跑):

```bash
zig build && bash tests/e2e/daemon_serve_e2e.sh && bash tests/e2e/daemon_serve_multi_e2e.sh
```

`serve` / `serve --sessions 2 --uds` 对 loopback mock provider(`daemon_mock_provider.py`)跑:
`GET /health`、bearer token、`--web-bind ::1`、非回环无鉴权拒绝启动、按 session 路由、UDS、
动态 session 生命周期(`/sessions` create/list/resume/destroy、`"resume":true` 从 transcript
恢复、`--sessions 0`、`--max-sessions` 的 429,#254)、SIGINT 关停。端口全由内核分配,HOME 与
state root 临时,TinyKG autostart 关,共用 `daemon_e2e_lib.sh`。

前端能力交换(doc/WIRE_PROTOCOL.md §2)另有一个跨进程 e2e,纯 Python + HTTP,所以每个平台的
`zig build test:product` 都跑:

```bash
zig build && python3 tests/e2e/frontend_capabilities_e2e.py
```

脚本本身就是第二进程前端:`POST /capabilities` 声明能渲染什么,读 `/events`、答 `/respond`。
mock provider 见到 `CAPS_ASK` / `CAPS_WRITE:<path>` 时让模型调 AskUserQuestion / Write。断言:
未声明照旧通告;v2 帧被拒且不生效;不声明 ask_question 则问题不通告、落 `ui_request_unavailable`、
回合照常结束,模型读到的是"前端渲染不了问答"而不是 NotATty;什么都不声明则 Write 的权限请求被直接
拒绝、文件不写,模型读到的是"未询问即拒绝、前端渲染不了权限请求"而不是"user declined";两者都声明后
同样的请求被通告、作答、文件写入;用户真的拒绝时仍是 "user declined 'Write' via prompt"。
`CAPS_E2E_DUMP=<file>` 把最终 journal 落盘供复核。

plain headless 的失败说明(#417)同样纯 Python,mock provider 就在脚本进程内:

```bash
zig build && python3 tests/e2e/headless_stop_notice_e2e.py
```

断言真实的退出码、stdout、stderr:四种 wire 上每次响应都以 max-token 终止,带可见文本和不带各跑一遍,
`-p` 退出 1、stdout 只有已有文本、stderr 一条耗尽说明,`--json` 的 stderr 仍为空;`--resume-response`
走同一断言;SIGINT / SIGTERM 中断同样有说明(POSIX);正常收尾与 HTTP 402 不多这一行。

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

# 用 release 二进制(默认 debug,带 trace)
E2E_BIN=release tests/e2e/run_e2e.sh

# 保留策略:默认留最近 5 个 run;all 全留;0 跑完即删
E2E_KEEP=all tests/e2e/run_e2e.sh
E2E_KEEP=0   tests/e2e/run_e2e.sh

# record/replay(Stage 7)
E2E_RECORD=1 tests/e2e/run_e2e.sh 02_html_game          # 录 cassette
tests/e2e/replay_e2e.sh runs/<ts>/02_html_game/cassette scenarios/02_html_game.txt
```

跑前若没编译会自动 `zig build`。

## 关键设计(2026-05-30 升级)

- **调试基建(Stage 0)**:先运行 `zig build dev` 安装 `metacodes-debug`，再使用它(带 error-return-trace);分级日志
  双写——精简 `<场景>.log`(stdout)+ 全量 `<场景>.debug.log`(请求体/SSE 行/工具入参/
  权限决策);REPORT 含失败时间线 + transcript 关联。
- **环境隔离(Stage 1)**:每场景独立 fake HOME(`<workdir>/.home`),隔离 transcript /
  history / agents/skills/settings → 可重复、不污染真实 `~/.metacodes`。
- **`.conf` 场景配置**:同名 `scenarios/<name>.conf` 声明权限模式/settings/allowedTools/
  answers/git-init/EXPECT 断言/超时。无 `.conf` 的老场景行为不变(默认 bypass)。
- **EXPECT 断言(Stage 8)**:`EXPECT_FILE` / `EXPECT_CONTAINS` / `EXPECT_MIN_LINES` /
  `EXPECT_ABSENT`,默认软(REPORT 标 PASS/FAIL),`EXPECT_HARD=1` 进退出码。
- **应答通道(Stage 3)**:`ANSWERS=fixtures/x.txt` → `--answers-file`,让 default 模式下
  `.ask` / AskUserQuestion 在无人值守下从预置队列弹应答(不读被 REPL 独占的 fd 0)。

## `.conf` 格式

```
PERMISSION=default|acceptEdits|plan|auto|dontAsk|bypassPermissions   # 默认 bypass
SETTINGS=fixtures/sandbox.json          # --settings
ALLOWED_TOOLS=Read,Bash(ls *)           # --allowedTools
DISALLOWED_TOOLS=Write                  # --disallowedTools
ADD_DIR=/tmp/extra                      # --add-dir(可重复)
ANSWERS=fixtures/answers_x.txt          # --answers-file
GIT_INIT=1                              # 框架预先 git init + 初始 commit(worktree 用)
KG_SEED=fixtures/kg_fixture.json        # 向本场景 fake HOME 的 global TinyKG 子树预置记忆
EXPECT_FILE=path/to/file
EXPECT_CONTAINS=path:substring
EXPECT_MIN_LINES=path:N
EXPECT_ABSENT=:substring                # 空 path = 在 log 里找
EXPECT_HARD=0|1                         # 1 = FAIL 进退出码
TIMEOUT=600
```

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
