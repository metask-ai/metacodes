const std = @import("std");

pub const FileEntry = struct {
    path: []const u8,
    sha256: []const u8,
};

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
        abi: []const u8,
        optimize: []const u8,
        strip: bool,
    },
    contract: struct {
        binary_abi_version: u32,
        required_system_link_inputs: []const []const u8,
        ui_request_mode: []const u8,
    },
    files: []const FileEntry,
};

pub const Expected = struct {
    resolved_target: []const u8,
    architecture: []const u8,
    os: []const u8,
    abi: []const u8,
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
    ArchitectureMismatch,
    OsMismatch,
    TargetAbiMismatch,
    OptimizeMismatch,
    StripMismatch,
    AbiMismatch,
    UiModeMismatch,
    LinkInputsMismatch,
    InvalidSha256,
    UnexpectedFile,
    DuplicateFile,
    MissingFile,
    UnexpectedDirectory,
    DuplicateDirectory,
    MissingDirectory,
    UnexpectedEntryKind,
};

pub const fixed_artifact_files = [_][]const u8{
    "include/metacodes_agentcore.h",
    "sdk/metacodes_agentcore.zig",
    "sdk/metacodes_agentcore_protocol.zig",
    "sdk/metacodes_agentcore_types.zig",
};

pub const bundle_directories = [_][]const u8{ "include", "lib", "sdk" };
pub const default_system_link_inputs = [_][]const u8{"libc"};
pub const windows_system_link_inputs = [_][]const u8{ "libc", "crypt32" };

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
    if (!std.mem.eql(u8, manifest.build.resolved_target, expected.resolved_target)) return error.TargetMismatch;
    if (!std.mem.eql(u8, manifest.build.architecture, expected.architecture)) return error.ArchitectureMismatch;
    if (!std.mem.eql(u8, manifest.build.os, expected.os)) return error.OsMismatch;
    if (!std.mem.eql(u8, manifest.build.abi, expected.abi)) return error.TargetAbiMismatch;
    if (!std.mem.eql(u8, manifest.build.optimize, expected.optimize)) return error.OptimizeMismatch;
    if (manifest.build.strip != expected.strip) return error.StripMismatch;
    if (manifest.contract.binary_abi_version != 1) return error.AbiMismatch;
    if (!std.mem.eql(u8, manifest.contract.ui_request_mode, "synchronous")) return error.UiModeMismatch;
    const expected_link_inputs: []const []const u8 = if (std.mem.eql(u8, expected.os, "windows"))
        &windows_system_link_inputs
    else
        &default_system_link_inputs;
    if (!equalStrings(manifest.contract.required_system_link_inputs, expected_link_inputs))
        return error.LinkInputsMismatch;
}

fn equalStrings(actual: []const []const u8, expected: []const []const u8) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
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

pub fn validateManifestFiles(files: []const FileEntry, library_path: []const u8) Error!void {
    var seen = [_]bool{false} ** (fixed_artifact_files.len + 1);
    for (files) |file| {
        const index = artifactFileIndex(file.path, library_path) orelse return error.UnexpectedFile;
        if (seen[index]) return error.DuplicateFile;
        if (file.sha256.len != 64 or !isLowerHex(file.sha256)) return error.InvalidSha256;
        seen[index] = true;
    }
    for (seen) |present| if (!present) return error.MissingFile;
}

pub fn fileSha256(files: []const FileEntry, path: []const u8) ?[]const u8 {
    for (files) |file| {
        if (std.mem.eql(u8, file.path, path)) return file.sha256;
    }
    return null;
}

pub fn validateBundleEntries(entries: []const BundleEntry, library_path: []const u8) Error!void {
    var seen_files = [_]bool{false} ** (fixed_artifact_files.len + 2);
    var seen_directories = [_]bool{false} ** bundle_directories.len;
    for (entries) |entry| switch (entry.kind) {
        .file => {
            const index = bundleFileIndex(entry.path, library_path) orelse return error.UnexpectedFile;
            if (seen_files[index]) return error.DuplicateFile;
            seen_files[index] = true;
        },
        .directory => {
            const index = findFixed(&bundle_directories, entry.path) orelse return error.UnexpectedDirectory;
            if (seen_directories[index]) return error.DuplicateDirectory;
            seen_directories[index] = true;
        },
        .other => return error.UnexpectedEntryKind,
    };
    for (seen_files) |present| if (!present) return error.MissingFile;
    for (seen_directories) |present| if (!present) return error.MissingDirectory;
}

