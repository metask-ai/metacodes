"""T06/T12:窄终端长行软折 / resize 自适应。"""
from tty_driver import idle_footer, run
from asserts import TTYAssert


def test_T06_softwrap_narrow(bin_path):
    # cols=24 → inner_w=23 → avail=20。打 30 个 a 应软折成多内容行,不溢出边框。
    raw = run(bin_path, ["sleep:0.8", "type:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"], term_size=(24, 24))
    a = TTYAssert(raw, rows=24, cols=24)
    top = a.box_top_row()
    bot = a.box_bottom_row()
    if top is None or bot is None:
        a._fail("窄终端下无完整边框")
    content_rows = bot - top - 1
    if content_rows < 2:
        a._fail(f"长行未软折(content_rows={content_rows},应 >=2)")
    # 每个内容行可见宽度不超过 cols(不冲破右边框/不被硬折)
    for r in range(top + 1, bot):
        w = a.final.line_text(r)
        # 行内容(含 prefix)显示宽不应超过 cols
        from screen import str_width
        if str_width(w) > 24:
            a._fail(f"内容行 {r} 宽 {str_width(w)} 超过 cols=24:'{w}'")


def test_T12_resize_widens(bin_path):
    # 起 24x40,打 hi,resize 到 24x100,**不按键**只等待 → SIGWINCH 应让框自动重画变宽。
    raw = run(bin_path, ["sleep:0.8", "type:hi", "resize:24x100", "sleep:0.6"],
              term_size=(24, 40))
    a = TTYAssert(raw, rows=24, cols=100)
    top = a.box_top_row()
    if top is None:
        a._fail("resize 后无上边框")
    border = a.final.line_text(top)
    from screen import str_width
    # 新边框宽度应接近 cols-1=99(而非旧的 39)
    if str_width(border) < 60:
        a._fail(f"resize 后边框未变宽(宽={str_width(border)},应接近 99)实际 '{border}'")
    a.assert_input_echo("hi")
    a.assert_box_at_bottom()


def _narrow_idle_box(bin_path, env=None, reflow=True, probe_answer=None):
    """空闲输入框从 100 列分四步缩到 60 列(拖窗口边时一串 SIGWINCH),每步等重画。

    回放在每次 resize 的那个字节偏移改尺寸:reflow=True 按现代终端重排已显示的行,
    False 按 xterm 式裁剪。整条流按最终尺寸回放的话,看不到终端对旧画面做了什么。

    工作目录是空的临时目录:在 git 仓库里启动,banner 和框之间还有一行按 `git log -1
    --name-only` 选的 suggestion,有没有它取决于检出(CI 的 depth-1 检出把 HEAD 当根提交、
    列出全部文件,有;HEAD 是 merge 提交时没有)。"""
    from tty_driver import READY, case_tmpdir
    resizes = []
    events = [READY]
    drain = {}
    if probe_answer is not None:
        events = ["waitbytes:\\x1b[c:10", "raw:" + probe_answer, READY]
        drain = {"startup_drain": 0}
    for cols in (90, 80, 70, 60):
        events += [f"resize:24x{cols}", "strictsleep:0.5"]
    raw = run(bin_path, events, term_size=(24, 100), env=env, resizes=resizes,
              cwd=case_tmpdir("cc-tty-narrow-"), **drain)
    return TTYAssert(raw, resizes=resizes, reflow=reflow)


_PROBED_TERMINAL = {"TERM": "xterm-256color", "TERM_PROGRAM": None, "TMUX": None, "STY": None, "ZELLIJ": None,
                    "XTERM_VERSION": None, "METACODES_NO_PROBE": None}


def _assert_nothing_above_the_box_moved(a):
    # 启动画面:banner、一行空行、输入框。少爬了行,空行处是旧横线;多爬了行(把裁剪的
    # 终端当成会重排),新框盖掉空行和 banner 的底边。
    top = a.box_top_row()
    if top is None or top < 2 or a.final.line_text(top - 1) != "" or "─" not in a.final.line_text(top - 2):
        a._fail(f"框上方应是一行空行和 banner 的底边(上边框在第 {top} 行)")


