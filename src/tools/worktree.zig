//! Worktree 工具:在隔离 git worktree 中工作。
//!
//! 两个工具:
//!   EnterWorktree(name?, path?, base?)
//!     - 若提供 path:切换到该已存在的 worktree(必须在 `git worktree list` 中)
//!     - 否则:在 .metacodes/worktrees/<name|random>/ 创建新 worktree,基于 base 分支
//!       (base 缺省 = 当前 default branch,简化为 HEAD)
//!     - 进入 = chdir + 在 ToolContext 上把 worktree 状态推到一个栈
//!     - 返回 JSON: {"worktree":"...","branch":"...","entered":true}
//!
//!   ExitWorktree(action, discard_changes?)
//!     - action="keep": 仅 chdir 回 original_cwd,worktree 留盘
//!     - action="remove":git worktree remove + chdir 回原
//!     - discard_changes=true → 即使有未提交也强制 remove(否则 git 拒绝)
//!     - 返回 JSON: {"left":"...","removed":bool,"original_cwd":"..."}
//!
//! 状态:App.worktree_stack:[]struct{worktree, original_cwd}
//!       Enter 时 push,Exit 时 pop。

const std = @import("std");
const pfs = @import("platform").fs;
const common = @import("common.zig");
const path_mod = @import("../util/path.zig");
const ToolContext = @import("context.zig").ToolContext;
const util_json = @import("../util/json.zig");

pub const WorktreeEntry = struct {
    worktree_path: []u8,
    original_cwd: []u8,
};

/// 全局 worktree 栈 — 由 ToolContext 暴露的 *anyopaque 指针指向 App 上的 ArrayList。
/// 简单起见:跨工具调用通过 App 的 setter 函数管理。
pub fn enterExecute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const a = ctx.allocator;
    const path_opt = common.extractJsonArg(args, "path");
    const name_opt = common.extractJsonArg(args, "name");

    if (path_opt) |path_raw| {
        // 切到已有 worktree。只归一化 path(name/base 是 worktree 名/git ref,不是文件系统路径)。
        if (path_raw.len == 0) return error.EmptyPath;
        // 归一化(展开 ~、折叠、查 traversal)。chdir/open 不认 ~。
        const path = try path_mod.normalizeChecked(a, path_raw, .{ .home = ctx.home_dir, .base_dir = ctx.cwd_abs });
        defer a.free(path);
        if (!worktreeExists(a, path)) return error.WorktreePathNotFound;
        const old_cwd = try getCwd(a);
        try chdir(path);
        try pushWorktree(ctx, path, old_cwd);
        a.free(old_cwd);
        var reply: std.Io.Writer.Allocating = .init(a);
        defer reply.deinit();
        try reply.writer.writeAll("{\"worktree\":");
        try util_json.writeJsonString(&reply.writer, path);
        try reply.writer.writeAll(",\"entered\":true,\"created\":false}");
        return reply.toOwnedSlice();
    }

    // 创建新 worktree
    const name = name_opt orelse blk: {
        // 默认 cczig-tmp-<6 hex>
        var buf: [16]u8 = undefined;
        const ns = @import("../util/time.zig").nowNs();
        const id = try std.fmt.bufPrint(&buf, "cczig-{x}", .{@as(u32, @truncate(@as(u128, @intCast(ns))))});
        break :blk try a.dupe(u8, id);
    };
    defer if (name_opt == null) a.free(name);

    const base = common.extractJsonArg(args, "base") orelse "HEAD";

    // 路径:<cwd>/.metacodes/worktrees/<name>
    const cwd = try getCwd(a);
    defer a.free(cwd);
    const wt_dir = try std.fmt.allocPrint(a, "{s}/.metacodes/worktrees", .{cwd});
    defer a.free(wt_dir);
    try mkdirP(wt_dir);
    const wt_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ wt_dir, name });
    defer a.free(wt_path);

    // git worktree add <wt_path> [-b <name>] <base>
    const wt_z = try a.dupeZ(u8, wt_path);
    defer a.free(wt_z);
    const name_z = try a.dupeZ(u8, name);
    defer a.free(name_z);
    const base_z = try a.dupeZ(u8, base);
    defer a.free(base_z);
    const argv_args = [_]?[*:0]const u8{
        "/usr/bin/env",
        "git",
        "worktree",
        "add",
        "-b",
        name_z.ptr,
        wt_z.ptr,
        base_z.ptr,
        null,
    };
    const out = common.spawnCaptureWithStderrTimed(argv_args[0..], a, ctx.abort, 30_000, ctx.spawn_tick_fn, common.MAX_SPAWN_CAPTURE_BYTES, null) catch |err| {
        var reply: std.Io.Writer.Allocating = .init(a);
        defer reply.deinit();
        try reply.writer.writeAll("{\"error\":\"git_failed\",\"message\":");
        try util_json.writeJsonString(&reply.writer, @errorName(err));
        try reply.writer.writeByte('}');
        return reply.toOwnedSlice();
    };
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    if (out.exit_code != 0) {
        var reply: std.Io.Writer.Allocating = .init(a);
        defer reply.deinit();
        try reply.writer.print("{{\"error\":\"git_worktree_add_failed\",\"exit_code\":{d},\"stderr\":", .{out.exit_code});
        try util_json.writeJsonString(&reply.writer, out.stderr);
        try reply.writer.writeByte('}');
        return reply.toOwnedSlice();
    }

    try chdir(wt_path);
    try pushWorktree(ctx, wt_path, cwd);

    var reply: std.Io.Writer.Allocating = .init(a);
    defer reply.deinit();
    try reply.writer.writeAll("{\"worktree\":");
    try util_json.writeJsonString(&reply.writer, wt_path);
    try reply.writer.writeAll(",\"branch\":");
    try util_json.writeJsonString(&reply.writer, name);
    try reply.writer.writeAll(",\"entered\":true,\"created\":true}");
    return reply.toOwnedSlice();
}

