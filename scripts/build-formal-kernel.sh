#!/usr/bin/env bash
set -euo pipefail

# Build the independently shipped Lean governance kernel and prove that the
# artifact actually starts on the host.  A successful `lake build` is not a
# sufficient macOS smoke test: Lean 4.14's bundled ld64.lld emits a
# __DATA_CONST segment that macOS 26 dyld rejects.  Darwin therefore relinks
# Lake's exported objects with Apple clang; other hosts retain Lake's native
# executable.

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
lean_dir="$repo_dir/control-plane/lean"
output=${1:-"$repo_dir/zig-out/libexec/metacodes/metacodes-formal-kernel"}
manifest=${2:-"$output.provenance.json"}
lake=${LAKE:-"$HOME/.elan/bin/lake"}

if [[ ! -x "$lake" ]]; then
  echo "build-formal-kernel: lake not found: $lake" >&2
  exit 1
fi

mkdir -p "$(dirname "$output")" "$(dirname "$manifest")"

(
  cd "$lean_dir"
  "$lake" build metacodes-formal-kernel
)

# Lean permits declarations containing `sorry` to compile by inserting
# `sorryAx`.  Shipping a theorem-bearing checker therefore requires an axiom
# audit, not merely a green `lake build`.  The current proof uses only Lean's
# expected quotient/propositional extensionality axioms; any expansion of this
# exact trust set is a release-blocking review event.
axiom_audit=$(cd "$lean_dir" && "$lake" env lean FormalAxiomAudit.lean 2>&1)
expected_axioms="'MetaCodesControl.FormalKernel.safeMigration_sound' depends on axioms: [propext, Quot.sound]"
if [[ "$axiom_audit" != "$expected_axioms" ]]; then
  echo "build-formal-kernel: unexpected soundness theorem axiom set" >&2
  printf '%s\n' "$axiom_audit" >&2
  exit 1
fi

