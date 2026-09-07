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
const output_semantics = @import("../core/output_semantics.zig");
const evaluation_backend_mod = @import("../core/evaluation_backend.zig");
const permission_mod = @import("../permission.zig");
const project_activation = @import("../core/project_rule_activation.zig");
const self_evolution_mod = @import("../core/self_evolution.zig");
const request_gate_mod = @import("../core/request_gate.zig");
const tee_backend_mod = @import("../core/tee_backend.zig");
const tool_context_mod = @import("../tools/context.zig");
const ui_backend_mod = @import("../core/protocol/ui_backend.zig");
const writer_backend = @import("../core/writer_backend.zig");
const stream_json_mod = @import("stream_json_backend.zig");
const util_json = @import("../util/json.zig");

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

/// 读 `--image` 路径列表(\x00 分隔),构造 text+images 按序混排的多模态 user 消息。
/// 每图:扩展名 → MIME 白名单(png/jpg/jpeg/gif/webp,复用 Read 工具判定);读取走
/// tools/common.readAllFromFdCapped(单一入口:读错误显式 ReadError,超 3.75MB 上限
/// FileTooLarge——绝不把截断/部分字节当完整图);base64 缓冲直接转移进 image block
/// (无二次 MB 级拷贝)。空路径段/类型不识别/读失败 → 显式错误(绝不静默跳过)。
fn buildImageUserMessage(
    allocator: std.mem.Allocator,
    text: []const u8,
    image_paths_nul: ?[]const u8,
) !@import("../core/message.zig").Message {
    const msg_mod = @import("../core/message.zig");
    const read_tool = @import("../tools/read.zig");
    const common = @import("../tools/common.zig");

    var blocks: std.ArrayList(msg_mod.Block) = .empty;
    errdefer {
        for (blocks.items) |b| b.deinit(allocator);
        blocks.deinit(allocator);
    }
    if (text.len > 0) try blocks.append(allocator, .{ .text = try allocator.dupe(u8, text) });

    // null = flag 未出现;"" = 用户真传了 `--image ""`,进循环后按空路径报错。
    if (image_paths_nul) |image_paths| {
        var it = std.mem.splitScalar(u8, image_paths, 0);
        while (it.next()) |path| {
            if (path.len == 0) {
                // 空参数(如未设的 shell 变量 `--image "$SHOT"`)静默丢图违背 issue #10 铁律。
                std.debug.print("error: --image: empty path argument\n", .{});
                return error.EmptyImagePath;
            }
            const media_type = read_tool.imageMediaType(path) orelse {
                std.debug.print("error: --image {s}: unsupported image type (png/jpg/jpeg/gif/webp)\n", .{path});
                return error.UnsupportedImageType;
            };
            const fd = pfs.openZ(path, .{ .ACCMODE = .RDONLY }, 0) catch {
                std.debug.print("error: --image {s}: FileNotFound\n", .{path});
                return error.FileNotFound;
            };
            defer _ = pfs.close(fd);
            const raw = common.readAllFromFdCapped(fd, allocator, read_tool.MAX_IMAGE_BYTES) catch |err| {
                std.debug.print("error: --image {s}: {s}\n", .{ path, @errorName(err) });
                return err;
            };
            defer allocator.free(raw);
            const enc = std.base64.standard.Encoder;
            const b64 = try allocator.alloc(u8, enc.calcSize(raw.len));
            errdefer allocator.free(b64);
            _ = enc.encode(b64, raw);
            const mt_owned = try allocator.dupe(u8, media_type);
            errdefer allocator.free(mt_owned);
            // b64 所有权直接转移进 block(消除此前经 userMessageWithImages 的二次 MB 拷贝)。
            try blocks.append(allocator, .{ .image = .{ .media_type = mt_owned, .data = b64 } });
        }
    }

    if (blocks.items.len == 0) return error.EmptyMessage;
    return .{ .role = .user, .blocks = try blocks.toOwnedSlice(allocator) };
}

