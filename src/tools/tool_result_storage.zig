//! 大工具结果落盘(批1C,对齐 cc toolResultStorage.ts)。
//!
//! 工具结果超过阈值 → 落盘 $HOME/.cc-zig/tool-results/<hash>.txt,返回 preview+路径
//! 替代 inline,防大结果(DB dump / 大文件)撑爆 context。FileRead 等已自限的工具不落盘。
//! 失败降级:写盘失败 → 返回截断的 inline preview(不崩)。

const std = @import("std");

/// 默认单结果落盘阈值(对齐 cc DEFAULT_MAX_RESULT_SIZE_CHARS)。
pub const DEFAULT_MAX_RESULT_CHARS: usize = 50_000;
/// preview 长度。
const PREVIEW_CHARS: usize = 2000;

/// 按工具名返回落盘阈值。FileRead/Read 已自限(MAX_FILE_BYTES)→ 不落盘(返很大值)。
pub fn maxResultChars(name: []const u8) usize {
    // Read 自己已有 256KB 文件守卫 + 行截断,不再二次落盘(避免 Read→file→Read 环)。
    if (std.mem.eql(u8, name, "Read")) return std.math.maxInt(usize);
    return DEFAULT_MAX_RESULT_CHARS;
}

/// 若 content 超阈值则落盘并返回新 preview 内容(owned,caller free);否则返 null(不改)。
/// session_id 用于命名隔离;home_dir 决定落盘根。任一缺失或写盘失败 → 返回截断 preview。
pub fn maybePersist(
    allocator: std.mem.Allocator,
    name: []const u8,
    content: []const u8,
    home_dir: []const u8,
) !?[]u8 {
    const limit = maxResultChars(name);
    if (content.len <= limit) return null;

    const hash = std.hash.Wyhash.hash(0, content);

    // 落盘路径:$HOME/.cc-zig/tool-results/<hash>.txt
    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const persisted: ?[]const u8 = blk: {
        if (home_dir.len == 0) break :blk null;
        const dir = std.fmt.allocPrint(allocator, "{s}/.cc-zig/tool-results", .{home_dir}) catch break :blk null;
        defer allocator.free(dir);
        @import("../util/fs.zig").mkdirParents(dir) catch break :blk null;
        const fpath = std.fmt.bufPrintZ(&pathbuf, "{s}/{x}.txt", .{ dir, hash }) catch break :blk null;
        const fd = std.c.open(fpath.ptr, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) break :blk null;
        defer _ = std.c.close(fd);
        var pos: usize = 0;
        while (pos < content.len) {
            const n = std.c.write(fd, content.ptr + pos, content.len - pos);
            if (n <= 0) break :blk null;
            pos += @intCast(n);
        }
        break :blk allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(fpath.ptr)))) catch null;
    };

    const preview = content[0..@min(content.len, PREVIEW_CHARS)];
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    if (persisted) |fp| {
        defer allocator.free(fp);
        try w.print("{{\"persisted\":true,\"original_bytes\":{d},\"path\":", .{content.len});
        try std.json.Stringify.encodeJsonString(fp, .{}, w);
        try w.writeAll(",\"preview\":");
        try std.json.Stringify.encodeJsonString(preview, .{}, w);
        try w.writeAll("}");
    } else {
        // 降级:inline 截断 preview(不落盘)。
        try w.print("{{\"truncated\":true,\"original_bytes\":{d},\"preview\":", .{content.len});
        try std.json.Stringify.encodeJsonString(preview, .{}, w);
        try w.writeAll("}");
    }
    return try aw.toOwnedSlice();
}
