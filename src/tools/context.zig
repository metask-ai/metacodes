//! ToolContext：工具执行时拿到的所有依赖。
//!
//! 目的：从 agent_loop 传进工具的信息，让工具能做 abort 检查、权限钩子、
//! cwd 解析等，而不必每个工具自己 @import util/abort.zig。
//!
//! 本期（M2）字段：
//! - allocator：工具的 scratch allocator（owned output 用）
//! - abort：AbortSignal 可空指针，工具可在长循环中检查或传给 spawnCaptureStdoutAbortable
//!
//! 本期留占位（M3+ 扩展）：
//! - cwd：未来 cwd 解析用（暂使 process cwd）
//! - permission：permission.Context，tool.checkPermissions 钩子会用
//! - verbose：日志粒度

const std = @import("std");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    abort: ?*const AbortSignal = null,

    /// 便利构造：只需 allocator 的场景（大多数单元测试）。
    pub fn simple(allocator: std.mem.Allocator) ToolContext {
        return .{ .allocator = allocator };
    }

    /// 带 abort 的构造。
    pub fn withAbort(allocator: std.mem.Allocator, abort: *const AbortSignal) ToolContext {
        return .{ .allocator = allocator, .abort = abort };
    }

    /// 快捷：检查 abort 是否触发，若是返回 error.Aborted。
    pub fn throwIfAborted(self: *const ToolContext) error{Aborted}!void {
        if (self.abort) |a| return a.throwIfAborted();
    }
};

test "simple ctx has no abort" {
    const ctx = ToolContext.simple(std.testing.allocator);
    try std.testing.expect(ctx.abort == null);
    try ctx.throwIfAborted();
}

test "withAbort ctx propagates abort" {
    var sig = AbortSignal.init();
    sig.abort(.user_ctrl_c);
    const ctx = ToolContext.withAbort(std.testing.allocator, &sig);
    try std.testing.expectError(error.Aborted, ctx.throwIfAborted());
}