pub fn exitExecute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const a = ctx.allocator;
    const action = common.extractJsonArg(args, "action") orelse return error.MissingAction;
    if (!std.mem.eql(u8, action, "keep") and !std.mem.eql(u8, action, "remove")) {
        return error.InvalidAction;
    }
    const discard = blk: {
        const v = common.extractJsonArg(args, "discard_changes") orelse break :blk false;
        break :blk std.mem.eql(u8, v, "true");
    };

    const entry = try popWorktree(ctx) orelse return error.NotInWorktree;
    defer {
        a.free(entry.worktree_path);
        a.free(entry.original_cwd);
    }

    // 先切回去
    try chdir(entry.original_cwd);

    var removed = false;
    if (std.mem.eql(u8, action, "remove")) {
        const wt_z = try a.dupeZ(u8, entry.worktree_path);
        defer a.free(wt_z);
        var argv_list = std.ArrayList(?[*:0]const u8).empty;
        defer argv_list.deinit(a);
        try argv_list.append(a, "/usr/bin/env");
        try argv_list.append(a, "git");
        try argv_list.append(a, "worktree");
        try argv_list.append(a, "remove");
        if (discard) try argv_list.append(a, "--force");
        try argv_list.append(a, wt_z.ptr);
        try argv_list.append(a, null);

        const out = common.spawnCaptureWithStderrTimed(argv_list.items, a, ctx.abort, 30_000, ctx.spawn_tick_fn, common.MAX_SPAWN_CAPTURE_BYTES, null) catch null;
        if (out) |o| {
            defer a.free(o.stdout);
            defer a.free(o.stderr);
            if (o.exit_code == 0) removed = true;
        }
    }

    var reply: std.Io.Writer.Allocating = .init(a);
    defer reply.deinit();
    try reply.writer.writeAll("{\"left\":");
    try util_json.writeJsonString(&reply.writer, entry.worktree_path);
    try reply.writer.print(",\"removed\":{},\"original_cwd\":", .{removed});
    try util_json.writeJsonString(&reply.writer, entry.original_cwd);
    try reply.writer.writeByte('}');
    return reply.toOwnedSlice();
}

