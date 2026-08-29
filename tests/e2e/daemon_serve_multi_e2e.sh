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
import http.server, sys, time
SSE=(b'data: {"type":"message_start","message":{"id":"m","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":0}}}\n\n'
 b'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
 b'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"DAEMON_OK"}}\n\n'
 b'data: {"type":"content_block_stop","index":0}\n\n'
 b'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}\n\n'
 b'data: {"type":"message_stop"}\n\n')
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(s):
        body = s.rfile.read(int(s.headers.get('Content-Length',0)))
        # body 含 SLOWGEN 标记 → 延 2s 再回(保持该 session generating,供 UDS interrupt 真打进来)。
        # 只对 interrupt 测试那一发生效,其余生成保持瞬时,不拖慢主体。
        if b'SLOWGEN' in body:
            time.sleep(2.0)
        s.send_response(200); s.send_header('Content-Type','text/event-stream'); s.end_headers()
        s.wfile.write(SSE); s.wfile.flush()
    def log_message(s,*a): pass
http.server.ThreadingHTTPServer.allow_reuse_address=True
http.server.ThreadingHTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
PY

usock="$TMP/daemon.sock"
python3 "$TMP/mock.py" $mport & mpid=$!
sleep 1
NO_PROBE=1 METACODES_NO_PROBE=1 "$BIN" serve $dport --sessions 2 --uds "$usock" --api-key test --base-url "http://127.0.0.1:$mport" >"$out" 2>&1 & dpid=$!
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

# ── U11:per-session rich /state + /command(此前 multi 是 "{}" + 501)+ 命令隔离 ──
stA=$(curl -s "http://127.0.0.1:$dport/s/$A/state")
echo "$stA" | grep -q "\"session_id\":\"$A\"" || { echo "FAIL: A /state 非本 session rich 快照: $stA"; exit 1; }
cackA=$(curl -s -X POST "http://127.0.0.1:$dport/s/$A/command" -H "Origin: http://127.0.0.1:$dport" -d '{"cmd":"/mode plan"}')
echo "$cackA" | grep -q '"ok":true' || { echo "FAIL: A /command 未入队: $cackA"; exit 1; }
sleep 1
curl -s "http://127.0.0.1:$dport/s/$A/state" | grep -q '"permission_mode":"plan"' || { echo "FAIL: A /state 未反映 mode plan"; exit 1; }
# 命令隔离铁证:A 的 /mode 绝不改 B。
curl -s "http://127.0.0.1:$dport/s/$B/state" | grep -q '"permission_mode":"plan"' && { echo "FAIL: 命令串台!A 的 /mode 改了 B"; exit 1; }
evA2=$(curl -s --max-time 3 "http://127.0.0.1:$dport/s/$A/events")
echo "$evA2" | grep -q 'permission mode → plan' || { echo "FAIL: A 无 command_result mode→plan"; echo "$evA2"; exit 1; }

