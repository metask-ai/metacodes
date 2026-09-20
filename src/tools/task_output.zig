//! TaskOutput:查询后台 subagent(Task run_in_background)的状态 + 增量输出。
//!
//! 对齐 Claude Code 的统一 TaskOutput(按 task_id/type 分流):这里 id 带 `agent_`
//! 前缀 → 查后台 subagent registry;否则(todo task id)→ not_applicable。
//!
//! input:
//!   - agent_job_id (必填):`agent_xxxxxxxx`
//!   - since_byte (可选):从输出缓冲第 N 字节起增量读。默认 0。
//!   - max_bytes (可选):单次读出上限。默认 65536。
//!
//! output:
//!   { "agent_job_id":"...","status":"running|done|failed|killed",
//!     "output":"<增量文本>","output_total_bytes":N,"output_next_offset":N,
//!     "output_size_bytes":N,"output_truncated":bool,
//!     "final_text":"..."?,        // done 时(若与 output 重复可省;这里给最终拼接)
//!     "stop_reason":"..."?,"turns":N?,"tool_calls":N?,
//!     "error":"<err_name>"? }
//!
//! 增量轮询:模型下次传 since_byte = 上次 output_next_offset。无新输出时最长等待 30s；
//! terminal/output change 会立即唤醒。truncated=true 表示还有。

const std = @import("std");
const common = @import("common.zig");
const ToolContext = @import("context.zig").ToolContext;
const util_time = @import("../util/time.zig");
const util_json = @import("../util/json.zig");
const utf8 = @import("../util/utf8.zig");

