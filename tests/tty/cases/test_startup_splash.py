"""启动动画(src/repl/tui/splash.zig + splash_player.zig)在真二进制上的 L2 证据。

动画默认开;tty_driver 为其它用例默认关(METACODES_NO_STARTUP_ANIMATION=1),本文件经
env 传 None 打开。断言的都是用户看得见的结果:原地重绘了几十帧、定格的 "Metask Lab"
字标(只用 M e t a s k L b 这几个字母)留在 banner 框正上方、任意键跳到定格帧且这个键
进输入框、启动期间(动画中、动画后 App.init 还在等)敲的键按序进输入框、env 与 config.json
两个开关各自关得掉、窄终端不播。

ConPTY 会把输出流整屏重合成,原始字节(帧前缀、cursor-up 计数)在 Windows 上不可断言:
那两条用例在 Windows 上 SkipTest,其余只看屏幕终态,两平台都跑。
"""
import glob
import json
import os
import shutil
import subprocess
import time

from tty_driver import IDLE, IS_WINDOWS, READY, arrival_time, case_tmpdir, run, wait_for
from asserts import TTYAssert
from slow_mock_server import SlowMockServer, SlowModels, simple_text

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
# FIRST_FRAME as a driver event (`waitbytes:` takes \xNN escapes).
FIRST_FRAME_EVENT = "\\x1b[?25l\\x1b[?2026h\\r"
LONG_PASTE = ("x" * 49 + "\\r") * 100
MACOS_PTY_HOLDS = 1024
BANNER_TOP = "╭─ metacodes v".encode()
FRAME_BEGIN = b"\x1b[?2026h"


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
    # 跳过键是用户打的第一个字:动画跳过,这个键进输入框(以前被动画吃掉)。
    a.assert_input_echo("x")
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


def test_splash_plays_while_startup_waits(bin_path):
    """The splash starts before App.init and plays during it: it has settled
    while init is still waiting for `/v1/models`, and the banner follows the
    answer. (It used to start only after init returned: blank terminal for
    the whole wait, then 1.5 s more of animation.)"""
    if IS_WINDOWS:
        raise SkipTest("ConPTY re-encodes the stream; byte arrival times are not observable")
    server, base_url = SlowModels.serve(2.5)
    timeline = []
    try:
        raw = run(bin_path, [IDLE], term_size=SIZE, env=dict(ON, METACODES_NO_PROBE=None, **SlowModels.HOLD_STARTUP),
                  base_url=base_url, timeline=timeline)
    finally:
        server.shutdown()
    a = TTYAssert(raw, *SIZE)
    _assert_settled_wordmark(a)
    a.assert_box_present()
    assert len(SlowModels.answered) == 1, f"/v1/models answered {len(SlowModels.answered)} times"
    answered = SlowModels.answered[0]
    settled = arrival_time(timeline, raw, REDRAW, last=True)
    banner = arrival_time(timeline, raw, b"metacodes v")
    assert settled is not None and banner is not None
    assert settled < answered, f"the splash settled {settled - answered:.2f}s after init's wait ended"
    assert banner >= answered, "banner drawn before App.init finished"


def test_the_prompt_comes_without_a_models_list_that_does_not_answer(bin_path):
    if IS_WINDOWS:
        raise SkipTest("ConPTY re-encodes the stream; byte arrival times are not observable")
    server, base_url = SlowModels.serve(15.0)
    timeline = []
    try:
        started = time.monotonic()
        raw = run(bin_path, [IDLE], term_size=SIZE, env={"METACODES_NO_PROBE": None},
                  base_url=base_url, timeline=timeline)
    finally:
        server.shutdown()
    a = TTYAssert(raw, *SIZE)
    a.assert_box_present()
    assert not SlowModels.answered, "/v1/models answered before the case ended"
    box = arrival_time(timeline, raw, b'Try "fix typecheck errors"')
    assert box is not None
    assert box - started < 6.0, f"the prompt came {box - started:.2f}s after the start"


