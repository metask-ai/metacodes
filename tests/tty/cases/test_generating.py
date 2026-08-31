"""T14-T16:生成期(模型输出时)输入框保留 + queued 输入 + 自动提交。

这些用例**打真实模型**(生成期才有 spinner/输入框共存)。无 API key 时 skip。
key_events 用够长 sleep 落在生成窗口内。
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import run
from asserts import TTYAssert
from e2e_helpers import run_live_fresh  # 真模型用例:播种凭证隔离 HOME + 凭证回传 + 失效跳过

# 这套用例打真实模型，需要 metacodes login 或 METASK_API_KEY；
# 若想跳过(离线/CI),设 TTY_SKIP_MODEL=1。
SKIP = os.environ.get("TTY_SKIP_MODEL") == "1"


def test_T14_generating_keeps_input_box(bin_path):
    if SKIP:
        return
    # 提交一句会产生输出的查询 → 生成期应有【多帧持续】同时有 spinner + 完整输入框 + footer
    # (不是"某一帧有",而是 spinner+框+❯+footer 共存于生成窗口的多个帧 → 区持续可见、不闪没)。
    raw = run_live_fresh(bin_path, ["sleep:0.8", "type:慢慢数到十五,每行一个数字", "key:enter", "sleep:4"],
              per_key_drain=0.05)
    a = TTYAssert(raw)
    coexist = sum(
        1 for sc in a.frame_screens
        if sc.find_last_row("esc to interrupt") is not None
        and sc.find_last_row("❯") is not None
        # 三横线边框无 ╭;❯ 内容行即证输入框在。
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
    raw = run_live_fresh(bin_path, ["sleep:0.8",
                         "type:请从 1 数到 60,每个数字单独占一行,不要省略", "key:enter",
                         "sleep:0.6", "type:HELLO", "sleep:2.5"],
              per_key_drain=0.06)
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
    # 尾窗须容纳完整两轮(数到 60 慢模型一轮即 >10s);settle 下 cap 放宽零成本。
    raw = run_live_fresh(bin_path, ["sleep:0.8", "type:请从 1 数到 60,每个数字单独占一行,不要省略", "key:enter",
                         "sleep:0.6", "type:DONE2", "key:enter", "sleep:35"],
              per_key_drain=0.06)
    a = TTYAssert(raw)
    # queued "DONE2" 回车入队 → 第一轮结束后自动续发 → ❯ 回显进 scrollback。
    a.assert_prose_contains("DONE2")


def test_T20_enter_enqueues_clears_box(bin_path):
    # 生成期打字 + 回车 → 输入框清空 + 队列预览出现(dim ⏳ QMSG),且未即时提交进 scrollback。
    if SKIP:
        return
    raw = run_live_fresh(bin_path, ["sleep:0.8", "type:请从 1 数到 60,每个数字单独一行", "key:enter",
                         "sleep:0.6", "type:QUEUEDMSG", "key:enter", "sleep:2.0"],
              per_key_drain=0.05)
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
    # 生成期入队 2 条 → 一轮结束后**一次性合并提交**(对齐 cc 同模式批量,loop.zig popAllJoined("\n\n"))
    # → 合并成一条 user 消息(BATCHA\n\nBATCHB),而非各自独立一轮。
    if SKIP:
        return
    import glob
    import json
    import shutil
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from e2e_helpers import fresh_home, run_live  # noqa: E402

    # 时序要点(2026-06-11 修正):两条排队消息必须在**同一次**生成窗口内入队,否则首轮结束时
    # popAllJoined 只捞到 BATCHA、BATCHB 落入下一轮 → 不合并。故首查询够长(数到 50 + 慢慢来)+
    # 两条快速连入(0.5s/0.3s)+ 尾部 sleep 给足。旧版"数到 60 + sleep 10"耗在计数上 → 确定性失败。
    #
    # **断言走 transcript 权威层**(关键稳定性修复):合并结果是一条 user 消息 `BATCHA\n\nBATCHB`,
    # 这在 transcript 里确定记录,与屏幕回显时序无关。旧版查 scrollback prose 的 ❯ 回显——模型答题
    # 速度波动时回显可能没落到捕获窗口内 → flaky。transcript 是 popAllJoined 合并的权威证据。
    home = fresh_home()
    run_live(bin_path, ["sleep:0.8", "type:请从 1 数到 50,每个数字单独占一行,慢慢来", "key:enter",
                        "sleep:0.5", "type:BATCHA", "key:enter",
                        "sleep:0.3", "type:BATCHB", "key:enter", "sleep:45"],
             home, per_key_drain=0.05)

    # 扫 transcript 的 user 消息,找含 BATCH 的文本块。
    user_batch_msgs = []
    for path in glob.glob(os.path.join(home, ".metacodes", "projects", "*", "*", "transcript.jsonl")):
        for line in open(path, encoding="utf-8", errors="replace"):
            try:
                m = json.loads(line)
            except json.JSONDecodeError:
                continue
            if m.get("role") != "user":
                continue
            for b in m.get("blocks", []):
                if b.get("type") == "text" and "BATCH" in (b.get("text") or ""):
                    user_batch_msgs.append(b["text"])
    shutil.rmtree(home, ignore_errors=True)

    # 核心断言:BATCHA 与 BATCHB **合并进同一条 user 消息**(popAllJoined "\n\n"),
    # 而非两条独立 user 消息。即:恰有 1 条含 BATCH 的 user 消息,且同时含 BATCHA + BATCHB。
    assert len(user_batch_msgs) == 1, (
        "队列多条应合并为一条 user 消息,实际含 BATCH 的 user 消息 %d 条:%r"
        % (len(user_batch_msgs), user_batch_msgs))
    merged = user_batch_msgs[0]
    assert "BATCHA" in merged and "BATCHB" in merged, (
        "合并消息应含 BATCHA + BATCHB,实际:%r" % merged)


def test_T22_esc_interrupts(bin_path):
    # 单 esc 直接中断当前任务(对齐 CC,不再两档)。框里已打的字先入队续发,再中断。
    if SKIP:
        return
    import re
    from asserts import split_frames
    raw = run_live_fresh(bin_path, ["sleep:0.8", "type:请从 1 数到 60 每行一个数字", "key:enter",
                         "sleep:0.6", "type:TYPED", "key:esc", "sleep:3"],
              per_key_drain=0.05)
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
    raw = run_live_fresh(bin_path, ["sleep:0.8", "type:请从 1 数到 60 每行一个数字", "key:enter",
                         "sleep:0.6", "type:你好世界", "sleep:1.5"],
              per_key_drain=0.05)
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
    raw = run_live_fresh(bin_path, ["sleep:0.8", "type:请从 1 数到 60,每个数字单独占一行,不要省略", "key:enter",
                         "sleep:0.8", "type:打断后请回答你是谁", "key:enter",
                         "sleep:0.4", "key:esc", "sleep:8"],
              per_key_drain=0.05)
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


def test_completion_spinner_never_commits_to_history(bin_path):
    # 用户实测 bug:每次回答完,spinner 的完成态词("✻ Hatched for 1s" / "Cooked for 1s" / "Drafted
    # for 2s")被 commit 进**历史消息区**,多轮后一行行堆噪声。产品决策:**spinner 根本不该进历史区**
    # —— 它是纯瞬态指示器,生成结束随固定区一起擦掉,不留任何完成态行。
    # (旧版 leaveGenerating 每轮 ≥0.5s 就 emitFinishedSpinner;cc 默认仅 >30s 长轮有 turn_duration
    #  系统消息,但用户明确要求 cc-zig 不要它。此处已彻底移除 emitFinishedSpinner。)
    # 为什么旧 tty 测试没发现:无任何用例断言"完成态行不入 scrollback";且我此前探针里见过该行却
    # 误判成"cc 正常思考总结"放过(确认偏差)。test_overlay 的 spinner-residue 测试只断言 ≤1 行,
    # 反而容忍了它。本测试用离线 mock 多轮短对话,钉死 committed scrollback 里**零**完成态行。
    import re
    from slow_mock_server import SlowMockServer, slow_text_then_end
    from asserts import split_frames

    # 两轮短对话(各 ~1.6s),复刻用户"在么 / 你是谁"多轮场景。离线 mock,确定性。
    turns = [slow_text_then_end(n_chunks=4, delay=0.4), slow_text_then_end(n_chunks=4, delay=0.4)]
    with SlowMockServer(turns) as srv:
        raw = run(bin_path,
                  ["sleep:0.8", "type:在么", "key:enter", "sleep:3.0",
                   "type:你是谁", "key:enter", "sleep:3.0"],
                  base_url=srv.url, startup_drain=0.8, per_key_drain=0.06, term_size=(24, 80))

    # committed scrollback(帧间散文本 = 真正进历史区的字节)。
    prose = re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]", b"",
                   b"".join(c for k, c in split_frames(raw) if k == "prose")).decode("utf-8", "replace")
    # 完成态行形态:`<spinner字符> <Verb> for <N>s`(区别于生成期实时 spinner 的 `<Verb>… (Ns)`,后者带 …)。
    completion = re.compile(r"[✻✦✶✺✷✸]\s+\w+\s+for\s+\d+s")
    hits = completion.findall(prose)
    assert not hits, (
        "完成态 spinner 行被 commit 进历史区(应彻底不入,用户实测 bug):%r\n--- scrollback ---\n%s"
        % (hits, prose[-1200:]))
    # 兜底:连"for Ns"裸形态也不该在历史区(mock 助手文本不含 for,故任何命中即 bug)。
    assert not re.search(r"\bfor \d+s\b", prose), \
        "历史区出现 'for Ns'(完成态行残留):\n" + prose[-1200:]


def test_logs_never_leak_into_tui_render_stream(bin_path):
    # 用户实测(Warp):web 搜索时 spinner 在 input 上方留**残影**堆叠。根因(offline 复现坐实):
    #   日志默认级别 .err → err/warn 写 **stderr(fd 2)**,而交互式 TUI 渲染走 fd 1——同一终端。
    #   任何 err(web 搜索是最易出错路径:真后端 HTTP 子请求 / JSON 解析)直接**注入渲染流**,
    #   插进固定区(实测插进 footer 行 `esc to interrupt[ERROR client ...]`)→ 滚屏 desync →
    #   in-place 区重画错位 → spinner/footer 一行行堆进 scrollback。
    #   离线干净 mock 不 err → 从不复现;这是真机 + 出错路径才暴露,靠 HTTP-500 mock 离线钉死。
    # 修:交互式 TUI(isatty + 非 verbose)启动时 log.setStderrEnabled(false) → 日志不上屏
    #   (仍写 METACODES_LOG_FILE);用户可见错误走正规 UI 通道(retry/卡),非裸日志。
    import re
    import http.server
    import socketserver
    import threading
    from asserts import split_frames

    OK_SSE = (
        b'data: {"type":"message_start","message":{"id":"m","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n'
        b'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
        b'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}\n\n'
        b'data: {"type":"content_block_stop","index":0}\n\n'
        b'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}\n\n'
        b'data: {"type":"message_stop"}\n\n'
    )
    state = {"n": 0}

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            ln = int(self.headers.get("content-length", 0))
            self.rfile.read(ln)
            state["n"] += 1
            if state["n"] <= 2:  # 前两连接 500 → 触发 client err 日志(+ 重试)
                self.send_response(500)
                self.end_headers()
                self.wfile.write(b'{"error":"boom"}')
            else:
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.end_headers()
                self.wfile.write(OK_SSE)
                self.wfile.flush()

    socketserver.TCPServer.allow_reuse_address = True
    srv = socketserver.TCPServer(("127.0.0.1", 0), H)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        raw = run(bin_path, ["sleep:0.8", "type:hi", "key:enter", "sleep:5"],
                  base_url="http://127.0.0.1:%d/v1/messages" % port,
                  startup_drain=0.8, per_key_drain=0.05, term_size=(24, 80))
    finally:
        srv.shutdown()

    det = re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]", b"", raw).decode("utf-8", "replace")
    # 核心:任何日志前缀都不得出现在 TUI 渲染流里(否则注入固定区 → 残影)。
    assert "[ERROR" not in det, "err 日志泄漏进 TUI 渲染流(会注入固定区致残影):\n" + \
        "\n".join(l for l in det.split("\n") if "ERROR" in l)[:600]
    assert "[WARN" not in det, "warn 日志泄漏进 TUI 渲染流:\n" + \
        "\n".join(l for l in det.split("\n") if "WARN" in l)[:600]


def test_A6_narrow_terminal_no_wrap(bin_path):
    # 窄终端 cols=40:生成期 spinner 行被截断到 cols-1,不触发 DECAWM 折行 →
    # 区实际行数 = R,底部框/footer 不错位。断言:生成期共存帧的可见行宽不超 cols。
    if SKIP:
        return
    from screen import str_width
    raw = run_live_fresh(bin_path, ["sleep:0.8", "type:数到八每行一个", "key:enter", "sleep:3"],
              term_size=(24, 40), per_key_drain=0.05)
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
    """生成期帧。spinner 行(含 '…')是生成期可靠标志——它在 help 开/关都在。
    注:30s 门控后(对齐 cc),<30s 的 spinner 只有 `<char> <Verb>…`,无 token,
    故检测只能靠 '…'(不能再依赖 'tokens');'esc to interrupt' 在 footer(help 开时会被替换)。"""
    def is_gen(sc):
        for r in range(sc.rows):
            if "…" in sc.line_text(r):
                return True
        return False
    return [sc for sc in a.frame_screens if is_gen(sc)]


def test_T30_gen_help_nonmodal(bin_path):
    # 生成期按 ? → footer 区原地展开快捷键(非模态:输入框 ❯/╭ 仍在)。早期 bug:? 被当
    # 字面字符塞进输入框,生成期完全不响应。长查询保证 ? 落在生成窗口。
    if SKIP:
        return
    raw = run_live_fresh(bin_path, ["sleep:0.8", "type:请用中文从 1 数到 200,每个数字单独占一行,不要省略任何数字", "key:enter",
                         "sleep:0.6", "type:?", "sleep:0.5"],
              per_key_drain=0.05)
    a = TTYAssert(raw)
    gen = _gen_frames(a)
    if not gen:
        a._fail("无生成期帧(? 时模型已结束?重试或加长查询)")
        return
    # 某生成帧:help 快捷键展开 + 输入框仍在(非模态)。
    ok = any(
        sc.find_last_row("Open transcript") is not None
        and sc.find_last_row("❯") is not None
        # 三横线边框无 ╭;❯ 即证非模态输入框仍在。
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
    raw = run_live_fresh(bin_path, ["sleep:0.8", "type:请从 1 数到 60,每个数字单独占一行,不要省略", "key:enter",
                         "sleep:0.6", "type:?", "sleep:0.4", "key:esc", "sleep:3"],
              per_key_drain=0.05)
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
    # 生成期按 Ctrl+O → 全屏 transcript viewer(alt-screen)。持渲染锁,emit 线程阻塞不抢 stdout;
    # 先 sleep 让首轮 append 进 conversation,transcript 有内容。alt-screen 独立缓冲根治多 agent 显两份。
    if SKIP:
        return
    raw = run_live_fresh(bin_path, ["sleep:0.8", "type:请从 1 数到 60,每个数字单独占一行,不要省略", "key:enter",
                         "sleep:1.5", "key:ctrl_x", "key:ctrl_o", "sleep:0.8"],
              per_key_drain=0.05)
    assert b"\x1b[?1049h" in raw, "生成期 Ctrl+O 全屏 transcript 应进 alt-screen"
    assert b"Showing detailed transcript" in raw, "生成期 Ctrl+O 应渲染 cc 风格 transcript footer"


def test_T33_gen_ctrl_o_toggle_close(bin_path):
    # 生成期 Ctrl+O 开全屏(alt-screen)→ 再 Ctrl+O 关(viewer 认 0x0f/CSI-u 退出)→ 终端自动恢复回生成区。
    if SKIP:
        return
    raw = run_live_fresh(bin_path, ["sleep:0.8", "type:请从 1 数到 60,每个数字单独占一行,不要省略", "key:enter",
                         "sleep:1.5", "key:ctrl_x", "key:ctrl_o", "sleep:0.6", "key:ctrl_o", "sleep:1"],
              per_key_drain=0.05)
    a = TTYAssert(raw)
    assert b"\x1b[?1049h" in raw, "全屏 transcript 应进 alt-screen"
    assert b"Showing detailed transcript" in raw, "应一度显示 transcript footer"
    # 关闭后最终屏不残留 transcript footer。
    last = a.frame_screens[-1] if a.frame_screens else None
    if last is not None and last.find_last_row("Showing detailed transcript") is not None:
        a._fail("Ctrl+O 关闭后仍残留 transcript footer")


def test_T34_gen_shift_tab_cycles_mode(bin_path):
    # 生成期 Shift+Tab → 循环权限模式(footer mode part 变)。验证全局键经 dispatch 上抛后
    # 两期一致(对齐 cc Shift+Tab 在 isLoading 仍激活)。早期 bug:生成期 watcher 丢弃 action。
    # 注:mode part 替换 footer 的 "esc to interrupt" 段(同一行),故不能用它筛生成帧——
    # 直接在所有帧找 mode 切换标志。短查询 + shift_tab 早按,确保落在生成窗口。
    if SKIP:
        return
    # 用 default 模式启动(tty_driver 默认 bypassPermissions,其 cycle 是 bypass→default
    # 看不到 accept edits)。default 下 Shift+Tab → accept edits,可断言。
    raw = run_live_fresh(bin_path, ["sleep:0.8", "type:数到30每行一个数字", "key:enter",
                         "sleep:0.6", "key:shift_tab", "sleep:1.5"],
              per_key_drain=0.05, permission="default")
    a = TTYAssert(raw)
    # 某帧 footer 出现非 default 模式(accept edits / plan mode)——Shift+Tab 在生成期切换生效。
    ok = any(
        sc.find_last_row("accept edits") is not None or sc.find_last_row("plan mode") is not None
        for sc in a.frame_screens
    )
    if not ok:
        a._fail("生成期 Shift+Tab 未切换权限模式(footer 无 accept edits/plan mode)")


def test_generation_frames_are_synchronized(bin_path):
    """回归:生成期固定区重画(spinner tick / 文本流入)必须用 DEC 2026 同步输出包裹,
    否则 Windows Terminal 在 erase→draw 两步间呈现空白帧 → 输入框闪烁 + 分隔线分段。
    慢流 mock 触发多次重画,断言字节流里同步帧成对出现——screen.py 终态回放测不到闪动,
    故直接断言字节流的同步标记(这是"闪烁"这类帧间时序缺陷唯一可自动化的护栏)。"""
    import http.server
    import threading
    import time

    parts = [
        b'data: {"type":"message_start","message":{"id":"m","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n',
        b'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n',
        b'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello "}}\n\n',
        b'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}\n\n',
        b'data: {"type":"content_block_stop","index":0}\n\n',
        b'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}\n\n',
        b'data: {"type":"message_stop"}\n\n',
    ]

    class _Mock(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            return

        def do_POST(self):
            n = int(self.headers.get("content-length", "0"))
            self.rfile.read(n)
            body = b"".join(parts)
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            for p in parts:  # 分块慢发 → 多次 spinner tick / 文本重画
                try:
                    self.wfile.write(p)
                    self.wfile.flush()
                except OSError:
                    return
                time.sleep(0.15)

    srv = http.server.HTTPServer(("127.0.0.1", 0), _Mock)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{srv.server_port}/v1/messages"
    try:
        raw = run(bin_path, ["sleep:0.8", "type:hi", "key:enter", "sleep:2.5"], base_url=url)
    finally:
        srv.shutdown()

    nb = raw.count(b"\x1b[?2026h")
    ne = raw.count(b"\x1b[?2026l")
    assert nb > 0 and nb == ne, f"生成期重画帧应被 DEC2026 同步输出成对包裹: begin={nb} end={ne}"

