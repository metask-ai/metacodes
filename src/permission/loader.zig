//! Settings 5 层文件加载:把 managed / cli / local_project / shared_project / user
//! 5 处的 JSON 都读出来,各自解析成 Layer,聚合成 MergedSettings。
//!
//! 单层文件不存在 / 解析失败 → 只 log,不阻塞其它层和启动。

const std = @import("std");
const pfs = @import("platform").fs;
const settings = @import("settings.zig");
const log = @import("../util/log.zig");

pub const Paths = struct {
    /// managed-settings.json 系统级路径(可空,空就只查默认)
    managed: ?[]const u8 = null,
    /// CLI --settings <path>(可空)
    cli: ?[]const u8 = null,
    /// project 根目录(用于推导 .claude/settings*.json),可空则跳过 project 两层
    project_root: ?[]const u8 = null,
    /// HOME(用于 ~/.claude/settings.json),可空则取 $HOME
    home: ?[]const u8 = null,
    /// CLI inline 规则(--allowedTools / --disallowedTools / --add-dir),逗号分隔。
    cli_allow: ?[]const u8 = null,
    cli_deny: ?[]const u8 = null,
    /// --add-dir 多值,用 \x00 分隔。
    cli_dirs: ?[]const u8 = null,
};

/// 加载所有 5 层,聚合返回。caller 负责 deinit。
pub fn load(alloc: std.mem.Allocator, paths: Paths) !settings.MergedSettings {
    var layers: std.ArrayList(settings.Layer) = .empty;
    errdefer {
        for (layers.items) |L| {
            for (L.allow) |r| alloc.free(r.raw);
            for (L.ask) |r| alloc.free(r.raw);
            for (L.deny) |r| alloc.free(r.raw);
            alloc.free(L.allow);
            alloc.free(L.ask);
            alloc.free(L.deny);
            for (L.additional_directories) |d| alloc.free(d);
            alloc.free(L.additional_directories);
        }
        layers.deinit(alloc);
    }

    // 顺序:managed 最高优先(放第一,但 evaluate 按 deny→allow→ask 走,
    //       deny 在哪一层都先扫,所以放第一只对 allow/ask 决胜有意义)
    try maybePushFile(alloc, &layers, .managed, defaultManagedPath(paths));

    // CLI inline layer(--allowedTools/--disallowedTools/--add-dir)在 --settings 文件之前
    if (paths.cli_allow != null or paths.cli_deny != null or paths.cli_dirs != null) {
        const L = try settings.buildInlineLayer(alloc, .cli, paths.cli_allow, null, paths.cli_deny, paths.cli_dirs);
        try layers.append(alloc, L);
    }
    try maybePushFile(alloc, &layers, .cli, paths.cli);

    if (paths.project_root) |root| {
        var buf1: [std.fs.max_path_bytes]u8 = undefined;
        const local = std.fmt.bufPrint(&buf1, "{s}/.claude/settings.local.json", .{root}) catch null;
        if (local) |p| try maybePushFile(alloc, &layers, .local_project, p);

        var buf2: [std.fs.max_path_bytes]u8 = undefined;
        const shared = std.fmt.bufPrint(&buf2, "{s}/.claude/settings.json", .{root}) catch null;
        if (shared) |p| try maybePushFile(alloc, &layers, .shared_project, p);
    }

    // HOME / Windows USERPROFILE(paths.home 优先,回退可移植 homeDir)。
    const home_path = paths.home orelse @import("platform").paths.homeDir();
    if (home_path) |h| {
        var buf3: [std.fs.max_path_bytes]u8 = undefined;
        const user = std.fmt.bufPrint(&buf3, "{s}/.claude/settings.json", .{h}) catch null;
        if (user) |p| try maybePushFile(alloc, &layers, .user, p);
    }

    return settings.MergedSettings{
        .layers = try layers.toOwnedSlice(alloc),
        .allocator = alloc,
    };
}

fn defaultManagedPath(p: Paths) ?[]const u8 {
    if (p.managed) |m| return m;
    // 平台默认 — 不主动去 stat:返回 null,maybePushFile 跳过
    return null;
}

fn maybePushFile(
    alloc: std.mem.Allocator,
    layers: *std.ArrayList(settings.Layer),
    source: settings.Source,
    path_opt: ?[]const u8,
) !void {
    const path = path_opt orelse return;
    if (path.len == 0) return;
    const content = readFile(alloc, path) catch |e| {
        if (e == error.FileNotFound) return; // 沉默
        log.warn("settings", "read {s} failed: {s}", .{ path, @errorName(e) });
        return;
    };
    defer alloc.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch |e| {
        log.warn("settings", "parse {s} failed: {s}", .{ path, @errorName(e) });
        return;
    };
    defer parsed.deinit();

    const L = settings.parseLayer(alloc, source, parsed.value) catch |e| {
        log.warn("settings", "build layer {s} failed: {s}", .{ path, @errorName(e) });
        return;
    };
    try layers.append(alloc, L);
    log.info("settings", "loaded {s}: allow={d} ask={d} deny={d}", .{
        path,
        L.allow.len,
        L.ask.len,
        L.deny.len,
    });
}

fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len + 1 > pbuf.len) return error.PathTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&pbuf), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = pfs.close(fd);

    var all: std.ArrayList(u8) = .empty;
    errdefer all.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buf);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try all.appendSlice(alloc, buf[0..@intCast(n)]);
    }
    return try all.toOwnedSlice(alloc);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "load: cli layer parse + evaluate" {
    const alloc = testing.allocator;

    // 用 pid + 时间拼一个唯一路径(规避 0.16 std.c 无 mkstemp)
    const pid: i64 = std.c.getpid();
    var path_buf: [128]u8 = undefined;
    const path_with_nul = try std.fmt.bufPrint(&path_buf, "/tmp/cczig_settings_{d}.json\x00", .{pid});
    const path = path_with_nul[0 .. path_with_nul.len - 1];

    const fd = pfs.open(@ptrCast(path_with_nul.ptr), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.WriteFailed;
    defer _ = pfs.close(fd);
    defer _ = std.c.unlink(@ptrCast(path_with_nul.ptr));

    const json_body = "{\"permissions\":{\"allow\":[\"Bash(git *)\"],\"deny\":[\"Bash(git push)\"]}}";
    _ = pfs.write(fd, json_body);

    var ms = try load(alloc, .{ .cli = path, .home = "", .project_root = null, .managed = null });
    defer ms.deinit();

    try testing.expectEqual(@as(usize, 1), ms.layers.len);

    var mctx = @import("rule_spec.zig").MatchContext{};
    try testing.expectEqual(settings.Decision.allow, settings.evaluate(&ms, &mctx, "Bash", "{\"command\":\"git status\"}"));
    try testing.expectEqual(settings.Decision.deny, settings.evaluate(&ms, &mctx, "Bash", "{\"command\":\"git push\"}"));
}
