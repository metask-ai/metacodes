//! `metacodes doctor` (#78, #47 stage 3): where the two runtime binaries this
//! build depends on resolve from, and whether they are the ones the build
//! expected. ripgrep goes through `toolchain.ripgrepResolution` and TinyKG
//! through `KgClient.resolveTinykgBinary` — the same decisions the tools make
//! at run time, taken without side effects (no Store is created, no daemon
//! contacted, nothing written). The expectations are the digests `build.zig`
//! pinned into `build_info` for the target; a target without a vendored
//! binary has none, and the check then only reports where the binary came
//! from. `--strict` turns an unresolved binary or a digest mismatch into exit
//! code 1 so an install step can fail closed on it.
const std = @import("std");
const pfs = @import("platform").fs;
const toolchain = @import("../util/toolchain.zig");
const kg_client = @import("../kg/client.zig");

/// Where a binary was found. `config` is TinyKG-only (config.json `kg_bin`);
/// `path` and `fallback` are ripgrep-only (PATH scan, the fixed system
/// locations and the repository-relative vendored copy of a development
/// checkout). A `vendored` source arrives with the release layout in a later
/// #47 stage.
pub const Source = enum { env, config, adjacent, path, fallback };

pub const Check = struct {
    name: []const u8,
    /// Owned; null when the binary could not be resolved.
    resolved_path: ?[]u8,
    /// Lowercase hex SHA-256 of the resolved file; null when unresolved or
    /// unreadable.
    sha256: ?[64]u8,
    /// The digest `build_info` pinned for this target; null when it pinned none.
    expected_sha256: ?[]const u8,
    /// null when there is no expectation; otherwise digest equality (false
    /// also when the file could not be hashed).
    match: ?bool,
    source: ?Source,

    pub fn deinit(self: *Check, allocator: std.mem.Allocator) void {
        if (self.resolved_path) |path| allocator.free(path);
        self.resolved_path = null;
    }

    fn init(allocator: std.mem.Allocator, name: []const u8, resolved: ?Resolved, expected: ?[]const u8) !Check {
        var check: Check = .{
            .name = name,
            .resolved_path = null,
            .sha256 = null,
            .expected_sha256 = expected,
            .match = if (expected == null) null else false,
            .source = null,
        };
        const found = resolved orelse return check;
        check.resolved_path = try allocator.dupe(u8, found.path);
        errdefer check.deinit(allocator);
        check.source = found.source;
        check.sha256 = hashFile(found.path) catch null;
        if (expected) |want| {
            if (check.sha256) |*digest| check.match = std.mem.eql(u8, digest, want);
        }
        return check;
    }
};

const Resolved = struct { path: []const u8, source: Source };

/// What `build_info` pinned for the target (`main.zig` fills this from the
/// module; the library never imports it).
pub const Expectations = struct {
    ripgrep_sha256: ?[]const u8,
    tinykg_sha256: ?[]const u8,
};

pub const Report = struct {
    /// `[0]` ripgrep, `[1]` TinyKG.
    checks: [2]Check,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (&self.checks) |*check| check.deinit(allocator);
    }

    /// Every binary resolved, and every one with an expectation matches it.
    pub fn healthy(self: *const Report) bool {
        for (&self.checks) |*check| {
            if (check.resolved_path == null) return false;
            if (check.match) |matched| if (!matched) return false;
        }
        return true;
    }
};

pub fn run(allocator: std.mem.Allocator, expected: Expectations) !Report {
    const ripgrep: ?Resolved = if (toolchain.ripgrepResolution()) |found| .{
        .path = found.path,
        .source = switch (found.source) {
            .env => .env,
            .path => .path,
            .adjacent => .adjacent,
            .fallback => .fallback,
        },
    } else |_| null;
    var checks: [2]Check = undefined;
    checks[0] = try Check.init(allocator, "ripgrep", ripgrep, expected.ripgrep_sha256);
    errdefer checks[0].deinit(allocator);

    // `exe_dir = null` resolves the adjacent layout from the real executable
    // directory; `config_bin = null` mirrors app.zig, where config.json carries
    // no `kg_bin` yet. `home` and `domain` only shape the Store path, which
    // this pure resolution never touches.
    var tinykg = try kg_client.KgClient.resolveTinykgBinary(allocator, .{ .home = "", .domain = "" });
    defer if (tinykg) |*found| found.deinit(allocator);
    const tinykg_resolved: ?Resolved = if (tinykg) |found| .{
        .path = found.path,
        .source = switch (found.source) {
            .env => .env,
            .config => .config,
            .adjacent => .adjacent,
        },
    } else null;
    checks[1] = try Check.init(allocator, "tinykg", tinykg_resolved, expected.tinykg_sha256);
    return .{ .checks = checks };
}

/// SHA-256 of a file streamed in 64 KiB chunks; a binary is never loaded whole.
fn hashFile(path: []const u8) error{Unreadable}![64]u8 {
    var path_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_z.len) return error.Unreadable;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const fd = pfs.open(path_z[0..path.len :0], .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.Unreadable;
    defer _ = pfs.close(fd);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buffer);
        if (n < 0) return error.Unreadable;
        if (n == 0) break;
        hasher.update(buffer[0..@intCast(n)]);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// One line per check:
