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
//!     "output":"<增量文本>","output_total_bytes":N,"output_truncated":bool,
//!     "final_text":"..."?,        // done 时(若与 output 重复可省;这里给最终拼接)
//!     "stop_reason":"..."?,"turns":N?,"tool_calls":N?,
//!     "error":"<err_name>"? }
//!
//! 增量轮询:模型下次传 since_byte = 上次 output_total_bytes。truncated=true 表示还有。

const std = @import("std");
const common = @import("common.zig");
const ToolContext = @import("context.zig").ToolContext;

const DEFAULT_MAX_BYTES: usize = 64 * 1024;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const id = common.extractJsonArg(args, "agent_job_id") orelse return error.MissingJobId;

    // 非 agent_ 前缀:这是 todo task id,TaskOutput 对 todo 无意义。
    if (!std.mem.startsWith(u8, id, "agent_")) {
        return allocator.dupe(u8, "{\"status\":\"not_applicable\",\"detail\":\"TaskOutput only applies to backgrounded agent jobs (agent_* ids)\"}");
    }

    const reg = ctx.agent_jobs orelse return error.AgentJobsUnavailable;
    const e = reg.get(id) orelse return error.JobNotFound;

    const since = parseUsizeArg(args, "since_byte") orelse 0;
    const max_bytes = parseUsizeArg(args, "max_bytes") orelse DEFAULT_MAX_BYTES;

    // 持 entry 锁:把要序列化的内容拷到本地,unlock 后再拼 JSON(锁内不做大分配)。
    var snap = Snapshot{};
    defer snap.deinit(allocator);
    {
        e.lockPublic();
        defer e.unlockPublic();
        snap.status = e.status;
        snap.total = e.output_buf.items.len;
        const buf = e.output_buf.items;
        if (since < buf.len) {
            const remaining = buf.len - since;
            const take = @min(remaining, max_bytes);
            snap.output = try allocator.dupe(u8, buf[since .. since + take]);
            snap.truncated = take < remaining;
        } else {
            snap.output = try allocator.dupe(u8, "");
            snap.truncated = false;
        }
        snap.stop_reason = e.stop_reason;
        snap.turns = e.turns;
        snap.tool_calls = e.tool_calls;
        snap.err_name = e.err_name;
        if (e.final_text) |ft| snap.final_text = try allocator.dupe(u8, ft);
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"agent_job_id\":");
    try std.json.Stringify.encodeJsonString(id, .{}, &aw.writer);
    try aw.writer.print(",\"status\":\"{s}\"", .{@tagName(snap.status)});
    try aw.writer.writeAll(",\"output\":");
    try std.json.Stringify.encodeJsonString(snap.output, .{}, &aw.writer);
    try aw.writer.print(",\"output_total_bytes\":{d},\"output_truncated\":{s}", .{
        snap.total,
        if (snap.truncated) "true" else "false",
    });
    if (snap.stop_reason) |sr| {
        try aw.writer.print(",\"stop_reason\":\"{s}\",\"turns\":{d},\"tool_calls\":{d}", .{ @tagName(sr), snap.turns, snap.tool_calls });
    }
    if (snap.final_text) |ft| {
        try aw.writer.writeAll(",\"final_text\":");
        try std.json.Stringify.encodeJsonString(ft, .{}, &aw.writer);
    }
    if (snap.err_name) |en| {
        try aw.writer.writeAll(",\"error\":");
        try std.json.Stringify.encodeJsonString(en, .{}, &aw.writer);
    }
    try aw.writer.writeAll("}");
    return try aw.toOwnedSlice();
}

const Snapshot = struct {
    status: @import("../core/agent_job_registry.zig").JobStatus = .running,
    output: []const u8 = &.{},
    final_text: ?[]const u8 = null,
    total: usize = 0,
    truncated: bool = false,
    stop_reason: ?@import("../core/agent_loop.zig").StopReason = null,
    turns: u32 = 0,
    tool_calls: u32 = 0,
    err_name: ?[]const u8 = null,

    fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        if (self.output.len > 0) allocator.free(@constCast(self.output));
        if (self.final_text) |ft| allocator.free(@constCast(ft));
    }
};

fn parseUsizeArg(args: []const u8, key: []const u8) ?usize {
    const raw = common.extractJsonArg(args, key) orelse return null;
    return std.fmt.parseInt(usize, std.mem.trim(u8, raw, " \""), 10) catch null;
}
