//! 语法高亮数据模型:按行的高亮索引(Highlights)+ 组(Group)+ 行内区间(Span)。
//!
//! Y2 砍 tree-sitter 后,唯一的高亮产出方是 hl-zig(见 hl_adapter.zig)——本文件只保留**类型**
//! (tree-sitter 版 highlightFile/query 已随 grammar 删除)。tool_card 的 diff 着色消费这些类型。
const std = @import("std");

/// 高亮组(下游 groupColor 映射到 ANSI 颜色)。hl-zig 只产 keyword/string/comment/number/none;
/// 其余组保留是历史 tree-sitter 的更细分类,当前无产出方,留作类型完整(groupColor 仍映射)。
pub const Group = enum(u8) {
    none = 0,
    keyword,
    string,
    comment,
    number,
    function,
    type,
    constant,
    variable,
    operator,
    punctuation,
};

/// 行内字节区间 + 高亮组。start/end 是相对**行首**的字节偏移。
pub const Span = struct { start: u32, end: u32, group: Group };

pub const Highlights = struct {
    arena: std.heap.ArenaAllocator,
    source: []const u8, // dup 的全文(line_text 借它)
    line_spans: [][]Span, // 0-based 行索引 → 该行有序 span
    line_text: [][]const u8, // 0-based 行索引 → 该行原文(不含 \n)

    pub fn deinit(self: *Highlights) void {
        self.arena.deinit();
    }

    /// 1-based 行号 → 该行 span(越界返回空)。
    pub fn spansForLine(self: *const Highlights, line_1based: usize) []const Span {
        if (line_1based == 0 or line_1based > self.line_spans.len) return &.{};
        return self.line_spans[line_1based - 1];
    }

    /// 1-based 行号 → 该行原文(越界返回 null)。供 diff 行比对校验。
    pub fn textForLine(self: *const Highlights, line_1based: usize) ?[]const u8 {
        if (line_1based == 0 or line_1based > self.line_text.len) return null;
        return self.line_text[line_1based - 1];
    }
};

test "Highlights spansForLine/textForLine 边界" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const a = arena.allocator();
    var spans = try a.alloc([]Span, 1);
    spans[0] = try a.alloc(Span, 1);
    spans[0][0] = .{ .start = 0, .end = 3, .group = .keyword };
    var texts = try a.alloc([]const u8, 1);
    texts[0] = "abc";
    var hl = Highlights{ .arena = arena, .source = "abc\n", .line_spans = spans, .line_text = texts };
    defer hl.deinit();
    try std.testing.expectEqual(@as(usize, 1), hl.spansForLine(1).len);
    try std.testing.expectEqual(@as(usize, 0), hl.spansForLine(2).len); // 越界
    try std.testing.expectEqualStrings("abc", hl.textForLine(1).?);
    try std.testing.expect(hl.textForLine(0) == null);
}
