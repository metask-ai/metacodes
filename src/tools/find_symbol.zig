//! FindSymbol 工具(默认常驻;2026-06-08 从 deferred 提出):跨文件找符号*定义*位置。
//! 不同于 Grep(返回所有出现),只返回定义,带 file:line + 签名。
//!
//! 先快后准:rg -l -w <name> 找候选文件 → 逐个经 LSP documentSymbol 抽符号、留 name 匹配的定义。
//! 需要装了对应 language server(Y2 砍 tree-sitter 后;LSP 默认开,`--no-lsp` 关)。
//! 输出 JSON 数组,便于模型/上层解析。
//!
//! **空结果必须自证**(issue #17):符号能力缺失时(LSP 被关 / 没注册 server / server 没装 /
//! server 起不来 / 不在 git 仓)绝不能输出裸 `[]`——那会被模型读成"这个符号不存在"并据此走错路。
//! 一律在数组后追加一句限定语,点名具体原因。裸 `[]` 只在能力全程在位时出现。
//! (**已知残留**:`MAX_CANDIDATE_FILES` 截断仍是静默的——那是配额而非能力缺失,且没有不依赖
//! 真 language server 的确定性测法,故不在本次修复内假装解决。CodeMap 的 glob cap 有明说。)
const std = @import("std");
const pfs = @import("platform").fs;
const common = @import("common.zig");
const path_mod = @import("../util/path.zig");
const read_state = @import("../core/read_state.zig");
const toolchain = @import("../util/toolchain.zig");
const symbols = @import("../symbols/symbol.zig");
const symbol_provider = @import("symbol_provider.zig");
const capability = @import("../lsp/capability.zig");
const ToolContext = @import("context.zig").ToolContext;
const ToolResultBody = @import("context.zig").ToolResultBody;
const artifact_store = @import("../core/tool_result_artifact.zig");
const result_spool = @import("result_spool.zig");

const MAX_CANDIDATE_FILES: usize = 300;
const MAX_SOURCE_BYTES: usize = 2 * 1024 * 1024;
/// `rg -l -w` 候选文件列表字节上限:巨型仓库防护,读到此上限就 killpg。
/// 路径均长 ~80B × MAX_CANDIDATE_FILES=300 ≈ 24KB,256KB 给足余量又能在巨仓快速止血。
const LIST_BYTE_CAP: usize = 256 * 1024;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try executeToWriter(ctx, args, &out.writer);
    return try out.toOwnedSlice();
}

pub fn executeBody(ctx: *const ToolContext, args: []const u8) anyerror!ToolResultBody {
    if (ctx.artifact_root.len == 0)
        return ToolResultBody.initInline(try execute(ctx, args));
    var capture = try artifact_store.Capture.begin(
        ctx.allocator,
        ctx.artifact_root,
        artifact_store.MAX_ARTIFACT_BYTES,
    );
    defer capture.deinit();
    var output = result_spool.CaptureWriter.init(&capture);
    try executeToWriter(ctx, args, &output.writer);
    try output.check();
    try capture.seal();
    return result_spool.finishCaptureAsBody(
        ctx.allocator,
        ctx.artifact_root,
        &capture,
        .json,
        true,
    );
}

fn executeToWriter(ctx: *const ToolContext, args: []const u8, w: *std.Io.Writer) anyerror!void {
    const allocator = ctx.allocator;
    const name = common.extractJsonArg(args, "name") orelse return error.MissingName;
    if (name.len == 0) return error.EmptyName;

    // Y2 砍 tree-sitter 后符号只来自 LSP。没有 Service → 带提示的空结果,别用裸 `[]` 把"能力缺失"
    // 伪装成"查无定义"。早退是为了省掉 rg;措辞与下面所有缺失原因共用同一个渲染器,不会漂移。
    if (ctx.lsp == null) {
        try w.writeAll("[]");
        try writeUnavailableNote(w, .{ .reason = .lsp_disabled }, 0);
        return;
    }

    const path_raw = common.extractJsonArg(args, "path") orelse ".";
    // 归一化(展开 ~、折叠、查 traversal)。rg 经 execve 不认 ~。
    const path = try path_mod.normalizeChecked(allocator, path_raw, .{ .home = ctx.home_dir, .base_dir = ctx.cwd_abs });
    defer allocator.free(path);
    // 存在性检查:rg 静默路径错误 → 先拦给明确错误。
    _ = read_state.statPath(path) catch {
        common.setErrorDetail(ctx.error_detail, allocator, "path not found: '{s}' (用绝对路径或 ~/...?)", .{path});
        return error.PathNotFound;
    };
    const kind_filter = common.extractJsonArg(args, "kind"); // 可选

    const scan = try scanDefinitions(allocator, name, path, kind_filter, ctx);
    const defs = scan.defs;
    defer {
        for (defs) |s| freeSymbol(allocator, s);
        allocator.free(defs);
    }

    try w.writeByte('[');
    for (defs, 0..) |s, i| {
        if (i != 0) try w.writeByte(',');
        try writeSymbolJson(w, s);
    }
    try w.writeByte(']');
    // 有候选文件因能力缺失被跳过 → 结果不可信为完整,更不可信为"查无定义"。
    if (scan.unavailable) |u| try writeUnavailableNote(w, u, defs.len);
}

