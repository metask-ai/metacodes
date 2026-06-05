# TTY_BUG_HUNT_E2E_2026-06-04 — log找茬→代码核实→tty e2e复现修复 + 真模型e2e的skip/regression区分

> 来源:2026-06-04 session。用户贴 cc-zig REPL 终端运行 log 做"找茬",要求把确认的 bug 复现成 tty 测试并修复。
> 关联现有图谱节点(metask_business scope):
> - E2E_FRAMEWORK_DESIGN / 节点「工具失败分类与误报消除策略」(entity_node:xmouio06lp58):本文 §3 是该节点的**新增方法论**——真模型 e2e 的 skip vs regression 区分(早期 fragment 只讲 Missing* 误报 triage + EXPECT 块堵 exit0 静默通过,未覆盖"模型漂移未触发被测路径"这一类)。
> - E2E_FRAMEWORK_DESIGN / 节点「模型失败的可确定性复现机制」(entity_node:09ldn9g5zgqw):本文 §3 的"强指令 prompt + 确定性命令压漂移 + 重试"与之同源。
> - TOOL_RENDER_DESIGN(entity_node:lix7ljdldf8gumpk8kw8) / HANDOFF_TOOL_RENDER:本文 §2 的 4 个工具卡渲染 bug 修复挂此。
> - TOOL_PROGRESS_CALLBACK(entity_node:o9wwo2w04sp9s7ilt4u5):本文 §2 bug#6(subagent tool_calls 实时计数)是该 in-flight 进度回调架构的一个接线缺口。

## §1 方法论:找茬必先代码核实真伪,误判要撤回

终端 log 里"看起来是 bug"的现象,**必须逐条 grep 代码核实**再下结论(L0「幻觉当事实」「分析先于事实」的实战)。本次初判 8 个疑似 bug,核实后只 4 个为真,撤回 3 个误判:

- **撤回 #1 ERROR 进对话流**:`util/log.zig` 写 `fd=2`(stderr),与 TUI 的 stdout 分离。log 里 ERROR 与对话交织,是**终端把 stdout+stderr 合并显示**的结果,非 harness bug。用户确认"复制进来的确实是终端显示"佐证。
- **撤回 #2 工具卡双段重复**:`renderStart`/`renderResult` 本就各追加一行落 scrollback(正常设计,一次工具调用=起始卡+完成卡两行),log 平铺整个 scrollback 才显得"重复"。
- **撤回 #5 sleep15 边界竞态**:`bash.zig` 退出判定是单条 if-else 链(`elapsed>=timeout` 先判,再 `elapsed>=effective_budget`,互斥),log 里相邻的 `✓15.0s` 与 `auto_backgrounded` 是**两条不同命令**,非同一条双态。

**教训**:代码能编织任何"看似合理的故事"。真伪靠证据链(grep 到 is_error/fd/分支条件)非推理链。撤回误判和确认真 bug 同等重要。

## §2 4 个真 bug:都是「展示层与语义层耦合错」

| # | 现象 | 根因 | 修复 |
|---|------|------|------|
| #3 | Bash `exit 3` 头部显示 `✓ 0.1s` | `tool_exec.zig` 的 `is_error` 只在 dispatch 抛 Zig error 时 true;Bash 把非零 exit 包成正常 JSON `{"exit_code":3}` 返回,不抛错 → is_error=false → `agent_loop` kind=.ok → 渲染 ✓ | 新增 `headerIcon()` 解耦头部图标:Bash + exit_code≠0 → ✗。**不碰 is_error** |
| #4 | auto-bg 显示 `✓ 15.1s` + 裸吐 JSON | `formatAutoBackgrounded` 返回正常 JSON(无 status、无 exit_code)→ is_error=false → ✓;`renderBashResult` 的 job_id 分支要求 `status!=null` 不命中 → 落 `renderGenericFold` 裸吐整个 JSON | job_id 分支改认 `auto_backgrounded:true` → `▶ moved to background job <id>`;headerIcon 对 auto-bg 返中性 ⏺ |
| #6 | subagent 树 `· 0 tools ·` 恒 0(turn 在涨) | `agent_job_registry` 的 progressTrampoline 只回写 `current_turn`,不回写 `tool_calls`;tool_calls 只在 job 跑完后(jobThreadMain)一次性赋值 → snapshotJobs 执行中读到恒 0 | `progress_fn` 加 `tool_calls` 参数(三处签名链:agent_loop/subagent/agent_job_registry,Zig 编译期强制不漏),trampoline 在 early-return 之前持锁回写 `self.tool_calls` |
| #8 | Task 起始卡被吞(用户对 subagent 启动无感) | `agent_loop` gate `if resultRenderMode(name)==.hidden continue` — Task→hidden → 连起始卡 renderStart 都跳过 | 新增 `showStartCard()` 把「起始卡门控」与「结果门控」分离:Task/Agent 起始卡可见、结果仍 hidden |

