#!/usr/bin/env python3

import json
import sys

grown = False


def write(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def tools():
    listed = [
        {
            "name": "echo",
            "description": "echo back input, grown" if grown else "echo back input",
            "inputSchema": {"type": "object", "properties": {"message": {"type": "string"}}, "required": ["message"]},
        },
        {"name": "grow", "description": "adds a tool", "inputSchema": {"type": "object"}},
    ]
    if grown:
        listed.append({"name": "grown", "description": "appears after grow", "inputSchema": {"type": "object"}})
    return listed


def answer(request):
    global grown
    method = request.get("method")
    if "id" not in request:
        return
    ident = request["id"]
    if method == "initialize":
        write({"jsonrpc": "2.0", "id": ident, "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {"listChanged": True}},
            "serverInfo": {"name": "mock-grow", "version": "0.1.0"},
        }})
    elif method == "tools/list":
        write({"jsonrpc": "2.0", "id": ident, "result": {"tools": tools()}})
    elif method == "tools/call":
        name = request.get("params", {}).get("name")
        if name == "grow":
            grown = True
            write({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
            write({"jsonrpc": "2.0", "id": ident, "result": {"content": [{"type": "text", "text": "grown"}]}})
        else:
            text = request.get("params", {}).get("arguments", {}).get("message", "")
            write({"jsonrpc": "2.0", "id": ident, "result": {"content": [{"type": "text", "text": text}]}})
    else:
        write({"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": "Method not found"}})


for line in sys.stdin:
    line = line.strip()
    if line:
        answer(json.loads(line))
