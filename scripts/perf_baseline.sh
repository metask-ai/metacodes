#!/usr/bin/env bash
# perf_baseline.sh —— metacodes 性能/内存基线对比(见 doc/PERF_MEMORY_PRINCIPLES.md §2 红线)。
#
# 量:① ReleaseSmall 二进制体积 ② 暖启动时间(--help) ③ --help 常驻内存峰值(RSS)。
# 对比红线,任一超标或量不到 exit 1。CI 的 release leg 以 report-only 方式运行它(#303)。
#
# 用法:scripts/perf_baseline.sh [--build]   (--build 先 zig build -Doptimize=ReleaseSmall)

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BIN=zig-out/bin/metacodes

# 红线(对齐 PERF_MEMORY_PRINCIPLES §2)。
LIMIT_BIN_BYTES=$((6 * 1024 * 1024)) # 6 MiB(2026-10-18 按 5.50 MB 实测重新标定)
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
if [ "$bin_bytes" -gt "$LIMIT_BIN_BYTES" ]; then echo "  ✗ 超红线 6MB"; fail=1; else echo "  ✓"; fi

# ---- ② 暖启动时间(取 5 次最小值,排除冷启磁盘加载)----
./"$BIN" --help >/dev/null 2>&1  # 预热(冷启不计)
best_us=99999999
for _ in 1 2 3 4 5; do
  # 用 perl 取微秒级 wall time(macOS date 无 %N;整毫秒会把亚毫秒的启动记成 0 ms)。
  # 子进程的 stdout 指向 /dev/null:它继承 perl 的 stdout 时,--help 全文会混进 $t,
  # 数字比较报错,5 次全都量不到。
  t=$(perl -MTime::HiRes=time -e 'open(my $out, ">&", \*STDOUT) or exit 1; open(STDOUT, ">", "/dev/null") or exit 1;
        $s=time; system(@ARGV)==0 or exit 1; printf $out "%d", (time-$s)*1000000' \
        ./"$BIN" --help 2>/dev/null)
  [ -n "$t" ] && [ "$t" -lt "$best_us" ] && best_us=$t
done
# 5 次都没量到(缺 perl 或进程失败)算不达标,不能当成 0。
if [ "$best_us" -eq 99999999 ]; then
  echo "暖启动(min/5): 无法测量(需要 perl,且 --help 须成功)  ✗"; fail=1
else
  printf "暖启动(min/5): %.1f ms" "$(echo "scale=1; $best_us/1000" | bc)"
  if [ "$best_us" -gt $((LIMIT_START_MS * 1000)) ]; then echo "  ✗ 超红线 20ms"; fail=1; else echo "  ✓"; fi
fi

# ---- ③ --help 常驻内存峰值(RSS)----
# macOS: /usr/bin/time -l 输出 "maximum resident set size";Linux: -v 输出 "Maximum resident"。
rss_bytes=""
if /usr/bin/time -l true >/dev/null 2>&1; then
  # macOS:-l 的 maximum resident set size 单位是字节。
  rss_bytes=$(/usr/bin/time -l ./"$BIN" --help 2>&1 >/dev/null | awk '/maximum resident set size/{print $1}')
else
  # Linux:-v 的 Maximum resident set size 单位是 KB。
  rss_kb=$(/usr/bin/time -v ./"$BIN" --help 2>&1 >/dev/null | awk -F: '/Maximum resident/{gsub(/ /,"",$2);print $2}')
  [ -n "$rss_kb" ] && rss_bytes=$((rss_kb * 1024))
fi
# 没有 /usr/bin/time 时上面两支都量不到;空值曾按 0 KB 记为达标。
if [ -z "$rss_bytes" ] || [ "$rss_bytes" -eq 0 ]; then
  echo "空闲 RSS 峰值: 无法测量(需要 /usr/bin/time:macOS -l,Linux -v)  ✗"; fail=1
else
  printf "空闲 RSS 峰值: %d KB" "$((rss_bytes / 1024))"
  if [ "$rss_bytes" -gt "$LIMIT_RSS_BYTES" ]; then echo "  ✗ 超红线 3MB"; fail=1; else echo "  ✓"; fi
fi

echo "---"
if [ "$fail" -eq 0 ]; then echo "基线全部达标 ✓"; else echo "基线有超标项 ✗(见 doc/PERF_MEMORY_PRINCIPLES.md)"; fi
exit $fail
