//! tree-sitter C API 的 Zig FFI 封装。
//!
//! tree-sitter 是 C 库,静态编译进二进制(见 build.zig addTreeSitter)。
//! 本模块把裸 extern fn 封成 Zig 惯用的 Parser/Tree/Node/Query,带 errdefer 清理。
//!
//! ABI 注意(Zig 0.16 C-interop):
//!   - TSNode 按值传 → 必须 extern struct,字段对齐 api.h(context[4]+id+tree = 32 字节)。
//!   - 不透明类型(TSParser 等)用 opaque{} + 指针。
//!   - ts_node_type 返回 [*:0]const u8 → std.mem.span 转 slice。
//!   - 节点 row/column 是 0-based;用户可见行号 +1,集中在 symbols.zig 处理。
const std = @import("std");

/// 裸 C API 声明。对齐 vendor/tree-sitter/runtime/include/tree_sitter/api.h。
pub const c = struct {
    pub const TSParser = opaque {};
    pub const TSTree = opaque {};
    pub const TSLanguage = opaque {};
    pub const TSQuery = opaque {};
    pub const TSQueryCursor = opaque {};

    /// 按值传递的节点句柄。布局必须与 api.h 的 `struct TSNode` 完全一致。
    pub const TSNode = extern struct {
        context: [4]u32,
        id: ?*const anyopaque,
        tree: ?*const TSTree,
    };
    pub const TSPoint = extern struct {
        row: u32,
        column: u32,
    };
    pub const TSQueryCapture = extern struct {
        node: TSNode,
        index: u32,
    };
    pub const TSQueryMatch = extern struct {
        id: u32,
        pattern_index: u16,
        capture_count: u16,
        captures: [*]const TSQueryCapture,
    };
    pub const TSQueryError = u32;

    pub const TSQueryPredicateStep = extern struct {
        type: u32, // 0=Done, 1=Capture, 2=String
        value_id: u32,
    };

    // --- parser ---
    pub extern fn ts_parser_new() *TSParser;
    pub extern fn ts_parser_delete(self: *TSParser) void;
    pub extern fn ts_parser_set_language(self: *TSParser, language: *const TSLanguage) bool;
    pub extern fn ts_parser_parse_string(
        self: *TSParser,
        old_tree: ?*const TSTree,
        string: [*]const u8,
        length: u32,
    ) ?*TSTree;

    // --- tree ---
    pub extern fn ts_tree_delete(self: *TSTree) void;
    pub extern fn ts_tree_root_node(self: *const TSTree) TSNode;

    // --- node ---
    pub extern fn ts_node_type(node: TSNode) [*:0]const u8;
    pub extern fn ts_node_start_byte(node: TSNode) u32;
    pub extern fn ts_node_end_byte(node: TSNode) u32;
    pub extern fn ts_node_start_point(node: TSNode) TSPoint;
    pub extern fn ts_node_end_point(node: TSNode) TSPoint;
    pub extern fn ts_node_is_null(node: TSNode) bool;
    pub extern fn ts_node_named_child_count(node: TSNode) u32;
    pub extern fn ts_node_named_child(node: TSNode, index: u32) TSNode;
    pub extern fn ts_node_child_by_field_name(node: TSNode, name: [*]const u8, name_length: u32) TSNode;
    pub extern fn ts_node_parent(node: TSNode) TSNode;

    // --- query ---
    pub extern fn ts_query_new(
        language: *const TSLanguage,
        source: [*]const u8,
        source_len: u32,
        error_offset: *u32,
        error_type: *TSQueryError,
    ) ?*TSQuery;
    pub extern fn ts_query_delete(self: *TSQuery) void;
    pub extern fn ts_query_capture_name_for_id(
        self: *const TSQuery,
        index: u32,
        length: *u32,
    ) [*]const u8;
    /// 某 pattern 的 predicate 步骤(用于判断/求值 #match?/#eq? 等)。空 → 无 predicate。
    pub extern fn ts_query_predicates_for_pattern(
        self: *const TSQuery,
        pattern_index: u32,
        step_count: *u32,
    ) [*]const TSQueryPredicateStep;
    pub extern fn ts_query_string_value_for_id(
        self: *const TSQuery,
        id: u32,
        length: *u32,
    ) [*]const u8;
    pub extern fn ts_query_cursor_new() *TSQueryCursor;
    pub extern fn ts_query_cursor_delete(self: *TSQueryCursor) void;
    pub extern fn ts_query_cursor_exec(self: *TSQueryCursor, query: *const TSQuery, node: TSNode) void;
    pub extern fn ts_query_cursor_next_match(self: *TSQueryCursor, match: *TSQueryMatch) bool;

    // --- 每语言的 language() 入口(由各 grammar 的 parser.c 导出) ---
    pub extern fn tree_sitter_zig() *const TSLanguage;
    pub extern fn tree_sitter_typescript() *const TSLanguage;
    pub extern fn tree_sitter_tsx() *const TSLanguage;
    pub extern fn tree_sitter_python() *const TSLanguage;
    pub extern fn tree_sitter_c() *const TSLanguage;
    pub extern fn tree_sitter_bash() *const TSLanguage;
};

