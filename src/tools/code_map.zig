//! CodeMap 工具:输出代码结构大纲(函数/类型/类/常量 + 行号 + 签名)。
//! 单文件或 glob 批量。比整文件 Read 省 token,适合"这文件里有哪些定义"。
//!
//! 输出是缩进文本树(模型友好、省 token):
//!   src/foo.zig
//!     struct Parser        (12-48)  const Parser = struct {
//!       fn init            (14-20)  pub fn init(...) !Parser
//!     fn extractSymbols    (60-95)  pub fn extractSymbols(...) !Symbols
const std = @import("std");
const pfs = @import("platform").fs;
const common = @import("common.zig");
const path_mod = @import("../util/path.zig");
const toolchain = @import("../util/toolchain.zig");
const symbols = @import("../symbols/symbol.zig");
const symbol_provider = @import("symbol_provider.zig");
const ToolContext = @import("context.zig").ToolContext;
const ToolResultBody = @import("context.zig").ToolResultBody;
const artifact_store = @import("../core/tool_result_artifact.zig");
const result_spool = @import("result_spool.zig");

/// 单次 CodeMap 最多处理的文件数(glob 命中很多时防失控)。
const MAX_FILES: usize = 200;
/// 单文件源码字节上限(超大文件跳过解析,避免卡顿)。
const MAX_SOURCE_BYTES: usize = 2 * 1024 * 1024;
/// `rg --files` 输出字节上限:巨型仓库(Chrome ~40 万文件)会吐几十 MB 路径,
/// 读到此上限就 killpg 止血。路径均长 ~80B × MAX_FILES=200 ≈ 16KB,256KB 给足余量。
const LIST_BYTE_CAP: usize = 256 * 1024;

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
        .text_utf8,
        true,
        ctx.result_budget,
    );
}

fn executeToWriter(ctx: *const ToolContext, args: []const u8, w: *std.Io.Writer) anyerror!void {
    const allocator = ctx.allocator;
    const path_raw = common.extractJsonArg(args, "path") orelse return error.MissingPath;
    if (path_raw.len == 0) return error.EmptyPath;
    // 归一化(展开 ~、折叠、查 traversal)。path 可能含 glob 通配(src/**/*.zig),
    // ** 不被词法折叠影响;~ 必须展开(openat/rg 都不认)。
    const path = try path_mod.normalizeChecked(allocator, path_raw, .{ .home = ctx.home_dir, .base_dir = ctx.cwd_abs });
    defer allocator.free(path);

    // 门禁答案只取决于扩展名,而每算一次要扫一遍 PATH(30 段 PATH 实测 36–43µs)。逐文件问同
    // 一个问题就记忆化——glob 批量下省的是 MAX_FILES 次重复 access(2)。
    var caps = symbol_provider.CapabilityCache.init(ctx);

    // path 含 glob 元字符 → 走 rg --files 解析文件列表;否则单文件。
    if (isGlob(path)) {
        const files = try listFiles(allocator, path, ctx);
        defer {
            for (files) |f| allocator.free(f);
            allocator.free(files);
        }
        if (files.len == 0) {
            try w.writeAll("(no files matched)\n");
            return;
        }
        var shown: usize = 0;
        for (files) |f| {
            if (shown >= MAX_FILES) {
                try w.print(
                    "\n… {d} more files not shown (cap {d}). Narrow the glob.\n",
                    .{ files.len - shown, MAX_FILES },
                );
                break;
            }
            try ctx.throwIfAborted();
            try mapOneFile(ctx, allocator, w, f, &caps);
            shown += 1;
        }
    } else {
        try mapOneFile(ctx, allocator, w, path, &caps);
    }
}

/// 处理单个文件:读盘 → 推断语言 → 抽符号 → 渲染缩进树。
/// 失败(读不了/不支持的语言/解析空)只输出一行说明,不中断整体。
fn mapOneFile(
    ctx: *const ToolContext,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    file: []const u8,
    caps: *symbol_provider.CapabilityCache,
) !void {
    // 门禁:能力缺失就地说明原因(措辞来自 capability.why,与 FindSymbol/Read 同一份)。
    switch (caps.get(file)) {
        .available => {},
        .unavailable => |u| return printNoOutline(w, file, u),
    }

    const source = readFile(allocator, file) catch |e| {
        if (e == error.FileTooLarge) {
            try w.print("{s}\n  (file too large to parse; limit {d} bytes)\n", .{ file, MAX_SOURCE_BYTES });
            return;
        }
        try w.print("{s}\n  (cannot read: {s})\n", .{ file, @errorName(e) });
        return;
    };
    defer allocator.free(source);

    var outcome = symbol_provider.extractSymbols(ctx, allocator, file, source) catch |e| {
        try w.print("{s}\n  (parse failed: {s})\n", .{ file, @errorName(e) });
        return;
    };
    switch (outcome) {
        // 门禁看不见的运行期失败(server 起不来 / broken-set / client 满员 / 不在 git 仓)
        // 在这里兜住:同样报原因,绝不冒充 "(no symbols)"。
        .unavailable => |u| return printNoOutline(w, file, u),
        .symbols => |*syms| {
            defer syms.deinit();
            try w.print("{s}\n", .{file});
            if (syms.items.len == 0) {
                try w.writeAll("  (no symbols)\n");
                return;
            }
            try renderTree(w, syms.items);
        },
    }
}

/// 能力缺失行:`<file>` + 一句具体原因。**与 "(no symbols)" 严格区分**——后者只属于
/// "能力在位、这个文件真的没符号"。两个 unavailable 分支共用此函数,措辞不会各写一遍。
fn printNoOutline(w: *std.Io.Writer, file: []const u8, u: symbol_provider.Unavailable) !void {
    var why_buf: [symbol_provider.capability.WHY_BUF]u8 = undefined;
    try w.print("{s}\n  (no outline: {s})\n", .{ file, u.why(&why_buf) });
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

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = pfs.openZ(path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer pfs.close(fd);
    return try common.readAllFromFdCapped(fd, allocator, MAX_SOURCE_BYTES);
}

fn isGlob(path: []const u8) bool {
    for (path) |c| {
        if (c == '*' or c == '?' or c == '[' or c == '{') return true;
    }
    return false;
}

/// 用 rg --files -g <glob> 解析 glob 命中的文件(复用 Glob 工具同款机制)。
fn listFiles(allocator: std.mem.Allocator, glob: []const u8, ctx: *const ToolContext) ![][]const u8 {
    const rg_path = try toolchain.ripgrepPath();
    const glob_z = try allocator.dupeZ(u8, glob);
    defer allocator.free(glob_z);

    var argv = [_]?[*:0]const u8{
        rg_path.ptr,
        "--files",
        "--no-messages",
        "--glob",
        glob_z.ptr,
        null,
    };
    const raw = try common.spawnCaptureStdoutCapped(argv[0..argv.len], allocator, ctx.abort, 0, LIST_BYTE_CAP);
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
