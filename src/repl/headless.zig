//! Headless 模式：`-p "prompt"` / stdin pipe → 跑单次 agent_loop 后退出。
//!
//! 与 REPL 的区别：
//! - 不进交互循环，不开 raw mode / statusline / progress / history。
//! - 流式输出走静默 writer（不把 ANSI / tool 注解打到 stdout）；
//!   运行结束后从 conversation 提取最后一条 assistant 的文本，干净地打到 stdout。
//! - `--json`：改为 NDJSON 事件流（每行一个 JSON），便于 CI/脚本消费。
//!
//! 退出码：end_turn / max_turns / budget / tool_loop → 0；
//! api_error / tool_error / aborted → 1。tool_loop 保留在 result.stop_reason
//! 供上游区分，但它和其它受控软停一样不把已有产出判成进程失败。

const std = @import("std");
const pfs = @import("platform").fs;
const app_mod = @import("../app.zig");
const agent_loop = @import("../core/agent_loop.zig");
const evaluation_backend_mod = @import("../core/evaluation_backend.zig");
const permission_mod = @import("../permission.zig");
const project_activation = @import("../core/project_rule_activation.zig");
const request_gate_mod = @import("../core/request_gate.zig");
const tee_backend_mod = @import("../core/tee_backend.zig");
const tool_context_mod = @import("../tools/context.zig");
const ui_backend_mod = @import("../core/protocol/ui_backend.zig");
const writer_backend = @import("../core/writer_backend.zig");

/// Headless callers can make tool availability part of their frozen runtime
/// contract with `--disallowed-tools`. The ordinary permission settings still
/// enforce every rule at dispatch; this narrower ceiling additionally removes
/// exact bare tool names from the provider schema so the model cannot spend a
/// turn proposing an action the host has already forbidden.
///
/// Parameterized permission rules such as `Bash(git push *)` are intentionally
/// not treated as name bans: hiding all of Bash would be stronger than the
/// caller requested. They remain enforced by the normal permission pipeline.
const HeadlessToolPolicy = struct {
    disallowed_rules: []const u8,
    parent: ?tool_context_mod.ToolExecutionPolicy = null,

    fn executionPolicy(self: *const HeadlessToolPolicy) tool_context_mod.ToolExecutionPolicy {
        return .{
            .ctx = @ptrCast(self),
            .allowsToolFn = allowsToolAdapter,
            .allowsInvocationFn = allowsInvocationAdapter,
        };
    }

    fn deniesExactName(self: *const HeadlessToolPolicy, name: []const u8) bool {
        var it = std.mem.tokenizeScalar(u8, self.disallowed_rules, ',');
        while (it.next()) |raw| {
            const rule = std.mem.trim(u8, raw, " \t\r\n");
            if (rule.len == 0 or std.mem.indexOfScalar(u8, rule, '(') != null) continue;
            if (std.mem.eql(u8, rule, name)) return true;
        }
        return false;
    }

    fn allowsToolAdapter(raw: *const anyopaque, name: []const u8) bool {
        const self: *const HeadlessToolPolicy = @ptrCast(@alignCast(raw));
        if (self.deniesExactName(name)) return false;
        return if (self.parent) |parent| parent.allowsTool(name) else true;
    }

    fn allowsInvocationAdapter(raw: *const anyopaque, name: []const u8, arguments_json: []const u8) bool {
        const self: *const HeadlessToolPolicy = @ptrCast(@alignCast(raw));
        if (self.deniesExactName(name)) return false;
        return if (self.parent) |parent| parent.allowsInvocation(name, arguments_json) else true;
    }
};

