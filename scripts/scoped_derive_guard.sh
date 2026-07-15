#!/usr/bin/env bash
# U4 grep-guard(Linus 精确性要求):PermissionContext 的**裸值解引用拷贝**必须走
# scopedDerive() 单 seam(它 null 掉 event_sink,scoped ctx 的 mode override 绝不 emit 到
# session sink)。手工枚举 N 个 null 点已被证伪(草案漏 4 个:agent_loop 631/988 + agent 163/190),
# 故靠"结构上只有 1 个 null 点 + 本 guard"兜底。
#
# **精确区分两类(Linus 提醒,避免假信心)**:
#   违规  = 裸值解引用拷贝  `= <ident>.*`（复制整个 PermissionContext 值 → 带走 sink 指针）
#   合法  = 指针共享         `= p.permission_ctx`（有意共享 lead 的 ctx，task#15 债，不误报）
# 只匹配前者。允许的唯一值拷贝 = scopedDerive 内部的 `var derived = self.*`。
set -euo pipefail
cd "$(dirname "$0")/.."

# 匹配值解引用拷贝 `= <路径>.*`，其中源路径以 permission_ctx 结尾（含 app./self./裸）
# 或恰为 perm。排除测试 + scopedDerive 内部的 `var derived = self.*`（源是 self 不是
# permission_ctx，天然不匹配）。红灯已验:`= app.permission_ctx.*` 会被抓（此前窄模式漏）。
hits=$(grep -rnE '=[[:space:]]*([A-Za-z0-9_]+\.)*permission_ctx\.\*|=[[:space:]]*perm\.\*' src/ | grep -v '_test.zig' || true)

# scopedDerive 内部的 self.* 不是 permission_ctx/perm 命名，天然不匹配上面的模式，
# 无需特判。任何命中都是"未走 seam 的裸值拷贝" = 违规。
if [ -n "$hits" ]; then
    echo "FAIL: PermissionContext 裸值拷贝未走 scopedDerive():"
    echo "$hits"
    echo ""
    echo "改法:把 \`= permission_ctx.*\` / \`= perm.*\` 换成 \`permission_ctx.scopedDerive(mode_override)\`。"
    exit 1
fi
echo "OK: 无裸 PermissionContext 值拷贝(全走 scopedDerive 单 seam)。"
