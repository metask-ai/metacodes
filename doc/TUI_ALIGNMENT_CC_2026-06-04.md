# TUI_ALIGNMENT_CC_2026-06-04 — cc-zig TUI 对齐 Claude Code 差距矩阵 + 实施记录

> 来源:2026-06-04 session。用户要求 cc-zig TUI 交互完全对齐 Claude Code,并修两个具体问题(esc 双击、Edit diff 背景非矩形)。
> 调研方式:3 路 cc-zig 现状 Explore + 3 路 CC(cc/ TS 源码)实锤 Explore。
> 关联现有图谱根:TUI_DESIGN、TUI_COMPONENTS、UI_LAYER_DESIGN、EDIT_DIFF_HIGHLIGHT_DESIGN、TUI_PARITY_PLAN。

## §1 esc 取消语义(核实:cc-zig 现状≠用户预期≠CC)

- **cc-zig 现状**:two-tier 设计(loop.zig:471-479 stdinAbortWatcher)。生成中按 esc:框非空→第一次只清框(不中断)、框空→才 abort。用户报"要按两次"的真因。
- **CC 真实**:单 esc → `chat:cancel`(cc/src/keybindings/defaultBindings.ts:66),生成中直接中断,不拦截。
- **决策**:对齐 CC,单 esc 直接中断。改进:abort 前把框内容入队(不丢用户已打的字)。
- **不动**:纯输入期 esc-esc 清草稿(input.zig:488-495,不同 editor + 时机互斥,已确认不重叠)。

## §2 Edit diff 背景非矩形(根因 + CC 实锤机制)

- **cc-zig 根因**(tool_card.zig:appendDiffLine 652-689):① sign 字符后过早 `th.reset`(678 行)断背景;② 缺行尾填充(没 padEnd 到列宽,也没 `\x1b[K`);③ 行号列在背景块外;④ 语法高亮逐 token 重铺背景显抖动。
- **CC 实锤机制**(cc/src/native-ts/color-diff/index.ts):
  - 713-723:`' '.repeat(width - curW)` 补空格到终端宽度,**空格携带背景色** → 整行矩形(字符串级 ANSI,非 Box backgroundColor)。
  - 726-744:行号在背景块内(首行 ` {num} `、续行全空格对齐)。
  - 747-756:sign(+/-)也在同一 lineBackground 背景块。
  - 768-817 applyBackground:前景语法高亮与背景独立(只改 background 不动 foreground)。
  - 暗色主题色:addLine rgb(2,40,0)、deleteLine rgb(61,1,0)、addWord/deleteWord 更深。
- **决策**:appendDiffLine 加 width 参数,sign+行号+内容+行尾填充全在同一背景块,padEnd 到列宽(减 gutter 缩进)。basic_16/mono(bg="")退化不画块。

## §3 快捷键差距矩阵

**cc-zig 已有(40+)**:Ctrl+A/C/D/E/G/K/L/O(transcript)/R(history)/T(tasktab)/U/W/X(前缀)/Y(yank)、方向键、Home/End/Delete/Backspace、Tab/Shift+Tab(模式循环)、Alt+B/F(词)、Shift+Enter/Ctrl+Enter(换行)、bracketed paste、`!` 行首 bash。

**CC 有 cc-zig 缺**:
| 键 | CC 行为 | cc-zig 决策 |
|----|---------|------------|
| Ctrl+_ / Ctrl+Shift+- | undo | **建 undo 子系统做**(用户选) |
| `?` 行首 | shortcuts 帮助 | **补**(loop.zig 命令派发) |
| Ctrl+B | 后台当前 agent | 若 agent_job_registry 支持则补 |
| Ctrl+S | stash | 评估,低优先 |
| Ctrl+Shift+F | 全局搜索 | **不做**(需索引子系统,非 TUI 对齐范畴) |
| Ctrl+Shift+P | quick-open | **不做**(需文件索引) |
| Space(push-to-talk) | voice | **不做**(无音频栈) |

**CC 保留键(终端/OS 拦截,双方都不能改)**:Ctrl+C/D(硬编码 interrupt/exit)、Ctrl+M(=Enter)、Ctrl+Z(SIGTSTP)、Ctrl+\(SIGQUIT)、macOS cmd+*。

**undo 子系统设计(cc-zig 新增)**:LineEditor 加 undo_stack(存 {buf 快照,cursor}),破坏性编辑前 push(连续同类去抖),Ctrl+_ pop 恢复。栈深上限防膨胀,deinit 全释放。参考现有 yank_buf owned 状态模式(input.zig:325)。

## §4 spinner 字段(cc-zig 已接近 CC)

- **cc-zig**(status_bar.zig:61-126):`{fr} {verb}… ({secs}s · ↑{in} ↓{out}{rate} · ${cost} · esc to interrupt)`,帧 `✻✦✶✺✷✸`,~50 动词,100ms tick。
- **CC**(Spinner/SpinnerAnimationRow.tsx):`{glyph} {verb}… ( {elapsed} · {↓N tokens} · {thinking} )` + esc 提示,200+ 动词,50ms tick,有 shimmer/stall 检测。
- **决策**:微调为主(分隔符统一 `·`),保留 cc-zig 双向 token(↑↓ 信息更全,不退化成 CC 单向)。100ms tick 保持。

## §5 footer(决策:完全对齐 CC)

- **cc-zig 现**(render_region.zig:drawFooter 521-547):`? for shortcuts · shift+tab to cycle ({mode})` 左 + `{tok} tokens` 右。
- **CC**(PromptInput/PromptInputFooterLeftSide.tsx):`{mode_symbol} {mode} on · shift+tab to cycle` + 动态 hints(优先级:loading→esc to interrupt、有 agent→{key} to stop agents、空闲→? for shortcuts)。
- **决策**:完全改成 CC 风格。同步更新 test_mode_commit/test_layout 旧文案断言。输入框 borderStyle 已 round,与 CC 一致不改。

## §6 实施状态(2026-06-04)

5 块按依赖实施:① esc 单击中断 ② diff 整块矩形 ③ 快捷键+undo 子系统 ④ spinner 微调 ⑤ footer 完全对齐。验证:tool_card diff L2 单测 + test_generating esc 测试更新 + zig build test 全绿 + test:e2e-tty 20 用例无回归。详见 git log 与 doc/PLAN(metaknow)。
