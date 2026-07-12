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
const provider_mod = @import("../api/provider.zig");
const json_mod = @import("../json.zig");
const tools_mod = @import("../tools.zig");
const permission_mod = @import("../permission.zig");
const message_repair_mod = @import("message_repair.zig");
const hooks_mod = @import("../permission/hooks.zig");
const msg = @import("message.zig");
const conversation_mod = @import("conversation.zig");
const Conversation = conversation_mod.Conversation;
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const ReadState = @import("read_state.zig").ReadState;
const api_stream = @import("../api/stream.zig");
const tool_error = @import("tool_error.zig");
const context_pressure_mod = @import("context_pressure.zig");
const util_time = @import("../util/time.zig");
const log = @import("../util/log.zig");
const ui_backend = @import("protocol/ui_backend.zig");
const ui_event = @import("protocol/ui_event.zig");
const UiBackend = ui_backend.UiBackend;
const CoreEvent = ui_event.CoreEvent;

pub const StopReason = enum { end_turn, max_turns, aborted, tool_error, api_error, tool_loop, suspended, backgrounded, budget };

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

/// **零增益重复熔断(主防线,与轮数正交)**:同一 (tool, input) 产出**同一 result** 累计达此
/// 次数 → 判定原地打转(错误型 MAX_SAME_TOOL_ERROR 熔断抓不到"成功但零信息增益"的重复:
/// 反复 Read 同一 offset / 反复 Grep 同 pattern,每次成功→永不熔断→无限循环,50 轮帽曾是唯一
/// 拦截)。分页(offset 递进)是不同 signature 不触发;结果变化(git status 状态变)→ result_hash
/// 变 → 重置计数,不误杀合法 re-check。这才度量真实"打转",轮数只配当防呆 backstop。
pub const MAX_ZERO_GAIN_REPEAT: u32 = 3;

/// 零增益重复追踪器:sig_hash(tool name+input)→ {同结果累计次数}。同 sig **同 result** 累计
/// 达 MAX_ZERO_GAIN_REPEAT = 原地打转。结果变化(result_hash 变)→ 重置(不误杀合法 re-check);
/// 不同 sig(如分页 offset 递进)各自独立计数(不触发)。
pub const ZeroGainTracker = struct {
    const Entry = struct { result_hash: u64, count: u32 };
    map: std.AutoHashMap(u64, Entry),

    pub fn init(allocator: std.mem.Allocator) ZeroGainTracker {
        return .{ .map = std.AutoHashMap(u64, Entry).init(allocator) };
    }
    pub fn deinit(self: *ZeroGainTracker) void {
        self.map.deinit();
    }
    /// 记录一次并返回该 sig 的当前同结果累计次数。OOM → best-effort 返 0(不阻塞 run)。
    pub fn record(self: *ZeroGainTracker, sig_hash: u64, result_hash: u64) u32 {
        const gop = self.map.getOrPut(sig_hash) catch return 0;
        if (gop.found_existing and gop.value_ptr.result_hash == result_hash) {
            gop.value_ptr.count += 1;
        } else {
            gop.value_ptr.* = .{ .result_hash = result_hash, .count = 1 };
        }
        return gop.value_ptr.count;
    }
    pub fn tripped(self: *ZeroGainTracker, sig_hash: u64, result_hash: u64) bool {
        return self.record(sig_hash, result_hash) >= MAX_ZERO_GAIN_REPEAT;
    }
};

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
pub const COMPACT_MIN_SAVED_PERCENT: usize = 5;

/// 强制 auto-compact 阈值(测试/power-user 旋钮)。设 `METACODES_FORCE_COMPACT_AT=<tokens>` 后,
/// **直接**把 auto/micro 阈值钉到该值,绕过 formula(≈window-reserve)和 32K 下限——让真模型 e2e
/// 能在短对话里触发真实压缩+投影(否则 glm 262K 窗口下要灌 ~200K token 才够)。
/// 生产默认不设此 env → null → 走正常 formula+floor,行为不变。非法/0/空 → null(坏 env 不改行为)。
pub fn forcedAutoCompactThreshold() ?usize {
    const raw = std.c.getenv("METACODES_FORCE_COMPACT_AT") orelse return null;
    return parseForcedAutoCompactThreshold(std.mem.span(raw));
}

/// 纯解析(可单测,不碰 env):非法/0/空 → null。
fn parseForcedAutoCompactThreshold(raw: []const u8) ?usize {
    const v = std.fmt.parseInt(usize, raw, 10) catch return null;
    if (v == 0) return null;
    return v;
}

/// 强制 keep_recent(测试旋钮):`METACODES_FORCE_COMPACT_KEEP=<n>`。默认 keep_recent=10 需要 >10 条
/// 消息才有可丢的;调小它让"大的早期消息 + 几轮小追问"就能触发真实 summary 压缩(e2e 用)。
/// 生产默认不设 → null → 用正常 keep_recent。非法/0/空 → null。
pub fn forcedAutoCompactKeep() ?usize {
    const raw = std.c.getenv("METACODES_FORCE_COMPACT_KEEP") orelse return null;
    return parseForcedAutoCompactThreshold(std.mem.span(raw)); // 同款解析:非法/0/空 → null
}

/// L3 挂起信息:stop_reason==.suspended 时非空,带出挂起点供调用方落盘 + 恢复。
/// owned by run() 的 allocator;调用方用后 free(deinit)。
///
/// **API 配对约束(关键)**:Anthropic 要求 assistant 的每个 tool_use 在紧接 user 消息里都有
/// 对应 tool_result——不能拆成两次 user 消息。故挂起时**不**提交任何 partial user 消息;
/// 已完成工具(非 pending)的结果 stash 进 completed_results,resume 时与 pending 工具的迟来
/// 结果**一起**作为单条 user 消息补齐(A+B 同 turn),满足配对。
pub const SuspendInfo = struct {
    /// 待补迟来结果的 pending tool_use id(owned)。
    tool_use_id: []const u8,
    kind: []const u8, // custom UI 类型(owned)
    payload_json: []const u8, // 渲染规格(owned)
    /// 同轮已完成工具的结果(owned)。resume 时与 pending 的迟来结果一起补成单条 user 消息。
    completed_results: []CompletedResult,
    allocator: std.mem.Allocator,

    pub const CompletedResult = struct {
        tool_use_id: []const u8, // owned
        content: []const u8, // owned
        is_error: bool,
    };

    pub fn deinit(self: SuspendInfo) void {
        self.allocator.free(self.tool_use_id);
        self.allocator.free(self.kind);
        self.allocator.free(self.payload_json);
        for (self.completed_results) |cr| {
            self.allocator.free(cr.tool_use_id);
            self.allocator.free(cr.content);
        }
        self.allocator.free(self.completed_results);
    }
};

pub const RunResult = struct {
    stop_reason: StopReason,
    turns: u32,
    tool_calls: u32,
    /// L3:仅 stop_reason==.suspended 时非空。调用方据此落盘 suspend.json + 投递 UI 请求,
    /// 响应到达后 resumeRun 注入。用后 deinit。
    suspend_info: ?SuspendInfo = null,
};

pub const Options = struct {
    /// **防呆 backstop**,非防跑飞主闸(轮数不度量任何真实风险)。长任务靠 pre-sampling
    /// auto-compact 压缩续接(codex 同构),防跑飞靠 MAX_SAME_TOOL_ERROR(错误型)+
    /// MAX_ZERO_GAIN_REPEAT(零增益重复,主防线)。故此值只当"真失控兜底",设高。
    max_turns: u32 = 400,
    /// **成本次闸**(度量真实"烧钱"维度,与轮数正交)。本 run 累计成本(USD)达此值 → 停
    /// (.budget),交互层询问用户是否继续(不自动续)。null = 不设预算(默认)。
    cost_budget_usd: ?f64 = null,
    /// 本次 run 归属的会话(emit/poll 路由用)。默认 .single(N=1/TUI);M6 多 Session 时
    /// 由 SessionContext 传各自的 id。所有 backend.emitEvent 用它路由到对应 UI 视图。
    session: @import("session_id.zig").SessionId = @import("session_id.zig").SessionId.single,
    system_prompt: ?[]const u8 = null,
    /// 首条 user-context message(对齐 cc prependUserContext):CLAUDE.md 链 + AutoMem +
    /// currentDate,`<system-reminder>` 包裹。仅主 session 传(subagent 走 preload 自己的链)。
    /// null → 不 prepend(headless/subagent/无记忆)。由 user_context.build 生成,owned-by-caller,
    /// 生命周期须覆盖整个 run。
    inject_user_context: ?[]const u8 = null,
    /// One-shot user-role steering item appended to the first API request only.
    /// This is intentionally not written to Conversation/transcript; extensions such
    /// as /loop use it to continue work without fabricating a persisted user turn.
    synthetic_user_input: ?[]const u8 = null,
    verbose: bool = false,
    abort: ?*const AbortSignal = null,
    /// 转后台请求信号(Ctrl+B 生成期置位)。run() 每轮**开头**(turn 边界,conversation 干净时)
    /// load 一次,命中则返回 stop_reason=.backgrounded(不中断当前未完成的 turn)。调用方据此把
    /// 主对话深拷贝转后台续跑。与 abort 分开:abort 是用户中断(对话留前台),background 是转后台续跑。
    /// null → 不支持转后台(headless/子 agent)。
    background_request: ?*const std.atomic.Value(bool) = null,
    /// 传给 Write/Edit 做 must-read-first 校验。null → 单测/headless 简化路径（不校验）
    read_state: ?*ReadState = null,
    /// Edit/Write 旁路高亮缓存(diff 工具卡 tree-sitter 着色用)。null → 不缓存。
    edit_hl_cache: ?*@import("edit_hl_cache.zig").EditHlCache = null,
    /// 自动 compact 的 token 阈值。null → 按 input context window 扣输出保留区后动态算。
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
    kg: ?*@import("../kg/client.zig").KgClient = null,
    kg_projects_dir: []const u8 = "",
    /// 本 agent loop 的对外身份(KG claim 租约)。null = 沿用 session(主 loop:
    /// App.session_id 跨进程唯一且跨 turn 稳定)。subagent spawn 时必须显式 gen——
    /// 每个独立 agent loop 一个全局唯一 id,进程内并发 subagent 才互相有防撞。
    agent_ident: ?@import("session_id.zig").SessionId = null,
    /// AutoMem memdir 绝对路径(B/C 合并 markdown 自动入图)。
    memdir_abs: []const u8 = "",
    /// Anthropic 具体 *Client(仅 web_search server tool 用;非 Anthropic provider → null)。
    /// **职责边界**:P0.5 后 subagent **构造** per-call client 已走 provider_factory.makeProvider
    /// (provider-neutral),此字段只剩 web_search 这个 Anthropic 专有 server tool 的入口——它必须
    /// 是 Anthropic 具体 client 才能发 server-tool 请求,故保持 *Client 而非 Provider。
    api_client: ?*@import("../client.zig").Client = null,
    tool_defs: ?[]const @import("../json.zig").ToolDefinition = null,
    /// 本次 run 对应的 agent 嵌套深度（父=0，子=1…）
    agent_depth: u8 = 0,
    /// 运行时工具（Skill/MCP）注册表。null = 仅静态工具。
    dyn_registry: ?*const @import("../tools/dynamic.zig").DynRegistry = null,
    /// L5:宿主能力聚合(Skill 激活 / ToolSearch 激活 / Worktree push-pop)。透传到 ToolContext。
    /// 见 ToolContext.HostServices。
    host_services: ?tools_mod.HostServices = null,
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
    /// /model 从大上下文窗口切到小窗口后，下一次采样前先用旧模型做一次 inline compact。
    /// 新模型可能已经装不下旧历史+compact prompt，旧模型仍可完成摘要。
    model_switch_compact: ?ModelSwitchCompact = null,
    /// Skill 集合(Task 工具 subagent preload_skills 字段用)。
    skills_set: ?*const @import("../skills/skill.zig").SkillSet = null,
    /// ToolSearch 激活的 deferred 工具名集。非 null 时:deferred 且不在此集的工具
    /// 不进 API tools 数组(降低弱后端工具菜单稀释)。null = 不过滤 deferred(全暴露)。
    activated_tools: ?*const std.StringHashMap(void) = null,
    /// 统一 UI 请求回调(替代旧 ask_question/exit_plan 三套;ctx 指 *TuiBackend)。
    /// 仅顶层 TUI 接(agent_depth==0)——子 agent 无 tty。见 UiRequester。
    ui_requester: ?@import("protocol/ui_request.zig").UiRequester = null,
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
};

pub const ModelSwitchCompact = struct {
    previous_model: []const u8,
    previous_context_window: u32,
    current_context_window: u32,
};

/// 内部:发一次进度事件(turn 1-based;tool_name/tool_input 空 = 仅更新轮次)。
/// tool_calls = 截至此刻累计工具调用数(单调)。L1 重构:轮/工具级进度从扁平回调
/// (旧 ProgressReporter → JobEntry)收编进 CoreEvent.progress 事件——单向通知=事件。
/// 顶层 TUI 后端忽略它;JobEntry 后端(subagent 进度树)消费它更新 turn/工具/token 行。
fn emitProgress(backend: *const UiBackend, sess: @import("session_id.zig").SessionId, turn: u32, tool_name: []const u8, tool_input: []const u8, tool_calls: u32) void {
    backend.emitEvent(sess, .{ .progress = .{ .turn = turn, .tool_name = tool_name, .tool_input = tool_input, .tool_calls = tool_calls } });
}

