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
const ReadState = @import("../core/read_state.zig").ReadState;
const JobRegistry = @import("../core/job_registry.zig").JobRegistry;
const AgentJobRegistry = @import("../core/agent_job_registry.zig").AgentJobRegistry;
const PermissionContext = @import("../permission.zig").PermissionContext;
const TaskStore = @import("../core/task_store.zig").TaskStore;
const Client = @import("../client.zig").Client;
const ToolDefinition = @import("../json.zig").ToolDefinition;
const DynRegistry = @import("dynamic.zig").DynRegistry;

/// AskUserQuestion 的结构化输入(解析+校验在 ask_user.zig 做,渲染在 dialog/ask_question.zig)。
/// 放在中性的 context 层:所有工具已 import 它,避免 ask_user.zig ↔ tui dialog 的循环依赖。
pub const AskOption = struct {
    label: []const u8,
    description: []const u8,
    /// 单选 preview 内容(ASCII/markdown mockup),空=无。选中时右侧 side-by-side 框展示。
    preview: []const u8 = "",
};
pub const AskQuestion = struct {
    question: []const u8,
    header: []const u8,
    multi: bool,
    options: []const AskOption,
};

/// L3 挂起:一个待异步前端处理的 custom UI 请求(工具填 ToolContext.pending_request,
/// runJob → Slot.pending_payload,agent_loop emit ui_request_pending)。纯数据,可序列化落盘
/// (suspend.json)。kind 标识界面类型(如 "video_timeline"),payload_json 是渲染规格。
pub const PendingRequest = struct {
    kind: []const u8,
    payload_json: []const u8,
};

// ── 工具回调接口(仿 agent_loop.UsageSink:把裸 *anyopaque+*fn 对收成类型安全的接口值)──
// 放中立 context 层:agent_loop.Options 和 ToolContext 都引用,零循环依赖
// (agent_loop → tools.zig → context.zig,context 不反向 import agent_loop)。

/// HostServices(L5):把"工具请求宿主(App)改其状态"的三类请求-响应回调聚合成**一个**接口。
///
/// 背景:SkillActivator / ToolActivator / WorktreeHook 三者本质相同——都是工具(执行期)
/// 调宿主、宿主改自身状态(激活 skill 白黑名单 / 激活 deferred 工具 / worktree 栈 push-pop)。
/// 它们**有返回值、是请求-响应**(非单向通知),故 L1 没把它们收进 CoreEvent 事件总线;
/// 但它们在 App→ToolContext 路径上全部 `ctx = @ptrCast(app)`——同一个宿主、四个一样的裸指针 +
/// 四个 trampoline。L5 收成一个 HostServices:一个 ctx(=app)+ 四个可空 fn-ptr。
///
/// **进程内能力**:这些改宿主内存,与可序列化的 CoreEvent 总线是两类东西(跨进程后端各自
/// 用 RPC 实现 HostServices,不走事件总线)。不要混。
///
/// **可空字段**:不同路径提供的能力子集不同(subagent 只需 activateSkill;ToolSearch 只需
/// activateTool;worktree 只需 push/pop)。null fn-ptr = 该能力不可用,对应方法按语义兜底
/// (activate* 返 error.HostCapabilityUnavailable;worktree push/pop 同)。
pub const HostServices = struct {
    ctx: *anyopaque,
    activateSkillFn: ?*const fn (ctx: *anyopaque, skill_name: []const u8, allowed: []const []const u8, disallowed: []const []const u8) anyerror!void = null,
    activateToolFn: ?*const fn (ctx: *anyopaque, tool_name: []const u8) anyerror!void = null,
    worktreePushFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, wt_path: []const u8, original_cwd: []const u8) anyerror!void = null,
    worktreePopFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?@import("worktree.zig").WorktreeEntry = null,

    pub const Error = error{HostCapabilityUnavailable};

    /// Skill 激活后把临时白/黑名单挂到宿主。无 activateSkillFn → HostCapabilityUnavailable。
    pub fn activateSkill(self: HostServices, skill_name: []const u8, allowed: []const []const u8, disallowed: []const []const u8) anyerror!void {
        const f = self.activateSkillFn orelse return Error.HostCapabilityUnavailable;
        return f(self.ctx, skill_name, allowed, disallowed);
    }
    /// ToolSearch 激活 deferred 工具,记入宿主 activated 集。无 fn → HostCapabilityUnavailable。
    pub fn activateTool(self: HostServices, tool_name: []const u8) anyerror!void {
        const f = self.activateToolFn orelse return Error.HostCapabilityUnavailable;
        return f(self.ctx, tool_name);
    }
    /// EnterWorktree 压栈。无 fn → HostCapabilityUnavailable(工具映射成 WorktreeStateUnavailable)。
    pub fn worktreePush(self: HostServices, allocator: std.mem.Allocator, wt_path: []const u8, original_cwd: []const u8) anyerror!void {
        const f = self.worktreePushFn orelse return Error.HostCapabilityUnavailable;
        return f(self.ctx, allocator, wt_path, original_cwd);
    }
    /// ExitWorktree 弹栈。无 fn → HostCapabilityUnavailable。
    pub fn worktreePop(self: HostServices, allocator: std.mem.Allocator) anyerror!?@import("worktree.zig").WorktreeEntry {
        const f = self.worktreePopFn orelse return Error.HostCapabilityUnavailable;
        return f(self.ctx, allocator);
    }

    /// 投影成"只保留 skill 激活"的子集(其余能力清空)。subagent 用:它能激活 skill,但
    /// **不能**碰父的 worktree 栈(并发后台 subagent 在独立线程,改父 worktree 栈=数据竞争)
    /// 或父的 ToolSearch activated 集(隔离)。对齐 L5 前 subagent 只接 skill_activator 的语义。
    pub fn skillOnly(self: HostServices) HostServices {
        return .{ .ctx = self.ctx, .activateSkillFn = self.activateSkillFn };
    }
};

