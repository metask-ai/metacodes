//! What the two host-side manifest generators share (#80): the source
//! identity from git, streaming SHA-256 of an installed file, atomic writes,
//! and the package target id. `agentcore_manifest.zig` (the AgentCore bundle)
//! and `release_manifest.zig` (the CLI release unit) import this file; each
//! keeps its own schema, because the two units are different products.
const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const SourceIdentity = struct {
    /// 40 lowercase hex characters.
    commit: []const u8,
    /// Any tracked or untracked change under the repository root.
    dirty: bool,
};

/// `git rev-parse HEAD` and `git status --porcelain` for the current directory
/// (the build graph runs the tools from the repository root).
pub fn sourceIdentity(allocator: std.mem.Allocator, io: std.Io, tool_name: []const u8) !SourceIdentity {
    const commit_output = try runGit(allocator, io, tool_name, &.{ "git", "rev-parse", "HEAD" });
    const commit = std.mem.trim(u8, commit_output, " \r\n\t");
    if (commit.len != 40 or !isLowerHex(commit)) return error.InvalidGitCommit;
    const status = try runGit(allocator, io, tool_name, &.{
        "git", "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--", ".",
    });
    return .{ .commit = commit, .dirty = status.len != 0 };
}

/// The tag that points exactly at HEAD, or null when HEAD is untagged; a
/// stable release refuses to describe itself without one.
pub fn exactTag(allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "describe", "--tags", "--exact-match", "HEAD" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(64 * 1024),
    });
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const tag = std.mem.trim(u8, result.stdout, " \r\n\t");
    return if (tag.len == 0) null else tag;
}

pub fn runGit(allocator: std.mem.Allocator, io: std.Io, tool_name: []const u8, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(512 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    std.debug.print("{s}: git command failed: {s}\n", .{ tool_name, result.stderr });
    return error.GitCommandFailed;
}

/// Streaming SHA-256 of a file, 64 KiB at a time.
pub fn fileSha256(io: std.Io, path: []const u8) ![32]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var hash = Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try file.readPositional(io, &.{&buffer}, offset);
        if (count == 0) break;
        hash.update(buffer[0..count]);
        offset += count;
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

/// Write-then-rename so a reader never sees a partial manifest; creates the
/// parent directories.
pub fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .replace = true,
        .make_path = true,
    });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, bytes);
    try atomic_file.replace(io);
}

pub fn writeBundleFile(allocator: std.mem.Allocator, io: std.Io, bundle_root: []const u8, relative_path: []const u8, bytes: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ bundle_root, relative_path });
    try writeAtomic(io, path, bytes);
}

/// `<arch>-macos` on macOS (one universal id per architecture), otherwise
/// `<arch>-<os>-<abi>`.
pub fn packageTargetId(allocator: std.mem.Allocator, architecture: []const u8, os: []const u8, abi: []const u8) ![]const u8 {
    return if (std.mem.eql(u8, os, "macos"))
        std.fmt.allocPrint(allocator, "{s}-macos", .{architecture})
    else
        std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ architecture, os, abi });
}

pub fn isLowerHex(bytes: []const u8) bool {
    for (bytes) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

test "package target id folds macOS into one id per architecture" {
    const allocator = std.testing.allocator;
    const macos = try packageTargetId(allocator, "aarch64", "macos", "none");
    defer allocator.free(macos);
    try std.testing.expectEqualStrings("aarch64-macos", macos);
    const linux = try packageTargetId(allocator, "x86_64", "linux", "gnu");
    defer allocator.free(linux);
    try std.testing.expectEqualStrings("x86_64-linux-gnu", linux);
}

test "lowercase hex accepts digests and rejects everything else" {
    try std.testing.expect(isLowerHex("0123456789abcdef"));
    try std.testing.expect(!isLowerHex("ABCDEF"));
    try std.testing.expect(!isLowerHex("xyz"));
}
