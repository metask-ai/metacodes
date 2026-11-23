"""A session's Run lease (`tool-observations.lock`) as the person at the terminal meets it.

  - The terminal closing (SIGHUP) or a `kill` (SIGTERM) during a Run stops the
    Run as Esc would: the journal gets its terminal record, the lease goes
    away, and the process exits.
  - A process killed mid-Run (SIGKILL) leaves its Run open and its lease
    behind. Resuming the session closes that Run as abandoned, says so, and
    runs the new turn. The same holds for the empty marker an older metacodes
    leaves, once no process has it open.
  - While another process holds the lease, a turn is refused with that
    process's pid, and the REPL stays up.
  - A hangup inherited as ignored (`nohup`) stays ignored.
"""
import glob
import json
import os
import re
import signal
import subprocess
import time

if os.name != "nt":
    import fcntl

from tty_driver import run, READY, IDLE, wait_for, case_tmpdir, _build_env
from asserts import TTYAssert
from slow_mock_server import SlowMockServer, simple_text, slow_text_then_end

try:
    from e2e_helpers import SkipTest
except ImportError:  # pragma: no cover - the runner always has it
    class SkipTest(Exception):
        pass

LEASE = "tool-observations.lock"
JOURNAL = "tool-observations.jsonl"
RESUMED = "RESUMED_REPLY"


def _require_posix():
    if os.name == "nt":
        raise SkipTest("signals and flock are POSIX; Windows has its own console-close path")


def _workspace(tag):
    home = case_tmpdir(f"cc-tty-lease-{tag}-home-")
    cwd = case_tmpdir(f"cc-tty-lease-{tag}-cwd-")
    return {"HOME": home, "METACODES_HOME": os.path.join(home, ".metacodes")}, cwd


def _session_dir(env):
    dirs = [d for d in glob.glob(os.path.join(env["METACODES_HOME"], "projects", "*", "*"))
            if re.fullmatch(r"[0-9a-f]{24}", os.path.basename(d))
            and os.path.exists(os.path.join(d, JOURNAL))]
    assert len(dirs) == 1, f"expected one session with a journal: {dirs}"
    return dirs[0]


