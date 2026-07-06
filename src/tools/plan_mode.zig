//! EnterPlanMode / ExitPlanMode：让模型主动进/出 plan 模式。
//!
//! Plan 模式下，所有 write/exec 类工具被 permission 拒绝，只允许 read。
//! 用于模型先规划再问用户 → 确认后 exit → 执行。
//!
//! 实现：修改 ctx.permission_ctx.mode；保存原 mode 到 ctx.plan_prev_mode。
//! 需要 ctx 挂 permission_ctx + plan_prev_mode，否则返 error.NotAvailable。
//!
//! ExitPlanMode 审批(对齐 cc):带 `plan` 正文参数 → 经 exit_plan_fn 回调弹审批框 →
//! 仅用户批准才切回执行模式;拒绝则留在 plan,把"继续打磨"回传模型。无回调(headless/
//! 子 agent)→ answer_queue 兜底 → 都无则安全默认 reject(绝不静默放行)。

const std = @import("std");
const ToolContext = @import("context.zig").ToolContext;
const PlanApproval = ToolContext.PlanApproval;

/// Plan 模式工作流指令(对齐 mecode collaboration_mode/plan.md)。**两处共用**:
///   ① EnterPlanMode 返回 tool_result(模型进 plan 当轮读到);
///   ② agent_loop 每轮 system prompt 注入(只要 mode==plan)——根治"模型多轮后忘了 <proposed_plan>
///      格式"(指令若只在 EnterPlanMode 返回出现一次,后续轮模型读不到)。
/// 关键:计划用 <proposed_plan> XML 块走文本流(非工具参数),弱后端只需输出文本就能稳定产计划。
pub const PLAN_MODE_INSTRUCTIONS =
    "You are now in PLAN MODE: research and design only. Do NOT edit code files or run mutating commands. " ++
    "Plan mode is NOT changed by user intent or tone — if the user asks you to execute while still in plan mode, " ++
    "treat it as a request to PLAN the execution, not perform it. " ++
    "Workflow: " ++
    "(1) UNDERSTAND — explore the codebase with read-only tools (Read/Grep/Glob) BEFORE asking questions; " ++
    "resolve everything discoverable from the repo by exploring, not by asking. For broad exploration, spawn the " ++
    "read-only 'Explore' subagent via the Task tool (it can run several in parallel). " ++
    "(2) DESIGN — once you understand the code, decide the approach; for non-trivial designs you may use the " ++
    "read-only 'Plan' subagent to weigh alternatives. " ++
    "(3) CLARIFY — only ask (via AskUserQuestion) about preferences/tradeoffs that cannot be discovered by exploring. " ++
    "(4) PRESENT — when the plan is decision-complete, output it wrapped in a <proposed_plan> block: the opening " ++
    "tag <proposed_plan> on its own line, the markdown plan on the next lines, the closing tag </proposed_plan> " ++
    "on its own line. Then call ExitPlanMode (no need to repeat the plan in its arguments). " ++
    "Do NOT ask 'should I proceed?' in plain text — ExitPlanMode requests approval. The user approves (then you " ++
    "implement) or asks you to keep refining. Produce at most one <proposed_plan> block per turn. " ++
    "PLAN STRUCTURE: write the plan as a numbered or bulleted list of concrete, independently-completable, " ++
    "verifiable steps. On approval the plan becomes a PERSISTENT TASK GRAPH — you and future sessions resume " ++
    "progress from it (via TaskList), so each step must stand on its own. Steps are serial by default (each " ++
    "depends on the previous). If steps are independent, mark dependencies explicitly at the end of a step line " ++
    "as '(depends: N)' or '(depends: N,M)' referring to earlier step numbers — independent steps can then be " ++
    "executed in parallel. After approval, use TaskList to pick ready steps and TaskUpdate completed to close " ++
    "each one (which auto-unlocks its dependents).";

