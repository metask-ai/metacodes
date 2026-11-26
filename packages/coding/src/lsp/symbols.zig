//! LSP `textDocument/documentSymbol` 响应解析(自包含,不依赖 core/util)。
//!
//! server 返回两种形态之一(LSP 规范二选一,server 自选):
//!   - **DocumentSymbol[]**(层级):每项 {name, detail?, kind, range, selectionRange, children?}。
//!     children 递归 → 展平成扁平列表,parent = 父项 name。
//!   - **SymbolInformation[]**(扁平,旧式):每项 {name, kind, location:{uri,range}, containerName?}。
//!     parent = containerName。
//! 判别:有 "location" → SymbolInformation;有 "range" → DocumentSymbol。
//!
//! kind 保留 LSP `SymbolKind`(1-26)原始 int——中立 Kind 映射在 tools/ 集成层做(保持 lsp/ 自包含)。
//! 行号:LSP 0-based → 本模块转 1-based(与 tree-sitter 符号一致,tools 层零适配)。
const std = @import("std");

/// 展平后的单个符号。字符串借 LspSymbols.arena。
pub const LspSymbol = struct {
    name: []const u8,
    kind: i64, // LSP SymbolKind(1-26)
    line_start: u32, // 1-based
    line_end: u32, // 1-based
    detail: []const u8, // ≈ signature(server 给的 detail,可能空)
    parent: ?[]const u8 = null,
};

pub const LspSymbols = struct {
    items: []LspSymbol,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *LspSymbols) void {
        self.arena.deinit();
    }
};

/// 递归展平深度上限(防恶意/病态深层嵌套爆栈)。
const MAX_DEPTH: u32 = 64;
/// 符号总数上限(防超大文件 OOM;够覆盖任何正常源文件)。
const MAX_SYMBOLS: usize = 20_000;

/// 解析 documentSymbol 的 result 值(数组)。result 为 null/非数组 → 空。
/// 返回的 LspSymbols 拥有自己的 arena;调用方 deinit。
pub fn parse(gpa: std.mem.Allocator, result: std.json.Value) !LspSymbols {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var list = std.ArrayList(LspSymbol).empty;
    // list 用 gpa(在 arena 之外增长),末尾 toOwnedSlice 后 dupe 进 arena 拥有。
    defer list.deinit(gpa);

    if (result == .array) {
        for (result.array.items) |item| {
            try collect(a, gpa, &list, item, null, 0);
            if (list.items.len >= MAX_SYMBOLS) break;
        }
    }

    const owned = try a.dupe(LspSymbol, list.items);
    return .{ .items = owned, .arena = arena };
}

/// 处理一个符号节点(DocumentSymbol 或 SymbolInformation),追加到 list;DocumentSymbol 的
/// children 递归(depth+1,parent=本项 name)。所有字符串 dupe 进 arena `a`。
fn collect(
    a: std.mem.Allocator,
    gpa: std.mem.Allocator,
    list: *std.ArrayList(LspSymbol),
    item: std.json.Value,
    parent: ?[]const u8,
    depth: u32,
) !void {
    if (depth > MAX_DEPTH) return;
    if (item != .object) return;
    if (list.items.len >= MAX_SYMBOLS) return;
    const obj = item.object;

    const name_v = obj.get("name") orelse return;
    if (name_v != .string) return;
    const name = try a.dupe(u8, name_v.string);

    const kind: i64 = if (obj.get("kind")) |k| (if (k == .integer) k.integer else 0) else 0;
    const detail: []const u8 = if (obj.get("detail")) |d| (if (d == .string) try a.dupe(u8, d.string) else "") else "";

    // 取行范围:DocumentSymbol.range 或 SymbolInformation.location.range。
    const range: ?std.json.Value = blk: {
        if (obj.get("range")) |r| break :blk r; // DocumentSymbol
        if (obj.get("location")) |loc| {
            if (loc == .object) {
                if (loc.object.get("range")) |r| break :blk r; // SymbolInformation
            }
        }
        break :blk null;
    };
    const lines = rangeLines(range);

    // SymbolInformation 用 containerName 作 parent;DocumentSymbol 用递归传入的 parent。
    const eff_parent: ?[]const u8 = if (parent) |p| p else blk: {
        if (obj.get("containerName")) |c| {
            if (c == .string and c.string.len > 0) break :blk try a.dupe(u8, c.string);
        }
        break :blk null;
    };

    try list.append(gpa, .{
        .name = name,
        .kind = kind,
        .line_start = lines.start,
        .line_end = lines.end,
        .detail = detail,
        .parent = eff_parent,
    });

    // DocumentSymbol children 递归(parent = 本项 name)。
    if (obj.get("children")) |ch| {
        if (ch == .array) {
            for (ch.array.items) |c| {
                try collect(a, gpa, list, c, name, depth + 1);
                if (list.items.len >= MAX_SYMBOLS) return;
            }
        }
    }
}

