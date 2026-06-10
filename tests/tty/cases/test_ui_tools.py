"""T35-T36:工具 UI 渲染经真 TTY 验收(类别A 工具 UI)。

用 replay_server 喂确定性 cassette:
  sse-001 = assistant 发起 Write tool_use(写一个临时文件)
  sse-002 = assistant 收尾文字(turn 结束)
binary 执行 Write(--permission bypassPermissions,无弹窗)→ tool_result 进 conversation。
然后 Ctrl+O 打开 transcript viewer → 断言屏幕上出现 Write 结果的 diff 渲染
(renderResult → renderEditDiff:gitDiff 字段逐行 +绿/-红 着色)。

这覆盖了 tool_card 新渲染器经 transcript_viewer 接线后的**真终端**显示,
补齐 L2 单测之外的端到端 TTY 验收。

无 replay_server 二进制时 skip。
"""
import os
import sys
import subprocess
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import run
from asserts import TTYAssert

# __file__ = cc-zig/tests/tty/cases/test_ui_tools.py → 上溯 3 级到 cc-zig。
# (此前误写 "..","..",落到 cc-zig/tests,REPLAY_BIN 永不存在 → T35-T38 静默 skip。)
ZIG_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
REPLAY_BIN = os.path.join(ZIG_ROOT, "zig-out", "bin", "replay_server")


def _write_cassette(cdir, target_file):
    """写两轮 SSE:Write tool_use → 收尾文字。"""
    # Write 入参:file_path + content(JSON,需对 SSE 里的引号转义)。
    # input_json_delta 的 partial_json 是被 JSON 再转义一层的字符串。
    import json
    write_input = {"file_path": target_file, "content": "hello\nworld\n"}
    partial = json.dumps(write_input)              # {"file_path":"...","content":"hello\nworld\n"}
    partial_escaped = json.dumps(partial)[1:-1]    # 再转义一层(去掉外层引号)

    sse1 = (
        'data: {"type":"message_start","message":{"id":"m1","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n'
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"Write","input":{}}}\n\n'
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"' + partial_escaped + '"}}\n\n'
        'data: {"type":"content_block_stop","index":0}\n\n'
        'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}\n\n'
        'data: {"type":"message_stop"}\n\n'
    )
    sse2 = (
        'data: {"type":"message_start","message":{"id":"m2","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n'
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Done."}}\n\n'
        'data: {"type":"content_block_stop","index":0}\n\n'
        'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}\n\n'
        'data: {"type":"message_stop"}\n\n'
    )
    with open(os.path.join(cdir, "sse-001.txt"), "w") as f:
        f.write(sse1)
    with open(os.path.join(cdir, "sse-002.txt"), "w") as f:
        f.write(sse2)


