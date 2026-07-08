//! ~/.metacodes/config.json 的 TUI 相关读写。
//!
//! 现在管 1 个字段:`theme`("auto"/"dark"/"light"/"mono")。
//!
//! 读:启动时 App 调 loadTheme(home),返回 ?Variant。null = 文件不存在/无 theme 字段。
//! 写:/theme 命令调 saveTheme(home, variant),原子读改写(保留其他字段)。
//!
//! 容错:文件不存在 → 写时自建;JSON 解析失败 → 读返 null / 写直接覆盖为 {"theme":"X"}。

const std = @import("std");
const theme_mod = @import("theme.zig");

/// 读取 home 目录下 ~/.metacodes/config.json 的 theme 字段。
/// 返回:成功且字段存在合法 → Variant;否则 null。
pub fn loadTheme(alloc: std.mem.Allocator, home: []const u8) ?theme_mod.Variant {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path_z = std.fmt.bufPrint(&path_buf, "{s}/.metacodes/config.json\x00", .{home}) catch return null;
    const path = path_z[0 .. path_z.len - 1];

    const content = readFile(alloc, path) catch return null;
    defer alloc.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const t = parsed.value.object.get("theme") orelse return null;
    if (t != .string) return null;
    return theme_mod.parseVariant(t.string);
}

/// 写入 theme 字段。原子读改写:读 → 改/插 → 写回。
/// 文件不存在 → 自动 mkdir ~/.metacodes + 创建。其它 IO 错误 → 返回 error。
pub fn saveTheme(alloc: std.mem.Allocator, home: []const u8, variant: theme_mod.Variant) !void {
    // 确保 ~/.metacodes 存在
    var dir_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const dir_z = try std.fmt.bufPrint(&dir_buf, "{s}/.metacodes\x00", .{home});
    _ = std.c.mkdir(@ptrCast(dir_z.ptr), 0o755); // 已存在 EEXIST 忽略

    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path_z = try std.fmt.bufPrint(&path_buf, "{s}/.metacodes/config.json\x00", .{home});
    const path = path_z[0 .. path_z.len - 1];

    // 读旧内容(可能没有);解析失败 → 直接覆盖
    const old = readFile(alloc, path) catch null;
    defer if (old) |o| alloc.free(o);

    var new_json: []u8 = undefined;
    if (old) |content| {
        if (std.json.parseFromSlice(std.json.Value, alloc, content, .{})) |*parsed_v| {
            var parsed = parsed_v.*;
            defer parsed.deinit();
            if (parsed.value == .object) {
                // 替换/插入 theme(parsed.value 的 ObjectMap 是 parsed.arena 拥有,
                // 我们这里只需要重新序列化字符串)。简化:跑一个 stringify。
                new_json = try writeWithTheme(alloc, parsed.value, theme_mod.variantName(variant));
            } else {
                new_json = try defaultJson(alloc, theme_mod.variantName(variant));
            }
        } else |_| {
            new_json = try defaultJson(alloc, theme_mod.variantName(variant));
        }
    } else {
        new_json = try defaultJson(alloc, theme_mod.variantName(variant));
    }
    defer alloc.free(new_json);

    try writeFile(path, new_json);
}

// ============================================================================
// 内部 helpers
// ============================================================================

fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len + 1 > pbuf.len) return error.PathTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = std.c.open(@ptrCast(&pbuf), std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);

    var all: std.ArrayList(u8) = .empty;
    errdefer all.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try all.appendSlice(alloc, buf[0..@intCast(n)]);
    }
    return try all.toOwnedSlice(alloc);
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len + 1 > pbuf.len) return error.PathTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = std.c.open(@ptrCast(&pbuf), std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.WriteFailed;
    defer _ = std.c.close(fd);

    var written: usize = 0;
    while (written < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + written, bytes.len - written);
        if (n < 0) return error.WriteFailed;
        if (n == 0) break;
        written += @intCast(n);
    }
}

