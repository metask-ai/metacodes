const std = @import("std");
const common = @import("common.zig");
const security = @import("security.zig");
const read_state = @import("../core/read_state.zig");
const ToolContext = @import("context.zig").ToolContext;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const path = common.extractJsonArg(args, "path") orelse return error.MissingPath;
    const content = common.extractJsonArg(args, "content") orelse return error.MissingContent;
    if (path.len == 0) return error.EmptyPath;
    try security.validateNoTraversal(path);

    // must-read-first 校验：若挂了 ReadState（正式 agent 路径），文件存在但没读过 → 拒绝
    // 两个例外：1) 文件不存在（即将创建）；2) ReadState 未挂（单测/dev 路径）
    if (ctx.read_state) |rs| {
        const exists = read_state.statPath(path) catch |err| switch (err) {
            error.StatFailed => null, // 文件不存在，允许创建
            else => return err,
        };
        if (exists) |st| {
            const rec = rs.get(path) orelse return error.NotRead;
            if (rec.mtime_ns != st.mtime_ns) return error.StaleFile;
        }
    }

    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666) catch return error.WriteError;
    defer _ = std.c.close(fd);

    var pos: usize = 0;
    while (pos < content.len) {
        const remaining = content.len - pos;
        const n = std.c.write(fd, content.ptr + pos, remaining);
        if (n <= 0) return error.WriteError;
        pos += @as(usize, @intCast(n));
    }

    // 写完后刷新 ReadState 的 mtime，让紧接着的下一轮 Edit 仍然合法（不误报 stale）
    if (ctx.read_state) |rs| {
        const st = read_state.statFd(fd) catch null;
        if (st) |s| rs.record(path, s.mtime_ns, s.size) catch {};
    }

    return try std.fmt.allocPrint(allocator, "{{\"success\": true, \"path\": \"{s}\"}}", .{path});
}

fn testCtx() ToolContext {
    return ToolContext.simple(std.testing.allocator);
}

test "WriteTool missing path" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingPath, execute(&ctx, "{\"content\":\"test\"}"));
}

test "WriteTool missing content" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingContent, execute(&ctx, "{\"path\":\"/tmp/x\"}"));
}

test "WriteTool path traversal blocked" {
    const ctx = testCtx();
    try std.testing.expectError(error.PathTraversal, execute(&ctx, "{\"path\":\"../etc/x\",\"content\":\"y\"}"));
}

test "WriteTool create file" {
    const ctx = testCtx();
    const args = "{\"path\":\"/tmp/cc-zig-write-test.txt\",\"content\":\"hello\"}";
    const result = try execute(&ctx, args);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\": true") != null);
    _ = std.c.unlink("/tmp/cc-zig-write-test.txt");
}

test "WriteTool does not auto-mkdir parent directory" {
    const ctx = testCtx();
    // 父目录 /tmp/cc-zig-nonexistent-parent-XXXX/ 不存在 → 应返 WriteError
    const args = "{\"path\":\"/tmp/cc-zig-nonexistent-parent-9a8b/foo.txt\",\"content\":\"x\"}";
    try std.testing.expectError(error.WriteError, execute(&ctx, args));
}

test "WriteTool not-read-first rejects existing file" {
    const a = std.testing.allocator;
    const path = "/tmp/cc-zig-write-mrf-test.txt";
    defer _ = std.c.unlink(path);
    // 先存在一个文件（外部创建）
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = std.c.write(fd, "old", 3);
    _ = std.c.close(fd);

    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();

    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    try std.testing.expectError(error.NotRead, execute(&ctx, "{\"path\":\"/tmp/cc-zig-write-mrf-test.txt\",\"content\":\"new\"}"));
}

test "WriteTool creating new file does not require read" {
    const a = std.testing.allocator;
    const path = "/tmp/cc-zig-write-new-test.txt";
    _ = std.c.unlink(path); // 确保不存在
    defer _ = std.c.unlink(path);

    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();

    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    const result = try execute(&ctx, "{\"path\":\"/tmp/cc-zig-write-new-test.txt\",\"content\":\"hello\"}");
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\": true") != null);
}

test "WriteTool stale file rejected" {
    const a = std.testing.allocator;
    const path = "/tmp/cc-zig-write-stale-test.txt";
    defer _ = std.c.unlink(path);

    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = std.c.write(fd, "v1", 2);
    _ = std.c.close(fd);

    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();
    // 手工记录一个假 mtime，模拟"读完后外部改了"
    try rs.record(path, 1, 2);

    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    try std.testing.expectError(error.StaleFile, execute(&ctx, "{\"path\":\"/tmp/cc-zig-write-stale-test.txt\",\"content\":\"v2\"}"));
}
