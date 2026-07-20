const std = @import("std");
const builtin = @import("builtin");

const Sha256 = std.crypto.hash.sha2.Sha256;

const FileEntry = struct {
    path: []const u8,
    sha256: []const u8,
};

const Manifest = struct {
    schema_version: u32 = 1,
    name: []const u8 = "metask-agentcore",
    version: []const u8,
    source: struct {
        commit: []const u8,
        dirty: bool,
        dirty_source_sha256: []const u8,
    },
    toolchain: struct { zig_version: []const u8 },
    build: struct {
        resolved_target: []const u8,
        architecture: []const u8,
        os: []const u8,
        abi: []const u8,
        optimize: []const u8,
        strip: bool,
    },
    contract: struct {
        binary_abi_version: u32 = 1,
        binary_abi_revision: u32 = 3,
        required_system_link_inputs: []const []const u8,
        ui_request_mode: []const u8 = "synchronous",
    },
    files: []const FileEntry,
};

const SourceIdentity = struct {
    commit: []const u8,
    dirty: bool,
    dirty_digest: [64]u8,
};

const DigestEntry = struct {
    path: []const u8,
    digest: [32]u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = std.process.Args.iterateAllocator(init.minimal.args, allocator) catch
        return error.InvalidArguments;
    defer args.deinit();
    _ = args.next();

    const bundle_root = args.next() orelse return usage();
    const resolved_target = args.next() orelse return usage();
    const architecture = args.next() orelse return usage();
    const os = args.next() orelse return usage();
    const abi = args.next() orelse return usage();
    const optimize = args.next() orelse return usage();
    const strip_text = args.next() orelse return usage();
    const library_file = args.next() orelse return usage();
    if (args.next() != null) return usage();

    if (bundle_root.len == 0 or resolved_target.len == 0 or architecture.len == 0 or
        os.len == 0 or abi.len == 0 or optimize.len == 0 or library_file.len == 0)
        return error.EmptyMetadata;
    const strip = parseBool(strip_text) orelse return error.InvalidBoolean;

    const library_rel = try std.fmt.allocPrint(allocator, "lib/{s}", .{library_file});
    const relative_paths = [_][]const u8{
        library_rel,
        "include/metask_agentcore.h",
        "sdk/metask_agentcore.zig",
        "sdk/metask_agentcore_protocol.zig",
        "sdk/metask_agentcore_types.zig",
    };

    var digests: [relative_paths.len][64]u8 = undefined;
    var files: [relative_paths.len]FileEntry = undefined;
    for (relative_paths, 0..) |relative_path, index| {
        const installed_path = try std.fs.path.join(allocator, &.{ bundle_root, relative_path });
        digests[index] = std.fmt.bytesToHex(try fileSha256(init.io, installed_path), .lower);
        files[index] = .{ .path = relative_path, .sha256 = &digests[index] };
    }

    const source = try sourceIdentity(allocator, init.io, bundle_root);
    const sdk_version_bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        "sdk/VERSION",
        allocator,
        .limited(256),
    );
    const sdk_version = std.mem.trim(u8, sdk_version_bytes, " \r\n\t");
    const version = try packageVersion(allocator, sdk_version, source);
    const sdk_semver = std.SemanticVersion.parse(sdk_version) catch return error.InvalidSdkVersion;
    if (sdk_semver.pre == null)
        try requireStableTag(allocator, init.io, sdk_version, source.commit);
    const default_link_inputs = [_][]const u8{"libc"};
    const windows_link_inputs = [_][]const u8{ "libc", "crypt32" };
    const required_link_inputs: []const []const u8 = if (std.mem.eql(u8, os, "windows"))
        &windows_link_inputs
    else
        &default_link_inputs;

    const manifest = Manifest{
        .version = version,
        .source = .{
            .commit = source.commit,
            .dirty = source.dirty,
            .dirty_source_sha256 = if (source.dirty) &source.dirty_digest else "",
        },
        .toolchain = .{ .zig_version = builtin.zig_version_string },
        .build = .{
            .resolved_target = resolved_target,
            .architecture = architecture,
            .os = os,
            .abi = abi,
            .optimize = optimize,
            .strip = strip,
        },
        .contract = .{ .required_system_link_inputs = required_link_inputs },
        .files = &files,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, manifest, .{ .whitespace = .indent_2 });
    const json_with_newline = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
    const manifest_path = try std.fs.path.join(allocator, &.{ bundle_root, "manifest.json" });
    try writeAtomic(init.io, manifest_path, json_with_newline);
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        "usage: agentcore-manifest <bundle-root> <target> <arch> <os> <abi> <optimize> <strip> <library-file>\n",
        .{},
    );
    return error.InvalidArguments;
}

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

