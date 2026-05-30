#!/usr/bin/env bash
# 验证「提示词 × 工具关系」复刻:工具长描述 + 动态耦合是否真进了组装好的
# system prompt / 工具 defs。
#
# 用 metacodes --dump-prompt:构造完 prompt + tool defs 后直接打印 stdout 退出,
# 不发网络、不需有效 API key。比 dump 日志可靠(日志有 8192 截断)。
#
# 用法: ./scripts/test_prompt_tool.sh

set -u
cd "$(dirname "$0")/.."   # cc-zig 根

BIN=./zig-out/bin/metacodes
[[ -x "$BIN" ]] || { echo "找不到 $BIN,先 zig build" >&2; exit 2; }

PASS=0; FAIL=0
check() { # <desc> <file> <needle>
  if grep -qF "$3" "$2"; then echo "  ✓ $1"; PASS=$((PASS+1));
  else echo "  ✗ $1  —— 未找到 \"$3\""; FAIL=$((FAIL+1)); fi
}
absent() { # <desc> <file> <needle>  —— 断言不存在
  if grep -qF "$3" "$2"; then echo "  ✗ $1  —— 不该出现却出现了 \"$3\""; FAIL=$((FAIL+1));
  else echo "  ✓ $1 (已裁剪)"; PASS=$((PASS+1)); fi
}

# --- 1) 主对话:全量工具集 ---
FULL=/tmp/cc-dump-full.txt
"$BIN" --api-key sk-fake --dump-prompt 2>/dev/null > "$FULL"
echo "=== 1) 主对话 dump ($(wc -c <"$FULL") bytes, $(grep -c '^----- ' "$FULL") 个工具) ==="

echo "--- 工具长描述进 defs ---"
check "Read  (cat -n format)"             "$FULL" "cat -n format"
check "Write (must-read-first)"           "$FULL" "MUST use the Read tool first"
check "Edit  (exact replacements)"        "$FULL" "exact string replacements"
check "Grep  (ALWAYS use Grep)"           "$FULL" "ALWAYS use Grep"
check "Glob  (pattern matching)"          "$FULL" "Fast file pattern matching"
check "Bash  (Git 段,主对话应含)"        "$FULL" "Committing changes with git"

echo "--- USING_TOOLS 段动态条目(全量应都在)---"
check "Grep 子条"   "$FULL" "use Grep instead of grep"
check "Glob 子条"   "$FULL" "use Glob instead of find"
check "任务管理条"  "$FULL" "TaskCreate tool"

# --- 2) 动态裁剪说明 ---
# 注意:cc-zig 的 --disallowedTools 是【权限层 deny】(拦截执行),
#       不从【API 工具池】移除工具——对齐 Claude Code(deny 规则 gate 执行,不 gate 可见性)。
#       USING_TOOLS 段按"真正发给 API 的工具池"裁剪,故主对话(池齐全)不会去 Grep/Glob 子条。
#       真正会裁剪工具池的是 subagent(filterToolDefs 按 agent 的 tools/disallowedTools 收窄),
#       这条由 L2 测试 tests/component/prompt_tool_coupling_test.zig 覆盖(只读 Explore 的 Bash
#       去 Git 段 + 加只读提醒)。此处不重复(--dump-prompt 只 dump 主对话)。
echo ""
echo "=== 2) 动态裁剪(工具池层)由 L2 测试覆盖 ==="
echo "  ℹ 主对话工具池齐全 → USING_TOOLS 段不裁剪(符合预期)。"
echo "  ℹ subagent 池收窄 + 只读 Bash 描述对齐 → 见 zig build test 的 prompt_tool_coupling_test"

echo ""
echo "=========================================="
echo "  通过: $PASS   失败: $FAIL"
echo "  dump: $FULL"
echo "=========================================="
if [[ $FAIL -eq 0 ]]; then echo "✅ 全过(主对话长描述 + 动态条目全部进 prompt)"; else echo "⚠️  有失败项,看上面 ✗"; fi