const EffectiveToolSet = struct {
    filtered_pool: ?[]json_mod.ToolDefinition = null,
    deferred_filtered: ?[]json_mod.ToolDefinition = null,
    cap_filtered: ?[]json_mod.ToolDefinition = null,
    defs: []const json_mod.ToolDefinition = &.{},

    fn deinit(self: *EffectiveToolSet, allocator: std.mem.Allocator) void {
        if (self.filtered_pool) |fp| allocator.free(fp);
        if (self.deferred_filtered) |df| allocator.free(df);
        if (self.cap_filtered) |cf| allocator.free(cf);
        self.* = .{};
    }
};

fn buildEffectiveToolSet(
    allocator: std.mem.Allocator,
    tool_defs: []const json_mod.ToolDefinition,
    permission_ctx: *const permission_mod.PermissionContext,
    activated_tools: ?*const std.StringHashMap(void),
    provider: provider_mod.Provider,
) EffectiveToolSet {
    var out = EffectiveToolSet{ .defs = tool_defs };

    const pool_filter = @import("../skills/tool_pool_filter.zig");
    out.filtered_pool = pool_filter.filterToolDefs(allocator, tool_defs, permission_ctx.active_skill) catch null;
    const skill_filtered = if (out.filtered_pool) |fp| fp else tool_defs;
    out.defs = skill_filtered;

    const effective_tool_defs = blk: {
        const acts = activated_tools orelse break :blk skill_filtered;
        var has_deferred = false;
        for (skill_filtered) |d| {
            if (d.deferred) {
                has_deferred = true;
                break;
            }
        }
        if (!has_deferred) break :blk skill_filtered;

        var keep: std.ArrayList(json_mod.ToolDefinition) = .empty;
        for (skill_filtered) |d| {
            if (d.deferred and !acts.contains(d.name)) continue;
            keep.append(allocator, d) catch {
                keep.deinit(allocator);
                break :blk skill_filtered;
            };
        }
        out.deferred_filtered = keep.toOwnedSlice(allocator) catch {
            keep.deinit(allocator);
            break :blk skill_filtered;
        };
        break :blk out.deferred_filtered.?;
    };
    out.defs = effective_tool_defs;

    const capability = @import("../api/capability.zig");
    const gated_tool_defs = blk: {
        var any_dropped = false;
        for (effective_tool_defs) |d| {
            if (capability.requiredCapability(d.name)) |cap| {
                if (!provider.supports(cap)) {
                    any_dropped = true;
                    break;
                }
            }
        }
        if (!any_dropped) break :blk effective_tool_defs;

        var keep: std.ArrayList(json_mod.ToolDefinition) = .empty;
        for (effective_tool_defs) |d| {
            if (capability.requiredCapability(d.name)) |cap| {
                if (!provider.supports(cap)) continue;
            }
            keep.append(allocator, d) catch {
                keep.deinit(allocator);
                break :blk effective_tool_defs;
            };
        }
        out.cap_filtered = keep.toOwnedSlice(allocator) catch {
            keep.deinit(allocator);
            break :blk effective_tool_defs;
        };
        break :blk out.cap_filtered.?;
    };
    out.defs = gated_tool_defs;
    return out;
}

