//! hl-zig → highlight.Highlights 适配器(Y2:替换 tree-sitter diff 高亮)。
//!
//! 用 hl-zig 的 tokenize(4 类 token 状态机:keyword/string/comment/number,200+ 语言,~200KB blob)
//! 产出与 tree-sitter `highlight.highlightFile` **同形状**的按行高亮索引(highlight.Highlights),
//! 下游 renderSpans/groupColor/colorLineContent 完全不变。tree-sitter 的 11 类 Group 里,hl-zig 只产
//! 其中 4 类(function/type/variable 等语义类别不区分——"高亮差不多就行",小二进制换广覆盖)。
//!
//! hl-zig 的 span 会跨行(块注释/多行字符串),本适配器按行 clip(\n 不进 span)。owned:返回的
//! Highlights 全挂在自带 arena,deinit 一次释放(与 tree-sitter 版语义一致)。
const std = @import("std");
const hl = @import("hl");
const highlight = @import("highlight.zig");

/// TokenType(hl-zig 4 类 + none)→ highlight.Group(tree-sitter 子集)。
fn groupFromToken(t: hl.TokenType) highlight.Group {
    return switch (t) {
        .none => .none,
        .keyword => .keyword,
        .string => .string,
        .comment => .comment,
        .number => .number,
    };
}

/// 按文件路径识别语言并整文件高亮。语言不识别/tokenize 失败 → error(调用方退回关键字表)。
pub fn highlightFileByPath(gpa: std.mem.Allocator, source: []const u8, path: []const u8) !highlight.Highlights {
    const rule = ruleForPath(path) orelse return error.UnsupportedLanguage;
    return highlightFileWithRule(gpa, source, rule);
}

/// 按语言名(如 "zig"/"python"/"typescript")高亮。NotebookEdit 等无法从扩展名推断的工具用它。
/// 名不识别 → error。
pub fn highlightFileByName(gpa: std.mem.Allocator, source: []const u8, name: []const u8) !highlight.Highlights {
    const rule = hl.lookupByName(name) orelse return error.UnsupportedLanguage;
    return highlightFileWithRule(gpa, source, rule);
}

/// 文件路径 → hl-zig LangRule(按扩展名)。无扩展名/未知语言 → null。
pub fn ruleForPath(path: []const u8) ?*const hl.LangRule {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    if (dot + 1 >= base.len) return null;
    const ext = base[dot..]; // 含点,如 ".zig"
    return hl.lookupByExtension(ext);
}

