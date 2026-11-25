//! The update notice of an interactive session (doc/UPDATE_DESIGN.md §13).

const std = @import("std");
const platform = @import("metacodes-internal").platform;
const install = @import("install.zig");
const release_fetch = @import("release_fetch.zig");
const update = @import("update.zig");
const files = @import("terminal_setup/files.zig");
const state_root_mod = @import("metacodes-internal").util.state_root;
const time = @import("metacodes-internal").util.time;

pub const file_name = "update-check.json";
pub const check_interval_s: i64 = 24 * 60 * 60;
pub const opt_out_env = "METACODES_NO_UPDATE_CHECK";

pub const ReleaseInstall = struct {
    prefix: []const u8,
    version: []const u8,
    base: []const u8,
};

pub const Cache = struct {
    checked_at: i64 = 0,
    base: []const u8 = "",
    latest: []const u8 = "",
    skipped: []const u8 = "",
};

pub const Choice = enum { update, skip, skip_version };

pub fn releaseInstall(arena: std.mem.Allocator, io: std.Io) ?ReleaseInstall {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = platform.paths.selfExeRealPath(&exe_buf) orelse return null;
    const prefix = state_root_mod.prefixOf(exe) orelse return null;
    return releaseInstallAt(arena, io, arena.dupe(u8, prefix) catch return null);
}

pub fn releaseInstallAt(arena: std.mem.Allocator, io: std.Io, prefix: []const u8) ?ReleaseInstall {
    const record = install.readRecord(arena, io, prefix) catch return null;
    if (record.invalid_update_source or !release_fetch.isStableVersion(record.version)) return null;
    const base = record.update_source.releaseBase() orelse return null;
    return .{ .prefix = prefix, .version = record.version, .base = base };
}

pub fn offered(found: ReleaseInstall, cache: Cache) ?[]const u8 {
    if (!std.mem.eql(u8, cache.base, found.base)) return null;
    if (!install.isOlder(found.version, cache.latest)) return null;
    if (std.mem.eql(u8, cache.latest, cache.skipped)) return null;
    return cache.latest;
}

pub fn due(found: ReleaseInstall, cache: Cache, now: i64) bool {
    if (!std.mem.eql(u8, cache.base, found.base)) return true;
    return now < cache.checked_at or now - cache.checked_at >= check_interval_s;
}

pub fn parseChoice(answer: []const u8) Choice {
    const trimmed = std.mem.trim(u8, answer, " \t");
    if (std.mem.eql(u8, trimmed, "1")) return .update;
    if (std.mem.eql(u8, trimmed, "3")) return .skip_version;
    return .skip;
}

pub fn readCache(arena: std.mem.Allocator, io: std.Io, state_root: []const u8) Cache {
    const path = std.fs.path.join(arena, &.{ state_root, file_name }) catch return .{};
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 << 10)) catch return .{};
    return std.json.parseFromSliceLeaky(Cache, arena, bytes, .{ .ignore_unknown_fields = true }) catch .{};
}

pub fn writeCache(arena: std.mem.Allocator, state_root: []const u8, cache: Cache) void {
    const path = std.fs.path.join(arena, &.{ state_root, file_name }) catch return;
    const bytes = std.json.Stringify.valueAlloc(arena, cache, .{}) catch return;
    files.writeAtomic(path, bytes, true) catch {};
}

pub fn startCheck(found: ReleaseInstall, state_root: []const u8, cache: Cache) void {
    const check = Check.create(found, state_root, cache) catch return;
    const thread = platform.thread.spawn(.full, Check.run, .{check}) catch {
        check.destroy();
        return;
    };
    thread.detach();
}

