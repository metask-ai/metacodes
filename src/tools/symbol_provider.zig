const std = @import("std");
const ToolContext = @import("context.zig").ToolContext;
const symbol = @import("../symbols/symbol.zig");
const lsp_diag = @import("lsp_diag.zig");
const servers = @import("../lsp/servers.zig");

pub const capability = @import("../lsp/capability.zig");
pub const Unavailable = capability.Unavailable;

/// "这个文件能不能出符号"的判定结果。**三态里的两态**:能力在位(带那个 server 的 def)
/// vs 能力缺失(带原因)。第三态"在位但没有符号"属于 `Outcome`,不在门禁这一层。
pub const Capability = union(enum) {
    available: *const servers.ServerDef,
    unavailable: Unavailable,
};

/// 取符号的结果。**不是** `!Symbols`:那个类型只有"ok(可能为空)"和"错误"两态,
/// 于是"能力缺失"必然被挤成空列表 —— issue #17 的类型层病根。
pub const Outcome = union(enum) {
    /// 能力在位:`items` 就是 server 报的真实符号集,**为空即代表该文件确实没符号**。
    symbols: symbol.Symbols,
    /// 能力缺失:调用方必须把原因讲出来,绝不能渲染成裸 `[]` / 空大纲。
    unavailable: Unavailable,
};

/// 该文件是否可能产符号的**唯一**判定入口。
///
/// issue #17:这里曾只查静态注册表(`ctx.lsp != null and findServerForFile(file) != null`),
/// 而真正干活的 `service.getOrSpawn` 还要过 `which` → spawn → broken-set。两个谓词对同一个
/// 能力给出不同答案,差额(注册了但没装)就以裸空结果的形式泄漏给模型。判定必须包含运行期。
pub fn capabilityFor(ctx: *const ToolContext, file: []const u8) Capability {
    if (ctx.lsp == null) return .{ .unavailable = .{ .reason = .lsp_disabled } };
    return capabilityForDef(servers.findServerForFile(file));
}

/// `capabilityFor` 的纯函数内核(不碰 ctx):注册表命中 **且** 二进制此刻可解析,才算能力在位。
/// 独立成 pub 是为了测试能传合成 `ServerDef`——server-absent 那一侧因此可以无条件在 CI 跑到,
/// 不必"机器上恰好没装某个 language server"(那正是这个 bug 当初躲过测试的方式)。
pub fn capabilityForDef(def: ?*const servers.ServerDef) Capability {
    const d = def orelse return .{ .unavailable = .{ .reason = .no_server_for_language } };
    if (!servers.binaryAvailable(d))
        return .{ .unavailable = .{ .reason = .server_not_installed, .detail = d.binary } };
    return .{ .available = d };
}

/// 布尔门(只关心"能不能"、不需要解释原因的调用点用,如 Read 的弱提示)。
/// 语义严格等于 `capabilityFor(...) == .available`,不另立谓词。
pub fn hasSymbolsFor(ctx: *const ToolContext, file: []const u8) bool {
    return switch (capabilityFor(ctx, file)) {
        .available => true,
        .unavailable => false,
    };
}

/// 取文件符号(LSP documentSymbol)。`.symbols` 的 arena 归 caller(deinit)。
/// source = 文件全文;file = 结果标签(也用于语言/URI 推断)。
///
/// 能力缺失一律走 `.unavailable`,**不再**伪装成空符号集。注意原因取自真正干活的那条路径
/// (`service.fetchSymbols`),所以 `capabilityFor` 看不见的失败(broken-set、client 满员、
/// 不在 git workspace)也不会静默。
pub fn extractSymbols(ctx: *const ToolContext, gpa: std.mem.Allocator, file: []const u8, source: []const u8) !Outcome {
    const svc = ctx.lsp orelse return .{ .unavailable = .{ .reason = .lsp_disabled } };
    switch (capabilityForDef(servers.findServerForFile(file))) {
        .unavailable => |u| return .{ .unavailable = u },
        .available => {},
    }
    var abuf: [std.fs.max_path_bytes]u8 = undefined;
    const ap = lsp_diag.absPath(file, &abuf) orelse
        return .{ .unavailable = .{ .reason = .path_unresolved } };

    var fetched = svc.fetchSymbols(gpa, ap, source);
    switch (fetched) {
        .unavailable => |u| return .{ .unavailable = u },
        .ok => |*lsp_syms| {
            defer lsp_syms.deinit();
            return .{ .symbols = try convertLsp(gpa, file, lsp_syms.items) };
        },
    }
}