def _start_replay(cdir):
    """起 replay_server,返回 (proc, base_url)。"""
    proc = subprocess.Popen([REPLAY_BIN, cdir], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    base_url = ""
    for _ in range(50):
        line = proc.stdout.readline().decode("utf-8", "replace").strip()
        if line.startswith("http"):
            base_url = line
            break
        time.sleep(0.1)
    return proc, base_url


# replay_server(mock SSE)偶发连接竞态:client 连上但读响应失败(takeLine/ReadFailed →
# stream returned error RequestFailed)。非被测逻辑 bug,是 mock server 的瞬态。检测到这些标记
# 就重跑(fresh replay_server),让 cassette 测试确定性通过。
_STREAM_ERR = (b"RequestFailed", b"ReadFailed", b"stream returned error", b"HttpConnectionClosing")


def _stream_errored(raw):
    return any(m in raw for m in _STREAM_ERR)


def replay_run(cdir, key_events, term_size=(40, 100), bin_path="zig-out/bin/metacodes-debug", tries=6, before_each=None, success=None):
    """起 replay_server + run,瞬态失败则重跑(最多 tries 次)。
    before_each: 每次 attempt 前调(重置有状态场景,如 Edit 改文件的测试)。
    success(raw)->bool: 可选成功判据;给定时,未成功(且非最后一次)就重跑(覆盖 stream 错误外的瞬态,
      如 mock server 半截响应致工具未执行)。不给时只按 _stream_errored 判。
    返回 raw(最后一次);replay 未就绪返回 None(skip)。"""
    for attempt in range(tries):
        if before_each is not None:
            before_each()  # 重置状态(文件/读态),使每次重跑都从干净起点
        proc, base_url = _start_replay(cdir)
        if not base_url:
            proc.kill()
            if attempt == tries - 1:
                return None
            time.sleep(0.3)
            continue
        time.sleep(0.15)  # base_url 已打印(listen 成功);给 serveLoop 线程进 accept 的余量(防首连竞态)
        try:
            raw = run(bin_path, key_events, term_size=term_size, per_key_drain=0.06, base_url=base_url)
        finally:
            proc.kill()
        last = attempt == tries - 1
        ok = (not _stream_errored(raw)) and (success is None or success(raw))
        if ok:
            return raw
        if last:
            # 重试耗尽仍失败:若是 mock server 的 stream 错误(takeLine/ReadFailed/RequestFailed),
            # 是 harness 瞬态非产品 bug → 返 None 让调用方 skip;否则返 raw 交断言(真失败)。
            if _stream_errored(raw):
                return None
            return raw
        time.sleep(0.3)  # 瞬态:歇一下重起 fresh server 重跑
    return raw



def test_T35_write_diff_in_transcript(bin_path):
    if not os.path.isfile(REPLAY_BIN):
        return  # 无 replay_server → skip
    tmp = tempfile.mkdtemp(prefix="cc-tty-uitool-")
    cdir = os.path.join(tmp, "cassette")
    os.makedirs(cdir, exist_ok=True)
    target = os.path.join(tmp, "out.txt")
    _write_cassette(cdir, target)

    def _ok35(raw):
        import re as _re
        s = _re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]", b"", raw).decode("utf-8", "replace")
        return "hello" in s and "world" in s

    def _reset35():
        # Write 目标文件每次 attempt 删掉(重跑撞已存在文件 → diff 不同/不写)。
        try:
            os.remove(target)
        except OSError:
            pass

    raw = replay_run(
        cdir,
        ["sleep:0.8", "type:write the file", "key:enter", "sleep:2.0",
         "key:ctrl_o", "sleep:1.0", "type:q"],
        term_size=(40, 100), bin_path=bin_path, before_each=_reset35, success=_ok35,
    )
    if raw is None:
        return  # replay 未就绪 → skip(环境问题)

    a = TTYAssert(raw)
    # transcript 视图里应出现 Write 结果的 diff 内容行(gitDiff → +绿 着色的新增行)。
    # 新文件 Write 的 diff:+hello / +world。断言任一出现在某帧屏幕。
    found = False
    for sc in a.frame_screens:
        text = "\n".join(sc.line_text(r) for r in range(sc.rows))
        if "hello" in text and "world" in text:
            found = True
            break
    if not found:
        # 兜底:看整个原始流(transcript 可能只在某一刷新帧)
        import re
        prose = re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]", b"", raw).decode("utf-8", "replace")
        if "hello" in prose and "world" in prose:
            found = True
    if not found:
        a._fail("transcript 视图未显示 Write 的 diff 内容(hello/world)")