const DEFAULT_MAX_BYTES: usize = 64 * 1024;
const MAX_MAX_BYTES: usize = 256 * 1024;
const LONG_POLL_MS: i64 = 30_000;
const ABORT_SLICE_MS: i64 = 250;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const id = common.extractJsonArg(args, "agent_job_id") orelse return error.MissingJobId;

    // 非 agent_ 前缀:这是 todo task id,TaskOutput 对 todo 无意义。
    if (!std.mem.startsWith(u8, id, "agent_")) {
        return allocator.dupe(u8, "{\"status\":\"not_applicable\",\"detail\":\"TaskOutput only applies to backgrounded agent jobs (agent_* ids)\"}");
    }

    const reg = ctx.agent_jobs orelse return error.AgentJobsUnavailable;
    const e = reg.acquireBackgroundForSession(id, ctx.session) orelse return error.JobNotFound;
    defer reg.releaseBackground(e);

    const since_raw = common.extractJsonArg(args, "since_byte");
    const since_arg = parseUsizeArg(args, "since_byte");
    if (since_raw != null and since_arg == null) {
        common.setErrorDetail(ctx.error_detail, allocator, "TaskOutput since_byte must be a non-negative integer", .{});
        return error.InvalidSinceByte;
    }
    const since = since_arg orelse 0;
    const max_raw = common.extractJsonArg(args, "max_bytes");
    const max_arg = parseUsizeArg(args, "max_bytes");
    if (max_raw != null and max_arg == null) {
        common.setErrorDetail(ctx.error_detail, allocator, "TaskOutput max_bytes must be a non-negative integer", .{});
        return error.InvalidMaxBytes;
    }
    const max_bytes = max_arg orelse DEFAULT_MAX_BYTES;
    if (max_bytes == 0 or max_bytes > MAX_MAX_BYTES) {
        common.setErrorDetail(ctx.error_detail, allocator, "TaskOutput max_bytes must be in 1..{d}", .{MAX_MAX_BYTES});
        return error.InvalidMaxBytes;
    }

    // Reject stale/malformed cursors before entering the 30s long-poll. A
    // caller can only resume at a boundary in the currently published byte
    // stream; waiting cannot make an already-invalid continuation byte valid.
    {
        e.lockPublic();
        const invalid = since > e.output_buf.items.len or
            (since < e.output_buf.items.len and utf8.prefixEnd(e.output_buf.items, since) != since);
        const size = e.output_buf.items.len;
        e.unlockPublic();
        if (invalid) {
            common.setErrorDetail(ctx.error_detail, allocator, "TaskOutput since_byte must be a UTF-8 boundary within output_size_bytes={d}", .{size});
            return error.InvalidSinceByte;
        }
    }

    // A status read with no unseen output is a long-poll, not a zero-wait
    // snapshot. Otherwise a fast model can issue three identical TaskOutput
    // calls before the background thread gets scheduled and trip the generic
    // zero-gain breaker even though the job is making progress.
    const deadline = util_time.nowMs() + LONG_POLL_MS;
    while (true) {
        try ctx.throwIfAborted();
        const now = util_time.nowMs();
        if (now >= deadline) break;
        const remaining = deadline - now;
        const wait_ms: u64 = @intCast(@min(remaining, ABORT_SLICE_MS));
        // `since` is the effective cursor. Passing the raw optional here made
        // an omitted cursor disable the output-change wakeup entirely, so a
        // running job with already available output waited for the full 30s.
        if (e.waitForOutputOrTerminal(since, wait_ms * std.time.ns_per_ms)) break;
    }

    // 持 entry 锁:把要序列化的内容拷到本地,unlock 后再拼 JSON(锁内不做大分配)。
    var snap = Snapshot{};
    defer snap.deinit(allocator);
    {
        e.lockPublic();
        defer e.unlockPublic();
        snap.status = e.status;
        snap.total = e.output_buf.items.len;
        snap.truncated = e.output_truncated;
        const buf = e.output_buf.items;
        if (since > buf.len or (since < buf.len and utf8.prefixEnd(buf, since) != since)) {
            common.setErrorDetail(ctx.error_detail, allocator, "TaskOutput since_byte must be a UTF-8 boundary within output_size_bytes={d}", .{buf.len});
            return error.InvalidSinceByte;
        }
        if (since < buf.len) {
            const remaining = buf.len - since;
            var page = utf8.pagePrefix(buf[since..], max_bytes);
            if (page.len == 0 and snap.status != .running) {
                // A terminal job may end with a malformed/incomplete byte
                // sequence. Consume the complete incomplete tail as one
                // recovery unit; consuming only its lead byte would leave a
                // continuation-byte suffix that the next cursor can never
                // validate. writeJsonString converts the raw tail to U+FFFD.
                const tail = buf[since..];
                const take = if (utf8.incompleteTailStart(tail) != null)
                    tail.len
                else
                    utf8.nextBoundary(tail, 0);
                page = tail[0..take];
            }
            const take = page.len;
            snap.output = try allocator.dupe(u8, page);
            snap.truncated = snap.truncated or take < remaining;
            snap.next = since + take;
        } else {
            snap.output = try allocator.dupe(u8, "");
            // Truncation is a property of the retained stream, not only of
            // this page. Preserve it even when the caller polls at the end
            // of the current buffer.
            snap.truncated = e.output_truncated;
            snap.next = since;
        }
        snap.stop_reason = e.stop_reason;
        snap.turns = e.turns;
        snap.tool_calls = e.tool_calls;
        snap.err_name = e.err_name;
        // `output` is the paged recovery plane. final_text is only a small
        // convenience duplicate; never copy an arbitrarily large completed
        // agent response a second time merely to serialize this status row.
        if (e.final_text) |ft| {
            if (ft.len <= max_bytes) snap.final_text = try allocator.dupe(u8, ft);
        }
        if (e.worktree_path.len > 0) snap.worktree_path = try allocator.dupe(u8, e.worktree_path);
        snap.worktree_kept = e.worktree_kept;
        snap.worktree_cleanup_complete = e.worktree_cleanup_complete;
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"agent_job_id\":");
    try util_json.writeJsonString(&aw.writer, id);
    try aw.writer.print(",\"status\":\"{s}\"", .{@tagName(snap.status)});
    try aw.writer.writeAll(",\"output\":");
    try util_json.writeJsonString(&aw.writer, snap.output);
    try aw.writer.print(",\"output_total_bytes\":{d},\"output_next_offset\":{d},\"output_size_bytes\":{d},\"output_truncated\":{s}", .{
        snap.total,
        snap.next,
        snap.total,
        if (snap.truncated) "true" else "false",
    });
    if (snap.stop_reason) |sr| {
        try aw.writer.print(",\"stop_reason\":\"{s}\",\"turns\":{d},\"tool_calls\":{d}", .{ @tagName(sr), snap.turns, snap.tool_calls });
    }
    if (snap.final_text) |ft| {
        try aw.writer.writeAll(",\"final_text\":");
        try util_json.writeJsonString(&aw.writer, ft);
    }
    if (snap.err_name) |en| {
        try aw.writer.writeAll(",\"error\":");
        try util_json.writeJsonString(&aw.writer, en);
    }
    if (snap.worktree_path) |path| {
        try aw.writer.writeAll(",\"worktree_path\":");
        try util_json.writeJsonString(&aw.writer, path);
        if (snap.worktree_kept) |kept| {
            try aw.writer.print(",\"worktree_kept\":{s}", .{if (kept) "true" else "false"});
        }
        if (snap.worktree_cleanup_complete) |complete| {
            try aw.writer.print(",\"worktree_cleanup_complete\":{s}", .{if (complete) "true" else "false"});
        }
    }
    try aw.writer.writeAll("}");
    return try aw.toOwnedSlice();
}

const Snapshot = struct {
    status: @import("../core/agent_job_registry.zig").JobStatus = .running,
    output: []const u8 = &.{},
    final_text: ?[]const u8 = null,
    total: usize = 0,
    next: usize = 0,
    truncated: bool = false,
    stop_reason: ?@import("../core/agent_loop.zig").StopReason = null,
    turns: u32 = 0,
    tool_calls: u32 = 0,
    err_name: ?[]const u8 = null,
    worktree_path: ?[]const u8 = null,
    worktree_kept: ?bool = null,
    worktree_cleanup_complete: ?bool = null,

    fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        if (self.output.len > 0) allocator.free(@constCast(self.output));
        if (self.final_text) |ft| allocator.free(@constCast(ft));
        if (self.worktree_path) |path| allocator.free(@constCast(path));
    }
};

fn parseUsizeArg(args: []const u8, key: []const u8) ?usize {
    const raw = common.extractJsonArg(args, key) orelse return null;
    return std.fmt.parseInt(usize, std.mem.trim(u8, raw, " \""), 10) catch null;
}
