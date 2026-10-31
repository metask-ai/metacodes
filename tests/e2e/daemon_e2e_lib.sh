#!/usr/bin/env bash
# Shared by daemon_serve_e2e.sh and daemon_serve_multi_e2e.sh; sourced, not run.
#
# Offline by construction: the provider is tests/e2e/daemon_mock_provider.py on
# 127.0.0.1, every port is picked by the kernel (port 0, read back from the
# daemon's startup line), HOME and the state root are temporary, TinyKG
# autostart and the Jev advisor are off, and every METACODES_WEB_* /
# METACODES_KG_* override of the caller is removed. Nothing a run starts may
# outlive it.
#
# The binary is METACODES_DAEMON_E2E_BIN (set by `zig build test`), else
# zig-out/bin/metacodes.

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$E2E_DIR/../.." && pwd)"
BIN="${METACODES_DAEMON_E2E_BIN:-$ROOT/zig-out/bin/metacodes}"
[[ -x "$BIN" ]] || { echo "missing metacodes binary: $BIN (zig build first)" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 2; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 2; }

TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
mkdir -p "$TMP/home" "$TMP/state"
MOCK_PID=""
DAEMON_PID=""
BASE_URL=""
DAEMON_URL=""
# -g: an IPv6 URL's brackets are literal, not a glob.
CURL=(curl -g -sS)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