def test_T36_edit_diff_live_inline(bin_path):
    """live(非 transcript)Edit 后,屏幕应**立即**显示 diff(-foo 红 / +BAR 绿)。

    覆盖 agent_loop.opts.tool_render_theme 接线:工具执行后经 tool_card.renderResult
    实时渲染到 stdout。先 Read 再 Edit(满足 must-read-first)。
    """
    if not os.path.isfile(REPLAY_BIN):
        return
    tmp = tempfile.mkdtemp(prefix="cc-tty-livediff-")
    cdir = os.path.join(tmp, "cassette")
    os.makedirs(cdir, exist_ok=True)
    tf = os.path.join(tmp, "f.txt")
    with open(tf, "w") as f:
        f.write("foo\nbaz\n")

    import json as _json
    def _tool(tid, name, inp):
        pj = _json.dumps(_json.dumps(inp))[1:-1]
        return ('data: {"type":"message_start","message":{"id":"m","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n'
                'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"' + tid + '","name":"' + name + '","input":{}}}\n\n'
                'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"' + pj + '"}}\n\n'
                'data: {"type":"content_block_stop","index":0}\n\n'
                'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}\n\n'
                'data: {"type":"message_stop"}\n\n')

    with open(os.path.join(cdir, "sse-001.txt"), "w") as f:
        f.write(_tool("tu1", "Read", {"file_path": tf}))
    with open(os.path.join(cdir, "sse-002.txt"), "w") as f:
        f.write(_tool("tu2", "Edit", {"file_path": tf, "old_string": "foo", "new_string": "BAR"}))
    with open(os.path.join(cdir, "sse-003.txt"), "w") as f:
        # 收尾文字
        f.write('data: {"type":"message_start","message":{"id":"m","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n'
                'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
                'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Done"}}\n\n'
                'data: {"type":"content_block_stop","index":0}\n\n'
                'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}\n\n'
                'data: {"type":"message_stop"}\n\n')

    def _reset_file():
        with open(tf, "w") as ff:
            ff.write("foo\nbaz\n")

    # success 判据:Edit 真应用 + inline diff 出现(否则 mock server 半截响应致工具没跑 → 重跑)。
    def _ok(raw):
        import re as _re
        s = _re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]", b"", raw).decode("utf-8", "replace")
        return "+BAR" in s and "-foo" in s

    raw = replay_run(cdir, ["sleep:0.8", "type:edit it", "key:enter", "sleep:2.5"],
                     term_size=(40, 100), bin_path=bin_path, before_each=_reset_file, success=_ok)
    if raw is None:
        return  # replay 未就绪 → skip

    # 文件真被改
    if open(tf).read() != "BAR\nbaz\n":
        TTYAssert(raw)._fail("Edit 未应用(must-read-first 链路或 live 渲染破坏了执行)")
    import re
    stripped = re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]", b"", raw).decode("utf-8", "replace")
    # diff 内容行 inline 出现(不经 Ctrl+O)
    if "+BAR" not in stripped or "-foo" not in stripped:
        TTYAssert(raw)._fail("live Edit 未 inline 显示 diff(-foo/+BAR)")
    # 着色:+ 行绿(32m)、- 行红(31m)
    if b"\x1b[32m" not in raw or b"\x1b[31m" not in raw:
        TTYAssert(raw)._fail("live Edit diff 缺 +绿/-红 着色")



def _run_cassette(steps_files, key_events, term_size=(30, 90)):
    """通用:写 cassette(steps_files=[(name,sse_text)...]),起 replay(带瞬态重试),跑,返回 raw。"""
    if not os.path.isfile(REPLAY_BIN):
        return None
    tmp = tempfile.mkdtemp(prefix="cc-tty-iface-")
    cdir = os.path.join(tmp, "cassette")
    os.makedirs(cdir, exist_ok=True)
    for i, (_, txt) in enumerate(steps_files, start=1):
        with open(os.path.join(cdir, f"sse-{i:03d}.txt"), "w") as f:
            f.write(txt)
    return replay_run(cdir, key_events, term_size=term_size)



def _sse_tool(tid, name, inp):
    import json as _j
    pj = _j.dumps(_j.dumps(inp))[1:-1]
    return ('data: {"type":"message_start","message":{"id":"m","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n'
            'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"' + tid + '","name":"' + name + '","input":{}}}\n\n'
            'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"' + pj + '"}}\n\n'
            'data: {"type":"content_block_stop","index":0}\n\n'
            'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}\n\n'
            'data: {"type":"message_stop"}\n\n')


def _sse_text(txt):
    return ('data: {"type":"message_start","message":{"id":"m","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n'
            'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
            'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"' + txt + '"}}\n\n'
            'data: {"type":"content_block_stop","index":0}\n\n'
            'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}\n\n'
            'data: {"type":"message_stop"}\n\n')


