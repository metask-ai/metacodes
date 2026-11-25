const std = @import("std");
const symbols = @import("../symbols/symbol.zig");
const symbol_provider = @import("symbol_provider.zig");
const ToolContext = @import("context.zig").ToolContext;

/// `renderOutlineForSource` 的三态结果。**不是 `?[]u8`**:调用方(Read 的 outline 模式)对
/// "能力在位但文件没符号"和"能力缺失"要做不同的事——前者静默回退正常读取即可,后者必须交代
/// 原因,否则又变成 issue #17 那种"静默降级冒充正常结果"。
pub const Outline = union(enum) {
    /// 渲染好的缩进文本树(调用方拥有)。
    text: []u8,
    /// 能力在位,但该文件确实没有符号 → 调用方可安静回退正常读取(Linus S1 的原意)。
    no_symbols,
    /// 能力缺失 → 调用方必须说明原因。
    unavailable: symbol_provider.Unavailable,
};

/// 渲染单文件大纲为缩进文本树(供 Read 工具的 outline 模式复用)。
pub fn renderOutlineForSource(
    ctx: *const ToolContext,
    allocator: std.mem.Allocator,
    file: []const u8,
    source: []const u8,
) !Outline {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    // **不 catch**:唯一的错误来源是分配失败,而 `.no_symbols` 的含义是"能力在位、这文件真的
    // 没符号"。把 OOM 折进去,调用方就会安静地按"没结构"处理——同一类谎报。下面的 renderTree /
    // toOwnedSlice 本来也是直接上抛的,原先只 catch 这一处纯属不一致。
    var outcome = try symbol_provider.extractSymbols(ctx, allocator, file, source);
    switch (outcome) {
        .unavailable => |u| return .{ .unavailable = u },
        .symbols => |*syms| {
            defer syms.deinit();
            if (syms.items.len == 0) return .no_symbols;
            try renderTree(w, syms.items);
            return .{ .text = try out.toOwnedSlice() };
        },
    }
}

/// 按 parent 关系渲染缩进树。v1:两级(顶层 + 直接 child),足够覆盖
/// 方法/字段挂在 struct/class 下的常见情形。无 parent 的算顶层。
fn renderTree(w: *std.Io.Writer, syms: []const symbols.Symbol) !void {
    for (syms) |s| {
        if (s.parent != null) continue; // 子符号在父项下输出
        try renderRow(w, s, 1);
        for (syms) |c| {
            if (c.parent) |p| {
                if (std.mem.eql(u8, p, s.name)) {
                    try renderRow(w, c, 2);
                }
            }
        }
    }
    // 兜底:parent 指向的名字不在本文件顶层时,这些子符号补在顶层缩进(否则漏掉)。
    for (syms) |c| {
        const p = c.parent orelse continue;
        var has_parent_at_top = false;
        for (syms) |s| {
            if (s.parent == null and std.mem.eql(u8, s.name, p)) {
                has_parent_at_top = true;
                break;
            }
        }
        if (!has_parent_at_top) {
            try renderRow(w, c, 1);
        }
    }
}

fn renderRow(w: *std.Io.Writer, s: symbols.Symbol, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try w.writeAll("  ");
    // "kind name" + 对齐填充到 ~28 列 + "(start-end)  signature"
    const used = depth * 2 + s.kind.jsonName().len + 1 + s.name.len;
    try w.print("{s} {s}", .{ s.kind.jsonName(), s.name });
    const pad_to: usize = 28;
    if (used < pad_to) {
        var k: usize = used;
        while (k < pad_to) : (k += 1) try w.writeByte(' ');
    } else {
        try w.writeByte(' ');
    }
    try w.print("({d}-{d})  {s}\n", .{ s.line_start, s.line_end, s.signature });
}