/// L4:run 出口统一收口——发 diag_run_end 诊断事件后返回 result。每个 `return <result>` 改成
/// `return finishRun(backend, sess, trace_id, depth, <result>)`,保证所有出口(abort/api_error/
/// end_turn/tool_error/tool_loop/max_turns)都 emit run span 终点,无遗漏(对齐"诊断不沉默")。
///
/// **span 平衡契约**:正常完成的 turn(有工具→循环 / 无工具→end_turn)都发 diag_turn_end,
/// 每个 turn_begin 配一个 turn_end。异常终止(abort/api_error/tool_error/tool_loop)**不**发
/// turn_end——该 turn 未完成,由 run_end 的 stop_reason 标明死因。消费者:turn span 未闭合 +
/// run_end 非 end_turn/max_turns = 该 turn 被中断,正确语义,非 bug。
fn finishRun(backend: *const UiBackend, sess: @import("session_id.zig").SessionId, trace_id: [12]u8, depth: u8, result: RunResult) RunResult {
    backend.emitEvent(sess, .{ .diag_run_end = .{
        .trace_id = trace_id,
        .depth = depth,
        .turns = result.turns,
        .tool_calls = result.tool_calls,
        .stop_reason_name = @tagName(result.stop_reason),
    } });
    return result;
}

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
    provider: provider_mod.Provider,
    tool_defs: []const json_mod.ToolDefinition,
    permission_ctx: *const permission_mod.PermissionContext,
    opts: Options,
    backend: *const UiBackend,
    allocator: std.mem.Allocator,
) !RunResult {
    // 本次 run 归属的会话(emit/poll 路由用)。N=1/TUI 默认 .single;M6 由 SessionContext 传。
    const sess = opts.session;
    // L4:run 级 trace_id(整个 run 一个,跨所有 turn);诊断事件内联携带,DiagnosticsBackend
    // 据 trace_id+depth 重建 span 树。depth = agent 嵌套深度(父 0 子 1)。
    const trace_id = log.genRequestId().bytes;
    const depth = opts.agent_depth;
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
    // 零增益重复熔断(主防线),持有整个 run。
    var zero_gain = ZeroGainTracker.init(allocator);
    defer zero_gain.deinit();
    // 成本次闸:累计本 run 成本(USD),达 opts.cost_budget_usd → 停(.budget)。
    const cost_rates = @import("../util/pricing.zig").rateFor(provider.model());
    var run_cost_usd: f64 = 0;

    // Prompt cache 击穿检测(批3):跨 turn 跟踪 cache_read 跌幅 + system/tools 指纹。
    var cache_detector = @import("cache_break.zig").CacheBreakDetector{};
    var context_warning_emitted = false;

    while (turns < opts.max_turns) : (turns += 1) {
        // 开头检查 abort
        if (opts.abort) |a| if (a.isAborted()) {
            log.warn("agent", "aborted before turn {d}", .{turns + 1});
            return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .aborted, .turns = turns, .tool_calls = total_tool_calls });
        };
        // 成本次闸:本 run 累计成本达预算 → 停,交互层询问是否继续(不自动续)。
        if (opts.cost_budget_usd) |budget| {
            if (run_cost_usd >= budget) {
                log.warn("agent", "cost budget reached: ${d:.4} >= ${d:.4}", .{ run_cost_usd, budget });
                return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .budget, .turns = turns, .tool_calls = total_tool_calls });
            }
        }

        // 转后台请求(Ctrl+B):turn 边界检查——此刻 conversation 干净(上轮 tool_result 已 append),
        // 返回 .backgrounded 让调用方深拷贝转后台续跑。**只在 turn 开头查**(run 是同步循环,无中途
        // 暂停点;唯一安全转后台点是 turn 边界)。与 abort 分开:这不是中断,是把完整对话搬去后台。
        if (opts.background_request) |bg| if (bg.load(.acquire)) {
            log.info("agent", "background requested before turn {d} → backgrounding", .{turns + 1});
            return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .backgrounded, .turns = turns, .tool_calls = total_tool_calls });
        };

        // 进度事件:进入新一轮(1-based);空 tool 名 = 仅推进轮次,保留上一个工具
        // (JobEntry 后端据空名跳过工具更新,对齐 cc 持续显示最近动作)。
        emitProgress(backend, sess, turns + 1, "", "", total_tool_calls);
        // L4 诊断:turn span 起点。
        backend.emitEvent(sess, .{ .diag_turn_begin = .{ .trace_id = trace_id, .depth = depth, .turn = turns + 1 } });

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

        // 工具池过滤必须在 compact 判断之前完成。auto-compact 以"实际下一次请求"
        // 为准，而不是未经过 skill/deferred/capability 门控的全量工具表。
        var effective_tools = buildEffectiveToolSet(allocator, tool_defs, permission_ctx, opts.activated_tools, provider);
        defer effective_tools.deinit(allocator);
        const gated_tool_defs = effective_tools.defs;

        // 自动 compact：发请求前检查 token 估算,超阈值则保留最近 N 条。
        // 阈值 null 时 = input context window * 0.8(逼近 context 上限才压缩,留出回复空间)。
        // **必须用 input context window(resolveMaxInputTokens,~200K),不是 output max_tokens(32K)**——
        // 否则正常工具调研刚读几个文件(20K+)就误触发压缩、丢掉原始问题(真机 bug)。
        // 下限 MIN_AUTO_COMPACT_THRESHOLD:避免异常小值导致每 turn 都 compact。
        const synthetic_user_input = if (turns == 0) opts.synthetic_user_input else null;
        const model_switch_compact = if (turns == 0) opts.model_switch_compact else null;
        var previous_model_compact_outcome: AutoCompactOutcome = .not_needed;
        if (model_switch_compact) |msc| {
            if (!std.mem.eql(u8, msc.previous_model, provider.model()) and msc.previous_context_window > msc.current_context_window) {
                previous_model_compact_outcome = try runAutoCompactIfNeeded(
                    conversation,
                    provider,
                    effective_system_prompt,
                    opts.inject_user_context,
                    synthetic_user_input,
                    gated_tool_defs,
                    opts.model_override,
                    msc.previous_model,
                    opts.auto_compact_threshold,
                    opts.auto_compact_keep_recent,
                    "pre_sampling_previous_model_smaller_window",
                    backend,
                    sess,
                    &context_warning_emitted,
                    allocator,
                    opts.tasks,
                );
                if (previous_model_compact_outcome == .api_error) {
                    return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .api_error, .turns = turns, .tool_calls = total_tool_calls });
                }
            }
        }
        if (previous_model_compact_outcome != .skipped_no_savings) {
            const pre_sampling_compact = try runAutoCompactIfNeeded(
                conversation,
                provider,
                effective_system_prompt,
                opts.inject_user_context,
                synthetic_user_input,
                gated_tool_defs,
                opts.model_override,
                null,
                opts.auto_compact_threshold,
                opts.auto_compact_keep_recent,
                "pre_sampling_pending_turn_threshold",
                backend,
                sess,
                &context_warning_emitted,
                allocator,
                opts.tasks,
            );
            if (pre_sampling_compact == .api_error) {
                return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .api_error, .turns = turns, .tool_calls = total_tool_calls });
            }
        }

        log.info("agent", "turn {d}/{d} starting (msgs={d})", .{ turns + 1, opts.max_turns, conversation.messages.items.len });

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
        const reporter = provider_mod.RetryReporter{ .state = @ptrCast(&retry_ui), .report = RetryUi.report };

        // 1+2. 构造当前这一轮的 API 请求并发送。若建连/收头阶段或 SSE error
        // 明确报 context-window-exceeded,按 Rust compact recovery 路径逐步删最老
        // history 后重试。同一 turn 内重试,不把恢复尝试计成新 turn。
        var context_recovery_attempts: usize = 0;
        const context_recovery_cap = @max(conversation.len(), 1);
        var turn_stop_reason: api_stream.StopReason = .unknown;
        var rid_for_turn: log.RequestId = undefined;

        // 3. 收集响应 blocks。声明在 request_recovery 外层，使 SSE context
        // recovery 可以清空临时状态后重试同一 turn。
        var assistant_blocks = std.ArrayList(msg.Block).empty;
        errdefer {
            for (assistant_blocks.items) |b| b.deinit(allocator);
            assistant_blocks.deinit(allocator);
        }
        var assistant_text = std.ArrayList(u8).empty;
        defer assistant_text.deinit(allocator);

        var tool_uses = std.ArrayList(msg.ToolUse).empty;
        defer tool_uses.deinit(allocator);

        // P0.4 流式预取:纯只读工具(Read/Grep/Glob)在其 tool_use_start 到达时就开线程执行,流末
        // executeSlots 直接用结果。仅当无 PreToolUse hook(避免 ModifyInput 让预取输入过时)时启用。
        const sp = @import("stream_prefetch.zig");
        var prefetch = sp.Prefetch.init(allocator);
        defer prefetch.deinit();
        const prefetch_enabled = if (permission_ctx.hooks) |h| !h.hasPre() else true;
        // 流期权限判定用的无 hook 上下文副本(不 mid-stream 跑 hook 副作用)。
        var pc_prefetch = permission_ctx.*;
        pc_prefetch.hooks = null;
        // 预取用 ToolContext:与主 base_ctx **同源** opts.*(避免行为分叉——dispatch 要能路由 dyn 工具,
        // read_state/cwd/home/sandbox 与主执行一致)。只读工具不碰的字段留默认无害。
        var prefetch_ctx = tools_mod.ToolContext{
            .allocator = allocator,
            .abort = opts.abort,
            .read_state = opts.read_state,
            .cwd_abs = opts.cwd_abs,
            .home_dir = opts.home_dir,
            .sandbox = opts.sandbox,
            .tool_defs = opts.tool_defs,
            .dyn_registry = opts.dyn_registry,
            .host_services = opts.host_services,
            .session_id = opts.session_id,
            .project_dir = opts.project_dir,
            .agent_depth = opts.agent_depth,
            .parent_model = opts.parent_model,
            .disable_shell_execution = opts.disable_shell_execution,
        };

        request_recovery: while (true) {
            var stream: api_stream.StreamHandle = undefined;
            var api_messages = try buildApiMessages(conversation, allocator, opts.inject_user_context, synthetic_user_input);
            defer freeApiMessages(&api_messages, allocator);

            // 击穿检测:发请求前记录 system/tools/model 指纹(tools 用工具名拼接 hash)。
            {
                var th = std.hash.Wyhash.init(0);
                for (gated_tool_defs) |d| th.update(d.name);
                var tbuf: [16]u8 = undefined;
                std.mem.writeInt(u64, tbuf[0..8], th.final(), .little);
                const model_for_req = opts.model_override orelse provider.model();
                cache_detector.recordRequest(opts.system_prompt orelse "", tbuf[0..8], model_for_req);
            }

            stream = provider.sendStreamRetry(
                api_messages.items,
                effective_system_prompt,
                gated_tool_defs,
                opts.abort,
                opts.model_override,
                null,
                client_mod.defaultMaxRetries(),
                0, // base_ms=0 → 用默认 RETRY_BASE_MS(500)
                reporter,
                latestUserText(conversation), // web_search 显示用:用户原话(P1:作请求参数传, 不再 post-set)
            ) catch |err| switch (err) {
                error.ContextWindowExceeded => {
                    if (!recoverContextWindowExceeded(
                        conversation,
                        provider,
                        effective_system_prompt,
                        opts.inject_user_context,
                        synthetic_user_input,
                        gated_tool_defs,
                        opts.model_override,
                        backend,
                        sess,
                        &context_recovery_attempts,
                        context_recovery_cap,
                        turns + 1,
                        allocator,
                    )) {
                        return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .api_error, .turns = turns, .tool_calls = total_tool_calls });
                    }
                    continue :request_recovery;
                },
                else => |e| {
                    log.err("agent", "sendMessageStream failed turn={d}: {s}", .{ turns + 1, @errorName(e) });
                    return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .api_error, .turns = turns, .tool_calls = total_tool_calls });
                },
            };
            defer stream.deinit();

            rid_for_turn = stream.requestId();
            const rid = rid_for_turn;
            log.infoId("agent", rid, "stream opened, reading events", .{});

            if (opts.colorize) backend.emitEvent(sess, .stream_begin);
            var aborted_during_stream = false;
            var stream_error = false;
            var stream_context_window_exceeded = false;
            while (true) {
                const ev_opt = stream.next() catch |err| switch (err) {
                    error.Aborted => {
                        aborted_during_stream = true;
                        log.warnId("agent", rid, "stream aborted mid-turn", .{});
                        break;
                    },
                    error.ContextWindowExceeded => {
                        stream_error = true;
                        stream_context_window_exceeded = true;
                        log.warnId("agent", rid, "stream returned context-window-exceeded at turn {d}", .{turns + 1});
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
                    .tool_use_start => |tu_in| {
                        var tu = tu_in;
                        // P0.6 弱模型健壮性:tool input 非法 JSON(markdown 围栏/trailing comma/括号不
                        // 配平/前置噪声)→ 尽力 salvage,兜底 {}。单一 choke point 覆盖所有 provider。
                        // tu.input_json 是 owned(stream 转移),修复则 free 旧、换 owned repaired。
                        if (!message_repair_mod.isValidJson(tu.input_json)) {
                            if (message_repair_mod.repairToolArgs(allocator, tu.input_json)) |repaired| {
                                log.warnId("agent", rid, "tool input repaired name={s}: {s} → {s}", .{ tu.name, tu.input_json, repaired });
                                allocator.free(tu.input_json);
                                tu.input_json = repaired;
                            } else |_| {} // repair OOM → 用原始(下游 tool 报错自纠)
                        }
                        // verbose 的 `[Tool: name]` 行移到 backend(在 tool_start 渲染时打,
                        // 见 TuiBackend/WriterBackend);此处只入队 tool_use。
                        log.infoId("agent", rid, "tool_use queued id={s} name={s} input_bytes={d}", .{ tu.id, tu.name, tu.input_json.len });
                        // stream 里 id/name/input_json 都是 owned；转移所有权给 tool_uses（不 dupe）
                        try tool_uses.append(allocator, .{
                            .id = tu.id,
                            .name = tu.name,
                            .input = tu.input_json,
                        });
                        // P0.4 流式预取:只读 + 并发安全 + 权限 allow(纯判定不 prompt)→ 立即开线程执行。
                        // borrow 刚 append 的 tool_uses 里的稳定堆切片(ArrayList 扩容搬结构体不动堆内容)。
                        const not_aborted = if (opts.abort) |ab| !ab.isAborted() else true;
                        if (prefetch_enabled and not_aborted and sp.isPrefetchable(tu.name) and
                            tools_mod.isConcurrencySafeInput(tu.name, tu.input_json) and
                            permission_mod.checkPermission(&pc_prefetch, tu.name, tu.input_json) == .allow)
                        {
                            const last = &tool_uses.items[tool_uses.items.len - 1];
                            prefetch.start(&prefetch_ctx, last.id, last.name, last.input);
                        }
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
                        // L1:usage 走 CoreEvent 总线(顶层 TuiBackend 累加进 app.usage;
                        // JobEntry 后端累加进 .tokens 供进度树)——取代旧 opts.usage_sink 私有回调。
                        backend.emitEvent(sess, .{ .usage = u });
                        // 成本次闸累计(本 run):按模型单价把本响应 usage 折算成本。
                        run_cost_usd += @import("../util/pricing.zig").computeCost(cost_rates, u.input_tokens, u.output_tokens, u.cache_read_input_tokens, u.cache_creation_input_tokens);
                        // usage 锚点:服务端实计 prompt tokens(in+cache_r+cache_w)。
                        // auto-compact 估算以此为基准,只对之后新 append 的消息做本地估算
                        // (估算器 vs 各家 tokenizer 偏差不再随会话放大;glm-5.2 262K 窗口
                        // 下旧的纯字节估算超估 ~3.5x,在真实 ~65K 时就误触发 blocking 清空)。
                        const anchor_tokens = u.input_tokens + u.cache_read_input_tokens + u.cache_creation_input_tokens;
                        conversation.setUsageAnchor(@intCast(anchor_tokens));
                        if (cache_detector.checkResponse(u.cache_read_input_tokens, u.cache_creation_input_tokens)) |reason| {
                            log.warnId("cache", rid, "PROMPT CACHE BREAK: {s} [cache_read {d} creation {d}]", .{ reason, u.cache_read_input_tokens, u.cache_creation_input_tokens });
                            // L4 诊断:cache 击穿。
                            backend.emitEvent(sess, .{ .diag_cache_break = .{ .trace_id = trace_id, .depth = depth, .cache_read = u.cache_read_input_tokens, .cache_creation = u.cache_creation_input_tokens } });
                        }
                        log.infoId("agent", rid, "usage in={d} out={d} cache_r={d} cache_w={d}", .{ u.input_tokens, u.output_tokens, u.cache_read_input_tokens, u.cache_creation_input_tokens });
                    },
                    .done => {},
                }
            }
            // 闭颜色括号 + 尾换行由 backend 决定(colorize ? "\x1b[0m\n" : "\n")。
            backend.emitEvent(sess, .stream_done);

            // 抓本轮 API 报告的 stop_reason(stream.deinit 前读;defer 在 turn 末才执行)
            turn_stop_reason = stream.stopReason();

            log.infoId("agent", rid, "stream finished text_bytes={d} tool_uses={d} aborted={} err={}", .{
                assistant_text.items.len,
                tool_uses.items.len,
                aborted_during_stream,
                stream_error,
            });

            if (aborted_during_stream) {
                // 保留已流出的 partial assistant text（对齐 TS 原版 `onCancel` 行为）：
                // 让用户看到已生成的内容；下次用 /retry 能继续。
                // **先 join 预取线程**:它们 borrow tool_uses 的 id/name/input 字节,必须在下面 free
                // 之前 join,否则在飞 Read/Grep 读已释放内存(Linus HIGH-1 UAF)。
                prefetch.joinAll();
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
                return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .aborted, .turns = turns + 1, .tool_calls = total_tool_calls });
            }

            // Stream error：不把残缺的 assistant_text / tool_uses commit 到 conversation
            // 否则下一轮会把残片作为 context 导致模型"续写"残片。
            // context-window-exceeded 若发生在任何 assistant payload 之前，可以安全删老
            // history 并重开同一 turn；一旦已经流出内容，就不能假装 UI 可回滚。
            if (stream_error) {
                const can_recover_context_error = stream_context_window_exceeded and
                    assistant_text.items.len == 0 and
                    tool_uses.items.len == 0 and
                    assistant_blocks.items.len == 0;
                // 先 join 预取线程再释放 tool_uses(它们 borrow 其字节),防 UAF(Linus HIGH-1)。
                prefetch.joinAll();
                for (tool_uses.items) |tu| {
                    allocator.free(tu.id);
                    allocator.free(tu.name);
                    allocator.free(tu.input);
                }
                tool_uses.clearRetainingCapacity();
                for (assistant_blocks.items) |b| b.deinit(allocator);
                assistant_blocks.clearRetainingCapacity();
                assistant_text.clearRetainingCapacity();
                if (can_recover_context_error) {
                    if (!recoverContextWindowExceeded(
                        conversation,
                        provider,
                        effective_system_prompt,
                        opts.inject_user_context,
                        synthetic_user_input,
                        gated_tool_defs,
                        opts.model_override,
                        backend,
                        sess,
                        &context_recovery_attempts,
                        context_recovery_cap,
                        turns + 1,
                        allocator,
                    )) {
                        return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .api_error, .turns = turns + 1, .tool_calls = total_tool_calls });
                    }
                    continue :request_recovery;
                }
                return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .api_error, .turns = turns + 1, .tool_calls = total_tool_calls });
            }

            break :request_recovery;
        }
        const rid = rid_for_turn;

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
                // L4 诊断:续写。
                backend.emitEvent(sess, .{ .diag_continuation = .{ .trace_id = trace_id, .depth = depth, .n = continuations, .max = MAX_CONTINUATIONS } });
                try conversation.appendText(.user, "Your previous response was cut off by the token limit. Continue exactly where you left off, without repeating.");
                continue;
            }
            // L4 诊断:本轮无 tool_use → turn 结束(span 平衡:每个 turn_begin 都配一个
            // turn_end,无论有无工具)。紧接 run_end(end_turn)收口。
            backend.emitEvent(sess, .{ .diag_turn_end = .{ .trace_id = trace_id, .depth = depth, .turn = turns + 1, .tool_calls = total_tool_calls } });
            return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .end_turn, .turns = turns + 1, .tool_calls = total_tool_calls });
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
        // P0.2 PreToolUse ModifyInput/Block:hook 在此**统一跑一次**(拿 block + updatedInput 改写);
        // 为避免 checkPermission 内 decision.check 再跑一次 hook(重复副作用),给它一份 hooks=null 的
        // 上下文副本。改写后的输入(owned)挂 mod_inputs,turn 作用域统一释放;slot.input 指向它。
        const hookset: ?*const hooks_mod.HookSet = permission_ctx.hooks;
        var pc_nohooks = permission_ctx.*;
        pc_nohooks.hooks = null;
        var mod_inputs: std.ArrayList([]u8) = .empty;
        defer {
            for (mod_inputs.items) |mi| allocator.free(mi);
            mod_inputs.deinit(allocator);
        }
        for (last_msg.blocks) |b| {
            const tu = switch (b) {
                .tool_use => |t| t,
                else => continue,
            };
            total_tool_calls += 1;
            // PreToolUse hook(有配置才跑):可 block(拒)或 updatedInput(改写工具输入)。
            var eff_input = tu.input;
            if (hookset) |hs| if (hs.hasPre()) {
                const pre = hooks_mod.runPreToolUseFull(hs, allocator, tu.name, tu.input);
                if (pre.modified_input) |mi| {
                    mod_inputs.append(allocator, mi) catch allocator.free(mi);
                    // append 成功才用改写值;失败(OOM)已 free,退回原 input。
                    if (mod_inputs.items.len > 0 and mod_inputs.items[mod_inputs.items.len - 1].ptr == mi.ptr) eff_input = mi;
                }
                if (pre.decision == .block) {
                    log.warnId("permission", rid, "PreToolUse hook blocked tool={s}", .{tu.name});
                    var dslot = tool_exec.Slot{ .decision = .denied, .name = tu.name, .id = tu.id, .input = eff_input };
                    dslot.content = try tool_error.errorToJson("PreToolUseBlocked", "tool '{s}' blocked by PreToolUse hook", .{tu.name}, allocator);
                    dslot.is_error = true;
                    try slots.append(allocator, dslot);
                    continue;
                }
            };
            const perm_result = permission_mod.checkPermission(&pc_nohooks, tu.name, eff_input);
            log.infoId("permission", rid, "tool={s} decision={s}", .{ tu.name, @tagName(perm_result) });
            var slot = tool_exec.Slot{ .decision = .run, .name = tu.name, .id = tu.id, .input = eff_input };
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
                    const allowed = permission_mod.promptUser(@constCast(permission_ctx), tu.name, eff_input) catch false;
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
            .kg = opts.kg,
            .kg_projects_dir = opts.kg_projects_dir,
            .memdir_abs = opts.memdir_abs,
            .api_client = opts.api_client,
            .provider = provider, // P0.5:子 spawn 继承父 provider(跨 provider 正确)
            .tool_defs = opts.tool_defs,
            .agent_depth = opts.agent_depth,
            .dyn_registry = opts.dyn_registry,
            .host_services = opts.host_services,
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
            .mcp_sessions = opts.mcp_sessions,
            .cron_registry = opts.cron_registry,
        };

        // 工具执行期 progress 通路(对齐 cc onProgress):把 WebSearch 子请求的
        // query_update/results_received 格式化成第二行文本,经 backend.emit(.tool_progress) 喂 UI。
        // depth==0 才接(子 agent 不驱动顶层 TUI)。WriterBackend 的 tool_progress no-op → 无害,
        // 故去掉旧 @hasDecl 探测。
        if (opts.agent_depth == 0) {
            progress_tramp = .{ .be = backend, .session = sess };
            base_ctx.progress_reporter = .{ .ctx = @ptrCast(&progress_tramp), .reportFn = &ProgressTramp.cb };
        }

        // 统一 UI 请求回调(AskUserQuestion/权限/plan 审批共用):仅顶层 TUI(depth==0)接——
        // 子 agent 无 tty,工具按语义兜底(ask→NotATty;plan→answer_queue/reject)。
        if (opts.ui_requester != null and opts.agent_depth == 0) {
            base_ctx.ui_requester = opts.ui_requester;
        }
        // 子进程心跳(Bash 长命令"仍在运行")per-session 通路:从 opts 透传到 ctx → spawn 层。
        base_ctx.spawn_tick_fn = opts.spawn_tick_fn;
        base_ctx.session = sess; // UiRequest 路由到本 session 视图(M5)
        base_ctx.agent_ident = opts.agent_ident orelse sess; // 对外身份(claim);主 loop=session,subagent=spawn 时 gen

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
        // 进度事件:本轮第一个 run slot 的工具名 + 原始 input(subagent agent 树显示当前动作)。
        // 无条件 emit——backend 自决消费(顶层 TuiBackend 忽略 .progress;JobEntry 后端更新树)。
        for (slots.items) |*s| {
            if (s.decision == .run) {
                emitProgress(backend, sess, turns + 1, s.name, s.input, total_tool_calls);
                break;
            }
        }
        // P0.4:流式预取命中的 slot 直接填结果(executeSlots 会跳过 prefetched 的,不重复执行)。
        for (slots.items) |*s| {
            if (s.decision != .run) continue;
            if (prefetch.take(s.id)) |pf| {
                s.content = pf.content;
                s.is_error = pf.is_error;
                s.elapsed_ms = pf.elapsed_ms;
                s.prefetched = true;
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

        // 6c.5 L3 挂起:本轮有工具返 error.UiPending(异步 custom UI 未完成)→ 整轮挂起。
        // **API 配对约束**:assistant 的每个 tool_use 须在紧接 user 消息里有 tool_result,不能拆
        // 两次。故挂起时**不**提交任何 partial user 消息;已完成工具的结果 stash 进 SuspendInfo,
        // resume 时与 pending 的迟来结果一起补成单条 user 消息(A+B 同 turn)。
        // 找首个 pending 作挂起点;其余 pending(MVP 不支持多挂起点)→ 当错误,resume 时也配对补。
        var first_pending: ?*tool_exec.Slot = null;
        for (slots.items) |*s| {
            if (s.pending) {
                first_pending = s;
                break;
            }
        }
        if (first_pending) |s| {
            // 收集**所有非挂起点**工具的结果(已完成的用真实结果;其余 pending 用错误占位)——
            // 它们都要在 resume 时与挂起点的迟来结果同 turn 补齐,满足 API 配对。
            var completed: std.ArrayList(SuspendInfo.CompletedResult) = .empty;
            errdefer completed.deinit(allocator);
            for (slots.items) |*o| {
                if (o == s or o.decision != .run) continue;
                const content: []const u8 = if (o.pending)
                    // 非首个 pending:MVP 不支持并发挂起 → 错误占位(模型 resume 后可重试)。
                    try tool_error.errorToJson("ConcurrentSuspendUnsupported", "tool {s} requested UI while another suspended; not supported in MVP", .{o.name}, allocator)
                else
                    try allocator.dupe(u8, o.content orelse "{}");
                try completed.append(allocator, .{
                    .tool_use_id = try allocator.dupe(u8, o.id),
                    .content = content,
                    .is_error = if (o.pending) true else o.is_error,
                });
                // 释放 slot 原 owned 内存(content 已 dupe 进 completed;pending 的 kind/payload
                // 不进 SuspendInfo)——否则泄漏(正常路径 content 移交 result_blocks,此处改 dupe)。
                if (o.content) |c| {
                    allocator.free(c);
                    o.content = null;
                }
                if (o.pending) {
                    if (o.pending_kind) |k| allocator.free(k);
                    if (o.pending_payload) |p| allocator.free(p);
                    o.pending_kind = null;
                    o.pending_payload = null;
                }
            }
            // result_blocks 这轮不提交(挂起不落 partial user 消息);释放已 append 的(本应为空)。
            result_blocks.clearAndFree(allocator);
            const kind = s.pending_kind orelse "";
            const payload = s.pending_payload orelse "{}";
            // 异步前端据此投递 UI 请求(tool_use_id + 渲染规格)。
            backend.emitEvent(sess, .{ .ui_request_pending = .{ .tool_use_id = s.id, .request_json = payload } });
            // SuspendInfo 接管挂起点 slot 的 pending 字符串所有权(移动,不重复 dupe);置 null 防 double-free。
            const si = SuspendInfo{
                .tool_use_id = try allocator.dupe(u8, s.id),
                .kind = if (s.pending_kind) |k| k else try allocator.dupe(u8, ""),
                .payload_json = if (s.pending_payload) |p| p else try allocator.dupe(u8, "{}"),
                .completed_results = try completed.toOwnedSlice(allocator),
                .allocator = allocator,
            };
            s.pending_kind = null;
            s.pending_payload = null;
            log.infoId("agent", rid, "run SUSPENDED tool_use_id={s} kind={s} completed_siblings={d}", .{ s.id, kind, si.completed_results.len });
            return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .suspended, .turns = turns + 1, .tool_calls = total_tool_calls, .suspend_info = si });
        }

        // 6d. 按原顺序回填 result_blocks。熔断判定**不在此内层循环累加**——否则单轮内
        // 多个工具调用返回同一错误(如 subagent 第一轮发 3 个 TaskCreate 全失败)会在一轮内
        // 把 same_err_count 累到阈值,turns=1 就误熔断。改为:本轮只归纳"本轮错误特征"
        // (是否所有 error slot 同签名、有无成功 slot),循环后做**跨 turn**累积判定。
        var turn_err_sig: ?ToolErrSig = null; // 本轮 error slot 的统一签名(若全同)
        var turn_uniform_err = true; // 本轮 error slot 是否全是同一签名
        var turn_any_error = false; // 本轮是否有 error slot
        var turn_any_success = false; // 本轮是否有成功 slot
        // P0.2 PostToolUse:执行后 hook 产出的 additionalContext,拼成一段注入本轮 user 消息(下轮模型可见)。
        var post_ctx: std.ArrayList(u8) = .empty;
        defer post_ctx.deinit(allocator);
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

            // PostToolUse hook(执行后,仅真跑过的 slot):收集 additionalContext 注入下轮上下文。
            if (s.decision == .run) {
                if (hookset) |hs| if (hs.hasPost()) {
                    if (hooks_mod.runPostToolUse(hs, allocator, s.name, s.input, content)) |ac| {
                        defer allocator.free(ac);
                        if (post_ctx.items.len > 0) post_ctx.append(allocator, '\n') catch {};
                        post_ctx.appendSlice(allocator, ac) catch {};
                    }
                };
            }

            // 零增益重复熔断(主防线):同 (name,input) 产出同 result 累计 MAX_ZERO_GAIN_REPEAT 次
            // → 原地打转 → 复用 tool_loop 停。分页(offset 异)= 异 signature 不触发;结果变 →
            // result_hash 变 → 重置,不误杀 re-check。best-effort:getOrPut OOM 时跳过(不阻塞)。
            {
                var sh = std.hash.Wyhash.init(0);
                sh.update(s.name);
                sh.update(s.input);
                const n = zero_gain.record(sh.final(), std.hash.Wyhash.hash(0, content));
                if (n >= MAX_ZERO_GAIN_REPEAT) {
                    log.warnId("agent", rid, "zero-gain repeat breaker: tool {s} identical input+result x{d}", .{ s.name, n });
                    backend.emitEvent(sess, .{ .diag_breaker_tripped = .{ .trace_id = trace_id, .depth = depth, .same_err_count = n } });
                    tool_loop_tripped = true;
                }
            }

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
                // L4 诊断:熔断触发。
                backend.emitEvent(sess, .{ .diag_breaker_tripped = .{ .trace_id = trace_id, .depth = depth, .same_err_count = same_err_count } });
                tool_loop_tripped = true;
            }
        } else {
            same_err_count = 0;
            last_err_sig = null;
        }

        if (result_blocks.items.len == 0) {
            result_blocks.deinit(allocator);
            return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .tool_error, .turns = turns + 1, .tool_calls = total_tool_calls });
        }

        // PostToolUse additionalContext → 同一 user 消息追加一个 text block(下轮模型可见)。
        if (post_ctx.items.len > 0) {
            const ctx_text = try std.fmt.allocPrint(allocator, "[PostToolUse hook]\n{s}", .{post_ctx.items});
            try result_blocks.append(allocator, .{ .text = ctx_text });
        }

        const blocks_owned = try result_blocks.toOwnedSlice(allocator);
        try conversation.append(.{ .role = .user, .blocks = blocks_owned });

        // 工具熔断:同工具同错连续 MAX_SAME_TOOL_ERROR 次 → 停。错误结果已写入
        // conversation(供复盘),这里直接返回 .tool_loop,不再发下一轮请求——避免
        // 模型原地空参风暴烧满 max_turns。
        if (tool_loop_tripped) {
            return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .tool_loop, .turns = turns + 1, .tool_calls = total_tool_calls });
        }

        // Mid-turn follow-up compact: after tool_result blocks are appended and
        // before the next sampling request, re-check the actual pending request.
        // This is the explicit Rust/metacode "post_sampling_follow_up_threshold"
        // equivalent; the next loop's pre-sampling check would be close, but this
        // makes the follow-up boundary a real trigger point with its own cause.
        const post_tool_compact = try runAutoCompactIfNeeded(
            conversation,
            provider,
            effective_system_prompt,
            opts.inject_user_context,
            null,
            gated_tool_defs,
            opts.model_override,
            null,
            opts.auto_compact_threshold,
            opts.auto_compact_keep_recent,
            "post_tool_follow_up_threshold",
            backend,
            sess,
            &context_warning_emitted,
            allocator,
            opts.tasks,
        );
        if (post_tool_compact == .api_error) {
            return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .api_error, .turns = turns + 1, .tool_calls = total_tool_calls });
        }

        // L4 诊断:turn span 终点(本轮有 tool_use、将进入下一轮的正常路径;无工具的
        // end_turn 路径在上方提前 return + diag_run_end 收口,故不重复发)。
        backend.emitEvent(sess, .{ .diag_turn_end = .{ .trace_id = trace_id, .depth = depth, .turn = turns + 1, .tool_calls = total_tool_calls } });
    }

    // 循环正常退出 = turns >= max_turns
    return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .max_turns, .turns = turns, .tool_calls = total_tool_calls });
}