def test_T43_narrowing_a_reflowing_terminal_leaves_one_box(bin_path):
    # iTerm2、Terminal.app、kitty、xterm.js……变窄时把 99 列的横线重排成两行。
    a = _narrow_idle_box(bin_path)
    a.assert_single_box()
    _assert_nothing_above_the_box_moved(a)
    a.assert_input_echo("")
    a.assert_cursor_on_content("")


def test_T44_narrowing_a_clipping_terminal_keeps_the_lines_above_the_box(bin_path):
    # xterm(XTERM_VERSION)变窄时只裁剪,横线仍是一行:按重排算行数会多爬一行,
    # 每次 resize 吃掉框上方一行对话。
    a = _narrow_idle_box(bin_path, env={"XTERM_VERSION": "XTerm(390)"}, reflow=False)
    a.assert_single_box()
    _assert_nothing_above_the_box_moved(a)
    a.assert_cursor_on_content("")


def test_T48_narrowing_xterm_named_only_by_its_xtversion_answer_keeps_the_lines_above_the_box(bin_path):
    a = _narrow_idle_box(bin_path, env=_PROBED_TERMINAL, reflow=False,
                         probe_answer="\\x1bP>|XTerm(390)\\x1b\\\\\\x1b[?64;1c")
    a.assert_single_box()
    _assert_nothing_above_the_box_moved(a)
    a.assert_cursor_on_content("")


def test_T49_narrowing_putty_named_only_by_its_da2_answer_keeps_the_lines_above_the_box(bin_path):
    a = _narrow_idle_box(bin_path, env=_PROBED_TERMINAL, reflow=False, probe_answer="\\x1b[>0;136;0c\\x1b[?6c")
    a.assert_single_box()
    _assert_nothing_above_the_box_moved(a)
    a.assert_cursor_on_content("")