/// 重新写整个 JSON object,只把 theme 字段改成新值。
/// 简化:遍历 ObjectMap entries,逐字段序列化,theme 字段值用 new_theme。
fn writeWithTheme(alloc: std.mem.Allocator, value: std.json.Value, new_theme: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '{');
    var it = value.object.iterator();
    var first = true;
    var saw_theme = false;
    while (it.next()) |entry| {
        if (!first) try out.append(alloc, ',');
        first = false;
        try out.append(alloc, '"');
        try writeEscaped(&out, alloc, entry.key_ptr.*);
        try out.appendSlice(alloc, "\":");
        if (std.mem.eql(u8, entry.key_ptr.*, "theme")) {
            saw_theme = true;
            try out.append(alloc, '"');
            try writeEscaped(&out, alloc, new_theme);
            try out.append(alloc, '"');
        } else {
            try writeValue(&out, alloc, entry.value_ptr.*);
        }
    }
    if (!saw_theme) {
        if (!first) try out.append(alloc, ',');
        try out.appendSlice(alloc, "\"theme\":\"");
        try writeEscaped(&out, alloc, new_theme);
        try out.append(alloc, '"');
    }
    try out.append(alloc, '}');
    try out.append(alloc, '\n');
    return try out.toOwnedSlice(alloc);
}

fn defaultJson(alloc: std.mem.Allocator, theme_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"theme\":\"{s}\"}}\n", .{theme_name});
}

fn writeEscaped(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, c),
        }
    }
}

fn writeValue(out: *std.ArrayList(u8), alloc: std.mem.Allocator, v: std.json.Value) !void {
    switch (v) {
        .null => try out.appendSlice(alloc, "null"),
        .bool => |b| try out.appendSlice(alloc, if (b) "true" else "false"),
        .integer => |i| try out.print(alloc, "{d}", .{i}),
        .float => |f| try out.print(alloc, "{d}", .{f}),
        .number_string => |s| try out.appendSlice(alloc, s),
        .string => |s| {
            try out.append(alloc, '"');
            try writeEscaped(out, alloc, s);
            try out.append(alloc, '"');
        },
        .array => |arr| {
            try out.append(alloc, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try out.append(alloc, ',');
                try writeValue(out, alloc, item);
            }
            try out.append(alloc, ']');
        },
        .object => |o| {
            try out.append(alloc, '{');
            var it = o.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try out.append(alloc, ',');
                first = false;
                try out.append(alloc, '"');
                try writeEscaped(out, alloc, entry.key_ptr.*);
                try out.appendSlice(alloc, "\":");
                try writeValue(out, alloc, entry.value_ptr.*);
            }
            try out.append(alloc, '}');
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "defaultJson 形状" {
    const s = try defaultJson(testing.allocator, "dark");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("{\"theme\":\"dark\"}\n", s);
}

test "writeWithTheme: 改现有字段" {
    const src = "{\"theme\":\"dark\",\"other\":42}";
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    const out = try writeWithTheme(testing.allocator, parsed.value, "light");
    defer testing.allocator.free(out);
    // 应含 "theme":"light" 和 "other":42
    try testing.expect(std.mem.indexOf(u8, out, "\"theme\":\"light\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"other\":42") != null);
}

test "writeWithTheme: 字段不存在时追加" {
    const src = "{\"other\":\"x\"}";
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    const out = try writeWithTheme(testing.allocator, parsed.value, "mono");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"theme\":\"mono\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"other\":\"x\"") != null);
}

test "loadTheme + saveTheme 往返(临时 home)" {
    const pid: i64 = std.c.getpid();
    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/cczig_thtest_{d}", .{pid});
    var dir_z: [129]u8 = undefined;
    @memcpy(dir_z[0..dir.len], dir);
    dir_z[dir.len] = 0;
    _ = std.c.mkdir(@ptrCast(&dir_z), 0o755);
    defer {
        // 清理 ~/.metacodes/config.json + ~/.metacodes + tmp 目录
        var p1_buf: [256]u8 = undefined;
        const p1 = std.fmt.bufPrint(&p1_buf, "{s}/.metacodes/config.json\x00", .{dir}) catch unreachable;
        _ = std.c.unlink(@ptrCast(p1.ptr));
        var p2_buf: [256]u8 = undefined;
        const p2 = std.fmt.bufPrint(&p2_buf, "{s}/.metacodes\x00", .{dir}) catch unreachable;
        _ = std.c.rmdir(@ptrCast(p2.ptr));
        _ = std.c.rmdir(@ptrCast(&dir_z));
    }

    // 初始无文件 → loadTheme = null
    try testing.expect(loadTheme(testing.allocator, dir) == null);

    // saveTheme(.light) → 文件创建 + loadTheme=light
    try saveTheme(testing.allocator, dir, .light);
    const got = loadTheme(testing.allocator, dir).?;
    try testing.expectEqual(theme_mod.Variant.light, got);

    // 改 .dark → loadTheme=dark(替换字段,不是追加)
    try saveTheme(testing.allocator, dir, .dark);
    const got2 = loadTheme(testing.allocator, dir).?;
    try testing.expectEqual(theme_mod.Variant.dark, got2);
}