pub fn executeEnter(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    _ = args;
    const pctx = ctx.permission_ctx orelse return error.NotAvailable;
    const prev_slot = ctx.plan_prev_mode orelse return error.NotAvailable;

    // 若已在 plan 模式，幂等返回（不覆盖 prev）
    if (pctx.modeValue() != .plan) {
        prev_slot.* = pctx.modeValue();
        pctx.setMode(.plan);
    }
    // instruction 字段让模型在 tool_result 里读到 plan 模式工作流(进 plan 当轮)。后续轮靠
    // agent_loop 每轮 system prompt 注入同一指令(见 PLAN_MODE_INSTRUCTIONS 注释)。
    const workflow = PLAN_MODE_INSTRUCTIONS;

    // plan 文件可用时,告知路径并允许把计划写盘(它是 plan 模式下唯一可写文件)。
    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"mode\":\"plan\",\"status\":\"entered\",");
    if (ctx.plan_file_path.len > 0) {
        try w.writeAll("\"planFilePath\":");
        try std.json.Stringify.encodeJsonString(ctx.plan_file_path, .{}, w);
        try w.writeAll(",\"instruction\":");
        try std.json.Stringify.encodeJsonString(workflow ++
            " You MAY write/update your plan in the plan file at the planFilePath above (it is the only file " ++
            "you can write in plan mode); then pass that same content to ExitPlanMode.", .{}, w);
    } else {
        try w.writeAll("\"instruction\":");
        try std.json.Stringify.encodeJsonString(workflow, .{}, w);
    }
    try w.writeAll("}");
    return try aw.toOwnedSlice();
}

/// 从 args JSON 取 `plan` 字段(借用 parsed 内存,调用方在 parsed 存活期内用)。
fn extractPlan(allocator: std.mem.Allocator, args: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const v = parsed.value.object.get("plan") orelse return null;
    if (v != .string) return null;
    return allocator.dupe(u8, v.string) catch null;
}

/// answer_queue 兜底(非 tty e2e):弹一条应答 → 映射 PlanApproval。
/// "approve"/"y"/"1" → approve_default;"accept"/"2" → approve_accept_edits;其余 → reject。
fn approvalFromQueue() ?PlanApproval {
    const aq = @import("../core/answer_queue.zig");
    const ans = aq.pop() orelse return null;
    if (ans.len == 0) return .reject;
    if (std.mem.eql(u8, ans, "accept") or ans[0] == '2') return .approve_accept_edits;
    if (std.mem.eql(u8, ans, "approve") or ans[0] == 'y' or ans[0] == 'Y' or ans[0] == '1') return .approve_default;
    return .reject;
}