// ============================================================================
// Worktree 栈管理 — 通过 ToolContext 上的 callback 回到 App
// ============================================================================

fn pushWorktree(ctx: *const ToolContext, wt_path: []const u8, cwd: []const u8) !void {
    const hs = ctx.host_services orelse return error.WorktreeStateUnavailable;
    // 单一失败点:能力缺失映射成 WorktreeStateUnavailable;真实 push 错误(如 OOM)照常上抛。
    hs.worktreePush(ctx.allocator, wt_path, cwd) catch |e| switch (e) {
        error.HostCapabilityUnavailable => return error.WorktreeStateUnavailable,
        else => return e,
    };
}

fn popWorktree(ctx: *const ToolContext) !?WorktreeEntry {
    const hs = ctx.host_services orelse return error.WorktreeStateUnavailable;
    return hs.worktreePop(ctx.allocator) catch |e| switch (e) {
        error.HostCapabilityUnavailable => return error.WorktreeStateUnavailable,
        else => return e,
    };
}

// ============================================================================
// 工具调用
// ============================================================================

fn chdir(path: []const u8) !void {
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    if (pfs.chdir(path_z) != 0) return error.ChdirFailed; // 宽字符(#121):CJK worktree 路径
}

fn getCwd(allocator: std.mem.Allocator) ![]u8 {
    return @import("../util/fs.zig").getCwd(allocator);
}

fn mkdirP(path: []const u8) !void {
    // 唯一的 mkdir -p 走查器在 util/fs.zig(Windows 两种分隔符 + 盘符前缀都在那里处理)。
    return @import("../util/fs.zig").mkdirBestEffort(path, 0o755);
}

fn worktreeExists(allocator: std.mem.Allocator, path: []const u8) bool {
    // 简单 stat:目录存在即认为是 worktree(更严格的方法是 git worktree list 然后匹配)
    const path_z = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(path_z);
    const fd = pfs.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return false;
    _ = pfs.close(fd);
    return true;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "EnterWorktree: empty path errors" {
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(error.EmptyPath, enterExecute(&ctx, "{\"path\":\"\"}"));
}

test "EnterWorktree: nonexistent path errors" {
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(error.WorktreePathNotFound, enterExecute(&ctx, "{\"path\":\"/tmp/nonexistent-wt-99999\"}"));
}

test "ExitWorktree: missing action errors" {
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(error.MissingAction, exitExecute(&ctx, "{}"));
}

test "ExitWorktree: invalid action errors" {
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(error.InvalidAction, exitExecute(&ctx, "{\"action\":\"bogus\"}"));
}

test "ExitWorktree: not in worktree errors" {
    var state: std.ArrayList(WorktreeEntry) = .empty;
    defer state.deinit(testing.allocator);
    var ctx = ToolContext.simple(testing.allocator);
    const Hook = struct {
        fn push(s: *anyopaque, a: std.mem.Allocator, wt: []const u8, cwd: []const u8) anyerror!void {
            _ = s;
            _ = a;
            _ = wt;
            _ = cwd;
        }
        fn pop(s: *anyopaque, a: std.mem.Allocator) anyerror!?WorktreeEntry {
            const stack: *std.ArrayList(WorktreeEntry) = @ptrCast(@alignCast(s));
            _ = a;
            if (stack.items.len == 0) return null;
            return stack.pop();
        }
    };
    ctx.host_services = .{ .ctx = @ptrCast(&state), .worktreePushFn = &Hook.push, .worktreePopFn = &Hook.pop };
    try testing.expectError(error.NotInWorktree, exitExecute(&ctx, "{\"action\":\"keep\"}"));
}
