#!/usr/bin/env bash
# download-tree-sitter.sh —— 拉取 tree-sitter runtime + 各语言 grammar 的生成 C 源,
# 拷进 vendor/tree-sitter/ 并锁定 tag。幂等:重跑覆盖 vendor 内容。
#
# 这些源(runtime *.c + grammar parser.c/scanner.c)是生成且稳定的,**commit 进 git**,
# 所以构建/CI 不依赖本脚本——脚本只用于首次拉取或升级 grammar 版本。
#
# 单一真理源:语言清单也在 vendor/tree-sitter/grammars.zig(构建)+ src/treesitter/registry.zig
# (语义)。加语言时这三处要同步(ts.zig 有 comptime 断言守卫漏改)。
#
# 用法:  bash scripts/download-tree-sitter.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DST="$ROOT/vendor/tree-sitter"
HLDST="$ROOT/src/treesitter/queries/highlights"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- 锁定版本 -------------------------------------------------------------
TS_CORE_TAG="v0.26.9"     # runtime (ABI 13..15)
clone() { git clone --quiet --depth 1 --branch "$2" "https://github.com/$1" "$TMP/$3"; }

echo ">> cloning runtime + grammars (shallow, pinned)…"
clone tree-sitter/tree-sitter                  "$TS_CORE_TAG"  core

# 完整支持(grammar+highlights+symbols)。symbols 查询手写在 src/treesitter/queries/<lang>.scm。
clone tree-sitter-grammars/tree-sitter-zig     v1.1.2   zig
clone tree-sitter/tree-sitter-typescript       v0.23.2  typescript
clone tree-sitter/tree-sitter-python           v0.23.6  python
clone tree-sitter/tree-sitter-c                v0.24.1  c
clone tree-sitter/tree-sitter-bash             v0.23.3  bash
clone tree-sitter/tree-sitter-go               v0.25.0  go
clone tree-sitter/tree-sitter-javascript       v0.25.0  javascript
clone tree-sitter/tree-sitter-java             v0.23.5  java
clone tree-sitter/tree-sitter-rust             v0.24.2  rust
clone tree-sitter/tree-sitter-cpp              v0.23.4  cpp
clone tree-sitter/tree-sitter-ruby             v0.23.1  ruby
clone tree-sitter/tree-sitter-c-sharp          v0.23.5  csharp
# 仅高亮(grammar+highlights,无 symbols 查询)
clone tree-sitter/tree-sitter-json             v0.24.8  json
clone tree-sitter-grammars/tree-sitter-yaml    v0.7.2   yaml
clone tree-sitter-grammars/tree-sitter-toml    v0.7.0   toml
clone tree-sitter/tree-sitter-html             v0.23.2  html
clone tree-sitter/tree-sitter-css              v0.25.0  css
clone tree-sitter-grammars/tree-sitter-markdown v0.5.3  markdown

echo ">> staging runtime…"
rm -rf "$DST"
mkdir -p "$DST/runtime" "$HLDST"
cp -R "$TMP/core/lib/include" "$DST/runtime/include"
cp -R "$TMP/core/lib/src"     "$DST/runtime/src"

# grammar 拷贝:parser.c(必有)+ scanner.c(可选)+ 额外 .c/.h + src/tree_sitter/ 头。
# srcdir 默认 <name>/src;部分 grammar src 在子目录(见下显式调用)。
copy_grammar() { # srcdir  destname
  local src="$1" name="$2"
  mkdir -p "$DST/grammars/$name/src"
  cp "$src/parser.c" "$DST/grammars/$name/src/parser.c"
  [ -f "$src/scanner.c" ] && cp "$src/scanner.c" "$DST/grammars/$name/src/scanner.c"
  if [ -f "$src/scanner.cc" ]; then
    echo "!! WARNING: $name ships a C++ scanner (scanner.cc) — build.zig needs link_libcpp." >&2
    cp "$src/scanner.cc" "$DST/grammars/$name/src/scanner.cc"
  fi
  # 额外随 scanner 编/被 include 的 .c/.h(yaml schema.*.c、html tag.h 等)
  find "$src" -maxdepth 1 -type f \( -name '*.c' -o -name '*.h' \) \
    ! -name parser.c ! -name scanner.c -exec cp {} "$DST/grammars/$name/src/" \;
  cp -R "$src/tree_sitter" "$DST/grammars/$name/src/tree_sitter"
}

# highlights:拷 queries/highlights.scm → src/treesitter/queries/highlights/<name>.scm。
copy_highlights() { # repodir  destname
  cp "$TMP/$1/queries/highlights.scm" "$HLDST/$2.scm"
}