**关键设计决策(#3 为何不改 is_error)**:`is_error` 流入 API 请求体的 `tool_result.is_error`。非零 exit 在 cc 语义里是**正常结果**(grep miss、test fail)。若翻转 is_error:(a) 触发跨轮熔断器(turn_any_error)误停;(b) body 渲染走 errorBody 分支丢掉 stdout。所以**纯展示层修复**(只改头部图标)才安全。

**通用模式**:工具的「执行成功(无 Zig error)」≠「业务成功」。非零退出码、转后台、部分失败都是"成功返回了但不是真完成"。头部图标若直接绑 ResultKind(ok/err)会误报。要在展示层按 output 内容细分,不污染影响控制流的 is_error。

## §3 方法论:真模型 e2e 必须区分「漂移 skip」vs「regression fail」

**血泪现场**:bug4 第一遍绿、第二遍 `uses=[]`(模型这次根本没调 Bash)被判 fail → 假红。这不是修复失效,是**真模型漂移**——模型自主决定不调目标工具。

**正确语义**(测试只在被测路径真触发时才能判定):
- 测试内设 `ever_called/triggered` 标志。循环每次重试:只有"被测路径真触发"(模型真调了目标工具 / prose 真出现被测现象)才置 true。
- 重试耗尽后:
  - 从未触发 → `raise SkipTest`(模型漂移,**非失败**)
  - 触发了但行为错 → `raise AssertionError`(**真 regression**)
- runner(`run_tty_tests.py`)加 `except SkipTest` → 计入 skipped、**不计 failed、exit 0**(不污染 CI)。`SkipTest` 定义在 `e2e_helpers.py`。
- **"调了目标工具"还不够精确**:bug4 要额外查 prose 真出现 auto-bg 现象(`"auto_backgrounded"` 或 `background job`)——命令可能秒退没到 15s 阈值,那也是漂移不是 regression。

**与现有节点的关系**:这是「工具失败分类与误报消除策略」的新一类。早期 fragment 解决的是"Missing*字段误报""exit0 静默通过";本条解决的是"模型漂移导致被测路径未触发,不该判 fail"。三者共同点:**失败必须可归因到具体类别,沉默/笼统判负都是反模式**。

**压漂移手段**(与「模型失败的可确定性复现机制」同源):强指令 prompt("Use the X tool to run exactly: ...")+ 确定性命令(`exit 3`/`sleep 20`)+ 重试 3 次。

## §4 方法论:tty 工具卡断言走 prose 通道,非 frame

- 工具卡是 `stdout_writer.print` 裸字节落 **scrollback**(`split_frames` 切出的 `prose` 段),不是 RenderRegion 的 `frame`。断言要 decode prose 段。
- **例外**:agent 进度树是底部 in-frame 面板,用 `frame_screens`(逐帧)断言(bug#6 走这条)。
- strip ANSI 细节:`✗` 夹在 SGR `\x1b[31m`…`\x1b[0m` 里,strip ANSI 后裸 codepoint 保留;`⏺ ✓ ✗ ▶` 是普通 codepoint,strip 不掉。先 strip 再匹配 glyph。
- 一次工具调用产生**两行** `⏺ Bash`(起始卡无状态 + 完成卡带 ✓/✗/▶ + 时长)。图标定位要选**带状态符的完成卡**,不能取第一个匹配(会命中无状态起始卡)。

## §5 验证(2026-06-04 全面 tty 测试,全绿)

- **离线渲染 tty**:62 passed / 0 failed(editing/layout/sgr/wrap/slash/task_tab/ui_tools/generating/...)
- **真模型 e2e**:20 passed / 0 failed(含新增 4 bug + 现有 16 个 A/B 组工具 e2e,0 漂移 skip)
- **zig 单测**:1047/1055 passed(8 skip,0 fail);新增 7 个 DoD 单测(3 tool_card headerIcon/showStartCard + 1 registry progressTrampoline 实时回写 + 反向破坏验证)
- **红→绿铁证**:3 bug 在未修代码上确认真复现(贴出实际渲染 `⏺ Bash ✓ 0.1s` 等);反向破坏 #3 单测 → build test 变红,证明单测真执行(非孤立通过);skip 机制反向验证(改 prompt 让模型不调工具 → 走 SkipTest、runner exit 0)。

## §6 改动文件

- `tests/tty/cases/test_e2e_tui_bugs.py`(新建,4 个 e2e + `_prose_text`/`_card_header_line` helper + skip/regression 区分)
- `tests/tty/e2e_helpers.py`(新增 `SkipTest` 异常)
- `tests/tty/run_tty_tests.py`(runner 识别 SkipTest 计 skipped 不计 failed)
- `src/repl/tui/widget/tool_card.zig`(`headerIcon` / `showStartCard` / `renderBashResult` job_id 分支)
- `src/core/agent_loop.zig`(#6 progress_fn 签名 + 传 total_tool_calls;#8 gate 改 showStartCard)
- `src/core/agent_job_registry.zig`(#6 progressTrampoline 回写 self.tool_calls)
- `src/core/subagent.zig`(#6 SpawnOptions.progress_fn 签名同步)