def _typed_during_startup(bin_path, env, first_key_after):
    """Start with `/v1/models` answering after 2.5 s (App.init waits for it),
    type `a`, then `b` 0.6 s later while App.init still waits, and return the
    screen once the prompt shows them. `first_key_after` is the event that
    marks when `a` goes out."""
    server, base_url = SlowModels.serve(2.5)
    try:
        raw = run(bin_path, [first_key_after, "raw:a", "strictsleep:0.6", "raw:b", wait_for("❯ ab"), IDLE],
                  term_size=SIZE, env=dict(env, METACODES_NO_PROBE=None, **SlowModels.HOLD_STARTUP), base_url=base_url,
                  startup_drain=0)
    finally:
        server.shutdown()
    assert SlowModels.answered, "App.init did not wait for /v1/models: nothing was typed during startup"
    return TTYAssert(raw, *SIZE), raw


# The Windows driver sends the first key only after the first frame that shows the
# cursor (tty_driver._run_windows): with the splash off that is the input box, so keys
# "typed during startup" would reach a prompt that is already up. With the splash on it is
# the splash's settled frame, and App.init is still waiting: keys sent then are startup input.
WINDOWS_TYPES_AFTER_FIRST_FRAME = (
    "the Windows driver sends keys only after the first frame (tty_driver._run_windows): "
    "it cannot type during the splash or before an input box drawn without one"
)


def _sent_during_startup(bin_path, raw_text, shown, cwd=None):
    """`raw_text` arrives after the splash, while App.init still waits for
    `/v1/models` (4 s), on both platforms; then the case waits for `shown`
    and 1.5 s more (a submitted line would be echoed above the box by then)."""
    if IS_WINDOWS:
        first = ["strictsleep:0.3"]  # the driver has waited for the splash's settled frame
    else:
        first = [f"waitbytes:{FIRST_FRAME_EVENT}:30", "strictsleep:1.8"]
    server, base_url = SlowModels.serve(4.0)
    try:
        raw = run(bin_path, first + ["raw:" + raw_text, shown, "strictsleep:1.5"],
                  term_size=SIZE, env=dict(ON, METACODES_NO_PROBE=None, **SlowModels.HOLD_STARTUP), base_url=base_url,
                  startup_drain=0, cwd=cwd)
    finally:
        server.shutdown()
    assert SlowModels.answered, "App.init did not wait for /v1/models"
    a = TTYAssert(raw, *SIZE)
    return a, "\n".join(a.final.line_text(r) for r in range(a.final.rows))


def test_lines_pasted_during_startup_land_in_the_prompt_unsubmitted(bin_path):
    """A multi-line paste right after starting, before the prompt is up, comes
    without bracketed paste (the REPL turns it on with its first prompt), so
    every newline is an Enter. It used to submit `line1` on its own and drop or
    queue the other lines. Now everything typed before the first prompt goes
    into it as one paste: three lines in the box, nothing submitted until the
    user presses Enter. The Enter after the last line is left out: kept, it
    made a fourth, empty line, and four lines fold into a placeholder."""
    a, screen = _sent_during_startup(bin_path, "line1\\rline2\\rline3\\r", wait_for("line3"))
    a.assert_box_height(3)
    top = a.box_top_row()
    for i, line in enumerate(("line1", "line2", "line3"), 1):
        a.assert_line_contains(top + i, line)
    # Submitted, `line1` would also be echoed above the box.
    assert sum("line1" in a.final.line_text(r) for r in range(a.final.rows)) == 1, "line1 was submitted:\n" + screen


def test_a_paste_longer_than_4_kib_during_startup_is_one_paste_unsubmitted(bin_path):
    """5000 bytes, a hundred lines. Only the first 4 KiB used to make the
    paste; the rest stayed with the terminal as typed keys, and its first
    newline submitted the cut paste with half a line."""
    _assert_one_paste_unsubmitted(_sent_during_startup(bin_path, LONG_PASTE, wait_for("[Pasted text #1"))[1])


