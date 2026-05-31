#!/usr/bin/env bash
# tests/e2e/run_e2e.sh —— 交互式 e2e 测试总驱动。
#
# 用法:
#   tests/e2e/run_e2e.sh              # 跑 scenarios/ 下全部
#   tests/e2e/run_e2e.sh '01*'        # 只跑匹配 glob 的场景
#   E2E_TIMEOUT=900 tests/e2e/run_e2e.sh 00_smoke   # 单场景 + 自定义超时
#   E2E_BIN=release tests/e2e/run_e2e.sh            # 用 ReleaseSmall(默认 debug)
#   E2E_KEEP=all  tests/e2e/run_e2e.sh              # 保留所有 runs/(默认留最近 5)
#   E2E_KEEP=0    tests/e2e/run_e2e.sh              # 跑完即删本次 run
#   E2E_RECORD=1  tests/e2e/run_e2e.sh 02_html_game # 录 cassette 到 <场景>/cassette/
#
# ⚠️ 这会打【真实模型】(MiniMax),消耗真 token、需真网络。不进默认 CI。
#    record/replay(Stage 7):E2E_RECORD=1 录;replay 用 tests/e2e/replay_e2e.sh。

set -u
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$E2E_DIR/lib.sh"

GLOB="${1:-*}"

# 1) 确认二进制在(默认 debug)
if [[ ! -x "$BIN" ]]; then
  echo "未找到 $BIN,先编译..." >&2
  ( cd "$ZIG_ROOT" && zig build ) || { echo "zig build 失败" >&2; exit 1; }
fi
[[ -x "$BIN" ]] || { echo "编译后仍无 $BIN" >&2; exit 1; }

# 2) 时间戳 run 目录
TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$E2E_DIR/runs/$TS"
mkdir -p "$RUN_DIR"
REPORT="$RUN_DIR/REPORT.md"
report_header "$REPORT" "$TS"

# 2.5) 保留策略(Stage 1):默认留最近 5 个 runs/<ts>;E2E_KEEP=all 全留,=0 跑完删本次。
E2E_KEEP="${E2E_KEEP:-5}"
prune_runs() {
  [[ "$E2E_KEEP" == "all" ]] && return 0
  if [[ "$E2E_KEEP" == "0" ]]; then
    rm -rf "$RUN_DIR"
    echo "(E2E_KEEP=0:已删除本次 run $RUN_DIR)" >&2
    return 0
  fi
  # 留最近 N 个(按名字倒序,名字是时间戳 → 字典序=时间序)
  local keep="$E2E_KEEP"
  ( cd "$E2E_DIR/runs" 2>/dev/null && ls -1d */ 2>/dev/null | sort -r | tail -n +"$(( keep + 1 ))" \
      | while IFS= read -r d; do rm -rf "$d"; done )
}
trap prune_runs EXIT

# 3) 收集要跑的场景(bash 3.2 兼容)
shopt -s nullglob
SCENARIOS=()
while IFS= read -r f; do
  [[ -n "$f" ]] && SCENARIOS+=("$f")
done < <(cd "$E2E_DIR/scenarios" && ls -1 ${GLOB}.txt 2>/dev/null | sort)
if [[ ${#SCENARIOS[@]} -eq 0 ]]; then
  echo "没有匹配 '$GLOB' 的场景(scenarios/${GLOB}.txt)" >&2
  exit 1
fi

echo "=========================================="
echo " cc-zig 交互式 e2e — ${#SCENARIOS[@]} 个场景"
echo " 二进制: $BIN"
echo " 报告: $REPORT"
echo "=========================================="

declare -a SUMMARY
HARD_FAILS=0

# 4) 逐场景跑
for sfile in "${SCENARIOS[@]}"; do
  name="${sfile%.txt}"
  scenario_path="$E2E_DIR/scenarios/$sfile"
  conf_path="$E2E_DIR/scenarios/$name.conf"
  workdir="$RUN_DIR/$name"
  logfile="$RUN_DIR/$name.log"
  debug_logfile="$RUN_DIR/$name.debug.log"

  echo ""
  echo ">>> 场景: $name  (超时 ${SESSION_TIMEOUT}s$( [[ -f "$conf_path" ]] && echo ', 有 .conf' ))"
  rc="$(run_session "$scenario_path" "$workdir" "$logfile" "$debug_logfile" "$conf_path")"

  # collect 返回 "<错误数>|<硬失败数>"(load_conf 在 run_session 已填,collect 复用)
  collect_ret="$(collect_artifacts "$name" "$workdir" "$logfile" "$debug_logfile" "$REPORT" "$rc" "$conf_path")"
  nerr="${collect_ret%%|*}"
  hard="${collect_ret##*|}"
  HARD_FAILS=$(( HARD_FAILS + ${hard:-0} ))

  nfiles=$(cd "$workdir" 2>/dev/null && find . -type f -not -path './.*' | wc -l | tr -d ' ')
  ntools=$(grep -cE 'tool\.exec start name=' "$debug_logfile" 2>/dev/null | tr -d ' \n')
  SUMMARY+=("$name|$rc|$nfiles|$ntools|$nerr")
  echo "    退出码=$rc 文件=$nfiles 工具调用=$ntools 错误=$nerr$( [[ "${hard:-0}" != "0" ]] && echo " 硬失败=$hard" )"
done

# 5) 摘要表
{
  echo ""
  echo "---"
  echo ""
  echo "## 摘要"
  echo ""
  echo "| 场景 | 退出码 | 文件数 | 工具调用 | 错误 |"
  echo "|------|--------|--------|----------|------|"
  for row in "${SUMMARY[@]}"; do
    IFS='|' read -r n rc nf nt ne <<< "$row"
    echo "| $n | $rc | $nf | $nt | $ne |"
  done
  [[ "$HARD_FAILS" != "0" ]] && echo "" && echo "**硬断言失败总数: $HARD_FAILS**"
} >> "$REPORT"

echo ""
echo "=========================================="
echo " 完成。摘要:"
for row in "${SUMMARY[@]}"; do
  IFS='|' read -r n rc nf nt ne <<< "$row"
  printf '   %-22s rc=%-4s files=%-3s tools=%-3s err=%s\n' "$n" "$rc" "$nf" "$nt" "$ne"
done
echo ""
echo " 完整报告: $REPORT"
[[ "$HARD_FAILS" != "0" ]] && echo " ⚠️  硬断言失败: $HARD_FAILS"
echo "=========================================="

# EXPECT_HARD=1 的 FAIL 进退出码(供 CI)
[[ "$HARD_FAILS" != "0" ]] && exit 2
exit 0