/// 给结果加限定语:说清"为什么没有(或可能不全)",堵死"能力缺失被读成查无定义"(issue #17)。
/// **所有**缺失原因(含 LSP 被关)都走这里,措辞只有这一处。
fn writeUnavailableNote(w: *std.Io.Writer, u: capability.Unavailable, found: usize) !void {
    var why_buf: [capability.WHY_BUF]u8 = undefined;
    const why = u.why(&why_buf);
    if (found == 0) {
        try w.print(
            "\n(FindSymbol resolved no definitions because {s}. This empty result does NOT mean the symbol is undefined — use Grep to search the text, or install/enable the language server and retry.)",
            .{why},
        );
    } else {
        try w.print(
            "\n(Some candidate files were skipped because {s}, so this list may be incomplete. A missing definition here does NOT mean it is undefined — use Grep to search the text.)",
            .{why},
        );
    }
}

/// 一次跨文件定义扫描的结果。
pub const Scan = struct {
    /// 匹配的定义(owned:字符串字段 dupe 到 allocator,调用方负责 freeSymbol + free slice)。
    defs: []symbols.Symbol,
    /// 有候选文件因**符号能力缺失**被跳过时,记下**最可操作**的那个原因(不是最先遇到的——
    /// 见 `capability.moreActionable`);否则 null。
    /// 非 null ⇒ `defs` 不保证完整,空 `defs` **不得**解读为"查无定义"(issue #17)。
    unavailable: ?capability.Unavailable,
};

/// 跨文件找符号*定义*,并如实报告扫描过程中的能力缺失。kind_filter 非 null 时按
/// kind.jsonName() 过滤。
pub fn scanDefinitions(
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,
    kind_filter: ?[]const u8,
    ctx: *const ToolContext,
) !Scan {
    const files = try listCandidateFiles(allocator, name, path, ctx);
    defer {
        for (files) |f| allocator.free(f);
        allocator.free(files);
    }

    var defs: std.ArrayList(symbols.Symbol) = .empty;
    errdefer {
        for (defs.items) |s| freeSymbol(allocator, s);
        defs.deinit(allocator);
    }

    // 候选文件为空(rg 一个都没找到)时保持 null:那是真正的"查无此名",裸 `[]` 才是诚实的。
    var unavailable: ?capability.Unavailable = null;
    // 门禁答案只取决于扩展名,而每算一次要扫一遍 PATH(30 段 PATH 实测 36–43µs)。候选文件可达
    // 数千个、且被挡掉的那些此外什么都不做 → 不记忆化就是上百 ms 的纯 access(2)。
    var caps = symbol_provider.CapabilityCache.init(ctx);

    var processed: usize = 0;
    for (files) |file| {
        if (processed >= MAX_CANDIDATE_FILES) break;
        // 门禁:需要 LSP 在位 + 注册 server + 该 server 二进制真的装了。
        switch (caps.get(file)) {
            .available => {},
            .unavailable => |u| {
                unavailable = capability.moreActionable(unavailable, u);
                continue;
            },
        }
        processed += 1;
        try ctx.throwIfAborted();

        const source = readFile(allocator, file) catch continue;
        defer allocator.free(source);
        if (source.len > MAX_SOURCE_BYTES) continue;

        // **不 catch**:这里唯一的错误来源是分配失败。把 OOM 吞成"这文件没匹配"会得到一份
        // 短了却看起来完整的定义列表——正是本 issue 要消灭的那类谎报,只是换了个原因。
        var outcome = try symbol_provider.extractSymbols(ctx, allocator, file, source);
        switch (outcome) {
            // 门禁看不见的运行期失败(spawn 失败 / broken-set / client 满员 / 不在 git 仓)。
            .unavailable => |u| {
                unavailable = capability.moreActionable(unavailable, u);
                continue;
            },
            .symbols => |*syms| {
                defer syms.deinit();
                for (syms.items) |s| {
                    if (!std.mem.eql(u8, s.name, name)) continue;
                    if (kind_filter) |kf| {
                        if (!std.mem.eql(u8, s.kind.jsonName(), kf)) continue;
                    }
                    try defs.append(allocator, try dupeSymbol(allocator, s));
                }
            },
        }
    }
    return .{ .defs = try defs.toOwnedSlice(allocator), .unavailable = unavailable };
}

