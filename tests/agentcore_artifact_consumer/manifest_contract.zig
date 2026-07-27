const std = @import("std");

pub const FileEntry = struct {
    path: []const u8,
    sha256: []const u8,
};

pub const Manifest = struct {
    schema_version: u32,
    vendor: []const u8,
    name: []const u8,
    version: []const u8,
    source: struct {
        commit: []const u8,
        dirty: bool,
    },
    toolchain: struct { zig_version: []const u8 },
    target: struct {
        id: []const u8,
        architecture: []const u8,
        os: []const u8,
        abi: []const u8,
        zig_target: []const u8,
        rust_target: []const u8,
    },
    build: struct {
        optimize: []const u8,
        strip: bool,
    },
    link: struct {
        requires_c_runtime: bool,
        system_libraries: []const []const u8,
        system_frameworks: []const []const u8,
    },
    contract: struct {
        binary_abi_status: []const u8,
        binary_abi_version: u32,
        binary_abi_revision: u32,
    },
    files: []const FileEntry,
};

pub const Expected = struct {
    target_id: []const u8,
    resolved_target: []const u8,
    rust_target: []const u8,
    architecture: []const u8,
    os: []const u8,
    abi: []const u8,
    optimize: []const u8,
    strip: bool,
    zig_version: []const u8,
};

pub const Error = error{
    InvalidSchema,
    InvalidVendor,
    InvalidName,
    InvalidCommit,
    InvalidVersion,
    ZigVersionMismatch,
    TargetMismatch,
    RustTargetMismatch,
    ArchitectureMismatch,
    OsMismatch,
    TargetAbiMismatch,
    OptimizeMismatch,
    StripMismatch,
    AbiMismatch,
    AbiStatusMismatch,
    LinkInputsMismatch,
    InvalidSha256,
    UnexpectedFile,
    DuplicateFile,
    MissingFile,
};

pub const fixed_artifact_files = [_][]const u8{
    "include/metask/agentcore.h",
    "bindings/zig/build.zig",
    "bindings/zig/build.zig.zon",
    "bindings/zig/src/root.zig",
    "bindings/zig/src/protocol.zig",
    "bindings/zig/src/types.zig",
    "bindings/rust/Cargo.toml",
    "bindings/rust/Cargo.lock",
    "bindings/rust/link.cfg",
    "bindings/rust/build.rs",
    "bindings/rust/src/lib.rs",
    "bindings/rust/src/raw.rs",
    "bindings/rust/examples/link_probe.rs",
    "README.md",
};

pub const default_system_link_inputs = [_][]const u8{};
pub const windows_system_link_inputs = [_][]const u8{ "advapi32", "crypt32" };

pub fn validateManifest(manifest: Manifest, expected: Expected) Error!void {
    if (manifest.schema_version != 1) return error.InvalidSchema;
    if (!std.mem.eql(u8, manifest.vendor, "metask")) return error.InvalidVendor;
    if (!std.mem.eql(u8, manifest.name, "agentcore")) return error.InvalidName;
    if (manifest.source.commit.len != 40 or !isLowerHex(manifest.source.commit)) return error.InvalidCommit;
    try validateVersion(manifest);
    if (!std.mem.eql(u8, manifest.toolchain.zig_version, expected.zig_version)) return error.ZigVersionMismatch;
    if (!std.mem.eql(u8, manifest.target.id, expected.target_id)) return error.TargetMismatch;
    if (!std.mem.eql(u8, manifest.target.zig_target, expected.resolved_target)) return error.TargetMismatch;
    if (!std.mem.eql(u8, manifest.target.rust_target, expected.rust_target)) return error.RustTargetMismatch;
    if (!std.mem.eql(u8, manifest.target.architecture, expected.architecture)) return error.ArchitectureMismatch;
    if (!std.mem.eql(u8, manifest.target.os, expected.os)) return error.OsMismatch;
    if (!std.mem.eql(u8, manifest.target.abi, expected.abi)) return error.TargetAbiMismatch;
    if (!std.mem.eql(u8, manifest.build.optimize, expected.optimize)) return error.OptimizeMismatch;
    if (manifest.build.strip != expected.strip) return error.StripMismatch;
    if (manifest.contract.binary_abi_version != 1 or manifest.contract.binary_abi_revision != 4)
        return error.AbiMismatch;
    if (!std.mem.eql(u8, manifest.contract.binary_abi_status, "experimental")) return error.AbiStatusMismatch;
    const expected_link_inputs: []const []const u8 = if (std.mem.eql(u8, expected.os, "windows"))
        &windows_system_link_inputs
    else
        &default_system_link_inputs;
    if (!manifest.link.requires_c_runtime or !equalStrings(manifest.link.system_libraries, expected_link_inputs) or
        manifest.link.system_frameworks.len != 0)
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
    _ = std.SemanticVersion.parse(manifest.version) catch return error.InvalidVersion;
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

fn artifactFileIndex(path: []const u8, library_path: []const u8) ?usize {
    if (std.mem.eql(u8, path, library_path)) return 0;
    const index = findFixed(&fixed_artifact_files, path) orelse return null;
    return index + 1;
}

fn findFixed(comptime expected: []const []const u8, actual: []const u8) ?usize {
    inline for (expected, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, actual)) return index;
    }
    return null;
}

