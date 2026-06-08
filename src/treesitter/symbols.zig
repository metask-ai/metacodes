//! 用 tree-sitter Query 从源码抽取符号(函数/类型/常量等)。
//!
//! 查询文件 @embedFile 进二进制(queries/<lang>.scm)。约定:每个 match 含
//! 一个 @name capture(标识符)和一个 @definition.<kind> capture(定义节点);
//! kind 取 capture 名后缀。行号从 0-based 节点 point 转 1-based。
//!
//! 返回的 Symbols 用内部 ArenaAllocator 持有全部 dup 字符串,deinit 一次释放。
const std = @import("std");
const ts = @import("ts.zig");
const registry = @import("registry.zig");

pub const Kind = enum {
    function,
    method,
    @"struct",
    @"enum",
    @"union",
    type,
    constant,
    variable,
    class,
    interface,
    field,
    import,
    @"test",
    other,

    /// 稳定的 JSON/展示名(小写)。
    pub fn jsonName(self: Kind) []const u8 {
        return @tagName(self);
    }

    /// capture 名后缀 → Kind。未知后缀归 .other。
    pub fn fromCapture(suffix: []const u8) Kind {
        const Pair = struct { s: []const u8, k: Kind };
        const table = [_]Pair{
            .{ .s = "function", .k = .function },
            .{ .s = "method", .k = .method },
            .{ .s = "struct", .k = .@"struct" },
            .{ .s = "enum", .k = .@"enum" },
            .{ .s = "union", .k = .@"union" },
            .{ .s = "type", .k = .type },
            .{ .s = "constant", .k = .constant },
            .{ .s = "variable", .k = .variable },
            .{ .s = "class", .k = .class },
            .{ .s = "interface", .k = .interface },
            .{ .s = "field", .k = .field },
            .{ .s = "import", .k = .import },
            .{ .s = "test", .k = .@"test" },
        };
        for (table) |p| {
            if (std.mem.eql(u8, suffix, p.s)) return p.k;
        }
        return .other;
    }

    /// 具体度:去重时同 (line,name) 保留更具体的 kind。
    /// constant/variable/other 最弱(1);泛 type(2);具体容器 struct/enum/union/class/interface
    /// 最强(3)——一个 struct 比泛 "type" 更精确(Go 的 type_spec 同时匹配 struct 与泛 type 时取 struct)。
    fn specificity(self: Kind) u8 {
        return switch (self) {
            .constant, .variable, .other => 1,
            .type => 2,
            .@"struct", .@"enum", .@"union", .class, .interface => 3,
            else => 2,
        };
    }
};

pub const Symbol = struct {
    name: []const u8,
    kind: Kind,
    file: []const u8,
    line_start: u32, // 1-based
    line_end: u32, // 1-based
    signature: []const u8,
    parent: ?[]const u8 = null,
    doc: ?[]const u8 = null,
    lang: ts.Lang,
};

pub const Symbols = struct {
    items: []Symbol,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Symbols) void {
        self.arena.deinit();
    }
};

fn querySrc(lang: ts.Lang) []const u8 {
    // 由 registry 驱动:仅 has_symbols 的语言嵌入 queries/<query_name>.scm。
    // 无 symbols 查询的语言返回 ""(extractSymbols 的 Query.init 会失败→空符号→CodeMap fallback)。
    inline for (registry.LANGS) |spec| {
        if (lang == @field(ts.Lang, spec.tag)) {
            if (spec.has_symbols) return @embedFile("queries/" ++ spec.query_name ++ ".scm");
            return "";
        }
    }
    unreachable;
}

// 收集阶段的临时记录(借 source/tree 内存,尚未 dup)。
const Raw = struct {
    name: []const u8,
    kind: Kind,
    def_start_byte: u32,
    def_end_byte: u32,
    line_start: u32,
    line_end: u32,
    signature: []const u8,
    dropped: bool = false,
};

