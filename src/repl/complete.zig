//! TAB 补全：根据当前 buffer + cursor 计算补全候选。
//!
//! 两种场景：
//! 1. 整行以 `/` 开头且无空格 → slash command 补全（从固定命令表）
//! 2. 否则 → 光标前最后一个"路径 token"做文件路径补全（扫目录）
//!
//! 设计：纯函数式——输入 (line, cursor)，输出候选列表 + 公共前缀。
//! 调用方（loop.zig）负责：唯一候选直接补全；多候选打印列表 + 补到公共前缀。

const std = @import("std");

pub const SlashCmd = struct { name: []const u8, desc: []const u8 };

/// slash 命令表(name + 一行描述,供 `/` 菜单与补全共用)。
pub const SLASH_COMMAND_TABLE = [_]SlashCmd{
    .{ .name = "/help", .desc = "Show help and available commands" },
    .{ .name = "/clear", .desc = "Clear conversation history" },
    .{ .name = "/tools", .desc = "List available tools" },
    .{ .name = "/skills", .desc = "List available skills" },
    .{ .name = "/history", .desc = "Show input history" },
    .{ .name = "/model", .desc = "Show or switch the model" },
    .{ .name = "/resume", .desc = "Resume a previous session" },
    .{ .name = "/retry", .desc = "Retry the last request" },
    .{ .name = "/compact", .desc = "Compact the conversation context" },
    .{ .name = "/cost", .desc = "Show token usage and cost" },
    .{ .name = "/doctor", .desc = "Diagnose the environment" },
    .{ .name = "/config", .desc = "Show configuration" },
    .{ .name = "/init", .desc = "Initialize project memory (CLAUDE.md)" },
    .{ .name = "/mcp", .desc = "Manage MCP servers" },
    .{ .name = "/agents", .desc = "List subagents" },
    .{ .name = "/permissions", .desc = "Show permission rules and mode" },
    .{ .name = "/memory", .desc = "Edit persistent memory" },
    .{ .name = "/commit", .desc = "Create a git commit" },
    .{ .name = "/review", .desc = "Ask the model to review the current diff" },
    .{ .name = "/exit", .desc = "Exit REPL" },
};

pub const SLASH_COMMANDS = blk: {
    var arr: [SLASH_COMMAND_TABLE.len][]const u8 = undefined;
    for (SLASH_COMMAND_TABLE, 0..) |c, i| arr[i] = c.name;
    break :blk arr;
};

/// slash 菜单是否应弹出(整行 trim 后以 `/` 开头且无空格 → 命令补全态)。
/// 单一真相源:dispatch(导航键语义)与 drawSlashMenu(渲染)共用,防两处判定漂移。
pub fn slashMenuOpen(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "/")) return false;
    if (std.mem.indexOfScalar(u8, trimmed, ' ') != null) return false;
    return slashFilterCount(line) > 0;
}

/// 当前 `/` 前缀匹配的命令数(菜单显示的行数,也是导航上限)。
pub fn slashFilterCount(line: []const u8) usize {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "/")) return 0;
    if (std.mem.indexOfScalar(u8, trimmed, ' ') != null) return 0;
    var n: usize = 0;
    for (SLASH_COMMAND_TABLE) |cmd| {
        if (std.mem.startsWith(u8, cmd.name, trimmed)) n += 1;
    }
    return n;
}

/// 取第 idx 个匹配命令(0-based,顺序同 drawSlashMenu);越界返回 null。
pub fn slashNthMatch(line: []const u8, idx: usize) ?SlashCmd {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "/")) return null;
    var n: usize = 0;
    for (SLASH_COMMAND_TABLE) |cmd| {
        if (!std.mem.startsWith(u8, cmd.name, trimmed)) continue;
        if (n == idx) return cmd;
        n += 1;
    }
    return null;
}

/// @-mention 菜单是否激活(对齐 cc DIFF#5):光标前最后一个空白分隔 token 以 `@` 开头。
/// 与 compute() 的 @-mention 路径同源(token[0]=='@' → pathCandidates)。
pub fn atMenuActive(line: []const u8, cursor: usize) bool {
    const upto = line[0..@min(cursor, line.len)];
    var tok_start = upto.len;
    while (tok_start > 0 and !isWs(upto[tok_start - 1])) : (tok_start -= 1) {}
    const token = upto[tok_start..];
    return token.len >= 1 and token[0] == '@';
}

/// @ 菜单候选(文件路径,owned)。调用方用完 deinit。复用 compute 的 @-mention 路径。
pub fn atCandidates(allocator: std.mem.Allocator, line: []const u8, cursor: usize) !Result {
    return compute(allocator, line[0..@min(cursor, line.len)], @min(cursor, line.len));
}

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

    // @-mention:`@<path>` 触发文件路径补全(对齐 Claude Code 的 @ 文件提及)。
    // 保留 @ 前缀,只对 @ 后面的路径部分补全。
    if (token[0] == '@') {
        return try pathCandidates(allocator, token[1..], tok_start + 1);
    }

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

test "@-mention completion finds file" {
    const path = "/tmp/cc-zig-atmention-uniq.txt";
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path);

    // 输入 "review @/tmp/cc-zig-atmention-" → 补全应找到文件,replace_start 在 @ 之后
    const line = "review @/tmp/cc-zig-atmention-";
    var r = try compute(testing.allocator, line, line.len);
    defer r.deinit(testing.allocator);
    try testing.expect(r.candidates.len >= 1);
    var found = false;
    for (r.candidates) |c| {
        if (std.mem.eql(u8, c, "cc-zig-atmention-uniq.txt")) found = true;
    }
    try testing.expect(found);
    // replace_start 指向 @ 后的 / (保留 @ 前缀不被覆盖)
    try testing.expect(line[r.replace_start - 1] == '/' or r.replace_start > 7);
}
