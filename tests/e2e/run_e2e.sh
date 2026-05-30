#!/usr/bin/env bash
# tests/e2e/run_e2e.sh —— 交互式 e2e 测试总驱动。
#
# 用法:
#   tests/e2e/run_e2e.sh              # 跑 scenarios/ 下全部
#   tests/e2e/run_e2e.sh '01*'        # 只跑匹配 glob 的场景
#   E2E_TIMEOUT=900 tests/e2e/run_e2e.sh 00_smoke   # 单场景 + 自定义超时
#
# ⚠️ 这会打【真实模型】(MiniMax),消耗真 token、需真网络。不进默认 CI。

set -u
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$E2E_DIR/lib.sh"

GLOB="${1:-*}"

# 1) 确认二进制在
if [[ ! -x "$BIN" ]]; then
  echo "未找到 $BIN,先编译..." >&2
  ( cd "$ZIG_ROOT" && zig build ) || { echo "zig build 失败" >&2; exit 1; }
fi
[[ -x "$BIN" ]] || { echo "编译后仍无 $BIN" >&2; exit 1; }

# 2) 时间戳 run 目录(可移植:不依赖 GNU date 的 %N)
TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$E2E_DIR/runs/$TS"
mkdir -p "$RUN_DIR"
REPORT="$RUN_DIR/REPORT.md"
report_header "$REPORT" "$TS"

# 3) 收集要跑的场景(bash 3.2 兼容:不用 mapfile)
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
echo " 报告: $REPORT"
echo "=========================================="

# 摘要表行
declare -a SUMMARY

# 4) 逐场景跑
for sfile in "${SCENARIOS[@]}"; do
  name="${sfile%.txt}"
  scenario_path="$E2E_DIR/scenarios/$sfile"
  workdir="$RUN_DIR/$name"
  logfile="$RUN_DIR/$name.log"

  echo ""
  echo ">>> 场景: $name  (超时 ${SESSION_TIMEOUT}s)"
  rc="$(run_session "$scenario_path" "$workdir" "$logfile")"

  collect_artifacts "$name" "$workdir" "$logfile" "$REPORT" "$rc"

  # 摘要数据
  nfiles=$(cd "$workdir" 2>/dev/null && find . -type f -not -path './.*' | wc -l | tr -d ' ')
  ntools=$(grep -cE 'tool\.exec start name=' "$logfile" 2>/dev/null | tr -d ' \n')
  nerr=$(grep -ciE 'error:|panic|unreachable|Unauthorized|StreamTooLong|RequestFailed|takeDelimiter failed|err=true|tool.exec FAILED' "$logfile" 2>/dev/null | tr -d ' \n')
  SUMMARY+=("$name|$rc|$nfiles|$ntools|$nerr")
  echo "    退出码=$rc 文件=$nfiles 工具调用=$ntools 错误=$nerr"
done

# 5) 摘要表写进报告 + 打印
{
  echo ""
  echo "---"
  echo ""
  echo "## 摘要"
  echo ""
  echo "| 场景 | 退出码 | 文件数 | 工具调用 | 错误行 |"
  echo "|------|--------|--------|----------|--------|"
  for row in "${SUMMARY[@]}"; do
    IFS='|' read -r n rc nf nt ne <<< "$row"
    echo "| $n | $rc | $nf | $nt | $ne |"
  done
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
echo "=========================================="