const hash = "0000000000000000000000000000000000000000000000000000000000000000";
const macos_library_path = "lib/libmetask_agentcore.a";
const valid_files = makeValidFiles();

fn makeValidFiles() [fixed_artifact_files.len + 1]FileEntry {
    var files: [fixed_artifact_files.len + 1]FileEntry = undefined;
    files[0] = .{ .path = macos_library_path, .sha256 = hash };
    for (fixed_artifact_files, 0..) |path, index|
        files[index + 1] = .{ .path = path, .sha256 = hash };
    return files;
}

fn validManifest() Manifest {
    return .{
        .schema_version = 1,
        .vendor = "metask",
        .name = "agentcore",
        .version = "0.1.0-dev+0123456789ab",
        .source = .{
            .commit = "0123456789abcdef0123456789abcdef01234567",
            .dirty = false,
        },
        .toolchain = .{ .zig_version = "0.16.0" },
        .target = .{
            .id = "aarch64-macos",
            .architecture = "aarch64",
            .os = "macos",
            .abi = "none",
            .zig_target = "aarch64-macos.13.0...15.6-none",
            .rust_target = "aarch64-apple-darwin",
        },
        .build = .{
            .optimize = "ReleaseSafe",
            .strip = true,
        },
        .link = .{
            .requires_c_runtime = true,
            .system_libraries = &default_system_link_inputs,
            .system_frameworks = &default_system_link_inputs,
        },
        .contract = .{
            .binary_abi_status = "experimental",
            .binary_abi_version = 1,
            .binary_abi_revision = 4,
        },
        .files = &valid_files,
    };
}

const valid_expected = Expected{
    .target_id = "aarch64-macos",
    .resolved_target = "aarch64-macos.13.0...15.6-none",
    .rust_target = "aarch64-apple-darwin",
    .architecture = "aarch64",
    .os = "macos",
    .abi = "none",
    .optimize = "ReleaseSafe",
    .strip = true,
    .zig_version = "0.16.0",
};

test "manifest identity accepts semantic versions and records dirty state independently" {
    try validateManifest(validManifest(), valid_expected);
    var dirty = validManifest();
    dirty.source.dirty = true;
    dirty.version = "0.1.0-dev+0123456789ab.dirty";
    try validateManifest(dirty, valid_expected);

    var stable = validManifest();
    stable.version = "0.1.0";
    try validateManifest(stable, valid_expected);

    var invalid = validManifest();
    invalid.version = "not-semver";
    try std.testing.expectError(error.InvalidVersion, validateManifest(invalid, valid_expected));
}

test "manifest accepts target-neutral Linux build metadata" {
    var manifest = validManifest();
    manifest.target.id = "x86_64-linux-gnu";
    manifest.target.zig_target = "x86_64-linux.6.5...6.5-gnu.2.36";
    manifest.target.rust_target = "x86_64-unknown-linux-gnu";
    manifest.target.architecture = "x86_64";
    manifest.target.os = "linux";
    manifest.target.abi = "gnu";
    var expected = valid_expected;
    expected.target_id = manifest.target.id;
    expected.resolved_target = manifest.target.zig_target;
    expected.rust_target = manifest.target.rust_target;
    expected.architecture = manifest.target.architecture;
    expected.os = manifest.target.os;
    expected.abi = manifest.target.abi;
    try validateManifest(manifest, expected);
}

