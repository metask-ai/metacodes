//! The reader's side of the CLI release manifest (#80, #47 stage 5).
//!
//! `scripts/release_manifest.zig` writes `manifest.json` for a staged prefix;
//! this file says what a valid one is, one error tag per rule, so
//! `release:check` and any consumer can refuse a bundle for a named reason.
//! `release/manifest.schema.json` is the same contract as a JSON Schema and
//! `release/LAYOUT.md` the prose. Pure: no I/O, nothing allocated.
//!
//! Field names are the wire names — the fixtures parse straight into
//! `Manifest` with `std.json`.
const std = @import("std");

pub const FileEntry = struct {
    path: []const u8,
    sha256: []const u8,
};

pub const Compat = struct {
    storage_format_version: []const u8,
    store_schema_version: []const u8,
};

/// One array carries both roles; a field a role does not use is null.
pub const Component = struct {
    role: []const u8,
    name: []const u8,
    path: []const u8,
    sha256: []const u8,
    version: []const u8,
    revision: ?[]const u8 = null,
    source_commit: ?[]const u8 = null,
    upstream: ?[]const u8 = null,
    license: ?[]const u8 = null,
    license_path: ?[]const u8 = null,
    provenance_path: ?[]const u8 = null,
    compat: ?Compat = null,
    purpose: ?[]const u8 = null,
};

pub const Requirement = struct {
    component: []const u8,
    cli_version: []const u8,
    storage_format_version: []const u8,
    store_schema_version: []const u8,
};

pub const Effect = struct {
    component: []const u8,
    effect: []const u8,
};

pub const Manifest = struct {
    schema_version: u32,
    vendor: []const u8,
    name: []const u8,
    release: struct {
        version: []const u8,
        channel: []const u8,
        tag: ?[]const u8 = null,
    },
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
    },
    build: struct {
        optimize: []const u8,
        strip: bool,
    },
    contract: struct {
        cli_surface_version: u32,
        binary_abi_status: []const u8,
        binary_abi_version: u32,
        binary_abi_revision: u32,
        config_schema_version: u32,
    },
    components: []const Component,
    compatibility: struct {
        requires: []const Requirement,
        fails_without: []const Effect,
        degraded_without: []const Effect,
    },
    files: []const FileEntry,
};

pub const Channel = enum { stable, pre };

/// What the build that produced the prefix knows independently of the
/// manifest; every field must be echoed exactly.
pub const Expected = struct {
    version: []const u8,
    channel: Channel,
    commit: []const u8,
    dirty: bool,
    zig_version: []const u8,
    target_id: []const u8,
    architecture: []const u8,
    os: []const u8,
    abi: []const u8,
    zig_target: []const u8,
    optimize: []const u8,
    strip: bool,
    cli_surface_version: u32,
    binary_abi_version: u32,
    binary_abi_revision: u32,
    config_schema_version: u32,
};

pub const Error = error{
    UnsupportedSchemaVersion,
    WrongVendor,
    WrongName,
    InvalidVersion,
    VersionMismatch,
    ChannelMismatch,
    StableTagMismatch,
    StableDirtySource,
    PreBuildMetadataMismatch,
    PreHasTag,
    CommitMismatch,
    DirtyMismatch,
    ToolchainMismatch,
    TargetMismatch,
    BuildMismatch,
    ContractMismatch,
    InvalidDigest,
    MissingFile,
    UnexpectedFile,
    DuplicateFile,
    FilesNotSorted,
    PrimaryExecutableInvalid,
    RipgrepComponentInvalid,
    TinykgComponentInvalid,
    UnknownComponent,
    ComponentDigestMismatch,
    RequiresMismatch,
    FailsWithoutMismatch,
    DegradedWithoutMismatch,
    CompatibilityUnknownComponent,
};

/// The four validators in order; the first failing rule names the reason.
pub fn validateManifest(manifest: Manifest, expected: Expected, expected_paths: []const []const u8) Error!void {
    try validateIdentity(manifest, expected);
    try validateFiles(manifest.files, expected_paths);
    try validateComponents(manifest.components, manifest.files, manifest.target.os, manifest.release.version);
    try validateCompatibility(manifest);
}

