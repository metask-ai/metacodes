//! .claude/settings.local.json 的增量写入(P2.2 权限 always 持久化)。
//!
//! 用途:用户在权限对话框选 "Yes, always" 时,把工具规则写到 project 的
//! .claude/settings.local.json 的 permissions.allow 数组,下次 cc-zig 启动
//! settings.evaluate 即识别为 allow,真正"不再问"。
//!
//! 路径选择:有 project_dir(在 git repo)→ `<project>/.claude/settings.local.json`;
//! 否则 → `~/.claude/settings.json`(用户级,所有 project 生效)。
//!
//! 规则格式:
//! - 工具裸名(如 "Bash" / "Read")→ 添加裸名(整工具放行)
//! - 已存在则跳过(不重复)
//!
//! 容错:文件不存在 → 创建 + 完整 JSON;parse 失败 → log + 不写(避免覆盖损坏的 settings)。

const std = @import("std");
const pfs = @import("platform").fs;
const util_json = @import("../util/json.zig");

/// 把 rule 加入 settings.local.json 的 permissions.allow 数组。
/// project_dir 非 null → 优先用 project local;否则用 ~/.claude/settings.json。
/// 返回写入的文件路径(borrow from path_out)或 error。
pub fn addAllowRule(
    alloc: std.mem.Allocator,
    project_dir: ?[]const u8,
    home: []const u8,
    rule: []const u8,
    path_out: []u8,
) ![]const u8 {
    const path = pickPath(project_dir, home, path_out) orelse return error.NoTargetPath;

    // 确保目录存在
    try ensureDir(path);

    // 读旧内容(不存在视作空)
    const old = readFile(alloc, path) catch null;
    defer if (old) |o| alloc.free(o);

    if (old) |content| {
        if (std.json.parseFromSlice(std.json.Value, alloc, content, .{})) |*parsed_v| {
            var parsed = parsed_v.*;
            defer parsed.deinit();
            if (parsed.value == .object) {
                const new_json = try rewriteWithAllow(alloc, parsed.value, rule);
                defer alloc.free(new_json);
                try writeFile(path, new_json);
                return path;
            } else {
                return error.MalformedSettings;
            }
        } else |_| {
            return error.MalformedSettings;
        }
    }

    // 文件不存在 → 创建 fresh
    var fresh_builder: std.ArrayList(u8) = .empty;
    errdefer fresh_builder.deinit(alloc);
    try fresh_builder.appendSlice(alloc, "{\"permissions\":{\"allow\":[");
    try util_json.serializeString(rule, &fresh_builder, alloc);
    try fresh_builder.appendSlice(alloc, "]}}\n");
    const fresh = try fresh_builder.toOwnedSlice(alloc);
    defer alloc.free(fresh);
    try writeFile(path, fresh);
    return path;
}

fn pickPath(project_dir: ?[]const u8, home: []const u8, buf: []u8) ?[]const u8 {
    if (project_dir) |p| {
        const s = std.fmt.bufPrint(buf, "{s}/.claude/settings.local.json", .{p}) catch return null;
        return s;
    }
    const s = std.fmt.bufPrint(buf, "{s}/.claude/settings.json", .{home}) catch return null;
    return s;
}

fn ensureDir(path: []const u8) !void {
    // 从 path 倒推到最后一个 `/`,创建 parent dir(不递归)
    const sep = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    var dir_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (sep + 1 > dir_buf.len) return error.PathTooLong;
    @memcpy(dir_buf[0..sep], path[0..sep]);
    dir_buf[sep] = 0;
    // mkdir 不存在则建,EEXIST 忽略;父父级不存在直接失败(让 caller 报错)
    _ = pfs.mkdir(@ptrCast(&dir_buf), 0o755);
}

fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len + 1 > pbuf.len) return error.PathTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&pbuf), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = pfs.close(fd);
    var all: std.ArrayList(u8) = .empty;
    errdefer all.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buf);
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
    const fd = pfs.open(@ptrCast(&pbuf), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.WriteFailed;
    defer _ = pfs.close(fd);
    var written: usize = 0;
    while (written < bytes.len) {
        const n = pfs.write(fd, bytes[written..][0 .. bytes.len - written]);
        if (n < 0) return error.WriteFailed;
        if (n == 0) break;
        written += @intCast(n);
    }
}

/// 重写整个 JSON,把 permissions.allow 数组里加入 new_rule(去重)。
/// permissions 不存在则创建;allow 不存在则创建。
fn rewriteWithAllow(alloc: std.mem.Allocator, value: std.json.Value, new_rule: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.append(alloc, '{');
    var it = value.object.iterator();
    var first = true;
    var saw_perms = false;
    while (it.next()) |entry| {
        if (!first) try out.append(alloc, ',');
        first = false;
        try out.append(alloc, '"');
        try writeEscaped(&out, alloc, entry.key_ptr.*);
        try out.appendSlice(alloc, "\":");
        if (std.mem.eql(u8, entry.key_ptr.*, "permissions")) {
            saw_perms = true;
            try writePermsWithAllow(&out, alloc, entry.value_ptr.*, new_rule);
        } else {
            try writeValue(&out, alloc, entry.value_ptr.*);
        }
    }
    if (!saw_perms) {
        if (!first) try out.append(alloc, ',');
        try out.appendSlice(alloc, "\"permissions\":{\"allow\":[\"");
        try writeEscaped(&out, alloc, new_rule);
        try out.appendSlice(alloc, "\"]}");
    }
    try out.append(alloc, '}');
    try out.append(alloc, '\n');
    return try out.toOwnedSlice(alloc);
}