/// L3 恢复:把异步 UI 响应 + 同轮已完成工具的结果**一起**注入为单条 user 消息(满足 API 的
/// tool_use/tool_result 同 turn 配对),然后续跑 run()。
///
/// conversation 须已含挂起点的 assistant(带那些 tool_use)——同进程时它还在内存;跨进程/重启
/// 时由调用方先 loadTranscript 从盘重建。resumeRun 不关心来源,只:① 构造一条 user 消息,内含
/// **挂起点 tool_use 的迟来 tool_result(content=response_json)+ completed_results 里每个同轮
/// 已完成工具的 tool_result**;② 调 run() 续跑。response_json / completed 借用,append 时 dupe。
///
/// **为什么要 completed_results**:挂起的那条 assistant 消息可能有多个 tool_use(A=pending,
/// B/C=done)。API 要求 A+B+C 的 tool_result 都在紧接的同一条 user 消息里。挂起时已完成的 B/C
/// 结果没单独提交(那样会拆 turn 违规),而是 stash 在 SuspendInfo.completed_results,此刻一起补。
pub fn resumeRun(
    conversation: *Conversation,
    provider: provider_mod.Provider,
    tool_defs: []const json_mod.ToolDefinition,
    permission_ctx: *const permission_mod.PermissionContext,
    resumed_tool_use_id: []const u8,
    response_json: []const u8,
    completed_results: []const SuspendInfo.CompletedResult,
    opts: Options,
    backend: *const UiBackend,
    allocator: std.mem.Allocator,
) !RunResult {
    // 一条 user 消息,内含挂起点的迟来结果 + 所有同轮已完成工具的结果(同 turn 配对)。
    var blocks: std.ArrayList(msg.Block) = .empty;
    errdefer blocks.deinit(allocator);
    try blocks.append(allocator, .{ .tool_result = .{
        .tool_use_id = try allocator.dupe(u8, resumed_tool_use_id),
        .content = try allocator.dupe(u8, response_json),
        .is_error = false,
    } });
    for (completed_results) |cr| {
        try blocks.append(allocator, .{ .tool_result = .{
            .tool_use_id = try allocator.dupe(u8, cr.tool_use_id),
            .content = try allocator.dupe(u8, cr.content),
            .is_error = cr.is_error,
        } });
    }
    try conversation.append(.{ .role = .user, .blocks = try blocks.toOwnedSlice(allocator) });
    log.info("agent", "resume: injected {d} tool_result(s) (pending={s} + {d} siblings), continuing run", .{ completed_results.len + 1, resumed_tool_use_id, completed_results.len });
    // 续跑(可能再次挂起——resume 可链式)。
    return run(conversation, provider, tool_defs, permission_ctx, opts, backend, allocator);
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
    inject_user_context: ?[]const u8,
    synthetic_user_input: ?[]const u8,
) !std.ArrayList(types.ApiMessage) {
    var out = std.ArrayList(types.ApiMessage).empty;
    errdefer {
        freeApiMessages(&out, allocator);
    }

    // 首条 user-context message(对齐 cc prependUserContext):合成一条 user message,
    // content 单 text block = `<system-reminder>` 包裹的 CLAUDE.md/AutoMem/currentDate。
    // 借用 inject_user_context 的字节(不 dupe);freeApiMessages 只 free content 数组本身,
    // 不 free block 内字符串——与下方 conversation 借用块同策略。
    if (inject_user_context) |ctx_text| {
        if (ctx_text.len > 0) {
            const contents = try allocator.alloc(types.ApiContent, 1);
            contents[0] = .{ .text = ctx_text };
            try out.append(allocator, .{ .role = .user, .content = contents });
        }
    }

    // P1.5 纯投影:压缩摘要作为边界前一条 assistant 消息注入(原始消息仍全量留在 conversation,
    // 只是不发)。发给模型 = [inject_ctx] + [summary] + activeMessages()。与 totalTokens 投影一致。
    if (conversation.compact_summary) |summ| {
        if (summ.len > 0) {
            const contents = try allocator.alloc(types.ApiContent, 1);
            contents[0] = .{ .text = summ }; // 借用 conversation 拥有的摘要字节
            try out.append(allocator, .{ .role = .assistant, .content = contents });
        }
    }

    for (conversation.activeMessages()) |m| {
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
    if (synthetic_user_input) |synthetic_text| {
        if (synthetic_text.len > 0) {
            const contents = try allocator.alloc(types.ApiContent, 1);
            contents[0] = .{ .text = synthetic_text };
            try out.append(allocator, .{ .role = .user, .content = contents });
        }
    }
    // P0.6 弱模型健壮性层:发请求前规范化——剥孤儿 tool_result + 补缺失结果 + 合并连续同角色。
    // 维持 content 数组 owned / block 借用的内存契约(见 message_repair 顶注)。
    try @import("message_repair.zig").normalizeApiMessages(allocator, &out);
    return out;
}

fn freeApiMessages(list: *std.ArrayList(types.ApiMessage), allocator: std.mem.Allocator) void {
    for (list.items) |m| {
        allocator.free(m.content);
    }
    list.deinit(allocator);
}

fn estimateNextRequestTokens(
    allocator: std.mem.Allocator,
    provider: provider_mod.Provider,
    conversation: *const Conversation,
    system_prompt: ?[]const u8,
    inject_user_context: ?[]const u8,
    synthetic_user_input: ?[]const u8,
    tool_defs: []const json_mod.ToolDefinition,
    model_override: ?[]const u8,
) !usize {
    // 热路径:usage 锚点有效 → 服务端实计 tokens + 锚点后新消息的本地估算。
    // 锚点请求已含 system/tools/inject_user_context,不重复计;synthetic 只在
    // turns==0 发,锚点在则它已被计入或不再发,同样不补。
    if (conversation.usageAnchor()) |anchor| {
        var total: usize = anchor.context_tokens;
        for (conversation.messages.items[anchor.msg_count..]) |m| {
            total += estimateMessageTokens(m);
        }
        return total;
    }
    // 冷路径(首轮/后端不报 usage/前缀被 compact 改写):序列化真实下一请求做全量估算。
    var api_messages = try buildApiMessages(conversation, allocator, inject_user_context, synthetic_user_input);
    defer freeApiMessages(&api_messages, allocator);
    return estimateApiRequestTokens(allocator, provider, api_messages.items, system_prompt, tool_defs, model_override);
}

/// 单条消息的 token 估算(usage 锚点后缀用):text/tool_use/tool_result 各 block
/// 走 Conversation.estimateTokens,再加 JSON 信封开销;thinking 不回 API 不计。
fn estimateMessageTokens(m: msg.Message) usize {
    var total: usize = 8; // message 信封(role/content 括号)
    for (m.blocks) |b| {
        total += 12; // block 信封(type/id 等字段)
        switch (b) {
            .text => |t| total += Conversation.estimateTokens(t),
            .tool_use => |tu| total += Conversation.estimateTokens(tu.name) + Conversation.estimateTokens(tu.input),
            .tool_result => |tr| total += Conversation.estimateTokens(tr.content),
            .thinking => {},
        }
    }
    return total;
}

fn estimateApiRequestTokens(
    allocator: std.mem.Allocator,
    provider: provider_mod.Provider,
    messages: []const types.ApiMessage,
    system_prompt: ?[]const u8,
    tool_defs: []const json_mod.ToolDefinition,
    model_override: ?[]const u8,
) !usize {
    const req_body = try json_mod.serializeMessagesRequest(.{
        .model = model_override orelse provider.model(),
        .max_tokens = provider.maxTokens(),
        .messages = messages,
        .system = system_prompt,
        .stream = true,
        .tools = tool_defs,
        .reasoning_effort = provider.reasoningEffort(),
    }, allocator);
    defer allocator.free(req_body);
    return Conversation.estimateTokens(req_body);
}

fn estimateNextRequestTokensOrFallback(
    allocator: std.mem.Allocator,
    provider: provider_mod.Provider,
    conversation: *const Conversation,
    system_prompt: ?[]const u8,
    inject_user_context: ?[]const u8,
    synthetic_user_input: ?[]const u8,
    tool_defs: []const json_mod.ToolDefinition,
    model_override: ?[]const u8,
) usize {
    return estimateNextRequestTokens(allocator, provider, conversation, system_prompt, inject_user_context, synthetic_user_input, tool_defs, model_override) catch |err| {
        log.warn("agent", "actual request token estimate failed: {s}; using fallback estimate", .{@errorName(err)});
        return estimateNextRequestTokensFallback(conversation, system_prompt, inject_user_context, synthetic_user_input, tool_defs);
    };
}

const AutoCompactOutcome = enum { not_needed, compacted, skipped_no_savings, api_error };

fn recoverContextWindowExceeded(
    conversation: *Conversation,
    provider: provider_mod.Provider,
    system_prompt: ?[]const u8,
    inject_user_context: ?[]const u8,
    synthetic_user_input: ?[]const u8,
    tool_defs: []const json_mod.ToolDefinition,
    model_override: ?[]const u8,
    backend: *const UiBackend,
    sess: @import("session_id.zig").SessionId,
    attempts: *usize,
    cap: usize,
    turn_number: u32,
    allocator: std.mem.Allocator,
) bool {
    attempts.* += 1;
    if (attempts.* > cap) {
        log.err("agent", "context-window recovery exhausted turn={d} attempts={d}", .{ turn_number, attempts.* });
        return false;
    }
    // 先作废 usage 锚点:removeOldest 反正会作废它,提前作废让 before/after 同用
    // 冷路径基准——否则 before=锚点实计、after=冷估算,删消息后数字反而翻倍(假遥测,
    // 实录 2026-07-06 fix4.log:dropped=1 before=203081 after=415469)。
    conversation.invalidateUsageAnchor();
    const before_tokens = estimateNextRequestTokensOrFallback(allocator, provider, conversation, system_prompt, inject_user_context, synthetic_user_input, tool_defs, model_override);
    // 投影:removeOldest 推进 boundary(原始不删),收缩的是活跃窗口 → 遥测用活跃计数,否则 N->N。
    const before_active = conversation.activeMessages().len;
    const dropped = conversation.removeOldestForContextRecovery();
    if (dropped == 0) {
        log.err("agent", "context-window recovery impossible turn={d} active_msgs={d}", .{ turn_number, conversation.activeMessages().len });
        return false;
    }
    const after_tokens = estimateNextRequestTokensOrFallback(allocator, provider, conversation, system_prompt, inject_user_context, synthetic_user_input, tool_defs, model_override);
    const kept_active = conversation.activeMessages().len;
    log.warn("agent", "context-window recovery: dropped={d} active_msgs={d}->{d} before_tokens={d} after_tokens={d} attempt={d}", .{ dropped, before_active, kept_active, before_tokens, after_tokens, attempts.* });
    backend.emitEvent(sess, .{ .auto_compact = .{
        .dropped = @as(u32, @intCast(dropped)),
        .kept = @as(u32, @intCast(kept_active)),
        .before_tokens = @intCast(before_tokens),
        .after_tokens = @intCast(after_tokens),
        .cause = "context_window_exceeded_recovery",
    } });
    return true;
}

fn runAutoCompactIfNeeded(
    conversation: *Conversation,
    provider: provider_mod.Provider,
    system_prompt: ?[]const u8,
    inject_user_context: ?[]const u8,
    synthetic_user_input: ?[]const u8,
    tool_defs: []const json_mod.ToolDefinition,
    model_override: ?[]const u8,
    compact_model_override: ?[]const u8,
    configured_threshold: ?usize,
    keep_recent: usize,
    trigger_cause: []const u8,
    backend: *const UiBackend,
    sess: @import("session_id.zig").SessionId,
    context_warning_emitted: ?*bool,
    allocator: std.mem.Allocator,
    tasks: ?*@import("task_store.zig").TaskStore,
) !AutoCompactOutcome {
    var outcome: AutoCompactOutcome = .not_needed;
    const tool_result_limit = conversation_mod.toolResultContextBytes(provider.maxInputTokens());
    const preflight_truncated = conversation.truncateLargeToolResults(tool_result_limit);
    if (preflight_truncated.changed()) {
        outcome = .compacted;
        log.info("agent", "tool-result truncate: truncated={d} cleared={d} bytes={d}->{d} max_inline={d}", .{ preflight_truncated.truncated, preflight_truncated.cleared, preflight_truncated.bytes_before, preflight_truncated.bytes_after, tool_result_limit });
    }

    var request_tokens_before = estimateNextRequestTokensOrFallback(allocator, provider, conversation, system_prompt, inject_user_context, synthetic_user_input, tool_defs, model_override);
    var pressure = context_pressure_mod.ContextPressure.fromModel(provider.maxInputTokens(), provider.maxTokens(), configured_threshold, request_tokens_before);
    emitContextWarningIfNeeded(backend, sess, pressure, context_warning_emitted);
    // 正常:auto=max(formula, 32K floor);micro=其下一档。强制旋钮(仅测试/power-user)存在时,
    // auto/micro 一起钉到强制值——让短对话也能触发真实 summary 压缩+投影。一次 getenv,不在热路径重复读。
    const forced_threshold = forcedAutoCompactThreshold();
    const auto_threshold: usize = forced_threshold orelse
        @max(pressure.auto_compact_threshold, MIN_AUTO_COMPACT_THRESHOLD);
    const micro_threshold = forced_threshold orelse
        @max(@min(pressure.warning_threshold, auto_threshold), MIN_AUTO_COMPACT_THRESHOLD);
    if (request_tokens_before > micro_threshold and request_tokens_before <= auto_threshold) {
        const reduced = conversation.microcompactToolResultsByRecentResults(conversation_mod.DEFAULT_RECENT_TOOL_RESULTS_TO_KEEP);
        if (reduced.changed()) {
            outcome = .compacted;
            log.info("agent", "microcompact: cleared={d} truncated={d} old tool_results bytes={d}->{d} keep_recent_results={d} threshold={d} cause={s}", .{ reduced.cleared, reduced.truncated, reduced.bytes_before, reduced.bytes_after, conversation_mod.DEFAULT_RECENT_TOOL_RESULTS_TO_KEEP, micro_threshold, trigger_cause });
            request_tokens_before = estimateNextRequestTokensOrFallback(allocator, provider, conversation, system_prompt, inject_user_context, synthetic_user_input, tool_defs, model_override);
            pressure = context_pressure_mod.ContextPressure.fromModel(provider.maxInputTokens(), provider.maxTokens(), configured_threshold, request_tokens_before);
        }
    }

    if (request_tokens_before >= auto_threshold) {
        const compact_summary = @import("compact_summary.zig");
        const SummCtx = struct { provider: provider_mod.Provider, alloc: std.mem.Allocator, model_override: ?[]const u8, task_anchor: ?[]const u8 };
        const summary_model = compact_model_override orelse model_override;
        const eff_keep_recent = forcedAutoCompactKeep() orelse keep_recent;
        // 任务锚:进行中的任务确定性追加到摘要尾(压缩有损,闭环纪律硬保底)。
        const task_anchor: ?[]u8 = if (tasks) |ts| compact_summary.buildTaskAnchor(allocator, ts) else null;
        defer if (task_anchor) |a| allocator.free(a);
        var preview = try conversation.cloneForCompactPreview(allocator, eff_keep_recent);
        defer preview.deinit();
        const before_len = preview.conversation.len();
        const report = preview.conversation.compactWithSummaryReport(eff_keep_recent, SummCtx{ .provider = provider, .alloc = allocator, .model_override = summary_model, .task_anchor = task_anchor }, struct {
            fn f(c: SummCtx, drop_msgs: []const msg.Message) ?[]u8 {
                const summary = compact_summary.summarizeWithModel(c.alloc, c.provider, drop_msgs, c.model_override) orelse return null;
                return compact_summary.appendTaskAnchor(c.alloc, summary, c.task_anchor);
            }
        }.f) catch Conversation.CompactReport{
            .dropped = preview.conversation.compactKeepRecent(eff_keep_recent),
            .summary_used = false,
        };
        if (report.dropped > 0) {
            var cause: []const u8 = if (report.summary_used) trigger_cause else "summary_fallback";
            var request_tokens_after = estimateNextRequestTokensOrFallback(allocator, provider, &preview.conversation, system_prompt, inject_user_context, synthetic_user_input, tool_defs, model_override);
            var saved_percent = compactSavedPercent(request_tokens_before, request_tokens_after);
            if (report.summary_used and !compactHasMinSavings(request_tokens_before, request_tokens_after)) {
                outcome = .skipped_no_savings;
                log.warn("agent", "auto-compact skipped: summary savings below {d}% before_tokens={d} after_tokens={d} saved_percent={d} dropped={d} cause={s}", .{ COMPACT_MIN_SAVED_PERCENT, request_tokens_before, request_tokens_after, saved_percent, report.dropped, trigger_cause });
            } else {
                if (request_tokens_after > auto_threshold) {
                    const emergency = preview.conversation.microcompactToolResultsByRecentResults(0);
                    if (emergency.changed()) {
                        cause = "tool_result_pressure";
                        request_tokens_after = estimateNextRequestTokensOrFallback(allocator, provider, &preview.conversation, system_prompt, inject_user_context, synthetic_user_input, tool_defs, model_override);
                        saved_percent = compactSavedPercent(request_tokens_before, request_tokens_after);
                    }
                }
                if (!conversation.replaceWithOwnedIfSuffixUnchanged(&preview.suffix, &preview.conversation)) {
                    log.warn("agent", "auto-compact aborted: conversation suffix changed during summary generation cause={s}", .{trigger_cause});
                    return .api_error;
                }
                // 投影:len() 不变(原始不删),真正收缩的是活跃窗口——日志/事件的"after/kept"用活跃计数。
                const kept_active = conversation.activeMessages().len;
                log.info("agent", "auto-compact: dropped {d} old messages (active {d} -> {d}) threshold={d} before_tokens={d} after_tokens={d} saved_percent={d} cause={s}", .{ report.dropped, before_len, kept_active, auto_threshold, request_tokens_before, request_tokens_after, saved_percent, cause });
                backend.emitEvent(sess, .{ .auto_compact = .{
                    .dropped = @as(u32, @intCast(report.dropped)),
                    .kept = @as(u32, @intCast(kept_active)),
                    .before_tokens = @intCast(request_tokens_before),
                    .after_tokens = @intCast(request_tokens_after),
                    .cause = cause,
                } });
                outcome = .compacted;
                request_tokens_before = request_tokens_after;
                pressure = context_pressure_mod.ContextPressure.fromModel(provider.maxInputTokens(), provider.maxTokens(), configured_threshold, request_tokens_before);
            }
        }
    }

    if (outcome == .skipped_no_savings) return outcome;

    if (pressure.isAtBlockingLimit()) {
        const reduced = conversation.microcompactToolResultsByRecentResults(0);
        if (reduced.changed()) {
            outcome = .compacted;
            const before_block_tokens = request_tokens_before;
            request_tokens_before = estimateNextRequestTokensOrFallback(allocator, provider, conversation, system_prompt, inject_user_context, synthetic_user_input, tool_defs, model_override);
            pressure = context_pressure_mod.ContextPressure.fromModel(provider.maxInputTokens(), provider.maxTokens(), configured_threshold, request_tokens_before);
            log.warn("agent", "blocking-limit recovery microcompact: bytes={d}->{d} before_tokens={d} after_tokens={d} cause={s}", .{ reduced.bytes_before, reduced.bytes_after, before_block_tokens, request_tokens_before, trigger_cause });
        }
        if (pressure.isAtBlockingLimit()) {
            log.err("agent", "context blocking limit reached: tokens={d} blocking_limit={d} raw_window={d} effective_window={d} cause={s}", .{ request_tokens_before, pressure.blocking_limit, pressure.raw_context_window, pressure.effective_context_window, trigger_cause });
            return .api_error;
        }
    }
    return outcome;
}

fn emitContextWarningIfNeeded(
    backend: *const UiBackend,
    sess: @import("session_id.zig").SessionId,
    pressure: context_pressure_mod.ContextPressure,
    emitted: ?*bool,
) void {
    const flag = emitted orelse return;
    if (flag.*) return;
    if (pressure.level() != .medium) return;
    flag.* = true;
    backend.emitEvent(sess, .{ .context_warning = .{
        .current_tokens = @intCast(pressure.current_context_tokens),
        .warning_threshold = @intCast(pressure.warning_threshold),
        .auto_compact_threshold = @intCast(pressure.auto_compact_threshold),
        .blocking_limit = @intCast(pressure.blocking_limit),
        .level = pressure.level().label(),
    } });
}

fn compactHasMinSavings(before_tokens: usize, after_tokens: usize) bool {
    if (before_tokens == 0) return false;
    if (after_tokens >= before_tokens) return false;
    const saved = before_tokens - after_tokens;
    const divisor = 100 / COMPACT_MIN_SAVED_PERCENT;
    const required = before_tokens / divisor + @intFromBool(before_tokens % divisor != 0);
    return saved >= required;
}

fn compactSavedPercent(before_tokens: usize, after_tokens: usize) usize {
    if (before_tokens == 0 or after_tokens >= before_tokens) return 0;
    return (before_tokens - after_tokens) * 100 / before_tokens;
}

fn estimateNextRequestTokensFallback(
    conversation: *const Conversation,
    system_prompt: ?[]const u8,
    inject_user_context: ?[]const u8,
    synthetic_user_input: ?[]const u8,
    tool_defs: []const json_mod.ToolDefinition,
) usize {
    var total = conversation.totalTokens();
    if (system_prompt) |s| total += Conversation.estimateTokens(s);
    if (inject_user_context) |s| total += Conversation.estimateTokens(s);
    if (synthetic_user_input) |s| total += Conversation.estimateTokens(s);
    for (tool_defs) |tool| {
        total += Conversation.estimateTokens(tool.name);
        total += Conversation.estimateTokens(tool.description);
        if (tool.server_type) |server_type| total += Conversation.estimateTokens(server_type);
        total += estimateInputSchemaTokens(tool.input_schema);
    }
    return total;
}

fn estimateInputSchemaTokens(schema: json_mod.InputSchema) usize {
    var total = Conversation.estimateTokens(schema.type);
    if (schema.prop_specs) |props| {
        total += estimatePropSpecsTokens(props);
    }
    if (schema.required) |required| {
        for (required) |r| total += Conversation.estimateTokens(r);
    }
    if (schema.properties) |props| {
        var it = props.iterator();
        while (it.next()) |entry| total += Conversation.estimateTokens(entry.key_ptr.*);
    }
    return total;
}

fn estimatePropSpecsTokens(props: []const json_mod.PropSpec) usize {
    var total: usize = 0;
    for (props) |prop| {
        total += Conversation.estimateTokens(prop.name);
        total += Conversation.estimateTokens(prop.type);
        total += Conversation.estimateTokens(prop.description);
        if (prop.items_type) |t| total += Conversation.estimateTokens(t);
        if (prop.enum_values) |vals| {
            for (vals) |v| total += Conversation.estimateTokens(v);
        }
        if (prop.items_props) |nested| total += estimatePropSpecsTokens(nested);
        if (prop.items_required) |required| {
            for (required) |r| total += Conversation.estimateTokens(r);
        }
        if (prop.object_props) |nested| total += estimatePropSpecsTokens(nested);
        if (prop.object_required) |required| {
            for (required) |r| total += Conversation.estimateTokens(r);
        }
    }
    return total;
}

test "emitProgress 发 CoreEvent.progress 到 backend(L1:进度=事件)" {
    const S = struct {
        var hits: u32 = 0;
        var last_turn: u32 = 0;
        var last_calls: u32 = 0;
        var last_tool: [16]u8 = undefined;
        var last_tool_len: usize = 0;
        fn emit(_: *anyopaque, _: ui_backend.SessionId, ev: ui_backend.CoreEvent) void {
            switch (ev) {
                .progress => |p| {
                    hits += 1;
                    last_turn = p.turn;
                    last_calls = p.tool_calls;
                    last_tool_len = @min(p.tool_name.len, last_tool.len);
                    @memcpy(last_tool[0..last_tool_len], p.tool_name[0..last_tool_len]);
                },
                else => {},
            }
        }
        fn poll(_: *anyopaque, _: ui_backend.SessionId) ?ui_backend.UiEvent {
            return null;
        }
    };
    S.hits = 0;
    var dummy: u8 = 0;
    const be = ui_backend.UiBackend{ .ctx = @ptrCast(&dummy), .emit = &S.emit, .poll = &S.poll };
    emitProgress(&be, .single, 2, "Grep", "{}", 5);
    try std.testing.expectEqual(@as(u32, 1), S.hits);
    try std.testing.expectEqual(@as(u32, 2), S.last_turn);
    try std.testing.expectEqual(@as(u32, 5), S.last_calls);
    try std.testing.expectEqualStrings("Grep", S.last_tool[0..S.last_tool_len]);
}

test "buildApiMessages maps blocks" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "hi");

    var api = try buildApiMessages(&c, a, null, null);
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

    var api = try buildApiMessages(&c, a, null, null);
    defer freeApiMessages(&api, a);

    try std.testing.expect(api.items.len == 2);
    try std.testing.expect(@as(std.meta.Tag(types.ApiContent), api.items[0].content[0]) == .tool_use);
    try std.testing.expect(@as(std.meta.Tag(types.ApiContent), api.items[1].content[0]) == .tool_result);
}

