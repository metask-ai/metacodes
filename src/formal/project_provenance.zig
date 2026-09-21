//! Strict loader for the build-time provenance shipped beside the project
//! governance kernel (`scripts/build-project-harness-kernel.sh`).
//!
//! The project kernel carries its own artifact manifest
//! (`metacodes-project-kernel-artifact-v6`): the same binary/source/toolchain
//! identity as the formal kernel's `provenance.zig`, plus the batch and
//! RuleImpact governance schemas, the bounds the kernel was smoked against, and
//! one line per native smoke. It has no build receipt: nothing reports the
//! project kernel's build timestamp, so there is no wall-clock file to bind.
//! Like the formal loader this is hash-linked research provenance, not a
//! signature.
//!
//! Each kernel is validated by its own loader. Running this manifest through
//! the formal loader (or the formal manifest through this one) is a schema
//! mismatch, never a pass — `app/doctor.zig` depends on that.

const std = @import("std");
const runtime = @import("project_harness_runtime.zig");
const formal_provenance = @import("provenance.zig");
const impact_aggregate = @import("../core/rule_impact_aggregate_receipt.zig");

pub const MANIFEST_SCHEMA = "metacodes-project-kernel-artifact-v6";
/// The project kernel's axiom audit admits `propext` only; the formal kernel's
/// admits `Quot.sound` as well. The two policies are not interchangeable.
pub const AXIOM_POLICY = "propext";

