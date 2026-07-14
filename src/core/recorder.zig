//! 请求/响应录制器(Stage 7,record/replay)。
//!
//! `--record <dir>` / `METACODES_RECORD_DIR` 设置后,把每次 API 请求 body +
//! 对应 SSE 响应原始字节 dump 到 `<dir>/req-NNN.json` / `<dir>/sse-NNN.txt`,
//! 形成 cassette。replay 时 mock server 按序回放 → 固定模型输出,确定性复现。
//!
//! 设计:process-global(对齐 answer_queue / prompt.zig 惯例)。dir == null 时
//! 全部 no-op,client.zig / stream.zig 的 tap 点零开销,签名不变。
//!
//! **多 Session 说明(M7 决策)**:g_dir/g_seq 进程全局**故意保留**——record/replay 是单
//! session 的调试/e2e 路径(一次只录一个会话),非多 session 生产路径。强行 per-session 化是
//! 为不存在的需求加复杂度。真要并发录多会话时再按 session_id 分文件名(低优先级)。

const std = @import("std");
const pfs = @import("platform").fs;
const sync = @import("platform").sync;
const log = @import("../util/log.zig");

var g_dir: ?[]const u8 = null;
/// 请求序号(每次 recordRequest 递增),用于文件名 + 关联同一轮的 SSE。
var g_seq: u32 = 0;
/// 当前轮的 SSE 累积 buffer(recordSseLine 追加,finishSse 落盘)。
var g_sse_buf: [256 * 1024]u8 = undefined;
var g_sse_len: usize = 0;
var g_mutex: sync.Mutex = .{};

fn lock() void {
    _ = g_mutex.lock();
}
fn unlock() void {
    _ = g_mutex.unlock();
}

pub fn setDir(dir: []const u8) void {
    lock();
    defer unlock();
    g_dir = dir;
    // 建目录(单层;嵌套由 caller/shell 保证)。已存在则忽略。
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (dir.len + 1 <= pbuf.len) {
        @memcpy(pbuf[0..dir.len], dir);
        pbuf[dir.len] = 0;
        _ = std.c.mkdir(@ptrCast(&pbuf), @as(std.c.mode_t, 0o755));
    }
    log.info("recorder", "recording to {s}", .{dir});
}

pub fn isActive() bool {
    return g_dir != null;
}

/// 录一次请求 body。开启新一轮:递增 seq、清 SSE buffer、写 req-NNN.json。
pub fn recordRequest(body: []const u8) void {
    const dir = g_dir orelse return;
    lock();
    defer unlock();
    g_seq += 1;
    g_sse_len = 0;
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&name_buf, "{s}/req-{d:0>3}.json", .{ dir, g_seq }) catch return;
    writeFile(path, body);
}

/// 录一行 SSE(原始,含换行)。累积到当前轮 buffer。
pub fn recordSseLine(line: []const u8) void {
    if (g_dir == null) return;
    lock();
    defer unlock();
    if (g_sse_len + line.len + 1 > g_sse_buf.len) return; // 溢出保护
    @memcpy(g_sse_buf[g_sse_len..][0..line.len], line);
    g_sse_len += line.len;
    g_sse_buf[g_sse_len] = '\n';
    g_sse_len += 1;
}

/// 当前轮 SSE 收尾:把累积 buffer 落盘 sse-NNN.txt。
pub fn finishSse() void {
    const dir = g_dir orelse return;
    lock();
    defer unlock();
    if (g_sse_len == 0) return;
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&name_buf, "{s}/sse-{d:0>3}.txt", .{ dir, g_seq }) catch return;
    writeFile(path, g_sse_buf[0..g_sse_len]);
    g_sse_len = 0;
}

fn writeFile(path: []const u8, bytes: []const u8) void {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len + 1 > pbuf.len) return;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&pbuf), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) {
        log.warn("recorder", "create {s} failed", .{path});
        return;
    }
    defer _ = pfs.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = pfs.write(fd, bytes[off..][0..bytes.len - off]);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

pub fn resetForTest() void {
    g_dir = null;
    g_seq = 0;
    g_sse_len = 0;
}

test "recorder no-op when dir unset" {
    resetForTest();
    try std.testing.expect(!isActive());
    recordRequest("{}"); // 不崩
    recordSseLine("data: x");
    finishSse();
}
