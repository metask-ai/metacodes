//! 统一的"后端调用 UI"请求/响应抽象。
//!
//! 背景:cc-zig 曾有 3 套各自为政的同步阻塞 UI 回调——AskUserQuestion(ask_question_fn)、
//! ExitPlanMode 审批(exit_plan_fn)、权限确认(permission/prompt.zig 的 g_dialog_runner)。
//! 三者本质相同:**agent_loop/工具(主线程)同步阻塞地问 UI 一个问题 → UI 返回一个选择**,
//! 终端接管骨架逐字节相同。本模块把它们统一成一组 UiRequest/UiResponse + 单一回调。
//!
//! 分离架构:UiRequest/UiResponse 是**纯数据 union**(slice/enum,无函数指针),符合
//! CoreEvent 同款约束——agent_loop 经 ctx 回调发请求,backend 是唯一表达层(渲染对话框)。
//! 进程外 backend(未来 WsBackend)可序列化传输。

const std = @import("std");
const context = @import("../tools/context.zig");
const perm_dialog = @import("tui/dialog/permission.zig");

pub const AskQuestion = context.AskQuestion;
pub const PermissionChoice = perm_dialog.PermissionChoice;
pub const PlanApproval = context.ToolContext.PlanApproval;

/// UI 请求(backend → 渲染对应对话框,同步阻塞拿用户选择)。
pub const UiRequest = union(enum) {
    /// AskUserQuestion:一组多选问答。
    ask_question: []const AskQuestion,
    /// 权限确认:工具名 + 参数预览。
    permission: struct { tool: []const u8, args: []const u8 },
    /// ExitPlanMode 计划审批:展示计划 markdown,三选项。
    plan_approval: struct { plan_md: []const u8 },
};

/// UI 响应(用户的选择)。tag 与对应 UiRequest 一一对应。
pub const UiResponse = union(enum) {
    /// ask_question 每问选中的 label(s)(多选用 ", " 拼接)。owned by allocator(caller free)。
    answers: []const []const u8,
    /// 权限选择。
    permission: PermissionChoice,
    /// 计划审批选择。
    plan_approval: PlanApproval,
};

/// 统一回调签名(挂 ToolContext)。state 指向 *TuiBackend(经 trampoline)。
/// out 由调用方栈上提供,回调写入;ask_question 的 answers slice owned by allocator。
pub const UiRequestFn = *const fn (
    state: *anyopaque,
    allocator: std.mem.Allocator,
    req: *const UiRequest,
    out: *UiResponse,
) anyerror!void;

// ============================================================================
// Tests:纯数据守卫(对齐 ui_event.zig CoreEvent 测试)
// ============================================================================

const testing = std.testing;

test "UiRequest/UiResponse 是纯数据(可 @sizeOf,无 comptime-only)" {
    try testing.expect(@sizeOf(UiRequest) > 0);
    try testing.expect(@sizeOf(UiResponse) > 0);
}

test "UiRequest tag 与 UiResponse 对应" {
    const req = UiRequest{ .plan_approval = .{ .plan_md = "do x" } };
    try testing.expect(req == .plan_approval);
    const resp = UiResponse{ .plan_approval = .reject };
    try testing.expect(resp == .plan_approval);
}

test "UiRequest.permission 携带工具名+参数" {
    const req = UiRequest{ .permission = .{ .tool = "Bash", .args = "{\"command\":\"ls\"}" } };
    try testing.expectEqualStrings("Bash", req.permission.tool);
}
