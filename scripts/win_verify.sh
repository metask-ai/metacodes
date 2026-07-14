#!/usr/bin/env bash
# ============================================================================
# Windows 真机验证脚本 —— 跨平台移植 roadmap W6 产品成熟度门。
#
# 目的:在**原生 Windows**上真跑 platform keystone,验证 NT syscall 运行期正确性
#   (WSAStartup/ws2_32 socket、FindFirstFileW、QueryPerformanceCounter、CreateProcessW…),
#   这是交叉编译(仅证类型/链接)证不了、只有真机能证的一层。
#
# 用法:
#   ① WSL(interop 调 Windows 原生 zig.exe;test 二进制作为 Windows 进程真执行):
#        ZIG=zig.exe bash scripts/win_verify.sh
#   ② 原生 git-bash / MSYS(zig 在 PATH):
#        ZIG=zig bash scripts/win_verify.sh
#   ③ 指定全路径:
#        ZIG=/mnt/c/zig/zig.exe bash scripts/win_verify.sh
#
# 要求:Zig **0.16.0**(其它版本 std API 不同会全红,非本仓 bug)。
# 输出:分段清晰,把整段贴回即可判读。
# ============================================================================
set -u
ZIG="${ZIG:-zig.exe}"

echo "===== 0. 环境 ====="
echo "ZIG=$ZIG"
"$ZIG" version || { echo "!! zig 不可用:装 Windows 原生 zig 0.16.0 并加进 PATH,或用 ZIG=<全路径>"; exit 1; }
echo ""

echo "===== A. 原生 Windows 构建(编译+链接) ====="
"$ZIG" build 2>&1 | tail -25
echo "[A exit=$?]"
echo ""

echo "===== B. keystone 真机运行时单测(★核心:NT syscall 真执行) ====="
b_fail=0
for m in net dir sync process rng paths; do
  echo "----- platform/$m -----"
  "$ZIG" test "src/platform/$m.zig" -lc 2>&1 | tail -10
  rc=$?
  [ "$rc" -ne 0 ] && b_fail=1
  echo "[$m exit=$rc]"
done
echo "----- util/time -----"
"$ZIG" test "src/util/time.zig" 2>&1 | tail -8
echo "[time exit=$?]"
echo "[B keystone 有失败=$b_fail]"
echo ""

echo "===== C. 全量单测(注:含 POSIX-only e2e 工装项,windows 上部分预期失败——看 keystone/工具类是否绿) ====="
"$ZIG" build test 2>&1 | tail -18
echo "[C exit=$?]"
echo ""

echo "===== D. 真跑二进制 ====="
if [ -f ./zig-out/bin/metacodes.exe ]; then
  ./zig-out/bin/metacodes.exe --help 2>&1 | head -10
else
  echo "(zig-out/bin/metacodes.exe 不存在——看 A 段构建是否成功)"
fi
echo ""
echo "===== DONE(把以上整段贴回) ====="
