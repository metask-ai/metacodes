const std = @import("std");
const common = @import("common.zig");
const toolchain = @import("../util/toolchain.zig");
const ToolContext = @import("context.zig").ToolContext;

/// 默认 head_limit(对齐 Claude Code GrepTool):content 模式不传 head_limit 时只返前 250 行,
/// 防止宽匹配把整个文件灌进上下文。显式传 head_limit=0 = 无限。
pub const DEFAULT_HEAD_LIMIT: usize = 250;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const pattern = common.extractJsonArg(args, "pattern") orelse return error.MissingPattern;
    const path = common.extractJsonArg(args, "path") orelse ".";
    if (pattern.len == 0) return error.EmptyPattern;

    const rg_path = try toolchain.ripgrepPath();

    // output_mode: content (默认，带行号) / files_with_matches / count
    const output_mode = common.extractJsonArg(args, "output_mode") orelse "files_with_matches";

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, rg_path);
    // 静默 stderr 上的权限/访问错误，避免污染 tool_result 和 CI 日志。
    try argv.append(allocator, "--no-messages");

    // 基础模式选择
    if (std.mem.eql(u8, output_mode, "files_with_matches")) {
        try argv.append(allocator, "-l");
    } else if (std.mem.eql(u8, output_mode, "count")) {
        try argv.append(allocator, "-c");
    } else if (std.mem.eql(u8, output_mode, "content")) {
        // 默认 content 模式开 -n
        if (common.extractJsonArg(args, "-n") == null or isTrue(common.extractJsonArg(args, "-n"))) {
            try argv.append(allocator, "-n");
        }
    } else {
        return error.InvalidOutputMode;
    }

    // -B / -A / -C（仅在 content 模式有意义，但 rg 会忽略非 content 的数值）
    if (std.mem.eql(u8, output_mode, "content")) {
        if (common.extractJsonArg(args, "-B")) |s| {
            try argv.append(allocator, "-B");
            try argv.append(allocator, s);
        }
        if (common.extractJsonArg(args, "-A")) |s| {
            try argv.append(allocator, "-A");
            try argv.append(allocator, s);
        }
        if (common.extractJsonArg(args, "-C")) |s| {
            try argv.append(allocator, "-C");
            try argv.append(allocator, s);
        } else if (common.extractJsonArg(args, "context")) |s| {
            // 兼容旧 "context" 参数
            try argv.append(allocator, "-C");
            try argv.append(allocator, s);
        }
    }

    // -i 大小写不敏感
    if (isTrue(common.extractJsonArg(args, "-i"))) {
        try argv.append(allocator, "-i");
    }

    // --type
    if (common.extractJsonArg(args, "type")) |t| {
        try argv.append(allocator, "--type");
        try argv.append(allocator, t);
    }

    // --glob
    if (common.extractJsonArg(args, "glob")) |g| {
        try argv.append(allocator, "--glob");
        try argv.append(allocator, g);
    }

    // multiline：-U 启用多行模式（需要 -P PCRE）
    if (isTrue(common.extractJsonArg(args, "multiline"))) {
        try argv.append(allocator, "-U");
        try argv.append(allocator, "--multiline-dotall");
    }

    // head_limit / offset：全局（跨文件）分页。
    // 不再用 rg 的 -m（那是每文件上限，跨文件会失真）；改为抓全量输出后按行截断。
    // offset = 跳过前 N 行；head_limit = 截断后保留 N 行。
    // **默认 head_limit=250**（对齐 Claude Code,防止 `grep "."` 把整个文件灌进上下文）。
    // 显式传 head_limit=0 = 无限（用户主动要全量时）。缺省（null）→ 用默认 250。
    const head_limit: usize = parseUsize(common.extractJsonArg(args, "head_limit")) orelse DEFAULT_HEAD_LIMIT;
    const offset = parseUsize(common.extractJsonArg(args, "offset")) orelse 0;

    // positional: pattern, path
    try argv.append(allocator, pattern);
    try argv.append(allocator, path);

    // 转成 [*:0]const u8 数组（z-strings）
    var argv_z = try allocator.alloc(?[*:0]const u8, argv.items.len + 1);
    defer {
        for (argv_z[0..argv.items.len]) |p| if (p) |pp| allocator.free(std.mem.span(pp));
        allocator.free(argv_z);
    }
    for (argv.items, 0..) |s, i| {
        argv_z[i] = (try allocator.dupeZ(u8, s)).ptr;
    }
    argv_z[argv.items.len] = null;

    const raw = try common.spawnCaptureStdoutAbortable(argv_z, allocator, ctx.abort);

    // head_limit=0（显式无限）且 offset=0 → 原样返回（保持既有行为 + 测试兼容）。
    if (head_limit == 0 and offset == 0) return raw;
    defer allocator.free(raw);

    return try paginate(allocator, raw, offset, head_limit);
}

