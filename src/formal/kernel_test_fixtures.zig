//! Test-only builders for the two kernels' provenance sidecars: the manifest
//! each build script writes (`scripts/build-formal-kernel.sh`,
//! `scripts/build-project-harness-kernel.sh`), field for field, with the
//! runtime's own constants substituted, and the formal kernel's hash-bound
//! receipt. Shared by `provenance.zig`, `project_provenance.zig` and
//! `app/doctor.zig` tests; nothing in the product imports this file.

const std = @import("std");
const runtime = @import("runtime.zig");
const project_runtime = @import("project_harness_runtime.zig");
const provenance = @import("provenance.zig");
const project_provenance = @import("project_provenance.zig");
const impact_aggregate = @import("../core/rule_impact_aggregate_receipt.zig");

/// The formal kernel's v4 manifest; the caller owns it.
pub fn formalManifest(allocator: std.mem.Allocator, binary_sha256: []const u8, binary_bytes: u64) ![]u8 {
    const host_os = provenance.expectedHostOs() orelse return error.SkipZigTest;
    const host_arch = provenance.expectedHostArch() orelse return error.SkipZigTest;
    const zeros = "0" ** 64;
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"{s}\",\"checker_version\":\"{s}\",\"request_schema\":\"{s}\",\"memory_request_schema\":\"{s}\",\"artifact_request_schema\":\"{s}\",\"verdict_schema\":\"{s}\",\"binary_sha256\":\"{s}\",\"binary_bytes\":{d},\"kernel_source_sha256\":\"{s}\",\"memory_kernel_source_sha256\":\"{s}\",\"artifact_kernel_source_sha256\":\"{s}\",\"main_source_sha256\":\"{s}\",\"axiom_audit_source_sha256\":\"{s}\",\"axiom_policy\":\"propext,Quot.sound\",\"axiom_audit\":\"passed\",\"host_os\":\"{s}\",\"host_arch\":\"{s}\",\"linker\":\"test\",\"lean_version\":\"Lean (version 4.14.0, test)\",\"native_smoke\":\"passed\"}}\n",
        .{ provenance.MANIFEST_SCHEMA, runtime.CHECKER_VERSION, runtime.REQUEST_SCHEMA, runtime.MEMORY_REQUEST_SCHEMA, runtime.ARTIFACT_REQUEST_SCHEMA, runtime.VERDICT_SCHEMA, binary_sha256, binary_bytes, zeros, zeros, zeros, zeros, zeros, host_os, host_arch },
    );
}

/// The receipt that binds a formal `manifest` and the binary; the caller owns it.
pub fn formalBuildReceipt(allocator: std.mem.Allocator, manifest: []const u8, binary_sha256: []const u8) ![]u8 {
    const manifest_sha256 = provenance.sha256Hex(manifest);
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"{s}\",\"artifact_manifest_sha256\":\"{s}\",\"binary_sha256\":\"{s}\",\"built_at_utc\":\"2026-01-01T00:00:00Z\"}}\n",
        .{ provenance.BUILD_RECEIPT_SCHEMA, manifest_sha256[0..], binary_sha256 },
    );
}

/// The project kernel's v6 manifest; the caller owns it.
pub fn projectManifest(allocator: std.mem.Allocator, binary_sha256: []const u8, binary_bytes: u64) ![]u8 {
    const host_os = provenance.expectedHostOs() orelse return error.SkipZigTest;
    const host_arch = provenance.expectedHostArch() orelse return error.SkipZigTest;
    const zeros = "0" ** 64;
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"{s}\",\"checker_version\":\"{s}\",\"request_schema\":\"{s}\",\"verdict_schema\":\"{s}\",\"batch_request_schema\":\"{s}\",\"batch_verdict_schema\":\"{s}\",\"impact_request_schema\":\"{s}\",\"impact_verdict_schema\":\"{s}\",\"impact_aggregate_request_schema\":\"{s}\",\"impact_aggregate_verdict_schema\":\"{s}\",\"max_batch_requests\":{d},\"max_impact_aggregate_members\":{d},\"binary_sha256\":\"{s}\",\"binary_bytes\":{d},\"kernel_source_sha256\":\"{s}\",\"rule_source_sha256\":\"{s}\",\"impact_source_sha256\":\"{s}\",\"impact_aggregate_source_sha256\":\"{s}\",\"formal_kernel_source_sha256\":\"{s}\",\"main_source_sha256\":\"{s}\",\"axiom_audit_source_sha256\":\"{s}\",\"axiom_policy\":\"{s}\",\"axiom_audit\":\"passed\",\"host_os\":\"{s}\",\"host_arch\":\"{s}\",\"linker\":\"test\",\"lean_version\":\"Lean (version 4.14.0, test)\",\"native_smoke\":\"passed\",\"native_rule_author_promotion_smoke\":\"passed\",\"native_batch_smoke\":\"passed\",\"native_recovery_smoke\":\"passed\",\"native_impact_smoke\":\"passed\",\"native_impact_aggregate_smoke\":\"passed\"}}\n",
        .{
            project_provenance.MANIFEST_SCHEMA,
            project_runtime.CHECKER_VERSION,
            project_runtime.REQUEST_SCHEMA,
            project_runtime.VERDICT_SCHEMA,
            project_runtime.BATCH_REQUEST_SCHEMA,
            project_runtime.BATCH_VERDICT_SCHEMA,
            project_runtime.IMPACT_REQUEST_SCHEMA,
            project_runtime.IMPACT_VERDICT_SCHEMA,
            project_runtime.IMPACT_AGGREGATE_REQUEST_SCHEMA,
            project_runtime.IMPACT_AGGREGATE_VERDICT_SCHEMA,
            project_runtime.MAX_BATCH_REQUESTS,
            impact_aggregate.MAX_MEMBERS,
            binary_sha256,
            binary_bytes,
            zeros,
            zeros,
            zeros,
            zeros,
            zeros,
            zeros,
            zeros,
            project_provenance.AXIOM_POLICY,
            host_os,
            host_arch,
        },
    );
}