pub fn validateIdentity(manifest: Manifest, expected: Expected) Error!void {
    if (manifest.schema_version != 1) return error.UnsupportedSchemaVersion;
    if (!std.mem.eql(u8, manifest.vendor, "metask")) return error.WrongVendor;
    if (!std.mem.eql(u8, manifest.name, "metacodes-cli")) return error.WrongName;

    const version = std.SemanticVersion.parse(manifest.release.version) catch return error.InvalidVersion;
    if (!std.mem.eql(u8, manifest.release.version, expected.version)) return error.VersionMismatch;
    const channel = std.meta.stringToEnum(Channel, manifest.release.channel) orelse return error.ChannelMismatch;
    if (channel != expected.channel) return error.ChannelMismatch;

    if (manifest.source.commit.len != 40 or !isLowerHex(manifest.source.commit) or
        !std.mem.eql(u8, manifest.source.commit, expected.commit)) return error.CommitMismatch;
    if (manifest.source.dirty != expected.dirty) return error.DirtyMismatch;

    switch (channel) {
        .stable => {
            // The public coordinate is the bare X.Y.Z git tag (#47 Q1): no
            // pre-release, no build metadata, tag equal to the version, and a
            // clean tree behind it.
            if (version.pre != null or version.build != null) return error.StableTagMismatch;
            const tag = manifest.release.tag orelse return error.StableTagMismatch;
            if (!std.mem.eql(u8, tag, manifest.release.version)) return error.StableTagMismatch;
            if (manifest.source.dirty) return error.StableDirtySource;
        },
        .pre => {
            if (version.pre == null) return error.PreBuildMetadataMismatch;
            const build = version.build orelse return error.PreBuildMetadataMismatch;
            // `+<commit12>` or `+<commit12>.dirty`, matching the source.
            if (build.len < 12 or !std.mem.eql(u8, build[0..12], manifest.source.commit[0..12])) return error.PreBuildMetadataMismatch;
            const suffix = build[12..];
            const dirty_suffix = std.mem.eql(u8, suffix, ".dirty");
            if (suffix.len != 0 and !dirty_suffix) return error.PreBuildMetadataMismatch;
            if (dirty_suffix != manifest.source.dirty) return error.PreBuildMetadataMismatch;
            if (manifest.release.tag != null) return error.PreHasTag;
        },
    }

    if (!std.mem.eql(u8, manifest.toolchain.zig_version, expected.zig_version)) return error.ToolchainMismatch;
    if (!std.mem.eql(u8, manifest.target.id, expected.target_id) or
        !std.mem.eql(u8, manifest.target.architecture, expected.architecture) or
        !std.mem.eql(u8, manifest.target.os, expected.os) or
        !std.mem.eql(u8, manifest.target.abi, expected.abi) or
        !std.mem.eql(u8, manifest.target.zig_target, expected.zig_target)) return error.TargetMismatch;
    if (!std.mem.eql(u8, manifest.build.optimize, expected.optimize) or manifest.build.strip != expected.strip) return error.BuildMismatch;
    if (manifest.contract.cli_surface_version != expected.cli_surface_version or
        !std.mem.eql(u8, manifest.contract.binary_abi_status, "experimental") or
        manifest.contract.binary_abi_version != expected.binary_abi_version or
        manifest.contract.binary_abi_revision != expected.binary_abi_revision or
        manifest.contract.config_schema_version != expected.config_schema_version) return error.ContractMismatch;
}

/// `files` is exactly `expected_paths` as a set, each digest 64 lowercase hex,
/// no duplicates, sorted by path.
pub fn validateFiles(files: []const FileEntry, expected_paths: []const []const u8) Error!void {
    for (files, 0..) |file, index| {
        if (file.sha256.len != 64 or !isLowerHex(file.sha256)) return error.InvalidDigest;
        if (index > 0 and std.mem.order(u8, files[index - 1].path, file.path) != .lt) {
            return if (std.mem.eql(u8, files[index - 1].path, file.path)) error.DuplicateFile else error.FilesNotSorted;
        }
        for (files[0..index]) |earlier| if (std.mem.eql(u8, earlier.path, file.path)) return error.DuplicateFile;
        if (indexOfPath(expected_paths, file.path) == null) return error.UnexpectedFile;
    }
    for (expected_paths) |path| if (fileSha256(files, path) == null) return error.MissingFile;
}

