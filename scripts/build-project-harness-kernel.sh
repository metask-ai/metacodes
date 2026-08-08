#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
lean_dir="$repo_dir/control-plane/lean"
output=${1:-"$repo_dir/zig-out/libexec/metacodes/metacodes-project-kernel"}
manifest=${2:-"$output.provenance.json"}
lake=${LAKE:-"$HOME/.elan/bin/lake"}

if [[ ! -x "$lake" ]]; then
  echo "build-project-harness-kernel: lake not found: $lake" >&2
  exit 1
fi
mkdir -p "$(dirname "$output")" "$(dirname "$manifest")"

host_os=$(uname -s)
(
  cd "$lean_dir"
  if [[ "$host_os" == "Darwin" ]]; then
    "$lake" build ProjectHarnessMain:c.o MetaCodesControl.ProjectHarness:c.o \
      MetaCodesControl.ProjectRule:c.o MetaCodesControl.FormalKernel:c.o
  else
    "$lake" build metacodes-project-kernel
  fi
)

axiom_audit=$(cd "$lean_dir" && "$lake" env lean ProjectHarnessAxiomAudit.lean 2>&1)
expected_axioms="'MetaCodesControl.ProjectHarness.safePromotion_sound' depends on axioms: [propext]
'MetaCodesControl.ProjectHarness.correction_promotion_requires_receipt' depends on axioms: [propext]
'MetaCodesControl.ProjectHarness.denied_predecision_blocks' depends on axioms: [propext]
'MetaCodesControl.ProjectHarness.decideBatch_sound' does not depend on any axioms"
if [[ "$axiom_audit" != "$expected_axioms" ]]; then
  echo "build-project-harness-kernel: unexpected axiom set" >&2
  printf '%s\n' "$axiom_audit" >&2
  exit 1
fi

linker="lake-default"
if [[ "$host_os" == "Darwin" ]]; then
  lean_prefix=$(cd "$lean_dir" && "$lake" env lean --print-prefix)
  leanc="$lean_prefix/bin/leanc"
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/metacodes-project-kernel.XXXXXX")
  mkdir "$tmp_dir/first" "$tmp_dir/second"
  trap 'rm -rf "$tmp_dir"' EXIT
  link_args=()
  for library_dir in /opt/homebrew/lib /usr/local/lib; do
    [[ -d "$library_dir" ]] && link_args+=("-L$library_dir")
  done
  for candidate in "$tmp_dir/first/metacodes-project-kernel" "$tmp_dir/second/metacodes-project-kernel"; do
    LEAN_CC=/usr/bin/clang "$leanc" -o "$candidate" \
      "$lean_dir/.lake/build/ir/ProjectHarnessMain.c.o.export" \
      "$lean_dir/.lake/build/ir/MetaCodesControl/ProjectHarness.c.o.export" \
      "$lean_dir/.lake/build/ir/MetaCodesControl/ProjectRule.c.o.export" \
      "$lean_dir/.lake/build/ir/MetaCodesControl/FormalKernel.c.o.export" \
      "${link_args[@]}"
  done
  cmp -s "$tmp_dir/first/metacodes-project-kernel" "$tmp_dir/second/metacodes-project-kernel" || {
    echo "build-project-harness-kernel: non-reproducible native link" >&2
    exit 1
  }
  install -m 0755 "$tmp_dir/first/metacodes-project-kernel" "$output"
  linker="apple-clang"
else
  install -m 0755 "$lean_dir/.lake/build/bin/metacodes-project-kernel" "$output"
fi

