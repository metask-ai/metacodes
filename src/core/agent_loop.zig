//! Agent 主循环：user → API stream → tool_use(s) → tool_result(s) → API stream → ...
//!
//! M0.5 把 main.zig 的 runRepl 里嵌在 while 里的业务逻辑抽到这里。
//! M1.5 加入 AbortSignal 检查点：每轮开头、每 stream 事件前检查，触发时返回 .aborted。
//!
//! 核心：用 Conversation 的 Block tagged union 正确保存 tool_use / tool_result，
//! 不再像旧版那样把所有东西扁平化成 text。

const std = @import("std");
const types = @import("../types.zig");
const client_mod = @import("../client.zig");
const json_mod = @import("../json.zig");
const tools_mod = @import("../tools.zig");
const permission_mod = @import("../permission.zig");
const msg = @import("message.zig");
const Conversation = @import("conversation.zig").Conversation;
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const ReadState = @import("read_state.zig").ReadState;
const api_stream = @import("../api/stream.zig");
const tool_error = @import("tool_error.zig");
const util_time = @import("../util/time.zig");
const log = @import("../util/log.zig");
const ui_backend = @import("protocol/ui_backend.zig");
const ui_event = @import("protocol/ui_event.zig");
const UiBackend = ui_backend.UiBackend;
const CoreEvent = ui_event.CoreEvent;

pub const StopReason = enum { end_turn, max_turns, aborted, tool_error, api_error, tool_loop };

/// 工具进度 trampoline:把工具的 progress 回调(WebSearch query/results)转成 CoreEvent,
/// 经 backend 路由到归属 session 的 UI。per-run 实例(backend + session),progress_state 指它。
///
/// **生命周期 invariant**:progress_state 指向的 ProgressTramp 栈变量(agent_loop while-turn
/// 块内)必须活过 `executeSlots`——progress_fn 只在 executeSlots 同步执行期间被工具回调,
/// 那时存储仍在帧上。**若将来把工具执行改成异步/跨 turn 持有 ctx,必须把它移到更长寿的存储**
/// (否则 progress_fn 在栈回收后触发 = UAF)。
const ProgressTramp = struct {
    be: *const UiBackend,
    session: @import("session_id.zig").SessionId,
    fn cb(state: *anyopaque, id: []const u8, phase: tools_mod.ToolContext.ProgressPhase, text: []const u8, count: u32) void {
        const self: *@This() = @ptrCast(@alignCast(state));
        var buf: [192]u8 = undefined;
        const line: []const u8 = switch (phase) {
            // 对齐 cc UI.tsx:query_update→"Searching: q";results_received→"Found N results…".
            .query_update => std.fmt.bufPrint(&buf, "Searching: {s}", .{text}) catch text,
            .results_received => std.fmt.bufPrint(&buf, "Found {d} results for \"{s}\"", .{ count, text }) catch text,
        };
        // line 是栈 borrow,emit 同步消费(TuiBackend.setToolProgress 立即拷进定长卡)。
        self.be.emitEvent(self.session, .{ .tool_progress = .{ .id = id, .text = line } });
    }
};

/// 同一工具连续返回同样错误码达到此次数 → 判定模型陷入死循环,熔断中止本轮 run。
/// 实战痛点(e2e 实测):MiniMax 端点对 Task/TaskCreate 反复发空参 `{}`,触发同一
/// MissingField 错误,从 ~46 turn 烧到 max_turns=50 才停。3 次足以区分"偶发重试"
/// 与"原地空参风暴";到达即注入明确终止现场并停。
pub const MAX_SAME_TOOL_ERROR: u32 = 3;

/// 工具失败签名:工具名 + 错误码 的哈希。用于检测"同工具同错连续 N 次"。
/// 用哈希而非存切片:tu.name/code 生命周期随 turn 释放,存哈希避免悬挂。
const ToolErrSig = struct {
    name_hash: u64,
    code_hash: u64,
    fn of(name: []const u8, code: []const u8) ToolErrSig {
        return .{
            .name_hash = std.hash.Wyhash.hash(0, name),
            .code_hash = std.hash.Wyhash.hash(0, code),
        };
    }
    fn eql(a: ToolErrSig, b: ToolErrSig) bool {
        return a.name_hash == b.name_hash and a.code_hash == b.code_hash;
    }
};

/// Auto-compact 阈值下限:避免 catalog 返回异常小值(测试 mock、未知模型)导致每 turn 都 compact。
/// 低于这个值不做压缩。设为 32K——正常对话/工具调研远小于此,只有真逼近 context window 才触发。
pub const MIN_AUTO_COMPACT_THRESHOLD: usize = 32_000;

pub const RunResult = struct {
    stop_reason: StopReason,
    turns: u32,
    tool_calls: u32,
};