/// `<name> <resolved_path|unresolved> source=<source|-> sha256=<hex|-> expected=<hex|none> match=<true|false|n/a>`.
pub fn writeText(w: *std.Io.Writer, report: *const Report) std.Io.Writer.Error!void {
    for (&report.checks) |*check| {
        try w.print("{s} {s} source={s} sha256={s} expected={s} match={s}\n", .{
            check.name,
            check.resolved_path orelse "unresolved",
            if (check.source) |source| @tagName(source) else "-",
            if (check.sha256) |*digest| digest[0..] else "-",
            check.expected_sha256 orelse "none",
            if (check.match) |matched| (if (matched) "true" else "false") else "n/a",
        });
    }
}

/// The `doctor --json` document: `{"checks":[{name, resolved_path, sha256,
/// expected_sha256, match, source}, ...]}`, nulls where a value is absent.
pub fn writeJson(w: *std.Io.Writer, report: *const Report) std.Io.Writer.Error!void {
    const Entry = struct {
        name: []const u8,
        resolved_path: ?[]const u8,
        sha256: ?[]const u8,
        expected_sha256: ?[]const u8,
        match: ?bool,
        source: ?[]const u8,
    };
    var entries: [2]Entry = undefined;
    for (&report.checks, &entries) |*check, *entry| {
        entry.* = .{
            .name = check.name,
            .resolved_path = check.resolved_path,
            .sha256 = if (check.sha256) |*digest| digest[0..] else null,
            .expected_sha256 = check.expected_sha256,
            .match = check.match,
            .source = if (check.source) |source| @tagName(source) else null,
        };
    }
    try std.json.Stringify.value(.{ .checks = entries }, .{}, w);
    try w.writeByte('\n');
}

const test_digest: [64]u8 = ("0123456789abcdef" ** 4).*;

fn testReport(allocator: std.mem.Allocator) !Report {
    return .{ .checks = .{
        .{
            .name = "ripgrep",
            .resolved_path = try allocator.dupe(u8, "/opt/tools/rg"),
            .sha256 = test_digest,
            .expected_sha256 = &test_digest,
            .match = true,
            .source = .path,
        },
        .{
            .name = "tinykg",
            .resolved_path = null,
            .sha256 = null,
            .expected_sha256 = null,
            .match = null,
            .source = null,
        },
    } };
}

test "doctor json names every field and uses null for what is absent" {
    const allocator = std.testing.allocator;
    var report = try testReport(allocator);
    defer report.deinit(allocator);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeJson(&out.writer, &report);
    try std.testing.expectEqualStrings(
        "{\"checks\":[{\"name\":\"ripgrep\",\"resolved_path\":\"/opt/tools/rg\",\"sha256\":\"" ++ ("0123456789abcdef" ** 4) ++
            "\",\"expected_sha256\":\"" ++ ("0123456789abcdef" ** 4) ++ "\",\"match\":true,\"source\":\"path\"}," ++
            "{\"name\":\"tinykg\",\"resolved_path\":null,\"sha256\":null,\"expected_sha256\":null,\"match\":null,\"source\":null}]}\n",
        out.written(),
    );
}

test "doctor text is one line per check" {
    const allocator = std.testing.allocator;
    var report = try testReport(allocator);
    defer report.deinit(allocator);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeText(&out.writer, &report);
    try std.testing.expectEqualStrings(
        "ripgrep /opt/tools/rg source=path sha256=" ++ ("0123456789abcdef" ** 4) ++ " expected=" ++ ("0123456789abcdef" ** 4) ++ " match=true\n" ++
            "tinykg unresolved source=- sha256=- expected=none match=n/a\n",
        out.written(),
    );
}

test "doctor health: unresolved fails, a mismatch fails, no expectation passes" {
    const allocator = std.testing.allocator;
    var unresolved = try testReport(allocator);
    defer unresolved.deinit(allocator);
    try std.testing.expect(!unresolved.healthy());

    unresolved.checks[1].resolved_path = try allocator.dupe(u8, "/opt/tools/tinykg");
    try std.testing.expect(unresolved.healthy());

    unresolved.checks[0].match = false;
    try std.testing.expect(!unresolved.healthy());
}

test "doctor hashes a file in chunks and matches the one-shot digest" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try allocator.alloc(u8, 200_000);
    defer allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i * 7 + i / 251);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blob.bin", .data = bytes });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const path = try std.fmt.allocPrint(allocator, "{s}/blob.bin", .{root});
    defer allocator.free(path);

    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &expected, .{});
    const hex = std.fmt.bytesToHex(expected, .lower);
    const hashed = try hashFile(path);
    try std.testing.expectEqualStrings(&hex, &hashed);

    const missing = try std.fmt.allocPrint(allocator, "{s}/absent.bin", .{root});
    defer allocator.free(missing);
    try std.testing.expectError(error.Unreadable, hashFile(missing));
}

test "doctor check with an expectation but an unreadable file is a mismatch, not a crash" {
    const allocator = std.testing.allocator;
    var check = try Check.init(allocator, "tinykg", .{ .path = "/definitely/absent/tinykg", .source = .env }, &test_digest);
    defer check.deinit(allocator);
    try std.testing.expect(check.sha256 == null);
    try std.testing.expectEqual(@as(?bool, false), check.match);
    try std.testing.expectEqual(@as(?Source, .env), check.source);
}
