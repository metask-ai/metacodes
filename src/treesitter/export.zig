//! export-symbols 机制(层三):walk 一个目录,抽取所有支持语言的符号,
//! 写出 JSONL(每符号一行)。供外围 metaknow skill 灌进知识图谱。
//!
//! cc-zig 唯一职责 = 产出忠实稳定的 symbols.jsonl;**不**调 KG HTTP API。
//! KG 灌库 + 关系推断由外围 skill 负责。
//!
//! 文件枚举复用 ripgrep(`rg --files <dir>`):自动遵守 .gitignore(跳过
//! node_modules/zig-out/.git 等),快、与 CodeMap/Glob 一致。
const std = @import("std");
const ts = @import("ts.zig");
const symbols = @import("symbols.zig");
const toolchain = @import("../util/toolchain.zig");
const common = @import("../tools/common.zig");

const MAX_SOURCE_BYTES: usize = 4 * 1024 * 1024;

/// 运行导出。root_dir 为待扫描目录;out_path 为 null 则写 stdout。
/// 返回进程退出码(0=成功)。
pub fn run(
    gpa: std.mem.Allocator,
    root_dir: []const u8,
    out_path: ?[]const u8,
) !u8 {
    // 1) 枚举文件(rg --files;遵守 .gitignore)。
    const files = listFiles(gpa, root_dir) catch |e| {
        std.debug.print("export-symbols: failed to list files in {s}: {s}\n", .{ root_dir, @errorName(e) });
        return 1;
    };
    defer {
        for (files) |f| gpa.free(f);
        gpa.free(files);
    }

    // 2) 输出目标(文件或 stdout)。用 Allocating writer 累积,末尾一次写出。
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;

    var total: usize = 0;
    var file_count: usize = 0;
    for (files) |file| {
        const lang = ts.Lang.fromPath(file) orelse continue;
        file_count += 1;

        const source = readFile(gpa, file) catch continue;
        defer gpa.free(source);
        if (source.len > MAX_SOURCE_BYTES) continue;

        var syms = symbols.extractSymbols(gpa, file, source, lang) catch continue;
        defer syms.deinit();

        for (syms.items) |s| {
            try writeSymbolLine(w, s);
            total += 1;
        }
    }

    // 3) 落盘 / 打 stdout。
    const bytes = out.written();
    if (out_path) |p| {
        try writeWholeFile(p, bytes);
        std.debug.print("export-symbols: wrote {d} symbols from {d} files → {s}\n", .{ total, file_count, p });
    } else {
        writeStdout(bytes);
    }
    return 0;
}

fn writeSymbolLine(w: *std.Io.Writer, s: symbols.Symbol) !void {
    try w.writeAll("{\"name\":");
    try writeJsonString(w, s.name);
    try w.writeAll(",\"kind\":");
    try writeJsonString(w, s.kind.jsonName());
    try w.writeAll(",\"file\":");
    try writeJsonString(w, s.file);
    try w.print(",\"line_start\":{d},\"line_end\":{d}", .{ s.line_start, s.line_end });
    try w.writeAll(",\"signature\":");
    try writeJsonString(w, s.signature);
    try w.writeAll(",\"parent\":");
    if (s.parent) |p| try writeJsonString(w, p) else try w.writeAll("null");
    try w.writeAll(",\"doc\":");
    if (s.doc) |d| try writeJsonString(w, d) else try w.writeAll("null");
    try w.writeAll(",\"lang\":");
    try writeJsonString(w, s.lang.name());
    try w.writeAll("}\n");
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

/// rg --files <dir>:列出 dir 下所有文件(遵守 .gitignore)。
fn listFiles(allocator: std.mem.Allocator, dir: []const u8) ![][]const u8 {
    const rg_path = try toolchain.ripgrepPath();
    const dir_z = try allocator.dupeZ(u8, dir);
    defer allocator.free(dir_z);

    var argv = [_]?[*:0]const u8{
        rg_path.ptr,
        "--files",
        "--no-messages",
        dir_z.ptr,
        null,
    };
    const raw = try common.spawnCaptureStdout(argv[0..argv.len], allocator);
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

fn writeWholeFile(path: []const u8, bytes: []const u8) !void {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch return error.WriteError;
    defer _ = std.c.close(fd);
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + pos, bytes.len - pos);
        if (n <= 0) return error.WriteError;
        pos += @as(usize, @intCast(n));
    }
}

fn writeStdout(bytes: []const u8) void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = std.c.write(1, bytes.ptr + pos, bytes.len - pos);
        if (n <= 0) break;
        pos += @as(usize, @intCast(n));
    }
}
