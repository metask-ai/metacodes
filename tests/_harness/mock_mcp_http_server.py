#!/usr/bin/env python3
"""Streamable HTTP MCP mock for tests/integration/mcp_http_test.zig.

Listens on 127.0.0.1 (an ephemeral port printed as the first stdout line).
Paths select the server:
  /classic  2025-06-18 handshake, MCP-Session-Id, tools/list over SSE with a
            server->client ping that must be answered before the result.
  /modern   2026-07-28: server/discover, required MCP-Protocol-Version /
            Mcp-Method / _meta, paginated tools/list (empty-string cursor),
            x-mcp-header tools.
  /auth     always 401.
  /keepalive  a Classic server that answers initialize and tools/list over
            chunked SSE on a kept-alive connection and, like a Vercel edge,
            drops a request that asks for `Connection: close` unanswered.
  /noisy      /keepalive whose tools/call "noise" sends a tools/list_changed
              notification and a late answer to another request before its
              own, and whose "toolerror" answers with isError.
  /dropcall   /keepalive that reads a tools/call and closes the connection
              without answering: the call executed, and nothing says so.
  /idleclose  /keepalive whose connections stay open until GET /closeidle
            closes every one of them, the way a server ends idle keep-alive
            connections. The test asks for it between two requests, so no
            close can land inside an exchange.
  /strid    /keepalive whose tools/call pings with the string id "abc", asks
            for roots/list as "r1", and reports whether the replies carried
            those ids (a result for the ping, method-not-found for the roots).
  /expire   a Classic server with numbered sessions. GET /forget drops every
            live session (the next request on one is a 404); GET /failinit
            makes the next initialize a 503; GET /downgrade makes later
            initializes select 2025-06-18; GET /refusecalls makes every later
            tools/call a 404.
  /elicit   a Classic server whose tools/call asks for input over
            elicitation/create only when the session declared elicitation.
  /poll     /keepalive whose tools/call answers over SSE polling: each stream
            carries a priming event (new id, empty data) and closes, until the
            fifth GET with Last-Event-ID carries the result.
  /pollstuck  /poll whose resumed streams never carry a new event id.
Every observation records the client port (`conn`: one TCP connection each)
and the request's `Connection` header.
GET /log returns every observation as JSON lines (for assertions).
"""
import json
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = []
LOCK = threading.Lock()
PENDING = {}
REPLIES = {}
SESSIONS = {"next": 0, "live": set(), "refuse_calls": False, "declared": {}, "failed_inits": 0, "version": "2025-11-25"}
POLLS = {"count": 0}
POLL_ROUNDS = 5
# Client port -> socket of every /idleclose connection still open.
IDLECLOSE = {}