/// Exactly the primary executable and the two runtime assets, each at its
/// place for the os, each digest equal to the files entry, each licence and
/// receipt listed.
pub fn validateComponents(components: []const Component, files: []const FileEntry, os: []const u8, release_version: []const u8) Error!void {
    const is_windows = std.mem.eql(u8, os, "windows");
    const metacodes_path: []const u8 = if (is_windows) "bin/metacodes.exe" else "bin/metacodes";
    const ripgrep_path: []const u8 = if (is_windows) "bin/rg.exe" else "bin/rg";
    const tinykg_path: []const u8 = if (is_windows) "vendor/tinykg/tinykg.exe" else "vendor/tinykg/tinykg";

    var primary_count: usize = 0;
    var ripgrep_count: usize = 0;
    var tinykg_count: usize = 0;
    for (components) |component| {
        const listed = fileSha256(files, component.path) orelse return error.ComponentDigestMismatch;
        if (!std.mem.eql(u8, listed, component.sha256)) return error.ComponentDigestMismatch;

        if (std.mem.eql(u8, component.role, "primary_executable") and std.mem.eql(u8, component.name, "metacodes")) {
            primary_count += 1;
            if (!std.mem.eql(u8, component.path, metacodes_path)) return error.PrimaryExecutableInvalid;
            if (!std.mem.eql(u8, component.version, release_version)) return error.PrimaryExecutableInvalid;
        } else if (std.mem.eql(u8, component.role, "runtime_asset") and std.mem.eql(u8, component.name, "ripgrep")) {
            ripgrep_count += 1;
            if (!std.mem.eql(u8, component.path, ripgrep_path)) return error.RipgrepComponentInvalid;
            if (component.revision == null or component.upstream == null or component.license == null) return error.RipgrepComponentInvalid;
            const license_path = component.license_path orelse return error.RipgrepComponentInvalid;
            if (fileSha256(files, license_path) == null) return error.RipgrepComponentInvalid;
        } else if (std.mem.eql(u8, component.role, "runtime_asset") and std.mem.eql(u8, component.name, "tinykg")) {
            tinykg_count += 1;
            if (!std.mem.eql(u8, component.path, tinykg_path)) return error.TinykgComponentInvalid;
            const source_commit = component.source_commit orelse return error.TinykgComponentInvalid;
            if (source_commit.len != 40 or !isLowerHex(source_commit)) return error.TinykgComponentInvalid;
            const license_path = component.license_path orelse return error.TinykgComponentInvalid;
            if (fileSha256(files, license_path) == null) return error.TinykgComponentInvalid;
            const provenance_path = component.provenance_path orelse return error.TinykgComponentInvalid;
            if (fileSha256(files, provenance_path) == null) return error.TinykgComponentInvalid;
            if (component.compat == null or component.upstream == null or component.license == null) return error.TinykgComponentInvalid;
        } else {
            return error.UnknownComponent;
        }
    }
    if (primary_count != 1) return error.PrimaryExecutableInvalid;
    if (ripgrep_count != 1) return error.RipgrepComponentInvalid;
    if (tinykg_count != 1) return error.TinykgComponentInvalid;
}

/// The behaviour without a component is part of the contract: TinyKG is
/// required at its minor series with the probed store schemas, ripgrep's
/// absence disables Grep/Glob, TinyKG's absence degrades memory only.
pub fn validateCompatibility(manifest: Manifest) Error!void {
    const compatibility = manifest.compatibility;
    for (compatibility.requires) |requirement| if (findComponent(manifest.components, requirement.component) == null) return error.CompatibilityUnknownComponent;
    for (compatibility.fails_without) |effect| if (findComponent(manifest.components, effect.component) == null) return error.CompatibilityUnknownComponent;
    for (compatibility.degraded_without) |effect| if (findComponent(manifest.components, effect.component) == null) return error.CompatibilityUnknownComponent;

    if (compatibility.requires.len != 1) return error.RequiresMismatch;
    const requirement = compatibility.requires[0];
    if (!std.mem.eql(u8, requirement.component, "tinykg")) return error.RequiresMismatch;
    const tinykg = findComponent(manifest.components, "tinykg") orelse return error.RequiresMismatch;
    const compat = tinykg.compat orelse return error.RequiresMismatch;
    if (!std.mem.eql(u8, requirement.storage_format_version, compat.storage_format_version) or
        !std.mem.eql(u8, requirement.store_schema_version, compat.store_schema_version)) return error.RequiresMismatch;
    if (!isMinorSeriesOf(requirement.cli_version, tinykg.version)) return error.RequiresMismatch;

    if (compatibility.fails_without.len != 1 or !std.mem.eql(u8, compatibility.fails_without[0].component, "ripgrep")) return error.FailsWithoutMismatch;
    if (compatibility.degraded_without.len != 1 or !std.mem.eql(u8, compatibility.degraded_without[0].component, "tinykg")) return error.DegradedWithoutMismatch;
}

