//! Strict loader for the build-time provenance shipped beside the Lean kernel.
//!
//! Runtime binary hashing proves which bytes were executed. This manifest
//! additionally freezes the Lean/source/toolchain identity used to build those
//! bytes. It is hash-linked research provenance, not a signature or protection
//! against a malicious same-user replacing both binary and configuration.

const std = @import("std");
const pfs = @import("platform").fs;
const runtime = @import("runtime.zig");

pub const MANIFEST_SCHEMA = "metacodes-formal-artifact-v1";
const MAX_MANIFEST_BYTES: usize = 64 * 1024;

const Raw = struct {
    schema_version: []const u8,
    checker_version: []const u8,
    request_schema: []const u8,
    verdict_schema: []const u8,
    binary_sha256: []const u8,
    binary_bytes: u64,
    kernel_source_sha256: []const u8,
    main_source_sha256: []const u8,
    axiom_audit_source_sha256: []const u8,
    axiom_policy: []const u8,
    axiom_audit: []const u8,
    host_os: []const u8,
    host_arch: []const u8,
    linker: []const u8,
    lean_version: []const u8,
    native_smoke: []const u8,
    built_at_utc: []const u8,
};

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    raw: []const u8,
    manifest_sha256: [64]u8,
    binary_sha256: [64]u8,
    binary_bytes: u64,
    kernel_source_sha256: [64]u8,
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
        !std.mem.eql(u8, parsed.verdict_schema, runtime.VERDICT_SCHEMA) or
        !std.mem.eql(u8, parsed.axiom_policy, "propext,Quot.sound") or
        !std.mem.eql(u8, parsed.axiom_audit, "passed") or
        !std.mem.eql(u8, parsed.native_smoke, "passed"))
        return error.ProvenanceSchemaMismatch;

    const binary_sha256 = parseLowerHex64(parsed.binary_sha256) orelse
        return error.InvalidProvenanceHash;
    const kernel_source_sha256 = parseLowerHex64(parsed.kernel_source_sha256) orelse
        return error.InvalidProvenanceHash;
    const main_source_sha256 = parseLowerHex64(parsed.main_source_sha256) orelse
        return error.InvalidProvenanceHash;
    const axiom_audit_source_sha256 = parseLowerHex64(parsed.axiom_audit_source_sha256) orelse
        return error.InvalidProvenanceHash;
    if (!std.mem.eql(u8, &binary_sha256, &expected_binary_sha256) or
        parsed.binary_bytes != expected_binary_bytes)
        return error.ProvenanceBinaryMismatch;
    if (!validLabel(parsed.host_os, 64) or !validLabel(parsed.host_arch, 64) or
        !validLabel(parsed.linker, 64) or !validLabel(parsed.lean_version, 512) or
        !validLabel(parsed.built_at_utc, 64))
        return error.InvalidProvenanceText;

    return .{
        .arena = arena,
        .raw = raw,
        .manifest_sha256 = sha256Hex(raw),
        .binary_sha256 = binary_sha256,
        .binary_bytes = parsed.binary_bytes,
        .kernel_source_sha256 = kernel_source_sha256,
        .main_source_sha256 = main_source_sha256,
        .axiom_audit_source_sha256 = axiom_audit_source_sha256,
        .host_os = parsed.host_os,
        .host_arch = parsed.host_arch,
        .linker = parsed.linker,
        .lean_version = parsed.lean_version,
        .built_at_utc = parsed.built_at_utc,
    };
}

fn readBounded(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
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

fn parseLowerHex64(raw: []const u8) ?[64]u8 {
    if (raw.len != 64) return null;
    var result: [64]u8 = undefined;
    for (raw, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        result[index] = byte;
    }
    return result;
}

fn validLabel(raw: []const u8, max: usize) bool {
    if (raw.len == 0 or raw.len > max) return false;
    for (raw) |byte| if (byte < 0x20 or byte > 0x7e) return false;
    return true;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
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
