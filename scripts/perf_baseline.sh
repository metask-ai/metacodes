#!/usr/bin/env bash
# perf_baseline.sh —— cc-zig 性能/内存基线对比(见 doc/PERF_MEMORY_PRINCIPLES.md §2 红线)。
#
# 量:① ReleaseSmall 二进制体积 ② 暖启动时间(--help) ③ --help 常驻内存峰值(RSS)。
# 对比红线,任一超标 exit 1(可用于 CI 守门)。
#
# 用法:scripts/perf_baseline.sh [--build]   (--build 先 zig build -Doptimize=ReleaseSmall)

set -uo pipefail
cd "$(dirname "$0")/.."

BIN=zig-out/bin/metacodes

# 红线(对齐 PERF_MEMORY_PRINCIPLES §2)。
LIMIT_BIN_BYTES=$((1500 * 1024))   # 1.5 MB
LIMIT_START_MS=20                   # 暖启动 ≤ 20ms
LIMIT_RSS_BYTES=$((3 * 1024 * 1024)) # 空闲 RSS ≤ 3 MB

if [ "${1:-}" = "--build" ]; then
  echo "[build] zig build -Doptimize=ReleaseSmall …"
  zig build -Doptimize=ReleaseSmall >/dev/null 2>&1 || { echo "build failed"; exit 1; }
fi

[ -x "$BIN" ] || { echo "缺二进制 $BIN(先 zig build -Doptimize=ReleaseSmall 或加 --build)"; exit 2; }

fail=0

# ---- ① 二进制体积 ----
bin_bytes=$(wc -c < "$BIN" | tr -d ' ')
bin_kb=$((bin_bytes / 1024))
printf "二进制体积:   %d KB (%.2f MB)" "$bin_kb" "$(echo "scale=2; $bin_bytes/1048576" | bc)"
if [ "$bin_bytes" -gt "$LIMIT_BIN_BYTES" ]; then echo "  ✗ 超红线 1.5MB"; fail=1; else echo "  ✓"; fi

# ---- ② 暖启动时间(取 5 次最小值,排除冷启磁盘加载)----
./"$BIN" --help >/dev/null 2>&1  # 预热(冷启不计)
best_ms=99999
for _ in 1 2 3 4 5; do
  # 用 perl 取毫秒级 wall time(macOS date 无 %N)。
  t=$(perl -MTime::HiRes=time -e '$s=time; system(@ARGV)==0 or exit 1; printf "%d", (time-$s)*1000' \
        ./"$BIN" --help 2>/dev/null)
  [ -n "$t" ] && [ "$t" -lt "$best_ms" ] && best_ms=$t
done
printf "暖启动(min/5): %d ms" "$best_ms"
if [ "$best_ms" -gt "$LIMIT_START_MS" ]; then echo "  ✗ 超红线 20ms"; fail=1; else echo "  ✓"; fi

# ---- ③ --help 常驻内存峰值(RSS)----
# macOS: /usr/bin/time -l 输出 "maximum resident set size";Linux: -v 输出 "Maximum resident"。
rss_bytes=0
if /usr/bin/time -l true >/dev/null 2>&1; then
  # macOS:-l 的 maximum resident set size 单位是字节。
  rss_bytes=$(/usr/bin/time -l ./"$BIN" --help 2>&1 >/dev/null | awk '/maximum resident set size/{print $1}')
else
  # Linux:-v 的 Maximum resident set size 单位是 KB。
  rss_kb=$(/usr/bin/time -v ./"$BIN" --help 2>&1 >/dev/null | awk -F: '/Maximum resident/{gsub(/ /,"",$2);print $2}')
  rss_bytes=$((rss_kb * 1024))
fi
rss_kb_disp=$((rss_bytes / 1024))
printf "空闲 RSS 峰值: %d KB" "$rss_kb_disp"
if [ "$rss_bytes" -gt "$LIMIT_RSS_BYTES" ]; then echo "  ✗ 超红线 3MB"; fail=1; else echo "  ✓"; fi

echo "---"
if [ "$fail" -eq 0 ]; then echo "基线全部达标 ✓"; else echo "基线有超标项 ✗(见 doc/PERF_MEMORY_PRINCIPLES.md)"; fi
exit $fail
