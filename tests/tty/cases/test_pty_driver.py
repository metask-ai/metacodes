import json
import os
import shlex
import subprocess
import sys

from tty_driver import IS_WINDOWS, case_tmpdir

try:
    from e2e_helpers import SkipTest
except ImportError:
    class SkipTest(Exception):
        pass

TTY_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASTE_BYTES = 256 * 1024
WRITTEN_BEFORE_READING = 256 * 1024
DRIVER_LIMIT_S = 60
PROGRAM_LIMIT_S = 90

PROGRAM = r"""
import os, select, signal, sys, time, tty
mode, paste, before, limit = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
signal.alarm(limit)
signal.signal(signal.SIGHUP, signal.SIG_IGN)
tty.setraw(0)
os.write(1, b"ready\r\n")
if mode == "writes-before-reading":
    select.select([0], [], [])
    os.write(1, b"." * before)
    got = 0
    while got < paste:
        chunk = os.read(0, 65536)
        if not chunk:
            sys.exit(1)
        got += len(chunk)
    os.write(1, b"\r\ngot %d\r\n" % got)
    sys.exit(0)
while mode == "floods":
    os.write(1, b"." * 65536)
while True:
    if mode == "chatters":
        os.write(1, b".")
    time.sleep(0.05)
"""

DRIVER = r"""
import json, os, signal, sys
sys.path.insert(0, sys.argv[1])
import tty_driver
program, events, arm = sys.argv[2], json.loads(sys.argv[3]), sys.argv[4]
alarm, wait_s = float(sys.argv[5]), float(sys.argv[6])
if wait_s:
    tty_driver.WAIT_S = wait_s


class Interrupted(BaseException):
    pass


def interrupt(signum, frame):
    raise Interrupted()


def alarm_on_entry(owner, name):
    real = getattr(owner, name)

    def armed(*args, **kwargs):
        signal.setitimer(signal.ITIMER_REAL, alarm)
        return real(*args, **kwargs)
    setattr(owner, name, armed)


if arm == "finish":
    alarm_on_entry(tty_driver._Capture, "finish")
elif arm == "reap":
    alarm_on_entry(tty_driver, "_reap")
signal.signal(signal.SIGALRM, interrupt)
before = len(os.listdir("/dev/fd"))
result = {"error": ""}
try:
    result["output"] = tty_driver.run(program, events, startup_drain=0).decode("latin-1")
    result["outcome"] = "returned"
except Interrupted:
    result["outcome"] = "interrupted"
except AssertionError as e:
    result["outcome"] = "failed"
    result["error"] = str(e)
signal.setitimer(signal.ITIMER_REAL, 0)
try:
    pid, _ = os.waitpid(-1, os.WNOHANG)
    result["program"] = "running" if pid == 0 else "exited, not reaped"
except ChildProcessError:
    result["program"] = "reaped"
result["fds_left_open"] = len(os.listdir("/dev/fd")) - before
print(json.dumps(result))
"""


def _program(mode):
    if IS_WINDOWS:
        raise SkipTest("the POSIX pty driver; ConPTY has its own")
    d = case_tmpdir("cc-tty-program-")
    script = os.path.join(d, "program.py")
    with open(script, "w", encoding="utf-8") as f:
        f.write(PROGRAM)
    path = os.path.join(d, "program")
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} -I {shlex.quote(script)} {mode} "
                f"{PASTE_BYTES} {WRITTEN_BEFORE_READING} {PROGRAM_LIMIT_S}\n")
    os.chmod(path, 0o755)
    return path


def _run_in_a_fresh_process(mode, events, arm="", alarm=0.0, wait_s=0.0):
    argv = [sys.executable, "-I", "-c", DRIVER, TTY_DIR, _program(mode), json.dumps(events), arm, str(alarm),
            str(wait_s)]
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=DRIVER_LIMIT_S)
    except subprocess.TimeoutExpired:
        raise AssertionError(f"the driver hung: it did not return within {DRIVER_LIMIT_S}s (#569)") from None
    assert out.returncode == 0, out.stderr
    return json.loads(out.stdout)


def _assert_nothing_left(result):
    assert result["program"] == "reaped", result
    assert result["fds_left_open"] == 0, result


def test_a_write_keeps_reading_what_the_program_writes_before_its_first_read(bin_path):
    result = _run_in_a_fresh_process(
        "writes-before-reading", ["waitbytes:ready:10", "raw:" + "y" * PASTE_BYTES, f"waitbytes:got {PASTE_BYTES}:10"])
    assert result["outcome"] == "returned", result
    assert result["output"].count(".") == WRITTEN_BEFORE_READING, result["output"][-200:]
    _assert_nothing_left(result)


def test_a_write_the_program_never_reads_fails_the_case_instead_of_hanging(bin_path):
    result = _run_in_a_fresh_process("lingers", ["waitbytes:ready:10", "raw:" + "y" * PASTE_BYTES], wait_s=1.0)
    assert result["outcome"] == "failed", result
    assert f"of {PASTE_BYTES} bytes written to its terminal within 1.0s" in result["error"], result
    _assert_nothing_left(result)


def test_a_case_that_fails_while_the_program_waits_to_write_leaves_nothing_behind(bin_path):
    result = _run_in_a_fresh_process("floods", ["waitbytes:ready:10", "waitbytes:never printed:0.3"])
    assert result["outcome"] == "failed", result
    _assert_nothing_left(result)


def test_a_case_interrupted_while_the_last_output_is_collected_leaves_nothing_behind(bin_path):
    result = _run_in_a_fresh_process("chatters", ["waitbytes:ready:10"], arm="finish", alarm=0.5)
    assert result["outcome"] == "interrupted", result
    _assert_nothing_left(result)


def test_a_case_interrupted_while_the_program_is_given_time_to_exit_leaves_nothing_behind(bin_path):
    result = _run_in_a_fresh_process("lingers", ["waitbytes:ready:10"], arm="reap", alarm=0.5)
    assert result["outcome"] == "interrupted", result
    _assert_nothing_left(result)
