//! CodeMap 工具:输出代码结构大纲(函数/类型/类/常量 + 行号 + 签名)。
//! 单文件或 glob 批量。比整文件 Read 省 token,适合"这文件里有哪些定义"。
//!
//! 输出是缩进文本树(模型友好、省 token):
//!   src/foo.zig
//!     struct Parser        (12-48)  const Parser = struct {
//!       fn init            (14-20)  pub fn init(...) !Parser
//!     fn extractSymbols    (60-95)  pub fn extractSymbols(...) !Symbols
const std = @import("std");
const common = @import("common.zig");
const security = @import("security.zig");
const toolchain = @import("../util/toolchain.zig");
const ts = @import("../treesitter/ts.zig");
const symbols = @import("../treesitter/symbols.zig");
const ToolContext = @import("context.zig").ToolContext;

/// 单次 CodeMap 最多处理的文件数(glob 命中很多时防失控)。
const MAX_FILES: usize = 200;
/// 单文件源码字节上限(超大文件跳过解析,避免卡顿)。
const MAX_SOURCE_BYTES: usize = 2 * 1024 * 1024;

/// 渲染单文件大纲为缩进文本树(供 Read 工具的 outline 模式复用)。
/// 调用方拥有返回串。lang 已知、source 已读。空符号 → "(no symbols)\n"。
pub fn renderOutlineForSource(
    allocator: std.mem.Allocator,
    file: []const u8,
    source: []const u8,
    lang: ts.Lang,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    var syms = symbols.extractSymbols(allocator, file, source, lang) catch {
        return try allocator.dupe(u8, "(outline unavailable: parse failed)\n");
    };
    defer syms.deinit();

    if (syms.items.len == 0) {
        return try allocator.dupe(u8, "(no symbols)\n");
    }
    try renderTree(w, syms.items);
    return try out.toOwnedSlice();
}

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const path = common.extractJsonArg(args, "path") orelse return error.MissingPath;
    if (path.len == 0) return error.EmptyPath;
    try security.validateNoTraversal(path);

    // lang 覆盖(可选);否则按扩展名推断。显式给了但不认识 → 报错(不静默忽略 typo)。
    const lang_override: ?ts.Lang = if (common.extractJsonArg(args, "lang")) |l|
        (langFromName(l) orelse return error.UnsupportedLanguage)
    else
        null;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    // path 含 glob 元字符 → 走 rg --files 解析文件列表;否则单文件。
    if (isGlob(path)) {
        const files = try listFiles(allocator, path, ctx);
        defer {
            for (files) |f| allocator.free(f);
            allocator.free(files);
        }
        if (files.len == 0) {
            return try allocator.dupe(u8, "(no files matched)\n");
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
            try mapOneFile(allocator, w, f, lang_override);
            shown += 1;
        }
    } else {
        try mapOneFile(allocator, w, path, lang_override);
    }

    if (out.written().len == 0) {
        return try allocator.dupe(u8, "(no symbols found)\n");
    }
    return try out.toOwnedSlice();
}

/// 处理单个文件:读盘 → 推断语言 → 抽符号 → 渲染缩进树。
/// 失败(读不了/不支持的语言/解析空)只输出一行说明,不中断整体。
fn mapOneFile(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    file: []const u8,
    lang_override: ?ts.Lang,
) !void {
    const lang = lang_override orelse ts.Lang.fromPath(file) orelse {
        try w.print("{s}\n  (unsupported language)\n", .{file});
        return;
    };

    const source = readFile(allocator, file) catch |e| {
        try w.print("{s}\n  (cannot read: {s})\n", .{ file, @errorName(e) });
        return;
    };
    defer allocator.free(source);

    if (source.len > MAX_SOURCE_BYTES) {
        try w.print("{s}\n  (file too large to parse: {d} bytes)\n", .{ file, source.len });
        return;
    }

    var syms = symbols.extractSymbols(allocator, file, source, lang) catch |e| {
        try w.print("{s}\n  (parse failed: {s})\n", .{ file, @errorName(e) });
        return;
    };
    defer syms.deinit();

    try w.print("{s}\n", .{file});
    if (syms.items.len == 0) {
        try w.writeAll("  (no symbols)\n");
        return;
    }
    try renderTree(w, syms.items);
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
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer _ = std.c.close(fd);
    return try common.readAllFromFd(fd, allocator);
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
    const raw = try common.spawnCaptureStdoutAbortable(argv[0..argv.len], allocator, ctx.abort);
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

fn langFromName(name: []const u8) ?ts.Lang {
    const Pair = struct { n: []const u8, l: ts.Lang };
    const table = [_]Pair{
        .{ .n = "zig", .l = .zig },
        .{ .n = "typescript", .l = .typescript },
        .{ .n = "tsx", .l = .tsx },
        .{ .n = "python", .l = .python },
        .{ .n = "c", .l = .c },
        .{ .n = "bash", .l = .bash },
    };
    for (table) |p| {
        if (std.mem.eql(u8, name, p.n)) return p.l;
    }
    return null;
}