// ABI 守卫:布局漂移(grammar/runtime 升级)立即编译失败,而非运行时神秘崩溃。
comptime {
    std.debug.assert(@sizeOf(c.TSNode) == 32); // [4]u32(16) + *id(8) + *tree(8)
}

pub const Error = error{
    SetLanguageFailed,
    ParseFailed,
    SourceTooLarge,
    QueryCompileFailed,
};

/// 支持的语言。enum → extern language fn + 扩展名探测。
pub const Lang = enum {
    zig,
    typescript,
    tsx,
    python,
    c,
    bash,

    pub fn language(self: Lang) *const c.TSLanguage {
        return switch (self) {
            .zig => c.tree_sitter_zig(),
            .typescript => c.tree_sitter_typescript(),
            .tsx => c.tree_sitter_tsx(),
            .python => c.tree_sitter_python(),
            .c => c.tree_sitter_c(),
            .bash => c.tree_sitter_bash(),
        };
    }

    pub fn name(self: Lang) []const u8 {
        return @tagName(self);
    }

    /// 按文件扩展名推断语言;不支持返回 null。
    pub fn fromPath(path: []const u8) ?Lang {
        const ext = std.fs.path.extension(path);
        if (ext.len == 0) return null;
        const Pair = struct { e: []const u8, l: Lang };
        const table = [_]Pair{
            .{ .e = ".zig", .l = .zig },
            .{ .e = ".ts", .l = .typescript },
            .{ .e = ".mts", .l = .typescript },
            .{ .e = ".cts", .l = .typescript },
            .{ .e = ".tsx", .l = .tsx },
            .{ .e = ".jsx", .l = .tsx },
            .{ .e = ".py", .l = .python },
            .{ .e = ".pyi", .l = .python },
            .{ .e = ".c", .l = .c },
            .{ .e = ".h", .l = .c },
            .{ .e = ".sh", .l = .bash },
            .{ .e = ".bash", .l = .bash },
        };
        for (table) |p| {
            if (std.ascii.eqlIgnoreCase(ext, p.e)) return p.l;
        }
        return null;
    }
};

pub const Parser = struct {
    raw: *c.TSParser,

    pub fn init(lang: Lang) Error!Parser {
        const p = c.ts_parser_new();
        errdefer c.ts_parser_delete(p);
        if (!c.ts_parser_set_language(p, lang.language())) return Error.SetLanguageFailed;
        return .{ .raw = p };
    }

    pub fn deinit(self: *Parser) void {
        c.ts_parser_delete(self.raw);
    }

    pub fn parse(self: *Parser, source: []const u8) Error!Tree {
        if (source.len > std.math.maxInt(u32)) return Error.SourceTooLarge;
        const t = c.ts_parser_parse_string(
            self.raw,
            null,
            source.ptr,
            @intCast(source.len),
        ) orelse return Error.ParseFailed;
        return .{ .raw = t };
    }
};

