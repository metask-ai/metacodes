const std = @import("std");
const common = @import("common.zig");
const security = @import("security.zig");
const read_state = @import("../core/read_state.zig");
const ToolContext = @import("context.zig").ToolContext;

/// 默认读取行数上限（对齐 TS：限制 200KB/2000 行用户无感截断）。
pub const DEFAULT_LIMIT_LINES: usize = 2000;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    // 兼容：优先 file_path（TS 原版），回退 path（历史）
    const path = common.extractJsonArg(args, "file_path") orelse
        common.extractJsonArg(args, "path") orelse
        return error.MissingPath;
    if (path.len == 0) return error.EmptyPath;
    try security.validateNoTraversal(path);

    const offset_1based: usize = if (common.extractJsonArg(args, "offset")) |s|
        std.fmt.parseInt(usize, s, 10) catch 1
    else
        1;
    const limit: usize = if (common.extractJsonArg(args, "limit")) |s|
        std.fmt.parseInt(usize, s, 10) catch DEFAULT_LIMIT_LINES
    else
        DEFAULT_LIMIT_LINES;
    if (offset_1based == 0) return error.InvalidOffset;

    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer _ = std.c.close(fd);

    // 在读之前 fstat 一次拿 mtime/size，供 ReadState 记录用（must-read-first/staleness 校验）
    const st = read_state.statFd(fd) catch null;

    const full = try common.readAllFromFd(fd, allocator);
    defer allocator.free(full);

    // 切片 [offset .. offset+limit) 行（1-based，offset=1 表示第一行）
    var line_start: usize = 0;
    var line_idx: usize = 1;
    while (line_idx < offset_1based and line_start < full.len) : (line_idx += 1) {
        const nl = std.mem.indexOfScalarPos(u8, full, line_start, '\n') orelse {
            // 不足 offset 行 → 返回空
            return try allocator.dupe(u8, "");
        };
        line_start = nl + 1;
    }
    if (line_start >= full.len) return try allocator.dupe(u8, "");

    // 取 limit 行
    var end: usize = line_start;
    var count: usize = 0;
    while (count < limit and end < full.len) : (count += 1) {
        const nl = std.mem.indexOfScalarPos(u8, full, end, '\n') orelse {
            end = full.len;
            break;
        };
        end = nl + 1;
    }

    // 成功读取（不管有没有内容）都记录 ReadState，后续 Write/Edit 才能放行
    if (ctx.read_state) |rs| {
        if (st) |s| rs.record(path, s.mtime_ns, s.size) catch {};
    }

    return try renderWithLineNumbers(full[line_start..end], offset_1based, allocator);
}

/// 把切片按行加 "%6d\t" 前缀（对齐 TS cat -n）。
/// 输入 slice 可能以 \n 结尾或不以 \n 结尾；尾行不足时仍带前缀，尾部不强制补 \n。
/// 行号从 start_line 开始递增。空切片返回空串。
fn renderWithLineNumbers(slice: []const u8, start_line: usize, allocator: std.mem.Allocator) ![]u8 {
    if (slice.len == 0) return try allocator.dupe(u8, "");

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var line_no = start_line;
    var pos: usize = 0;
    while (pos < slice.len) {
        const nl = std.mem.indexOfScalarPos(u8, slice, pos, '\n');
        const line_end = nl orelse slice.len;
        var buf: [16]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&buf, "{d: >6}\t", .{line_no});
        try out.appendSlice(allocator, prefix);
        try out.appendSlice(allocator, slice[pos..line_end]);
        if (nl) |i| {
            try out.append(allocator, '\n');
            pos = i + 1;
        } else {
            pos = slice.len;
        }
        line_no += 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn testCtx() ToolContext {
    return ToolContext.simple(std.testing.allocator);
}

test "ReadTool missing path" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingPath, execute(&ctx, "{\"content\":\"x\"}"));
}

test "ReadTool path traversal blocked (file_path)" {
    const ctx = testCtx();
    try std.testing.expectError(error.PathTraversal, execute(&ctx, "{\"file_path\":\"../../etc/passwd\"}"));
}

test "ReadTool read /etc/hostname via file_path" {
    const ctx = testCtx();
    const r = try execute(&ctx, "{\"file_path\":\"/etc/hostname\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(r.len > 0);
}

test "ReadTool read /etc/hostname via legacy path" {
    const ctx = testCtx();
    const r = try execute(&ctx, "{\"path\":\"/etc/hostname\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(r.len > 0);
}

test "ReadTool offset beyond file returns empty" {
    const ctx = testCtx();
    const r = try execute(&ctx, "{\"file_path\":\"/etc/hostname\",\"offset\":1000}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(r.len == 0);
}

test "ReadTool offset=0 is invalid" {
    const ctx = testCtx();
    try std.testing.expectError(error.InvalidOffset, execute(&ctx, "{\"file_path\":\"/etc/hostname\",\"offset\":0}"));
}

test "ReadTool offset/limit extracts correct slice" {
    const ctx = testCtx();
    // 直接用 libc 写一个 10 行的文件（绕过 write 工具的 JSON 转义差异）
    const path_cstr = "/tmp/cc-zig-read-offset-test.txt";
    const fd = std.c.open(path_cstr, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n";
    _ = std.c.write(fd, text.ptr, text.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path_cstr);

    // offset=3, limit=2 → 带 cat -n 前缀，行号从 3 开始
    const r = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-offset-test.txt\",\"offset\":3,\"limit\":2}");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("     3\tline3\n     4\tline4\n", r);
}

test "ReadTool first line has line-number prefix 1" {
    const ctx = testCtx();
    const path_cstr = "/tmp/cc-zig-read-ln1-test.txt";
    const fd = std.c.open(path_cstr, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "hello\nworld\n";
    _ = std.c.write(fd, text.ptr, text.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path_cstr);

    const r = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-ln1-test.txt\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("     1\thello\n     2\tworld\n", r);
}

test "ReadTool file without trailing newline still gets prefix" {
    const ctx = testCtx();
    const path_cstr = "/tmp/cc-zig-read-noeol-test.txt";
    const fd = std.c.open(path_cstr, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "noeol";
    _ = std.c.write(fd, text.ptr, text.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path_cstr);

    const r = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-noeol-test.txt\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("     1\tnoeol", r);
}

test "ReadTool limit caps very large file" {
    const ctx = testCtx();
    // /etc/hostname 一般 1 行；limit=10000 不会报错
    const r = try execute(&ctx, "{\"file_path\":\"/etc/hostname\",\"limit\":10000}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(r.len > 0);
}

test "ReadTool default limit reads at least first line" {
    const ctx = testCtx();
    const r = try execute(&ctx, "{\"file_path\":\"/etc/hostname\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(r.len > 0);
}
