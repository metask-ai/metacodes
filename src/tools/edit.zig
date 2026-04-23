const std = @import("std");
const common = @import("common.zig");
const security = @import("security.zig");
const util_json = @import("../util/json.zig");
const read_state = @import("../core/read_state.zig");
const ToolContext = @import("context.zig").ToolContext;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const file_path = common.extractJsonArg(args, "file_path") orelse return error.MissingFilePath;
    const old_raw = common.extractJsonArg(args, "old_string") orelse return error.MissingOldString;
    const new_raw = common.extractJsonArg(args, "new_string") orelse return error.MissingNewString;

    if (file_path.len == 0) return error.EmptyFilePath;
    if (old_raw.len == 0) return error.EmptyOldString;
    try security.validateNoTraversal(file_path);

    // must-read-first：Edit 必须先 Read 过；挂了 ReadState 才校验。
    // Edit 和 Write 不同：Edit 必然需要文件存在且内容可匹配，所以文件必须存在 → 必须被读过。
    if (ctx.read_state) |rs| {
        const st = read_state.statPath(file_path) catch return error.FileNotFound;
        const rec = rs.get(file_path) orelse return error.NotRead;
        if (rec.mtime_ns != st.mtime_ns) return error.StaleFile;
    }

    // old/new 是 JSON 字符串值的原始切片（未 unescape）。Edit 对字节精确匹配敏感，
    // 必须先反转义回真实字节（\n → LF，\t → TAB 等）。
    const old_unesc = try util_json.unescapeString(old_raw, allocator);
    defer allocator.free(old_unesc);
    const new_unesc = try util_json.unescapeString(new_raw, allocator);
    defer allocator.free(new_unesc);

    // 处理 Read 注入的 "%6d\t" 行号前缀：模型可能原样复制。strip 后作为 fallback 匹配。
    const old_stripped = try stripLineNumberPrefix(old_unesc, allocator);
    defer allocator.free(old_stripped);
    const new_stripped = try stripLineNumberPrefix(new_unesc, allocator);
    defer allocator.free(new_stripped);

    const fd = std.posix.openat(std.posix.AT.FDCWD, file_path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    const original = blk: {
        defer _ = std.c.close(fd);
        break :blk try common.readAllFromFd(fd, allocator);
    };
    defer allocator.free(original);

    // 先尝试原样（unescaped）匹配；没匹配到再用 stripped 版本。
    // 这样：1) 真实文件里本来就有类似 "    5\t" 这种前缀的行不被误改；2) 模型带前缀复制过来也能工作。
    const use_stripped = std.mem.indexOf(u8, original, old_unesc) == null;
    if (use_stripped and std.mem.indexOf(u8, original, old_stripped) == null) {
        return error.StringNotFound;
    }
    const old_string = if (use_stripped) old_stripped else old_unesc;
    const new_string = if (use_stripped) new_stripped else new_unesc;

    const replace_all_str = common.extractJsonArg(args, "replace_all");
    const replace_all = replace_all_str != null and std.mem.eql(u8, replace_all_str.?, "true");

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

    // 写完后刷新 ReadState 的 mtime，避免紧接着再次 Edit 报 stale
    if (ctx.read_state) |rs| {
        const st = read_state.statFd(write_fd) catch null;
        if (st) |s| rs.record(file_path, s.mtime_ns, s.size) catch {};
    }

    return try std.fmt.allocPrint(allocator,
        \\{{"file_path":"{s}","old_string":"{s}","new_string":"{s}","success":true}}
    , .{ file_path, old_raw, new_raw });
}

