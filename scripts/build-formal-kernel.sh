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

# This script is intentionally a native builder: the produced checker is
# executed below before its provenance may say `native_smoke=passed`.  GitHub's
# Windows runners invoke it through Git Bash, where `uname` reports a MINGW/
# MSYS name and Lake emits an `.exe`; normalize both facts rather than treating
# every non-Darwin host as a Unix filesystem.
raw_host_os=$(uname -s)
case "$raw_host_os" in
  Darwin)
    host_os="Darwin"
    executable_suffix=""
    ;;
  Linux)
    host_os="Linux"
    executable_suffix=""
    ;;
  MINGW*|MSYS*|CYGWIN*)
    host_os="Windows"
    executable_suffix=".exe"
    ;;
  *)
    echo "build-formal-kernel: unsupported native host: $raw_host_os" >&2
    exit 1
    ;;
esac

host_arch=$(uname -m)
case "$host_arch" in
  x86_64|aarch64|arm64) ;;
  *)
    echo "build-formal-kernel: unsupported native architecture: $host_arch" >&2
    exit 1
    ;;
esac

output=${1:-"$repo_dir/zig-out/libexec/metacodes/metacodes-formal-kernel$executable_suffix"}
manifest=${2:-"$output.provenance.json"}
receipt=${3:-"$output.build-receipt.json"}
if [[ -n "${LAKE:-}" ]]; then
  lake=$LAKE
elif command -v lake >/dev/null 2>&1; then
  lake=$(command -v lake)
else
  lake="$HOME/.elan/bin/lake$executable_suffix"
fi

if [[ ! -x "$lake" ]]; then
  echo "build-formal-kernel: lake not found: $lake" >&2
  exit 1
fi

mkdir -p "$(dirname "$output")" "$(dirname "$manifest")" "$(dirname "$receipt")"

(
  cd "$lean_dir"
  if [[ "$host_os" == "Darwin" ]]; then
    # A clean Darwin build cannot first link Lake's executable and then repair
    # it: Lean 4.14's bundled ld64.lld may reject the current macOS SDK before
    # our Apple-clang relink is reached. Build only the exported objects here.
    "$lake" build \
      FormalMain:c.o \
      MetaCodesControl.FormalKernel:c.o \
      MetaCodesControl.MemoryMigration:c.o \
      MetaCodesControl.ArtifactVerification:c.o
  else
    "$lake" build metacodes-formal-kernel
  fi
)

# Lean permits declarations containing `sorry` to compile by inserting
# `sorryAx`.  Shipping a theorem-bearing checker therefore requires an axiom
# audit, not merely a green `lake build`.  The current proof uses only Lean's
# expected quotient/propositional extensionality axioms; any expansion of this
# exact trust set is a release-blocking review event.
axiom_audit=$(cd "$lean_dir" && "$lake" env lean FormalAxiomAudit.lean 2>&1)
expected_axioms="'MetaCodesControl.FormalKernel.safeMigration_sound' depends on axioms: [propext, Quot.sound]"
expected_axioms="$expected_axioms
'MetaCodesControl.FormalKernel.taskAudit_verified_iff_safe' depends on axioms: [propext]
'MetaCodesControl.FormalKernel.taskAudit_terminal_closed' does not depend on any axioms
'MetaCodesControl.MemoryMigration.safeSupersede_sound' depends on axioms: [propext]
'MetaCodesControl.MemoryMigration.applySupersede_preserves_nodes' does not depend on any axioms
'MetaCodesControl.MemoryMigration.rollbackSupersede_apply' depends on axioms: [propext, Quot.sound]
'MetaCodesControl.ArtifactVerification.safeTransition_sound' depends on axioms: [propext]
'MetaCodesControl.ArtifactVerification.admitted_provider_request_is_bound_to_authorization' depends on axioms: [propext]
'MetaCodesControl.ArtifactVerification.admitted_provider_result_follows_authorized_state' depends on axioms: [propext]
'MetaCodesControl.ArtifactVerification.admitted_repaired_state_requires_reverification' depends on axioms: [propext]
'MetaCodesControl.ArtifactVerification.admitted_record_repair_advances_artifact' depends on axioms: [propext]
'MetaCodesControl.ArtifactVerification.admitted_transition_produces_well_formed_state' depends on axioms: [propext]
'MetaCodesControl.ArtifactVerification.admitted_transition_binds_expected_next_phase' depends on axioms: [propext]"
if [[ "$axiom_audit" != "$expected_axioms" ]]; then
  echo "build-formal-kernel: unexpected soundness theorem axiom set" >&2
  printf '%s\n' "$axiom_audit" >&2
  exit 1
