//! Test-only resolver for the native Lean kernels that kernel-gated tests run.
//!
//! `zig build` stages each kernel from this checkout's own Lean sources and
//! hands the test process only its path (`METACODES_TEST_<KIND>_KERNEL_PATH`):
//! the digest is a build-time fact, so it is read from the provenance sidecar
//! the build script writes beside the binary after its native smoke. An
//! operator may still pin a kernel explicitly with the PATH + SHA256 pair.
//!
//! Unset PATH means "no kernel for this run" and callers skip. Anything else
//! that does not resolve (relative path, malformed digest, missing or
//! unreadable sidecar) is an error, so a broken configuration fails the test
//! instead of turning it into a silent skip.
//!
//! The digest pins the bytes the runtime will execute: `runtime.zig` and
//! `project_harness_runtime.zig` hash the checker before and after every call
//! and fail closed on any difference, so a sidecar that disagrees with its
//! binary fails the test rather than vouching for itself.

const std = @import("std");

pub const Kind = enum {
    formal,
    project,

    pub fn pathVariable(kind: Kind) [:0]const u8 {
        return switch (kind) {
            .formal => "METACODES_TEST_FORMAL_KERNEL_PATH",
            .project => "METACODES_TEST_PROJECT_KERNEL_PATH",
        };
    }

    pub fn digestVariable(kind: Kind) [:0]const u8 {
        return switch (kind) {
            .formal => "METACODES_TEST_FORMAL_KERNEL_SHA256",
            .project => "METACODES_TEST_PROJECT_KERNEL_SHA256",
        };
    }
};

pub const Kernel = struct {
    /// Absolute path; borrowed from the process environment (or the caller's
    /// argument for `resolveFrom`).
    path: []const u8,
    expected_sha256: [64]u8,
};

pub const Error = error{
    /// SHA256 without PATH, a relative PATH, or a malformed SHA256.
    InvalidTestKernelConfig,
    /// PATH without SHA256 and no usable `<PATH>.provenance.json` beside it.
    TestKernelSidecarUnavailable,
};

const sidecar_suffix = ".provenance.json";
const max_sidecar_bytes = 16 * 1024;

/// Resolve `kind` from the process environment. Null = not configured.
pub fn resolve(io: std.Io, kind: Kind) Error!?Kernel {
    const raw_path = std.c.getenv(kind.pathVariable().ptr);
    const raw_digest = std.c.getenv(kind.digestVariable().ptr);
    return resolveFrom(
        io,
        if (raw_path) |value| std.mem.span(value) else null,
        if (raw_digest) |value| std.mem.span(value) else null,
    );
}

/// Same precedence as `resolve`, over explicit values.
pub fn resolveFrom(io: std.Io, path: ?[]const u8, digest: ?[]const u8) Error!?Kernel {
    const checker_path = path orelse {
        if (digest != null) return error.InvalidTestKernelConfig;
        return null;
    };
    if (!std.fs.path.isAbsolute(checker_path)) return error.InvalidTestKernelConfig;
    if (digest) |text| {
        const expected = parseLowerHex64(text) orelse return error.InvalidTestKernelConfig;
        return .{ .path = checker_path, .expected_sha256 = expected };
    }
    return .{ .path = checker_path, .expected_sha256 = try sidecarDigest(io, checker_path) };
}

fn sidecarDigest(io: std.Io, checker_path: []const u8) Error![64]u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const sidecar_path = std.fmt.bufPrint(&path_buffer, "{s}{s}", .{ checker_path, sidecar_suffix }) catch
        return error.TestKernelSidecarUnavailable;
    var bytes_buffer: [max_sidecar_bytes]u8 = undefined;
    const bytes = std.Io.Dir.cwd().readFile(io, sidecar_path, &bytes_buffer) catch
        return error.TestKernelSidecarUnavailable;
    if (bytes.len == bytes_buffer.len) return error.TestKernelSidecarUnavailable;
    var parse_buffer: [max_sidecar_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&parse_buffer);
    const Sidecar = struct { binary_sha256: []const u8 };
    const sidecar = std.json.parseFromSliceLeaky(Sidecar, fba.allocator(), bytes, .{
        .ignore_unknown_fields = true,
    }) catch return error.TestKernelSidecarUnavailable;
    return parseLowerHex64(sidecar.binary_sha256) orelse error.TestKernelSidecarUnavailable;
}

fn parseLowerHex64(text: []const u8) ?[64]u8 {
    if (text.len != 64) return null;
    var result: [64]u8 = undefined;
    for (text, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        result[index] = byte;
    }
    return result;
}

const digest_a = "a" ** 64;

fn writeFixture(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
}

fn tmpRoot(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

test "unset path is not configured, digest alone is a config error" {
    try std.testing.expectEqual(@as(?Kernel, null), try resolveFrom(std.testing.io, null, null));
    try std.testing.expectError(error.InvalidTestKernelConfig, resolveFrom(std.testing.io, null, digest_a));
}

test "explicit pair wins over the sidecar and is validated" {
    const kernel = (try resolveFrom(std.testing.io, "/nonexistent/kernel", digest_a)).?;
    try std.testing.expectEqualStrings(digest_a, &kernel.expected_sha256);
    try std.testing.expectError(error.InvalidTestKernelConfig, resolveFrom(std.testing.io, "relative/kernel", digest_a));
    try std.testing.expectError(error.InvalidTestKernelConfig, resolveFrom(std.testing.io, "/k", "A" ** 64));
    try std.testing.expectError(error.InvalidTestKernelConfig, resolveFrom(std.testing.io, "/k", "a" ** 63));
}

test "path alone takes the digest from the provenance sidecar" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "kernel", "binary");
    try writeFixture(tmp.dir, "kernel.provenance.json", "{\"schema_version\":\"x\",\"binary_sha256\":\"" ++ "b" ** 64 ++ "\",\"n\":1}");
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/kernel", .{root});
    const kernel = (try resolveFrom(std.testing.io, path, null)).?;
    try std.testing.expectEqualStrings("b" ** 64, &kernel.expected_sha256);
    try std.testing.expectEqualStrings(path, kernel.path);
}

test "path alone without a usable sidecar fails instead of skipping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/kernel", .{root});
    try std.testing.expectError(error.TestKernelSidecarUnavailable, resolveFrom(std.testing.io, path, null));
    try writeFixture(tmp.dir, "kernel.provenance.json", "{\"binary_sha256\":\"" ++ "B" ** 64 ++ "\"}");
    try std.testing.expectError(error.TestKernelSidecarUnavailable, resolveFrom(std.testing.io, path, null));
    try writeFixture(tmp.dir, "kernel.provenance.json", "{\"schema_version\":\"x\"}");
    try std.testing.expectError(error.TestKernelSidecarUnavailable, resolveFrom(std.testing.io, path, null));
    try writeFixture(tmp.dir, "kernel.provenance.json", "not json");
    try std.testing.expectError(error.TestKernelSidecarUnavailable, resolveFrom(std.testing.io, path, null));
}
