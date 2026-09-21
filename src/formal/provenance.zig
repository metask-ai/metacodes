//! Strict loader for the build-time provenance shipped beside the Lean kernel.
//!
//! Runtime binary hashing proves which bytes were executed. This manifest
//! additionally freezes the Lean/source/toolchain identity used to build those
//! bytes. It is hash-linked research provenance, not a signature or protection
//! against a malicious same-user replacing both binary and configuration.

const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const runtime = @import("runtime.zig");

pub const MANIFEST_SCHEMA = "metacodes-formal-artifact-v4";
pub const BUILD_RECEIPT_SCHEMA = "metacodes-formal-build-receipt-v1";
const MAX_MANIFEST_BYTES: usize = 64 * 1024;

const Raw = struct {
    schema_version: []const u8,
    checker_version: []const u8,
    request_schema: []const u8,
    memory_request_schema: []const u8,
    artifact_request_schema: []const u8,
    verdict_schema: []const u8,
    binary_sha256: []const u8,
    binary_bytes: u64,
    kernel_source_sha256: []const u8,
    memory_kernel_source_sha256: []const u8,
    artifact_kernel_source_sha256: []const u8,
    main_source_sha256: []const u8,
    axiom_audit_source_sha256: []const u8,
    axiom_policy: []const u8,
    axiom_audit: []const u8,
    host_os: []const u8,
    host_arch: []const u8,
    linker: []const u8,
    lean_version: []const u8,
    native_smoke: []const u8,
};

const RawBuildReceipt = struct {
    schema_version: []const u8,
    artifact_manifest_sha256: []const u8,
    binary_sha256: []const u8,
    built_at_utc: []const u8,
};

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    raw: []const u8,
    build_receipt_raw: []const u8,
    manifest_sha256: [64]u8,
    build_receipt_sha256: [64]u8,
    binary_sha256: [64]u8,
    binary_bytes: u64,
    kernel_source_sha256: [64]u8,
    memory_kernel_source_sha256: [64]u8,
    artifact_kernel_source_sha256: [64]u8,
    main_source_sha256: [64]u8,
    axiom_audit_source_sha256: [64]u8,
    host_os: []const u8,
    host_arch: []const u8,
    linker: []const u8,
    lean_version: []const u8,
    built_at_utc: []const u8,

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
    const raw = try readBounded(a, path);
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
        !std.mem.eql(u8, parsed.memory_request_schema, runtime.MEMORY_REQUEST_SCHEMA) or
        !std.mem.eql(u8, parsed.artifact_request_schema, runtime.ARTIFACT_REQUEST_SCHEMA) or
        !std.mem.eql(u8, parsed.verdict_schema, runtime.VERDICT_SCHEMA) or
        !std.mem.eql(u8, parsed.axiom_policy, "propext,Quot.sound") or
        !std.mem.eql(u8, parsed.axiom_audit, "passed") or
        !std.mem.eql(u8, parsed.native_smoke, "passed"))
        return error.ProvenanceSchemaMismatch;

    const manifest_sha256 = sha256Hex(raw);
    const binary_sha256 = parseLowerHex64(parsed.binary_sha256) orelse
        return error.InvalidProvenanceHash;
    const kernel_source_sha256 = parseLowerHex64(parsed.kernel_source_sha256) orelse
        return error.InvalidProvenanceHash;
    const memory_kernel_source_sha256 = parseLowerHex64(parsed.memory_kernel_source_sha256) orelse
        return error.InvalidProvenanceHash;
    const artifact_kernel_source_sha256 = parseLowerHex64(parsed.artifact_kernel_source_sha256) orelse
        return error.InvalidProvenanceHash;
    const main_source_sha256 = parseLowerHex64(parsed.main_source_sha256) orelse
        return error.InvalidProvenanceHash;
    const axiom_audit_source_sha256 = parseLowerHex64(parsed.axiom_audit_source_sha256) orelse
        return error.InvalidProvenanceHash;
    if (!std.mem.eql(u8, &binary_sha256, &expected_binary_sha256) or
        parsed.binary_bytes != expected_binary_bytes)
        return error.ProvenanceBinaryMismatch;
    if (!validLabel(parsed.host_os, 64) or !validLabel(parsed.host_arch, 64) or
        !validLabel(parsed.linker, 64) or !validLabel(parsed.lean_version, 512))
        return error.InvalidProvenanceText;
    const host_os = expectedHostOs() orelse return error.UnsupportedProvenanceHost;
    const host_arch = expectedHostArch() orelse return error.UnsupportedProvenanceHost;
    if (!std.mem.eql(u8, parsed.host_os, host_os) or
        !std.mem.eql(u8, parsed.host_arch, host_arch))
        return error.ProvenanceHostMismatch;

    // Per-build wall-clock facts deliberately live outside the stable
    // artifact identity. Both files are mandatory and hash-bound: accepting
    // the v3 manifest without its receipt would make the runtime report an
    // ungrounded build timestamp, while accepting an unbound receipt would
    // let provenance from another artifact be spliced in.
    const build_receipt_path = try std.fmt.allocPrint(a, "{s}.build-receipt.json", .{checker_path});
    const build_receipt_raw = try readBounded(a, build_receipt_path);
    const build_receipt = std.json.parseFromSliceLeaky(RawBuildReceipt, a, build_receipt_raw, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidBuildReceiptJson,
    };
    const receipt_manifest_sha256 = parseLowerHex64(build_receipt.artifact_manifest_sha256) orelse
        return error.InvalidBuildReceiptHash;
    const receipt_binary_sha256 = parseLowerHex64(build_receipt.binary_sha256) orelse
        return error.InvalidBuildReceiptHash;
    if (!std.mem.eql(u8, build_receipt.schema_version, BUILD_RECEIPT_SCHEMA))
        return error.BuildReceiptSchemaMismatch;
    if (!std.mem.eql(u8, &receipt_manifest_sha256, &manifest_sha256) or
        !std.mem.eql(u8, &receipt_binary_sha256, &binary_sha256))
        return error.BuildReceiptBindingMismatch;
    if (!validUtcTimestamp(build_receipt.built_at_utc)) return error.InvalidBuildReceiptTimestamp;

    return .{
        .arena = arena,
        .raw = raw,
        .build_receipt_raw = build_receipt_raw,
        .manifest_sha256 = manifest_sha256,
        .build_receipt_sha256 = sha256Hex(build_receipt_raw),
        .binary_sha256 = binary_sha256,
        .binary_bytes = parsed.binary_bytes,
        .kernel_source_sha256 = kernel_source_sha256,
        .memory_kernel_source_sha256 = memory_kernel_source_sha256,
        .artifact_kernel_source_sha256 = artifact_kernel_source_sha256,
        .main_source_sha256 = main_source_sha256,
        .axiom_audit_source_sha256 = axiom_audit_source_sha256,
        .host_os = parsed.host_os,
        .host_arch = parsed.host_arch,
        .linker = parsed.linker,
        .lean_version = parsed.lean_version,
        .built_at_utc = build_receipt.built_at_utc,
    };
}

