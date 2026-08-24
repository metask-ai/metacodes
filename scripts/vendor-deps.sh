#!/usr/bin/env bash
# 重新 vendor highlight-zig 源码快照到 lib/。
#
# 设计:这些依赖更新频度低,故**不用 git submodule**(避免其他开发者 clone 后还要
# `submodule update --init` 的摩擦)。改为在 lib/ 里 commit 一份**源码快照**——plain
# `git clone` + `zig build` 直接能跑。TinyKG 不属于源码 vendoring；它由
# 维护者以显式路径 + SHA-256 提供，并通过 tinykg:stage 验证。
# 各依赖仍有独立上游 repo(自身开发用),本脚本从上游拉最新源码覆盖进 lib/。
#
# 用法:
#   scripts/vendor-deps.sh              # 从 github 上游更新 highlight-zig
#   scripts/vendor-deps.sh highlight    # 只 highlight-zig
#   HL_SRC=~/prj/hl-zig scripts/vendor-deps.sh   # 用本地源码目录代替 clone
#
# 更新后务必:① zig build 验证 ② commit lib/highlight-zig 改动。
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WHICH="${1:-highlight}"

if [[ "$WHICH" != "all" && "$WHICH" != "highlight" ]]; then
  echo "error: 仅支持 highlight；TinyKG 请用 zig build tinykg:stage -Dtinykg-bin=... -Dtinykg-sha256=..." >&2
  exit 2
fi

vendor_one() {
  local name="$1" url="$2" src_override="$3" dest="$4" subpath="$5"
  local tmp="" srcdir=""
  if [ -n "$src_override" ]; then
    [ -d "$src_override" ] || { echo "error: $src_override 不存在" >&2; exit 1; }
    srcdir="$src_override"
    echo "[$name] 用本地源: $srcdir"
  else
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    echo "[$name] clone $url ..."
    git clone -q --depth 1 "$url" "$tmp/repo"
    srcdir="$tmp/repo"
  fi
  local rev; rev="$(git -C "$srcdir" rev-parse HEAD 2>/dev/null || echo unknown)"

  rm -rf "$dest"
  mkdir -p "$dest"
  # 只拷需要的子路径(subpath 为空=拷整个源目录白名单)。
  if [ -n "$subpath" ]; then
    cp -R "$srcdir/$subpath" "$dest/$(basename "$subpath")"
  else
    for f in src lib.zig LICENSE README.md build.zig; do
      [ -e "$srcdir/$f" ] && cp -R "$srcdir/$f" "$dest/" || true
    done
  fi
  cat > "$dest/SOURCE.txt" <<EOF
vendored from: $url
commit: $rev
note: 源码快照(非 submodule)。更新用 scripts/vendor-deps.sh。
EOF
  echo "[$name] vendored @ ${rev:0:12} → $dest"
}

if [ "$WHICH" = all ] || [ "$WHICH" = highlight ]; then
  vendor_one highlight-zig "https://github.com/shuzuan-org/highlight-zig.git" "${HL_SRC:-}" "$HERE/lib/highlight-zig" ""
fi
echo "完成。跑 'zig build' 验证,再 commit lib/ 改动。"
