#!/usr/bin/env bash
# tests/e2e/replay_e2e.sh —— Stage 7 record/replay 的 replay 端。
#
# 前置:先用 `E2E_RECORD=1 tests/e2e/run_e2e.sh <场景>` 录出 cassette
#   (落在 runs/<ts>/<场景>/cassette/sse-NNN.txt)。
#
# 用法:
#   tests/e2e/replay_e2e.sh runs/<ts>/<场景>/cassette <场景脚本.txt>
#
# 机制:起 replay_server(读 cassette → MockServer.startCassette,打印 base_url),
#   再用 metacodes --base-url <该地址> 跑同一场景脚本 → 不连真实端点、确定性复现。
#   断网也能跑(验证 replay 真的不打网络)。

set -u
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$E2E_DIR/lib.sh"

CASSETTE_DIR="${1:?用法: replay_e2e.sh <cassette_dir> <scenario.txt>}"
SCENARIO="${2:?用法: replay_e2e.sh <cassette_dir> <scenario.txt>}"
REPLAY_BIN="$ZIG_ROOT/zig-out/bin/replay_server"

[[ -d "$CASSETTE_DIR" ]] || { echo "cassette 目录不存在: $CASSETTE_DIR" >&2; exit 1; }
if [[ ! -x "$REPLAY_BIN" ]]; then
  echo "未找到 $REPLAY_BIN,先编译..." >&2
  ( cd "$ZIG_ROOT" && zig build ) || exit 1
fi

# 1) 起 replay_server,捕获首行 base_url
TMP_OUT="$(mktemp)"
"$REPLAY_BIN" "$CASSETTE_DIR" > "$TMP_OUT" &
REPLAY_PID=$!
trap 'kill "$REPLAY_PID" 2>/dev/null; rm -f "$TMP_OUT"' EXIT

# 等 base_url 出现(最多 5s)
BASE_URL=""
for _ in $(seq 1 50); do
  BASE_URL="$(head -1 "$TMP_OUT" 2>/dev/null)"
  [[ -n "$BASE_URL" ]] && break
  sleep 0.1
done
[[ -n "$BASE_URL" ]] || { echo "replay_server 未输出 base_url" >&2; exit 1; }
echo "replay base_url = $BASE_URL"

# 2) 用 --base-url 跑场景(经 E2E_BASE_URL 让 run_session 注入)
REPLAY_RUN="$E2E_DIR/runs/replay-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$REPLAY_RUN"
workdir="$REPLAY_RUN/work"
logfile="$REPLAY_RUN/replay.log"
debug_logfile="$REPLAY_RUN/replay.debug.log"

E2E_BASE_URL="$BASE_URL" \
  rc="$(run_session "$SCENARIO" "$workdir" "$logfile" "$debug_logfile" "/nonexistent.conf")"

echo "replay 退出码: $rc"
echo "产物: $workdir"
echo "日志: $logfile"
( cd "$workdir" && find . -type f -not -path './.*' | sort )
