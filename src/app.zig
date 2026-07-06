//! App 应用生命周期：持有所有顶层组件（Config, Conversation, Client, ToolDefs, Permission, AbortSignal）。
//!
//! 目的：让 main.zig 只负责参数解析 + 启动 App。所有业务状态和循环逻辑从 main.zig 下沉到
//! 此模块 + core/agent_loop.zig。
//!
//! M1.5 起加入 AbortSignal + SIGINT 绑定。signal handler 只做 atomic store，async-signal-safe。

const std = @import("std");
const types = @import("types.zig");
const client_mod = @import("client.zig");
const api_keys_mod = @import("api/api_keys.zig");
const openai_mod = @import("api/openai_client.zig");
const gemini_mod = @import("api/gemini_client.zig");
const provider_mod = @import("api/provider.zig");
const json_mod = @import("json.zig");
const tools_mod = @import("tools.zig");
const permission_mod = @import("permission.zig");
const Conversation = @import("core/conversation.zig").Conversation;
const AbortSignal = @import("util/abort.zig").AbortSignal;
const SkillSet = @import("skills/skill.zig").SkillSet;
const ReadState = @import("core/read_state.zig").ReadState;
const transcript = @import("core/transcript.zig");
const pricing = @import("util/pricing.zig");
const agent_loop = @import("core/agent_loop.zig");
const api_stream = @import("api/stream.zig");
const JobRegistry = @import("core/job_registry.zig").JobRegistry;
const TaskStore = @import("core/task_store.zig").TaskStore;
const system_prompt_mod = @import("core/system_prompt.zig");
const DynRegistry = @import("tools/dynamic.zig").DynRegistry;
const skill_tool_mod = @import("skills/tool.zig");
const McpClient = @import("mcp/client.zig").McpClient;
const McpSession = @import("mcp/registry_bridge.zig").McpSession;
const ActiveSkillState = @import("skills/active.zig").ActiveSkillState;
const AgentSet = @import("agents/set.zig").AgentSet;
const WorktreeEntry = @import("tools/worktree.zig").WorktreeEntry;
const CronRegistry = @import("core/cron_registry.zig").CronRegistry;
const GoalState = @import("core/goal.zig").State;

/// 跨 turn 累加的 token 计数。L1:类型下沉到 core/usage.zig(usage 走 CoreEvent 总线后
/// 需 core 可引用);app 只 re-export,行为不变(app.usage / costUsd / 各 UI 读法照旧)。
pub const UsageTotals = @import("core/usage.zig").UsageTotals;

/// 全局 AbortSignal 指针，供 signal handler 访问。installSigintHandler 绑定后非 null。
/// signal handler 只读该指针 + 调 abort.abort()——不分配、不 IO、不获锁。
/// **多 Session 说明**:这是唯一剩的进程全局,但**不是**多 session 缺陷——SIGINT 是进程级
/// 单一信号,只服务前台 TUI(N=1)会话。多 session(GUI)经每个会话的 per-instance
/// app.abort.abort() 直接中断,旁路 SIGINT。故无需做成 per-session 路由表。
var g_abort_signal: ?*AbortSignal = null;

/// 一个已连接 MCP server 的资源捆绑：name（owned）+ heap-allocated client + session。
/// session 内的 binding 指针指向同一个 client；client 必须比 session 活得久。
pub const McpSessionEntry = @import("core/mcp_session.zig").McpSessionEntry;