pub fn readBounded(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ProvenanceOpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.ProvenanceStatFailed;
    if (!before.is_regular or before.size == 0 or before.size > MAX_MANIFEST_BYTES)
        return error.ProvenanceSizeInvalid;
    const size: usize = @intCast(before.size);
    const bytes = try allocator.alloc(u8, size);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.readZ(fd, bytes[offset..]) catch return error.ProvenanceReadFailed;
        if (count == 0) return error.ProvenanceChangedDuringRead;
        offset += count;
    }
    var probe: [1]u8 = undefined;
    if ((pfs.readZ(fd, &probe) catch return error.ProvenanceReadFailed) != 0)
        return error.ProvenanceChangedDuringRead;
    const after = pfs.fileInfo(fd) catch return error.ProvenanceChangedDuringRead;
    if (!after.is_regular or after.size != before.size)
        return error.ProvenanceChangedDuringRead;
    return bytes;
}

pub fn parseLowerHex64(raw: []const u8) ?[64]u8 {
    if (raw.len != 64) return null;
    var result: [64]u8 = undefined;
    for (raw, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        result[index] = byte;
    }
    return result;
}

pub fn validLabel(raw: []const u8, max: usize) bool {
    if (raw.len == 0 or raw.len > max) return false;
    for (raw) |byte| if (byte < 0x20 or byte > 0x7e) return false;
    return true;
}

pub fn expectedHostOs() ?[]const u8 {
    return switch (builtin.os.tag) {
        .macos => "Darwin",
        .linux => "Linux",
        .windows => "Windows",
        else => null,
    };
}

pub fn expectedHostArch() ?[]const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => if (builtin.os.tag == .macos) "arm64" else "aarch64",
        else => null,
    };
}