fn packageVersion(allocator: std.mem.Allocator, sdk_version: []const u8, source: SourceIdentity) ![]const u8 {
    if (sdk_version.len == 0) return error.InvalidSdkVersion;
    const parsed = std.SemanticVersion.parse(sdk_version) catch return error.InvalidSdkVersion;
    if (parsed.build != null) return error.InvalidSdkVersion;

    if (parsed.pre == null) {
        if (source.dirty) return error.DirtyStableVersion;
        return allocator.dupe(u8, sdk_version);
    }

    const commit_short = source.commit[0..12];
    return if (source.dirty)
        std.fmt.allocPrint(allocator, "{s}+{s}.dirty.{s}", .{ sdk_version, commit_short, source.dirty_digest[0..12] })
    else
        std.fmt.allocPrint(allocator, "{s}+{s}", .{ sdk_version, commit_short });
}

fn requireStableTag(allocator: std.mem.Allocator, io: std.Io, version: []const u8, commit: []const u8) !void {
    const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/agentcore-v{s}^{{commit}}", .{version});
    const output = try runGit(allocator, io, &.{ "git", "rev-parse", "--verify", "--quiet", tag_ref });
    const tag_commit = std.mem.trim(u8, output, " \r\n\t");
    if (!std.mem.eql(u8, tag_commit, commit)) return error.StableTagMismatch;
}

fn fileSha256(io: std.Io, path: []const u8) ![32]u8 {
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

fn sourceIdentity(allocator: std.mem.Allocator, io: std.Io, bundle_root: []const u8) !SourceIdentity {
    const commit_output = try runGit(allocator, io, &.{ "git", "rev-parse", "HEAD" });
    const commit = std.mem.trim(u8, commit_output, " \r\n\t");
    if (commit.len != 40 or !isLowerHex(commit)) return error.InvalidGitCommit;

    const repo_root_output = try runGit(allocator, io, &.{ "git", "rev-parse", "--show-toplevel" });
    const repo_root = std.mem.trim(u8, repo_root_output, " \r\n\t");
    const repo_prefix_output = try runGit(allocator, io, &.{ "git", "rev-parse", "--show-prefix" });
    const repo_prefix = std.mem.trim(u8, repo_prefix_output, " \r\n\t");
    const source_pathspec = try std.fmt.allocPrint(allocator, ":(top){s}**", .{repo_prefix});
    const exclude_pathspec = try bundleExcludePathspec(allocator, repo_root, bundle_root);

    var status_args = std.ArrayList([]const u8).empty;
    try status_args.appendSlice(allocator, &.{ "git", "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--", source_pathspec });
    if (exclude_pathspec) |exclude| try status_args.append(allocator, exclude);
    const status = try runGit(allocator, io, status_args.items);
    if (status.len == 0) return .{ .commit = commit, .dirty = false, .dirty_digest = undefined };

    var diff_args = std.ArrayList([]const u8).empty;
    try diff_args.appendSlice(allocator, &.{ "git", "diff", "HEAD", "--binary", "--", source_pathspec });
    if (exclude_pathspec) |exclude| try diff_args.append(allocator, exclude);
    const diff = try runGit(allocator, io, diff_args.items);

    var untracked_args = std.ArrayList([]const u8).empty;
    try untracked_args.appendSlice(allocator, &.{ "git", "ls-files", "--others", "--exclude-standard", "-z", "--", source_pathspec });
    if (exclude_pathspec) |exclude| try untracked_args.append(allocator, exclude);
    const untracked_output = try runGit(allocator, io, untracked_args.items);
    var untracked = std.ArrayList(DigestEntry).empty;
    var names = std.mem.splitScalar(u8, untracked_output, 0);
    while (names.next()) |path| {
        if (path.len == 0) continue;
        try untracked.append(allocator, .{ .path = path, .digest = try fileSha256(io, path) });
    }
    return .{
        .commit = commit,
        .dirty = true,
        .dirty_digest = dirtySourceDigest(diff, untracked.items),
    };
}

fn bundleExcludePathspec(allocator: std.mem.Allocator, repo_root: []const u8, bundle_root: []const u8) !?[]const u8 {
    const bundle_absolute = if (std.fs.path.isAbsolute(bundle_root))
        try allocator.dupe(u8, bundle_root)
    else
        try std.fs.path.resolve(allocator, &.{bundle_root});
    defer allocator.free(bundle_absolute);
    const relative = std.fs.path.relative(allocator, ".", null, repo_root, bundle_absolute) catch return null;
    defer allocator.free(relative);
    if (std.fs.path.isAbsolute(relative) or relative.len == 0 or std.mem.eql(u8, relative, ".") or
        std.mem.eql(u8, relative, "..") or std.mem.startsWith(u8, relative, "../") or
        std.mem.startsWith(u8, relative, "..\\"))
        return null;
    const normalized = try allocator.dupe(u8, relative);
    defer allocator.free(normalized);
    for (normalized) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return try std.fmt.allocPrint(allocator, ":(top,exclude){s}/**", .{normalized});
}

fn runGit(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(512 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    std.debug.print("AgentCore manifest: git command failed: {s}\n", .{result.stderr});
    return error.GitCommandFailed;
}

fn dirtySourceDigest(diff: []const u8, entries: []DigestEntry) [64]u8 {
    std.mem.sort(DigestEntry, entries, {}, struct {
        fn lessThan(_: void, left: DigestEntry, right: DigestEntry) bool {
            return std.mem.order(u8, left.path, right.path) == .lt;
        }
    }.lessThan);
    var hash = Sha256.init(.{});
    hash.update("metask-agentcore-dirty-v1\x00diff\x00");
    hash.update(diff);
    for (entries) |entry| {
        hash.update("\x00untracked\x00");
        hash.update(entry.path);
        hash.update("\x00");
        hash.update(&entry.digest);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .replace = true,
        .make_path = true,
    });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, bytes);
    try atomic_file.replace(io);
}

