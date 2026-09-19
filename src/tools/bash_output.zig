//! BashOutput：查询后台作业的输出和状态。
//!
//! input 参数：
//!   - `job_id` (必填)：12-hex job id
//!   - `stdout`：true/false，默认 true
//!   - `stderr`：true/false，默认 true
//!   - `stdout_since_byte`：从 stdout 文件的第 N 字节开始读（增量）。省略时续接该 job 的记忆游标。
//!   - `stderr_since_byte`：同上对 stderr。
//!   - `max_bytes`：单次读出上限。**没有固定默认值**,省略时由 `ctx.result_budget`
//!     派生(200K window 为 24488,预算下限为 7680);硬上限 262144。读到的内容还会
//!     按同一预算裁剪,余量走 `*_next_offset`。registry 里那份 property description
//!     由 `tests/component/tool_schema_coverage_test.zig` 绑回这些常量,不会再分叉。
//!   - `wait_ms`：无新内容时等待新字节或作业结束。省略默认 30 秒，0 为快照，最大 600 秒。
//!
//! output:两条通道对称,各带同样的四个字段(此前这里只列了 stdout 的
//! encoding/next_offset,stderr 的两个实际会发却没写——见 `writeChannel` 调用处)。
//!   {
//!     "job_id":"...","status":"running|exited|killed","exit_code":N?,
//!     "stdout":"...","stdout_encoding":"utf-8"|"base64",
//!     "stdout_total_bytes":N,"stdout_next_offset":N,"stdout_truncated":bool,
//!     "stderr":"...","stderr_encoding":"utf-8"|"base64",
//!     "stderr_total_bytes":N,"stderr_next_offset":N,"stderr_truncated":bool,
//!     "waited_ms":N
//!   }
//!
//! 续读只认 `*_next_offset`:下一次传 `stdout_since_byte = 上次 stdout_next_offset`。
//! 它等于 `since + 本次实际展示的字节数`。
//! `*_total_bytes` 是文件当前大小,**不是游标**——拿它当游标会跳过"本次展示到文件末尾"
//! 之间的全部内容(读取按预算限界后,这段通常不为空)。
//! `truncated=true` 表示本次没读完,继续从 `*_next_offset` 读即可;提高 `max_bytes`
//! 只在预算允许时有用,并不能替代游标。
//! `*_encoding` 按通道各自判定:该通道本次展示的字节不是合法 UTF-8 就发 base64
//! (`stdout` 与 `stderr` 可以一个 base64 一个 utf-8)。

const std = @import("std");
const time = @import("../util/time.zig");
const pfs = @import("platform").fs;
const common = @import("common.zig");
const ToolContext = @import("context.zig").ToolContext;
const result_budget = @import("../core/result_budget.zig");

/// 单次 tool_result 中 stdout/stderr 的默认字节上限；避免 100MB 文件塞爆 context。
/// Fixed JSON scaffolding of one BashOutput result: job id, status, exit code,
/// both channels' byte counters and truncation flags.
pub const ENVELOPE_OVERHEAD_BYTES: result_budget.Encoded = .of(512);
pub const MAX_MAX_BYTES: usize = 256 * 1024;
pub const DEFAULT_WAIT_MS: usize = 30_000;
pub const MAX_WAIT_MS: usize = 600_000;
const WAIT_POLL_SLICE_MS: u64 = 200;