fn validUtcTimestamp(raw: []const u8) bool {
    if (raw.len != 20 or raw[4] != '-' or raw[7] != '-' or raw[10] != 'T' or
        raw[13] != ':' or raw[16] != ':' or raw[19] != 'Z') return false;
    for (raw, 0..) |byte, index| switch (index) {
        4, 7, 10, 13, 16, 19 => {},
        else => if (!std.ascii.isDigit(byte)) return false,
    };
    const year = std.fmt.parseInt(u16, raw[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, raw[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, raw[8..10], 10) catch return false;
    const hour = std.fmt.parseInt(u8, raw[11..13], 10) catch return false;
    const minute = std.fmt.parseInt(u8, raw[14..16], 10) catch return false;
    const second = std.fmt.parseInt(u8, raw[17..19], 10) catch return false;
    if (year == 0 or month == 0 or month > 12 or hour > 23 or minute > 59 or second > 59)
        return false;
    const leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    const days_in_month = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return day > 0 and day <= days_in_month[month - 1];
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

// ── test fixtures (shared with app/doctor.zig and project_provenance.zig) ────

/// The manifest `scripts/build-formal-kernel.sh` writes, field for field, with
/// the runtime's own constants substituted; the caller owns it.
pub fn testManifest(allocator: std.mem.Allocator, binary_sha256: []const u8, binary_bytes: u64) ![]u8 {
    const host_os = expectedHostOs() orelse return error.SkipZigTest;
    const host_arch = expectedHostArch() orelse return error.SkipZigTest;
    const zeros = "0" ** 64;
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"{s}\",\"checker_version\":\"{s}\",\"request_schema\":\"{s}\",\"memory_request_schema\":\"{s}\",\"artifact_request_schema\":\"{s}\",\"verdict_schema\":\"{s}\",\"binary_sha256\":\"{s}\",\"binary_bytes\":{d},\"kernel_source_sha256\":\"{s}\",\"memory_kernel_source_sha256\":\"{s}\",\"artifact_kernel_source_sha256\":\"{s}\",\"main_source_sha256\":\"{s}\",\"axiom_audit_source_sha256\":\"{s}\",\"axiom_policy\":\"propext,Quot.sound\",\"axiom_audit\":\"passed\",\"host_os\":\"{s}\",\"host_arch\":\"{s}\",\"linker\":\"test\",\"lean_version\":\"Lean (version 4.14.0, test)\",\"native_smoke\":\"passed\"}}\n",
        .{ MANIFEST_SCHEMA, runtime.CHECKER_VERSION, runtime.REQUEST_SCHEMA, runtime.MEMORY_REQUEST_SCHEMA, runtime.ARTIFACT_REQUEST_SCHEMA, runtime.VERDICT_SCHEMA, binary_sha256, binary_bytes, zeros, zeros, zeros, zeros, zeros, host_os, host_arch },
    );
}

/// The receipt that binds `manifest` and the binary; the caller owns it.
pub fn testBuildReceipt(allocator: std.mem.Allocator, manifest: []const u8, binary_sha256: []const u8) ![]u8 {
    const manifest_sha256 = sha256Hex(manifest);
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"{s}\",\"artifact_manifest_sha256\":\"{s}\",\"binary_sha256\":\"{s}\",\"built_at_utc\":\"2026-01-01T00:00:00Z\"}}\n",
        .{ BUILD_RECEIPT_SCHEMA, manifest_sha256[0..], binary_sha256 },
    );
}

test "formal checker provenance is mandatory for a deployable admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const checker_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/checker-without-manifest",
        .{root_buffer[0..root_len]},
    );
    defer std.testing.allocator.free(checker_path);
    try std.testing.expectError(
        error.ProvenanceOpenFailed,
        loadAdjacent(
            std.testing.allocator,
            checker_path,
            ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").*,
            1,
        ),
    );
}

