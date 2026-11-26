//! 中立符号类型:不依赖任何语法引擎 / ts.Lang,由 LSP textDocument/documentSymbol 产出,
//! CodeMap/FindSymbol/Read-outline 三工具统一消费。(设计上可挂多来源;当前唯一来源是 LSP。)
//!
//! 砍 tree-sitter(Y2 Step4)后 ts.Lang 消失,故符号类型必须与语法引擎解耦。原 tree-sitter 版
//! 的 `lang: ts.Lang` 字段无任何消费者(仅在 dupe 里传递,从不读/渲染)→ 本中立版直接去掉。
const std = @import("std");

/// 符号种类。稳定小写 tag 名用于 JSON/展示;specificity 用于同 (line,name) 去重取更精确者。
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

    /// 具体度:去重时同 (line,name) 保留更具体的 kind。
    /// constant/variable/other 最弱(1);泛 type(2);具体容器 struct/enum/union/class/interface
    /// 最强(3)——一个 struct 比泛 "type" 更精确。
    pub fn specificity(self: Kind) u8 {
        return switch (self) {
            .constant, .variable, .other => 1,
            .type => 2,
            .@"struct", .@"enum", .@"union", .class, .interface => 3,
            else => 2,
        };
    }

    /// LSP `SymbolKind`(1-26,见 LSP 规范)→ 中立 Kind。未知归 .other。
    /// 参考:File=1 Module=2 Namespace=3 Package=4 Class=5 Method=6 Property=7 Field=8
    /// Constructor=9 Enum=10 Interface=11 Function=12 Variable=13 Constant=14 String=15
    /// Number=16 Boolean=17 Array=18 Object=19 Key=20 Null=21 EnumMember=22 Struct=23
    /// Event=24 Operator=25 TypeParameter=26。
    pub fn fromLspKind(n: i64) Kind {
        return switch (n) {
            5 => .class,
            6, 9 => .method, // Method / Constructor
            7, 8 => .field, // Property / Field
            10 => .@"enum",
            11 => .interface,
            12 => .function,
            13 => .variable,
            14 => .constant,
            22 => .field, // EnumMember 归 field(枚举成员)
            23 => .@"struct",
            26 => .type, // TypeParameter
            2, 3, 4 => .import, // Module/Namespace/Package ≈ 顶层容器,归 import 展示
            else => .other,
        };
    }
};

/// 一个符号定义。所有 slice 由持有它的 Symbols.arena 拥有(或 dupe 到 caller allocator)。
/// 行号 1-based。
pub const Symbol = struct {
    name: []const u8,
    kind: Kind,
    file: []const u8,
    line_start: u32,
    line_end: u32,
    signature: []const u8,
    parent: ?[]const u8 = null,
    doc: ?[]const u8 = null,
};

/// 一批符号 + 拥有其字符串的 arena。
pub const Symbols = struct {
    items: []Symbol,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Symbols) void {
        self.arena.deinit();
    }
};

test "Kind.jsonName 稳定" {
    try std.testing.expectEqualStrings("function", Kind.function.jsonName());
    try std.testing.expectEqualStrings("struct", Kind.@"struct".jsonName());
}

test "Kind.specificity 排序" {
    try std.testing.expect(Kind.@"struct".specificity() > Kind.type.specificity());
    try std.testing.expect(Kind.type.specificity() > Kind.variable.specificity());
}

test "Kind.fromLspKind 映射" {
    try std.testing.expectEqual(Kind.function, Kind.fromLspKind(12));
    try std.testing.expectEqual(Kind.@"struct", Kind.fromLspKind(23));
    try std.testing.expectEqual(Kind.class, Kind.fromLspKind(5));
    try std.testing.expectEqual(Kind.method, Kind.fromLspKind(6));
    try std.testing.expectEqual(Kind.constant, Kind.fromLspKind(14));
    try std.testing.expectEqual(Kind.other, Kind.fromLspKind(99));
    try std.testing.expectEqual(Kind.other, Kind.fromLspKind(15)); // String
}