test "buildApiMessages empty conversation returns empty" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    var api = try buildApiMessages(&c, a, null, null);
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
    var api = try buildApiMessages(&c, a, null, null);
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
    var api = try buildApiMessages(&c, a, null, null);
    defer freeApiMessages(&api, a);
    try std.testing.expect(api.items[0].content.len == 2);
}

test "buildApiMessages appends one-shot synthetic user input without mutating conversation" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "real user");

    var api = try buildApiMessages(&c, a, null, "synthetic steering");
    defer freeApiMessages(&api, a);

    try std.testing.expectEqual(@as(usize, 1), c.len());
    // P0.6 normalizeApiMessages 合并相邻同角色:real user + synthetic 都是 user →
    // 合成 1 条 user 消息(2 个 text block),满足 OpenAI/Gemini 严格角色交替。conversation 不被改动。
    try std.testing.expectEqual(@as(usize, 1), api.items.len);
    try std.testing.expect(api.items[0].role == .user);
    try std.testing.expectEqual(@as(usize, 2), api.items[0].content.len);
    try std.testing.expectEqualStrings("real user", api.items[0].content[0].text);
    try std.testing.expectEqualStrings("synthetic steering", api.items[0].content[1].text);
}

const TestProviderState = struct {
    model: []const u8 = "test-model",
    max_tokens: u32 = 777,
    max_input_tokens: u32 = 200_000,
    supports_web_search: bool = true,
    reasoning_effort: ?types.ReasoningEffort = null,
    allocator: ?std.mem.Allocator = null,
    compact_summary_response: ?[]const u8 = null,
    last_send_model_override: ?[]const u8 = null,
};

