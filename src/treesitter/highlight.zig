//! tree-sitter 整文件语法高亮 → 按行 token 区间索引。供 Edit/Write diff 着色。
//!
//! 为什么按行索引:diff 逐行渲染单行片段,而 tree-sitter 要整文件上下文才能正确解析。
//! 解法:解析整文件一次 → 每行存"该行各 token 的 (字节区间, 高亮组)" → 渲染时按行号查。
//!
//! Paint-buffer 算法规避 capture 重叠/嵌套(tree-sitter query 会产生嵌套 capture,
//! 如 call 里的函数名):先把每个 capture 的字节涂成对应 group(后写覆盖 = "last wins",
//! highlights.scm 里更具体的 pattern 通常在后,自然更精确),再按行合并连续同 group 成 span。
const std = @import("std");
const ts = @import("ts.zig");
const registry = @import("registry.zig");

/// 高亮组(颜色由渲染层 groupColor 映射)。
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

/// tree-sitter capture 名 → Group(前缀匹配)。
/// "keyword.return"→keyword,"string.escape"→string,"function.builtin"→function…
/// 未知 capture → none(不上色)。
pub fn groupFromCapture(name: []const u8) Group {
    const Pair = struct { p: []const u8, g: Group };
    // 顺序:更长/更具体前缀在前,避免 "constant" 抢 "constructor"。这里用精确段前缀。
    const table = [_]Pair{
        .{ .p = "keyword", .g = .keyword },
        .{ .p = "string", .g = .string },
        .{ .p = "character", .g = .string },
        .{ .p = "comment", .g = .comment },
        .{ .p = "number", .g = .number },
        .{ .p = "boolean", .g = .constant },
        .{ .p = "float", .g = .number },
        .{ .p = "function", .g = .function },
        .{ .p = "method", .g = .function },
        .{ .p = "constructor", .g = .type },
        .{ .p = "type", .g = .type },
        .{ .p = "constant", .g = .constant },
        .{ .p = "variable", .g = .variable },
        .{ .p = "property", .g = .variable },
        .{ .p = "parameter", .g = .variable },
        .{ .p = "operator", .g = .operator },
        .{ .p = "punctuation", .g = .punctuation },
        .{ .p = "label", .g = .constant },
        .{ .p = "module", .g = .type },
    };
    for (table) |e| {
        if (std.mem.startsWith(u8, name, e.p)) return e.g;
    }
    return .none;
}

/// 覆盖优先级:cursor match 顺序不定,用它仲裁同字节多 capture。
/// none 最低(0);variable 次低(1,通用兜底,不盖具体语义);其余具体组同高(2)。
/// 这样 `(identifier) @variable` 绝不覆盖 @function/@type/@constant 等精确着色。
fn groupPriority(g: Group) u8 {
    return switch (g) {
        .none => 0,
        .variable => 1,
        else => 2,
    };
}

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

fn querySrc(lang: ts.Lang) []const u8 {
    // 由 registry 驱动:按 tag 匹配,嵌入 queries/highlights/<query_name>.scm。
    // inline for 编译期展开;@embedFile 路径 comptime 拼接。
    inline for (registry.LANGS) |spec| {
        if (lang == @field(ts.Lang, spec.tag)) {
            return @embedFile("queries/highlights/" ++ spec.query_name ++ ".scm");
        }
    }
    unreachable; // ts.zig 的 comptime 断言保证覆盖所有 Lang
}

