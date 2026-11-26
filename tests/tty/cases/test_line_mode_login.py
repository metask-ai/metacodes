import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import metask_mock  # noqa: E402


def _wait(predicate, timeout=20.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


def _line_mode_login(bin_path, mock, wait_for_second_turn):
    tmp = tempfile.mkdtemp(prefix="cc-tty-line-login-")
    try:
        home, state, work = (os.path.join(tmp, d) for d in ("home", "state", "work"))
        for d in (home, state, work):
            os.makedirs(d)
        mock.sessions.append(metask_mock.session_tokens(1))
        mock.write_session(state)
        env = {"HOME": home, "PATH": "/usr/bin:/bin", "TMPDIR": "/tmp", "LANG": "en_US.UTF-8",
               "METACODES_NO_PROBE": "1", "METACODES_KG_AUTOSTART": "0", "METACODES_JEV_URL": "off",
               "METACODES_NO_STARTUP_ANIMATION": "1"}
        env.update({k: v for k, v in mock.env(home).items() if v is not None})
        proc = subprocess.Popen([os.path.abspath(bin_path), "--state-dir", state, "--permission", "bypassPermissions"],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=env, cwd=work)
        try:
            proc.stdin.write(b"first message\n")
            proc.stdin.flush()
            assert _wait(lambda: len(mock.messages) >= 1), "the first turn never reached the gateway"
            proc.stdin.write(b"/login metask\n")
            proc.stdin.flush()
            assert _wait(lambda: len(mock.sessions) >= 2), "the second sign-in was never issued"
            time.sleep(1.0)
            proc.stdin.write(b"second message\n")
            proc.stdin.flush()
            if wait_for_second_turn:
                _wait(lambda: len(mock.messages) >= 2)
            else:
                time.sleep(1.0)
            proc.stdin.close()
            out, err = proc.communicate(timeout=30)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()
        return out.decode("utf-8", "replace") + err.decode("utf-8", "replace")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_line_mode_login_metask_sends_the_new_sign_in_s_token_next(bin_path):
    with metask_mock.MetaskMock(distinct_sessions=True) as mock:
        output = _line_mode_login(bin_path, mock, wait_for_second_turn=True)
        assert len(mock.messages) >= 2, "the second turn never reached the gateway:\n" + output
        first_access, _ = metask_mock.session_tokens(1)
        second_access, _ = metask_mock.session_tokens(2)
        assert mock.messages[0][0] == f"Bearer {first_access}", (mock.messages, output)
        assert mock.messages[1][0] == f"Bearer {second_access}", (mock.messages, output)
        assert "another Metask gateway" not in output, output


def test_line_mode_login_metask_on_another_gateway_says_how_to_move(bin_path):
    with metask_mock.MetaskMock() as other:
        with metask_mock.MetaskMock(distinct_sessions=True, sign_in_gateways=(None, other.origin)) as mock:
            output = _line_mode_login(bin_path, mock, wait_for_second_turn=False)
            assert "another Metask gateway than the new sign-in" in output, output