fn writePermsWithAllow(out: *std.ArrayList(u8), alloc: std.mem.Allocator, perms: std.json.Value, new_rule: []const u8) !void {
    if (perms != .object) {
        // 非 object,覆盖为 {"allow":["X"]}
        try out.appendSlice(alloc, "{\"allow\":[\"");
        try writeEscaped(out, alloc, new_rule);
        try out.appendSlice(alloc, "\"]}");
        return;
    }
    try out.append(alloc, '{');
    var it = perms.object.iterator();
    var first = true;
    var saw_allow = false;
    while (it.next()) |entry| {
        if (!first) try out.append(alloc, ',');
        first = false;
        try out.append(alloc, '"');
        try writeEscaped(out, alloc, entry.key_ptr.*);
        try out.appendSlice(alloc, "\":");
        if (std.mem.eql(u8, entry.key_ptr.*, "allow")) {
            saw_allow = true;
            try writeAllowWithRule(out, alloc, entry.value_ptr.*, new_rule);
        } else {
            try writeValue(out, alloc, entry.value_ptr.*);
        }
    }
    if (!saw_allow) {
        if (!first) try out.append(alloc, ',');
        try out.appendSlice(alloc, "\"allow\":[\"");
        try writeEscaped(out, alloc, new_rule);
        try out.appendSlice(alloc, "\"]");
    }
    try out.append(alloc, '}');
}

fn writeAllowWithRule(out: *std.ArrayList(u8), alloc: std.mem.Allocator, allow: std.json.Value, new_rule: []const u8) !void {
    if (allow != .array) {
        // 非 array,覆盖为 ["X"]
        try out.append(alloc, '[');
        try out.append(alloc, '"');
        try writeEscaped(out, alloc, new_rule);
        try out.appendSlice(alloc, "\"]");
        return;
    }
    try out.append(alloc, '[');
    var already = false;
    for (allow.array.items, 0..) |item, i| {
        if (i > 0) try out.append(alloc, ',');
        try writeValue(out, alloc, item);
        if (item == .string and std.mem.eql(u8, item.string, new_rule)) already = true;
    }
    if (!already) {
        if (allow.array.items.len > 0) try out.append(alloc, ',');
        try out.append(alloc, '"');
        try writeEscaped(out, alloc, new_rule);
        try out.append(alloc, '"');
    }
    try out.append(alloc, ']');
}

fn writeEscaped(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try util_json.serializeStringContents(s, out, alloc);
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

test "rewriteWithAllow: 空 settings 加新规则" {
    const src = "{}";
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    const out = try rewriteWithAllow(testing.allocator, parsed.value, "Bash");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"permissions\":{\"allow\":[\"Bash\"]}") != null);
}

test "rewriteWithAllow: 已有 permissions.allow 追加" {
    const src = "{\"permissions\":{\"allow\":[\"Read\"]}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    const out = try rewriteWithAllow(testing.allocator, parsed.value, "Bash");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"Read\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"Bash\"") != null);
}

test "rewriteWithAllow: 重复规则不追加" {
    const src = "{\"permissions\":{\"allow\":[\"Bash\"]}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    const out = try rewriteWithAllow(testing.allocator, parsed.value, "Bash");
    defer testing.allocator.free(out);
    // 只该出现一次 "Bash"
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, out, pos, "\"Bash\"")) |idx| {
        count += 1;
        pos = idx + 6;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "rewriteWithAllow: 保留其它顶层字段" {
    const src = "{\"theme\":\"dark\",\"other\":42}";
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    const out = try rewriteWithAllow(testing.allocator, parsed.value, "Bash");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"theme\":\"dark\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"other\":42") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"permissions\":{\"allow\":[\"Bash\"]}") != null);
}

test "addAllowRule: 端到端创建文件" {
    // per-pid 临时目录(POSIX /tmp,Windows %TEMP%),见 tools/test_tmp.zig 头注释。
    var home_buf: [512]u8 = undefined;
    const home = @import("../tools/test_tmp.zig").path(&home_buf, "cczig_psave");
    _ = pfs.mkdir(home.ptr, 0o755);
    defer {
        // 清理:.claude 子目录 + settings.json + home
        var p_buf: [std.fs.max_path_bytes]u8 = undefined;
        const p1 = std.fmt.bufPrintZ(&p_buf, "{s}/.claude/settings.json", .{home}) catch unreachable;
        _ = std.c.unlink(p1.ptr);
        var p2_buf: [std.fs.max_path_bytes]u8 = undefined;
        const p2 = std.fmt.bufPrintZ(&p2_buf, "{s}/.claude", .{home}) catch unreachable;
        _ = std.c.rmdir(p2.ptr);
        _ = std.c.rmdir(home.ptr);
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const written_path = try addAllowRule(testing.allocator, null, home, "Bash", &path_buf);
    try testing.expect(std.mem.endsWith(u8, written_path, "/.claude/settings.json"));

    // 验证文件存在 + 含 Bash
    var pz: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(pz[0..written_path.len], written_path);
    pz[written_path.len] = 0;
    try testing.expect(std.c.access(@ptrCast(&pz), std.c.F_OK) == 0);
    const content = try readFile(testing.allocator, written_path);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "\"Bash\"") != null);
}