/// 从 source 抽取 lang 的符号。file 仅作为结果里的标签(不读盘)。
pub fn extractSymbols(
    gpa: std.mem.Allocator,
    file: []const u8,
    source: []const u8,
    lang: ts.Lang,
) !Symbols {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var parser = try ts.Parser.init(lang);
    defer parser.deinit();
    var tree = try parser.parse(source);
    defer tree.deinit();

    var query = ts.Query.init(lang, querySrc(lang)) catch {
        // 查询编译失败 → 优雅降级:返回空符号集(调用方据此回退)。
        return Symbols{ .items = &.{}, .arena = arena };
    };
    defer query.deinit();

    var cursor = ts.Cursor.init();
    defer cursor.deinit();
    cursor.exec(&query, tree.root());

    var raws: std.ArrayList(Raw) = .empty;
    defer raws.deinit(gpa);

    while (cursor.nextMatch()) |m| {
        var name_text: ?[]const u8 = null;
        var def_node: ?ts.Node = null;
        var kind: Kind = .other;

        const caps = m.captures[0..m.capture_count];
        for (caps) |cap| {
            const cap_name = query.captureName(cap.index);
            const node = ts.Node{ .raw = cap.node };
            if (std.mem.eql(u8, cap_name, "name")) {
                name_text = node.text(source);
            } else if (std.mem.startsWith(u8, cap_name, "definition.")) {
                def_node = node;
                kind = Kind.fromCapture(cap_name["definition.".len..]);
            }
        }

        const nm = name_text orelse continue;
        const dn = def_node orelse continue;
        if (nm.len == 0) continue;

        // 函数体内的局部 const/var 不算"符号"(只要容器级/顶层定义)。
        // 丢弃:kind 是 constant/variable 且 def 节点位于某函数/方法体内。
        if ((kind == .constant or kind == .variable) and isInsideFunctionBody(dn)) continue;

        try raws.append(gpa, .{
            .name = nm,
            .kind = kind,
            .def_start_byte = dn.startByte(),
            .def_end_byte = dn.endByte(),
            .line_start = dn.startRow() + 1,
            .line_end = dn.endRow() + 1,
            .signature = firstLine(dn.text(source)),
        });
    }

    // 去重:同 (line_start, name) 保留更具体 kind(zig struct vs 泛 constant)。
    dedupBySpecificity(raws.items);

    // 计算 parent:对每个符号,找字节区间严格包含它、且最小的另一符号名。
    // N 通常小(单文件几十~几百),O(n²) 可接受。
    const kept = countKept(raws.items);
    var out = try a.alloc(Symbol, kept);
    var oi: usize = 0;
    for (raws.items, 0..) |r, i| {
        if (r.dropped) continue;
        const parent = findParent(raws.items, i);
        out[oi] = .{
            .name = try a.dupe(u8, r.name),
            .kind = r.kind,
            .file = try a.dupe(u8, file),
            .line_start = r.line_start,
            .line_end = r.line_end,
            .signature = try a.dupe(u8, r.signature),
            .parent = if (parent) |p| try a.dupe(u8, p) else null,
            .doc = null, // v1:暂不抽 doc
            .lang = lang,
        };
        oi += 1;
    }

    return Symbols{ .items = out[0..oi], .arena = arena };
}

fn firstLine(text: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return std.mem.trim(u8, text[0..nl], " \t\r");
}

/// def 节点是否位于某函数/方法体内(用于丢弃函数体内的局部 const/var)。
/// 向上 walk 父链,遇到函数体类节点即判定为局部。
fn isInsideFunctionBody(node: ts.Node) bool {
    var cur = node.parent();
    while (cur) |n| {
        const k = n.kind();
        if (std.mem.eql(u8, k, "function_declaration") or
            std.mem.eql(u8, k, "function_definition") or
            std.mem.eql(u8, k, "method_definition") or
            std.mem.eql(u8, k, "function_declarator"))
        {
            return true;
        }
        cur = n.parent();
    }
    return false;
}

