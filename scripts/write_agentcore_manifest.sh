#!/bin/sh
set -eu
export LC_ALL=C
export LANG=C

prefix=$1
resolved_target=$2
optimize=$3
strip=$4
zig_exe=$5
target_was_explicit=$6

if [ "$target_was_explicit" != true ]; then
    echo "AgentCore release bundle requires explicit -Dtarget=aarch64-macos.13.0" >&2
    exit 1
fi
case "$resolved_target" in
    aarch64-macos.13.0*) ;;
    *)
        echo "AgentCore v1 bundle target must be aarch64-macos.13.0 (resolved: $resolved_target)" >&2
        exit 1
        ;;
esac

lib="$prefix/lib/libmetacodes_agentcore.a"
header="$prefix/include/metacodes_agentcore.h"
sdk="$prefix/sdk/metacodes_agentcore.zig"
protocol="$prefix/sdk/metacodes_agentcore_protocol.zig"
types="$prefix/sdk/metacodes_agentcore_types.zig"
manifest="$prefix/manifest.json"
manifest_tmp="$manifest.tmp.$$"
trap 'rm -f "$manifest_tmp"' EXIT HUP INT TERM

for file in "$lib" "$header" "$sdk" "$protocol" "$types"; do
    if [ ! -f "$file" ]; then
        echo "AgentCore manifest: missing installed file: $file" >&2
        exit 1
    fi
done

commit=$(git rev-parse HEAD)
commit_short=$(printf '%s' "$commit" | cut -c1-12)
zig_version=$("$zig_exe" version)
dirty=false
source_digest=""
repo_root=$(git rev-parse --show-toplevel)
repo_prefix=$(git rev-parse --show-prefix)
source_pathspec=":(top)${repo_prefix}**"
prefix_abs=$(cd "$prefix" && pwd -P)
exclude_pathspec=""
case "$prefix_abs/" in
    "$repo_root/"*)
        prefix_relative=${prefix_abs#"$repo_root"/}
        exclude_pathspec=":(top,exclude)$prefix_relative/**"
        ;;
esac

git_status() {
    if [ -n "$exclude_pathspec" ]; then
        git status --porcelain --untracked-files=normal -- "$source_pathspec" "$exclude_pathspec"
    else
        git status --porcelain --untracked-files=normal -- "$source_pathspec"
    fi
}

if [ -n "$(git_status)" ]; then
    dirty=true
    source_digest=$(
        {
            if [ -n "$exclude_pathspec" ]; then
                git diff HEAD --binary -- "$source_pathspec" "$exclude_pathspec"
            else
                git diff HEAD --binary -- "$source_pathspec"
            fi
            if [ -n "$exclude_pathspec" ]; then
                git ls-files --others --exclude-standard -- "$source_pathspec" "$exclude_pathspec"
            else
                git ls-files --others --exclude-standard -- "$source_pathspec"
            fi | LC_ALL=C sort | while IFS= read -r file; do
                printf '%s\n' "$file"
                shasum -a 256 "$file"
            done
        } | shasum -a 256 | awk '{print $1}'
    )
fi

version="0.0.0-dev+$commit_short"
if [ "$dirty" = true ]; then
    version="$version-dirty.$(printf '%s' "$source_digest" | cut -c1-12)"
fi

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

cat > "$manifest_tmp" <<EOF
{
  "schema_version": 1,
  "name": "metacodes-agentcore",
  "version": "$version",
  "source": {
    "commit": "$commit",
    "dirty": $dirty,
    "dirty_source_sha256": "$source_digest"
  },
  "toolchain": {"zig_version": "$zig_version"},
  "build": {
    "resolved_target": "$resolved_target",
    "architecture": "aarch64",
    "os": "macos",
    "macos_deployment_target": "13.0",
    "optimize": "$optimize",
    "strip": $strip
  },
  "contract": {
    "binary_abi_version": 1,
    "required_system_link_inputs": ["libc"],
    "ui_request_mode": "synchronous"
  },
  "files": {
    "lib/libmetacodes_agentcore.a": {"sha256": "$(sha "$lib")"},
    "include/metacodes_agentcore.h": {"sha256": "$(sha "$header")"},
    "sdk/metacodes_agentcore.zig": {"sha256": "$(sha "$sdk")"},
    "sdk/metacodes_agentcore_protocol.zig": {"sha256": "$(sha "$protocol")"},
    "sdk/metacodes_agentcore_types.zig": {"sha256": "$(sha "$types")"}
  }
}
EOF
mv "$manifest_tmp" "$manifest"
trap - EXIT HUP INT TERM