/// Every field the build script writes, in its order; `ignore_unknown_fields`
/// is off, so a manifest with a field this struct does not name (a receipt
/// hash, a formal-only source digest) is rejected as a whole.
const Raw = struct {
    schema_version: []const u8,
    checker_version: []const u8,
    request_schema: []const u8,
    verdict_schema: []const u8,
    batch_request_schema: []const u8,
    batch_verdict_schema: []const u8,
    impact_request_schema: []const u8,
    impact_verdict_schema: []const u8,
    impact_aggregate_request_schema: []const u8,
    impact_aggregate_verdict_schema: []const u8,
    max_batch_requests: u64,
    max_impact_aggregate_members: u64,
    binary_sha256: []const u8,
    binary_bytes: u64,
    kernel_source_sha256: []const u8,
    rule_source_sha256: []const u8,
    impact_source_sha256: []const u8,
    impact_aggregate_source_sha256: []const u8,
    formal_kernel_source_sha256: []const u8,
    main_source_sha256: []const u8,
    axiom_audit_source_sha256: []const u8,
    axiom_policy: []const u8,
    axiom_audit: []const u8,
    host_os: []const u8,
    host_arch: []const u8,
    linker: []const u8,
    lean_version: []const u8,
    native_smoke: []const u8,
    native_rule_author_promotion_smoke: []const u8,
    native_batch_smoke: []const u8,
    native_recovery_smoke: []const u8,
    native_impact_smoke: []const u8,
    native_impact_aggregate_smoke: []const u8,
};

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    raw: []const u8,
    manifest_sha256: [64]u8,
    binary_sha256: [64]u8,
    binary_bytes: u64,
    kernel_source_sha256: [64]u8,
    rule_source_sha256: [64]u8,
    impact_source_sha256: [64]u8,
    impact_aggregate_source_sha256: [64]u8,
    formal_kernel_source_sha256: [64]u8,
    main_source_sha256: [64]u8,
    axiom_audit_source_sha256: [64]u8,
    host_os: []const u8,
    host_arch: []const u8,
    linker: []const u8,
    lean_version: []const u8,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn loadAdjacent(
    allocator: std.mem.Allocator,
    checker_path: []const u8,
    expected_binary_sha256: [64]u8,
    expected_binary_bytes: u64,
) !Loaded {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, "{s}.provenance.json", .{checker_path});
    const raw = try formal_provenance.readBounded(a, path);
    const parsed = std.json.parseFromSliceLeaky(Raw, a, raw, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProvenanceJson,
    };
    if (!std.mem.eql(u8, parsed.schema_version, MANIFEST_SCHEMA) or
        !std.mem.eql(u8, parsed.checker_version, runtime.CHECKER_VERSION) or
        !std.mem.eql(u8, parsed.request_schema, runtime.REQUEST_SCHEMA) or
        !std.mem.eql(u8, parsed.verdict_schema, runtime.VERDICT_SCHEMA) or
        !std.mem.eql(u8, parsed.batch_request_schema, runtime.BATCH_REQUEST_SCHEMA) or
        !std.mem.eql(u8, parsed.batch_verdict_schema, runtime.BATCH_VERDICT_SCHEMA) or
        !std.mem.eql(u8, parsed.impact_request_schema, runtime.IMPACT_REQUEST_SCHEMA) or
        !std.mem.eql(u8, parsed.impact_verdict_schema, runtime.IMPACT_VERDICT_SCHEMA) or
        !std.mem.eql(u8, parsed.impact_aggregate_request_schema, runtime.IMPACT_AGGREGATE_REQUEST_SCHEMA) or
        !std.mem.eql(u8, parsed.impact_aggregate_verdict_schema, runtime.IMPACT_AGGREGATE_VERDICT_SCHEMA) or
        parsed.max_batch_requests != runtime.MAX_BATCH_REQUESTS or
        parsed.max_impact_aggregate_members != impact_aggregate.MAX_MEMBERS or
        !std.mem.eql(u8, parsed.axiom_policy, AXIOM_POLICY) or
        !std.mem.eql(u8, parsed.axiom_audit, "passed") or
        !std.mem.eql(u8, parsed.native_smoke, "passed") or
        !std.mem.eql(u8, parsed.native_rule_author_promotion_smoke, "passed") or
        !std.mem.eql(u8, parsed.native_batch_smoke, "passed") or
        !std.mem.eql(u8, parsed.native_recovery_smoke, "passed") or
        !std.mem.eql(u8, parsed.native_impact_smoke, "passed") or
        !std.mem.eql(u8, parsed.native_impact_aggregate_smoke, "passed"))
        return error.ProvenanceSchemaMismatch;

    const manifest_sha256 = formal_provenance.sha256Hex(raw);
    const binary_sha256 = formal_provenance.parseLowerHex64(parsed.binary_sha256) orelse
        return error.InvalidProvenanceHash;
    const kernel_source_sha256 = formal_provenance.parseLowerHex64(parsed.kernel_source_sha256) orelse
        return error.InvalidProvenanceHash;
    const rule_source_sha256 = formal_provenance.parseLowerHex64(parsed.rule_source_sha256) orelse
        return error.InvalidProvenanceHash;
    const impact_source_sha256 = formal_provenance.parseLowerHex64(parsed.impact_source_sha256) orelse
        return error.InvalidProvenanceHash;
    const impact_aggregate_source_sha256 = formal_provenance.parseLowerHex64(parsed.impact_aggregate_source_sha256) orelse
        return error.InvalidProvenanceHash;
    const formal_kernel_source_sha256 = formal_provenance.parseLowerHex64(parsed.formal_kernel_source_sha256) orelse
        return error.InvalidProvenanceHash;
    const main_source_sha256 = formal_provenance.parseLowerHex64(parsed.main_source_sha256) orelse
        return error.InvalidProvenanceHash;
    const axiom_audit_source_sha256 = formal_provenance.parseLowerHex64(parsed.axiom_audit_source_sha256) orelse
        return error.InvalidProvenanceHash;
    if (!std.mem.eql(u8, &binary_sha256, &expected_binary_sha256) or
        parsed.binary_bytes != expected_binary_bytes)
        return error.ProvenanceBinaryMismatch;
    if (!formal_provenance.validLabel(parsed.host_os, 64) or !formal_provenance.validLabel(parsed.host_arch, 64) or
        !formal_provenance.validLabel(parsed.linker, 64) or !formal_provenance.validLabel(parsed.lean_version, 512))
        return error.InvalidProvenanceText;
    const host_os = formal_provenance.expectedHostOs() orelse return error.UnsupportedProvenanceHost;
    const host_arch = formal_provenance.expectedHostArch() orelse return error.UnsupportedProvenanceHost;
    if (!std.mem.eql(u8, parsed.host_os, host_os) or
        !std.mem.eql(u8, parsed.host_arch, host_arch))
        return error.ProvenanceHostMismatch;

    return .{
        .arena = arena,
        .raw = raw,
        .manifest_sha256 = manifest_sha256,
        .binary_sha256 = binary_sha256,
        .binary_bytes = parsed.binary_bytes,
        .kernel_source_sha256 = kernel_source_sha256,
        .rule_source_sha256 = rule_source_sha256,
        .impact_source_sha256 = impact_source_sha256,
        .impact_aggregate_source_sha256 = impact_aggregate_source_sha256,
        .formal_kernel_source_sha256 = formal_kernel_source_sha256,
        .main_source_sha256 = main_source_sha256,
        .axiom_audit_source_sha256 = axiom_audit_source_sha256,
        .host_os = parsed.host_os,
        .host_arch = parsed.host_arch,
        .linker = parsed.linker,
        .lean_version = parsed.lean_version,
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

const test_binary_sha256: [64]u8 = ("a" ** 64).*;
const test_binary_bytes: u64 = 7;

/// The manifest `scripts/build-project-harness-kernel.sh` writes, field for
/// field, with the runtime's own constants substituted; the caller owns it.
pub fn testManifest(allocator: std.mem.Allocator, binary_sha256: []const u8, binary_bytes: u64) ![]u8 {
    const host_os = formal_provenance.expectedHostOs() orelse return error.SkipZigTest;
    const host_arch = formal_provenance.expectedHostArch() orelse return error.SkipZigTest;
    const zeros = "0" ** 64;
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"{s}\",\"checker_version\":\"{s}\",\"request_schema\":\"{s}\",\"verdict_schema\":\"{s}\",\"batch_request_schema\":\"{s}\",\"batch_verdict_schema\":\"{s}\",\"impact_request_schema\":\"{s}\",\"impact_verdict_schema\":\"{s}\",\"impact_aggregate_request_schema\":\"{s}\",\"impact_aggregate_verdict_schema\":\"{s}\",\"max_batch_requests\":{d},\"max_impact_aggregate_members\":{d},\"binary_sha256\":\"{s}\",\"binary_bytes\":{d},\"kernel_source_sha256\":\"{s}\",\"rule_source_sha256\":\"{s}\",\"impact_source_sha256\":\"{s}\",\"impact_aggregate_source_sha256\":\"{s}\",\"formal_kernel_source_sha256\":\"{s}\",\"main_source_sha256\":\"{s}\",\"axiom_audit_source_sha256\":\"{s}\",\"axiom_policy\":\"{s}\",\"axiom_audit\":\"passed\",\"host_os\":\"{s}\",\"host_arch\":\"{s}\",\"linker\":\"test\",\"lean_version\":\"Lean (version 4.14.0, test)\",\"native_smoke\":\"passed\",\"native_rule_author_promotion_smoke\":\"passed\",\"native_batch_smoke\":\"passed\",\"native_recovery_smoke\":\"passed\",\"native_impact_smoke\":\"passed\",\"native_impact_aggregate_smoke\":\"passed\"}}\n",
        .{
            MANIFEST_SCHEMA,
            runtime.CHECKER_VERSION,
            runtime.REQUEST_SCHEMA,
            runtime.VERDICT_SCHEMA,
            runtime.BATCH_REQUEST_SCHEMA,
            runtime.BATCH_VERDICT_SCHEMA,
            runtime.IMPACT_REQUEST_SCHEMA,
            runtime.IMPACT_VERDICT_SCHEMA,
            runtime.IMPACT_AGGREGATE_REQUEST_SCHEMA,
            runtime.IMPACT_AGGREGATE_VERDICT_SCHEMA,
            runtime.MAX_BATCH_REQUESTS,
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
            AXIOM_POLICY,
            host_os,
            host_arch,
        },
    );
}

