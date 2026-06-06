"""DIFF#3:`!` shell 模式 UI(对齐 cc 2.1.167)。

空框打 `!` → 前缀 ❯→!、placeholder→`Try "fix lint errors"`、footer→`! for shell mode`;
删到只剩 `!` 仍留 shell 态,删掉 `!` 才退回普通态。全离线(纯 UI 层,不打模型)。
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import run
from screen import Screen

SKIP = os.environ.get("TTY_SKIP_MODEL") == "1"


def _cap(bin_path, events, rows=24, cols=80):
    raw = run(bin_path, ["sleep:0.8"] + events, per_key_drain=0.07)
    sc = Screen(rows, cols)
    sc.feed(raw)
    return sc


def _content_row(sc):
    """输入框内容行(以 ❯ 或 ! 开头)。"""
    for r in range(sc.rows):
        t = sc.line_text(r).strip()
        if t.startswith("❯") or t.startswith("!"):
            return r, sc.line_text(r).strip()
    return None, ""


def _footer_row(sc):
    for r in range(sc.rows):
        t = sc.line_text(r)
        if "shell mode" in t or "shift+tab to cycle" in t:
            return r, t.strip()
    return None, ""


def test_shell_enter_on_bang(bin_path):
    # 空框打 `!` → 前缀 `!` + placeholder + footer `! for shell mode`。
    sc = _cap(bin_path, ["type:!", "sleep:0.3"])
    cr, ctext = _content_row(sc)
    fr, ftext = _footer_row(sc)
    assert ctext.startswith("!"), f"前缀应为 !,实得 {ctext!r}"
    assert "fix lint errors" in ctext, f"shell placeholder 缺失:{ctext!r}"
    assert "! for shell mode" in ftext, f"footer 应为 '! for shell mode',实得 {ftext!r}"


def test_shell_body_after_bang(bin_path):
    # `!ls` → 显示 `! ls`(sigil 作前缀,命令在后),footer 仍 shell。
    sc = _cap(bin_path, ["type:!ls", "sleep:0.3"])
    cr, ctext = _content_row(sc)
    fr, ftext = _footer_row(sc)
    assert ctext.replace(" ", "").startswith("!ls"), f"应显示 '! ls',实得 {ctext!r}"
    assert "! for shell mode" in ftext


def test_shell_delete_body_keeps_mode(bin_path):
    # `!ls` 删 `ls` → 回到 `!`+placeholder,仍 shell 态(不退)。
    sc = _cap(bin_path, ["type:!ls", "key:backspace", "key:backspace", "sleep:0.3"])
    cr, ctext = _content_row(sc)
    fr, ftext = _footer_row(sc)
    assert "fix lint errors" in ctext, f"删 body 后应回 shell placeholder:{ctext!r}"
    assert "! for shell mode" in ftext


def test_shell_delete_bang_exits(bin_path):
    # `!ls` 删 3 次(ls + !)→ 退回普通态 ❯ + 普通 placeholder + mode footer。
    sc = _cap(bin_path, ["type:!ls", "key:backspace", "key:backspace", "key:backspace", "sleep:0.3"])
    cr, ctext = _content_row(sc)
    fr, ftext = _footer_row(sc)
    assert ctext.startswith("❯"), f"删掉 ! 应退回 ❯,实得 {ctext!r}"
    assert "fix typecheck errors" in ctext, f"应回普通 placeholder:{ctext!r}"
    assert "shift+tab to cycle" in ftext, f"footer 应回 mode 行:{ftext!r}"


def test_shell_submit_executes(bin_path):
    # `!echo MARKER` 回车 → 执行 shell 命令,输出含 MARKER。
    if SKIP:
        return
    import re
    raw = run(bin_path, ["sleep:0.8", "type:!echo SHELLMODEMARK", "key:enter", "sleep:1.5"],
              per_key_drain=0.06, base_url=None)
    prose = re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]", b"", raw).decode("utf-8", "replace")
    assert "SHELLMODEMARK" in prose, "!cmd 未执行(输出缺 MARKER)"