def _assert_one_paste_unsubmitted(screen):
    assert "[Pasted text #1 " in screen and "#2" not in screen, screen
    assert "x" * 20 not in screen, "part of the paste was typed or submitted:\n" + screen
    assert "API request failed" not in screen and "Error" not in screen, "something was submitted:\n" + screen


def _plain_commit_repo_with_long_names():
    repo = case_tmpdir("cc-tty-paste-" + "long-name-" * 10)
    name = os.path.join("docs", "notes", "startup-output-" + "long-name-" * 8 + "paste.md")
    os.makedirs(os.path.join(repo, os.path.dirname(name)))
    with open(os.path.join(repo, name), "w", encoding="utf-8") as f:
        f.write("one\n")
    git = ["git", "-C", repo, "-c", "user.name=tty", "-c", "user.email=tty@example.invalid",
           "-c", "commit.gpgsign=false"]
    for args in (["init", "-q"], ["add", "."], ["commit", "-q", "-m", "plain"]):
        subprocess.run(git + args, check=True, capture_output=True)
    subprocess.run(["/usr/bin/env", "git", "log", "-1", "--name-only", "--pretty=format:"],
                   cwd=repo, env={}, capture_output=True)
    return repo


def test_a_paste_longer_than_4_kib_while_startup_writes_more_than_a_macos_pty_holds(bin_path):
    if IS_WINDOWS:
        raise SkipTest("ConPTY re-encodes the stream; what the program writes before its first read is not observable")
    if shutil.which("git") is None:
        raise SkipTest("git is not installed")
    a, screen = _sent_during_startup(bin_path, LONG_PASTE, wait_for("[Pasted text #1"),
                                     cwd=_plain_commit_repo_with_long_names())
    banner = a.raw.find(BANNER_TOP)
    first_frame = a.raw.find(FRAME_BEGIN, banner)
    assert 0 <= banner < first_frame, "no banner followed by a prompt:\n" + screen
    written = first_frame - banner
    assert written > MACOS_PTY_HOLDS, (
        f"only {written} bytes between the banner and the first prompt: the case needs more than "
        f"{MACOS_PTY_HOLDS} (what a macOS pty holds) written before the program's first read (#569)")
    _assert_one_paste_unsubmitted(screen)


def test_enter_that_skips_the_splash_leaves_the_prompt_empty(bin_path):
    """Enter is a key like any other for ending the splash; the newline it
    types is not kept, so the first prompt is empty, not a blank line with the
    cursor on a second one."""
    a, _ = _sent_during_startup(bin_path, "\\r", IDLE)
    a.assert_box_height(1)
    a.assert_input_echo("")


def test_keys_typed_during_the_splash_and_after_it_reach_the_prompt_in_order(bin_path):
    """`a` skips the splash, `b` comes while App.init still waits: both are the
    start of what the user types. The splash used to consume `a` (on Windows
    it flushed the console's whole input queue), and on POSIX the input box's
    raw-mode entry (TCSAFLUSH) dropped `b`. On Windows this was checked in
    Windows Terminal by hand (`skipped_by_key`, `abc` kept)."""
    if IS_WINDOWS:
        raise SkipTest(WINDOWS_TYPES_AFTER_FIRST_FRAME)
    a, raw = _typed_during_startup(bin_path, ON, f"waitbytes:{FIRST_FRAME_EVENT}:30")
    assert raw.count(REDRAW) < 10, "`a` did not cut the splash short"
    a.assert_input_echo("ab")
    a.assert_box_at_bottom()


def test_keys_typed_while_startup_waits_reach_the_prompt(bin_path):
    """No splash: everything typed before the prompt is up goes into it, in order."""
    if IS_WINDOWS:
        raise SkipTest(WINDOWS_TYPES_AFTER_FIRST_FRAME)
    a, _ = _typed_during_startup(bin_path, {}, "strictsleep:0.4")
    a.assert_input_echo("ab")
    a.assert_box_at_bottom()


