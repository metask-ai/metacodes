//! 统一符号来源。CodeMap/FindSymbol/Read-outline 三工具经此取符号。
//!
//! Y2 砍 tree-sitter 后**仅 LSP**:ctx.lsp 开、该文件有注册 server、且那个 server 的二进制此刻
//! 真的可解析 → documentSymbol。任一条不满足 → `.unavailable(原因)`,三工具据此优雅降级
//! **并说明原因**(CodeMap 打印原因行、FindSymbol 给限定空结果、Read-outline 回退正常读 + 附注)。
//!
//! **三态是硬要求**(issue #17):能力缺失 ≠ 查无符号。曾经两者都是空列表,模型把
//! "没装 pyright" 读成"这个符号不存在"并据此走错路。状态词汇表见 `lsp/capability.zig`。
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

/// 该文件是否可能产符号的**唯一**判定入口(CodeMap / FindSymbol / Read-outline 共用)。
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

test "hasSymbolsFor: 无 --lsp → false(且原因是 lsp_disabled,不是'这语言没 server')" {
    const a = testing.allocator;
    const ctx = ToolContext.simple(a); // 无 lsp
    try testing.expect(!hasSymbolsFor(&ctx, "/p/a.zig"));
    switch (capabilityFor(&ctx, "/p/a.zig")) {
        .unavailable => |u| try testing.expectEqual(capability.Reason.lsp_disabled, u.reason),
        .available => return error.TestUnexpectedResult,
    }
}

test "extractSymbols: 无 --lsp → .unavailable,绝不返回空符号集冒充'没符号'" {
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