pub const Options = struct {
    max_turns: u32 = 50,
    /// 本次 run 归属的会话(emit/poll 路由用)。默认 .single(N=1/TUI);M6 多 Session 时
    /// 由 SessionContext 传各自的 id。所有 backend.emitEvent 用它路由到对应 UI 视图。
    session: @import("session_id.zig").SessionId = @import("session_id.zig").SessionId.single,
    system_prompt: ?[]const u8 = null,
    verbose: bool = false,
    abort: ?*const AbortSignal = null,
    /// 传给 Write/Edit 做 must-read-first 校验。null → 单测/headless 简化路径（不校验）
    read_state: ?*ReadState = null,
    /// Edit/Write 旁路高亮缓存(diff 工具卡 tree-sitter 着色用)。null → 不缓存。
    edit_hl_cache: ?*@import("edit_hl_cache.zig").EditHlCache = null,
    /// 收集 stream usage 事件：input/output/cache token 数。null → 不累加。
    /// by-value：sink 只含两个指针，直接塞进来，避免悬挂指针风险。
    usage_sink: ?UsageSink = null,
    /// 自动 compact 的 token 阈值。null → 按 resolveMaxTokens() * 0.7 动态算
    auto_compact_threshold: ?usize = null,
    /// 自动 compact 保留的消息数（最新的 N 条）
    auto_compact_keep_recent: usize = 10,
    /// Bash 后台作业注册表（给 ToolContext 用，工具侧 Bash/BashOutput/KillShell 用）
    jobs: ?*@import("job_registry.zig").JobRegistry = null,
    /// 后台 subagent 作业注册表（Task run_in_background + TaskOutput + TaskStop agent_ 分流用）
    agent_jobs: ?*@import("agent_job_registry.zig").AgentJobRegistry = null,
    /// Plan mode 前的原始 mode 存储；EnterPlanMode/ExitPlanMode 用
    plan_prev_mode: ?*?types.PermissionMode = null,
    /// 模型 Task 清单（TaskCreate/Get/List/Update/Stop 共享）
    tasks: ?*@import("task_store.zig").TaskStore = null,
    /// 供 Agent 工具 spawn 子 agent 复用 api_client + tool_defs
    api_client: ?*@import("../client.zig").Client = null,
    tool_defs: ?[]const @import("../json.zig").ToolDefinition = null,
    /// 本次 run 对应的 agent 嵌套深度（父=0，子=1…）
    agent_depth: u8 = 0,
    /// 运行时工具（Skill/MCP）注册表。null = 仅静态工具。
    dyn_registry: ?*const @import("../tools/dynamic.zig").DynRegistry = null,
    /// Skill 激活回调:Skill 工具激活后调用,把临时白/黑名单挂到 App。
    activate_skill_state: ?*anyopaque = null,
    activate_skill_fn: ?*const fn (
        state: *anyopaque,
        skill_name: []const u8,
        allowed: []const []const u8,
        disallowed: []const []const u8,
    ) anyerror!void = null,
    /// ToolSearch 激活 deferred 工具的回调(透传到 ToolContext)。
    activate_tool_state: ?*anyopaque = null,
    activate_tool_fn: ?*const fn (state: *anyopaque, tool_name: []const u8) anyerror!void = null,
    /// 本轮的 Skill 工具调用是否为"用户显式 /name 触发"。
    /// 当前 Stage C 总是 false(只支持模型自主);Stage D 加 /<skill-name> 命令后置 true。
    explicit_invocation: bool = false,
    /// session id + project root + shell-exec policy(对接 Skill 渲染)。
    session_id: []const u8 = "",
    project_dir: []const u8 = "",
    disable_shell_execution: bool = false,
    /// Sandbox 配置(Bash 工具用):非 null 且 enabled 时包 sandbox-exec。
    sandbox: ?*const @import("../sandbox/config.zig").SandboxSettings = null,
    /// cwd 绝对路径 + HOME(sandbox profile 用)。
    cwd_abs: []const u8 = "",
    home_dir: []const u8 = "",
    /// 当前 session plan 文件路径(ExitPlanMode 读盘兜底用;仅顶层接)。
    plan_file_path: []const u8 = "",
    /// 子 agent 定义集合(Task 工具据此找 subagent_type)。
    agents: ?*const @import("../agents/set.zig").AgentSet = null,
    /// 当前会话用的 model 名(供 subagent inherit 解析)。
    parent_model: []const u8 = "",
    /// per-call model override(subagent 用 AgentDef.model 覆盖父 client.model)。
    /// null = 用 api_client.model;非 null = 本次 turn 循环的所有请求都用此 model。
    model_override: ?[]const u8 = null,
    /// Skill 集合(Task 工具 subagent preload_skills 字段用)。
    skills_set: ?*const @import("../skills/skill.zig").SkillSet = null,
    /// ToolSearch 激活的 deferred 工具名集。非 null 时:deferred 且不在此集的工具
    /// 不进 API tools 数组(降低弱后端工具菜单稀释)。null = 不过滤 deferred(全暴露)。
    activated_tools: ?*const std.StringHashMap(void) = null,
    /// Worktree state(EnterWorktree/ExitWorktree 工具用)。
    worktree_state: ?*anyopaque = null,
    worktree_push_fn: ?*const fn (
        state: *anyopaque,
        allocator: std.mem.Allocator,
        wt_path: []const u8,
        original_cwd: []const u8,
    ) anyerror!void = null,
    worktree_pop_fn: ?*const fn (
        state: *anyopaque,
        allocator: std.mem.Allocator,
    ) anyerror!?@import("../tools/worktree.zig").WorktreeEntry = null,
    /// 统一 UI 请求回调(替代旧 ask_question/exit_plan 三套;state 指 *TuiBackend)。
    /// 仅顶层 TUI 接(agent_depth==0)——子 agent 无 tty。
    ui_request_state: ?*anyopaque = null,
    ui_request_fn: ?@import("protocol/ui_request.zig").UiRequestFn = null,
    /// MCP session 列表(ListMcpResourcesTool/ReadMcpResourceTool 用)。
    mcp_sessions: ?*const []@import("mcp_session.zig").McpSessionEntry = null,
    /// Cron registry(CronCreate/Delete/List 用)。
    cron_registry: ?*@import("cron_registry.zig").CronRegistry = null,
    /// 是否给每个工具执行 emit tool_start/tool_result 事件(REPL=true)。
    /// 由 backend(TuiBackend)经 renderResult 渲染(Edit diff 着色 / 搜索摘要 / Read 摘要)。
    /// false(headless/单测)→ 不 emit 工具卡事件,保持纯净输出。
    /// (原 tool_render_theme: ?*const Theme,只当存在标志用;为解 core→UI 类型依赖降为 bool。)
    emit_tool_cards: bool = false,
    /// 子进程长命令"仍在运行"心跳回调(per-session,传给 ToolContext.spawn_tick_fn → spawn 层)。
    /// 重构前是 tools/common.zig 进程全局 g_progress_cb。REPL tty 下 loop.zig 设;headless=null。
    spawn_tick_fn: ?*const fn (elapsed_ms: u64, argv0: []const u8) void = null,
    /// 是否给 assistant 流式文本加 ANSI 着色(\x1b[32m…)。前台交互 REPL = true;
    /// 后台 subagent(输出经 SinkWriter 进可查询缓冲)/headless = false,否则 final_text
    /// 会混入 \x1b[32m 等控制码。
    colorize: bool = true,
    /// 实时进度回调(后台 subagent 用):每轮开始 + 每个工具执行前调用,
    /// 把 (turn, tool_name, tool_input) 写回调用方(JobEntry)。null = 不上报(前台/headless/同步)。
    /// state 经类型擦除传 *JobEntry,progress_fn 是其 trampoline。tool_input 为工具原始
    /// input JSON(供动作行渲染参数预览);仅更新轮次时传空。tool_calls 为截至当前的累计
    /// 工具调用数(供 subagent 树 `· N tools ·` 实时显示)。
    progress_state: ?*anyopaque = null,
    progress_fn: ?*const fn (state: *anyopaque, turn: u32, tool_name: []const u8, tool_input: []const u8, tool_calls: u32) void = null,
};

