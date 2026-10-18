"""启动动画(src/repl/tui/splash.zig + splash_player.zig)在真二进制上的 L2 证据。

动画默认开;tty_driver 为其它用例默认关(METACODES_NO_STARTUP_ANIMATION=1),本文件经
env 传 None 打开。断言的都是用户看得见的结果:原地重绘了几十帧、定格的 "Metask Lab"
字标(只用 M e t a s k L b 这几个字母)留在 banner 框正上方、任意键跳到定格帧且这个键
被吃掉、env 与 config.json 两个开关各自关得掉、窄终端不播。

ConPTY 会把输出流整屏重合成,原始字节(帧前缀、cursor-up 计数)在 Windows 上不可断言:
那两条用例在 Windows 上 SkipTest,其余只看屏幕终态,两平台都跑。
"""
import json
import os

from tty_driver import IDLE, IS_WINDOWS, case_tmpdir, run
from asserts import TTYAssert

try:
    from e2e_helpers import SkipTest
except ImportError:  # pragma: no cover - runner 同款兜底
    class SkipTest(Exception):
        pass

SIZE = (30, 100)  # splash.layoutFor(100, 30):8 行区域
REGION_ROWS = 8
FIRST_FRAME = b"\x1b[?25l\x1b[?2026h\r"
REDRAW = b"\x1b[?2026h\x1b[8A"
ON = {"METACODES_NO_STARTUP_ANIMATION": None}
PALETTE = set("MetaskLb")


def _banner_top(a):
    sc = a.final
    for r in range(sc.rows):
        line = sc.line_text(r)
        if "╭" in line and "metacodes" in line:
            return r
    raise AssertionError("no banner box on screen:\n" + "\n".join(sc.lines()))


def _rows_above_banner(a):
    sc = a.final
    return [sc.line_text(r) for r in range(_banner_top(a))]


def _assert_settled_wordmark(a):
    above = _rows_above_banner(a)
    assert len(above) >= REGION_ROWS, f"banner at row {len(above)}: no 8-row splash above it\n" + "\n".join(above)
    rows = above[-REGION_ROWS:]
    text = "\n".join(rows)
    letters = "".join(rows).replace(" ", "")
    assert set(letters) <= PALETTE, f"letters outside Metask Lab: {sorted(set(letters) - PALETTE)}\n{text}"
    assert len(letters) > 250, f"only {len(letters)} lit cells; the wordmark did not settle\n{text}"
    # FORCE_COLOR=1 → basic_16:有颜色时笔画核心按序拼写品牌名。
    assert any(w in text for w in ("Meta", "task", "kLab")), f"core does not spell the name\n{text}"
    return rows


def _assert_no_splash(a, raw):
    assert FIRST_FRAME not in raw, "splash frame bytes present"
    above = [r for r in _rows_above_banner(a) if r.strip()]
    assert not above, "rows above the banner:\n" + "\n".join(above)
    a.assert_box_present()


def test_splash_plays_and_settles_above_banner(bin_path):
    raw = run(bin_path, [IDLE], term_size=SIZE, env=ON)
    a = TTYAssert(raw, *SIZE)
    rows = _assert_settled_wordmark(a)
    a.assert_box_present()
    a.assert_box_at_bottom()
    a.assert_cursor_on_content("")
    if not IS_WINDOWS:
        assert raw.count(FIRST_FRAME) == 1
        redraws = raw.count(REDRAW)
        assert redraws >= 15, f"only {redraws} in-place redraws in ~1.5s"
        # 定格帧(最后一次重绘)把光标显示回来。
        assert b"\x1b[?25h" in raw[raw.rfind(REDRAW):]
    return rows


def test_splash_any_key_skips_to_the_same_settled_wordmark(bin_path):
    if IS_WINDOWS:
        raise SkipTest("ConPTY re-encodes the stream; the frame prefix to key off is not observable")
    full = TTYAssert(run(bin_path, [IDLE], term_size=SIZE, env=ON), *SIZE)
    # startup_drain=0:默认的 0.8s 启动 drain 会在按键前吃掉大半段动画。
    raw = run(bin_path, ["waitbytes:\\x1b[?25l\\x1b[?2026h\\r:30", "raw:x", IDLE],
              term_size=SIZE, env=ON, startup_drain=0)
    a = TTYAssert(raw, *SIZE)
    redraws = raw.count(REDRAW)
    assert 1 <= redraws < 10, f"{redraws} redraws: the key did not cut the animation short"
    # 定格帧与跳过时刻无关。
    assert _assert_settled_wordmark(a) == _assert_settled_wordmark(full)
    # 跳过键被动画吃掉,没有漏进输入框。
    a.assert_cursor_on_content("")
    a.assert_box_at_bottom()


def test_splash_env_switch_keeps_it_off(bin_path):
    raw = run(bin_path, [IDLE], term_size=SIZE, env={"METACODES_NO_STARTUP_ANIMATION": "1"})
    _assert_no_splash(TTYAssert(raw, *SIZE), raw)


def test_splash_config_switch_keeps_it_off(bin_path):
    home = case_tmpdir("cc-tty-splash-")
    state = os.path.join(home, "state")
    os.makedirs(state)
    with open(os.path.join(state, "config.json"), "w") as f:
        json.dump({"startupAnimation": False}, f)
    env = dict(ON, HOME=home, METACODES_HOME=state)
    raw = run(bin_path, [IDLE], term_size=SIZE, env=env)
    _assert_no_splash(TTYAssert(raw, *SIZE), raw)


def test_splash_skips_a_terminal_too_narrow_for_the_wordmark(bin_path):
    raw = run(bin_path, [IDLE], term_size=(30, 60), env=ON)
    _assert_no_splash(TTYAssert(raw, 30, 60), raw)
