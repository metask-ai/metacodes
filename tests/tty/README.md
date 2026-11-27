# metacodes 系统化 TTY 测试框架

把 RenderRegion(底部锚定输入框)emit 的 ANSI 字节流**回放成虚拟屏幕网格**,
从而像人眼一样断言 TUI 布局/光标/钉底,自动发现渲染 bug(跳动/错位/残留/resize 不生效)。

**不打真实模型、零 token**:打字阶段不提交;提交类用例只用本地命令(`/help`/`/exit`)。
用 Python 标准库(`pty`/`os`/`select`/`termios`),macOS 自带 python3 即可。

## 跑法

```bash
# 先编译,再跑(独立 runner,不经 zig build —— PTY 在 build-runner 下时序不稳)
zig build dev
zig build test:harness  # e2e cases that need mock_mcp_server/replay_server
TTY_SKIP_MODEL=1 python3 tests/tty/run_tty_tests.py --bin zig-out/bin/metacodes-debug
# 按域过滤(见 tests/tty/domains.json;逗号分隔,空值/未设 = 全量;与 --shard/--jobs 兼容):
TTY_SKIP_MODEL=1 python3 tests/tty/run_tty_tests.py --bin zig-out/bin/metacodes-debug --domains mcp,smoke
# 单跑某用例 + dump(-k 是纯子串过滤,匹配 `文件名.函数名`):
python3 tests/tty/run_tty_tests.py --bin zig-out/bin/metacodes-debug -k T07 -v
```
退出码:0 全过 / 1 有失败(打印期望 vs 实际屏幕 diff)/ 2 环境错误。