fn dedupBySpecificity(raws: []Raw) void {
    for (raws, 0..) |*a, i| {
        if (a.dropped) continue;
        for (raws[i + 1 ..]) |*b| {
            if (b.dropped) continue;
            if (a.line_start == b.line_start and std.mem.eql(u8, a.name, b.name)) {
                // 保留更具体的;相等则保留先出现的 a。
                if (b.kind.specificity() > a.kind.specificity()) {
                    a.kind = b.kind;
                    a.def_start_byte = b.def_start_byte;
                    a.def_end_byte = b.def_end_byte;
                    a.line_end = b.line_end;
                    a.signature = b.signature;
                }
                b.dropped = true;
            }
        }
    }
}

fn countKept(raws: []const Raw) usize {
    var n: usize = 0;
    for (raws) |r| {
        if (!r.dropped) n += 1;
    }
    return n;
}

/// 找字节区间严格包含 raws[idx] 的最小符号的名字(即最近祖先定义)。
fn findParent(raws: []const Raw, idx: usize) ?[]const u8 {
    const me = raws[idx];
    var best: ?usize = null;
    for (raws, 0..) |r, j| {
        if (j == idx or r.dropped) continue;
        const contains = r.def_start_byte <= me.def_start_byte and
            r.def_end_byte >= me.def_end_byte and
            (r.def_start_byte != me.def_start_byte or r.def_end_byte != me.def_end_byte);
        if (!contains) continue;
        if (best) |bi| {
            const span_r = r.def_end_byte - r.def_start_byte;
            const span_b = raws[bi].def_end_byte - raws[bi].def_start_byte;
            if (span_r < span_b) best = j;
        } else best = j;
    }
    return if (best) |bi| raws[bi].name else null;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------
const testing = std.testing;

fn findSym(syms: []const Symbol, name: []const u8) ?Symbol {
    for (syms) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

test "zig: 函数/struct/enum/常量/方法/test" {
    const src =
        \\const std = @import("std");
        \\pub const Foo = struct {
        \\    x: u32,
        \\    pub fn bar(self: *Foo) void {}
        \\};
        \\pub const E = enum { a, b };
        \\pub fn baz() void {}
        \\test "sanity" {}
        \\
    ;
    var syms = try extractSymbols(testing.allocator, "t.zig", src, .zig);
    defer syms.deinit();

    const foo = findSym(syms.items, "Foo").?;
    try testing.expectEqual(Kind.@"struct", foo.kind);
    try testing.expectEqual(@as(u32, 2), foo.line_start);

    const e = findSym(syms.items, "E").?;
    try testing.expectEqual(Kind.@"enum", e.kind);

    const baz = findSym(syms.items, "baz").?;
    try testing.expectEqual(Kind.function, baz.kind);
    try testing.expectEqual(@as(u32, 7), baz.line_start);

    // 方法 bar 的 parent 应是 Foo
    const bar = findSym(syms.items, "bar").?;
    try testing.expectEqual(Kind.function, bar.kind);
    try testing.expect(bar.parent != null);
    try testing.expectEqualStrings("Foo", bar.parent.?);

    // std 是个 constant(import 绑定)
    const stdc = findSym(syms.items, "std").?;
    try testing.expectEqual(Kind.constant, stdc.kind);
}

test "python: function + class + method" {
    const src =
        \\import os
        \\class Foo:
        \\    def bar(self):
        \\        pass
        \\def baz():
        \\    return 1
        \\
    ;
    var syms = try extractSymbols(testing.allocator, "t.py", src, .python);
    defer syms.deinit();
    try testing.expectEqual(Kind.class, findSym(syms.items, "Foo").?.kind);
    try testing.expectEqual(Kind.function, findSym(syms.items, "baz").?.kind);
    const bar = findSym(syms.items, "bar").?;
    try testing.expectEqualStrings("Foo", bar.parent.?);
}

test "c: function + struct + enum + typedef" {
    const src =
        \\struct Foo { int x; };
        \\enum E { A, B };
        \\int baz(int a) { return a; }
        \\typedef int myint;
        \\
    ;
    var syms = try extractSymbols(testing.allocator, "t.c", src, .c);
    defer syms.deinit();
    try testing.expectEqual(Kind.@"struct", findSym(syms.items, "Foo").?.kind);
    try testing.expectEqual(Kind.@"enum", findSym(syms.items, "E").?.kind);
    try testing.expectEqual(Kind.function, findSym(syms.items, "baz").?.kind);
    try testing.expectEqual(Kind.type, findSym(syms.items, "myint").?.kind);
}

test "c: typedef/参数里的 struct 引用不产生幻影定义" {
    const src =
        \\typedef struct Point PointT;
        \\double d(struct Point a) { return 0; }
        \\struct Point { int x; };
        \\
    ;
    var syms = try extractSymbols(testing.allocator, "t.c", src, .c);
    defer syms.deinit();
    // 应只有 1 个 struct Point(带 body 的真定义,line 3),不含 typedef/参数里的引用。
    var struct_point_count: usize = 0;
    for (syms.items) |s| {
        if (std.mem.eql(u8, s.name, "Point") and s.kind == .@"struct") {
            struct_point_count += 1;
            try testing.expectEqual(@as(u32, 3), s.line_start);
        }
    }
    try testing.expectEqual(@as(usize, 1), struct_point_count);
    // typedef PointT 仍在
    try testing.expectEqual(Kind.type, findSym(syms.items, "PointT").?.kind);
}

test "typescript: function/class/method/interface/type/enum/const" {
    const src =
        \\export const A = 1;
        \\export function baz(a: number): void {}
        \\export class Foo {
        \\  bar(): void {}
        \\}
        \\interface I { m(): void; }
        \\type T = string;
        \\enum E { A, B }
        \\
    ;
    var syms = try extractSymbols(testing.allocator, "t.ts", src, .typescript);
    defer syms.deinit();
    try testing.expectEqual(Kind.constant, findSym(syms.items, "A").?.kind);
    try testing.expectEqual(Kind.function, findSym(syms.items, "baz").?.kind);
    try testing.expectEqual(Kind.class, findSym(syms.items, "Foo").?.kind);
    try testing.expectEqual(Kind.method, findSym(syms.items, "bar").?.kind);
    try testing.expectEqualStrings("Foo", findSym(syms.items, "bar").?.parent.?);
    try testing.expectEqual(Kind.interface, findSym(syms.items, "I").?.kind);
    try testing.expectEqual(Kind.type, findSym(syms.items, "T").?.kind);
    try testing.expectEqual(Kind.@"enum", findSym(syms.items, "E").?.kind);
}

test "tsx: JSX 不破坏抽取(function/class/method/interface/const)" {
    const src =
        \\export function App(): JSX.Element {
        \\  return <div className="x">hi</div>;
        \\}
        \\export const Button = (p: Props) => <button>{p.label}</button>;
        \\export class Panel extends React.Component {
        \\  render(): JSX.Element { return <span/>; }
        \\}
        \\interface Props { label: string; }
        \\
    ;
    var syms = try extractSymbols(testing.allocator, "t.tsx", src, .tsx);
    defer syms.deinit();
    try testing.expectEqual(Kind.function, findSym(syms.items, "App").?.kind);
    try testing.expectEqual(Kind.constant, findSym(syms.items, "Button").?.kind);
    try testing.expectEqual(Kind.class, findSym(syms.items, "Panel").?.kind);
    try testing.expectEqual(Kind.method, findSym(syms.items, "render").?.kind);
    try testing.expectEqualStrings("Panel", findSym(syms.items, "render").?.parent.?);
    try testing.expectEqual(Kind.interface, findSym(syms.items, "Props").?.kind);
}

test "语法错误文件:仍抽出合法兄弟符号,不崩" {
    // foo 完整,bar 缺闭合 → tree 有 ERROR,但 foo 仍应被抽出。
    const src =
        \\pub fn foo() void {}
        \\pub fn bar( void {{{
        \\pub const X = 42;
        \\
    ;
    var syms = try extractSymbols(testing.allocator, "broken.zig", src, .zig);
    defer syms.deinit();
    // 至少 foo 应在(合法定义);不要求 bar(语法残破)。不崩、无泄漏即达标。
    try testing.expect(findSym(syms.items, "foo") != null);
}

test "只有注释的文件 → 0 符号,不崩" {
    const src =
        \\// just a comment
        \\// another line
        \\
    ;
    var syms = try extractSymbols(testing.allocator, "comments.zig", src, .zig);
    defer syms.deinit();
    try testing.expectEqual(@as(usize, 0), syms.items.len);
}

test "深层嵌套 parent:方法的 parent 是最近的容器(非更外层)" {
    // Zig:Outer struct 内含 Inner struct,Inner 内含方法 m。
    // m 的 parent 应是 Inner(最近容器),不是 Outer。
    const src =
        \\pub const Outer = struct {
        \\    pub const Inner = struct {
        \\        pub fn m(self: *Inner) void { _ = self; }
        \\    };
        \\};
        \\
    ;
    var syms = try extractSymbols(testing.allocator, "nested.zig", src, .zig);
    defer syms.deinit();
    const m = findSym(syms.items, "m").?;
    try testing.expectEqualStrings("Inner", m.parent.?);
}

test "bash: function + variable" {
    const src =
        \\#!/bin/bash
        \\function foo() { echo hi; }
        \\bar() {
        \\  echo bye
        \\}
        \\X=1
        \\
    ;
    var syms = try extractSymbols(testing.allocator, "t.sh", src, .bash);
    defer syms.deinit();
    try testing.expectEqual(Kind.function, findSym(syms.items, "foo").?.kind);
    try testing.expectEqual(Kind.function, findSym(syms.items, "bar").?.kind);
    try testing.expectEqual(Kind.variable, findSym(syms.items, "X").?.kind);
}

test "signature 是定义首行 trim" {
    const src = "pub fn baz() void {}\n";
    var syms = try extractSymbols(testing.allocator, "t.zig", src, .zig);
    defer syms.deinit();
    try testing.expectEqualStrings("pub fn baz() void {}", findSym(syms.items, "baz").?.signature);
}

test "空源码 → 无符号,无泄漏" {
    var syms = try extractSymbols(testing.allocator, "empty.zig", "", .zig);
    defer syms.deinit();
    try testing.expectEqual(@as(usize, 0), syms.items.len);
}



test "extractSymbols go: function/method/struct/interface/type/const/var" {
    const src =
        \\package main
        \\
        \\type Point struct {
        \\    X int
        \\}
        \\
        \\type Shape interface {
        \\    Area() int
        \\}
        \\
        \\const Pi = 3
        \\
        \\var Version = "1.0"
        \\
        \\func Add(a int, b int) int {
        \\    return a + b
        \\}
        \\
        \\func (p Point) Dist() int {
        \\    return p.X
        \\}
    ;
    var syms = try extractSymbols(testing.allocator, "t.go", src, .go);
    defer syms.deinit();
    try testing.expectEqual(Kind.@"struct", findSym(syms.items, "Point").?.kind);
    try testing.expectEqual(Kind.interface, findSym(syms.items, "Shape").?.kind);
    try testing.expectEqual(Kind.function, findSym(syms.items, "Add").?.kind);
    try testing.expectEqual(Kind.method, findSym(syms.items, "Dist").?.kind);
    try testing.expectEqual(Kind.constant, findSym(syms.items, "Pi").?.kind);
    try testing.expectEqual(Kind.variable, findSym(syms.items, "Version").?.kind);
}

test "extractSymbols javascript: function/class/method" {
    const src =
        \\function add(a, b) { return a + b; }
        \\class Point {
        \\  dist() { return 0; }
        \\}
    ;
    var syms = try extractSymbols(testing.allocator, "t.js", src, .javascript);
    defer syms.deinit();
    try testing.expectEqual(Kind.function, findSym(syms.items, "add").?.kind);
    try testing.expectEqual(Kind.class, findSym(syms.items, "Point").?.kind);
    try testing.expectEqual(Kind.method, findSym(syms.items, "dist").?.kind);
}

test "extractSymbols java: class/interface/method" {
    const src =
        \\interface Shape { int area(); }
        \\class Rect implements Shape {
        \\  public int area() { return 0; }
        \\}
    ;
    var syms = try extractSymbols(testing.allocator, "t.java", src, .java);
    defer syms.deinit();
    try testing.expectEqual(Kind.interface, findSym(syms.items, "Shape").?.kind);
    try testing.expectEqual(Kind.class, findSym(syms.items, "Rect").?.kind);
    try testing.expectEqual(Kind.method, findSym(syms.items, "area").?.kind);
}

test "extractSymbols rust: struct/enum/trait/fn" {
    const src =
        \\struct Point { x: i32 }
        \\enum Color { Red, Green }
        \\trait Shape { fn area(&self) -> i32; }
        \\fn add(a: i32, b: i32) -> i32 { a + b }
    ;
    var syms = try extractSymbols(testing.allocator, "t.rs", src, .rust);
    defer syms.deinit();
    try testing.expectEqual(Kind.@"struct", findSym(syms.items, "Point").?.kind);
    try testing.expectEqual(Kind.@"enum", findSym(syms.items, "Color").?.kind);
    try testing.expectEqual(Kind.interface, findSym(syms.items, "Shape").?.kind);
    try testing.expectEqual(Kind.function, findSym(syms.items, "add").?.kind);
}

test "extractSymbols cpp: class/struct/function" {
    const src =
        \\struct Pt { int x; };
        \\class Rect { public: int area(); };
        \\int add(int a, int b) { return a + b; }
    ;
    var syms = try extractSymbols(testing.allocator, "t.cpp", src, .cpp);
    defer syms.deinit();
    try testing.expectEqual(Kind.@"struct", findSym(syms.items, "Pt").?.kind);
    try testing.expectEqual(Kind.class, findSym(syms.items, "Rect").?.kind);
    try testing.expectEqual(Kind.function, findSym(syms.items, "add").?.kind);
}

test "extractSymbols ruby: class/module/method" {
    const src =
        \\module Geo
        \\  class Point
        \\    def dist
        \\      0
        \\    end
        \\  end
        \\end
    ;
    var syms = try extractSymbols(testing.allocator, "t.rb", src, .ruby);
    defer syms.deinit();
    try testing.expectEqual(Kind.class, findSym(syms.items, "Point").?.kind);
    try testing.expectEqual(Kind.method, findSym(syms.items, "dist").?.kind);
}

test "extractSymbols csharp: class/interface/method" {
    const src =
        \\interface IShape { int Area(); }
        \\class Rect : IShape {
        \\  public int Area() { return 0; }
        \\}
    ;
    var syms = try extractSymbols(testing.allocator, "t.cs", src, .csharp);
    defer syms.deinit();
    try testing.expectEqual(Kind.interface, findSym(syms.items, "IShape").?.kind);
    try testing.expectEqual(Kind.class, findSym(syms.items, "Rect").?.kind);
    try testing.expectEqual(Kind.method, findSym(syms.items, "Area").?.kind);
}

test "extractSymbols 仅高亮语言返回空(CodeMap fallback)" {
    const json_src = "{\"key\": \"value\"}";
    var syms = try extractSymbols(testing.allocator, "t.json", json_src, .json);
    defer syms.deinit();
    try testing.expectEqual(@as(usize, 0), syms.items.len);
}
