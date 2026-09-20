//! LSP 诊断格式化 + XSS/注入防护(对齐 hermes reporter.py)。
//!
//! **安全关键**:message/code/source 来自 language server 解析**潜在恶意的仓库源码**,是攻击者可控
//! 输入,直接拼进给模型的工具结果。必须 sanitize:CR/LF→空格、剥非打印控制符、逐字段截断、HTML 转义
//! `< > &`;file 路径额外转义 `"`(防 `foo"><script` 破坏 `file="..."` 属性)。
//!
//! severity 默认只报 error(warning/info/hint 洪水会淹没模型)。caps:每文件 20 条 + 总 4000 字符。
const std = @import("std");

pub const Severity = enum(u8) { err = 1, warn = 2, info = 3, hint = 4 };

pub const Diagnostic = struct {
    severity: Severity,
    line: u32, // 0-based(LSP wire);格式化时 +1
    col: u32,
    end_line: u32,
    end_col: u32,
    message: []const u8,
    code: []const u8 = "",
    source: []const u8 = "",
};

const MAX_MESSAGE = 300;
const MAX_CODE = 80;
const MAX_SOURCE = 80;
const MAX_PER_FILE = 20;
pub const MAX_TOTAL_CHARS = 4000;

/// 只报这些严重度(默认只 error)。
pub const DEFAULT_SEVERITIES = [_]Severity{.err};

fn severityAllowed(s: Severity, allowed: []const Severity) bool {
    for (allowed) |a| if (a == s) return true;
    return false;
}

fn severityName(s: Severity) []const u8 {
    return switch (s) {
        .err => "ERROR",
        .warn => "WARN",
        .info => "INFO",
        .hint => "HINT",
    };
}

/// sanitize 一个攻击者可控字段:CR/LF→空格、剥控制符、截断到 limit、HTML 转义 `< > &`。
/// escape_quote=true 时额外转义 `"`(供 file 属性)。写入 out。
fn sanitizeField(out: *std.ArrayList(u8), alloc: std.mem.Allocator, value: []const u8, limit: usize, escape_quote: bool) !void {
    var written: usize = 0;
    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];
        // CR/LF/Tab → 空格(单字节)。
        if (c == '\r' or c == '\n' or c == '\t') {
            if (written >= limit) break;
            try out.append(alloc, ' ');
            written += 1;
            i += 1;
            continue;
        }
        // 其它非打印控制符 → 丢弃(不计 written)。
        if (c < 0x20 or c == 0x7f) {
            i += 1;
            continue;
        }
        // 多字节 UTF-8:**整码点一起**处理,绝不切半个码点(否则产坏 UTF-8)。
        const cp_len: usize = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (c >= 0x80) {
            if (cp_len == 1 or cp_len > value.len - i or
                !std.unicode.utf8ValidateSlice(value[i .. i + cp_len]))
            {
                // LSP input is external bytes, so a lead byte and a length
                // check are insufficient: validate the complete sequence.
                // Keep the output valid UTF-8 and preserve a visible marker
                // instead of leaking an illegal byte into the host stream.
                if (3 > limit - written) break;
                try out.appendSlice(alloc, "�");
                written += 3;
                i += 1;
                continue;
            }
            if (cp_len > limit - written) break; // 放不下整码点 → 在码点边界停
            try out.appendSlice(alloc, value[i .. i + cp_len]);
            written += cp_len;
            i += cp_len;
            continue;
        }
        // 单字节可打印 ASCII:HTML 转义。
        if (written >= limit) break;
        switch (c) {
            '<' => try out.appendSlice(alloc, "&lt;"),
            '>' => try out.appendSlice(alloc, "&gt;"),
            '&' => try out.appendSlice(alloc, "&amp;"),
            '"' => if (escape_quote) try out.appendSlice(alloc, "&quot;") else try out.append(alloc, '"'),
            else => try out.append(alloc, c),
        }
        written += 1;
        i += 1;
    }
    if (i < value.len) try out.appendSlice(alloc, "…"); // 截断标记
}

/// 格式化一个文件的诊断为 `<diagnostics file="...">...</diagnostics>` 块。
/// 无 allowed 严重度诊断 → 返回空串("")。owned,调用方 free。
pub fn reportForFile(alloc: std.mem.Allocator, file_path: []const u8, diags: []const Diagnostic, allowed: []const Severity) ![]u8 {
    // 先过滤。
    var kept: std.ArrayList(*const Diagnostic) = .empty;
    defer kept.deinit(alloc);
    for (diags) |*d| {
        if (severityAllowed(d.severity, allowed)) try kept.append(alloc, d);
    }
    if (kept.items.len == 0) return try alloc.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, "<diagnostics file=\"");
    try sanitizeField(&out, alloc, file_path, 1024, true); // file 属性:转义引号
    try out.appendSlice(alloc, "\">\n");

    const show = @min(kept.items.len, MAX_PER_FILE);
    for (kept.items[0..show]) |d| {
        // ERROR [line:col] message [code] (source)
        try out.appendSlice(alloc, severityName(d.severity));
        var lc_buf: [48]u8 = undefined;
        try out.appendSlice(alloc, try std.fmt.bufPrint(&lc_buf, " [{d}:{d}] ", .{ d.line + 1, d.col + 1 })); // 1-indexed
        try sanitizeField(&out, alloc, d.message, MAX_MESSAGE, false);
        if (d.code.len > 0) {
            try out.appendSlice(alloc, " [");
            try sanitizeField(&out, alloc, d.code, MAX_CODE, false);
            try out.append(alloc, ']');
        }
        if (d.source.len > 0) {
            try out.appendSlice(alloc, " (");
            try sanitizeField(&out, alloc, d.source, MAX_SOURCE, false);
            try out.append(alloc, ')');
        }
        try out.append(alloc, '\n');
    }
    if (kept.items.len > show) {
        var more_buf: [48]u8 = undefined;
        try out.appendSlice(alloc, try std.fmt.bufPrint(&more_buf, "... and {d} more\n", .{kept.items.len - show}));
    }
    try out.appendSlice(alloc, "</diagnostics>");
    return try out.toOwnedSlice(alloc);
}

