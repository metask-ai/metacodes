//! DiagnosticsBackend(L4):旁路观测后端——消费 agent_loop 的诊断 CoreEvent,
//! 累积成结构化 trace,供导出(JSONL)/健康度量/问题定位。
//!
//! 它是 UiBackend 的一个实现,但**不渲染**:emit 只挑 `.diag_*` 记进内存事件列表,其余
//! 渲染事件 no-op。通过 TeeBackend 与真实渲染 backend 并存(见 tee_backend.zig)。
//!
//! **当前范围 = run-level(单层),不是跨 agent 树**。诚实说明:本版 DiagnosticsBackend 只挂
//! 顶层 run,只看得见 **depth=0** 的诊断;subagent 的诊断进 JobEntry backend → no-op → 不
//! 到达这里。故导出的 trace 是**顶层 run 的时间线**,`depth` 字段当前恒 0。
//! `depth` 字段保留是为日后接 subagent(让 JobEntry 把 diag_* 转发到共享 diag sink,届时
//! depth>0 才有值,真正构成跨 agent span 树)——**那是 future L4.1,本版不做**(见 L4 plan §6)。
//! 不要据当前 depth 字段假设已有树结构。
//!
//! trace 结构:同一 trace_id 的事件按到达顺序构成一个 run 的时间线;diag_turn_begin/end 划
//! turn span(span 平衡契约见 agent_loop.finishRun)。
//!
//! 纯数据 + 可序列化:TraceEvent 是 tagged union,具名 payload,toJsonl 产出每行一个事件的
//! NDJSON(字段自解释,如 `{"cache_break":{"cache_read":512,...}}`),可直接喂 jq / OTel。

const std = @import("std");
const json_util = @import("../util/json.zig");
const ui_backend = @import("protocol/ui_backend.zig");

const CoreEvent = ui_backend.CoreEvent;
const UiEvent = ui_backend.UiEvent;
const UiBackend = ui_backend.UiBackend;
const SessionId = ui_backend.SessionId;

/// 一条 trace 事件(诊断 CoreEvent 的归一化记录)。tagged union——每 kind 具名 payload,
/// 直接 JSON 序列化即自解释(`{"cache_break":{"cache_read":512,...}}`),可喂 jq/OTel。
/// 公共字段(trace_id/depth)随每个 payload 携带(union 无法提公共字段,故内联进各变体)。
pub const TraceEvent = union(enum) {
    turn_begin: struct { trace_id: [12]u8, depth: u8, turn: u32 },
    turn_end: struct { trace_id: [12]u8, depth: u8, turn: u32, tool_calls: u32 },
    breaker_tripped: struct { trace_id: [12]u8, depth: u8, same_err_count: u32 },
    cache_break: struct { trace_id: [12]u8, depth: u8, cache_read: u64, cache_creation: u64 },
    continuation: struct { trace_id: [12]u8, depth: u8, n: u32, max: u32 },
    run_end: struct { trace_id: [12]u8, depth: u8, turns: u32, tool_calls: u32, stop_reason: []const u8 },

    pub const Kind = std.meta.Tag(TraceEvent);

    /// 取本事件的 trace_id(各变体共有,统一取出)。
    pub fn traceId(self: *const TraceEvent) [12]u8 {
        return switch (self.*) {
            inline else => |p| p.trace_id,
        };
    }
    /// 取 depth(各变体共有)。
    pub fn depth(self: *const TraceEvent) u8 {
        return switch (self.*) {
            inline else => |p| p.depth,
        };
    }
};