/// headless 用 WriterBackend null-sink:吞掉 agent_loop 的流式输出（ANSI + tool 注解），
/// 只要最终文本。工具卡事件 no-op,text_chunk/颜色括号全丢弃。
/// 跑单次 prompt。返回进程退出码。
pub fn run(
    app: *app_mod.App,
    allocator: std.mem.Allocator,
    prompt: []const u8,
    json_output: bool,
) !u8 {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len == 0) {
        std.debug.print("error: empty prompt\n", .{});
        return 1;
    }

    // A headless caller owns stdin and cannot answer an interactive permission
    // prompt.  This must be set on the session PermissionContext itself (rather
    // than inferred from isatty) so an .ask decision deterministically denies
    // without printing a prompt or consuming fd 0.  In particular, protected
    // paths still override bypassPermissions, but they cannot corrupt --json
    // stdout while failing closed.
    const previous_no_interactive = enterNonInteractivePermissionBoundary(&app.permission_ctx);
    defer restoreInteractivePermissionBoundary(&app.permission_ctx, previous_no_interactive);

    try app.conversation.appendText(.user, trimmed);

    // Headless is the benchmark/CI entry point, so evaluation cannot remain a
    // REPL-only decorator.  Metadata and event fds are host-owned; malformed
    // grounding fails before the provider or any tool can run.
    var eval_runtime = try evaluation_backend_mod.RuntimeConfig.fromEnvironment(allocator);
    defer if (eval_runtime) |*runtime| runtime.deinit();

    var wb = writer_backend.WriterBackend.initNullWithUsage(&app.usage);
    var be = wb.backend();
    const run_control: ?*project_activation.RunControl = if (app.sessionDir()) |dir|
        try project_activation.RunControl.init(
            allocator,
            dir,
            app.session_id,
            if (app.project_dir_or_empty().len > 0) app.project_dir_or_empty() else app.cwdAbs(),
            &app.abort,
        )
    else
        null;
    defer if (run_control) |control| control.deinit();
    if (run_control) |control| control.requireDetachedIdle(
        (if (app.jobs) |*jobs| jobs.runningCount() else 0) +|
            (if (app.agent_jobs) |*jobs| jobs.runningCount() else 0),
        app.swarm.hasTeam(),
    ) catch |err| {
        try control.finishRun(@errorName(err));
        return err;
    };
    var eval_be: ?evaluation_backend_mod.EvaluationBackend = if (eval_runtime) |*runtime| blk: {
        const active_provider = app.provider();
        runtime.configureBudgetReserve(
            active_provider.maxInputTokens(),
            active_provider.maxTokens(),
            app.activeModel(),
        );
        break :blk try runtime.initEvaluation(allocator, runtime.nextMetadata(
            @tagName(app.config.provider_kind),
            app.activeModel(),
            @tagName(app.permission_ctx.modeValue()),
        ));
    } else null;
    const eval_request_gate = if (eval_runtime) |*runtime|
        runtime.requestGate(&app.abort)
    else
        null;
    const eval_execution_policy = if (eval_runtime) |*runtime|
        runtime.toolExecutionPolicy()
    else
        null;
    var headless_tool_policy = HeadlessToolPolicy{
        .disallowed_rules = app.config.disallowed_tools orelse "",
        .parent = eval_execution_policy,
    };
    const effective_execution_policy = if (headless_tool_policy.disallowed_rules.len > 0 or eval_execution_policy != null) headless_tool_policy.executionPolicy() else null;
    defer if (eval_be) |*evaluation| evaluation.deinit();
    var eval_ui: ui_backend_mod.UiBackend = if (eval_be) |*evaluation| evaluation.backend() else be;
    var eval_tee = tee_backend_mod.TeeBackend{ .primary = &be, .secondary = &eval_ui };
    const eval_tee_ui = eval_tee.backend();
    const effective_be: *const ui_backend_mod.UiBackend = if (eval_be != null) &eval_tee_ui else &be;
    // scoped 自动召回(一等公民 P1):headless 单次 prompt 也按请求装配相关记忆(cache-safe 尾注入)。
    const scoped_recall_mod = @import("../kg/scoped_recall.zig");
    var scoped_recall_result: ?scoped_recall_mod.BuildResult = if (app.kg) |*k|
        (scoped_recall_mod.buildWithReceipt(allocator, k, &app.conversation, &app.abort) catch null)
    else
        null;
    defer if (scoped_recall_result) |*result| result.deinit(allocator);
    if (eval_be) |*evaluation| if (scoped_recall_result) |result| {
        try evaluation.setScopedRecallEvidence(.{
            .schema_version = result.receipt.schema_version,
            .status = result.receipt.status,
            .query_sha256 = result.receipt.query_sha256,
            .result_count = result.receipt.result_count,
            .injected_count = result.receipt.injected_count,
            .injected_bytes = result.receipt.injected_bytes,
            .injection_sha256 = result.receipt.injection_sha256,
        });
    };
    const scoped_recall = if (scoped_recall_result) |result| result.text else null;
    const result = agent_loop.run(
        &app.conversation,
        app.provider(),
        app.tool_defs,
        &app.permission_ctx,
        buildOptions(
            app,
            scoped_recall,
            eval_request_gate,
            effective_execution_policy,
            eval_be != null,
            if (run_control) |control| control.observer() else null,
            if (run_control) |control| control.formalGate() else null,
        ),
        effective_be,
        allocator,
    ) catch |err| {
        if (run_control) |control| try control.finishRun(@errorName(err));
        std.debug.print("error: {s}\n", .{@errorName(err)});
        return 1;
    };
    if (run_control) |control| try control.finishRun(@tagName(result.stop_reason));

    // Streaming writes every complete event as it is emitted; the final flush
    // is still mandatory so a short write or transient sink error cannot leave
    // a successful headless result backed by an incomplete artifact.
    if (eval_be) |*evaluation| {
        if (eval_runtime) |*runtime| try runtime.appendEvaluation(evaluation);
    }

    app.persistTranscript();

    // L3:挂起 → 落 suspend.json(挂起元数据 + 同轮已完成结果),供跨进程恢复。
    if (result.suspend_info) |si| {
        defer si.deinit();
        if (app.sessionDir()) |dir| {
            const suspend_state = @import("../core/suspend_state.zig");
            suspend_state.writeFromSuspendInfo(dir, si, allocator) catch |e| {
                std.debug.print("warning: suspend.json write failed: {s}\n", .{@errorName(e)});
            };
            std.debug.print("⏸ Suspended (kind={s}) — resume from session dir: {s}\n", .{ si.kind, dir });
        }
    }

    const final_text = lastAssistantText(&app.conversation, allocator) catch "";
    defer if (final_text.len > 0) allocator.free(final_text);

    if (json_output) {
        try emitJson(allocator, final_text, result, &app.usage, app.activeModel());
    } else {
        // 纯文本：直接打模型最终回复 + 结尾换行
        writeStdout(final_text);
        if (final_text.len == 0 or final_text[final_text.len - 1] != '\n') writeStdout("\n");
    }

    return exitCodeFor(result.stop_reason);
}

