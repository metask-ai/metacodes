#!/usr/bin/env python3
"""顽固 mock LSP server:**trap 并忽略 SIGTERM**,只应 initialize/shutdown。
用于测 client.shutdown 的 SIGKILL 升级——SIGTERM 被吞,必须靠 SIGKILL 才能杀掉,
否则 reader 线程永挂、join 死锁。SIGKILL 不可 trap,transport.terminate 升级后一定杀死。
"""
import sys, json, signal

signal.signal(signal.SIGTERM, signal.SIG_IGN)  # 吞掉 SIGTERM

def read_message():
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
    return json.loads(sys.stdin.buffer.read(length).decode("utf-8"))

def send(obj):
    data = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(data))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()

def main():
    while True:
        msg = read_message()
        if msg is None:
            break
        method = msg.get("method")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": msg.get("id"), "result": {"capabilities": {"textDocumentSync": 1}}})
        elif method == "shutdown":
            # 故意**不**响应 shutdown(模拟卡死的 server)→ client 的 shutdown sendRequest 会 2s 超时,
            # 然后 terminate 发 SIGTERM(被吞)→ WNOHANG 查未死 → SIGKILL 强杀。
            pass
        # 不处理 exit,继续 loop(顽固)。

if __name__ == "__main__":
    main()
