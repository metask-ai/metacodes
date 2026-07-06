#!/usr/bin/env bash
# 构建并 vendor tinykg 二进制(KG 记忆/计划/DAG 子系统的外部引擎)。
#
# 版本 pin 纪律(设计 KG_DESIGN v3 §2.7):
#   - 二进制必须与 store 格式版本锁定(storage_format_version=2);
#   - 每次 vendor 更新都写 VERSION.txt(commit + 格式版本),KgClient 版本门警告引用它;
#   - 不要混用不同版本二进制打同一个 store(实证:格式 skew 直接 FileNotFound)。
#
# 用法:scripts/build-tinykg.sh [tinykg 源码目录,默认 ~/prj/tinykg]
set -euo pipefail

SRC="${1:-$HOME/prj/tinykg}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$HERE/vendor/tinykg"

[ -f "$SRC/build.zig" ] || { echo "error: $SRC 不是 tinykg 源码目录" >&2; exit 1; }
command -v zig >/dev/null || { echo "error: zig 不在 PATH" >&2; exit 1; }

COMMIT=$(git -C "$SRC" rev-parse HEAD)
DIRTY=$(git -C "$SRC" status --porcelain | grep -v '^??' | wc -l | tr -d ' ')
[ "$DIRTY" = "0" ] || echo "warn: tinykg 工作区有未提交改动($DIRTY 个文件),vendor 的二进制将不可复现" >&2

echo "building tinykg @ ${COMMIT:0:12} (ReleaseSafe)..."
(cd "$SRC" && zig build -Doptimize=ReleaseSafe)

mkdir -p "$VENDOR"
cp "$SRC/zig-out/bin/tinykg" "$VENDOR/tinykg"

# 探格式版本:临时 store init 后读 store-info。
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
"$VENDOR/tinykg" init "$TMP/probe.kg" >/dev/null
FMT=$("$VENDOR/tinykg" store-info "$TMP/probe.kg" | sed -n 's/^storage_format_version=//p')

cat > "$VENDOR/VERSION.txt" <<EOF
tinykg_commit=$COMMIT
tinykg_dirty=$DIRTY
storage_format_version=$FMT
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
zig=$(zig version)
EOF

echo "vendored: $VENDOR/tinykg (storage_format_version=$FMT)"
cat "$VENDOR/VERSION.txt"