fi

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
  # Apple's linker derives the ad-hoc code-sign identifier from the output
  # basename.  Passing mktemp's random basename here made otherwise identical
  # Lean IR produce a different LC_UUID and signature on every build.  Keep the
  # parent private/random but the basename stable, then relink independently and
  # require byte identity before publishing the artifact.
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/metacodes-formal-kernel.XXXXXX")
  mkdir "$tmp_dir/first" "$tmp_dir/second"
  tmp_binary="$tmp_dir/first/metacodes-formal-kernel"
  tmp_repro="$tmp_dir/second/metacodes-formal-kernel"
  trap 'rm -f "$tmp_binary" "$tmp_repro"; rmdir "$tmp_dir/first" "$tmp_dir/second" "$tmp_dir" 2>/dev/null || true' EXIT
  for candidate in "$tmp_binary" "$tmp_repro"; do
    LEAN_CC=/usr/bin/clang "$leanc" -o "$candidate" \
      "$lean_dir/.lake/build/ir/FormalMain.c.o.export" \
      "$lean_dir/.lake/build/ir/MetaCodesControl/FormalKernel.c.o.export" \
      "$lean_dir/.lake/build/ir/MetaCodesControl/MemoryMigration.c.o.export" \
      "$lean_dir/.lake/build/ir/MetaCodesControl/ArtifactVerification.c.o.export" \
      "${link_args[@]}"
  done
  if ! cmp -s "$tmp_binary" "$tmp_repro"; then
    echo "build-formal-kernel: Darwin relink is not reproducible" >&2
    exit 1
  fi
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
  install -m 0755 "$lean_dir/.lake/build/bin/metacodes-formal-kernel$executable_suffix" "$output"
fi

hex_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
hex_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
hex_c=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
hex_d=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
request_prefix="{\"schema_version\":\"metacodes-formal-request-v1\",\"request_id\":\"$hex_a\",\"operation\":\"task_audit\",\"proposal_sha256\":\"$hex_b\",\"snapshot_sha256\":\"$hex_c\",\"snapshot_revision\":\"$hex_d\",\"expected_checker_version\":\"metacodes-formal-kernel-v2\",\"facts\":{"
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

memory_prefix="{\"schema_version\":\"metacodes-memory-migration-request-v1\",\"request_id\":\"$hex_a\",\"operation\":\"memory_supersede_existing\",\"proposal_sha256\":\"$hex_b\",\"snapshot_sha256\":\"$hex_c\",\"snapshot_revision\":\"$hex_d\",\"expected_checker_version\":\"metacodes-formal-kernel-v2\",\"snapshot\":{\"bounded\":true,\"truncated\":false,\"source\":{\"id\":1,\"kind\":\"observation\",\"schema_type\":\"lesson\",\"current_generation\":true,\"retrieval_excluded\":false,\"contradicted\":false},\"replacement\":{\"id\":2,\"kind\":\"observation\",\"schema_type\":\"lesson\",\"current_generation\":true,\"retrieval_excluded\":false,\"contradicted\":false},\"evidence\":{\"id\":3,\"kind\":\"verification\",\"schema_type\":\"verification\",\"current_generation\":true,\"retrieval_excluded\":false,\"contradicted\":false},\"deprecated_edge_exists\":false},\"proposal\":{\"source_id\":1,\"replacement_id\":2,\"evidence_id\":3,\"effect\":\"add_deprecated_by_and_exclude_source\",\"rollback\":\"remove_deprecated_by_and_restore_source\",\"snapshot_revision\":\"$hex_d\"}}"
memory_admit=$(printf '%s' "$memory_prefix" | "$output")
if [[ "$memory_admit" != *'"decision":"admit"'* || "$memory_admit" != *'"reversible":true'* ]]; then
  echo "build-formal-kernel: native memory migration admit smoke failed" >&2
  exit 1