pub fn executeExit(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const pctx = ctx.permission_ctx orelse return error.NotAvailable;
    const prev_slot = ctx.plan_prev_mode orelse return error.NotAvailable;

    // 非 plan 模式调用 → 幂等返回(对齐 cc outside-plan:不弹框)。
    if (pctx.modeValue() != .plan) {
        return try std.fmt.allocPrint(ctx.allocator, "{{\"mode\":\"{s}\",\"status\":\"not_in_plan\"}}", .{@tagName(pctx.modeValue())});
    }

    // 取计划正文,优先级(对齐新 XML 协议 + 兼容):
    //   ① ctx.last_proposed_plan —— agent_loop 末轮从助手文本提取的 <proposed_plan>(新主路径);
    //   ② 模型传的 plan 参数(兼容老协议);
    //   ③ plan 文件读盘兜底(对齐 cc normalizeToolInput);
    //   ④ 都无 → 空串(审批框显"described above"提示,不卡死)。
    const plan_md = blk: {
        if (ctx.last_proposed_plan.len > 0) break :blk try ctx.allocator.dupe(u8, ctx.last_proposed_plan);
        if (extractPlan(ctx.allocator, args)) |p| {
            if (p.len > 0) break :blk p;
            ctx.allocator.free(p); // 空串 plan 参数 → 当作未传,试读盘
        }
        const plan_file = @import("../core/plan_file.zig");
        if (plan_file.readPlan(ctx.allocator, ctx.plan_file_path)) |from_disk| break :blk from_disk;
        break :blk try ctx.allocator.dupe(u8, "");
    };
    defer ctx.allocator.free(plan_md);

    // 决定审批结果:① 统一 UI 请求弹框;② answer_queue 兜底;③ 安全默认 reject(留 plan)。
    var choice: PlanApproval = .reject;
    const ui_request = @import("../core/protocol/ui_request.zig");
    const req = ui_request.UiRequest{ .plan_approval = .{ .plan_md = plan_md } };
    var resp: ui_request.UiResponse = undefined;
    switch (try ctx.requestUi(ctx.allocator, &req, &resp)) {
        .answered => choice = switch (resp) {
            .plan_approval => |c| c,
            else => .reject, // backend 返回非预期 tag
        },
        // L3:异步前端挂起 → error.UiPending(agent_loop 挂起,resumeRun 续跑)。
        .pending => return error.UiPending,
        // 无 UI 回调(headless/子 agent)→ answer_queue 兜底,再无则 reject。
        .unavailable => choice = approvalFromQueue() orelse .reject,
    }

    switch (choice) {
        .approve_default => {
            // 恢复进 plan 前的原模式(无记录 → default 安全默认)。
            const restore = prev_slot.* orelse .default;
            pctx.setMode(restore);
            prev_slot.* = null;
            const kg_note = try commitPlanToGraph(ctx, plan_md);
            defer if (kg_note) |n| ctx.allocator.free(n);
            return try std.fmt.allocPrint(ctx.allocator, "{{\"mode\":\"{s}\",\"status\":\"approved\"{s}}}", .{ @tagName(pctx.modeValue()), kg_note orelse "" });
        },
        .approve_accept_edits => {
            pctx.setMode(.accept_edits);
            prev_slot.* = null;
            const kg_note = try commitPlanToGraph(ctx, plan_md);
            defer if (kg_note) |n| ctx.allocator.free(n);
            return try std.fmt.allocPrint(ctx.allocator, "{{\"mode\":\"acceptEdits\",\"status\":\"approved\"{s}}}", .{kg_note orelse ""});
        },
        .reject => {
            // 留在 plan 模式;告知模型继续打磨,不要执行。
            return try ctx.allocator.dupe(u8,
                "{\"mode\":\"plan\",\"status\":\"rejected\"," ++
                "\"note\":\"User wants to keep planning. Continue refining the plan and do not execute. Call ExitPlanMode again when the plan is updated.\"}");
        },
    }
}

/// 批准时把计划落成持久任务 DAG(设计 §3)。返回 owned JSON 片段(",\"kg\":{...}"追加进
/// 工具结果)供模型立即进入执行;KG 不可用/失败 → 返回 null(计划仍批准,不阻塞——降级)。
/// 写 kg_root 指针文件供下次 session 恢复。
fn commitPlanToGraph(ctx: *const ToolContext, plan_md: []const u8) !?[]u8 {
    const kg = ctx.kg orelse return null;
    if (!kg.ready or plan_md.len == 0) return null;

    const plan_commit = @import("../kg/plan_commit.zig");
    const result = plan_commit.commit(ctx.allocator, kg, plan_md) catch |e| {
        // 落图失败不阻塞批准(降级):模型仍按计划执行,只是没进图。
        return try std.fmt.allocPrint(ctx.allocator, ",\"kg\":{{\"committed\":false,\"error\":\"{s}\"}}", .{@errorName(e)});
    };

    // 写 kg_root 指针(下次 session 从 frontier 恢复)。
    if (ctx.kg_projects_dir.len > 0) {
        const inject = @import("../kg/inject.zig");
        inject.writeIdPointer(ctx.allocator, ctx.kg_projects_dir, "kg_root", result.root_id) catch {};
    }

    if (!result.structured) {
        return try std.fmt.allocPrint(ctx.allocator,
            ",\"kg\":{{\"committed\":true,\"root_id\":{d},\"structured\":false," ++
            "\"note\":\"计划未能结构化,已按整体目标入图。用 TaskList 查看,TaskUpdate completed 闭合。\"}}",
            .{result.root_id});
    }
    const status = if (result.incomplete) "incomplete" else "complete";
    return try std.fmt.allocPrint(ctx.allocator,
        ",\"kg\":{{\"committed\":true,\"root_id\":{d},\"steps\":{d}/{d},\"status\":\"{s}\"," ++
        "\"note\":\"计划已存为持久任务图({d} 步)。用 TaskList 领 ready 任务,完成后 TaskUpdate completed(会自动解锁后续步骤)。未来 session 从图恢复进度。\"}}",
        .{ result.root_id, result.steps_committed, result.total_steps, status, result.total_steps });
}