fn artifactFileIndex(path: []const u8, library_path: []const u8) ?usize {
    if (std.mem.eql(u8, path, library_path)) return 0;
    const index = findFixed(&fixed_artifact_files, path) orelse return null;
    return index + 1;
}

fn bundleFileIndex(path: []const u8, library_path: []const u8) ?usize {
    if (std.mem.eql(u8, path, "manifest.json")) return fixed_artifact_files.len + 1;
    return artifactFileIndex(path, library_path);
}

fn findFixed(comptime expected: []const []const u8, actual: []const u8) ?usize {
    inline for (expected, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, actual)) return index;
    }
    return null;
}

const hash = "0000000000000000000000000000000000000000000000000000000000000000";
const macos_library_path = "lib/libmetacodes_agentcore.a";
const valid_files = [_]FileEntry{
    .{ .path = macos_library_path, .sha256 = hash },
    .{ .path = fixed_artifact_files[0], .sha256 = hash },
    .{ .path = fixed_artifact_files[1], .sha256 = hash },
    .{ .path = fixed_artifact_files[2], .sha256 = hash },
    .{ .path = fixed_artifact_files[3], .sha256 = hash },
};

fn validManifest() Manifest {
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
            .abi = "none",
            .optimize = "ReleaseSafe",
            .strip = true,
        },
        .contract = .{
            .binary_abi_version = 1,
            .required_system_link_inputs = &default_system_link_inputs,
            .ui_request_mode = "synchronous",
        },
        .files = &valid_files,
    };
}