test "formal v4 provenance requires a hash-bound build receipt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const checker_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/checker",
        .{root_buffer[0..root_len]},
    );
    defer std.testing.allocator.free(checker_path);
    const expected_binary_sha256 =
        ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").*;
    const host_os = expectedHostOs() orelse return error.SkipZigTest;
    const host_arch = expectedHostArch() orelse return error.SkipZigTest;
    const manifest = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":\"metacodes-formal-artifact-v4\",\"checker_version\":\"metacodes-formal-kernel-v2\",\"request_schema\":\"metacodes-formal-request-v1\",\"memory_request_schema\":\"metacodes-memory-migration-request-v1\",\"artifact_request_schema\":\"metacodes-artifact-verification-request-v1\",\"verdict_schema\":\"metacodes-formal-verdict-v2\",\"binary_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"binary_bytes\":7,\"kernel_source_sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"memory_kernel_source_sha256\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"artifact_kernel_source_sha256\":\"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"main_source_sha256\":\"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"axiom_audit_source_sha256\":\"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"axiom_policy\":\"propext,Quot.sound\",\"axiom_audit\":\"passed\",\"host_os\":\"{s}\",\"host_arch\":\"{s}\",\"linker\":\"test\",\"lean_version\":\"Lean test\",\"native_smoke\":\"passed\"}}\n",
        .{ host_os, host_arch },
    );
    defer std.testing.allocator.free(manifest);
    const manifest_hash = sha256Hex(manifest);
    const manifest_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}.provenance.json",
        .{checker_path},
    );
    defer std.testing.allocator.free(manifest_path);
    const receipt_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}.build-receipt.json",
        .{checker_path},
    );
    defer std.testing.allocator.free(receipt_path);
    try writeFixture(manifest_path, manifest);
    const receipt = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":\"{s}\",\"artifact_manifest_sha256\":\"{s}\",\"binary_sha256\":\"{s}\",\"built_at_utc\":\"2026-08-08T00:00:00Z\"}}\n",
        .{ BUILD_RECEIPT_SCHEMA, manifest_hash[0..], expected_binary_sha256[0..] },
    );
    defer std.testing.allocator.free(receipt);
    try writeFixture(receipt_path, receipt);

    var loaded = try loadAdjacent(std.testing.allocator, checker_path, expected_binary_sha256, 7);
    defer loaded.deinit();
    try std.testing.expectEqualSlices(u8, &manifest_hash, &loaded.manifest_sha256);
    const receipt_hash = sha256Hex(receipt);
    try std.testing.expectEqualSlices(u8, &receipt_hash, &loaded.build_receipt_sha256);
    try std.testing.expectEqualStrings("2026-08-08T00:00:00Z", loaded.built_at_utc);
    try std.testing.expectEqualStrings(receipt, loaded.build_receipt_raw);

    const wrong_host_manifest = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        manifest,
        host_os,
        "definitely-wrong-host",
    );
    defer std.testing.allocator.free(wrong_host_manifest);
    try writeFixture(manifest_path, wrong_host_manifest);
    try std.testing.expectError(
        error.ProvenanceHostMismatch,
        loadAdjacent(std.testing.allocator, checker_path, expected_binary_sha256, 7),
    );
    try writeFixture(manifest_path, manifest);

    const wrong_receipt =
        "{\"schema_version\":\"metacodes-formal-build-receipt-v1\",\"artifact_manifest_sha256\":\"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"binary_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"built_at_utc\":\"2026-08-08T00:00:00Z\"}\n";
    try writeFixture(receipt_path, wrong_receipt);
    try std.testing.expectError(
        error.BuildReceiptBindingMismatch,
        loadAdjacent(std.testing.allocator, checker_path, expected_binary_sha256, 7),
    );

    try writeFixture(receipt_path, "{not-json}\n");
    try std.testing.expectError(
        error.InvalidBuildReceiptJson,
        loadAdjacent(std.testing.allocator, checker_path, expected_binary_sha256, 7),
    );

    const impossible_date_receipt = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":\"{s}\",\"artifact_manifest_sha256\":\"{s}\",\"binary_sha256\":\"{s}\",\"built_at_utc\":\"2026-02-31T00:00:00Z\"}}\n",
        .{ BUILD_RECEIPT_SCHEMA, manifest_hash[0..], expected_binary_sha256[0..] },
    );
    defer std.testing.allocator.free(impossible_date_receipt);
    try writeFixture(receipt_path, impossible_date_receipt);
    try std.testing.expectError(
        error.InvalidBuildReceiptTimestamp,
        loadAdjacent(std.testing.allocator, checker_path, expected_binary_sha256, 7),
    );
}

fn writeFixture(path: []const u8, bytes: []const u8) !void {
    const path_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(path_z);
    const fd = pfs.open(
        path_z.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true },
        @as(std.c.mode_t, 0o600),
    );
    if (fd < 0) return error.FixtureOpenFailed;
    defer _ = pfs.close(fd);
    if (pfs.write(fd, bytes) != @as(isize, @intCast(bytes.len)))
        return error.FixtureWriteFailed;
}