/// 内部:发一次进度上报(turn 1-based;tool_name/tool_input 空 = 仅更新轮次)。
/// tool_calls = 截至此刻累计工具调用数(单调,trampoline 持锁回写 JobEntry.tool_calls)。
fn reportProgress(opts: Options, turn: u32, tool_name: []const u8, tool_input: []const u8, tool_calls: u32) void {
    if (opts.progress_fn) |f| {
        if (opts.progress_state) |s| f(s, turn, tool_name, tool_input, tool_calls);
    }
}

/// usage 回调接口：stream 每次吐 usage event 时调用。
/// App.usage 实现此接口；测试用 mock 亦可。
pub const UsageSink = struct {
    ctx: *anyopaque,
    addFn: *const fn (ctx: *anyopaque, delta: api_stream.UsageDelta) void,

    pub fn add(self: UsageSink, delta: api_stream.UsageDelta) void {
        self.addFn(self.ctx, delta);
    }
};

/// 一次用户请求的完整 agent 运行：发送当前 conversation 到 API，
/// 收集事件到 assistant message 里（text 和 tool_use blocks），
/// 如果有 tool_use 则执行、追加 tool_result 到 conversation，继续下一轮。
/// 直到没有 tool_use、turns 达到 max_turns、或 abort 触发。
///
/// 每轮的 assistant 响应文字也通过 backend 实时输出（便于 REPL 看流）。
/// backend 是显式 vtable 契约(UiBackend):agent_loop 只发语义 CoreEvent,所有表达
/// (ANSI 颜色 / 工具卡渲染)由 backend 实现(TuiBackend / WriterBackend)完成。
pub fn run(
    conversation: *Conversation,
    api_client: *client_mod.Client,
    tool_defs: []const json_mod.ToolDefinition,
    permission_ctx: *const permission_mod.PermissionContext,
    opts: Options,
    backend: *const UiBackend,
    allocator: std.mem.Allocator,
) !RunResult {
    // 本次 run 归属的会话(emit/poll 路由用)。N=1/TUI 默认 .single;M6 由 SessionContext 传。
    const sess = opts.session;
    var turns: u32 = 0;
    var total_tool_calls: u32 = 0;
    // max_tokens 续写计数:防止模型一直撞上限导致无限续写。上限 3 次。
    var continuations: u32 = 0;
    const MAX_CONTINUATIONS: u32 = 3;

    // 工具错误熔断:**按 turn** 跟踪"同错轮"。本轮有错、无成功、且本轮所有 error 同签名
    // → 算一个"同错轮";连续 MAX_SAME_TOOL_ERROR 个同签名同错轮 → 熔断。任意成功/换签名
    // /无错 → 重置。判定在 6d 内层循环**之后**(避免单轮多工具同错被误算多次)。
    var last_err_sig: ?ToolErrSig = null;
    var same_err_count: u32 = 0;

    // Prompt cache 击穿检测(批3):跨 turn 跟踪 cache_read 跌幅 + system/tools 指纹。
    var cache_detector = @import("cache_break.zig").CacheBreakDetector{};

    while (turns < opts.max_turns) : (turns += 1) {
        // 开头检查 abort
        if (opts.abort) |a| if (a.isAborted()) {
            log.warn("agent", "aborted before turn {d}", .{turns + 1});
            return .{ .stop_reason = .aborted, .turns = turns, .tool_calls = total_tool_calls };
        };

        // 进度上报:进入新一轮(1-based);空 tool 名 = 仅推进轮次,保留上一个工具
        // (trampoline 据空名跳过工具更新,对齐 cc 持续显示最近动作)。
        reportProgress(opts, turns + 1, "", "", total_tool_calls);

        // 自动 compact：发请求前检查 token 估算,超阈值则保留最近 N 条。
        // 阈值 null 时 = input context window * 0.8(逼近 context 上限才压缩,留出回复空间)。
        // **必须用 input context window(resolveMaxInputTokens,~200K),不是 output max_tokens(32K)**——
        // 否则正常工具调研刚读几个文件(20K+)就误触发压缩、丢掉原始问题(真机 bug)。
        // 下限 MIN_AUTO_COMPACT_THRESHOLD:避免异常小值导致每 turn 都 compact。
        const auto_threshold: usize = opts.auto_compact_threshold orelse
            @max(@as(usize, api_client.resolveMaxInputTokens()) * 8 / 10, MIN_AUTO_COMPACT_THRESHOLD);
        // Microcompact(批4):在 full-compact 之前,更低阈值(70% of full)先清旧 tool_result
        // 内容(最占 token 的部分),保留消息结构。比 compactKeepRecent 温和、不丢对话流。
        const micro_threshold = auto_threshold * 7 / 10;
        if (conversation.isOverThreshold(micro_threshold) and !conversation.isOverThreshold(auto_threshold)) {
            const cleared = conversation.microcompactToolResults(opts.auto_compact_keep_recent);
            if (cleared > 0) {
                log.info("agent", "microcompact: cleared {d} old tool_results (msgs={d}) threshold={d}", .{ cleared, conversation.len(), micro_threshold });
            }
        }
        if (conversation.isOverThreshold(auto_threshold)) {
            const before = conversation.len();
            // 9 段结构化摘要(补真缺口):有 api_client → 调模型把要丢的历史总结成 summary
            // prepend 保住早期上下文(对齐 cc);summarize 失败/无 client → 退回纯丢老消息。
            const compact_summary = @import("compact_summary.zig");
            const SummCtx = struct { client: *client_mod.Client, alloc: std.mem.Allocator };
            const dropped = conversation.compactWithSummary(opts.auto_compact_keep_recent, SummCtx{ .client = api_client, .alloc = allocator }, struct {
                fn f(c: SummCtx, drop_msgs: []const msg.Message) ?[]u8 {
                    return compact_summary.summarize(c.alloc, c.client, drop_msgs);
                }
            }.f) catch conversation.compactKeepRecent(opts.auto_compact_keep_recent);
            if (dropped > 0) {
                log.info("agent", "auto-compact: dropped {d} old messages ({d} -> {d}) threshold={d}", .{ dropped, before, conversation.len(), auto_threshold });
                backend.emitEvent(sess, .{ .auto_compact = .{ .dropped = @as(u32, @intCast(dropped)), .kept = @as(u32, @intCast(conversation.len())) } });
            }
        }

        log.info("agent", "turn {d}/{d} starting (msgs={d})", .{ turns + 1, opts.max_turns, conversation.messages.items.len });

        // 1. 构造当前这一轮的 API 请求（把 Conversation 映射为 types.ApiMessage 数组）。
        var api_messages = try buildApiMessages(conversation, allocator);
        defer freeApiMessages(&api_messages, allocator);

        // 2. Skill 激活时硬隔离工具池(SKILL_DESIGN §11 Stage B.8):
        //    根据 permission_ctx.active_skill 的 allowed/disallowed 裁 tool_defs,
        //    模型在请求体里看不见被禁工具,避免反复尝试调用。
        //    与 decision.check 的 active_skill 权限检查互补(双保险)。
        const pool_filter = @import("../skills/tool_pool_filter.zig");
        const filtered_pool = pool_filter.filterToolDefs(allocator, tool_defs, permission_ctx.active_skill) catch null;
        defer pool_filter.freeFiltered(allocator, filtered_pool);
        const skill_filtered = if (filtered_pool) |fp| fp else tool_defs;

        // deferred 过滤(对齐 cc:isMcp→defer)。deferred 工具(主要是 MCP 动态工具)
        // 未激活 → 不进 tools 数组,经 ToolSearch 取 schema 激活后才发。内置工具全不 deferred
        // (实测 33 工具守纪律;真根因是 web_search 异形而非工具数)。
        // 仅顶层(opts.activated_tools 非 null)生效;subagent 不传 → 全暴露。
        var deferred_filtered: ?[]json_mod.ToolDefinition = null;
        defer if (deferred_filtered) |df| allocator.free(df);
        const effective_tool_defs = blk: {
            const acts = opts.activated_tools orelse break :blk skill_filtered;
            // 无任何 deferred 工具 → 不必过滤(对齐 cc:无 deferred 则正常全发)。
            var has_deferred = false;
            for (skill_filtered) |d| {
                if (d.deferred) {
                    has_deferred = true;
                    break;
                }
            }
            if (!has_deferred) break :blk skill_filtered;
            var keep: std.ArrayList(json_mod.ToolDefinition) = .empty;
            errdefer keep.deinit(allocator);
            for (skill_filtered) |d| {
                if (d.deferred and !acts.contains(d.name)) continue; // deferred 未激活 → 隐藏
                keep.append(allocator, d) catch break :blk skill_filtered;
            }
            deferred_filtered = keep.toOwnedSlice(allocator) catch break :blk skill_filtered;
            break :blk deferred_filtered.?;
        };

        // 3. 发送流式请求（abortable 版本：abort 通过 EventIterator 检查点传播）
        //    带 opts.model_override:subagent 用自己的 model(如 Explore=haiku);
        //    null 时 sendMessageStreamFull 用 api_client.model(父 model)。
        // 击穿检测:发请求前记录 system/tools/model 指纹(tools 用工具名拼接 hash)。
        {
            var th = std.hash.Wyhash.init(0);
            for (effective_tool_defs) |d| th.update(d.name);
            var tbuf: [16]u8 = undefined;
            std.mem.writeInt(u64, tbuf[0..8], th.final(), .little);
            const model_for_req = opts.model_override orelse api_client.model;
            cache_detector.recordRequest(opts.system_prompt orelse "", tbuf[0..8], model_for_req);
        }
        // 建连阶段重试(对齐 CC withRetry):瞬态网络错误/429/5xx 退避重试,UI 提示"Retrying…"。
        // 仅覆盖建连+收头(未消费流、未输出文本);进入 stream.next() 后不再重试(已输出)。
        // 门控/格式/着色全在 backend 的 .retry_notice 处理(show_retry/colorize)——此处只转发。
        const RetryUi = struct {
            be: *const UiBackend,
            session: @import("session_id.zig").SessionId,
            fn report(state: *anyopaque, attempt: u32, max: u32, delay_ms: u64) void {
                const self: *@This() = @ptrCast(@alignCast(state));
                self.be.emitEvent(self.session, .{ .retry_notice = .{ .attempt = attempt, .max = max, .delay_ms = delay_ms } });
            }
        };
        var retry_ui = RetryUi{ .be = backend, .session = sess };
        const reporter = client_mod.RetryReporter{ .state = @ptrCast(&retry_ui), .report = RetryUi.report };

        // Plan 模式每轮把 plan 指令追加到 system prompt(对齐 mecode 每轮 developer_instructions):
        // 根治"指令只在 EnterPlanMode 返回出现一次,后续轮模型忘了 <proposed_plan> 格式"。
        // turn 作用域 alloc,用后 free;非 plan 模式直接用 opts.system_prompt(零开销)。
        var sys_prompt_owned: ?[]u8 = null;
        defer if (sys_prompt_owned) |p| allocator.free(p);
        const effective_system_prompt: ?[]const u8 = blk: {
            if (permission_ctx.modeValue() != .plan) break :blk opts.system_prompt;
            const plan_mode = @import("../tools/plan_mode.zig");
            const base = opts.system_prompt orelse "";
            sys_prompt_owned = std.fmt.allocPrint(allocator, "{s}\n\n# Plan Mode (active)\n{s}", .{ base, plan_mode.PLAN_MODE_INSTRUCTIONS }) catch null;
            break :blk if (sys_prompt_owned) |p| p else opts.system_prompt;
        };

        var stream = api_client.sendMessageStreamFullRetry(
            api_messages.items,
            effective_system_prompt,
            effective_tool_defs,
            opts.abort,
            opts.model_override,
            null,
            client_mod.defaultMaxRetries(),
            0, // base_ms=0 → 用默认 RETRY_BASE_MS(500)
            reporter,
        ) catch |err| {
            log.err("agent", "sendMessageStream failed turn={d}: {s}", .{ turns + 1, @errorName(err) });
            return .{ .stop_reason = .api_error, .turns = turns, .tool_calls = total_tool_calls };
        };
        defer stream.deinit();

        // web_search 显示用:把最近一条用户文本作为真实 query 透传给 stream(对齐 mecode——
        // provider 返回的 web_search query 常是占位符,优先显示用户原始输入)。
        stream.user_query = latestUserText(conversation);

        const rid = stream.id;
        log.infoId("agent", rid, "stream opened, reading events", .{});

        // 3. 收集响应 blocks
        var assistant_blocks = std.ArrayList(msg.Block).empty;
        errdefer {
            for (assistant_blocks.items) |b| b.deinit(allocator);
            assistant_blocks.deinit(allocator);
        }
        var assistant_text = std.ArrayList(u8).empty;
        defer assistant_text.deinit(allocator);

        var tool_uses = std.ArrayList(msg.ToolUse).empty;
        defer tool_uses.deinit(allocator);

        if (opts.colorize) backend.emitEvent(sess, .stream_begin);
        var aborted_during_stream = false;
        var stream_error = false;
        while (true) {
            const ev_opt = stream.next() catch |err| switch (err) {
                error.Aborted => {
                    aborted_during_stream = true;
                    log.warnId("agent", rid, "stream aborted mid-turn", .{});
                    break;
                },
                else => |e| {
                    stream_error = true;
                    log.errId("agent", rid, "stream returned error {s} at turn {d}", .{ @errorName(e), turns + 1 });
                    break;
                },
            };
            const ev = ev_opt orelse break;
            switch (ev) {
                .text => |text| {
                    backend.emitEvent(sess, .{ .text_chunk = text });
                    try assistant_text.appendSlice(allocator, text);
                    log.debugId("agent", rid, "text chunk bytes={d}", .{text.len});
                    // text bytes 是 stream 分配的 owned——用完必须 free，否则泄漏
                    allocator.free(text);
                },
                .tool_use_start => |tu| {
                    // verbose 的 `[Tool: name]` 行移到 backend(在 tool_start 渲染时打,
                    // 见 TuiBackend/WriterBackend);此处只入队 tool_use。
                    log.infoId("agent", rid, "tool_use queued id={s} name={s} input_bytes={d}", .{ tu.id, tu.name, tu.input_json.len });
                    // stream 里 id/name/input_json 都是 owned；转移所有权给 tool_uses（不 dupe）
                    try tool_uses.append(allocator, .{
                        .id = tu.id,
                        .name = tu.name,
                        .input = tu.input_json,
                    });
                },
                .web_search_result => |w| {
                    // 主对话:照打 UI 装饰(⏺ Web Search ...),TUI 字节与旧版一致。
                    // ui_text 是预渲染的可见 assistant 内容(例外:含 ANSI 但属"可见输出")。
                    // content_json(结构化结果)主对话不消费(仅 web_search.zig 子请求用)。
                    backend.emitEvent(sess, .{ .text_chunk = w.ui_text });
                    try assistant_text.appendSlice(allocator, w.ui_text);
                    allocator.free(w.ui_text);
                    allocator.free(w.content_json);
                },
                .web_search_query => |q| {
                    // 主对话不消费 query_update 进度(仅 web_search.zig 子请求驱动 TUI);释放。
                    allocator.free(q);
                },
                .usage => |u| {
                    if (opts.usage_sink) |sink| sink.add(u);
                    if (cache_detector.checkResponse(u.cache_read_input_tokens, u.cache_creation_input_tokens)) |reason| {
                        log.warnId("cache", rid, "PROMPT CACHE BREAK: {s} [cache_read {d} creation {d}]", .{ reason, u.cache_read_input_tokens, u.cache_creation_input_tokens });
                    }
                    log.infoId("agent", rid, "usage in={d} out={d} cache_r={d} cache_w={d}", .{ u.input_tokens, u.output_tokens, u.cache_read_input_tokens, u.cache_creation_input_tokens });
                },
                .done => {},
            }
        }
        // 闭颜色括号 + 尾换行由 backend 决定(colorize ? "\x1b[0m\n" : "\n")。
        backend.emitEvent(sess, .stream_done);

        // 抓本轮 API 报告的 stop_reason(stream.deinit 前读;defer 在 turn 末才执行)
        const turn_stop_reason = stream.stopReason();

        log.infoId("agent", rid, "stream finished text_bytes={d} tool_uses={d} aborted={} err={}", .{
            assistant_text.items.len,
            tool_uses.items.len,
            aborted_during_stream,
            stream_error,
        });

        if (aborted_during_stream) {
            // 保留已流出的 partial assistant text（对齐 TS 原版 `onCancel` 行为）：
            // 让用户看到已生成的内容；下次用 /retry 能继续。
            // tool_uses 累了一半但没收齐 content_block_stop 时可能残缺——弃掉（不 commit）。
            for (tool_uses.items) |tu| {
                allocator.free(tu.id);
                allocator.free(tu.name);
                allocator.free(tu.input);
            }
            tool_uses.clearRetainingCapacity();

            if (assistant_text.items.len > 0) {
                const text_owned = try allocator.dupe(u8, assistant_text.items);
                errdefer allocator.free(text_owned);
                try assistant_blocks.append(allocator, .{ .text = text_owned });
            }
            if (assistant_blocks.items.len > 0) {
                const blocks_slice = try assistant_blocks.toOwnedSlice(allocator);
                try conversation.append(.{ .role = .assistant, .blocks = blocks_slice });
            } else {
                assistant_blocks.deinit(allocator);
            }
            return .{ .stop_reason = .aborted, .turns = turns + 1, .tool_calls = total_tool_calls };
        }

        // Stream error：不把残缺的 assistant_text / tool_uses commit 到 conversation
        // 否则下一轮会把残片作为 context 导致模型"续写"残片
        if (stream_error) {
            for (tool_uses.items) |tu| {
                allocator.free(tu.id);
                allocator.free(tu.name);
                allocator.free(tu.input);
            }
            tool_uses.clearRetainingCapacity();
            for (assistant_blocks.items) |b| b.deinit(allocator);
            assistant_blocks.deinit(allocator);
            return .{ .stop_reason = .api_error, .turns = turns + 1, .tool_calls = total_tool_calls };
        }

        // 4. 把 assistant text + tool_uses 组装成 Message 追加到 conversation
        if (assistant_text.items.len > 0) {
            const text_owned = try allocator.dupe(u8, assistant_text.items);
            errdefer allocator.free(text_owned);
            try assistant_blocks.append(allocator, .{ .text = text_owned });
        }
        for (tool_uses.items) |tu| {
            try assistant_blocks.append(allocator, .{ .tool_use = tu });
        }
        // 清空 tool_uses 的所有权转移表示：此后 tool_uses.items 内的字节归 assistant_blocks 所有
        tool_uses.clearRetainingCapacity();

        if (assistant_blocks.items.len > 0) {
            const blocks_slice = try assistant_blocks.toOwnedSlice(allocator);
            try conversation.append(.{ .role = .assistant, .blocks = blocks_slice });
        } else {
            // 空响应，避免 deinit 释放已归还的 slice
            assistant_blocks.deinit(allocator);
        }

        // 5. 如果这一轮没有 tool_use，整个请求结束
        const last_msg = &conversation.messages.items[conversation.messages.items.len - 1];
        var has_tool_use = false;
        for (last_msg.blocks) |b| if (@as(std.meta.Tag(msg.Block), b) == .tool_use) {
            has_tool_use = true;
            break;
        };
        if (!has_tool_use) {
            // max_tokens 续写:模型被 token 上限截断(非自然 end_turn),
            // 注入 continue 提示让它接着写,而不是当作完成。最多 MAX_CONTINUATIONS 次。
            if (turn_stop_reason == .max_tokens and continuations < MAX_CONTINUATIONS) {
                continuations += 1;
                log.infoId("agent", rid, "max_tokens truncation → continuation {d}/{d}", .{ continuations, MAX_CONTINUATIONS });
                try conversation.appendText(.user, "Your previous response was cut off by the token limit. Continue exactly where you left off, without repeating.");
                continue;
            }
            return .{ .stop_reason = .end_turn, .turns = turns + 1, .tool_calls = total_tool_calls };
        }

        // 6. 执行所有 tool_use，把结果作为 user-role 的 tool_result block 追加。
        //    批1:权限检查主线程串行,执行按 isConcurrencySafe 分批并发(tool_exec.zig)。
        var result_blocks = std.ArrayList(msg.Block).empty;
        errdefer {
            for (result_blocks.items) |b| b.deinit(allocator);
            result_blocks.deinit(allocator);
        }

        // 本轮是否触发工具熔断(同工具同错连续 MAX_SAME_TOOL_ERROR 次)。
        var tool_loop_tripped = false;

        // 6a. 收集 tool_use + 主线程串行做权限检查 → slots。
        const tool_exec = @import("tool_exec.zig");
        var slots = std.ArrayList(tool_exec.Slot).empty;
        defer slots.deinit(allocator);
        for (last_msg.blocks) |b| {
            const tu = switch (b) {
                .tool_use => |t| t,
                else => continue,
            };
            total_tool_calls += 1;
            const perm_result = permission_mod.checkPermission(permission_ctx, tu.name, tu.input);
            log.infoId("permission", rid, "tool={s} decision={s}", .{ tu.name, @tagName(perm_result) });
            var slot = tool_exec.Slot{ .decision = .run, .name = tu.name, .id = tu.id, .input = tu.input };
            switch (perm_result) {
                .deny => {
                    log.warnId("permission", rid, "DENY tool={s} input={s}", .{ tu.name, tu.input });
                    slot.decision = .denied;
                    slot.content = try tool_error.errorToJson("PermissionDenied", "tool '{s}' denied by permission rule or plan mode", .{tu.name}, allocator);
                    slot.is_error = true;
                },
                .ask => {
                    // ctx constCast:promptUser 写 session 记忆(有副作用)。同 plan_mode 分支
                    // 的 @constCast 先例——agent_loop 持 *const 但权限交互本就改 per-session 状态。
                    const allowed = permission_mod.promptUser(@constCast(permission_ctx), tu.name, tu.input) catch false;
                    log.infoId("permission", rid, "prompt tool={s} user_allowed={}", .{ tu.name, allowed });
                    if (!allowed) {
                        slot.decision = .denied;
                        slot.content = try tool_error.errorToJson("PermissionDenied", "user declined '{s}' via prompt", .{tu.name}, allocator);
                        slot.is_error = true;
                    }
                },
                .allow => {},
            }
            try slots.append(allocator, slot);
        }

        // 6b. 构造一次 ToolContext(所有 tool 共用;并发 job 各自换独立 arena allocator)。
        // plan 模式:从刚提交的助手文本提取 <proposed_plan>,存进 ctx 供 ExitPlanMode 读
        //（XML 协议主路径,对齐 mecode:计划走文本流而非工具参数)。turn 作用域,用后 free。
        var proposed_plan_buf: ?[]u8 = null;
        defer if (proposed_plan_buf) |p| allocator.free(p);
        if (permission_ctx.modeValue() == .plan and assistant_text.items.len > 0) {
            const pp = @import("proposed_plan.zig");
            proposed_plan_buf = pp.extractProposedPlan(allocator, assistant_text.items) catch null;
        }
        // 工具进度 trampoline 的 per-run 存储(backend + session),供 progress_state 指向。
        // 声明在 base_ctx 同作用域,生命周期覆盖整个工具执行。
        var progress_tramp: ProgressTramp = undefined;
        var base_ctx = tools_mod.ToolContext{
            .allocator = allocator,
            .abort = opts.abort,
            .read_state = opts.read_state,
            .edit_hl_cache = opts.edit_hl_cache,
            .jobs = opts.jobs,
            .agent_jobs = opts.agent_jobs,
            .permission_ctx = @constCast(permission_ctx),
            .plan_prev_mode = opts.plan_prev_mode,
            .tasks = opts.tasks,
            .api_client = opts.api_client,
            .tool_defs = opts.tool_defs,
            .agent_depth = opts.agent_depth,
            .dyn_registry = opts.dyn_registry,
            .activate_skill_state = opts.activate_skill_state,
            .activate_skill_fn = opts.activate_skill_fn,
            .activate_tool_state = opts.activate_tool_state,
            .activate_tool_fn = opts.activate_tool_fn,
            .explicit_invocation = opts.explicit_invocation,
            .session_id = opts.session_id,
            .project_dir = opts.project_dir,
            .disable_shell_execution = opts.disable_shell_execution,
            .sandbox = opts.sandbox,
            .cwd_abs = opts.cwd_abs,
            .home_dir = opts.home_dir,
            .plan_file_path = opts.plan_file_path,
            .last_proposed_plan = if (proposed_plan_buf) |p| p else "",
            .agents = opts.agents,
            .parent_model = opts.parent_model,
            .skills = opts.skills_set,
            .worktree_state = opts.worktree_state,
            .worktree_push_fn = opts.worktree_push_fn,
            .worktree_pop_fn = opts.worktree_pop_fn,
            .mcp_sessions = opts.mcp_sessions,
            .cron_registry = opts.cron_registry,
        };

        // 工具执行期 progress 通路(对齐 cc onProgress):把 WebSearch 子请求的
        // query_update/results_received 格式化成第二行文本,经 backend.emit(.tool_progress) 喂 UI。
        // depth==0 才接(子 agent 不驱动顶层 TUI)。WriterBackend 的 tool_progress no-op → 无害,
        // 故去掉旧 @hasDecl 探测。
        if (opts.agent_depth == 0) {
            progress_tramp = .{ .be = backend, .session = sess };
            base_ctx.progress_state = @ptrCast(&progress_tramp);
            base_ctx.progress_fn = &ProgressTramp.cb;
        }

        // 统一 UI 请求回调(AskUserQuestion/权限/plan 审批共用):仅顶层 TUI(depth==0)接——
        // 子 agent 无 tty,工具按语义兜底(ask→NotATty;plan→answer_queue/reject)。
        if (opts.ui_request_fn != null and opts.agent_depth == 0) {
            base_ctx.ui_request_state = opts.ui_request_state;
            base_ctx.ui_request_fn = opts.ui_request_fn;
        }
        // 子进程心跳(Bash 长命令"仍在运行")per-session 通路:从 opts 透传到 ctx → spawn 层。
        base_ctx.spawn_tick_fn = opts.spawn_tick_fn;
        base_ctx.session = sess; // UiRequest 路由到本 session 视图(M5)

        // 6c. 分批并发执行。过程态(TTY 顶层):无条件 emit tool_start(每个 run slot);
        // **渲染决策(showStartCard/hasProgressCard/喂 spinner)全在 backend**——agent_loop
        // 不再 import tool_card UI widget(层泄漏修复)。headless/subagent(depth>0)/无 theme
        // 时 tool_render_theme=null → 不 emit(那些场景 WriterBackend 也 no-op)。
        if (opts.emit_tool_cards and opts.agent_depth == 0) {
            for (slots.items) |*s| {
                if (s.decision != .run) continue;
                backend.emitEvent(sess, .{ .tool_start = .{ .id = s.id, .name = s.name, .input = s.input } });
            }
        }
        // 进度上报:本轮第一个 run slot 的工具名 + 原始 input(subagent agent 树显示当前动作)。
        if (opts.progress_fn != null) {
            for (slots.items) |*s| {
                if (s.decision == .run) {
                    reportProgress(opts, turns + 1, s.name, s.input, total_tool_calls);
                    break;
                }
            }
        }
        tool_exec.executeSlots(slots.items, &base_ctx, allocator, rid);
        if (opts.emit_tool_cards and opts.agent_depth == 0) {
            backend.emitEvent(sess, .clear_current_tool);
            // 进度卡工具的清卡也无条件发(backend 据 name 自决 clearToolCard)。
            for (slots.items) |*s| {
                if (s.decision == .run) {
                    backend.emitEvent(sess, .{ .tool_result = .{ .id = s.id, .name = s.name, .input = s.input, .content = "", .is_error = s.is_error } });
                }
            }
        }

        // 6d. 按原顺序回填 result_blocks。熔断判定**不在此内层循环累加**——否则单轮内
        // 多个工具调用返回同一错误(如 subagent 第一轮发 3 个 TaskCreate 全失败)会在一轮内
        // 把 same_err_count 累到阈值,turns=1 就误熔断。改为:本轮只归纳"本轮错误特征"
        // (是否所有 error slot 同签名、有无成功 slot),循环后做**跨 turn**累积判定。
        var turn_err_sig: ?ToolErrSig = null; // 本轮 error slot 的统一签名(若全同)
        var turn_uniform_err = true; // 本轮 error slot 是否全是同一签名
        var turn_any_error = false; // 本轮是否有 error slot
        var turn_any_success = false; // 本轮是否有成功 slot
        for (slots.items) |*s| {
            const content = s.content orelse try tool_error.errorToJson("InternalError", "tool {s} produced no result", .{s.name}, allocator);
            if (s.is_error) {
                turn_any_error = true;
                const sig = ToolErrSig.of(s.name, content);
                if (turn_err_sig) |prev| {
                    if (!prev.eql(sig)) turn_uniform_err = false;
                } else {
                    turn_err_sig = sig;
                }
            } else {
                turn_any_success = true;
            }
            try result_blocks.append(allocator, .{ .tool_result = .{
                .tool_use_id = try allocator.dupe(u8, s.id),
                .content = content,
                .is_error = s.is_error,
            } });

            // 实时工具卡渲染(REPL):把结果经 backend 渲染到屏幕——Edit/Write diff 着色、
            // Grep/Glob 摘要、Read 摘要。headless/单测 tool_render_theme=null → 跳过(emit 仍发,
            // 但那些场景用 WriterBackend,tool_result no-op)。渲染移入 backend(renderResult)。
            if (opts.emit_tool_cards) {
                backend.emitEvent(sess, .{ .tool_result = .{
                    .id = s.id,
                    .name = s.name,
                    .input = s.input,
                    .content = content,
                    .is_error = s.is_error,
                    .elapsed_ms = s.elapsed_ms,
                } });
            }
        }

        // 跨 turn 熔断累积:本轮被视为"同错轮"当且仅当——有错、无成功、且本轮所有 error
        // 同一签名。连续 MAX_SAME_TOOL_ERROR 个"同错轮"且签名一致 → 熔断。任意成功 / 换
        // 签名 / 无错 → 重置。这样既治"连续多轮原地同错风暴",又不误杀"单轮并发多工具同错"。
        if (turn_any_error and !turn_any_success and turn_uniform_err) {
            const sig = turn_err_sig.?;
            if (last_err_sig != null and last_err_sig.?.eql(sig)) {
                same_err_count += 1;
            } else {
                same_err_count = 1;
                last_err_sig = sig;
            }
            if (same_err_count >= MAX_SAME_TOOL_ERROR) {
                log.warnId("agent", rid, "tool-loop circuit breaker tripped: same error x{d} turns consecutively", .{same_err_count});
                tool_loop_tripped = true;
            }
        } else {
            same_err_count = 0;
            last_err_sig = null;
        }

        if (result_blocks.items.len == 0) {
            result_blocks.deinit(allocator);
            return .{ .stop_reason = .tool_error, .turns = turns + 1, .tool_calls = total_tool_calls };
        }

        const blocks_owned = try result_blocks.toOwnedSlice(allocator);
        try conversation.append(.{ .role = .user, .blocks = blocks_owned });

        // 工具熔断:同工具同错连续 MAX_SAME_TOOL_ERROR 次 → 停。错误结果已写入
        // conversation(供复盘),这里直接返回 .tool_loop,不再发下一轮请求——避免
        // 模型原地空参风暴烧满 max_turns。
        if (tool_loop_tripped) {
            return .{ .stop_reason = .tool_loop, .turns = turns + 1, .tool_calls = total_tool_calls };
        }
    }

    // 循环正常退出 = turns >= max_turns
    return .{ .stop_reason = .max_turns, .turns = turns, .tool_calls = total_tool_calls };
}