fn isLowerHex(bytes: []const u8) bool {
    for (bytes) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

test "dirty source digest is stable across untracked input order" {
    const first_digest = [_]u8{1} ** 32;
    const second_digest = [_]u8{2} ** 32;
    var forward = [_]DigestEntry{
        .{ .path = "z-last.txt", .digest = second_digest },
        .{ .path = "a-first.txt", .digest = first_digest },
    };
    var reverse = [_]DigestEntry{
        .{ .path = "a-first.txt", .digest = first_digest },
        .{ .path = "z-last.txt", .digest = second_digest },
    };
    try std.testing.expectEqualSlices(u8, &dirtySourceDigest("diff", &forward), &dirtySourceDigest("diff", &reverse));
}

test "dirty source digest separates paths and contents" {
    const digest = [_]u8{7} ** 32;
    var left = [_]DigestEntry{.{ .path = "ab", .digest = digest }};
    var right = [_]DigestEntry{.{ .path = "a", .digest = digest }};
    try std.testing.expect(!std.mem.eql(u8, &dirtySourceDigest("c", &left), &dirtySourceDigest("bc", &right)));
}

test "bundle exclusion accepts Windows separators and rejects outside paths" {
    const allocator = std.testing.allocator;
    const repo_root = if (builtin.os.tag == .windows) "C:\\repo" else "/repo";
    const bundle_root = if (builtin.os.tag == .windows)
        "C:\\repo\\zig-out\\agentcore\\x86_64-windows-gnu"
    else
        "/repo/zig-out/agentcore/x86_64-windows-gnu";
    const outside_root = if (builtin.os.tag == .windows) "D:\\release" else "/release";
    const inside = try bundleExcludePathspec(allocator, repo_root, bundle_root);
    defer allocator.free(inside.?);
    try std.testing.expectEqualStrings(
        ":(top,exclude)zig-out/agentcore/x86_64-windows-gnu/**",
        inside.?,
    );
    try std.testing.expect((try bundleExcludePathspec(allocator, repo_root, outside_root)) == null);
}

test "strict boolean parser" {
    try std.testing.expectEqual(true, parseBool("true").?);
    try std.testing.expectEqual(false, parseBool("false").?);
    try std.testing.expect(parseBool("TRUE") == null);
}

test "package version is derived from sdk version and source identity" {
    const allocator = std.testing.allocator;
    const clean = SourceIdentity{
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .dirty = false,
        .dirty_digest = [_]u8{'0'} ** 64,
    };
    const clean_version = try packageVersion(allocator, "0.1.0-dev", clean);
    defer allocator.free(clean_version);
    try std.testing.expectEqualStrings("0.1.0-dev+0123456789ab", clean_version);

    const stable_version = try packageVersion(allocator, "0.1.0", clean);
    defer allocator.free(stable_version);
    try std.testing.expectEqualStrings("0.1.0", stable_version);

    var dirty = clean;
    dirty.dirty = true;
    dirty.dirty_digest = [_]u8{'a'} ** 64;
    const dirty_version = try packageVersion(allocator, "0.1.0-dev", dirty);
    defer allocator.free(dirty_version);
    try std.testing.expectEqualStrings("0.1.0-dev+0123456789ab.dirty.aaaaaaaaaaaa", dirty_version);
    try std.testing.expectError(error.DirtyStableVersion, packageVersion(allocator, "0.1.0", dirty));
    try std.testing.expectError(error.InvalidSdkVersion, packageVersion(allocator, "0.1.0+local", clean));
}
