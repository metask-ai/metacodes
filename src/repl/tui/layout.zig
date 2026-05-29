//! 渲染辅助函数(渲染工具集,不是 widget 框架)。
//!
//! 设计原则(TUI_COMPONENTS.md §四):
//! - 不引入 Box/Flex widget 树
//! - 提供"一次完成一件事"的工具函数:centerLine / truncate / wrapLines / drawBox / hcat
//! - 组件按需调用,自己组织布局
//!
//! UTF-8 + CJK 全角宽度计算复用 term.zig 的 displayWidth。
//!
//! ANSI 处理策略(本期):
//! - centerLine / truncate:**假设输入无 ANSI**(调用方自己加),按字节宽度处理
//! - wrapLines:同上(纯文本折行)
//! - drawBox:输入内容也假设无 ANSI(简化);标题/边框自己加色
//! 完整 ANSI 感知的实现留 P2 优化(`strip_ansi.zig`)。

const std = @import("std");
const term = @import("term.zig");
const ansi = @import("ansi.zig");
const Theme = @import("theme.zig").Theme;

// ============================================================================
// 单行操作:截断 / 居中
// ============================================================================

/// 按显示宽度截断字符串,超出加 ellipsis(默认 "…")。
/// 不超出原样返回(借用 s)。超出则分配 new buffer,caller free。
/// max_cols < ellipsis 宽度时返回空字符串。
pub fn truncate(alloc: std.mem.Allocator, s: []const u8, max_cols: usize, ellipsis: []const u8) ![]const u8 {
    const w = term.displayWidth(s);
    if (w <= max_cols) return s; // 不超就借用

    const ell_w = term.displayWidth(ellipsis);
    if (max_cols < ell_w) return try alloc.dupe(u8, "");

    const want_cols = max_cols - ell_w;
    // 找到 s 中显示宽度刚好 ≤ want_cols 的字节切片
    var byte_end: usize = 0;
    var cols: usize = 0;
    while (byte_end < s.len) {
        const next = nextCharBytes(s, byte_end);
        const ch_w = term.displayWidth(s[byte_end..byte_end + next]);
        if (cols + ch_w > want_cols) break;
        cols += ch_w;
        byte_end += next;
    }
    var out = try alloc.alloc(u8, byte_end + ellipsis.len);
    @memcpy(out[0..byte_end], s[0..byte_end]);
    @memcpy(out[byte_end..], ellipsis);
    return out;
}

/// 把 s 按显示宽度居中到 total_cols 列,左右填充空格。
/// 总宽不够时(s 已经太宽)原样返回。caller free。
pub fn centerLine(alloc: std.mem.Allocator, s: []const u8, total_cols: usize) ![]const u8 {
    const w = term.displayWidth(s);
    if (w >= total_cols) return try alloc.dupe(u8, s);
    const left = (total_cols - w) / 2;
    const right = total_cols - w - left;
    var out = try alloc.alloc(u8, left + s.len + right);
    @memset(out[0..left], ' ');
    @memcpy(out[left .. left + s.len], s);
    @memset(out[left + s.len ..], ' ');
    return out;
}

// ============================================================================
// 多行操作:折行
// ============================================================================

/// 按 cols 折行(简单字符级,不做单词边界)。换行符 `\n` 强制断行。
/// 返回行数组(各行 borrow s 的字节范围,无新分配——除了顶层 slice 本身)。
pub fn wrapLines(alloc: std.mem.Allocator, s: []const u8, cols: usize) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(alloc);

    if (cols == 0) {
        try lines.append(alloc, s);
        return try lines.toOwnedSlice(alloc);
    }

    var line_start: usize = 0;
    var i: usize = 0;
    var cur_cols: usize = 0;
    while (i < s.len) {
        if (s[i] == '\n') {
            try lines.append(alloc, s[line_start..i]);
            i += 1;
            line_start = i;
            cur_cols = 0;
            continue;
        }
        const n = nextCharBytes(s, i);
        const ch_w = term.displayWidth(s[i .. i + n]);
        if (cur_cols + ch_w > cols and i > line_start) {
            // 行已满,在 i 处断
            try lines.append(alloc, s[line_start..i]);
            line_start = i;
            cur_cols = ch_w;
            i += n;
            continue;
        }
        cur_cols += ch_w;
        i += n;
    }
    if (line_start < s.len) try lines.append(alloc, s[line_start..]);
    return try lines.toOwnedSlice(alloc);
}

