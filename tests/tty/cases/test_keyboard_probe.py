"""启动期键盘协议探测(#327):认不出的终端被问 `CSI ? u` + DA1,答案决定发不发 Kitty 协议。

驱动就是终端:用例等二进制写出查询(`waitbytes:`),再按场景写回应答——肯定(Kitty flags 在
DA1 之前)、否定(只有 DA1)、超时(什么都不答)、应答之间夹着用户提前敲的键、应答晚于探测
才到。断言三件事:发没发 `\x1b[>1u`(Kitty enable)、多行时 footer 的换行提示与之一致、
提前敲的键一个不丢地进了输入框而应答一个字节都没漏进去。

POSIX pty 专属:Windows console 不探测(ConPTY 自己答 DA1、从不答 Kitty,见 bg_probe.zig),
ConPTY 也不透传应用发的私有序列,字节级断言在那里观测不到。
"""
import sys

from tty_driver import IDLE, READY, run, wait_for, case_tmpdir
from asserts import TTYAssert
from slow_mock_server import SlowModels

try:
    from e2e_helpers import SkipTest
except Exception:  # noqa: BLE001
    class SkipTest(Exception):
        pass


KITTY_QUERY = b"\x1b[?u"
KITTY_ENABLE = b"\x1b[>1u"
SHIFT_HINT = "shift + \u23ce for newline"
BACKSLASH_HINT = "\\ + \u23ce for newline"
# 等查询:DA1 是每轮的最后一个查询,它出现时整轮查询都已写出。
QUERY_SENT = "waitbytes:\\x1b[c:10"


def _posix_only():
    if sys.platform == "win32":
        raise SkipTest("Windows console 不探测;ConPTY 不透传私有序列")


def _unknown_terminal(**extra):
    """一个环境认不出的终端(TERM 普通、无 TERM_PROGRAM、不在复用器里),探测打开。"""
    env = {
        "TERM": "xterm-256color",
        "TERM_PROGRAM": None,
        "TMUX": None,
        "STY": None,
        "ZELLIJ": None,
        "METACODES_NO_PROBE": None,
    }
    env.update(extra)
    return env


def _run(bin_path, events, env, **kw):
    # startup_drain=0:查询在启动后几十毫秒内就写出,探测只等 ~120ms,不能先睡 0.8s 再应答。
    return run(bin_path, events, env=env, startup_drain=0, cwd=case_tmpdir("cc-tty-kbd-"), **kw)


def _slow_startup(bin_path, events, env, **kw):
    """App.init waits 2.5 s for `/v1/models`: bytes written in that window arrive
    before the REPL takes the terminal."""
    server, base_url = SlowModels.serve(2.5)
    try:
        return _run(bin_path, events, env, base_url=base_url, **kw)
    finally:
        server.shutdown()


def _screen(raw):
    a = TTYAssert(raw)
    return a, "\n".join(a.final.line_text(r) for r in range(a.final.rows))


def _screen_sized(raw, rows, cols):
    a = TTYAssert(raw, rows, cols)
    return a, "\n".join(a.final.line_text(r) for r in range(a.final.rows))


def test_probe_positive_enables_kitty_and_replays_typeahead(bin_path):
    _posix_only()
    raw = _run(bin_path, [
        QUERY_SENT,
        # 应答(背景色、Kitty flags、DA1)和用户在探测期间敲的键交错着到,一次写出:
        # 驱动的每个事件之后都要 settle,分开写会让 DA1 晚于探测的 ~120ms。
        "raw:ab\\x1b]11;rgb:0000/0000/0000\\x1b\\\\\\x1b[?1uc\\x1b[?62;22cd",
        wait_for("❯ abcd"),
        "key:shift_enter", "type:e",
        wait_for(SHIFT_HINT),
    ], _unknown_terminal())
    assert raw.count(KITTY_QUERY) == 1, "认不出的终端应被问一次 Kitty flags"
    assert KITTY_ENABLE in raw, "答了 Kitty flags 的终端应收到 Kitty enable"
    a, screen = _screen(raw)
    assert SHIFT_HINT in screen, "发了 Kitty 协议,多行提示应是 shift+⏎:\n" + screen
    top = a.box_top_row()
    a.assert_line_contains(top + 1, "abcd")
    a.assert_line_contains(top + 2, "e")
    for leak in ("62;22", "rgb:", "?1u"):
        assert leak not in screen, f"应答漏进了屏幕({leak!r}):\n" + screen


