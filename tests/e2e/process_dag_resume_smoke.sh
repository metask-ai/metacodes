#!/usr/bin/env bash
# Deterministic process-level startup/resume smoke test for the TinyKG control plane.
# No model call: fresh metacodes processes with the same host-injected session id
# must recover a task claimed under that id from the persistent store, and the
# second one must put the bounded "Active task recovery packet" into its first
# API request.
#
# The store is reached the way sessions reach it: through the state root's local
# service (`metacodes kg install` + `metacodes kgd`, doc/TINYKG_INTEGRATION.md
# "The local service"). The script starts that service itself and stops it on
# exit; sessions run with METACODES_KG_AUTOSTART=0 and every METACODES_KG_*
# override removed, so they use exactly that service and leave nothing running.
#
# Run by `zig build test` on POSIX hosts (build.zig, METACODES_PROCESS_E2E_BIN set
# to the installed product); by hand: `zig build && bash tests/e2e/process_dag_resume_smoke.sh`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${METACODES_PROCESS_E2E_BIN:-$ROOT/zig-out/bin/metacodes}"
KGD_API=(python3 "$ROOT/tests/e2e/kgd_api.py")

[[ -x "$BIN" ]] || { echo "missing metacodes binary: $BIN (zig build first)" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 2; }

tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
home="$tmp/home"
project="$tmp/project"
state="$home/.metacodes"
mkdir -p "$state" "$project"
session_id="0123456789abcdef01234567"
kgd_pid=""
server_pid=""

cleanup() {
  local status=$?
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
  if [[ -n "$kgd_pid" ]]; then
    kill -TERM "$kgd_pid" 2>/dev/null || true
    wait "$kgd_pid" 2>/dev/null || true
  fi
  # Nothing this run started may outlive it (a session would autostart a
  # service in its state root that never exits when idle).
  local leaked
  # The path travels in the environment: in awk's argv it would match awk itself.
  leaked="$(
    export SMOKE_ROOT="$tmp/"
    ps -A -ww -o pid= -o command= 2>/dev/null |
      awk 'ENVIRON["SMOKE_ROOT"] != "/" && index($0, ENVIRON["SMOKE_ROOT"]) && / kgd( |$)|tinykgd/ {print $1}' |
      tr '\n' ' '
  )"
  if [[ -n "${leaked// /}" ]]; then
    echo "process_dag_resume_smoke: TinyKG processes left running under $tmp: $leaked" >&2
    # shellcheck disable=SC2086 # one pid per word
    kill -KILL $leaked 2>/dev/null || true
    [[ $status -eq 0 ]] && status=7
  fi
  if [[ "${KEEP_PROCESS_DAG_RESUME_TMP:-0}" == "1" ]]; then
    echo "kept diagnostics: $tmp" >&2
  else
    rm -rf "$tmp"
  fi
  exit "$status"
}
trap cleanup EXIT

# A session in this HOME and state root, using only the service started below.
session() {
  (
    cd "$project"
    env -u METACODES_KG_BIN -u METACODES_KG_STORE -u METACODES_KG_TRANSPORT \
      -u METACODES_KG_CONFIG -u METACODES_KG_URL -u METACODES_KG_API_KEY \
      -u METACODES_KG_EXPECTED_BUILD_ID -u METACODES_KG_EXPECTED_SCHEMA_DIGEST \
      HOME="$home" METASK_API_KEY="process-resume-smoke" METACODES_NO_PROBE=1 \
      METACODES_KG_AUTOSTART=0 METACODES_JEV_URL=off \
      "$BIN" --state-dir "$state" --api-key process-resume-smoke \
      --model claude-sonnet-4-20250514 --session "$session_id" --no-theme "$@"
  )
}

# The state root's service: provision it (store, key, daemon.json) and serve it.
HOME="$home" "$BIN" --state-dir "$state" kg install >"$tmp/kg-install.out" 2>&1 ||
  { cat "$tmp/kg-install.out" >&2; exit 3; }
HOME="$home" "$BIN" --state-dir "$state" kgd >"$tmp/kgd.log" 2>&1 &
kgd_pid=$!
"${KGD_API[@]}" ready "$state" --wait 60 || { cat "$tmp/kgd.log" >&2; exit 3; }

# A first process creates the per-project pointer directory (and, with a ready
# service, its task anchor).
session --dump-prompt >"$tmp/first.prompt"
project_dirs=("$state/projects"/*)
[[ ${#project_dirs[@]} -eq 1 && -d "${project_dirs[0]}" ]] || {
  echo "expected exactly one project pointer directory" >&2
  exit 3
}
pointer_dir="${project_dirs[0]}"

node_id() {
  local output="$1"
  local id
  id="$(printf '%s\n' "$output" | awk 'NR == 1 && $1 == "node" { print $2 }')"
  [[ "$id" =~ ^[0-9]+$ ]] || { echo "invalid node output: $output" >&2; exit 4; }
  printf '%s' "$id"
}

kg() { "${KGD_API[@]}" run "$state" "$@"; }

root="$(node_id "$(kg add-node task "process resume root" --schema-type plan_root)")"
child="$(node_id "$(kg add-node task "recover this exact claimed task" --schema-type plan_step)")"
kg add-edge "$root" contains "$child" >/dev/null
if [[ -f "$pointer_dir/kg_task_anchor" ]]; then
  task_anchor="$(tr -d '[:space:]' <"$pointer_dir/kg_task_anchor")"
  kg add-edge "$task_anchor" contains "$root" >/dev/null
else
  printf '%s\n' "$root" >"$pointer_dir/kg_root"
fi
kg task-claim "$child" --by "$session_id" >/dev/null

# A genuinely fresh process must inject the bounded packet into its first API request.
python3 "$ROOT/tests/e2e/capture_sse_once.py" "$tmp/request.json" "$tmp/base-url" 2>"$tmp/capture.err" &
server_pid=$!
# A loaded host (`zig build test` runs this beside the whole suite) can take
# seconds to start an interpreter: give up only when the server has died or
# after a minute, and wait for the whole URL line, not just a first byte.
deadline=$((SECONDS + 60))
until grep -qs '/v1/messages$' "$tmp/base-url"; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "capture server exited before it listened:" >&2
    cat "$tmp/capture.err" >&2
    exit 5
  fi
  if ((SECONDS >= deadline)); then
    echo "capture server did not listen within 60 s" >&2
    cat "$tmp/capture.err" >&2
    exit 5
  fi
  sleep 0.05
done
base_url="$(tr -d '[:space:]' <"$tmp/base-url")"
session --base-url "$base_url" --permission bypassPermissions \
  -p "continue the claimed task" >"$tmp/resumed.out" 2>"$tmp/resumed.err" || true
wait "$server_pid" || true
server_pid=""

if ! grep -q "Active task recovery packet" "$tmp/request.json" 2>/dev/null; then
  echo "resume packet missing; request/task diagnostics:" >&2
  grep -n -E "Knowledge Graph|CLAIMED|recover this exact|TinyKG" "$tmp/request.json" >&2 || true
  kg task-frontier "$root" --limit 8 >&2 || true
  sed -n '1,120p' "$tmp/resumed.err" >&2
  exit 6
fi
grep -Fq "\\\"task_id\\\":$child" "$tmp/request.json" || { echo "packet does not name task $child" >&2; exit 6; }
grep -q "recover this exact claimed task" "$tmp/request.json" || { echo "packet does not carry the task text" >&2; exit 6; }

echo "process_dag_resume_smoke ok task=$child session=$session_id"