def record(**fields):
    with LOCK:
        LOG.append(fields)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, code, obj=None, headers=None):
        body = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(code)
        if obj is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/log":
            with LOCK:
                body = "\n".join(json.dumps(entry) for entry in LOG).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/closeidle":
            with LOCK:
                connections = list(IDLECLOSE.values())
                IDLECLOSE.clear()
            for connection in connections:
                # Synchronously, before this answer: the handler blocked
                # reading the next request sees EOF and closes its socket, and
                # anything the client sends after it is never read.
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            return self.reply(200, {"closed": len(connections)})
        if self.path == "/forget":
            with LOCK:
                SESSIONS["live"].clear()
            return self.reply(200, {})
        if self.path == "/failinit":
            with LOCK:
                SESSIONS["failed_inits"] = 1
            return self.reply(200, {})
        if self.path == "/downgrade":
            with LOCK:
                SESSIONS["version"] = "2025-06-18"
            return self.reply(200, {})
        if self.path == "/refusecalls":
            with LOCK:
                SESSIONS["refuse_calls"] = True
            return self.reply(200, {})
        if self.path in ("/poll", "/pollstuck"):
            return self.poll_get()
        self.reply(405)

    def do_DELETE(self):
        record(path=self.path, method="DELETE", session=self.headers.get("Mcp-Session-Id"))
        self.reply(200)

    def do_POST(self):
        mode = self.path.strip("/")
        length = int(self.headers.get("Content-Length", "0"))
        message = json.loads(self.rfile.read(length))
        headers = {key.lower(): value for key, value in self.headers.items()}
        method = message.get("method")
        rid = message.get("id")
        params = message.get("params") or {}
        record(path=self.path, method=method, id=rid, headers=headers, has_meta="_meta" in params,
               conn=self.client_address[1], connection=headers.get("connection"))
        if mode == "idleclose":
            with LOCK:
                IDLECLOSE[self.client_address[1]] = self.connection
        if mode == "dropcall" and method == "tools/call":
            self.close_connection = True
            return
        if mode == "noisy" and method == "tools/call":
            return self.noisy(rid, params)
        if mode in ("strid", "elicit") and method is None:
            with LOCK:
                REPLIES[rid] = message
            event = PENDING.get(rid)
            if event:
                event.set()
            return self.reply(202)
        if mode == "strid" and method == "tools/call":
            return self.strid(rid)
        if mode in ("poll", "pollstuck") and method == "tools/call":
            return self.poll_call(rid)
        if mode in ("expire", "elicit"):
            return self.sessions(mode, method, rid, params, headers)
        if mode in ("strid", "poll", "pollstuck"):
            return self.keepalive(mode, method, rid)
        if mode in ("keepalive", "idleclose", "dropcall", "noisy"):
            return self.keepalive(mode, method, rid)
        if mode == "auth":
            return self.reply(401, {"error": "unauthorized"})
        if method is None:
            event = PENDING.get(rid)
            if event:
                event.set()
            return self.reply(202)
        if mode == "classic":
            return self.classic(method, rid, params, headers)
        if mode == "modern":
            return self.modern(method, rid, params, headers)
        return self.reply(404, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "Method not found"}})

    def classic(self, method, rid, params, headers):
        if method == "server/discover":
            return self.reply(400, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": "Bad Request: not initialized"}})
        if method == "initialize":
            return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "classic", "version": "1"}}}, {"Mcp-Session-Id": "session-1"})
        if headers.get("mcp-session-id") != "session-1" or headers.get("mcp-protocol-version") != "2025-06-18":
            return self.reply(400, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": "missing session or version"}})
        if method.startswith("notifications/"):
            return self.reply(202)
        if method == "tools/list":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            event = threading.Event()
            PENDING[909] = event
            self.wfile.write(b": keep-alive\n\n")
            self.wfile.write(b"data: " + json.dumps({"jsonrpc": "2.0", "id": 909, "method": "ping"}).encode() + b"\n\n")
            self.wfile.flush()
            answered = event.wait(10)
            record(ping_answered=answered)
            result = {"jsonrpc": "2.0", "id": rid, "result": {"tools": [{"name": "sse_tool", "inputSchema": {"type": "object"}}]}}
            self.wfile.write(b"event: message\ndata: " + json.dumps(result).encode() + b"\n\n")
            self.wfile.flush()
            self.close_connection = True
            return
        if method == "tools/call":
            text = "classic:" + params.get("name", "")
            return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": text}]}})
        return self.reply(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "Method not found"}})

    def noisy(self, rid, params):
        if params.get("name") == "toolerror":
            return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": "tool said no"}], "isError": True}})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        messages = [
            {"jsonrpc": "2.0", "method": "notifications/tools/list_changed"},
            {"jsonrpc": "2.0", "id": 999999, "result": {"content": [{"type": "text", "text": "stale"}]}},
            {"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": "noise-done"}]}},
        ]
        data = b"".join(b"event: message\ndata: " + json.dumps(message).encode() + b"\n\n" for message in messages)
        self.wfile.write(b"%x\r\n%s\r\n0\r\n\r\n" % (len(data), data))
        self.wfile.flush()

    def sse_chunked(self, message):
        """One `message` event as a chunked SSE body that ends at once, so
        the connection can carry the next request."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        data = b"event: message\ndata: " + json.dumps(message).encode() + b"\n\n"
        self.wfile.write(b"%x\r\n%s\r\n0\r\n\r\n" % (len(data), data))
        self.wfile.flush()

    def sse_open(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

    def sse_chunk(self, data):
        self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
        self.wfile.flush()

    def sse_close(self):
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def await_reply(self, request_id, request):
        event = threading.Event()
        PENDING[request_id] = event
        self.sse_chunk(b"event: message\ndata: " + json.dumps(request).encode() + b"\n\n")
        answered = event.wait(3)
        with LOCK:
            return REPLIES.pop(request_id, None) if answered else None

    def strid(self, rid):
        self.sse_open()
        reply = self.await_reply("abc", {"jsonrpc": "2.0", "id": "abc", "method": "ping"})
        refusal = self.await_reply("r1", {"jsonrpc": "2.0", "id": "r1", "method": "roots/list"}) or {}
        text = "strid:%s:%s" % (
            "answered" if reply == {"jsonrpc": "2.0", "id": "abc", "result": {}} else "unanswered",
            "refused" if (refusal.get("error") or {}).get("code") == -32601 else "unrefused",
        )
        result = {"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": text}]}}
        self.sse_chunk(b"event: message\ndata: " + json.dumps(result).encode() + b"\n\n")
        self.sse_close()

    def poll_call(self, rid):
        with LOCK:
            POLLS["count"] = 0
            POLLS["rid"] = rid
        self.sse_open()
        self.sse_chunk(b"retry: 50\nid: p0\ndata: \n\n")
        self.sse_close()

    def poll_get(self):
        last = self.headers.get("Last-Event-ID")
        with LOCK:
            POLLS["count"] += 1
            count = POLLS["count"]
            rid = POLLS.get("rid")
        record(path=self.path, method="GET", last_event_id=last, conn=self.client_address[1])
        self.sse_open()
        if self.path == "/pollstuck":
            self.sse_chunk(b"retry: 50\nid: p0\ndata: \n\n")
        elif count < POLL_ROUNDS:
            self.sse_chunk(b"retry: 50\nid: p%d\ndata: \n\n" % count)
        else:
            result = {"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": "poll:done"}]}}
            self.sse_chunk(b"id: p%d\nevent: message\ndata: " % count + json.dumps(result).encode() + b"\n\n")
        self.sse_close()

    def sessions(self, mode, method, rid, params, headers):
        session = headers.get("mcp-session-id")
        if method == "server/discover":
            return self.reply(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32000, "message": "Bad Request: Unsupported protocol version: 2026-07-28"}})
        if method == "initialize":
            with LOCK:
                failing = SESSIONS["failed_inits"] > 0
                if failing:
                    SESSIONS["failed_inits"] -= 1
            if failing:
                return self.reply(503, {"error": "starting"})
            with LOCK:
                SESSIONS["next"] += 1
                assigned = "s%d" % SESSIONS["next"]
                SESSIONS["live"].add(assigned)
                SESSIONS["declared"][assigned] = "elicitation" in (params.get("capabilities") or {})
                version = SESSIONS["version"]
            record(path=self.path, declared=params.get("capabilities"))
            result = {"protocolVersion": version, "capabilities": {"tools": {}}, "serverInfo": {"name": mode, "version": "1"}}
            return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": result}, {"Mcp-Session-Id": assigned})
        with LOCK:
            live = session in SESSIONS["live"]
            refused = method == "tools/call" and SESSIONS["refuse_calls"]
            declared = SESSIONS["declared"].get(session, False)
        if not live or refused:
            return self.reply(404, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32001, "message": "Session not found"}})
        if method is None or method.startswith("notifications/"):
            return self.reply(202)
        if method == "tools/list":
            return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": {"tools": [{"name": "ask", "inputSchema": {"type": "object"}}]}})
        if method == "tools/call" and mode == "elicit":
            if not declared:
                return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": "elicit:undeclared"}]}})
            self.sse_open()
            ask = {"jsonrpc": "2.0", "id": "who-1", "method": "elicitation/create", "params": {"message": "who are you", "requestedSchema": {"type": "object", "properties": {"name": {"type": "string"}}}}}
            reply = self.await_reply("who-1", ask) or {}
            answer = reply.get("result") or {}
            text = "elicit:%s:%s" % (answer.get("action"), (answer.get("content") or {}).get("name"))
            result = {"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": text}]}}
            self.sse_chunk(b"event: message\ndata: " + json.dumps(result).encode() + b"\n\n")
            return self.sse_close()
        if method == "tools/call":
            return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": "expire:%s" % session}]}})
        return self.reply(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "Method not found"}})

    def keepalive(self, mode, method, rid):
        if (self.headers.get("Connection") or "").lower() == "close":
            # Vercel drops these intermittently; here always, so a client that
            # sends it cannot pass by luck.
            self.close_connection = True
            return
        if method is None or method.startswith("notifications/"):
            self.reply(202)
        elif method == "server/discover":
            # As developers.openai.com answers it: 400, and an error without id.
            self.reply(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32000, "message": "Bad Request: Unsupported protocol version: 2026-07-28"}})
        elif method == "initialize":
            self.sse_chunked({"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}}, "serverInfo": {"name": mode, "version": "1"}}})
        elif method == "tools/list":
            self.sse_chunked({"jsonrpc": "2.0", "id": rid, "result": {"tools": [{"name": "kept", "inputSchema": {"type": "object"}}]}})
        elif method == "tools/call":
            self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": "kept-call"}]}})
        else:
            self.reply(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "Method not found"}})

    def modern(self, method, rid, params, headers):
        meta = params.get("_meta") or {}
        if headers.get("mcp-protocol-version") != "2026-07-28" or headers.get("mcp-method") != method or meta.get("io.modelcontextprotocol/protocolVersion") != "2026-07-28":
            return self.reply(400, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32020, "message": "header mismatch"}})
        record(path=self.path, declared=meta.get("io.modelcontextprotocol/clientCapabilities"))
        if method == "server/discover":
            return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": {"resultType": "complete", "supportedVersions": ["2026-07-28"], "capabilities": {"tools": {}}, "ttlMs": 0, "cacheScope": "private"}})
        if method == "tools/list":
            if "cursor" not in params:
                tools = [
                    {"name": "regional", "inputSchema": {"type": "object", "properties": {"region": {"type": "string", "x-mcp-header": "Region"}, "q": {"type": "string"}}}},
                    {"name": "badannot", "inputSchema": {"type": "object", "properties": {"n": {"type": "number", "x-mcp-header": "N"}}}},
                ]
                return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": {"resultType": "complete", "tools": tools, "nextCursor": "", "ttlMs": 0, "cacheScope": "private"}})
            tools = [{"name": "second.page", "inputSchema": {"type": "object"}}]
            return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": {"resultType": "complete", "tools": tools, "ttlMs": 0, "cacheScope": "private"}})
        if method == "tools/call":
            text = "name-header:%s region-header:%s" % (headers.get("mcp-name"), headers.get("mcp-param-region"))
            return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": {"resultType": "complete", "content": [{"type": "text", "text": text}]}})
        return self.reply(404, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "Method not found"}})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    sys.stdout.write("%d\n" % server.server_address[1])
    sys.stdout.flush()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    # Exit when the test closes our stdin.
    sys.stdin.read()
    server.shutdown()


if __name__ == "__main__":
    main()