def test_probe_negative_keeps_kitty_off(bin_path):
    _posix_only()
    # Windows Terminal(ConPTY)实测的 DA1 原文,前面没有 Kitty 应答:确定的否定,不等超时。
    raw = _run(bin_path, [
        QUERY_SENT,
        "raw:\\x1b[?61;4;6;7;14;21;22;23;24;28;32;42;52c",
        wait_for('Try "fix typecheck errors"'),
        "type:x", "key:shift_enter", "type:y",
        wait_for(BACKSLASH_HINT),
    ], _unknown_terminal())
    assert KITTY_QUERY in raw, "认不出的终端应被问 Kitty flags"
    assert KITTY_ENABLE not in raw, "DA1 先到、没有 Kitty 应答 → 不应发 Kitty enable"
    _, screen = _screen(raw)
    assert BACKSLASH_HINT in screen, "没发 Kitty 协议,多行提示应是 \\+⏎:\n" + screen
    assert "52c" not in screen and "61;4" not in screen, "DA1 漏进了屏幕:\n" + screen


def test_probe_timeout_falls_back_and_late_answers_do_not_leak(bin_path):
    _posix_only()
    # 终端什么都不答:探测到期按"不知道"处理(不发),启动照常。应答晚于探测才到
    # (慢链路),这时 REPL 已在读键:整条吃掉,不能变成输入框里的字符。
    # 背景色应答以前会变成 Esc、字符、Esc:两次 Esc 连按清空输入框里已经打的 z。
    raw = _run(bin_path, [
        QUERY_SENT,
        wait_for('Try "fix typecheck errors"'),
        "type:z",
        "raw:\\x1b]11;rgb:ffff/ffff/ffff\\x1b\\\\\\x1b[?1u\\x1b[?62;22c",
        "key:shift_enter", "type:w",
        wait_for(BACKSLASH_HINT),
    ], _unknown_terminal())
    assert KITTY_ENABLE not in raw, "超时没有答案 → 不应发 Kitty enable"
    a, screen = _screen(raw)
    top = a.box_top_row()
    a.assert_line_contains(top + 1, "z")
    a.assert_line_contains(top + 2, "w")
    for leak in ("62;22", "?1u", "rgb:", "ffff"):
        assert leak not in screen, f"迟到的应答漏进了屏幕({leak!r}):\n" + screen


def test_deny_listed_terminal_is_not_asked(bin_path):
    _posix_only()
    # #23350 的教训:Apple Terminal 不发协议,也不问;背景色那一轮照问(DA1 作哨兵)。
    raw = _run(bin_path, [
        QUERY_SENT,
        "raw:\\x1b[?1u\\x1b[?62c",
        wait_for('Try "fix typecheck errors"'),
    ], _unknown_terminal(TERM_PROGRAM="Apple_Terminal"))
    assert KITTY_QUERY not in raw, "deny-list 上的终端不应被问 Kitty flags"
    assert KITTY_ENABLE not in raw, "deny-list 上的终端即便答了也不应收到 Kitty enable"


def test_tmux_is_not_asked_and_keeps_kitty(bin_path):
    _posix_only()
    # 复用器自己答查询(答的不是外层终端):tmux 照旧直接发,不问。
    raw = _run(bin_path, ["sleep:0.8"], _unknown_terminal(TMUX="/tmp/tmux-0/default,1,0"))
    assert KITTY_QUERY not in raw, "tmux 里不应探测"
    assert KITTY_ENABLE in raw, "tmux 照旧应收到 Kitty enable"


def test_tmux_multiline_hint_is_backslash_though_kitty_stays_on(bin_path):
    _posix_only()
    raw = _run(bin_path, [READY, "type:a\\", "raw:\\x0d", "type:b", wait_for(BACKSLASH_HINT, 5), "sleep:0.3"],
               _unknown_terminal(TMUX="/tmp/tmux-0/default,1,0"))
    a, screen = _screen(raw)
    assert KITTY_ENABLE in raw, "tmux should still get the Kitty enable"
    assert BACKSLASH_HINT in screen and SHIFT_HINT not in screen, \
        "in tmux Shift+Enter is a plain Enter unless extended-keys forwards it, so the hint must be \\+⏎:\n" + screen


