//! App 应用生命周期：持有所有顶层组件（Config, Conversation, Client, ToolDefs, Permission, AbortSignal）。
//!
//! 目的：让 main.zig 只负责参数解析 + 启动 App。所有业务状态和循环逻辑从 main.zig 下沉到
//! 此模块 + core/agent_loop.zig。
//!
//! M1.5 起加入 AbortSignal + SIGINT 绑定。signal handler 只做 atomic store，async-signal-safe。

const std = @import("std");
const types = @import("types.zig");
const client_mod = @import("client.zig");
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

pub const UsageTotals = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,

    pub fn apply(self: *UsageTotals, d: api_stream.UsageDelta) void {
        self.input_tokens += d.input_tokens;
        self.output_tokens += d.output_tokens;
        self.cache_read_input_tokens += d.cache_read_input_tokens;
        self.cache_creation_input_tokens += d.cache_creation_input_tokens;
    }

    pub fn costUsd(self: *const UsageTotals, model: []const u8) f64 {
        return pricing.computeCost(
            pricing.rateFor(model),
            self.input_tokens,
            self.output_tokens,
            self.cache_read_input_tokens,
            self.cache_creation_input_tokens,
        );
    }
};

/// 给 agent_loop 用的 trampoline：把 *anyopaque 还原成 *UsageTotals。
fn usageTotalsAdd(ctx: *anyopaque, d: api_stream.UsageDelta) void {
    const self: *UsageTotals = @ptrCast(@alignCast(ctx));
    self.apply(d);
}

/// 全局 AbortSignal 指针，供 signal handler 访问。installSigintHandler 绑定后非 null。
/// signal handler 只读该指针 + 调 abort.abort()——不分配、不 IO、不获锁。
var g_abort_signal: ?*AbortSignal = null;

/// 一个已连接 MCP server 的资源捆绑：name（owned）+ heap-allocated client + session。
/// session 内的 binding 指针指向同一个 client；client 必须比 session 活得久。
pub const McpSessionEntry = @import("core/mcp_session.zig").McpSessionEntry;

