#!/usr/bin/env python3
"""最小 mock LSP server(供 client.zig 测试)。说 LSP base protocol:
- 读 Content-Length 帧;
- initialize → 回 capabilities(textDocumentSync=Full);
- initialized → 忽略;
- textDocument/didOpen / didChange → 回一条 publishDiagnostics(带该文档 version + 一条 ERROR 诊断);
- shutdown → 回 null;exit → 退出。
诊断内容可被 MOCK_LSP_MESSAGE env 覆盖(默认含独特标记 MOCK_LSP_DIAG)。
"""
import sys, json, os

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

def publish(uri, version, message):
    send({
        "jsonrpc": "2.0",
        "method": "textDocument/publishDiagnostics",
        "params": {
            "uri": uri,
            "version": version,
            "diagnostics": [{
                "range": {"start": {"line": 2, "character": 4}, "end": {"line": 2, "character": 9}},
                "severity": 1,
                "code": "E123",
                "source": "mocklsp",
                "message": message,
            }],
        },
    })

def main():
    msg_text = os.environ.get("MOCK_LSP_MESSAGE", "MOCK_LSP_DIAG undefined name")
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
            publish(uri, version, msg_text)
        elif method == "textDocument/didSave":
            pass
        elif method == "shutdown":
            send({"jsonrpc": "2.0", "id": mid, "result": None})
        elif method == "exit":
            break
    sys.exit(0)

if __name__ == "__main__":
    main()