/// `scanDefinitions` 的只要结果版。供 Grep 搭车复用——Grep 的主结果本就完整,拿不到定义前缀
/// 时静默降级是正确的,故它不需要能力状态。
pub fn findDefinitions(
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,
    kind_filter: ?[]const u8,
    ctx: *const ToolContext,
) ![]symbols.Symbol {
    const scan = try scanDefinitions(allocator, name, path, kind_filter, ctx);
    return scan.defs;
}

/// Symbol 的字符串字段借用 extractSymbols 的临时 buffer(syms.deinit 后失效),
/// 跨函数边界返回前必须深拷贝。
fn dupeSymbol(allocator: std.mem.Allocator, s: symbols.Symbol) !symbols.Symbol {
    return .{
        .name = try allocator.dupe(u8, s.name),
        .kind = s.kind,
        .file = try allocator.dupe(u8, s.file),
        .line_start = s.line_start,
        .line_end = s.line_end,
        .signature = try allocator.dupe(u8, s.signature),
        .parent = if (s.parent) |p| try allocator.dupe(u8, p) else null,
        .doc = if (s.doc) |d| try allocator.dupe(u8, d) else null,
    };
}

/// 释放 findDefinitions 返回的单个 Symbol。公开供 Grep 搭车复用。
pub fn freeSymbolPublic(allocator: std.mem.Allocator, s: symbols.Symbol) void {
    freeSymbol(allocator, s);
}

fn freeSymbol(allocator: std.mem.Allocator, s: symbols.Symbol) void {
    allocator.free(s.name);
    allocator.free(s.file);
    allocator.free(s.signature);
    if (s.parent) |p| allocator.free(p);
    if (s.doc) |d| allocator.free(d);
}

fn writeSymbolJson(w: *std.Io.Writer, s: symbols.Symbol) !void {
    try w.writeAll("{\"name\":");
    try writeJsonString(w, s.name);
    try w.writeAll(",\"kind\":");
    try writeJsonString(w, s.kind.jsonName());
    try w.writeAll(",\"file\":");
    try writeJsonString(w, s.file);
    try w.print(",\"line\":{d}", .{s.line_start});
    try w.writeAll(",\"signature\":");
    try writeJsonString(w, s.signature);
    try w.writeAll(",\"parent\":");
    if (s.parent) |p| {
        try writeJsonString(w, p);
    } else {
        try w.writeAll("null");
    }
    try w.writeByte('}');
}

const writeJsonString = @import("../util/json.zig").writeJsonString;

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = pfs.openZ(path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer pfs.close(fd);
    return try common.readAllFromFdCapped(fd, allocator, MAX_SOURCE_BYTES);
}

/// rg -l -w <name> <path>:列出含该词(词边界)的文件。
fn listCandidateFiles(
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,
    ctx: *const ToolContext,
) ![][]const u8 {
    const rg_path = try toolchain.ripgrepPath();
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var argv = [_]?[*:0]const u8{
        rg_path.ptr,
        "-l",
        "-w",
        "--no-messages",
        name_z.ptr,
        path_z.ptr,
        null,
    };
    const raw = common.spawnCaptureStdoutCapped(argv[0..argv.len], allocator, ctx.abort, 0, LIST_BYTE_CAP) catch
        return try allocator.alloc([]const u8, 0);
    defer allocator.free(raw);

    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, raw, cursor, '\n')) |nl| {
        if (nl > cursor) {
            try files.append(allocator, try allocator.dupe(u8, raw[cursor..nl]));
        }
        cursor = nl + 1;
    }
    return try files.toOwnedSlice(allocator);
}

