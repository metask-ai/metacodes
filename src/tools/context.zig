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

pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    abort: ?*const AbortSignal = null,
    /// 工具抛错时可选的富文本 detail:工具在 `return error.X` 前写 `*error_detail = msg`,
    /// tool_exec 读到后用它替代通用的 "<tool> failed with X" 作为模型可见 detail。
    /// msg 用 ctx.allocator 分配(errorToJson 会拷贝,arena 释放前读取安全)。null = 不支持。
    error_detail: ?*?[]const u8 = null,
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
    /// Skill 激活回调:让 Skill 工具能告诉 App 现在激活了哪个 skill 的权限。
    /// 签名:(state_ptr, skill_name, allowed, disallowed) → !void
    /// state_ptr 通常指向 *App,具体 setter 由 App 端 wire。null = 没人接管(Skill 工具仍渲染 body,但权限无效果)。
    activate_skill_state: ?*anyopaque = null,
    activate_skill_fn: ?*const fn (
        state: *anyopaque,
        skill_name: []const u8,
        allowed: []const []const u8,
        disallowed: []const []const u8,
    ) anyerror!void = null,
    /// ToolSearch 激活 deferred 工具的回调(仿 activate_skill)。
    /// 签名:(state_ptr, tool_name) → !void。state_ptr 指向 *App,把 tool_name 记入
    /// App 的 activated 集,下一轮该 deferred 工具进 tools 数组变可调。null = 不接管。
    activate_tool_state: ?*anyopaque = null,
    activate_tool_fn: ?*const fn (state: *anyopaque, tool_name: []const u8) anyerror!void = null,
    /// 用户是否显式触发(true = 用户 /name;false = 模型自主调用)。
    /// 用于 disable-model-invocation 检查。
    explicit_invocation: bool = false,
    /// 当前 session id(${CLAUDE_SESSION_ID} 替换 + 日志相关)。
    session_id: []const u8 = "",
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
    /// Worktree 栈:Enter/ExitWorktree 工具用,App 端提供 push/pop 回调。
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
    ) anyerror!?@import("worktree.zig").WorktreeEntry = null,
    /// MCP session 列表(ListMcpResourcesTool / ReadMcpResourceTool 用)。
    /// 不直接 import app.zig(防循环);用 anytype pointer 转译。
    mcp_sessions: ?*const []@import("../core/mcp_session.zig").McpSessionEntry = null,
    /// Cron registry(CronCreate/Delete/List 用)。
    cron_registry: ?*@import("../core/cron_registry.zig").CronRegistry = null,
    /// 工具执行期进度回调(对齐 cc onProgress):工具(如 WebSearch 子请求)在执行**中**
    /// 实时上报进度,驱动 TUI 刷新工具卡第二行(Searching: q / Found N results)。
    /// state 指向 *RenderRegion(经 trampoline),tool_exec 注入。null = 无 TUI(headless/单测)。
    /// id = 该工具的 tool_use id(per-toolUse 多卡按它路由;tool_exec runJob 盖入)。
    progress_state: ?*anyopaque = null,
    progress_tool_id: []const u8 = "",
    progress_fn: ?*const fn (state: *anyopaque, id: []const u8, phase: ProgressPhase, text: []const u8, count: u32) void = null,

    /// 子进程"仍在运行"心跳回调(spawn 层每 2s 调,Bash/WebFetch/Worktree 长命令用)。
    /// 重构前是 tools/common.zig 的进程全局 g_progress_cb(多 Session 串台)。现 per-session 挂
    /// ToolContext,传给 spawnCaptureWithStderrTimed。null = 不显示心跳(headless/非 tty)。
    /// 比 progress_fn 简单:只报 (elapsed_ms, argv0),不分 phase——是 Bash spawn 的轻量 ticker。
    spawn_tick_fn: ?*const fn (elapsed_ms: u64, argv0: []const u8) void = null,

    /// 统一 UI 请求回调(替代旧 ask_question_fn / exit_plan_fn / 权限 dialog_runner 三套)。
    /// 工具(主线程)构造一个 UiRequest 交给 TUI backend,backend 停 watcher + 持渲染锁 +
    /// 独占 fd0 渲染对应对话框,把用户选择写回 out。state 指向 *TuiBackend(经 trampoline)。
    /// null = 无 TUI(headless/单测/子 agent)→ 各工具按语义兜底(ask→NotATty;plan→answer_queue/reject)。
    /// req/out 借用(回调同步消费);ask_question 的 answers slice owned by allocator(caller free)。
    ui_request_state: ?*anyopaque = null,
    ui_request_fn: ?@import("../core/protocol/ui_request.zig").UiRequestFn = null,

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
        if (self.progress_fn) |f| {
            if (self.progress_state) |st| f(st, self.progress_tool_id, phase, text, count);
        }
    }

    /// 发一个统一 UI 请求(同步阻塞)。有回调 + state → 调它写 out 返回 true;否则返回 false
    /// (调用方按语义兜底:ask→NotATty;plan→answer_queue/reject)。req/out 调用方栈上提供。
    pub fn requestUi(
        self: *const ToolContext,
        allocator: std.mem.Allocator,
        req: *const @import("../core/protocol/ui_request.zig").UiRequest,
        out: *@import("../core/protocol/ui_request.zig").UiResponse,
    ) anyerror!bool {
        const f = self.ui_request_fn orelse return false;
        const st = self.ui_request_state orelse return false;
        try f(st, allocator, req, out);
        return true;
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

test "withAbort ctx propagates abort" {
    var sig = AbortSignal.init();
    sig.abort(.user_ctrl_c);
    const ctx = ToolContext.withAbort(std.testing.allocator, &sig);
    try std.testing.expectError(error.Aborted, ctx.throwIfAborted());
}