// ============================================================================
// 盒子边框
// ============================================================================

pub const BoxOptions = struct {
    title: []const u8 = "",
    /// 总宽度(包括边框)。0 = 内容最长行 + 2 + padding。
    width: usize = 0,
    /// 左右内边距(空格数)
    padding: usize = 1,
};

/// 绘制带边框的盒子。content 多行用 `\n` 分隔(不是预先分好的数组)。
/// title 空 → 顶边纯横线;非空 → 顶边嵌入 "─ title ─"。
/// 返回的字符串包含 ANSI(边框 = th.dim;title = th.accent + bold)。
/// caller free。
pub fn drawBox(alloc: std.mem.Allocator, th: Theme, content: []const u8, opts: BoxOptions) ![]u8 {
    // 算内容各行 + 最长行宽
    const lines = try wrapLines(alloc, content, if (opts.width == 0) std.math.maxInt(usize) else opts.width);
    defer alloc.free(lines);

    var max_w: usize = 0;
    for (lines) |ln| {
        const w = term.displayWidth(ln);
        if (w > max_w) max_w = w;
    }
    const title_w = term.displayWidth(opts.title);
    if (title_w + 4 > max_w) max_w = title_w + 4; // 标题至少要装得下:"╭─ TITLE ─...╮"

    const inner_w = max_w + opts.padding * 2;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    // ---- 顶边 ----
    try out.appendSlice(alloc, th.dim);
    try out.appendSlice(alloc, th.box_tl);
    if (opts.title.len == 0) {
        var i: usize = 0;
        while (i < inner_w) : (i += 1) try out.appendSlice(alloc, th.box_h);
    } else {
        // "╭─ title " + padding 横线 + "╮"
        try out.appendSlice(alloc, th.box_h);
        try out.append(alloc, ' ');
        try out.appendSlice(alloc, th.reset);
        try out.appendSlice(alloc, th.accent);
        try out.appendSlice(alloc, opts.title);
        try out.appendSlice(alloc, th.reset);
        try out.appendSlice(alloc, th.dim);
        try out.append(alloc, ' ');
        var used: usize = 2 + title_w + 2; // "─ title "
        while (used < inner_w) : (used += 1) try out.appendSlice(alloc, th.box_h);
    }
    try out.appendSlice(alloc, th.box_tr);
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, '\n');

    // ---- 内容行 ----
    for (lines) |ln| {
        try out.appendSlice(alloc, th.dim);
        try out.appendSlice(alloc, th.box_v);
        try out.appendSlice(alloc, th.reset);
        // 左 padding
        var p: usize = 0;
        while (p < opts.padding) : (p += 1) try out.append(alloc, ' ');
        try out.appendSlice(alloc, ln);
        // 右 padding 补齐到 inner_w(行宽)
        const ln_w = term.displayWidth(ln);
        const pad_r = (inner_w - opts.padding) - ln_w; // 已 padding 左 1,内容右还需 inner_w - left_pad - ln_w
        var pr: usize = 0;
        while (pr < pad_r) : (pr += 1) try out.append(alloc, ' ');
        try out.appendSlice(alloc, th.dim);
        try out.appendSlice(alloc, th.box_v);
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');
    }

    // ---- 底边 ----
    try out.appendSlice(alloc, th.dim);
    try out.appendSlice(alloc, th.box_bl);
    var i: usize = 0;
    while (i < inner_w) : (i += 1) try out.appendSlice(alloc, th.box_h);
    try out.appendSlice(alloc, th.box_br);
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, '\n');

    return try out.toOwnedSlice(alloc);
}