/// 按行做全局 offset + head_limit 截断。head_limit=0 表示无限。
/// 截断发生时在末尾追加一行 appliedLimit 提示，让模型知道还有更多结果、可用 offset 翻页。
fn paginate(allocator: std.mem.Allocator, raw: []const u8, offset: usize, head_limit: usize) ![]u8 {
    // 统计 + 收集行（保留行内容，不含换行符）
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |ln| {
        // splitScalar 末尾的空串（raw 以 \n 结尾）跳过
        if (ln.len == 0 and it.peek() == null) break;
        try lines.append(allocator, ln);
    }
    const total = lines.items.len;

    const start = @min(offset, total);
    const remaining = total - start;
    const take = if (head_limit == 0) remaining else @min(head_limit, remaining);
    const end = start + take;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (lines.items[start..end]) |ln| {
        try out.writer.writeAll(ln);
        try out.writer.writeByte('\n');
    }

    const truncated = end < total or start > 0;
    if (truncated) {
        try out.writer.print(
            "\n[appliedLimit: showing lines {d}-{d} of {d}; pass offset={d} for the next page]\n",
            .{ start + 1, end, total, end },
        );
    }
    return try out.toOwnedSlice();
}

fn parseUsize(s: ?[]const u8) ?usize {
    const v = s orelse return null;
    return std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t"), 10) catch null;
}

fn isTrue(s: ?[]const u8) bool {
    return s != null and std.mem.eql(u8, s.?, "true");
}

fn testCtx() ToolContext {
    return ToolContext.simple(std.testing.allocator);
}

test "GrepTool missing pattern" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingPattern, execute(&ctx, "{\"path\":\".\"}"));
}

test "GrepTool empty pattern" {
    const ctx = testCtx();
    try std.testing.expectError(error.EmptyPattern, execute(&ctx, "{\"pattern\":\"\"}"));
}

test "GrepTool invalid output_mode" {
    const ctx = testCtx();
    try std.testing.expectError(error.InvalidOutputMode, execute(&ctx, "{\"pattern\":\"x\",\"output_mode\":\"bogus\"}"));
}

test "GrepTool files_with_matches default" {
    // pattern 只需不崩即可，rg 可能返空
    const ctx = testCtx();
    const r = try execute(&ctx, "{\"pattern\":\"zzzzzz-nonexistent-zzzzzz\",\"path\":\"/tmp\"}");
    defer std.testing.allocator.free(r);
}

test "GrepTool content mode with -n" {
    const ctx = testCtx();
    // 准备一个包含 "needle" 的临时文件
    const path = "/tmp/cc-zig-grep-content-test.txt";
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "pre\nneedle line\npost\n";
    _ = std.c.write(fd, text.ptr, text.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path);

    const r = try execute(&ctx, "{\"pattern\":\"needle\",\"path\":\"/tmp/cc-zig-grep-content-test.txt\",\"output_mode\":\"content\"}");
    defer std.testing.allocator.free(r);
    // content 模式应含行号 "2:" 和匹配文本 "needle"
    try std.testing.expect(std.mem.indexOf(u8, r, "needle") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "2:") != null);
}

test "GrepTool count mode" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-grep-count-test.txt";
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "x\nx\ny\nx\n";
    _ = std.c.write(fd, text.ptr, text.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path);

    const r = try execute(&ctx, "{\"pattern\":\"x\",\"path\":\"/tmp/cc-zig-grep-count-test.txt\",\"output_mode\":\"count\"}");
    defer std.testing.allocator.free(r);
    // rg -c 对单文件输出 "3\n"（无 path 前缀）
    const trimmed = std.mem.trim(u8, r, " \r\n");
    try std.testing.expectEqualStrings("3", trimmed);
}

test "GrepTool case insensitive" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-grep-i-test.txt";
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "HELLO\nworld\n";
    _ = std.c.write(fd, text.ptr, text.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path);

    const r = try execute(&ctx, "{\"pattern\":\"hello\",\"path\":\"/tmp/cc-zig-grep-i-test.txt\",\"output_mode\":\"content\",\"-i\":true}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "HELLO") != null);
}

test "GrepTool -B -A context" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-grep-ctx-test.txt";
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "before\nmatch\nafter\nother\n";
    _ = std.c.write(fd, text.ptr, text.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path);

    const r = try execute(&ctx, "{\"pattern\":\"match\",\"path\":\"/tmp/cc-zig-grep-ctx-test.txt\",\"output_mode\":\"content\",\"-B\":\"1\",\"-A\":\"1\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "other") == null);
}

