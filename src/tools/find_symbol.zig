//! FindSymbol 工具(deferred,藏 ToolSearch 后):跨文件找符号*定义*位置。
//! 不同于 Grep(返回所有出现),只返回定义,带 file:line + 签名。
//!
//! 先快后准:rg -l -w <name> 找候选文件 → 逐个 tree-sitter 抽符号、留 name 匹配的定义。
//! 输出 JSON 数组,便于模型/上层解析。
const std = @import("std");
const common = @import("common.zig");
const security = @import("security.zig");
const toolchain = @import("../util/toolchain.zig");
const ts = @import("../treesitter/ts.zig");
const symbols = @import("../treesitter/symbols.zig");
const ToolContext = @import("context.zig").ToolContext;

const MAX_CANDIDATE_FILES: usize = 300;
const MAX_SOURCE_BYTES: usize = 2 * 1024 * 1024;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const name = common.extractJsonArg(args, "name") orelse return error.MissingName;
    if (name.len == 0) return error.EmptyName;
    const path = common.extractJsonArg(args, "path") orelse ".";
    try security.validateNoTraversal(path);
    const kind_filter = common.extractJsonArg(args, "kind"); // 可选

    // rg -l -w <name> <path>:词边界匹配,只列含该词的文件(快速缩小候选)。
    const files = try listCandidateFiles(allocator, name, path, ctx);
    defer {
        for (files) |f| allocator.free(f);
        allocator.free(files);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeByte('[');
    var first = true;

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
            if (!first) try w.writeByte(',');
            first = false;
            try writeSymbolJson(w, s);
        }
    }

    try w.writeByte(']');
    return try out.toOwnedSlice();
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

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

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
    const raw = common.spawnCaptureStdoutAbortable(argv[0..argv.len], allocator, ctx.abort) catch
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
