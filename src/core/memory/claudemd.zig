//! 通道 A:CLAUDE.md 加载链。
//!
//! 对齐 cc/src/utils/claudemd.ts:getMemoryFiles。职责:
//!   1. 向上递归收集 cwd→root 每层的 CLAUDE.md / .claude/CLAUDE.md / CLAUDE.local.md
//!   2. 加 User 级 ~/.claude/CLAUDE.md(+ ~/.cc-zig/CLAUDE.md 向后兼容)
//!   3. 每个文件过 @import 递归内联(import.zig)
//!   4. 每块带标签 `Contents of <abs> (<desc>):`
//!   5. 顺序:User → Project(根→cwd) → Local,后加载者优先级最高(对齐 cc)
//!
//! 输出是**拼接好的纯文本**(不含 system-reminder 包裹)——包裹由 user_context.zig 做,
//! 因为同一文本既要进主 session user-context,也要进 subagent system prompt(preload)。
//!
//! AutoMem(memdir MEMORY.md)不在此加载——由 memdir.zig 单独追加(它有截断逻辑)。

const std = @import("std");
const import_mod = @import("import.zig");

/// cc claudemd.ts:89 原文,一字不差。注入在 claudeMd 段最前。
pub const MEMORY_INSTRUCTION_PROMPT =
    "Codebase and user instructions are shown below. Be sure to adhere to these instructions. IMPORTANT: These instructions OVERRIDE any default behavior and you MUST follow them exactly as written.";

/// 各层描述字面量(对齐 cc,本会话 system-reminder 实证)。
const DESC_USER = "user's private global instructions for all projects";
const DESC_PROJECT = "project instructions, checked into the codebase";
const DESC_LOCAL = "user's private project instructions, not checked into git";

pub const LoadOptions = struct {
    /// 起始目录(通常 cwd)。从此向上递归到文件系统根收集 Project/Local 链。
    cwd: []const u8 = "",
    /// HOME,用于 User 级 ~/.claude/CLAUDE.md 与 import 的 `~` 展开。
    home: []const u8 = "",
};

/// 读文件全文(posix,仿 import.zig)。返回 owned;不存在/读失败返回对应 error。
fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = std.posix.openat(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0) catch return error.NotFound;
    defer _ = std.c.close(fd);
    var buf: [65536]u8 = undefined;
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    var total: usize = 0;
    while (true) {
        const n = std.posix.read(fd, &buf) catch return error.ReadError;
        if (n == 0) break;
        total += n;
        if (total > 4 * 1024 * 1024) return error.FileTooLarge;
        try result.appendSlice(allocator, buf[0..n]);
    }
    return result.toOwnedSlice(allocator);
}

/// 把单个 CLAUDE.md 文件读出 → @import 展开 → 带标签写进 out。
/// 文件不存在/空 静默跳过。base_dir = 文件所在目录(import 基准)。
fn appendFile(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    abs_path: []const u8,
    desc: []const u8,
    home: []const u8,
) !void {
    const raw = readFileAlloc(allocator, abs_path) catch return;
    defer allocator.free(raw);
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return;

    const base_dir = std.fs.path.dirname(abs_path) orelse ".";
    const expanded = import_mod.expandImports(allocator, raw, base_dir, home) catch try allocator.dupe(u8, raw);
    defer allocator.free(expanded);

    if (out.items.len > 0) try out.appendSlice(allocator, "\n\n");
    const header = try std.fmt.allocPrint(allocator, "Contents of {s} ({s}):\n\n", .{ abs_path, desc });
    defer allocator.free(header);
    try out.appendSlice(allocator, header);
    try out.appendSlice(allocator, expanded);
}

/// 收集 cwd 向上到根的所有祖先目录,**反转成 根→cwd 顺序**返回(owned 数组,owned 字符串)。
/// 越靠近 cwd 的越靠后 = 优先级越高(对齐 cc dirs.reverse())。
fn ancestorDirs(allocator: std.mem.Allocator, cwd: []const u8) ![][]u8 {
    var list = std.ArrayList([]u8).empty;
    errdefer {
        for (list.items) |d| allocator.free(d);
        list.deinit(allocator);
    }
    var cur: []const u8 = cwd;
    while (true) {
        try list.append(allocator, try allocator.dupe(u8, cur));
        const parent = std.fs.path.dirname(cur) orelse break;
        if (std.mem.eql(u8, parent, cur)) break; // 到根
        cur = parent;
    }
    // 反转:当前 list 是 cwd→根,反成 根→cwd
    std.mem.reverse([]u8, list.items);
    return list.toOwnedSlice(allocator);
}

