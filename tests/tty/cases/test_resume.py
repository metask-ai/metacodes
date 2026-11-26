"""Resuming a session from the command line, aligned with Claude Code 2.1.278
(recorded in the workspace's ui_compare/cc2.1.278).

  - An interactive exit (/exit, Ctrl+C or Ctrl+D twice, EOF) from a session
    whose transcript is on disk ends with two dim lines:

        Resume this session with:
        metacodes --resume <id>

    A session with no transcript (no turn yet, or just `/clear`ed) and a
    non-tty run print nothing.
  - `metacodes --resume <id>` starts the REPL as that session with its
    conversation loaded: the next request carries it, and the turn is appended
    to the same transcript.
  - The resumed conversation is written back under the banner exactly as its
    turns were shown live (prompts, replies, tool cards); text the runtime
    injected (a max-token continuation request) stays hidden, as it was live.
    `/resume <id>` redraws the screen the same way, then shows itself and
    what it restored.
"""
import glob
import json
import os
import re
import subprocess

from tty_driver import run, READY, IDLE, wait_for, case_tmpdir, _build_env
from asserts import TTYAssert
from slow_mock_server import SlowMockServer, simple_text, text_turn, text_then_tool

HINT = "Resume this session with:"
SEED_PROMPT = "remember the word PELICAN"
SEED_REPLY = "PELICAN_ACK"


def _workspace():
    """An isolated state root and working directory (sessions are per directory)."""
    home = case_tmpdir("cc-tty-resume-home-")
    cwd = case_tmpdir("cc-tty-resume-cwd-")
    return {"HOME": home, "METACODES_HOME": os.path.join(home, ".metacodes")}, cwd


def _project_dirs(env):
    return glob.glob(os.path.join(env["METACODES_HOME"], "projects", "*"))


def _session_dirs(project):
    """The session directories of a project (it also holds `memory/`)."""
    return sorted(name for name in os.listdir(project) if re.fullmatch(r"[0-9a-f]{24}", name))


def _sessions(env):
    """Ids of the sessions whose transcript is on disk."""
    pattern = os.path.join(env["METACODES_HOME"], "projects", "*", "*", "transcript.jsonl")
    return sorted(os.path.basename(os.path.dirname(p)) for p in glob.glob(pattern))


def _transcript_lines(env, sid):
    (path,) = glob.glob(os.path.join(env["METACODES_HOME"], "projects", "*", sid, "transcript.jsonl"))
    with open(path, encoding="utf-8") as f:
        return [line for line in f if line.strip()]


def _turn(prompt, reply):
    return [READY, f"type:{prompt}", "key:enter", wait_for(reply), IDLE]


def _seed(bin_path, env, cwd):
    """One turn against a mock model, then /exit: the session id on disk and the screen."""
    with SlowMockServer([simple_text(SEED_REPLY)]) as srv:
        raw = run(bin_path, _turn(SEED_PROMPT, SEED_REPLY) + ["type:/exit", "key:enter", wait_for(HINT)],
                  env=env, cwd=cwd, base_url=srv.url)
    sessions = _sessions(env)
    assert len(sessions) == 1, f"one turn should leave one transcript: {sessions}"
    return sessions[0], raw


def _assert_hint(raw, sid):
    a = TTYAssert(raw)
    row = a.final.find_last_row(HINT)
    if row is None:
        a._fail("the exit should print the resume hint")
    a.assert_line_contains(row + 1, f"metacodes --resume {sid}")
    if a.final.line_text(row + 1).strip() != f"metacodes --resume {sid}":
        a._fail(f"the command line should be exactly `metacodes --resume {sid}`")
    for r in (row, row + 1):
        if a.final.line_attr_class(r) != "dim":
            a._fail(f"hint row {r} should be dim, is {a.final.line_attr_class(r)}")
    if a.final.line_text(row - 1).strip():
        a._fail("a blank line should separate the hint from what precedes it")
    a.assert_clean_exit()
    return a


def test_exit_after_a_turn_prints_the_resume_hint(bin_path):
    env, cwd = _workspace()
    sid, raw = _seed(bin_path, env, cwd)
    a = _assert_hint(raw, sid)
    # /exit still says goodbye first; the hint closes the session.
    goodbye = a.final.find_last_row("⎿  Goodbye!")
    if goodbye is None or goodbye > a.final.find_last_row(HINT):
        a._fail("`⎿  Goodbye!` should come before the hint")


def test_every_interactive_exit_prints_the_hint(bin_path):
    env, cwd = _workspace()
    sid, _ = _seed(bin_path, env, cwd)
    exits = {
        "/exit": ["type:/exit", "key:enter"],
        "Ctrl+C twice": ["key:ctrl_c", "key:ctrl_c"],
        "Ctrl+D twice": ["key:ctrl_d", "key:ctrl_d"],
    }
    for name, keys in exits.items():
        raw = run(bin_path, [READY] + keys + [wait_for(HINT)], env=env, cwd=cwd, extra_args=["--resume", sid])
        try:
            _assert_hint(raw, sid)
        except AssertionError as e:
            raise AssertionError(f"{name}: {e}") from None