/// 取对话里最近一条 user 文本 block(borrowed),用于 web_search 显示真实 query。
/// 找不到返回 ""。从后往前找第一条 role==.user 且含 text block 的。
fn latestUserText(conversation: *const @import("conversation.zig").Conversation) []const u8 {
    var i: usize = conversation.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = conversation.messages.items[i];
        if (m.role != .user) continue;
        for (m.blocks) |b| {
            if (b == .text and b.text.len > 0) return b.text;
        }
    }
    return "";
}

/// 把 Conversation 中的所有消息 1:1 映射为 `types.ApiMessage`，
/// 供 `client.sendMessageStream` 使用。调用方必须用 `freeApiMessages` 释放。
fn buildApiMessages(
    conversation: *const Conversation,
    allocator: std.mem.Allocator,
) !std.ArrayList(types.ApiMessage) {
    var out = std.ArrayList(types.ApiMessage).empty;
    errdefer {
        freeApiMessages(&out, allocator);
    }

    for (conversation.messages.items) |m| {
        // thinking block 不回 API(模型自己产);先算实际要回的 block 数
        var n_actual: usize = 0;
        for (m.blocks) |b| {
            if (@as(std.meta.Tag(msg.Block), b) != .thinking) n_actual += 1;
        }
        const contents = try allocator.alloc(types.ApiContent, n_actual);
        var idx: usize = 0;
        for (m.blocks) |b| {
            const c: types.ApiContent = switch (b) {
                .text => |t| .{ .text = t }, // 借用，不 dupe——lifetime 绑定 conversation
                .tool_use => |tu| .{ .tool_use = .{ .id = tu.id, .name = tu.name, .input = tu.input } },
                .tool_result => |tr| .{ .tool_result = .{
                    .tool_use_id = tr.tool_use_id,
                    .content = tr.content,
                    .is_error = tr.is_error,
                } },
                .thinking => continue, // 不发回 API
            };
            contents[idx] = c;
            idx += 1;
        }
        try out.append(allocator, .{ .role = m.role, .content = contents });
    }
    return out;
}