// 2026-09-19 incident (session 000001a0b86114522f8eb6a0): 375 one-round-trip
// polls kept returning identical running snapshots. Long-polling plus remembered
// cursors makes one visible call wait for progress instead of replaying the spool.
// 2026-09-19 事故:375 次轮询反复返回相同 running 快照;长轮询与记忆游标合并修复。

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const job_id = common.extractJsonArg(args, "job_id") orelse return error.MissingJobId;
    const registry = ctx.jobs orelse return error.JobsNotAvailable;

    // 先 reap 一次最新状态
    registry.reapExited();

    var job = registry.get(job_id) orelse return error.JobNotFound;

    const want_stdout = if (common.extractJsonArg(args, "stdout")) |v| !std.mem.eql(u8, v, "false") else true;
    const want_stderr = if (common.extractJsonArg(args, "stderr")) |v| !std.mem.eql(u8, v, "false") else true;
    const stdout_since_arg = parseUsizeArg(args, "stdout_since_byte");
    const stderr_since_arg = parseUsizeArg(args, "stderr_since_byte");
    const stdout_since = stdout_since_arg orelse @as(usize, @intCast(job.stdout_read_offset));
    const stderr_since = stderr_since_arg orelse @as(usize, @intCast(job.stderr_read_offset));
    const wait_ms_arg = parseUsizeArg(args, "wait_ms");
    if (wait_ms_arg) |value| {
        if (value > MAX_WAIT_MS) {
            common.setErrorDetail(ctx.error_detail, allocator, "BashOutput wait_ms must be in 0..{d}", .{MAX_WAIT_MS});
            return error.InvalidWaitMs;
        }
    }
    const wait_ms_limit = wait_ms_arg orelse DEFAULT_WAIT_MS;
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

    // A BashOutput poll is deliberately demand-driven. It waits only when a
    // running job has no unread bytes on any requested channel; this keeps the
    // wait visible to the model instead of hiding it in speculative prefetch.
    var waited_ms: u64 = 0;
    if (wait_ms_limit > 0 and job.status == .running and (want_stdout or want_stderr)) {
        const stdout_has_unread = if (want_stdout) (fileSize(job.stdout_path) catch 0) > @as(u64, @intCast(stdout_since)) else false;
        const stderr_has_unread = if (want_stderr) (fileSize(job.stderr_path) catch 0) > @as(u64, @intCast(stderr_since)) else false;
        if (!stdout_has_unread and !stderr_has_unread) {
            const started = time.nowMs();
            const deadline = started + @as(i64, @intCast(wait_ms_limit));
            while (true) {
                try ctx.throwIfAborted();
                registry.reapExited();
                job = registry.get(job_id) orelse return error.JobNotFound;
                if (job.status != .running) break;
                const stdout_ready = if (want_stdout) (fileSize(job.stdout_path) catch 0) > @as(u64, @intCast(stdout_since)) else false;
                const stderr_ready = if (want_stderr) (fileSize(job.stderr_path) catch 0) > @as(u64, @intCast(stderr_since)) else false;
                if (stdout_ready or stderr_ready) break;
                const now = time.nowMs();
                if (now >= deadline) break;
                const remaining: u64 = @intCast(deadline - now);
                time.sleepMs(@min(remaining, WAIT_POLL_SLICE_MS));
            }
            const elapsed = time.nowMs() - started;
            waited_ms = if (elapsed > 0) @intCast(elapsed) else 0;
        }
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
    // A channel that is not valid UTF-8 cannot go into a JSON string: Zig's
    // writer escapes control bytes but passes 0x80..0xff through unchanged, so
    // `printf '\xff'` produced a result that is not UTF-8 at all. The completed
    // Bash envelope has always picked per channel and said which; this one
    // wrote everything as text. Budget, cut and render all read the same flag,
    // for the reason the completed path learned the hard way.
    const stdout_base64 = !std.unicode.utf8ValidateSlice(stdout_chunk.data);
    const stderr_base64 = !std.unicode.utf8ValidateSlice(stderr_chunk.data);
    const shares = result_budget.splitPair(
        allowance,
        result_budget.encodedCost(stdout_chunk.data, stdout_base64),
        result_budget.encodedCost(stderr_chunk.data, stderr_base64),
    );
    const stdout_shown = result_budget.headCut(stdout_chunk.data, shares.first, stdout_base64);
    const stderr_shown = result_budget.headCut(stderr_chunk.data, shares.second, stderr_base64);
    const stdout_next_offset: u64 = @as(u64, @intCast(stdout_since)) + stdout_shown.raw();
    const stderr_next_offset: u64 = @as(u64, @intCast(stderr_since)) + stderr_shown.raw();
    if (want_stdout) {
        try writeChannel(&aw.writer, allocator, "stdout", stdout_shown.head(stdout_chunk.data), stdout_base64);
        try aw.writer.print(",\"stdout_total_bytes\":{d},\"stdout_next_offset\":{d},\"stdout_truncated\":{s}", .{
            stdout_chunk.total_bytes,
            stdout_next_offset,
            if (stdout_chunk.truncated or stdout_shown.raw() < stdout_chunk.data.len) "true" else "false",
        });
    }
    if (want_stderr) {
        try writeChannel(&aw.writer, allocator, "stderr", stderr_shown.head(stderr_chunk.data), stderr_base64);
        try aw.writer.print(",\"stderr_total_bytes\":{d},\"stderr_next_offset\":{d},\"stderr_truncated\":{s}", .{
            stderr_chunk.total_bytes,
            stderr_next_offset,
            if (stderr_chunk.truncated or stderr_shown.raw() < stderr_chunk.data.len) "true" else "false",
        });
    }
    try aw.writer.print(",\"waited_ms\":{d}", .{waited_ms});
    try aw.writer.writeAll("}");
    // Only advance after the bytes are owned by the caller; an OOM before
    // toOwnedSlice must leave the model's unread output available next time.
    const out = try aw.toOwnedSlice();
    registry.updateReadCursors(
        job_id,
        if (want_stdout) stdout_next_offset else null,
        if (want_stderr) stderr_next_offset else null,
    );
    if (job.status != .running) registry.markExitObserved(job_id);
    return out;
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
/// total_bytes 是文件整体大小,**不是下次的 since**——续读游标由调用方按实际展示的
/// 字节数算成 `*_next_offset`。这行注释原本写着"便于模型决定下次 since",正是把
/// 文件长度当游标的那句,与模块头的契约相反。
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

/// Read only the current spool size for the long-poll readiness check.
fn fileSize(path: []const u8) !u64 {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= pbuf.len) return error.PathTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&pbuf), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    const total = pfs.lseek(fd, 0, .end);
    if (total < 0) return error.SeekFailed;
    return @intCast(total);
}

