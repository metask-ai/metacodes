//! Markdown 子集 → ANSI 渲染。
//!
//! 支持：
//! - `**bold**` → ANSI bold
//! - `*italic*` → ANSI italic
//! - `` `code` `` → dim + 灰背景
//! - `### heading` → bold cyan（支持 #/##/###/####）
//! - ```` ```lang\n...\n``` ```` → 代码块（dim，前后换行）
//! - `- item` / `* item` → `  • item`
//!
//! 设计选择（有意保持简单）：
//! - 单遍扫描，不建 AST
//! - 行内 emphasis 解析：遇到 `**` / `*` / `` ` `` 成对配对；不成对按字面输出
//! - 代码块：` ``` ` 独占一行时切换状态
//! - 不支持嵌套 emphasis、表格、引用块——留到未来
//!
//! 调用：`renderToOwned(markdown, allocator) → []u8`

const std = @import("std");

// ANSI 常量
const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const ITALIC = "\x1b[3m";
const CYAN = "\x1b[36m";
const GRAY = "\x1b[90m";

pub fn renderToOwned(md: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var cursor: usize = 0;
    var in_code_block = false;

    while (cursor < md.len) {
        // 行首：找下一行边界
        const line_end = std.mem.indexOfScalarPos(u8, md, cursor, '\n') orelse md.len;
        const line = md[cursor..line_end];
        const next = if (line_end < md.len) line_end + 1 else md.len;

        if (in_code_block) {
            if (std.mem.startsWith(u8, line, "```")) {
                try out.appendSlice(allocator, RESET);
                try out.append(allocator, '\n');
                in_code_block = false;
            } else {
                try out.appendSlice(allocator, GRAY);
                try out.appendSlice(allocator, line);
                try out.appendSlice(allocator, RESET);
                try out.append(allocator, '\n');
            }
        } else if (std.mem.startsWith(u8, line, "```")) {
            // 进入代码块（忽略语言标记）
            try out.appendSlice(allocator, DIM);
            try out.append(allocator, '\n');
            in_code_block = true;
        } else if (isHeading(line)) |h| {
            try renderHeading(line, h, &out, allocator);
            try out.append(allocator, '\n');
        } else if (isListItem(line)) |prefix_len| {
            try out.appendSlice(allocator, "  • ");
            try renderInline(line[prefix_len..], &out, allocator);
            try out.append(allocator, '\n');
        } else {
            try renderInline(line, &out, allocator);
            if (line_end < md.len) try out.append(allocator, '\n');
        }
        cursor = next;
    }

    if (in_code_block) {
        try out.appendSlice(allocator, RESET);
    }

    return try out.toOwnedSlice(allocator);
}

/// 返回 '#' 数量（1-4），非标题返 null。
fn isHeading(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len and i < 5 and line[i] == '#') : (i += 1) {}
    if (i == 0 or i > 4) return null;
    if (i >= line.len or line[i] != ' ') return null;
    return i;
}

/// 返回 list 前缀长度（"- " 或 "* "），非 list 返 null。
fn isListItem(line: []const u8) ?usize {
    if (line.len < 2) return null;
    if ((line[0] == '-' or line[0] == '*') and line[1] == ' ') return 2;
    return null;
}

fn renderHeading(line: []const u8, hash_count: usize, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try out.appendSlice(allocator, BOLD);
    try out.appendSlice(allocator, CYAN);
    try renderInline(line[hash_count + 1 ..], out, allocator);
    try out.appendSlice(allocator, RESET);
}

/// 行内：`**bold**` / `*italic*` / `` `code` ``。成对扫描。
fn renderInline(text: []const u8, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i < text.len) {
        // 代码 `...`
        if (text[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |close| {
                try out.appendSlice(allocator, DIM);
                try out.appendSlice(allocator, text[i + 1 .. close]);
                try out.appendSlice(allocator, RESET);
                i = close + 1;
                continue;
            }
        }

        // 粗体 **...**
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |close| {
                try out.appendSlice(allocator, BOLD);
                try out.appendSlice(allocator, text[i + 2 .. close]);
                try out.appendSlice(allocator, RESET);
                i = close + 2;
                continue;
            }
        }

        // 斜体 *...*（只在不是 ** 的时候）
        if (text[i] == '*' and (i + 1 >= text.len or text[i + 1] != '*')) {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '*')) |close| {
                // 保证不是 ** 的情况
                if (close + 1 >= text.len or text[close + 1] != '*') {
                    try out.appendSlice(allocator, ITALIC);
                    try out.appendSlice(allocator, text[i + 1 .. close]);
                    try out.appendSlice(allocator, RESET);
                    i = close + 1;
                    continue;
                }
            }
        }

        try out.append(allocator, text[i]);
        i += 1;
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "render plain text passes through" {
    const r = try renderToOwned("hello world", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("hello world", r);
}

test "render bold" {
    const r = try renderToOwned("**bold**", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\x1b[1mbold\x1b[0m", r);
}

test "render italic" {
    const r = try renderToOwned("*italic*", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\x1b[3mitalic\x1b[0m", r);
}

test "render code span" {
    const r = try renderToOwned("`x`", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\x1b[2mx\x1b[0m", r);
}

test "render heading level 1" {
    const r = try renderToOwned("# Title", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "\x1b[1m") != null);
    try testing.expect(std.mem.indexOf(u8, r, "\x1b[36m") != null);
    try testing.expect(std.mem.indexOf(u8, r, "Title") != null);
}

test "render heading level 3" {
    const r = try renderToOwned("### Sub", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "Sub") != null);
}

test "render unordered list dash" {
    const r = try renderToOwned("- item", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("  • item\n", r);
}

test "render unordered list asterisk" {
    const r = try renderToOwned("* item", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("  • item\n", r);
}

test "render fenced code block" {
    const md =
        "```zig\n" ++
        "pub fn x() void {}\n" ++
        "```\n";
    const r = try renderToOwned(md, testing.allocator);
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "\x1b[90m") != null); // gray for code line
    try testing.expect(std.mem.indexOf(u8, r, "pub fn x()") != null);
}

test "render multiple paragraphs preserve newlines" {
    const r = try renderToOwned("a\nb\nc", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a\nb\nc", r);
}

test "render mixed bold in text" {
    const r = try renderToOwned("say **hi** now", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "say ") != null);
    try testing.expect(std.mem.indexOf(u8, r, "\x1b[1mhi\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, r, " now") != null);
}

test "render unclosed bold is literal" {
    const r = try renderToOwned("**no close", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("**no close", r);
}

test "render unclosed code span is literal" {
    const r = try renderToOwned("`open", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("`open", r);
}

test "render heading with bold inside" {
    const r = try renderToOwned("## **bold head**", testing.allocator);
    defer testing.allocator.free(r);
    // 会有两层 ANSI（heading + bold）
    try testing.expect(std.mem.indexOf(u8, r, "bold head") != null);
}

test "render empty input" {
    const r = try renderToOwned("", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("", r);
}

test "render trailing newline preserved in plain text" {
    const r = try renderToOwned("line\n", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("line\n", r);
}
