//! TAB 补全：根据当前 buffer + cursor 计算补全候选。
//!
//! 两种场景：
//! 1. 整行以 `/` 开头且无空格 → slash command 补全（从固定命令表）
//! 2. 否则 → 光标前最后一个"路径 token"做文件路径补全（扫目录）
//!
//! 设计：纯函数式——输入 (line, cursor)，输出候选列表 + 公共前缀。
//! 调用方（loop.zig）负责：唯一候选直接补全；多候选打印列表 + 补到公共前缀。

const std = @import("std");

pub const SLASH_COMMANDS = [_][]const u8{
    "/help",        "/clear",  "/tools",   "/skills",  "/history",
    "/model",       "/resume", "/retry",   "/compact", "/cost",
    "/doctor",      "/config", "/init",    "/mcp",     "/agents",
    "/permissions", "/memory", "/commit",  "/review",  "/exit",
};

pub const Result = struct {
    /// 候选项（借用：slash 命令是静态字符串；路径是 owned，见 owns_candidates）。
    candidates: [][]const u8,
    /// 要替换的 token 在 line 中的起始字节（候选会替换 [replace_start, cursor)）。
    replace_start: usize,
    /// 候选是否 owned（路径补全 = true，需调用方 free 每个 + 数组）。
    owns_candidates: bool,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.owns_candidates) {
            for (self.candidates) |c| allocator.free(c);
        }
        allocator.free(self.candidates);
    }
};

/// 计算补全。无候选返回 candidates.len == 0。
pub fn compute(allocator: std.mem.Allocator, line: []const u8, cursor: usize) !Result {
    const upto = line[0..@min(cursor, line.len)];

    // slash command：整行 trim 后以 '/' 开头且没有空格
    const trimmed = std.mem.trimStart(u8, upto, " \t");
    if (std.mem.startsWith(u8, trimmed, "/") and std.mem.indexOfScalar(u8, trimmed, ' ') == null) {
        const start = line.len - upto.len + (upto.len - trimmed.len); // trimmed 在 line 中的起点
        return try slashCandidates(allocator, trimmed, start);
    }

    // 路径补全：取光标前最后一个空白分隔的 token
    var tok_start = upto.len;
    while (tok_start > 0 and !isWs(upto[tok_start - 1])) : (tok_start -= 1) {}
    const token = upto[tok_start..];
    if (token.len == 0) return .{ .candidates = &.{}, .replace_start = cursor, .owns_candidates = false };

    return try pathCandidates(allocator, token, tok_start);
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn slashCandidates(allocator: std.mem.Allocator, prefix: []const u8, start: usize) !Result {
    var list = std.ArrayList([]const u8).empty;
    errdefer list.deinit(allocator);
    for (SLASH_COMMANDS) |cmd| {
        if (std.mem.startsWith(u8, cmd, prefix)) try list.append(allocator, cmd);
    }
    return .{ .candidates = try list.toOwnedSlice(allocator), .replace_start = start, .owns_candidates = false };
}

fn pathCandidates(allocator: std.mem.Allocator, token: []const u8, tok_start: usize) !Result {
    // 拆 token 为 dir + base
    const slash = std.mem.lastIndexOfScalar(u8, token, '/');
    const dir_path: []const u8 = if (slash) |s| token[0 .. s + 1] else "./";
    const base: []const u8 = if (slash) |s| token[s + 1 ..] else token;
    // replace_start 指向 base 的起点（保留已输入的目录前缀）
    const replace_start = if (slash) |s| tok_start + s + 1 else tok_start;

    var dbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const dir_for_open = if (dir_path.len == 0) "." else dir_path;
    if (dir_for_open.len >= dbuf.len) return .{ .candidates = &.{}, .replace_start = replace_start, .owns_candidates = false };
    @memcpy(dbuf[0..dir_for_open.len], dir_for_open);
    dbuf[dir_for_open.len] = 0;

    const dirp = std.c.opendir(@ptrCast(&dbuf)) orelse {
        return .{ .candidates = &.{}, .replace_start = replace_start, .owns_candidates = false };
    };
    defer _ = std.c.closedir(dirp);

    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |c| allocator.free(c);
        list.deinit(allocator);
    }

    while (std.c.readdir(dirp)) |ent| {
        const name_ptr: [*:0]const u8 = @ptrCast(&ent.name);
        const name = std.mem.span(name_ptr);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (!std.mem.startsWith(u8, name, base)) continue;
        const is_dir = ent.type == std.c.DT.DIR;
        const owned = if (is_dir)
            try std.fmt.allocPrint(allocator, "{s}/", .{name})
        else
            try allocator.dupe(u8, name);
        try list.append(allocator, owned);
        if (list.items.len >= 50) break; // 上限防爆
    }
    return .{ .candidates = try list.toOwnedSlice(allocator), .replace_start = replace_start, .owns_candidates = true };
}

/// 候选的最长公共前缀（用于 TAB 补到歧义点）。
pub fn commonPrefix(candidates: []const []const u8) []const u8 {
    if (candidates.len == 0) return "";
    if (candidates.len == 1) return candidates[0];
    var prefix = candidates[0];
    for (candidates[1..]) |c| {
        var i: usize = 0;
        while (i < prefix.len and i < c.len and prefix[i] == c[i]) : (i += 1) {}
        prefix = prefix[0..i];
    }
    return prefix;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "slash completion: /he -> /help" {
    var r = try compute(testing.allocator, "/he", 3);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.candidates.len);
    try testing.expectEqualStrings("/help", r.candidates[0]);
    try testing.expectEqual(@as(usize, 0), r.replace_start);
}

test "slash completion: /co -> commit/compact/config/cost" {
    var r = try compute(testing.allocator, "/co", 3);
    defer r.deinit(testing.allocator);
    try testing.expect(r.candidates.len >= 3);
    const pfx = commonPrefix(r.candidates);
    try testing.expectEqualStrings("/co", pfx);
}

test "slash completion: no match" {
    var r = try compute(testing.allocator, "/zzz", 4);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.candidates.len);
}

test "commonPrefix" {
    const c = [_][]const u8{ "/commit", "/compact", "/config" };
    try testing.expectEqualStrings("/co", commonPrefix(&c));
}

test "path completion finds known file" {
    // /tmp 一定存在；造一个唯一前缀文件
    const path = "/tmp/cc-zig-complete-uniq-xyz.txt";
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path);

    var r = try compute(testing.allocator, "cat /tmp/cc-zig-complete-uniq-", 30);
    defer r.deinit(testing.allocator);
    try testing.expect(r.candidates.len >= 1);
    var found = false;
    for (r.candidates) |c| {
        if (std.mem.eql(u8, c, "cc-zig-complete-uniq-xyz.txt")) found = true;
    }
    try testing.expect(found);
}
