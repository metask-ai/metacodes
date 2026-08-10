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
'MetaCodesControl.ProjectHarness.denied_all_predecision_blocks' depends on axioms: [propext]
'MetaCodesControl.ProjectHarness.denied_existing_file_predecision_blocks' depends on axioms: [propext]
'MetaCodesControl.ProjectRule.denied_observed_overwrite_selects_exact_edit_recovery' depends on axioms: [propext]
'MetaCodesControl.ProjectRule.nonregular_target_has_no_exact_edit_recovery' depends on axioms: [propext]
'MetaCodesControl.ProjectRule.exact_edit_recovery_pre_sound' depends on axioms: [propext]
'MetaCodesControl.ProjectRule.exact_edit_recovery_post_sound' depends on axioms: [propext]
'MetaCodesControl.ProjectRule.exact_edit_recovery_failed_mutation_sound' depends on axioms: [propext]
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
request_prefix="{\"schema_version\":\"metacodes-project-harness-request-v3\",\"request_id\":\"$hex_a\","
request_bindings="\"expected_checker_version\":\"metacodes-project-harness-kernel-v3\",\"kernel_sha256\":\"$hex_a\",\"candidate_id\":\"$hex_b\",\"project_sha256\":\"$hex_c\",\"bundle_sha256\":\"$hex_d\",\"bundle_revision\":1,\"rule_spec\":{\"schema_version\":\"metacodes-project-rule-spec-v2\",\"target_tool\":\"Write\",\"target_scope\":\"existing_file\",\"deny_target\":true,\"max_input_bytes\":8192,\"max_agent_depth\":4,\"authoritative_only\":true,\"effect_requirement\":\"none\"},"
prefix="${request_prefix}\"operation\":\"pre_decision\",${request_bindings}\"payload\":{\"pre\":{"
deny_request="${prefix}\"tool\":\"Write\",\"input_bytes\":10,\"agent_depth\":0,\"authoritative\":true,\"file_target_state\":\"regular_existing\",\"exact_recovery_material_ready\":true}}}"
admit_request=${deny_request/\"regular_existing\"/\"missing\"}
deny_verdict=$(printf '%s' "$deny_request" | "$output")
admit_verdict=$(printf '%s' "$admit_request" | "$output")
[[ "$deny_verdict" == *'"decision":"block"'* &&
  "$deny_verdict" == *'"rule_precondition_blocked"'* &&
  "$deny_verdict" == *'"recover_edit_existing_file_exact"'* ]] || {
  echo "build-project-harness-kernel: deny smoke failed" >&2
  exit 1
}
[[ "$admit_verdict" == *'"decision":"admit"'* ]] || {
  echo "build-project-harness-kernel: admit smoke failed" >&2
  exit 1
}
recovery_pre_prefix="${request_prefix}\"operation\":\"recovery_pre_decision\",${request_bindings}\"payload\":{\"recovery_pre\":{"
valid_recovery_pre="${recovery_pre_prefix}\"tool\":\"Edit\",\"input_bytes\":20,\"agent_depth\":0,\"authoritative\":true,\"target_matches\":true,\"material_available\":true,\"current_matches_source\":true,\"old_matches_current\":true,\"new_matches_blocked\":true}}}"
invalid_recovery_pre=${valid_recovery_pre/\"old_matches_current\":true/\"old_matches_current\":false}
stale_recovery_pre=${valid_recovery_pre/\"current_matches_source\":true/\"current_matches_source\":false}
valid_recovery_pre_verdict=$(printf '%s' "$valid_recovery_pre" | "$output")
invalid_recovery_pre_verdict=$(printf '%s' "$invalid_recovery_pre" | "$output")
stale_recovery_pre_verdict=$(printf '%s' "$stale_recovery_pre" | "$output")
[[ "$valid_recovery_pre_verdict" == *'"decision":"admit"'* ]] || {
  echo "build-project-harness-kernel: recovery pre admit smoke failed" >&2
  exit 1
}
[[ "$invalid_recovery_pre_verdict" == *'"decision":"block"'* &&
  "$invalid_recovery_pre_verdict" == *'"recover_edit_existing_file_exact"'* ]] || {
  echo "build-project-harness-kernel: recovery pre block smoke failed" >&2
  exit 1
}
[[ "$stale_recovery_pre_verdict" == *'"decision":"block"'* &&
  "$stale_recovery_pre_verdict" != *'"recover_edit_existing_file_exact"'* ]] || {
  echo "build-project-harness-kernel: stale recovery incorrectly advertised a retry" >&2
  exit 1
}
recovery_post_prefix="${request_prefix}\"operation\":\"recovery_post_decision\",${request_bindings}\"payload\":{\"recovery_post\":{\"pre\":{"
valid_recovery_post="${recovery_post_prefix}\"tool\":\"Edit\",\"input_bytes\":20,\"agent_depth\":0,\"authoritative\":true,\"target_matches\":true,\"material_available\":true,\"current_matches_source\":true,\"old_matches_current\":true,\"new_matches_blocked\":true},\"succeeded\":true,\"effect_valid\":true,\"has_file_mutation_v1\":true,\"post_reobserved\":true,\"observed_matches_blocked\":true}}}"
invalid_recovery_post=${valid_recovery_post/\"observed_matches_blocked\":true/\"observed_matches_blocked\":false}
failed_clean_recovery_post=${valid_recovery_post/\"succeeded\":true,\"effect_valid\":true,\"has_file_mutation_v1\":true,\"post_reobserved\":true,\"observed_matches_blocked\":true/\"succeeded\":false,\"effect_valid\":true,\"has_file_mutation_v1\":false,\"post_reobserved\":false,\"observed_matches_blocked\":false}
failed_partial_recovery_post=${valid_recovery_post/\"succeeded\":true,\"effect_valid\":true,\"has_file_mutation_v1\":true,\"post_reobserved\":true,\"observed_matches_blocked\":true/\"succeeded\":false,\"effect_valid\":true,\"has_file_mutation_v1\":true,\"post_reobserved\":false,\"observed_matches_blocked\":false}
valid_recovery_post_verdict=$(printf '%s' "$valid_recovery_post" | "$output")
invalid_recovery_post_verdict=$(printf '%s' "$invalid_recovery_post" | "$output")
failed_clean_recovery_post_verdict=$(printf '%s' "$failed_clean_recovery_post" | "$output")
failed_partial_recovery_post_verdict=$(printf '%s' "$failed_partial_recovery_post" | "$output")
[[ "$valid_recovery_post_verdict" == *'"decision":"admit"'* ]] || {
  echo "build-project-harness-kernel: recovery post admit smoke failed" >&2
  exit 1
}
[[ "$invalid_recovery_post_verdict" == *'"decision":"block"'* ]] || {
  echo "build-project-harness-kernel: recovery post block smoke failed" >&2
  exit 1
}
[[ "$failed_clean_recovery_post_verdict" == *'"decision":"admit"'* ]] || {
  echo "build-project-harness-kernel: clean recovery failure smoke failed" >&2
  exit 1
}
[[ "$failed_partial_recovery_post_verdict" == *'"decision":"block"'* ]] || {
  echo "build-project-harness-kernel: partial-effect recovery failure smoke failed" >&2
  exit 1
}
batch_request="{\"schema_version\":\"metacodes-project-harness-batch-request-v3\",\"requests\":[$admit_request,$deny_request]}"
batch_verdict=$(printf '%s' "$batch_request" | "$output")
[[ "$batch_verdict" == *'"schema_version":"metacodes-project-harness-batch-verdict-v3"'* &&
  "$batch_verdict" == *'"verdicts":['* &&
  "$batch_verdict" == *'"decision":"admit"'* &&
  "$batch_verdict" == *'"decision":"block"'* ]] || {
  echo "build-project-harness-kernel: batch smoke failed" >&2
  exit 1
}
if printf '%s' '{"schema_version":"metacodes-project-harness-batch-request-v3","requests":[]}' \
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
formal_kernel_source_sha256=$(hash_file "$lean_dir/MetaCodesControl/FormalKernel.lean")
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
  "{\"schema_version\":\"metacodes-project-kernel-artifact-v4\",\"checker_version\":\"metacodes-project-harness-kernel-v3\",\"request_schema\":\"metacodes-project-harness-request-v3\",\"verdict_schema\":\"metacodes-project-harness-verdict-v3\",\"batch_request_schema\":\"metacodes-project-harness-batch-request-v3\",\"batch_verdict_schema\":\"metacodes-project-harness-batch-verdict-v3\",\"max_batch_requests\":1024,\"binary_sha256\":\"$binary_sha256\",\"binary_bytes\":$binary_bytes,\"kernel_source_sha256\":\"$kernel_source_sha256\",\"rule_source_sha256\":\"$rule_source_sha256\",\"formal_kernel_source_sha256\":\"$formal_kernel_source_sha256\",\"main_source_sha256\":\"$main_source_sha256\",\"axiom_audit_source_sha256\":\"$axiom_source_sha256\",\"axiom_policy\":\"propext\",\"axiom_audit\":\"passed\",\"host_os\":\"$host_os\",\"host_arch\":\"$host_arch\",\"linker\":\"$linker\",\"lean_version\":\"$lean_version\",\"native_smoke\":\"passed\",\"native_batch_smoke\":\"passed\",\"native_recovery_smoke\":\"passed\"}" >"$manifest"

echo "project harness kernel: $output"
echo "sha256: $binary_sha256"
echo "bytes: $binary_bytes"
echo "provenance: $manifest"