def _events(session_dir):
    with open(os.path.join(session_dir, JOURNAL), encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def _kinds(session_dir):
    return [next(iter(record["event"])) for record in _events(session_dir)]


def _start_slow_turn(bin_path, env, cwd, then):
    """One finished turn (so the session has a transcript to resume), then a turn
    whose reply streams for ~20 s, with `then` run while it streams."""
    with SlowMockServer([simple_text("SEEDED"), slow_text_then_end(n_chunks=40, delay=0.5)]) as srv:
        # The footer says "esc to interrupt" only while a reply streams (text
        # itself is drawn when its block ends, too late to signal mid-Run).
        return run(bin_path, [READY, "type:seed", "key:enter", wait_for("SEEDED"), IDLE,
                              "type:count slowly", "key:enter", wait_for("esc to interrupt", 20),
                              "strictsleep:1"] + then,
                   env=env, cwd=cwd, base_url=srv.url)


def _screen_text(raw):
    """The final screen as one line of words: notices wrap at the terminal width."""
    return " ".join(" ".join(TTYAssert(raw).final.lines()).split())


def _resume_turn(bin_path, env, cwd, sid, events_after_reply=()):
    with SlowMockServer([simple_text(RESUMED)]) as srv:
        return run(bin_path, [READY, "type:continue", "key:enter", wait_for(RESUMED), IDLE]
                   + list(events_after_reply),
                   env=env, cwd=cwd, base_url=srv.url, extra_args=["--resume", sid])


def _signal_mid_run(bin_path, tag, signals):
    """Signal mid-Run: the Run is stopped and closed, the lease goes away, and
    the REPL leaves by itself (its way out prints the resume hint)."""
    _require_posix()
    env, cwd = _workspace(tag)
    raw = _start_slow_turn(bin_path, env, cwd, [f"signal:{signals}", wait_for("Resume this session with:", 8)])
    session = _session_dir(env)
    events = _events(session)
    kinds = [next(iter(record["event"])) for record in events]
    assert kinds.count("run_started") == 2 and kinds[-1] == "run_finished", kinds
    # Stopped mid-reply, not finished by the model.
    assert events[-1]["event"]["run_finished"]["stop_reason"] != "end_turn", events[-1]
    assert not os.path.exists(os.path.join(session, LEASE)), "a closed Run gives its lease up"
    screen = _screen_text(raw)
    assert "Resume this session with:" in screen, screen


def test_hangup_mid_run_closes_the_journal(bin_path):
    """The terminal closing mid-Run (SIGHUP)."""
    _signal_mid_run(bin_path, "hup", "HUP")


def test_closing_terminal_hangup_twice_closes_the_journal(bin_path):
    """A terminal closing under a shell sends SIGHUP twice, milliseconds apart:
    the shell forwards its own, and the kernel sends another when the shell
    exits. The second must not cut the first one's shutdown short."""
    _signal_mid_run(bin_path, "hup2", "HUP+0.02+HUP")


def test_terminate_mid_run_closes_the_journal(bin_path):
    """A `kill` mid-Run (SIGTERM), the terminal still open."""
    _signal_mid_run(bin_path, "term", "TERM")


def _signal_at_the_prompt(bin_path, tag, signals):
    _require_posix()
    env, cwd = _workspace(tag)
    with SlowMockServer([simple_text("SEEDED")]) as srv:
        raw = run(bin_path, [READY, "type:seed", "key:enter", wait_for("SEEDED"), IDLE,
                             f"signal:{signals}", wait_for("Resume this session with:", 8)],
                  env=env, cwd=cwd, base_url=srv.url)
    screen = _screen_text(raw)
    assert "Resume this session with:" in screen, screen


def test_terminate_at_the_prompt_leaves_at_once(bin_path):
    _signal_at_the_prompt(bin_path, "idle-term", "TERM")


def test_closing_terminal_at_the_prompt_leaves_at_once(bin_path):
    _signal_at_the_prompt(bin_path, "idle-hup2", "HUP+0.02+HUP")


def test_killed_mid_run_is_abandoned_on_resume(bin_path):
    """SIGKILL mid-Run leaves the Run open; the next turn closes it as abandoned and runs."""
    _require_posix()
    env, cwd = _workspace("kill")
    _start_slow_turn(bin_path, env, cwd, ["signal:KILL"])
    session = _session_dir(env)
    assert os.path.exists(os.path.join(session, LEASE)), "a killed owner cannot give its lease up"
    assert _kinds(session)[-1] != "run_finished"

    raw = _resume_turn(bin_path, env, cwd, os.path.basename(session))
    screen = _screen_text(raw)
    assert "It is now closed as abandoned" in screen and RESUMED in screen, screen
    kinds = _kinds(session)
    abandoned = kinds.index("run_abandoned")
    assert kinds[abandoned + 1] == "run_started" and kinds[-1] == "run_finished", kinds
    record = _events(session)[abandoned]
    assert record["event"]["run_abandoned"]["evidence"] == "lease_unlocked", record
    assert not os.path.exists(os.path.join(session, LEASE))


def test_older_metacodes_marker_is_abandoned_once_nobody_holds_it(bin_path):
    """The empty marker an older metacodes leaves, held by no process, is closed the same way."""
    _require_posix()
    env, cwd = _workspace("legacy")
    _start_slow_turn(bin_path, env, cwd, ["signal:KILL"])
    session = _session_dir(env)
    with open(os.path.join(session, LEASE), "w"):
        pass  # what an older metacodes leaves: empty, naming no owner

    raw = _resume_turn(bin_path, env, cwd, os.path.basename(session))
    screen = _screen_text(raw)
    assert "It is now closed as abandoned" in screen and RESUMED in screen, screen
    (record,) = [r for r in _events(session) if "run_abandoned" in r["event"]]
    assert record["event"]["run_abandoned"]["evidence"] == "legacy_lease_unheld", record


def test_a_held_lease_refuses_the_turn_and_names_its_process(bin_path):
    """Another live owner: the turn is refused with its pid; the REPL stays up."""
    _require_posix()
    env, cwd = _workspace("busy")
    with SlowMockServer([simple_text("SEEDED")]) as srv:
        run(bin_path, [READY, "type:seed", "key:enter", wait_for("SEEDED"), IDLE, "type:/exit", "key:enter"],
            env=env, cwd=cwd, base_url=srv.url)
    session = _session_dir(env)
    lease_path = os.path.join(session, LEASE)
    owner_pid = os.getpid()
    record = json.dumps({
        "schema_version": "metacodes-run-lease-v1",
        "pid": owner_pid,
        "run_id": "0123456789abcdef01234567",
        "acquired_wall_ns": 1793020790000000000,
        "state": "running",
    })
    fd = os.open(lease_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        os.write(fd, record.encode())
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with SlowMockServer([simple_text("SHOULD_NOT_REACH")]) as srv:
            raw = run(bin_path, [READY, "type:continue", "key:enter", wait_for(f"pid {owner_pid}"), IDLE,
                                 "type:/exit", "key:enter", wait_for("Resume this session with:")],
                      env=env, cwd=cwd, base_url=srv.url, extra_args=["--resume", os.path.basename(session)])
    finally:
        os.close(fd)
    a = TTYAssert(raw)
    assert a.final.find_last_row(f"pid {owner_pid}") is not None, a.final.render_ascii()
    # The REPL outlived the refusal: /exit still printed its resume hint.
    assert a.final.find_last_row("Resume this session with:") is not None, a.final.render_ascii()
    assert "SHOULD_NOT_REACH" not in raw.decode("utf-8", "replace")


def test_nohup_keeps_a_headless_run_through_a_hangup(bin_path):
    """`nohup metacodes -p ...`: SIGHUP inherited as ignored stays ignored."""
    _require_posix()
    env, cwd = _workspace("nohup")
    with SlowMockServer([slow_text_then_end(n_chunks=6, delay=0.5)]) as srv:
        full_env, _ = _build_env(srv.url, env)
        proc = subprocess.Popen(
            [os.path.abspath(bin_path), "--permission", "bypassPermissions", "--base-url", srv.url,
             "-p", "count slowly"],
            cwd=cwd, env=full_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            preexec_fn=lambda: signal.signal(signal.SIGHUP, signal.SIG_IGN),
        )
        try:
            time.sleep(1.5)  # inside the ~3 s reply
            proc.send_signal(signal.SIGHUP)
            out, err = proc.communicate(timeout=30)
        finally:
            if proc.poll() is None:
                proc.kill()
    assert proc.returncode == 0, (proc.returncode, err.decode("utf-8", "replace"))
    assert b"tok5" in out, out
    finished = _events(_session_dir(env))[-1]["event"]["run_finished"]
    assert finished["stop_reason"] == "end_turn", finished