pub const DiagnosticsBackend = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(TraceEvent) = .empty,

    pub fn init(allocator: std.mem.Allocator) DiagnosticsBackend {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DiagnosticsBackend) void {
        self.events.deinit(self.allocator);
    }

    pub fn backend(self: *DiagnosticsBackend) UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emitThunk, .poll = pollThunk };
    }

    fn pollThunk(_: *anyopaque, _: SessionId) ?UiEvent {
        return null; // 观测后端无输入端
    }

    fn emitThunk(ctx: *anyopaque, _: SessionId, ev: CoreEvent) void {
        const self: *DiagnosticsBackend = @ptrCast(@alignCast(ctx));
        // CoreEvent 诊断变体 → TraceEvent(1:1 具名映射,无位置槽)。渲染事件忽略。
        const te: ?TraceEvent = switch (ev) {
            .diag_turn_begin => |d| .{ .turn_begin = .{ .trace_id = d.trace_id, .depth = d.depth, .turn = d.turn } },
            .diag_turn_end => |d| .{ .turn_end = .{ .trace_id = d.trace_id, .depth = d.depth, .turn = d.turn, .tool_calls = d.tool_calls } },
            .diag_breaker_tripped => |d| .{ .breaker_tripped = .{ .trace_id = d.trace_id, .depth = d.depth, .same_err_count = d.same_err_count } },
            .diag_cache_break => |d| .{ .cache_break = .{ .trace_id = d.trace_id, .depth = d.depth, .cache_read = d.cache_read, .cache_creation = d.cache_creation } },
            .diag_continuation => |d| .{ .continuation = .{ .trace_id = d.trace_id, .depth = d.depth, .n = d.n, .max = d.max } },
            .diag_run_end => |d| .{ .run_end = .{ .trace_id = d.trace_id, .depth = d.depth, .turns = d.turns, .tool_calls = d.tool_calls, .stop_reason = d.stop_reason_name } },
            else => null, // 渲染事件 + usage/auto_compact(MVP 不入 trace)→ 忽略
        };
        if (te) |e| {
            // append 失败(OOM)不致命但不静默:trace 丢事件会让时间线错位,记 warn。
            self.events.append(self.allocator, e) catch {
                @import("../util/log.zig").warn("diag", "dropped trace event (OOM)", .{});
            };
        }
    }

    /// 把累积的 trace 事件导成 NDJSON(每行一个事件)。caller free。
    pub fn toJsonl(self: *const DiagnosticsBackend, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (self.events.items) |e| {
            const raw = try std.json.Stringify.valueAlloc(allocator, e, .{});
            defer allocator.free(raw);
            const line = try json_util.repairJsonUtf8(allocator, raw);
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
        return out.toOwnedSlice(allocator);
    }

    /// 计数某类事件(健康度量 / 测试断言用)。
    pub fn countKind(self: *const DiagnosticsBackend, kind: TraceEvent.Kind) u32 {
        var n: u32 = 0;
        for (self.events.items) |e| {
            if (std.meta.activeTag(e) == kind) n += 1;
        }
        return n;
    }
};

// ── 测试 ─────────────────────────────────────────────────────────────────

test "DiagnosticsBackend: 只消费诊断事件,重建 trace + JSONL" {
    const a = std.testing.allocator;
    var diag = DiagnosticsBackend.init(a);
    defer diag.deinit();
    const be = diag.backend();

    const tid: [12]u8 = "abcd00010000".*;
    // 渲染事件被忽略。
    be.emit(be.ctx, .single, .stream_begin);
    be.emit(be.ctx, .single, .{ .text_chunk = "hi" });
    // 诊断事件被记录。
    be.emit(be.ctx, .single, .{ .diag_turn_begin = .{ .trace_id = tid, .depth = 0, .turn = 1 } });
    be.emit(be.ctx, .single, .{ .diag_turn_end = .{ .trace_id = tid, .depth = 0, .turn = 1, .tool_calls = 2 } });
    be.emit(be.ctx, .single, .{ .diag_run_end = .{ .trace_id = tid, .depth = 0, .turns = 1, .tool_calls = 2, .stop_reason_name = "end_turn" } });

    try std.testing.expectEqual(@as(usize, 3), diag.events.items.len);
    try std.testing.expectEqual(@as(u32, 1), diag.countKind(.turn_begin));
    try std.testing.expectEqual(@as(u32, 1), diag.countKind(.run_end));
    const tid_got = diag.events.items[0].traceId();
    try std.testing.expectEqualSlices(u8, "abcd00010000", &tid_got);

    const jsonl = try diag.toJsonl(a);
    defer a.free(jsonl);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "turn_begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "end_turn") != null);
    // union 序列化:具名字段(stop_reason)而非位置槽(a/b/c)。
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "stop_reason") != null);
    // 三行(三个诊断事件)。
    var lines: usize = 0;
    for (jsonl) |ch| {
        if (ch == '\n') lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), lines);
}