/// Write one channel plus the encoding it is in. `*_next_offset` is the cursor
/// to resume from: `total_bytes` is the file's current size, and a caller that
/// used it as the next `since_byte` - which the schema told it to - skipped
/// everything between what was shown and the end of the file. With the read
/// bounded by a budget rather than by 64 KiB, that gap became the common case:
/// a 100 KB log showed 24 KB and lost 75 KB with `truncated: true` and no
/// usable position to continue from.
fn writeChannel(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    label: []const u8,
    data: []const u8,
    base64: bool,
) !void {
    try writer.print(",\"{s}\":", .{label});
    if (base64) {
        const encoder = std.base64.standard.Encoder;
        const encoded = try allocator.alloc(u8, encoder.calcSize(data.len));
        defer allocator.free(encoded);
        _ = encoder.encode(encoded, data);
        try std.json.Stringify.encodeJsonString(encoded, .{}, writer);
    } else {
        try std.json.Stringify.encodeJsonString(data, .{}, writer);
    }
    try writer.print(",\"{s}_encoding\":\"{s}\"", .{ label, if (base64) "base64" else "utf-8" });
}

fn parseUsizeArg(args: []const u8, field: []const u8) ?usize {
    const s = common.extractJsonArg(args, field) orelse return null;
    return std.fmt.parseInt(usize, s, 10) catch null;
}

fn waitForSpoolBytes(registry: *@import("../core/job_registry.zig").JobRegistry, id: []const u8, want: u64) !void {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        const job = registry.get(id) orelse return error.JobNotFound;
        if ((fileSize(job.stdout_path) catch 0) >= want) return;
        registry.reapExited();
        time.sleepMs(10);
    }
    return error.TestTimeout;
}

fn waitForExit(registry: *@import("../core/job_registry.zig").JobRegistry, id: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        registry.reapExited();
        const job = registry.get(id) orelse return error.JobNotFound;
        if (job.status != .running) return;
        time.sleepMs(10);
    }
    return error.TestTimeout;
}

fn parseEnvelope(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
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

test "BashOutput observed exit is not announced" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("../core/session_id.zig").gen();
    const j = try r.spawnBackgroundOwned("printf done", null, owner);
    try waitForExit(&r, j.idSlice());
    const ctx = ToolContext{ .allocator = a, .jobs = &r, .agent_ident = owner };
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\"}}", .{j.idSlice()});
    defer a.free(args);
    const result = try execute(&ctx, args);
    defer a.free(result);
    const events = try r.takeUnannouncedExits(owner, a);
    defer @import("../core/job_registry.zig").freeJobExitEvents(a, events);
    try std.testing.expectEqual(@as(usize, 0), events.len);
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

test "BashOutput waits for delayed output" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const job = try registry.spawnBackground("sleep 0.4; printf hi", null);
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const start = time.nowMs();
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\"}}", .{job.idSlice()});
    defer a.free(args);
    const result = try execute(&ctx, args);
    defer a.free(result);
    const elapsed = time.nowMs() - start;
    try std.testing.expect(elapsed >= 300);
    try std.testing.expect(elapsed < @as(i64, @intCast(DEFAULT_WAIT_MS)));
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout\":\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"waited_ms\":") != null);
}

test "BashOutput returns immediately when unread bytes exist" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const job = try registry.spawnBackground("printf ready; sleep 5", null);
    try waitForSpoolBytes(&registry, job.idSlice(), 5);
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const start = time.nowMs();
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":500}}", .{job.idSlice()});
    defer a.free(args);
    const result = try execute(&ctx, args);
    defer a.free(result);
    try std.testing.expect(time.nowMs() - start < 2000);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout\":\"ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"waited_ms\":0") != null);
}