# U10-B:UDS+NDJSON 绑定(与 web 共享 registry)。此时 A/B 均已跑完 → 空闲。
[ -S "$usock" ] || { echo "FAIL: UDS socket 未创建: $usock"; cat "$out"; exit 1; }
uds_out=$(python3 - "$usock" "$A" "$B" <<'PY'
import socket, sys, json, time
path, A, B = sys.argv[1], sys.argv[2], sys.argv[3]
def conn():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(path); return s
def req(obj):  # 一发一收(单响应 op)
    s = conn(); s.sendall((json.dumps(obj)+"\n").encode()); s.settimeout(3)
    try: data = s.recv(65536).decode()
    except socket.timeout: data = ""
    s.close(); return data
def attach_lines(sid, since, secs):  # attach 流,读 secs 秒内的所有 NDJSON 行
    s = conn(); s.sendall((json.dumps({"op":"attach","session":sid,"since":since})+"\n").encode())
    s.settimeout(secs); buf=""
    try:
        while True:
            d = s.recv(65536)
            if not d: break
            buf += d.decode()
    except socket.timeout: pass
    s.close()
    return [ln for ln in buf.split("\n") if ln]

# list：两个 session id 都在
lst = req({"op":"list"}); assert A in lst and B in lst, "list 缺 session id: "+lst
# 未知 session → 拒
unk = req({"op":"message","session":"deadbeefdeadbeefdeadbeef","text":"x"})
assert '"ok":false' in unk and "unknown session" in unk, "未知 session 未拒: "+unk

# ── M1:since / streaming / 消息投递 / 路由隔离 全部给牙 ──────────────────────────
# 基线:attach A since=0 数出当前 journal 行数 n0。
base = attach_lines(A, 0, 2); n0 = len(base)
assert n0 > 0, "A 基线 journal 为空"
# UDS 发一条**唯一标记**消息到 A(标记不会来自早先 web 流量 → 无 vacuous)。
MARK = "uds-mark-A-7f3c9"
m = req({"op":"message","session":A,"text":MARK}); assert '"ok":true' in m, "UDS message 未接受: "+m
# 投递+streaming+since:attach A since=n0 只收 n0 之后的新行,必须含 MARK 的 echo。
newl = attach_lines(A, n0, 3); joined = "\n".join(newl)
assert MARK in joined, "since=n0 未流式收到 UDS 新消息 echo(投递/streaming/since 失效): "+joined[:300]
# since 真被尊重:attach A since=n0+1000(远超) → MARK 不该出现(否则 since 被忽略当 0 回放)。
far = attach_lines(A, n0+1000, 2)
assert MARK not in "\n".join(far), "since 被忽略:远期 since 仍回放了旧标记"
# 路由隔离(UDS 侧):A 的标记消息绝不进 B 的 journal。
bl = attach_lines(B, 0, 2)
assert MARK not in "\n".join(bl), "UDS 路由串台:A 的消息出现在 B 的 journal"

# ── M2:interrupt 成功分支(真打到 generating 的 session,非仅门挡)─────────────────
# 空闲期 interrupt B → generating 门挡(not generating,409 语义)。
it = req({"op":"interrupt","session":B})
assert '"ok":false' in it and "not generating" in it, "空闲 interrupt 门(S1)失效: "+it
# 发 SLOWGEN 消息到 B → driver POST 到 mock,mock 延 2s → B 进入 generating。
sg = req({"op":"message","session":B,"text":"SLOWGEN interrupt-me"}); assert '"ok":true' in sg
time.sleep(0.7)  # 等 driver 起 POST、mock 开始 sleep(B generating=true)
# 此刻 interrupt B → 命中成功分支(generating→abort→ok:true),非 409。
it2 = req({"op":"interrupt","session":B})
assert '"ok":true' in it2, "generating 期 interrupt 未走成功分支(仍被门挡?): "+it2

# ── U10-E:mid-run interrupt **真中断**(不止返 ok,run 要真以 aborted 收尾)────────────
# mock 延 2s 后送数据,client 在 SSE 事件检查点见 abort → run 以 aborted 结束(agent_loop 751)。
import time as _t
deadline = _t.time() + 6; aborted_done = False
while _t.time() < deadline:
    if any('"run_done"' in l and '"aborted"' in l for l in attach_lines(B, 0, 1)):
        aborted_done = True; break
    _t.sleep(0.3)
assert aborted_done, "SLOWGEN interrupt 未使 B 的 run 真以 aborted 收尾(仅返 ok 不够)"

# ── U10-E:多消息连续对话(daemon driver 多轮)──────────────────────────────────
rd_before = sum(1 for l in attach_lines(A, 0, 1) if '"run_done"' in l)
assert '"ok":true' in req({"op":"message","session":A,"text":"multi-one-abc"})
_t.sleep(0.5)
assert '"ok":true' in req({"op":"message","session":A,"text":"multi-two-def"})
_t.sleep(1.0)
allA = attach_lines(A, 0, 2); joinedA = "\n".join(allA)
rd_after = sum(1 for l in allA if '"run_done"' in l)
assert rd_after >= rd_before + 2, "多消息未各产 run_done: %d→%d" % (rd_before, rd_after)
assert "multi-one-abc" in joinedA and "multi-two-def" in joinedA, "多消息 echo 缺失"

print("UDS_OK")
PY
) || { echo "FAIL: UDS 检查异常"; echo "$uds_out"; exit 1; }
echo "$uds_out" | grep -q "UDS_OK" || { echo "FAIL: UDS+NDJSON 检查未过: $uds_out"; exit 1; }

# SIGINT → 两 driver 优雅 join,退出码 0。
kill -INT $dpid
for i in $(seq 1 60); do kill -0 $dpid 2>/dev/null || break; sleep 0.1; done
if kill -0 $dpid 2>/dev/null; then echo "FAIL: SIGINT 后挂死(关停 join 未收敛)"; exit 1; fi
wait $dpid; rc=$?
[ "$rc" = 0 ] || { echo "FAIL: daemon 退出码 $rc(非 0)"; exit 1; }
grep -q "daemon closed" "$out" || { echo "FAIL: 无 'daemon closed'"; exit 1; }

echo "PASS: serve-multi e2e — 路由隔离 + UDS(list/message/attach/interrupt) + U10-E(真中断/多消息连续) + U11(/state·/command 按 session 隔离) + SIGINT 优雅关停"
