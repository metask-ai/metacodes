//! Build identity of the running executable (#78, #47 stage 3).
//!
//! `build.zig` fixes every value at configure time — git commit and dirty
//! state, Zig version, target, optimize mode, the `-Drelease-layout` flag, the
//! AgentCore ABI version and revision from `sdk/zig/types.zig`, and the
//! ripgrep / TinyKG versions with the digests the vendored manifests pin for
//! the target — and injects them as the `build_info` module of the two app
//! modules. `--version` renders them as text whose first line stays
//! `metacodes <semver>`; `--version --json` renders the same identity as one
//! JSON document, which `scripts/eval/runtime_arm_smoke.py` checks against the
//! repository sources with the real binary. The library module receives no
//! `build_info`, so this file takes a plain `BuildInfo` and never imports the
//! module itself.
const std = @import("std");
const config = @import("app/config.zig");

/// Everything `build_info` declares, in one value. `fromOptions` copies the
/// module's declarations so `main.zig` is the only place that names it.
pub const BuildInfo = struct {
    commit: []const u8,
    dirty: bool,
    zig: []const u8,
    target: []const u8,
    optimize: []const u8,
    release_layout: bool,
    abi_version: u32,
    abi_revision: u32,
    ripgrep_version: []const u8,
    ripgrep_revision: []const u8,
    /// Digest the vendored bundle pins for this target; null when it has no
    /// artifact for the target and rg resolves from the environment.
    ripgrep_sha256: ?[]const u8,
    tinykg_version: []const u8,
    tinykg_commit: []const u8,
    /// Digest of the TinyKG binary selected for this build (bundled or the
    /// maintainer override); null when TinyKG is disabled or unavailable.
    tinykg_sha256: ?[]const u8,

    pub fn fromOptions(comptime Options: type) BuildInfo {
        return .{
            .commit = Options.commit,
            .dirty = Options.dirty,
            .zig = Options.zig_version,
            .target = Options.target_triple,
            .optimize = Options.optimize,
            .release_layout = Options.release_layout,
            .abi_version = Options.abi_version,
            .abi_revision = Options.abi_revision,
            .ripgrep_version = Options.ripgrep_version,
            .ripgrep_revision = Options.ripgrep_revision,
            .ripgrep_sha256 = Options.ripgrep_expected_sha256,
            .tinykg_version = Options.tinykg_version,
            .tinykg_commit = Options.tinykg_source_commit,
            .tinykg_sha256 = Options.tinykg_expected_sha256,
        };
    }
};

/// One entry of `expected_runtime_assets`.
pub const RuntimeAsset = struct {
    name: []const u8,
    version: []const u8,
    sha256: ?[]const u8,
};

/// The `--version --json` document (doc/API.md, CLI surface). Field order is
/// the wire order; a consumer keys on names, not positions.
pub const Document = struct {
    name: []const u8,
    version: []const u8,
    commit: []const u8,
    dirty: bool,
    zig: []const u8,
    target: []const u8,
    optimize: []const u8,
    release_layout: bool,
    contract: struct {
        binary_abi_version: u32,
        binary_abi_revision: u32,
        config_schema_version: u32,
    },
    expected_runtime_assets: [2]RuntimeAsset,

    pub fn init(semver: []const u8, info: BuildInfo) Document {
        return .{
            .name = "metacodes",
            .version = semver,
            .commit = info.commit,
            .dirty = info.dirty,
            .zig = info.zig,
            .target = info.target,
            .optimize = info.optimize,
            .release_layout = info.release_layout,
            .contract = .{
                .binary_abi_version = info.abi_version,
                .binary_abi_revision = info.abi_revision,
                .config_schema_version = config.SCHEMA_VERSION,
            },
            .expected_runtime_assets = .{
                .{ .name = "ripgrep", .version = info.ripgrep_version, .sha256 = info.ripgrep_sha256 },
                .{ .name = "tinykg", .version = info.tinykg_version, .sha256 = info.tinykg_sha256 },
            },
        };
    }
};

