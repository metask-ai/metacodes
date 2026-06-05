//! EnterPlanMode / ExitPlanMode：让模型主动进/出 plan 模式。
//!
//! Plan 模式下，所有 write/exec 类工具被 permission 拒绝，只允许 read。
//! 用于模型先规划再问用户 → 确认后 exit → 执行。
//!
//! 实现：修改 ctx.permission_ctx.mode；保存原 mode 到 ctx.plan_prev_mode。
//! 需要 ctx 挂 permission_ctx + plan_prev_mode，否则返 error.NotAvailable。

const std = @import("std");
const ToolContext = @import("context.zig").ToolContext;

pub fn executeEnter(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    _ = args;
    const pctx = ctx.permission_ctx orelse return error.NotAvailable;
    const prev_slot = ctx.plan_prev_mode orelse return error.NotAvailable;

    // 若已在 plan 模式，幂等返回（不覆盖 prev）
    if (pctx.modeValue() != .plan) {
        prev_slot.* = pctx.modeValue();
        pctx.setMode(.plan);
    }
    return try ctx.allocator.dupe(u8, "{\"mode\":\"plan\",\"status\":\"entered\"}");
}

pub fn executeExit(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    _ = args;
    const pctx = ctx.permission_ctx orelse return error.NotAvailable;
    const prev_slot = ctx.plan_prev_mode orelse return error.NotAvailable;

    if (pctx.modeValue() == .plan) {
        if (prev_slot.*) |m| {
            pctx.setMode(m);
            prev_slot.* = null;
        } else {
            // 没记录 prev → 回退到 prompt 安全默认
            pctx.setMode(.prompt);
        }
    }
    return try std.fmt.allocPrint(ctx.allocator, "{{\"mode\":\"{s}\",\"status\":\"exited\"}}", .{@tagName(pctx.modeValue())});
}

test "EnterPlanMode without ctx returns NotAvailable" {
    const ctx = ToolContext{ .allocator = std.testing.allocator };
    try std.testing.expectError(error.NotAvailable, executeEnter(&ctx, "{}"));
}

test "Enter/Exit plan mode cycle" {
    const a = std.testing.allocator;
    const permission = @import("../permission.zig");
    var pctx = permission.PermissionContext{ .mode = .init(.auto), .allocator = a };
    var prev: ?@import("../types.zig").PermissionMode = null;
    const ctx = ToolContext{
        .allocator = a,
        .permission_ctx = &pctx,
        .plan_prev_mode = &prev,
    };

    try std.testing.expect(pctx.modeValue() == .auto);
    const r1 = try executeEnter(&ctx, "{}");
    defer a.free(r1);
    try std.testing.expect(pctx.modeValue() == .plan);
    try std.testing.expect(prev.? == .auto);

    const r2 = try executeExit(&ctx, "{}");
    defer a.free(r2);
    try std.testing.expect(pctx.modeValue() == .auto);
    try std.testing.expect(prev == null);
}