/// LspSymbol[](kind=LSP SymbolKind int)→ 中立 Symbols(kind=Kind,signature=detail)。
/// 全部字符串 dup 进新 arena。
fn convertLsp(gpa: std.mem.Allocator, file: []const u8, items: []const @import("../lsp/symbols.zig").LspSymbol) !symbol.Symbols {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const out = try a.alloc(symbol.Symbol, items.len);
    const file_dup = try a.dupe(u8, file);
    for (items, 0..) |s, i| {
        out[i] = .{
            .name = try a.dupe(u8, s.name),
            .kind = symbol.Kind.fromLspKind(s.kind),
            .file = file_dup,
            .line_start = s.line_start,
            .line_end = s.line_end,
            .signature = try a.dupe(u8, s.detail),
            .parent = if (s.parent) |p| try a.dupe(u8, p) else null,
            .doc = null,
        };
    }
    return .{ .items = out, .arena = arena };
}

test "convertLsp: LSP kind→中立 Kind + detail→signature" {
    const a = std.testing.allocator;
    const lsp_symbols = @import("../lsp/symbols.zig");
    const items = [_]lsp_symbols.LspSymbol{
        .{ .name = "add", .kind = 12, .line_start = 6, .line_end = 8, .detail = "fn (i32,i32) i32", .parent = null },
        .{ .name = "x", .kind = 8, .line_start = 2, .line_end = 2, .detail = "", .parent = "Point" },
    };
    var syms = try convertLsp(a, "mod.zig", &items);
    defer syms.deinit();
    try std.testing.expectEqual(@as(usize, 2), syms.items.len);
    try std.testing.expectEqual(symbol.Kind.function, syms.items[0].kind);
    try std.testing.expectEqualStrings("fn (i32,i32) i32", syms.items[0].signature);
    try std.testing.expectEqual(symbol.Kind.field, syms.items[1].kind);
    try std.testing.expectEqualStrings("Point", syms.items[1].parent.?);
    try std.testing.expectEqualStrings("mod.zig", syms.items[1].file);
}

// ============================================================================
// issue #17 回归:决策谓词(能不能出符号)必须与使用谓词(server 真在不在)一致
// ============================================================================

