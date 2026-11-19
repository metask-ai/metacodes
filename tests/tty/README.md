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
# 单跑某用例 + dump(-k 是纯子串过滤,匹配 `文件名.函数名`):
python3 tests/tty/run_tty_tests.py --bin zig-out/bin/metacodes-debug -k T07 -v
```
退出码:0 全过 / 1 有失败(打印期望 vs 实际屏幕 diff)/ 2 环境错误。

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

**本机并行**:全套逐个跑要近半小时,时间几乎都在等屏幕安静(#588)。`--jobs N` 起 N 个 worker
子进程同时跑,结果汇总成一份,退出码同上:

```bash
TTY_SKIP_MODEL=1 python3 tests/tty/run_tty_tests.py --bin zig-out/bin/metacodes-debug --jobs 3
```

- 只用于离线跑法:不设 `TTY_SKIP_MODEL=1` 时 `--jobs` 报错退出(2)。真模型用例共用用户的一份
  OAuth 凭证(复制进各自的 HOME、用完写回),并行会让两个用例拿同一枚轮换的 refresh token 各自刷新。
- 每个用例有时限(`--case-timeout 秒`,默认 120,最慢的用例约 30s)。超时的用例判失败(结果行标
  `(超时)`),它所在的 worker 连同进程组(用例起的 mock/replay server)和它独占的临时目录
  (worker 的 `TMPDIR`,用例的临时 HOME 都在里面)一起回收,换新的接着跑,一个卡死的用例(#569)
  拖不住整轮。
- 让 metacodes 在固定端口(1455/1457)等登录回调的用例同一时刻只跑一个:整个模块登记在
  `run_tty_tests.EXCLUSIVE_MODULES`,别的模块里提交裸 `/login` 的单个用例登记在 `EXCLUSIVE_CASES`;
  新加这类用例要登记进去。其余用例各用自己的临时 HOME、工作目录和随机端口,可以并行。
- 可以和 `--shard`、`-k` 一起用:先选出用例,再并行跑。不加 `--jobs` 时行为不变(逐个跑、无时限)。
- CI 仍按分片放在多台 runner 上,不在一台上并行。

## 结构

- `screen.py` —— 终端模拟器:最小 ANSI 解释器(CSI A/C/G/K/H/m + \r\n 底部上滚)
  → 虚拟 grid + 光标 + SGR border_class;`char_width` 复刻 `src/repl/tui/term.zig` 的 CJK/emoji 宽度表。
  它的 Zig 移植 `tests/component/vterm.zig` 给组件测试用(不起 pty)。两者由 golden 向量钉成同一行为:
  `vterm_parity.py` 用 screen.py 回放一组固定字节流(手写语义用例 + 固定 seed 随机流)写出
  `tests/fixtures/vterm/screen_parity.jsonl`,`cases/test_vterm_parity.py` 检查它仍是 screen.py 的答案,
  `tests/component/vterm_test.zig` 让 Zig 移植逐 cell 重放同一份。改了 screen.py 的语义就跑
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
| T43/T44 缩窄不叠框 | 空闲框 100→60 列分四步缩窄:重排终端里只剩一个框(上方无旧横线、下方无旧 footer);裁剪终端(`XTERM_VERSION`)里框上方一行不丢 |
| startup_splash | 启动动画原地重绘、定格字标在 banner 上方且只用 Metask Lab 的字母、任意键跳过且这个键进输入框、启动期间(动画中、动画后 App.init 还在等、不播动画时)敲的键按序进输入框、env/config 开关、窄终端不播(帧字节类断言 Windows 跳过:ConPTY 重编码) |
| startup_suggestion | 启动建议的 `git log` 卡住(工作目录的 `.git/HEAD` 是没人写的 FIFO)时首个输入框 1.5 s 内出来、不出建议;一次提交的仓库照常出 `suggestion: explain or improve <文件>`(POSIX) |
| e2e_metask_device(真模型) | Metask 设备码登录(程序化确认)→ 经网关请求真实模型 → 本地账本每请求带 X-Metask-Request-Id → `scripts/metask_reconcile.py` 与网关 /v1/usage 对账零差异;需 METASK_WEB_SESSION_TOKEN、METASK_SITE_URL、METASK_MODELS |
| phase_ownership 阶段拥有 widget(#330) | 回复里打开的 agent 列表(`↓ to manage`)与 `?` help 不进入下一次提示:列表不吞下一次输入(#298 的症状),空闲 footer 不被 help 盖住;离线(slow mock server) |
| redraw_coalesce 重画合并窗口(#328) | 突发流每行到齐且有序、帧数 < 行数/2;静默等待里 spinner 仍在动;回复中突发打字每键回显、帧数 < 键数/2;突发流中 resize 只剩一个框;中断后提示符回来、已流出的文本完整;突发后立刻 `/exit` 干净;WebSearch 结果行在卡离场前上屏。帧数断言只在 POSIX(ConPTY 重编码) |
| keyboard_probe 键盘协议探测 | 认不出的终端启动时被问 `CSI ? u` + DA1(驱动按场景应答):答了 Kitty flags → 发 `\x1b[>1u`、多行提示 shift+⏎;只答 DA1 / 不答 → 不发、提示 \+⏎;应答之间夹着的提前敲的键回放进输入框;迟到的应答(DA1、Kitty、OSC 11)不漏成字符;deny-list / tmux / `METACODES_NO_PROBE` 不问(#327;POSIX,Windows console 不探测) |
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
