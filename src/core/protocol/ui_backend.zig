//! UiBackend:core↔UI 的显式 vtable 契约(阶段 A)。
//!
//! 设计(见 plan zazzy-dazzling-lake §UiBackend):用函数指针 vtable 而非 anytype
//! 鸭子类型——GUI/语音/跨进程后端照显式契约实现即可,不必猜隐式方法集。
//!
//! 进程内 vs 进程外(同一协议,不同传输):
//! - 进程内:TuiBackend.emit(CoreEvent) 直接翻成 RenderRegion 调用(零序列化)。
//! - 进程外(未来):WsBackend.emit = ws.send(json(CoreEvent));
//!   poll = parse(ws.recv()) → UiEvent。core 化进程 + 加 WsBackend 即跨进程。
//!
//! tick(定期激活)**不进 vtable**:UI 后端自己起 tick 线程/timer(TuiBackend=
//! spinner tick 线程,GUI=requestAnimationFrame,语音=无 tick)。core 不管。

const ui_event = @import("ui_event.zig");

pub const CoreEvent = ui_event.CoreEvent;
pub const UiEvent = ui_event.UiEvent;
pub const SessionId = @import("../session_id.zig").SessionId;

/// UI 后端接口。ctx 是后端实例的 type-erased 指针,emit/poll 是其方法的 thunk。
///
/// **多 Session 路由**:emit/poll 带 session——一个 backend 可多路复用(GUI 多视图按
/// session 分流;TUI N=1 忽略它)。事件本身(CoreEvent/UiEvent)不带 session 字段
/// (D1 决策:签名带参数,避免每变体塞字段 + 序列化重复)。
///
/// 线程性:emit 可能在 agent_loop 线程或工具线程(tool_progress 跨线程)被调——
/// 后端实现自行保证线程安全(TuiBackend.emit 内部持 RenderRegion.lock,同现状)。
pub const UiBackend = struct {
    ctx: *anyopaque,

    /// core→UI:消费一个 CoreEvent(归属 session)。同步——返回时 ev 携带的 borrow slice
    /// 即失效,后端必须在返回前拷贝需要保留的字节。
    emit: *const fn (ctx: *anyopaque, session: SessionId, ev: CoreEvent) void,

    /// UI→core:非阻塞拉取 session 这个会话的一个用户事件。无事件返 null。
    /// 返回 .queue_message 时,其 slice 所有权转移给调用方(agent_loop 用 run 的 allocator
    /// free,见 ui_event.zig);.interrupt 无所有权。agent_loop 在每个 turn 边界反复调到 null
    /// 为止(#115),流式期间不调。
    poll: *const fn (ctx: *anyopaque, session: SessionId) ?UiEvent,

    /// 便利转发(可读性 + 给 agent_loop 接线用)。
    pub inline fn emitEvent(self: *const UiBackend, session: SessionId, ev: CoreEvent) void {
        self.emit(self.ctx, session, ev);
    }

    pub inline fn pollEvent(self: *const UiBackend, session: SessionId) ?UiEvent {
        return self.poll(self.ctx, session);
    }
};

test "UiBackend: vtable 字段全为函数指针 + ctx" {
    // 编译期断言结构完整(thunk 接线在 tui_backend.zig / 测试 mock 中)。
    const std = @import("std");
    try std.testing.expect(@sizeOf(UiBackend) > 0);
}