test "GrepTool -C context shorthand" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-grep-cC-test.txt";
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "a\nb\nHIT\nc\nd\n";
    _ = std.c.write(fd, text.ptr, text.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path);

    const r = try execute(&ctx, "{\"pattern\":\"HIT\",\"path\":\"/tmp/cc-zig-grep-cC-test.txt\",\"output_mode\":\"content\",\"-C\":\"1\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "b") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "c") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "a") == null);
}

test "GrepTool glob filter" {
    const ctx = testCtx();
    // 在 /tmp 造两个文件：一个 .zig 一个 .txt
    const zig_path: [*:0]const u8 = "/tmp/cc-zig-grep-glob.zig";
    const txt_path: [*:0]const u8 = "/tmp/cc-zig-grep-glob.txt";
    const text = "hello\n";

    const fd1 = std.c.open(zig_path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = std.c.write(fd1, text.ptr, text.len);
    _ = std.c.close(fd1);
    const fd2 = std.c.open(txt_path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = std.c.write(fd2, text.ptr, text.len);
    _ = std.c.close(fd2);
    defer _ = std.c.unlink(zig_path);
    defer _ = std.c.unlink(txt_path);

    const r = try execute(&ctx, "{\"pattern\":\"hello\",\"path\":\"/tmp\",\"output_mode\":\"files_with_matches\",\"glob\":\"cc-zig-grep-glob.zig\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "cc-zig-grep-glob.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "cc-zig-grep-glob.txt") == null);
}

test "paginate: head_limit truncates and adds appliedLimit notice" {
    const a = std.testing.allocator;
    const raw = "l1\nl2\nl3\nl4\nl5\n";
    const r = try paginate(a, raw, 0, 2);
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "l1\nl2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "l3") == null);
    try std.testing.expect(std.mem.indexOf(u8, r, "appliedLimit") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "of 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "offset=2") != null);
}

test "paginate: offset skips leading lines" {
    const a = std.testing.allocator;
    const raw = "l1\nl2\nl3\nl4\n";
    const r = try paginate(a, raw, 2, 0); // 0 = 无限 head_limit
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "l1") == null);
    try std.testing.expect(std.mem.indexOf(u8, r, "l3\nl4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "appliedLimit") != null);
}

test "paginate: limit >= total has no notice" {
    const a = std.testing.allocator;
    const raw = "l1\nl2\n";
    const r = try paginate(a, raw, 0, 10);
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "l1\nl2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "appliedLimit") == null);
}

test "paginate: offset beyond total returns just notice" {
    const a = std.testing.allocator;
    const raw = "l1\nl2\n";
    const r = try paginate(a, raw, 99, 0); // 0 = 无限
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "l1") == null);
    try std.testing.expect(std.mem.indexOf(u8, r, "of 2") != null);
}

test "GrepTool global head_limit across content" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-grep-headlimit.txt";
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "m\nm\nm\nm\nm\n";
    _ = std.c.write(fd, text.ptr, text.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path);

    const r = try execute(&ctx, "{\"pattern\":\"m\",\"path\":\"/tmp/cc-zig-grep-headlimit.txt\",\"output_mode\":\"content\",\"head_limit\":2}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "appliedLimit") != null);
}

test "GrepTool 默认 head_limit=250:不传时宽匹配被截断(防撑爆)" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-grep-default-cap.txt";
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    // 写 300 行全匹配 → 不传 head_limit → 应只返 250 行 + appliedLimit 提示。
    var i: usize = 0;
    while (i < 300) : (i += 1) _ = std.c.write(fd, "match\n", 6);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path);

    const r = try execute(&ctx, "{\"pattern\":\"match\",\"path\":\"/tmp/cc-zig-grep-default-cap.txt\",\"output_mode\":\"content\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "appliedLimit") != null); // 被截断
    // 数 match 行数应 ≤ 250(+提示行)。
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, r, '\n');
    while (it.next()) |ln| {
        if (std.mem.indexOf(u8, ln, "match") != null) count += 1;
    }
    try std.testing.expect(count <= 250);
}

test "GrepTool head_limit=0 显式无限:返回全部不截断" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-grep-unlimited.txt";
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    var i: usize = 0;
    while (i < 300) : (i += 1) _ = std.c.write(fd, "match\n", 6);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path);

    const r = try execute(&ctx, "{\"pattern\":\"match\",\"path\":\"/tmp/cc-zig-grep-unlimited.txt\",\"output_mode\":\"content\",\"head_limit\":0}");
    defer std.testing.allocator.free(r);
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, r, '\n');
    while (it.next()) |ln| {
        if (std.mem.indexOf(u8, ln, "match") != null) count += 1;
    }
    try std.testing.expect(count == 300); // 全返回
}