fn testProvider(state: *TestProviderState) provider_mod.Provider {
    const F = struct {
        fn asState(ctx: *anyopaque) *TestProviderState {
            return @ptrCast(@alignCast(ctx));
        }
        fn model(ctx: *anyopaque) []const u8 {
            return asState(ctx).model;
        }
        fn sendStream(_: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const json_mod.ToolDefinition, _: ?*const AbortSignal, _: ?[]const u8, _: ?json_mod.ToolChoice, _: []const u8) anyerror!provider_mod.StreamHandle {
            return error.UnexpectedTestCall;
        }
        fn sendStreamRetry(_: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const json_mod.ToolDefinition, _: ?*const AbortSignal, _: ?[]const u8, _: ?json_mod.ToolChoice, _: u32, _: u64, _: ?provider_mod.RetryReporter, _: []const u8) anyerror!provider_mod.StreamHandle {
            return error.UnexpectedTestCall;
        }
        fn send(ctx: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const json_mod.ToolDefinition, model_override: ?[]const u8) anyerror!provider_mod.ApiResponse {
            const st = asState(ctx);
            st.last_send_model_override = model_override;
            if (st.compact_summary_response) |body| {
                const a = st.allocator orelse return error.UnexpectedTestCall;
                return .{ .content = try a.dupe(u8, body) };
            }
            return error.UnexpectedTestCall;
        }
        fn maxTokens(ctx: *anyopaque) u32 {
            return asState(ctx).max_tokens;
        }
        fn maxInputTokens(ctx: *anyopaque) u32 {
            return asState(ctx).max_input_tokens;
        }
        fn reasoningEffort(ctx: *anyopaque) ?types.ReasoningEffort {
            return asState(ctx).reasoning_effort;
        }
        fn supports(ctx: *anyopaque, cap: provider_mod.Capability) bool {
            if (cap == .web_search) return asState(ctx).supports_web_search;
            return true;
        }
    };
    return .{
        .ctx = @ptrCast(state),
        .modelFn = F.model,
        .sendStreamFn = F.sendStream,
        .sendStreamRetryFn = F.sendStreamRetry,
        .sendFn = F.send,
        .maxTokensFn = F.maxTokens,
        .maxInputTokensFn = F.maxInputTokens,
        .reasoningEffortFn = F.reasoningEffort,
        .supportsFn = F.supports,
    };
}

