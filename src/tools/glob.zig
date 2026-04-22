const std = @import("std");
const common = @import("common.zig");
const security = @import("security.zig");
const toolchain = @import("../util/toolchain.zig");
const ToolContext = @import("context.zig").ToolContext;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const pattern = common.extractJsonArg(args, "pattern") orelse return error.MissingPattern;
    const path = common.extractJsonArg(args, "path") orelse ".";
    if (pattern.len == 0) return error.EmptyPattern;
    try security.validateNoTraversal(path);

    const rg_path = try toolchain.ripgrepPath();

    const pattern_z = try allocator.dupeZ(u8, pattern);
    defer allocator.free(pattern_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var argv = [_]?[*:0]const u8{
        rg_path.ptr,
        "--files",
        "--no-messages",
        "--glob",
        pattern_z.ptr,
        path_z.ptr,
        null,
    };
    const raw = try common.spawnCaptureStdoutAbortable(argv[0..argv.len], allocator, ctx.abort);
    defer allocator.free(raw);

    var files = std.ArrayList([]const u8).empty;
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, raw, cursor, '\n')) |nl| {
        if (nl > cursor) {
            const line = raw[cursor..nl];
            try files.append(allocator, try allocator.dupe(u8, line));
        }
        cursor = nl + 1;
    }

    const num = files.items.len;
    const truncated = num > 100;
    const display: usize = if (truncated) 100 else num;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"filenames\":[");
    for (files.items[0..display], 0..) |f, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.append(allocator, '"');
        for (f) |c| {
            switch (c) {
                '"' => try out.appendSlice(allocator, "\\\""),
                '\\' => try out.appendSlice(allocator, "\\\\"),
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                else => try out.append(allocator, c),
            }
        }
        try out.append(allocator, '"');
    }
    try out.appendSlice(allocator, "],\"numFiles\":");
    var num_buf: [32]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{num}) catch return error.OutOfMemory;
    try out.appendSlice(allocator, num_str);
    try out.appendSlice(allocator, ",\"truncated\":");
    try out.appendSlice(allocator, if (truncated) "true" else "false");
    try out.appendSlice(allocator, ",\"durationMs\":0}");

    return try out.toOwnedSlice(allocator);
}

fn testCtx() ToolContext {
    return ToolContext.simple(std.testing.allocator);
}

test "GlobTool missing pattern" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingPattern, execute(&ctx, "{\"path\":\".\"}"));
}

test "GlobTool path traversal blocked" {
    const ctx = testCtx();
    try std.testing.expectError(error.PathTraversal, execute(&ctx, "{\"pattern\":\"*.txt\",\"path\":\"../..\"}"));
}

test "GlobTool returns valid json" {
    const ctx = testCtx();
    const result = try execute(&ctx, "{\"pattern\":\"*\",\"path\":\"/tmp\"}");
    defer std.testing.allocator.free(result);
    try std.testing.expect(result[0] == '{');
    try std.testing.expect(result[result.len - 1] == '}');
    try std.testing.expect(std.mem.indexOf(u8, result, "\"filenames\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"numFiles\":") != null);
}

test "GlobTool brace pattern (*.{ts,tsx})" {
    const ctx = testCtx();
    // 先造 2 个 .ts / .tsx，1 个 .txt
    const ts_path: [*:0]const u8 = "/tmp/cc-zig-glob-brace-a.ts";
    const tsx_path: [*:0]const u8 = "/tmp/cc-zig-glob-brace-a.tsx";
    const txt_path: [*:0]const u8 = "/tmp/cc-zig-glob-brace-a.txt";
    for ([_][*:0]const u8{ ts_path, tsx_path, txt_path }) |p| {
        const fd = std.c.open(p, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        _ = std.c.write(fd, "x\n", 2);
        _ = std.c.close(fd);
    }
    defer _ = std.c.unlink(ts_path);
    defer _ = std.c.unlink(tsx_path);
    defer _ = std.c.unlink(txt_path);

    const result = try execute(&ctx, "{\"pattern\":\"cc-zig-glob-brace-*.{ts,tsx}\",\"path\":\"/tmp\"}");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "cc-zig-glob-brace-a.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "cc-zig-glob-brace-a.tsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "cc-zig-glob-brace-a.txt") == null);
}