pub fn highlightFileWithRule(gpa: std.mem.Allocator, source: []const u8, rule: *const hl.LangRule) !highlight.Highlights {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const src = try a.dupe(u8, source);

    // 1) 切行:line[i] = [start,end)(end 为内容末,不含 \n)。按 \n split → N+1 行。
    var line_starts = std.ArrayList(usize).empty;
    defer line_starts.deinit(gpa);
    var line_ends = std.ArrayList(usize).empty;
    defer line_ends.deinit(gpa);
    {
        var ls: usize = 0;
        var i: usize = 0;
        while (i < src.len) : (i += 1) {
            if (src[i] == '\n') {
                try line_starts.append(gpa, ls);
                try line_ends.append(gpa, i);
                ls = i + 1;
            }
        }
        try line_starts.append(gpa, ls);
        try line_ends.append(gpa, src.len);
    }
    const n_lines = line_starts.items.len;

    // 2) line_text(借 src)。
    const line_text = try a.alloc([]const u8, n_lines);
    for (0..n_lines) |i| line_text[i] = src[line_starts.items[i]..line_ends.items[i]];

    // 3) 每行 span builder(临时用 gpa)。
    const builders = try gpa.alloc(std.ArrayList(highlight.Span), n_lines);
    defer {
        for (builders) |*bld| bld.deinit(gpa);
        gpa.free(builders);
    }
    for (builders) |*bld| bld.* = std.ArrayList(highlight.Span).empty;

    // 4) tokenize 整文件 → 按行 clip(spans 有序,cur_line 单调前进)。
    const spans = hl.tokenize(gpa, src, rule) catch return error.TokenizeFailed;
    defer gpa.free(spans);

    var cur_line: usize = 0;
    for (spans) |sp| {
        const g = groupFromToken(sp.token);
        if (g == .none) continue; // 无色 token 不发 span,渲染层用 base 填空隙
        // sp.text 是 src 的直接切片(见 hl engine),指针差即绝对偏移。
        const abs_start = @intFromPtr(sp.text.ptr) - @intFromPtr(src.ptr);
        const abs_end = abs_start + sp.text.len;
        while (cur_line + 1 < n_lines and abs_start >= line_starts.items[cur_line + 1]) cur_line += 1;
        var L = cur_line;
        while (L < n_lines and line_starts.items[L] < abs_end) : (L += 1) {
            const ls = line_starts.items[L];
            const le = line_ends.items[L]; // 内容末(不含 \n)
            const s = @max(abs_start, ls);
            const e = @min(abs_end, le);
            if (s < e) {
                builders[L].append(gpa, .{ .start = @intCast(s - ls), .end = @intCast(e - ls), .group = g }) catch {};
            }
            if (abs_end <= le) break; // span 在本行内结束
        }
    }

    // 5) 冻结 builders → arena 拥有的 line_spans。
    const line_spans = try a.alloc([]highlight.Span, n_lines);
    for (0..n_lines) |i| line_spans[i] = try a.dupe(highlight.Span, builders[i].items);

    return highlight.Highlights{
        .arena = arena,
        .source = src,
        .line_spans = line_spans,
        .line_text = line_text,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "hl_adapter: 单行 keyword/number 的行相对 span" {
    const a = std.testing.allocator;
    var h = try highlightFileByName(a, "const x = 42;\n", "zig");
    defer h.deinit();
    // 行 1(1-based)= "const x = 42;";应含 const(keyword)+ 42(number)的 span。
    const spans = h.spansForLine(1);
    var has_kw = false;
    var has_num = false;
    for (spans) |s| {
        if (s.group == .keyword and s.start == 0 and s.end == 5) has_kw = true; // "const"
        if (s.group == .number) has_num = true;
    }
    try std.testing.expect(has_kw);
    try std.testing.expect(has_num);
    try std.testing.expectEqualStrings("const x = 42;", h.textForLine(1).?);
}

test "hl_adapter: 跨行块注释按行 clip(\\n 不进 span)" {
    const a = std.testing.allocator;
    // 用 C(有块注释;Zig 只有行注释)。行1: code; 行2-3: 块注释跨行; 行4: code。
    const src = "const int a = 1;\n/* multi\nline comment */\nconst int b = 2;\n";
    var h = try highlightFileByName(a, src, "c");
    defer h.deinit();
    // 行2 = "/* multi";整行是 comment,span 覆盖到行内容末(8 字节),不含 \n。
    const l2 = h.spansForLine(2);
    var l2_comment = false;
    for (l2) |s| {
        if (s.group == .comment) {
            l2_comment = true;
            try std.testing.expect(s.end <= h.textForLine(2).?.len); // 不越过行内容(不含 \n)
        }
    }
    try std.testing.expect(l2_comment);
    // 行3 = "line comment */";续注释,也应有 comment span。
    var l3_comment = false;
    for (h.spansForLine(3)) |s| if (s.group == .comment) {
        l3_comment = true;
    };
    try std.testing.expect(l3_comment);
    // 行4 = "const b = 2;";注释已闭合 → const 是 keyword(证明状态正确恢复)。
    var l4_kw = false;
    for (h.spansForLine(4)) |s| if (s.group == .keyword) {
        l4_kw = true;
    };
    try std.testing.expect(l4_kw);
}

test "hl_adapter: 未知语言 → error(调用方退回关键字表)" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedLanguage, highlightFileByPath(a, "x", "/no/ext/file"));
    try std.testing.expectError(error.UnsupportedLanguage, highlightFileByName(a, "x", "no-such-lang-xyz"));
}
