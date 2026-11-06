//! TAB 补全：根据当前 buffer + cursor 计算补全候选。
//!
//! 两种场景：
//! 1. 整行以 `/` 开头且无空格 → slash command 补全（内建命令表 + 可由用户调用的 skill,见 SlashCatalog）
//! 2. 否则 → 光标前最后一个"路径 token"做文件路径补全（扫目录）
//!
//! 设计：纯函数式——输入 (line, cursor)，输出候选列表 + 公共前缀。
//! 调用方（loop.zig）负责：唯一候选直接补全；多候选打印列表 + 补到公共前缀。

const std = @import("std");
const tt = @import("../tools/test_tmp.zig"); // 测试 fixture 唯一路径(并发隔离)
const pfs = @import("platform").fs;
const pdir = @import("platform").dir;

pub const SlashKind = enum { builtin, skill };

pub const SlashCmd = struct {
    /// 含前导 `/`。
    name: []const u8,
    desc: []const u8,
    kind: SlashKind = .builtin,
    /// Claude Code `argument-hint`,菜单里跟在命令名后(dim)。
    hint: []const u8 = "",
    /// Enter 选中时只填 `name ` 等用户补参数,而不是立即提交(skill 声明了参数时)。
    takes_args: bool = false,
    /// A Skill's tier (`user`, `project`, `plugin`, …), shown after its
    /// description as Claude Code does; empty when unknown.
    source: []const u8 = "",
};

/// `/` 菜单与 Tab 补全的命令源:内建命令在前,可由用户调用的 skill 在后。
/// 由 REPL loop 构建并持有,UiState 借用(见 buildSlashCatalog)。
pub const SlashCatalog = struct {
    entries: []const SlashCmd,

    pub const builtin: SlashCatalog = .{ .entries = &SLASH_COMMAND_TABLE };
};

pub const MODEL_MENU_MAX_ROWS: usize = 8;

/// How a key moves the selection of a list menu (`/models`).
pub const MenuStep = enum { previous, next, page_up, page_down, first, last };

/// The selection after `step` over `len` entries. ↑/↓ wrap, as the menus
/// always have; a page moves by `page` and stops at either end.
pub fn menuMove(len: usize, selected: usize, step: MenuStep, page: usize) usize {
    if (len == 0) return 0;
    const current = @min(selected, len - 1);
    const by = @max(page, 1);
    return switch (step) {
        .next => (current + 1) % len,
        .previous => if (current == 0) len - 1 else current - 1,
        .page_down => @min(current + by, len - 1),
        .page_up => current -| by,
        .first => 0,
        .last => len - 1,
    };
}

pub const MenuWindow = struct { top: usize, end: usize };

/// The entries of a `len`-entry menu drawn in `rows` lines: the first page
/// until the selection leaves it, then the page that ends at the selection.
/// Every entry is reachable and the selected one is always on screen; a
/// menu that drew only its first page made entry `rows + 1` unselectable.
pub fn menuWindow(len: usize, selected: usize, rows: usize) MenuWindow {
    if (len == 0) return .{ .top = 0, .end = 0 };
    const page = @max(rows, 1);
    const current = @min(selected, len - 1);
    const top = if (current + 1 > page) current + 1 - page else 0;
    return .{ .top = top, .end = @min(top + page, len) };
}

