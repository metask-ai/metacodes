const std = @import("std");

pub const Manifest = struct {
    schema_version: u32,
    name: []const u8,
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
        macos_deployment_target: []const u8,
        optimize: []const u8,
        strip: bool,
    },
    contract: struct {
        binary_abi_version: u32,
        required_system_link_inputs: []const []const u8,
        ui_request_mode: []const u8,
    },
    files: struct {
        @"lib/libmetacodes_agentcore.a": struct { sha256: []const u8 },
        @"include/metacodes_agentcore.h": struct { sha256: []const u8 },
        @"sdk/metacodes_agentcore.zig": struct { sha256: []const u8 },
        @"sdk/metacodes_agentcore_protocol.zig": struct { sha256: []const u8 },
        @"sdk/metacodes_agentcore_types.zig": struct { sha256: []const u8 },
    },
};

pub const Expected = struct {
    resolved_target: []const u8,
    optimize: []const u8,
    strip: bool,
    zig_version: []const u8,
    require_clean: bool = false,
    commit: ?[]const u8 = null,
};

pub const EntryKind = enum { file, directory, other };
pub const BundleEntry = struct { path: []const u8, kind: EntryKind };

pub const Error = error{
    InvalidSchema,
    InvalidName,
    InvalidCommit,
    CommitMismatch,
    InvalidVersion,
    DirtyBundle,
    ExpectedCommitRequired,
    ZigVersionMismatch,
    TargetMismatch,
    OptimizeMismatch,
    StripMismatch,
    AbiMismatch,
    UiModeMismatch,
    LinkInputsMismatch,
    UnexpectedFile,
    DuplicateFile,
    MissingFile,
    UnexpectedDirectory,
    DuplicateDirectory,
    MissingDirectory,
    UnexpectedEntryKind,
};

pub const manifest_files = [_][]const u8{
    "lib/libmetacodes_agentcore.a",
    "include/metacodes_agentcore.h",
    "sdk/metacodes_agentcore.zig",
    "sdk/metacodes_agentcore_protocol.zig",
    "sdk/metacodes_agentcore_types.zig",
};

pub const bundle_files = manifest_files ++ [_][]const u8{"manifest.json"};
pub const bundle_directories = [_][]const u8{ "include", "lib", "sdk" };

pub fn validateManifest(manifest: Manifest, expected: Expected) Error!void {
    if (manifest.schema_version != 1) return error.InvalidSchema;
    if (!std.mem.eql(u8, manifest.name, "metacodes-agentcore")) return error.InvalidName;
    if (manifest.source.commit.len != 40 or !isLowerHex(manifest.source.commit)) return error.InvalidCommit;
    if (expected.commit) |commit| {
        if (!std.mem.eql(u8, manifest.source.commit, commit)) return error.CommitMismatch;
    } else if (expected.require_clean) {
        return error.ExpectedCommitRequired;
    }
    try validateVersion(manifest);
    if (expected.require_clean and manifest.source.dirty) return error.DirtyBundle;
    if (!std.mem.eql(u8, manifest.toolchain.zig_version, expected.zig_version)) return error.ZigVersionMismatch;
    if (!std.mem.eql(u8, manifest.build.resolved_target, expected.resolved_target) or
        !std.mem.eql(u8, manifest.build.architecture, "aarch64") or
        !std.mem.eql(u8, manifest.build.os, "macos") or
        !std.mem.eql(u8, manifest.build.macos_deployment_target, "13.0"))
        return error.TargetMismatch;
    if (!std.mem.eql(u8, manifest.build.optimize, expected.optimize)) return error.OptimizeMismatch;
    if (manifest.build.strip != expected.strip) return error.StripMismatch;
    if (manifest.contract.binary_abi_version != 1) return error.AbiMismatch;
    if (!std.mem.eql(u8, manifest.contract.ui_request_mode, "synchronous")) return error.UiModeMismatch;
    if (manifest.contract.required_system_link_inputs.len != 1 or
        !std.mem.eql(u8, manifest.contract.required_system_link_inputs[0], "libc"))
        return error.LinkInputsMismatch;
}