test "EnterPlanMode without ctx returns NotAvailable" {
    const ctx = ToolContext{ .allocator = std.testing.allocator };
    try std.testing.expectError(error.NotAvailable, executeEnter(&ctx, "{}"));
}

test "EnterPlanMode 返回含 instruction" {
    const a = std.testing.allocator;
    const permission = @import("../permission.zig");
    var pctx = permission.PermissionContext{ .mode = .init(.default), .allocator = a };
    var prev: ?@import("../types.zig").PermissionMode = null;
    const ctx = ToolContext{ .allocator = a, .permission_ctx = &pctx, .plan_prev_mode = &prev };
    const r = try executeEnter(&ctx, "{}");
    defer a.free(r);
    try std.testing.expect(pctx.modeValue() == .plan);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"instruction\"") != null);
    // 无 plan_file_path → 不含 planFilePath 字段。
    try std.testing.expect(std.mem.indexOf(u8, r, "planFilePath") == null);
}

test "EnterPlanMode 有 plan_file_path → 返回含 planFilePath + 引导写盘" {
    const a = std.testing.allocator;
    const permission = @import("../permission.zig");
    var pctx = permission.PermissionContext{ .mode = .init(.default), .allocator = a };
    var prev: ?@import("../types.zig").PermissionMode = null;
    const ctx = ToolContext{
        .allocator = a,
        .permission_ctx = &pctx,
        .plan_prev_mode = &prev,
        .plan_file_path = "/home/u/.cc-zig/plans/cozy-canyon.md",
    };
    const r = try executeEnter(&ctx, "{}");
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"planFilePath\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "cozy-canyon.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"instruction\"") != null);
}

// 测试用 mock ui_request_fn:plan_approval 请求按 g_mock_choice 返回,并记录收到的 plan_md。
var g_mock_choice: PlanApproval = .reject;
var g_mock_seen_plan: [256]u8 = undefined;
var g_mock_seen_len: usize = 0;
fn mockUiRequestFn(
    state: *anyopaque,
    _: @import("../core/session_id.zig").SessionId,
    allocator: std.mem.Allocator,
    req: *const @import("../core/protocol/ui_request.zig").UiRequest,
    out: *@import("../core/protocol/ui_request.zig").UiResponse,
) anyerror!@import("../core/protocol/ui_request.zig").RequestOutcome {
    _ = state;
    _ = allocator;
    switch (req.*) {
        .plan_approval => |pa| {
            g_mock_seen_len = @min(pa.plan_md.len, g_mock_seen_plan.len);
            @memcpy(g_mock_seen_plan[0..g_mock_seen_len], pa.plan_md[0..g_mock_seen_len]);
            out.* = .{ .plan_approval = g_mock_choice };
        },
        else => out.* = .{ .plan_approval = .reject },
    }
    return .answered;
}

fn setupExitCtx(a: std.mem.Allocator, pctx: *@import("../permission.zig").PermissionContext, prev: *?@import("../types.zig").PermissionMode, dummy_state: *anyopaque) ToolContext {
    return ToolContext{
        .allocator = a,
        .permission_ctx = pctx,
        .plan_prev_mode = prev,
        .ui_requester = .{ .ctx = dummy_state, .requestFn = &mockUiRequestFn },
    };
}