/// 总长度截断到 MAX_TOTAL_CHARS(多文件拼接后)。超出 → 截断 + `…[truncated]`。owned。
pub fn truncate(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len <= MAX_TOTAL_CHARS) return try alloc.dupe(u8, text);
    // 在 UTF-8 边界截断(不切多字节码点中间)。
    var cut: usize = MAX_TOTAL_CHARS;
    while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1; // 回退到码点起始
    return try std.fmt.allocPrint(alloc, "{s}…[truncated]", .{text[0..cut]});
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "reportForFile: 基本格式 + 1-indexed" {
    const a = testing.allocator;
    const diags = [_]Diagnostic{
        .{ .severity = .err, .line = 11, .col = 4, .end_line = 11, .end_col = 10, .message = "Cannot find name 'foo'", .code = "reportUndefinedVariable", .source = "pyright" },
    };
    const s = try reportForFile(a, "src/x.py", &diags, &DEFAULT_SEVERITIES);
    defer a.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "<diagnostics file=\"src/x.py\">") != null);
    try testing.expect(std.mem.indexOf(u8, s, "ERROR [12:5] Cannot find name 'foo' [reportUndefinedVariable] (pyright)") != null);
    try testing.expect(std.mem.endsWith(u8, s, "</diagnostics>"));
}

test "reportForFile: severity 过滤(默认只 error;warn 被丢)" {
    const a = testing.allocator;
    const diags = [_]Diagnostic{
        .{ .severity = .warn, .line = 0, .col = 0, .end_line = 0, .end_col = 1, .message = "unused" },
    };
    const s = try reportForFile(a, "x.py", &diags, &DEFAULT_SEVERITIES);
    defer a.free(s);
    try testing.expectEqualStrings("", s); // 全被过滤 → 空
}

test "reportForFile: XSS sanitize(message/file 恶意内容转义)" {
    const a = testing.allocator;
    const diags = [_]Diagnostic{
        .{ .severity = .err, .line = 0, .col = 0, .end_line = 0, .end_col = 1, .message = "bad <script>alert(1)</script> & stuff\nnewline" },
    };
    const s = try reportForFile(a, "a\"><script>.py", &diags, &DEFAULT_SEVERITIES);
    defer a.free(s);
    // message 里的 < > & 转义,\n → 空格。
    try testing.expect(std.mem.indexOf(u8, s, "&lt;script&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<script>") == null); // 无裸标签
    try testing.expect(std.mem.indexOf(u8, s, "\n newline") == null or std.mem.indexOf(u8, s, "newline") != null);
    // file 属性:引号转义,防破坏 file="..."
    try testing.expect(std.mem.indexOf(u8, s, "&quot;&gt;&lt;script&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, s, "file=\"a\"><script>") == null); // 无属性逃逸
}

test "reportForFile: 每文件 caps 20 + more" {
    const a = testing.allocator;
    var diags: [25]Diagnostic = undefined;
    for (&diags, 0..) |*d, i| d.* = .{ .severity = .err, .line = @intCast(i), .col = 0, .end_line = @intCast(i), .end_col = 1, .message = "e" };
    const s = try reportForFile(a, "x.py", &diags, &DEFAULT_SEVERITIES);
    defer a.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "... and 5 more") != null); // 25-20=5
}

test "sanitizeField: 多字节 UTF-8 截断在码点边界(不产坏字节)" {
    const a = testing.allocator;
    // message 由多个 3 字节 CJK 组成,limit 落在某个码点中间——输出必须仍是合法 UTF-8。
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(a);
    var i: usize = 0;
    while (i < 200) : (i += 1) try msg.appendSlice(a, "中"); // 每个 3 字节
    const diags = [_]Diagnostic{
        .{ .severity = .err, .line = 0, .col = 0, .end_line = 0, .end_col = 1, .message = msg.items },
    };
    const s = try reportForFile(a, "x.zig", &diags, &DEFAULT_SEVERITIES);
    defer a.free(s);
    // 整块输出必须是合法 UTF-8(证明没在 CJK 中间切出半个码点)。
    try testing.expect(std.unicode.utf8ValidateSlice(s));
    try testing.expect(std.mem.indexOf(u8, s, "…") != null); // 截断标记在
}

test "sanitizeField: malformed UTF-8 becomes replacement characters" {
    const a = testing.allocator;
    const diags = [_]Diagnostic{
        .{ .severity = .err, .line = 0, .col = 0, .end_line = 0, .end_col = 1, .message = "bad\xe4\x60\x80tail" },
    };
    const s = try reportForFile(a, "x.zig", &diags, &DEFAULT_SEVERITIES);
    defer a.free(s);
    try testing.expect(std.unicode.utf8ValidateSlice(s));
    try testing.expect(std.mem.indexOf(u8, s, "bad�`�tail") != null);
}

test "truncate: 超 4000 截断 + 标记" {
    const a = testing.allocator;
    const big = try a.alloc(u8, 5000);
    defer a.free(big);
    @memset(big, 'x');
    const s = try truncate(a, big);
    defer a.free(s);
    try testing.expect(s.len < 5000);
    try testing.expect(std.mem.endsWith(u8, s, "…[truncated]"));
    // 未超则原样。
    const small = try truncate(a, "short");
    defer a.free(small);
    try testing.expectEqualStrings("short", small);
}