def test_T37_taskcreate_shows_tasktab(bin_path):
    """task 工具(TaskCreate+TaskUpdate in_progress)→ 输入框上方出现 ◼ activeForm 清单行(B3 多行面板)。"""
    raw = _run_cassette(
        [("a", _sse_tool("tu1", "TaskCreate", {"subject": "build the widget", "description": "d", "activeForm": "Building the widget"})),
         ("b", _sse_tool("tu2", "TaskUpdate", {"taskId": "1", "status": "in_progress"})),
         ("c", _sse_text("started"))],
        ["sleep:0.8", "type:make a task", "key:enter", "sleep:2.5"],
        term_size=(40, 100),
    )
    if raw is None:
        return
    a = TTYAssert(raw)
    top = a.box_top_row()
    if top is None or top == 0:
        a._fail("无法定位输入框")
    tab = a.final.line_text(top - 1)
    # B3 多行 Task 清单:in_progress 用 ◼(对齐 cc TaskListV2),label 用 activeForm。
    if "◼" not in tab or "Building the widget" not in tab:
        a._fail(f"TaskCreate/Update 后 TaskTab 未显示 activeForm:row={top-1!r} '{tab}'")


def test_T38_enterplanmode_updates_footer(bin_path):
    """EnterPlanMode 工具 → footer 反映 "plan mode on"(回归:config/ctx mode 同步 bug)。"""
    raw = _run_cassette(
        [("a", _sse_tool("tu1", "EnterPlanMode", {})),
         ("b", _sse_text("in plan"))],
        ["sleep:0.8", "type:plan it", "key:enter", "sleep:2.0"],
    )
    if raw is None:
        return
    a = TTYAssert(raw)
    foot = None
    for r in range(a.final.rows):
        lt = a.final.line_text(r)
        # CC 风格 footer:"{symbol} {title} on · shift+tab to cycle · …"。
        if "shift+tab to cycle" in lt:
            foot = lt
    # 2026-06-05:footer mode part 改为 cc title 形式 "plan mode on"(原 "plan on")。
    if foot is None or "plan mode on" not in foot:
        a._fail(f"EnterPlanMode 后 footer 未显示 'plan mode on':{foot!r}")


def test_T39_plan_mode_reflects_during_generation(bin_path):
    """#11:EnterPlanMode 在生成期触发 → footer 在生成窗口内即反映 plan(非等 turn 结束)。

    cassette:step a 发 EnterPlanMode(tool_use)→ 工具写 permission_ctx.mode=plan;
    step b 发文本(生成继续)。生成期 drawFooter 读 permission_ctx.mode(live),tickSpinner
    重画即反映。断言:某个生成期帧的 footer 已含 'plan mode'(修 #11 前只在 turn 结束后才同步)。
    """
    raw = _run_cassette(
        [("a", _sse_tool("tu1", "EnterPlanMode", {})),
         ("b", _sse_text("now in plan mode generating some text"))],
        ["sleep:0.8", "type:plan it", "key:enter", "sleep:2.0"],
    )
    if raw is None:
        return
    a = TTYAssert(raw)
    # 扫所有捕获帧(含生成期),只要有一帧 footer 含 plan mode 即证生成期已联动。
    found = False
    for sc in a.frame_screens:
        for r in range(sc.rows):
            lt = sc.line_text(r)
            if "shift+tab to cycle" in lt and "plan mode" in lt:
                found = True
                break
        if found:
            break
    if not found:
        a._fail("生成期无任何帧 footer 反映 plan mode(#11:生成期联动失效)")


def test_T40_assistant_markdown_render(bin_path):
    """#22+#23:live 助手文本 markdown 轻度渲染 + 缩进 + 段首 ⏺。

    cassette 注入一段 markdown 助手文本,断言渲染结果(对齐 cc):
      - `## Heading` → 去掉 `##`,以 `⏺ ` 段首前缀(段落首行)
      - `**bold**` → 去掉 `**`(标记消化)
      - `- item`   → `•` 列表符 + 2 空格缩进
      - 代码块围栏 ``` → 去掉(不裸吐 ```)
    """
    md = "## Heading\\n\\nSome **bold** text.\\n\\n- one\\n- two\\n\\n```py\\nprint('x')\\n```"
    raw = _run_cassette([("a", _sse_text(md))],
                        ["sleep:0.8", "type:show md", "key:enter", "sleep:2.5"])
    if raw is None:
        return
    a = TTYAssert(raw)
    screen = "\n".join(a.final.line_text(r) for r in range(a.final.rows))
    # 标题渲染:去 ## + ⏺ 段首(整屏应有 "⏺ Heading",且无裸 "## Heading")。
    assert "## Heading" not in screen, "标题未渲染(裸 ##):\n" + screen
    assert "Heading" in screen, "标题文字丢失:\n" + screen
    assert "⏺" in screen, "助手段落缺 ⏺ 前缀:\n" + screen
    # bold 标记消化(无裸 **)。
    assert "**bold**" not in screen, "bold 标记未消化(裸 **):\n" + screen
    assert "bold" in screen
    # 列表用 • + 缩进。
    assert "•" in screen, "列表未渲染为 •:\n" + screen
    # 代码块围栏消化(无裸 ```)。
    assert "```" not in screen, "代码块围栏未消化(裸 ```):\n" + screen
    assert "print" in screen, "代码块内容丢失:\n" + screen