test "ExitPlanMode approve_default → 恢复原模式 + status approved" {
    const a = std.testing.allocator;
    const permission = @import("../permission.zig");
    const types = @import("../types.zig");
    var pctx = permission.PermissionContext{ .mode = .init(.plan), .allocator = a };
    var prev: ?types.PermissionMode = .default;
    var dummy: u8 = 0;
    const ctx = setupExitCtx(a, &pctx, &prev, &dummy);

    g_mock_choice = .approve_default;
    const r = try executeExit(&ctx, "{\"plan\":\"do X\"}");
    defer a.free(r);
    try std.testing.expect(pctx.modeValue() == .default);
    try std.testing.expect(prev == null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"status\":\"approved\"") != null);
}

test "ExitPlanMode approve_accept_edits → 切 accept_edits" {
    const a = std.testing.allocator;
    const permission = @import("../permission.zig");
    const types = @import("../types.zig");
    var pctx = permission.PermissionContext{ .mode = .init(.plan), .allocator = a };
    var prev: ?types.PermissionMode = .default;
    var dummy: u8 = 0;
    const ctx = setupExitCtx(a, &pctx, &prev, &dummy);

    g_mock_choice = .approve_accept_edits;
    const r = try executeExit(&ctx, "{\"plan\":\"do X\"}");
    defer a.free(r);
    try std.testing.expect(pctx.modeValue() == .accept_edits);
    try std.testing.expect(std.mem.indexOf(u8, r, "acceptEdits") != null);
}

test "ExitPlanMode reject → 留 plan + status rejected" {
    const a = std.testing.allocator;
    const permission = @import("../permission.zig");
    const types = @import("../types.zig");
    var pctx = permission.PermissionContext{ .mode = .init(.plan), .allocator = a };
    var prev: ?types.PermissionMode = .default;
    var dummy: u8 = 0;
    const ctx = setupExitCtx(a, &pctx, &prev, &dummy);

    g_mock_choice = .reject;
    const r = try executeExit(&ctx, "{\"plan\":\"do X\"}");
    defer a.free(r);
    try std.testing.expect(pctx.modeValue() == .plan); // 留在 plan
    try std.testing.expect(prev.? == .default); // prev 不清(还在 plan)
    try std.testing.expect(std.mem.indexOf(u8, r, "\"status\":\"rejected\"") != null);
}

test "ExitPlanMode 非 plan 模式 → not_in_plan 幂等" {
    const a = std.testing.allocator;
    const permission = @import("../permission.zig");
    const types = @import("../types.zig");
    var pctx = permission.PermissionContext{ .mode = .init(.default), .allocator = a };
    var prev: ?types.PermissionMode = null;
    var dummy: u8 = 0;
    const ctx = setupExitCtx(a, &pctx, &prev, &dummy);

    const r = try executeExit(&ctx, "{\"plan\":\"x\"}");
    defer a.free(r);
    try std.testing.expect(pctx.modeValue() == .default);
    try std.testing.expect(std.mem.indexOf(u8, r, "not_in_plan") != null);
}

test "ExitPlanMode 无回调无队列 → 安全默认 reject(留 plan)" {
    const a = std.testing.allocator;
    const permission = @import("../permission.zig");
    const types = @import("../types.zig");
    var pctx = permission.PermissionContext{ .mode = .init(.plan), .allocator = a };
    var prev: ?types.PermissionMode = .default;
    // 不挂 exit_plan_fn → 走 answer_queue(测试环境未加载)→ reject。
    const ctx = ToolContext{ .allocator = a, .permission_ctx = &pctx, .plan_prev_mode = &prev };
    const r = try executeExit(&ctx, "{\"plan\":\"x\"}");
    defer a.free(r);
    try std.testing.expect(pctx.modeValue() == .plan); // 绝不静默放行
    try std.testing.expect(std.mem.indexOf(u8, r, "\"status\":\"rejected\"") != null);
}

