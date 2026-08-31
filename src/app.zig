//! App 应用生命周期：持有所有顶层组件（Config, Conversation, Client, ToolDefs, Permission, AbortSignal）。
//!
//! 目的：让 main.zig 只负责参数解析 + 启动 App。所有业务状态和循环逻辑从 main.zig 下沉到
//! 此模块 + core/agent_loop.zig。
//!
//! M1.5 起加入 AbortSignal + SIGINT 绑定。signal handler 只做 atomic store，async-signal-safe。

const std = @import("std");
const pfs = @import("platform").fs;
const platform_signal = @import("platform").signal;
const platform_paths = @import("platform").paths;
const sync = @import("platform").sync;

/// **U5 B1:slice-safe snapshot 发布缓存(A')**。UAF-critical、运行时会 free+reassign 的 slice
/// 字段(model/dirs)的 owned dup，mutex 守护。核心不变式：这些 slice 的 free+reassign（driver 侧
/// switchModel/addDirectory）与任何跨线程 读+dup（HTTP /state）**必须经本 mutex 互斥**——否则
/// HTTP 线程读 live slice 撞 driver 无锁 free = UAF。
/// **refresh 骑 emit（App.emitConfig）**：emit⟺refresh 一个不变式，因"所有 mutation 都 emit"
/// (U4 grep-guard 单写侧) 自动保证"所有 mutation 都刷 cache"，零新增枚举义务（不手工 per-mutation refresh）。
/// 标量(mode/reasoning/usage/generating)不进 cache——值语义无 UAF，跨字段良性 skew（display）。
/// snapshotSlices/readOwned 返回的 owned slice 束（命名类型：匿名 struct 跨函数不 unify）。
/// caller free：model + 每个 dirs 元素 + dirs slice。
pub const SnapshotSlices = struct { model: []u8, dirs: [][]u8 };

const SnapshotCache = struct {
    mutex: sync.Mutex = .{},
    allocator: std.mem.Allocator,
    model: []u8 = &.{}, // owned dup
    dirs: [][]u8 = &.{}, // owned dup（slice-of-owned）

    fn deinit(self: *SnapshotCache) void {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        self.freeDirsLocked();
        if (self.model.len > 0) self.allocator.free(self.model);
        self.model = &.{};
    }
    fn freeDirsLocked(self: *SnapshotCache) void {
        for (self.dirs) |d| self.allocator.free(d);
        if (self.dirs.len > 0) self.allocator.free(self.dirs);
        self.dirs = &.{};
    }
    /// 刷 model（emitConfig(.model) 骑此）。锁内 free 旧 + dup 新。
    fn setModel(self: *SnapshotCache, m: []const u8) void {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        // OOM:保留旧值(降级不崩)。但 emitConfig 仍会 journal.append 推进 seq → 快照留
        // (旧 model, 新 seq)= U5 B3 无缺口不变式在此 OOM 下降级(同 journal.append 自身 OOM 丢行,
        // 整层 best-effort)。故 warn(不静默),对齐 journal.zig:48 的 drop 记账。
        const dup = self.allocator.dupe(u8, m) catch {
            @import("util/log.zig").warn("web", "snapshot cache model refresh dropped (OOM) — attach 快照可能暂缺此变更", .{});
            return;
        };
        if (self.model.len > 0) self.allocator.free(self.model);
        self.model = dup;
    }
    /// 刷 dirs（emitConfig(.dirs) 骑此）。锁内 free 旧 + dup 新（全量）。
    fn setDirs(self: *SnapshotCache, dirs: []const []const u8) void {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        var out = self.allocator.alloc([]u8, dirs.len) catch {
            @import("util/log.zig").warn("web", "snapshot cache dirs refresh dropped (OOM) — attach 快照可能暂缺此变更", .{});
            return; // OOM:保留旧(同 setModel:best-effort,warn 不静默)
        };
        var n: usize = 0;
        for (dirs) |d| {
            out[n] = self.allocator.dupe(u8, d) catch {
                for (out[0..n]) |x| self.allocator.free(x);
                self.allocator.free(out);
                @import("util/log.zig").warn("web", "snapshot cache dirs refresh dropped (OOM) — attach 快照可能暂缺此变更", .{});
                return; // OOM:保留旧
            };
            n += 1;
        }
        self.freeDirsLocked();
        self.dirs = out;
    }
    /// 读侧（HTTP /state）：锁内 dup 出 model + dirs 给调用方（caller free）。
    /// 单次持锁读全部 slice → 这批 slice 彼此一致且都安全（driver free 被锁挡）。
    fn readOwned(self: *SnapshotCache, alloc: std.mem.Allocator) !SnapshotSlices {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        const m = try alloc.dupe(u8, self.model);
        errdefer alloc.free(m);
        var d = try alloc.alloc([]u8, self.dirs.len);
        var n: usize = 0;
        errdefer {
            for (d[0..n]) |x| alloc.free(x);
            alloc.free(d);
        }
        for (self.dirs) |src| {
            d[n] = try alloc.dupe(u8, src);
            n += 1;
        }
        return .{ .model = m, .dirs = d };
    }
};
const types = @import("types.zig");
const client_mod = @import("client.zig");
const api_keys_mod = @import("api/api_keys.zig");
const openai_mod = @import("api/openai_client.zig");
const gemini_mod = @import("api/gemini_client.zig");
const provider_host_mod = @import("provider/host.zig");
const provider_binding_mod = @import("provider/runtime_binding.zig");
const provider_control_plane = @import("provider/control_plane.zig");
const provider_config_store = @import("provider/config_store.zig");
const provider_selection_mod = @import("provider/selection.zig");
const provider_ids_mod = @import("provider/ids.zig");
const provider_credential_mod = @import("provider/credential.zig");
const provider_config_doc = @import("provider/config_doc.zig");
const model_picker_mod = @import("repl/model_picker.zig");
const kg_provider_audit = @import("kg/provider_audit.zig");
const provider_alias_mod = @import("provider/alias.zig");
const provider_oauth_mod = @import("provider/oauth.zig");
const oauth_exchange_mod = @import("api/oauth_exchange.zig");
const provider_mod = @import("api/provider.zig");
const request_overrides = @import("api/request_overrides.zig");
const dialect_mod = @import("api/dialect.zig");
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
const skill_cli_adapter = @import("skills/cli_adapter.zig");
const plugin_mod = @import("plugin/root.zig");
const path_util = @import("util/path.zig");
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

fn buildCliPluginSnapshot(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    home: []const u8,
    packed_data_dirs: ?[]const u8,
    packed_process_dirs: ?[]const u8,
) !?*plugin_mod.runtime.Snapshot {
    if (packed_data_dirs == null and packed_process_dirs == null) return null;
    var roots: std.ArrayList([]u8) = .empty;
    defer {
        for (roots.items) |root| allocator.free(root);
        roots.deinit(allocator);
    }
    var packages: std.ArrayList(plugin_mod.runtime.PackageSource) = .empty;
    defer packages.deinit(allocator);
    var process_packages: std.ArrayList(plugin_mod.runtime.PackageSource) = .empty;
    defer process_packages.deinit(allocator);

    try appendCliPluginSources(allocator, cwd, home, packed_data_dirs, &roots, &packages);
    try appendCliPluginSources(allocator, cwd, home, packed_process_dirs, &roots, &process_packages);
    if (packages.items.len == 0 and process_packages.items.len == 0)
        return error.InvalidPackageRoot;

    return try plugin_mod.runtime.Snapshot.create(allocator, .{
        .generation = @enumFromInt(1),
        .supported_capabilities = plugin_mod.support.acceptedCapabilities(.cli_data),
        .packages = packages.items,
        .process_packages = process_packages.items,
    });
}

fn appendCliPluginSources(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    home: []const u8,
    packed_dirs: ?[]const u8,
    roots: *std.ArrayList([]u8),
    packages: *std.ArrayList(plugin_mod.runtime.PackageSource),
) !void {
    const encoded_dirs = packed_dirs orelse return;
    var iterator = std.mem.splitScalar(u8, encoded_dirs, 0);
    while (iterator.next()) |raw| {
        if (raw.len == 0) return error.InvalidPackageRoot;
        const root = try path_util.normalize(allocator, raw, .{
            .home = home,
            .base_dir = cwd,
            .resolve_relative = true,
        });
        try roots.append(allocator, root);
        try packages.append(allocator, .{ .root = root, .layer = .session });
    }
}

fn executeCliProcessTool(
    ctx: *const @import("tools/context.zig").ToolContext,
    args: []const u8,
    raw: ?*anyopaque,
) anyerror!@import("core/tool_result.zig").ToolResultBody {
    const isolated: *const @import("core/tool_catalog.zig").IsolatedTool =
        @ptrCast(@alignCast(raw orelse return error.ProcessPluginUnavailable));
    const outcome = try isolated.execute(isolated.ctx, ctx, args);
    return switch (outcome) {
        .ok => |body| body,
        .host_failed => |detail| {
            installCliProcessError(ctx, detail);
            return error.ProcessPluginFailed;
        },
        .host_rejected => |detail| {
            installCliProcessError(ctx, detail);
            return error.ProcessPluginRejected;
        },
        // process.zig never produces fatal. Keep the legacy adapter fail-closed
        // if another isolated implementation violates that contract.
        .host_fatal => error.ProcessPluginProtocolViolation,
    };
}

fn installCliProcessError(
    ctx: *const @import("tools/context.zig").ToolContext,
    detail: ?[]u8,
) void {
    const bytes = detail orelse return;
    if (ctx.error_detail) |slot| {
        slot.* = bytes;
    } else {
        ctx.allocator.free(bytes);
    }
}

/// 一个已连接 MCP server 的资源捆绑：name（owned）+ heap-allocated client + session。
/// session 内的 binding 指针指向同一个 client；client 必须比 session 活得久。
pub const McpSessionEntry = @import("core/mcp_session.zig").McpSessionEntry;

