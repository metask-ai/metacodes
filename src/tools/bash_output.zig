//! BashOutput：查询后台作业的输出和状态。
//!
//! input 参数：
//!   - `job_id` (必填)：12-hex job id
//!   - `stdout`：true/false，默认 true
//!   - `stderr`：true/false，默认 true
//!   - `stdout_since_byte`：从 stdout 文件的第 N 字节开始读（增量）。默认 0（全读）。
//!   - `stderr_since_byte`：同上对 stderr。
//!   - `max_bytes`：单次读出上限（防单 turn tool_result 塞爆 context）。默认 65536。
//!
//! output:
//!   {
//!     "job_id":"...","status":"running|exited|killed","exit_code":N?,
//!     "stdout":"...","stdout_total_bytes":N,"stdout_truncated":bool,
//!     "stderr":"...","stderr_total_bytes":N,"stderr_truncated":bool
//!   }
//!
//! 模型应该在下一次轮询时传 stdout_since_byte = 上次 stdout_total_bytes 做增量。
//! truncated=true 表示本次没读完，需要提高 since_byte（或 max_bytes）。

const std = @import("std");
const time = @import("../util/time.zig");
const pfs = @import("platform").fs;
const common = @import("common.zig");
const ToolContext = @import("context.zig").ToolContext;

/// 单次 tool_result 中 stdout/stderr 的默认字节上限；避免 100MB 文件塞爆 context。
const DEFAULT_MAX_BYTES: usize = 64 * 1024;
const MAX_MAX_BYTES: usize = 256 * 1024;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const job_id = common.extractJsonArg(args, "job_id") orelse return error.MissingJobId;
    const registry = ctx.jobs orelse return error.JobsNotAvailable;

    // 先 reap 一次最新状态
    registry.reapExited();

    const job = registry.get(job_id) orelse return error.JobNotFound;

    const want_stdout = if (common.extractJsonArg(args, "stdout")) |v| !std.mem.eql(u8, v, "false") else true;
    const want_stderr = if (common.extractJsonArg(args, "stderr")) |v| !std.mem.eql(u8, v, "false") else true;
    const stdout_since = parseUsizeArg(args, "stdout_since_byte") orelse 0;
    const stderr_since = parseUsizeArg(args, "stderr_since_byte") orelse 0;
    const max_bytes = parseUsizeArg(args, "max_bytes") orelse DEFAULT_MAX_BYTES;
    if (max_bytes == 0 or max_bytes > MAX_MAX_BYTES) {
        common.setErrorDetail(ctx.error_detail, allocator, "BashOutput max_bytes must be in 1..{d}", .{MAX_MAX_BYTES});
        return error.InvalidMaxBytes;
    }

    var stdout_chunk: Chunk = .{};
    var stderr_chunk: Chunk = .{};
    defer stdout_chunk.deinit(allocator);
    defer stderr_chunk.deinit(allocator);

    if (want_stdout) {
        stdout_chunk = readFileRange(job.stdout_path, stdout_since, max_bytes, allocator) catch .{};
    }
    if (want_stderr) {
        stderr_chunk = readFileRange(job.stderr_path, stderr_since, max_bytes, allocator) catch .{};
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"job_id\":");
    try std.json.Stringify.encodeJsonString(job_id, .{}, &aw.writer);
    try aw.writer.print(",\"status\":\"{s}\"", .{@tagName(job.status)});
    if (job.exit_code) |ec| {
        try aw.writer.print(",\"exit_code\":{d}", .{ec});
    }
    if (want_stdout) {
        try aw.writer.writeAll(",\"stdout\":");
        try std.json.Stringify.encodeJsonString(stdout_chunk.data, .{}, &aw.writer);
        try aw.writer.print(",\"stdout_total_bytes\":{d},\"stdout_truncated\":{s}", .{
            stdout_chunk.total_bytes,
            if (stdout_chunk.truncated) "true" else "false",
        });
    }
    if (want_stderr) {
        try aw.writer.writeAll(",\"stderr\":");
        try std.json.Stringify.encodeJsonString(stderr_chunk.data, .{}, &aw.writer);
        try aw.writer.print(",\"stderr_total_bytes\":{d},\"stderr_truncated\":{s}", .{
            stderr_chunk.total_bytes,
            if (stderr_chunk.truncated) "true" else "false",
        });
    }
    try aw.writer.writeAll("}");
    return try aw.toOwnedSlice();
}