def test_no_probe_env_skips_the_question(bin_path):
    _posix_only()
    raw = _run(bin_path, ["sleep:0.8"], _unknown_terminal(METACODES_NO_PROBE="1"))
    assert KITTY_QUERY not in raw and b"\x1b[c" not in raw, "METACODES_NO_PROBE 应跳过探测"
    assert KITTY_ENABLE not in raw, "没探测的认不出的终端照旧不发"


def test_no_keyboard_enhancement_env_skips_the_question_and_keeps_kitty_off(bin_path):
    _posix_only()
    raw = _run(bin_path, [
        QUERY_SENT,
        "raw:\\x1b[?1u\\x1b[?62c",
        wait_for('Try "fix typecheck errors"'),
        "type:x", "key:shift_enter", "type:y",
        wait_for(BACKSLASH_HINT),
    ], _unknown_terminal(METACODES_NO_KEYBOARD_ENHANCEMENT="1"))
    assert KITTY_QUERY not in raw, "METACODES_NO_KEYBOARD_ENHANCEMENT should skip the Kitty question"
    assert KITTY_ENABLE not in raw, "METACODES_NO_KEYBOARD_ENHANCEMENT should keep Kitty off even when the terminal answers"
    _, screen = _screen(raw)
    assert BACKSLASH_HINT in screen, "with the protocol off the multi-line hint should be \\+⏎:\n" + screen


# A full answer set, arriving after the probe stopped waiting (a slow link).
LATE_ANSWERS = "raw:\\x1b]11;rgb:ffff/ffff/ffff\\x1b\\\\\\x1b[?1u\\x1b[?62;22c"


def test_answer_queued_before_the_probe_is_not_taken_for_its_sentinel(bin_path):
    _posix_only()
    # A program that ran before left its DA1 answer unread in the input queue. Taken for this
    # round's sentinel it ended the round before the Kitty answer and the protocol stayed off.
    raw = _run(bin_path, [
        "raw:\\x1b[?62;22c",
        QUERY_SENT,
        "raw:\\x1b[?1u\\x1b[?62;22c",
        wait_for('Try "fix typecheck errors"'),
        "type:x", "key:shift_enter", "type:y",
        wait_for(SHIFT_HINT),
    ], _unknown_terminal(), per_key_drain=0.01)
    assert KITTY_ENABLE in raw, "an answer queued before the query was taken for this round's DA1"


def test_answer_cut_by_the_deadline_neither_echoes_nor_eats_the_next_key(bin_path):
    _posix_only()
    # The deadline falls inside DA1: `h` and `ESC[?62;` arrive in time, `22c` after, while
    # App.init still runs. The half answer used to go to the prompt's parser, which waited for
    # its tail (echoed, then flushed by the first raw-mode entry) and ate the `l` of `ls`.
    raw = _slow_startup(bin_path, [
        QUERY_SENT,
        "raw:h\\x1b[?62;",
        "strictsleep:0.3",
        "raw:22c",
        wait_for("❯ h"),
        "type:ls",
        wait_for("❯ hls"),
    ], _unknown_terminal())
    a, screen = _screen(raw)
    a.assert_input_echo("hls")
    assert b"22c" not in raw, "the tail of the cut answer was echoed:\n" + screen


def test_late_answers_during_a_slow_startup_are_not_echoed(bin_path):
    _posix_only()
    # The probe gave up after 120 ms; the answers come while App.init waits. The terminal
    # stays quiet until the REPL takes it, so the line discipline does not print them
    # (`^[[?62;22c` above the banner), and they never reach the prompt.
    raw = _slow_startup(bin_path, [
        QUERY_SENT,
        "strictsleep:0.3",
        LATE_ANSWERS,
        IDLE,
        "type:z",
        wait_for("❯ z"),
    ], _unknown_terminal())
    a, screen = _screen(raw)
    a.assert_input_echo("z")
    for echo in (b"62;22c", b"rgb:ffff"):
        assert echo not in raw, f"a late answer was echoed ({echo!r}):\n" + screen


