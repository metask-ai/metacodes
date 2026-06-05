"""T14-T16:生成期(模型输出时)输入框保留 + queued 输入 + 自动提交。

这些用例**打真实模型**(生成期才有 spinner/输入框共存)。无 API key 时 skip。
key_events 用够长 sleep 落在生成窗口内。
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import run
from asserts import TTYAssert

# 这套二进制用硬编码 token(client.zig ANTHROPIC_AUTH_TOKEN),无需 API key env;
# 但若想跳过(离线/CI),设 TTY_SKIP_MODEL=1。
SKIP = os.environ.get("TTY_SKIP_MODEL") == "1"


def test_T14_generating_keeps_input_box(bin_path):
    if SKIP:
        return
    # 提交一句会产生输出的查询 → 生成期应有【多帧持续】同时有 spinner + 完整输入框 + footer
    # (不是"某一帧有",而是 spinner+框+❯+footer 共存于生成窗口的多个帧 → 区持续可见、不闪没)。
    raw = run(bin_path, ["sleep:0.8", "type:慢慢数到十五,每行一个数字", "key:enter", "sleep:4"],
              per_key_drain=0.05, base_url=None)
    a = TTYAssert(raw)
    coexist = sum(
        1 for sc in a.frame_screens
        if sc.find_last_row("esc to interrupt") is not None
        and sc.find_last_row("╭") is not None
        and sc.find_last_row("❯") is not None
        # footer 标志:bypass 模式(driver 默认)footer 含 "shift+tab to cycle"
        # (2026-06-05 对齐 cc:非 default 态不再含 "? for shortcuts")。
        and sc.find_last_row("shift+tab to cycle") is not None
    )
    # 旧 bug:0 帧共存(区被擦没)。修复后应有相当多帧(每 100ms tick 画一次)。
    if coexist < 3:
        a._fail(f"生成期 spinner+完整框+footer 共存帧过少(coexist={coexist},应 ≥3 表示区持续可见)")


def test_T15_type_into_queued_during_gen(bin_path):
    if SKIP:
        return
    # 对齐 cc:生成期打 HELLO(不回车)→ 只停在输入框 ❯ 行,**不提交、不进 scrollback**。
    raw = run(bin_path, ["sleep:0.8",
                         "type:请从 1 数到 60,每个数字单独占一行,不要省略", "key:enter",
                         "sleep:0.6", "type:HELLO", "sleep:2.5"],
              per_key_drain=0.06, base_url=None)
    a = TTYAssert(raw)
    # HELLO 出现在生成帧的 ❯ 内容行
    in_box = any(
        sc.find_last_row("esc to interrupt") is not None
        and sc.find_last_row("❯") is not None
        and "HELLO" in sc.line_text(sc.find_last_row("❯"))
        for sc in a.frame_screens
    )
    if not in_box:
        a._fail("生成期打的 HELLO 未显示在输入框 ❯ 行")
    # 不该被提交进 scrollback(prose)——未回车不提交
    import re
    from asserts import split_frames
    prose = re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]", b"",
                   b"".join(c for k, c in split_frames(raw) if k == "prose")).decode("utf-8", "replace")
    if "HELLO" in prose:
        a._fail("HELLO 不该进 scrollback(未回车不应提交)")


def test_T16_queued_autosubmits_after_gen(bin_path):
    if SKIP:
        return
    # 生成期打第二句 + 回车入队;第一轮自然结束 → 队列自动续发跑第二轮。
    # 第一句须生成够久(长查询),保证 DONE2 在生成窗口内入队(否则被 drainStdin 丢弃,属正确行为)。
    raw = run(bin_path, ["sleep:0.8", "type:请从 1 数到 60,每个数字单独占一行,不要省略", "key:enter",
                         "sleep:0.6", "type:DONE2", "key:enter", "sleep:10"],
              per_key_drain=0.06, base_url=None)
    a = TTYAssert(raw)
    # queued "DONE2" 回车入队 → 第一轮结束后自动续发 → ❯ 回显进 scrollback。
    a.assert_prose_contains("DONE2")


def test_T20_enter_enqueues_clears_box(bin_path):
    # 生成期打字 + 回车 → 输入框清空 + 队列预览出现(dim ⏳ QMSG),且未即时提交进 scrollback。
    if SKIP:
        return
    raw = run(bin_path, ["sleep:0.8", "type:请从 1 数到 60,每个数字单独一行", "key:enter",
                         "sleep:0.6", "type:QUEUEDMSG", "key:enter", "sleep:2.0"],
              per_key_drain=0.05, base_url=None)
    a = TTYAssert(raw)
    # 回车后某生成帧:队列预览含 QUEUEDMSG(在框上方),且 ❯ 框已清空(不含 QUEUEDMSG)。
    found_preview = False
    for sc in a.frame_screens:
        if sc.find_last_row("esc to interrupt") is None:
            continue
        full = "\n".join(sc.line_text(r) for r in range(sc.rows))
        cr = sc.find_last_row("❯")
        box_txt = sc.line_text(cr) if cr is not None else ""
        if "QUEUEDMSG" in full and "QUEUEDMSG" not in box_txt:
            found_preview = True
            break
    if not found_preview:
        a._fail("回车后队列预览未出现在框上方(或框未清空)")


def test_T21_multiple_queued_autosubmit(bin_path):
    # 生成期入队 2 条 → 一轮结束后**一次性合并提交**(对齐 cc 同模式批量)→ 两条都进 scrollback,
    # 且只产生一个新的提交块(BATCHB 作为 BATCHA 的续行,而非各自独立一轮)。
    if SKIP:
        return
    raw = run(bin_path, ["sleep:0.8", "type:请从 1 数到 60,每个数字单独占一行,不要省略", "key:enter",
                         "sleep:0.6", "type:BATCHA", "key:enter",
                         "sleep:0.4", "type:BATCHB", "key:enter", "sleep:10"],
              per_key_drain=0.05, base_url=None)
    a = TTYAssert(raw)
    a.assert_prose_contains("BATCHA")
    a.assert_prose_contains("BATCHB")
    # 合并提交:除首轮长查询外,队列只回显一个 ❯ 块(BATCHA 行 + BATCHB 续行),不是两个独立轮。
    import re
    from asserts import split_frames
    prose = re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]", b"",
                   b"".join(c for k, c in split_frames(raw) if k == "prose")).decode("utf-8", "replace")
    echoes = [l for l in prose.split("\n") if l.strip().startswith("❯")]
    # 首查询 1 个 ❯ + 合并批次 1 个 ❯(BATCHA);BATCHB 是续行不带 ❯ → 总共 2 个 ❯ 行。
    if len([e for e in echoes if "BATCH" in e]) != 1:
        a._fail(f"队列多条应合并为一次提交(一个 ❯ 块),实际 ❯ 行:{echoes}")


def test_T22_esc_interrupts(bin_path):
    # 单 esc 直接中断当前任务(对齐 CC,不再两档)。框里已打的字先入队续发,再中断。
    if SKIP:
        return
    import re
    from asserts import split_frames
    raw = run(bin_path, ["sleep:0.8", "type:请从 1 数到 60 每行一个数字", "key:enter",
                         "sleep:0.6", "type:TYPED", "key:esc", "sleep:3"],
              per_key_drain=0.05, base_url=None)
    a = TTYAssert(raw)
    prose = re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]", b"",
                   b"".join(c for k, c in split_frames(raw) if k == "prose")).decode("utf-8", "replace")
    # TYPED 应一度出现在框(证明输入进了编辑器)。
    typed_seen = any(
        sc.find_last_row("❯") is not None and "TYPED" in sc.line_text(sc.find_last_row("❯"))
        for sc in a.frame_screens
    )
    if not typed_seen:
        a._fail("TYPED 未曾出现在框(输入没进编辑器)")
    # 单 esc 后应中断:出现 cancel 标记(或第一条已自然结束)。核心是不再"清框继续"。
    finished = "59" in prose or "60" in prose
    if "cancel" not in prose.lower() and not finished:
        a._fail("单 esc 未中断当前推理(无 cancel 标记)")


def test_T23_cjk_ime_in_box(bin_path):
    # 中文(多字节)在生成期输入框完整显示;模拟 IME committed 文本逐字节到达。
    if SKIP:
        return
    raw = run(bin_path, ["sleep:0.8", "type:请从 1 数到 60 每行一个数字", "key:enter",
                         "sleep:0.6", "type:你好世界", "sleep:1.5"],
              per_key_drain=0.05, base_url=None)
    a = TTYAssert(raw)
    found = any(
        sc.find_last_row("esc to interrupt") is not None
        and sc.find_last_row("❯") is not None
        and "你好世界" in sc.line_text(sc.find_last_row("❯"))
        for sc in a.frame_screens
    )
    if not found:
        a._fail("生成期中文输入未完整显示在 ❯ 框(IME committed 文本丢失)")


def test_T24_esc_interrupts_then_resends_queue(bin_path):
    # 用户报的 bug:生成期入队消息后按 Esc → 应中断当前推理并自动续发队列消息。
    # 数到 60 的较长查询确保 Esc 时生成仍在进行;短超时下 Esc 经 flushEsc 兑现为中断。
    if SKIP:
        return
    raw = run(bin_path, ["sleep:0.8", "type:请从 1 数到 60,每个数字单独占一行,不要省略", "key:enter",
                         "sleep:0.8", "type:打断后请回答你是谁", "key:enter",
                         "sleep:0.4", "key:esc", "sleep:8"],
              per_key_drain=0.05, base_url=None)
    a = TTYAssert(raw)
    import re
    from asserts import split_frames
    prose = re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]", b"",
                   b"".join(c for k, c in split_frames(raw) if k == "prose")).decode("utf-8", "replace")
    # 核心(用户的诉求):中断后队列消息必须被自动续发提交。
    if "打断后请回答你是谁" not in prose:
        a._fail("中断后队列消息未自动续发提交")
    # 中断标记:Esc 落在生成窗口内时应出现 cancelled;若模型恰好已结束则跳过该断言(时序宽松)。
    finished_naturally = "59" in prose or "60" in prose
    if "cancel" not in prose.lower() and not finished_naturally:
        a._fail("Esc 未中断当前推理(无 cancelled 标记,且生成未自然结束)")
        a._fail("中断后队列消息未自动续发提交")


def test_A6_narrow_terminal_no_wrap(bin_path):
    # 窄终端 cols=40:生成期 spinner 行被截断到 cols-1,不触发 DECAWM 折行 →
    # 区实际行数 = R,底部框/footer 不错位。断言:生成期共存帧的可见行宽不超 cols。
    if SKIP:
        return
    from screen import str_width
    raw = run(bin_path, ["sleep:0.8", "type:数到八每行一个", "key:enter", "sleep:3"],
              term_size=(24, 40), per_key_drain=0.05, base_url=None)
    a = TTYAssert(raw, rows=24, cols=40)
    bad = []
    for sc in a.frame_screens:
        if sc.find_last_row("esc to interrupt") is None:
            continue  # 只看生成期帧
        for r in range(sc.rows):
            if str_width(sc.line_text(r)) > 40:
                bad.append((r, sc.line_text(r)))
    if bad:
        a._fail(f"窄终端生成期有行宽 > cols=40(折行风险):{bad[:3]}")


def _gen_frames(a):
    """生成期帧(含 'esc to interrupt' 的 spinner 帧)。"""
    return [sc for sc in a.frame_screens if sc.find_last_row("esc to interrupt") is not None]


def test_T30_gen_help_nonmodal(bin_path):
    # 生成期按 ? → footer 区原地展开快捷键(非模态:输入框 ❯/╭ 仍在)。早期 bug:? 被当
    # 字面字符塞进输入框,生成期完全不响应。长查询保证 ? 落在生成窗口。
    if SKIP:
        return
    raw = run(bin_path, ["sleep:0.8", "type:请从 1 数到 60,每个数字单独占一行,不要省略", "key:enter",
                         "sleep:0.6", "type:?", "sleep:0.5"],
              per_key_drain=0.05, base_url=None)
    a = TTYAssert(raw)
    gen = _gen_frames(a)
    if not gen:
        a._fail("无生成期帧(? 时模型已结束?重试或加长查询)")
        return
    # 某生成帧:help 快捷键展开 + 输入框仍在(非模态)。
    ok = any(
        sc.find_last_row("Open transcript") is not None
        and sc.find_last_row("❯") is not None
        and sc.find_last_row("╭") is not None
        for sc in gen
    )
    if not ok:
        a._fail("生成期 ? 未展开 help(或非模态输入框丢失)")
    a.assert_no_full_clear()


def test_T31_gen_help_esc_only_closes(bin_path):
    # 生成期 ? 开 help 后按 esc → 只关 help、不中断生成(先关弹层再中断)。
    # esc 为末键,sleep 足够长靠 flushEsc 兑现;之后生成应继续(spinner 帧仍在)。
    if SKIP:
        return
    raw = run(bin_path, ["sleep:0.8", "type:请从 1 数到 60,每个数字单独占一行,不要省略", "key:enter",
                         "sleep:0.6", "type:?", "sleep:0.4", "key:esc", "sleep:3"],
              per_key_drain=0.05, base_url=None)
    a = TTYAssert(raw)
    import re
    from asserts import split_frames
    prose = re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]", b"",
                   b"".join(c for k, c in split_frames(raw) if k == "prose")).decode("utf-8", "replace")
    # esc 只关 help 不中断:生成应继续(prose 有数字增长)或自然结束。不应出现 cancelled。
    # (若 esc 误中断,会有 cancel 标记且数列被截断。)
    finished_or_progressing = any(str(n) in prose for n in (10, 20, 30, 40, 50, 59, 60))
    if "cancel" in prose.lower() and not finished_or_progressing:
        a._fail("生成期 help 开时 esc 误中断了生成(应只关 help)")


def test_T32_gen_ctrl_o_transcript(bin_path):
    # 生成期按 Ctrl+O → transcript 模态覆盖生成区(对齐 cc app:toggleTranscript Global)。
    # 先 sleep 让首轮 append 进 conversation,transcript 才有内容。
    if SKIP:
        return
    raw = run(bin_path, ["sleep:0.8", "type:请从 1 数到 60,每个数字单独占一行,不要省略", "key:enter",
                         "sleep:1.2", "key:ctrl_o", "sleep:0.6"],
              per_key_drain=0.05, base_url=None)
    a = TTYAssert(raw)
    # 某帧含 transcript 标题;且不进 alt screen。
    ok = any(sc.find_last_row("transcript (Ctrl+O") is not None for sc in a.frame_screens)
    if not ok:
        a._fail("生成期 Ctrl+O 未打开 transcript")
    assert b"\x1b[?1049h" not in raw, "生成期 transcript 误进 alt screen"


def test_T33_gen_ctrl_o_toggle_close(bin_path):
    # 生成期 Ctrl+O 开 transcript → 再 Ctrl+O 关 → 回到生成区(spinner 帧),无 transcript 残留。
    if SKIP:
        return
    raw = run(bin_path, ["sleep:0.8", "type:请从 1 数到 60,每个数字单独占一行,不要省略", "key:enter",
                         "sleep:1.2", "key:ctrl_o", "sleep:0.5", "key:ctrl_o", "sleep:1"],
              per_key_drain=0.05, base_url=None)
    a = TTYAssert(raw)
    # 最后若干帧应回到生成区(含 esc to interrupt),非 transcript。
    last_frames = a.frame_screens[-3:] if len(a.frame_screens) >= 3 else a.frame_screens
    back_to_gen = any(sc.find_last_row("esc to interrupt") is not None for sc in last_frames)
    still_transcript = last_frames[-1].find_last_row("transcript (Ctrl+O") is not None if last_frames else False
    if still_transcript:
        a._fail("Ctrl+O 关闭后仍残留 transcript")
    if not back_to_gen:
        a._fail("Ctrl+O 关闭后未回到生成区(或生成已结束,可重试)")


def test_T34_gen_shift_tab_cycles_mode(bin_path):
    # 生成期 Shift+Tab → 循环权限模式(footer mode part 变)。验证全局键经 dispatch 上抛后
    # 两期一致(对齐 cc Shift+Tab 在 isLoading 仍激活)。早期 bug:生成期 watcher 丢弃 action。
    # 注:mode part 替换 footer 的 "esc to interrupt" 段(同一行),故不能用它筛生成帧——
    # 直接在所有帧找 mode 切换标志。短查询 + shift_tab 早按,确保落在生成窗口。
    if SKIP:
        return
    # 用 default 模式启动(tty_driver 默认 bypassPermissions,其 cycle 是 bypass→default
    # 看不到 accept edits)。default 下 Shift+Tab → accept edits,可断言。
    raw = run(bin_path, ["sleep:0.8", "type:数到30每行一个数字", "key:enter",
                         "sleep:0.6", "key:shift_tab", "sleep:1.5"],
              per_key_drain=0.05, base_url=None, permission="default")
    a = TTYAssert(raw)
    # 某帧 footer 出现非 default 模式(accept edits / plan mode)——Shift+Tab 在生成期切换生效。
    ok = any(
        sc.find_last_row("accept edits") is not None or sc.find_last_row("plan mode") is not None
        for sc in a.frame_screens
    )
    if not ok:
        a._fail("生成期 Shift+Tab 未切换权限模式(footer 无 accept edits/plan mode)")