test "BashOutput returns immediately when the job exited" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const job = try registry.spawnBackground("printf done; exit 0", null);
    try waitForExit(&registry, job.idSlice());
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\"}}", .{job.idSlice()});
    defer a.free(args);
    const start = time.nowMs();
    const result = try execute(&ctx, args);
    defer a.free(result);
    try std.testing.expect(time.nowMs() - start < 2000);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"status\":\"exited\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"waited_ms\":0") != null);
}

test "BashOutput wait_ms zero preserves snapshot behavior" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const job = try registry.spawnBackground("sleep 5", null);
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":0}}", .{job.idSlice()});
    defer a.free(args);
    const start = time.nowMs();
    const result = try execute(&ctx, args);
    defer a.free(result);
    try std.testing.expect(time.nowMs() - start < 2000);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"status\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"waited_ms\":0") != null);
}

test "BashOutput deadline returns a still-running job" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const job = try registry.spawnBackground("sleep 5", null);
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":300}}", .{job.idSlice()});
    defer a.free(args);
    const start = time.nowMs();
    const result = try execute(&ctx, args);
    defer a.free(result);
    try std.testing.expect(time.nowMs() - start >= 300);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"status\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout\":\"\"") != null);
    var parsed = try parseEnvelope(a, result);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("waited_ms").?.integer >= 300);
}

test "BashOutput abort interrupts its wait" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const job = try registry.spawnBackground("sleep 5", null);
    var signal = @import("../util/abort.zig").AbortSignal.init();
    const Aborter = struct {
        fn run(target: *@import("../util/abort.zig").AbortSignal) void {
            time.sleepMs(100);
            target.abort(.user_interrupt);
        }
    };
    const thread = try std.Thread.spawn(.{}, Aborter.run, .{&signal});
    defer thread.join();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry, .abort = &signal };
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":5000}}", .{job.idSlice()});
    defer a.free(args);
    const start = time.nowMs();
    try std.testing.expectError(error.Aborted, execute(&ctx, args));
    try std.testing.expect(time.nowMs() - start < 1000);
}

test "BashOutput remembered cursor and explicit offset override" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const job = try registry.spawnBackground("printf once; sleep 1", null);
    try waitForSpoolBytes(&registry, job.idSlice(), 4);
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const first_args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":0}}", .{job.idSlice()});
    defer a.free(first_args);
    const first = try execute(&ctx, first_args);
    defer a.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"stdout\":\"once\"") != null);

    const second_args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":100}}", .{job.idSlice()});
    defer a.free(second_args);
    const second = try execute(&ctx, second_args);
    defer a.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"stdout\":\"\"") != null);

    const explicit_args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"stdout_since_byte\":0,\"wait_ms\":0}}", .{job.idSlice()});
    defer a.free(explicit_args);
    const explicit = try execute(&ctx, explicit_args);
    defer a.free(explicit);
    try std.testing.expect(std.mem.indexOf(u8, explicit, "\"stdout\":\"once\"") != null);

    const large = try registry.spawnBackground("awk 'BEGIN { for(i=0;i<100000;i++) printf \"x\" }'", null);
    try waitForExit(&registry, large.idSlice());
    const small_args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"max_bytes\":3,\"wait_ms\":0}}", .{large.idSlice()});
    defer a.free(small_args);
    const small = try execute(&ctx, small_args);
    defer a.free(small);
    try std.testing.expect(std.mem.indexOf(u8, small, "\"stdout_next_offset\":3") != null);
    const next = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"max_bytes\":3,\"wait_ms\":0}}", .{large.idSlice()});
    defer a.free(next);
    const continued = try execute(&ctx, next);
    defer a.free(continued);
    try std.testing.expect(std.mem.indexOf(u8, continued, "\"stdout_next_offset\":6") != null);
}

test "BashOutput rejects wait_ms above the maximum" {
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    try std.testing.expectError(error.JobNotFound, execute(&ctx, "{\"job_id\":\"deadbeef0001\"}"));
    // Validate the wait bound on a real job so the error is not masked by lookup.
    const job = try registry.spawnBackground("sleep 1", null);
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":{d}}}", .{ job.idSlice(), MAX_WAIT_MS + 1 });
    defer a.free(args);
    try std.testing.expectError(error.InvalidWaitMs, execute(&ctx, args));
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

    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"stdout_since_byte\":0,\"stderr_since_byte\":0}}", .{j.idSlice()});
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

