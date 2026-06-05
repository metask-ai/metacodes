//! HeadlessBackend:把每个 CoreEvent 序列化成一行 JSON(NDJSON)发给 sink。
//!
//! 阶段 E:证明 CoreEvent 协议**可序列化** = 进程外传输的前提(对齐 plan §协议可序列化:
//! 进程内 vtable 直传 vs 进程外 WsBackend = ws.send(json(CoreEvent)))。HeadlessBackend
//! 是"序列化发出"这一端的最小实现:emit 不渲染、不持终端,只把事件转 JSON 行交给 sink。
//!
//! 与 WriterBackend 的区别:WriterBackend 把 text_chunk **字节**直接喂 sink(给 TUI/job
//! buffer 的可见输出);HeadlessBackend 把**整个 CoreEvent**(含 tag + payload)转 JSON
//! (给机器消费 / 跨进程隧道)。同一协议,两种传输实现。
//!
//! poll → 恒 null(无输入端;真正的 headless 输入由上层编排,不经此 backend)。

const std = @import("std");
const ui_backend = @import("../repl/ui_backend.zig");
const ui_event = @import("../repl/ui_event.zig");
const log = @import("../util/log.zig");

const CoreEvent = ui_event.CoreEvent;
const UiEvent = ui_event.UiEvent;
const UiBackend = ui_backend.UiBackend;

pub const HeadlessBackend = struct {
    /// sink 适配器:收一行 JSON(不含尾 \n;由 sink 决定是否换行/落盘/发送)。
    sink_ctx: *anyopaque,
    sink: *const fn (ctx: *anyopaque, json_line: []const u8) void,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, sink_ctx: *anyopaque, sink: *const fn (ctx: *anyopaque, json_line: []const u8) void) HeadlessBackend {
        return .{ .sink_ctx = sink_ctx, .sink = sink, .allocator = allocator };
    }

    pub fn backend(self: *HeadlessBackend) UiBackend {
        return .{
            .ctx = @ptrCast(self),
            .emit = emitThunk,
            .poll = pollThunk,
        };
    }

    fn emitThunk(ctx: *anyopaque, ev: CoreEvent) void {
        const self: *HeadlessBackend = @ptrCast(@alignCast(ctx));
        // 整个 CoreEvent → JSON 行。序列化失败(OOM)不致命,但**不静默吞**:
        // 丢一行可能让下游 parser 错位/丢工具结果(违反"No silent caps")→ 记 warn。
        const line = std.json.Stringify.valueAlloc(self.allocator, ev, .{}) catch {
            log.warn("headless", "dropped CoreEvent .{s} (JSON serialize failed/OOM)", .{@tagName(ev)});
            return;
        };
        defer self.allocator.free(line);
        self.sink(self.sink_ctx, line);
    }

    fn pollThunk(_: *anyopaque) ?UiEvent {
        return null; // headless 无输入端
    }
};

test {
    std.testing.refAllDecls(@This());
}