/// 解析整文件 → 按行高亮索引。不支持/parse/query 编译失败 → error(调用方退回关键字表)。
pub fn highlightFile(gpa: std.mem.Allocator, source: []const u8, lang: ts.Lang) !Highlights {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // 1) paint buffer:每字节一个 Group,初始 none。用 gpa(临时,函数内释放)。
    const paint = try gpa.alloc(Group, source.len);
    defer gpa.free(paint);
    @memset(paint, .none);

    {
        var parser = try ts.Parser.init(lang);
        defer parser.deinit();
        var tree = try parser.parse(source);
        defer tree.deinit();
        var query = try ts.Query.init(lang, querySrc(lang));
        defer query.deinit();
        var cursor = ts.Cursor.init();
        defer cursor.deinit();
        cursor.exec(&query, tree.root());

        // 2) 遍历每个 match 的每个 capture,涂字节。
        // 跳过带过滤 predicate(?结尾,如 #match?/#eq?)的 pattern:基础 cursor 不求值它们,
        // 这类 pattern 会无条件命中(python `((identifier) @constant (#match? "^[A-Z_]+$"))`
        // 会把所有 identifier 染成 constant)。保留 directive(#set! 等)。
        // **优先级覆盖**(非"后写覆盖"):cursor 返回 match 的顺序按节点位置而非 pattern 文件
        // 顺序,故同一字节会被宽松规则((identifier) @variable)和精确规则(@function/@type)
        // 各命中一次,顺序不定。用 priority 仲裁:variable/none 最低,绝不覆盖已painted的
        // function/type/keyword 等(对齐 tree-sitter-highlight "specific wins")。
        while (cursor.nextMatch()) |m| {
            if (query.patternHasFilterPredicate(m.pattern_index)) continue;
            const caps = m.captures[0..m.capture_count];
            for (caps) |cap| {
                const g = groupFromCapture(query.captureName(cap.index));
                if (g == .none) continue;
                const node = ts.Node{ .raw = cap.node };
                const s = node.startByte();
                const e = node.endByte();
                if (s >= e or e > source.len) continue;
                const gp = groupPriority(g);
                var i: usize = s;
                while (i < e) : (i += 1) {
                    // 仅当新 group 优先级 >= 已有,才覆盖(同级允许覆盖=同位置后到的精确规则;
                    // 但 variable 这类低优先级绝不盖 function/type)。
                    if (gp >= groupPriority(paint[i])) paint[i] = g;
                }
            }
        }
    }

    // 3) 按行切 source,每行内合并连续同 group(非 none)成 span。
    var spans_list: std.ArrayList([]Span) = .empty;
    defer spans_list.deinit(gpa);
    var text_list: std.ArrayList([]const u8) = .empty;
    defer text_list.deinit(gpa);

    const src_owned = try a.dupe(u8, source);

    var line_start: usize = 0;
    while (line_start <= src_owned.len) {
        const nl = std.mem.indexOfScalarPos(u8, src_owned, line_start, '\n') orelse src_owned.len;
        const line = src_owned[line_start..nl];

        // 该行的 span:扫 paint[line_start..nl],合并连续同 group。
        var row_spans: std.ArrayList(Span) = .empty;
        defer row_spans.deinit(gpa);
        var col: usize = 0;
        while (col < line.len) {
            const g = paint[line_start + col];
            if (g == .none) {
                col += 1;
                continue;
            }
            const run_start = col;
            while (col < line.len and paint[line_start + col] == g) : (col += 1) {}
            try row_spans.append(gpa, .{ .start = @intCast(run_start), .end = @intCast(col), .group = g });
        }

        try spans_list.append(gpa, try a.dupe(Span, row_spans.items));
        try text_list.append(gpa, line);

        if (nl >= src_owned.len) break;
        line_start = nl + 1;
    }

    // 注意:必须在 return 前完成所有 arena 分配。`return X{.arena=arena, .f=a.dupe(...)}`
    // 里字段求值顺序会先**值拷贝** arena 再跑 dupe → dupe 进了局部 arena(拷贝后),
    // 返回的拷贝不含该分配 → 泄漏。故先 dupe 到局部变量。
    const line_spans = try a.dupe([]Span, spans_list.items);
    const line_text = try a.dupe([]const u8, text_list.items);

    return Highlights{
        .arena = arena,
        .source = src_owned,
        .line_spans = line_spans,
        .line_text = line_text,
    };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------
const testing = std.testing;

/// 找 line(1-based)上覆盖 [需 col_start..] 的 span 的 group;辅助断言。
fn groupAt(hl: *const Highlights, line: usize, col: u32) Group {
    for (hl.spansForLine(line)) |s| {
        if (col >= s.start and col < s.end) return s.group;
    }
    return .none;
}

test "groupFromCapture 前缀映射" {
    try testing.expectEqual(Group.keyword, groupFromCapture("keyword.return"));
    try testing.expectEqual(Group.string, groupFromCapture("string.escape"));
    try testing.expectEqual(Group.function, groupFromCapture("function.builtin"));
    try testing.expectEqual(Group.type, groupFromCapture("type.builtin"));
    try testing.expectEqual(Group.comment, groupFromCapture("comment.documentation"));
    try testing.expectEqual(Group.number, groupFromCapture("number"));
    try testing.expectEqual(Group.none, groupFromCapture("spell"));
}

test "zig: const=keyword, 42=number, 字符串=string, 注释=comment" {
    const src = "const x = 42; // note\nconst s = \"hi\";\n";
    var hl = try highlightFile(testing.allocator, src, .zig);
    defer hl.deinit();

    // line 1: "const x = 42; // note"
    try testing.expectEqual(Group.keyword, groupAt(&hl, 1, 0)); // const
    // 42 在 "const x = " 之后,偏移 10-11
    try testing.expectEqual(Group.number, groupAt(&hl, 1, 10));
    // 注释 "// note" 偏移 14+
    try testing.expectEqual(Group.comment, groupAt(&hl, 1, 14));
    // line 2: 字符串 "hi"
    try testing.expectEqual(Group.string, groupAt(&hl, 2, 10));
}

test "predicate-gated capture 不过度着色(tty 实测回归:python/c identifier 不应变 constant)" {
    // 根因:python/c highlights.scm 的 `((identifier) @constant (#match? "^[A-Z_]+"))`
    // 等 predicate 规则,基础 cursor 不求值 #match? → 会无条件染中所有 identifier。
    // 修复:跳过带过滤 predicate 的 pattern。此测试钉住 identifier=variable 而非 constant。
    {
        var hl = try highlightFile(testing.allocator, "x = 42\nprint(x)\n", .python);
        defer hl.deinit();
        // x、print 是普通标识符 → variable(绝不能是 constant)。
        try testing.expectEqual(Group.variable, groupAt(&hl, 1, 0)); // x
        try testing.expect(groupAt(&hl, 2, 0) != Group.constant); // print 不是 constant
        try testing.expectEqual(Group.number, groupAt(&hl, 1, 4)); // 42 仍是 number
    }
    {
        var hl = try highlightFile(testing.allocator, "int foo = 5;\n", .c);
        defer hl.deinit();
        try testing.expect(groupAt(&hl, 1, 4) != Group.constant); // foo 不是 constant
        try testing.expectEqual(Group.number, groupAt(&hl, 1, 10)); // 5 是 number
    }
    {
        // zig @string 用 #set! priority(directive 非过滤 predicate)→ 不应被跳过。
        var hl = try highlightFile(testing.allocator, "const s = \"hi\";\n", .zig);
        defer hl.deinit();
        try testing.expectEqual(Group.string, groupAt(&hl, 1, 10)); // "hi" 仍着色
    }
}

test "优先级覆盖:variable 不盖 function/type(tty 实测回归:Write/diff 颜色丰富度)" {
    // 根因:cursor match 返回顺序按节点位置非 pattern 文件顺序,通用 (identifier) @variable
    // 可能**后于**精确 @function/@type 命中同字节 → 纯"后写覆盖"把 function/type 染回 variable
    // (Write 一个 .py 时所有标识符全成蓝 variable,颜色看着很少)。修:groupPriority 仲裁,
    // variable 最低不盖具体组。
    var hl = try highlightFile(testing.allocator, "def greet(name: str) -> str:\n    pass\n", .python);
    defer hl.deinit();
    // greet=function(定义名),str=type(注解),name=variable。
    try testing.expectEqual(Group.function, groupAt(&hl, 1, 4)); // greet
    try testing.expectEqual(Group.type, groupAt(&hl, 1, 17)); // str(第一个)
    try testing.expectEqual(Group.variable, groupAt(&hl, 1, 10)); // name
}

test "textForLine 与 spansForLine 行号对齐(1-based)" {
    const src = "line1\nline2\nline3\n";
    var hl = try highlightFile(testing.allocator, src, .zig);
    defer hl.deinit();
    try testing.expectEqualStrings("line1", hl.textForLine(1).?);
    try testing.expectEqualStrings("line2", hl.textForLine(2).?);
    try testing.expectEqualStrings("line3", hl.textForLine(3).?);
    try testing.expect(hl.textForLine(0) == null);
    try testing.expect(hl.textForLine(99) == null);
}

test "多行块注释按行切分(每行各自成 comment span)" {
    // c 块注释跨 3 行
    const src = "int a;\n/* multi\n   line */\nint b;\n";
    var hl = try highlightFile(testing.allocator, src, .c);
    defer hl.deinit();
    // line 2 "/* multi" 应有 comment span
    try testing.expectEqual(Group.comment, groupAt(&hl, 2, 0));
    // line 3 "   line */" 末尾 comment
    try testing.expectEqual(Group.comment, groupAt(&hl, 3, 5));
}

test "python: def=keyword, 数字=number, 字符串=string" {
    const src = "def f():\n    return 99\nx = \"hi\"\n";
    var hl = try highlightFile(testing.allocator, src, .python);
    defer hl.deinit();
    try testing.expectEqual(Group.keyword, groupAt(&hl, 1, 0)); // def
    try testing.expectEqual(Group.number, groupAt(&hl, 2, 11)); // 99
    try testing.expectEqual(Group.string, groupAt(&hl, 3, 4)); // "hi"
}

test "typescript: function/const 关键字着色" {
    const src = "function f() {}\nconst x = 1;\n";
    var hl = try highlightFile(testing.allocator, src, .typescript);
    defer hl.deinit();
    try testing.expectEqual(Group.keyword, groupAt(&hl, 1, 0)); // function
    try testing.expectEqual(Group.keyword, groupAt(&hl, 2, 0)); // const
}

test "tsx: JSX 不破坏高亮(const/number)" {
    const src = "const App = () => <div>1</div>;\nconst n = 42;\n";
    var hl = try highlightFile(testing.allocator, src, .tsx);
    defer hl.deinit();
    try testing.expectEqual(Group.keyword, groupAt(&hl, 1, 0)); // const
    try testing.expectEqual(Group.number, groupAt(&hl, 2, 10)); // 42
}

test "bash: 注释 + 字符串" {
    const src = "# comment\nX=\"val\"\n";
    var hl = try highlightFile(testing.allocator, src, .bash);
    defer hl.deinit();
    try testing.expectEqual(Group.comment, groupAt(&hl, 1, 0));
}

test "空文件 → 1 行空 span,不崩,无泄漏" {
    var hl = try highlightFile(testing.allocator, "", .zig);
    defer hl.deinit();
    // 空 source:line_text 应有 1 个空行
    try testing.expect(hl.line_spans.len >= 1);
    try testing.expectEqual(@as(usize, 0), hl.spansForLine(1).len);
}