pub const Tree = struct {
    raw: *c.TSTree,

    pub fn deinit(self: *Tree) void {
        c.ts_tree_delete(self.raw);
    }

    pub fn root(self: *const Tree) Node {
        return .{ .raw = c.ts_tree_root_node(self.raw) };
    }

    /// 整棵树是否含语法错误节点(ERROR / MISSING)。
    pub fn hasError(self: *const Tree) bool {
        return self.root().hasErrorDescendant();
    }
};

pub const Node = struct {
    raw: c.TSNode,

    pub fn kind(self: Node) []const u8 {
        return std.mem.span(c.ts_node_type(self.raw));
    }
    /// 0-based 起始行(用户可见需 +1)。
    pub fn startRow(self: Node) u32 {
        return c.ts_node_start_point(self.raw).row;
    }
    pub fn endRow(self: Node) u32 {
        return c.ts_node_end_point(self.raw).row;
    }
    pub fn startByte(self: Node) u32 {
        return c.ts_node_start_byte(self.raw);
    }
    pub fn endByte(self: Node) u32 {
        return c.ts_node_end_byte(self.raw);
    }
    /// 节点覆盖的源码切片(零拷贝,借 source 内存)。
    pub fn text(self: Node, source: []const u8) []const u8 {
        const s = self.startByte();
        const e = self.endByte();
        if (s > source.len or e > source.len or s > e) return "";
        return source[s..e];
    }
    pub fn isNull(self: Node) bool {
        return c.ts_node_is_null(self.raw);
    }
    pub fn namedChildCount(self: Node) u32 {
        return c.ts_node_named_child_count(self.raw);
    }
    pub fn namedChild(self: Node, index: u32) Node {
        return .{ .raw = c.ts_node_named_child(self.raw, index) };
    }
    pub fn childByField(self: Node, field: []const u8) ?Node {
        const n = c.ts_node_child_by_field_name(self.raw, field.ptr, @intCast(field.len));
        return if (c.ts_node_is_null(n)) null else Node{ .raw = n };
    }
    pub fn parent(self: Node) ?Node {
        const n = c.ts_node_parent(self.raw);
        return if (c.ts_node_is_null(n)) null else Node{ .raw = n };
    }

    fn hasErrorDescendant(self: Node) bool {
        const k = self.kind();
        if (std.mem.eql(u8, k, "ERROR") or std.mem.eql(u8, k, "MISSING")) return true;
        var i: u32 = 0;
        const n = self.namedChildCount();
        while (i < n) : (i += 1) {
            if (self.namedChild(i).hasErrorDescendant()) return true;
        }
        return false;
    }
};