def test_late_answers_do_not_skip_the_splash(bin_path):
    _posix_only()
    # The splash ends on a key. Late answers are not one: it plays to the end.
    raw = _run(bin_path, [
        QUERY_SENT,
        "strictsleep:0.3",
        LATE_ANSWERS,
        IDLE,
    ], _unknown_terminal(METACODES_NO_STARTUP_ANIMATION=None), term_size=(30, 100))
    redraws = raw.count(b"\x1b[?2026h\x1b[8A")
    assert redraws >= 15, f"{redraws} redraws: a late answer cut the splash short"
    a, screen = _screen_sized(raw, 30, 100)
    a.assert_input_echo("")
    assert "62;22c" not in screen


SPLASH_FIRST_FRAME = "waitbytes:\\x1b[?25l\\x1b[?2026h\\r:30"


def test_a_cut_answer_completed_during_the_splash_is_dropped_whole(bin_path):
    _posix_only()
    # The deadline falls inside DA1: `ESC[?62;` arrives in time, `22c` while the splash plays,
    # then a key ends the splash. The splash entered raw mode (TCSAFLUSH) before `22c` came,
    # on an empty queue; counted as a discard that may have taken the tail, it made the
    # answer be given up, and `22c` was typed into the prompt.
    raw = _slow_startup(bin_path, [
        QUERY_SENT,
        "raw:\\x1b[?62;",
        SPLASH_FIRST_FRAME,
        "strictsleep:0.3",
        "raw:22c",
        "strictsleep:0.3",
        "raw:ls",
        wait_for("❯ ls"),
    ], _unknown_terminal(METACODES_NO_STARTUP_ANIMATION=None), term_size=(30, 100))
    a, screen = _screen_sized(raw, 30, 100)
    a.assert_input_echo("ls")
    assert b"22c" not in raw, "the tail of the cut answer was echoed:\n" + screen


def test_keys_typed_one_by_one_after_a_lost_tail_are_typed(bin_path):
    _posix_only()
    # The deadline cuts OSC 11 inside its colour and the tail never comes. Then `fix the bug`
    # is typed a key every 100 ms while the splash plays (it reads each key as it comes).
    # `f` fits a colour; taking it used to restart the 200 ms wait for the tail, so each next
    # key, read within it, went into the answer as well: the prompt read `bug`.
    keys = []
    for c in "fix the bug":
        keys += ["raw:" + c, "strictsleep:0.1"]
    raw = _slow_startup(bin_path, [
        QUERY_SENT,
        "raw:\\x1b]11;rgb:1e1e/",
        SPLASH_FIRST_FRAME,
        "strictsleep:0.3",
        *keys,
        wait_for("❯ fix the bug"),
    ], _unknown_terminal(METACODES_NO_STARTUP_ANIMATION=None), term_size=(30, 100), per_key_drain=0.01)
    a, _ = _screen_sized(raw, 30, 100)
    a.assert_input_echo("fix the bug")


def test_a_flood_typed_after_a_timed_out_round_does_not_crash(bin_path):
    _posix_only()
    # The probe gave up (nothing answers); then more is typed during startup than stdin's
    # replay holds (4096 bytes): one byte short of it, then a Left arrow that straddles the
    # limit. Reading it out used to overrun the replay and panic (the Debug binary;
    # ReleaseSafe likewise) at the REPL's first raw-mode entry.
    flood = "p" * 4095
    raw = _slow_startup(bin_path, [
        QUERY_SENT,
        "strictsleep:0.3",
        "raw:" + flood + "\\x1b[Dd",
        wait_for("[Pasted text #1"),
    ], _unknown_terminal(), per_key_drain=0.01)
    assert b"panic" not in raw and b"unreachable" not in raw, raw[-400:].decode("utf-8", "replace")
    # Typed before the first prompt, all of it is one paste, closed: the prompt holds it as a
    # placeholder, and none of it spilled out as keys (an unclosed paste, then `Esc again`).
    _, screen = _screen(raw)
    assert "[Pasted text #1 " in screen and "#2" not in screen and "Esc again" not in screen, screen
