const std = @import("std");
const common = @import("common.zig");
const security = @import("security.zig");
const read_state = @import("../core/read_state.zig");
const ts = @import("../treesitter/ts.zig");
const code_map = @import("code_map.zig");
const ToolContext = @import("context.zig").ToolContext;

/// 默认读取行数上限（对齐 TS：限制 200KB/2000 行用户无感截断）。
pub const DEFAULT_LIMIT_LINES: usize = 2000;

/// 整读(不带 offset/limit)的文件字节上限(对齐 Claude Code 256KB)。超出 → 拒读 + 提示用
/// offset/limit 或 Grep,防一次性把大文件灌进上下文。显式传 offset/limit 时不受此限(用户要精确范围)。
pub const MAX_FILE_BYTES: usize = 256 * 1024;

/// 单行字节上限:超长行(如压缩成一行的 minified 文件)截断到此 + 标记,防"1 行几 MB"撑爆。
pub const MAX_LINE_BYTES: usize = 2000;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    // 兼容：优先 file_path（TS 原版），回退 path（历史）
    const path = common.extractJsonArg(args, "file_path") orelse
        common.extractJsonArg(args, "path") orelse
        return error.MissingPath;
    if (path.len == 0) return error.EmptyPath;
    try security.validateNoTraversal(path);
    try rejectDevicePath(path);

    // 图像文件：单独路径——不当文本读（会乱码 + 撑爆 token）。
    if (imageMediaType(path)) |media_type| {
        return try readImage(allocator, ctx, path, media_type);
    }

    // outline 模式(opt-in):返回符号大纲(函数/类型/类 + 行号 + 签名)而非文件内容。
    // 仅对 tree-sitter 支持的语言;不支持则回退正常读取(向后兼容)。
    if (isTrue(common.extractJsonArg(args, "outline"))) {
        if (ts.Lang.fromPath(path)) |lang| {
            return try readOutline(allocator, path, lang);
        }
        // 不支持的语言 → 落到正常读取路径
    }

    const has_offset = common.extractJsonArg(args, "offset") != null;
    const has_limit = common.extractJsonArg(args, "limit") != null;
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

    // 大文件守卫:整读(未显式传 offset/limit)且 > MAX_FILE_BYTES → 不再死胡同报错;
    // 若是 tree-sitter 支持的语言,返回符号大纲 + 提示(用 offset/limit 读具体范围);
    // 否则维持原"too large"错误串(不支持的语言无法出大纲)。显式 offset/limit 放行。
    if (!has_offset and !has_limit) {
        if (st) |s| {
            if (s.size > MAX_FILE_BYTES) {
                if (ts.Lang.fromPath(path)) |lang| {
                    const outline = try readOutlineFromFd(allocator, path, lang, fd);
                    defer allocator.free(outline);
                    return try std.fmt.allocPrint(allocator, "File too large to show in full ({d} bytes, limit {d}). Outline below; Read a range with offset+limit for bodies.\n\n{s}", .{ s.size, MAX_FILE_BYTES, outline });
                }
                return try std.fmt.allocPrint(allocator, "{{\"error\":\"file too large ({d} bytes, limit {d}). Read a range with offset+limit, or use Grep to find specific content.\"}}", .{ s.size, MAX_FILE_BYTES });
            }
        }
    }

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
        if (st) |s| rs.recordHashed(path, s.mtime_ns, s.size, std.hash.Wyhash.hash(0, full)) catch {};
    }

    return try renderWithLineNumbers(full[line_start..end], offset_1based, allocator);
}

fn isTrue(s: ?[]const u8) bool {
    return s != null and std.mem.eql(u8, s.?, "true");
}

/// outline 模式:打开文件、读全量、渲染符号大纲。调用方拥有返回串。
fn readOutline(allocator: std.mem.Allocator, path: []const u8, lang: ts.Lang) ![]u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer _ = std.c.close(fd);
    return try readOutlineFromFd(allocator, path, lang, fd);
}