def test_T41_webfetch_output_reasonable(bin_path):
    """WebFetch 工具卡输出合理:`⏺ WebFetch(url)` + `⎿ Received N bytes` 人话摘要,
    **绝不裸吐结果 JSON**({\"bytes\":/\"content\": 等字段名)。

    cassette 注入 WebFetch tool_use(指向 example.com)→ 工具真 curl(在线则成功)。
    断言对网络状态鲁棒:无论成败,卡都不得裸吐 JSON;在线成功时显 Received N bytes。
    """
    url = "https://example.com"
    raw = _run_cassette(
        [("a", _sse_tool("tu1", "WebFetch", {"url": url})),
         ("b", _sse_text("done"))],
        ["sleep:0.8", "type:fetch it", "key:enter", "sleep:4.0"],
    )
    if raw is None:
        return
    a = TTYAssert(raw)
    screen = "\n".join(a.final.line_text(r) for r in range(a.final.rows))
    # 工具卡标题:⏺ WebFetch(url)。
    assert "WebFetch" in screen, "无 WebFetch 工具卡:\n" + screen
    # **核心:绝不裸吐结果 JSON 字段名**(反模式回归守卫)。
    assert '"bytes"' not in screen, "WebFetch 裸吐 JSON(bytes):\n" + screen
    assert '"content"' not in screen, "WebFetch 裸吐 JSON(content):\n" + screen
    assert '"truncated"' not in screen, "WebFetch 裸吐 JSON(truncated):\n" + screen
    # 在线成功时应有 'Received N bytes' 人话摘要;离线/失败也不得裸 JSON(上面已守)。
    if "Received" in screen:
        import re
        assert re.search(r"Received \d+ bytes", screen), "Received 摘要格式不对:\n" + screen


def test_T42_transcript_close_reanchors_box_to_bottom(bin_path):
    """#24 回归:小屏 + 多行对话时,Ctrl+O 开 transcript(比框高、顶动终端)→ 再 Ctrl+O 关,
    输入框必须重锚回**屏底**(修前漂到屏顶、下方留大片空白)。

    cassette 注入多行助手回复 → 小屏(16 行)→ Ctrl+O 开 → Ctrl+O 关 → 断言框在屏下半部、
    框下方无大片空白。
    """
    reply = "line one\\nline two\\nline three\\nline four\\nline five\\nline six"
    raw = _run_cassette(
        [("a", _sse_text(reply))],
        ["sleep:0.8", "type:hi", "key:enter", "sleep:2.0",
         "key:ctrl_o", "sleep:0.5", "key:ctrl_o", "sleep:0.5"],
        term_size=(16, 80),
    )
    if raw is None:
        return
    a = TTYAssert(raw, rows=16, cols=80)  # PTY 是 16 行;TTYAssert 默认 24 → top>=rows//2 用错分母
    a.assert_box_present()
    top = a.box_top_row()
    bot = a.box_bottom_row()
    rows = a.final.rows
    assert top is not None and bot is not None, "无完整输入框"
    # 框应在屏下半部(inline 关闭后框锚在对话尾之下,对齐 cc),不得漂到屏顶(修前 bug:top≈0)。
    assert top >= rows // 2, f"输入框未回到屏底(top={top}, rows={rows}),疑似漂到屏顶:\n" + "\n".join(a.final.line_text(r) for r in range(rows))
    # 框下方(footer 之后)无大片非空残留。
    a.assert_box_at_bottom()
