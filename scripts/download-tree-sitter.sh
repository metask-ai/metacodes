#!/usr/bin/env bash
# download-tree-sitter.sh —— 拉取 tree-sitter runtime + 各语言 grammar 的生成 C 源,
# 拷进 vendor/tree-sitter/ 并锁定 tag。幂等:重跑覆盖 vendor 内容。
#
# 这些源(runtime *.c + grammar parser.c/scanner.c)是生成且稳定的,**commit 进 git**,
# 所以构建/CI 不依赖本脚本——脚本只用于首次拉取或升级 grammar 版本。
#
# 用法:  bash scripts/download-tree-sitter.sh
#
# 升级某 grammar:改下面对应 *_TAG,重跑,跑测试,更新 VERSIONS.txt。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DST="$ROOT/vendor/tree-sitter"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- 锁定版本(ABI 兼容性见 VERSIONS.txt)----------------------------------
# core v0.26.x 支持 LANGUAGE_VERSION 13..15;下列 grammar 均在该区间。
TS_CORE_TAG="v0.26.9"
ZIG_TAG="v1.1.2"          # tree-sitter-grammars/tree-sitter-zig (ABI 14)
TS_TS_TAG="v0.23.2"       # tree-sitter/tree-sitter-typescript (typescript + tsx)
PY_TAG="v0.23.6"          # tree-sitter/tree-sitter-python
C_TAG="v0.24.1"           # tree-sitter/tree-sitter-c
BASH_TAG="v0.23.3"        # tree-sitter/tree-sitter-bash

clone() { # repo  tag  destdir
  git clone --quiet --depth 1 --branch "$2" "https://github.com/$1" "$TMP/$3"
}

echo ">> cloning (shallow, pinned tags)…"
clone tree-sitter/tree-sitter             "$TS_CORE_TAG" core
clone tree-sitter-grammars/tree-sitter-zig "$ZIG_TAG"     zig
clone tree-sitter/tree-sitter-typescript  "$TS_TS_TAG"   typescript
clone tree-sitter/tree-sitter-python      "$PY_TAG"      python
clone tree-sitter/tree-sitter-c           "$C_TAG"       c
clone tree-sitter/tree-sitter-bash        "$BASH_TAG"    bash

echo ">> staging runtime…"
rm -rf "$DST"
mkdir -p "$DST/runtime"
cp -R "$TMP/core/lib/include" "$DST/runtime/include"
cp -R "$TMP/core/lib/src"     "$DST/runtime/src"

# grammar 拷贝:parser.c(必有) + scanner.c(可选) + src/tree_sitter/(parser.h 等头)
copy_grammar() { # srcroot  destname
  local src="$1" name="$2"
  mkdir -p "$DST/grammars/$name/src"
  cp "$src/src/parser.c" "$DST/grammars/$name/src/parser.c"
  if [ -f "$src/src/scanner.c" ]; then
    cp "$src/src/scanner.c" "$DST/grammars/$name/src/scanner.c"
  fi
  if [ -f "$src/src/scanner.cc" ]; then
    echo "!! WARNING: $name ships a C++ scanner (scanner.cc) — build.zig needs link_libcpp." >&2
    cp "$src/src/scanner.cc" "$DST/grammars/$name/src/scanner.cc"
  fi
  cp -R "$src/src/tree_sitter" "$DST/grammars/$name/src/tree_sitter"
}

echo ">> staging grammars…"
copy_grammar "$TMP/zig"                   zig
copy_grammar "$TMP/typescript/typescript" typescript/typescript
copy_grammar "$TMP/typescript/tsx"        typescript/tsx
copy_grammar "$TMP/python"                python
copy_grammar "$TMP/c"                     c
copy_grammar "$TMP/bash"                  bash

# typescript/tsx 的 scanner.c #include "../../common/scanner.h"(相对 src/ → repo 根
# common/)。vendored 布局保留该相对结构,故把共享头放到 grammars/typescript/common/。
mkdir -p "$DST/grammars/typescript/common"
cp "$TMP/typescript/common/scanner.h" "$DST/grammars/typescript/common/scanner.h"

# ---- highlights.scm(语法高亮查询,供 diff 着色)---------------------------
# 拷各 grammar 的 queries/highlights.scm → src/treesitter/queries/highlights/<lang>.scm
# (放 src 下便于 @embedFile)。tsx 复用 typescript。
# typescript 的 highlights 是 JS 增量(; inherits: ecma),需拼 JS base + TS delta。
HLDST="$ROOT/src/treesitter/queries/highlights"
mkdir -p "$HLDST"
git clone --quiet --depth 1 https://github.com/tree-sitter/tree-sitter-javascript "$TMP/js"
cp "$TMP/zig/queries/highlights.scm"    "$HLDST/zig.scm"
cp "$TMP/python/queries/highlights.scm" "$HLDST/python.scm"
cp "$TMP/c/queries/highlights.scm"      "$HLDST/c.scm"
cp "$TMP/bash/queries/highlights.scm"   "$HLDST/bash.scm"
cat "$TMP/js/queries/highlights.scm" "$TMP/typescript/queries/highlights.scm" > "$HLDST/typescript.scm"

# ---- 记录 provenance ------------------------------------------------------
cat > "$DST/VERSIONS.txt" <<EOF
# tree-sitter vendored sources — pinned versions
# 由 scripts/download-tree-sitter.sh 生成。升级走脚本,勿手改源。
#
# runtime  tree-sitter/tree-sitter                  $TS_CORE_TAG  (ABI 13..15)
# zig      tree-sitter-grammars/tree-sitter-zig     $ZIG_TAG      (ABI 14)
# ts/tsx   tree-sitter/tree-sitter-typescript       $TS_TS_TAG
# python   tree-sitter/tree-sitter-python           $PY_TAG
# c        tree-sitter/tree-sitter-c                $C_TAG
# bash     tree-sitter/tree-sitter-bash             $BASH_TAG
#
# License: MIT (runtime + 全部 grammar)。
EOF

echo ">> scanner inventory:"
find "$DST/grammars" -name 'scanner.*' -exec echo "   {}" \;

echo ">> done. vendored into $DST"
echo "   next: zig build && zig build test"