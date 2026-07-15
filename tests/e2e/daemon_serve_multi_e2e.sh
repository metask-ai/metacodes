#!/usr/bin/env bash
# U10-C serve-multi e2e:真跑 `metacodes serve --sessions 2`,验 WebServer resolver 按 /s/<id>/* 路由到
# 各自 session,**消息路由隔离**(A 的消息绝不进 B 的 journal)+ 未知 session→404 + SIGINT 优雅关停全部。
# Python mock 假 Anthropic 后端(ThreadingHTTPServer,并发 2 driver 各自生成),返回 end_turn "DAEMON_OK"。
# 需 python3 + curl + 已 `zig build`。断言失败 → exit 1。跑法:bash tests/e2e/daemon_serve_multi_e2e.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/zig-out/bin/metacodes"
[ -x "$BIN" ] || { echo "FAIL: $BIN 不存在(先 zig build)"; exit 1; }
command -v python3 >/dev/null || { echo "SKIP: 无 python3"; exit 0; }

TMP="$(mktemp -d)"; export HOME="$TMP/home"; mkdir -p "$HOME"
mport=18095; dport=18096; out="$TMP/daemon.txt"
cleanup(){ kill -9 "${dpid:-0}" "${mpid:-0}" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

cat > "$TMP/mock.py" <<'PY'
import http.server, sys
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
http.server.ThreadingHTTPServer.allow_reuse_address=True
http.server.ThreadingHTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
PY

python3 "$TMP/mock.py" $mport & mpid=$!
sleep 1
NO_PROBE=1 METACODES_NO_PROBE=1 "$BIN" serve $dport --sessions 2 --api-key test --base-url "http://127.0.0.1:$mport" >"$out" 2>&1 & dpid=$!
sleep 2

grep -q "daemon.*http://127.0.0.1:$dport" "$out" || { echo "FAIL: daemon 未监听"; cat "$out"; exit 1; }
# 提取两个 session id(启动时各印一行 "session <id> ready")。bash 3.2 兼容(macOS 无 mapfile)。
sids=($(grep -oE "session [0-9a-f]{24} ready" "$out" | awk '{print $2}' | sort -u))
[ "${#sids[@]}" -eq 2 ] || { echo "FAIL: 期望 2 个 session,实得 ${#sids[@]}"; cat "$out"; exit 1; }
A="${sids[0]}"; B="${sids[1]}"
echo "session A=$A  B=$B"

# 未知 session → 404。
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$dport/s/deadbeefdeadbeefdeadbeef/events")
[ "$code" = 404 ] || { echo "FAIL: 未知 session 应 404,实得 $code"; exit 1; }

# M1:多 session GET / 返回**诚实落地页**(非死 SPA):标注多 session + API 级路由 + 列出 session id。
root=$(curl -s "http://127.0.0.1:$dport/")
echo "$root" | grep -q "multi-session" || { echo "FAIL: GET / 未返多 session 落地页(疑返死 SPA)"; echo "$root" | head -c 300; exit 1; }
echo "$root" | grep -q "$A" || { echo "FAIL: 落地页未列 session A"; exit 1; }
echo "$root" | grep -q "$B" || { echo "FAIL: 落地页未列 session B"; exit 1; }

# **只**给 A 发消息(证隔离:B 不应收到)。
ack=$(curl -s -X POST "http://127.0.0.1:$dport/s/$A/message" -H "Origin: http://127.0.0.1:$dport" -d '{"text":"hi-A"}')
echo "$ack" | grep -q '"ok":true' || { echo "FAIL: /s/$A/message 未接受: $ack"; exit 1; }

# A 的 /events 应有 DAEMON_OK + run_done end_turn。
evA=$(curl -s --max-time 3 "http://127.0.0.1:$dport/s/$A/events")
echo "$evA" | grep -q "DAEMON_OK" || { echo "FAIL: A 的 SSE 无 assistant 文本(driver 未跑?)"; echo "$evA"; exit 1; }
echo "$evA" | grep -q '"run_done".*end_turn' || { echo "FAIL: A 无 run_done end_turn"; echo "$evA"; exit 1; }

# **路由隔离铁证**:B 的 /events 绝不含 A 的生成(B 从未收到消息 → 无 run_done/DAEMON_OK)。
evB=$(curl -s --max-time 3 "http://127.0.0.1:$dport/s/$B/events")
echo "$evB" | grep -q "DAEMON_OK" && { echo "FAIL: 路由串台!A 的消息进了 B 的 journal"; echo "$evB"; exit 1; }
echo "$evB" | grep -q '"run_done"' && { echo "FAIL: 路由串台!B 出现 run_done(未发消息却跑了)"; echo "$evB"; exit 1; }

# S1:B 空闲期误打 /interrupt 应被 generating 门挡(409),**绝不吞掉随后的消息**。
# 真牙:若 SessionView 丢 generating 门(回归),此 interrupt 会 abort → 下面 B 的消息被 already-aborted
# 即刻中断 → 无 DAEMON_OK → 后续断言 FAIL。
icode=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$dport/s/$B/interrupt" -H "Origin: http://127.0.0.1:$dport")
[ "$icode" = 409 ] || { echo "FAIL: 空闲期 /interrupt 应 409(generating 门缺失=S1 回归),实得 $icode"; exit 1; }

# B 独立可用:给 B 发消息 → B 的 /events 现出 DAEMON_OK(证 B driver 真跑 + 上面误 interrupt 未吞消息)。
ackB=$(curl -s -X POST "http://127.0.0.1:$dport/s/$B/message" -H "Origin: http://127.0.0.1:$dport" -d '{"text":"hi-B"}')
echo "$ackB" | grep -q '"ok":true' || { echo "FAIL: /s/$B/message 未接受: $ackB"; exit 1; }
evB2=$(curl -s --max-time 3 "http://127.0.0.1:$dport/s/$B/events")
echo "$evB2" | grep -q "DAEMON_OK" || { echo "FAIL: B 发消息后仍无生成(B driver 死?)"; echo "$evB2"; exit 1; }

# SIGINT → 两 driver 优雅 join,退出码 0。
kill -INT $dpid
for i in $(seq 1 60); do kill -0 $dpid 2>/dev/null || break; sleep 0.1; done
if kill -0 $dpid 2>/dev/null; then echo "FAIL: SIGINT 后挂死(关停 join 未收敛)"; exit 1; fi
wait $dpid; rc=$?
[ "$rc" = 0 ] || { echo "FAIL: daemon 退出码 $rc(非 0)"; exit 1; }
grep -q "daemon closed" "$out" || { echo "FAIL: 无 'daemon closed'"; exit 1; }

echo "PASS: serve-multi e2e — 2 session 路由隔离 + 未知 404 + 双 driver 并发 + SIGINT 优雅关停"
