"""A local stand-in for Metask's OAuth server and gateway (#485, #527), loopback only.

`metacodes login` and the TUI's `/login` sign in with an authorization code and
PKCE: the browser opens the authorize URL, Metask redirects it back to
`http://localhost:<port>/auth/metask/callback?code=…&state=…`, and metacodes
trades the code for tokens at the token URL (the device code, `/login metask`,
asks `/api/oauth/device/code` for a code instead and polls the token URL with
it). The token response names the
gateway (`gateway_url`, here this server): the models are listed there with
the access token, and turns go there with it. Sign-out revokes the session at
`/api/oauth/revoke`. This server answers all of that (and a key's models and
the account's keys, for the key routes an older sign-in left), so a case can
sign in, choose, send a turn and sign out without an account or a real
request:

    with MetaskMock() as mock:
        env = mock.env(home)      # the URL overrides and a $BROWSER stub
        raw = run(bin, [...], env=env, base_url=None)
        mock.requests             # (method, path, authorization) of each request
        mock.revocations          # the body of each revocation request

The `$BROWSER` stub plays the user's browser: it reads the authorize URL it is
handed and requests the redirect URI with a code and the same `state`.

Every sign-in gets the same tokens (`ACCESS_TOKEN`, `REFRESH_TOKEN`) unless
`distinct_sessions` is set: then each one gets its own, `session_tokens(n)`
for the n-th (the first is the same pair), as a second sign-in at Metask is a
second authorization (#560). `revoke_answers` scripts the revocations: the
n-th is answered with that status, or held unanswered for None; the ones past
the list get 200.
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
# The name `/api/oauth/userinfo` gives the signed-in account.
ACCOUNT_NAME = "Mock User"
# The device code (`/login metask`, `metacodes login --provider metask`): the
# code the user would confirm elsewhere. The first poll is answered with the
# tokens, as if it had been confirmed already.
DEVICE_CODE = "mk-device-tty-0001"
USER_CODE = "MOCK-4711"


def session_tokens(n):
    """The (access, refresh) tokens of the n-th sign-in, with `distinct_sessions`."""
    return f"mk-access-tty-{n:04d}", f"mk-refresh-tty-{n:04d}"

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


# The Anthropic-shaped `effort` block the gateway sends with every chat model,
# all false, beside its own `reasoning.efforts` (as it answered on 2026-11-17).
ALL_FALSE_EFFORT = {"low": {"supported": False}, "max": {"supported": False}, "high": {"supported": False},
                    "medium": {"supported": False}, "supported": False}

# The gateway's `/v1/models`, in its capabilities format (#527): a chat model
# with two reasoning levels that cannot turn reasoning off, another chat model,
# and an image model the gateway does not serve on `/v1/messages` (the sign-in
# must not offer it).
DEFAULT_MODELS = [
    {"id": MODEL, "max_input_tokens": 200000, "max_tokens": 32000,
     "capabilities": {"endpoints": {"messages": {"supported": True, "status": "supported"}},
                      "effort": ALL_FALSE_EFFORT,
                      "reasoning": {"supported": True, "disable": {"supported": False},
                                    "efforts": ["low", "high"], "translated": True}}},
    {"id": "glm-5-air", "max_input_tokens": 128000, "max_tokens": 16000,
     "capabilities": {"endpoints": {"messages": {"supported": True, "status": "supported"}},
                      "effort": ALL_FALSE_EFFORT}},
    {"id": "image-model-only",
     "capabilities": {"endpoints": {"messages": {"supported": False, "status": "unsupported"},
                                    "images_generations": {"supported": True}}}},
]


class MetaskMock:
    def __init__(self, keys=None, reply="METASK_MOCK_REPLY", models=None, userinfo_stalls=False,
                 distinct_sessions=False, revoke_answers=()):
        # [(name, secret)]: the keys an older sign-in's key route lists.
        self.keys = [("dev key", KEY_SECRET), ("ops key", OTHER_KEY_SECRET)] if keys is None else keys
        self.models = DEFAULT_MODELS if models is None else models
        self.reply = reply
        self.requests = []
        self.messages = []  # (authorization, model) of each /v1/messages request
        self.revocations = []  # the body of each /api/oauth/revoke request
        self.device_requests = []  # the body of each /api/oauth/device/code request
        # A userinfo request is held, unanswered, until the mock closes.
        self.userinfo_stalls = userinfo_stalls
        self._unstall = threading.Event()
        # Each sign-in its own tokens (`session_tokens`); the pairs issued so far.
        self.distinct_sessions = distinct_sessions
        self.sessions = []
        # The status each revocation in turn is answered with (None: held).
        self.revoke_answers = list(revoke_answers)

    def _issue(self):
        """The tokens a sign-in (a code or a device code) is answered with."""
        if not self.distinct_sessions:
            return ACCESS_TOKEN, REFRESH_TOKEN
        pair = session_tokens(len(self.sessions) + 1)
        self.sessions.append(pair)
        return pair

    def _access_tokens(self):
        return {ACCESS_TOKEN} | {access for access, _ in self.sessions}

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
                if self.path.startswith("/api/oauth/userinfo"):
                    # Who the session belongs to, for the line that ends a sign-in.
                    if outer.userinfo_stalls:
                        outer._unstall.wait(60)
                        return
                    if auth not in {f"Bearer {token}" for token in outer._access_tokens()}:
                        return self._send(401, b'{"error":"invalid_token"}')
                    info = {"sub": "mock-user-1", "name": ACCOUNT_NAME, "email": "mock@example.invalid",
                            "client_id": "metacodes", "authorization_id": "auth-1"}
                    return self._send(200, json.dumps(info).encode())
                if self.path.startswith("/v1/models"):
                    allowed = ([f"Bearer {token}" for token in outer._access_tokens()]
                               + [f"Bearer {secret}" for _, secret in outer.keys])
                    if auth not in allowed:
                        return self._send(401, b'{"error":{"code":"invalid_api_key"}}')
                    return self._send(200, json.dumps({"object": "list", "data": outer.models}).encode())
                self._send(404, b'{"error":"not found"}')

            def do_POST(self):  # noqa: N802
                self._record()
                length = int(self.headers.get("content-length", 0))
                body = self.rfile.read(length)
                if self.path.startswith("/api/oauth/revoke"):
                    outer.revocations.append(body.decode("utf-8", "replace"))
                    status = outer.revoke_answers.pop(0) if outer.revoke_answers else 200
                    if status is None:
                        outer._unstall.wait(60)
                        return
                    return self._send(status, b"" if status == 200 else b'{"error":"server_error"}')
                if self.path.startswith("/api/oauth/device/code"):
                    outer.device_requests.append(body.decode("utf-8", "replace"))
                    grant = {"device_code": DEVICE_CODE, "user_code": USER_CODE,
                             "verification_uri": f"{outer.origin}/device",
                             "verification_uri_complete": f"{outer.origin}/device?user_code={USER_CODE}",
                             "expires_in": 600, "interval": 1}
                    return self._send(200, json.dumps(grant).encode())
                if self.path.startswith("/api/oauth/token") or self.path.startswith("/oauth/token"):
                    signs_in = b"tty-code-0001" in body or DEVICE_CODE.encode() in body
                    refreshes = [pair for pair in outer.sessions if pair[1].encode() in body]
                    if not signs_in and not refreshes and REFRESH_TOKEN.encode() not in body:
                        return self._send(400, b'{"error":"invalid_grant"}')
                    if b"client_id=metacodes" not in body and b'"client_id":"metacodes"' not in body:
                        return self._send(401, b'{"error":"invalid_client"}')
                    # A sign-in is a new authorization; a refresh keeps its own.
                    access, refresh = (outer._issue() if signs_in
                                       else refreshes[0] if refreshes else (ACCESS_TOKEN, REFRESH_TOKEN))
                    token = {"access_token": access, "refresh_token": refresh,
                             "token_type": "bearer", "expires_in": 3600,
                             "gateway_url": outer.origin, "models_url": f"{outer.origin}/v1/models",
                             "client_name": "metacodes", "scope": "read model:invoke"}
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
        self._unstall.set()
        self._server.shutdown()
        self._server.server_close()

    @property
    def origin(self):
        return f"http://127.0.0.1:{self.port}"

    def env(self, home):
        """The environment a session signs in against this mock with: the
        sign-in URLs, the authorization server (revocation, refresh), and the
        browser stub. The gateway is the one the token response names."""
        log = os.path.join(home, "browser-opened.txt")
        stub = os.path.join(home, "browser-stub")
        with open(stub, "w") as f:
            f.write(_BROWSER_STUB.format(python=sys.executable, log=log))
        os.chmod(stub, 0o755)
        self.browser_log = log
        return {
            "BROWSER": stub,
            "METACODE_OAUTH_AUTHORIZE_URL": f"{self.origin}/oauth/authorize",
            "METACODE_OAUTH_TOKEN_URL": f"{self.origin}/api/oauth/token",
            "METASK_SITE_URL": self.origin,
            "METASK_GATEWAY_URL": None,
            "METACODES_BASE_URL": None,
            "METACODE_API_KEYS_URL": None,
        }

    def key_route_env(self):
        """For a start on an older sign-in's key (`auth.json`): the Messages
        endpoint the historical key route uses."""
        return {"METACODES_BASE_URL": f"{self.origin}/v1/messages"}

    def write_session(self, state):
        """The Metask session `/login` stores (`oauth/metask.json`), naming
        this server as its gateway, and the model choice it leaves in
        `auth.json`."""
        oauth = os.path.join(state, "oauth")
        os.makedirs(oauth, exist_ok=True)
        path = os.path.join(oauth, "metask.json")
        with open(path, "w") as f:
            # The layout `provider/oauth.zig` stores (`renderStored`).
            json.dump({"schema_version": 1, "access_token": ACCESS_TOKEN, "refresh_token": REFRESH_TOKEN,
                       "token_type": "bearer", "expires_at": int(time.time()) + 3600,
                       "scope": "read model:invoke",
                       "gateway_url": self.origin, "models_url": f"{self.origin}/v1/models"}, f)
        os.chmod(path, 0o600)
        auth = os.path.join(state, "auth.json")
        with open(auth, "w") as f:
            json.dump({"selected_model": MODEL, "reasoning_effort": "low"}, f)
        os.chmod(auth, 0o600)
        return path

    def wait_for(self, predicate, timeout=10.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(0.05)
        return predicate()
