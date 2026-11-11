#!/usr/bin/env bash
# serve-multi e2e: the real `metacodes serve --sessions 2 --uds <path>` against a
# loopback mock provider (tests/e2e/daemon_mock_provider.py; no network, no
# paid call), with bearer-token auth from METACODES_WEB_TOKEN (#252).
#
#   - GET /health (#251): open, version as `--version` prints it, sessions 2.
#   - The HTTP surface needs the token on every other route (the landing page
#     and session routes included); the UDS transport does not: its access
#     control stays the socket file's 0600 mode.
#   - The resolver routes /s/<id>/* to its own session: message isolation,
#     unknown session → 404, the idle /interrupt gate (409), per-session rich
#     /state and /command (/mode dont-ask) isolation.
#   - UDS + NDJSON: list / message / attach (since, streaming) / interrupt,
#     mid-run interrupt ends the run as aborted, consecutive messages;
#     respond answers the pending ui_request on the socket (stale id refused)
#     and capabilities installs a declaration (empty one routes the next ask
#     unavailable), so a UDS-only frontend needs no HTTP side channel.
#   - #254 dynamic lifecycle: GET /sessions, POST /sessions/create (201, 409
#     live duplicate, 400 malformed id), /sessions/<id>/resume (200 live, 404
#     not), /sessions/<id>/destroy (200, then 404 everywhere, /health drops,
#     the main loop reaps it), create {"resume":true} restores the transcript;
#     a second daemon with --sessions 0 starts empty and answers 429 at
#     --max-sessions.
#   - SIGINT shuts every driver down cleanly.
#
# Run by `zig build test` on POSIX hosts (build.zig sets
# METACODES_DAEMON_E2E_BIN); by hand: `zig build && bash tests/e2e/daemon_serve_multi_e2e.sh`.
set -euo pipefail
# Responses are read whole before grep: under pipefail, `curl | grep -q` fails
# a matching check whenever grep exits before curl has written everything.
# shellcheck source=tests/e2e/daemon_e2e_lib.sh
source "$(dirname "$0")/daemon_e2e_lib.sh"

start_mock
version="$(binary_version)"
[[ -n "$version" ]] || fail "metacodes --version printed no version"
token="e2e-$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
auth=(-H "Authorization: Bearer $token")
usock="$TMP/daemon.sock"

# daemon:info puts "session <id> reaped" in the log: the main loop's reaper at work.
start_daemon "$TMP/multi.out" METACODES_WEB_TOKEN="$token" METACODES_LOG=daemon:info \
  "$BIN" serve 0 --sessions 2 --uds "$usock" --api-key test --base-url "$BASE_URL"
