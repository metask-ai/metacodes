"""A local stand-in for Metask's browser sign-in and gateway (#485), loopback only.

`metacodes login` and the TUI's `/login` sign in with an authorization code and
PKCE: the browser opens the authorize URL, Metask redirects it back to
`http://localhost:<port>/auth/callback?code=…&state=…`, and metacodes trades
the code for tokens at the token URL. They then list the account's API keys
and a key's models through the Messages endpoint's origin. This server answers
all of that, and `/v1/messages` too, so a case can sign in, choose, and send a
turn without an account or a real request:

    with MetaskMock() as mock:
        env = mock.env(home)      # the URL overrides and a $BROWSER stub
        raw = run(bin, [...], env=env, base_url=None)
        mock.requests             # (method, path, authorization) of each request

The `$BROWSER` stub plays the user's browser: it reads the authorize URL it is
handed and requests the redirect URI with a code and the same `state`.
"""
import http.server
import json
import os
import sys
import threading
import time

ACCESS_TOKEN = "mk-access-tty-0001"
REFRESH_TOKEN = "mk-refresh-tty-0001"
KEY_SECRET = "sk-mk-tty-dev-0001"
OTHER_KEY_SECRET = "sk-mk-tty-ops-0002"
MODEL = "glm-5"

_BROWSER_STUB = r'''#!{python}
import sys, urllib.parse, urllib.request
url = sys.argv[1]
with open({log!r}, "a") as f:
    f.write(url + "\n")
query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
redirect = query["redirect_uri"][0]
state = query["state"][0]
target = redirect + "?" + urllib.parse.urlencode({{"code": "tty-code-0001", "state": state}})
urllib.request.urlopen(target, timeout=10).read()
'''


def _sse_text(text):
    return (
        'data: {"type":"message_start","message":{"id":"m1","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n'
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":%s}}\n\n'
        'data: {"type":"content_block_stop","index":0}\n\n'
        'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}\n\n'
        'data: {"type":"message_stop"}\n\n' % json.dumps(text)
    ).encode()


class MetaskMock:
    def __init__(self, keys=None, reply="METASK_MOCK_REPLY"):
        # [(name, secret)]; an empty list is an account without keys.
        self.keys = [("dev key", KEY_SECRET), ("ops key", OTHER_KEY_SECRET)] if keys is None else keys
        self.reply = reply
        self.requests = []
        self.messages = []  # (authorization, model) of each /v1/messages request

    def __enter__(self):
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):  # noqa: D401
                return

            def _send(self, status, body, content_type="application/json"):
                self.send_response(status)
                self.send_header("content-type", content_type)
                self.send_header("content-length", str(len(body)))
                self.send_header("connection", "close")
                self.end_headers()
                self.wfile.write(body)

            def _record(self):
                outer.requests.append((self.command, self.path, self.headers.get("authorization")))

            def do_GET(self):  # noqa: N802
                self._record()
                auth = self.headers.get("authorization")
                if self.path.startswith("/api/v1/keys"):
                    if auth != f"Bearer {ACCESS_TOKEN}":
                        return self._send(401, b'{"error":"unauthorized"}')
                    data = [{"id": f"key-{i}", "name": name, "api_key": secret, "status": "active"}
                            for i, (name, secret) in enumerate(outer.keys)]
                    return self._send(200, json.dumps({"data": data}).encode())
                if self.path.startswith("/v1/models"):
                    if auth not in (f"Bearer {secret}" for _, secret in outer.keys):
                        return self._send(401, b'{"error":"unauthorized"}')
                    body = {"data": [
                        {"id": MODEL, "max_input_tokens": 200000, "max_tokens": 32000,
                         "capabilities": {"effort": {"low": {"supported": True}, "high": {"supported": True}}}},
                        {"id": "glm-5-air", "max_input_tokens": 128000, "max_tokens": 16000},
                    ]}
                    return self._send(200, json.dumps(body).encode())
                self._send(404, b'{"error":"not found"}')

            def do_POST(self):  # noqa: N802
                self._record()
                length = int(self.headers.get("content-length", 0))
                body = self.rfile.read(length)
                if self.path.startswith("/oauth/token"):
                    if b"tty-code-0001" not in body:
                        return self._send(400, b'{"error":"invalid_grant"}')
                    token = {"access_token": ACCESS_TOKEN, "refresh_token": REFRESH_TOKEN,
                             "token_type": "Bearer", "expires_in": 3600}
                    return self._send(200, json.dumps(token).encode())
                if self.path.startswith("/v1/messages"):
                    model = None
                    try:
                        model = json.loads(body).get("model")
                    except ValueError:
                        pass
                    outer.messages.append((self.headers.get("authorization"), model))
                    return self._send(200, _sse_text(outer.reply), "text/event-stream")
                self._send(404, b'{"error":"not found"}')

        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self._server.server_address[1]
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc):
        self._server.shutdown()
        self._server.server_close()

    @property
    def origin(self):
        return f"http://127.0.0.1:{self.port}"

    def env(self, home):
        """The environment a session signs in against this mock with: the
        sign-in URLs, the Messages endpoint, and the browser stub."""
        log = os.path.join(home, "browser-opened.txt")
        stub = os.path.join(home, "browser-stub")
        with open(stub, "w") as f:
            f.write(_BROWSER_STUB.format(python=sys.executable, log=log))
        os.chmod(stub, 0o755)
        self.browser_log = log
        return {
            "BROWSER": stub,
            "METACODE_OAUTH_AUTHORIZE_URL": f"{self.origin}/oauth/authorize",
            "METACODE_OAUTH_TOKEN_URL": f"{self.origin}/oauth/token",
            "METACODES_BASE_URL": f"{self.origin}/v1/messages",
            "METACODE_API_KEYS_URL": None,
        }

    def wait_for(self, predicate, timeout=10.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(0.05)
        return predicate()
