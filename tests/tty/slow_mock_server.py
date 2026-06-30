"""离线慢速 mock SSE 服务器:给需要"宽生成窗口"的 tty 测试用(如 Ctrl+B 转后台——必须在
某个 turn 执行期间注入按键)。真模型时序不可控、e2e 会 Skip;本 mock 把 turn 拉长成确定性窗口。

用法:
    from slow_mock_server import SlowMockServer
    with SlowMockServer(turns=[...]) as srv:
        raw = run(bin, [...], base_url=srv.url)

每个 turn 是一段已就绪的 SSE 文本(含 message_start..message_stop)。服务器按连接顺序逐 turn 回放;
turn 文本里可用 {"__delay__": 0.5} 之外——简单起见,turn 文本直接是完整 SSE bytes,调用方自己拼延迟。
"""
import http.server
import socketserver
import threading
import time


# 一段"慢吐 N 个 text chunk(每块 delay 秒)后发一个 tool_use(stop_reason=tool_use)"的 SSE。
# 用于 turn1:制造宽窗口让测试注入 Ctrl+B,且以 tool_use 收尾 → 会进 turn2(turn2 起点被转后台拦截)。
def slow_text_then_tooluse(n_chunks=15, delay=0.5, tool="Read", tool_input='{"file_path":"/tmp/bgtest_file.txt"}'):
    parts = [
        b'data: {"type":"message_start","message":{"id":"m1","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n',
        b'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n',
    ]
    for i in range(n_chunks):
        parts.append((b'__DELAY__%f\n' % delay))
        parts.append(('data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"tok%d "}}\n\n' % i).encode())
    parts += [
        b'data: {"type":"content_block_stop","index":0}\n\n',
        ('data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"%s","input":{}}}\n\n' % tool).encode(),
        ('data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":%s}}\n\n' % _json_str(tool_input)).encode(),
        b'data: {"type":"content_block_stop","index":1}\n\n',
        b'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}\n\n',
        b'data: {"type":"message_stop"}\n\n',
    ]
    return b''.join(parts)


def simple_text(text="SHOULD_NOT_REACH"):
    return (
        b'data: {"type":"message_start","message":{"id":"m2","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n'
        b'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
        + ('data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"%s"}}\n\n' % text).encode()
        + b'data: {"type":"content_block_stop","index":0}\n\n'
        b'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}\n\n'
        b'data: {"type":"message_stop"}\n\n'
    )


def _json_str(s):
    import json
    return json.dumps(s)


class SlowMockServer:
    """逐连接回放 turns[i]。turn bytes 里的 `__DELAY__<sec>\\n` 标记被解释成 sleep(用于宽窗口)。"""

    def __init__(self, turns):
        self.turns = turns
        self.turn_idx = 0
        self._srv = None
        self._thr = None
        self.port = None

    def __enter__(self):
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                ln = int(self.headers.get('content-length', 0))
                self.rfile.read(ln)
                self.send_response(200)
                self.send_header('content-type', 'text/event-stream')
                self.end_headers()
                idx = min(outer.turn_idx, len(outer.turns) - 1)
                outer.turn_idx += 1
                body = outer.turns[idx]
                # 逐段写,遇 __DELAY__ 标记 sleep。
                for chunk in _split_delays(body):
                    if isinstance(chunk, float):
                        time.sleep(chunk)
                    else:
                        try:
                            self.wfile.write(chunk)
                            self.wfile.flush()
                        except (BrokenPipeError, ConnectionResetError):
                            return

        socketserver.TCPServer.allow_reuse_address = True
        self._srv = socketserver.TCPServer(("127.0.0.1", 0), H)
        self.port = self._srv.server_address[1]
        self._thr = threading.Thread(target=self._srv.serve_forever, daemon=True)
        self._thr.start()
        return self

    @property
    def url(self):
        return "http://127.0.0.1:%d/v1/messages" % self.port

    def __exit__(self, *a):
        if self._srv:
            self._srv.shutdown()
            self._srv.server_close()


def _split_delays(body):
    """把 bytes 按 `__DELAY__<sec>\\n` 标记切成 [bytes, float(sleep), bytes, ...]。"""
    out = []
    i = 0
    marker = b'__DELAY__'
    while i < len(body):
        j = body.find(marker, i)
        if j == -1:
            out.append(body[i:])
            break
        if j > i:
            out.append(body[i:j])
        nl = body.find(b'\n', j)
        sec = float(body[j + len(marker):nl])
        out.append(sec)
        i = nl + 1
    return out
