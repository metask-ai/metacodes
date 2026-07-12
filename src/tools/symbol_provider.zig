//! 统一符号来源。CodeMap/FindSymbol/Read-outline 三工具经此取符号。
//!
//! Y2 砍 tree-sitter 后**仅 LSP**:ctx.lsp 开且该文件有 LSP server → documentSymbol。未开 `--lsp`
//! 或无对应 server → 无符号(三工具优雅降级:CodeMap 报 unsupported、Read-outline 回退正常读)。
//!
//! **语义**:kind 分类是 LSP server 的语义(如 zls 把 `pub const X = struct` 报成 Constant 而非
//! Struct)。option A 接受(用户 2026-07-12 定案)。
//!
//! **已知性能/设计取舍**(Linus review 2026-07-12 登记):
//!  - **D1 CodeMap glob 性能悬崖**:CodeMap 对目录逐文件 documentSymbol 往返。首文件 spawn+init
//!    server(冷 2-5s),后续复用 warm client(~30ms/文件)。MAX_FILES=200 → warm ~11s。tree-sitter
//!    时代进程内微秒级——option A 的数量级退化。慢 server 每文件最坏 REQUEST_TIMEOUT_MS=10s。缓解:
//!    未来可并发 documentSymbol(需 client 支持并发 sendRequest)或对大 glob 降 cap/警告。
//!    **FindSymbol 无此问题**:rg -w 预筛到"含该名字的少数文件",per-file 成本有界。
//!  - **D2 FindSymbol 可迁 workspace/symbol**:一次请求全项目找名字更快;但 rg -w 不漏定义文件
//!    (定义必含名字文本),故非正确性问题,仅纯性能优化,延后。
//!  - **D3 打开文件不 didClose**:getSymbols 每次 openFile 不 didClose,长跑扫大量文件后 server 端
//!    内存单增。延后(诊断路径也需文件保持 open)。
const std = @import("std");
const ToolContext = @import("context.zig").ToolContext;
const symbol = @import("../symbols/symbol.zig");
const lsp_diag = @import("lsp_diag.zig");
const servers = @import("../lsp/servers.zig");

/// 该文件是否可能产符号:`--lsp` 开且有对应 LSP server。工具用作 outline/大纲入口的 gate。
pub fn hasSymbolsFor(ctx: *const ToolContext, file: []const u8) bool {
    return ctx.lsp != null and servers.findServerForFile(file) != null;
}

/// 取文件符号(LSP documentSymbol)。返回中立 Symbols(caller deinit)。无来源 → 空 Symbols(非错误)。
/// source = 文件全文;file = 结果标签(也用于语言/URI 推断)。
pub fn extractSymbols(ctx: *const ToolContext, gpa: std.mem.Allocator, file: []const u8, source: []const u8) !symbol.Symbols {
    if (ctx.lsp) |svc| {
        var abuf: [std.fs.max_path_bytes]u8 = undefined;
        if (lsp_diag.absPath(file, &abuf)) |ap| {
            var lsp_syms = svc.getSymbols(gpa, ap, source);
            defer lsp_syms.deinit();
            if (lsp_syms.items.len > 0) return convertLsp(gpa, file, lsp_syms.items);
        }
    }
    return emptyNeutral(gpa);
}

fn emptyNeutral(gpa: std.mem.Allocator) symbol.Symbols {
    return .{ .items = &.{}, .arena = std.heap.ArenaAllocator.init(gpa) };
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