/// 构造 agent_loop.Options(run + resumeSuspended 共用,消两份字段漂移)。
/// scoped_recall = 本轮尾注入的召回记忆(fresh run 传;resume 传 null——续跑不重新召回)。
/// **task#20:headless 挂起 requester**。恒返 .pending → UI 工具(ask_user/plan_mode)返 error.UiPending
/// → agent_loop 挂起(写 suspend.json)。out 不写(响应经 subprocess resume 的 --resume-response 迟来)。
const ui_request_mod = @import("../core/protocol/ui_request.zig");
fn pendingRequestFn(
    _: *anyopaque,
    _: @import("../core/session_id.zig").SessionId,
    _: std.mem.Allocator,
    _: *const ui_request_mod.UiRequest,
    _: *ui_request_mod.UiResponse,
) anyerror!ui_request_mod.RequestOutcome {
    return .pending;
}
var pending_requester_dummy: u8 = 0;

fn buildOptions(
    app: *app_mod.App,
    scoped_recall: ?[]const u8,
    request_gate: ?request_gate_mod.Gate,
    execution_policy: ?tool_context_mod.ToolExecutionPolicy,
    emit_semantic_tool_events: bool,
    tool_observer: ?@import("../tools/context.zig").ToolObservationSink,
    project_rule_gate: ?@import("../tools/context.zig").ProjectRuleGate,
) agent_loop.Options {
    return .{
        // task#20:--suspendable 时装恒 .pending requester → headless 遇 UI 工具挂起而非 NotATty。
        .ui_requester = if (app.config.suspendable)
            .{ .ctx = @ptrCast(&pending_requester_dummy), .requestFn = &pendingRequestFn }
        else
            null,
        .verbose = app.config.verbose,
        .abort = &app.abort,
        .request_gate = request_gate,
        .execution_policy = execution_policy,
        .tool_observer = tool_observer,
        .project_rule_gate = project_rule_gate,
        .verification_checkpoint = app.config.verification_checkpoint,
        // Tool lifecycle events are part of the evaluation protocol even
        // though the null writer renders no cards.  Leaving this false made
        // headless traces contain policy decisions without tool attempts.
        .emit_tool_cards = emit_semantic_tool_events,
        .read_state = &app.read_state,
        .lsp = app.lsp_service, // Y2:headless 也接 LSP 诊断
        .jobs = if (app.jobs) |*j| j else null,
        .agent_jobs = if (app.agent_jobs) |*aj| aj else null,
        .swarm = &app.swarm, // SW7:headless 也接 swarm
        .plan_prev_mode = &app.plan_prev_mode,
        .tasks = &app.tasks,
        .kg = if (app.kg) |*k| k else null,
        .kg_projects_dir = app.kg_projects_dir,
        .memdir_abs = app.memdir_abs,
        .api_client = app.anthropicClientOrNull(),
        .tool_defs = app.tool_defs,
        .system_prompt = app.system_prompt,
        .inject_user_context = app.user_context,
        .synthetic_user_input = scoped_recall,
        .dyn_registry = &app.dyn_registry,
        .host_services = app.hostServices(),
        .project_dir = app.project_dir_or_empty(),
        .sandbox = app.sandboxPtr(),
        .cwd_abs = app.cwdAbs(),
        .additional_dirs = app.additionalDirs(),
        .home_dir = app.homeDir(),
        .agents = &app.agents,
        .parent_model = app.activeModel(),
        .skills_set = &app.skills,
        .mcp_sessions = &app.mcp_sessions.items,
        .cron_registry = &app.cron_registry,
    };
}