hex_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
hex_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
hex_c=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
hex_d=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
prefix="{\"schema_version\":\"metacodes-project-harness-request-v1\",\"request_id\":\"$hex_a\",\"operation\":\"pre_decision\",\"expected_checker_version\":\"metacodes-project-harness-kernel-v1\",\"kernel_sha256\":\"$hex_a\",\"candidate_id\":\"$hex_b\",\"project_sha256\":\"$hex_c\",\"bundle_sha256\":\"$hex_d\",\"bundle_revision\":1,\"rule_spec\":{\"schema_version\":\"metacodes-project-rule-spec-v1\",\"target_tool\":\"Write\",\"deny_target\":true,\"max_input_bytes\":8192,\"max_agent_depth\":4,\"authoritative_only\":true,\"effect_requirement\":\"none\"},\"payload\":{\"pre\":{"
deny_request="${prefix}\"tool\":\"Write\",\"input_bytes\":10,\"agent_depth\":0,\"authoritative\":true}}}"
admit_request=${deny_request/\"tool\":\"Write\"/\"tool\":\"Read\"}
deny_verdict=$(printf '%s' "$deny_request" | "$output")
admit_verdict=$(printf '%s' "$admit_request" | "$output")
[[ "$deny_verdict" == *'"decision":"block"'* && "$deny_verdict" == *'"rule_precondition_blocked"'* ]] || {
  echo "build-project-harness-kernel: deny smoke failed" >&2
  exit 1
}
[[ "$admit_verdict" == *'"decision":"admit"'* ]] || {
  echo "build-project-harness-kernel: admit smoke failed" >&2
  exit 1
}
batch_request="{\"schema_version\":\"metacodes-project-harness-batch-request-v1\",\"requests\":[$admit_request,$deny_request]}"
batch_verdict=$(printf '%s' "$batch_request" | "$output")
[[ "$batch_verdict" == *'"schema_version":"metacodes-project-harness-batch-verdict-v1"'* &&
  "$batch_verdict" == *'"verdicts":['* &&
  "$batch_verdict" == *'"decision":"admit"'* &&
  "$batch_verdict" == *'"decision":"block"'* ]] || {
  echo "build-project-harness-kernel: batch smoke failed" >&2
  exit 1
}
if printf '%s' '{"schema_version":"metacodes-project-harness-batch-request-v1","requests":[]}' \
  | "$output" >/dev/null 2>&1; then
  echo "build-project-harness-kernel: empty batch was not rejected" >&2
  exit 1
fi

if command -v shasum >/dev/null 2>&1; then
  hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  hash_file() { sha256sum "$1" | awk '{print $1}'; }
fi
binary_sha256=$(hash_file "$output")
kernel_source_sha256=$(hash_file "$lean_dir/MetaCodesControl/ProjectHarness.lean")
rule_source_sha256=$(hash_file "$lean_dir/MetaCodesControl/ProjectRule.lean")
main_source_sha256=$(hash_file "$lean_dir/ProjectHarnessMain.lean")
axiom_source_sha256=$(hash_file "$lean_dir/ProjectHarnessAxiomAudit.lean")
if [[ "$host_os" == "Darwin" ]]; then
  binary_bytes=$(stat -f '%z' "$output")
else
  binary_bytes=$(stat -c '%s' "$output")
fi
host_arch=$(uname -m)
lean_version=$(cd "$lean_dir" && "$lake" env lean --version | tr -d '\n')
printf '%s\n' \
  "{\"schema_version\":\"metacodes-project-kernel-artifact-v1\",\"checker_version\":\"metacodes-project-harness-kernel-v1\",\"request_schema\":\"metacodes-project-harness-request-v1\",\"verdict_schema\":\"metacodes-project-harness-verdict-v1\",\"batch_request_schema\":\"metacodes-project-harness-batch-request-v1\",\"batch_verdict_schema\":\"metacodes-project-harness-batch-verdict-v1\",\"max_batch_requests\":1024,\"binary_sha256\":\"$binary_sha256\",\"binary_bytes\":$binary_bytes,\"kernel_source_sha256\":\"$kernel_source_sha256\",\"rule_source_sha256\":\"$rule_source_sha256\",\"main_source_sha256\":\"$main_source_sha256\",\"axiom_audit_source_sha256\":\"$axiom_source_sha256\",\"axiom_policy\":\"propext\",\"axiom_audit\":\"passed\",\"host_os\":\"$host_os\",\"host_arch\":\"$host_arch\",\"linker\":\"$linker\",\"lean_version\":\"$lean_version\",\"native_smoke\":\"passed\",\"native_batch_smoke\":\"passed\"}" >"$manifest"

echo "project harness kernel: $output"
echo "sha256: $binary_sha256"
echo "bytes: $binary_bytes"
echo "provenance: $manifest"