def test_resume_restores_the_conversation(bin_path):
    env, cwd = _workspace()
    sid, _ = _seed(bin_path, env, cwd)
    with SlowMockServer([simple_text("SECOND_ACK")]) as srv:
        raw = run(bin_path, [wait_for("Resumed session (2 messages)")] + _turn("which word?", "SECOND_ACK")
                  + ["key:ctrl_c", "key:ctrl_c", wait_for(HINT)],
                  env=env, cwd=cwd, base_url=srv.url, extra_args=["--resume", sid])
    assert b"Resumed session (2 messages). Continue by sending a message." in raw, \
        "--resume should report the restored conversation"
    # The model sees the stored conversation ahead of the new prompt.
    assert len(srv.requests) == 1, f"expected one request, got {len(srv.requests)}"
    body = srv.requests[0]
    for part in (SEED_PROMPT.encode(), SEED_REPLY.encode(), b"which word?"):
        assert part in body, f"the resumed request is missing {part!r}"
    assert body.index(SEED_PROMPT.encode()) < body.index(b"which word?"), "the stored turn should come first"
    # The same session continues: its transcript grows past the restored
    # messages (none written twice), and no other session was made.
    assert len(_transcript_lines(env, sid)) == 4, _transcript_lines(env, sid)
    (project,) = _project_dirs(env)
    assert _session_dirs(project) == [sid], f"--resume should not create a session directory: {os.listdir(project)}"
    _assert_hint(raw, sid)


def test_no_hint_without_a_transcript(bin_path):
    env, cwd = _workspace()
    raw = run(bin_path, [READY, "key:ctrl_c", "key:ctrl_c", "strictsleep:1.0"], env=env, cwd=cwd)
    assert HINT.encode() not in raw, "a session that never ran a turn has nothing to resume"
    TTYAssert(raw).assert_clean_exit()
    # After /clear the current session is a new, empty one: no hint for it
    # (the cleared one is still on disk for /resume).
    with SlowMockServer([simple_text(SEED_REPLY)]) as srv:
        raw = run(bin_path, _turn(SEED_PROMPT, SEED_REPLY) + [
            "type:/clear", "key:enter", READY, "type:/exit", "key:enter", wait_for("Goodbye!"), "strictsleep:1.0",
        ], env=env, cwd=cwd, base_url=srv.url)
    assert HINT.encode() not in raw, "the session /clear started has no transcript"
    assert len(_sessions(env)) == 1, _sessions(env)


def test_non_tty_run_prints_no_hint(bin_path):
    env, cwd = _workspace()
    with SlowMockServer([simple_text(SEED_REPLY)]) as srv:
        full_env, ephemeral = _build_env(srv.url, env)
        assert ephemeral is None
        proc = subprocess.run(
            [os.path.abspath(bin_path), "--permission", "bypassPermissions", "--base-url", srv.url],
            input=f"{SEED_PROMPT}\n".encode(), capture_output=True, env=full_env, cwd=cwd, timeout=60,
        )
    out = proc.stdout + proc.stderr
    assert proc.returncode == 0, out.decode("utf-8", "replace")[-2000:]
    assert SEED_REPLY.encode() in out, "the piped turn should have run"
    assert len(_sessions(env)) == 1, "the piped turn should leave a transcript"
    assert HINT.encode() not in out, "a non-tty run prints no resume hint"


def test_resume_of_an_unknown_session_stops_before_the_repl(bin_path):
    env, cwd = _workspace()
    full_env, _ = _build_env("http://127.0.0.1:1/v1/messages", env)
    proc = subprocess.run(
        [os.path.abspath(bin_path), "--resume", "nosuchsession"],
        stdin=subprocess.DEVNULL, capture_output=True, env=full_env, cwd=cwd, timeout=60,
    )
    err = proc.stderr.decode("utf-8", "replace")
    assert proc.returncode == 1, (proc.returncode, err)
    assert "no session matching 'nosuchsession'" in err, err
    assert b"> " not in proc.stdout + proc.stderr, "the REPL must not start"
    assert all(not _session_dirs(p) for p in _project_dirs(env)), "no session directory is made"


CONTINUATION = "cut off by the token limit"