pub const Query = struct {
    raw: *c.TSQuery,

    pub fn init(lang: Lang, source: []const u8) Error!Query {
        if (source.len > std.math.maxInt(u32)) return Error.QueryCompileFailed;
        var err_offset: u32 = 0;
        var err_type: c.TSQueryError = 0;
        const q = c.ts_query_new(
            lang.language(),
            source.ptr,
            @intCast(source.len),
            &err_offset,
            &err_type,
        ) orelse return Error.QueryCompileFailed;
        return .{ .raw = q };
    }

    pub fn deinit(self: *Query) void {
        c.ts_query_delete(self.raw);
    }

    /// 给定 capture id 返回其名字(借 query 内存)。
    pub fn captureName(self: *const Query, id: u32) []const u8 {
        var len: u32 = 0;
        const ptr = c.ts_query_capture_name_for_id(self.raw, id, &len);
        return ptr[0..len];
    }

    /// 某 pattern 是否带**无法求值的过滤 predicate**(#match?/#eq?/#any-of? 等)。
    /// 区分:`#set!`/`#offset!` 是 directive(设属性,不过滤匹配)→ 不算;只有
    /// 过滤型 predicate 才返回 true。基础 cursor 不求值过滤 predicate,故带这类的
    /// pattern 会无条件命中(python @constant 染中所有 identifier),高亮层据此跳过。
    /// directive-only 的 pattern(如 zig @string 的 #set! priority)正常着色,不跳过。
    pub fn patternHasFilterPredicate(self: *const Query, pattern_index: u32) bool {
        var step_count: u32 = 0;
        const steps = c.ts_query_predicates_for_pattern(self.raw, pattern_index, &step_count);
        if (step_count == 0) return false;
        // predicate 步骤序列:每个 predicate 以一个 String step(predicate 名,如 "match?"
        // / "eq?" / "set!")开头,以 Done(type=0)结尾。检查每个 predicate 名:
        // 以 '!' 结尾 = directive(set!/offset!)→ 不过滤;否则(?结尾)= 过滤 predicate。
        var i: u32 = 0;
        var at_pred_start = true;
        while (i < step_count) : (i += 1) {
            const step = steps[i];
            if (step.type == 0) { // Done:下一个 step 是新 predicate 的名
                at_pred_start = true;
                continue;
            }
            if (at_pred_start) {
                at_pred_start = false;
                // step.type==2(String):predicate/directive 名。
                if (step.type == 2) {
                    var len: u32 = 0;
                    const ptr = c.ts_query_string_value_for_id(self.raw, step.value_id, &len);
                    const name = ptr[0..len];
                    // directive 以 '!' 结尾(set!/offset!);过滤 predicate 以 '?' 结尾。
                    if (name.len > 0 and name[name.len - 1] != '!') return true;
                }
            }
        }
        return false;
    }
};

/// 查询游标:对一棵树跑 query,迭代 match。
pub const Cursor = struct {
    raw: *c.TSQueryCursor,

    pub fn init() Cursor {
        return .{ .raw = c.ts_query_cursor_new() };
    }
    pub fn deinit(self: *Cursor) void {
        c.ts_query_cursor_delete(self.raw);
    }
    pub fn exec(self: *Cursor, query: *const Query, node: Node) void {
        c.ts_query_cursor_exec(self.raw, query.raw, node.raw);
    }
    /// 取下一个 match;无则返回 null。
    pub fn nextMatch(self: *Cursor) ?c.TSQueryMatch {
        var m: c.TSQueryMatch = undefined;
        if (c.ts_query_cursor_next_match(self.raw, &m)) return m;
        return null;
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------
const testing = std.testing;

test "Lang.fromPath 扩展名映射" {
    try testing.expectEqual(Lang.zig, Lang.fromPath("src/main.zig").?);
    try testing.expectEqual(Lang.typescript, Lang.fromPath("a/b.ts").?);
    try testing.expectEqual(Lang.tsx, Lang.fromPath("c.tsx").?);
    try testing.expectEqual(Lang.python, Lang.fromPath("x.py").?);
    try testing.expectEqual(Lang.c, Lang.fromPath("y.c").?);
    try testing.expectEqual(Lang.c, Lang.fromPath("y.h").?);
    try testing.expectEqual(Lang.bash, Lang.fromPath("z.sh").?);
    try testing.expect(Lang.fromPath("README.md") == null);
    try testing.expect(Lang.fromPath("noext") == null);
}

test "parse 干净 Zig 片段 → root=source_file, 无错误" {
    var parser = try Parser.init(.zig);
    defer parser.deinit();
    var tree = try parser.parse("pub fn foo() void {}\n");
    defer tree.deinit();
    const root = tree.root();
    try testing.expectEqualStrings("source_file", root.kind());
    try testing.expect(!tree.hasError());
}

test "parse 破损 Zig 片段 → hasError" {
    var parser = try Parser.init(.zig);
    defer parser.deinit();
    var tree = try parser.parse("pub fn foo( void {{{\n");
    defer tree.deinit();
    try testing.expect(tree.hasError());
}

test "6 语言 language() 入口都非空 + parser 可建" {
    inline for (.{ Lang.zig, Lang.typescript, Lang.tsx, Lang.python, Lang.c, Lang.bash }) |l| {
        var p = try Parser.init(l);
        defer p.deinit();
    }
}