/// 已有 fd 时渲染大纲(大文件守卫路径复用,避免重开)。
fn readOutlineFromFd(allocator: std.mem.Allocator, path: []const u8, lang: ts.Lang, fd: std.posix.fd_t) ![]u8 {
    const source = try common.readAllFromFd(fd, allocator);
    defer allocator.free(source);
    return try code_map.renderOutlineForSource(allocator, path, source, lang);
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
        // 单行超长 → 截断到 MAX_LINE_BYTES(UTF-8 边界安全)+ 标记,防 minified 一行几 MB 撑爆。
        const raw_line = slice[pos..line_end];
        if (raw_line.len > MAX_LINE_BYTES) {
            var cut = MAX_LINE_BYTES;
            while (cut > 0 and (raw_line[cut] & 0b1100_0000) == 0b1000_0000) : (cut -= 1) {}
            try out.appendSlice(allocator, raw_line[0..cut]);
            try out.appendSlice(allocator, " … [line truncated]");
        } else {
            try out.appendSlice(allocator, raw_line);
        }
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

/// 阻塞/无限设备路径黑名单——读这些会 hang 或无限流。
const DEVICE_PATHS = [_][]const u8{
    "/dev/zero",  "/dev/random", "/dev/urandom", "/dev/null",
    "/dev/stdin", "/dev/stdout", "/dev/stderr",  "/dev/full",
    "/dev/tty",   "/dev/ptmx",
};

fn rejectDevicePath(path: []const u8) !void {
    for (DEVICE_PATHS) |dp| {
        if (std.mem.eql(u8, path, dp)) return error.DevicePathBlocked;
    }
    // /dev/fd/* 与 /proc/*/fd/* 也容易 hang
    if (std.mem.startsWith(u8, path, "/dev/fd/")) return error.DevicePathBlocked;
}

/// 按扩展名判定图像 media_type；非图像返 null。
fn imageMediaType(path: []const u8) ?[]const u8 {
    const Ext = struct { suffix: []const u8, mt: []const u8 };
    const table = [_]Ext{
        .{ .suffix = ".png", .mt = "image/png" },
        .{ .suffix = ".jpg", .mt = "image/jpeg" },
        .{ .suffix = ".jpeg", .mt = "image/jpeg" },
        .{ .suffix = ".gif", .mt = "image/gif" },
        .{ .suffix = ".webp", .mt = "image/webp" },
    };
    for (table) |e| {
        if (endsWithIgnoreCase(path, e.suffix)) return e.mt;
    }
    return null;
}

fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    if (s.len < suffix.len) return false;
    const tail = s[s.len - suffix.len ..];
    for (tail, suffix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

/// 图像读取上限（base64 前的原始字节）。Anthropic 单图 ~5MB 限制，留余量取 3.75MB。
const MAX_IMAGE_BYTES: usize = 3_750_000;

/// 读图像 → base64 → 返回结构化 JSON：{"type":"image","media_type":"...","data":"<b64>"}。
/// api/request.zig 的 serializeContent 检测到此形态会发成真正的 image content block。
fn readImage(allocator: std.mem.Allocator, ctx: *const ToolContext, path: []const u8, media_type: []const u8) ![]u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer _ = std.c.close(fd);

    const st = read_state.statFd(fd) catch null;
    if (st) |s| {
        if (s.size > MAX_IMAGE_BYTES) return error.ImageTooLarge;
    }

    const raw = try common.readAllFromFd(fd, allocator);
    defer allocator.free(raw);
    if (raw.len > MAX_IMAGE_BYTES) return error.ImageTooLarge;

    // base64 编码
    const enc = std.base64.standard.Encoder;
    const b64_len = enc.calcSize(raw.len);
    const b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64);
    _ = enc.encode(b64, raw);

    // 记录 ReadState（图像也算"读过"，后续 Write 才放行）
    if (ctx.read_state) |rs| {
        if (st) |s| rs.recordHashed(path, s.mtime_ns, s.size, std.hash.Wyhash.hash(0, raw)) catch {};
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"type\":\"image\",\"media_type\":");
    try std.json.Stringify.encodeJsonString(media_type, .{}, &out.writer);
    try out.writer.writeAll(",\"data\":");
    try std.json.Stringify.encodeJsonString(b64, .{}, &out.writer);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

test "imageMediaType detects extensions" {
    try std.testing.expectEqualStrings("image/png", imageMediaType("/x/y.png").?);
    try std.testing.expectEqualStrings("image/jpeg", imageMediaType("a.JPG").?);
    try std.testing.expectEqualStrings("image/webp", imageMediaType("z.webp").?);
    try std.testing.expect(imageMediaType("foo.txt") == null);
    try std.testing.expect(imageMediaType("noext") == null);
}

test "rejectDevicePath blocks devices" {
    try std.testing.expectError(error.DevicePathBlocked, rejectDevicePath("/dev/zero"));
    try std.testing.expectError(error.DevicePathBlocked, rejectDevicePath("/dev/fd/3"));
    try rejectDevicePath("/tmp/normal.txt"); // 不报错
}

test "ReadTool device path blocked via execute" {
    const ctx = testCtx();
    try std.testing.expectError(error.DevicePathBlocked, execute(&ctx, "{\"file_path\":\"/dev/zero\"}"));
}

test "ReadTool image returns structured json" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-read-img-test.png";
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    // 4 字节假 PNG header
    const bytes = [_]u8{ 0x89, 0x50, 0x4E, 0x47 };
    _ = std.c.write(fd, &bytes, bytes.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path);

    const r = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-img-test.png\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"type\":\"image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"media_type\":\"image/png\"") != null);
    // base64 of 0x89504E47 = "iVBORw=="
    try std.testing.expect(std.mem.indexOf(u8, r, "iVBORw") != null);
}

