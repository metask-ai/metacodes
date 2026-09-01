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
const result_budget = @import("../core/result_budget.zig");

/// 单次 tool_result 中 stdout/stderr 的默认字节上限；避免 100MB 文件塞爆 context。
/// Fixed JSON scaffolding of one BashOutput result: job id, status, exit code,
/// both channels' byte counters and truncation flags.
const ENVELOPE_OVERHEAD_BYTES: result_budget.Encoded = .of(512);
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
    // Default from the turn's budget, not a private constant. 64 KiB of
    // *source* bytes was chosen against "do not blow up the context", but the
    // per-result budget counts *rendered* bytes and tops out at 64 KiB too -
    // two different 64Ks - so a default read of a large enough job produced a
    // 65_717-byte result that the projection layer then spilled to an
    // artifact, handing the model an envelope instead of the output it had
    // just asked for.
    //
    // How often, measured rather than assumed: across 314 real BashOutput
    // results the median is 164 bytes and exactly one exceeded a 200K-window
    // budget. Most polls of a background job return very little. So this is a
    // tail case, not the common path - worth fixing because the failure is
    // silent and the fix is the same one `ReadArtifact` already got, not
    // because it was happening constantly.
    const allowance = ctx.result_budget.payloadAllowance(ENVELOPE_OVERHEAD_BYTES);
    const max_bytes = parseUsizeArg(args, "max_bytes") orelse
        @max(1, @min(MAX_MAX_BYTES, allowance.raw()));
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
    // `max_bytes` bounds the *read*; what the model is charged for is the
    // rendered result, so the two channels share one encoded allowance the
    // same way a completed Bash result's channels do. A channel cut here is
    // still "not finished", which is what `truncated` already means, so the
    // caller's `since_byte` loop needs no new concept.
    const shares = result_budget.splitPair(
        allowance,
        result_budget.encodedCost(stdout_chunk.data, false),
        result_budget.encodedCost(stderr_chunk.data, false),
    );
    const stdout_shown = result_budget.headCut(stdout_chunk.data, shares.first, false);
    const stderr_shown = result_budget.headCut(stderr_chunk.data, shares.second, false);
    if (want_stdout) {
        try aw.writer.writeAll(",\"stdout\":");
        try std.json.Stringify.encodeJsonString(stdout_shown.head(stdout_chunk.data), .{}, &aw.writer);
        try aw.writer.print(",\"stdout_total_bytes\":{d},\"stdout_truncated\":{s}", .{
            stdout_chunk.total_bytes,
            if (stdout_chunk.truncated or stdout_shown.raw() < stdout_chunk.data.len) "true" else "false",
        });
    }
    if (want_stderr) {
        try aw.writer.writeAll(",\"stderr\":");
        try std.json.Stringify.encodeJsonString(stderr_shown.head(stderr_chunk.data), .{}, &aw.writer);
        try aw.writer.print(",\"stderr_total_bytes\":{d},\"stderr_truncated\":{s}", .{
            stderr_chunk.total_bytes,
            if (stderr_chunk.truncated or stderr_shown.raw() < stderr_chunk.data.len) "true" else "false",
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

test "BashOutput 的默认读取落在单条预算内" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // 默认值曾是 64KiB **源**字节,而 per-result 预算数的是**渲染后**字节、上限
    // 同样是 64KiB —— 两个不同的 64K。输出足够大时(下面构造的 100KB 纯 ASCII,
    // 已是最省字节的情形)默认读会产出 65_717 字节的结果,被投影层溢出成
    // artifact,模型拿回信封而不是它刚要的输出。
    //
    // 尾部情形而非常态:审计 314 次真实 BashOutput 结果,中位 164 字节,只有 1 次
    // 超过 200K 窗口的预算。值得修是因为它静默失败、且修法与 ReadArtifact 同源,
    // 不是因为它频繁发生。
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const j = try registry.spawnBackground("awk 'BEGIN { for(i=0;i<100000;i++) printf \"x\" }'", null);
    while (registry.get(j.idSlice())) |e| {
        if (e.status != .running) break;
        time.sleepMs(20);
        registry.reapExited();
    }
    registry.reapExited();

    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\"}}", .{j.idSlice()});
    defer a.free(args);

    // 窄窗口与宽窗口都必须落在各自预算内。
    for ([_]usize{ 200_000, 1_048_576 }) |window| {
        const budget = result_budget.Budget.fromModel(window);
        const ctx = ToolContext{ .allocator = a, .jobs = &registry, .result_budget = budget };
        const out = try execute(&ctx, args);
        defer a.free(out);
        try std.testing.expect(out.len <= budget.per_result_bytes);

        var parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
        defer parsed.deinit();
        // 没读完就得说没读完 —— 调用方靠它决定要不要继续推进 since_byte。
        try std.testing.expect(parsed.value.object.get("stdout_truncated").?.bool);
        // 而且仍然给出真正的内容,不是空壳。
        try std.testing.expect(parsed.value.object.get("stdout").?.string.len > 4096);
        try std.testing.expectEqual(@as(i64, 100_000), parsed.value.object.get("stdout_total_bytes").?.integer);
    }
}