fn freeApiMessages(list: *std.ArrayList(types.ApiMessage), allocator: std.mem.Allocator) void {
    for (list.items) |m| {
        allocator.free(m.content);
    }
    list.deinit(allocator);
}

test "buildApiMessages maps blocks" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "hi");

    var api = try buildApiMessages(&c, a);
    defer freeApiMessages(&api, a);

    try std.testing.expect(api.items.len == 1);
    try std.testing.expect(api.items[0].role == .user);
    try std.testing.expect(api.items[0].content.len == 1);
    try std.testing.expectEqualStrings("hi", api.items[0].content[0].text);
}

test "buildApiMessages maps tool_use and tool_result" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    // assistant with tool_use
    const blks_a = try a.alloc(msg.Block, 1);
    blks_a[0] = .{ .tool_use = .{
        .id = try a.dupe(u8, "t1"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{\"path\":\"/x\"}"),
    } };
    try c.append(.{ .role = .assistant, .blocks = blks_a });

    // user with tool_result
    const blks_u = try a.alloc(msg.Block, 1);
    blks_u[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, "t1"),
        .content = try a.dupe(u8, "ok"),
        .is_error = false,
    } };
    try c.append(.{ .role = .user, .blocks = blks_u });

    var api = try buildApiMessages(&c, a);
    defer freeApiMessages(&api, a);

    try std.testing.expect(api.items.len == 2);
    try std.testing.expect(@as(std.meta.Tag(types.ApiContent), api.items[0].content[0]) == .tool_use);
    try std.testing.expect(@as(std.meta.Tag(types.ApiContent), api.items[1].content[0]) == .tool_result);
}

