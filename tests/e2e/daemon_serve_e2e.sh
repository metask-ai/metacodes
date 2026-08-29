#!/usr/bin/env bash
# U10-D daemon serve e2e:真跑 `metacodes serve`,验 message→agent_loop→journal→SSE + SIGINT 优雅关停。
# 用 Python mock 假 Anthropic 后端(返回 end_turn "DAEMON_OK")。需 python3 + curl + 已 `zig build`。
# 断言失败 → exit 1。跑法:bash tests/e2e/daemon_serve_e2e.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/zig-out/bin/metacodes"
[ -x "$BIN" ] || { echo "FAIL: $BIN 不存在(先 zig build)"; exit 1; }
command -v python3 >/dev/null || { echo "SKIP: 无 python3"; exit 0; }

TMP="$(mktemp -d)"; export HOME="$TMP/home"; mkdir -p "$HOME"
mport=18091; dport=18092; out="$TMP/daemon.txt"
cleanup(){ kill -9 "${dpid:-0}" "${mpid:-0}" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

cat > "$TMP/mock.py" <<'PY'
import http.server, socketserver, sys
SSE=(b'data: {"type":"message_start","message":{"id":"m","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":0}}}\n\n'
 b'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
 b'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"DAEMON_OK"}}\n\n'
 b'data: {"type":"content_block_stop","index":0}\n\n'
 b'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}\n\n'
 b'data: {"type":"message_stop"}\n\n')
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(s):
        s.rfile.read(int(s.headers.get('Content-Length',0)))
        s.send_response(200); s.send_header('Content-Type','text/event-stream'); s.end_headers()
        s.wfile.write(SSE); s.wfile.flush()
    def log_message(s,*a): pass
socketserver.TCPServer.allow_reuse_address=True
socketserver.TCPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
PY

python3 "$TMP/mock.py" $mport & mpid=$!
sleep 1
NO_PROBE=1 METACODES_NO_PROBE=1 "$BIN" serve $dport --api-key test --base-url "http://127.0.0.1:$mport" >"$out" 2>&1 & dpid=$!
sleep 2

grep -q "daemon.*http://127.0.0.1:$dport" "$out" || { echo "FAIL: daemon 未监听"; cat "$out"; exit 1; }
ack=$(curl -s -X POST "http://127.0.0.1:$dport/message" -H "Origin: http://127.0.0.1:$dport" -d '{"text":"hi"}')
echo "$ack" | grep -q '"ok":true' || { echo "FAIL: /message 未接受: $ack"; exit 1; }

events=$(curl -s --max-time 3 "http://127.0.0.1:$dport/events")
echo "$events" | grep -q "DAEMON_OK" || { echo "FAIL: SSE 无 assistant 文本(driver 未跑 agent_loop?)"; echo "$events"; exit 1; }
echo "$events" | grep -q '"run_done".*end_turn' || { echo "FAIL: 无 run_done end_turn"; echo "$events"; exit 1; }

# ── U11:rich /state + /command(canonical 命令面;此前 daemon 是 "{}" + 501)──
state=$(curl -s "http://127.0.0.1:$dport/state")
echo "$state" | grep -q '"session_id"' || { echo "FAIL: /state 非 rich 快照: $state"; exit 1; }
echo "$state" | grep -q '"permission_mode"' || { echo "FAIL: /state 缺 permission_mode: $state"; exit 1; }
cack=$(curl -s -X POST "http://127.0.0.1:$dport/command" -H "Origin: http://127.0.0.1:$dport" -d '{"cmd":"/mode plan"}')
echo "$cack" | grep -q '"ok":true' || { echo "FAIL: /command 未入队: $cack"; exit 1; }
sleep 1
events2=$(curl -s --max-time 3 "http://127.0.0.1:$dport/events")
echo "$events2" | grep -q 'permission mode → plan' || { echo "FAIL: 无 command_result mode→plan"; echo "$events2"; exit 1; }
curl -s "http://127.0.0.1:$dport/state" | grep -q '"permission_mode":"plan"' || { echo "FAIL: /state 未反映 plan"; exit 1; }
# `!cmd` shell 车道:执行 + stdout 摘录回显进 command_result(浏览器用户可见)。
sack=$(curl -s -X POST "http://127.0.0.1:$dport/command" -H "Origin: http://127.0.0.1:$dport" -d '{"cmd":"!echo WIRE_SHELL_OK"}')
echo "$sack" | grep -q '"ok":true' || { echo "FAIL: shell /command 未入队: $sack"; exit 1; }
sleep 1
curl -s --max-time 3 "http://127.0.0.1:$dport/events" | grep -q 'WIRE_SHELL_OK' || { echo "FAIL: shell 输出未回显进 command_result"; exit 1; }

kill -INT $dpid
for i in $(seq 1 50); do kill -0 $dpid 2>/dev/null || break; sleep 0.1; done
if kill -0 $dpid 2>/dev/null; then echo "FAIL: SIGINT 后挂死(关停 join 未收敛)"; exit 1; fi
wait $dpid; rc=$?
[ "$rc" = 0 ] || { echo "FAIL: daemon 退出码 $rc(非 0)"; exit 1; }
grep -q "daemon closed" "$out" || { echo "FAIL: 无 'daemon closed'"; exit 1; }

echo "PASS: daemon e2e — message→agent_loop→journal→SSE + U11(rich /state + /command) + SIGINT 优雅关停"