pub const App = struct {
    allocator: std.mem.Allocator,
    config: types.Config,
    api_key: []const u8,
    oauth_token_for_catalog: ?[]u8 = null,
    selected_api_key_owned: ?[]u8 = null,
    api_key_catalog: api_keys_mod.Catalog,
    models_picker_key_index: ?usize = null,
    models_picker_model_index: ?usize = null,
    model_switch_owned: ?[]u8 = null,
    pending_previous_model_for_compact: ?[]u8 = null,
    pending_previous_model_context_window: ?u32 = null,
    pending_current_model_context_window: ?u32 = null,
    // ── 会话身份(M6)──────────────────────────────────────────────────────
    /// 本 App 实例的会话标识。**cc-zig 的多 Session 模型 = 多个 App 实例,各为一个
    /// SessionContext(见下分区注释),共享一个进程。**
    /// **现状是 multi-session-READY,不是 DONE**:当前仍是一进程一 App 一 session
    /// (main 只 create 一个 App,无 sessions HashMap,无多线程跑多 run())。M1-M6 移除了
    /// 多 session 的**前提障碍**(清掉会串台的进程全局 permission/progress/ui-runner,给 App
    /// 身份 + session 路由通了),使"未来加 sessions map + 起多线程跑多个 App"成为可能;
    /// 但 M6 本身没有第二个 session 在跑。剩 g_abort_signal 待 M7 路由。
    /// session_id 用于把本会话的 emit/UiRequest 路由到对应 UI 视图。init 时 gen() 一个。
    /// **TODO**:本 id 与 transcript 目录名 id 是两个独立 gen(),将来应统一(App 生成、transcript 复用)。
    session_id: @import("core/session_id.zig").SessionId = @import("core/session_id.zig").SessionId.single,

    // ── ProcessContainer 区(进程级,逻辑上只读)──────────────────────────────
    // config / api_key / api_client / tool_defs / enabled_tool_names / skills / agents /
    // dyn_registry / settings / sandbox_settings / hooks / rule_set / theme*。
    // 逻辑上只读配置/能力。**当前每 App 各持一份**(各自 Client/SkillSet…)。真多 session 时,
    // tool_defs/skills/agents 可提取到共享 ProcessContainer(只读,省内存);**api_client 建议保持
    // per-session**(避免共享 http 连接的线程竞争,同 agent_job_registry 每 job 一个 Client)。
    // 这是 GUI 集成时的优化,非 M6 的活——此处仅画线,非已实现的物理共享。
    //
    // ── SessionContext 区(每会话独立可变;就是"一个 App = 一个 session"的本体)────
    // conversation / read_state / edit_hl_cache / jobs / agent_jobs / tasks / cron_registry /
    // mcp_sessions / worktree_stack / abort / permission_ctx / session_rules / plan_prev_mode /
    // plan_file_path / usage / transcript_writer / activated_tools / active_skill /
    // cwd_abs / project_dir / system_prompt。
    // 这些是会话状态,每 App 实例独立 = 天然 per-session 隔离。
    // **注:此分区是注释级"地图"(未来真拆分的指引),非编译器 enforced 边界——
    //   加字段时自觉归对区。真拆 struct 时才需 enforcement。**
    conversation: Conversation,
    api_client: client_mod.Client,
    /// OpenAI 后端(config.provider_kind==.openai 时非 null)。与 api_client 二选一:
    /// provider() 据 config.provider_kind 选哪个的 .provider()。**core/UI 只见 App.provider()
    /// 返回的中立 Provider,不知道背后是哪家**(多 Provider 重构 P3 组装层)。
    openai_client: ?openai_mod.OpenAIClient = null,
    /// Gemini 后端(config.provider_kind==.gemini 时非 null)。持有状态缓存句柄表(C3)。
    gemini_client: ?gemini_mod.GeminiClient = null,
    tool_defs: []json_mod.ToolDefinition,
    /// 当前启用的工具名（含动态 Skill/MCP）。用于 system prompt 的 # Using your tools
    /// 段按工具集裁剪 + 构造 PromptContext。生命周期随 arena。
    enabled_tool_names: []const []const u8 = &.{},
    permission_ctx: permission_mod.PermissionContext,
    /// Session 级权限记忆(always-allow / session-deny)。挂到 permission_ctx.session_rules。
    /// 每 App(= 每 session)一份;多 Session 化后随 SessionContext 走,不再进程全局。
    session_rules: @import("permission/session_rules.zig").SessionRules = .{},
    abort: AbortSignal,
    /// Ctrl+B 转后台请求信号(地址稳定:watcher 线程 store、agent_loop turn 边界 load)。
    /// 与 abort 分开:abort=用户中断(对话留前台),background=主对话转后台续跑。
    background_request: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    skills: SkillSet,
    read_state: ReadState,
    /// Edit/Write 旁路高亮缓存(tool_id → 新旧全文)。供 diff 工具卡 tree-sitter 着色;
    /// 不进对话历史。session 退出 deinit。
    edit_hl_cache: @import("core/edit_hl_cache.zig").EditHlCache,
    /// Session transcript writer；失败初始化则保持 null（日志落盘 fallback）
    transcript_writer: ?transcript.Writer = null,
    /// 本 session 累计用量（跨多 turn）
    usage: UsageTotals = .{},
    /// 从 config.json 加载的细粒度权限规则；null 时仅靠四模式兜底
    rule_set: ?permission_mod.RuleSet = null,
    /// 5 层 settings 聚合(allow/ask/deny + additionalDirectories + disable flags)。
    /// 启动时 loader.load;挂到 permission_ctx.settings。
    settings: ?permission_mod.MergedSettings = null,
    /// Sandbox 配置(从 settings 的 sandbox 段解析,跨层合并)。
    sandbox_settings: ?@import("sandbox/config.zig").SandboxSettings = null,
    /// PreToolUse hooks(从 settings.hooks.PreToolUse 解析)。
    hooks: ?@import("permission/hooks.zig").HookSet = null,
    /// 缓存的 cwd 绝对路径(供 permission match_ctx 用,session 期不变)。
    cwd_abs: ?[]u8 = null,
    /// 当前 TUI 主题(启动时根据 --no-theme + ColorCapability 选;/theme 可改)。
    theme: @import("repl/tui/theme.zig").Theme = @import("repl/tui/theme.zig").dark,
    /// 当前主题 variant(/theme 命令读它显示当前)。
    theme_variant: @import("repl/tui/theme.zig").Variant = .auto,
    /// 后台 Bash 作业注册表（失败初始化则 null）
    jobs: ?JobRegistry = null,
    /// 后台 subagent 作业注册表（Task run_in_background）。失败初始化则 null。
    agent_jobs: ?@import("core/agent_job_registry.zig").AgentJobRegistry = null,
    /// 进入 plan 模式前的原 mode；ExitPlanMode 用它恢复
    plan_prev_mode: ?types.PermissionMode = null,
    /// 当前 session 的 plan 文件全路径(`{home}/.cc-zig/plans/{slug}.md`,owned)。
    /// init 时算一次,挂到 permission_ctx.plan_file_path(plan 模式特许写)+ ToolContext。
    /// 空串 = home 缺失,plan 文件机制降级(模型把计划写对话文本)。
    plan_file_path: []u8 = &.{},
    /// 本 session 的 memdir 绝对路径(通道 B 自动记忆;`{home}/.cc-zig/projects/<hash>/memory`,
    /// owned)。init 时算一次,挂 permission_ctx.memdir_abs(写豁免)。空串=禁用/无 home。
    memdir_abs: []u8 = &.{},
    /// 模型长任务 scratchpad（Task* 工具共享）
    tasks: TaskStore,
    /// Session-scoped objective state for /goal and /loop.
    goal_state: GoalState,
    /// User-controlled automatic continuation. /loop on sets enabled + remaining budget;
    /// the REPL starts continuations only from idle boundaries via agent_loop.run().
    loop_enabled: bool = false,
    loop_remaining: u32 = 0,
    /// 预构造的 system prompt（app 启动时一次性 build）。null = build 失败时降级为无 prompt。
    system_prompt: ?[]u8 = null,
    /// 首条 user-context message(CLAUDE.md 链 + AutoMem + currentDate,`<system-reminder>` 包裹)。
    /// init 时构建一次(memoize),agent_loop 每轮 prepend。owned;deinit free。
    /// null = 无记忆内容 / CLAUDE_CODE_DISABLE_CLAUDE_MDS。
    user_context: ?[]u8 = null,
    /// 运行时工具表（Skill + MCP 工具都注册到这里）。
    dyn_registry: DynRegistry,
    /// 已连接的 MCP server。每个 owns 一个 McpClient + McpSession（一一对应）。
    /// 退出时 deinit 反向关闭：先 session（释放 binding 内存）再 client（关 transport）。
    mcp_sessions: std.ArrayList(McpSessionEntry),
    /// 当前激活的 skill 状态(allowed/disallowed 临时白黑名单)。
    /// 激活 Skill 工具时设;loop.zig 处理下条 user message 前清。
    active_skill: ?ActiveSkillState = null,
    /// ToolSearch 激活的 deferred 工具名集(会话级,只增不减)。每轮 agent_loop 据此把
    /// deferred 工具放回 tools 数组。owns the duped name keys。
    activated_tools: std.StringHashMap(void),
    /// 启动时缓存的 project root(沿 cwd 向上找 .git);null = 不在 git repo。
    /// 供 ${CLAUDE_PROJECT_DIR} 替换用。
    project_dir: ?[]u8 = null,
    /// 已加载的 subagent 定义集合(builtin + personal + project)。
    agents: AgentSet,
    /// 当前进入的 worktree 栈(支持嵌套)。EnterWorktree push,ExitWorktree pop。
    worktree_stack: std.ArrayList(WorktreeEntry),
    /// Session 级 cron 调度。CronCreate/Delete/List 用;REPL 读 prompt 前 collectDue。
    cron_registry: CronRegistry,
    /// 模型上下文窗口表(~/.metacode/models.toml)。api_client.model_context 借用它做 auto-compact 阈值。
    model_context: @import("app/model_context.zig").ModelContext,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: types.Config,
        api_key: []const u8,
    ) !*App {
        const app = try allocator.create(App);
        errdefer allocator.destroy(app);

        // 顺序：先把 conversation/skills/jobs/tasks/abort 等"空壳"放好,
        // 然后注册动态工具（Skill 需要 &app.skills 指针）,
        // 最后 toToolDefinitionsWithDyn 一次性构造给 API 的 tool 清单。
        app.* = .{
            .allocator = allocator,
            .config = config,
            .api_key = api_key,
            .api_key_catalog = api_keys_mod.Catalog.init(allocator),
            .session_id = @import("core/session_id.zig").gen(), // 本会话身份(路由用)
            .conversation = Conversation.init(allocator),
            .api_client = client_mod.Client.initWithBaseUrl(allocator, io, api_key, config.model, config.base_url),
            .tool_defs = &.{}, // 占位，下面重建
            .permission_ctx = permission_mod.createContext(config.permission_mode, allocator),
            .abort = AbortSignal.init(),
            .skills = SkillSet.init(allocator),
            .activated_tools = std.StringHashMap(void).init(allocator),
            .read_state = ReadState.init(allocator),
            .edit_hl_cache = @import("core/edit_hl_cache.zig").EditHlCache.init(allocator),
            .tasks = TaskStore.init(allocator),
            .goal_state = GoalState.init(allocator),
            .loop_enabled = false,
            .loop_remaining = 0,
            .dyn_registry = DynRegistry.init(allocator),
            .mcp_sessions = .empty,
            .agents = AgentSet.init(allocator),
            .worktree_stack = .empty,
            .cron_registry = CronRegistry.init(allocator),
            .model_context = @import("app/model_context.zig").ModelContext.init(allocator),
        };

        // OpenAI 后端:仅当 provider_kind==.openai 才建(讲 chat/completions 协议)。
        // base_url 复用 config.base_url(record/replay 指 MockServer);null → OpenAI 官方端点。
        if (config.provider_kind == .openai) {
            app.openai_client = openai_mod.OpenAIClient.init(allocator, io, api_key, config.model, config.base_url);
        }
        // Gemini 后端:仅当 provider_kind==.gemini 才建(讲 generateContent 协议 + 有状态缓存)。
        if (config.provider_kind == .gemini) {
            app.gemini_client = gemini_mod.GeminiClient.init(allocator, io, api_key, config.model, config.base_url);
        }

        // 启动时加载 skills:enterprise / ~/.cc-zig / ~/.claude / project chain。
        // 沿 cwd 向上找 .git 定位 project root,沿途每级 .cc-zig/skills 都加载。
        const cwd_for_skills = @import("util/fs.zig").getCwd(allocator) catch null;
        defer if (cwd_for_skills) |c| allocator.free(c);
        app.skills.loadFromStandardPaths(cwd_for_skills orelse "") catch {};
        // 加载 subagent 定义(builtin 三个 + personal + project)
        app.agents.loadFromStandardPaths(cwd_for_skills orelse "") catch {};
        // 缓存 project root(供 ${CLAUDE_PROJECT_DIR} 替换)
        if (cwd_for_skills) |cwd| {
            app.project_dir = @import("skills/skill.zig").findRepoRoot(allocator, cwd) catch null;
            app.cwd_abs = allocator.dupe(u8, cwd) catch null;
        }

        // 选 TUI 主题:--no-theme → monochrome;否则用 .auto + 终端能力检测
        const theme_mod = @import("repl/tui/theme.zig");
        const tui_term = @import("repl/tui/term.zig");
        const tui_config = @import("repl/tui/config.zig");
        const cap = tui_term.detectFromEnv(1);
        if (config.no_theme) {
            app.theme_variant = .monochrome;
        } else {
            // ~/.cc-zig/config.json 的 theme 字段覆盖默认 auto
            const home_for_theme: ?[]const u8 = blk: {
                const h = std.c.getenv("HOME") orelse break :blk null;
                break :blk std.mem.span(h);
            };
            const persisted = if (home_for_theme) |h| tui_config.loadTheme(allocator, h) else null;
            app.theme_variant = persisted orelse .auto;
        }
        // variant=.auto 且支持颜色:探测终端背景色自动选 dark/light(仿 mecode)。
        // 跳过条件:已显式持久化具体 variant(用户优先)、能力 none、NO_PROBE、非 tty。
        if (app.theme_variant == .auto and cap != .none and std.c.getenv("METACODES_NO_PROBE") == null) {
            const bg_probe = @import("repl/tui/bg_probe.zig");
            if (bg_probe.probeBackground(1)) |bg| {
                app.theme_variant = if (bg_probe.isLight(bg)) .light else .dark;
            }
        }
        app.theme = theme_mod.select(app.theme_variant, cap);

        // Session 级权限记忆挂到 permission_ctx(persist 路径复用 match_ctx.home/project_root,
        // 在 settings 加载处统一设,无需独立 persist context)。
        app.permission_ctx.session_rules = &app.session_rules;
        app.permission_ctx.session = app.session_id; // 权限对话框路由到本会话视图(M5/M6)

        // 注册 Skill 工具到 dyn_registry（ctx_ptr 指向 SkillSet）。
        // 失败仅 log——skills 仍可通过 /skills 列表，只是模型激活不了。
        skill_tool_mod.registerSkillTool(&app.dyn_registry, &app.skills) catch |err| {
            @import("util/log.zig").warn("skill", "register Skill tool failed: {s}", .{@errorName(err)});
        };

        // 启动时尝试连接 config.json 里声明的 MCP servers。失败逐个 log，不影响启动。
        app.connectMcpServers() catch |err| {
            @import("util/log.zig").debug("mcp", "no servers connected: {s}", .{@errorName(err)});
        };

        // 现在构造完整的 tool_defs：静态 + 动态（Skill / MCP）+ web_search。
        // 先构造一次拿到全部工具名（含动态），据此建 PromptContext，再带 context 重建——
        // 让核心工具拿到动态长描述（对应 cc tool.prompt(ctx)）。
        // arena allocator：第一次的临时 defs 随 session 释放，不单独 free。
        const probe_defs = try tools_mod.toToolDefinitionsWithDyn(allocator, &app.dyn_registry);
        const enabled_names = try allocator.alloc([]const u8, probe_defs.len);
        for (probe_defs, 0..) |d, i| enabled_names[i] = d.name;
        app.enabled_tool_names = enabled_names;

        const prompt_ctx = tools_mod.PromptContext{
            .permission_mode = config.permission_mode,
            .enabled_tool_names = enabled_names,
            .agent_type = "", // 主对话
            .include_git = true,
        };
        app.tool_defs = try tools_mod.toToolDefinitionsFull(allocator, &app.dyn_registry, &prompt_ctx);
        errdefer allocator.free(app.tool_defs);

        // 加载模型上下文窗口表(~/.metacode/models.toml)并挂到 client。
        // precedence 高于 probe → auto-compact 阈值优先用此表(offline 可靠 + 用户可编辑)。
        app.model_context.loadOrBundle();
        app.api_client.model_context = &app.model_context;

        // 探测 <base_url>/v1/models 取 model catalog（max_tokens）。失败静默，走本地 fallback。
        // METACODES_NO_PROBE=1 跳过：离线/沙箱/TTY 测试下 probeModels 的网络调用会 hang,
        // 跳过让 REPL 立即可用(走本地 model 单价表)。
        // **仅 anthropic 模式 probe**:probeModels 打 Anthropic 的 /v1/models,openai 模式下
        // api_client 是死资源、且其 base_url 指向 Anthropic 端点——probe 它=对错端点发真请求
        // (用真 key),必须跳过。openai 的 context_window 走 OpenAIClient 自己的硬编码值。
        if (config.provider_kind == .anthropic) {
            if (std.c.getenv("METACODES_NO_PROBE") == null) {
                app.oauth_token_for_catalog = @import("core/auth.zig").resolveStoredOAuthBearer(allocator) catch null;
                app.probeApiKeys();
                app.api_client.probeModels();
            } else {
                @import("util/log.zig").debug("catalog", "probeModels skipped (METACODES_NO_PROBE)", .{});
            }
            // CLI --max-tokens 覆盖(仅作用于 anthropic api_client)
            app.api_client.setMaxTokensOverride(config.max_tokens);
            app.api_client.reasoning_effort = config.reasoning_effort;
        } else {
            @import("util/log.zig").debug("catalog", "probeModels skipped (provider={s})", .{@tagName(config.provider_kind)});
        }

        // 初始化 transcript writer：需要 cwd + HOME
        app.initTranscriptWriter() catch |err| {
            @import("util/log.zig").warn("transcript", "init failed: {s} (session will not persist)", .{@errorName(err)});
        };

        // 计算本 session 的 plan 文件路径(plan 模式下模型把计划写这里;唯一可写)。
        // slug seed 优先用 transcript session id(每 session 稳定),否则时间兜底。
        app.initPlanFilePath();

        // 计算本 session 的 memdir 路径(通道 B 自动记忆)+ mkdir + 挂权限豁免。
        app.initMemdir();

        // 从 config.json 加载 permission_rules（旧 schema，向后兼容）
        app.loadPermissionRules() catch |err| {
            @import("util/log.zig").debug("permission", "no rules loaded: {s}", .{@errorName(err)});
        };

        // 加载 5 层 settings（新 schema permissions.allow/ask/deny）并挂到 permission_ctx
        app.loadSettings() catch |err| {
            @import("util/log.zig").debug("permission", "no settings loaded: {s}", .{@errorName(err)});
        };

        // 初始化 job registry
        app.jobs = JobRegistry.init(allocator) catch |err| blk: {
            @import("util/log.zig").warn("job", "registry init failed: {s}", .{@errorName(err)});
            break :blk null;
        };

        // 初始化后台 subagent registry（Task run_in_background）。每个 job 内部自建
        // 专属 Client（指向同 endpoint），故这里只需 api_key/base_url/model。
        app.agent_jobs = @import("core/agent_job_registry.zig").AgentJobRegistry.init(allocator, app.api_key, config.base_url, app.config.model) catch |err| blk: {
            @import("util/log.zig").warn("agent", "agent_jobs registry init failed: {s}", .{@errorName(err)});
            break :blk null;
        };

        // 构造 system prompt（依赖 config.model）。# Using your tools 段按 enabled_tool_names
        // 动态裁剪（对应 cc getUsingYourToolsSection(enabledTools)）。失败仅 log，保持 null。
        app.system_prompt = system_prompt_mod.buildFull(allocator, app.config.model, &app.skills, &app.agents, app.enabled_tool_names, app.memdir_abs) catch |err| blk: {
            @import("util/log.zig").warn("sysprompt", "build failed: {s} (continuing without system prompt)", .{@errorName(err)});
            break :blk null;
        };

        // 构造首条 user-context message(通道 A:CLAUDE.md 链 + currentDate,system-reminder 包裹)。
        // 向上递归从 cwd 收集 CLAUDE.md;User 级读 ~/.claude/CLAUDE.md。失败仅 log,保持 null。
        // 通道 B(AutoMem):读 memdir 的 MEMORY.md 索引(已截断)拼进同一 user message。
        const auto_mem: []u8 = blk: {
            if (app.memdir_abs.len == 0) break :blk &.{};
            const memdir = @import("core/memory/memdir.zig");
            const idx = memdir.readIndexTruncated(allocator, app.homeDir(), app.cwdAbs()) catch null;
            break :blk (idx orelse &.{});
        };
        defer if (auto_mem.len > 0) allocator.free(auto_mem);
        app.user_context = @import("core/memory/user_context.zig").build(allocator, .{
            .cwd = app.cwdAbs(),
            .home = app.homeDir(),
            .auto_mem = auto_mem,
        }) catch |err| blk: {
            @import("util/log.zig").warn("memory", "user_context build failed: {s}", .{@errorName(err)});
            break :blk null;
        };

        return app;
    }

    /// 组装层选 Provider:据 config.provider_kind 返回对应后端的中立 Provider。
    /// **这是整个多 Provider 重构里唯一 if(provider) 的地方**——core(agent_loop)/UI 只调
    /// `app.provider()` 拿中立 Provider,完全不知道背后是 Anthropic 还是 OpenAI。
    pub fn provider(app: *App) provider_mod.Provider {
        return switch (app.config.provider_kind) {
            .anthropic => app.api_client.provider(),
            .openai => app.openai_client.?.provider(),
            .gemini => app.gemini_client.?.provider(),
        };
    }

    pub fn deinit(app: *App) void {
        // 最先 drain 后台 subagent：abort 全部 running → join 全部线程 → free。
        // 必须早于任何共享资源（agents/dyn_registry/skills/allocator）释放，
        // 否则在跑的后台线程会触碰已释放内存（UAF）。job 用专属 Client，不依赖 api_client。
        if (app.agent_jobs) |*aj| aj.deinit();
        if (app.transcript_writer) |*w| w.deinit();
        app.api_client.deinit();
        if (app.oauth_token_for_catalog) |tok| {
            @memset(tok, 0);
            app.allocator.free(tok);
        }
        app.api_key_catalog.deinit();
        if (app.selected_api_key_owned) |k| {
            @memset(k, 0);
            app.allocator.free(k);
        }
        if (app.model_switch_owned) |m| app.allocator.free(m);
        if (app.pending_previous_model_for_compact) |m| app.allocator.free(m);
        if (app.openai_client) |*oc| oc.deinit();
        if (app.gemini_client) |*gc| gc.deinit();
        app.conversation.deinit();
        app.allocator.free(app.tool_defs);
        app.skills.deinit();
        app.read_state.deinit();
        app.edit_hl_cache.deinit();
        app.tasks.deinit();
        app.goal_state.deinit();
        // MCP：先 session（释放 binding 内存）再 client（关 transport + reap 子进程）
        for (app.mcp_sessions.items) |*entry| {
            entry.session.deinit();
            entry.client.close();
            app.allocator.destroy(entry.client);
            app.allocator.free(entry.name);
        }
        app.mcp_sessions.deinit(app.allocator);
        app.dyn_registry.deinit();
        if (app.active_skill) |*as| as.deinit();
        {
            var it = app.activated_tools.keyIterator();
            while (it.next()) |k| app.allocator.free(k.*);
            app.activated_tools.deinit();
        }
        if (app.project_dir) |p| app.allocator.free(p);
        if (app.plan_file_path.len > 0) app.allocator.free(app.plan_file_path);
        if (app.memdir_abs.len > 0) app.allocator.free(app.memdir_abs);
        app.agents.deinit();
        for (app.worktree_stack.items) |entry| {
            app.allocator.free(entry.worktree_path);
            app.allocator.free(entry.original_cwd);
        }
        app.worktree_stack.deinit(app.allocator);
        app.cron_registry.deinit();
        app.model_context.deinit();
        if (app.rule_set) |*r| r.deinit();
        if (app.settings) |*s| s.deinit();
        if (app.sandbox_settings) |*s| s.deinit();
        if (app.hooks) |*h| h.deinit();
        if (app.cwd_abs) |c| app.allocator.free(c);
        if (app.jobs) |*j| j.deinit();
        if (app.system_prompt) |s| app.allocator.free(s);
        if (app.user_context) |u| app.allocator.free(u);
        app.allocator.destroy(app);
    }

    pub fn probeApiKeys(app: *App) void {
        if (app.config.provider_kind != .anthropic) return;
        const bearer = app.oauth_token_for_catalog orelse app.api_key;
        api_keys_mod.fetchInto(&app.api_key_catalog, app.allocator, app.api_client.http_client.io, app.api_client.base_url, bearer) catch |err| {
            @import("util/log.zig").debug("auth", "api key list probe failed: {s}", .{@errorName(err)});
        };
        if (app.api_key_catalog.entries.items.len == 0) {
            app.api_key_catalog.addCurrentKeyFallback(app.api_key) catch |err| {
                @import("util/log.zig").debug("auth", "current API key fallback unavailable: {s}", .{@errorName(err)});
            };
        }
    }

    pub fn selectApiKeyForModels(app: *App, idx: usize) !void {
        if (idx >= app.api_key_catalog.entries.items.len) return error.InvalidApiKeySelection;
        const secret = app.api_key_catalog.entries.items[idx].secret;
        const owned = try app.allocator.dupe(u8, secret);
        errdefer {
            @memset(owned, 0);
            app.allocator.free(owned);
        }
        if (app.selected_api_key_owned) |old| {
            @memset(old, 0);
            app.allocator.free(old);
        }
        app.selected_api_key_owned = owned;
        app.api_key = owned;
        app.api_client.api_key = owned;
        if (app.openai_client) |*oc| oc.api_key = owned;
        if (app.gemini_client) |*gc| gc.api_key = owned;
        if (app.agent_jobs) |*aj| try aj.setApiKey(owned);

        app.api_client.catalog.deinit();
        app.api_client.catalog = @import("api/catalog.zig").Catalog.init(app.allocator);
        app.api_client.probeModels();
        app.models_picker_key_index = idx;
    }

    pub fn switchModel(app: *App, model_id: []const u8) !void {
        const previous_model = app.config.model;
        const previous_window = app.api_client.resolveMaxInputTokens();
        const current_window = app.api_client.resolveMaxInputTokensFor(model_id);
        const needs_previous_model_compact = shouldQueueModelSwitchCompact(previous_model, model_id, previous_window, current_window);

        const model = try app.allocator.dupe(u8, model_id);
        errdefer app.allocator.free(model);
        const previous_model_copy = if (needs_previous_model_compact)
            try app.allocator.dupe(u8, previous_model)
        else
            null;
        errdefer if (previous_model_copy) |m| app.allocator.free(m);

        if (app.agent_jobs) |*aj| try aj.setModel(model);
        const sp_mod = @import("core/system_prompt.zig");
        const new_system_prompt = sp_mod.buildFull(app.allocator, model, &app.skills, &app.agents, app.enabled_tool_names, app.memdir_abs) catch null;

        if (app.model_switch_owned) |old| app.allocator.free(old);
        app.model_switch_owned = model;
        app.config.model = model;
        app.api_client.model = model;
        if (app.openai_client) |*oc| oc.model = model;
        if (app.gemini_client) |*gc| gc.model = model;
        if (app.transcript_writer) |*w| w.model = model;

        if (app.pending_previous_model_for_compact) |old| app.allocator.free(old);
        app.pending_previous_model_for_compact = previous_model_copy;
        app.pending_previous_model_context_window = if (needs_previous_model_compact) previous_window else null;
        app.pending_current_model_context_window = if (needs_previous_model_compact) current_window else null;

        if (new_system_prompt) |sp| {
            if (app.system_prompt) |old| app.allocator.free(old);
            app.system_prompt = sp;
        }
    }

    pub fn pendingModelSwitchCompact(app: *const App) ?agent_loop.ModelSwitchCompact {
        const previous_model = app.pending_previous_model_for_compact orelse return null;
        return .{
            .previous_model = previous_model,
            .previous_context_window = app.pending_previous_model_context_window orelse return null,
            .current_context_window = app.pending_current_model_context_window orelse return null,
        };
    }

    pub fn clearPendingModelSwitchCompact(app: *App) void {
        if (app.pending_previous_model_for_compact) |old| app.allocator.free(old);
        app.pending_previous_model_for_compact = null;
        app.pending_previous_model_context_window = null;
        app.pending_current_model_context_window = null;
    }

    pub fn setReasoningEffort(app: *App, effort: types.ReasoningEffort) void {
        app.config.reasoning_effort = effort;
        app.api_client.reasoning_effort = effort;
    }

    pub fn persistLoginSelection(app: *App) void {
        const auth_mod = @import("core/auth.zig");
        var stored = auth_mod.loadDefault(app.allocator) catch |err| switch (err) {
            error.NotFound, error.NoHome => auth_mod.StoredCredentials{},
            else => {
                @import("util/log.zig").warn("auth", "load for selection persist failed: {s}", .{@errorName(err)});
                return;
            },
        };
        defer stored.deinit(app.allocator);
        if (app.selected_api_key_owned) |k| {
            if (stored.api_key) |old| {
                @memset(old, 0);
                app.allocator.free(old);
            }
            stored.api_key = app.allocator.dupe(u8, k) catch return;
        }
        if (stored.selected_model) |old| app.allocator.free(old);
        stored.selected_model = app.allocator.dupe(u8, app.config.model) catch return;
        stored.reasoning_effort = app.config.reasoning_effort;
        auth_mod.saveDefault(app.allocator, stored) catch |err| {
            @import("util/log.zig").warn("auth", "persist selection failed: {s}", .{@errorName(err)});
        };
    }

    fn initTranscriptWriter(app: *App) !void {
        // HOME
        const home_z = std.c.getenv("HOME") orelse return error.NoHome;
        const home = std.mem.span(home_z);

        const cwd = try @import("util/fs.zig").getCwd(app.allocator);
        defer app.allocator.free(cwd);

        // session_id 传入,使 transcript 目录名 == App.session_id(统一,不再两个独立 gen)。
        const w = try transcript.Writer.init(app.allocator, cwd, home, app.config.model, app.session_id);
        app.transcript_writer = w;
    }

    /// Agent loop 每轮结束后调用一次，把 conversation 新增的 message 刷到 transcript。
    pub fn persistTranscript(app: *App) void {
        if (app.transcript_writer) |*w| w.flush(&app.conversation);
    }

    /// Persist the current /goal state into the active session directory.
    pub fn persistGoal(app: *App) void {
        const dir = app.sessionDir() orelse return;
        app.goal_state.persistToDir(dir) catch |err| {
            @import("util/log.zig").warn("goal", "persist failed: {s}", .{@errorName(err)});
        };
    }

    /// Load /goal state from a session directory. Missing goal.json means no active goal.
    pub fn loadGoalFromSessionDir(app: *App, dir: []const u8) void {
        app.goal_state.loadFromDir(dir) catch |err| switch (err) {
            error.NotFound => app.goal_state.clearInMemory(),
            else => {
                @import("util/log.zig").warn("goal", "load failed: {s}", .{@errorName(err)});
                app.goal_state.clearInMemory();
            },
        };
    }

    /// 当前 session 目录(transcript.jsonl / suspend.json 所在)。无 writer → null。
    pub fn sessionDir(app: *App) ?[]const u8 {
        if (app.transcript_writer) |*w| return w.dir;
        return null;
    }

    /// 计算本 session 的 plan 文件路径 + mkdir。seed 优先用 transcript session id(每 session
    /// 稳定),否则时间兜底。失败仅降级(plan_file_path 留空,plan 模式靠对话文本)。
    fn initPlanFilePath(app: *App) void {
        const plan_file = @import("core/plan_file.zig");
        const home = app.homeDir();
        if (home.len == 0) return;
        // seed:session id(transcript dir basename)哈希;无 transcript → 时间。
        const seed: u64 = blk: {
            if (app.transcript_writer) |*w| {
                const base = std.fs.path.basename(w.dir);
                if (base.len > 0) break :blk std.hash.Wyhash.hash(0, base);
            }
            break :blk @as(u64, @bitCast(@import("util/time.zig").nowMs()));
        };
        var slug_buf: [64]u8 = undefined;
        const slug = plan_file.slugFromSeed(seed, &slug_buf);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = plan_file.planFilePath(home, slug, &path_buf);
        if (path.len == 0) return;
        plan_file.ensureDir(home) catch {}; // mkdir 失败不致命:写盘时模型会拿到错误
        app.plan_file_path = app.allocator.dupe(u8, path) catch return;
        // 挂到 permission_ctx,plan 模式下 decision 据此特许写 plan 文件。
        app.permission_ctx.plan_file_path = app.plan_file_path;
    }

    /// 计算本 session 的 memdir 绝对路径(通道 B)+ mkdir + 挂权限豁免。
    /// memdir 禁用(env)或无 home/cwd → 留空串(降级:不豁免、不注入 AutoMem)。
    fn initMemdir(app: *App) void {
        const memdir = @import("core/memory/memdir.zig");
        if (!memdir.isEnabled()) return;
        const home = app.homeDir();
        const cwd = app.cwdAbs();
        if (home.len == 0 or cwd.len == 0) return;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = memdir.memdirPath(home, cwd, &buf);
        if (path.len == 0) return;
        memdir.ensureDir(home, cwd) catch {}; // mkdir 失败不致命:写盘时模型拿到错误
        app.memdir_abs = app.allocator.dupe(u8, path) catch return;
        // 挂到 permission_ctx:写 memdir 子树内文件任何模式豁免(decision isAutoMemPath)。
        app.permission_ctx.memdir_abs = app.memdir_abs;
    }

    /// Shift+Tab 的纯状态机:当前 mode → 下一个 mode(对齐 Claude Code)。
    /// 循环档(default/acceptEdits/plan)三者轮转;非循环档(bypass/auto/dont_ask)→ default。
    /// 抽成纯函数让状态机可纯单测(不构造 App),cyclePermMode 只做副作用接线。
    pub fn nextPermMode(mode: types.PermissionMode) types.PermissionMode {
        return switch (mode) {
            .default, .prompt => .accept_edits,
            .accept_edits => .plan,
            .plan => .default,
            .auto, .dont_ask, .bypass_permissions, .bypass => .default,
        };
    }

    /// Shift+Tab:循环权限模式 default → acceptEdits → plan → default(对齐 Claude Code)。
    /// 改 config + permission_ctx;footer 读 live permission_ctx.mode 即反映。两期(loop/tui_backend)共用。
    pub fn cyclePermMode(app: *App) void {
        const from = app.config.permission_mode;
        const to = nextPermMode(from);
        // 经 Shift+Tab 进/出 plan 时同步维护 plan_prev_mode,使 ExitPlanMode(approve)能恢复
        // 到进 plan 前的真实模式(否则回退 default)。进 plan:记 from;离开 plan:清。
        if (to == .plan and from != .plan) {
            app.plan_prev_mode = from;
        } else if (from == .plan and to != .plan) {
            app.plan_prev_mode = null;
        }
        app.config.permission_mode = to;
        app.permission_ctx.setMode(to);
    }

    /// Ctrl+X Ctrl+K:杀所有 running 后台任务,返回 killed 数。两期共用。
    pub fn killAllBackground(app: *App) usize {
        const jobs = if (app.jobs) |*j| j else return 0;
        var killed: usize = 0;
        for (jobs.jobs.items) |*j| {
            if (j.status != .running) continue;
            var id_copy: [12]u8 = j.id; // 快照 id(kill 可能改 collection)
            jobs.kill(id_copy[0..]) catch continue;
            killed += 1;
        }
        return killed;
    }

    /// 激活一个 skill 的权限态。先清旧的(如有),再装新的。
    /// 同时把 active_skill 指针挂到 permission_ctx,让 dispatch 时 decision.check 看到。
    pub fn activateSkill(
        app: *App,
        skill_name: []const u8,
        allowed_tools: []const []const u8,
        disallowed_tools: []const []const u8,
    ) !void {
        if (app.active_skill) |*as| as.deinit();
        app.active_skill = try ActiveSkillState.init(app.allocator, skill_name, allowed_tools, disallowed_tools);
        app.permission_ctx.active_skill = &app.active_skill.?;
    }

    /// 清除激活态(loop.zig 在每条新 user message 进来时调用)。
    pub fn clearActiveSkill(app: *App) void {
        if (app.active_skill) |*as| {
            as.deinit();
            app.active_skill = null;
        }
        app.permission_ctx.active_skill = null;
    }

    /// Trampoline: ToolContext.activate_skill_fn 签名 — Skill 工具调用它把激活态通知到 App。
    pub fn activateSkillTrampoline(
        state: *anyopaque,
        skill_name: []const u8,
        allowed: []const []const u8,
        disallowed: []const []const u8,
    ) anyerror!void {
        const app: *App = @ptrCast(@alignCast(state));
        return app.activateSkill(skill_name, allowed, disallowed);
    }

    /// 激活一个 deferred 工具(ToolSearch 调):记入 activated_tools 集(dupe name,只增)。
    /// 已激活则幂等。下一轮 agent_loop 据此把该工具放回 tools 数组。
    pub fn activateTool(app: *App, tool_name: []const u8) !void {
        if (app.activated_tools.contains(tool_name)) return;
        const key = try app.allocator.dupe(u8, tool_name);
        errdefer app.allocator.free(key);
        try app.activated_tools.put(key, {});
    }

    /// Trampoline: ToolContext.activate_tool_fn 签名 — ToolSearch 调用它激活 deferred 工具。
    pub fn activateToolTrampoline(state: *anyopaque, tool_name: []const u8) anyerror!void {
        const app: *App = @ptrCast(@alignCast(state));
        return app.activateTool(tool_name);
    }

    /// 取 project_dir;不在 git repo 返空串(供 ${CLAUDE_PROJECT_DIR} 替换默认值)。
    pub fn project_dir_or_empty(app: *const App) []const u8 {
        return app.project_dir orelse "";
    }

    /// sandbox 配置指针(供 agent_loop opts 注入 ToolContext)。null = 未启用。
    pub fn sandboxPtr(app: *const App) ?*const @import("sandbox/config.zig").SandboxSettings {
        if (app.sandbox_settings) |*s| return s;
        return null;
    }

    /// 后台 subagent registry 的**可变**指针(TUI 只读统计/快照用)。
    /// 关键:`|*aj|` 捕获的是 App 字段本身的地址(App 会话级稳定),不是值拷贝——
    /// 这样 snapshotJobs/runningCount 里 listLock 锁的是**真 registry 的 mutex**,
    /// 与后台线程注册新 job 时锁的是同一把,不会锁到栈副本(那是 race)。
    /// @constCast 去掉 const 是诚实的:快照只动 mutex 不改逻辑状态(同 sandboxPtr 理据)。
    pub fn agentJobsPtr(app: *const App) ?*@import("core/agent_job_registry.zig").AgentJobRegistry {
        if (app.agent_jobs) |*aj| return @constCast(aj);
        return null;
    }

    /// cwd 绝对路径(sandbox profile 工作目录),空串 = 未知(用 process cwd)。
    pub fn cwdAbs(app: *const App) []const u8 {
        return app.cwd_abs orelse "";
    }

    /// HOME(sandbox ~/ 展开)。
    pub fn homeDir(app: *const App) []const u8 {
        _ = app;
        const h = std.c.getenv("HOME") orelse return "";
        return std.mem.span(h);
    }

    /// EnterWorktree 工具用:把新 worktree 入栈。
    pub fn worktreePushTrampoline(
        state: *anyopaque,
        allocator: std.mem.Allocator,
        wt_path: []const u8,
        original_cwd: []const u8,
    ) anyerror!void {
        const app: *App = @ptrCast(@alignCast(state));
        const entry = WorktreeEntry{
            .worktree_path = try allocator.dupe(u8, wt_path),
            .original_cwd = try allocator.dupe(u8, original_cwd),
        };
        try app.worktree_stack.append(allocator, entry);
    }

    /// ExitWorktree 工具用:从栈顶弹出。返 null 表示当前不在任何 worktree。
    pub fn worktreePopTrampoline(state: *anyopaque, allocator: std.mem.Allocator) anyerror!?WorktreeEntry {
        _ = allocator;
        const app: *App = @ptrCast(@alignCast(state));
        if (app.worktree_stack.items.len == 0) return null;
        return app.worktree_stack.pop();
    }

    /// L5:把 App 提供给工具的三类宿主能力(Skill 激活 / ToolSearch 激活 / Worktree push-pop)
    /// 聚合成一个 HostServices——一个 ctx(=app)+ 四个 trampoline,取代散落的四个裸字段。
    pub fn hostServices(app: *App) tools_mod.HostServices {
        return .{
            .ctx = @ptrCast(app),
            .activateSkillFn = &activateSkillTrampoline,
            .activateToolFn = &activateToolTrampoline,
            .worktreePushFn = &worktreePushTrampoline,
            .worktreePopFn = &worktreePopTrampoline,
        };
    }

    /// 加载 5 层 settings(managed/cli/project local+shared/user)+ CLI inline 规则,
    /// 挂到 permission_ctx.settings,并填 match_ctx(cwd/project_root/home)。
    fn loadSettings(app: *App) !void {
        const loader = @import("permission/loader.zig");
        const home_c = std.c.getenv("HOME");
        const home: ?[]const u8 = if (home_c) |h| std.mem.span(h) else null;

        const ms = try loader.load(app.allocator, .{
            .managed = null,
            .cli = app.config.settings_path,
            .project_root = app.project_dir,
            .home = home,
            .cli_allow = app.config.allowed_tools,
            .cli_deny = app.config.disallowed_tools,
            .cli_dirs = app.config.add_dirs,
        });
        app.settings = ms;
        app.permission_ctx.settings = &app.settings.?;
        app.permission_ctx.match_ctx = .{
            .cwd = app.cwd_abs orelse "",
            .project_root = app.project_dir orelse (app.cwd_abs orelse ""),
            .home = home orelse "",
        };
        @import("util/log.zig").info("permission", "settings loaded: {d} layer(s)", .{app.settings.?.layers.len});

        // disableBypassPermissionsMode / disableAutoMode 强制:若 settings 禁用了某模式
        // 而当前正处于该模式,降级到 default + 警告(对齐官方:这两个开关是硬约束)。
        const canon = @import("permission/mode.zig").canonical(app.config.permission_mode);
        if (app.settings.?.isBypassDisabled() and canon == .bypass_permissions) {
            @import("util/log.zig").warn("permission", "bypassPermissions disabled by settings → downgraded to default", .{});
            app.config.permission_mode = .default;
            app.permission_ctx.setMode(.default);
        }
        if (app.settings.?.isAutoModeDisabled() and canon == .auto) {
            @import("util/log.zig").warn("permission", "auto mode disabled by settings → downgraded to default", .{});
            app.config.permission_mode = .default;
            app.permission_ctx.setMode(.default);
        }

        // 解析 sandbox 段(project shared + user;managed/cli 罕见配沙箱,本期跳过)
        app.loadSandboxConfig(home) catch |e| {
            @import("util/log.zig").debug("sandbox", "no sandbox config: {s}", .{@errorName(e)});
        };

        // 解析 hooks 段(同样从 project/user settings 收集 PreToolUse)
        app.loadHooks(home) catch |e| {
            @import("util/log.zig").debug("hook", "no hooks: {s}", .{@errorName(e)});
        };
    }

    /// 收集 project/user settings 的 hooks.PreToolUse,合并成一个 HookSet。
    /// 简化:取第一个非空 source(优先 project 覆盖 user)。完整跨层合并留后续。
    fn loadHooks(app: *App, home: ?[]const u8) !void {
        const hooks_mod = @import("permission/hooks.zig");
        const candidates = [_]?[]const u8{
            if (app.project_dir) |r| (std.fmt.allocPrint(app.allocator, "{s}/.claude/settings.json", .{r}) catch null) else null,
            if (home) |h| (std.fmt.allocPrint(app.allocator, "{s}/.claude/settings.json", .{h}) catch null) else null,
        };
        defer for (candidates) |p| if (p) |x| app.allocator.free(x);

        for (candidates) |maybe_path| {
            const path = maybe_path orelse continue;
            const content = readFileAlloc(app.allocator, path) catch continue;
            defer app.allocator.free(content);
            var parsed = std.json.parseFromSlice(std.json.Value, app.allocator, content, .{}) catch continue;
            defer parsed.deinit();
            var hs = hooks_mod.parse(app.allocator, parsed.value) catch continue;
            if (!hs.isEmpty()) {
                app.hooks = hs;
                app.permission_ctx.hooks = &app.hooks.?;
                @import("util/log.zig").info("hook", "PreToolUse loaded {d} matcher(s) (from {s})", .{ hs.pre_tool_use.len, path });
                return;
            }
            hs.deinit();
        }
    }

    /// 读 project/.claude/settings.json + ~/.claude/settings.json 的 sandbox 段,
    /// 取第一个 enabled 的(简化:不跨层合并 filesystem 数组,本期足够)。
    fn loadSandboxConfig(app: *App, home: ?[]const u8) !void {
        const sb_config = @import("sandbox/config.zig");
        const candidates = [_]?[]const u8{
            app.config.settings_path,
            if (app.project_dir) |r| (std.fmt.allocPrint(app.allocator, "{s}/.claude/settings.json", .{r}) catch null) else null,
            if (home) |h| (std.fmt.allocPrint(app.allocator, "{s}/.claude/settings.json", .{h}) catch null) else null,
        };
        // 后两个是 allocPrint 的,用完 free
        defer {
            if (candidates[1]) |p| app.allocator.free(p);
            if (candidates[2]) |p| app.allocator.free(p);
        }

        for (candidates) |maybe_path| {
            const path = maybe_path orelse continue;
            const content = readFileAlloc(app.allocator, path) catch continue;
            defer app.allocator.free(content);
            var parsed = std.json.parseFromSlice(std.json.Value, app.allocator, content, .{}) catch continue;
            defer parsed.deinit();
            var sb = sb_config.parse(app.allocator, parsed.value) catch continue;
            if (sb.enabled) {
                app.sandbox_settings = sb;
                app.permission_ctx.sandbox_enabled = true;
                app.permission_ctx.auto_allow_bash_if_sandboxed = sb.auto_allow_bash_if_sandboxed;
                @import("util/log.zig").info("sandbox", "enabled (from {s})", .{path});
                return;
            }
            sb.deinit();
        }
    }

    /// 运行时追加一个 additionalDirectory(/add-dir 命令),重建 settings 使其立即生效。
    /// dir 复制进 config.add_dirs(\x00 分隔累加),旧 settings deinit 后重 load。
    pub fn addDirectory(app: *App, dir: []const u8) !void {
        const new_list = if (app.config.add_dirs) |p|
            try std.fmt.allocPrint(app.allocator, "{s}\x00{s}", .{ p, dir })
        else
            try app.allocator.dupe(u8, dir);
        // 旧 add_dirs 若是 arena 分配则不 free(parseArgs 用 arena);这里统一不 free 旧值,
        // 改为只更新指针。new_list 用 app.allocator,deinit 时不单独释放(随 arena/进程结束)。
        app.config.add_dirs = new_list;

        // 重建 settings
        if (app.settings) |*s| s.deinit();
        app.settings = null;
        app.permission_ctx.settings = null;
        try app.loadSettings();
    }

    /// 从 ~/.cc-zig/config.json 读 permission_rules 数组。失败仅 log，不影响启动。
    /// 同时把加载的 rule_set 绑到 permission_ctx.rules。
    fn loadPermissionRules(app: *App) !void {
        const home_c = std.c.getenv("HOME") orelse return error.NoHome;
        const home = std.mem.span(home_c);
        var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "{s}/.cc-zig/config.json\x00", .{home});
        const fd = std.c.open(@ptrCast(path.ptr), std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return error.NotFound;
        defer _ = std.c.close(fd);

        var all = std.ArrayList(u8).empty;
        defer all.deinit(app.allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &buf, buf.len);
            if (n <= 0) break;
            try all.appendSlice(app.allocator, buf[0..@intCast(n)]);
        }

        var parsed = try std.json.parseFromSlice(std.json.Value, app.allocator, all.items, .{});
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return;

        const rules_v = root.object.get("permission_rules") orelse return;
        if (rules_v != .array) return;

        var rs = permission_mod.RuleSet.init(app.allocator);
        errdefer rs.deinit();

        for (rules_v.array.items) |rv| {
            if (rv != .object) continue;
            const match_v = rv.object.get("match") orelse continue;
            const dec_v = rv.object.get("decision") orelse continue;
            if (match_v != .object or dec_v != .string) continue;

            const tool_v = match_v.object.get("tool") orelse continue;
            if (tool_v != .string) continue;

            const d: permission_mod.PermissionResult = if (std.mem.eql(u8, dec_v.string, "allow"))
                .allow
            else if (std.mem.eql(u8, dec_v.string, "deny"))
                .deny
            else if (std.mem.eql(u8, dec_v.string, "ask"))
                .ask
            else
                continue;

            const cmd_prefix = if (match_v.object.get("command_prefix")) |v|
                (if (v == .string) try app.allocator.dupe(u8, v.string) else null)
            else
                null;
            const path_glob = if (match_v.object.get("path_glob")) |v|
                (if (v == .string) try app.allocator.dupe(u8, v.string) else null)
            else
                null;

            try rs.append(.{
                .tool = try app.allocator.dupe(u8, tool_v.string),
                .command_prefix = cmd_prefix,
                .path_glob = path_glob,
                .decision = d,
            });
        }

        app.rule_set = rs;
        app.permission_ctx.rules = &app.rule_set.?;
        @import("util/log.zig").info("permission", "loaded {d} rule(s) from config", .{app.rule_set.?.rules.items.len});
    }

    /// 启动时连接 ~/.cc-zig/config.json 里 mcp_servers 数组里声明的每个 server。
    /// Schema：
    ///   {"mcp_servers": [
    ///       {"name": "github", "command": ["/usr/local/bin/mcp-github", "--token=..."]},
    ///       ...
    ///   ]}
    /// 每个 server 失败仅 log,不影响其它 server 或 App 启动。
    /// 成功的 session 注册的工具进 dyn_registry,naming: `<name>__<tool>`。
    fn connectMcpServers(app: *App) !void {
        const home_c = std.c.getenv("HOME") orelse return error.NoHome;
        const home = std.mem.span(home_c);
        var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "{s}/.cc-zig/config.json\x00", .{home});
        const fd = std.c.open(@ptrCast(path.ptr), std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return error.NotFound;
        defer _ = std.c.close(fd);

        var all = std.ArrayList(u8).empty;
        defer all.deinit(app.allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &buf, buf.len);
            if (n <= 0) break;
            try all.appendSlice(app.allocator, buf[0..@intCast(n)]);
        }

        var parsed = try std.json.parseFromSlice(std.json.Value, app.allocator, all.items, .{});
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return;
        const servers_v = root.object.get("mcp_servers") orelse return;
        if (servers_v != .array) return;

        const log = @import("util/log.zig");
        for (servers_v.array.items) |sv| {
            if (sv != .object) continue;
            const name_v = sv.object.get("name") orelse continue;
            const cmd_v = sv.object.get("command") orelse continue;
            if (name_v != .string or cmd_v != .array) continue;

            // 把 command 数组转成 C argv（null-terminated, 每项 [*:0]u8）
            var argv_storage = std.ArrayList(?[*:0]const u8).empty;
            defer {
                for (argv_storage.items) |item| {
                    if (item) |p| app.allocator.free(std.mem.span(p));
                }
                argv_storage.deinit(app.allocator);
            }
            for (cmd_v.array.items) |arg| {
                if (arg != .string) {
                    log.warn("mcp", "server '{s}': non-string in command array, skipped", .{name_v.string});
                    break;
                }
                const dup = try app.allocator.dupeZ(u8, arg.string);
                try argv_storage.append(app.allocator, dup.ptr);
            }
            if (argv_storage.items.len == 0) continue;
            try argv_storage.append(app.allocator, null);

            // spawn + connect
            const client_heap = try app.allocator.create(McpClient);
            errdefer app.allocator.destroy(client_heap);
            client_heap.* = McpClient.connect(app.allocator, argv_storage.items) catch |err| {
                log.warn("mcp", "server '{s}' connect failed: {s}", .{ name_v.string, @errorName(err) });
                app.allocator.destroy(client_heap);
                continue;
            };

            var session = McpSession.init(app.allocator, client_heap);
            // 注册 server tools + resource tools；任一失败回滚本 server
            session.registerTools(&app.dyn_registry, name_v.string) catch |err| {
                log.warn("mcp", "server '{s}' registerTools failed: {s}", .{ name_v.string, @errorName(err) });
                session.deinit();
                client_heap.close();
                app.allocator.destroy(client_heap);
                continue;
            };
            session.registerResourceTools(&app.dyn_registry, name_v.string) catch |err| {
                log.warn("mcp", "server '{s}' registerResourceTools failed: {s}", .{ name_v.string, @errorName(err) });
                // tools 已注册无法回滚；只能略过 resources
            };

            const name_owned = try app.allocator.dupe(u8, name_v.string);
            try app.mcp_sessions.append(app.allocator, .{
                .name = name_owned,
                .client = client_heap,
                .session = session,
            });
            log.info("mcp", "connected '{s}'", .{name_v.string});
        }
    }

    /// 把 app.abort 绑到进程级 SIGINT handler。**只在前台(TUI N=1)会话调一次。**
    /// SIGINT 是进程级单一信号——一个进程只有一个 handler,只能指向一个 abort。这对 TUI
    /// 正确(N=1:唯一会话即前台会话)。**多 Session(GUI)不用 SIGINT 路由**:GUI 没有
    /// "Ctrl+C 打到哪个会话"的歧义,它对每个会话**直接调 `app.abort.abort(reason)`**
    /// (AbortSignal.abort 已 public,app.abort 是 per-instance,各会话独立中断,互不影响)。
    /// 故 g_abort_signal 单指针不是多 session 缺陷——它是 TUI 单终端的正确机制,GUI 旁路它。
    /// (不预包 requestStop wrapper:GUI 真来时直接调 abort.abort + 那时定确切语义,避孤儿 API。)
    pub fn installSigintHandler(app: *App) !void {
        g_abort_signal = &app.abort;

        var act: std.posix.Sigaction = .{
            .handler = .{ .handler = sigintHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
    }
};

pub fn shouldQueueModelSwitchCompact(
    previous_model: []const u8,
    current_model: []const u8,
    previous_context_window: u32,
    current_context_window: u32,
) bool {
    return !std.mem.eql(u8, previous_model, current_model) and previous_context_window > current_context_window;
}

/// 读整个文件(POSIX open/read,稳定不依赖 Io.Dir)。caller free。
fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len + 1 > pbuf.len) return error.PathTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = std.c.open(@ptrCast(&pbuf), std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);
    var all: std.ArrayList(u8) = .empty;
    errdefer all.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try all.appendSlice(alloc, buf[0..@intCast(n)]);
    }
    return try all.toOwnedSlice(alloc);
}

