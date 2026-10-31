#!/usr/bin/env python3
"""HTTP+SSE, SSE resumption and OAuth MCP mock for
tests/integration/mcp_sse_oauth_test.zig.

Listens on 127.0.0.1 (an ephemeral port printed as the first stdout line).

HTTP+SSE (2024-11-05):
  GET  /sse            event stream; first event `endpoint` names
                       /sse/messages?sessionId=<n> (a second one names
                       /sse/elsewhere and must be ignored); every answer is
                       a `message` event on it. Needs header X-Team: t1.
  POST /sse/messages   202; the answer goes to the session's stream.
  GET  /sse-foreign    an `endpoint` on another origin (must be refused).
  GET  /sse-oauth      /sse that requires a bearer token (401 otherwise).

Streamable HTTP resumption (2025-11-25):
  POST /resume         Classic server. tools/call answers with an SSE stream
                       that sends a primed event id e1 and `retry: 50`, then
                       an `id: e2` whose event never completes, and closes
                       without the response; GET /resume with
                       Last-Event-ID: e1 replays it.

OAuth (2025-11-25 authorization):
  POST /oauth-mcp      Classic server that answers 401 with
                       WWW-Authenticate resource_metadata=... unless the
                       bearer is a live access token.
  GET  /.well-known/oauth-protected-resource/oauth-mcp   (and /sse-oauth)
  GET  /.well-known/oauth-authorization-server/as
  POST /as/register    RFC 7591
  GET  /as/authorize   302 to the redirect URI with code and state
  POST /as/token       authorization_code (PKCE S256 + resource checked) and
                       refresh_token (rotates the refresh token)
  POST /control/revoke every access token issued so far stops working

GET /log returns every observation as JSON lines (for assertions).
"""
import base64
import hashlib
import json
import queue
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = []
LOCK = threading.Lock()
SESSIONS = {}
STATE = {
    "next_session": 0,
    "clients": {},
    "codes": {},
    "access": set(),
    "refresh": {},
    "issued": 0,
}
RESUME = {}


def record(**fields):
    with LOCK:
        LOG.append(fields)