/// **U8:suspend/resume 生产接线 —— read→resumeRun 闭环**。异步前端(Slack/邮件/工作流)的
/// UI 请求返 error.UiPending → run 挂起落 suspend.json + 退出码 2。响应 out-of-band 到达后,
/// 新进程带 response_json 调本函数:loadTranscript 重建对话 → suspend_state.read 取挂起点
/// (tool_use_id/completed_results)→ resumeRun 注入迟来结果续跑 → 完成清 suspend.json,再挂起则
/// 重写(resume 可链式)。**这是把此前只有 write 侧的挂起机制补成完整闭环**(read 侧原零调用者)。
///
/// 前置:app 已用与挂起时**同一 session_id** init(transcript 目录一致);response_json 是挂起工具
/// (AskUserQuestion/ExitPlanMode/custom)的迟来结果(工具结果 JSON,直接作 tool_result content)。
pub fn resumeSuspended(
    app: *app_mod.App,
    allocator: std.mem.Allocator,
    response_json: []const u8,
    json_output: bool,
) !u8 {
    const previous_no_interactive = enterNonInteractivePermissionBoundary(&app.permission_ctx);
    defer restoreInteractivePermissionBoundary(&app.permission_ctx, previous_no_interactive);

    const suspend_state = @import("../core/suspend_state.zig");
    const transcript = @import("../core/transcript.zig");
    const dir = app.sessionDir() orelse {
        std.debug.print("error: resume 需要 session 目录(--session/持久化 transcript)\n", .{});
        return 1;
    };

    // 读挂起点(tool_use_id/kind/completed_results)。缺 suspend.json = 无挂起可恢复。
    const state = suspend_state.read(dir, allocator) catch |e| {
        std.debug.print("error: 读 suspend.json 失败({s})——该 session 无待恢复挂起?\n", .{@errorName(e)});
        return 1;
    };
    defer suspend_state.freeState(state, allocator);

    // 重建对话(挂起前的完整历史;transcript 是持久真相)。app.conversation 由 init 已建空,
    // loadTranscript 追加历史消息。
    transcript.loadTranscript(&app.conversation, dir, allocator) catch |e| {
        std.debug.print("error: loadTranscript 失败({s})\n", .{@errorName(e)});
        return 1;
    };

    var wb = writer_backend.WriterBackend.initNullWithUsage(&app.usage);
    const be = wb.backend();
    var run_control = try project_activation.RunControl.init(
        allocator,
        dir,
        app.session_id,
        if (app.project_dir_or_empty().len > 0) app.project_dir_or_empty() else app.cwdAbs(),
        &app.abort,
    );
    defer run_control.deinit();
    run_control.requireDetachedIdle(
        (if (app.jobs) |*jobs| jobs.runningCount() else 0) +|
            (if (app.agent_jobs) |*jobs| jobs.runningCount() else 0),
        app.swarm.hasTeam(),
    ) catch |err| {
        try run_control.finishRun(@errorName(err));
        return err;
    };

    // suspend_state.CompletedResult → agent_loop.SuspendInfo.CompletedResult(同形状,异 nominal 类型)。
    const CR = agent_loop.SuspendInfo.CompletedResult;
    const crs = allocator.alloc(CR, state.completed_results.len) catch {
        std.debug.print("error: resume OOM\n", .{});
        return 1;
    };
    defer allocator.free(crs);
    for (state.completed_results, 0..) |src, i| {
        crs[i] = .{ .tool_use_id = src.tool_use_id, .content = src.content, .is_error = src.is_error };
    }

    var headless_tool_policy = HeadlessToolPolicy{
        .disallowed_rules = app.config.disallowed_tools orelse "",
    };
    const execution_policy = if (headless_tool_policy.disallowed_rules.len > 0)
        headless_tool_policy.executionPolicy()
    else
        null;

    const result = agent_loop.resumeRun(
        &app.conversation,
        app.provider(),
        app.tool_defs,
        &app.permission_ctx,
        state.tool_use_id,
        response_json,
        crs,
        buildOptions(app, null, null, execution_policy, false, run_control.observer(), run_control.formalGate()), // resume 不重新召回;fresh eval metadata 已在原进程消费
        &be,
        allocator,
    ) catch |err| {
        try run_control.finishRun(@errorName(err));
        std.debug.print("error: resumeRun 失败({s})\n", .{@errorName(err)});
        return 1;
    };
    try run_control.finishRun(@tagName(result.stop_reason));

    app.persistTranscript();

    // 完成 → 清 suspend.json;再次挂起(resume 链式)→ 重写新挂起点。
    if (result.suspend_info) |si| {
        defer si.deinit();
        suspend_state.writeFromSuspendInfo(dir, si, allocator) catch |e| {
            std.debug.print("warning: suspend.json 重写失败: {s}\n", .{@errorName(e)});
        };
        std.debug.print("⏸ 再次挂起 (kind={s}) — 续 resume from: {s}\n", .{ si.kind, dir });
    } else {
        suspend_state.clear(dir); // 恢复完成,挂起点作废
    }

    const final_text = lastAssistantText(&app.conversation, allocator) catch "";
    defer if (final_text.len > 0) allocator.free(final_text);
    if (json_output) {
        try emitJson(allocator, final_text, result, &app.usage, app.activeModel());
    } else {
        writeStdout(final_text);
        if (final_text.len == 0 or final_text[final_text.len - 1] != '\n') writeStdout("\n");
    }
    return exitCodeFor(result.stop_reason);
}

