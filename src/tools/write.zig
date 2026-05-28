const std = @import("std");
const common = @import("common.zig");
const security = @import("security.zig");
const read_state = @import("../core/read_state.zig");
const ToolContext = @import("context.zig").ToolContext;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const path = common.extractJsonArg(args, "path") orelse return error.MissingPath;
    const content = common.extractJsonArg(args, "content") orelse return error.MissingContent;
    if (path.len == 0) return error.EmptyPath;
    try security.validateNoTraversal(path);

    // must-read-first 校验：若挂了 ReadState（正式 agent 路径），文件存在但没读过 → 拒绝
    // 两个例外：1) 文件不存在（即将创建）；2) ReadState 未挂（单测/dev 路径）
    if (ctx.read_state) |rs| {
        const exists = read_state.statPath(path) catch |err| switch (err) {
            error.StatFailed => null, // 文件不存在，允许创建
            else => return err,
        };
        if (exists) |st| {
            const rec = rs.get(path) orelse return error.NotRead;
            if (rec.mtime_ns != st.mtime_ns) return error.StaleFile;
        }
    }

    // 自动建父目录（对齐 TS：Write 到不存在的目录会先 mkdir -p）。
    try mkdirParents(path);

    // 写前抓旧内容（用于 structuredPatch / gitDiff）。文件不存在 → 旧内容为空。
    const old_content = readExisting(allocator, path) catch null;
    defer if (old_content) |oc| allocator.free(oc);

    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666) catch return error.WriteError;
    defer _ = std.c.close(fd);

    var pos: usize = 0;
    while (pos < content.len) {
        const remaining = content.len - pos;
        const n = std.c.write(fd, content.ptr + pos, remaining);
        if (n <= 0) return error.WriteError;
        pos += @as(usize, @intCast(n));
    }

    // 写完后刷新 ReadState 的 mtime，让紧接着的下一轮 Edit 仍然合法（不误报 stale）
    if (ctx.read_state) |rs| {
        const st = read_state.statFd(fd) catch null;
        if (st) |s| rs.record(path, s.mtime_ns, s.size) catch {};
    }

    return try renderResult(allocator, path, old_content orelse "", content);
}

/// 读已存在文件全文（不存在返 error）。供 Write 计算 diff。
fn readExisting(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer _ = std.c.close(fd);
    return try common.readAllFromFd(fd, allocator);
}

/// 渲染 Write 成功结果：success + path + structuredPatch + gitDiff。
fn renderResult(allocator: std.mem.Allocator, path: []const u8, old_content: []const u8, new_content: []const u8) ![]u8 {
    const patch_mod = @import("../core/patch.zig");
    var patch = patch_mod.compute(allocator, old_content, new_content) catch {
        // diff 失败不致命：退回最简结果
        return try std.fmt.allocPrint(allocator, "{{\"success\":true, \"path\": \"{s}\"}}", .{path});
    };
    defer patch.deinit(allocator);

    const structured = try patch_mod.toStructuredJson(allocator, patch.hunks);
    defer allocator.free(structured);
    const git_diff = try patch_mod.toGitDiff(allocator, path, patch.hunks);
    defer allocator.free(git_diff);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"success\":true,\"path\":");
    try std.json.Stringify.encodeJsonString(path, .{}, &out.writer);
    try out.writer.writeAll(",\"structuredPatch\":");
    try out.writer.writeAll(structured);
    try out.writer.writeAll(",\"gitDiff\":");
    try std.json.Stringify.encodeJsonString(git_diff, .{}, &out.writer);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

