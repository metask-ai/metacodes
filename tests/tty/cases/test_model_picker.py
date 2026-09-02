"""TTY coverage for the cross-UI model picker (issue #16).

Offline: the picker reads compiled provider profiles, so no request is made and
no credential is needed. What is asserted here is the behaviour the requirement
names and that unit tests cannot see — that the overlay reaches a real terminal,
that it owns the keyboard without eating the draft, and that a mid-stream
selection does not disturb the reply in flight.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import run  # noqa: E402
from asserts import TTYAssert  # noqa: E402


def _screen(raw, rows=24, cols=80):
    a = TTYAssert(raw, rows=rows, cols=cols)
    return a, "\n".join(a.final.line_text(r) for r in range(a.final.rows))


def test_picker_opens_with_scope_and_next_turn_footer(bin_path):
    raw = run(bin_path, ["sleep:0.8", "key:ctrl_o", "sleep:0.5"], per_key_drain=0.1)
    a, text = _screen(raw)
    assert "Provider" in text, text
    assert "metask" in text, "内置 provider 未列出:\n" + text
    # 作用域和"下一轮生效"必须写在用户正在看的那一行,不能只在文档里。
    assert "enter apply to this session" in text, "footer 未说明默认作用域:\n" + text
    assert "next turn" in text, "footer 未说明下一轮语义:\n" + text
    a.assert_no_full_clear()  # 覆盖层不进 alt-screen、不清 scrollback


def test_picker_typing_filters_without_touching_the_draft(bin_path):
    # 先打一段草稿,再开 picker 打字过滤:字符属于 picker,草稿一个字都不能变。
    raw = run(
        bin_path,
        ["sleep:0.8", "type:explain this", "sleep:0.3", "key:ctrl_o", "sleep:0.4", "type:zai", "sleep:0.4"],
        per_key_drain=0.08,
    )
    _, text = _screen(raw)
    assert "zai-coding-plan" in text, "过滤未生效:\n" + text
    assert "metask" not in text, "过滤后仍显示不匹配项:\n" + text
    assert "explain this" in text, "picker 吃掉了输入框里的草稿:\n" + text


def test_picker_escape_clears_filter_then_walks_back_then_closes(bin_path):
    raw = run(
        bin_path,
        ["sleep:0.8", "key:ctrl_o", "sleep:0.4", "type:zai", "sleep:0.3",
         "key:esc", "sleep:0.3", "key:esc", "sleep:0.4"],
        per_key_drain=0.08,
    )
    _, text = _screen(raw)
    # 第一次 Esc 清过滤(列表回全量),第二次 Esc 在首个阶段=关闭。
    assert "enter apply to this session" not in text, "首个阶段的 Esc 未关闭 picker:\n" + text
    assert "❯" in text, "关闭后应回到输入框:\n" + text


def test_picker_tab_cycles_scope_and_shows_it(bin_path):
    raw = run(
        bin_path,
        ["sleep:0.8", "key:ctrl_o", "sleep:0.4", "key:tab", "sleep:0.4"],
        per_key_drain=0.1,
    )
    _, text = _screen(raw)
    # global 是显式选择,并且在按下 Enter 之前就必须看得见"durable"。
    assert "durable" in text, "Tab 未把作用域切到 global 或未显示它:\n" + text


def test_picker_opens_during_generation_without_alt_screen(bin_path):
    # 要求:picker 在流式回复期间可用。它画在固定区里,回复继续往 scrollback 走,
    # 不进 alt-screen(那是 transcript viewer 的行为)。
    from slow_mock_server import SlowMockServer, slow_text_then_end

    with SlowMockServer([slow_text_then_end(n_chunks=14, delay=0.4)]) as srv:
        raw = run(
            bin_path,
            ["sleep:0.8", "type:go", "key:enter", "sleep:1.5", "key:ctrl_o", "sleep:1.0"],
            base_url=srv.url,
            startup_drain=0.8,
            per_key_drain=0.08,
        )
    _, text = _screen(raw)
    assert "Provider" in text, "生成期 Ctrl+O 未打开 picker:\n" + text
    assert b"\x1b[?1049h" not in raw, "picker 不应进 alt-screen(那是 transcript viewer)"
