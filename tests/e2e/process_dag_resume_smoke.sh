#!/usr/bin/env bash
# Deterministic process-level startup/resume smoke test for the TinyKG control plane.
# No model call:two fresh metacodes processes use the same host-injected session id;
# the second must recover the lease packet from the persistent store in --dump-prompt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${METACODES_PROCESS_E2E_BIN:-$ROOT/zig-out/bin/metacodes-debug}"
TINYKG="${METACODES_TEST_TINYKG_BIN:-${METACODES_KG_BIN:-}}"

[[ -x "$BIN" ]] || { echo "missing metacodes binary: $BIN" >&2; exit 2; }
[[ -n "$TINYKG" && -x "$TINYKG" ]] || {
  echo "missing explicit TinyKG binary; set METACODES_TEST_TINYKG_BIN or METACODES_KG_BIN" >&2
  exit 2
}

tmp="$(mktemp -d)"
cleanup() {
  if [[ "${KEEP_PROCESS_DAG_RESUME_TMP:-0}" == "1" ]]; then
    echo "kept diagnostics: $tmp" >&2
  else
    rm -rf "$tmp"
  fi
}
trap cleanup EXIT
home="$tmp/home"
project="$tmp/project"
mkdir -p "$home/.metacodes" "$project"
session_id="0123456789abcdef01234567"

dump_prompt() {
  (
    cd "$project"
    HOME="$home" METASK_API_KEY="process-resume-smoke" \
      "$BIN" --api-key process-resume-smoke --model claude-sonnet-4-20250514 \
      --session "$session_id" --dump-prompt --no-theme
  )
}

# First process creates the canonical store and per-project pointer directory.
dump_prompt >"$tmp/first.prompt"
project_dirs=("$home/.metacodes/projects"/*)
[[ ${#project_dirs[@]} -eq 1 && -d "${project_dirs[0]}" ]] || {
  echo "expected exactly one project pointer directory" >&2
  exit 3
}
pointer_dir="${project_dirs[0]}"
store="$home/.metacodes/kg/store.kg"

node_id() {
  local output="$1"
  local id
  id="$(printf '%s\n' "$output" | awk 'NR == 1 && $1 == "node" { print $2 }')"
  [[ "$id" =~ ^[0-9]+$ ]] || { echo "invalid node output: $output" >&2; exit 4; }
  printf '%s' "$id"
}

root="$(node_id "$("$TINYKG" add-node "$store" task "process resume root" --schema-type plan_root)")"
child="$(node_id "$("$TINYKG" add-node "$store" task "recover this exact claimed task" --schema-type plan_step)")"
"$TINYKG" add-edge "$store" "$root" contains "$child" >/dev/null
if [[ -f "$pointer_dir/kg_task_anchor" ]]; then
  task_anchor="$(tr -d '[:space:]' <"$pointer_dir/kg_task_anchor")"
  "$TINYKG" add-edge "$store" "$task_anchor" contains "$root" >/dev/null
else
  printf '%s\n' "$root" >"$pointer_dir/kg_root"
fi
"$TINYKG" task-claim "$store" "$child" --by "$session_id" >/dev/null

# A genuinely fresh process must inject the bounded packet into its first API request.
python3 "$ROOT/tests/e2e/capture_sse_once.py" "$tmp/request.json" "$tmp/base-url" &
server_pid=$!
for _ in {1..100}; do
  [[ -s "$tmp/base-url" ]] && break
  sleep 0.02
done
[[ -s "$tmp/base-url" ]] || { echo "capture server did not start" >&2; exit 5; }
base_url="$(tr -d '[:space:]' <"$tmp/base-url")"
(
  cd "$project"
  HOME="$home" METASK_API_KEY="process-resume-smoke" METACODES_NO_PROBE=1 \
    "$BIN" --api-key process-resume-smoke --model claude-sonnet-4-20250514 \
    --session "$session_id" --base-url "$base_url" --permission bypassPermissions \
    -p "continue the claimed task" --no-theme
) >"$tmp/resumed.out" 2>"$tmp/resumed.err" || true
wait "$server_pid"

if ! rg -q "Active task recovery packet" "$tmp/request.json"; then
  echo "resume packet missing; request/task diagnostics:" >&2
  rg -n "Knowledge Graph|CLAIMED|recover this exact|TinyKG" "$tmp/request.json" >&2 || true
  "$TINYKG" task-frontier "$store" "$root" --limit 8 >&2 || true
  sed -n '1,120p' "$tmp/resumed.err" >&2
  exit 6
fi
rg -Fq "\\\"task_id\\\":$child" "$tmp/request.json"
rg -q "recover this exact claimed task" "$tmp/request.json"

echo "process_dag_resume_smoke ok task=$child session=$session_id"