const Chunk = struct {
    data: []const u8 = &.{},
    total_bytes: u64 = 0, // 文件整体大小（不只是本次读到的）
    truncated: bool = false, // 还没读完（文件还有剩）

    fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        if (self.data.len > 0) allocator.free(@constCast(self.data));
    }
};

/// 从 path 的 since 字节开始读最多 max 字节。若文件更大，truncated=true。
/// total_bytes 是文件整体大小（便于模型决定下次 since）。
fn readFileRange(path: []const u8, since: usize, max: usize, allocator: std.mem.Allocator) !Chunk {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= pbuf.len) return error.PathTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&pbuf), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);

    // lseek 到 end 取 total_bytes(可移植 pfs.lseek,POSIX lseek / Windows _lseek)
    const total = pfs.lseek(fd, 0, .end);
    if (total < 0) return error.SeekFailed;
    const total_u: u64 = @intCast(total);

    if (since >= total_u) return .{ .total_bytes = total_u };

    _ = pfs.lseek(fd, @intCast(since), .set);

    const available = total_u - since;
    const to_read: usize = @intCast(@min(@as(u64, max), available));
    const truncated = to_read < available;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, to_read);

    var buf: [4096]u8 = undefined;
    var remaining = to_read;
    while (remaining > 0) {
        const chunk_size = @min(remaining, buf.len);
        const n = pfs.read(fd, buf[0..chunk_size]);
        if (n <= 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
        remaining -= @intCast(n);
    }

    return .{
        .data = try out.toOwnedSlice(allocator),
        .total_bytes = total_u,
        .truncated = truncated,
    };
}

fn parseUsizeArg(args: []const u8, field: []const u8) ?usize {
    const s = common.extractJsonArg(args, field) orelse return null;
    return std.fmt.parseInt(usize, s, 10) catch null;
}

test "BashOutput on nonexistent job" {
    const a = std.testing.allocator;
    var r = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer r.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &r };
    try std.testing.expectError(error.JobNotFound, execute(&ctx, "{\"job_id\":\"deadbeef0001\"}"));
}

test "BashOutput returns stdout after exit" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    const a = std.testing.allocator;
    var r = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer r.deinit();
    const j = try r.spawnBackground("echo hello; exit 0", null);

    // 等子进程结束
    time.sleepMs(200);

    var args_buf: [128]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"job_id\":\"{s}\"}}", .{j.id[0..]});

    const ctx = ToolContext{ .allocator = a, .jobs = &r };
    const result = try execute(&ctx, args);
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"exit_code\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"status\":\"exited\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout_total_bytes\":6") != null); // "hello\n"
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout_truncated\":false") != null);
}

test "BashOutput since_byte skips prefix" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    const a = std.testing.allocator;
    var r = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer r.deinit();
    const j = try r.spawnBackground("printf 'ABCDEFG'; exit 0", null);

    time.sleepMs(200);

    var args_buf: [128]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"job_id\":\"{s}\",\"stdout_since_byte\":\"3\"}}", .{j.id[0..]});

    const ctx = ToolContext{ .allocator = a, .jobs = &r };
    const result = try execute(&ctx, args);
    defer a.free(result);
    // 只应看到 "DEFG"，不是 "ABCDEFG"
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout\":\"DEFG\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout_total_bytes\":7") != null);
}

test "BashOutput max_bytes truncates" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    const a = std.testing.allocator;
    var r = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer r.deinit();
    const j = try r.spawnBackground("printf 'ABCDEFGHIJ'; exit 0", null);

    time.sleepMs(200);

    var args_buf: [128]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"job_id\":\"{s}\",\"max_bytes\":\"3\"}}", .{j.id[0..]});

    const ctx = ToolContext{ .allocator = a, .jobs = &r };
    const result = try execute(&ctx, args);
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout\":\"ABC\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout_total_bytes\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout_truncated\":true") != null);
}