test "FindSymbol 无 LSP 服务 → 带提示的空结果(非裸 [],不伪装查无)" {
    const a = std.testing.allocator;
    const ctx = ToolContext.simple(a); // 无 lsp
    const r = try execute(&ctx, "{\"name\":\"Foo\"}");
    defer a.free(r);
    // 不是裸 "[]";点名关掉它的开关(LSP 默认开,所以引导是"别用 --no-lsp"而非"加 --lsp")。
    try std.testing.expect(!std.mem.eql(u8, r, "[]"));
    try std.testing.expect(std.mem.indexOf(u8, r, "--no-lsp") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "does NOT mean") != null);
}

test "REGRESSION issue #17: 限定语点名缺失的 language server 二进制" {
    // 修复项 3:沿用既有措辞,并把缺失的 binary 名带上,模型据此知道下一步该装什么。
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try writeUnavailableNote(&out.writer, .{
        .reason = .server_not_installed,
        .detail = "pyright-langserver",
    }, 0);
    const s = out.written();
    try std.testing.expect(std.mem.indexOf(u8, s, "pyright-langserver") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "not installed") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "does NOT mean") != null);
}

test "REGRESSION issue #17: 有结果但有文件被跳过 → 提示可能不完整(不谎称完整)" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try writeUnavailableNote(&out.writer, .{ .reason = .server_not_installed, .detail = "gopls" }, 3);
    const s = out.written();
    try std.testing.expect(std.mem.indexOf(u8, s, "may be incomplete") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "gopls") != null);
}

test "REGRESSION issue #17: --lsp 开但符号能力缺失 → 仍不是裸 []" {
    // 老代码的漏洞正在这条路径上:`ctx.lsp != null` 就跳过了唯一的限定分支,
    // 于是"server 没装 / 起不来 / 不在 git 仓"全都以裸 `[]` 收场。
    //
    // 本测试**在任何机器上都跑到 unavailable**,不靠"恰好没装某个 server":
    //   · 没装 zls  → 门禁判 server_not_installed;
    //   · 装了 zls  → /tmp 不是 git 仓,fetchSymbols 判 outside_workspace。
    // 两条都必须给出限定语,断言取二者的公共不变量。
    const a = std.testing.allocator;
    const pprocess = @import("platform").process;

    const base = try std.fmt.allocPrint(a, "/tmp/cc_fs_capgap_{d}", .{pprocess.currentPid()});
    defer a.free(base);
    {
        var zbuf: [std.fs.max_path_bytes]u8 = undefined;
        const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{base}) catch return;
        _ = std.c.mkdir(z.ptr, 0o755);
    }
    const file = try std.fmt.allocPrint(a, "{s}/probe.zig", .{base});
    defer a.free(file);
    {
        var zbuf: [std.fs.max_path_bytes]u8 = undefined;
        const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{file}) catch return;
        const fd = pfs.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return;
        _ = pfs.write(fd, "pub fn CapGapProbeSymbol() void {}\n");
        pfs.close(fd);
    }
    defer {
        var zbuf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrintZ(&zbuf, "{s}", .{file})) |z| {
            _ = std.c.unlink(z.ptr);
        } else |_| {}
        if (std.fmt.bufPrintZ(&zbuf, "{s}", .{base})) |z| {
            _ = std.c.rmdir(z.ptr);
        } else |_| {}
    }

    const Service = @import("../lsp/service.zig").Service;
    var svc = Service.create(a, base, null) catch return;
    defer svc.shutdown();

    var ctx = ToolContext.simple(a);
    ctx.lsp = svc; // LSP **在位** —— 老 guard 在这里就放行了
    ctx.cwd_abs = base;

    var abuf: [512]u8 = undefined;
    const args = std.fmt.bufPrint(&abuf, "{{\"name\":\"CapGapProbeSymbol\",\"path\":\"{s}\"}}", .{base}) catch unreachable;
    const r = try execute(&ctx, args);
    defer a.free(r);

    try std.testing.expect(!std.mem.eql(u8, r, "[]")); // 核心断言:裸 [] 绝迹
    try std.testing.expect(std.mem.startsWith(u8, r, "[]")); // 定义确实一个没找到
    try std.testing.expect(std.mem.indexOf(u8, r, "does NOT mean") != null);
    // 原因必须是具体的两种之一(不是笼统的"没找到")。
    const named_binary = std.mem.indexOf(u8, r, "not installed") != null;
    const outside_repo = std.mem.indexOf(u8, r, "outside a git workspace") != null;
    try std.testing.expect(named_binary or outside_repo);
}