test "ExitPlanMode 模型未传 plan → 从 plan 文件读盘兜底(对齐 cc normalizeToolInput)" {
    const a = std.testing.allocator;
    const permission = @import("../permission.zig");
    const types = @import("../types.zig");
    const plan_file = @import("../core/plan_file.zig");
    const util_time = @import("../util/time.zig");
    const fs = @import("../util/fs.zig");

    // 准备一个真 plan 文件。
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "/tmp/cc-zig-exitplan-test-{d}", .{util_time.nowMs()});
    defer fs.testing.rmrfBestEffort(home);
    try plan_file.ensureDir(home);
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = plan_file.planFilePath(home, "cozy-canyon", &pbuf);
    var wpath: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(wpath[0..path.len], path);
    wpath[path.len] = 0;
    const fd = std.c.open(@ptrCast(&wpath), std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const body = "# Plan from disk\n1. step one\n";
    _ = std.c.write(fd, body, body.len);
    _ = std.c.close(fd);

    var pctx = permission.PermissionContext{ .mode = .init(.plan), .allocator = a };
    var prev: ?types.PermissionMode = .default;
    var dummy: u8 = 0;
    const ctx = ToolContext{
        .allocator = a,
        .permission_ctx = &pctx,
        .plan_prev_mode = &prev,
        .ui_requester = .{ .ctx = &dummy, .requestFn = &mockUiRequestFn },
        .plan_file_path = path, // 关键:ExitPlanMode 据此读盘
    };

    g_mock_choice = .approve_default;
    g_mock_seen_len = 0;
    const r = try executeExit(&ctx, "{}"); // 模型不传 plan
    defer a.free(r);
    // 审批回调收到的 plan_md 应是盘上内容(读盘兜底生效)。
    try std.testing.expectEqualStrings(body, g_mock_seen_plan[0..g_mock_seen_len]);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"status\":\"approved\"") != null);
}

test "ExitPlanMode 缺 plan 参数不报错(实测 bug:plan 非 required)" {
    // 回归:plan 曾误设为 required → validateRequired 在 dispatch 前拦死,模型不传 plan
    //（把计划写在对话文本里)就被拒。修法:plan 改可选,缺失则空 plan_md 兜底,审批照常走。
    const a = std.testing.allocator;
    const permission = @import("../permission.zig");
    const types = @import("../types.zig");
    var pctx = permission.PermissionContext{ .mode = .init(.plan), .allocator = a };
    var prev: ?types.PermissionMode = .default;
    var dummy: u8 = 0;
    const ctx = setupExitCtx(a, &pctx, &prev, &dummy);

    g_mock_choice = .approve_default;
    const r = try executeExit(&ctx, "{}"); // 无 plan 字段
    defer a.free(r);
    try std.testing.expect(pctx.modeValue() == .default); // 正常审批通过,不因缺 plan 失败
    try std.testing.expect(std.mem.indexOf(u8, r, "\"status\":\"approved\"") != null);
}

test "ExitPlanMode 优先用 ctx.last_proposed_plan(XML 协议主路径)" {
    // 新协议:agent_loop 末轮从助手文本提取的 <proposed_plan> 存 ctx.last_proposed_plan,
    // ExitPlanMode 优先读它(高于 plan 参数 / 读盘)。验证审批框收到的就是它。
    const a = std.testing.allocator;
    const permission = @import("../permission.zig");
    const types = @import("../types.zig");
    var pctx = permission.PermissionContext{ .mode = .init(.plan), .allocator = a };
    var prev: ?types.PermissionMode = .default;
    var dummy: u8 = 0;
    const ctx = ToolContext{
        .allocator = a,
        .permission_ctx = &pctx,
        .plan_prev_mode = &prev,
        .ui_requester = .{ .ctx = &dummy, .requestFn = &mockUiRequestFn },
        .last_proposed_plan = "# Plan from XML\n1. do it\n",
    };
    g_mock_choice = .approve_default;
    g_mock_seen_len = 0;
    // 即使 args 带 plan 参数,也应优先用 last_proposed_plan。
    const r = try executeExit(&ctx, "{\"plan\":\"arg plan should be ignored\"}");
    defer a.free(r);
    try std.testing.expectEqualStrings("# Plan from XML\n1. do it\n", g_mock_seen_plan[0..g_mock_seen_len]);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"status\":\"approved\"") != null);
}