/// 工具执行期进度回调(ToolContext 用,id/phase/text/count 签名)。
/// 与 agent_loop 的 turn/tool 级 ProgressReporter 不同 —— 这是工具内进度(如 WebSearch 子请求)。
pub const ToolProgressReporter = struct {
    ctx: *anyopaque,
    reportFn: *const fn (ctx: *anyopaque, id: []const u8, phase: ToolContext.ProgressPhase, text: []const u8, count: u32) void,
    pub fn report(self: ToolProgressReporter, id: []const u8, phase: ToolContext.ProgressPhase, text: []const u8, count: u32) void {
        self.reportFn(self.ctx, id, phase, text, count);
    }
};

pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    abort: ?*const AbortSignal = null,
    /// TinyKG 客户端(记忆/计划/DAG 真相源;设计 KG_DESIGN v3-final)。
    /// null = 未配置(缺二进制)——KG 工具此时不会注册;non-null 但 !ready = degraded。
    kg: ?*@import("../kg/client.zig").KgClient = null,
    /// KG per-project 指针目录(`{home}/.metacodes/projects/<git根hash>`)。plan 落图写 kg_root
    /// 到此。空串 = 未配置。设计 KG_DESIGN v3-final §3。
    kg_projects_dir: []const u8 = "",
    /// AutoMem memdir 绝对路径(B/C 合并:Write/Edit 落盘 memdir markdown 自动入图用)。
    /// 空串=禁用。
    memdir_abs: []const u8 = "",

    /// 工具抛错时可选的富文本 detail:工具在 `return error.X` 前写 `*error_detail = msg`,
    /// tool_exec 读到后用它替代通用的 "<tool> failed with X" 作为模型可见 detail。
    /// msg 用 ctx.allocator 分配(errorToJson 会拷贝,arena 释放前读取安全)。null = 不支持。
    error_detail: ?*?[]const u8 = null,
    /// L3 挂起:工具发起的 custom UI 请求拿到 RequestOutcome.pending 时,在 `return error.UiPending`
    /// 前把 `{kind, payload_json}` 写进这个槽;tool_exec(runJob)读到后填 Slot.pending_payload,
    /// agent_loop 据此 emit ui_request_pending + 挂起。null = 不支持挂起(同步/无异步 backend)。
    /// kind/payload 用 ctx.allocator 分配(逃逸需 runJob dupe 到父,见 tool_exec)。
    pending_request: ?*?PendingRequest = null,
    /// ReadState 表：Read 成功后会 record，Write/Edit 入口查 get 做 must-read-first 校验。
    /// 单元测试可用 `simple` 构造跳过（无校验）。
    read_state: ?*ReadState = null,
    /// Edit/Write 旁路高亮缓存:finalizeWrite 把新旧全文 put 进来(key=progress_tool_id),
    /// diff 工具卡渲染时取出做 tree-sitter 着色。null = 不缓存(headless/测试)。
    edit_hl_cache: ?*@import("../core/edit_hl_cache.zig").EditHlCache = null,
    /// Bash 后台作业注册表：run_in_background + BashOutput + KillShell 用
    jobs: ?*JobRegistry = null,
    /// 后台 subagent 作业注册表：Task(run_in_background) + TaskOutput + TaskStop(agent_ id) 用
    agent_jobs: ?*AgentJobRegistry = null,
    /// 权限上下文：EnterPlanMode/ExitPlanMode 需要写 mode
    permission_ctx: ?*PermissionContext = null,
    /// 进入 plan 模式前的原 mode；ExitPlanMode 时恢复
    plan_prev_mode: ?*?@import("../types.zig").PermissionMode = null,
    /// Task 清单：TaskCreate/Get/List/Update/Stop 共享的 scratchpad
    tasks: ?*TaskStore = null,
    /// 用于 Agent 工具 spawn 子 agent：共享 API client + tool defs + permission ctx
    api_client: ?*Client = null,
    tool_defs: ?[]const ToolDefinition = null,
    /// 当前 agent 嵌套深度（父=0，子=1，孙=2…）。Agent 工具用它限制递归。
    agent_depth: u8 = 0,
    /// 运行时工具表（Skill/MCP）。agent_loop 在静态注册表未命中时回退到此。
    dyn_registry: ?*const DynRegistry = null,
    /// L5:宿主能力聚合(Skill 激活 / ToolSearch 激活 / Worktree push-pop)——三类"工具改宿主
    /// 状态"的请求-响应回调收成一个接口。null = 无宿主(纯单测)。各能力可空,见 HostServices。
    host_services: ?HostServices = null,
    /// 用户是否显式触发(true = 用户 /name;false = 模型自主调用)。
    /// 用于 disable-model-invocation 检查。
    explicit_invocation: bool = false,
    /// 当前 session id(${CLAUDE_SESSION_ID} 替换 + 日志相关)。
    session_id: []const u8 = "",
    /// 本 agent loop 的**对外身份**(全局唯一,程序注入):KG claim 租约等跨进程/跨 loop
    /// 协调用。与 `session`(UI 事件路由键)是不同概念——主 loop 两者恰好同值
    /// (App.session_id,跨进程唯一:ms 时戳+monotonic ns);subagent 每次 spawn 独立
    /// gen(路由仍归父视图,身份必须独立,否则并发 subagent 共享 sentinel 互相无防撞)。
    /// **身份由程序赋予,绝不指望模型手填。**
    agent_ident: @import("../core/session_id.zig").SessionId = @import("../core/session_id.zig").SessionId.single,
    /// 当前 project root(${CLAUDE_PROJECT_DIR} 替换)。
    project_dir: []const u8 = "",
    /// 全局 disable-shell-execution 开关(settings.json `disableSkillShellExecution`)。
    disable_shell_execution: bool = false,
    /// Sandbox 配置(macOS Seatbelt)。非 null 且 enabled 时,Bash 命令包进 sandbox-exec。
    sandbox: ?*const @import("../sandbox/config.zig").SandboxSettings = null,
    /// 当前 cwd 绝对路径(sandbox profile 工作目录写权限)。空 = 用 process cwd。
    cwd_abs: []const u8 = "",
    /// HOME(sandbox profile ~/ 展开)。
    home_dir: []const u8 = "",
    /// 当前 session plan 文件全路径(ExitPlanMode 模型未传 plan 时从此读回兜底)。空=无。
    plan_file_path: []const u8 = "",
    /// 末轮助手消息里提取的 `<proposed_plan>` 内容(agent_loop 在 plan 模式末轮填;
    /// ExitPlanMode 优先读它作为计划来源)。空=本轮无 proposed_plan。借用 conversation 内存。
    last_proposed_plan: []const u8 = "",
    /// Subagent 定义集合(Task 工具据此找 subagent_type → AgentDef)。
    agents: ?*const @import("../agents/set.zig").AgentSet = null,
    /// 父 model(供 subagent model 字段 `inherit` 解析)。
    parent_model: []const u8 = "",
    /// Skill 集合(供 subagent preload_skills 字段读取 skill body)。
    skills: ?*const @import("../skills/skill.zig").SkillSet = null,
    /// MCP session 列表(ListMcpResourcesTool / ReadMcpResourceTool 用)。
    /// 不直接 import app.zig(防循环);用 anytype pointer 转译。
    mcp_sessions: ?*const []@import("../core/mcp_session.zig").McpSessionEntry = null,
    /// Cron registry(CronCreate/Delete/List 用)。
    cron_registry: ?*@import("../core/cron_registry.zig").CronRegistry = null,
    /// 工具执行期进度回调(对齐 cc onProgress):工具(如 WebSearch 子请求)在执行**中**
    /// 实时上报进度,驱动 TUI 刷新工具卡第二行(Searching: q / Found N results)。
    /// 工具执行期进度。ctx 指 *RenderRegion(经 trampoline),tool_exec 注入。null = 无 TUI。见 ToolProgressReporter。
    progress_reporter: ?ToolProgressReporter = null,
    /// id = 该工具的 tool_use id(per-toolUse 多卡按它路由;tool_exec runJob 盖入)。flat 保留(per-job 数据非闭包)。
    progress_tool_id: []const u8 = "",

    /// 子进程"仍在运行"心跳回调(spawn 层每 2s 调,Bash/WebFetch/Worktree 长命令用)。
    /// 重构前是 tools/common.zig 的进程全局 g_progress_cb(多 Session 串台)。现 per-session 挂
    /// ToolContext,传给 spawnCaptureWithStderrTimed。null = 不显示心跳(headless/非 tty)。
    /// 比 progress_fn 简单:只报 (elapsed_ms, argv0),不分 phase——是 Bash spawn 的轻量 ticker。
    spawn_tick_fn: ?*const fn (elapsed_ms: u64, argv0: []const u8) void = null,

    /// 统一 UI 请求回调(替代旧 ask_question_fn / exit_plan_fn / 权限 dialog_runner 三套)。
    /// 工具(主线程)构造一个 UiRequest 交给 TUI backend,backend 停 watcher + 持渲染锁 +
    /// 独占 fd0 渲染对应对话框,把用户选择写回 out。state 指向 *TuiBackend(经 trampoline)。
    /// null = 无 TUI(headless/单测/子 agent)→ 各工具按语义兜底(ask→NotATty;plan→answer_queue/reject)。
    /// req/out 借用(回调同步消费);ask_question 的 answers slice owned by allocator(caller free)。见 UiRequester。
    ui_requester: ?@import("../core/protocol/ui_request.zig").UiRequester = null,
    /// 本 ToolContext 归属的会话(UiRequest 路由到对应 session 视图)。默认 .single(N=1)。
    /// agent_loop 构造 base_ctx 时从 opts.session 设。
    /// **M6 待办**:与 PermissionContext.session 是同一概念的两份(见那里注释);M6 拆
    /// SessionContext 后两者都从 SessionContext.id 取,本字段消失。
    session: @import("../core/session_id.zig").SessionId = @import("../core/session_id.zig").SessionId.single,

    /// ExitPlanMode 审批结果(对齐 cc 三选项)。
    /// - approve_default:批准 → 恢复进 plan 前的原模式(通常 default),模型继续执行。
    /// - approve_accept_edits:批准并自动接受编辑 → 切 accept_edits。
    /// - reject:留在 plan 模式,模型继续打磨计划(不执行)。
    pub const PlanApproval = enum { approve_default, approve_accept_edits, reject };


    /// 工具进度阶段(对齐 cc WebSearchProgress 两态)。
    pub const ProgressPhase = enum { query_update, results_received };

    /// 上报进度(null 安全)。text 借用,回调内须立即拷贝(不跨调用持有)。
    /// id 自动用 self.progress_tool_id(per-toolUse 多卡路由)。
    pub fn reportProgress(self: *const ToolContext, phase: ProgressPhase, text: []const u8, count: u32) void {
        if (self.progress_reporter) |r| r.report(self.progress_tool_id, phase, text, count);
    }

    /// 发一个统一 UI 请求(同步阻塞)。有回调 + state → 调它写 out 返回 true;否则返回 false
    /// (调用方按语义兜底:ask→NotATty;plan→answer_queue/reject)。req/out 调用方栈上提供。
    /// 返回 RequestOutcome:answered=out 已写;pending=异步前端挂起(工具应返 error.UiPending);
    /// unavailable=无 requester(工具按语义兜底)。
    pub fn requestUi(
        self: *const ToolContext,
        allocator: std.mem.Allocator,
        req: *const @import("../core/protocol/ui_request.zig").UiRequest,
        out: *@import("../core/protocol/ui_request.zig").UiResponse,
    ) anyerror!@import("../core/protocol/ui_request.zig").RequestOutcome {
        const r = self.ui_requester orelse return .unavailable;
        return try r.request(self.session, allocator, req, out);
    }

    /// L3:发起一个 custom UI 请求(动态 UI)。三态:
    /// - answered:同步 backend 已渲染并写 out.custom(结果 JSON),返回它(borrow,arena 有效)。
    /// - pending:异步 backend 已 stash 请求未阻塞 → 把 {kind,payload_json} 写进 pending_request 槽
    ///   并返 error.UiPending(agent_loop 据此挂起)。**out 未写,不得读**。
    /// - unavailable:无 requester(headless/子 agent/无 backend)→ error.CustomUiUnsupported(工具兜底)。
    /// kind/payload_json 借用调用方内存;pending 时 dupe 进 pending_request(逃逸 runJob arena 由其负责)。
    ///
    /// **⚠️ error.UiPending 是控制信号,工具绝不能 catch 它**——必须让它一路冒泡到 tool_exec.runJob
    /// (那里特判成挂起)。工具若 `requestUiCustom() catch {...}` 吞掉 UiPending,挂起静默失效、
    /// 变成普通工具结果。**子 agent(Task)内的挂起目前未定义**(子 run 返 .suspended 后父怎么 resume
    /// 子,无机制)——custom UI 工具只应在顶层用;子 agent 内发起 = future(见 L3 plan gap)。
    pub fn requestUiCustom(
        self: *const ToolContext,
        allocator: std.mem.Allocator,
        kind: []const u8,
        payload_json: []const u8,
    ) anyerror![]const u8 {
        const ui_request = @import("../core/protocol/ui_request.zig");
        const req = ui_request.UiRequest{ .custom = .{ .kind = kind, .payload_json = payload_json } };
        var out: ui_request.UiResponse = undefined;
        switch (try self.requestUi(allocator, &req, &out)) {
            .answered => return switch (out) {
                .custom => |j| j,
                else => error.CustomUiUnsupported, // backend 返非 custom tag = 协议违例
            },
            .pending => {
                const slot = self.pending_request orelse return error.CustomUiUnsupported;
                slot.* = .{
                    .kind = try allocator.dupe(u8, kind),
                    .payload_json = try allocator.dupe(u8, payload_json),
                };
                return error.UiPending;
            },
            .unavailable => return error.CustomUiUnsupported,
        }
    }

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