fn validateVersion(manifest: Manifest) Error!void {
    const prefix = "0.0.0-dev+";
    const commit_short = manifest.source.commit[0..12];
    if (!std.mem.startsWith(u8, manifest.version, prefix)) return error.InvalidVersion;
    const suffix = manifest.version[prefix.len..];
    if (!std.mem.startsWith(u8, suffix, commit_short)) return error.InvalidVersion;
    const identity_suffix = suffix[commit_short.len..];
    if (!manifest.source.dirty) {
        if (identity_suffix.len != 0 or manifest.source.dirty_source_sha256.len != 0) return error.InvalidVersion;
        return;
    }
    const dirty_prefix = "-dirty.";
    if (manifest.source.dirty_source_sha256.len != 64 or !isLowerHex(manifest.source.dirty_source_sha256) or
        !std.mem.startsWith(u8, identity_suffix, dirty_prefix) or
        identity_suffix.len != dirty_prefix.len + 12 or
        !std.mem.eql(u8, identity_suffix[dirty_prefix.len..], manifest.source.dirty_source_sha256[0..12]))
        return error.InvalidVersion;
}

fn isLowerHex(bytes: []const u8) bool {
    for (bytes) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

pub fn validateManifestFiles(paths: []const []const u8) Error!void {
    return validateExactFiles(paths, &manifest_files);
}

fn validateExactFiles(paths: []const []const u8, comptime expected: []const []const u8) Error!void {
    var seen = [_]bool{false} ** expected.len;
    for (paths) |path| {
        const index = find(expected, path) orelse return error.UnexpectedFile;
        if (seen[index]) return error.DuplicateFile;
        seen[index] = true;
    }
    for (seen) |present| if (!present) return error.MissingFile;
}

pub fn validateBundleEntries(entries: []const BundleEntry) Error!void {
    var seen_files = [_]bool{false} ** bundle_files.len;
    var seen_directories = [_]bool{false} ** bundle_directories.len;
    for (entries) |entry| switch (entry.kind) {
        .file => {
            const index = find(&bundle_files, entry.path) orelse return error.UnexpectedFile;
            if (seen_files[index]) return error.DuplicateFile;
            seen_files[index] = true;
        },
        .directory => {
            const index = find(&bundle_directories, entry.path) orelse return error.UnexpectedDirectory;
            if (seen_directories[index]) return error.DuplicateDirectory;
            seen_directories[index] = true;
        },
        .other => return error.UnexpectedEntryKind,
    };
    for (seen_files) |present| if (!present) return error.MissingFile;
    for (seen_directories) |present| if (!present) return error.MissingDirectory;
}

fn find(comptime expected: []const []const u8, actual: []const u8) ?usize {
    inline for (expected, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, actual)) return index;
    }
    return null;
}

fn validManifest() Manifest {
    const hash = "0000000000000000000000000000000000000000000000000000000000000000";
    return .{
        .schema_version = 1,
        .name = "metacodes-agentcore",
        .version = "0.0.0-dev+0123456789ab",
        .source = .{
            .commit = "0123456789abcdef0123456789abcdef01234567",
            .dirty = false,
            .dirty_source_sha256 = "",
        },
        .toolchain = .{ .zig_version = "0.16.0" },
        .build = .{
            .resolved_target = "aarch64-macos.13.0...15.6-none",
            .architecture = "aarch64",
            .os = "macos",
            .macos_deployment_target = "13.0",
            .optimize = "ReleaseSafe",
            .strip = true,
        },
        .contract = .{
            .binary_abi_version = 1,
            .required_system_link_inputs = &.{"libc"},
            .ui_request_mode = "synchronous",
        },
        .files = .{
            .@"lib/libmetacodes_agentcore.a" = .{ .sha256 = hash },
            .@"include/metacodes_agentcore.h" = .{ .sha256 = hash },
            .@"sdk/metacodes_agentcore.zig" = .{ .sha256 = hash },
            .@"sdk/metacodes_agentcore_protocol.zig" = .{ .sha256 = hash },
            .@"sdk/metacodes_agentcore_types.zig" = .{ .sha256 = hash },
        },
    };
}

