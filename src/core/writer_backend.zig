//! WriterBackend:把 UiBackend vtable 接到一个"只收字节"的 sink(print-only writer)。
//!
//! 塌缩旧 4 种 print-only writer(DebugWriter/SilentWriter/NullWriter/SinkWriter)——
//! 它们只有 `print`,区别仅在字节去向(std.debug.print / 丢弃 / 丢弃 / 追加 job buf)。
//! WriterBackend 参数化一个 `sink` fn-ptr(ctx, bytes),由调用点提供适配器。
//!
//! 字节精确(对齐旧 agent_loop 直 print):旧 print-only writer 因 comptime @hasDecl
//! 守卫,卡/进度分支编译期消失——它们从不收卡字节,只收 text/颜色括号/auto-compact 行/
//! verbose 行/尾换行。故 WriterBackend:
//!   .stream_begin       → colorize ? sink("\x1b[32m")
//!   .text_chunk         → sink(t)
//!   .context_warning    → sink(格式化 warning 行)
//!   .auto_compact       → sink(格式化行)
//!   .retry_notice       → [门控] sink("Retrying in Ns…")
//!   .tool_start{card=f}  → verbose ? sink("\n\x1b[35m[Tool: name]\x1b[0m")
//!   .stream_done        → sink(colorize ? "\x1b[0m\n" : "\n")
//!   其余(卡/spinner/progress/usage/phase) → no-op
//! poll → 恒 null(print-only sink 无输入端)。

const std = @import("std");
const ui_backend = @import("protocol/ui_backend.zig");
const ui_event = @import("protocol/ui_event.zig");

const CoreEvent = ui_event.CoreEvent;
const UiEvent = ui_event.UiEvent;
const UiBackend = ui_backend.UiBackend;
const SessionId = ui_backend.SessionId;

pub const WriterBackend = struct {
    /// sink 适配器:把字节交给底层(std.debug.print / job buf / 丢弃)。
    sink_ctx: *anyopaque,
    sink: *const fn (ctx: *anyopaque, bytes: []const u8) void,
    colorize: bool = false,
    verbose: bool = false,
    show_retry: bool = false,
    /// usage 累加目标(L1:usage 走 CoreEvent.usage 总线)。非主交互路径(skill 注入 / cron)
    /// 用 WriterBackend 也要把 token 计入 app.usage,否则 /cost 漏算这些 turn。null = 不累加。
    usage_acc: ?*@import("usage.zig").UsageTotals = null,

    /// null sink:丢弃所有字节(SilentWriter/NullWriter 等价)。
    pub fn nullSink(_: *anyopaque, _: []const u8) void {}

    /// 便利:构造一个丢弃一切的 WriterBackend(headless/subagent/测试)。
    pub fn initNull() WriterBackend {
        return .{ .sink_ctx = undefined, .sink = nullSink };
    }

    /// 便利:丢弃字节但累加 usage(headless 仍要 /cost 计数)。
    pub fn initNullWithUsage(usage_acc: *@import("usage.zig").UsageTotals) WriterBackend {
        return .{ .sink_ctx = undefined, .sink = nullSink, .usage_acc = usage_acc };
    }

    pub fn backend(self: *WriterBackend) UiBackend {
        return .{
            .ctx = @ptrCast(self),
            .emit = emitThunk,
            .poll = pollThunk,
        };
    }

    fn emitThunk(ctx: *anyopaque, _: SessionId, ev: CoreEvent) void {
        const self: *WriterBackend = @ptrCast(@alignCast(ctx));
        self.emitImpl(ev);
    }

    fn pollThunk(_: *anyopaque, _: SessionId) ?UiEvent {
        return null; // print-only sink 无输入端
    }

    inline fn emit(self: *WriterBackend, bytes: []const u8) void {
        self.sink(self.sink_ctx, bytes);
    }

    fn emitImpl(self: *WriterBackend, ev: CoreEvent) void {
        switch (ev) {
            .stream_begin => {
                if (self.colorize) self.emit("\x1b[32m");
            },
            .text_chunk => |t| self.emit(t),
            .thinking_chunk => {}, // headless/job sink 不显示思考过程(agent_loop 已存 conversation)
            .tool_start => |s| {
                // verbose 普通工具行(对齐旧 agent_loop:387)。WriterBackend 是 core 层,
                // 不 import UI widget tool_card 做分类(层泄漏);verbose 下打所有工具名即可
                // (headless/非主路径,多打进度卡工具名无害)。
                if (self.verbose) {
                    var buf: [256]u8 = undefined;
                    const v = std.fmt.bufPrint(&buf, "\n\x1b[35m[Tool: {s}]\x1b[0m", .{s.name}) catch return;
                    self.emit(v);
                }
            },
            .auto_compact => |c| {
                var buf: [256]u8 = undefined;
                const s = std.fmt.bufPrint(
                    &buf,
                    "\x1b[33m[auto-compacted {d} old messages, kept last {d}]\x1b[0m\n",
                    .{ c.dropped, c.kept },
                ) catch return;
                self.emit(s);
            },
            .context_warning => |w| {
                var buf: [256]u8 = undefined;
                const s = std.fmt.bufPrint(
                    &buf,
                    "\x1b[33m[context warning: {d}/{d} tokens, auto-compact at {d}, blocking at {d}]\x1b[0m\n",
                    .{ w.current_tokens, w.warning_threshold, w.auto_compact_threshold, w.blocking_limit },
                ) catch return;
                self.emit(s);
            },
            .retry_notice => |r| {
                if (!self.show_retry) return;
                if (r.attempt < 3) return;
                const secs = (r.delay_ms + 999) / 1000;
                var buf: [256]u8 = undefined;
                const s = if (self.colorize)
                    std.fmt.bufPrint(&buf, "\x1b[2mRetrying in {d}s… (attempt {d}/{d})\x1b[0m\n", .{ secs, r.attempt, r.max }) catch return
                else
                    std.fmt.bufPrint(&buf, "Retrying in {d}s… (attempt {d}/{d})\n", .{ secs, r.attempt, r.max }) catch return;
                self.emit(s);
            },
            .stream_done => {
                self.emit(if (self.colorize) "\x1b[0m\n" else "\n");
            },
            // usage:累加进 usage_acc(若接),供 /cost。其余卡/spinner/progress/phase no-op。
            .usage => |u| {
                if (self.usage_acc) |acc| acc.apply(u);
            },
            // print-only sink 不收这些(旧 @hasDecl 守卫即编译期消失):
            // ui_request_pending:异步前端专属;print-only(headless/后台 job)不投递,no-op。
            // diag_*:L4 诊断事件,DiagnosticsBackend 专属,渲染后端 no-op。
            .set_current_tool, .clear_current_tool, .tool_progress, .progress, .tool_result, .config_changed, .session_lifecycle, .agent_lifecycle, .tasks_changed, .ui_request_pending, .diag_turn_begin, .diag_turn_end, .diag_model_request, .diag_compact_request, .diag_compact_begin, .diag_compact_end, .diag_tool_stage, .diag_breaker_tripped, .diag_cache_break, .diag_continuation, .context_projection, .policy_decision, .diag_run_end => {},
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}