const TestSidecar = struct {
    tmp: std.testing.TmpDir,
    checker_path: []u8,
    manifest_path: []u8,

    fn init() !TestSidecar {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
        const checker_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/metacodes-project-kernel", .{root});
        errdefer std.testing.allocator.free(checker_path);
        const manifest_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.provenance.json", .{checker_path});
        return .{ .tmp = tmp, .checker_path = checker_path, .manifest_path = manifest_path };
    }

    fn deinit(self: *TestSidecar) void {
        std.testing.allocator.free(self.manifest_path);
        std.testing.allocator.free(self.checker_path);
        self.tmp.cleanup();
    }

    fn write(self: *TestSidecar, bytes: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "metacodes-project-kernel.provenance.json", .data = bytes });
    }

    fn load(self: *TestSidecar) !Loaded {
        return loadAdjacent(std.testing.allocator, self.checker_path, test_binary_sha256, test_binary_bytes);
    }
};

test "project Kernel provenance is mandatory" {
    var sidecar = try TestSidecar.init();
    defer sidecar.deinit();
    try std.testing.expectError(error.ProvenanceOpenFailed, sidecar.load());
}

test "project Kernel v6 manifest loads and binds binary, sources and host" {
    var sidecar = try TestSidecar.init();
    defer sidecar.deinit();
    const manifest = try testManifest(std.testing.allocator, &test_binary_sha256, test_binary_bytes);
    defer std.testing.allocator.free(manifest);
    try sidecar.write(manifest);

    var loaded = try sidecar.load();
    defer loaded.deinit();
    try std.testing.expectEqualSlices(u8, &formal_provenance.sha256Hex(manifest), &loaded.manifest_sha256);
    try std.testing.expectEqualSlices(u8, &test_binary_sha256, &loaded.binary_sha256);
    try std.testing.expectEqual(test_binary_bytes, loaded.binary_bytes);
    try std.testing.expectEqualStrings("test", loaded.linker);
    try std.testing.expectEqualStrings(manifest, loaded.raw);

    // The binary the manifest describes must be the binary on disk.
    try std.testing.expectError(
        error.ProvenanceBinaryMismatch,
        loadAdjacent(std.testing.allocator, sidecar.checker_path, ("b" ** 64).*, test_binary_bytes),
    );
    try std.testing.expectError(
        error.ProvenanceBinaryMismatch,
        loadAdjacent(std.testing.allocator, sidecar.checker_path, test_binary_sha256, test_binary_bytes + 1),
    );

    const host_os = formal_provenance.expectedHostOs() orelse return error.SkipZigTest;
    const wrong_host = try std.mem.replaceOwned(u8, std.testing.allocator, manifest, host_os, "definitely-wrong-host");
    defer std.testing.allocator.free(wrong_host);
    try sidecar.write(wrong_host);
    try std.testing.expectError(error.ProvenanceHostMismatch, sidecar.load());
}