const Check = struct {
    arena: std.heap.ArenaAllocator,
    base: []const u8,
    state_root: []const u8,
    cache: Cache,

    fn create(found: ReleaseInstall, state_root: []const u8, cache: Cache) !*Check {
        const self = try std.heap.page_allocator.create(Check);
        self.arena = .init(std.heap.page_allocator);
        errdefer self.destroy();
        const a = self.arena.allocator();
        self.base = try a.dupe(u8, found.base);
        self.state_root = try a.dupe(u8, state_root);
        self.cache = .{
            .checked_at = cache.checked_at,
            .base = try a.dupe(u8, cache.base),
            .latest = try a.dupe(u8, cache.latest),
            .skipped = try a.dupe(u8, cache.skipped),
        };
        return self;
    }

    fn destroy(self: *Check) void {
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }

    fn run(self: *Check) void {
        defer self.destroy();
        const a = self.arena.allocator();
        const latest = fetchLatest(a, self.base) orelse
            if (std.mem.eql(u8, self.cache.base, self.base)) self.cache.latest else "";
        writeCache(a, self.state_root, .{
            .checked_at = time.nowUnix(),
            .base = self.base,
            .latest = latest,
            .skipped = self.cache.skipped,
        });
    }
};

fn fetchLatest(arena: std.mem.Allocator, base: []const u8) ?[]const u8 {
    var fetcher = release_fetch.Fetcher.init(arena, base, update.user_agent, null) catch return null;
    fetcher.echo_errors = false;
    var report: release_fetch.Report = .{};
    return fetcher.latestTag(arena, base, &report) catch null;
}

const testing = std.testing;

const install_at: ReleaseInstall = .{ .prefix = "/opt/metacodes", .version = "0.13.0", .base = "https://example.test/releases" };

test "offered: a newer release from the same base that was not skipped" {
    const base = install_at.base;
    try testing.expectEqualStrings("0.14.0", offered(install_at, .{ .base = base, .latest = "0.14.0" }).?);
    try testing.expectEqualStrings("0.14.0", offered(install_at, .{ .base = base, .latest = "0.14.0", .skipped = "0.13.5" }).?);
    try testing.expect(offered(install_at, .{ .base = base, .latest = "0.14.0", .skipped = "0.14.0" }) == null);
    try testing.expect(offered(install_at, .{ .base = base, .latest = "0.13.0" }) == null);
    try testing.expect(offered(install_at, .{ .base = base, .latest = "0.12.9" }) == null);
    try testing.expect(offered(install_at, .{ .base = base, .latest = "" }) == null);
    try testing.expect(offered(install_at, .{ .base = "https://mirror.test/r", .latest = "0.14.0" }) == null);
}

test "due: once a day, at once for another base or a clock that went back" {
    const base = install_at.base;
    try testing.expect(due(install_at, .{}, 1000));
    try testing.expect(!due(install_at, .{ .base = base, .checked_at = 1000 }, 1000 + check_interval_s - 1));
    try testing.expect(due(install_at, .{ .base = base, .checked_at = 1000 }, 1000 + check_interval_s));
    try testing.expect(due(install_at, .{ .base = base, .checked_at = 1000 }, 999));
    try testing.expect(due(install_at, .{ .base = "https://mirror.test/r", .checked_at = 1000 }, 1000));
}

test "parseChoice: 1 updates, 3 skips the version, anything else skips" {
    try testing.expectEqual(Choice.update, parseChoice("1"));
    try testing.expectEqual(Choice.update, parseChoice(" 1 "));
    try testing.expectEqual(Choice.skip_version, parseChoice("3"));
    try testing.expectEqual(Choice.skip, parseChoice(""));
    try testing.expectEqual(Choice.skip, parseChoice("2"));
    try testing.expectEqual(Choice.skip, parseChoice("yes"));
}

test "readCache and writeCache round-trip; a missing or broken file reads as empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];

    try testing.expectEqual(@as(i64, 0), readCache(arena, testing.io, root).checked_at);
    const state = try std.fs.path.join(arena, &.{ root, "state" });
    writeCache(arena, state, .{ .checked_at = 42, .base = "https://b.test/r", .latest = "1.2.3", .skipped = "1.2.2" });
    const back = readCache(arena, testing.io, state);
    try testing.expectEqual(@as(i64, 42), back.checked_at);
    try testing.expectEqualStrings("https://b.test/r", back.base);
    try testing.expectEqualStrings("1.2.3", back.latest);
    try testing.expectEqualStrings("1.2.2", back.skipped);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "state/" ++ file_name, .data = "not json" });
    try testing.expectEqualStrings("", readCache(arena, testing.io, state).latest);
}