/// Install the process-input ownership boundary used by both fresh headless
/// runs and subprocess resume.  The previous value is returned so library
/// consumers that reuse an App can restore their session exactly.
fn enterNonInteractivePermissionBoundary(ctx: *permission_mod.PermissionContext) bool {
    const previous = ctx.no_interactive_prompt;
    ctx.no_interactive_prompt = true;
    return previous;
}

fn restoreInteractivePermissionBoundary(ctx: *permission_mod.PermissionContext, previous: bool) void {
    ctx.no_interactive_prompt = previous;
}

test "headless permission boundary restores reusable session state" {
    var permission = permission_mod.createContext(.default, std.testing.allocator);
    permission.no_interactive_prompt = true;
    const previous = enterNonInteractivePermissionBoundary(&permission);
    restoreInteractivePermissionBoundary(&permission, previous);
    try std.testing.expect(permission.no_interactive_prompt);
}

test "headless tool policy intersects exact CLI denies with its parent" {
    const Parent = struct {
        var sentinel: u8 = 0;
        fn allowsTool(_: *const anyopaque, name: []const u8) bool {
            return !std.mem.eql(u8, name, "Write");
        }
        fn allowsInvocation(_: *const anyopaque, name: []const u8, _: []const u8) bool {
            return !std.mem.eql(u8, name, "Write");
        }
    };
    var policy = HeadlessToolPolicy{
        .disallowed_rules = " EnterPlanMode, Bash(git push *), Agent ",
        .parent = .{
            .ctx = @ptrCast(&Parent.sentinel),
            .allowsToolFn = Parent.allowsTool,
            .allowsInvocationFn = Parent.allowsInvocation,
        },
    };
    const execution = policy.executionPolicy();
    try std.testing.expect(!execution.allowsTool("EnterPlanMode"));
    try std.testing.expect(!execution.allowsInvocation("Agent", "{}"));
    try std.testing.expect(!execution.allowsTool("Write"));
    try std.testing.expect(execution.allowsTool("Bash"));
    try std.testing.expect(execution.allowsInvocation("Bash", "{\"command\":\"git status\"}"));
    try std.testing.expect(execution.allowsTool("KgRecall"));
}