def _seed_tool_session(bin_path, env, cwd):
    """A turn with a Read call and a max-token continuation; the session id and
    the rows the live screen showed for it (prompt through the last reply)."""
    with open(os.path.join(cwd, "note.txt"), "w") as f:
        f.write("the word is PELICAN\n")
    read = json.dumps({"file_path": os.path.join(cwd, "note.txt")})
    turns = [
        text_then_tool("Let me read it.", "Read", read),
        text_turn("The word is **PELICAN**", "max_tokens"),
        text_turn(" and that is all.", "end_turn"),
    ]
    with SlowMockServer(turns) as srv:
        raw = run(bin_path, _turn("read note.txt", "that is all") + ["type:/exit", "key:enter", wait_for(HINT)],
                  env=env, cwd=cwd, base_url=srv.url)
    assert len(srv.requests) == 3, f"the seed turn should make 3 requests, made {len(srv.requests)}"
    assert CONTINUATION.encode() in srv.requests[2], "the third request should carry the continuation request"
    (sid,) = _sessions(env)
    final = TTYAssert(raw).final
    first, last = final.find_row("❯ read note.txt"), final.find_row("❯ /exit")
    assert first is not None and last is not None, final.render_ascii()
    live = [final.line_text(r) for r in range(first, last)]
    assert any("Read 1 file" in line for line in live), live
    assert not any(CONTINUATION in line for line in live), "the continuation request is not shown live"
    return sid, live


def _rows_from(final, first_text, count):
    first = final.find_row(first_text)
    if first is None:
        return first, []
    return first, [final.line_text(r) for r in range(first, first + count)]


def test_resume_replays_the_conversation_as_it_was_shown(bin_path):
    env, cwd = _workspace()
    sid, live = _seed_tool_session(bin_path, env, cwd)
    raw = run(bin_path, [wait_for("Resumed session (6 messages)"), READY, "key:ctrl_c", "key:ctrl_c", wait_for(HINT)],
              env=env, cwd=cwd, extra_args=["--resume", sid])
    a = TTYAssert(raw)
    first, rows = _rows_from(a.final, "❯ read note.txt", len(live))
    if rows != live:
        a._fail(f"the replay should match the live rows\nlive:   {live}\nreplay: {rows}")
    if first is None or a.final.find_row("metacodes v") is None or a.final.find_row("metacodes v") > first:
        a._fail("the conversation should follow the banner")
    a.assert_line_contains(first + len(live), "Resumed session (6 messages). Continue by sending a message.")
    assert CONTINUATION.encode() not in raw, "the host's continuation request must not be replayed"
    assert b"suggestion:" not in raw, "a resumed session gets no new-session suggestion"
    _assert_hint(raw, sid)


def test_resume_of_a_long_session_names_the_key_that_shows_the_rest(bin_path):
    env, cwd = _workspace()
    sid, _ = _seed(bin_path, env, cwd)
    (path,) = glob.glob(os.path.join(env["METACODES_HOME"], "projects", "*", sid, "transcript.jsonl"))
    turn = _transcript_lines(env, sid)
    with open(path, "a", encoding="utf-8") as f:
        for _ in range(110):
            f.writelines(turn)
    with SlowMockServer([simple_text("UNUSED")]) as srv:
        raw = run(bin_path, ["waitbytes:earlier messages:15", "sleep:0.5", "key:ctrl_c", "key:ctrl_c", wait_for(HINT)],
                  env=env, cwd=cwd, base_url=srv.url, extra_args=["--resume", sid])
    assert "earlier messages · ctrl+x ctrl+o shows the whole conversation".encode() in raw, \
        "the replay of a long session should name Ctrl+X Ctrl+O, the key that opens the transcript"


def test_resume_command_redraws_the_screen_as_the_resumed_session(bin_path):
    env, cwd = _workspace()
    sid, live = _seed_tool_session(bin_path, env, cwd)
    # A fresh session in the same directory shows something, then resumes the seed.
    raw = run(bin_path, [READY, "type:/cost", "key:enter", wait_for("Total cost:"),
                         READY, f"type:/resume {sid}", "key:enter", wait_for("Resumed session (6 messages)"),
                         READY, "key:ctrl_c", "key:ctrl_c", wait_for(HINT)], env=env, cwd=cwd)
    a = TTYAssert(raw)
    if a.final.find_row("Total cost:") is not None:
        a._fail("/resume should clear what the previous session showed")
    if a.final.find_row("metacodes v") != 0:
        a._fail("the banner should open the redrawn screen")
    first, rows = _rows_from(a.final, "❯ read note.txt", len(live))
    if rows != live:
        a._fail(f"the replay should match the live rows\nlive:   {live}\nreplay: {rows}")
    a.assert_line_contains(first + len(live), f"❯ /resume {sid}")
    a.assert_line_contains(first + len(live) + 1, "⎿  Resumed session (6 messages). Continue by sending a message.")
    assert CONTINUATION.encode() not in raw, "the host's continuation request must not be replayed"
    # The session is now the resumed one.
    _assert_hint(raw, sid)