/// Human-readable identity. The first line is the documented `metacodes
/// <semver>` and must not change; every later line is `<key> <value...>`.
pub fn writeText(w: *std.Io.Writer, semver: []const u8, info: BuildInfo) std.Io.Writer.Error!void {
    try w.print("metacodes {s}\n", .{semver});
    try w.print("commit {s}{s}\n", .{ info.commit, if (info.dirty) " (dirty)" else "" });
    try w.print("zig {s}\n", .{info.zig});
    try w.print("target {s} {s}\n", .{ info.target, info.optimize });
    try w.print("agentcore-abi v{d} revision {d}\n", .{ info.abi_version, info.abi_revision });
    try w.print("config-schema {d}\n", .{config.SCHEMA_VERSION});
    try writeAssetLine(w, "ripgrep", info.ripgrep_version, info.ripgrep_revision, info.ripgrep_sha256);
    try writeAssetLine(w, "tinykg", info.tinykg_version, info.tinykg_commit, info.tinykg_sha256);
    try w.print("layout {s}\n", .{if (info.release_layout) "release" else "development"});
}

fn writeAssetLine(w: *std.Io.Writer, name: []const u8, version: []const u8, revision: []const u8, sha256: ?[]const u8) std.Io.Writer.Error!void {
    if (sha256) |digest| {
        try w.print("{s} {s} ({s}) expected sha256 {s}\n", .{ name, version, revision, digest });
    } else {
        try w.print("{s} {s} ({s}) not bundled for this target\n", .{ name, version, revision });
    }
}

/// The JSON document, one line, newline-terminated.
pub fn writeJson(w: *std.Io.Writer, semver: []const u8, info: BuildInfo) std.Io.Writer.Error!void {
    try std.json.Stringify.value(Document.init(semver, info), .{}, w);
    try w.writeByte('\n');
}

const test_info: BuildInfo = .{
    .commit = "0123456789abcdef0123456789abcdef01234567",
    .dirty = true,
    .zig = "0.16.0",
    .target = "x86_64-linux-gnu",
    .optimize = "ReleaseSafe",
    .release_layout = true,
    .abi_version = 1,
    .abi_revision = 15,
    .ripgrep_version = "14.1.1",
    .ripgrep_revision = "4649aa9700",
    .ripgrep_sha256 = null,
    .tinykg_version = "0.2.0",
    .tinykg_commit = "a0544788aeadb3b92c69e539834be54850792285",
    .tinykg_sha256 = "5288e81890f23abc12b796abf7188202c369c9e4be66df30d3509f740a8424ba",
};

test "version text keeps the documented first line and names every source" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeText(&out.writer, "1.2.3", test_info);
    const text = out.written();
    try std.testing.expect(std.mem.startsWith(u8, text, "metacodes 1.2.3\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\ncommit 0123456789abcdef0123456789abcdef01234567 (dirty)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\ntarget x86_64-linux-gnu ReleaseSafe\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\nagentcore-abi v1 revision 15\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\nripgrep 14.1.1 (4649aa9700) not bundled for this target\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "expected sha256 5288e81890f23abc12b796abf7188202c369c9e4be66df30d3509f740a8424ba\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\nlayout release\n"));
}

test "version json has the documented shape" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeJson(&out.writer, "1.2.3", test_info);
    const json = out.written();
    try std.testing.expect(std.mem.endsWith(u8, json, "}\n"));
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"name\":\"metacodes\",\"version\":\"1.2.3\",\"commit\":\""));

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 10), root.count());
    try std.testing.expect(root.get("dirty").?.bool);
    try std.testing.expect(root.get("release_layout").?.bool);
    try std.testing.expectEqualStrings("x86_64-linux-gnu", root.get("target").?.string);
    const contract = root.get("contract").?.object;
    try std.testing.expectEqual(@as(i64, 1), contract.get("binary_abi_version").?.integer);
    try std.testing.expectEqual(@as(i64, 15), contract.get("binary_abi_revision").?.integer);
    try std.testing.expectEqual(@as(i64, config.SCHEMA_VERSION), contract.get("config_schema_version").?.integer);
    const assets = root.get("expected_runtime_assets").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), assets.len);
    try std.testing.expectEqualStrings("ripgrep", assets[0].object.get("name").?.string);
    try std.testing.expect(assets[0].object.get("sha256").? == .null);
    try std.testing.expectEqualStrings("tinykg", assets[1].object.get("name").?.string);
    try std.testing.expectEqualStrings("0.2.0", assets[1].object.get("version").?.string);
    try std.testing.expectEqualStrings(
        "5288e81890f23abc12b796abf7188202c369c9e4be66df30d3509f740a8424ba",
        assets[1].object.get("sha256").?.string,
    );
}
