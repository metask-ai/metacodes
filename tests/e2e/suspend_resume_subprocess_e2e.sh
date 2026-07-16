#!/usr/bin/env bash
# task#20:suspend/resume **跨真 subprocess** e2e。证明完整闭环:
#   进程 A(headless)跑 → 模型调 AskUserQuestion(非 tty)→ 挂起 + 写 suspend.json + 打印 session dir。
#   进程 B(--session <A的id> --resume-response <答案>)→ 读 suspend.json + loadTranscript + resumeRun 续跑 → 完成。
# Python mock 按请求体分流:无 tool_result(A)→ 回 AskUserQuestion tool_use;有 tool_result(B resume)→ 回 end_turn "RESUMED_OK"。
# 需 python3 + 已 zig build。断言失败 → exit 1。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/zig-out/bin/metacodes"
[ -x "$BIN" ] || { echo "FAIL: $BIN 不存在(先 zig build)"; exit 1; }
command -v python3 >/dev/null || { echo "SKIP: 无 python3"; exit 0; }

TMP="$(mktemp -d)"; export HOME="$TMP/home"; mkdir -p "$HOME"
mport=18099
cleanup(){ kill -9 "${mpid:-0}" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

cat > "$TMP/mock.py" <<'PY'
import http.server, sys
ASK=(b'data: {"type":"message_start","message":{"id":"m","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":0}}}\n\n'
 b'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tuask1","name":"AskUserQuestion","input":{}}}\n\n'
 b'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"questions\\":[{\\"question\\":\\"Pick?\\",\\"header\\":\\"H\\",\\"options\\":[{\\"label\\":\\"Aaa\\",\\"description\\":\\"a\\"},{\\"label\\":\\"Bbb\\",\\"description\\":\\"b\\"}]}]}"}}\n\n'
 b'data: {"type":"content_block_stop","index":0}\n\n'
 b'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}\n\n'
 b'data: {"type":"message_stop"}\n\n')
DONE=(b'data: {"type":"message_start","message":{"id":"m2","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":0}}}\n\n'
 b'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
 b'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"RESUMED_OK"}}\n\n'
 b'data: {"type":"content_block_stop","index":0}\n\n'
 b'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}\n\n'
 b'data: {"type":"message_stop"}\n\n')
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(s):
        body = s.rfile.read(int(s.headers.get('Content-Length',0)))
        # 用唯一 marker 分流:B 的 resume-response 含 RESUMEMARKER42(注入的迟来答案),A 首轮不含。
        # (勿用 'tool_result':工具 schema/描述里就有该子串,A 首轮会误命中。)
        out = DONE if b'RESUMEMARKER42' in body else ASK
        s.send_response(200); s.send_header('Content-Type','text/event-stream'); s.end_headers()
        s.wfile.write(out); s.wfile.flush()
    def log_message(s,*a): pass
http.server.ThreadingHTTPServer.allow_reuse_address=True
http.server.ThreadingHTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
PY

python3 "$TMP/mock.py" $mport & mpid=$!
sleep 1
COMMON="--api-key test --base-url http://127.0.0.1:$mport"

# ── 进程 A:headless 跑 → 模型调 AskUserQuestion(非 tty)→ 挂起 + 写 suspend.json ──────────
outA="$($BIN --suspendable -p "please ask me a question" $COMMON 2>&1)"
echo "$outA" | grep -q "Suspended" || { echo "FAIL: A 未挂起(AskUserQuestion 非 tty 应挂起)"; echo "$outA"; exit 1; }
# 提取 session dir → basename = 24-char session id。
sdir="$(echo "$outA" | grep -oE "session dir: .*" | sed 's/session dir: //' | tr -d '[:space:]')"
[ -n "$sdir" ] || { echo "FAIL: 未从 A 输出提取到 session dir"; echo "$outA"; exit 1; }
[ -f "$sdir/suspend.json" ] || { echo "FAIL: suspend.json 未写到 $sdir"; ls -la "$sdir" 2>&1; exit 1; }
sid="$(basename "$sdir")"
echo "session A id=$sid  dir=$sdir"

# ── 进程 B:--session <sid> --resume-response <答案> → 读 suspend.json + resumeRun 续跑 ──────
outB="$($BIN --session "$sid" --resume-response '{"choice":"RESUMEMARKER42"}' $COMMON 2>&1)"
echo "$outB" | grep -q "RESUMED_OK" || { echo "FAIL: B resume 未续跑出 RESUMED_OK(subprocess 恢复断链)"; echo "$outB"; exit 1; }
# resume 完成 → suspend.json 应被清(避免重复恢复)。
[ ! -f "$sdir/suspend.json" ] || { echo "FAIL: resume 完成后 suspend.json 未清"; exit 1; }

echo "PASS: suspend/resume subprocess e2e — A 挂起写 suspend.json → B(--session)resumeRun 续跑 RESUMED_OK + 清挂起"
