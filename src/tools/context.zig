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
const PermissionContext = @import("../permission.zig").PermissionContext;
const TaskStore = @import("../core/task_store.zig").TaskStore;
const Client = @import("../client.zig").Client;
const ToolDefinition = @import("../json.zig").ToolDefinition;
const DynRegistry = @import("dynamic.zig").DynRegistry;

pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    abort: ?*const AbortSignal = null,
    /// ReadState 表：Read 成功后会 record，Write/Edit 入口查 get 做 must-read-first 校验。
    /// 单元测试可用 `simple` 构造跳过（无校验）。
    read_state: ?*ReadState = null,
    /// Bash 后台作业注册表：run_in_background + BashOutput + KillShell 用
    jobs: ?*JobRegistry = null,
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
    /// 用户是否显式触发(true = 用户 /name;false = 模型自主调用)。
    /// 用于 disable-model-invocation 检查。
    explicit_invocation: bool = false,
    /// 当前 session id(${CLAUDE_SESSION_ID} 替换 + 日志相关)。
    session_id: []const u8 = "",
    /// 当前 project root(${CLAUDE_PROJECT_DIR} 替换)。
    project_dir: []const u8 = "",
    /// 全局 disable-shell-execution 开关(settings.json `disableSkillShellExecution`)。
    disable_shell_execution: bool = false,
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