// ============================================================================
// 工具:UTF-8 单字符字节长度
// ============================================================================

fn nextCharBytes(s: []const u8, i: usize) usize {
    if (i >= s.len) return 0;
    const b = s[i];
    if (b < 0x80) return 1;
    if (b & 0b1110_0000 == 0b1100_0000) return @min(2, s.len - i);
    if (b & 0b1111_0000 == 0b1110_0000) return @min(3, s.len - i);
    if (b & 0b1111_1000 == 0b1111_0000) return @min(4, s.len - i);
    return 1;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const theme = @import("theme.zig");

test "truncate: 不超长返回原串" {
    const r = try truncate(testing.allocator, "hello", 10, "…");
    // 不超长时函数返回 borrow,但我们不能 free borrow → 用 expect 而非 free
    try testing.expectEqualStrings("hello", r);
}

test "truncate: 超长加省略号" {
    const r = try truncate(testing.allocator, "hello world", 7, "...");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("hell...", r);
}

test "truncate: CJK 全角正确截断" {
    const r = try truncate(testing.allocator, "你好世界abc", 6, "..");
    defer testing.allocator.free(r);
    // "你好" = 4 列 + ".." = 2 列 = 6 列。但 "你好世" = 6 列也行,无 padding 给省略号。
    // want_cols = 6 - 2 = 4,所以 "你好"(4 列)+ ".."
    try testing.expectEqualStrings("你好..", r);
}

test "centerLine: 居中" {
    const r = try centerLine(testing.allocator, "hi", 10);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("    hi    ", r);
}

test "centerLine: 奇数差额右侧多一格" {
    const r = try centerLine(testing.allocator, "hi", 9);
    defer testing.allocator.free(r);
    // left = (9-2)/2 = 3, right = 9-2-3 = 4
    try testing.expectEqualStrings("   hi    ", r);
}

test "wrapLines: 简单折行" {
    const lines = try wrapLines(testing.allocator, "hello world foobar", 6);
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("hello ", lines[0]);
    try testing.expectEqualStrings("world ", lines[1]);
    try testing.expectEqualStrings("foobar", lines[2]);
}

test "wrapLines: 换行符强制断行" {
    const lines = try wrapLines(testing.allocator, "ab\ncd", 100);
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("ab", lines[0]);
    try testing.expectEqualStrings("cd", lines[1]);
}

test "drawBox: monochrome 主题输出形状正确" {
    const t = theme.monochrome;
    const s = try drawBox(testing.allocator, t, "hi\nbye", .{ .title = "T", .width = 10, .padding = 1 });
    defer testing.allocator.free(s);
    // 期望(monochrome = 全 ASCII,无 ANSI):
    //   +- T --+
    //   | hi   |
    //   | bye  |
    //   +------+
    try testing.expect(std.mem.indexOf(u8, s, "+") != null);
    try testing.expect(std.mem.indexOf(u8, s, "T") != null);
    try testing.expect(std.mem.indexOf(u8, s, "| hi") != null);
    try testing.expect(std.mem.indexOf(u8, s, "| bye") != null);
    // 不应含任何 \x1b(monochrome 主题颜色字段全空)
    try testing.expect(std.mem.indexOf(u8, s, "\x1b") == null);
}

test "drawBox: dark 主题含 ANSI" {
    const t = theme.dark;
    const s = try drawBox(testing.allocator, t, "x", .{ .title = "", .width = 5, .padding = 0 });
    defer testing.allocator.free(s);
    // dark 主题边框走 th.dim = "\x1b[2m"
    try testing.expect(std.mem.indexOf(u8, s, "\x1b[2m") != null);
    try testing.expect(std.mem.indexOf(u8, s, "╭") != null);
    try testing.expect(std.mem.indexOf(u8, s, "╯") != null);
}
