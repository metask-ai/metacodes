# metacodes 系统化 TTY 测试框架

把 RenderRegion(底部锚定输入框)emit 的 ANSI 字节流**回放成虚拟屏幕网格**,
从而像人眼一样断言 TUI 布局/光标/钉底,自动发现渲染 bug(跳动/错位/残留/resize 不生效)。

**不打真实模型、零 token**:打字阶段不提交;提交类用例只用本地命令(`/help`/`/exit`)。
用 Python 标准库(`pty`/`os`/`select`/`termios`),macOS 自带 python3 即可。

## 跑法

```bash
# 先编译,再跑(独立 runner,不经 zig build —— PTY 在 build-runner 下时序不稳)
zig build
python3 tests/tty/run_tty_tests.py --bin zig-out/bin/metacodes-debug
# 单跑某用例 + dump:
python3 tests/tty/run_tty_tests.py --bin zig-out/bin/metacodes-debug -k T07 -v
```
退出码:0 全过 / 1 有失败(打印期望 vs 实际屏幕 diff)/ 2 环境错误。

## 结构

- `screen.py` —— 终端模拟器:最小 ANSI 解释器(CSI A/C/G/K/H/m + \r\n 底部上滚)
  → 虚拟 grid + 光标 + SGR border_class;`char_width` 复刻 `src/repl/tui/term.zig` 的 CJK/emoji 宽度表。
- `tty_driver.py` —— `run(bin, key_events, term_size)`:fork pty + TIOCSWINSZ + 键名映射
  (`type:文本`/`key:shift_enter|backspace|left|right|shift_tab|ctrl_u|enter`/`sleep:N`/
  `strictsleep:N`/`wait:PATTERN:N`/`resize:RxC`)。锁 `FORCE_COLOR=1` 让 accent/warn SGR 稳定可断言。
  **等待语义(事件+上限结合)**:`sleep:N` 是 settle 睡眠——至多 N 秒,输出流静默 0.8s 即提前返回
  (生成/工具执行期 spinner 每 100ms 重画,流不静默 → 静默 ⇔ turn 结束/等输入,N 只是最坏兜底);
  逐帧时序断言、"N 秒内不出现 X"类否定窗口必须用 `strictsleep:N`(睡满);已知等待内容时用
  `wait:PATTERN:N`(等屏幕出现 PATTERN,命中后短 settle 防半帧)。两后端(POSIX pty/ConPTY)
  共享同一份 `_Capture` 实现,平台差异只在"读一片字节"原语内。
- `asserts.py` —— 切帧(`ESC[?25l`..`ESC[?25h` 光标对)+ `TTYAssert`
  (box_at_bottom/no_jitter/input_echo/border_class/footer_mode/box_height/clean_exit/...)。
- `cases/*.py` —— T01-T13 用例(每个 `def test_*(bin_path)`)。
- `run_tty_tests.py` —— 收集 cases、跑、屏幕 diff、汇总。

## 用例(对齐 Claude Code 布局/交互)

| 用例 | 抓什么 |
|------|--------|
| T01 空框布局 | 四行框(╭/❯/╰/footer)、footer 文案、初始光标 col=2 |
| T02 ASCII 回显 | 字符回显 + 光标跟随 |
| T03 中文回显 | CJK 宽度(2 列/字)+ 光标列正确 |
| T04 退格+左右 | UTF-8 边界删除/移动 |
| T05 Shift+Enter 多行 | 框增高、跨行光标定位 |
| T06 窄终端软折 | 长行不冲破边框 |
| T07 无跳动(核心) | 框顶行号逐帧恒定(回归点:cursor_row 回顶) |
| T08 shift+tab 切模式 | footer (mode) + plan 边框变黄 |
| T09 Ctrl+U 清行 | 框缩回单行、无残留 |
| T10 提交本地命令 | 框清→/help 输出→新框回底部 |
| T11 退出清理 | 无残留边框、show cursor、Goodbye |
| T12 resize 自适应 | SIGWINCH → 框自动变宽(不按键) |
| T13 提交回显 | 提交后用户输入留在 scrollback(❯ 行) |
| e2e_metask_device(真模型) | Metask 设备码登录(程序化确认)→ 经网关请求真实模型 → 本地账本每请求带 X-Metask-Request-Id → `scripts/metask_reconcile.py` 与网关 /v1/usage 对账零差异;需 METASK_WEB_SESSION_TOKEN、METASK_SITE_URL、METASK_MODELS |

## 已发现并修复的 bug
- **输入框跳动**(T07):回顶用 `prev_rows`(总行数)而非 `cursor_row`(光标实际行)→ 逐帧上漂。
- **resize 不生效**(T12):无 SIGWINCH handler,要按键才刷新 → 装 handler + poll 循环。
- **提交后用户输入消失**(T13):commit 只清框不回显 → 加 `❯ <输入>` 回显到 scrollback。
- (澄清)中文 `�` 是旧 pty_probe 逐字节 write 拆断 UTF-8 所致,非 cc-zig bug。

新增/改渲染逻辑后,跑本框架 + 真机确认。渲染架构见 `doc/TUI_STATE_ARCHITECTURE.md`。
