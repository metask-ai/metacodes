#!/usr/bin/env bash
# daemon serve e2e: the real `metacodes serve` (one session) against a loopback
# mock provider (tests/e2e/daemon_mock_provider.py; no network, no paid call).
#
#   1. Default surface (127.0.0.1, no token): GET /health (#251), message →
#      agent_loop → journal → SSE, rich /state, /command (/mode dont-ask and the
#      `!cmd` shell lane), SIGINT shutdown.
#   2. Bearer token from METACODES_WEB_TOKEN (#252) on --web-bind ::1 (#253;
#      127.0.0.1 on an IPv4-only host): /health stays open, everything else
#      needs the token (header, or ?token= on GET), a POST never takes it from
#      the query, the token is never printed.
#   3. A non-loopback bind without a token is refused (exit 2) before anything
#      starts, from the flag and from METACODES_WEB_BIND.
#   4. Tracing: every run is recorded as an OpenTelemetry span tree. GET /spans
#      serves the session's spans as OTLP/JSON, GET /trace the viewer, and the
#      standard OTEL_* variables export the same spans to an OTLP/HTTP
#      collector (tests/e2e/otlp_mock_collector.py), flushed at shutdown.
#
# Run by `zig build test` on POSIX hosts (build.zig sets
# METACODES_DAEMON_E2E_BIN); by hand: `zig build && bash tests/e2e/daemon_serve_e2e.sh`.
set -euo pipefail
# Responses are read whole before grep: under pipefail, `curl | grep -q` fails
# a matching check whenever grep exits before curl has written everything.
# shellcheck source=tests/e2e/daemon_e2e_lib.sh
source "$(dirname "$0")/daemon_e2e_lib.sh"

start_mock
version="$(binary_version)"
[[ -n "$version" ]] || fail "metacodes --version printed no version"