// ── 回调接口微测(仿 UsageSink:栈计数器作 ctx,调 method,断言计数器变)──
const TestState = struct {
    skill_hits: u32 = 0,
    tool_hits: u32 = 0,
    progress_hits: u32 = 0,
    fn skillCb(ctx: *anyopaque, _: []const u8, _: []const []const u8, _: []const []const u8) anyerror!void {
        const s: *TestState = @ptrCast(@alignCast(ctx));
        s.skill_hits += 1;
    }
    fn toolCb(ctx: *anyopaque, _: []const u8) anyerror!void {
        const s: *TestState = @ptrCast(@alignCast(ctx));
        s.tool_hits += 1;
    }
    fn progressCb(ctx: *anyopaque, _: []const u8, _: ToolContext.ProgressPhase, _: []const u8, _: u32) void {
        const s: *TestState = @ptrCast(@alignCast(ctx));
        s.progress_hits += 1;
    }
};

test "HostServices.activateSkill 经接口触达回调" {
    var st = TestState{};
    const hs = HostServices{ .ctx = @ptrCast(&st), .activateSkillFn = &TestState.skillCb };
    try hs.activateSkill("foo", &.{}, &.{});
    try std.testing.expectEqual(@as(u32, 1), st.skill_hits);
}

test "HostServices.activateTool 经接口触达回调" {
    var st = TestState{};
    const hs = HostServices{ .ctx = @ptrCast(&st), .activateToolFn = &TestState.toolCb };
    try hs.activateTool("Bash");
    try std.testing.expectEqual(@as(u32, 1), st.tool_hits);
}

test "HostServices: 缺失能力返 HostCapabilityUnavailable" {
    var st = TestState{};
    // 只接 activateSkill,不接 tool/worktree → 对应方法返 HostCapabilityUnavailable。
    const hs = HostServices{ .ctx = @ptrCast(&st), .activateSkillFn = &TestState.skillCb };
    try std.testing.expectError(error.HostCapabilityUnavailable, hs.activateTool("x"));
    try std.testing.expectError(error.HostCapabilityUnavailable, hs.worktreePop(std.testing.allocator));
}

test "ToolProgressReporter.report 经接口触达回调" {
    var st = TestState{};
    const rep = ToolProgressReporter{ .ctx = @ptrCast(&st), .reportFn = &TestState.progressCb };
    rep.report("tu1", .query_update, "searching", 0);
    try std.testing.expectEqual(@as(u32, 1), st.progress_hits);
}

test "withAbort ctx propagates abort" {
    var sig = AbortSignal.init();
    sig.abort(.user_ctrl_c);
    const ctx = ToolContext.withAbort(std.testing.allocator, &sig);
    try std.testing.expectError(error.Aborted, ctx.throwIfAborted());
}