/// The built-in commands: the `/` menu, Tab completion, `/help` and the
/// unknown-command suggestion all read this one table. Alphabetical, as
/// Claude Code lists them; Skills follow in `buildSlashCatalog`.
pub const SLASH_COMMAND_TABLE = [_]SlashCmd{
    .{ .name = "/add-dir", .desc = "Add a working directory", .hint = "<path>", .takes_args = true },
    .{ .name = "/agents", .desc = "List available subagents" },
    .{ .name = "/alias", .desc = "Name a route: pin, float, use, or remove" },
    .{ .name = "/btw", .desc = "Ask a side question without adding it to the conversation", .hint = "<question>", .takes_args = true },
    .{ .name = "/clear", .desc = "Start a new session with empty context" },
    .{ .name = "/commit", .desc = "Create a git commit" },
    .{ .name = "/compact", .desc = "Free up context by dropping the oldest messages" },
    .{ .name = "/config", .desc = "Show configuration" },
    .{ .name = "/cost", .desc = "Show token usage and cost" },
    .{ .name = "/doctor", .desc = "Diagnose the installation and configuration" },
    .{ .name = "/edit", .desc = "Edit one of your messages and rerun from it", .hint = "<n> <text>", .takes_args = true },
    .{ .name = "/effort", .desc = "Show or set reasoning effort" },
    .{ .name = "/exit", .desc = "Exit metacodes" },
    .{ .name = "/goal", .desc = "View or manage the session goal" },
    .{ .name = "/help", .desc = "Show help and available commands" },
    .{ .name = "/history", .desc = "Show input history" },
    .{ .name = "/hooks", .desc = "List hooks and hook configuration problems" },
    .{ .name = "/init", .desc = "Write a CLAUDE.md that documents the codebase" },
    .{ .name = "/kg", .desc = "Knowledge graph: status, memory, plan, cleanup" },
    .{ .name = "/login", .desc = "Sign in to a provider" },
    .{ .name = "/loop", .desc = "Control automatic continuation" },
    .{ .name = "/mcp", .desc = "List MCP servers" },
    .{ .name = "/memory", .desc = "List or edit memory files" },
    .{ .name = "/mode", .desc = "Cycle or set the permission mode" },
    .{ .name = "/model", .desc = "Choose a provider, model, and channel (Ctrl+O)" },
    .{ .name = "/models", .desc = "Choose the account API key for this session" },
    .{ .name = "/overrides", .desc = "Show or set request dialect overrides" },
    .{ .name = "/permissions", .desc = "Show permission rules and mode" },
    .{ .name = "/providers", .desc = "List routes; refresh, enable, disable, or remove one" },
    .{ .name = "/recap", .desc = "Summarize this session in one line" },
    .{ .name = "/resume", .desc = "Resume a previous session" },
    .{ .name = "/retry", .desc = "Resend the last message" },
    .{ .name = "/review", .desc = "Review the current diff" },
    .{ .name = "/skills", .desc = "List available skills" },
    .{ .name = "/terminal-setup", .desc = "Make Shift+Enter insert a newline in this terminal" },
    .{ .name = "/theme", .desc = "Show or switch the color theme" },
    .{ .name = "/tools", .desc = "List available tools" },
    .{ .name = "/transcript", .desc = "Browse the conversation (Ctrl+X Ctrl+O)" },
    .{ .name = "/vim", .desc = "Toggle vim key bindings" },
};

comptime {
    // The table is the one source for the menu's order: keep it sorted.
    for (SLASH_COMMAND_TABLE[1..], 1..) |cmd, i| {
        if (!std.mem.lessThan(u8, SLASH_COMMAND_TABLE[i - 1].name, cmd.name))
            @compileError("SLASH_COMMAND_TABLE must stay alphabetical: " ++ cmd.name);
    }
}

/// Whether `name` (with its `/`) is a built-in command.
pub fn isBuiltinCommand(name: []const u8) bool {
    for (SLASH_COMMAND_TABLE) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return true;
    }
    return false;
}

/// The command `query` (with its `/`) most likely meant, for "Did you mean
/// …?": the closest built-in or Skill name within two edits (a transposition
/// counts as one), ignoring case, and closer than the query's own length so
/// a one-letter typo is not matched against everything. Ties go to catalog
/// order (built-ins first).
pub fn closestCommand(catalog: SlashCatalog, query: []const u8) ?[]const u8 {
    if (query.len < 2 or query[0] != '/') return null;
    const needle = query[1..];
    var best: ?[]const u8 = null;
    var best_distance: usize = 3;
    for (catalog.entries) |cmd| {
        const distance = editDistance(needle, cmd.name[1..]) orelse continue;
        if (distance == 0 or distance >= best_distance or distance >= needle.len) continue;
        best = cmd.name;
        best_distance = distance;
    }
    return best;
}

/// Optimal string alignment distance, case-insensitive. Null for names too
/// long to be a typo of each other (the table is bounded).
fn editDistance(a: []const u8, b: []const u8) ?usize {
    const max = 48;
    if (a.len > max or b.len > max) return null;
    var rows: [3][max + 1]usize = undefined;
    for (0..b.len + 1) |j| rows[1][j] = j;
    for (1..a.len + 1) |i| {
        const cur = &rows[(i + 1) % 3];
        const prev = &rows[i % 3];
        const prev2 = &rows[(i + 2) % 3];
        cur[0] = i;
        for (1..b.len + 1) |j| {
            const cost: usize = if (std.ascii.toLower(a[i - 1]) == std.ascii.toLower(b[j - 1])) 0 else 1;
            var d = @min(prev[j] + 1, @min(cur[j - 1] + 1, prev[j - 1] + cost));
            if (i > 1 and j > 1 and std.ascii.toLower(a[i - 1]) == std.ascii.toLower(b[j - 2]) and
                std.ascii.toLower(a[i - 2]) == std.ascii.toLower(b[j - 1]))
            {
                d = @min(d, prev2[j - 2] + 1);
            }
            cur[j] = d;
        }
    }
    return rows[(a.len + 1) % 3][b.len];
}