const valid_expected = Expected{
    .resolved_target = "aarch64-macos.13.0...15.6-none",
    .optimize = "ReleaseSafe",
    .strip = true,
    .zig_version = "0.16.0",
};

test "manifest identity accepts valid clean and dirty development bundles" {
    try validateManifest(validManifest(), valid_expected);
    var dirty = validManifest();
    dirty.source.dirty = true;
    dirty.source.dirty_source_sha256 = "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd";
    dirty.version = "0.0.0-dev+0123456789ab-dirty.abcdefabcdef";
    try validateManifest(dirty, valid_expected);
}

test "release identity rejects dirty and wrong-commit bundles" {
    var dirty = validManifest();
    dirty.source.dirty = true;
    dirty.source.dirty_source_sha256 = "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd";
    dirty.version = "0.0.0-dev+0123456789ab-dirty.abcdefabcdef";
    const clean_expected = Expected{
        .resolved_target = valid_expected.resolved_target,
        .optimize = valid_expected.optimize,
        .strip = valid_expected.strip,
        .zig_version = valid_expected.zig_version,
        .require_clean = true,
        .commit = "0123456789abcdef0123456789abcdef01234567",
    };
    try std.testing.expectError(error.DirtyBundle, validateManifest(dirty, clean_expected));
    var wrong_commit = clean_expected;
    wrong_commit.commit = "ffffffffffffffffffffffffffffffffffffffff";
    try std.testing.expectError(error.CommitMismatch, validateManifest(validManifest(), wrong_commit));
}

test "manifest contract rejects toolchain target optimize and ABI drift" {
    var manifest = validManifest();
    manifest.toolchain.zig_version = "0.17.0";
    try std.testing.expectError(error.ZigVersionMismatch, validateManifest(manifest, valid_expected));
    manifest = validManifest();
    manifest.build.resolved_target = "x86_64-macos.13.0...15.6-none";
    try std.testing.expectError(error.TargetMismatch, validateManifest(manifest, valid_expected));
    manifest = validManifest();
    manifest.build.optimize = "Debug";
    try std.testing.expectError(error.OptimizeMismatch, validateManifest(manifest, valid_expected));
    manifest = validManifest();
    manifest.build.strip = false;
    try std.testing.expectError(error.StripMismatch, validateManifest(manifest, valid_expected));
    manifest = validManifest();
    manifest.contract.binary_abi_version = 2;
    try std.testing.expectError(error.AbiMismatch, validateManifest(manifest, valid_expected));
}

test "manifest file set rejects extra and missing entries" {
    try validateManifestFiles(&manifest_files);
    try std.testing.expectError(error.MissingFile, validateManifestFiles(manifest_files[0 .. manifest_files.len - 1]));
    const extra = manifest_files ++ [_][]const u8{"sdk/unlisted.zig"};
    try std.testing.expectError(error.UnexpectedFile, validateManifestFiles(&extra));
}

test "bundle entry set rejects extra files directories and entry kinds" {
    const valid = [_]BundleEntry{
        .{ .path = "include", .kind = .directory },
        .{ .path = "lib", .kind = .directory },
        .{ .path = "sdk", .kind = .directory },
        .{ .path = bundle_files[0], .kind = .file },
        .{ .path = bundle_files[1], .kind = .file },
        .{ .path = bundle_files[2], .kind = .file },
        .{ .path = bundle_files[3], .kind = .file },
        .{ .path = bundle_files[4], .kind = .file },
        .{ .path = bundle_files[5], .kind = .file },
    };
    try validateBundleEntries(&valid);
    try std.testing.expectError(error.MissingFile, validateBundleEntries(valid[0 .. valid.len - 1]));
    var extra_file = valid ++ [_]BundleEntry{.{ .path = "sdk/unlisted.zig", .kind = .file }};
    try std.testing.expectError(error.UnexpectedFile, validateBundleEntries(&extra_file));
    var extra_directory = valid ++ [_]BundleEntry{.{ .path = "stale", .kind = .directory }};
    try std.testing.expectError(error.UnexpectedDirectory, validateBundleEntries(&extra_directory));
    var symlink = valid;
    symlink[3].kind = .other;
    try std.testing.expectError(error.UnexpectedEntryKind, validateBundleEntries(&symlink));
}