/// 按行扫描；若行首匹配 `^[ ]{0,5}\d+\t` 则去掉该前缀。返回新分配的切片。
/// 行分隔用 '\n'，原样保留。若没有任何行需要剥离，返回原内容的 dupe。
fn stripLineNumberPrefix(text: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);

    var line_start: usize = 0;
    while (line_start <= text.len) {
        const nl_opt = std.mem.indexOfScalarPos(u8, text, line_start, '\n');
        const line_end = nl_opt orelse text.len;
        const line = text[line_start..line_end];

        const body_start = detectPrefixLen(line);
        try out.appendSlice(allocator, line[body_start..]);
        if (nl_opt) |i| {
            try out.append(allocator, '\n');
            line_start = i + 1;
        } else {
            break;
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// 返回行首前缀长度（若匹配 `^[ ]{0,5}\d+\t`），否则 0。
fn detectPrefixLen(line: []const u8) usize {
    var i: usize = 0;
    while (i < @min(line.len, 5) and line[i] == ' ') : (i += 1) {}
    const digit_start = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == digit_start) return 0; // 没数字
    if (i >= line.len or line[i] != '\t') return 0; // 数字后不是 tab
    return i + 1;
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

test "EditTool strips cat-n line numbers from old_string" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-edit-lnstrip-test.txt";
    defer _ = std.c.unlink(path);

    const write = @import("write.zig");
    std.testing.allocator.free(try write.execute(&ctx, "{\"path\":\"/tmp/cc-zig-edit-lnstrip-test.txt\",\"content\":\"hello\\nworld\"}"));

    // 模拟模型从 Read 结果里复制带行号前缀的 old_string:
    //   "     2\\tworld"  —— Edit 应识别并 strip，匹配文件中的 "world"
    const result = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-edit-lnstrip-test.txt\",\"old_string\":\"     2\\tworld\",\"new_string\":\"     2\\tzig\"}");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);

    // 读回验证文件现在是 "hello\nzig"（注意 read 会加前缀，检查 content 包含 "zig"）
    const read = @import("read.zig");
    const content = try read.execute(&ctx, "{\"path\":\"/tmp/cc-zig-edit-lnstrip-test.txt\"}");
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "world") == null);
}

test "stripLineNumberPrefix basic" {
    const a = std.testing.allocator;
    const input = "     1\thello\n     2\tworld\n";
    const stripped = try stripLineNumberPrefix(input, a);
    defer a.free(stripped);
    try std.testing.expectEqualStrings("hello\nworld\n", stripped);
}

test "stripLineNumberPrefix leaves non-matching lines alone" {
    const a = std.testing.allocator;
    const input = "hello\nworld\n";
    const stripped = try stripLineNumberPrefix(input, a);
    defer a.free(stripped);
    try std.testing.expectEqualStrings("hello\nworld\n", stripped);
}

test "stripLineNumberPrefix ignores line without tab after digits" {
    const a = std.testing.allocator;
    // "42" 后面跟 space，不是 tab → 不剥离
    const input = "     42 hello\n";
    const stripped = try stripLineNumberPrefix(input, a);
    defer a.free(stripped);
    try std.testing.expectEqualStrings("     42 hello\n", stripped);
}

test "EditTool not-read-first rejects" {
    const a = std.testing.allocator;
    const path = "/tmp/cc-zig-edit-mrf-test.txt";
    defer _ = std.c.unlink(path);

    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = std.c.write(fd, "hello", 5);
    _ = std.c.close(fd);

    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();

    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    try std.testing.expectError(error.NotRead, execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-edit-mrf-test.txt\",\"old_string\":\"hello\",\"new_string\":\"world\"}"));
}

test "EditTool stale rejected" {
    const a = std.testing.allocator;
    const path = "/tmp/cc-zig-edit-stale-test.txt";
    defer _ = std.c.unlink(path);

    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = std.c.write(fd, "hello", 5);
    _ = std.c.close(fd);

    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();
    try rs.record(path, 1, 5); // 假 mtime

    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    try std.testing.expectError(error.StaleFile, execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-edit-stale-test.txt\",\"old_string\":\"hello\",\"new_string\":\"world\"}"));
}

test "EditTool after read succeeds" {
    const a = std.testing.allocator;
    const path = "/tmp/cc-zig-edit-after-read-test.txt";
    defer _ = std.c.unlink(path);

    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = std.c.write(fd, "foo", 3);
    _ = std.c.close(fd);

    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();

    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    // 先模拟 Read（从文件 stat 出真 mtime 记入）
    const read = @import("read.zig");
    const rout = try read.execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-edit-after-read-test.txt\"}");
    a.free(rout);

    // 现在 Edit 应成功
    const result = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-edit-after-read-test.txt\",\"old_string\":\"foo\",\"new_string\":\"bar\"}");
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
}