test "project Kernel loader rejects the formal kernel's manifest and any schema drift" {
    var sidecar = try TestSidecar.init();
    defer sidecar.deinit();
    const manifest = try testManifest(std.testing.allocator, &test_binary_sha256, test_binary_bytes);
    defer std.testing.allocator.free(manifest);

    // The formal v4 manifest names fields this schema does not have
    // (memory/artifact request schemas, a receipt-bound identity) and lacks
    // the batch/impact ones: a different document, not a looser one.
    const formal_manifest = try formal_provenance.testManifest(std.testing.allocator, &test_binary_sha256, test_binary_bytes);
    defer std.testing.allocator.free(formal_manifest);
    try sidecar.write(formal_manifest);
    try std.testing.expectError(error.InvalidProvenanceJson, sidecar.load());

    // Same field set, formal schema tag: a schema mismatch, not a pass.
    const relabelled = try std.mem.replaceOwned(u8, std.testing.allocator, manifest, MANIFEST_SCHEMA, formal_provenance.MANIFEST_SCHEMA);
    defer std.testing.allocator.free(relabelled);
    try sidecar.write(relabelled);
    try std.testing.expectError(error.ProvenanceSchemaMismatch, sidecar.load());

    // A kernel smoked against other bounds than this runtime enforces.
    const bound_needle = try std.fmt.allocPrint(std.testing.allocator, "\"max_impact_aggregate_members\":{d}", .{impact_aggregate.MAX_MEMBERS});
    defer std.testing.allocator.free(bound_needle);
    const bound_other = try std.fmt.allocPrint(std.testing.allocator, "\"max_impact_aggregate_members\":{d}", .{impact_aggregate.MAX_MEMBERS + 1});
    defer std.testing.allocator.free(bound_other);
    const other_bound = try std.mem.replaceOwned(u8, std.testing.allocator, manifest, bound_needle, bound_other);
    defer std.testing.allocator.free(other_bound);
    try std.testing.expect(!std.mem.eql(u8, other_bound, manifest));
    try sidecar.write(other_bound);
    try std.testing.expectError(error.ProvenanceSchemaMismatch, sidecar.load());

    // A smoke the build script did not pass is not "passed".
    const failed_smoke = try std.mem.replaceOwned(u8, std.testing.allocator, manifest, "\"native_recovery_smoke\":\"passed\"", "\"native_recovery_smoke\":\"skipped\"");
    defer std.testing.allocator.free(failed_smoke);
    try sidecar.write(failed_smoke);
    try std.testing.expectError(error.ProvenanceSchemaMismatch, sidecar.load());

    // The formal kernel's axiom policy is wider than this kernel's.
    const wider_axioms = try std.mem.replaceOwned(u8, std.testing.allocator, manifest, "\"axiom_policy\":\"propext\"", "\"axiom_policy\":\"propext,Quot.sound\"");
    defer std.testing.allocator.free(wider_axioms);
    try sidecar.write(wider_axioms);
    try std.testing.expectError(error.ProvenanceSchemaMismatch, sidecar.load());

    // An extra field (a receipt hash this kernel never had) rejects the document.
    const extra_field = try std.mem.replaceOwned(u8, std.testing.allocator, manifest, "\"axiom_audit\":\"passed\"", "\"axiom_audit\":\"passed\",\"artifact_manifest_sha256\":\"" ++ ("0" ** 64) ++ "\"");
    defer std.testing.allocator.free(extra_field);
    try sidecar.write(extra_field);
    try std.testing.expectError(error.InvalidProvenanceJson, sidecar.load());

    // A source digest that is not 64 lowercase hex characters.
    const bad_hash = try std.mem.replaceOwned(u8, std.testing.allocator, manifest, "\"rule_source_sha256\":\"" ++ ("0" ** 64) ++ "\"", "\"rule_source_sha256\":\"" ++ ("0" ** 63) ++ "G\"");
    defer std.testing.allocator.free(bad_hash);
    try std.testing.expect(!std.mem.eql(u8, bad_hash, manifest));
    try sidecar.write(bad_hash);
    try std.testing.expectError(error.InvalidProvenanceHash, sidecar.load());
}