daemon_e2e_cleanup() {
  local status=$?
  # Reaped here, quietly: bash would otherwise report each killed job.
  local pid
  for pid in "$DAEMON_PID" "$MOCK_PID" "$COLLECTOR_PID"; do
    [[ -n "$pid" ]] || continue
    { kill -KILL "$pid" && wait "$pid"; } 2>/dev/null || true
  done
  local leaked
  # The path travels in the environment: in awk's argv it would match awk itself.
  leaked="$(
    export DAEMON_E2E_ROOT="$TMP/"
    ps -A -ww -o pid= -o command= 2>/dev/null |
      awk 'ENVIRON["DAEMON_E2E_ROOT"] != "/" && index($0, ENVIRON["DAEMON_E2E_ROOT"]) && / kgd( |$)|tinykgd/ {print $1}' |
      tr '\n' ' '
  )"
  if [[ -n "${leaked// /}" ]]; then
    echo "TinyKG processes left running under $TMP: $leaked" >&2
    # shellcheck disable=SC2086 # one pid per word
    kill -KILL $leaked 2>/dev/null || true
    [[ $status -eq 0 ]] && status=7
  fi
  if [[ $status -ne 0 ]]; then
    for log in "$TMP"/*.out; do
      [[ -f "$log" ]] && { echo "--- $log" >&2; tail -n 40 "$log" >&2; }
    done
  fi
  if [[ "${KEEP_DAEMON_E2E_TMP:-0}" == "1" ]]; then
    echo "kept: $TMP" >&2
  else
    rm -rf "$TMP"
  fi
  exit "$status"
}
trap daemon_e2e_cleanup EXIT

# Wait (up to 60 s) for <file> to hold a complete line, while <pid> lives.
wait_for_line() {
  local file="$1" pid="$2" pattern="$3"
  local deadline=$((SECONDS + 60))
  until grep -qsE -- "$pattern" "$file"; do
    kill -0 "$pid" 2>/dev/null || return 1
    ((SECONDS < deadline)) || return 1
    sleep 0.05
  done
}

COLLECTOR_PID=""
COLLECTOR_URL=""

# A loopback OTLP/HTTP receiver; requests land in $TMP/otlp.jsonl.
start_collector() {
  python3 "$E2E_DIR/otlp_mock_collector.py" "$TMP/collector.url" "$TMP/otlp.jsonl" >"$TMP/collector.out" 2>&1 &
  COLLECTOR_PID=$!
  wait_for_line "$TMP/collector.url" "$COLLECTOR_PID" '^http://' || fail "OTLP collector did not start"
  COLLECTOR_URL="$(tr -d '[:space:]' <"$TMP/collector.url")"
}

start_mock() {
  python3 "$E2E_DIR/daemon_mock_provider.py" "$TMP/mock.url" >"$TMP/mock.out" 2>&1 &
  MOCK_PID=$!
  wait_for_line "$TMP/mock.url" "$MOCK_PID" '/v1/messages$' || fail "mock provider did not start"
  BASE_URL="$(tr -d '[:space:]' <"$TMP/mock.url")"
}

# start_daemon <log> [VAR=value ...] <command...>: run in the isolated environment.
start_daemon() {
  local log="$1"
  shift
  env -u METACODES_WEB_TOKEN -u METACODES_WEB_BIND -u METACODES_HOME \
    -u METACODES_KG_BIN -u METACODES_KG_STORE -u METACODES_KG_TRANSPORT \
    -u METACODES_KG_CONFIG -u METACODES_KG_URL -u METACODES_KG_API_KEY \
    -u METACODES_KG_EXPECTED_BUILD_ID -u METACODES_KG_EXPECTED_SCHEMA_DIGEST \
    -u OTEL_SDK_DISABLED -u OTEL_TRACES_EXPORTER -u OTEL_EXPORTER_OTLP_ENDPOINT \
    -u OTEL_EXPORTER_OTLP_TRACES_ENDPOINT -u OTEL_EXPORTER_OTLP_PROTOCOL \
    -u OTEL_EXPORTER_OTLP_TRACES_PROTOCOL -u OTEL_EXPORTER_OTLP_HEADERS \
    -u OTEL_EXPORTER_OTLP_TRACES_HEADERS -u OTEL_SERVICE_NAME -u OTEL_RESOURCE_ATTRIBUTES \
    -u OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT -u METACODES_SPANS \
    HOME="$TMP/home" METACODES_HOME="$TMP/state" METACODES_NO_PROBE=1 \
    METACODES_KG_AUTOSTART=0 METACODES_JEV_URL=off \
    "$@" >"$log" 2>&1 &
  DAEMON_PID=$!
}

# Wait for the startup line `<label>: http://<addr>:<port>  (Ctrl+C to quit)`
# and set DAEMON_URL to the URL it names (the real bind address and port).
wait_listening() {
  local log="$1"
  wait_for_line "$log" "$DAEMON_PID" 'http://[^ ]+  \(Ctrl\+C to quit\)' || fail "daemon did not start listening ($log)"
  DAEMON_URL="$(grep -m 1 -oE 'http://[^ ]+  \(Ctrl' "$log" | sed 's/  (Ctrl$//')"
  [[ -n "$DAEMON_URL" ]] || fail "no URL in the startup line ($log)"
}

# SIGINT, then the daemon must exit 0 within 10 s and say so.
stop_daemon() {
  local log="$1"
  kill -INT "$DAEMON_PID"
  local deadline=$((SECONDS + 10))
  while kill -0 "$DAEMON_PID" 2>/dev/null; do
    ((SECONDS < deadline)) || fail "daemon hung after SIGINT"
    sleep 0.1
  done
  local rc=0
  wait "$DAEMON_PID" || rc=$?
  DAEMON_PID=""
  [[ $rc -eq 0 ]] || fail "daemon exited $rc after SIGINT"
  grep -q "daemon closed" "$log" || fail "no 'daemon closed' in $log"
}

# expect_refusal <log> [VAR=value ...] <command...>: must exit 2 at once, never serve.
expect_refusal() {
  local log="$1"
  start_daemon "$@"
  local deadline=$((SECONDS + 10))
  while kill -0 "$DAEMON_PID" 2>/dev/null; do
    ((SECONDS < deadline)) || fail "a refused bind started serving ($log)"
    sleep 0.05
  done
  local rc=0
  wait "$DAEMON_PID" || rc=$?
  DAEMON_PID=""
  [[ $rc -eq 2 ]] || fail "refused bind exited $rc, not 2 ($log)"
  grep -q "refusing to serve on" "$log" || fail "no refusal message in $log"
  if grep -q "Ctrl+C to quit" "$log"; then fail "a refused bind printed a listening line ($log)"; fi
}

# http_code <curl args...>: the status code only.
http_code() {
  "${CURL[@]}" -o /dev/null -w '%{http_code}' --max-time 5 "$@" || true
}

# check_health <url> <version> <sessions> [curl args...]
check_health() {
  local url="$1" version="$2" sessions="$3"
  shift 3
  local body
  body="$("${CURL[@]}" -f --max-time 5 "$@" "$url/health")" || fail "GET $url/health failed"
  python3 - "$body" "$version" "$sessions" <<'PY' || fail "unexpected /health body: $body"
import json, sys
doc = json.loads(sys.argv[1])
expected = {"status": "ok", "version": sys.argv[2], "sessions": int(sys.argv[3])}
assert doc == expected, (doc, expected)
PY
}

# events_until <pattern> <curl args...>: read the SSE stream (replayed from the
# start) until it shows <pattern>, for up to 30 s; prints what it last read.
events_until() {
  local pattern="$1"
  shift
  local deadline=$((SECONDS + 30)) body=""
  while :; do
    body="$("${CURL[@]}" --max-time 1 "$@" 2>/dev/null || true)"
    if grep -qE -- "$pattern" <<<"$body"; then
      printf '%s' "$body"
      return 0
    fi
    ((SECONDS < deadline)) || { printf '%s' "$body"; return 1; }
  done
}

# The version `metacodes --version` prints on its first line, which GET /health
# must repeat. awk reads to the end: closing the pipe early would SIGPIPE the binary.
binary_version() {
  "$BIN" --version | awk 'NR == 1 {print $2}'
}
