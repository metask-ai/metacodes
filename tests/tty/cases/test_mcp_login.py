import http.client
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tty_driver import IS_WINDOWS, case_tmpdir  # noqa: E402
from e2e_helpers import SkipTest  # noqa: E402
from test_key_login import _cli  # noqa: E402

ZIG_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
AUTH_MOCK = os.path.join(ZIG_ROOT, "tests", "_harness", "mock_mcp_auth_server.py")
_SSH = {"SSH_CONNECTION": "192.0.2.10 50022 192.0.2.20 22", "SSH_TTY": "/dev/pts/7"}
_PASTE_LINE = "paste that page's address here and press Enter."
_OTHER_SIGN_IN = "That address is from another sign-in."
_NO_PTY = "the CLI's prompt is answered over a POSIX pty here"


class _AuthMock:
    def __enter__(self):
        self.proc = subprocess.Popen([sys.executable, AUTH_MOCK], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.port = int(self.proc.stdout.readline())
        return self

    def __exit__(self, *exc):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.proc.stdout.close()

    def _get(self, target):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request("GET", target)
            answer = conn.getresponse()
            return answer.getheader("Location"), answer.read()
        finally:
            conn.close()

    def seen(self, path):
        _, body = self._get("/log")
        entries = [json.loads(line) for line in body.decode().splitlines() if line]
        return [entry for entry in entries if entry.get("path") == path]

    def ended_on(self, out):
        found = re.search(rb"http://127\.0\.0\.1:\d+(/as/authorize\?[^\s]+)", out)
        assert found, out.decode("utf-8", "replace")
        location, _ = self._get(found.group(1).decode())
        assert location, "the authorization server did not send the browser back"
        return location


def _case(mock, extra):
    home = case_tmpdir("cc-tty-mcp-login-")
    state = os.path.join(home, ".metacodes")
    os.makedirs(state)
    with open(os.path.join(state, "config.json"), "w") as f:
        json.dump({"mcpServers": {"authd": {"type": "http", "url": f"http://127.0.0.1:{mock.port}/oauth-mcp"}}}, f)
    env = {
        "HOME": home,
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "METACODES_HOME": state,
        "METACODES_NO_PROBE": "1",
        "METACODES_KG_AUTOSTART": "0",
        "METACODES_JEV_URL": "off",
    }
    env.update(extra)
    return state, env


def _stored(state):
    directory = os.path.join(state, "mcp-oauth")
    return sorted(os.listdir(directory)) if os.path.isdir(directory) else []


def _refuse(out):
    found = re.search(rb"http://127\.0\.0\.1:\d+/as/authorize\?[^\s]+", out)
    assert found, out.decode("utf-8", "replace")
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(found.group(0).decode()).query)
    callback = urllib.parse.urlsplit(query["redirect_uri"][0])
    state = urllib.parse.quote(query["state"][0], safe="")
    conn = http.client.HTTPConnection("127.0.0.1", callback.port, timeout=5)
    try:
        conn.request("GET", f"{callback.path}?error=access_denied&error_description=The%20user%20said%20no&state={state}")
        conn.getresponse().read()
    finally:
        conn.close()
    return ""


def test_cli_mcp_login_over_ssh_names_the_forward_and_finishes_with_the_pasted_address(bin_path):
    if IS_WINDOWS:
        raise SkipTest(_NO_PTY)
    with _AuthMock() as mock:
        state, env = _case(mock, _SSH)
        ended_on = []

        def from_another_login(out):
            ended_on.append(mock.ended_on(out))
            return re.sub(r"state=[^&]*", "state=from-another-login", ended_on[0]) + "\r"

        code, out = _cli(os.path.abspath(bin_path), ["mcp", "login", "authd", "--no-browser"], env, [
            (_PASTE_LINE, from_another_login),
            (_OTHER_SIGN_IN, lambda _: ended_on[0] + "\r"),
        ])
        text = out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        redirect = re.search(r"Waiting for the redirect on http://localhost:(\d+)/callback", text)
        assert redirect, text
        port = redirect.group(1)
        assert f"Over SSH? Forward the port first: ssh -L {port}:127.0.0.1:{port} <you>@<this machine>" in text, text
        assert _OTHER_SIGN_IN in text, text
        assert "Logged in to MCP server 'authd'" in text, text
        stored = _stored(state)
        assert len(stored) == 1 and stored[0].startswith("authd-"), stored
        tokens = mock.seen("/as/token")
        assert len(tokens) == 1, tokens
        assert tokens[0]["form"]["grant_type"] == "authorization_code", tokens
        pasted_code = urllib.parse.parse_qs(urllib.parse.urlsplit(ended_on[0]).query)["code"][0]
        assert tokens[0]["form"]["code"] == pasted_code, tokens


def test_cli_mcp_login_stops_waiting_after_the_bound_and_stores_nothing(bin_path):
    if IS_WINDOWS:
        raise SkipTest(_NO_PTY)
    with _AuthMock() as mock:
        state, env = _case(mock, {"METACODES_LOGIN_CALLBACK_TIMEOUT_MS": "2000"})
        started = time.monotonic()
        code, out = _cli(os.path.abspath(bin_path), ["mcp", "login", "authd", "--no-browser"], env, [])
        elapsed = time.monotonic() - started
        text = out.decode("utf-8", "replace")
        assert code == 1, f"exit {code}:\n{text}"
        assert "error: login to 'authd' failed: no answer from the browser in 2 seconds; nothing was stored" in text, text
        assert _PASTE_LINE in text, text
        assert "Over SSH?" not in text, text
        assert 1.5 < elapsed < 15, f"took {elapsed:.1f}s"
        assert _stored(state) == [], _stored(state)
        assert mock.seen("/as/token") == [], mock.seen("/as/token")


def test_cli_mcp_login_ends_when_the_authorization_page_refuses_and_stores_nothing(bin_path):
    if IS_WINDOWS:
        raise SkipTest(_NO_PTY)
    with _AuthMock() as mock:
        state, env = _case(mock, {"METACODES_LOGIN_CALLBACK_TIMEOUT_MS": "8000"})
        started = time.monotonic()
        code, out = _cli(os.path.abspath(bin_path), ["mcp", "login", "authd", "--no-browser"], env, [
            (_PASTE_LINE, _refuse),
        ])
        elapsed = time.monotonic() - started
        text = out.decode("utf-8", "replace")
        assert code == 1, f"exit {code}:\n{text}"
        assert "The sign-in was refused: access_denied (The user said no)." in text, text
        assert "error: login to 'authd' failed: authorization was denied in the browser" in text, text
        assert "no answer from the browser" not in text, text
        assert elapsed < 6, f"took {elapsed:.1f}s"
        assert _stored(state) == [], _stored(state)
        assert mock.seen("/as/token") == [], mock.seen("/as/token")