echo ">> staging grammars…"
copy_grammar "$TMP/zig/src"                    zig
copy_grammar "$TMP/typescript/typescript/src"  typescript/typescript
copy_grammar "$TMP/typescript/tsx/src"         typescript/tsx
copy_grammar "$TMP/python/src"                 python
copy_grammar "$TMP/c/src"                      c
copy_grammar "$TMP/bash/src"                   bash
copy_grammar "$TMP/go/src"                     go
copy_grammar "$TMP/javascript/src"             javascript
copy_grammar "$TMP/java/src"                   java
copy_grammar "$TMP/rust/src"                   rust
copy_grammar "$TMP/cpp/src"                    cpp
copy_grammar "$TMP/ruby/src"                   ruby
copy_grammar "$TMP/csharp/src"                 csharp
copy_grammar "$TMP/json/src"                   json
copy_grammar "$TMP/yaml/src"                   yaml
copy_grammar "$TMP/toml/src"                   toml
copy_grammar "$TMP/html/src"                   html
copy_grammar "$TMP/css/src"                    css
# markdown:块级 grammar 在 tree-sitter-markdown/ 子目录(行内 grammar 暂不 vendor)。
copy_grammar "$TMP/markdown/tree-sitter-markdown/src" markdown

# typescript/tsx 的 scanner.c #include "../../common/scanner.h"。保留相对结构。
mkdir -p "$DST/grammars/typescript/common"
cp "$TMP/typescript/common/scanner.h" "$DST/grammars/typescript/common/scanner.h"

echo ">> staging highlights…"
# typescript highlights 是 JS 增量(inherits ecma),需拼 JS base + TS delta。
cp "$TMP/zig/queries/highlights.scm"     "$HLDST/zig.scm"
cp "$TMP/python/queries/highlights.scm"  "$HLDST/python.scm"
cp "$TMP/c/queries/highlights.scm"       "$HLDST/c.scm"
cp "$TMP/bash/queries/highlights.scm"    "$HLDST/bash.scm"
cat "$TMP/javascript/queries/highlights.scm" "$TMP/typescript/queries/highlights.scm" > "$HLDST/typescript.scm"
for l in go javascript java rust cpp ruby csharp json yaml toml html css; do
  copy_highlights "$l" "$l"
done
cp "$TMP/markdown/tree-sitter-markdown/queries/highlights.scm" "$HLDST/markdown.scm"

# ---- provenance -----------------------------------------------------------
cat > "$DST/VERSIONS.txt" <<EOF
# tree-sitter vendored sources — pinned versions
# 由 scripts/download-tree-sitter.sh 生成。升级走脚本,勿手改源。
# 语言清单单一真理源:vendor/tree-sitter/grammars.zig + src/treesitter/registry.zig
#
# runtime  tree-sitter/tree-sitter                  $TS_CORE_TAG  (ABI 13..15)
#
# 完整支持(grammar+highlights+symbols 查询):
#   zig      tree-sitter-grammars/tree-sitter-zig     v1.1.2
#   ts/tsx   tree-sitter/tree-sitter-typescript       v0.23.2
#   python   tree-sitter/tree-sitter-python           v0.23.6
#   c        tree-sitter/tree-sitter-c                v0.24.1
#   bash     tree-sitter/tree-sitter-bash             v0.23.3
#   go       tree-sitter/tree-sitter-go               v0.25.0
#   javascript tree-sitter/tree-sitter-javascript     v0.25.0
#   java     tree-sitter/tree-sitter-java             v0.23.5
#   rust     tree-sitter/tree-sitter-rust             v0.24.2
#   cpp      tree-sitter/tree-sitter-cpp              v0.23.4  (scanner 纯 C,无需 libcpp)
#   ruby     tree-sitter/tree-sitter-ruby             v0.23.1
#   csharp   tree-sitter/tree-sitter-c-sharp          v0.23.5
#
# 仅高亮(grammar+highlights,无 symbols 查询 → CodeMap/FindSymbol fallback Grep):
#   json     tree-sitter/tree-sitter-json             v0.24.8
#   yaml     tree-sitter-grammars/tree-sitter-yaml    v0.7.2   (含 schema.{core,json,legacy}.c)
#   toml     tree-sitter-grammars/tree-sitter-toml    v0.7.0
#   html     tree-sitter/tree-sitter-html             v0.23.2  (含 tag.h)
#   css      tree-sitter/tree-sitter-css              v0.25.0
#   markdown tree-sitter-grammars/tree-sitter-markdown v0.5.3  (仅块级,行内未 vendor)
#
# License: MIT (runtime + 全部 grammar)。
EOF

echo ">> scanner inventory:"
find "$DST/grammars" -name 'scanner.*' | sed 's|.*/grammars/||' | sort | sed 's/^/   /'

echo ">> done. vendored into $DST"
echo "   next: zig build && zig build test:ts"
