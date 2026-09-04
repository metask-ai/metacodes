//! Host tool: write `manifest.json` for a staged CLI release prefix (#80,
//! #47 stage 5). `zig build release:manifest` runs it from the repository
//! root after `release:stage`; `release/manifest_contract.zig` is the reader's
//! side of the same contract and `release/LAYOUT.md` the prose.
//!
//! Every value is read from its source, never typed: the version from
//! `build.zig.zon` (passed in by the build graph), the commit and dirty state
//! from git, the ABI numbers from `sdk/zig/types.zig`, the CLI contract
//! constants from `src/release_contract.zig`, the ripgrep pin from
//! `vendor/ripgrep/manifest.json`, the TinyKG contract from `deps/tinykg.json`
//! and its bundle commit from `vendor/tinykg/manifest.json`, and every digest
//! from the installed file itself. The staged TinyKG binary must match its own
//! provenance receipt.
//!
//! Channels (#47 Q1): a version without a pre-release part is `stable` — HEAD
//! must carry exactly that bare `X.Y.Z` tag and the tree must be clean, or the
//! tool refuses to write. A version with a pre-release part is `pre` — build
//! metadata `+<commit12>` (`.dirty` appended when the tree is dirty) and no tag.
const std = @import("std");
const builtin = @import("builtin");
const abi_types = @import("metask_agentcore_types");
const release_contract = @import("metacodes_release_contract");
const common = @import("manifest_common.zig");

const TOOL_NAME = "release manifest";

const FileEntry = struct {
    path: []const u8,
    sha256: []const u8,
};

const Compat = struct {
    storage_format_version: []const u8,
    store_schema_version: []const u8,
};