/// headless 用 WriterBackend null-sink:吞掉 agent_loop 的流式输出（ANSI + tool 注解），
/// 只要最终文本。工具卡事件 no-op,text_chunk/颜色括号全丢弃。
/// 跑单次 prompt。返回进程退出码。
/// `images`:`--image <path>` 的 \x00 分隔路径列表(null=纯文本)。有图时构造一条
/// text+images 按序混排的多模态 user 消息(issue #10);读文件/MIME/大小校验失败或
/// 当前 (provider, model) 不支持图像输入时显式报错退出——绝不静默丢图降级为文本。
pub fn run(
    app: *app_mod.App,
    allocator: std.mem.Allocator,
    prompt: []const u8,
    images: ?[]const u8,
    json_output: bool,
) !u8 {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len == 0 and images == null) {
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

    if (images) |image_paths| {
        // 入口预检:不支持 vision 的 (provider, model) 立即显式报错(不落网络请求)。
        if (!app.provider().supports(.image_input)) {
            std.debug.print(
                "error: model does not support image input (provider capability image_input=false)\n",
                .{},
            );
            return 1;
        }
        // 消息字节必须由 conversation 的 allocator 拥有(deinit 用 self.allocator 释放;
        // 当前两者相同,按构造正确性显式绑定,防将来任一侧换 allocator 变 UB)。
        const conv_allocator = app.conversation.allocator;
        const user_msg = try buildImageUserMessage(conv_allocator, trimmed, image_paths);
        errdefer user_msg.deinit(conv_allocator);
        try app.conversation.append(user_msg);
    } else {
        try app.conversation.appendText(.user, trimmed);
    }

    // Headless is the benchmark/CI entry point, so evaluation cannot remain a
    // REPL-only decorator.  Metadata and event fds are host-owned; malformed
    // grounding fails before the provider or any tool can run.
    var eval_runtime = try evaluation_backend_mod.RuntimeConfig.fromEnvironment(allocator);
    defer if (eval_runtime) |*runtime| runtime.deinit();

    var wb = writer_backend.WriterBackend.initNullWithUsage(&app.usage);
    var wb_be = wb.backend();
    // --stream-json:实时 NDJSON 事件流(运行中止损/定位)。tee 挂在 usage 记账
    // 的 null writer 之上;下游 eval tee 组合拿到的 `be` 已含流式腿,零感知。
    // c_allocator:emit 可能来自工具线程,App arena 非线程安全(WebUI 同则)。
    var sjb = stream_json_mod.StreamJsonBackend.init(std.heap.c_allocator, stdoutStreamSink());
    var sjb_be = sjb.backend();
    var stream_tee = tee_backend_mod.TeeBackend{ .primary = &wb_be, .secondary = &sjb_be };
    var be = if (app.config.stream_json) stream_tee.backend() else wb_be;
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
    // 自演化 S2:store 里有临时规则 → 以固定 kernel 合并进(或独立构成)
    // 项目规则 gate。装载失败/降级一律回退到普通 gate,绝不放倒 Run。
    const self_evo_enabled = self_evolution_mod.enabledFromEnv();
    // host-run 裁决:开工即钉住检查命令(内容哈希),收尾比对后由 host 执行。
    const host_check_mod = @import("../core/host_check.zig");
    const host_check_pin: ?host_check_mod.Pin = if (self_evo_enabled) host_check_mod.Pin.fromEnv() else null;
    var self_evo_ingested: usize = 0;
    var provisional_gate: ?*self_evolution_mod.ProvisionalGate = null;
    defer if (provisional_gate) |pg| pg.deinit();
    // 任务范围收尾义务:上一轮 author 为本任务学得的环境规则(hint 绑定,
    // 有界 nudge)。装载失败 → null,不影响 Run。
    const obligation_gate_mod = @import("../core/obligation_gate.zig");
    var obligation_runtime: ?*obligation_gate_mod.Runtime = null;
    defer if (obligation_runtime) |runtime| {
        runtime.deinit();
        allocator.destroy(runtime);
    };
    if (self_evo_enabled) {
        if (app.kg) |*known_graph| {
            // 结局回灌先于 provisional 装载与 scoped recall:本 Run 一开始
            // 就把 host 提供的已完成 trial 结局写进 KG,召回面立即可见。
            const ingested = self_evolution_mod.ingestOutcomes(allocator, known_graph);
            self_evo_ingested = ingested;
            if (std.c.getenv("METACODES_TASK_HINT")) |hint_c| {
                obligation_runtime = obligation_gate_mod.load(
                    allocator,
                    known_graph,
                    std.mem.span(hint_c),
                );
            }
            if (run_control) |control| {
                provisional_gate = self_evolution_mod.loadProvisionalGate(
                    allocator,
                    known_graph,
                    if (control.project_gate) |base_gate| &base_gate.active else null,
                    if (app.project_dir_or_empty().len > 0) app.project_dir_or_empty() else app.cwdAbs(),
                    control.session_dir,
                    &app.abort,
                    control.observer(),
                );
            }
        }
    }
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
    var run_options = buildOptions(
        app,
        scoped_recall,
        eval_request_gate,
        effective_execution_policy,
        // 工具生命周期事件:eval 协议需要;--stream-json 的实时时间线同样依赖
        // tool_start/tool_result 事件流,单开也要点亮。
        eval_be != null or app.config.stream_json,
        if (run_control) |control| control.observer() else null,
        if (run_control) |control| control.executionBoundary() else null,
        if (provisional_gate) |pg|
            pg.gate()
        else if (run_control) |control|
            control.formalGate()
        else
            null,
    );
    run_options.obligations = obligation_runtime;
    // 输出语义账本:最终结果由 core 定性并组装。取代旧的 lastAssistantText 猜测——那个只看
    // conversation 最后一条 assistant message,分不清 commentary/final,也拼不回 max_tokens
    // 续写被拆成多条 message 的完整答案。
    var output_ledger = output_semantics.Ledger.init(allocator);
    defer output_ledger.deinit();
    run_options.output_ledger = &output_ledger;
    const result = agent_loop.run(
        &app.conversation,
        app.provider(),
        app.tool_defs,
        &app.permission_ctx,
        run_options,
        effective_be,
        allocator,
    ) catch |err| {
        // --stream-json:run 报错提前返回没走到 diag_run_end 收口,悬挂的半个字符也要落地(U+FFFD)。
        if (app.config.stream_json) sjb.flush();
        if (run_control) |control| try control.finishRun(@errorName(err));
        std.debug.print("error: {s}\n", .{@errorName(err)});
        return 1;
    };
    // --stream-json:正常路径 diag_run_end 已触发同一收口;这里幂等兜底,保证 result 行
    // 之前时间线已封口,不留半个字符悬在内存里。
    if (app.config.stream_json) sjb.flush();
    if (run_control) |control| try control.finishRun(@tagName(result.stop_reason));

    // v41 机制遥测:run 末把义务运行时状态折叠成 ontology 行(host 观测,
    // 任务无关)。独立于 self_evo 开关——遥测是机制自观察的数据面;一切
    // 失败静默。
    if (obligation_runtime) |runtime| {
        if (app.kg) |*known_graph| {
            const hint: []const u8 = if (std.c.getenv("METACODES_TASK_HINT")) |h| std.mem.span(h) else "";
            const rid: []const u8 = if (run_control) |control| blk: {
                const b = control.journal.runBinding() catch break :blk "unbound";
                break :blk b.run_id.asSlice();
            } else "unbound";
            _ = @import("../core/obligation_gate.zig").writeTelemetry(allocator, known_graph, runtime, hint, rid);
        }
    }

    // 自演化 S1+S3:Run 完结(观察日志封口)后,规则效果回灌本体 +
    // 满足稀疏触发时经隔离单次 provider 调用起草临时规则并写回 store。
    // 一切结果(含降级)静默——自演化永不影响 Run 的退出语义。
    if (self_evo_enabled) evolve: {
        const known_graph = if (app.kg) |*k| k else break :evolve;
        // host-run 裁决先于 endOfRun:裁决行入库后,author 的 task_context
        // 与下一轮注入立即可见(模型不可干预,失败静默降级)。
        if (host_check_pin) |*pin| {
            const hint: []const u8 = if (std.c.getenv("METACODES_TASK_HINT")) |h| std.mem.span(h) else "";
            // 裁决用的 outcome note 要的是**这次 Run 的结果**。conversation 尾条可能是工具调用
            // 前的过程说明,也可能是被主机拒绝的"过早最终答案"——拿它当结论会污染自演化的
            // 输入。core 已经定性好了,优先用;没定性出结果才退回旧取法。
            const classified = projectRunText(&output_ledger);
            const note_owned: ?[]const u8 = if (classified.text != null)
                null
            else
                lastAssistantText(&app.conversation, allocator) catch null;
            defer if (note_owned) |n| if (n.len > 0) allocator.free(n);
            const note: []const u8 = classified.text orelse (note_owned orelse "");
            _ = host_check_mod.runAndIngest(
                allocator,
                known_graph,
                pin,
                hint,
                note,
                @intCast(@import("../util/time.zig").nowWallNs()),
            );
        }
        const control = run_control orelse break :evolve;
        const binding = control.journal.runBinding() catch break :evolve;
        var identity_buffer: [512]u8 = undefined;
        const base_url: []const u8 = if (std.c.getenv("METACODES_BASE_URL")) |raw|
            std.mem.span(raw)
        else
            "unknown-endpoint";
        const actor_identity = std.fmt.bufPrint(
            &identity_buffer,
            "{s}|{s}",
            .{ base_url, app.activeModel() },
        ) catch break :evolve;
        const evo_outcome = self_evolution_mod.endOfRun(allocator, .{
            .kg = known_graph,
            .session_dir = control.session_dir,
            .project_root = if (app.project_dir_or_empty().len > 0) app.project_dir_or_empty() else app.cwdAbs(),
            .provider = app.provider(),
            .actor_identity = actor_identity,
            .model = app.activeModel(),
            .run_binding = binding,
            .now_ns = @import("../util/time.zig").nowWallNs(),
            .stop_reason = @tagName(result.stop_reason),
            .provisional_active_count = if (provisional_gate) |pg| pg.provisional_count else 0,
            .outcomes_ingested = self_evo_ingested,
            .provisional_candidate_ids = if (provisional_gate) |pg| pg.provisional_candidate_ids else &.{},
            .provisional_bundle_sha256 = if (provisional_gate) |pg| pg.active.bundle_sha256 else null,
            .abort = &app.abort,
        });
        const log = @import("../util/log.zig");
        log.info("self-evolution", "outcome={s}", .{@tagName(evo_outcome)});
    }

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

    const projected = projectRunText(&output_ledger);
    const final_text = if (projected.text) |t| t else lastAssistantText(&app.conversation, allocator) catch "";
    const final_text_owned = projected.text == null;
    const text_kind = if (projected.text != null) projected.kind else fallbackTextKind(final_text);
    defer if (final_text_owned and final_text.len > 0) allocator.free(final_text);

    if (json_output) {
        try emitJson(allocator, final_text, text_kind, &app.file_change_journal, result, &app.usage, app.activeModel());
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
    execution_boundary: ?@import("../core/execution_effect.zig").Boundary,
    project_rule_gate: ?@import("../tools/context.zig").ProjectRuleGate,
) agent_loop.Options {
    return .{
        // R2/F3:run 身份用真实 session id(此前缺省 SessionId.single——RunControl/
        // transcript 用真 id 而 agent_loop 内 KG 任务 claim/lease 归属却是 single,
        // 并发 headless 进程共享 KG store 时租约互相碰撞)。
        .session = app.session_id,
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
        .execution_boundary = execution_boundary,
        .project_rule_gate = project_rule_gate,
        .verification_checkpoint = app.config.verification_checkpoint,
        .verification_final_gate = app.config.verification_final_gate,
        .verification_final_observe = app.config.verification_final_observe,
        .requirement_ledger = app.config.requirement_ledger,
        .requirement_ledger_observe = app.config.requirement_ledger_observe,
        .max_stream_turn_retries = 2,
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
        .artifact_root = app.sessionDir() orelse "",
        .metask_ledger_protocol = if (std.ascii.eqlIgnoreCase(app.config.provider_profile orelse "", "metask"))
            if (app.config.provider_kind == .openai) "openai_chat" else "anthropic_messages"
        else
            null,
        .tool_result_metrics = &app.tool_result_metrics,
        .file_change_journal = &app.file_change_journal,
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
        // 同 REPL:撤回的 document 块要给出可行动的提示,而不是一个错误名。
        // loadTranscript 是原子的,失败时 app.conversation 仍是空的。
        if (e == error.WithdrawnDocumentBlock) {
            std.debug.print(
                "error: this session contains a PDF document block from the withdrawn " ++
                    "first-class document input; it cannot be resumed by this build\n",
                .{},
            );
        } else {
            std.debug.print("error: loadTranscript 失败({s})\n", .{@errorName(e)});
        }
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

    var output_ledger = output_semantics.Ledger.init(allocator);
    defer output_ledger.deinit();
    // resume 不重新召回;fresh eval metadata 已在原进程消费。
    var resume_options = buildOptions(
        app,
        null,
        null,
        execution_policy,
        false,
        run_control.observer(),
        run_control.executionBoundary(),
        run_control.formalGate(),
    );
    resume_options.output_ledger = &output_ledger;
    const result = agent_loop.resumeRun(
        &app.conversation,
        app.provider(),
        app.tool_defs,
        &app.permission_ctx,
        state.tool_use_id,
        response_json,
        crs,
        resume_options,
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

    const projected = projectRunText(&output_ledger);
    const final_text = if (projected.text) |t| t else lastAssistantText(&app.conversation, allocator) catch "";
    const final_text_owned = projected.text == null;
    const text_kind = if (projected.text != null) projected.kind else fallbackTextKind(final_text);
    defer if (final_text_owned and final_text.len > 0) allocator.free(final_text);
    if (json_output) {
        try emitJson(allocator, final_text, text_kind, &app.file_change_journal, result, &app.usage, app.activeModel());
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

/// Run 文本 + 它到底是什么。text 借自 ledger(不 owned);null = core 没定性出任何可见输出,
/// 调用方退回 lastAssistantText(兜底:嵌入方没挂账本,或本 Run 只产出过 commentary)。
pub const RunText = struct {
    text: ?[]const u8,
    /// "final"(完成的结果)| "partial"(可见但未完成)| "unclassified"(兜底取到的
    /// conversation 尾条文本,core 没把它定性成结果)| "none"(没有可见输出)。
    kind: []const u8,
};

pub fn projectRunText(ledger: *const output_semantics.Ledger) RunText {
    if (ledger.finalText()) |t| return .{ .text = t, .kind = "final" };
    // 中断/错误/限额停机产生的可见文本:照打给用户,但明确不是完成的结果。
    if (ledger.partialText()) |t| return .{ .text = t, .kind = "partial" };
    return .{ .text = null, .kind = "none" };
}

/// 兜底路径的诚实标注:core 没定性出结果,但 conversation 尾条还有文本(例如整个 Run 只产出
/// commentary 后撞 max_turns)。**不能沿用 "none"**——那等于一边说"没有可见输出"一边把文本
/// 打进同一条 receipt。
fn fallbackTextKind(text: []const u8) []const u8 {
    return if (text.len == 0) "none" else "unclassified";
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
    text_kind: []const u8,
    changes: ?*@import("../core/file_change.zig").Journal,
    result: agent_loop.RunResult,
    usage: *const app_mod.UsageTotals,
    model: []const u8,
) !void {
    const line = try buildResultLine(allocator, final_text, text_kind, changes, result, usage, model);
    defer allocator.free(line);
    writeStdout(line);
}

/// 构造 result NDJSON 行(owned,含尾部 \n)。提 pub 供 L2 断言格式,不直接写 stdout。
pub fn buildResultLine(
    allocator: std.mem.Allocator,
    final_text: []const u8,
    /// 输出语义(见 core/output_semantics.zig):"final" = 完成的结果;"partial" = 可见但未完成
    /// (中断/API 错误/限额);"none" = 本 Run 没有可见输出。消费者不必再从 stop_reason 猜。
    text_kind: []const u8,
    /// 本 Run 的文件修改账本(见 core/file_change.zig)。非 null → 结果行带 `file_changes`
    /// 信封(`{schema_version, truncated, changes[]}`,由该模块自己拼,不在这里散装),
    /// 消费者拿实际改动不解析 tool_result 里的工具私有 gitDiff。
    changes: ?*@import("../core/file_change.zig").Journal,
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
    // 规范编码器(util/json.zig):非法 UTF-8 字节 → U+FFFD。std.json 的 encodeJsonString 默认
    // 原样透传 0x80..0xFF,二进制工具输出混进最终文本会让整行无法严格解码。
    try util_json.writeJsonString(&aw.writer, final_text);
    try aw.writer.writeAll(",\"text_kind\":");
    try util_json.writeJsonString(&aw.writer, text_kind);
    if (changes) |journal| {
        const file_change = @import("../core/file_change.zig");
        const records = journal.acquire();
        defer journal.release();
        try aw.writer.writeAll(",\"file_changes\":");
        try file_change.writeJsonEnvelope(&aw.writer, records, journal.truncated);
    }
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

/// --stream-json 的 stdout sink(fd 1 直写,一行一次调用,无缓冲即最实时)。
fn stdoutStreamWrite(_: *anyopaque, line: []const u8) void {
    writeStdout(line);
}
var stdout_stream_sink_ctx: u8 = 0;
fn stdoutStreamSink() stream_json_mod.Sink {
    return .{ .ctx = @ptrCast(&stdout_stream_sink_ctx), .writeFn = &stdoutStreamWrite };
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

test "buildImageUserMessage: 文件 → text+image 按序构造(MIME/base64 正确)" {
    const a = std.testing.allocator;
    var tmp_buf: [512]u8 = undefined;
    const dir = @import("../tools/test_tmp.zig").dir(&tmp_buf);
    const path = try std.fmt.allocPrint(a, "{s}/cc-headless-img-test.png", .{dir});
    defer a.free(path);
    {
        const fd = pfs.openZ(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600) catch return error.SkipZigTest;
        defer _ = pfs.close(fd);
        _ = pfs.write(fd, "PNGDATA");
    }
    defer @import("../util/fs.zig").testing.rmrfBestEffort(path);

    var paths_nul: std.ArrayList(u8) = .empty;
    defer paths_nul.deinit(a);
    try paths_nul.appendSlice(a, path);

    const m = try buildImageUserMessage(a, "看图", paths_nul.items);
    defer m.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), m.blocks.len);
    try std.testing.expectEqualStrings("看图", m.blocks[0].text);
    try std.testing.expectEqualStrings("image/png", m.blocks[1].image.media_type);
    // "PNGDATA" 的标准 base64。
    try std.testing.expectEqualStrings("UE5HREFUQQ==", m.blocks[1].image.data);
}

test "buildImageUserMessage: 不识别扩展名/空路径段 → 显式错误(不静默跳过)" {
    const a = std.testing.allocator;
    try std.testing.expectError(
        error.UnsupportedImageType,
        buildImageUserMessage(a, "t", "note.txt"),
    );
    try std.testing.expectError(
        error.EmptyImagePath,
        buildImageUserMessage(a, "t", ""),
    );
    try std.testing.expectError(
        error.FileNotFound,
        buildImageUserMessage(a, "t", "/definitely/not/there.png"),
    );
}