/// slash 菜单是否应弹出(整行 trim 后以 `/` 开头且无空格 → 命令补全态)。
/// 单一真相源:dispatch(导航键语义)与 drawSlashMenu(渲染)共用,防两处判定漂移。
pub fn slashMenuOpen(catalog: SlashCatalog, line: []const u8) bool {
    return slashFilterCount(catalog, line) > 0;
}

/// `/model` 的服务端 catalog 菜单。它和普通 slash 菜单同占下边框与 footer 之间的区域,
/// 但导航/Enter 语义是选择模型,不是选择 slash command。
pub fn modelMenuOpen(line: []const u8) bool {
    _ = line;
    return false;
}

/// `/models` 的账号 API key 菜单(**凭证**选择,不是路由选择)。
///
/// issue #16 起 `/model` 不再进这个菜单:路由选择归跨 UI model picker
/// (`/model` 提交或 Ctrl+O),凭证选择仍留在这里——picker 的 credential 阶段
/// 还没落地(见 doc/PROVIDER_OFFER_ARCHITECTURE.md 的未实现清单)。
pub fn modelsMenuOpen(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return std.mem.eql(u8, trimmed, "/models");
}

/// A draft the `/models` picker menu is drawn under: `/models`, or `/model`
/// before it is submitted (`RenderRegion.drawModelsPickerMenu`).
pub fn modelsPickerLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return std.mem.eql(u8, trimmed, "/models") or std.mem.eql(u8, trimmed, "/model");
}

/// 菜单处于命令态时的查询串(含 `/`);非命令态 null。
fn slashQuery(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "/")) return null;
    if (std.mem.indexOfAny(u8, trimmed, " \t") != null) return null;
    return trimmed;
}

