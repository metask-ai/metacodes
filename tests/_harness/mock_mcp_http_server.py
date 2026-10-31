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
  /dropcall   /keepalive that reads a tools/call and closes the connection
              without answering: the call executed, and nothing says so.
  /idleclose  /keepalive whose connections close 50 ms after each response,
            the way a server ends an idle keep-alive connection.
Every observation records the client port (`conn`: one TCP connection each)
and the request's `Connection` header.
GET /log returns every observation as JSON lines (for assertions).
"""
import json
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = []
LOCK = threading.Lock()
PENDING = {}


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
        if mode == "dropcall" and method == "tools/call":
            self.close_connection = True
            return
        if mode in ("keepalive", "idleclose", "dropcall"):
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

    def close_soon(self):
        connection = self.connection

        def later():
            time.sleep(0.05)
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

        threading.Thread(target=later, daemon=True).start()

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
        if mode == "idleclose":
            self.close_soon()

    def modern(self, method, rid, params, headers):
        meta = params.get("_meta") or {}
        if headers.get("mcp-protocol-version") != "2026-07-28" or headers.get("mcp-method") != method or meta.get("io.modelcontextprotocol/protocolVersion") != "2026-07-28":
            return self.reply(400, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32020, "message": "header mismatch"}})
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