/// 从 LSP range({start:{line,character}, end:{...}})取 1-based 起止行。缺失 → (1,1)。
fn rangeLines(range: ?std.json.Value) struct { start: u32, end: u32 } {
    const r = range orelse return .{ .start = 1, .end = 1 };
    if (r != .object) return .{ .start = 1, .end = 1 };
    const start_line = lineOf(r.object.get("start"));
    const end_line = lineOf(r.object.get("end"));
    return .{ .start = start_line, .end = @max(start_line, end_line) };
}

/// 从 position({line, character})取 1-based line。0-based → +1。缺失/负/越界 → 1。
/// **上界防御**(Linus B1):LSP line 规范是 uinteger(u32),但坏/恶意 server 可传超大 i64 →
/// `+1` 溢出 panic 或 `@intCast` 截断 panic 打崩进程。best-effort 模块必须兜住:>=maxInt(u32) 归 1。
fn lineOf(pos: ?std.json.Value) u32 {
    const p = pos orelse return 1;
    if (p != .object) return 1;
    const l = p.object.get("line") orelse return 1;
    if (l != .integer or l.integer < 0 or l.integer >= std.math.maxInt(u32)) return 1;
    return @intCast(l.integer + 1);
}

// ── tests ────────────────────────────────────────────────────────────────
test "parse: DocumentSymbol 层级展平 + parent + 1-based 行" {
    const a = std.testing.allocator;
    const json =
        \\[{"name":"Foo","kind":23,"range":{"start":{"line":0,"character":0},"end":{"line":10,"character":1}},
        \\  "children":[{"name":"bar","kind":6,"detail":"fn () void","range":{"start":{"line":2,"character":4},"end":{"line":4,"character":5}}}]}]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    var syms = try parse(a, parsed.value);
    defer syms.deinit();

    try std.testing.expectEqual(@as(usize, 2), syms.items.len);
    try std.testing.expectEqualStrings("Foo", syms.items[0].name);
    try std.testing.expectEqual(@as(i64, 23), syms.items[0].kind);
    try std.testing.expectEqual(@as(u32, 1), syms.items[0].line_start); // 0→1
    try std.testing.expectEqual(@as(u32, 11), syms.items[0].line_end); // 10→11
    try std.testing.expect(syms.items[0].parent == null);
    try std.testing.expectEqualStrings("bar", syms.items[1].name);
    try std.testing.expectEqualStrings("fn () void", syms.items[1].detail);
    try std.testing.expectEqualStrings("Foo", syms.items[1].parent.?); // child parent = Foo
    try std.testing.expectEqual(@as(u32, 3), syms.items[1].line_start); // 2→3
}

test "parse: SymbolInformation 扁平 + containerName parent + location.range" {
    const a = std.testing.allocator;
    const json =
        \\[{"name":"main","kind":12,"location":{"uri":"file:///x.zig","range":{"start":{"line":5,"character":0},"end":{"line":8,"character":1}}},"containerName":"App"}]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    var syms = try parse(a, parsed.value);
    defer syms.deinit();

    try std.testing.expectEqual(@as(usize, 1), syms.items.len);
    try std.testing.expectEqualStrings("main", syms.items[0].name);
    try std.testing.expectEqual(@as(i64, 12), syms.items[0].kind);
    try std.testing.expectEqual(@as(u32, 6), syms.items[0].line_start); // 5→6
    try std.testing.expectEqualStrings("App", syms.items[0].parent.?);
}

test "parse: 非数组/null result → 空" {
    const a = std.testing.allocator;
    var syms = try parse(a, .null);
    defer syms.deinit();
    try std.testing.expectEqual(@as(usize, 0), syms.items.len);
}

test "parse: 坏 server 超大 line 号不 panic(Linus B1 overflow 回归)" {
    const a = std.testing.allocator;
    // line = i64 maxInt(远超 u32),旧代码 `+1` 溢出 / @intCast 截断 → panic。
    const json =
        \\[{"name":"x","kind":12,"range":{"start":{"line":9223372036854775807,"character":0},"end":{"line":9223372036854775807,"character":1}}}]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    var syms = try parse(a, parsed.value);
    defer syms.deinit();
    try std.testing.expectEqual(@as(usize, 1), syms.items.len);
    try std.testing.expectEqual(@as(u32, 1), syms.items[0].line_start); // 越界 → 兜底 1
}

test "parse: 缺 range → 兜底 (1,1),缺 name → 跳过" {
    const a = std.testing.allocator;
    const json =
        \\[{"kind":12},{"name":"ok","kind":12}]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    var syms = try parse(a, parsed.value);
    defer syms.deinit();
    try std.testing.expectEqual(@as(usize, 1), syms.items.len); // 无 name 的被跳
    try std.testing.expectEqualStrings("ok", syms.items[0].name);
    try std.testing.expectEqual(@as(u32, 1), syms.items[0].line_start);
}