test "manifest requires target-specific system link inputs" {
    var windows = validManifest();
    windows.target.id = "x86_64-windows-gnu";
    windows.target.zig_target = "x86_64-windows.win10...win11_dt-gnu";
    windows.target.rust_target = "x86_64-pc-windows-gnu";
    windows.target.architecture = "x86_64";
    windows.target.os = "windows";
    windows.target.abi = "gnu";
    windows.link.system_libraries = &windows_system_link_inputs;
    var expected = valid_expected;
    expected.target_id = windows.target.id;
    expected.resolved_target = windows.target.zig_target;
    expected.rust_target = windows.target.rust_target;
    expected.architecture = windows.target.architecture;
    expected.os = windows.target.os;
    expected.abi = windows.target.abi;
    try validateManifest(windows, expected);

    windows.link.system_libraries = &default_system_link_inputs;
    try std.testing.expectError(error.LinkInputsMismatch, validateManifest(windows, expected));
    const extra = [_][]const u8{ "advapi32", "crypt32", "user32" };
    windows.link.system_libraries = &extra;
    try std.testing.expectError(error.LinkInputsMismatch, validateManifest(windows, expected));
}

test "manifest contract rejects toolchain target optimize and ABI drift" {
    var manifest = validManifest();
    manifest.vendor = "other";
    try std.testing.expectError(error.InvalidVendor, validateManifest(manifest, valid_expected));
    manifest = validManifest();
    manifest.toolchain.zig_version = "0.17.0";
    try std.testing.expectError(error.ZigVersionMismatch, validateManifest(manifest, valid_expected));
    manifest = validManifest();
    manifest.target.zig_target = "x86_64-macos.13.0...15.6-none";
    try std.testing.expectError(error.TargetMismatch, validateManifest(manifest, valid_expected));
    manifest = validManifest();
    manifest.target.rust_target = "x86_64-apple-darwin";
    try std.testing.expectError(error.RustTargetMismatch, validateManifest(manifest, valid_expected));
    manifest = validManifest();
    manifest.target.architecture = "x86_64";
    try std.testing.expectError(error.ArchitectureMismatch, validateManifest(manifest, valid_expected));
    manifest = validManifest();
    manifest.target.os = "linux";
    try std.testing.expectError(error.OsMismatch, validateManifest(manifest, valid_expected));
    manifest = validManifest();
    manifest.target.abi = "gnu";
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
    manifest = validManifest();
    manifest.contract.binary_abi_revision = 1;
    try std.testing.expectError(error.AbiMismatch, validateManifest(manifest, valid_expected));
    manifest = validManifest();
    manifest.contract.binary_abi_status = "stable";
    try std.testing.expectError(error.AbiStatusMismatch, validateManifest(manifest, valid_expected));
}

test "manifest file set validates dynamic library name hashes and exact entries" {
    try validateManifestFiles(&valid_files, macos_library_path);
    var windows_files = valid_files;
    windows_files[0].path = "lib/metask_agentcore.lib";
    try validateManifestFiles(&windows_files, windows_files[0].path);
    try std.testing.expectEqualStrings(hash, fileSha256(&valid_files, macos_library_path).?);
    try std.testing.expect(fileSha256(&valid_files, "lib/missing.lib") == null);
    try std.testing.expectError(error.MissingFile, validateManifestFiles(valid_files[0 .. valid_files.len - 1], macos_library_path));
    const extra = valid_files ++ [_]FileEntry{.{ .path = "bindings/zig/src/unlisted.zig", .sha256 = hash }};
    try std.testing.expectError(error.UnexpectedFile, validateManifestFiles(&extra, macos_library_path));
    var duplicate = valid_files;
    duplicate[4] = duplicate[0];
    try std.testing.expectError(error.DuplicateFile, validateManifestFiles(&duplicate, macos_library_path));
    var invalid_hash = valid_files;
    invalid_hash[0].sha256 = "ABCDEF";
    try std.testing.expectError(error.InvalidSha256, validateManifestFiles(&invalid_hash, macos_library_path));
}