**本机并行**(#588):套件几乎全部时间在等屏幕静默,不是在算;`--jobs N` 在本机同时跑 N 片,
按完成顺序打印每条结果,最后合并成一份汇总(退出码同上):

```bash
TTY_SKIP_MODEL=1 python3 tests/tty/run_tty_tests.py --bin zig-out/bin/metacodes-debug --jobs 3
```

- 分片与 CI 相同(`select_shard`,见下);每片是一个子进程,完整输出写在临时目录 `tty-jobs-*`
  里,开头打印路径,有失败时保留。可与 `-k` 同用,不能与 `--shard` 同用。
- 占用本机固定资源的用例(固定端口、固定路径)用 `tty_driver.runs_alone("占的是什么")` 标记,
  `--jobs` 把它们留到并行阶段之后单独逐个跑;现有的是 `test_login` 里断言 OAuth 回调端口
  1455/1457 的两条。用例的临时目录(`case_tmpdir`)、HOME(`run()` 的临时 HOME)和 mock server
  端口(绑 0)本来就各用各的,不用标。新用例要用固定端口或固定路径,就标上它。
- 每条用例有时限:`--jobs` 下默认 300s(`--case-timeout S` 可改;串行默认不限,与以前一样)。
  POSIX 上到点打断该用例、杀掉它起的程序、判失败,接着跑下一条;打断不了的,父进程再等 60s
  杀掉整片,它跑着的和没跑的用例都判失败。一个挂死的用例(#569)拖不住整个套件。
- 断言 pty 时序的用例在多片同时跑时也要稳;某条只在 `--jobs` 下失败,先单独重跑它
  (`-k`)确认,再当作时序脆弱的用例修。

`TTY_SKIP_MODEL=1` 是离线跑法:打真实模型的用例(`test_e2e_*`、`test_generating`、
`test_slash_menu` 的 T17/T19)经 `e2e_helpers.require_model()` 报 skip,不计为通过。

**CI**:`.github/workflows/ci.yml` 的 `TTY (Linux)` 按上面的命令跑离线全套;`TTY (Windows)`
跑 `zig build windows:tty -Dtarget=x86_64-windows-gnu`(ConPTY,需 `pip install pywinpty`)。
在此之前套件不在任何 workflow 里,12 个 agent 树用例挂了几周没人发现(#218、#222)。
两者都按 `TTY_SHARD=K/N` 拆到多台 runner(Linux 3 片、Windows 8 片),`TTY (Linux)` /
`TTY (Windows)` 是汇总各片结果的 result job(doc/CI_DESIGN.md §4)。本地复现某一片:

```bash
python3 tests/tty/run_tty_tests.py --bin zig-out/bin/metacodes-debug --shard 2/3
```

## 结构

- `screen.py` —— 终端模拟器:最小 ANSI 解释器(CSI A/C/G/K/H/m + \r\n 底部上滚)
  → 虚拟 grid + 光标 + SGR border_class;`char_width` 读 `terminal_width.py`,即 `scripts/gen_char_width.py`
  从 Unicode 数据生成的终端宽度表(零宽字符挂在前一格上),不照抄 TUI 自己的估算(`apps/cli/src/repl/tui/term.zig`)。
  它的 Zig 移植 `apps/cli/tests/component/vterm.zig` 给组件测试用(不起 pty)。两者由 golden 向量钉成同一行为:
  `vterm_parity.py` 用 screen.py 回放一组固定字节流(手写语义用例 + 固定 seed 随机流)写出
  `tests/fixtures/vterm/screen_parity.jsonl`,`cases/test_vterm_parity.py` 检查它仍是 screen.py 的答案,
  `apps/cli/tests/component/vterm_test.zig` 让 Zig 移植逐 cell 重放同一份。改了 screen.py 的语义就跑
  `python tests/tty/vterm_parity.py --write` 并让 vterm.zig 跟上。
- `tty_driver.py` —— `run(bin, key_events, term_size)`:fork pty + TIOCSWINSZ + 键名映射
  (`type:文本`/`key:shift_enter|backspace|left|right|shift_tab|ctrl_u|enter`/`sleep:N`/
  `strictsleep:N`/`wait:PATTERN:N`/`waitbytes:ESC:N`/`resize:RxC`/`resize-now:RxC`)。锁 `FORCE_COLOR=1` 让 accent/warn SGR 稳定可断言;
  默认 `METACODES_NO_STARTUP_ANIMATION=1` 关掉启动动画(布局类用例断言的是它之后的画面),
  `test_startup_splash` 经 env 参数传 `None` 打开。
  **等待语义(事件+上限结合)**:`sleep:N` 是 settle 睡眠——至多 N 秒,输出流静默 0.8s 即提前返回
  (生成/工具执行期 spinner 每 100ms 重画,流不静默 → 静默 ⇔ turn 结束/等输入,N 只是最坏兜底);
  逐帧时序断言、"N 秒内不出现 X"类否定窗口必须用 `strictsleep:N`(睡满);已知等待内容时用
  `wait:PATTERN:N`(等屏幕出现 PATTERN,命中后短 settle 防半帧)。两后端(POSIX pty/ConPTY)
  共享同一份 `_Capture` 实现,平台差异只在"读一片字节"原语内。
  **收尾**也只有一份(`_Capture.finish`):最后一个事件之后收到输出静默 0.6s 为止(上限 6s),
  只为收齐已在路上的字节。断言哪一刻的画面由用例的事件写明——#220 之前 POSIX 固定收 0.5s、
  ConPTY 等静默,同一用例在两个平台上断言的是不同时刻。POSIX 关掉终端后至多等子进程 15s,
  不退出就 SIGKILL 并判该用例失败(以前无超时 `waitpid`,会挂死整个 runner)。
  POSIX **写入**时一直读程序的输出:macOS 的 pty 每个方向只缓冲约 1 KiB,程序在读输入之前先写出
  更多时,只写不读的驱动和它会互相等、永远卡住(#569);程序 `WAIT_S`(20s)内一个字节也不读,
  该用例失败。用例出错或被打断时(收尾、等子进程退出的时候也算),驱动先关掉终端,再杀掉并回收
  程序(终端开着时,macOS 上输出没被读走的程序退不干净),然后把异常交出去。
- `asserts.py` —— 切帧(`ESC[?25l`..`ESC[?25h` 光标对)+ `TTYAssert`
  (box_at_bottom/single_box/no_jitter/input_echo/border_class/footer_mode/box_height/clean_exit/...)。
- **resize 回放**:默认整条流按最终尺寸回放,看不到 resize 那一刻终端对旧画面做了什么。
  `run(..., resizes=lst)` 记下起始尺寸和每个 `resize:` 落在输出流的字节偏移,
  `TTYAssert(raw, resizes=lst)` 从起始尺寸回放、在同一偏移调 `Screen.resize`:默认按现代终端
  (iTerm2、Terminal.app、kitty、xterm.js、tmux……)把软折的行拼成逻辑行再按新宽度重排,
  `reflow=False` 是 xterm / GNU screen 式裁剪;`autowrap=True` 让比终端宽的行在画的那一刻就折行。
  Windows 上忽略:resize 后 ConPTY 的 conhost 自己重画整屏;它裁剪、不重排已显示的行,
  metacodes 在 Windows 上也就按裁剪终端爬行(`term.reflowFromEnv`)。
- `cases/*.py` —— T01-T13 用例(每个 `def test_*(bin_path)`)。用例自建的临时目录(工作目录、
  指定的 HOME)用 `tty_driver.case_tmpdir(prefix)`,runner 在每个用例结束后删,失败也删;
  缺依赖(replay_server、mock_mcp_server)时 `raise SkipTest`,不要 `return`。
- `run_tty_tests.py` —— 收集 cases、跑、屏幕 diff、汇总;`--shard K/N` 跑一片,`--jobs N` 在本机
  并行跑 N 片并合并结果(`cases/test_runner_shards.py` 钉死分片与合并:每条用例恰好跑一次、计一次)。

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
| T43/T44/T48/T49 缩窄不叠框 | 空闲框 100→60 列分四步缩窄:重排终端里只剩一个框(上方无旧横线、下方无旧 footer);裁剪终端(`XTERM_VERSION`,或启动探测里 XTVERSION 答 `XTerm(…)`、DA2 答 PuTTY 的 `0;136;0`)里框上方一行不丢 |
| startup_splash | 启动动画原地重绘、定格字标在 banner 上方且只用 Metask Lab 的字母、任意键跳过且这个键进输入框、启动期间(动画中、动画后 App.init 还在等、不播动画时)敲的键按序进输入框、env/config 开关、窄终端不播(帧字节类断言 Windows 跳过:ConPTY 重编码) |
| startup_suggestion | 启动建议的 `git log` 卡住(工作目录的 `.git/HEAD` 是没人写的 FIFO)时首个输入框 1.5 s 内出来、不出建议;一次提交的仓库照常出 `suggestion: explain or improve <文件>`(POSIX) |
| e2e_metask_device(真模型) | Metask 设备码登录(程序化确认)→ 经网关请求真实模型 → 本地账本每请求带 X-Metask-Request-Id → `scripts/metask_reconcile.py` 与网关 /v1/usage 对账零差异;需 METASK_WEB_SESSION_TOKEN、METASK_SITE_URL、METASK_MODELS |
| phase_ownership 阶段拥有 widget(#330) | 回复里打开的 agent 列表(`↓ to manage`)与 `?` help 不进入下一次提示:列表不吞下一次输入(#298 的症状),空闲 footer 不被 help 盖住;离线(slow mock server) |
| redraw_coalesce 重画合并窗口(#328) | 突发流每行到齐且有序、帧数 < 行数/2;静默等待里 spinner 仍在动;回复中突发打字每键回显、帧数 < 键数/2;突发流中 resize 只剩一个框;中断后提示符回来、已流出的文本完整;突发后立刻 `/exit` 干净;WebSearch 结果行在卡离场前上屏。帧数断言只在 POSIX(ConPTY 重编码) |
| keyboard_probe 键盘协议探测 | 认不出的终端启动时被问 `CSI ? u` + DA1(驱动按场景应答):答了 Kitty flags → 发 `\x1b[>1u`、多行提示 shift+⏎;只答 DA1 / 不答 → 不发、提示 \+⏎;应答之间夹着的提前敲的键回放进输入框;迟到的应答(DA1、Kitty、OSC 11)不漏成字符,其中的 Kitty 应答(启动期间到的、输入框里到的)补发 `\x1b[>1u`、提示跟着变 shift+⏎,`/exit` 和崩溃时照样关;deny-list / tmux / `METACODES_NO_PROBE` / `METACODES_NO_KEYBOARD_ENHANCEMENT` 不问(#327;POSIX,Windows console 不探测);`METACODES_NO_KEYBOARD_ENHANCEMENT` 在认得出的终端里也不发 `\x1b[>1u`、`\x1b[>4;2m`,退出时也不发关闭序列 |
| T45-T47 resize 打断按键 | ESC、resize、`[A` 在一次 ESC 等待内先后到达:反向搜索不被取消、transcript viewer 不被关掉,`[A` 不漏进输入框(#340);单按 Esc 不等下一个键就关 viewer(POSIX;ConPTY 无 SIGWINCH,T45/T46 跳过) |

## 已发现并修复的 bug
- **输入框跳动**(T07):回顶用 `prev_rows`(总行数)而非 `cursor_row`(光标实际行)→ 逐帧上漂。
- **resize 不生效**(T12):无 SIGWINCH handler,要按键才刷新 → 装 handler + poll 循环。
- **提交后用户输入消失**(T13):commit 只清框不回显 → 加 `❯ <输入>` 回显到 scrollback。
- **缩窄窗口后横线和 footer 越叠越多**(T43,`test_wrap_resize` 的 T13/T14/T15):终端把画满一行的
  横线重排成两行,回顶仍按画的时候的行数爬 → 停在旧框里,上方留旧横线、下方留旧 footer(生成期留旧
  spinner 行,对话框叠第二份)→ 每帧记下光标上方各行宽度,按现在的宽度数行回顶(`tui/reflow.zig`),
  回顶后 ED 0 清到屏底;xterm/GNU screen/Linux 控制台不重排,仍按画的时候的行数(T44)。
- (澄清)中文 `�` 是旧 pty_probe 逐字节 write 拆断 UTF-8 所致,非 cc-zig bug。

新增/改渲染逻辑后,跑本框架 + 真机确认。渲染架构见 `doc/TUI_STATE_ARCHITECTURE.md`。