test "ReadTool missing path" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingPath, execute(&ctx, "{\"content\":\"x\"}"));
}

test "ReadTool path traversal blocked (file_path)" {
    const ctx = testCtx();
    try std.testing.expectError(error.PathTraversal, execute(&ctx, "{\"file_path\":\"../../etc/passwd\"}"));
}

test "ReadTool read /etc/hosts via file_path" {
    const ctx = testCtx();
    const r = try execute(&ctx, "{\"file_path\":\"/etc/hosts\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(r.len > 0);
}

test "ReadTool read /etc/hosts via legacy path" {
    const ctx = testCtx();
    const r = try execute(&ctx, "{\"path\":\"/etc/hosts\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(r.len > 0);
}

test "ReadTool offset beyond file returns empty" {
    const ctx = testCtx();
    const r = try execute(&ctx, "{\"file_path\":\"/etc/hosts\",\"offset\":1000}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(r.len == 0);
}

test "ReadTool offset=0 is invalid" {
    const ctx = testCtx();
    try std.testing.expectError(error.InvalidOffset, execute(&ctx, "{\"file_path\":\"/etc/hosts\",\"offset\":0}"));
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
    // /etc/hosts 一般 1 行；limit=10000 不会报错
    const r = try execute(&ctx, "{\"file_path\":\"/etc/hosts\",\"limit\":10000}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(r.len > 0);
}

test "ReadTool default limit reads at least first line" {
    const ctx = testCtx();
    const r = try execute(&ctx, "{\"file_path\":\"/etc/hosts\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(r.len > 0);
}

test "ReadTool 大文件整读被拒(防撑爆);带 offset/limit 放行" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-read-toobig.txt";
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    // 写 > 256KB(每行短,行数也多)。
    const line = "abcdefghij\n"; // 11 bytes
    var i: usize = 0;
    while (i < 30000) : (i += 1) _ = std.c.write(fd, line.ptr, line.len); // ~330KB
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path);

    // 整读(无 offset/limit)→ 拒读 + too large 提示。
    const r1 = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-toobig.txt\"}");
    defer std.testing.allocator.free(r1);
    try std.testing.expect(std.mem.indexOf(u8, r1, "too large") != null);

    // 带 limit → 放行(读前 N 行)。
    const r2 = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-toobig.txt\",\"limit\":5}");
    defer std.testing.allocator.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "too large") == null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "abcdefghij") != null);
}

test "ReadTool 超长单行被截断 + 标记" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-read-longline.txt";
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    // 一行 5000 个 'x'(超过 MAX_LINE_BYTES=2000),文件总字节 < 256KB 不触发大文件守卫。
    const big_line = "x" ** 5000;
    _ = std.c.write(fd, big_line.ptr, big_line.len);
    _ = std.c.write(fd, "\n", 1);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path);

    const r = try execute(&ctx, "{\"file_path\":\"/tmp/cc-zig-read-longline.txt\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "line truncated") != null);
    // 截断后该行的 x 数应 ≤ MAX_LINE_BYTES。
    var xcount: usize = 0;
    for (r) |c| {
        if (c == 'x') xcount += 1;
    }
    try std.testing.expect(xcount <= MAX_LINE_BYTES);
}