const valid_expected = Expected{
    .resolved_target = "aarch64-macos.13.0...15.6-none",
    .architecture = "aarch64",
    .os = "macos",
    .abi = "none",
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

test "manifest accepts target-neutral Linux build metadata" {
    var manifest = validManifest();
    manifest.build.resolved_target = "x86_64-linux.6.5...6.5-gnu.2.36";
    manifest.build.architecture = "x86_64";
    manifest.build.os = "linux";
    manifest.build.abi = "gnu";
    var expected = valid_expected;
    expected.resolved_target = manifest.build.resolved_target;
    expected.architecture = manifest.build.architecture;
    expected.os = manifest.build.os;
    expected.abi = manifest.build.abi;
    try validateManifest(manifest, expected);
}

test "manifest requires target-specific system link inputs" {
    var windows = validManifest();
    windows.build.resolved_target = "x86_64-windows.win10...win11_dt-gnu";
    windows.build.architecture = "x86_64";
    windows.build.os = "windows";
    windows.build.abi = "gnu";
    windows.contract.required_system_link_inputs = &windows_system_link_inputs;
    var expected = valid_expected;
    expected.resolved_target = windows.build.resolved_target;
    expected.architecture = windows.build.architecture;
    expected.os = windows.build.os;
    expected.abi = windows.build.abi;
    try validateManifest(windows, expected);

    windows.contract.required_system_link_inputs = &default_system_link_inputs;
    try std.testing.expectError(error.LinkInputsMismatch, validateManifest(windows, expected));
    const reversed = [_][]const u8{ "crypt32", "libc" };
    windows.contract.required_system_link_inputs = &reversed;
    try std.testing.expectError(error.LinkInputsMismatch, validateManifest(windows, expected));
}

test "release identity rejects dirty and wrong-commit bundles" {
    var dirty = validManifest();
    dirty.source.dirty = true;
    dirty.source.dirty_source_sha256 = "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd";
    dirty.version = "0.0.0-dev+0123456789ab-dirty.abcdefabcdef";
    var clean_expected = valid_expected;
    clean_expected.require_clean = true;
    clean_expected.commit = "0123456789abcdef0123456789abcdef01234567";
    try std.testing.expectError(error.DirtyBundle, validateManifest(dirty, clean_expected));
    clean_expected.commit = "ffffffffffffffffffffffffffffffffffffffff";
    try std.testing.expectError(error.CommitMismatch, validateManifest(validManifest(), clean_expected));
}

test "manifest contract rejects toolchain target optimize and ABI drift" {
    var manifest = validManifest();
    manifest.toolchain.zig_version = "0.17.0";
    try std.testing.expectError(error.ZigVersionMismatch, validateManifest(manifest, valid_expected));
    manifest = validManifest();
    manifest.build.resolved_target = "x86_64-macos.13.0...15.6-none";
    try std.testing.expectError(error.TargetMismatch, validateManifest(manifest, valid_expected));
    manifest = validManifest();
    manifest.build.architecture = "x86_64";
    try std.testing.expectError(error.ArchitectureMismatch, validateManifest(manifest, valid_expected));
    manifest = validManifest();
    manifest.build.os = "linux";
    try std.testing.expectError(error.OsMismatch, validateManifest(manifest, valid_expected));
    manifest = validManifest();
    manifest.build.abi = "gnu";
    try std.testing.expectError(error.TargetAbiMismatch, validateManifest(manifest, valid_expected));
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

test "manifest file set validates dynamic library name hashes and exact entries" {
    try validateManifestFiles(&valid_files, macos_library_path);
    var windows_files = valid_files;
    windows_files[0].path = "lib/metacodes_agentcore.lib";
    try validateManifestFiles(&windows_files, windows_files[0].path);
    try std.testing.expectEqualStrings(hash, fileSha256(&valid_files, macos_library_path).?);
    try std.testing.expect(fileSha256(&valid_files, "lib/missing.lib") == null);
    try std.testing.expectError(error.MissingFile, validateManifestFiles(valid_files[0 .. valid_files.len - 1], macos_library_path));
    const extra = valid_files ++ [_]FileEntry{.{ .path = "sdk/unlisted.zig", .sha256 = hash }};
    try std.testing.expectError(error.UnexpectedFile, validateManifestFiles(&extra, macos_library_path));
    var duplicate = valid_files;
    duplicate[4] = duplicate[0];
    try std.testing.expectError(error.DuplicateFile, validateManifestFiles(&duplicate, macos_library_path));
    var invalid_hash = valid_files;
    invalid_hash[0].sha256 = "ABCDEF";
    try std.testing.expectError(error.InvalidSha256, validateManifestFiles(&invalid_hash, macos_library_path));
}

test "bundle entry set validates a dynamic library name and exact tree" {
    const valid = [_]BundleEntry{
        .{ .path = "include", .kind = .directory },
        .{ .path = "lib", .kind = .directory },
        .{ .path = "sdk", .kind = .directory },
        .{ .path = macos_library_path, .kind = .file },
        .{ .path = fixed_artifact_files[0], .kind = .file },
        .{ .path = fixed_artifact_files[1], .kind = .file },
        .{ .path = fixed_artifact_files[2], .kind = .file },
        .{ .path = fixed_artifact_files[3], .kind = .file },
        .{ .path = "manifest.json", .kind = .file },
    };
    try validateBundleEntries(&valid, macos_library_path);
    var windows = valid;
    windows[3].path = "lib/metacodes_agentcore.lib";
    try validateBundleEntries(&windows, windows[3].path);
    try std.testing.expectError(error.MissingFile, validateBundleEntries(valid[0 .. valid.len - 1], macos_library_path));
    const extra_file = valid ++ [_]BundleEntry{.{ .path = "sdk/unlisted.zig", .kind = .file }};
    try std.testing.expectError(error.UnexpectedFile, validateBundleEntries(&extra_file, macos_library_path));
    const extra_directory = valid ++ [_]BundleEntry{.{ .path = "stale", .kind = .directory }};
    try std.testing.expectError(error.UnexpectedDirectory, validateBundleEntries(&extra_directory, macos_library_path));
    var symlink = valid;
    symlink[3].kind = .other;
    try std.testing.expectError(error.UnexpectedEntryKind, validateBundleEntries(&symlink, macos_library_path));
}
