import os
import shlex
import shutil
import subprocess
import sys
import time

from tty_driver import case_tmpdir

try:
    from e2e_helpers import SkipTest
except Exception:  # noqa: BLE001
    class SkipTest(Exception):
        pass


COLS = 60
CHECK = chr(0x2705)
RULE = chr(0x2500)
PROMPT = chr(0x276F)
BOX_TOP = chr(0x256D) + RULE + " metacodes"
LOCALE = "C.UTF-8"


class Tmux:
    def __init__(self):
        self.socket = "cc-tty-wide-%d-%d" % (os.getpid(), time.monotonic_ns())
        self.env = {k: v for k, v in os.environ.items() if k != "TMUX"}
        self.env["LC_ALL"] = LOCALE

    def run(self, *args):
        argv = ["tmux", "-u", "-L", self.socket, "-f", os.devnull, *args]
        return subprocess.run(argv, env=self.env, capture_output=True, text=True, timeout=15).stdout

    def pane(self):
        return self.run("capture-pane", "-p", "-t", "w")

    def wait_for(self, text, timeout=15.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            pane = self.pane()
            if text in pane:
                return pane
            time.sleep(0.1)
        raise AssertionError("tmux pane never showed %r:\n%s" % (text, self.pane()))

    def settle(self, quiet=0.6, timeout=10.0):
        deadline = time.monotonic() + timeout
        last = self.pane()
        still_since = time.monotonic()
        while time.monotonic() < deadline:
            time.sleep(0.1)
            now = self.pane()
            if now != last:
                last = now
                still_since = time.monotonic()
            elif time.monotonic() - still_since >= quiet:
                break
        return last


def _offline_command(bin_path):
    home = case_tmpdir("cc-tty-tmux-home-")
    state = case_tmpdir("cc-tty-tmux-state-")
    return " ".join(shlex.quote(part) for part in [
        "env", "-i",
        "PATH=" + os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME=" + home,
        "TERM=tmux-256color",
        "LC_ALL=" + LOCALE,
        "METACODES_KG_AUTOSTART=0",
        "METACODES_LOG=*:warn",
        "METACODES_NO_PROBE=1",
        "METACODES_NO_STARTUP_ANIMATION=1",
        "METACODES_JEV_URL=off",
        "METASK_API_KEY=tty-dummy-key",
        "BROWSER=true",
        os.path.abspath(bin_path), "--permission", "bypassPermissions", "--state-dir", state,
        "--base-url", "http://127.0.0.1:1/v1/messages",
    ]) + "; sleep 60"


def _rule_rows(pane):
    return [line for line in pane.splitlines() if line.strip() and set(line.strip()) == {RULE}]


def test_a_prompt_of_wide_emoji_wrapping_in_tmux_leaves_no_rule_behind(bin_path):
    if sys.platform == "win32" or shutil.which("tmux") is None:
        raise SkipTest("needs tmux")
    tmux = Tmux()
    try:
        tmux.run("new-session", "-d", "-s", "w", "-x", str(COLS), "-y", "24", "-c", case_tmpdir("cc-tty-tmux-cwd-"),
                 _offline_command(bin_path))
        tmux.wait_for(PROMPT)
        start = tmux.settle()
        assert len(_rule_rows(start)) == 2, "the idle prompt has a rule above and below it:\n" + start
        line = CHECK * 20 + " done"
        tmux.run("send-keys", "-t", "w", "-l", line)
        tmux.settle()
        for _ in range(6):
            tmux.run("send-keys", "-t", "w", "BSpace")
            time.sleep(0.05)
        tmux.run("send-keys", "-t", "w", "-l", line)
        typed = tmux.settle()
        assert typed.count(CHECK) == 39, "the prompt should hold 39 checks over two rows:\n" + typed
        assert len(_rule_rows(typed)) == 2, "a redraw left a rule behind:\n" + typed
        tmux.run("send-keys", "-t", "w", "C-u")
        cleared = tmux.settle()
        assert len(_rule_rows(cleared)) == 2, "clearing the prompt left rules behind:\n" + cleared
        assert BOX_TOP in cleared, "the welcome box was pushed off the screen:\n" + cleared
    finally:
        tmux.run("kill-server")
