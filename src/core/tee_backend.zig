//! TeeBackend(L4):把一个 CoreEvent 同时转发给两个 UiBackend(decorator/multiplex)。
//!
//! 用途:顶层渲染 backend(TuiBackend/WriterBackend)旁挂一个 DiagnosticsBackend——
//! agent_loop 仍只收一个 `backend`,TeeBackend 在 emit 时先喂 primary(渲染)再喂 secondary
//! (诊断)。诊断关闭时 loop 不包裹、直接传 primary,零开销。
//!
//! poll 只走 primary(诊断后端无输入端;它 poll 恒 null,合并无意义且会丢 primary 的输入)。
//! 纯转发,无 UI 依赖 → 放 core/。

const ui_backend = @import("protocol/ui_backend.zig");

const CoreEvent = ui_backend.CoreEvent;
const UiEvent = ui_backend.UiEvent;
const UiBackend = ui_backend.UiBackend;
const SessionId = ui_backend.SessionId;

pub const TeeBackend = struct {
    primary: *const UiBackend,
    secondary: *const UiBackend,

    pub fn backend(self: *TeeBackend) UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emitThunk, .poll = pollThunk };
    }

    fn emitThunk(ctx: *anyopaque, session: SessionId, ev: CoreEvent) void {
        const self: *TeeBackend = @ptrCast(@alignCast(ctx));
        // 顺序固定:先渲染再诊断。两者都同步消费 borrow slice,返回前都读完,无生命周期问题。
        self.primary.emit(self.primary.ctx, session, ev);
        self.secondary.emit(self.secondary.ctx, session, ev);
    }

    fn pollThunk(ctx: *anyopaque, session: SessionId) ?UiEvent {
        const self: *TeeBackend = @ptrCast(@alignCast(ctx));
        return self.primary.poll(self.primary.ctx, session); // 输入只来自 primary
    }
};

// ── 测试 ─────────────────────────────────────────────────────────────────
const std = @import("std");

test "TeeBackend: emit 转发给两个后端,poll 只走 primary" {
    const Recorder = struct {
        emit_count: u32 = 0,
        poll_count: u32 = 0,
        fn be(self: *@This()) UiBackend {
            return .{ .ctx = @ptrCast(self), .emit = &emitFn, .poll = &pollFn };
        }
        fn emitFn(c: *anyopaque, _: SessionId, _: CoreEvent) void {
            const s: *@This() = @ptrCast(@alignCast(c));
            s.emit_count += 1;
        }
        fn pollFn(c: *anyopaque, _: SessionId) ?UiEvent {
            const s: *@This() = @ptrCast(@alignCast(c));
            s.poll_count += 1;
            return null;
        }
    };
    var prim = Recorder{};
    var sec = Recorder{};
    const pb = prim.be();
    const sb = sec.be();
    var tee = TeeBackend{ .primary = &pb, .secondary = &sb };
    const tb = tee.backend();

    tb.emit(tb.ctx, .single, .stream_begin);
    try std.testing.expectEqual(@as(u32, 1), prim.emit_count);
    try std.testing.expectEqual(@as(u32, 1), sec.emit_count);

    _ = tb.poll(tb.ctx, .single);
    try std.testing.expectEqual(@as(u32, 1), prim.poll_count);
    try std.testing.expectEqual(@as(u32, 0), sec.poll_count); // 诊断后端不被 poll
}