host_os=$(uname -s)
linker="lake-default"
if [[ "$host_os" == "Darwin" ]]; then
  lean_prefix=$(cd "$lean_dir" && "$lake" env lean --print-prefix)
  leanc="$lean_prefix/bin/leanc"
  if [[ ! -x "$leanc" || ! -x /usr/bin/clang ]]; then
    echo "build-formal-kernel: Darwin relink requires leanc and /usr/bin/clang" >&2
    exit 1
  fi
  link_args=()
  for library_dir in /opt/homebrew/lib /usr/local/lib; do
    if [[ -d "$library_dir" ]]; then
      link_args+=("-L$library_dir")
    fi
  done
  tmp_binary=$(mktemp "${TMPDIR:-/tmp}/metacodes-formal-kernel.XXXXXX")
  trap 'rm -f "$tmp_binary"' EXIT
  LEAN_CC=/usr/bin/clang "$leanc" -o "$tmp_binary" \
    "$lean_dir/.lake/build/ir/FormalMain.c.o.export" \
    "$lean_dir/.lake/build/ir/MetaCodesControl/FormalKernel.c.o.export" \
    "${link_args[@]}"
  data_const_flags=$(otool -l "$tmp_binary" | awk '
    $1 == "segname" && $2 == "__DATA_CONST" { in_segment = 1; next }
    in_segment && $1 == "flags" { print $2; exit }
  ')
  if [[ "$data_const_flags" != "0x10" ]]; then
    echo "build-formal-kernel: unsafe __DATA_CONST flags: ${data_const_flags:-missing}" >&2
    exit 1
  fi
  install -m 0755 "$tmp_binary" "$output"
  linker="apple-clang"
else
  install -m 0755 "$lean_dir/.lake/build/bin/metacodes-formal-kernel" "$output"
fi

hex_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
hex_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
hex_c=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
hex_d=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
request_prefix="{\"schema_version\":\"metacodes-formal-request-v1\",\"request_id\":\"$hex_a\",\"operation\":\"task_audit\",\"proposal_sha256\":\"$hex_b\",\"snapshot_sha256\":\"$hex_c\",\"snapshot_revision\":\"$hex_d\",\"expected_checker_version\":\"metacodes-formal-kernel-v1\",\"facts\":{"
admit_request="${request_prefix}\"schema_supported\":true,\"snapshot_bounded\":true,\"task_count\":1,\"open_count\":1,\"claimed_count\":0,\"completed_count\":0,\"failed_count\":0,\"claimed_with_owner_count\":0,\"reachable_task_count\":1,\"terminal_with_evidence_count\":0,\"invalid_reference_count\":0,\"truncated\":false,\"proposal_bound\":true,\"preserves_tasks\":true,\"preserves_evidence\":true,\"preserves_recovery\":true,\"preserves_schema\":true,\"contradiction_safe\":true,\"reversible\":true}}"
block_request="${request_prefix}\"schema_supported\":true,\"snapshot_bounded\":true,\"task_count\":1,\"open_count\":0,\"claimed_count\":1,\"completed_count\":0,\"failed_count\":0,\"claimed_with_owner_count\":0,\"reachable_task_count\":1,\"terminal_with_evidence_count\":0,\"invalid_reference_count\":0,\"truncated\":false,\"proposal_bound\":true,\"preserves_tasks\":true,\"preserves_evidence\":true,\"preserves_recovery\":true,\"preserves_schema\":true,\"contradiction_safe\":true,\"reversible\":true}}"

admit_verdict=$(printf '%s' "$admit_request" | "$output")
if [[ "$admit_verdict" != *'"decision":"admit"'* ]]; then
  echo "build-formal-kernel: native admit smoke failed" >&2
  exit 1
fi
block_verdict=$(printf '%s' "$block_request" | "$output")
if [[ "$block_verdict" != *'"decision":"block"'* || "$block_verdict" != *'"claim_without_owner"'* ]]; then
  echo "build-formal-kernel: native block smoke failed" >&2
  exit 1
fi
set +e
printf '%s\n' "$admit_request" | "$output" >/dev/null 2>&1
trailing_status=$?
set -e
if [[ "$trailing_status" -ne 64 ]]; then
  echo "build-formal-kernel: canonical protocol accepted trailing newline" >&2
  exit 1
fi

if command -v shasum >/dev/null 2>&1; then
  binary_sha256=$(shasum -a 256 "$output" | awk '{print $1}')
  kernel_source_sha256=$(shasum -a 256 "$lean_dir/MetaCodesControl/FormalKernel.lean" | awk '{print $1}')
  main_source_sha256=$(shasum -a 256 "$lean_dir/FormalMain.lean" | awk '{print $1}')
  axiom_audit_source_sha256=$(shasum -a 256 "$lean_dir/FormalAxiomAudit.lean" | awk '{print $1}')
else
  binary_sha256=$(sha256sum "$output" | awk '{print $1}')
  kernel_source_sha256=$(sha256sum "$lean_dir/MetaCodesControl/FormalKernel.lean" | awk '{print $1}')
  main_source_sha256=$(sha256sum "$lean_dir/FormalMain.lean" | awk '{print $1}')
  axiom_audit_source_sha256=$(sha256sum "$lean_dir/FormalAxiomAudit.lean" | awk '{print $1}')
fi
if [[ "$host_os" == "Darwin" ]]; then
  binary_bytes=$(stat -f '%z' "$output")
else
  binary_bytes=$(stat -c '%s' "$output")
fi
lean_version=$(cd "$lean_dir" && "$lake" env lean --version | tr -d '\n')
host_arch=$(uname -m)
built_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

printf '%s\n' \
  "{\"schema_version\":\"metacodes-formal-artifact-v1\",\"checker_version\":\"metacodes-formal-kernel-v1\",\"request_schema\":\"metacodes-formal-request-v1\",\"verdict_schema\":\"metacodes-formal-verdict-v1\",\"binary_sha256\":\"$binary_sha256\",\"binary_bytes\":$binary_bytes,\"kernel_source_sha256\":\"$kernel_source_sha256\",\"main_source_sha256\":\"$main_source_sha256\",\"axiom_audit_source_sha256\":\"$axiom_audit_source_sha256\",\"axiom_policy\":\"propext,Quot.sound\",\"axiom_audit\":\"passed\",\"host_os\":\"$host_os\",\"host_arch\":\"$host_arch\",\"linker\":\"$linker\",\"lean_version\":\"$lean_version\",\"native_smoke\":\"passed\",\"built_at_utc\":\"$built_at_utc\"}" \
  >"$manifest"

echo "formal kernel: $output"
echo "sha256: $binary_sha256"
echo "bytes: $binary_bytes"
echo "provenance: $manifest"
