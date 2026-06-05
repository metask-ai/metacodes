"""阶段1:? help overlay + Ctrl+O transcript overlay(新 UiState/dispatch/render 架构)。

全离线(死端口,不打模型)。验证:
  - 空框按 ? → 立即出 help 面板(不需回车),? 不进输入框。
  - help 下任意键 → 关闭,回正常输入框(prev_rows 收缩无残留)。
  - Ctrl+O → transcript overlay,且不进 alt screen(无 ESC[?1049h)。
  - transcript 滚动/关闭 → 回输入框。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import run  # noqa: E402
from asserts import TTYAssert  # noqa: E402


def _screen_text(a):
    return "\n".join(a.final.line_text(r) for r in range(a.final.rows))


def test_help_overlay_instant(bin_path):
    # 空框按 ? → 立即出 help(不需回车)。
    raw = run(bin_path, ["sleep:0.8", "type:?", "sleep:0.3"], per_key_drain=0.1)
    a = TTYAssert(raw)
    text = _screen_text(a)
    assert "Keyboard shortcuts" in text, text
    assert "Open transcript" in text, text
    # overlay 不得用 ESC[2J(不进 alt screen / 不清 scrollback)。
    a.assert_no_full_clear()


def test_help_overlay_dismiss(bin_path):
    # ? 开 help,再按任意字符关闭 → 回正常输入框(╭ ❯ footer),无残留 help 行。
    raw = run(bin_path, ["sleep:0.8", "type:?", "sleep:0.3", "type:x", "sleep:0.3"], per_key_drain=0.1)
    a = TTYAssert(raw)
    a.assert_box_present()
    a.assert_box_at_bottom()
    # 关闭后 help 标题不应再在屏(已被收缩擦除)。
    text = _screen_text(a)
    assert "Keyboard shortcuts" not in text, "help 关闭后仍残留:\n" + text


def test_ctrl_o_transcript_no_alt_screen(bin_path):
    # Ctrl+O 出 transcript overlay,关键:不进 alt screen(无 ESC[?1049h)。
    raw = run(bin_path, ["sleep:0.8", "key:ctrl_o", "sleep:0.4"], per_key_drain=0.1)
    a = TTYAssert(raw)
    text = _screen_text(a)
    assert "transcript" in text, text
    assert b"\x1b[?1049h" not in raw, "overlay 误进 alt screen(应是嵌入视图态)"


def test_ctrl_o_toggle_close(bin_path):
    # Ctrl+O 开 → 再 Ctrl+O 关 → 回输入框。
    raw = run(bin_path, ["sleep:0.8", "key:ctrl_o", "sleep:0.3", "key:ctrl_o", "sleep:0.3"], per_key_drain=0.1)
    a = TTYAssert(raw)
    a.assert_box_present()
    a.assert_box_at_bottom()
    assert b"\x1b[?1049h" not in raw


def test_question_in_nonempty_buffer_is_literal(bin_path):
    # 非空 buffer 按 ? → 普通字符进输入框(不开 help)。
    raw = run(bin_path, ["sleep:0.8", "type:foo?", "sleep:0.3"], per_key_drain=0.08)
    a = TTYAssert(raw)
    text = _screen_text(a)
    # foo? 应在输入框里,不出 help。
    assert "Keyboard shortcuts" not in text, "非空 buffer 的 ? 误触发 help"
    assert "foo?" in text, text