/// 匹配分档(对齐 cc 的命令联想:先前缀,再名字内子串)。0 = 不匹配。
fn matchTier(cmd: SlashCmd, query: []const u8) u2 {
    if (std.mem.startsWith(u8, cmd.name, query)) return 1;
    const needle = query[1..]; // 去掉 `/`
    if (needle.len >= 2 and containsIgnoreCase(cmd.name[1..], needle)) return 2;
    return 0;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// 当前查询匹配的命令数(菜单行数,也是导航上限)。
pub fn slashFilterCount(catalog: SlashCatalog, line: []const u8) usize {
    const query = slashQuery(line) orelse return 0;
    var n: usize = 0;
    for (catalog.entries) |cmd| {
        if (matchTier(cmd, query) != 0) n += 1;
    }
    return n;
}

/// 取第 idx 个匹配命令(0-based,前缀档在前、子串档在后,档内保持表序;
/// drawSlashMenu 用同一顺序);越界返回 null。
pub fn slashNthMatch(catalog: SlashCatalog, line: []const u8, idx: usize) ?SlashCmd {
    const query = slashQuery(line) orelse return null;
    var n: usize = 0;
    for ([_]u2{ 1, 2 }) |tier| {
        for (catalog.entries) |cmd| {
            if (matchTier(cmd, query) != tier) continue;
            if (n == idx) return cmd;
            n += 1;
        }
    }
    return null;
}

/// 构建 `/` 命令源:内建表 + 可由用户调用的 skill(`user-invocable: false` 的不进菜单)。
/// 与内建命令同名的 skill 不列出——loop 先分派内建命令,那个 skill 无法经 `/` 运行。
/// 返回的 entries 与名字由 `arena` 持有。
pub fn buildSlashCatalog(
    arena: std.mem.Allocator,
    skills: []const @import("../skills/runtime/definition.zig").Skill,
) !SlashCatalog {
    var list: std.ArrayList(SlashCmd) = .empty;
    try list.appendSlice(arena, &SLASH_COMMAND_TABLE);
    for (skills) |skill| {
        if (!skill.user_invocable) continue;
        const name = try std.fmt.allocPrint(arena, "/{s}", .{skill.name});
        var shadowed = false;
        for (SLASH_COMMAND_TABLE) |builtin_cmd| {
            if (std.mem.eql(u8, builtin_cmd.name, name)) shadowed = true;
        }
        if (shadowed) continue;
        try list.append(arena, .{
            .name = name,
            .desc = try collapseWhitespace(arena, skill.description),
            .kind = .skill,
            .hint = skill.argument_hint,
            .takes_args = skill.argument_hint.len != 0 or skill.arguments.len != 0,
        });
    }
    return .{ .entries = try list.toOwnedSlice(arena) };
}

fn collapseWhitespace(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (words.next()) |word| {
        if (out.items.len != 0) try out.append(arena, ' ');
        try out.appendSlice(arena, word);
    }
    return out.toOwnedSlice(arena);
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
    return compute(allocator, .builtin, line[0..@min(cursor, line.len)], @min(cursor, line.len));
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
pub fn compute(allocator: std.mem.Allocator, catalog: SlashCatalog, line: []const u8, cursor: usize) !Result {
    const upto = line[0..@min(cursor, line.len)];

    // slash command：整行 trim 后以 '/' 开头且没有空格
    const trimmed = std.mem.trimStart(u8, upto, " \t");
    if (std.mem.startsWith(u8, trimmed, "/") and std.mem.indexOfScalar(u8, trimmed, ' ') == null) {
        const start = line.len - upto.len + (upto.len - trimmed.len); // trimmed 在 line 中的起点
        return try slashCandidates(allocator, catalog, trimmed, start);
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

fn slashCandidates(allocator: std.mem.Allocator, catalog: SlashCatalog, prefix: []const u8, start: usize) !Result {
    var list = std.ArrayList([]const u8).empty;
    errdefer list.deinit(allocator);
    for (catalog.entries) |cmd| {
        if (std.mem.startsWith(u8, cmd.name, prefix)) try list.append(allocator, cmd.name);
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

    var it = pdir.open(@ptrCast(&dbuf)) orelse {
        return .{ .candidates = &.{}, .replace_start = replace_start, .owns_candidates = false };
    };
    defer pdir.close(&it);

    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |c| allocator.free(c);
        list.deinit(allocator);
    }

    while (pdir.next(&it)) |ent| {
        const name = ent.name;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (!std.mem.startsWith(u8, name, base)) continue;
        const is_dir = ent.is_dir;
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

test "menuMove: arrows wrap, pages stop at the ends" {
    try testing.expectEqual(@as(usize, 1), menuMove(20, 0, .next, 8));
    try testing.expectEqual(@as(usize, 0), menuMove(20, 19, .next, 8));
    try testing.expectEqual(@as(usize, 19), menuMove(20, 0, .previous, 8));
    try testing.expectEqual(@as(usize, 8), menuMove(20, 0, .page_down, 8));
    try testing.expectEqual(@as(usize, 19), menuMove(20, 15, .page_down, 8));
    try testing.expectEqual(@as(usize, 0), menuMove(20, 5, .page_up, 8));
    try testing.expectEqual(@as(usize, 19), menuMove(20, 3, .last, 8));
    try testing.expectEqual(@as(usize, 0), menuMove(20, 3, .first, 8));
    try testing.expectEqual(@as(usize, 0), menuMove(0, 3, .next, 8));
    // A stale selection past the end is clamped before it moves.
    try testing.expectEqual(@as(usize, 19), menuMove(20, 99, .page_down, 8));
}

test "menuWindow: the selection is always drawn, the last entry included" {
    try testing.expectEqual(MenuWindow{ .top = 0, .end = 8 }, menuWindow(300, 0, 8));
    try testing.expectEqual(MenuWindow{ .top = 0, .end = 8 }, menuWindow(300, 7, 8));
    try testing.expectEqual(MenuWindow{ .top = 1, .end = 9 }, menuWindow(300, 8, 8));
    try testing.expectEqual(MenuWindow{ .top = 292, .end = 300 }, menuWindow(300, 299, 8));
    try testing.expectEqual(MenuWindow{ .top = 0, .end = 3 }, menuWindow(3, 2, 8));
    try testing.expectEqual(MenuWindow{ .top = 0, .end = 0 }, menuWindow(0, 0, 8));
}

test "slash completion: /he -> /help" {
    var r = try compute(testing.allocator, .builtin, "/he", 3);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.candidates.len);
    try testing.expectEqualStrings("/help", r.candidates[0]);
    try testing.expectEqual(@as(usize, 0), r.replace_start);
}

test "slash completion: /co -> commit/compact/config/cost" {
    var r = try compute(testing.allocator, .builtin, "/co", 3);
    defer r.deinit(testing.allocator);
    try testing.expect(r.candidates.len >= 3);
    const pfx = commonPrefix(r.candidates);
    try testing.expectEqualStrings("/co", pfx);
}

test "slash completion: no match" {
    var r = try compute(testing.allocator, .builtin, "/zzz", 4);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.candidates.len);
}

test "commonPrefix" {
    const c = [_][]const u8{ "/commit", "/compact", "/config" };
    try testing.expectEqualStrings("/co", commonPrefix(&c));
}

test "path completion finds known file" {
    // 每进程唯一目录里造一个唯一前缀文件
    var dir_buf: [512]u8 = undefined;
    const dir = tt.dir(&dir_buf);
    var path_buf: [512]u8 = undefined;
    const path = tt.path(&path_buf, "complete-uniq-xyz.txt");
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = pfs.close(fd);
    defer pfs.unlinkPath(path.ptr) catch {};

    var line_buf: [600]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "cat {s}/complete-uniq-", .{dir});
    var r = try compute(testing.allocator, .builtin, line, line.len);
    defer r.deinit(testing.allocator);
    try testing.expect(r.candidates.len >= 1);
    var found = false;
    for (r.candidates) |c| {
        if (std.mem.eql(u8, c, "complete-uniq-xyz.txt")) found = true;
    }
    try testing.expect(found);
}

test "@-mention completion finds file" {
    var dir_buf: [512]u8 = undefined;
    const dir = tt.dir(&dir_buf);
    var path_buf: [512]u8 = undefined;
    const path = tt.path(&path_buf, "atmention-uniq.txt");
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = pfs.close(fd);
    defer pfs.unlinkPath(path.ptr) catch {};

    // 输入 "review @<dir>/atmention-" → 补全应找到文件,replace_start 在 @ 之后
    var line_buf: [600]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "review @{s}/atmention-", .{dir});
    var r = try compute(testing.allocator, .builtin, line, line.len);
    defer r.deinit(testing.allocator);
    try testing.expect(r.candidates.len >= 1);
    var found = false;
    for (r.candidates) |c| {
        if (std.mem.eql(u8, c, "atmention-uniq.txt")) found = true;
    }
    try testing.expect(found);
    // replace_start 指向 @ 后的 / (保留 @ 前缀不被覆盖)
    try testing.expect(line[r.replace_start - 1] == '/' or r.replace_start > 7);
}

test "slash catalog: skills join the built-ins, collisions and model-only skills stay out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const definition = @import("../skills/runtime/definition.zig");
    const base = definition.Skill{
        .name = "deploy",
        .description = "Deploy\n  the service",
        .description_source = .frontmatter,
        .warnings = .{},
        .when_to_use = "",
        .argument_hint = "[env]",
        .body = "",
        .allowed_tools = &.{},
        .disallowed_tools = &.{},
        .arguments = &.{},
        .disable_model_invocation = false,
        .user_invocable = true,
        .context = .inline_ctx,
        .agent = "",
        .model = "",
        .shell = "bash",
        .source_path = "",
    };
    var hidden = base;
    hidden.name = "model-only";
    hidden.user_invocable = false;
    var shadow = base;
    shadow.name = "help";
    var plain = base;
    plain.name = "地址库";
    plain.argument_hint = "";
    const catalog = try buildSlashCatalog(arena.allocator(), &.{ base, hidden, shadow, plain });
    try testing.expectEqual(SLASH_COMMAND_TABLE.len + 2, catalog.entries.len);

    // Prefix matches rank before substring matches.
    const first = slashNthMatch(catalog, "/dep", 0).?;
    try testing.expectEqualStrings("/deploy", first.name);
    try testing.expectEqual(SlashKind.skill, first.kind);
    try testing.expect(first.takes_args);
    try testing.expectEqualStrings("Deploy the service", first.desc);
    try testing.expectEqual(@as(usize, 1), slashFilterCount(catalog, "/ploy"));
    try testing.expect(slashMenuOpen(catalog, "/地址"));
    try testing.expect(!slashNthMatch(catalog, "/地址库", 0).?.takes_args);
    // A space closes the menu (arguments are being typed).
    try testing.expect(!slashMenuOpen(catalog, "/deploy prod"));
}

test "closestCommand: suggests the nearest command within two edits" {
    const catalog = SlashCatalog.builtin;
    try std.testing.expectEqualStrings("/loop", closestCommand(catalog, "/foo").?);
    try std.testing.expectEqualStrings("/help", closestCommand(catalog, "/hlep").?);
    try std.testing.expectEqualStrings("/compact", closestCommand(catalog, "/COMAPCT").?);
    try std.testing.expectEqualStrings("/login", closestCommand(catalog, "/logni").?);
    try std.testing.expect(closestCommand(catalog, "/zzzzzz") == null);
    try std.testing.expect(closestCommand(catalog, "/x") == null); // one letter matches nothing
    try std.testing.expect(closestCommand(catalog, "/help") == null); // already a command
}