/// 加载完整 CLAUDE.md 链,返回拼接好的纯文本(owned)。无内容返回空串(owned)。
///
/// 顺序(后者优先级高,放后面):
///   User(~/.claude/CLAUDE.md, ~/.cc-zig/CLAUDE.md)
///   → Project(根→cwd 每层 CLAUDE.md + .claude/CLAUDE.md)
///   → Local(根→cwd 每层 CLAUDE.local.md)
pub fn load(allocator: std.mem.Allocator, opts: LoadOptions) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // 1. User 级
    if (opts.home.len > 0) {
        const user_path = try std.fmt.allocPrint(allocator, "{s}/.claude/CLAUDE.md", .{opts.home});
        defer allocator.free(user_path);
        try appendFile(allocator, &out, user_path, DESC_USER, opts.home);

        const cczig_path = try std.fmt.allocPrint(allocator, "{s}/.cc-zig/CLAUDE.md", .{opts.home});
        defer allocator.free(cczig_path);
        try appendFile(allocator, &out, cczig_path, DESC_USER, opts.home);
    }

    // 2+3. Project + Local 链(向上递归,根→cwd 顺序)
    if (opts.cwd.len > 0) {
        const dirs = try ancestorDirs(allocator, opts.cwd);
        defer {
            for (dirs) |d| allocator.free(d);
            allocator.free(dirs);
        }
        // Project:每层 <dir>/CLAUDE.md + <dir>/.claude/CLAUDE.md
        for (dirs) |dir| {
            const p1 = try std.fmt.allocPrint(allocator, "{s}/CLAUDE.md", .{dir});
            defer allocator.free(p1);
            try appendFile(allocator, &out, p1, DESC_PROJECT, opts.home);

            const p2 = try std.fmt.allocPrint(allocator, "{s}/.claude/CLAUDE.md", .{dir});
            defer allocator.free(p2);
            try appendFile(allocator, &out, p2, DESC_PROJECT, opts.home);
        }
        // Local:每层 <dir>/CLAUDE.local.md(优先级最高,放最后)
        for (dirs) |dir| {
            const pl = try std.fmt.allocPrint(allocator, "{s}/CLAUDE.local.md", .{dir});
            defer allocator.free(pl);
            try appendFile(allocator, &out, pl, DESC_LOCAL, opts.home);
        }
    }

    return out.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn tmpAbsPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const rel = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(rel);
    var path_z: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(path_z[0..rel.len], rel);
    path_z[rel.len] = 0;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const res = std.c.realpath(@ptrCast(&path_z), &buf);
    if (res == null) return allocator.dupe(u8, rel);
    return allocator.dupe(u8, std.mem.span(@as([*:0]u8, @ptrCast(res.?))));
}

fn writeFileAt(dir_abs: []const u8, name: []const u8, data: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir_abs, name });
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer _ = std.c.close(fd);
    var written: usize = 0;
    while (written < data.len) {
        const n = std.c.write(fd, data[written..].ptr, data.len - written);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

fn mkdirAt(dir_abs: []const u8, name: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir_abs, name });
    const rc = std.c.mkdir(path, 0o755);
    if (rc != 0) {
        const e = std.posix.errno(rc);
        if (e != .EXIST) return error.MkdirFailed;
    }
}

test "load: no own CLAUDE.md in leaf dir contributes nothing from leaf" {
    // 注意:向上递归会吃到真实祖先目录(项目根)的 CLAUDE.md——这是 cc 的正确行为。
    // 故这里只断言"叶子目录没写文件 → 输出里没有叶子目录路径的 Contents 标签"。
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpAbsPath(a, &tmp);
    defer a.free(dir);

    const out = try load(a, .{ .cwd = dir, .home = "" });
    defer a.free(out);
    // 叶子目录自己的 CLAUDE.md 路径不应作为标签出现(因为不存在)
    const leaf_tag = try std.fmt.allocPrint(a, "Contents of {s}/CLAUDE.md", .{dir});
    defer a.free(leaf_tag);
    try testing.expect(std.mem.indexOf(u8, out, leaf_tag) == null);
}

test "load: project CLAUDE.md with label" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpAbsPath(a, &tmp);
    defer a.free(dir);
    try writeFileAt(dir, "CLAUDE.md", "PROJECT-RULES-HERE");

    const out = try load(a, .{ .cwd = dir, .home = "" });
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "PROJECT-RULES-HERE") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Contents of ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(project instructions, checked into the codebase):") != null);
}

test "load: upward recursion root->cwd order" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpAbsPath(a, &tmp);
    defer a.free(base);
    // base/CLAUDE.md (parent) + base/sub/CLAUDE.md (child)
    try writeFileAt(base, "CLAUDE.md", "PARENT-MARK");
    try mkdirAt(base, "sub");
    const sub = try std.fmt.allocPrint(a, "{s}/sub", .{base});
    defer a.free(sub);
    try writeFileAt(sub, "CLAUDE.md", "CHILD-MARK");

    const out = try load(a, .{ .cwd = sub, .home = "" });
    defer a.free(out);
    const pi = std.mem.indexOf(u8, out, "PARENT-MARK");
    const ci = std.mem.indexOf(u8, out, "CHILD-MARK");
    try testing.expect(pi != null);
    try testing.expect(ci != null);
    // 根→cwd 顺序:parent 在前,child 在后(优先级高)
    try testing.expect(pi.? < ci.?);
}

test "load: @import expanded inside CLAUDE.md" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpAbsPath(a, &tmp);
    defer a.free(dir);
    try writeFileAt(dir, "CLAUDE.md", "main @extra.md done");
    try writeFileAt(dir, "extra.md", "EXTRA-IMPORTED");

    const out = try load(a, .{ .cwd = dir, .home = "" });
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "EXTRA-IMPORTED") != null);
}

test "load: local higher priority than project" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpAbsPath(a, &tmp);
    defer a.free(dir);
    try writeFileAt(dir, "CLAUDE.md", "PROJ");
    try writeFileAt(dir, "CLAUDE.local.md", "LOCAL");

    const out = try load(a, .{ .cwd = dir, .home = "" });
    defer a.free(out);
    const proj = std.mem.indexOf(u8, out, "PROJ").?;
    const local = std.mem.indexOf(u8, out, "LOCAL").?;
    try testing.expect(proj < local); // local 放后面 = 优先级高
    try testing.expect(std.mem.indexOf(u8, out, "not checked into git):") != null);
}