pub const PendingOverlay = enum { none, model_picker, transcript };

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
    // ── issue #16: the provider control plane this session talks to ─────────
    /// Registry + catalog + kernel, created on first use. Null until something
    /// asks for a provider view, so a session that never opens the picker pays
    /// nothing for it.
    provider_host: ?*provider_host_mod.Host = null,
    /// Cross-UI picker state. Present whether or not it is on screen, so a
    /// reopened picker does not have to refetch the catalog.
    model_picker: model_picker_mod.Picker = undefined,
    /// Strings a committed offer put into borrowing client fields. Owned here
    /// because `Client.base_url` and `api_key` are borrowed slices that must
    /// outlive every in-flight request.
    route_base_url_owned: ?[]u8 = null,
    route_secret_owned: ?[]u8 = null,
    /// A slash command asked for a full-region overlay. Commands are handled
    /// after the input reader returns, so the request is parked here and the
    /// next read consumes it.
    pending_overlay: PendingOverlay = .none,
    /// Last control-plane event projected into the TinyKG audit plane. Events
    /// are recorded once; a restart starts from the journal's current head
    /// rather than replaying a ring that may already have evicted.
    provider_audit_cursor: u64 = 0,
    /// 模型档位表(~/.metacodes/config.json 的 model_tiers;null=未配置)。
    model_tiers_table: ?@import("api/model_tiers.zig").TierTable = null,
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
    /// Canonical Skill Runtime; `skills` above is only its legacy-shaped
    /// presentation/preload projection.
    skill_runtime: skill_cli_adapter.Runtime,
    /// Host-admitted immutable plugin generation. The snapshot owns manifest
    /// descriptors/provenance and only projects bounded contributions into
    /// canonical registries; AgentLoop remains the sole orchestration owner.
    plugin_snapshot: ?*plugin_mod.runtime.Snapshot = null,
    read_state: ReadState,
    /// Edit/Write 旁路高亮缓存(tool_id → 新旧全文)。供 diff 工具卡 hl-zig 着色;
    /// 不进对话历史。session 退出 deinit。
    edit_hl_cache: @import("core/edit_hl_cache.zig").EditHlCache,
    /// LSP 服务(默认开;`--no-lsp` 或创建失败时为 null)。Edit/Write finalizeWrite 取诊断,
    /// CodeMap/FindSymbol/Read-outline 取符号。session 退出 shutdown。
    lsp_service: ?*@import("lsp/service.zig").Service = null,
    /// Session transcript writer；失败初始化则保持 null（日志落盘 fallback）
    transcript_writer: ?transcript.Writer = null,
    /// 本 session 累计用量（跨多 turn）
    usage: UsageTotals = .{},
    /// Internal-only large-result projection/recovery counters. Evaluation
    /// and formal observation adapters may snapshot these; no UI owns them.
    tool_result_metrics: @import("core/tool_result_metrics.zig").Metrics = .{},
    /// 本 session 的文件修改结果账本(见 core/file_change.zig)。Run 及其子执行产生的每条
    /// 文件修改都记这里,上层无需解析 tool_result 里工具私有的 gitDiff。
    ///
    /// **c_allocator 而非 app.allocator**:后台 subagent / swarm teammate 线程共享这个账本指针
    /// 并会往里写(见 agent.zig 三处 spawn 的 file_change_journal 透传)。Journal 的 mutex 只
    /// 串行化它自己的调用,串行化不了 allocator;App GPA 非线程安全(teammate.zig 头注已立此
    /// 铁律),拿它给 teammate 线程用就是堆损坏。init 在下面补上。
    file_change_journal: @import("core/file_change.zig").Journal = .{ .allocator = undefined },
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
    /// 额外工作目录(--add-dir / settings additionalDirectories),已解析为**绝对路径**、
    /// owned(app.allocator)。loadSettings 每次重建(先 free 旧);消费点:
    /// permission match_ctx.additional_dirs(accept_edits scope 门)+ ToolContext.additional_dirs
    /// (sandbox 可写白名单)。null = 无。
    additional_dirs_abs: ?[]const []const u8 = null,
    /// **配置变更事件出口(U4)**:driver(TUI/web)经 setConfigEventSink 设。model/dirs/reasoning
    /// 单写侧(switchModel/addDirectory/setReasoningEffort)经它 emit config_changed;mode 走
    /// permission_ctx.event_sink(setConfigEventSink 同步设)。null = 无 UI/headless(不 emit)。
    config_event_sink: ?@import("core/protocol/ui_event.zig").ConfigEventSink = null,
    /// **U5 B1:slice-safe snapshot 发布缓存**。UAF-critical slice(model/dirs)的 mutex 守护 owned dup，
    /// refresh 骑 emitConfig；/state(HTTP 线程)经 snapshotSlices 安全读。setConfigEventSink 装配时
    /// seed + 每 emit refresh。null 化在 deinit。见 SnapshotCache。
    snapshot_cache: ?SnapshotCache = null,
    /// 当前 TUI 主题(启动时根据 --no-theme + ColorCapability 选;/theme 可改)。
    theme: @import("repl/tui/theme.zig").Theme = @import("repl/tui/theme.zig").dark,
    /// 当前主题 variant(/theme 命令读它显示当前)。
    theme_variant: @import("repl/tui/theme.zig").Variant = .auto,
    /// 后台 Bash 作业注册表（失败初始化则 null）
    jobs: ?JobRegistry = null,
    /// 后台 subagent 作业注册表（Task run_in_background）。失败初始化则 null。
    agent_jobs: ?@import("core/agent_job_registry.zig").AgentJobRegistry = null,
    /// Swarm 会话状态（teams/teammates）。lead(主 App)持有;TeamCreate 时惰性建 teammates
    /// registry。teammate 不 spawn teammate → subagent 侧不挂 swarm。
    swarm: @import("swarm/context.zig").SwarmContext = undefined,
    /// 进入 plan 模式前的原 mode；ExitPlanMode 用它恢复
    plan_prev_mode: ?types.PermissionMode = null,
    /// 当前 session 的 plan 文件全路径(`{home}/.metacodes/plans/{slug}.md`,owned)。
    /// init 时算一次,挂到 permission_ctx.plan_file_path(plan 模式特许写)+ ToolContext。
    /// 空串 = home 缺失,plan 文件机制降级(模型把计划写对话文本)。
    plan_file_path: []u8 = &.{},
    /// 本 session 的 memdir 绝对路径(通道 B 自动记忆;`{home}/.metacodes/projects/<hash>/memory`,
    /// owned)。init 时算一次,挂 permission_ctx.memdir_abs(写豁免)。空串=禁用/无 home。
    memdir_abs: []u8 = &.{},
    /// TinyKG 客户端(记忆/计划/DAG;设计 KG_DESIGN v3-final)。null = 未初始化
    /// (缺 home 等);non-null 但 !ready = degraded。工具经 ctx.kg 拿指针。
    kg: ?@import("kg/client.zig").KgClient = null,
    /// per-project 指针目录 `{home}/.metacodes/projects/<hash>`(kg_root/kg_inbox 落此)。owned。
    kg_projects_dir: []u8 = &.{},
    /// KG 启动注入快照(kg/inject.zig;owned)。空串=空态(不注入)。
    kg_summary: []u8 = &.{},
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
            .model_picker = model_picker_mod.Picker.init(allocator),
            // 本会话身份(路由 + transcript 目录)。`--session <id>` 显式指定(subprocess resume 复用
            // 挂起 session 的目录,task#20);否则 gen 新的。非法/非 24-char id 回退 gen。
            .session_id = if (config.session_id) |s|
                (@import("core/session_id.zig").SessionId.fromSlice(s) orelse @import("core/session_id.zig").gen())
            else
                @import("core/session_id.zig").gen(),
            .conversation = Conversation.init(allocator),
            .file_change_journal = @import("core/file_change.zig").Journal.init(std.heap.c_allocator),
            .api_client = client_mod.Client.initWithBaseUrl(allocator, io, api_key, config.model, config.base_url),
            .tool_defs = &.{}, // 占位，下面重建
            .permission_ctx = permission_mod.createContext(config.permission_mode, allocator),
            .abort = AbortSignal.init(),
            .skills = SkillSet.init(allocator),
            .skill_runtime = skill_cli_adapter.Runtime.init(allocator, io),
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

        // OpenAI 后端:仅当 provider_kind==.openai 才建(chat/completions 或 Responses,
        // 按 config.openai_protocol 显式选择)。base_url 复用 config.base_url(record/replay
        // 指 MockServer);null → 按 protocol 选 OpenAI 官方端点。
        if (config.provider_kind == .openai) {
            app.openai_client = openai_mod.OpenAIClient.init(allocator, io, api_key, config.model, config.base_url);
            app.openai_client.?.protocol = config.openai_protocol;
            app.openai_client.?.auth_scheme = config.auth_scheme;
            app.openai_client.?.reasoning_effort = config.reasoning_effort;
            app.openai_client.?.overrides = buildOverridesFromConfig(config);
        }
        // Gemini 后端:仅当 provider_kind==.gemini 才建(讲 generateContent 协议 + 有状态缓存)。
        if (config.provider_kind == .gemini) {
            app.gemini_client = gemini_mod.GeminiClient.init(allocator, io, api_key, config.model, config.base_url);
            app.gemini_client.?.overrides = buildOverridesFromConfig(config);
        }

        // 启动时先事务化解析 CLI data packages，再由 canonical Runtime 一次性解析
        // enterprise / personal / project / plugin Skill sources。插件失败不降级：用户
        // 显式声明的 package 若不可信或 Host 不支持，启动必须 fail closed。
        const cwd_for_skills = @import("util/fs.zig").getCwd(allocator) catch null;
        defer if (cwd_for_skills) |c| allocator.free(c);
        if ((config.plugin_dirs != null or config.process_plugin_dirs != null) and cwd_for_skills == null)
            return error.GetCwdFailed;
        app.plugin_snapshot = try buildCliPluginSnapshot(
            allocator,
            cwd_for_skills orelse "",
            @import("platform").paths.homeDir() orelse "",
            config.plugin_dirs,
            config.process_plugin_dirs,
        );
        // Bind every App-owned provider path to one immutable resolver. The
        // clients are allocated before package discovery, but no model request
        // is admitted before this point. Snapshot destruction happens only
        // after clients, subagents, and swarm workers have drained.
        const app_dialect_resolver = if (app.plugin_snapshot) |snapshot|
            snapshot.dialectResolver()
        else
            dialect_mod.Resolver.builtin();
        app.api_client.dialect_resolver = app_dialect_resolver;
        // issue #16: the resolved offer's provider-declared auth scheme. Null
        // (no `--provider`) keeps the historical bearer header byte for byte.
        app.api_client.auth_scheme = config.auth_scheme;
        if (app.openai_client) |*client| client.dialect_resolver = app_dialect_resolver;
        if (app.gemini_client) |*client| client.dialect_resolver = app_dialect_resolver;
        const plugin_skill_sources = if (app.plugin_snapshot) |snapshot| snapshot.skill_sources else &.{};
        const plugin_agent_sources = if (app.plugin_snapshot) |snapshot| snapshot.agent_sources else &.{};
        if (cwd_for_skills) |cwd| {
            app.skill_runtime.loadDefaultWithExtraSources(
                cwd,
                @import("platform").paths.homeDir() orelse "",
                if (app.plugin_snapshot != null) "plugin-generation-1" else "",
                plugin_skill_sources,
                &app.skills,
            ) catch |err| {
                @import("util/log.zig").warn(
                    "skill",
                    "canonical catalog load failed: {s}",
                    .{@errorName(err)},
                );
            };
        }
        // 加载 subagent 定义(builtin + namespaced plugin + personal + project)
        app.agents.loadFromStandardPathsWithPluginSources(
            cwd_for_skills orelse "",
            plugin_agent_sources,
        ) catch |err| {
            if (app.plugin_snapshot != null) return err;
        };
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
            // ~/.metacodes/config.json 的 theme 字段覆盖默认 auto
            const home_for_theme: ?[]const u8 = blk: {
                break :blk @import("platform").paths.homeDir();
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

        // 模型档位表(model_tiers):同一份 ~/.metacodes/config.json。解析失败降级为
        // 未配置(档位名全 inherit)并告警——配置拼写错误不该炸启动,但绝不静默。
        if (@import("platform").paths.homeDir()) |home| {
            app.model_tiers_table = @import("api/model_tiers.zig").loadFromHome(allocator, home) catch |err| tier_err: {
                @import("util/log.zig").warn("config", "model_tiers 解析失败({s}),按未配置处理", .{@errorName(err)});
                break :tier_err null;
            };
        }

        // Session 级权限记忆挂到 permission_ctx(persist 路径复用 match_ctx.home/project_root,
        // 在 settings 加载处统一设,无需独立 persist context)。
        app.permission_ctx.session_rules = &app.session_rules;
        app.permission_ctx.session = app.session_id; // 权限对话框路由到本会话视图(M5/M6)

        // Model-facing Skill is present only when the canonical snapshot has
        // at least one model-invocable record.
        if (app.skill_runtime.hasModelInvocable()) {
            skill_tool_mod.registerSkillTool(&app.dyn_registry, &app.skill_runtime) catch |err| {
                @import("util/log.zig").warn("skill", "register Skill tool failed: {s}", .{@errorName(err)});
            };
        }

        // Process tools enter the CLI through its canonical typed dynamic
        // registry. Definitions borrow the immutable snapshot (destroyed only
        // after dyn_registry), while typed artifact receipts pass through the
        // same isolated adapter used by AgentRuntime without flattening.
        if (app.plugin_snapshot) |snapshot| {
            for (snapshot.process_tools) |*tool| {
                try app.dyn_registry.registerBorrowedDefinitionBody(
                    tool.definition,
                    executeCliProcessTool,
                    @ptrCast(@constCast(tool)),
                    .execute,
                );
            }
        }

        // 启动时尝试连接 config.json 里声明的 MCP servers。失败逐个 log，不影响启动。
        app.connectMcpServers() catch |err| {
            @import("util/log.zig").debug("mcp", "no servers connected: {s}", .{@errorName(err)});
        };

        // 现在构造完整的 tool_defs：静态 + 动态（Skill / MCP）+ web_search。
        // 先构造一次拿到全部工具名（含动态），据此建 PromptContext，再带 context 重建——
        // 让核心工具拿到动态长描述（对应 cc tool.prompt(ctx)）。
        // arena allocator：第一次的临时 defs 随 session 释放，不单独 free。
        // probe pass 用 teams-aware bootstrap ctx,让 enabled_names 与最终 tool_defs 的
        // swarm 门控一致(否则 --agent-teams 开时 "Using your tools" 段漏列 swarm 工具)。
        const probe_ctx = tools_mod.PromptContext{
            .agent_teams = config.agent_teams,
            .tinykg_enabled = config.long_horizon_arm.usesTinyKg(),
        };
        const probe_defs = try tools_mod.toToolDefinitionsFull(allocator, &app.dyn_registry, &probe_ctx);
        const enabled_names = try allocator.alloc([]const u8, probe_defs.len);
        for (probe_defs, 0..) |d, i| enabled_names[i] = d.name;
        app.enabled_tool_names = enabled_names;

        const prompt_ctx = tools_mod.PromptContext{
            .permission_mode = config.permission_mode,
            .enabled_tool_names = enabled_names,
            .agent_type = "", // 主对话
            .include_git = true,
            .agent_teams = config.agent_teams, // F5:门控 swarm 工具进 tool_defs
            .tinykg_enabled = config.long_horizon_arm.usesTinyKg(),
        };
        app.tool_defs = try tools_mod.toToolDefinitionsFull(allocator, &app.dyn_registry, &prompt_ctx);
        _ = app.skill_runtime.applyModelToolSchema(app.tool_defs);
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

        // 初始化 TinyKG(记忆/计划/DAG 真相源)。best-effort:失败 → kg=null/degraded,
        // 注入段不出现；允许 TinyKG 的 treatment 仍广告工具并显式返回 kg_unavailable。
        app.initKg();

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
        // Background jobs allocate and free from worker threads.  The session
        // arena is not thread-safe; keep the registry and all job-owned state
        // on c_allocator (the provider/agent_loop allocator must match too).
        app.agent_jobs = @import("core/agent_job_registry.zig").AgentJobRegistry.initWithDialectResolver(std.heap.c_allocator, app.api_key, config.base_url, app.config.model, app.config.provider_kind, app.config.openai_protocol, app_dialect_resolver) catch |err| blk: {
            @import("util/log.zig").warn("agent", "agent_jobs registry init failed: {s}", .{@errorName(err)});
            break :blk null;
        };
        // Child agents authenticate the way the parent's resolved route does.
        if (app.agent_jobs) |*jobs| jobs.auth_scheme = config.auth_scheme;

        // Swarm 会话状态(lead 视角)。teammates registry 惰性(TeamCreate 才建);此处只装
        // 构造参数 + home。api_key/base_url/model 借 App 生命周期稳定内存(App 存活期不变)。
        app.swarm = .{
            .allocator = allocator,
            .home = app.homeDir(),
            .api_key = app.api_key,
            .base_url = config.base_url,
            .model = app.config.model,
            .provider_kind = app.config.provider_kind,
            .openai_protocol = app.config.openai_protocol,
            .auth_scheme = app.config.auth_scheme,
            .dialect_resolver = app_dialect_resolver,
            .out_of_process = config.teammate_out_of_process, // SW6:--teammate-mode process
        };

        // LSP 服务(默认开,`--no-lsp` 关)。**建 Service ≠ 起 language server**:这里只装一个
        // 惰性管理器 + idle reaper 线程;真正 spawn 要等某个文件同时满足"有注册 server + 二进制
        // 已装 + 在 git workspace + 命中 root marker"。没装 server 的机器上默认开是零成本。
        // best-effort:创建失败仅 log,不阻断启动。
        // abort 适配:app.abort(AbortSignal)→ LSP 中立 AbortCheck,让 LSP 等待可 Ctrl+C 中断(M2)。
        if (config.lsp_enabled) {
            const lsp_abort = @import("lsp/transport.zig").AbortCheck{
                .ctx = @ptrCast(&app.abort),
                .isAbortedFn = struct {
                    fn f(c: *anyopaque) bool {
                        return @as(*const AbortSignal, @ptrCast(@alignCast(c))).isAborted();
                    }
                }.f,
            };
            app.lsp_service = @import("lsp/service.zig").Service.create(allocator, app.cwdAbs(), lsp_abort) catch |err| blk: {
                @import("util/log.zig").warn("lsp", "service init failed: {s} (LSP disabled)", .{@errorName(err)});
                break :blk null;
            };
            if (app.lsp_service != null) @import("util/log.zig").info("lsp", "language server integration enabled (disable with --no-lsp)", .{});
        }

        // 构造 system prompt。显式 display identity 只作用于模型自述/knowledge
        // cutoff；真实 transport model 仍独立驱动 provider、catalog、pricing 与 context。
        // 动态裁剪（对应 cc getUsingYourToolsSection(enabledTools)）。失败仅 log，保持 null。
        // 环境段 cwd 用进程 cwd(CLI 语义);Session 库消费方用 workspace.root(见 agent_session)。
        const cli_cwd = @import("util/fs.zig").getCwd(allocator) catch "";
        defer if (cli_cwd.len > 0) allocator.free(cli_cwd);
        app.system_prompt = system_prompt_mod.buildFull(allocator, app.config.model_display_name orelse app.config.model, &app.skills, &app.agents, app.enabled_tool_names, app.memdir_abs, app.kgReady(), cli_cwd) catch |err| blk: {
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
            .kg_summary = app.kg_summary,
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

    /// **当前活跃 model 的单一运行时真理源(U3)**:活跃 provider 的 client.model。
    /// client.model 是请求真正发送的 model(resolveMaxTokens/capability/请求体都读它),
    /// 故它是运行时真理;`config.model` 仅剩**启动快照**语义(parseArgs 设 → init 构造
    /// client/agent_jobs/system_prompt 的种子),**运行时一律读 activeModel(),不读 config.model**,
    /// 消除 switchModel"改一处漏一处"的 model 漂移。切换只更新 client,config.model 不再
    /// 跟着变。直接读活跃 client 的 .model 字段(const-safe,不走 provider() vtable——那要 *App)。
    pub fn activeModel(app: *const App) []const u8 {
        return switch (app.config.provider_kind) {
            .anthropic => app.api_client.model,
            .openai => app.openai_client.?.model,
            .gemini => app.gemini_client.?.model,
        };
    }

    /// 当前 provider 的模型档位表(low/mid/high)。未配置 → null(档位名全 inherit)。
    /// 返回指针借用 App 生命周期的表,启动后只读——后台 worker 线程读安全。
    pub fn activeModelTiers(app: *const App) ?*const @import("api/model_tiers.zig").ProviderTiers {
        const table = &(app.model_tiers_table orelse return null);
        return table.forKind(app.config.provider_kind);
    }

    /// 供 subagent ctx.api_client(web_search 是 Anthropic server tool,只 Anthropic 用)。
    /// 非 Anthropic provider → null(subagent 不能用 web_search,其余工具照常)。
    pub fn anthropicClientOrNull(app: *App) ?*client_mod.Client {
        return switch (app.config.provider_kind) {
            .anthropic => &app.api_client,
            else => null,
        };
    }

    pub fn deinit(app: *App) void {
        // 最先 drain 后台 subagent：abort 全部 running → join 全部线程 → free。
        // 必须早于任何共享资源（agents/dyn_registry/skills/allocator）释放，
        // 否则在跑的后台线程会触碰已释放内存（UAF）。job 用专属 Client，不依赖 api_client。
        if (app.agent_jobs) |*aj| aj.deinit();
        // Swarm:abort+join 全 teammate → free（必须早于共享资源释放，同 agent_jobs 理由）。
        app.swarm.deinit();
        if (app.transcript_writer) |*w| w.deinit();
        app.api_client.deinit();
        if (app.oauth_token_for_catalog) |tok| {
            @memset(tok, 0);
            app.allocator.free(tok);
        }
        app.api_key_catalog.deinit();
        app.model_picker.deinit();
        if (app.provider_host) |host| host.destroy();
        if (app.route_base_url_owned) |value| app.allocator.free(value);
        if (app.route_secret_owned) |value| {
            std.crypto.secureZero(u8, value);
            app.allocator.free(value);
        }
        if (app.selected_api_key_owned) |k| {
            @memset(k, 0);
            app.allocator.free(k);
        }
        if (app.model_switch_owned) |m| app.allocator.free(m);
        if (app.model_tiers_table) |*t| t.deinit();
        if (app.pending_previous_model_for_compact) |m| app.allocator.free(m);
        if (app.openai_client) |*oc| oc.deinit();
        if (app.gemini_client) |*gc| gc.deinit();
        app.file_change_journal.deinit();
        app.conversation.deinit();
        if (app.kg) |*k| k.deinit();
        if (app.kg_projects_dir.len > 0) app.allocator.free(app.kg_projects_dir);
        if (app.kg_summary.len > 0) app.allocator.free(app.kg_summary);
        app.allocator.free(app.tool_defs);
        if (app.active_skill) |*active| {
            active.deinit();
            app.active_skill = null;
            app.permission_ctx.active_skill = null;
        }
        app.skill_runtime.deinit();
        app.skills.deinit();
        app.read_state.deinit();
        app.edit_hl_cache.deinit();
        if (app.lsp_service) |svc| svc.shutdown(); // 关所有 language server + reaper 线程
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
        {
            var it = app.activated_tools.keyIterator();
            while (it.next()) |k| app.allocator.free(k.*);
            app.activated_tools.deinit();
        }
        if (app.project_dir) |p| app.allocator.free(p);
        if (app.plan_file_path.len > 0) app.allocator.free(app.plan_file_path);
        if (app.memdir_abs.len > 0) app.allocator.free(app.memdir_abs);
        app.agents.deinit();
        if (app.plugin_snapshot) |snapshot| snapshot.destroy();
        for (app.worktree_stack.items) |entry| {
            app.allocator.free(entry.worktree_path);
            app.allocator.free(entry.original_cwd);
        }
        app.worktree_stack.deinit(app.allocator);
        app.cron_registry.deinit();
        app.model_context.deinit();
        if (app.rule_set) |*r| r.deinit();
        if (app.settings) |*s| s.deinit();
        app.freeAdditionalDirs();
        if (app.snapshot_cache) |*c| c.deinit(); // U5 B1
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

    // ── issue #16: the cross-UI provider control plane ──────────────────────

    /// The session's provider kernel, created on first use.
    ///
    /// Every UI reads offers and commits selections through this one object.
    /// A client that built its own registry would be a second place identity is
    /// decided, and the two would disagree the moment either refreshed.
    pub fn providerHost(app: *App) !*provider_host_mod.Host {
        if (app.provider_host) |host| return host;
        const host = try provider_host_mod.Host.create(app.allocator);
        errdefer host.destroy();
        // Seed the durable revision and any previously committed global
        // selection, so `selection.commit` compares against the number the
        // store actually holds rather than an invented one.
        var store = provider_config_store.Store.initHome(app.allocator) catch {
            app.provider_host = host;
            return host;
        };
        defer store.deinit();
        host.adoptDurableState(&store);
        app.provider_host = host;
        return host;
    }

    /// Materialize the configured credential pool for the current session.
    ///
    /// The document holds only references — an id, an environment variable
    /// name, a kind, a priority — so reading it never touches a secret. The
    /// secrets are read here, from the process environment, and borrowed for
    /// the duration of request setup.
    fn credentialPool(
        app: *App,
        buffer: []provider_credential_mod.PoolEntry,
    ) []const provider_credential_mod.PoolEntry {
        var store = provider_config_store.Store.initHome(app.allocator) catch return &.{};
        defer store.deinit();
        var document = store.load() catch return &.{};
        defer document.deinit();

        const env = provider_credential_mod.EnvLookup.process();
        var len: usize = 0;
        for (document.providers.items) |entry| {
            if (!entry.enabled) continue;
            for (entry.credentials.items()) |credential| {
                if (len == buffer.len) break;
                const secret = env.get(credential.env.slice()) orelse continue;
                const kind = provider_credential_mod.parseCredentialKind(credential.kind.slice()) orelse continue;
                buffer[len] = .{
                    .id = credential.id,
                    .kind = kind,
                    .secret = secret,
                    .priority = credential.priority,
                    .account_or_plan = if (credential.account_or_plan) |label| label.slice() else null,
                    // Learned state from previous runs: a cooldown recorded
                    // here is why the next process skips the credential instead
                    // of rediscovering the same rate limit by hitting it.
                    .cooldown_until = credential.cooldown_until,
                    .status = if (credential.invalid) .invalid else .active,
                };
                len += 1;
            }
        }
        return buffer[0..len];
    }

    /// The profile a selection resolves to, if it is still in the catalog.
    fn resolvedProfileFor(
        host: *provider_host_mod.Host,
        selection: provider_selection_mod.RuntimeSelection,
    ) ?*const @import("provider/profile.zig").ProviderProfile {
        const resolution = provider_selection_mod.resolve(host.kernel.catalogSnapshot(), selection) catch
            return null;
        return host.registry.findById(resolution.primary().provider_id);
    }

    /// A live access token for a provider whose profile declares an OAuth
    /// lifecycle, refreshing through the shared single-flight session.
    ///
    /// Returns null for every profile that declares none — Metask keeps its
    /// historical `core/auth.zig` path byte for byte, and a provider with no
    /// token endpoint has no lifecycle to run.
    pub fn oauthAccessToken(
        app: *App,
        built: *const @import("provider/profile.zig").ProviderProfile,
        now_seconds: i64,
    ) !?[]u8 {
        const token_url = built.oauth_token_url orelse return null;
        var serves = false;
        for (built.accepted_credential_kinds) |kind| {
            if (provider_oauth_mod.servesKind(kind)) serves = true;
        }
        if (!serves) return null;

        var session = try provider_oauth_mod.Session.initHome(
            app.allocator,
            built.id,
            built.id,
        );
        defer session.deinit();
        // No stored login is not an error: the provider simply falls through to
        // its API-key aliases.
        if (!(session.load() catch false)) return null;

        var exchange = oauth_exchange_mod.HttpExchange{
            .allocator = app.allocator,
            .io = app.api_client.http_client.io,
            .endpoint = .{ .token_url = token_url, .client_id = built.id.slice() },
        };
        const before = session.generation;
        const token = try session.accessToken(now_seconds, exchange.exchange());

        // The session is the only thing that knows this credential's expiry, so
        // it is the only thing that can warn before a turn fails. A refresh
        // that happened is also a status change a UI may want to show.
        if (app.provider_host) |host| {
            if (session.tokens) |current| {
                if (current.expires_at - now_seconds <= provider_host_mod.Host.CREDENTIAL_EXPIRY_WARNING_SECONDS) {
                    host.kernel.noteCredentialExpiring(built.id, built.id, current.expires_at);
                }
            }
            if (session.generation != before) {
                host.kernel.noteAuthChanged(built.id, built.id, .active);
            }
        }
        return token;
    }

    /// Refresh the picker's snapshot from the kernel. Called when the picker
    /// opens and whenever the catalog moves underneath it.
    pub fn refreshModelPicker(app: *App) !void {
        const host = try app.providerHost();
        var page: std.ArrayList(provider_control_plane.OfferSummary) = .empty;
        defer page.deinit(app.allocator);
        const listed = host.kernel.modelList(.{}, .{}, app.allocator, &page) catch {
            app.model_picker.markFailed();
            return;
        };
        try app.model_picker.adopt(listed, host.kernel.currentOfferId());
    }

    /// Apply a picker commit: validate through the kernel, bind the winning
    /// offer to real transport parameters, and only then move the session onto
    /// it. A rejection at any step leaves the previous runtime untouched, which
    /// is why nothing is mutated until the binding exists.
    pub fn commitModelSelection(
        app: *App,
        commit: model_picker_mod.Commit,
    ) !provider_control_plane.CommitOutcome {
        const host = try app.providerHost();
        var candidate = provider_selection_mod.RuntimeSelection.pinned(
            commit.offer_id,
            commit.offer_revision,
            commit.scope,
        );
        candidate.controls = commit.controls;

        const outcome = host.kernel.selectionCommit(.{
            .expected_config_revision = null,
            .expected_catalog_revision = null,
        }, candidate, commit.scope);
        switch (outcome) {
            .committed => |accepted| {
                try app.bindCommittedSelection(host, accepted.selection);
                if (accepted.requires_persist) try app.persistGlobalSelection(host, accepted.selection);
                // A session-scoped choice is durable *for this session*: it has
                // to survive a resume, and it must not reach any other session,
                // which is why it goes to the session's own file.
                if (accepted.scope == .session) app.persistSessionSelection(accepted.selection) catch {};
            },
            // The kernel already refused; the old runtime is still the live one.
            .rejected, .conflict => {},
        }
        return outcome;
    }

    /// `<session_dir>/runtime-selection.json`. Null when this session has no
    /// transcript directory, which is the case for one-shot and headless runs
    /// where there is nothing to resume into.
    fn sessionSelectionStore(app: *App) ?provider_config_store.Store {
        const writer = app.transcript_writer orelse return null;
        return provider_config_store.Store.initSessionFile(app.allocator, writer.dir) catch null;
    }

    fn persistSessionSelection(
        app: *App,
        selection: provider_selection_mod.RuntimeSelection,
    ) !void {
        var store = app.sessionSelectionStore() orelse return;
        defer store.deinit();
        _ = try provider_config_store.setSessionSelection(&store, selection, null, null);
    }

    /// Restore this session's own selection, if it committed one before.
    ///
    /// Ordering against the global selection is deliberate: session scope is
    /// narrower, so it wins. A resumed session continues on the route it was
    /// using, not on whatever became global in the meantime.
    pub fn restoreSessionSelection(app: *App) !bool {
        var store = app.sessionSelectionStore() orelse return false;
        defer store.deinit();
        var document = store.load() catch return false;
        defer document.deinit();
        const selection = document.session_selection orelse return false;

        const host = try app.providerHost();
        const outcome = host.kernel.selectionCommit(.{}, selection, .session);
        switch (outcome) {
            .committed => |accepted| {
                try app.bindCommittedSelection(host, accepted.selection);
                return true;
            },
            // A stored session route that no longer resolves is reported by the
            // caller, not silently replaced with a different vendor.
            .rejected, .conflict => return error.SessionSelectionUnavailable,
        }
    }

    fn persistGlobalSelection(
        app: *App,
        host: *provider_host_mod.Host,
        selection: provider_selection_mod.RuntimeSelection,
    ) !void {
        var store = try provider_config_store.Store.initHome(app.allocator);
        defer store.deinit();
        const result = try provider_config_store.setGlobalSelection(
            &store,
            selection,
            null,
            null,
        );
        // The store is the sole authority for this number; feeding it back is
        // what keeps `expected_config_revision` meaningful on the next commit.
        host.kernel.adoptConfigRevision(result.config_revision);
    }

    /// Move the live session onto a committed selection.
    ///
    /// Ordering is the correctness argument. Everything that can fail happens
    /// before anything is mutated, the model mirrors move through the existing
    /// `switchModel` seam, and only infallible transport assignment follows —
    /// so there is no state in which the model is new and the endpoint is old.
    fn bindCommittedSelection(
        app: *App,
        host: *provider_host_mod.Host,
        selection: provider_selection_mod.RuntimeSelection,
    ) !void {
        var reference_buffer: [provider_ids_mod.MAX_SLUG_LEN]u8 = undefined;
        const now = @import("util/time.zig").nowUnix();

        // An OAuth provider's live access token is obtained (and refreshed, and
        // persisted) before resolution, so the resolver sees ordinary stored
        // material and the OAuth lifecycle stays in one place.
        var oauth_token: ?[]u8 = null;
        defer if (oauth_token) |value| {
            std.crypto.secureZero(u8, value);
            app.allocator.free(value);
        };
        if (resolvedProfileFor(host, selection)) |built| {
            oauth_token = app.oauthAccessToken(built, now) catch null;
        }

        // The configured credential pool. Secrets come from the named
        // environment variables, never from the config document: that document
        // is read by several tools and is not mode 0600.
        var pool_buffer: [provider_config_doc.MAX_POOL_CREDENTIALS]provider_credential_mod.PoolEntry = undefined;
        const pool = app.credentialPool(&pool_buffer);

        const binding = try provider_binding_mod.bind(
            &host.registry,
            host.kernel.catalogSnapshot(),
            selection,
            .{
                .pool = pool,
                .cli_api_key = app.config.api_key,
                .stored_oauth = if (oauth_token) |value| .{
                    .kind = .openai_oauth,
                    .secret = value,
                } else null,
                .precedence = if (oauth_token != null) .oauth_first else .api_key_first,
                .env = @import("provider/credential.zig").EnvLookup.process(),
                .now_seconds = now,
            },
            &reference_buffer,
        );

        const endpoint = try app.allocator.dupe(u8, binding.endpoint_url);
        errdefer app.allocator.free(endpoint);
        const secret = try app.allocator.dupe(u8, binding.secret);
        errdefer {
            std.crypto.secureZero(u8, secret);
            app.allocator.free(secret);
        }

        // Background subagents build their own provider from the registry's
        // copy of the route. `setRoute` moves key, endpoint, transport, and
        // auth scheme together — a registry holding this provider's key while
        // still pointing at the previous provider's endpoint would send the
        // credential to the wrong vendor. It allocates before it swaps, so a
        // failure here leaves the previous route intact.
        const previous_key = app.api_key;
        const previous_url = app.config.base_url;
        const previous_kind = app.config.provider_kind;
        const previous_protocol = app.config.openai_protocol;
        const previous_scheme = app.config.auth_scheme;
        var jobs_rerouted = false;
        // Function-scoped so it also covers a failure in `switchModel` below;
        // a block-scoped errdefer would have already gone out of scope by then,
        // leaving the registry on the new route while the session is on the old.
        errdefer if (jobs_rerouted) {
            if (app.agent_jobs) |*jobs| jobs.setRoute(
                previous_key,
                previous_url,
                previous_kind,
                previous_protocol,
                previous_scheme,
            ) catch {};
        };
        if (app.agent_jobs) |*jobs| {
            try jobs.setRoute(secret, endpoint, binding.transport, binding.openai_protocol, binding.auth_scheme);
            jobs_rerouted = true;
        }

        // The target transport must exist before the model seam runs, or the
        // new client would never receive the model.
        const io = app.api_client.http_client.io;
        switch (binding.transport) {
            .anthropic => {},
            .openai => if (app.openai_client == null) {
                app.openai_client = openai_mod.OpenAIClient.init(
                    app.allocator,
                    io,
                    secret,
                    binding.request_model_id,
                    endpoint,
                );
                app.openai_client.?.dialect_resolver = app.api_client.dialect_resolver;
                app.openai_client.?.overrides = buildOverridesFromConfig(app.config);
            },
            .gemini => if (app.gemini_client == null) {
                app.gemini_client = gemini_mod.GeminiClient.init(
                    app.allocator,
                    io,
                    secret,
                    binding.request_model_id,
                    endpoint,
                );
                app.gemini_client.?.dialect_resolver = app.api_client.dialect_resolver;
                app.gemini_client.?.overrides = buildOverridesFromConfig(app.config);
            },
        }

        try app.switchModel(binding.request_model_id);

        // From here on nothing can fail, so the switch is all-or-nothing.
        //
        // Order matters the same way it does in `switchModel`: the old endpoint
        // and secret are what the live clients currently point at, and a
        // background request thread can read those fields at any moment. Every
        // borrower is repointed first; only then is the old memory released, so
        // there is no window in which a reader can observe a freed slice.
        const retired_url = app.route_base_url_owned;
        const retired_secret = app.route_secret_owned;
        app.route_base_url_owned = endpoint;
        app.route_secret_owned = secret;

        app.config.provider_kind = binding.transport;
        app.config.openai_protocol = binding.openai_protocol;
        app.config.auth_scheme = binding.auth_scheme;
        // `config` is the snapshot subagent and swarm workers are constructed
        // from, so it has to move with the route or a spawned worker would dial
        // the previous provider's endpoint.
        app.config.base_url = endpoint;
        app.api_key = secret;
        app.api_client.api_key = secret;
        app.api_client.base_url = endpoint;
        app.api_client.auth_scheme = binding.auth_scheme;
        if (app.openai_client) |*client| {
            client.api_key = secret;
            client.base_url = endpoint;
            client.protocol = binding.openai_protocol;
            client.auth_scheme = binding.auth_scheme;
        }
        if (app.gemini_client) |*client| {
            client.api_key = secret;
            client.base_url = endpoint;
        }
        // Every out-of-process UI learns the *route*, not just the model name: a
        // visible model name can come from several providers, channels,
        // protocols, and accounts, so broadcasting only the name would announce
        // a change a Web or CLI client cannot tell apart from another.
        {
            const rendered = binding.offer_id.render();
            app.emitConfig(.{ .route = .{
                .provider_id = binding.provider_id.slice(),
                .channel_id = binding.channel_id.slice(),
                .protocol = binding.protocol.id(),
                .request_model_id = binding.request_model_id,
                .offer_id = &rendered,
                .credential_ref = if (binding.credential_ref.id.len > 0)
                    binding.credential_ref.id.slice()
                else
                    null,
                .scope = @tagName(selection.scope),
            } });
        }

        // Swarm teammates are constructed from this context when they spawn, so
        // it has to move with the route: a teammate started after a switch must
        // not dial the previous provider with this provider's credential.
        app.swarm.api_key = secret;
        app.swarm.base_url = endpoint;
        app.swarm.provider_kind = binding.transport;
        app.swarm.openai_protocol = binding.openai_protocol;
        app.swarm.auth_scheme = binding.auth_scheme;

        // Every borrower now points at the new strings.
        if (retired_url) |old| app.allocator.free(old);
        if (retired_secret) |old| {
            std.crypto.secureZero(u8, old);
            app.allocator.free(old);
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

    /// **U3 单一真理源写侧 seam**:把 model 同步到全部值镜像。抽成独立函数(不依赖 io/App
    /// 整体)以便 L2 锁"所有镜像同步"不变式——纯 grep 验证会漏(swarm.model 就漏过,Linus U3 抓)。
    /// 镜像清单(加/删 model 存储处必改此表 + 对应断言):
    ///   api_client / openai_client / gemini_client —— 各 provider 的 client.model(请求真理源,借用)
    ///   transcript_writer.model —— meta.json 记 flush 时 model(借用)
    ///   agent_jobs —— subagent 用(内部 dupe 自持;OOM 可失败,故放最前)
    ///   swarm.model —— teammate spawn 无 override 时的 provider model(借用;U3 前漏同步→teammate 跑陈旧启动 model)
    /// **不含**:config.model(启动快照,运行时不读)/system_prompt(派生,switchModel 重建)/usage anchor(作废重建)。
    /// model 必须是调用方持有、App 生命周期稳定的串(switchModel 传 model_switch_owned)。
    fn syncModelMirrors(
        model: []const u8,
        api_client: *client_mod.Client,
        openai_client: ?*openai_mod.OpenAIClient,
        gemini_client: ?*gemini_mod.GeminiClient,
        transcript_writer: ?*transcript.Writer,
        agent_jobs: ?*@import("core/agent_job_registry.zig").AgentJobRegistry,
        swarm: *@import("swarm/context.zig").SwarmContext,
    ) !void {
        // agent_jobs 内部 dupe，可 OOM → 最前，失败时其它镜像未动(最小一致)。
        if (agent_jobs) |aj| try aj.setModel(model);
        api_client.setModel(model); // task#13:锁内写 {ptr,len},不与后台降级路径读撕裂
        if (openai_client) |oc| oc.model = model;
        if (gemini_client) |gc| gc.model = model;
        if (transcript_writer) |w| w.model = model;
        swarm.model = model;
    }

    pub fn switchModel(app: *App, model_id: []const u8) !void {
        // U3:运行时当前 model 读 activeModel()(活跃 client),非 config.model(仅启动快照)。
        // 必须在更新 client 前读——此刻 activeModel() 返回旧 model(client 未更新)。
        const previous_model = app.activeModel();
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

        const sp_mod = @import("core/system_prompt.zig");
        const sw_cwd = @import("util/fs.zig").getCwd(app.allocator) catch "";
        defer if (sw_cwd.len > 0) app.allocator.free(sw_cwd);
        // The startup display identity is bound to the startup transport route.
        // An explicit /model switch selects a new real model and must not keep
        // advertising the old backend identity.
        const new_system_prompt = sp_mod.buildFull(app.allocator, model, &app.skills, &app.agents, app.enabled_tool_names, app.memdir_abs, app.kgReady(), sw_cwd) catch null;

        // U3:先同步全部 model 值镜像(seam,不含 config.model=启动快照/system_prompt=派生重建/
        // usage anchor=作废重建),**再** free 旧 model_switch_owned。
        // **顺序关键(Linus U3 nitpick,消 freed-read UAF)**:旧 model_switch_owned(X)= 当前
        // api_client.model 指向的串;若先 free(X) 再由 seam 改指针,中间 HTTP 线程读 activeModel()
        // (=api_client.model)会读到**已 free 内存**(UB,非仅陈旧值)。seam 先把所有镜像刷成
        // 新 model → X 只剩 model_switch_owned 引用 → 此后 free 才安全。agent_jobs.setModel 可
        // OOM(放 seam 最前),失败时其它镜像与旧 X 都未动,errdefer 只释放新 dupe。
        try syncModelMirrors(
            model,
            &app.api_client,
            if (app.openai_client) |*oc| oc else null,
            if (app.gemini_client) |*gc| gc else null,
            if (app.transcript_writer) |*w| w else null,
            if (app.agent_jobs) |*aj| aj else null,
            &app.swarm,
        );
        // 镜像已全指向新 model → 旧 X 只剩此引用,现在 free 安全(无 freed-read 窗口)。
        if (app.model_switch_owned) |old| app.allocator.free(old);
        app.model_switch_owned = model;
        // usage 锚点是旧模型 tokenizer 实计的,跨模型不可比(tokenizer 差异可达 ±20%)
        // → 作废,下一轮新模型的 usage 自动重建。
        app.conversation.invalidateUsageAnchor();

        if (app.pending_previous_model_for_compact) |old| app.allocator.free(old);
        app.pending_previous_model_for_compact = previous_model_copy;
        app.pending_previous_model_context_window = if (needs_previous_model_compact) previous_window else null;
        app.pending_current_model_context_window = if (needs_previous_model_compact) current_window else null;

        // U4:model 单写侧 emit(syncModelMirrors 后,activeModel() 已是新值)。
        app.emitConfig(.{ .model = app.activeModel() });

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

    pub fn setReasoningEffort(app: *App, effort: types.ReasoningEffort) !void {
        try app.provider().setReasoningEffort(effort);
        app.config.reasoning_effort = effort;
        app.emitConfig(.{ .reasoning = effort }); // U4:reasoning 单写侧 emit
    }

    /// 覆盖方言字段(temperature/top_p/prompt_cache_key/parallel_tool_calls/response_format)。
    /// 非 null 字段 = 显式覆盖,null = 不变。provider 不支持(Anthropic)→ setRequestOverrides 返 error,
    /// 上层打印警告。reasoning_effort 不走此(它有独立 setter,保持单写侧 emit 路径)。
    pub fn setRequestOverrides(app: *App, o: request_overrides.RequestOverrides) !void {
        try app.provider().setRequestOverrides(o);
        // 同步 config(持久化 + /overrides 显示用)
        if (o.temperature != null) app.config.temperature = o.temperature;
        if (o.top_p != null) app.config.top_p = o.top_p;
        if (o.prompt_cache_key != null) app.config.prompt_cache_key = o.prompt_cache_key;
        if (o.parallel_tool_calls != null) app.config.parallel_tool_calls = o.parallel_tool_calls;
        if (o.response_format != null) {
            // response_format 是 enum,config 存字符串形式
            const rf_str: ?[]const u8 = switch (o.response_format.?.kind) {
                .json_object => "json_object",
                .json_schema => "json_schema",
                .none => null,
            };
            if (rf_str) |s| app.config.response_format = s;
        }
    }

    /// 清所有方言覆盖(全 null)。provider 不支持则静默跳过(无覆盖可清)。
    pub fn clearRequestOverrides(app: *App) void {
        app.provider().setRequestOverrides(.{}) catch {};
        app.config.temperature = null;
        app.config.top_p = null;
        app.config.prompt_cache_key = null;
        app.config.parallel_tool_calls = null;
        app.config.response_format = null;
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
        stored.selected_model = app.allocator.dupe(u8, app.activeModel()) catch return; // U3:持久化当前 model
        stored.reasoning_effort = app.config.reasoning_effort;
        auth_mod.saveDefault(app.allocator, stored) catch |err| {
            @import("util/log.zig").warn("auth", "persist selection failed: {s}", .{@errorName(err)});
        };
    }

    /// 前台开新空会话时轮换会话身份:新 session_id + 指向新目录的 transcript writer,
    /// 权限路由键同步(R3-1,Ctrl+B 转后台路径用)。**必须换 writer**:旧 writer 的
    /// flushed_count/seen_shrink_epoch 属于旧历史,fresh conversation(epoch=0)复用它
    /// 会在下一次 flush 把旧 transcript 整个重写成新会话的寥寥数条(历史被毁;修前则是
    /// 错位追加)。换 id + 新 writer 后旧 transcript 目录原样封存(仍可 /resume)。
    /// writer 重建失败非致命(warn,transcript 停写——与启动失败同语义)。
    pub fn rotateSessionIdentity(app: *App) void {
        app.session_id = transcript.genSessionId();
        app.permission_ctx.session = app.session_id;
        if (app.transcript_writer) |*w| w.deinit();
        app.transcript_writer = null;
        app.initTranscriptWriter() catch |err| {
            @import("util/log.zig").warn("transcript", "rotate writer failed: {s}", .{@errorName(err)});
        };
        // R4-3:goal 属于被转走的旧会话——不清则旧 goal 记进新会话目录、用量记错账,
        // /resume 旧会话时又读到陈旧快照。新会话从无 goal 起步(对齐"新空会话"语义)。
        app.goal_state.clearInMemory();
        // 已知残留(R4-2,存量收窄未闭):Ctrl+B 时若有 active skill,其 ExecutionState
        // 仍挂在旧 id 下(后续 clearActiveSkill 用新 id 注销不到 → 泄漏到 App deinit);
        // 且后台 job 按值拷走的 permission_ctx.active_skill 借着该投影——此处**不能**
        // 注销旧 id(会毁掉后台正读的投影 = UAF)。正确修法是 spawn 时深拷/引用计数
        // 投影,见 follow-up。
    }

    fn initTranscriptWriter(app: *App) !void {
        // HOME
        const home = @import("platform").paths.homeDir() orelse return error.NoHome;

        const cwd = try @import("util/fs.zig").getCwd(app.allocator);
        defer app.allocator.free(cwd);

        // session_id 传入,使 transcript 目录名 == App.session_id(统一,不再两个独立 gen)。
        const w = try transcript.Writer.init(app.allocator, cwd, home, app.activeModel(), app.session_id);
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
        if (!app.config.long_horizon_arm.usesAutoMemory(memdir.isEnabled())) return;
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

    /// KG 就绪判定(kg 非 null 且 ready)。system prompt 用它决定是否声明图谱与
    /// Markdown→KG 投影；工具广告则由 long_horizon_arm 的 typed treatment 门控。
    pub fn kgReady(app: *const App) bool {
        if (app.kg) |*k| return k.ready;
        return false;
    }

    /// Default cooldown for a rate-limited credential. Long enough that the
    /// next turn does not walk straight back into the limit, short enough that
    /// a brief burst does not retire an account for the session.
    pub const CREDENTIAL_COOLDOWN_SECONDS: i64 = 5 * 60;

    /// Record a failed request against the credential that made it.
    ///
    /// The class is the provider's own classification, not a guess: profiles
    /// already own `classify_error`, and the difference between "slow down" and
    /// "this key is dead" is exactly the difference between a cooldown and an
    /// invalidation. Durable, because a limit rediscovered every run is a limit
    /// never learned.
    pub fn noteCredentialFailure(
        app: *App,
        provider_id: provider_ids_mod.Slug,
        credential_id: provider_ids_mod.Slug,
        class: provider_credential_mod.FailureClass,
    ) void {
        if (class == .transient) return;
        var store = provider_config_store.Store.initHome(app.allocator) catch return;
        defer store.deinit();
        const result = provider_config_store.noteCredentialFailure(
            &store,
            provider_id,
            credential_id,
            class,
            @import("util/time.zig").nowUnix(),
            CREDENTIAL_COOLDOWN_SECONDS,
            null,
        ) catch return;
        if (app.provider_host) |host| {
            host.kernel.adoptConfigRevision(result.config_revision);
            host.kernel.noteAuthChanged(
                provider_id,
                credential_id,
                if (class == .invalid) .invalid else .active,
            );
        }
    }

    /// Enable, disable, or remove a provider instance through the control
    /// plane, and re-apply the result to the live catalog.
    ///
    /// Disabling preserves the instance's configuration and credential
    /// references; removing does not. Both take effect in every UI at once,
    /// because they change the catalog every UI reads.
    pub fn setProviderEnabled(app: *App, id: provider_ids_mod.Slug, enabled: bool) !void {
        var store = try provider_config_store.Store.initHome(app.allocator);
        defer store.deinit();
        const result = try provider_config_store.setProviderEnabled(&store, id, enabled, null);
        try app.reapplyProviderConfiguration(&store, result.config_revision);
    }

    pub fn removeProviderConfiguration(app: *App, id: provider_ids_mod.Slug) !void {
        var store = try provider_config_store.Store.initHome(app.allocator);
        defer store.deinit();
        const result = try provider_config_store.removeProvider(&store, id, null);
        try app.reapplyProviderConfiguration(&store, result.config_revision);
    }

    fn reapplyProviderConfiguration(
        app: *App,
        store: *const provider_config_store.Store,
        revision: provider_ids_mod.ConfigRevision,
    ) !void {
        const host = try app.providerHost();
        host.kernel.adoptConfigRevision(revision);
        var document = try store.load();
        defer document.deinit();
        try host.applyProviderConfiguration(&document);
    }

    /// Resolve a local alias and switch this session onto it.
    ///
    /// A pinned alias means the same route it always did; a floating one
    /// re-resolves and records where it landed, so a route stays attributable
    /// after the fact. Either way the resulting selection is *pinned* — the
    /// alias already decided, and leaving it auto would let it re-resolve
    /// mid-turn against a catalog the user never saw.
    pub fn useAlias(app: *App, name: []const u8) !bool {
        var store = provider_config_store.Store.initHome(app.allocator) catch return false;
        defer store.deinit();
        var document = store.load() catch return false;
        defer document.deinit();
        const entry = document.alias(name) orelse return false;

        const host = try app.providerHost();
        const resolution = try provider_alias_mod.resolve(host.kernel.catalogSnapshot(), entry);
        const selection = provider_alias_mod.selectionFor(resolution, .session);

        const outcome = host.kernel.selectionCommit(.{}, selection, .session);
        switch (outcome) {
            .committed => |accepted| try app.bindCommittedSelection(host, accepted.selection),
            .rejected, .conflict => return error.AliasUnavailable,
        }
        // A floating alias that never records where it went cannot explain a
        // route after the fact.
        if (resolution.moved) {
            _ = provider_config_store.setAlias(
                &store,
                provider_alias_mod.updated(entry, resolution),
                null,
                null,
            ) catch {};
        }
        return true;
    }

    /// Refresh provider catalogs named by `provider_catalogs` over the network.
    ///
    /// The config may give either files or URLs; the host already handles
    /// files, so this fills in the URLs. A refresh that fails leaves the
    /// previous catalog in place — a stale catalog is a far better answer than
    /// an empty one, and every pin stays resolvable because offer ids are
    /// derived from the stable binding.
    ///
    /// Returns the number of providers refreshed.
    pub fn refreshProviderCatalogs(app: *App) !usize {
        var store = provider_config_store.Store.initHome(app.allocator) catch return 0;
        defer store.deinit();
        const text = store.readText() catch return 0;
        defer app.allocator.free(text);

        var arena = std.heap.ArenaAllocator.init(app.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const root = std.json.parseFromSliceLeaky(std.json.Value, scratch, text, .{}) catch return 0;
        if (root != .object) return 0;
        const section = root.object.get("provider_catalogs") orelse return 0;
        if (section != .object) return 0;

        const host = try app.providerHost();
        const io = app.api_client.http_client.io;
        var refreshed: usize = 0;

        var it = section.object.iterator();
        while (it.next()) |pair| {
            const entry = pair.value_ptr.*;
            if (entry != .object) continue;
            const models_url = stringField(entry.object.get("models_url")) orelse continue;
            const provider_id = provider_ids_mod.Slug.parse(pair.key_ptr.*) catch continue;
            const bearer = if (stringField(entry.object.get("credential_env"))) |name|
                provider_credential_mod.EnvLookup.process().get(name)
            else
                null;

            const models = @import("api/catalog_fetch.zig").fetch(app.allocator, io, .{
                .url = models_url,
                .bearer = bearer,
            }) catch continue;
            defer app.allocator.free(models.body);

            var documents: std.ArrayList([]const u8) = .empty;
            defer {
                for (documents.items) |document| app.allocator.free(@constCast(document));
                documents.deinit(app.allocator);
            }
            if (entry.object.get("endpoint_urls")) |list| {
                if (list == .array) {
                    for (list.array.items) |item| {
                        const url = stringField(item) orelse continue;
                        const document = @import("api/catalog_fetch.zig").fetch(app.allocator, io, .{
                            .url = url,
                            .bearer = bearer,
                        }) catch continue;
                        try documents.append(app.allocator, document.body);
                    }
                }
            }

            host.ingestOpenRouter(provider_id, models.body, documents.items) catch continue;
            refreshed += 1;
        }
        return refreshed;
    }

    /// Project the provider control plane's new events into the TinyKG audit
    /// plane (issue #16).
    ///
    /// Called at a turn boundary, never on the request path. The audit plane is
    /// optional in the strongest sense: no route resolution, credential
    /// resolution, or request setup calls this, and a TinyKG outage is counted
    /// rather than propagated.
    ///
    /// Only *decisions* are recorded — which offer was accepted, which route a
    /// turn actually took, which selection failed and why — because the event
    /// payloads are ids and enums by construction, with no field a prompt,
    /// token, or provider body could travel in.
    pub fn auditProviderDecisions(app: *App) kg_provider_audit.Summary {
        const host = app.provider_host orelse return .{};
        const client = if (app.kg) |*value| value else return .{};
        if (!client.ready) return .{};

        var events: std.ArrayList(provider_control_plane.ControlPlaneEvent) = .empty;
        defer events.deinit(app.allocator);
        const replay = host.kernel.replayEvents(app.provider_audit_cursor, app.allocator, &events) catch
            return .{};
        if (replay.events.len == 0) return .{};
        app.provider_audit_cursor = replay.events[replay.events.len - 1].stream_sequence;

        const Bridge = struct {
            client: *@import("kg/client.zig").KgClient,
            fn append(ctx: *anyopaque, line: []const u8, schema_type: []const u8) anyerror!u64 {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                // `.decision` is what these are, and session-scoped rather than
                // global: this machine's routing choices are not shared project
                // knowledge.
                return self.client.remember(.decision, line, schema_type, false);
            }
        };
        var bridge = Bridge{ .client = client };
        return kg_provider_audit.recordAll(
            .{ .ctx = @ptrCast(&bridge), .appendFn = Bridge.append },
            replay.events,
        );
    }

    /// Versioned immutable plugin inventory for CLI/Web/embedding Hosts.
    pub fn describePlugins(app: *const App, allocator: std.mem.Allocator) ![]u8 {
        return if (app.plugin_snapshot) |snapshot|
            snapshot.describe(allocator)
        else
            plugin_mod.runtime.emptyInventory(allocator);
    }

    /// 初始化 TinyKG(设计 v3-final §1 D2、§6)。best-effort:任何步骤失败都不致命。
    /// P1:同步 ensureReady + 同步注入摘要(本地未竞争 store 为毫秒级)。
    /// **P2 待办**:移到后台线程(锁竞争最坏 35s;设计 §5 要求启动零阻塞)——已记账。
    fn initKg(app: *App) void {
        if (!app.config.long_horizon_arm.usesTinyKg()) return;
        const home = app.homeDir();
        const cwd = app.cwdAbs();
        if (home.len == 0 or cwd.len == 0) return;

        // **domain/指针目录都锚定 git 根**(H5:同一仓库无论从哪个子目录启动都是同一
        // domain,否则记忆按 cwd 碎片化——BM25/隔离/global 全建立在"一仓一 domain"上)。
        // project_dir = findRepoRoot(沿 cwd 上溯 .git);非 git repo 退 cwd。
        const anchor = app.project_dir orelse cwd;
        const anchor_hash = @import("core/transcript.zig").hashCwd(anchor);
        app.kg_projects_dir = std.fmt.allocPrint(app.allocator, "{s}/.metacodes/projects/{s}", .{ home, anchor_hash[0..] }) catch return;
        // **必须建目录**(Linus H1):否则从 git 子目录启动时 anchor_hash != cwd_hash,
        // projects/<anchor_hash> 无人 mkdir → plan 落图的 kg_root 指针 writeIdPointer 失败
        // 被 catch{} 吞 → frontier 永不呈现 → 整个 P2 跨会话恢复静默半死。逐级 mkdir。
        mkdirKgProjectsDir(app.allocator, home, anchor_hash);

        // domain = git 根 basename + git 根 hash 前 8(可读 + 防撞)。
        const domain_override: ?[]const u8 = if (std.c.getenv("METACODES_KG_DOMAIN")) |value|
            std.mem.span(value)
        else
            null;
        const domain = app.computeKgDomain(anchor, anchor_hash, domain_override) catch |err| {
            @import("util/log.zig").warn("kg", "project domain override rejected: {s}", .{@errorName(err)});
            return;
        };
        defer app.allocator.free(domain);

        var client = @import("kg/client.zig").KgClient.init(app.allocator, .{
            .home = home,
            .domain = domain,
            .config_bin = null, // config.json kg_bin(P2 接线)
            .config_store = null,
            .exe_dir = app.config.exe_dir, // argv[0] 解析(H1:vendor 定位现在真可达)
            .io = app.api_client.http_client.io,
        }) catch return;
        client.ensureReady();
        app.kg = client;

        // 注入摘要(空态零输出)。
        if (client.ready) {
            const inject = @import("kg/inject.zig");
            if (inject.buildSummaryForAgent(app.allocator, &app.kg.?, app.kg_projects_dir, app.session_id.asSlice())) |sum| {
                app.kg_summary = sum;
            }
            // 跨会话重建 TaskTab 显示缓存:把 inbox 里未完成的 todo 镜像进内存 store,
            // 让上次会话建的持久任务重启后仍在面板/TaskList 可见(PM P0-A:图为真相,
            // store 为显示缓存;不重建 → 重启后面板空、跨会话连续性只在图里用户看不见)。
            rebuildInboxMirror(app);
        } else {
            // KG 降级:启用 TaskStore 文件镜像,让 swarm teammate 看到 lead 的任务
            // (Bug ② 修复:KG 降级时 TaskCreate 退内存 store,而内存 store 进程隔离 →
            // teammate 永远看不到 lead 任务。mirror 文件作 KG 降级时的共享后备)。
            // 路径与 kg_projects_dir 同目录,文件名 tasks.json。
            const mirror_path = std.fmt.allocPrint(
                app.allocator,
                "{s}/tasks.json",
                .{app.kg_projects_dir},
            ) catch return;
            defer app.allocator.free(mirror_path);
            app.tasks.setMirror(mirror_path) catch |err| {
                @import("util/log.zig").warn("kg", "degraded task mirror setup failed: {s}", .{@errorName(err)});
                return;
            };
            // 启动时重开共享 mirror；损坏时保留 mirror 配置，让后续 Task* 在写前
            // fail closed，而不是用局部状态覆盖仍可取证的坏文件。
            app.tasks.loadFromMirror() catch |err| {
                @import("util/log.zig").warn("kg", "degraded task mirror reopen failed: {s}", .{@errorName(err)});
            };
        }
    }

    /// 从 kg_inbox frontier 重建内存 store 镜像(启动一次)。best-effort。
    fn rebuildInboxMirror(app: *App) void {
        const inject = @import("kg/inject.zig");
        const inbox = inject.readIdPointer(app.allocator, app.kg_projects_dir, "kg_inbox") orelse return;
        const kg = &app.kg.?;
        const rows = kg.frontier(inbox, 50) catch return;
        defer {
            // kg 内存契约:kg.allocator 释放(见 KgClient 顶注)。
            for (rows) |*r| r.deinit(kg.allocator);
            kg.allocator.free(rows);
        }
        for (rows) |r| {
            if (r.role == .branch) continue; // 复合节点非可执行项,镜像只收叶子
            if (r.status.isTerminal()) continue; // failed 仍在 frontier 作阻塞上下文，不镜像成 pending。
            var idbuf: [24]u8 = undefined;
            const kg_id = std.fmt.bufPrint(&idbuf, "kg-{d}", .{r.task_id}) catch continue;
            const nl = std.mem.indexOfScalar(u8, r.text, '\n');
            const subject = if (nl) |i| r.text[0..i] else r.text;
            const status: @import("core/task_store.zig").TaskStatus = if (r.status == .claimed) .in_progress else .pending;
            app.tasks.createWithId(kg_id, subject, r.text, status) catch {};
        }
    }

    /// 逐级建 `{home}/.metacodes/projects/<hash>`(Linus H1)。best-effort:失败静默
    /// (下游 writeIdPointer 会 log.warn;此处仅尽量把目录建出来)。
    fn mkdirKgProjectsDir(allocator: std.mem.Allocator, home: []const u8, hash: [16]u8) void {
        const parts = [_][]const u8{ ".metacodes", ".metacodes/projects" };
        for (parts) |p| {
            const dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, p }) catch return;
            defer allocator.free(dir);
            const dz = allocator.dupeZ(u8, dir) catch return;
            defer allocator.free(dz);
            _ = std.c.mkdir(dz, 0o700);
        }
        const full = std.fmt.allocPrint(allocator, "{s}/.metacodes/projects/{s}", .{ home, hash[0..] }) catch return;
        defer allocator.free(full);
        const fz = allocator.dupeZ(u8, full) catch return;
        defer allocator.free(fz);
        _ = std.c.mkdir(fz, 0o700);
    }

    /// domain id:默认由锚点(git 根/cwd)basename + hash 前 8 生成。隔离 worktree
    /// 可由可信 host 显式绑定同一 logical project；值只允许短 ASCII identifier，
    /// 防止换行/路径等外部输入进入 TinyKG project name。
    fn computeKgDomain(app: *App, anchor: []const u8, anchor_hash: [16]u8, override: ?[]const u8) ![]u8 {
        if (override) |value| {
            if (value.len == 0 or value.len > 128) return error.InvalidKgDomainOverride;
            for (value) |character| {
                if (!(std.ascii.isAlphanumeric(character) or character == '-' or character == '_' or character == '.')) {
                    return error.InvalidKgDomainOverride;
                }
            }
            return app.allocator.dupe(u8, value);
        }
        const base = std.fs.path.basename(anchor);
        const safe_base = if (base.len == 0) "root" else base;
        return std.fmt.allocPrint(app.allocator, "{s}-{s}", .{ safe_base, anchor_hash[0..8] });
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

    /// **当前权限模式的单一运行时真理源(U2 S2)**:permission_ctx.mode(atomic load)。
    /// `config.permission_mode` 降级为**启动快照**(parseArgs 设 → init 经 createContext 播种
    /// ctx.mode),运行时一律读 permMode(),不读 config.permission_mode。套 U3 config.model 模式,
    /// 从构造上消除 config/ctx 双存储 desync——旧版靠 loop.zig sync-back hack + web 漏 sync 致
    /// /state 陈旧 bug(task#14),根因就是两份真理源。ctx.mode 是 atomic → 此读是 atomic load。
    pub fn permMode(app: *const App) types.PermissionMode {
        return app.permission_ctx.modeValue();
    }

    /// 设置权限模式 + 维护 plan_prev_mode 簿记:进 plan 记 from(ExitPlanMode approve 据此
    /// 恢复真实前态),离开 plan 清。Shift+Tab 轮换与 `/mode` 命名设置(U11)**必须共用此路**
    /// ——命名路径若直写 setMode 会漏簿记,stale prev 可让 plan approve 恢复到更宽的历史模式
    /// (如 bypass)。**只写 permission_ctx.mode(单一源,U2 S2)**;读方走 permMode()。
    pub fn setPermModeTracked(app: *App, to: types.PermissionMode) void {
        const from = app.permMode();
        if (to == .plan and from != .plan) {
            app.plan_prev_mode = from;
        } else if (from == .plan and to != .plan) {
            app.plan_prev_mode = null;
        }
        app.permission_ctx.setMode(to);
    }

    /// Shift+Tab:循环权限模式 default → acceptEdits → plan → default(对齐 Claude Code)。
    pub fn cyclePermMode(app: *App) void {
        app.setPermModeTracked(nextPermMode(app.permMode()));
    }

    /// 设置 TUI 主题(变体 → 派生 theme → 持久化 ~/.metacodes/config.json)。U2 S1:抽出
    /// 原 loop.zig handleTheme 的**状态操作**(变体/theme/持久化),渲染留调用方。
    /// 返回 true=已持久化，false=无 HOME 跳过持久化(theme 仍已切);持久化 IO 失败返 error。
    /// cap 探测走 term(UI 环境)——init 也这么做。
    pub fn setTheme(app: *App, variant: @import("repl/tui/theme.zig").Variant) !bool {
        const theme_mod = @import("repl/tui/theme.zig");
        const tui_term = @import("repl/tui/term.zig");
        app.theme_variant = variant;
        const cap = tui_term.detectFromEnv(1);
        app.theme = theme_mod.select(variant, cap);
        const tui_config = @import("repl/tui/config.zig");
        const home = @import("platform").paths.homeDir() orelse return false;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        try tui_config.saveTheme(arena.allocator(), home, variant);
        return true;
    }

    /// 翻转 editor vim 模式,返回新值。U2 S1:抽出原 loop.zig /vim 内联翻转。
    pub fn toggleVim(app: *App) bool {
        app.config.vim_mode = !app.config.vim_mode;
        return app.config.vim_mode;
    }

    pub const CompactResult = struct { dropped: usize, before: usize, after: usize };

    /// 压缩上下文窗口(投影语义:原始消息不删,推进 boundary)。返回结构化结果供各 UI 渲染。
    /// U2 S1:抽出原 loop.zig /compact 与 web execCommand /compact 的**逐字重复**逻辑,两源共用。
    pub fn compactWindow(app: *App) CompactResult {
        const before = app.conversation.activeMessages().len;
        const dropped = app.conversation.compact(100_000) catch 0;
        const after = app.conversation.activeMessages().len;
        return .{ .dropped = dropped, .before = before, .after = after };
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
        _ = skill_name;
        _ = allowed_tools;
        _ = disallowed_tools;
        // The CLI adapter owns the context-local projection. Keeping it there
        // lets fork siblings use distinct PermissionContext values without
        // turning App into a second mutable Skill runtime.
        try app.skill_runtime.projectCurrent(
            app.session_id,
            &app.permission_ctx,
        );
    }

    /// 清除激活态(loop.zig 在每条新 user message 进来时调用)。
    pub fn clearActiveSkill(app: *App) void {
        if (app.active_skill) |*as| {
            as.deinit();
            app.active_skill = null;
        }
        app.permission_ctx.active_skill = null;
        app.skill_runtime.clearContext(app.session_id);
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

    /// HOME(sandbox ~/ 展开)。可移植:POSIX=$HOME,Windows=$USERPROFILE 回退(见 platform/paths.zig)。
    pub fn homeDir(app: *const App) []const u8 {
        _ = app;
        return platform_paths.homeDir() orelse "";
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
        const home: ?[]const u8 = @import("platform").paths.homeDir();

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
        // additionalDirectories:收集全层 + 解析为绝对路径(owned)。旧列表先 free
        // (addDirectory 重载路径)。失败不致命:降级为空集(add-dir 语义静默失效比崩溃好,
        // 但 warn 出来)。
        app.rebuildAdditionalDirs(home) catch |e| {
            @import("util/log.zig").warn("permission", "additionalDirectories resolve failed: {s}", .{@errorName(e)});
        };
        app.permission_ctx.match_ctx = .{
            .cwd = app.cwd_abs orelse "",
            .project_root = app.project_dir orelse (app.cwd_abs orelse ""),
            .home = home orelse "",
            .additional_dirs = app.additionalDirs(),
            // B1:路径规则匹配前 canonicalize(unescape + 折叠 ..)需要 allocator。
            .alloc = app.allocator,
        };
        @import("util/log.zig").info("permission", "settings loaded: {d} layer(s)", .{app.settings.?.layers.len});

        // disableBypassPermissionsMode / disableAutoMode 强制:若 settings 禁用了某模式
        // 而当前正处于该模式,降级到 default + 警告(对齐官方:这两个开关是硬约束)。
        // U2 S2:读走 permMode()(单一源),降级只写 ctx。init 时 ctx 已由 createContext 播种。
        const canon = @import("permission/mode.zig").canonical(app.permMode());
        if (app.settings.?.isBypassDisabled() and canon == .bypass_permissions) {
            @import("util/log.zig").warn("permission", "bypassPermissions disabled by settings → downgraded to default", .{});
            app.permission_ctx.setMode(.default);
        }
        if (app.settings.?.isAutoModeDisabled() and canon == .auto) {
            @import("util/log.zig").warn("permission", "auto mode disabled by settings → downgraded to default", .{});
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

    /// 重建 additional_dirs_abs:settings 全层 additionalDirectories → 绝对路径 owned 列表。
    /// 解析逻辑在可测 seam settings.resolveAdditionalDirs(L2 组件测试直驱)。
    fn rebuildAdditionalDirs(app: *App, home: ?[]const u8) !void {
        app.freeAdditionalDirs();
        if (app.settings == null) return;
        const raw = try app.settings.?.collectAdditionalDirs(app.allocator);
        defer app.allocator.free(raw); // 元素 borrow settings,不 free
        if (raw.len == 0) return;
        const settings_mod = @import("permission/settings.zig");
        app.additional_dirs_abs = try settings_mod.resolveAdditionalDirs(
            app.allocator,
            raw,
            app.cwd_abs orelse "",
            home orelse "",
        );
    }

    fn freeAdditionalDirs(app: *App) void {
        if (app.additional_dirs_abs) |dirs| {
            for (dirs) |d| app.allocator.free(d);
            app.allocator.free(dirs);
            app.additional_dirs_abs = null;
        }
    }

    /// 额外工作目录(绝对路径)。供 agent_loop Options / ToolContext 透传。
    pub fn additionalDirs(app: *const App) []const []const u8 {
        return app.additional_dirs_abs orelse &.{};
    }

    /// **配置变更事件 sink 装配(U4)**:driver(TUI/web)在 session 装配时调。同步设 App 的
    /// sink(model/dirs/reasoning emit)+ permission_ctx.event_sink(mode emit),两者一致。
    /// null 清除(deinit / 无 UI)。
    pub fn setConfigEventSink(app: *App, sink: ?@import("core/protocol/ui_event.zig").ConfigEventSink) void {
        app.config_event_sink = sink;
        app.permission_ctx.event_sink = sink;
        // U5 B1:装配 sink 时 seed slice-safe 缓存(首个 emit 前 /state 也有值可读)。
        if (sink != null) {
            if (app.snapshot_cache == null) app.snapshot_cache = .{ .allocator = app.allocator };
            app.snapshot_cache.?.setModel(app.activeModel());
            app.snapshot_cache.?.setDirs(app.additionalDirs());
        }
    }

    /// 内部:向 config 事件 sink emit 一条(有 sink 才发)。model/dirs/reasoning 单写侧调。
    /// **U5 B1:refresh 骑 emit**——slice 轴(model/dirs)顺手刷 snapshot_cache(emit⟺refresh 一个
    /// 不变式,不手工 per-mutation refresh,零枚举债)。
    fn emitConfig(app: *App, ev: @import("core/protocol/ui_event.zig").ConfigChange) void {
        if (app.snapshot_cache) |*c| switch (ev) {
            .model => |m| c.setModel(m),
            .dirs => c.setDirs(app.additionalDirs()), // dirs 全量刷(ev.dirs 只是新增项)
            else => {}, // mode/reasoning 标量不进 cache
        };
        if (app.config_event_sink) |s| s.emit(ev);
    }

    /// **U5 B1:/state(HTTP 线程)安全读 UAF-critical slice**。锁内 dup 出 model+dirs(caller free)。
    /// driver 的 free+reassign 被 cache mutex 挡 → 无 torn read/UAF。无 cache(未装 sink)→ 直读
    /// (单线程/无 HTTP 竞争)。
    pub fn snapshotSlices(app: *App, alloc: std.mem.Allocator) !SnapshotSlices {
        if (app.snapshot_cache) |*c| return c.readOwned(alloc);
        // 无 cache:直读(单线程场景,无竞争)
        const m = try alloc.dupe(u8, app.activeModel());
        errdefer alloc.free(m);
        const src = app.additionalDirs();
        var d = try alloc.alloc([]u8, src.len);
        var n: usize = 0;
        errdefer {
            for (d[0..n]) |x| alloc.free(x);
            alloc.free(d);
        }
        for (src) |s| {
            d[n] = try alloc.dupe(u8, s);
            n += 1;
        }
        return .{ .model = m, .dirs = d };
    }

    /// 收集 project + user settings 的 hooks(Pre+Post),**跨层合并**成一个 HookSet(不再首个覆盖)。
    /// 合并语义:各层 matcher entry 全部并入(project 与 user 的 hook 并存,org 全局 hook 不被项目覆盖)。
    fn loadHooks(app: *App, home: ?[]const u8) !void {
        const hooks_mod = @import("permission/hooks.zig");
        const candidates = [_]?[]const u8{
            if (app.project_dir) |r| (std.fmt.allocPrint(app.allocator, "{s}/.claude/settings.json", .{r}) catch null) else null,
            if (home) |h| (std.fmt.allocPrint(app.allocator, "{s}/.claude/settings.json", .{h}) catch null) else null,
        };
        defer for (candidates) |p| if (p) |x| app.allocator.free(x);

        // 读各层文件内容 → 交给可测 seam parseAndMerge(5 类事件跨层合并)。
        var contents: std.ArrayList([]const u8) = .empty;
        defer {
            for (contents.items) |c| app.allocator.free(c);
            contents.deinit(app.allocator);
        }
        for (candidates) |maybe_path| {
            const path = maybe_path orelse continue;
            const content = readFileAlloc(app.allocator, path) catch continue;
            contents.append(app.allocator, content) catch app.allocator.free(content);
        }
        if (contents.items.len == 0) return;

        var hs = try hooks_mod.parseAndMerge(app.allocator, contents.items);
        if (hs.isEmpty()) {
            hs.deinit();
            return;
        }
        app.hooks = hs;
        app.permission_ctx.hooks = &app.hooks.?;
        @import("util/log.zig").info("hook", "loaded hooks: Pre={d} Post={d} Stop={d} PreCompact={d} PostCompact={d} (merged across layers)", .{ app.hooks.?.pre_tool_use.len, app.hooks.?.post_tool_use.len, app.hooks.?.stop.len, app.hooks.?.pre_compact.len, app.hooks.?.post_compact.len });
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
        // U4:dirs 单写侧 emit(dir 借调用方瞬态 arg,sink 跨线程留存须 dup——见 ConfigEventSink 契约)。
        app.emitConfig(.{ .dirs = dir });
    }

    /// 从 ~/.metacodes/config.json 读 permission_rules 数组。失败仅 log，不影响启动。
    /// 同时把加载的 rule_set 绑到 permission_ctx.rules。
    fn loadPermissionRules(app: *App) !void {
        const home = @import("platform").paths.homeDir() orelse return error.NoHome;
        var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "{s}/.metacodes/config.json\x00", .{home});
        const fd = pfs.open(@ptrCast(path.ptr), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return error.NotFound;
        defer _ = pfs.close(fd);

        var all = std.ArrayList(u8).empty;
        defer all.deinit(app.allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = pfs.read(fd, buf[0..buf.len]);
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

    /// 启动时连接 ~/.metacodes/config.json 里 mcp_servers 数组里声明的每个 server。
    /// Schema：
    ///   {"mcp_servers": [
    ///       {"name": "github", "command": ["/usr/local/bin/mcp-github", "--token=..."]},
    ///       ...
    ///   ]}
    /// 每个 server 失败仅 log,不影响其它 server 或 App 启动。
    /// 成功的 session 注册的工具进 dyn_registry,naming: `<name>__<tool>`。
    fn connectMcpServers(app: *App) !void {
        const home = @import("platform").paths.homeDir() orelse return error.NoHome;
        var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "{s}/.metacodes/config.json\x00", .{home});
        const fd = pfs.open(@ptrCast(path.ptr), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return error.NotFound;
        defer _ = pfs.close(fd);

        var all = std.ArrayList(u8).empty;
        defer all.deinit(app.allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = pfs.read(fd, buf[0..buf.len]);
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
            client_heap.* = McpClient.connect(app.allocator, argv_storage.items) catch |err| {
                log.warn("mcp", "server '{s}' connect failed: {s}", .{ name_v.string, @errorName(err) });
                app.allocator.destroy(client_heap);
                continue;
            };
            var client_committed = false;
            defer if (!client_committed) {
                client_heap.close();
                app.allocator.destroy(client_heap);
            };

            // Reserve every App-owned resource before publishing any tool
            // definition into dyn_registry. After registration succeeds the
            // final session append is infallible, so registry ctx_ptr values
            // cannot outlive an unowned/freed McpSession.
            const name_owned = try app.allocator.dupe(u8, name_v.string);
            var name_committed = false;
            defer if (!name_committed) app.allocator.free(name_owned);
            try app.mcp_sessions.ensureUnusedCapacity(app.allocator, 1);

            // **诚实登记(elicitation UI 未接线)**:client.elicit 回调机制已实现+测试(见 mcp/client.zig),
            // 但此处**不设** handler → 生产中 MCP server 发 elicitation/create 一律安全 decline(协议正确闭合,
            // tool 继续/优雅失败,不 hang)。接真 UI 需一个 elicitation 渲染器(同 custom UiRequest,TUI 暂无);
            // 有渲染器后在此 per-session 设 client_heap.elicit=路由到 ui_requester 即可,MCP 层零改。
            var session = McpSession.init(app.allocator, client_heap);
            // 注册 server tools + resource tools；任一失败回滚本 server
            session.registerTools(&app.dyn_registry, name_v.string) catch |err| {
                log.warn("mcp", "server '{s}' registerTools failed: {s}", .{ name_v.string, @errorName(err) });
                session.deinit();
                continue;
            };
            session.registerResourceTools(&app.dyn_registry, name_v.string) catch |err| {
                log.warn("mcp", "server '{s}' registerResourceTools failed: {s}", .{ name_v.string, @errorName(err) });
                // tools 已注册无法回滚；只能略过 resources
            };

            app.mcp_sessions.appendAssumeCapacity(.{
                .name = name_owned,
                .client = client_heap,
                .session = session,
            });
            name_committed = true;
            client_committed = true;
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
        // 可移植:POSIX=SIGINT sigaction;Windows=SetConsoleCtrlHandler(见 platform/signal.zig)。
        platform_signal.installInterrupt(onSigint);
    }
};

/// 从 Config 的方言字段构造 RequestOverrides(给 OpenAI/Gemini client 用)。
/// reasoning_effort 不进 overrides(它有独立 legacy 字段 + setter,保持原路径)。
/// Anthropic client 不用此函数(不支持方言字段,setRequestOverrides 留 null)。
/// prompt_cache_key 借用 config 内存(App 生命周期有效,无需 dupe)。
fn buildOverridesFromConfig(config: types.Config) request_overrides.RequestOverrides {
    const rf: ?dialect_mod.ResponseFormatRequest = if (config.response_format) |rf_str|
        .{
            .kind = if (std.mem.eql(u8, rf_str, "json_schema")) .json_schema else .json_object,
            .schema = null,
        }
    else
        null;
    return .{
        .temperature = config.temperature,
        .top_p = config.top_p,
        .prompt_cache_key = config.prompt_cache_key,
        .parallel_tool_calls = config.parallel_tool_calls,
        .response_format = rf,
    };
}

/// 中断回调(async-signal-safe:只置原子,不分配/不锁/不 IO)。取代旧 sigintHandler(sig)。
/// **U9**:置进程级 shutdown flag(daemon 主循环 poll 它优雅关所有 session)+ 戳 g_abort_signal
/// (唤醒 N=1 宿主的 run,兼容既有行为;daemon 未绑单 session 时此指针为 null,靠 accept EINTR 醒)。
fn onSigint() void {
    @import("core/shutdown.zig").request();
    if (g_abort_signal) |s| {
        s.abort(.user_ctrl_c);
    }
}

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
    const fd = pfs.open(@ptrCast(&pbuf), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = pfs.close(fd);
    var all: std.ArrayList(u8) = .empty;
    errdefer all.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, buf[0..buf.len]);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try all.appendSlice(alloc, buf[0..@intCast(n)]);
    }
    return try all.toOwnedSlice(alloc);
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

test "U4 A3: reasoning/dirs 单写侧 emit config_changed;setConfigEventSink 同步 mode sink" {
    const ui_event = @import("core/protocol/ui_event.zig");
    const Recorder = struct {
        last: ?ui_event.ConfigChange = null,
        count: usize = 0,
        fn emit(ctx: *anyopaque, ev: ui_event.ConfigChange) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.last = ev;
            self.count += 1;
        }
    };
    var rec = Recorder{};
    const sink = ui_event.ConfigEventSink{ .ctx = @ptrCast(&rec), .emitFn = &Recorder.emit };

    // 只初始化 setConfigEventSink/setReasoningEffort/emitConfig 触及的字段(undefined App 技巧)。
    var app: App = undefined;
    app.allocator = std.testing.allocator; // U5 B1:cache seed 用 app.allocator dup
    app.config = types.Config{};
    app.config_event_sink = null;
    app.snapshot_cache = null; // U5 B1:setConfigEventSink 会 seed cache，需初始化
    app.additional_dirs_abs = null; // setConfigEventSink seed 读 additionalDirs()
    app.permission_ctx = permission_mod.createContext(.default, std.testing.allocator);
    // api_client 被 setReasoningEffort 写 reasoning_effort 字段——需真 Client。
    var io_rt = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_rt.deinit();
    app.api_client = client_mod.Client.initWithBaseUrl(std.testing.allocator, io_rt.io(), "k", "m", null);
    defer app.api_client.deinit();

    // 装配 sink:App + permission_ctx 两处同步设。
    app.setConfigEventSink(sink);
    try std.testing.expect(app.permission_ctx.event_sink != null); // mode sink 同步设了

    // reasoning 单写侧 → emit .reasoning
    try app.setReasoningEffort(.high);
    try std.testing.expectEqual(types.ReasoningEffort.high, rec.last.?.reasoning.?);
    try std.testing.expectEqual(@as(usize, 1), rec.count);

    // mode 走 permission_ctx.setMode(setConfigEventSink 已同步)→ emit .mode
    app.permission_ctx.setMode(.plan);
    try std.testing.expectEqual(types.PermissionMode.plan, rec.last.?.mode);
    try std.testing.expectEqual(@as(usize, 2), rec.count);

    // 清 sink:不再 emit
    app.setConfigEventSink(null);
    try app.setReasoningEffort(.low);
    try std.testing.expectEqual(@as(usize, 2), rec.count); // 无变化

    // setConfigEventSink 已 seed cache(dup model/dirs);undefined-App 无 deinit,手动释。
    if (app.snapshot_cache) |*c| c.deinit();
}

test "U5 B1: snapshot_cache slice-safe 并发读——狂 setModel/setDirs 时另线程读+dup 无 UAF/无撕裂" {
    const a = std.testing.allocator;
    var cache = SnapshotCache{ .allocator = a };
    defer cache.deinit();
    cache.setModel("model-A");
    const d0 = [_][]const u8{"/proj"};
    cache.setDirs(&d0);

    // writer 线程:狂 setModel/setDirs(free+reassign 旧 owned)。
    const Writer = struct {
        fn run(c: *SnapshotCache) void {
            var i: usize = 0;
            while (i < 2000) : (i += 1) {
                c.setModel(if (i % 2 == 0) "claude-opus-4-8" else "claude-sonnet-5");
                const dirs = [_][]const u8{ "/a/b/c", "/d/e/f/g" };
                c.setDirs(&dirs);
            }
        }
    };
    var th = try std.Thread.spawn(.{}, Writer.run, .{&cache});

    // reader 线程(本线程):同时锁内 dup 读——每次读出的 model/dirs 必须是完整合法值(不 UAF、
    // 不半新半旧)。若 free vs 读无互斥,这里会崩(UAF)或读到垃圾长度。
    var j: usize = 0;
    while (j < 2000) : (j += 1) {
        const s = try cache.readOwned(a);
        defer {
            a.free(s.model);
            for (s.dirs) |x| a.free(x);
            a.free(s.dirs);
        }
        // model 必是两个合法值之一(完整,非撕裂)。
        try std.testing.expect(std.mem.eql(u8, s.model, "claude-opus-4-8") or
            std.mem.eql(u8, s.model, "claude-sonnet-5") or std.mem.eql(u8, s.model, "model-A"));
        // dirs 每项非空合法(要么初始 /proj，要么新的两项)。
        for (s.dirs) |dir| try std.testing.expect(dir.len > 0);
    }
    th.join();
}

test "U5 B3: 附着无缺口不变式——快照(seq,model)绝不撕出漏读的 config 事件(跨双 mutex happens-before)" {
    // ── 证的东西:附着协议的**无缺口**属性。客户端拿 /state 快照(seq=S)后订阅 `?since=S`,
    // 只会收到 journal 位置 ≥S 的事件;位置 <S 的事件必须**已反映在快照的 model 里**。若快照给出
    // (旧 model, 新 seq),客户端既没在快照里、也不会在流里拿到那次变更 → 永久陈旧(GAP)。
    //
    // ── 不变式靠两个生产排序(本测精确复刻):
    //   写侧 emitConfig(.model):**cache.setModel(m) 先于 journal.append**(app.zig:1310→1314,
    //     WebConfigSink.emit 落 journal)。刷缓存骑 emit。
    //   读侧 StateSource.snapshot:**seq=journal.count() 先于 cache 读**(session.zig:74→76)。
    //   合起来(跨两把锁,靠 journal.mutex 携带 happens-before):快照见 S 条 journal ⇒ append(S-1)
    //   已完成 ⇒ 其前的 setModel(S-1) 对读者可见 ⇒ 读者随后读 cache 得 idx ≥ S-1。故 m ≥ S-1
    //   恒成立(m 可能=S,若第 S 次刷缓存已跑但 append 未落 → 良性双应用,config 事件幂等)。
    //   唯一被禁的组合 (m<S-1) = 漏读,本测断言它永不出现。
    //   **OOM 例外(Linus review MINOR)**:setModel 的 dup OOM 时保留旧值但 emit 仍推进 seq →
    //   降级出 (旧 model, 新 seq) 缺口(同 journal.append 自身 OOM 丢行,整层 best-effort)。本测
    //   在充足内存下证不变式;OOM 路径 setModel 已 warn 记账(不静默)。
    const a = std.testing.allocator;
    const EventJournal = @import("web/journal.zig").EventJournal; // test-scoped:不进 app.zig 非测试面
    const N: usize = 3000;

    var journal = EventJournal.init(a);
    defer journal.deinit();
    var cache = SnapshotCache{ .allocator = a };
    defer cache.deinit();
    cache.setModel("m0000"); // seed(seq 0 前的初值)

    // 写侧:严格复刻 emitConfig(.model) 排序——先刷缓存,再落 journal。model 名定宽 "mNNNN"
    // 使字符串序==数值序,idx 可解析。
    const Driver = struct {
        fn run(c: *SnapshotCache, j: *EventJournal, n: usize) void {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                var buf: [8]u8 = undefined;
                const m = std.fmt.bufPrint(&buf, "m{d:0>4}", .{i}) catch unreachable;
                c.setModel(m); // ← emitConfig 步①:刷缓存(app.zig:1310)
                j.append(m); //   ← emitConfig 步②:落 journal(app.zig:1314 sink.emit)
            }
        }
    };
    var th = try std.Thread.spawn(.{}, Driver.run, .{ &cache, &journal, N });

    // 读侧:严格复刻 StateSource.snapshot 读序——先取 seq,再读 cache。狂读到 driver 跑完,
    // 每次断言 m ≥ S-1(无缺口)。
    while (true) {
        const seq = journal.count(); // ← snapshot 步①:先取 seq(session.zig:74)
        const s = try cache.readOwned(a); // ← snapshot 步②:后读 cache(session.zig:76)
        defer {
            a.free(s.model);
            for (s.dirs) |x| a.free(x);
            a.free(s.dirs);
        }
        // 解析 model idx("mNNNN" → NNNN)。
        try std.testing.expectEqual(@as(usize, 5), s.model.len);
        const m_idx = try std.fmt.parseInt(usize, s.model[1..], 10);
        // 无缺口:m_idx + 1 ≥ seq(即 m_idx ≥ seq-1)。seq==0 时无约束(m_idx≥0 恒真)。
        if (seq >= 1) try std.testing.expect(m_idx + 1 >= seq);
        if (seq >= N) break; // driver 跑满
    }
    th.join();

    // 终态一致:全部落定后 seq==N,cache==最后一个 model。
    try std.testing.expectEqual(N, journal.count());
    const fin = try cache.readOwned(a);
    defer {
        a.free(fin.model);
        for (fin.dirs) |x| a.free(x);
        a.free(fin.dirs);
    }
    var ebuf: [8]u8 = undefined;
    const expect_last = try std.fmt.bufPrint(&ebuf, "m{d:0>4}", .{N - 1});
    try std.testing.expectEqualStrings(expect_last, fin.model);
}

test "U5 B3(判别性): 确定性证明读序**必须** seq→cache——正序永不缺口,逆序会缺口" {
    // 上一条并发压测只证"无崩溃/无撕裂";它**不判别**读序(逆序在锁竞争+窄窗口下也几乎不缺口)。
    // 本条用**手动步进**驱动器消除竞态,确定性地证明:
    //   · 正序(seq 先) → 即便驱动器随后猛进,快照 m_idx ≥ seq-1 恒成立(无缺口)。
    //   · 逆序(cache 先) → 驱动器在两读之间步进 → 快照给出(旧 model, 新 seq)= 缺口。
    // 这是"读序 load-bearing"的真凭据,非并发运气。
    const a = std.testing.allocator;
    const EventJournal = @import("web/journal.zig").EventJournal;

    var journal = EventJournal.init(a);
    defer journal.deinit();
    var cache = SnapshotCache{ .allocator = a };
    defer cache.deinit();

    // 手动步进 = emitConfig(.model) 一次:先刷缓存,再落 journal。
    const step = struct {
        fn do(c: *SnapshotCache, j: *EventJournal, i: usize) void {
            var buf: [8]u8 = undefined;
            const m = std.fmt.bufPrint(&buf, "m{d:0>4}", .{i}) catch unreachable;
            c.setModel(m);
            j.append(m);
        }
    }.do;
    const readIdx = struct {
        fn go(c: *SnapshotCache, alloc: std.mem.Allocator) usize {
            const s = c.readOwned(alloc) catch unreachable;
            defer {
                alloc.free(s.model);
                for (s.dirs) |x| alloc.free(x);
                alloc.free(s.dirs);
            }
            return std.fmt.parseInt(usize, s.model[1..], 10) catch unreachable;
        }
    }.go;

    step(&cache, &journal, 0); // cache=m0, count=1
    step(&cache, &journal, 1); // cache=m1, count=2

    // ── 正序:seq 先,cache 后。两读之间驱动器猛进 2 步 → model 只会更新,绝不缺口。
    {
        const seq = journal.count(); // =2
        step(&cache, &journal, 2); // 驱动器插进(cache=m2,count=3)
        step(&cache, &journal, 3); // (cache=m3,count=4)
        const m_idx = readIdx(&cache, a); // 读到 m3(=3)
        try std.testing.expect(m_idx + 1 >= seq); // 3+1 ≥ 2 ✓ 无缺口(model 反而超前)
    }

    // ── 逆序:cache 先,seq 后。两读之间驱动器插进 2 步 → 快照(旧 model, 新 seq)= 缺口。
    {
        const m_idx = readIdx(&cache, a); // 此刻 cache=m3 → 3
        step(&cache, &journal, 4); // 驱动器插进(count=5)
        step(&cache, &journal, 5); // (count=6)
        const seq = journal.count(); // =6
        // 逆序下 m_idx(3)+1=4 < seq(6) → 缺口成立。断言"逆序确实撕出缺口"(证读序 load-bearing)。
        try std.testing.expect(m_idx + 1 < seq);
    }
}

test "U2 S1: toggleVim 翻转 config.vim_mode 返回新值" {
    var app: App = undefined;
    app.config = types.Config{}; // 默认 vim_mode=false
    try std.testing.expect(!app.config.vim_mode);
    try std.testing.expect(app.toggleVim()); // → true
    try std.testing.expect(app.config.vim_mode);
    try std.testing.expect(!app.toggleVim()); // → false
    try std.testing.expect(!app.config.vim_mode);
}

test "KG domain override binds isolated worktrees and rejects unsafe identifiers" {
    var app: App = undefined;
    app.allocator = std.testing.allocator;
    const anchor_hash: [16]u8 = "0123456789abcdef".*;

    const fallback = try app.computeKgDomain("/tmp/repo", anchor_hash, null);
    defer app.allocator.free(fallback);
    try std.testing.expectEqualStrings("repo-01234567", fallback);

    const shared = try app.computeKgDomain("/tmp/worktree-a", anchor_hash, "project-deadbeef");
    defer app.allocator.free(shared);
    try std.testing.expectEqualStrings("project-deadbeef", shared);

    try std.testing.expectError(
        error.InvalidKgDomainOverride,
        app.computeKgDomain("/tmp/worktree-b", anchor_hash, "project\nother"),
    );
    try std.testing.expectError(
        error.InvalidKgDomainOverride,
        app.computeKgDomain("/tmp/worktree-b", anchor_hash, ""),
    );
}

test "U2 S1: compactWindow 结构化返回 {dropped,before,after}(loop/web 共用)" {
    const a = std.testing.allocator;
    var app: App = undefined;
    app.conversation = Conversation.init(a);
    app.file_change_journal = @import("core/file_change.zig").Journal.init(std.heap.c_allocator);
    defer app.conversation.deinit();
    // 空对话:compact 无可丢 → dropped=0, before=after=0(投影语义,活跃计数)
    const r = app.compactWindow();
    try std.testing.expectEqual(@as(usize, 0), r.dropped);
    try std.testing.expectEqual(r.before, r.after); // 空窗口不缩
}

test "U2 S2: permission_mode 单一源 — permMode 读 ctx,cyclePermMode 只写 ctx,工具 setMode 即时反映" {
    // cyclePermMode 只触及 permission_ctx + plan_prev_mode → 用 undefined App 只初始化这两个字段
    // (其余字段永不被读,安全)。锁住"config.permission_mode 不再是运行时真理源"这个不变式。
    var app: App = undefined;
    app.permission_ctx = permission_mod.createContext(.default, std.testing.allocator);
    app.plan_prev_mode = null;

    try std.testing.expectEqual(types.PermissionMode.default, app.permMode());
    app.cyclePermMode(); // default → accept_edits
    try std.testing.expectEqual(types.PermissionMode.accept_edits, app.permMode());
    app.cyclePermMode(); // accept_edits → plan:记 plan_prev_mode=from
    try std.testing.expectEqual(types.PermissionMode.plan, app.permMode());
    try std.testing.expectEqual(types.PermissionMode.accept_edits, app.plan_prev_mode.?);
    app.cyclePermMode(); // plan → default:清 plan_prev_mode
    try std.testing.expectEqual(types.PermissionMode.default, app.permMode());
    try std.testing.expect(app.plan_prev_mode == null);

    // task#14 修复机制:工具(EnterPlanMode/ExitPlanMode)只写 permission_ctx.mode,
    // permMode()=ctx 即时反映(旧版靠 loop.zig sync-back 补 config,web 漏了它致 /state 陈旧)。
    app.permission_ctx.setMode(.plan);
    try std.testing.expectEqual(types.PermissionMode.plan, app.permMode()); // web /state 现在读这个,不陈旧
}

test "U3 syncModelMirrors: 所有 model 镜像同步(含 swarm.model,Linus U3 抓的第7点)" {
    const a = std.testing.allocator;
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    const io = io_rt.io();

    // client(借用镜像)+ agent_jobs(dupe 自持镜像)+ swarm(借用镜像,U3 前漏同步)。
    var client = client_mod.Client.initWithBaseUrl(a, io, "test-key", "model-A", null);
    defer client.deinit();
    var jobs = try @import("core/agent_job_registry.zig").AgentJobRegistry.init(a, "test-key", null, "model-A", .anthropic);
    defer jobs.deinit();
    var swarm = @import("swarm/context.zig").SwarmContext{ .allocator = a, .model = "model-A" };

    // 切到 model-B:seam 必须把全部镜像刷成 B。
    try App.syncModelMirrors("model-B", &client, null, null, null, &jobs, &swarm);

    try std.testing.expectEqualStrings("model-B", client.model);
    try std.testing.expectEqualStrings("model-B", jobs.model); // agent_jobs 内部 dupe
    try std.testing.expectEqualStrings("model-B", swarm.model); // 第7镜像:teammate provider 用它
}

test "model switch compact is queued only when switching to smaller context window" {
    try std.testing.expect(shouldQueueModelSwitchCompact("large", "small", 200_000, 80_000));
    try std.testing.expect(!shouldQueueModelSwitchCompact("same", "same", 200_000, 80_000));
    try std.testing.expect(!shouldQueueModelSwitchCompact("small", "large", 80_000, 200_000));
    try std.testing.expect(!shouldQueueModelSwitchCompact("a", "b", 200_000, 200_000));
}

fn stringField(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    return switch (found) {
        .string => |text| text,
        else => null,
    };
}