# ── 1. default surface ──────────────────────────────────────────────────────
start_daemon "$TMP/plain.out" "$BIN" serve 0 --api-key test --base-url "$BASE_URL"
wait_listening "$TMP/plain.out"
url="$DAEMON_URL"
[[ "$url" == http://127.0.0.1:* ]] || fail "default bind is not 127.0.0.1: $url"
grep -q "daemon (1 session): $url" "$TMP/plain.out" || fail "unexpected startup line"
if grep -q "bearer-token auth is on" "$TMP/plain.out"; then fail "auth note without a token"; fi
check_health "$url" "$version" 1

ack="$("${CURL[@]}" -X POST "$url/message" -H "Origin: $url" -d '{"text":"hi"}')"
grep -q '"ok":true' <<<"$ack" || fail "/message not accepted: $ack"
events="$(events_until '"run_done".*end_turn' "$url/events")" || fail "no run_done end_turn: $events"
grep -q "DAEMON_OK" <<<"$events" || fail "SSE has no assistant text (driver did not run agent_loop?)"

# Rich /state and the canonical command surface (U11).
state="$("${CURL[@]}" "$url/state")"
grep -q '"session_id"' <<<"$state" || fail "/state is not the rich snapshot: $state"
grep -q '"permission_mode"' <<<"$state" || fail "/state lacks permission_mode: $state"
cack="$("${CURL[@]}" -X POST "$url/command" -H "Origin: $url" -d '{"cmd":"/mode dont-ask"}')"
grep -q '"ok":true' <<<"$cack" || fail "/command not queued: $cack"
events="$(events_until 'permission mode → dont_ask' "$url/events")" || fail "no command_result mode → dont_ask: $events"
state="$("${CURL[@]}" "$url/state")" || fail "GET /state failed"
grep -q '"permission_mode":"dont_ask"' <<<"$state" || fail "/state does not show dont_ask"
# The `!cmd` shell lane: runs, and its stdout comes back in command_result.
sack="$("${CURL[@]}" -X POST "$url/command" -H "Origin: $url" -d '{"cmd":"!echo WIRE_SHELL_OK"}')"
grep -q '"ok":true' <<<"$sack" || fail "shell /command not queued: $sack"
events_until 'WIRE_SHELL_OK' "$url/events" >/dev/null || fail "shell output not echoed into command_result"
# Cross-origin POST stays refused.
[[ "$(http_code -X POST "$url/message" -H "Origin: http://evil.example" -d '{"text":"x"}')" == 403 ]] ||
  fail "cross-origin POST not refused"
# DNS rebinding: a foreign Host name is refused without a token.
[[ "$(http_code -H "Host: rebound.example:${url##*:}" "$url/state")" == 403 ]] || fail "rebound Host not refused"

# The run above is in the session's span store (OTLP/JSON), and the viewer is served.
spans="$("${CURL[@]}" -f "$url/spans")" || fail "GET /spans failed"
python3 - "$spans" "$state" <<'PY' || fail "unexpected /spans body: $spans"
import json, sys
doc = json.loads(sys.argv[1])
session = json.loads(sys.argv[2])["session_id"]
spans = doc["resourceSpans"][0]["scopeSpans"][0]["spans"]
names = [s["name"] for s in spans]
roots = [s for s in spans if s["name"] == "invoke_agent metacodes"]
assert roots, names
root = roots[0]
attrs = {a["key"]: a["value"] for a in root["attributes"]}
assert attrs["gen_ai.conversation.id"]["stringValue"] == session, attrs
assert attrs["metacodes.run.stop_reason"]["stringValue"] == "end_turn", attrs
chats = [s for s in spans if s["name"].startswith("chat ") and s["traceId"] == root["traceId"]]
assert chats and all(s.get("parentSpanId") for s in chats), names
PY
page="$("${CURL[@]}" -f "$url/trace")" || fail "GET /trace failed"
grep -q "metacodes · trace" <<<"$page" || fail "/trace is not the trace viewer"

stop_daemon "$TMP/plain.out"

# ── 2. bearer token (environment) on an IPv6 loopback bind ──────────────────
token="e2e-$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
bind="::1"
# A v4-only host (many containers) has no ::1: skip only the IPv6 part.
if ! python3 -c 'import socket; s = socket.socket(socket.AF_INET6); s.bind(("::1", 0))' 2>/dev/null; then
  echo "SKIP: IPv6 bind (no ::1 on this host); the token checks run on 127.0.0.1"
  bind="127.0.0.1"
fi
start_daemon "$TMP/token.out" METACODES_WEB_TOKEN="$token" "$BIN" serve 0 --web-bind "$bind" --api-key test --base-url "$BASE_URL"
wait_listening "$TMP/token.out"
url="$DAEMON_URL"
if [[ "$bind" == "::1" ]]; then
  [[ "$url" == "http://[::1]:"* ]] || fail "startup line does not show the IPv6 bind: $url"
else
  [[ "$url" == http://127.0.0.1:* ]] || fail "startup line does not show the bind: $url"
fi
grep -q "bearer-token auth is on (token not shown)" "$TMP/token.out" || fail "no auth note"
if grep -qF "$token" "$TMP/token.out"; then fail "the token was printed"; fi
auth=(-H "Authorization: Bearer $token")

check_health "$url" "$version" 1 # no token needed
[[ "$(http_code "$url/state")" == 401 ]] || fail "/state without a token is not 401"
[[ "$(http_code -H "Authorization: Bearer wrong-$token" "$url/state")" == 401 ]] || fail "wrong token is not 401"
[[ "$(http_code --max-time 2 "$url/events")" == 401 ]] || fail "/events without a token is not 401"
[[ "$(http_code -X POST "$url/message?token=$token" -H "Origin: $url" -d '{"text":"query"}')" == 401 ]] ||
  fail "a POST authenticated by query"
[[ "$(http_code "$url/")" == 401 ]] || fail "the SPA loads without a token"
spa="$("${CURL[@]}" "$url/?token=$token")" || fail "GET /?token= failed"
grep -q "<title>metacodes web</title>" <<<"$spa" || fail "the SPA does not load with ?token="
state="$("${CURL[@]}" "${auth[@]}" "$url/state")" || fail "GET /state with the token failed"
grep -q '"session_id"' <<<"$state" || fail "/state with the token failed"
ack="$("${CURL[@]}" "${auth[@]}" -X POST "$url/message" -H "Origin: $url" -d '{"text":"with token"}')"
grep -q '"ok":true' <<<"$ack" || fail "/message with the token not accepted: $ack"
events="$(events_until '"run_done".*end_turn' "$url/events?token=$token")" || fail "SSE with ?token= did not stream: $events"
grep -q '"user_message":"with token"' <<<"$events" || fail "the authenticated message is missing from the stream"
if grep -q '"user_message":"query"' <<<"$events"; then fail "the query-authenticated POST had an effect"; fi
# The trace surface sits behind the same token.
[[ "$(http_code "$url/spans")" == 401 ]] || fail "/spans without a token is not 401"
[[ "$(http_code "$url/trace")" == 401 ]] || fail "/trace without a token is not 401"
[[ "$(http_code "$url/trace?token=$token")" == 200 ]] || fail "/trace?token= is not served"
spans="$("${CURL[@]}" "${auth[@]}" "$url/spans")" || fail "GET /spans with the token failed"
grep -q '"name":"invoke_agent metacodes"' <<<"$spans" || fail "/spans with the token has no run span"
stop_daemon "$TMP/token.out"

# ── 3. non-loopback bind without authentication: refused before startup ────
expect_refusal "$TMP/refuse-flag.out" "$BIN" serve 0 --web-bind 0.0.0.0 --api-key test --base-url "$BASE_URL"
expect_refusal "$TMP/refuse-env.out" METACODES_WEB_BIND=:: "$BIN" serve 0 --api-key test --base-url "$BASE_URL"

# ── 4. OTLP export from the standard OTEL_* variables ───────────────────────
start_collector
start_daemon "$TMP/otel.out" OTEL_EXPORTER_OTLP_ENDPOINT="$COLLECTOR_URL" OTEL_EXPORTER_OTLP_PROTOCOL=http/json \
  OTEL_EXPORTER_OTLP_HEADERS="authorization=Bearer%20otel-e2e" OTEL_SERVICE_NAME=metacodes-e2e \
  "$BIN" serve 0 --api-key test --base-url "$BASE_URL"
wait_listening "$TMP/otel.out"
url="$DAEMON_URL"
ack="$("${CURL[@]}" -X POST "$url/message" -H "Origin: $url" -d '{"text":"traced OTEL_PROMPT_MARKER"}')"
grep -q '"ok":true' <<<"$ack" || fail "/message not accepted: $ack"
events_until '"run_done".*end_turn' "$url/events" >/dev/null || fail "traced run did not finish"
# SIGINT: the last App release flushes the exporter before the process exits.
stop_daemon "$TMP/otel.out"
[[ -s "$TMP/otlp.jsonl" ]] || fail "the collector received nothing"
python3 - "$TMP/otlp.jsonl" <<'PY' || fail "unexpected OTLP export: $(head -c 2000 "$TMP/otlp.jsonl")"
import json, sys
records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert all(r["content_type"] == "application/json" for r in records), records
assert all(r["authorization"] == "Bearer otel-e2e" for r in records), records
spans, services = [], set()
for r in records:
    doc = json.loads(r["body"])
    for rs in doc["resourceSpans"]:
        for a in rs["resource"]["attributes"]:
            if a["key"] == "service.name":
                services.add(a["value"]["stringValue"])
        for ss in rs["scopeSpans"]:
            spans.extend(ss["spans"])
assert services == {"metacodes-e2e"}, services
names = {s["name"] for s in spans}
assert "invoke_agent metacodes" in names and any(n.startswith("chat ") for n in names), names
# Message content is not exported unless OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true.
assert "OTEL_PROMPT_MARKER" not in "".join(r["body"] for r in records)
PY

echo "PASS: daemon e2e — /health, message→agent_loop→journal→SSE, /state·/command, bearer token, bind $bind, non-loopback refusal, /spans·/trace, OTLP export, SIGINT shutdown"