pub const App = struct {
    allocator: std.mem.Allocator,
    config: types.Config,
    api_key: []const u8,
    conversation: Conversation,
    api_client: client_mod.Client,
    tool_defs: []json_mod.ToolDefinition,
    /// 当前启用的工具名（含动态 Skill/MCP）。用于 system prompt 的 # Using your tools
    /// 段按工具集裁剪 + 构造 PromptContext。生命周期随 arena。
    enabled_tool_names: []const []const u8 = &.{},
    permission_ctx: permission_mod.PermissionContext,
    abort: AbortSignal,
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
    /// 模型长任务 scratchpad（Task* 工具共享）
    tasks: TaskStore,
    /// 预构造的 system prompt（app 启动时一次性 build）。null = build 失败时降级为无 prompt。
    system_prompt: ?[]u8 = null,
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
            .dyn_registry = DynRegistry.init(allocator),
            .mcp_sessions = .empty,
            .agents = AgentSet.init(allocator),
            .worktree_stack = .empty,
            .cron_registry = CronRegistry.init(allocator),
        };

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

        // 把 project_dir + home 提供给 permission/prompt 的 allow_always 持久化路径
        {
            const home_for_prompt = blk: {
                const h = std.c.getenv("HOME") orelse break :blk @as([]const u8, "");
                break :blk std.mem.span(h);
            };
            @import("permission/prompt.zig").setPersistContext(app.project_dir, home_for_prompt);
        }

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

        // 探测 <base_url>/v1/models 取 model catalog（max_tokens）。失败静默，走本地 fallback。
        // METACODES_NO_PROBE=1 跳过：离线/沙箱/TTY 测试下 probeModels 的网络调用会 hang,
        // 跳过让 REPL 立即可用(走本地 model 单价表)。
        if (std.c.getenv("METACODES_NO_PROBE") == null) {
            app.api_client.probeModels();
        } else {
            @import("util/log.zig").debug("catalog", "probeModels skipped (METACODES_NO_PROBE)", .{});
        }
        // CLI --max-tokens 覆盖
        app.api_client.setMaxTokensOverride(config.max_tokens);

        // 初始化 transcript writer：需要 cwd + HOME
        app.initTranscriptWriter() catch |err| {
            @import("util/log.zig").warn("transcript", "init failed: {s} (session will not persist)", .{@errorName(err)});
        };

        // 计算本 session 的 plan 文件路径(plan 模式下模型把计划写这里;唯一可写)。
        // slug seed 优先用 transcript session id(每 session 稳定),否则时间兜底。
        app.initPlanFilePath();

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
        app.agent_jobs = @import("core/agent_job_registry.zig").AgentJobRegistry.init(allocator, api_key, config.base_url, config.model) catch |err| blk: {
            @import("util/log.zig").warn("agent", "agent_jobs registry init failed: {s}", .{@errorName(err)});
            break :blk null;
        };

        // 构造 system prompt（依赖 config.model）。# Using your tools 段按 enabled_tool_names
        // 动态裁剪（对应 cc getUsingYourToolsSection(enabledTools)）。失败仅 log，保持 null。
        app.system_prompt = system_prompt_mod.buildFull(allocator, config.model, &app.skills, &app.agents, app.enabled_tool_names) catch |err| blk: {
            @import("util/log.zig").warn("sysprompt", "build failed: {s} (continuing without system prompt)", .{@errorName(err)});
            break :blk null;
        };

        return app;
    }

    pub fn deinit(app: *App) void {
        // 最先 drain 后台 subagent：abort 全部 running → join 全部线程 → free。
        // 必须早于任何共享资源（agents/dyn_registry/skills/allocator）释放，
        // 否则在跑的后台线程会触碰已释放内存（UAF）。job 用专属 Client，不依赖 api_client。
        if (app.agent_jobs) |*aj| aj.deinit();
        if (app.transcript_writer) |*w| w.deinit();
        app.api_client.deinit();
        app.conversation.deinit();
        app.allocator.free(app.tool_defs);
        app.skills.deinit();
        app.read_state.deinit();
        app.edit_hl_cache.deinit();
        app.tasks.deinit();
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
        app.agents.deinit();
        for (app.worktree_stack.items) |entry| {
            app.allocator.free(entry.worktree_path);
            app.allocator.free(entry.original_cwd);
        }
        app.worktree_stack.deinit(app.allocator);
        app.cron_registry.deinit();
        if (app.rule_set) |*r| r.deinit();
        if (app.settings) |*s| s.deinit();
        if (app.sandbox_settings) |*s| s.deinit();
        if (app.hooks) |*h| h.deinit();
        if (app.cwd_abs) |c| app.allocator.free(c);
        if (app.jobs) |*j| j.deinit();
        if (app.system_prompt) |s| app.allocator.free(s);
        app.allocator.destroy(app);
    }

    fn initTranscriptWriter(app: *App) !void {
        // HOME
        const home_z = std.c.getenv("HOME") orelse return error.NoHome;
        const home = std.mem.span(home_z);

        const cwd = try @import("util/fs.zig").getCwd(app.allocator);
        defer app.allocator.free(cwd);

        const w = try transcript.Writer.init(app.allocator, cwd, home, app.config.model);
        app.transcript_writer = w;
    }

    /// Agent loop 每轮结束后调用一次，把 conversation 新增的 message 刷到 transcript。
    pub fn persistTranscript(app: *App) void {
        if (app.transcript_writer) |*w| w.flush(&app.conversation);
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

    /// 获取 agent_loop 能用的 UsageSink（把 event 累加到 app.usage）。
    pub fn usageSink(app: *App) agent_loop.UsageSink {
        return .{ .ctx = @ptrCast(&app.usage), .addFn = usageTotalsAdd };
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

    /// 把 app.abort 绑到进程级 SIGINT handler。只需调用一次。
    /// 再次按 Ctrl+C 时，handler 会 atomic-store true；主循环通过 isAborted() 观察。
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
