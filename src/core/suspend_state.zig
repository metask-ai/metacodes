//! L3 suspend 状态:挂起元数据的落盘/读取(suspend.json)。
//!
//! 挂起时 conversation 走 transcript(已有);本模块管**挂起点元数据**——pending 的 tool_use_id
//! + custom kind/payload。跨进程/重启恢复:新进程 loadTranscript 重建对话 + 读 suspend.json
//! 知道"哪个 tool_use 等响应、什么界面",注入响应后 resumeRun 续跑。
//!
//! 纯数据 JSON,放 session_dir/suspend.json(与 transcript.jsonl 同目录)。

const std = @import("std");
const pfs = @import("platform").fs;
const log = @import("../util/log.zig");

pub const SuspendState = struct {
    tool_use_id: []const u8,
    kind: []const u8,
    payload_json: []const u8,
    /// 同轮已完成工具的结果(resume 时与挂起点迟来结果一起补,满足 API 同 turn 配对)。
    completed_results: []const CompletedResult = &.{},

    pub const CompletedResult = struct {
        tool_use_id: []const u8,
        content: []const u8,
        is_error: bool,
    };
};

/// 写 {session_dir}/suspend.json。失败记 warn(不 panic;挂起仍可经内存恢复)。
pub fn write(session_dir: []const u8, state: SuspendState, allocator: std.mem.Allocator) !void {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/suspend.json\x00", .{session_dir});
    const json = try std.json.Stringify.valueAlloc(allocator, state, .{});
    defer allocator.free(json);
    const fd = pfs.open(@ptrCast(path.ptr), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    var off: usize = 0;
    while (off < json.len) {
        const n = pfs.write(fd, json[off..][0 .. json.len - off]);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

/// 读 {session_dir}/suspend.json。返回的 SuspendState 字段 owned by allocator(caller free)。
/// 无文件 → error.OpenFailed(调用方据此知道该 session 未挂起)。
pub fn read(session_dir: []const u8, allocator: std.mem.Allocator) !SuspendState {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/suspend.json\x00", .{session_dir});
    const fd = pfs.open(@ptrCast(path.ptr), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    var all = std.ArrayList(u8).empty;
    defer all.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buf);
        if (n <= 0) break;
        try all.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    const parsed = try std.json.parseFromSlice(SuspendState, allocator, all.items, .{});
    defer parsed.deinit();
    // 深拷贝逃逸 parsed 的 arena。
    const crs = try allocator.alloc(SuspendState.CompletedResult, parsed.value.completed_results.len);
    errdefer allocator.free(crs);
    for (parsed.value.completed_results, 0..) |cr, i| {
        crs[i] = .{
            .tool_use_id = try allocator.dupe(u8, cr.tool_use_id),
            .content = try allocator.dupe(u8, cr.content),
            .is_error = cr.is_error,
        };
    }
    return .{
        .tool_use_id = try allocator.dupe(u8, parsed.value.tool_use_id),
        .kind = try allocator.dupe(u8, parsed.value.kind),
        .payload_json = try allocator.dupe(u8, parsed.value.payload_json),
        .completed_results = crs,
    };
}

/// 释放 read() 返回的 SuspendState 的所有 owned 内存。
pub fn freeState(state: SuspendState, allocator: std.mem.Allocator) void {
    allocator.free(state.tool_use_id);
    allocator.free(state.kind);
    allocator.free(state.payload_json);
    for (state.completed_results) |cr| {
        allocator.free(cr.tool_use_id);
        allocator.free(cr.content);
    }
    allocator.free(state.completed_results);
}

/// 删 suspend.json(resume 成功后清理,避免重复恢复)。幂等(无文件不报错)。
pub fn clear(session_dir: []const u8) void {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/suspend.json\x00", .{session_dir}) catch return;
    _ = std.c.unlink(@ptrCast(path.ptr));
}

/// 便利:直接从 agent_loop.SuspendInfo 落盘(避免每个调用点手转 CompletedResult)。
/// si 的字段借用(write 内部序列化即拷贝),不接管所有权。
pub fn writeFromSuspendInfo(session_dir: []const u8, si: anytype, allocator: std.mem.Allocator) !void {
    var crs = try allocator.alloc(SuspendState.CompletedResult, si.completed_results.len);
    defer allocator.free(crs);
    for (si.completed_results, 0..) |cr, i| crs[i] = .{ .tool_use_id = cr.tool_use_id, .content = cr.content, .is_error = cr.is_error };
    try write(session_dir, .{ .tool_use_id = si.tool_use_id, .kind = si.kind, .payload_json = si.payload_json, .completed_results = crs }, allocator);
}

// ── 测试 ─────────────────────────────────────────────────────────────────

test "suspend state 落盘往返 + clear" {
    const a = std.testing.allocator;
    // per-pid 临时目录(避免并发 test artifact 撞固定路径,见 tools/test_tmp.zig 教训),结束删掉。
    var dirbuf: [512]u8 = undefined;
    const dir = @import("../util/fs.zig").testing.perPidDir(&dirbuf, "cc-zig-suspend-test");
    _ = pfs.mkdir(dir.ptr, 0o700);
    defer @import("../util/fs.zig").testing.rmrfBestEffort(dir);

    try write(dir, .{ .tool_use_id = "tu_42", .kind = "video_timeline", .payload_json = "{\"clips\":3}" }, a);
    const got = try read(dir, a);
    defer freeState(got, a);
    try std.testing.expectEqualStrings("tu_42", got.tool_use_id);
    try std.testing.expectEqualStrings("video_timeline", got.kind);
    try std.testing.expectEqualStrings("{\"clips\":3}", got.payload_json);

    // 带 completed_results 的往返。
    const crs = [_]SuspendState.CompletedResult{.{ .tool_use_id = "tu_b", .content = "{\"ok\":1}", .is_error = false }};
    try write(dir, .{ .tool_use_id = "tu_42", .kind = "k", .payload_json = "{}", .completed_results = &crs }, a);
    const got2 = try read(dir, a);
    defer freeState(got2, a);
    try std.testing.expectEqual(@as(usize, 1), got2.completed_results.len);
    try std.testing.expectEqualStrings("tu_b", got2.completed_results[0].tool_use_id);

    clear(dir);
    try std.testing.expectError(error.OpenFailed, read(dir, a));
}
