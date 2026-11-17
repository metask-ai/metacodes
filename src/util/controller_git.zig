//! Git run by the controller must not execute candidate code through index
//! callbacks, hooks or content filters. Keep these overrides out of the
//! repository's durable configuration and the user's own Git commands.
const std = @import("std");
const common = @import("../tools/common.zig");
const AbortSignal = @import("abort.zig").AbortSignal;

pub const Error = error{ OutOfMemory, Aborted, GitFailed };

/// Owned argv prefix. Append the fixed Git operation after `items`.
pub const Prefix = struct {
    items: [][]const u8,

    pub fn deinit(self: Prefix, gpa: std.mem.Allocator) void {
        for (self.items) |item| gpa.free(item);
        gpa.free(self.items);
    }
};

const fixed = [_][]const u8{ "git", "--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null" };
const max_config_bytes = 64 * 1024;
const max_drivers = 128;

/// Discover filter names without running them, including included config,
/// then override every driver for this invocation only. Empty filter commands
/// pass bytes through without starting even an identity helper process.
pub fn prefix(gpa: std.mem.Allocator, cwd: []const u8, abort: ?*const AbortSignal) Error!Prefix {
    const query = [_]?[*:0]const u8{
        "/usr/bin/env", "git",                      "--no-pager",                                      "-c",         "core.fsmonitor=false",
        "-c",           "core.hooksPath=/dev/null", "config",                                          "--includes", "--null",
        "--name-only",  "--get-regexp",             "^filter\\..*\\.(clean|smudge|process|required)$", null,
    };
    const out = common.spawnCaptureWithStderrTimed(&query, gpa, abort, 30_000, null, max_config_bytes, cwd) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Aborted => error.Aborted,
        else => error.GitFailed,
    };
    defer gpa.free(out.stdout);
    defer gpa.free(out.stderr);
    // Exit 1 means there are no matching keys. A truncated query must never
    // leave one executable driver outside the override set.
    if (!out.capture_complete or (out.exit_code != 0 and out.exit_code != 1)) return error.GitFailed;
    if (out.stdout.len != 0 and out.stdout[out.stdout.len - 1] != 0) return error.GitFailed;

    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(gpa);
    errdefer for (items.items) |item| gpa.free(item);
    for (fixed) |arg| try push(gpa, &items, arg);
    var drivers: std.StringHashMap(void) = .init(gpa);
    defer drivers.deinit();
    var keys = std.mem.splitScalar(u8, out.stdout, 0);
    while (keys.next()) |key| {
        if (key.len == 0) continue;
        const last = std.mem.lastIndexOfScalar(u8, key, '.') orelse return error.GitFailed;
        if (!std.mem.startsWith(u8, key, "filter.") or last <= "filter.".len) return error.GitFailed;
        const driver = key[0..last];
        const entry = try drivers.getOrPut(driver);
        if (entry.found_existing) continue;
        if (drivers.count() > max_drivers) return error.GitFailed;
        for ([_][]const u8{ ".clean=", ".smudge=", ".process=", ".required=false" }) |suffix| {
            try push(gpa, &items, "-c");
            const setting = try std.fmt.allocPrint(gpa, "{s}{s}", .{ driver, suffix });
            defer gpa.free(setting);
            try push(gpa, &items, setting);
        }
    }
    return .{ .items = try items.toOwnedSlice(gpa) };
}

fn push(gpa: std.mem.Allocator, items: *std.ArrayList([]const u8), arg: []const u8) error{OutOfMemory}!void {
    const owned = try gpa.dupe(u8, arg);
    errdefer gpa.free(owned);
    try items.append(gpa, owned);
}