/// Signal handler: async-signal-safe (仅 atomic store)。
fn sigintHandler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    if (g_abort_signal) |s| {
        s.abort(.user_ctrl_c);
    }
}

test "App init/deinit" {
    // 注意：init.io 在测试环境下不易构造，这里只校验 init/deinit 签名可用。
    // 真正的初始化测试放在集成测试层。
    _ = App;
}

test "nextPermMode: Shift+Tab 循环状态机(对齐 cc)" {
    // 循环档三者轮转:default → acceptEdits → plan → default。
    // 此前只有慢 PTY(test_mode_commit T08)覆盖;下沉成纯单测。
    try std.testing.expectEqual(types.PermissionMode.accept_edits, App.nextPermMode(.default));
    try std.testing.expectEqual(types.PermissionMode.plan, App.nextPermMode(.accept_edits));
    try std.testing.expectEqual(types.PermissionMode.default, App.nextPermMode(.plan));
    // prompt 别名等价 default → acceptEdits。
    try std.testing.expectEqual(types.PermissionMode.accept_edits, App.nextPermMode(.prompt));
    // 非循环档(bypass/auto/dont_ask)→ default(对齐 cc:从特殊模式按一次回循环起点)。
    try std.testing.expectEqual(types.PermissionMode.default, App.nextPermMode(.bypass_permissions));
    try std.testing.expectEqual(types.PermissionMode.default, App.nextPermMode(.bypass));
    try std.testing.expectEqual(types.PermissionMode.default, App.nextPermMode(.auto));
    try std.testing.expectEqual(types.PermissionMode.default, App.nextPermMode(.dont_ask));
    // 三步回到起点(完整一圈)。
    try std.testing.expectEqual(
        types.PermissionMode.default,
        App.nextPermMode(App.nextPermMode(App.nextPermMode(.default))),
    );
}

test "model switch compact is queued only when switching to smaller context window" {
    try std.testing.expect(shouldQueueModelSwitchCompact("large", "small", 200_000, 80_000));
    try std.testing.expect(!shouldQueueModelSwitchCompact("same", "same", 200_000, 80_000));
    try std.testing.expect(!shouldQueueModelSwitchCompact("small", "large", 80_000, 200_000));
    try std.testing.expect(!shouldQueueModelSwitchCompact("a", "b", 200_000, 200_000));
}