test "estimateNextRequestTokens serializes the actual next Anthropic request" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "short");

    var state = TestProviderState{ .model = "base-model", .max_tokens = 777, .reasoning_effort = .medium };
    const provider = testProvider(&state);
    const tool_defs = [_]json_mod.ToolDefinition{.{
        .name = "Read",
        .description = "Read file contents",
        .input_schema = .{ .prop_specs = &.{.{ .name = "file_path", .type = "string", .description = "Path to read" }}, .required = &.{"file_path"} },
    }};
    const estimated = try estimateNextRequestTokens(
        a,
        provider,
        &c,
        "system prompt text",
        "user context text",
        "synthetic steering text",
        &tool_defs,
        "override-model",
    );

    var api = try buildApiMessages(&c, a, "user context text", "synthetic steering text");
    defer freeApiMessages(&api, a);
    const body = try json_mod.serializeMessagesRequest(.{
        .model = "override-model",
        .max_tokens = 777,
        .messages = api.items,
        .system = "system prompt text",
        .stream = true,
        .tools = &tool_defs,
        .reasoning_effort = .medium,
    }, a);
    defer a.free(body);
    try std.testing.expectEqual(Conversation.estimateTokens(body), estimated);
    try std.testing.expect(std.mem.indexOf(u8, body, "synthetic steering text") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "override-model") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output_config\":{\"effort\":\"medium\"}") != null);
}

test "usage anchor: estimate = server tokens + suffix estimate; no anchor falls back to serialize" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "question");

    var state = TestProviderState{};
    const provider = testProvider(&state);

    // 无锚点:冷路径 = 序列化全请求估算。
    const cold = try estimateNextRequestTokens(a, provider, &c, null, null, null, &.{}, null);
    try std.testing.expect(cold > 0);

    // 设锚点(模拟 message_start usage),再追加后缀。
    c.setUsageAnchor(100_000);
    try c.appendText(.assistant, "reply text");
    const anchored = try estimateNextRequestTokens(a, provider, &c, null, null, null, &.{}, null);
    var expected: usize = 100_000;
    expected += estimateMessageTokens(c.messages.items[1]);
    try std.testing.expectEqual(expected, anchored);
}

test "usage anchor suppresses false blocking-limit nuke (glm-5.2 并发工具风暴回归)" {
    // 实测场景(2026-07-06):glm-5.2 窗口 262144,一轮 20 个并发 Read。
    // 旧行为:纯字节估算 384K > blocking 239K → 全部 tool_result 未给模型看就清成
    // stub,模型拿 20 个空结果幻觉"已完成"。真实用量仅 ~15K/245K。
    // 新行为:usage 锚点(真实 in+cache)+ 后缀校准估算 → 远低于阈值,一个都不清。
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "read all 20 files");
    c.setUsageAnchor(13_522); // message_start 报的真实 prompt tokens

    // 20 个 tool_use + 20 个 32KB tool_result(toolResultContextBytes(262144) 截断后)。
    const tu_blocks = try a.alloc(msg.Block, 20);
    for (tu_blocks, 0..) |*b, i| {
        var idbuf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&idbuf, "t{d}", .{i});
        b.* = .{ .tool_use = .{
            .id = try a.dupe(u8, id),
            .name = try a.dupe(u8, "Read"),
            .input = try a.dupe(u8, "{\"file_path\":\"/tmp/data.txt\"}"),
        } };
    }
    try c.append(.{ .role = .assistant, .blocks = tu_blocks });
    const tr_blocks = try a.alloc(msg.Block, 20);
    for (tr_blocks, 0..) |*b, i| {
        var idbuf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&idbuf, "t{d}", .{i});
        const content = try a.alloc(u8, 32 * 1024);
        @memset(content, 'r');
        b.* = .{ .tool_result = .{
            .tool_use_id = try a.dupe(u8, id),
            .content = content,
            .is_error = false,
        } };
    }
    try c.append(.{ .role = .user, .blocks = tr_blocks });

    var provider_state = TestProviderState{
        .allocator = a,
        .max_input_tokens = 262_144, // metask /v1/models 实测值
        .max_tokens = 64_000,
    };
    const provider = testProvider(&provider_state);

    const Capture = struct {
        fn emit(_: *anyopaque, _: @import("session_id.zig").SessionId, _: CoreEvent) void {}
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };
    var dummy: u8 = 0;
    const backend = UiBackend{ .ctx = @ptrCast(&dummy), .emit = Capture.emit, .poll = Capture.poll };

    const outcome = try runAutoCompactIfNeeded(
        &c,
        provider,
        null,
        null,
        null,
        &.{},
        null,
        null,
        null, // 阈值走窗口公式:auto=229144
        10,
        "post_tool_follow_up_threshold",
        &backend,
        .single,
        null,
        a,
        null,
    );

    // est = 13522 + 20×(32768/4) + 信封 ≈ 178K < 229144 → 不触发;结果全部保留。
    try std.testing.expectEqual(AutoCompactOutcome.not_needed, outcome);
    for (c.messages.items[2].blocks) |b| {
        try std.testing.expect(b.tool_result.content.len == 32 * 1024); // 无一被清成 stub
    }
}

test "auto-compact preflight truncates huge recent tool_result before next request estimate" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "inspect large output");

    // 配对的 tool_use:否则 tool_result 是孤儿,P0.6 normalizeApiMessages 会剥掉它 → 巨内容不进估算。
    const tu_blocks = try a.alloc(msg.Block, 1);
    tu_blocks[0] = .{ .tool_use = .{
        .id = try a.dupe(u8, "toolu_huge"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{}"),
    } };
    try c.append(.{ .role = .assistant, .blocks = tu_blocks });

    const limit = conversation_mod.toolResultContextBytes(200_000);
    const blocks = try a.alloc(msg.Block, 1);
    const huge = try a.alloc(u8, limit * 4);
    @memset(huge, 'A');
    huge[huge.len - 1] = 'Z';
    blocks[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, "toolu_huge"),
        .content = huge,
        .is_error = false,
    } };
    try c.append(.{ .role = .user, .blocks = blocks });

    var state = TestProviderState{};
    const provider = testProvider(&state);
    const before = try estimateNextRequestTokens(a, provider, &c, null, null, null, &.{}, null);
    const reduced = c.truncateLargeToolResults(limit);
    try std.testing.expectEqual(@as(usize, 1), reduced.truncated);
    const after = try estimateNextRequestTokens(a, provider, &c, null, null, null, &.{}, null);
    try std.testing.expect(after < before);

    var api = try buildApiMessages(&c, a, null, null);
    defer freeApiMessages(&api, a);
    const body = try json_mod.serializeMessagesRequest(.{
        .model = provider.model(),
        .max_tokens = provider.maxTokens(),
        .messages = api.items,
        .stream = true,
        .tools = &.{},
    }, a);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "original_bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "toolu_huge") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Z") != null);
    try std.testing.expectEqual(Conversation.estimateTokens(body), after);
    try std.testing.expect(body.len < before);
}

test "mid-turn follow-up auto-compact emits post-tool cause and preserves tool suffix" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    // 8192 ASCII ≈ 2048 est-token/条(校准估算 ASCII/4);30 条 ≈ 61K > 32K 阈值。
    const chunk = try a.alloc(u8, 8192);
    defer a.free(chunk);
    @memset(chunk, 'x');
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        try c.appendText(.user, chunk);
    }

    const tool_use_blocks = try a.alloc(msg.Block, 1);
    tool_use_blocks[0] = .{ .tool_use = .{
        .id = try a.dupe(u8, "t1"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{\"file_path\":\"/tmp/huge\"}"),
    } };
    try c.append(.{ .role = .assistant, .blocks = tool_use_blocks });

    const tool_result_blocks = try a.alloc(msg.Block, 1);
    tool_result_blocks[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, "t1"),
        .content = try a.dupe(u8, "tool output"),
        .is_error = false,
    } };
    try c.append(.{ .role = .user, .blocks = tool_result_blocks });

    var provider_state = TestProviderState{
        .allocator = a,
        .compact_summary_response = "small summary",
        .max_input_tokens = 200_000,
        .max_tokens = 32_000,
    };
    const provider = testProvider(&provider_state);

    const Capture = struct {
        cause: ?[]const u8 = null,
        dropped: u32 = 0,
        fn emit(ctx: *anyopaque, _: @import("session_id.zig").SessionId, ev: CoreEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .auto_compact => |ac| {
                    self.cause = ac.cause;
                    self.dropped = ac.dropped;
                },
                else => {},
            }
        }
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };
    var cap = Capture{};
    const backend = UiBackend{ .ctx = @ptrCast(&cap), .emit = Capture.emit, .poll = Capture.poll };

    const before_active = c.activeMessages().len;
    const outcome = try runAutoCompactIfNeeded(
        &c,
        provider,
        null,
        null,
        null,
        &.{},
        null,
        null,
        32_000,
        2,
        "post_tool_follow_up_threshold",
        &backend,
        .single,
        null,
        a,
        null,
    );

    try std.testing.expectEqual(AutoCompactOutcome.compacted, outcome);
    try std.testing.expect(cap.dropped > 0);
    // 投影:原始消息全量保留(len 不变),收缩的是活跃窗口。
    const active = c.activeMessages();
    try std.testing.expect(active.len < before_active);
    try std.testing.expectEqualStrings("post_tool_follow_up_threshold", cap.cause.?);
    // 保住工具后缀:活跃窗口末尾仍是配对的 tool_use / tool_result(不留孤儿)。
    try std.testing.expect(active[active.len - 2].blocks[0] == .tool_use);
    try std.testing.expect(active[active.len - 1].blocks[0] == .tool_result);
}

test "auto-compact summary carries in_progress task anchor through compaction" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    const chunk = try a.alloc(u8, 8192);
    defer a.free(chunk);
    @memset(chunk, 'x');
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        try c.appendText(.user, chunk);
    }

    var store = @import("task_store.zig").TaskStore.init(a);
    defer store.deinit();
    try store.createWithId("kg-42", "修复解析器", "细节", .in_progress);
    try store.createWithId("kg-43", "已完成的不进锚", "细节", .completed);

    var provider_state = TestProviderState{
        .allocator = a,
        .compact_summary_response = "small summary",
        .max_input_tokens = 200_000,
        .max_tokens = 32_000,
    };
    const provider = testProvider(&provider_state);

    const Capture = struct {
        fn emit(_: *anyopaque, _: @import("session_id.zig").SessionId, _: CoreEvent) void {}
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };
    var dummy: u8 = 0;
    const backend = UiBackend{ .ctx = @ptrCast(&dummy), .emit = Capture.emit, .poll = Capture.poll };

    const outcome = try runAutoCompactIfNeeded(
        &c,
        provider,
        null,
        null,
        null,
        &.{},
        null,
        null,
        32_000,
        2,
        "post_tool_follow_up_threshold",
        &backend,
        .single,
        null,
        a,
        &store,
    );
    try std.testing.expectEqual(AutoCompactOutcome.compacted, outcome);

    // 投影:摘要存在 compact_summary(投影时作边界前一条 assistant 消息注入),不在 messages.items。
    // 里面必须带确定性任务锚(进行中任务 + 闭合指引),completed 不进锚。
    try std.testing.expect(c.compact_summary != null);
    const summ = c.compact_summary.?;
    try std.testing.expect(std.mem.indexOf(u8, summ, "compact 任务锚") != null);
    try std.testing.expect(std.mem.indexOf(u8, summ, "kg-42 修复解析器") != null);
    try std.testing.expect(std.mem.indexOf(u8, summ, "small summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, summ, "kg-43") == null); // completed 不进锚
}

test "previous-model compact uses old model override before smaller-window sampling" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    // 8192 ASCII ≈ 2048 est-token/条;30 条 ≈ 61K > 32K 阈值(校准估算 ASCII/4)。
    const chunk = try a.alloc(u8, 8192);
    defer a.free(chunk);
    @memset(chunk, 'p');
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        try c.appendText(.user, chunk);
    }

    var provider_state = TestProviderState{
        .model = "new-small-model",
        .allocator = a,
        .compact_summary_response = "small summary",
        .max_input_tokens = 80_000,
        .max_tokens = 32_000,
    };
    const provider = testProvider(&provider_state);

    const Capture = struct {
        cause: ?[]const u8 = null,
        fn emit(ctx: *anyopaque, _: @import("session_id.zig").SessionId, ev: CoreEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .auto_compact => |ac| self.cause = ac.cause,
                else => {},
            }
        }
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };
    var cap = Capture{};
    const backend = UiBackend{ .ctx = @ptrCast(&cap), .emit = Capture.emit, .poll = Capture.poll };

    const outcome = try runAutoCompactIfNeeded(
        &c,
        provider,
        null,
        null,
        null,
        &.{},
        null,
        "old-large-model",
        32_000,
        2,
        "pre_sampling_previous_model_smaller_window",
        &backend,
        .single,
        null,
        a,
        null,
    );

    try std.testing.expectEqual(AutoCompactOutcome.compacted, outcome);
    try std.testing.expectEqualStrings("old-large-model", provider_state.last_send_model_override.?);
    try std.testing.expectEqualStrings("pre_sampling_previous_model_smaller_window", cap.cause.?);
}

