const std = @import("std");
const common = @import("common.zig");
const security = @import("security.zig");
const ToolContext = @import("context.zig").ToolContext;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const file_path = common.extractJsonArg(args, "file_path") orelse return error.MissingFilePath;
    const old_string = common.extractJsonArg(args, "old_string") orelse return error.MissingOldString;
    const new_string = common.extractJsonArg(args, "new_string") orelse return error.MissingNewString;

    if (file_path.len == 0) return error.EmptyFilePath;
    if (old_string.len == 0) return error.EmptyOldString;
    try security.validateNoTraversal(file_path);

    const fd = std.posix.openat(std.posix.AT.FDCWD, file_path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    const original = blk: {
        defer _ = std.c.close(fd);
        break :blk try common.readAllFromFd(fd, allocator);
    };
    defer allocator.free(original);

    if (std.mem.indexOf(u8, original, old_string) == null) return error.StringNotFound;

    const replace_all_str = common.extractJsonArg(args, "replace_all");
    const replace_all = replace_all_str != null and std.mem.eql(u8, replace_all_str.?, "true");

    // 若 replace_all=false 但多次匹配，返回 MultipleMatches
    if (!replace_all) {
        const first = std.mem.indexOf(u8, original, old_string).?;
        if (std.mem.indexOfPos(u8, original, first + old_string.len, old_string) != null) {
            return error.MultipleMatches;
        }
    }

    var new_content = std.ArrayList(u8).empty;
    defer new_content.deinit(allocator);

    if (replace_all) {
        var cursor: usize = 0;
        while (std.mem.indexOf(u8, original[cursor..], old_string)) |rel| {
            const abs = cursor + rel;
            try new_content.appendSlice(allocator, original[cursor..abs]);
            try new_content.appendSlice(allocator, new_string);
            cursor = abs + old_string.len;
        }
        try new_content.appendSlice(allocator, original[cursor..]);
    } else {
        const i = std.mem.indexOf(u8, original, old_string).?;
        try new_content.appendSlice(allocator, original[0..i]);
        try new_content.appendSlice(allocator, new_string);
        try new_content.appendSlice(allocator, original[i + old_string.len ..]);
    }

    const write_fd = std.posix.openat(std.posix.AT.FDCWD, file_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch return error.WriteError;
    defer _ = std.c.close(write_fd);

    const written = std.c.write(write_fd, new_content.items.ptr, new_content.items.len);
    if (written < 0) return error.WriteError;

    return try std.fmt.allocPrint(allocator,
        \\{{"file_path":"{s}","old_string":"{s}","new_string":"{s}","success":true}}
    , .{ file_path, old_string, new_string });
}

fn testCtx() ToolContext {
    return ToolContext.simple(std.testing.allocator);
}

test "EditTool missing file_path" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingFilePath, execute(&ctx, "{\"old_string\":\"a\",\"new_string\":\"b\"}"));
}

test "EditTool missing old_string" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingOldString, execute(&ctx, "{\"file_path\":\"/tmp/x\",\"new_string\":\"b\"}"));
}

test "EditTool path traversal blocked" {
    const ctx = testCtx();
    try std.testing.expectError(error.PathTraversal, execute(&ctx, "{\"file_path\":\"../etc/x\",\"old_string\":\"a\",\"new_string\":\"b\"}"));
}

test "EditTool basic replace" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-edit-test.txt";
    defer _ = std.c.unlink(path);

    const write = @import("write.zig");
    std.testing.allocator.free(try write.execute(&ctx, "{\"path\":\"/tmp/cc-zig-edit-test.txt\",\"content\":\"Hello World\"}"));

    const result = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-edit-test.txt\",\"old_string\":\"World\",\"new_string\":\"Zig\"}");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
}

test "EditTool replace_all" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-edit-all-test.txt";
    defer _ = std.c.unlink(path);

    const write = @import("write.zig");
    std.testing.allocator.free(try write.execute(&ctx, "{\"path\":\"/tmp/cc-zig-edit-all-test.txt\",\"content\":\"foo foo foo\"}"));

    const result = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-edit-all-test.txt\",\"old_string\":\"foo\",\"new_string\":\"bar\",\"replace_all\":true}");
    defer std.testing.allocator.free(result);

    const read = @import("read.zig");
    const content = try read.execute(&ctx, "{\"path\":\"/tmp/cc-zig-edit-all-test.txt\"}");
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "foo") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "bar bar bar") != null);
}

test "EditTool string not found" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-edit-nf-test.txt";
    defer _ = std.c.unlink(path);

    const write = @import("write.zig");
    std.testing.allocator.free(try write.execute(&ctx, "{\"path\":\"/tmp/cc-zig-edit-nf-test.txt\",\"content\":\"hello\"}"));

    try std.testing.expectError(error.StringNotFound, execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-edit-nf-test.txt\",\"old_string\":\"missing\",\"new_string\":\"x\"}"));
}

test "EditTool MultipleMatches without replace_all" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-edit-multi-test.txt";
    defer _ = std.c.unlink(path);

    const write = @import("write.zig");
    std.testing.allocator.free(try write.execute(&ctx, "{\"path\":\"/tmp/cc-zig-edit-multi-test.txt\",\"content\":\"foo foo foo\"}"));

    // 未设 replace_all，foo 多次命中 → MultipleMatches
    try std.testing.expectError(error.MultipleMatches, execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-edit-multi-test.txt\",\"old_string\":\"foo\",\"new_string\":\"bar\"}"));
}

test "EditTool MultipleMatches bypass with replace_all" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-edit-multi-ok-test.txt";
    defer _ = std.c.unlink(path);

    const write = @import("write.zig");
    std.testing.allocator.free(try write.execute(&ctx, "{\"path\":\"/tmp/cc-zig-edit-multi-ok-test.txt\",\"content\":\"foo foo foo\"}"));

    // replace_all=true 时多匹配是合法的
    const result = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-edit-multi-ok-test.txt\",\"old_string\":\"foo\",\"new_string\":\"bar\",\"replace_all\":true}");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
}
