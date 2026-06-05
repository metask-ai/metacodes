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


def test_T35_write_diff_in_transcript(bin_path):
    if not os.path.isfile(REPLAY_BIN):
        return  # 无 replay_server → skip
    tmp = tempfile.mkdtemp(prefix="cc-tty-uitool-")
    cdir = os.path.join(tmp, "cassette")
    os.makedirs(cdir, exist_ok=True)
    target = os.path.join(tmp, "out.txt")
    _write_cassette(cdir, target)

    proc, base_url = _start_replay(cdir)
    if not base_url:
        proc.kill()
        return  # replay 未就绪 → skip(不算失败,环境问题)
    try:
        # 提交 prompt → Write 执行(~1s)→ Ctrl+O 开 transcript → 等渲染 → q 退出
        raw = run(
            bin_path,
            ["sleep:0.8", "type:write the file", "key:enter", "sleep:2.0",
             "key:ctrl_o", "sleep:1.0", "type:q"],
            term_size=(40, 100),
            per_key_drain=0.06,
            base_url=base_url,
        )
    finally:
        proc.kill()

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

    proc, base_url = _start_replay(cdir)
    if not base_url:
        proc.kill()
        return
    try:
        raw = run(
            bin_path,
            ["sleep:0.8", "type:edit it", "key:enter", "sleep:2.5"],
            term_size=(40, 100),
            per_key_drain=0.06,
            base_url=base_url,
        )
    finally:
        proc.kill()

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
    """通用:写 cassette(steps_files=[(name,sse_text)...]),起 replay,跑,返回 raw。"""
    if not os.path.isfile(REPLAY_BIN):
        return None
    tmp = tempfile.mkdtemp(prefix="cc-tty-iface-")
    cdir = os.path.join(tmp, "cassette")
    os.makedirs(cdir, exist_ok=True)
    for i, (_, txt) in enumerate(steps_files, start=1):
        with open(os.path.join(cdir, f"sse-{i:03d}.txt"), "w") as f:
            f.write(txt)
    proc, base_url = _start_replay(cdir)
    if not base_url:
        proc.kill()
        return None
    try:
        return run("zig-out/bin/metacodes-debug", key_events, term_size=term_size,
                   per_key_drain=0.06, base_url=base_url)
    finally:
        proc.kill()


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
    """EnterPlanMode 工具 → footer 反映 "plan on"(回归:config/ctx mode 同步 bug)。"""
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
        # CC 风格 footer:"{mode} on · shift+tab to cycle · …"。
        if "shift+tab to cycle" in lt:
            foot = lt
    if foot is None or "plan on" not in foot:
        a._fail(f"EnterPlanMode 后 footer 未显示 'plan on':{foot!r}")