/// `renderOutlineForSource` 的三态结果。**不是 `?[]u8`**:调用方(Read 的 outline 模式)对
/// "能力在位但文件没符号"和"能力缺失"要做不同的事——前者静默回退正常读取即可,后者必须交代
/// 原因,否则又变成 issue #17 那种"静默降级冒充正常结果"。
pub const Outline = union(enum) {
    /// 渲染好的缩进文本树(调用方拥有)。
    text: []u8,
    /// 能力在位,但该文件确实没有符号 → 调用方可安静回退正常读取(Linus S1 的原意)。
    no_symbols,
    /// 能力缺失 → 调用方必须说明原因。
    unavailable: Unavailable,
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
    var outcome = try extractSymbols(ctx, allocator, file, source);
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
fn renderTree(w: *std.Io.Writer, syms: []const symbol.Symbol) !void {
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

fn renderRow(w: *std.Io.Writer, s: symbol.Symbol, depth: usize) !void {
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

const testing = std.testing;

/// 合成 def:binary 用绝对路径,可用/不可用两侧都不依赖机器上装了什么。
fn fakeDef(binary: []const u8) servers.ServerDef {
    return .{
        .server_id = "fake",
        .extensions = &.{".fake"},
        .binary = binary,
        .root_markers = &.{},
    };
}

test "capabilityForDef: 无注册 server → no_server_for_language" {
    switch (capabilityForDef(null)) {
        .unavailable => |u| try testing.expectEqual(capability.Reason.no_server_for_language, u.reason),
        .available => return error.TestUnexpectedResult,
    }
}

test "REGRESSION issue #17: 注册了但没装 → server_not_installed(点名 binary),不是 available" {
    // 这就是 bug 的原始形态:def 存在(注册表命中)但二进制不在。老 hasSymbolsFor 在这里返 true,
    // 于是"能力缺失"一路被压成空结果。合成 def 让 server-absent 这侧在任何机器/CI 上都跑得到。
    const def = fakeDef("/nonexistent/no-such-langserver-9417");
    switch (capabilityForDef(&def)) {
        .available => return error.TestUnexpectedResult,
        .unavailable => |u| {
            try testing.expectEqual(capability.Reason.server_not_installed, u.reason);
            try testing.expectEqualStrings("/nonexistent/no-such-langserver-9417", u.detail);
            var buf: [capability.WHY_BUF]u8 = undefined;
            // 措辞点名缺失的二进制(issue 的修复项 3)。
            try testing.expect(std.mem.indexOf(u8, u.why(&buf), "no-such-langserver-9417") != null);
        },
    }
}

test "capabilityForDef: 注册且装了 → available" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(/bin/sh 作已知可执行样本)
    const def = fakeDef("/bin/sh");
    switch (capabilityForDef(&def)) {
        .available => |d| try testing.expectEqualStrings("fake", d.server_id),
        .unavailable => return error.TestUnexpectedResult,
    }
}

test "REGRESSION issue #17: 六种真语言上,决策谓词与安装谓词逐一相等" {
    // issue 里的 REPRO_CAPGAP 探针:registered 恒 true,installed 随机器而定,两者曾经会打架。
    // 这里把它翻成断言——无论本机装了哪几个 server,两个谓词都不许再出现差额。
    const cases = [_][]const u8{ "/p/a.py", "/p/a.ts", "/p/a.go", "/p/a.zig", "/p/a.rs", "/p/a.c" };
    for (cases) |f| {
        const def = servers.findServerForFile(f) orelse return error.TestUnexpectedResult;
        const installed = servers.binaryAvailable(def);
        const decided = switch (capabilityForDef(def)) {
            .available => true,
            .unavailable => false,
        };
        try testing.expectEqual(installed, decided);
    }
}

test "hasSymbolsFor: 没有 LSP 服务 → false(且原因是 lsp_disabled,不是'这语言没 server')" {
    const a = testing.allocator;
    const ctx = ToolContext.simple(a); // 无 lsp
    try testing.expect(!hasSymbolsFor(&ctx, "/p/a.zig"));
    switch (capabilityFor(&ctx, "/p/a.zig")) {
        .unavailable => |u| try testing.expectEqual(capability.Reason.lsp_disabled, u.reason),
        .available => return error.TestUnexpectedResult,
    }
}

test "extractSymbols: 没有 LSP 服务 → .unavailable,绝不返回空符号集冒充'没符号'" {
    const a = testing.allocator;
    const ctx = ToolContext.simple(a);
    var outcome = try extractSymbols(&ctx, a, "/p/a.zig", "pub fn f() void {}\n");
    switch (outcome) {
        .symbols => |*syms| {
            syms.deinit();
            return error.TestUnexpectedResult; // 老行为:空 Symbols —— 正是本 issue 要杜绝的
        },
        .unavailable => |u| try testing.expectEqual(capability.Reason.lsp_disabled, u.reason),
    }
}