def _assert_splash_ended_before(raw, error_text):
    """A startup error printed while the splash played: the splash's last write
    (its settled frame, cursor shown) comes before the error; or, stopped
    before its first frame, it drew nothing."""
    err = raw.find(error_text)
    assert err >= 0, "startup error not printed:\n" + raw.decode("utf-8", "replace")[-400:]
    if FIRST_FRAME not in raw:
        assert REDRAW not in raw
        return False
    last = max(raw.rfind(REDRAW), raw.find(FIRST_FRAME))
    assert last < err, "a splash frame was drawn after the error"
    assert b"\x1b[?25h" in raw[last:err], "cursor left hidden"
    return True


def test_splash_settles_before_an_init_error(bin_path):
    """App.init itself fails while the splash plays (a missing --plugin-dir)."""
    if IS_WINDOWS:
        raise SkipTest("ConPTY re-encodes the stream; the frame prefix to key off is not observable")
    missing = os.path.join(case_tmpdir("cc-tty-splash-"), "no-such-plugin")
    raw = run(bin_path, ["sleep:3"], term_size=SIZE, env=ON, extra_args=["--plugin-dir", missing])
    _assert_splash_ended_before(raw, b"InvalidPackageRoot")


def test_splash_is_cut_short_by_a_startup_error_after_init(bin_path):
    """`--resume` of a session whose transcript cannot be loaded fails after
    App.init, which a slow `/v1/models` keeps busy for 0.6 s: the splash has
    drawn frames by then, is settled at once, and the error follows it."""
    if IS_WINDOWS:
        raise SkipTest("ConPTY re-encodes the stream; the frame prefix to key off is not observable")
    home = case_tmpdir("cc-tty-splash-resume-")
    cwd = case_tmpdir("cc-tty-splash-resume-cwd-")
    env = {"HOME": home, "METACODES_HOME": os.path.join(home, ".metacodes")}
    with SlowMockServer([simple_text("SEEDED")]) as srv:
        run(bin_path, [READY, "type:hello", "key:enter", wait_for("SEEDED"), IDLE],
            env=env, cwd=cwd, base_url=srv.url)
    (transcript,) = glob.glob(os.path.join(env["METACODES_HOME"], "projects", "*", "*", "transcript.jsonl"))
    sid = os.path.basename(os.path.dirname(transcript))
    # A first-class PDF block, withdrawn: this build refuses to resume it.
    with open(transcript, "a", encoding="utf-8") as f:
        f.write(json.dumps({"role": "user", "blocks": [{"type": "document", "media_type": "application/pdf",
                                                         "title": "r.pdf", "pages": 1, "data": "JVBERi0xLjcK"}]}) + "\n")

    server, base_url = SlowModels.serve(0.6)
    try:
        raw = run(bin_path, ["sleep:4"], term_size=SIZE, cwd=cwd,
                  env=dict(env, METACODES_NO_STARTUP_ANIMATION=None, METACODES_NO_PROBE=None),
                  base_url=base_url, extra_args=["--resume", sid])
    finally:
        server.shutdown()
    assert _assert_splash_ended_before(raw, b"cannot resume session"), "the splash drew nothing in 0.6 s"
    redraws = raw.count(REDRAW)
    # Settled early: far fewer than the ~45 frames a full 1.5 s play draws.
    assert redraws < 35, f"{redraws} redraws: not cut short"



def test_splash_is_cut_short_by_a_repl_setup_error(bin_path):
    """The REPL refuses to start (a malformed METACODES_EVAL_METADATA) before
    its banner, while the splash still plays (App.init kept busy 0.6 s): the
    splash is settled first and the error follows it."""
    if IS_WINDOWS:
        raise SkipTest("ConPTY re-encodes the stream; the frame prefix to key off is not observable")
    server, base_url = SlowModels.serve(0.6)
    try:
        raw = run(bin_path, ["sleep:4"], term_size=SIZE, base_url=base_url,
                  env=dict(ON, METACODES_NO_PROBE=None, METACODES_EVAL_METADATA="{not json"))
    finally:
        server.shutdown()
    assert _assert_splash_ended_before(raw, b"InsecureEvaluationMetadataChannel"), "the splash drew nothing in 0.6 s"