fi
memory_block=${memory_prefix/\"replacement_id\":2/\"replacement_id\":4}
memory_block_verdict=$(printf '%s' "$memory_block" | "$output")
if [[ "$memory_block_verdict" != *'"decision":"block"'* || "$memory_block_verdict" != *'"invalid_reference"'* ]]; then
  echo "build-formal-kernel: native memory migration block smoke failed" >&2
  exit 1
fi

zero_hash=0000000000000000000000000000000000000000000000000000000000000000
artifact_request="{\"schema_version\":\"metacodes-artifact-verification-request-v1\",\"request_id\":\"$hex_a\",\"operation\":\"artifact_transition\",\"proposal_sha256\":\"$hex_b\",\"snapshot_sha256\":\"$hex_c\",\"snapshot_revision\":\"$hex_d\",\"expected_checker_version\":\"metacodes-formal-kernel-v2\",\"state\":{\"phase\":\"candidate\",\"task_sha256\":\"$hex_a\",\"actor_run_sha256\":\"$hex_b\",\"artifact_sha256\":\"$hex_c\",\"artifact_revision\":\"$hex_d\",\"verifier_sha256\":\"$hex_a\",\"policy_sha256\":\"$hex_b\",\"budget_authority_sha256\":\"$hex_c\",\"active_provider_authorization_sha256\":\"$zero_hash\",\"transition_revision\":0,\"repair_attempts\":0,\"max_repair_attempts\":3,\"semantic_verdict_sha256\":\"$zero_hash\",\"defect_sha256\":\"$zero_hash\",\"repair_proposal_sha256\":\"$zero_hash\"},\"proposal\":{\"event\":\"request_verification\",\"expected_phase\":\"candidate\",\"expected_next_phase\":\"verification_requested\",\"expected_snapshot_revision\":\"$hex_d\",\"next_snapshot_revision\":\"$hex_a\",\"provider_authorization_sha256\":\"$hex_b\",\"semantic_verdict_sha256\":\"$zero_hash\",\"defect_sha256\":\"$zero_hash\",\"repair_proposal_sha256\":\"$zero_hash\",\"next_artifact_sha256\":\"$zero_hash\",\"next_artifact_revision\":\"$zero_hash\"}}"
artifact_admit=$(printf '%s' "$artifact_request" | "$output")
if [[ "$artifact_admit" != *'"decision":"admit"'* || "$artifact_admit" != *'"next_phase":"verification_requested"'* ]]; then
  echo "build-formal-kernel: native artifact verification admit smoke failed" >&2
  exit 1
fi
artifact_block=${artifact_request/\"provider_authorization_sha256\":\"$hex_b\"/\"provider_authorization_sha256\":\"$zero_hash\"}
artifact_block_verdict=$(printf '%s' "$artifact_block" | "$output")
if [[ "$artifact_block_verdict" != *'"decision":"block"'* || "$artifact_block_verdict" != *'"artifact_provider_not_authorized"'* ]]; then
  echo "build-formal-kernel: native artifact verification block smoke failed" >&2
  exit 1
fi
artifact_phase_block=${artifact_request/\"expected_next_phase\":\"verification_requested\"/\"expected_next_phase\":\"verified\"}
artifact_phase_block_verdict=$(printf '%s' "$artifact_phase_block" | "$output")
if [[ "$artifact_phase_block_verdict" != *'"decision":"block"'* || "$artifact_phase_block_verdict" != *'"artifact_transition_illegal"'* ]]; then
  echo "build-formal-kernel: native artifact next-phase binding smoke failed" >&2
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
  memory_kernel_source_sha256=$(shasum -a 256 "$lean_dir/MetaCodesControl/MemoryMigration.lean" | awk '{print $1}')
  artifact_kernel_source_sha256=$(shasum -a 256 "$lean_dir/MetaCodesControl/ArtifactVerification.lean" | awk '{print $1}')
  main_source_sha256=$(shasum -a 256 "$lean_dir/FormalMain.lean" | awk '{print $1}')
  axiom_audit_source_sha256=$(shasum -a 256 "$lean_dir/FormalAxiomAudit.lean" | awk '{print $1}')
else
  binary_sha256=$(sha256sum "$output" | awk '{print $1}')
  kernel_source_sha256=$(sha256sum "$lean_dir/MetaCodesControl/FormalKernel.lean" | awk '{print $1}')
  memory_kernel_source_sha256=$(sha256sum "$lean_dir/MetaCodesControl/MemoryMigration.lean" | awk '{print $1}')
  artifact_kernel_source_sha256=$(sha256sum "$lean_dir/MetaCodesControl/ArtifactVerification.lean" | awk '{print $1}')
  main_source_sha256=$(sha256sum "$lean_dir/FormalMain.lean" | awk '{print $1}')
  axiom_audit_source_sha256=$(sha256sum "$lean_dir/FormalAxiomAudit.lean" | awk '{print $1}')
fi
if [[ "$host_os" == "Darwin" ]]; then
  binary_bytes=$(stat -f '%z' "$output")
else
  binary_bytes=$(stat -c '%s' "$output")
fi
lean_version=$(cd "$lean_dir" && "$lake" env lean --version | tr -d '\r\n')
built_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# The artifact manifest is intentionally time-independent.  It is the stable
# semantic identity used by experiment fingerprints.  Per-build facts such as
# the wall-clock timestamp live in a separately hashed receipt so rebuilding
# identical source cannot silently create a different experiment treatment.
printf '%s\n' \
  "{\"schema_version\":\"metacodes-formal-artifact-v4\",\"checker_version\":\"metacodes-formal-kernel-v2\",\"request_schema\":\"metacodes-formal-request-v1\",\"memory_request_schema\":\"metacodes-memory-migration-request-v1\",\"artifact_request_schema\":\"metacodes-artifact-verification-request-v1\",\"verdict_schema\":\"metacodes-formal-verdict-v2\",\"binary_sha256\":\"$binary_sha256\",\"binary_bytes\":$binary_bytes,\"kernel_source_sha256\":\"$kernel_source_sha256\",\"memory_kernel_source_sha256\":\"$memory_kernel_source_sha256\",\"artifact_kernel_source_sha256\":\"$artifact_kernel_source_sha256\",\"main_source_sha256\":\"$main_source_sha256\",\"axiom_audit_source_sha256\":\"$axiom_audit_source_sha256\",\"axiom_policy\":\"propext,Quot.sound\",\"axiom_audit\":\"passed\",\"host_os\":\"$host_os\",\"host_arch\":\"$host_arch\",\"linker\":\"$linker\",\"lean_version\":\"$lean_version\",\"native_smoke\":\"passed\"}" \
  >"$manifest"

if command -v shasum >/dev/null 2>&1; then
  manifest_sha256=$(shasum -a 256 "$manifest" | awk '{print $1}')
else
  manifest_sha256=$(sha256sum "$manifest" | awk '{print $1}')
fi
printf '%s\n' \
  "{\"schema_version\":\"metacodes-formal-build-receipt-v1\",\"artifact_manifest_sha256\":\"$manifest_sha256\",\"binary_sha256\":\"$binary_sha256\",\"built_at_utc\":\"$built_at_utc\"}" \
  >"$receipt"

echo "formal kernel: $output"
echo "sha256: $binary_sha256"
echo "bytes: $binary_bytes"
echo "provenance: $manifest"
echo "build receipt: $receipt"