/// `0.2.x` is the series of `0.2.0`.
fn isMinorSeriesOf(series: []const u8, version: []const u8) bool {
    const parsed = std.SemanticVersion.parse(version) catch return false;
    var buffer: [48]u8 = undefined;
    const rendered = std.fmt.bufPrint(&buffer, "{d}.{d}.x", .{ parsed.major, parsed.minor }) catch return false;
    return std.mem.eql(u8, rendered, series);
}

pub fn fileSha256(files: []const FileEntry, path: []const u8) ?[]const u8 {
    for (files) |file| if (std.mem.eql(u8, file.path, path)) return file.sha256;
    return null;
}

pub fn findComponent(components: []const Component, name: []const u8) ?*const Component {
    for (components) |*component| if (std.mem.eql(u8, component.name, name)) return component;
    return null;
}

fn indexOfPath(paths: []const []const u8, path: []const u8) ?usize {
    for (paths, 0..) |candidate, index| if (std.mem.eql(u8, candidate, path)) return index;
    return null;
}

fn isLowerHex(bytes: []const u8) bool {
    for (bytes) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

pub const MAX_EXPECTED_FILES: usize = 10;

/// The whitelist for a target, sorted by path. `changelog_name` is
/// `share/doc/CHANGELOG-<version>.md`, formatted by the caller into memory it
/// owns; `include_license` is false only on the pre channel when the prefix
/// carries no `share/licenses/metacodes-LICENSE` (the generator warned).
pub fn expectedFiles(os: []const u8, changelog_name: []const u8, include_license: bool, buffer: *[MAX_EXPECTED_FILES][]const u8) []const []const u8 {
    const is_windows = std.mem.eql(u8, os, "windows");
    var count: usize = 0;
    const fixed = [_][]const u8{
        if (is_windows) "bin/metacodes.exe" else "bin/metacodes",
        if (is_windows) "bin/rg.exe" else "bin/rg",
        changelog_name,
        "share/doc/README.md",
        "share/licenses/THIRD_PARTY_NOTICES.md",
        "share/licenses/metacodes-LICENSE",
        "share/licenses/ripgrep-LICENSE-MIT",
        "share/licenses/tinykg-LICENSE",
        if (is_windows) "vendor/tinykg/tinykg.exe" else "vendor/tinykg/tinykg",
        "vendor/tinykg/tinykg.provenance.json",
    };
    for (fixed) |path| {
        if (!include_license and std.mem.eql(u8, path, "share/licenses/metacodes-LICENSE")) continue;
        buffer[count] = path;
        count += 1;
    }
    std.mem.sort([]const u8, buffer[0..count], {}, lessThanPath);
    return buffer[0..count];
}

fn lessThanPath(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const test_commit = "0123456789abcdef0123456789abcdef01234567";
const digest_a = "a" ** 64;
const digest_b = "b" ** 64;
const digest_c = "c" ** 64;
const digest_d = "d" ** 64;

const linux_files = [_]FileEntry{
    .{ .path = "bin/metacodes", .sha256 = digest_a },
    .{ .path = "bin/rg", .sha256 = digest_b },
    .{ .path = "share/doc/CHANGELOG-0.1.0.md", .sha256 = digest_d },
    .{ .path = "share/doc/README.md", .sha256 = digest_d },
    .{ .path = "share/licenses/THIRD_PARTY_NOTICES.md", .sha256 = digest_d },
    .{ .path = "share/licenses/metacodes-LICENSE", .sha256 = digest_d },
    .{ .path = "share/licenses/ripgrep-LICENSE-MIT", .sha256 = digest_d },
    .{ .path = "share/licenses/tinykg-LICENSE", .sha256 = digest_d },
    .{ .path = "vendor/tinykg/tinykg", .sha256 = digest_c },
    .{ .path = "vendor/tinykg/tinykg.provenance.json", .sha256 = digest_d },
};

fn linuxComponents(version: []const u8) [3]Component {
    return .{
        .{ .role = "primary_executable", .name = "metacodes", .path = "bin/metacodes", .sha256 = digest_a, .version = version },
        .{
            .role = "runtime_asset",
            .name = "ripgrep",
            .path = "bin/rg",
            .sha256 = digest_b,
            .version = "15.2.0",
            .revision = "e89fff89ac",
            .upstream = "https://github.com/BurntSushi/ripgrep",
            .license = "MIT OR Unlicense",
            .license_path = "share/licenses/ripgrep-LICENSE-MIT",
            .purpose = "Glob/Grep execution dependency",
        },
        .{
            .role = "runtime_asset",
            .name = "tinykg",
            .path = "vendor/tinykg/tinykg",
            .sha256 = digest_c,
            .version = "0.2.0",
            .source_commit = test_commit,
            .upstream = "https://github.com/metask-ai/tinykg",
            .license = "Apache-2.0",
            .license_path = "share/licenses/tinykg-LICENSE",
            .provenance_path = "vendor/tinykg/tinykg.provenance.json",
            .compat = .{ .storage_format_version = "3", .store_schema_version = "3" },
            .purpose = "memory / task control plane",
        },
    };
}

const requires = [_]Requirement{.{ .component = "tinykg", .cli_version = "0.2.x", .storage_format_version = "3", .store_schema_version = "3" }};
const fails_without = [_]Effect{.{ .component = "ripgrep", .effect = "Grep / Glob unavailable" }};
const degraded_without = [_]Effect{.{ .component = "tinykg", .effect = "KG memory/task degrade; agent loop unaffected" }};

fn validManifest(components: []const Component, files: []const FileEntry) Manifest {
    return .{
        .schema_version = 1,
        .vendor = "metask",
        .name = "metacodes-cli",
        .release = .{ .version = "0.1.0", .channel = "stable", .tag = "0.1.0" },
        .source = .{ .commit = test_commit, .dirty = false },
        .toolchain = .{ .zig_version = "0.16.0" },
        .target = .{ .id = "x86_64-linux-gnu", .architecture = "x86_64", .os = "linux", .abi = "gnu", .zig_target = "x86_64-linux-gnu" },
        .build = .{ .optimize = "ReleaseSafe", .strip = true },
        .contract = .{ .cli_surface_version = 1, .binary_abi_status = "experimental", .binary_abi_version = 1, .binary_abi_revision = 15, .config_schema_version = 1 },
        .components = components,
        .compatibility = .{ .requires = &requires, .fails_without = &fails_without, .degraded_without = &degraded_without },
        .files = files,
    };
}

fn expectedStable() Expected {
    return .{
        .version = "0.1.0",
        .channel = .stable,
        .commit = test_commit,
        .dirty = false,
        .zig_version = "0.16.0",
        .target_id = "x86_64-linux-gnu",
        .architecture = "x86_64",
        .os = "linux",
        .abi = "gnu",
        .zig_target = "x86_64-linux-gnu",
        .optimize = "ReleaseSafe",
        .strip = true,
        .cli_surface_version = 1,
        .binary_abi_version = 1,
        .binary_abi_revision = 15,
        .config_schema_version = 1,
    };
}

fn linuxExpectedPaths(buffer: *[MAX_EXPECTED_FILES][]const u8) []const []const u8 {
    return expectedFiles("linux", "share/doc/CHANGELOG-0.1.0.md", true, buffer);
}

test "a valid stable manifest passes every validator" {
    const components = linuxComponents("0.1.0");
    var buffer: [MAX_EXPECTED_FILES][]const u8 = undefined;
    try validateManifest(validManifest(&components, &linux_files), expectedStable(), linuxExpectedPaths(&buffer));
}

test "a valid Windows manifest names the .exe files" {
    const files = [_]FileEntry{
        .{ .path = "bin/metacodes.exe", .sha256 = digest_a },
        .{ .path = "bin/rg.exe", .sha256 = digest_b },
        .{ .path = "share/doc/CHANGELOG-0.1.0.md", .sha256 = digest_d },
        .{ .path = "share/doc/README.md", .sha256 = digest_d },
        .{ .path = "share/licenses/THIRD_PARTY_NOTICES.md", .sha256 = digest_d },
        .{ .path = "share/licenses/metacodes-LICENSE", .sha256 = digest_d },
        .{ .path = "share/licenses/ripgrep-LICENSE-MIT", .sha256 = digest_d },
        .{ .path = "share/licenses/tinykg-LICENSE", .sha256 = digest_d },
        .{ .path = "vendor/tinykg/tinykg.exe", .sha256 = digest_c },
        .{ .path = "vendor/tinykg/tinykg.provenance.json", .sha256 = digest_d },
    };
    var components = linuxComponents("0.1.0");
    components[0].path = "bin/metacodes.exe";
    components[1].path = "bin/rg.exe";
    components[2].path = "vendor/tinykg/tinykg.exe";
    var manifest = validManifest(&components, &files);
    manifest.target = .{ .id = "x86_64-windows-gnu", .architecture = "x86_64", .os = "windows", .abi = "gnu", .zig_target = "x86_64-windows-gnu" };
    var expected = expectedStable();
    expected.target_id = "x86_64-windows-gnu";
    expected.os = "windows";
    expected.zig_target = "x86_64-windows-gnu";
    var buffer: [MAX_EXPECTED_FILES][]const u8 = undefined;
    try validateManifest(manifest, expected, expectedFiles("windows", "share/doc/CHANGELOG-0.1.0.md", true, &buffer));
}

test "a valid pre manifest carries the commit as build metadata and no tag" {
    const components = linuxComponents("0.2.0-dev+0123456789ab");
    var manifest = validManifest(&components, &linux_files);
    manifest.release = .{ .version = "0.2.0-dev+0123456789ab", .channel = "pre", .tag = null };
    var expected = expectedStable();
    expected.version = "0.2.0-dev+0123456789ab";
    expected.channel = .pre;
    try validateIdentity(manifest, expected);

    // A dirty tree is spelled out in the metadata, and must agree with source.
    manifest.release.version = "0.2.0-dev+0123456789ab.dirty";
    manifest.source.dirty = true;
    expected.version = manifest.release.version;
    expected.dirty = true;
    try validateIdentity(manifest, expected);
    manifest.source.dirty = false;
    expected.dirty = false;
    try testing.expectError(error.PreBuildMetadataMismatch, validateIdentity(manifest, expected));
}

test "the schema example parses into Manifest" {
    const allocator = testing.allocator;
    const json =
        \\{"schema_version":1,"vendor":"metask","name":"metacodes-cli",
        \\ "release":{"version":"0.1.0","channel":"stable","tag":"0.1.0"},
        \\ "source":{"commit":"0123456789abcdef0123456789abcdef01234567","dirty":false},
        \\ "toolchain":{"zig_version":"0.16.0"},
        \\ "target":{"id":"x86_64-linux-gnu","architecture":"x86_64","os":"linux","abi":"gnu","zig_target":"x86_64-linux-gnu"},
        \\ "build":{"optimize":"ReleaseSafe","strip":true},
        \\ "contract":{"cli_surface_version":1,"binary_abi_status":"experimental","binary_abi_version":1,"binary_abi_revision":15,"config_schema_version":1},
        \\ "components":[{"role":"primary_executable","name":"metacodes","path":"bin/metacodes","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"0.1.0"}],
        \\ "compatibility":{"requires":[],"fails_without":[],"degraded_without":[]},
        \\ "files":[{"path":"bin/metacodes","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
    ;
    const parsed = try std.json.parseFromSlice(Manifest, allocator, json, .{});
    defer parsed.deinit();
    try validateIdentity(parsed.value, expectedStable());
    try testing.expectEqualStrings("0.1.0", parsed.value.release.tag.?);
    try testing.expect(parsed.value.components[0].revision == null);
}

test "identity rules each have their own error" {
    const components = linuxComponents("0.1.0");
    const base = validManifest(&components, &linux_files);
    const expected = expectedStable();

    var m = base;
    m.schema_version = 2;
    try testing.expectError(error.UnsupportedSchemaVersion, validateIdentity(m, expected));
    m = base;
    m.vendor = "someone";
    try testing.expectError(error.WrongVendor, validateIdentity(m, expected));
    m = base;
    m.name = "metacodes";
    try testing.expectError(error.WrongName, validateIdentity(m, expected));
    m = base;
    m.release.version = "not-a-version";
    try testing.expectError(error.InvalidVersion, validateIdentity(m, expected));
    m = base;
    m.release.version = "0.1.1";
    m.release.tag = "0.1.1";
    try testing.expectError(error.VersionMismatch, validateIdentity(m, expected));
    m = base;
    m.release.channel = "nightly";
    try testing.expectError(error.ChannelMismatch, validateIdentity(m, expected));
    m = base;
    m.release.channel = "pre";
    try testing.expectError(error.ChannelMismatch, validateIdentity(m, expected));
    m = base;
    m.release.tag = "v0.1.0";
    try testing.expectError(error.StableTagMismatch, validateIdentity(m, expected));
    m = base;
    m.release.tag = null;
    try testing.expectError(error.StableTagMismatch, validateIdentity(m, expected));
    m = base;
    m.source.dirty = true;
    var dirty_expected = expected;
    dirty_expected.dirty = true;
    try testing.expectError(error.StableDirtySource, validateIdentity(m, dirty_expected));
    m = base;
    m.source.commit = "ffffffffffffffffffffffffffffffffffffffff";
    try testing.expectError(error.CommitMismatch, validateIdentity(m, expected));
    m = base;
    m.source.commit = "0123";
    try testing.expectError(error.CommitMismatch, validateIdentity(m, expected));
    m = base;
    m.source.dirty = true;
    try testing.expectError(error.DirtyMismatch, validateIdentity(m, expected));
    m = base;
    m.toolchain.zig_version = "0.15.1";
    try testing.expectError(error.ToolchainMismatch, validateIdentity(m, expected));
    m = base;
    m.target.abi = "musl";
    try testing.expectError(error.TargetMismatch, validateIdentity(m, expected));
    m = base;
    m.build.strip = false;
    try testing.expectError(error.BuildMismatch, validateIdentity(m, expected));
    m = base;
    m.contract.binary_abi_revision = 14;
    try testing.expectError(error.ContractMismatch, validateIdentity(m, expected));
    m = base;
    m.contract.binary_abi_status = "stable";
    try testing.expectError(error.ContractMismatch, validateIdentity(m, expected));

    // pre channel rules
    var pre_expected = expected;
    pre_expected.channel = .pre;
    pre_expected.version = "0.2.0-dev+0123456789ab";
    m = base;
    m.release = .{ .version = "0.2.0-dev+0123456789ab", .channel = "pre", .tag = "0.2.0" };
    try testing.expectError(error.PreHasTag, validateIdentity(m, pre_expected));
    m.release.tag = null;
    m.release.version = "0.2.0-dev+ffffffffffff";
    pre_expected.version = m.release.version;
    try testing.expectError(error.PreBuildMetadataMismatch, validateIdentity(m, pre_expected));
    m.release.version = "0.2.0-dev";
    pre_expected.version = m.release.version;
    try testing.expectError(error.PreBuildMetadataMismatch, validateIdentity(m, pre_expected));
}

test "file rules each have their own error" {
    var buffer: [MAX_EXPECTED_FILES][]const u8 = undefined;
    const paths = linuxExpectedPaths(&buffer);
    try validateFiles(&linux_files, paths);

    var files = linux_files;
    files[0].sha256 = "ABCD";
    try testing.expectError(error.InvalidDigest, validateFiles(&files, paths));

    files = linux_files;
    files[1].path = "bin/metacodes";
    try testing.expectError(error.DuplicateFile, validateFiles(&files, paths));

    files = linux_files;
    const swapped = files[0];
    files[0] = files[1];
    files[1] = swapped;
    try testing.expectError(error.FilesNotSorted, validateFiles(&files, paths));

    files = linux_files;
    files[3].path = "share/doc/EXTRA.md";
    try testing.expectError(error.UnexpectedFile, validateFiles(&files, paths));

    try testing.expectError(error.MissingFile, validateFiles(linux_files[0..9], paths));

    // The pre channel may ship without the licence; stable never does.
    var pre_buffer: [MAX_EXPECTED_FILES][]const u8 = undefined;
    const pre_paths = expectedFiles("linux", "share/doc/CHANGELOG-0.1.0.md", false, &pre_buffer);
    try testing.expectEqual(@as(usize, 9), pre_paths.len);
    var without_license: [9]FileEntry = undefined;
    var count: usize = 0;
    for (linux_files) |file| {
        if (std.mem.eql(u8, file.path, "share/licenses/metacodes-LICENSE")) continue;
        without_license[count] = file;
        count += 1;
    }
    try validateFiles(&without_license, pre_paths);
    try testing.expectError(error.MissingFile, validateFiles(&without_license, paths));
}

test "component rules each have their own error" {
    const base = linuxComponents("0.1.0");
    try validateComponents(&base, &linux_files, "linux", "0.1.0");

    var components = base;
    components[0].sha256 = digest_b;
    try testing.expectError(error.ComponentDigestMismatch, validateComponents(&components, &linux_files, "linux", "0.1.0"));

    components = base;
    components[0].version = "0.0.9";
    try testing.expectError(error.PrimaryExecutableInvalid, validateComponents(&components, &linux_files, "linux", "0.1.0"));
    try testing.expectError(error.PrimaryExecutableInvalid, validateComponents(&base, &linux_files, "windows", "0.1.0"));

    components = base;
    components[1].license_path = "share/licenses/absent";
    try testing.expectError(error.RipgrepComponentInvalid, validateComponents(&components, &linux_files, "linux", "0.1.0"));
    components = base;
    components[1].revision = null;
    try testing.expectError(error.RipgrepComponentInvalid, validateComponents(&components, &linux_files, "linux", "0.1.0"));

    components = base;
    components[2].source_commit = "abc";
    try testing.expectError(error.TinykgComponentInvalid, validateComponents(&components, &linux_files, "linux", "0.1.0"));
    components = base;
    components[2].provenance_path = null;
    try testing.expectError(error.TinykgComponentInvalid, validateComponents(&components, &linux_files, "linux", "0.1.0"));
    components = base;
    components[2].compat = null;
    try testing.expectError(error.TinykgComponentInvalid, validateComponents(&components, &linux_files, "linux", "0.1.0"));

    components = base;
    components[1].name = "fd";
    try testing.expectError(error.UnknownComponent, validateComponents(&components, &linux_files, "linux", "0.1.0"));

    try testing.expectError(error.RipgrepComponentInvalid, validateComponents(&.{ base[0], base[2] }, &linux_files, "linux", "0.1.0"));
    try testing.expectError(error.TinykgComponentInvalid, validateComponents(&.{ base[0], base[1] }, &linux_files, "linux", "0.1.0"));
    try testing.expectError(error.PrimaryExecutableInvalid, validateComponents(&.{ base[1], base[2] }, &linux_files, "linux", "0.1.0"));
}

test "compatibility rules each have their own error" {
    const components = linuxComponents("0.1.0");
    const base = validManifest(&components, &linux_files);
    try validateCompatibility(base);

    var m = base;
    const wrong_series = [_]Requirement{.{ .component = "tinykg", .cli_version = "0.3.x", .storage_format_version = "3", .store_schema_version = "3" }};
    m.compatibility.requires = &wrong_series;
    try testing.expectError(error.RequiresMismatch, validateCompatibility(m));

    m = base;
    const wrong_schema = [_]Requirement{.{ .component = "tinykg", .cli_version = "0.2.x", .storage_format_version = "4", .store_schema_version = "3" }};
    m.compatibility.requires = &wrong_schema;
    try testing.expectError(error.RequiresMismatch, validateCompatibility(m));

    m = base;
    const no_requirement = [_]Requirement{};
    m.compatibility.requires = &no_requirement;
    try testing.expectError(error.RequiresMismatch, validateCompatibility(m));

    m = base;
    const wrong_fails = [_]Effect{.{ .component = "tinykg", .effect = "x" }};
    m.compatibility.fails_without = &wrong_fails;
    try testing.expectError(error.FailsWithoutMismatch, validateCompatibility(m));

    m = base;
    const wrong_degraded = [_]Effect{.{ .component = "ripgrep", .effect = "x" }};
    m.compatibility.degraded_without = &wrong_degraded;
    try testing.expectError(error.DegradedWithoutMismatch, validateCompatibility(m));

    m = base;
    const unknown = [_]Effect{.{ .component = "fd", .effect = "x" }};
    m.compatibility.degraded_without = &unknown;
    try testing.expectError(error.CompatibilityUnknownComponent, validateCompatibility(m));
}

test "the expected file list is sorted and target-specific" {
    var buffer: [MAX_EXPECTED_FILES][]const u8 = undefined;
    const linux = expectedFiles("linux", "share/doc/CHANGELOG-0.1.0.md", true, &buffer);
    try testing.expectEqual(@as(usize, 10), linux.len);
    for (linux[1..], 0..) |path, index| try testing.expect(std.mem.order(u8, linux[index], path) == .lt);
    try testing.expectEqualStrings("bin/metacodes", linux[0]);
    var windows_buffer: [MAX_EXPECTED_FILES][]const u8 = undefined;
    const windows = expectedFiles("windows", "share/doc/CHANGELOG-0.1.0.md", true, &windows_buffer);
    try testing.expectEqualStrings("bin/metacodes.exe", windows[0]);
    try testing.expectEqualStrings("vendor/tinykg/tinykg.exe", windows[8]);
}
