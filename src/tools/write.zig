const std = @import("std");
const common = @import("common.zig");
const security = @import("security.zig");
const ToolContext = @import("context.zig").ToolContext;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const path = common.extractJsonArg(args, "path") orelse return error.MissingPath;
    const content = common.extractJsonArg(args, "content") orelse return error.MissingContent;
    if (path.len == 0) return error.EmptyPath;
    try security.validateNoTraversal(path);

    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666) catch return error.WriteError;
    defer _ = std.c.close(fd);

    var pos: usize = 0;
    while (pos < content.len) {
        const remaining = content.len - pos;
        const n = std.c.write(fd, content.ptr + pos, remaining);
        if (n <= 0) return error.WriteError;
        pos += @as(usize, @intCast(n));
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
