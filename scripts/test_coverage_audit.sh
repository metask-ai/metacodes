#!/usr/bin/env bash
# 声明覆盖审计:把"配置 struct 声明的字段"和"L2 component 测试覆盖的字段"比对,
# 列出声明了但没有 L2 测试的字段(潜在"声明了没接线"风险)。
#
# 用法:scripts/test_coverage_audit.sh
# 退出码:始终 0(只报告,不阻塞);CI 可改为非 0 强制登记。
#
# 设计见 doc/E2E_TESTING.md §七。这不是精确工具——它做字符串匹配启发式,
# 目的是让遗漏"显形",每条要么补 L2,要么在 §3.1 差距矩阵登记。

set -euo pipefail
cd "$(dirname "$0")/.."   # cc-zig/

SRC=src
L2_DIR=tests/component

echo "=================================================================="
echo " 声明覆盖审计 (doc/E2E_TESTING.md §七)"
echo "=================================================================="

# ---- 1. 收集 L2 测试文件里出现的所有标识符(粗粒度:测试名 + 字段名引用)----
if [ -d "$L2_DIR" ]; then
  L2_TEXT=$(cat "$L2_DIR"/*.zig 2>/dev/null || true)
else
  L2_TEXT=""
fi

covered() {
  # 字段名是否在 L2 测试文本中出现(测试名、注释、断言任意位置)
  echo "$L2_TEXT" | grep -q "$1" && return 0 || return 1
}

# ---- 2. 提取 AgentDef 字段(src/agents/def.zig 顶层 struct 字段)----
echo
echo "## AgentDef 字段(src/agents/def.zig)"
echo "   声明 = struct 有字段;覆盖 = L2 测试文本提及。"
echo
AGENT_FIELDS=$(grep -oE "^    [a-z_]+: " "$SRC/agents/def.zig" | sed 's/[: ]//g' | sort -u)
MISSING_COUNT=0
for f in $AGENT_FIELDS; do
  # 跳过纯元数据字段(不影响运行时行为,无需 L2)
  case "$f" in
    name|description|prompt|origin|source_path|color|initial_prompt) continue ;;
  esac
  if covered "$f"; then
    printf "  [L2 ✓] %s\n" "$f"
  else
    printf "  [缺  ] %s\n" "$f"
    MISSING_COUNT=$((MISSING_COUNT+1))
  fi
done

# ---- 3. 提取 Task 工具 schema required 字段 ----
echo
echo "## Task 工具 schema(src/tools.zig)"
echo
TASK_REQUIRED=$(grep -A3 '.name = "Task"' "$SRC/tools.zig" | grep -oE 'required = &\.\{[^}]*\}' | grep -oE '"[a-z_]+"' | tr -d '"' | sort -u || true)
for f in $TASK_REQUIRED; do
  if covered "$f"; then
    printf "  [L2 ✓] %s (required)\n" "$f"
  else
    printf "  [缺  ] %s (required)\n" "$f"
    MISSING_COUNT=$((MISSING_COUNT+1))
  fi
done

# ---- 4. SandboxSettings 字段(L3 真 spawn 已覆盖,这里只列出供参考)----
echo
echo "## SandboxSettings 字段(src/sandbox/config.zig)— L3 真 spawn 覆盖,非 L2"
SB_FIELDS=$(grep -oE "^    [a-z_]+: " "$SRC/sandbox/config.zig" 2>/dev/null | sed 's/[: ]//g' | sort -u || true)
for f in $SB_FIELDS; do
  case "$f" in allocator) continue ;; esac
  printf "  [L3] %s\n" "$f"
done

echo
echo "=================================================================="
echo " 缺 L2 覆盖的字段数: $MISSING_COUNT"
echo "=================================================================="
echo
echo "每条「缺」要么:(a) 补一条 L2 测试,要么 (b) 在 doc/E2E_TESTING.md §3.1"
echo "差距矩阵登记「未实现 + 原因」。不允许沉默。"
echo
echo "已知登记(见 §3.1):background/effort/memory_scope/mcp_servers/isolation"
echo "  = AgentDef 解析了但下游未消费(P2/P3 未实现)。"

exit 0