test "buildApiMessages empty conversation returns empty" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    var api = try buildApiMessages(&c, a);
    defer freeApiMessages(&api, a);
    try std.testing.expect(api.items.len == 0);
}

test "buildApiMessages preserves roles" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "u1");
    try c.appendText(.assistant, "a1");
    try c.appendText(.user, "u2");
    var api = try buildApiMessages(&c, a);
    defer freeApiMessages(&api, a);
    try std.testing.expect(api.items[0].role == .user);
    try std.testing.expect(api.items[1].role == .assistant);
    try std.testing.expect(api.items[2].role == .user);
}

test "buildApiMessages multiple blocks per message" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    const blks = try a.alloc(msg.Block, 2);
    blks[0] = .{ .text = try a.dupe(u8, "preamble") };
    blks[1] = .{ .tool_use = .{
        .id = try a.dupe(u8, "t1"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{}"),
    } };
    try c.append(.{ .role = .assistant, .blocks = blks });
    var api = try buildApiMessages(&c, a);
    defer freeApiMessages(&api, a);
    try std.testing.expect(api.items[0].content.len == 2);
}

test "StopReason has aborted and max_turns" {
    // 编译时保证 stop_reason 含新枚举值
    const r: StopReason = .aborted;
    try std.testing.expect(r == .aborted);
    const r2: StopReason = .max_turns;
    try std.testing.expect(r2 == .max_turns);
}

test "auto-compact 阈值用 input context window 而非 output max_tokens(防回归真机 bug)" {
    // 真机 bug:阈值曾用 output max_tokens(sonnet 默认 32K)*0.7 → 工具调研刚读几个文件就误触发
    // 压缩、丢掉原始问题。修复:改用 input context window(~200K)*0.8。
    // 源级守卫:阈值算式必须调 resolveMaxInputTokens(而非 output 的解析器),且 MIN 不再是早期小值。
    const src = @embedFile("agent_loop.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "resolveMaxInputTokens()) * 8 / 10") != null);
    try std.testing.expect(MIN_AUTO_COMPACT_THRESHOLD >= 32_000);
}
