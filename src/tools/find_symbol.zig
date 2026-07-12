//! FindSymbol 工具(默认常驻;2026-06-08 从 deferred 提出):跨文件找符号*定义*位置。
//! 不同于 Grep(返回所有出现),只返回定义,带 file:line + 签名。
//!
//! 先快后准:rg -l -w <name> 找候选文件 → 逐个 tree-sitter 抽符号、留 name 匹配的定义。
//! 输出 JSON 数组,便于模型/上层解析。
const std = @import("std");
const common = @import("common.zig");
const path_mod = @import("../util/path.zig");
const read_state = @import("../core/read_state.zig");
const toolchain = @import("../util/toolchain.zig");
const ts = @import("../treesitter/ts.zig");
const symbols = @import("../treesitter/symbols.zig");
const ToolContext = @import("context.zig").ToolContext;

const MAX_CANDIDATE_FILES: usize = 300;
const MAX_SOURCE_BYTES: usize = 2 * 1024 * 1024;
/// `rg -l -w` 候选文件列表字节上限:巨型仓库防护,读到此上限就 killpg。
/// 路径均长 ~80B × MAX_CANDIDATE_FILES=300 ≈ 24KB,256KB 给足余量又能在巨仓快速止血。
const LIST_BYTE_CAP: usize = 256 * 1024;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const name = common.extractJsonArg(args, "name") orelse return error.MissingName;
    if (name.len == 0) return error.EmptyName;
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

    const defs = try findDefinitions(allocator, name, path, kind_filter, ctx);
    defer {
        for (defs) |s| freeSymbol(allocator, s);
        allocator.free(defs);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeByte('[');
    for (defs, 0..) |s, i| {
        if (i != 0) try w.writeByte(',');
        try writeSymbolJson(w, s);
    }
    try w.writeByte(']');
    return try out.toOwnedSlice();
}

/// 跨文件找符号*定义*,返回匹配的 Symbol 列表(owned:每个 Symbol 的字符串字段都 dupe 到
/// allocator,调用方负责 freeSymbol + free slice)。供 FindSymbol.execute 与 Grep 搭车复用。
/// kind_filter 非 null 时按 kind.jsonName() 过滤。
pub fn findDefinitions(
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,
    kind_filter: ?[]const u8,
    ctx: *const ToolContext,
) ![]symbols.Symbol {
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

    var processed: usize = 0;
    for (files) |file| {
        if (processed >= MAX_CANDIDATE_FILES) break;
        const lang = ts.Lang.fromPath(file) orelse continue;
        processed += 1;
        try ctx.throwIfAborted();

        const source = readFile(allocator, file) catch continue;
        defer allocator.free(source);
        if (source.len > MAX_SOURCE_BYTES) continue;

        var syms = symbols.extractSymbols(allocator, file, source, lang) catch continue;
        defer syms.deinit();

        for (syms.items) |s| {
            if (!std.mem.eql(u8, s.name, name)) continue;
            if (kind_filter) |kf| {
                if (!std.mem.eql(u8, s.kind.jsonName(), kf)) continue;
            }
            try defs.append(allocator, try dupeSymbol(allocator, s));
        }
    }
    return try defs.toOwnedSlice(allocator);
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
        .lang = s.lang,
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
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer _ = std.c.close(fd);
    return try common.readAllFromFd(fd, allocator);
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