test "BashOutput 增量游标能真正续读,不跳过被预算裁掉的部分" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // `*_total_bytes` 是文件当前大小;schema 曾让模型拿它当下次 since_byte。
    // 读取按预算限界后,"展示到文件末尾"之间就有一大段——实测 100KB 文件首轮展示
    // 24488 字节,按 total 续读会永久跳过 75512 字节,而 truncated=true 却没给出
    // 任何可用位置。`*_next_offset` 就是那个位置。
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
    const ctx = ToolContext{
        .allocator = a,
        .jobs = &registry,
        .result_budget = result_budget.Budget.fromModel(200_000),
    };

    const first_args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\"}}", .{j.idSlice()});
    defer a.free(first_args);
    const first = try execute(&ctx, first_args);
    defer a.free(first);
    var first_parsed = try std.json.parseFromSlice(std.json.Value, a, first, .{});
    defer first_parsed.deinit();
    const shown_first = first_parsed.value.object.get("stdout").?.string.len;
    const next = first_parsed.value.object.get("stdout_next_offset").?.integer;
    try std.testing.expect(first_parsed.value.object.get("stdout_truncated").?.bool);
    // 游标 == 已展示的字节数,而不是文件总长。
    try std.testing.expectEqual(@as(i64, @intCast(shown_first)), next);
    try std.testing.expectEqual(@as(i64, 100_000), first_parsed.value.object.get("stdout_total_bytes").?.integer);

    // 第二轮从游标续读:必须真的拿到后面的内容,而不是空。
    const second_args = try std.fmt.allocPrint(
        a,
        "{{\"job_id\":\"{s}\",\"stdout_since_byte\":{d}}}",
        .{ j.idSlice(), next },
    );
    defer a.free(second_args);
    const second = try execute(&ctx, second_args);
    defer a.free(second);
    var second_parsed = try std.json.parseFromSlice(std.json.Value, a, second, .{});
    defer second_parsed.deinit();
    const shown_second = second_parsed.value.object.get("stdout").?.string.len;
    try std.testing.expect(shown_second > 0);
    // 两轮相加严格前进;若拿 total 当游标,第二轮会是 0。
    try std.testing.expect(shown_first + shown_second > shown_first);
    try std.testing.expectEqual(
        @as(i64, @intCast(shown_first + shown_second)),
        second_parsed.value.object.get("stdout_next_offset").?.integer,
    );
}

test "BashOutput 二进制通道走 base64,结果仍是合法 UTF-8 JSON" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // Zig 的 JSON writer 只转义控制符,0x80..0xff 原样写出——含非 UTF-8 字节的
    // 通道因此产出的根本不是合法 UTF-8。完成态信封一直按通道选编码并携带
    // `*_encoding`,这里没有。
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    // 八进制而非 `\xff`:job 走 `/bin/sh -c`,Linux 上那是 dash,它的 printf 不认
    // 十六进制转义,会原样吐出字面量 `A\xffB\xfe`——纯 ASCII,于是通道被判成 utf-8
    // 而不是 base64,断言在 Linux 上失败而在 macOS(/bin/sh 即 bash)上通过。
    // `\ddd` 是 POSIX printf 的八进制转义,dash 与 bash 都实现。
    const j = try registry.spawnBackground("printf 'A\\377B\\376'", null);
    while (registry.get(j.idSlice())) |e| {
        if (e.status != .running) break;
        time.sleepMs(20);
        registry.reapExited();
    }
    registry.reapExited();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\"}}", .{j.idSlice()});
    defer a.free(args);
    const out = try execute(&ctx, args);
    defer a.free(out);

    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    var parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("base64", parsed.value.object.get("stdout_encoding").?.string);
    // 而且解出来就是原始字节。
    const encoded = parsed.value.object.get("stdout").?.string;
    const decoder = std.base64.standard.Decoder;
    const decoded = try a.alloc(u8, try decoder.calcSizeForSlice(encoded));
    defer a.free(decoded);
    try decoder.decode(decoded, encoded);
    try std.testing.expectEqualSlices(u8, "A\xffB\xfe", decoded);
    // 纯文本通道不受影响。
    try std.testing.expectEqualStrings("utf-8", parsed.value.object.get("stderr_encoding").?.string);

    // 两条通道对称:模块头声明各带同样四个字段,stderr 的 encoding/next_offset 曾经
    // 实际会发但没写进契约。这里把"对称"这句话变成断言,免得它退回成一句自述。
    inline for (.{ "stdout", "stderr" }) |channel| {
        inline for (.{ "", "_encoding", "_total_bytes", "_next_offset", "_truncated" }) |suffix| {
            const field = channel ++ suffix;
            if (parsed.value.object.get(field) == null) {
                std.debug.print("BashOutput 信封缺字段: {s}\n", .{field});
                return error.ChannelFieldMissing;
            }
        }
    }
}