/// 把 conversation 最后一条 assistant message 的所有 text block 拼起来（owned）。
pub fn lastAssistantText(conv: *const @import("../core/conversation.zig").Conversation, allocator: std.mem.Allocator) ![]const u8 {
    var i: usize = conv.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = conv.messages.items[i];
        if (m.role != .assistant) continue;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        for (m.blocks) |b| {
            switch (b) {
                .text => |t| try buf.appendSlice(allocator, t),
                else => {},
            }
        }
        // A breaker finalization provider may ignore the empty tool set and
        // return only tool_use. Fall back to the preceding assistant prose
        // instead of replacing useful partial work with an empty final result.
        if (buf.items.len == 0) {
            buf.deinit(allocator);
            continue;
        }
        return buf.toOwnedSlice(allocator);
    }
    return allocator.dupe(u8, "");
}

/// NDJSON：一行 result 事件。包含最终文本、stop_reason、turns、tool_calls、usage。
fn emitJson(
    allocator: std.mem.Allocator,
    final_text: []const u8,
    result: agent_loop.RunResult,
    usage: *const app_mod.UsageTotals,
    model: []const u8,
) !void {
    const line = try buildResultLine(allocator, final_text, result, usage, model);
    defer allocator.free(line);
    writeStdout(line);
}

/// 构造 result NDJSON 行(owned,含尾部 \n)。提 pub 供 L2 断言格式,不直接写 stdout。
pub fn buildResultLine(
    allocator: std.mem.Allocator,
    final_text: []const u8,
    result: agent_loop.RunResult,
    usage: *const app_mod.UsageTotals,
    model: []const u8,
) ![]u8 {
    const stop = switch (result.stop_reason) {
        .end_turn => "end_turn",
        .max_turns => "max_turns",
        .aborted => "aborted",
        .api_error => "api_error",
        .tool_error => "tool_error",
        .tool_loop => "tool_loop",
        .suspended => "suspended",
        .backgrounded => "backgrounded", // headless 不会转后台,但 switch 须穷尽
        .budget => "budget",
    };
    const cost = usage.costUsd(model);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print(
        \\{{"type":"result","stop_reason":"{s}","turns":{d},"tool_calls":{d},"input_tokens":{d},"output_tokens":{d},"cache_read_input_tokens":{d},"cache_creation_input_tokens":{d},"cost_usd":{d:.6},"text":
    , .{
        stop,
        result.turns,
        result.tool_calls,
        usage.input_tokens,
        usage.output_tokens,
        usage.cache_read_input_tokens,
        usage.cache_creation_input_tokens,
        cost,
    });
    try std.json.Stringify.encodeJsonString(final_text, .{}, &aw.writer);
    try aw.writer.writeAll("}\n");
    return try aw.toOwnedSlice();
}

/// 退出码逻辑(提 pub 供 L2):受控停止 → 0;suspended → 2(挂起待恢复,非失败);
/// 其它(api/tool error 或 aborted)→ 1。
pub fn exitCodeFor(stop_reason: agent_loop.StopReason) u8 {
    return switch (stop_reason) {
        .end_turn, .max_turns, .budget, .tool_loop => 0,
        .suspended => 2, // 挂起待恢复:区别于完成(0)与失败(1)
        else => 1,
    };
}

fn writeStdout(bytes: []const u8) void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = pfs.write(1, bytes[pos..]); // 可移植(POSIX write / Windows _write),fd 1=stdout
        if (n <= 0) break;
        pos += @as(usize, @intCast(n));
    }
}

test "lastAssistantText extracts trailing assistant text" {
    const a = std.testing.allocator;
    var conv = @import("../core/conversation.zig").Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    try conv.appendText(.assistant, "hello there");
    const t = try lastAssistantText(&conv, a);
    defer a.free(t);
    try std.testing.expectEqualStrings("hello there", t);
}

test "lastAssistantText empty when no assistant" {
    const a = std.testing.allocator;
    var conv = @import("../core/conversation.zig").Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    const t = try lastAssistantText(&conv, a);
    defer a.free(t);
    try std.testing.expectEqualStrings("", t);
}
