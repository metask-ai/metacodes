#!/usr/bin/env python3
"""最小 mock LSP server(供 client.zig 测试)。说 LSP base protocol:
- 读 Content-Length 帧;
- initialize → 回 capabilities(textDocumentSync=Full);
- initialized → 忽略;
- textDocument/didOpen / didChange → 回一条 publishDiagnostics(带该文档 version + 一条 ERROR 诊断);
- shutdown → 回 null;exit → 退出。
诊断内容可被 MOCK_LSP_MESSAGE env 覆盖(默认含独特标记 MOCK_LSP_DIAG)。
--silent:从不 publish;--skip-first:每个 uri 的首个 didOpen/didChange 不 publish;
--content:每个含 MOCK_BAD 的行报一条诊断(无则报空集)。
"""
import sys
import json
import os

def read_message():
    # 读 header 到 \r\n\r\n
    header = b""
    while b"\r\n\r\n" not in header:
        ch = sys.stdin.buffer.read(1)
        if not ch:
            return None
        header += ch
    length = 0
    for line in header.decode("ascii", "replace").split("\r\n"):
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())
    body = sys.stdin.buffer.read(length)
    return json.loads(body.decode("utf-8"))

def send(obj):
    data = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(data))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()

def diagnostic(line, message):
    return {
        "range": {"start": {"line": line, "character": 4}, "end": {"line": line, "character": 9}},
        "severity": 1,
        "code": "E123",
        "source": "mocklsp",
        "message": message,
    }

def publish(uri, version, diagnostics):
    send({
        "jsonrpc": "2.0",
        "method": "textDocument/publishDiagnostics",
        "params": {"uri": uri, "version": version, "diagnostics": diagnostics},
    })

def document_text(msg):
    params = msg["params"]
    if "contentChanges" in params:
        return params["contentChanges"][-1].get("text", "")
    return params["textDocument"].get("text", "")

def main():
    msg_text = os.environ.get("MOCK_LSP_MESSAGE", "MOCK_LSP_DIAG undefined name")
    silent = "--silent" in sys.argv
    skip_first = "--skip-first" in sys.argv
    from_content = "--content" in sys.argv
    seen_uris = set()
    while True:
        msg = read_message()
        if msg is None:
            break
        method = msg.get("method")
        mid = msg.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {"capabilities": {"textDocumentSync": 1}}})
        elif method == "initialized":
            pass
        elif method in ("textDocument/didOpen", "textDocument/didChange"):
            td = msg["params"]["textDocument"]
            uri = td["uri"]
            version = td.get("version", 0)
            first = uri not in seen_uris
            seen_uris.add(uri)
            if silent or (skip_first and first):
                continue
            if from_content:
                lines = document_text(msg).split("\n")
                diagnostics = [
                    diagnostic(n, "MOCK_LSP_DIAG at line %d" % (n + 1))
                    for n, text in enumerate(lines)
                    if "MOCK_BAD" in text
                ]
            else:
                diagnostics = [diagnostic(2, msg_text)]
            publish(uri, version, diagnostics)
        elif method == "textDocument/didSave":
            pass
        elif method == "mock/echo":
            send({"jsonrpc": "2.0", "id": mid, "result": None})
        elif method == "mock/publish":
            publish(msg["params"]["uri"], 0, [diagnostic(0, "MOCK_LSP_DIAG")])
        elif method == "shutdown":
            send({"jsonrpc": "2.0", "id": mid, "result": None})
        elif method == "exit":
            break
    sys.exit(0)

if __name__ == "__main__":
    main()