/// 为 path 创建所有缺失的父目录（等价 mkdir -p 到 dirname）。已存在的目录忽略。
/// 失败（权限等）静默返回——后续 openat 会以 WriteError 暴露真正问题。
fn mkdirParents(path: []const u8) !void {
    // 找最后一个 '/'，其左侧即父目录路径
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return; // 无目录分量
    if (slash == 0) return; // 直接在根目录下，无需建
    const dir = path[0..slash];

    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (dir.len >= buf.len) return error.PathTooLong;

    // 逐级建：对每个 '/' 位置，把到该处的前缀 mkdir 一次
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            @memcpy(buf[0..i], dir[0..i]);
            buf[i] = 0;
            const seg_z: [*:0]const u8 = @ptrCast(&buf);
            // mkdir 返回 <0 且 errno=EEXIST 时忽略
            if (std.c.mkdir(seg_z, 0o755) != 0) {
                const errno = std.c._errno().*;
                if (errno != @intFromEnum(std.c.E.EXIST)) {
                    // 其它错误（如权限）不在此处 fatal——交给 openat
                    return;
                }
            }
        }
    }
}

fn testCtx() ToolContext {
    return ToolContext.simple(std.testing.allocator);
}

test "WriteTool missing path" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingPath, execute(&ctx, "{\"content\":\"test\"}"));
}

test "WriteTool missing content" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingContent, execute(&ctx, "{\"path\":\"/tmp/x\"}"));
}

test "WriteTool path traversal blocked" {
    const ctx = testCtx();
    try std.testing.expectError(error.PathTraversal, execute(&ctx, "{\"path\":\"../etc/x\",\"content\":\"y\"}"));
}

test "WriteTool create file" {
    const ctx = testCtx();
    const args = "{\"path\":\"/tmp/cc-zig-write-test.txt\",\"content\":\"hello\"}";
    const result = try execute(&ctx, args);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
    _ = std.c.unlink("/tmp/cc-zig-write-test.txt");
}

test "WriteTool auto-mkdir creates missing parent directory" {
    const ctx = testCtx();
    const path = "/tmp/cc-zig-mkdir-parent-9a8b/sub/foo.txt";
    const args = "{\"path\":\"/tmp/cc-zig-mkdir-parent-9a8b/sub/foo.txt\",\"content\":\"x\"}";
    const result = try execute(&ctx, args);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
    // cleanup
    _ = std.c.unlink(path);
    _ = std.c.rmdir("/tmp/cc-zig-mkdir-parent-9a8b/sub");
    _ = std.c.rmdir("/tmp/cc-zig-mkdir-parent-9a8b");
}

test "WriteTool not-read-first rejects existing file" {
    const a = std.testing.allocator;
    const path = "/tmp/cc-zig-write-mrf-test.txt";
    defer _ = std.c.unlink(path);
    // 先存在一个文件（外部创建）
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = std.c.write(fd, "old", 3);
    _ = std.c.close(fd);

    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();

    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    try std.testing.expectError(error.NotRead, execute(&ctx, "{\"path\":\"/tmp/cc-zig-write-mrf-test.txt\",\"content\":\"new\"}"));
}

test "WriteTool creating new file does not require read" {
    const a = std.testing.allocator;
    const path = "/tmp/cc-zig-write-new-test.txt";
    _ = std.c.unlink(path); // 确保不存在
    defer _ = std.c.unlink(path);

    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();

    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    const result = try execute(&ctx, "{\"path\":\"/tmp/cc-zig-write-new-test.txt\",\"content\":\"hello\"}");
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
}

test "WriteTool stale file rejected" {
    const a = std.testing.allocator;
    const path = "/tmp/cc-zig-write-stale-test.txt";
    defer _ = std.c.unlink(path);

    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = std.c.write(fd, "v1", 2);
    _ = std.c.close(fd);

    var rs = @import("../core/read_state.zig").ReadState.init(a);
    defer rs.deinit();
    // 手工记录一个假 mtime，模拟"读完后外部改了"
    try rs.record(path, 1, 2);

    const ctx = ToolContext{ .allocator = a, .read_state = &rs };
    try std.testing.expectError(error.StaleFile, execute(&ctx, "{\"path\":\"/tmp/cc-zig-write-stale-test.txt\",\"content\":\"v2\"}"));
}