wait_listening "$TMP/multi.out"
url="$DAEMON_URL"
[[ "$url" == http://127.0.0.1:* ]] || fail "default bind is not 127.0.0.1: $url"
grep -q "daemon (2 sessions): $url" "$TMP/multi.out" || fail "unexpected startup line"
if grep -qF "$token" "$TMP/multi.out"; then fail "the token was printed"; fi
# Both session ids (each printed as "session <id> ready"). bash 3.2 compatible.
sids=($(grep -oE "session [0-9a-f]{24} ready" "$TMP/multi.out" | awk '{print $2}' | sort -u))
[[ "${#sids[@]}" -eq 2 ]] || fail "expected 2 sessions, got ${#sids[@]}"
A="${sids[0]}"
B="${sids[1]}"
echo "session A=$A  B=$B"

# ── #251/#252: /health is open, everything else needs the token ─────────────
check_health "$url" "$version" 2
[[ "$(http_code "$url/")" == 401 ]] || fail "landing page served without the token"
[[ "$(http_code "$url/s/$A/state")" == 401 ]] || fail "/s/<id>/state served without the token"
[[ "$(http_code --max-time 2 "$url/s/$A/events")" == 401 ]] || fail "/s/<id>/events served without the token"
[[ "$(http_code -X POST "$url/s/$A/message?token=$token" -H "Origin: $url" -d '{"text":"query"}')" == 401 ]] ||
  fail "a POST authenticated by query"

# Unknown session → 404 (authenticated).
[[ "$(http_code "${auth[@]}" "$url/s/deadbeefdeadbeefdeadbeef/events")" == 404 ]] || fail "unknown session is not 404"

# The landing page: an honest multi-session page, not the single-session SPA.
root="$("${CURL[@]}" "${auth[@]}" "$url/")"
grep -q "multi-session" <<<"$root" || fail "GET / is not the multi-session landing page"
grep -q "$A" <<<"$root" || fail "landing page does not list session A"
grep -q "$B" <<<"$root" || fail "landing page does not list session B"
grep -q "/health" <<<"$root" || fail "landing page does not list /health"

# ── routing isolation ────────────────────────────────────────────────────────
ack="$("${CURL[@]}" "${auth[@]}" -X POST "$url/s/$A/message" -H "Origin: $url" -d '{"text":"hi-A"}')"
grep -q '"ok":true' <<<"$ack" || fail "/s/A/message not accepted: $ack"
evA="$(events_until '"run_done".*end_turn' "${auth[@]}" "$url/s/$A/events")" || fail "A has no run_done end_turn: $evA"
grep -q "DAEMON_OK" <<<"$evA" || fail "A's stream has no assistant text"
evB="$("${CURL[@]}" --max-time 1 "${auth[@]}" "$url/s/$B/events" 2>/dev/null || true)"
if grep -q "DAEMON_OK" <<<"$evB"; then fail "A's message reached B's journal"; fi
if grep -q '"run_done"' <<<"$evB"; then fail "B ran without a message"; fi

# S1: an idle /interrupt is refused by the generating gate and must not
# swallow the next message.
[[ "$(http_code "${auth[@]}" -X POST "$url/s/$B/interrupt" -H "Origin: $url")" == 409 ]] ||
  fail "idle /interrupt is not 409 (generating gate missing)"
ackB="$("${CURL[@]}" "${auth[@]}" -X POST "$url/s/$B/message" -H "Origin: $url" -d '{"text":"hi-B"}')"
grep -q '"ok":true' <<<"$ackB" || fail "/s/B/message not accepted: $ackB"
events_until "DAEMON_OK" "${auth[@]}" "$url/s/$B/events" >/dev/null || fail "B produced nothing after its message"

# ── per-session /state and /command ──────────────────────────────────────────
stateA="$("${CURL[@]}" "${auth[@]}" "$url/s/$A/state")" || fail "GET A's /state failed"
grep -q "\"session_id\":\"$A\"" <<<"$stateA" || fail "A's /state is not its own snapshot"
cackA="$("${CURL[@]}" "${auth[@]}" -X POST "$url/s/$A/command" -H "Origin: $url" -d '{"cmd":"/mode dont-ask"}')"
grep -q '"ok":true' <<<"$cackA" || fail "A's /command not queued: $cackA"
events_until 'permission mode → dont_ask' "${auth[@]}" "$url/s/$A/events" >/dev/null || fail "A has no command_result mode → dont_ask"
stateA="$("${CURL[@]}" "${auth[@]}" "$url/s/$A/state")" || fail "GET A's /state failed"
grep -q '"permission_mode":"dont_ask"' <<<"$stateA" || fail "A's /state does not show dont_ask"
stateB="$("${CURL[@]}" "${auth[@]}" "$url/s/$B/state")" || fail "GET B's /state failed"
if grep -q '"permission_mode":"dont_ask"' <<<"$stateB"; then
  fail "A's /mode changed B"
fi
# A capability frame (doc/WIRE_PROTOCOL.md §2) belongs to its session alone.
capsA="$("${CURL[@]}" "${auth[@]}" -X POST "$url/s/$A/capabilities" -H "Origin: $url" \
  -d '{"v":1,"type":"capabilities","ui_requests":["permission"]}')" || fail "POST A's /capabilities failed"
grep -q '"type":"capabilities_accepted","ui_requests":\["permission"\]' <<<"$capsA" || fail "A's frame not accepted: $capsA"
stateA="$("${CURL[@]}" "${auth[@]}" "$url/s/$A/state")" || fail "GET A's /state failed"
grep -q '"frontend_capabilities":{"v":1,"type":"capabilities_accepted"' <<<"$stateA" || fail "A's /state lacks its declaration"
stateB="$("${CURL[@]}" "${auth[@]}" "$url/s/$B/state")" || fail "GET B's /state failed"
grep -q '"frontend_capabilities":null' <<<"$stateB" || fail "A's declaration reached B: $stateB"

# Put A's permission mode back: in dont-ask the permission chain denies an
# AskUserQuestion outright (never asks), which would starve the UDS respond
# journey below of its pending request.
cackA="$("${CURL[@]}" "${auth[@]}" -X POST "$url/s/$A/command" -H "Origin: $url" -d '{"cmd":"/mode default"}')"
grep -q '"ok":true' <<<"$cackA" || fail "A's mode reset not queued: $cackA"
events_until 'permission mode → default' "${auth[@]}" "$url/s/$A/events" >/dev/null || fail "A has no command_result mode → default"

# ── UDS + NDJSON: no token; the socket file's 0600 mode is the access control ─
[[ -S "$usock" ]] || fail "UDS socket not created: $usock"
mode="$(python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$usock")"
[[ "$mode" == 0o600 ]] || fail "UDS socket mode is $mode, not 0600"
# Written out first: bash 3.2 mis-parses a heredoc inside $(...) that has an apostrophe.
cat >"$TMP/uds_check.py" <<'PY'
import socket, sys, json, time
path, A, B = sys.argv[1], sys.argv[2], sys.argv[3]
def conn():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(path); return s
def req(obj):  # one request, one response line
    s = conn(); s.sendall((json.dumps(obj)+"\n").encode()); s.settimeout(3)
    try: data = s.recv(65536).decode()
    except socket.timeout: data = ""
    s.close(); return data
def attach_lines(sid, since, secs):  # the attach stream's NDJSON lines within secs seconds
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

lst = req({"op":"list"}); assert A in lst and B in lst, "list lacks a session id: "+lst
unk = req({"op":"message","session":"deadbeefdeadbeefdeadbeef","text":"x"})
assert '"ok":false' in unk and "unknown session" in unk, "unknown session not refused: "+unk

# since / streaming / delivery / isolation.
base = attach_lines(A, 0, 2); n0 = len(base)
assert n0 > 0, "A's baseline journal is empty"
MARK = "uds-mark-A-7f3c9"
m = req({"op":"message","session":A,"text":MARK}); assert '"ok":true' in m, "UDS message not accepted: "+m
newl = attach_lines(A, n0, 3); joined = "\n".join(newl)
assert MARK in joined, "since=n0 did not stream the new UDS message echo: "+joined[:300]
far = attach_lines(A, n0+1000, 2)
assert MARK not in "\n".join(far), "since ignored: a far cursor replayed the old mark"
bl = attach_lines(B, 0, 2)
assert MARK not in "\n".join(bl), "UDS routing leak: A's message is in B's journal"

# interrupt: refused while idle, accepted while generating.
it = req({"op":"interrupt","session":B})
assert '"ok":false' in it and "not generating" in it, "idle interrupt gate (S1) broken: "+it
sg = req({"op":"message","session":B,"text":"SLOWGEN interrupt-me"}); assert '"ok":true' in sg
# Retried until the driver is inside the mock's 2 s hold: a loaded runner may
# start the run later than any fixed sleep allows, and the gate refuses an
# interrupt until B is generating.
deadline = time.time() + 15
while True:
    it2 = req({"op":"interrupt","session":B})
    if '"ok":true' in it2 or "not generating" not in it2 or time.time() >= deadline: break
    time.sleep(0.2)
assert '"ok":true' in it2, "interrupt while generating was refused: "+it2

# The interrupt really ends the run as aborted.
deadline = time.time() + 6; aborted_done = False
while time.time() < deadline:
    if any('"run_done"' in l and '"aborted"' in l for l in attach_lines(B, 0, 1)):
        aborted_done = True; break
    time.sleep(0.3)
assert aborted_done, "the SLOWGEN interrupt did not end B's run as aborted"

# Consecutive messages each run.
rd_before = sum(1 for l in attach_lines(A, 0, 1) if '"run_done"' in l)
assert '"ok":true' in req({"op":"message","session":A,"text":"multi-one-abc"})
time.sleep(0.5)
assert '"ok":true' in req({"op":"message","session":A,"text":"multi-two-def"})
# Polled to a deadline rather than read after a fixed sleep: two runs back to
# back can take longer than a second on a loaded runner (#372's CI saw 2→2).
deadline = time.time() + 20
while True:
    allA = attach_lines(A, 0, 1)
    rd_after = sum(1 for l in allA if '"run_done"' in l)
    if rd_after >= rd_before + 2 or time.time() >= deadline: break
    time.sleep(0.3)
joinedA = "\n".join(allA)
assert rd_after >= rd_before + 2, "consecutive messages did not each run: %d→%d" % (rd_before, rd_after)
assert "multi-one-abc" in joinedA and "multi-two-def" in joinedA, "a consecutive message echo is missing"

# respond: the whole UI-request journey stays on the socket. The HTTP section
# above declared A as permission-only, so first re-declare over the socket
# (one declaration per Session, replaced by the next accepted frame), then
# CAPS_ASK makes the mock call AskUserQuestion and the pending request is
# answered with a UDS line.
recap = req({"op":"capabilities","session":A,"v":1,"type":"capabilities","ui_requests":["permission","ask_question"]})
assert '"type":"capabilities_accepted"' in recap and '"ask_question"' in recap, \
    "UDS re-declaration not accepted: "+recap
assert '"ok":true' in req({"op":"message","session":A,"text":"CAPS_ASK over uds"})
rid = None
deadline = time.time() + 15
while time.time() < deadline and rid is None:
    for ln in attach_lines(A, 0, 1):
        if '"type":"ui_request","id":' in ln:
            rid = int(ln.split('"type":"ui_request","id":')[1].split(",")[0]); break
    if rid is None: time.sleep(0.3)
if rid is None:
    _dbg = [l[:300] for l in attach_lines(A, 0, 2)
            if any(k in l for k in ('ui_request', 'capabilities', 'tool_result', 'policy_decision', 'tool_start'))]
    assert False, "CAPS_ASK announced no ui_request in A's journal; evidence:\n" + "\n".join(_dbg)
stale = req({"op":"respond","session":A,"id":rid+7,"answers":["Red"]})
assert '"ok":false' in stale and "no pending request" in stale, "stale respond not refused: "+stale
noid = req({"op":"respond","session":A,"answers":["Red"]})
assert "missing id" in noid, "respond without id not refused: "+noid
ans = req({"op":"respond","session":A,"id":rid,"answers":["Red"]})
assert '"ok":true' in ans, "UDS respond refused: "+ans
closed_needle = '"type":"ui_request_closed","id":%d,"outcome":"answered"' % rid
deadline = time.time() + 15; answered = False
while time.time() < deadline:
    allA = "\n".join(attach_lines(A, 0, 1))
    if closed_needle in allA and allA.count('"run_done"') >= rd_after + 1:
        answered = True; break
    time.sleep(0.3)
assert answered, "UDS respond did not close the request as answered"

# capabilities: declared empty over the socket, the next ask is never announced,
# it is journaled unavailable, and the run falls back and still finishes.
cap = req({"op":"capabilities","session":B,"v":1,"type":"capabilities","ui_requests":[]})
assert '"type":"capabilities_accepted"' in cap, "UDS capabilities not acknowledged: "+cap
bad = req({"op":"capabilities","session":B,"v":1,"type":"capabilities","ui_requests":["custom"]})
assert '"type":"capabilities_refused"' in bad, "a malformed frame was not refused: "+bad
rdB = sum(1 for l in attach_lines(B, 0, 1) if '"run_done"' in l)
assert '"ok":true' in req({"op":"message","session":B,"text":"CAPS_ASK on b"})
deadline = time.time() + 15; unavailable = False
while time.time() < deadline:
    allB = "\n".join(attach_lines(B, 0, 1))
    if '"type":"ui_request_unavailable"' in allB and allB.count('"run_done"') >= rdB + 1:
        unavailable = True; break
    time.sleep(0.3)
assert unavailable, "the declared-empty frontend did not journal the ask unavailable"
assert '"type":"ui_request","id":' not in allB, "an announce leaked past the empty declaration"

print("UDS_OK")
PY
uds_out="$(python3 "$TMP/uds_check.py" "$usock" "$A" "$B" 2>&1)" || fail "UDS checks failed: $uds_out"
grep -q "UDS_OK" <<<"$uds_out" || fail "UDS checks did not finish: $uds_out"

# ── #254: dynamic session lifecycle over HTTP ───────────────────────────────
# lifecycle <method> <path> [body]: prints "<status> <body>" (authenticated).
lifecycle() {
  local method="$1" path="$2" body="${3:-}"
  "${CURL[@]}" --max-time 30 "${auth[@]}" -X "$method" "$url$path" -H "Origin: $url" \
    ${body:+-d "$body"} -w ' %{http_code}' || true
}
# The token guards the lifecycle routes like every other.
[[ "$(http_code "$url/sessions")" == 401 ]] || fail "GET /sessions served without the token"
[[ "$(http_code -X POST "$url/sessions/create" -H "Origin: $url" -d '{}')" == 401 ]] || fail "create without the token"
[[ "$(http_code -X POST "$url/sessions/$A/destroy" -H "Origin: $url")" == 401 ]] || fail "destroy without the token"
check_health "$url" "$version" 2

# GET /sessions lists the two startup sessions with their state.
listed="$("${CURL[@]}" "${auth[@]}" "$url/sessions")"
python3 - "$listed" "$A" "$B" <<'PY' || fail "unexpected GET /sessions: $listed"
import json, sys
doc = json.loads(sys.argv[1])
ids = [s["session_id"] for s in doc["sessions"]]
assert sorted(ids) == sorted(sys.argv[2:4]), ids
for s in doc["sessions"]:
    assert set(s) == {"session_id", "generating", "model", "permission_mode", "pending_request_id"}, s
    assert isinstance(s["generating"], bool) and s["pending_request_id"] == 0, s
PY

# create → 201; it is an ordinary session: /s/<id>/*, its own driver.
created="$(lifecycle POST /sessions/create '{}')"
[[ "$created" == *" 201" ]] || fail "create did not answer 201: $created"
C="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1].rsplit(" ", 1)[0])["session_id"])' "$created")"
echo "session C=$C (created over HTTP)"
check_health "$url" "$version" 3
[[ "$(lifecycle POST "/sessions/$C/resume")" == *'"live":true}'*" 200" ]] || fail "resume of a live session is not 200"
grep -q '"ok":true' <<<"$("${CURL[@]}" "${auth[@]}" -X POST "$url/s/$C/message" -H "Origin: $url" -d '{"text":"hi-C"}')" ||
  fail "/s/C/message not accepted"
events_until '"run_done".*end_turn' "${auth[@]}" "$url/s/$C/events" >/dev/null || fail "C produced no run"
[[ "$(lifecycle POST /sessions/create "{\"session_id\":\"$C\"}")" == *" 409" ]] || fail "a live duplicate is not 409"
[[ "$(lifecycle POST /sessions/create '{"session_id":"NOT-AN-ID"}')" == *" 400" ]] || fail "a malformed id is not 400"

# destroy → 200 once the driver is joined; the session is gone, the reaper frees it.
[[ "$(lifecycle POST "/sessions/$C/destroy")" == *'"ok":true'*" 200" ]] || fail "destroy did not answer 200"
[[ "$(http_code "${auth[@]}" "$url/s/$C/state")" == 404 ]] || fail "/s/C/state after destroy is not 404"
[[ "$(lifecycle POST "/sessions/$C/resume")" == *" 404" ]] || fail "resume of a destroyed session is not 404"
[[ "$(lifecycle POST "/sessions/$C/destroy")" == *" 404" ]] || fail "a second destroy is not 404"
check_health "$url" "$version" 2
after_destroy="$("${CURL[@]}" "${auth[@]}" "$url/sessions")" || fail "GET /sessions after destroy failed"
if grep -q "$C" <<<"$after_destroy"; then fail "GET /sessions still lists C"; fi
wait_for_line "$TMP/multi.out" "$DAEMON_PID" "session $C reaped" || fail "the main loop never reaped C"

# The conversation survives the destroy: restore it from the transcript.
restored="$(lifecycle POST /sessions/create "{\"session_id\":\"$C\",\"resume\":true}")"
[[ "$restored" == "{\"session_id\":\"$C\",\"messages\":2} 201" ]] || fail "restore did not bring back 2 messages: $restored"
check_health "$url" "$version" 3
[[ "$(lifecycle POST "/sessions/$C/destroy")" == *" 200" ]] || fail "destroy of the restored session"

stop_daemon "$TMP/multi.out"

# ── #254: --sessions 0 starts empty; the cap answers 429 ────────────────────
start_daemon "$TMP/zero.out" METACODES_WEB_TOKEN="$token" \
  "$BIN" serve 0 --sessions 0 --max-sessions 1 --api-key test --base-url "$BASE_URL"
wait_listening "$TMP/zero.out"
url="$DAEMON_URL"
check_health "$url" "$version" 0
[[ "$("${CURL[@]}" "${auth[@]}" "$url/sessions")" == '{"sessions":[]}' ]] || fail "--sessions 0 did not start empty"
first="$(lifecycle POST /sessions/create)"
[[ "$first" == *" 201" ]] || fail "create on an empty daemon: $first"
D="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1].rsplit(" ", 1)[0])["session_id"])' "$first")"
[[ "$(lifecycle POST /sessions/create)" == '{"error":"session limit reached","max_sessions":1} 429' ]] || fail "the cap did not answer 429"
grep -q '"ok":true' <<<"$("${CURL[@]}" "${auth[@]}" -X POST "$url/s/$D/message" -H "Origin: $url" -d '{"text":"hi-D"}')" ||
  fail "/s/D/message not accepted"
events_until '"run_done".*end_turn' "${auth[@]}" "$url/s/$D/events" >/dev/null || fail "D produced no run"
stop_daemon "$TMP/zero.out"

echo "PASS: serve-multi e2e — /health, bearer token (HTTP) vs 0600 UDS, routing isolation, UDS list/message/attach/interrupt/respond/capabilities, per-session /state·/command, dynamic create/list/resume/destroy/restore (#254), --sessions 0 and the 429 cap, SIGINT shutdown"