test "stream context-window recovery retries before assistant payload" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "oldest context");
    try c.appendText(.assistant, "middle context");
    try c.appendText(.user, "current request");

    const FakeStream = struct {
        allocator: std.mem.Allocator,
        attempt: u32 = 0,
        index: u32 = 0,
        rid: log.RequestId = undefined,

        fn next(ctx: *anyopaque) anyerror!?api_stream.StreamEvent {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.attempt == 0) return error.ContextWindowExceeded;
            if (self.index == 0) {
                self.index += 1;
                return api_stream.StreamEvent{ .text = try self.allocator.dupe(u8, "ok") };
            }
            return null;
        }
        fn deinit(_: *anyopaque) void {}
        fn stop(ctx: *anyopaque) api_stream.StopReason {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return if (self.attempt == 0) .unknown else .end_turn;
        }
        fn requestId(ctx: *anyopaque) log.RequestId {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.rid;
        }
    };
    const FakeProvider = struct {
        allocator: std.mem.Allocator,
        sends: u32 = 0,
        streams: [2]FakeStream = undefined,

        fn asState(ctx: *anyopaque) *@This() {
            return @ptrCast(@alignCast(ctx));
        }
        fn model(_: *anyopaque) []const u8 {
            return "fake";
        }
        fn sendStreamRetry(ctx: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const json_mod.ToolDefinition, _: ?*const AbortSignal, _: ?[]const u8, _: ?json_mod.ToolChoice, _: u32, _: u64, _: ?provider_mod.RetryReporter, _: []const u8) anyerror!provider_mod.StreamHandle {
            const st = asState(ctx);
            if (st.sends >= st.streams.len) return error.UnexpectedTestCall;
            const attempt = st.sends;
            st.streams[attempt] = .{ .allocator = st.allocator, .attempt = attempt, .rid = log.genRequestId() };
            st.sends += 1;
            return .{
                .ctx = @ptrCast(&st.streams[attempt]),
                .nextFn = FakeStream.next,
                .deinitFn = FakeStream.deinit,
                .stopReasonFn = FakeStream.stop,
                .requestIdFn = FakeStream.requestId,
            };
        }
        fn sendStream(ctx: *anyopaque, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, abort: ?*const AbortSignal, model_override: ?[]const u8, tool_choice: ?json_mod.ToolChoice, user_query: []const u8) anyerror!provider_mod.StreamHandle {
            return sendStreamRetry(ctx, messages, system, tools, abort, model_override, tool_choice, 0, 0, null, user_query);
        }
        fn send(_: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const json_mod.ToolDefinition, _: ?[]const u8) anyerror!provider_mod.ApiResponse {
            return error.UnexpectedTestCall;
        }
        fn maxTokens(_: *anyopaque) u32 {
            return 32_000;
        }
        fn maxInputTokens(_: *anyopaque) u32 {
            return 200_000;
        }
        fn reasoningEffort(_: *anyopaque) ?types.ReasoningEffort {
            return null;
        }
        fn supports(_: *anyopaque, _: provider_mod.Capability) bool {
            return false;
        }
        fn provider(self: *@This()) provider_mod.Provider {
            return .{
                .ctx = @ptrCast(self),
                .modelFn = model,
                .sendStreamFn = sendStream,
                .sendStreamRetryFn = sendStreamRetry,
                .sendFn = send,
                .maxTokensFn = maxTokens,
                .maxInputTokensFn = maxInputTokens,
                .reasoningEffortFn = reasoningEffort,
                .supportsFn = supports,
            };
        }
    };

    const Capture = struct {
        auto_compacts: u32 = 0,
        text: std.ArrayList(u8) = .empty,
        allocator: std.mem.Allocator,
        fn emit(ctx: *anyopaque, _: @import("session_id.zig").SessionId, ev: CoreEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .auto_compact => self.auto_compacts += 1,
                .text_chunk => |t| self.text.appendSlice(self.allocator, t) catch {},
                else => {},
            }
        }
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };

    var fp = FakeProvider{ .allocator = a };
    var cap = Capture{ .allocator = a };
    defer cap.text.deinit(a);
    const backend = UiBackend{ .ctx = @ptrCast(&cap), .emit = Capture.emit, .poll = Capture.poll };
    const perm = permission_mod.createContext(.bypass_permissions, a);
    const result = try run(&c, fp.provider(), &.{}, &perm, .{ .max_turns = 2, .colorize = false }, &backend, a);

    try std.testing.expectEqual(StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 2), fp.sends);
    try std.testing.expectEqual(@as(u32, 1), cap.auto_compacts);
    try std.testing.expectEqualStrings("ok", cap.text.items);
    // 投影:context-window recovery 推进 boundary 丢 "oldest context",不删原始。
    // 全量 = [oldest, middle, current, ok(assistant 回复)];活跃窗口从 middle 起。
    try std.testing.expectEqual(@as(usize, 4), c.len());
    try std.testing.expectEqual(@as(usize, 1), c.activeStart());
    const active = c.activeMessages();
    try std.testing.expectEqualStrings("middle context", active[0].blocks[0].text);
    try std.testing.expectEqualStrings("current request", active[1].blocks[0].text);
    // 被投影掉的 oldest 仍原样保留在头部(供 transcript/resume)。
    try std.testing.expectEqualStrings("oldest context", c.messages.items[0].blocks[0].text);
}

test "ZeroGainTracker:同 sig 同 result 达 MAX 打转;分页/结果变化不误触发" {
    const a = std.testing.allocator;
    // 同 sig 同 result 累计:第 MAX_ZERO_GAIN_REPEAT(3)次才打转。
    {
        var z = ZeroGainTracker.init(a);
        defer z.deinit();
        try std.testing.expect(!z.tripped(1, 100)); // count=1
        try std.testing.expect(!z.tripped(1, 100)); // count=2
        try std.testing.expect(z.tripped(1, 100)); // count=3 → 打转
    }
    // 分页:不同 sig(offset 递进 → 不同 hash)各自独立,永不触发。
    {
        var z = ZeroGainTracker.init(a);
        defer z.deinit();
        try std.testing.expect(!z.tripped(10, 200));
        try std.testing.expect(!z.tripped(11, 201));
        try std.testing.expect(!z.tripped(12, 202));
        try std.testing.expect(!z.tripped(13, 203));
    }
    // 结果变化:同 sig 但 result_hash 每次变(如 git status 状态变)→ 每次重置,不误杀 re-check。
    {
        var z = ZeroGainTracker.init(a);
        defer z.deinit();
        try std.testing.expect(!z.tripped(5, 10));
        try std.testing.expect(!z.tripped(5, 20)); // result 变 → reset count=1
        try std.testing.expect(!z.tripped(5, 30)); // 又变 → reset,不触发
    }
}

test "context warning emits once only at medium pressure" {
    const Capture = struct {
        warnings: u32 = 0,
        level: ?[]const u8 = null,
        current_tokens: u64 = 0,
        fn emit(ctx: *anyopaque, _: @import("session_id.zig").SessionId, ev: CoreEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .context_warning => |w| {
                    self.warnings += 1;
                    self.level = w.level;
                    self.current_tokens = w.current_tokens;
                },
                else => {},
            }
        }
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };
    var cap = Capture{};
    const backend = UiBackend{ .ctx = @ptrCast(&cap), .emit = Capture.emit, .poll = Capture.poll };
    var emitted = false;

    emitContextWarningIfNeeded(&backend, .single, context_pressure_mod.ContextPressure.fromModel(200_000, 32_000, null, 147_999), &emitted);
    try std.testing.expectEqual(@as(u32, 0), cap.warnings);
    try std.testing.expect(!emitted);

    emitContextWarningIfNeeded(&backend, .single, context_pressure_mod.ContextPressure.fromModel(200_000, 32_000, null, 148_000), &emitted);
    try std.testing.expectEqual(@as(u32, 1), cap.warnings);
    try std.testing.expect(emitted);
    try std.testing.expectEqualStrings("medium", cap.level.?);
    try std.testing.expectEqual(@as(u64, 148_000), cap.current_tokens);

    emitContextWarningIfNeeded(&backend, .single, context_pressure_mod.ContextPressure.fromModel(200_000, 32_000, null, 152_000), &emitted);
    try std.testing.expectEqual(@as(u32, 1), cap.warnings);

    emitted = false;
    emitContextWarningIfNeeded(&backend, .single, context_pressure_mod.ContextPressure.fromModel(200_000, 32_000, null, 155_000), &emitted);
    try std.testing.expectEqual(@as(u32, 1), cap.warnings);
    try std.testing.expect(!emitted);
}

test "compactHasMinSavings requires at least five percent reduction" {
    try std.testing.expect(compactHasMinSavings(1000, 949)); // 5.1%
    try std.testing.expect(compactHasMinSavings(1000, 950)); // exactly 5%
    try std.testing.expect(!compactHasMinSavings(1000, 951));
    try std.testing.expect(!compactHasMinSavings(1000, 1000));
    try std.testing.expect(!compactHasMinSavings(0, 0));
    try std.testing.expectEqual(@as(usize, 5), compactSavedPercent(1000, 950));
    try std.testing.expectEqual(@as(usize, 0), compactSavedPercent(1000, 1000));
}

test "auto-compact preflight keeps serialized request valid UTF-8 after multibyte truncation" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    const limit = conversation_mod.toolResultContextBytes(0);
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(a);
    while (payload.items.len < limit * 3) {
        try payload.appendSlice(a, "路径/中文/🙂/");
    }

    // 配对 tool_use:否则 tool_result 是孤儿,normalizeApiMessages 会剥掉 → body 里就没有它。
    const tu_blocks = try a.alloc(msg.Block, 1);
    tu_blocks[0] = .{ .tool_use = .{
        .id = try a.dupe(u8, "toolu_utf8"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{}"),
    } };
    try c.append(.{ .role = .assistant, .blocks = tu_blocks });

    const blocks = try a.alloc(msg.Block, 1);
    blocks[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, "toolu_utf8"),
        .content = try a.dupe(u8, payload.items),
        .is_error = false,
    } };
    try c.append(.{ .role = .user, .blocks = blocks });

    const reduced = c.truncateLargeToolResults(limit);
    try std.testing.expectEqual(@as(usize, 1), reduced.truncated);
    try std.testing.expect(std.unicode.utf8ValidateSlice(c.messages.items[1].blocks[0].tool_result.content));

    var state = TestProviderState{};
    const provider = testProvider(&state);
    var api = try buildApiMessages(&c, a, null, null);
    defer freeApiMessages(&api, a);
    const body = try json_mod.serializeMessagesRequest(.{
        .model = provider.model(),
        .max_tokens = provider.maxTokens(),
        .messages = api.items,
        .stream = true,
        .tools = &.{},
    }, a);
    defer a.free(body);
    try std.testing.expect(std.unicode.utf8ValidateSlice(body));
    try std.testing.expect(std.mem.indexOf(u8, body, "original_bytes") != null);
}

test "buildEffectiveToolSet hides unactivated deferred tools for compact estimate" {
    const a = std.testing.allocator;
    const tool_defs = [_]json_mod.ToolDefinition{
        .{
            .name = "Read",
            .description = "Read file contents",
            .input_schema = .{ .prop_specs = &.{.{ .name = "file_path", .type = "string" }}, .required = &.{"file_path"} },
        },
        .{
            .name = "DeferredHuge",
            .description = "This deferred schema should not affect the next request estimate until activated.",
            .input_schema = .{ .prop_specs = &.{.{ .name = "payload", .type = "string", .description = "large hidden payload" }}, .required = &.{"payload"} },
            .deferred = true,
        },
    };
    var activated = std.StringHashMap(void).init(a);
    defer activated.deinit();
    var permission_ctx = permission_mod.PermissionContext{ .allocator = a };
    var state = TestProviderState{};
    var effective = buildEffectiveToolSet(a, &tool_defs, &permission_ctx, &activated, testProvider(&state));
    defer effective.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), effective.defs.len);
    try std.testing.expectEqualStrings("Read", effective.defs[0].name);
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
    // 压缩、丢掉原始问题。修复:改用 input context window(~200K)扣 output reserve 后的 CC/Rust 阈值。
    // 源级守卫:阈值算式必须调 resolveMaxInputTokens(而非 output 的解析器),且 MIN 不再是早期小值。
    const src = @embedFile("agent_loop.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "ContextPressure.fromModel(provider.maxInputTokens(), provider.maxTokens()") != null);
    // 全额输出预留(服务端校验 in+max_tokens ≤ window):200K-32K-13K = 155K。
    try std.testing.expectEqual(@as(usize, 155_000), context_pressure_mod.ContextPressure.fromModel(200_000, 32_000, null, 0).auto_compact_threshold);
    try std.testing.expect(MIN_AUTO_COMPACT_THRESHOLD >= 32_000);
}

test "parseForcedAutoCompactThreshold: 合法强制值 + 坏值回退 null" {
    // 合法:e2e 用它在短对话直接钉低阈值触发真实压缩+投影。
    try std.testing.expectEqual(@as(?usize, 3000), parseForcedAutoCompactThreshold("3000"));
    // 空 / 0 / 非法 → null(坏 env 绝不改压缩行为)。
    try std.testing.expectEqual(@as(?usize, null), parseForcedAutoCompactThreshold(""));
    try std.testing.expectEqual(@as(?usize, null), parseForcedAutoCompactThreshold("0"));
    try std.testing.expectEqual(@as(?usize, null), parseForcedAutoCompactThreshold("garbage"));
    // 无 env 时 getenv 返回 null → 走正常 formula+floor(wiring 由真模型 e2e 验证)。
}