def test_T13_resize_during_generation_keeps_stream_and_region_aligned(bin_path):
    """A SIGWINCH during a live stream must not strand the fixed generation region.

    The mock keeps the provider response open long enough to resize after the
    spinner/input region is visible.  The assertion checks both sides of the
    boundary: streamed text remains in scrollback and the generation region is
    redrawn at the new width and still sits at the bottom.
    """
    from tty_driver import IDLE, READY, wait_for
    from slow_mock_server import SlowMockServer, slow_text_then_end

    resizes = []
    with SlowMockServer([slow_text_then_end(n_chunks=18, delay=0.2)]) as srv:
        raw = run(
            bin_path,
            [
                READY,
                "type:resize while generating",
                "key:enter",
                wait_for("esc to interrupt"),
                "strictsleep:0.35",
                "resize:24x60",
                wait_for("tok17", 20),
                IDLE,
            ],
            term_size=(24, 80),
            base_url=srv.url,
            startup_drain=0.8,
            per_key_drain=0.05,
            resizes=resizes,
        )

    # The terminal re-wraps the generation region drawn at 80 columns when
    # it narrows; the erase that follows has to climb those rows.
    a = TTYAssert(raw, resizes=resizes)
    if a.final.find_last_row("tok17") is None:
        a._fail("resize 后流式输出尾部 tok17 丢失或落入固定区")
    # A short climb stopped inside the old region and left its spinner row in
    # the conversation, between the echo and the reply.
    echo = a.final.find_row("❯ resize while generating")
    if echo is None or not a.final.line_text(echo + 1).startswith("⏺"):
        a._fail("回复应紧跟在提交回显下面:resize 后擦生成期固定区少爬了行,旧 spinner 行留在了对话里")
    # The final screen is the input phase, which always re-measures. The
    # generation region is drawn by a different path: its last frame (the
    # spinner still says "esc to interrupt") must use the new width too.
    import re
    from asserts import split_frames
    # At 60 columns the 65-column bypass-mode footer is cut (`… · esc to in…`), so match its head.
    gen_frames = [c for k, c in split_frames(raw) if k == "frame" and b" \xc2\xb7 esc to" in c]
    if not gen_frames:
        a._fail("没有捕获到生成期固定区帧")
    runs = [len(m.group(0)) // 3 for m in re.finditer(rb"(?:\xe2\x94\x80)+", gen_frames[-1])]
    if not runs or max(runs) > 60 or max(runs) < 50:
        a._fail(f"resize 后生成期固定区边框未按新宽度(60)重画:横线长度 {runs}")
    a.assert_single_box()



def _resize_during_dialog(bin_path, tool, tool_input, dialog_marker, answer_events, drawn_once):
    """Drive one tool call whose dialog is open while the terminal resizes.

    A resize interrupts the dialog's blocked key read with EINTR (SIGWINCH has
    no SA_RESTART). The dialog must keep waiting for a key instead of reading
    the interruption as an answer. Returns the final screen and the
    tool_result the next provider request carried.

    The dialog redraws after each resize. The narrower terminal has re-wrapped
    its full-width rows (the permission box was drawn for 80 columns), so a
    redraw that climbs the rows it was drawn with stops inside the old frame
    and leaves a second copy: `drawn_once` is on at most one row of the
    screen the terminal holds (replayed with its reflow and autowrap).
    """
    import json
    from tty_driver import READY, wait_for
    from slow_mock_server import SlowMockServer, slow_text_then_tooluse, slow_text_then_end

    turns = [
        slow_text_then_tooluse(n_chunks=1, delay=0.1, tool=tool, tool_input=tool_input),
        slow_text_then_end(n_chunks=1, delay=0.1),
    ]
    resizes = []
    with SlowMockServer(turns) as srv:
        raw = run(
            bin_path,
            [
                READY,
                "type:go",
                "key:enter",
                wait_for(dialog_marker, 15),
                "strictsleep:0.8",
                "resize:24x60",
                "strictsleep:1.0",
                "resize:24x80",
                "strictsleep:1.0",
            ] + answer_events,
            term_size=(24, 80),
            base_url=srv.url,
            permission="default",
            startup_drain=0.8,
            per_key_drain=0.05,
            resizes=resizes,
        )
        requests = list(srv.requests)
    a = TTYAssert(raw, resizes=resizes, autowrap=True)
    copies = [r for r in range(a.rows) if drawn_once in a.final.line_text(r)]
    if len(copies) > 1:
        a._fail(f"resize 之后对话框叠了 {len(copies)} 份({drawn_once!r} 在 {copies} 行)")
    if len(requests) < 2:
        a._fail(f"工具结果没有发回模型(只收到 {len(requests)} 个请求)")
    result = None
    for message in json.loads(requests[1])["messages"]:
        content = message.get("content")
        if isinstance(content, list):
            for block in content:
                if block.get("type") == "tool_result" and block.get("tool_use_id") == "t1":
                    result = block
    if result is None:
        a._fail("第二个请求里没有 t1 的 tool_result")
    return a, result


def _tool_result_text(result):
    content = result.get("content")
    if isinstance(content, list):
        return "".join(part.get("text", "") for part in content if isinstance(part, dict))
    return str(content)


def test_T14_resize_during_permission_prompt_keeps_waiting(bin_path):
    import json
    import os
    from tty_driver import case_tmpdir

    target = os.path.join(case_tmpdir("cc-tty-winch-perm-"), "winch.txt")
    a, result = _resize_during_dialog(
        bin_path,
        "Write",
        json.dumps({"file_path": target, "content": "x"}),
        "Permission required",
        ["type:y", idle_footer("? for shortcuts")],
        "[d] No, and deny Write",
    )
    text = _tool_result_text(result)
    if result.get("is_error") or "declined" in text:
        a._fail(f"resize 被当成了拒绝:tool_result={text!r}")
    if not os.path.exists(target):
        a._fail("resize 之后按 y 没有写出文件:对话框没有在等按键")
    a.assert_box_at_bottom()


def test_T15_resize_during_ask_question_keeps_waiting(bin_path):
    import json

    question = {
        "questions": [{
            "question": "Which colour?",
            "header": "Colour",
            "multiSelect": False,
            "options": [
                {"label": "Teal", "description": "the first"},
                {"label": "Amber", "description": "the second"},
            ],
        }],
    }
    a, result = _resize_during_dialog(
        bin_path,
        "AskUserQuestion",
        json.dumps(question),
        "Which colour?",
        ["key:enter", idle_footer("? for shortcuts")],
        "☐ Colour",
    )
    text = _tool_result_text(result)
    if result.get("is_error") or "Teal" not in text:
        a._fail(f"resize 之后按 Enter 没有选中第一个选项:tool_result={text!r}")
    a.assert_box_at_bottom()