/// One array carries both roles; absent fields are omitted from the JSON.
const Component = struct {
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

const Requirement = struct {
    component: []const u8,
    cli_version: []const u8,
    storage_format_version: []const u8,
    store_schema_version: []const u8,
};

const Effect = struct {
    component: []const u8,
    effect: []const u8,
};

const Manifest = struct {
    schema_version: u32 = 1,
    vendor: []const u8 = "metask",
    name: []const u8 = "metacodes-cli",
    release: struct {
        version: []const u8,
        channel: []const u8,
        tag: ?[]const u8,
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
        cli_surface_version: u32 = release_contract.CLI_SURFACE_VERSION,
        binary_abi_status: []const u8 = "experimental",
        binary_abi_version: u32 = abi_types.ABI_VERSION_V1,
        binary_abi_revision: u32 = abi_types.ABI_REVISION,
        config_schema_version: u32 = release_contract.CONFIG_SCHEMA_VERSION,
    },
    components: []const Component,
    compatibility: struct {
        requires: []const Requirement,
        fails_without: []const Effect,
        degraded_without: []const Effect,
    },
    files: []const FileEntry,
};

const RipgrepPin = struct {
    upstream_release: []const u8,
    upstream_revision: []const u8,
    source_repository: []const u8,
    license: []const u8,
};

const TinykgContract = struct {
    tinykg_version: []const u8,
    source_repository: []const u8,
    license: []const u8,
    storage_format_version: []const u8,
    store_schema_version: []const u8,
};

const TinykgBundle = struct {
    source_commit: []const u8,
};

const Provenance = struct {
    binary_sha256: []const u8,
};

const Channel = enum { stable, pre };

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = std.process.Args.iterateAllocator(init.minimal.args, allocator) catch
        return error.InvalidArguments;
    defer args.deinit();
    _ = args.next();

    const prefix = args.next() orelse return usage();
    const zig_target = args.next() orelse return usage();
    const architecture = args.next() orelse return usage();
    const os = args.next() orelse return usage();
    const abi = args.next() orelse return usage();
    const optimize = args.next() orelse return usage();
    const strip_text = args.next() orelse return usage();
    const declared_version = args.next() orelse return usage();
    if (args.next() != null) return usage();
    if (prefix.len == 0 or zig_target.len == 0 or architecture.len == 0 or os.len == 0 or
        abi.len == 0 or optimize.len == 0 or declared_version.len == 0)
        return error.EmptyMetadata;
    const strip = parseBool(strip_text) orelse return error.InvalidBoolean;

    const source = try common.sourceIdentity(allocator, init.io, TOOL_NAME);
    const release = try releaseCoordinate(allocator, init.io, declared_version, source);
    const target_id = try common.packageTargetId(allocator, architecture, os, abi);

    const is_windows = std.mem.eql(u8, os, "windows");
    const metacodes_rel: []const u8 = if (is_windows) "bin/metacodes.exe" else "bin/metacodes";
    const ripgrep_rel: []const u8 = if (is_windows) "bin/rg.exe" else "bin/rg";
    const tinykg_rel: []const u8 = if (is_windows) "vendor/tinykg/tinykg.exe" else "vendor/tinykg/tinykg";
    // The changelog is named after the declared version (build.zig installs
    // it as CHANGELOG-<build.zig.zon version>.md); the pre channel's build
    // metadata stays out of file names.
    const changelog_rel = try std.fmt.allocPrint(allocator, "share/doc/CHANGELOG-{s}.md", .{declared_version});

    const ripgrep_pin = try readJson(RipgrepPin, allocator, init.io, "vendor/ripgrep/manifest.json");
    const tinykg_contract = try readJson(TinykgContract, allocator, init.io, "deps/tinykg.json");
    const tinykg_bundle = try readJson(TinykgBundle, allocator, init.io, "vendor/tinykg/manifest.json");
    const provenance_rel = "vendor/tinykg/tinykg.provenance.json";
    const provenance_path = try std.fs.path.join(allocator, &.{ prefix, provenance_rel });
    const provenance = try readJson(Provenance, allocator, init.io, provenance_path);

    // The licence text is part of the unit; a stable release without it is
    // not a release (#47 Q6), a pre-release only says so.
    const license_rel = "share/licenses/metacodes-LICENSE";
    const license_path = try std.fs.path.join(allocator, &.{ prefix, license_rel });
    const has_license = fileExists(init.io, license_path);
    if (!has_license) {
        if (release.channel == .stable) {
            std.debug.print("{s}: {s} is missing; a stable release ships its licence\n", .{ TOOL_NAME, license_rel });
            return error.StableReleaseRequiresLicense;
        }
        std.debug.print("{s}: warning: {s} is missing (pre channel)\n", .{ TOOL_NAME, license_rel });
    }

    var relative_paths: std.ArrayList([]const u8) = .empty;
    try relative_paths.appendSlice(allocator, &.{
        metacodes_rel,
        ripgrep_rel,
        tinykg_rel,
        provenance_rel,
        "share/licenses/ripgrep-LICENSE-MIT",
        "share/licenses/tinykg-LICENSE",
        "share/licenses/THIRD_PARTY_NOTICES.md",
        "share/doc/README.md",
        changelog_rel,
    });
    if (has_license) try relative_paths.append(allocator, license_rel);
    std.mem.sort([]const u8, relative_paths.items, {}, lessThanPath);

    const digests = try allocator.alloc([64]u8, relative_paths.items.len);
    const files = try allocator.alloc(FileEntry, relative_paths.items.len);
    for (relative_paths.items, 0..) |relative_path, index| {
        const installed_path = try std.fs.path.join(allocator, &.{ prefix, relative_path });
        const digest = common.fileSha256(init.io, installed_path) catch |err| {
            std.debug.print("{s}: cannot hash {s}: {s}\n", .{ TOOL_NAME, installed_path, @errorName(err) });
            return err;
        };
        digests[index] = std.fmt.bytesToHex(digest, .lower);
        files[index] = .{ .path = relative_path, .sha256 = &digests[index] };
    }

    const tinykg_sha = digestOf(files, tinykg_rel) orelse unreachable;
    if (!std.mem.eql(u8, tinykg_sha, provenance.binary_sha256)) {
        std.debug.print("{s}: staged TinyKG digest {s} does not match its provenance receipt {s}\n", .{ TOOL_NAME, tinykg_sha, provenance.binary_sha256 });
        return error.TinykgProvenanceMismatch;
    }

    const components = [_]Component{
        .{
            .role = "primary_executable",
            .name = "metacodes",
            .path = metacodes_rel,
            .sha256 = digestOf(files, metacodes_rel) orelse unreachable,
            .version = release.version,
        },
        .{
            .role = "runtime_asset",
            .name = "ripgrep",
            .path = ripgrep_rel,
            .sha256 = digestOf(files, ripgrep_rel) orelse unreachable,
            .version = ripgrep_pin.upstream_release,
            .revision = ripgrep_pin.upstream_revision,
            .upstream = ripgrep_pin.source_repository,
            .license = ripgrep_pin.license,
            .license_path = "share/licenses/ripgrep-LICENSE-MIT",
            .purpose = "Glob/Grep execution dependency",
        },
        .{
            .role = "runtime_asset",
            .name = "tinykg",
            .path = tinykg_rel,
            .sha256 = tinykg_sha,
            .version = tinykg_contract.tinykg_version,
            .source_commit = tinykg_bundle.source_commit,
            .upstream = tinykg_contract.source_repository,
            .license = tinykg_contract.license,
            .license_path = "share/licenses/tinykg-LICENSE",
            .provenance_path = provenance_rel,
            .compat = .{
                .storage_format_version = tinykg_contract.storage_format_version,
                .store_schema_version = tinykg_contract.store_schema_version,
            },
            .purpose = "memory / task control plane",
        },
    };

    const manifest = Manifest{
        .release = .{
            .version = release.version,
            .channel = @tagName(release.channel),
            .tag = release.tag,
        },
        .source = .{ .commit = source.commit, .dirty = source.dirty },
        .toolchain = .{ .zig_version = builtin.zig_version_string },
        .target = .{
            .id = target_id,
            .architecture = architecture,
            .os = os,
            .abi = abi,
            .zig_target = zig_target,
        },
        .build = .{ .optimize = optimize, .strip = strip },
        .contract = .{},
        .components = &components,
        .compatibility = .{
            .requires = &.{.{
                .component = "tinykg",
                .cli_version = try minorSeries(allocator, tinykg_contract.tinykg_version),
                .storage_format_version = tinykg_contract.storage_format_version,
                .store_schema_version = tinykg_contract.store_schema_version,
            }},
            .fails_without = &.{.{ .component = "ripgrep", .effect = "Grep / Glob unavailable" }},
            .degraded_without = &.{.{ .component = "tinykg", .effect = "KG memory/task degrade; agent loop unaffected" }},
        },
        .files = files,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, manifest, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    const json_with_newline = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
    const manifest_path = try std.fs.path.join(allocator, &.{ prefix, "manifest.json" });
    try common.writeAtomic(init.io, manifest_path, json_with_newline);
}

const ReleaseCoordinate = struct {
    version: []const u8,
    channel: Channel,
    tag: ?[]const u8,
};

/// The public coordinate. `release.tag` is always null on the pre channel and
/// null on the stable channel is never written: stable refuses without a tag.
fn releaseCoordinate(allocator: std.mem.Allocator, io: std.Io, declared: []const u8, source: common.SourceIdentity) !ReleaseCoordinate {
    const parsed = std.SemanticVersion.parse(declared) catch return error.InvalidVersion;
    if (parsed.build != null) return error.InvalidVersion;
    if (parsed.pre != null) {
        const commit_short = source.commit[0..12];
        const version = if (source.dirty)
            try std.fmt.allocPrint(allocator, "{s}+{s}.dirty", .{ declared, commit_short })
        else
            try std.fmt.allocPrint(allocator, "{s}+{s}", .{ declared, commit_short });
        return .{ .version = version, .channel = .pre, .tag = null };
    }
    if (source.dirty) {
        std.debug.print("{s}: stable version {s} requires a clean working tree\n", .{ TOOL_NAME, declared });
        return error.StableReleaseRequiresCleanTree;
    }
    const tag = (try common.exactTag(allocator, io)) orelse {
        std.debug.print("{s}: stable version {s} requires HEAD to carry the tag {s}\n", .{ TOOL_NAME, declared, declared });
        return error.StableReleaseRequiresTag;
    };
    if (!std.mem.eql(u8, tag, declared)) {
        std.debug.print("{s}: HEAD is tagged {s} but the version is {s}\n", .{ TOOL_NAME, tag, declared });
        return error.StableReleaseTagMismatch;
    }
    return .{ .version = declared, .channel = .stable, .tag = tag };
}

/// `0.2.0` → `0.2.x`: the TinyKG CLI series the store contract was probed with.
fn minorSeries(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    const parsed = std.SemanticVersion.parse(version) catch return error.InvalidTinykgVersion;
    return std.fmt.allocPrint(allocator, "{d}.{d}.x", .{ parsed.major, parsed.minor });
}

fn digestOf(files: []const FileEntry, path: []const u8) ?[]const u8 {
    for (files) |file| if (std.mem.eql(u8, file.path, path)) return file.sha256;
    return null;
}

fn lessThanPath(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn readJson(comptime T: type, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !T {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| {
        std.debug.print("{s}: cannot read {s}: {s}\n", .{ TOOL_NAME, path, @errorName(err) });
        return err;
    };
    return std.json.parseFromSliceLeaky(T, allocator, bytes, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("{s}: invalid {s}: {s}\n", .{ TOOL_NAME, path, @errorName(err) });
        return err;
    };
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        "usage: release-manifest <prefix> <zig-target> <architecture> <os> <abi> <optimize> <strip:true|false> <version>\n",
        .{},
    );
    return error.InvalidArguments;
}

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

test "the TinyKG requirement names the minor series" {
    const allocator = std.testing.allocator;
    const series = try minorSeries(allocator, "0.2.0");
    defer allocator.free(series);
    try std.testing.expectEqualStrings("0.2.x", series);
    try std.testing.expectError(error.InvalidTinykgVersion, minorSeries(allocator, "latest"));
}

test "a pre-release version carries the commit as build metadata, stable never gains one" {
    const allocator = std.testing.allocator;
    const clean = common.SourceIdentity{ .commit = "0123456789abcdef0123456789abcdef01234567", .dirty = false };
    const parsed = std.SemanticVersion.parse("0.2.0-dev") catch unreachable;
    try std.testing.expect(parsed.pre != null);
    const versioned = try std.fmt.allocPrint(allocator, "0.2.0-dev+{s}", .{clean.commit[0..12]});
    defer allocator.free(versioned);
    try std.testing.expectEqualStrings("0.2.0-dev+0123456789ab", versioned);
    try std.testing.expectError(error.InvalidVersion, releaseCoordinateForTest("0.2.0+meta"));
}

fn releaseCoordinateForTest(declared: []const u8) !void {
    const parsed = std.SemanticVersion.parse(declared) catch return error.InvalidVersion;
    if (parsed.build != null) return error.InvalidVersion;
}