def classic(method, rid, params, version="2025-06-18"):
    if method == "initialize":
        return {"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": version, "capabilities": {"tools": {}}, "serverInfo": {"name": "mock", "version": "1"}}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": rid, "result": {"tools": [{"name": "whoami", "inputSchema": {"type": "object"}}]}}
    if method == "tools/call":
        return {"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": "called:" + params.get("name", "")}]}}
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "Method not found"}}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def base(self):
        return "http://127.0.0.1:%d" % self.server.server_address[1]

    def reply(self, code, obj=None, headers=None, raw=None):
        body = raw if raw is not None else (b"" if obj is None else json.dumps(obj).encode())
        self.send_response(code)
        if obj is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def bearer(self):
        value = self.headers.get("Authorization") or ""
        return value[7:] if value.startswith("Bearer ") else None

    def challenge(self, resource_path):
        metadata = "%s/.well-known/oauth-protected-resource%s" % (self.base(), resource_path)
        header = 'Bearer error="invalid_token", resource_metadata="%s", scope="mcp:tools"' % metadata
        self.reply(401, {"error": "invalid_token"}, {"WWW-Authenticate": header})

    # -- GET ---------------------------------------------------------------

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)
        if path == "/log":
            with LOCK:
                body = "\n".join(json.dumps(entry) for entry in LOG).encode()
            return self.reply(200, raw=body)
        if path in ("/sse", "/sse-foreign", "/sse-oauth"):
            return self.sse_stream(path)
        if path == "/resume":
            return self.resume_get()
        if path.startswith("/.well-known/oauth-protected-resource/"):
            resource = path[len("/.well-known/oauth-protected-resource"):]
            record(path=path, method="GET")
            return self.reply(200, {
                "resource": self.base() + resource,
                "authorization_servers": [self.base() + "/as"],
                "scopes_supported": ["mcp:tools", "mcp:extra"],
            })
        if path == "/.well-known/oauth-authorization-server/as":
            record(path=path, method="GET")
            return self.reply(200, {
                "issuer": self.base() + "/as",
                "authorization_endpoint": self.base() + "/as/authorize",
                "token_endpoint": self.base() + "/as/token",
                "registration_endpoint": self.base() + "/as/register",
                "code_challenge_methods_supported": ["S256"],
            })
        if path == "/as/authorize":
            return self.authorize(query)
        self.reply(404)

    def sse_stream(self, path):
        headers = {key.lower(): value for key, value in self.headers.items()}
        record(path=path, method="GET", headers=headers)
        if path == "/sse-oauth" and self.bearer() not in STATE["access"]:
            return self.challenge("/sse-oauth")
        if path == "/sse" and headers.get("x-team") != "t1":
            return self.reply(400, {"error": "missing X-Team"})
        with LOCK:
            STATE["next_session"] += 1
            session = str(STATE["next_session"])
            SESSIONS[session] = queue.Queue()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        endpoint = "/sse/messages?sessionId=" + session
        if path == "/sse-foreign":
            endpoint = "http://evil.invalid/messages?sessionId=" + session
        self.wfile.write(b": hello\n\nevent: endpoint\ndata: " + endpoint.encode() + b"\n\n")
        # A second endpoint (a replaying proxy): the client keeps the first.
        self.wfile.write(b"event: endpoint\ndata: /sse/elsewhere\n\n")
        self.wfile.flush()
        outbox = SESSIONS[session]
        try:
            while True:
                message = outbox.get()
                if message is None:
                    break
                self.wfile.write(b"event: message\ndata: " + json.dumps(message).encode() + b"\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        record(path=path, method="STREAM-END", session=session)
        self.close_connection = True

    def resume_get(self):
        last = self.headers.get("Last-Event-ID")
        record(path="/resume", method="GET", last_event_id=last, session=self.headers.get("Mcp-Session-Id"))
        message = RESUME.pop(last, None)
        if message is None:
            return self.reply(405)
        data = b"id: e2\nevent: message\ndata: " + json.dumps(message).encode() + b"\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorize(self, query):
        def one(key):
            return (query.get(key) or [None])[0]
        record(path="/as/authorize", method="GET", query={key: one(key) for key in query})
        client = STATE["clients"].get(one("client_id"))
        redirect = one("redirect_uri")
        if client is None or redirect not in client or one("code_challenge_method") != "S256" or one("response_type") != "code":
            return self.reply(400, {"error": "invalid_request"})
        code = "code-%d" % (len(STATE["codes"]) + 1)
        STATE["codes"][code] = {"challenge": one("code_challenge"), "resource": one("resource"), "redirect": redirect, "client": one("client_id")}
        location = "%s?code=%s&state=%s" % (redirect, code, urllib.parse.quote(one("state") or ""))
        self.reply(302, headers={"Location": location})

    # -- POST --------------------------------------------------------------

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        headers = {key.lower(): value for key, value in self.headers.items()}
        if path == "/as/register":
            body = json.loads(raw)
            record(path=path, method="POST", body=body)
            client_id = "client-%d" % (len(STATE["clients"]) + 1)
            STATE["clients"][client_id] = body.get("redirect_uris", [])
            return self.reply(201, {"client_id": client_id, "redirect_uris": body.get("redirect_uris", [])})
        if path == "/as/token":
            return self.token(urllib.parse.parse_qs(raw.decode()))
        if path == "/control/revoke":
            STATE["access"].clear()
            return self.reply(204)
        message = json.loads(raw)
        method = message.get("method")
        rid = message.get("id")
        params = message.get("params") or {}
        query = urllib.parse.parse_qs(parsed.query)
        record(path=path, method=method, id=rid, headers=headers)
        if path == "/sse/messages":
            session = (query.get("sessionId") or [""])[0]
            outbox = SESSIONS.get(session)
            if outbox is None:
                return self.reply(404, raw=b"no session")
            self.reply(202, raw=b"Accepted")
            if method is None or method.startswith("notifications/"):
                return
            outbox.put(classic(method, rid, params, "2024-11-05"))
            return
        if path == "/oauth-mcp":
            if self.bearer() not in STATE["access"]:
                return self.challenge("/oauth-mcp")
            if method is None or method.startswith("notifications/"):
                return self.reply(202)
            if method == "server/discover":
                return self.reply(400, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "Method not found"}})
            answer = classic(method, rid, params)
            if method == "tools/call":
                answer["result"]["content"][0]["text"] = "token:" + self.bearer()
            return self.reply(200, answer)
        if path == "/resume":
            if method is None or method.startswith("notifications/"):
                return self.reply(202)
            if method == "server/discover":
                return self.reply(400, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "Method not found"}})
            answer = classic(method, rid, params)
            if method != "tools/call":
                return self.reply(200, answer, {"Mcp-Session-Id": "resume-1"} if method == "initialize" else None)
            # Prime the stream with an event id, then drop it before the
            # answer, as a server that polls (SEP-1699) does.
            RESUME["e1"] = answer
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            # e1 is dispatched; e2's event is cut before its blank line, so
            # the stream resumes from e1.
            self.wfile.write(b"id: e1\nretry: 50\ndata: \n\nid: e2\n")
            self.wfile.flush()
            self.close_connection = True
            return
        self.reply(404)

    def token(self, form):
        def one(key):
            return (form.get(key) or [None])[0]
        grant = one("grant_type")
        record(path="/as/token", method="POST", form={key: one(key) for key in form})
        if grant == "authorization_code":
            entry = STATE["codes"].pop(one("code"), None)
            if entry is None:
                return self.reply(400, {"error": "invalid_grant"})
            digest = hashlib.sha256((one("code_verifier") or "").encode()).digest()
            challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode()
            if challenge != entry["challenge"] or one("resource") != entry["resource"] or one("redirect_uri") != entry["redirect"] or one("client_id") != entry["client"]:
                return self.reply(400, {"error": "invalid_grant", "error_description": "pkce/resource/redirect mismatch"})
            return self.reply(200, self.issue(one("resource")))
        if grant == "refresh_token":
            resource = STATE["refresh"].pop(one("refresh_token"), None)
            if resource is None or resource != one("resource"):
                return self.reply(400, {"error": "invalid_grant"})
            return self.reply(200, self.issue(resource))
        return self.reply(400, {"error": "unsupported_grant_type"})

    def issue(self, resource):
        STATE["issued"] += 1
        n = STATE["issued"]
        STATE["access"].add("at-%d" % n)
        STATE["refresh"]["rt-%d" % n] = resource
        return {"access_token": "at-%d" % n, "token_type": "Bearer", "expires_in": 3600, "refresh_token": "rt-%d" % n, "scope": "mcp:tools"}


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    sys.stdout.write("%d\n" % server.server_address[1])
    sys.stdout.flush()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    sys.stdin.read()
    for outbox in list(SESSIONS.values()):
        outbox.put(None)
    server.shutdown()


if __name__ == "__main__":
    main()
