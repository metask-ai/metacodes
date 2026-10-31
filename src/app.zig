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
const login_worker = @import("api/login_worker.zig");

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
const models_cache_mod = @import("api/models_cache.zig");
const openai_mod = @import("api/openai_client.zig");
const gemini_mod = @import("api/gemini_client.zig");
const provider_host_mod = @import("provider/host.zig");
const provider_binding_mod = @import("provider/runtime_binding.zig");
const provider_api_key_store = @import("provider/api_key_store.zig");
const provider_control_plane = @import("provider/control_plane.zig");
const provider_config_store = @import("provider/config_store.zig");
const provider_selection_mod = @import("provider/selection.zig");
const provider_ids_mod = @import("provider/ids.zig");
const provider_credential_mod = @import("provider/credential.zig");
const provider_config_doc = @import("provider/config_doc.zig");
const model_picker_mod = @import("repl/model_picker.zig");
const route_strings_mod = @import("app/route_strings.zig");
const kg_provider_audit = @import("kg/provider_audit.zig");
const provider_alias_mod = @import("provider/alias.zig");
const provider_oauth_mod = @import("provider/oauth.zig");
const oauth_exchange_mod = @import("api/oauth_exchange.zig");
const metask_oauth_mod = @import("api/metask_oauth.zig");
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
const skill_overrides_mod = @import("skills/overrides.zig");
const plugin_mod = @import("plugin/root.zig");
const path_util = @import("util/path.zig");
const McpClient = @import("mcp/client.zig").McpClient;
const mcp_startup = @import("app/mcp_startup.zig");
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
    var body: @import("core/tool_result.zig").ToolResultBody = undefined;
    try executeCliProcessToolInto(&body, ctx, args, raw);
    return body;
}

/// `executeCliProcessTool` writing its result to `out`. In a function
/// returning a ToolResultBody, each `return error.X` would copy a 3.7 KiB
/// constant, one per error name (doc/PERF_MEMORY_PRINCIPLES.md §3g).
fn executeCliProcessToolInto(
    out: *@import("core/tool_result.zig").ToolResultBody,
    ctx: *const @import("tools/context.zig").ToolContext,
    args: []const u8,
    raw: ?*anyopaque,
) anyerror!void {
    const isolated: *const @import("core/tool_catalog.zig").IsolatedTool =
        @ptrCast(@alignCast(raw orelse return error.ProcessPluginUnavailable));
    const outcome = try isolated.execute(isolated.ctx, ctx, args);
    out.* = switch (outcome) {
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
        .host_fatal => return error.ProcessPluginProtocolViolation,
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

pub const PendingOverlay = enum {
    none,
    /// `/model` asked for the picker: open it fresh.
    model_picker,
    /// A reply ended while the picker was on screen (#220). Each phase draws
    /// its own region, so the next one shows the picker again as it was left:
    /// same stage, filter and cursor, sign-in still running.
    model_picker_kept,
    transcript,
};

/// The TUI theme for this terminal: monochrome under `--no-theme`; otherwise
/// the `theme` persisted in `<state root>/config.json`, else auto. Auto on a
/// colour terminal asks the terminal for its background (OSC 11, a short
/// raw-mode read of stdin) and settles on dark or light (as mecode does). A
/// persisted variant wins over the probe; `METACODES_NO_PROBE` and a terminal
/// without colour skip it.
pub fn resolveThemeVariant(allocator: std.mem.Allocator, no_theme: bool, state_root: []const u8) @import("repl/tui/theme.zig").Variant {
    return settleTerminal(allocator, no_theme, state_root, .theme);
}

/// resolveThemeVariant for the interactive REPL, which must also know before
/// it first takes the terminal whether to turn on the Kitty keyboard protocol
/// (Shift+Enter as a newline). A terminal `input.keyboardPolicy` cannot place
/// from its environment is asked in the same round trip as its background
/// (#327); `METACODES_NO_PROBE` skips both questions, leaving the protocol off.
pub fn resolveInteractiveTerminal(allocator: std.mem.Allocator, no_theme: bool, state_root: []const u8) @import("repl/tui/theme.zig").Variant {
    return settleTerminal(allocator, no_theme, state_root, .theme_and_keyboard);
}

fn settleTerminal(
    allocator: std.mem.Allocator,
    no_theme: bool,
    state_root: []const u8,
    questions: enum { theme, theme_and_keyboard },
) @import("repl/tui/theme.zig").Variant {
    const bg_probe = @import("repl/tui/bg_probe.zig");
    const input = @import("repl/input.zig");
    const persisted = if (no_theme or state_root.len == 0) null else @import("repl/tui/config.zig").loadTheme(allocator, state_root);
    const variant: @import("repl/tui/theme.zig").Variant = if (no_theme) .monochrome else persisted orelse .auto;
    if (std.c.getenv("METACODES_NO_PROBE") != null) return variant;
    const want: bg_probe.Want = .{
        .background = variant == .auto and @import("repl/tui/term.zig").detectFromEnv(1) != .none,
        .keyboard = questions == .theme_and_keyboard and input.keyboardPolicy() == .probe,
    };
    if (!want.any()) return variant;
    // The interactive REPL takes the terminal next: a round its deadline cut
    // short keeps reading its answers until then (`bg_probe.handOver`).
    const answer = bg_probe.probe(want, questions == .theme_and_keyboard);
    if (want.keyboard) input.recordKeyboardProbe(answer.keyboard == .supported);
    if (variant != .auto) return variant;
    const bg = answer.background orelse return variant;
    return if (bg_probe.isLight(bg)) .light else .dark;
}

/// `App.api_key_catalog_load`.
pub const ApiKeyCatalogLoad = enum {
    /// This route has no account key list (not Anthropic, a Metask device
    /// session, or `METACODES_NO_PROBE`): the menu says it is unavailable.
    off,
    /// Not loaded yet; the first key menu loads it.
    deferred,
    loaded,
};

/// The historical Metask API-key route: no provider named (or `metask` named
/// with an API key), no Metask session login, the Messages transport.
///
/// The key's gateway answers `/v1/models` with the models that key can use,
/// which need not include a single entry of the compiled Metask profile. The
/// provider host offers that document instead, so the picker lists what the
/// session can actually run, marks the one it is running, and a pick reaches
/// the endpoint the session already talks to.
pub const MetaskKeyRoute = struct {
    /// Where this session's Messages requests and its `/v1/models` probe go,
    /// without the `/v1/messages` path (owned).
    gateway_origin: []u8,
    /// The key the session started with. Borrowed: `App.init`'s caller keeps
    /// it for the process, exactly as it does `App.api_key`.
    startup_key: []const u8,
    /// The newest `/v1/models` document that origin answered (owned), or null
    /// until one has.
    models_json: ?[]u8 = null,

    /// The route `config` starts on, or null when it starts on another one.
    /// `messages_url` is the session's Messages endpoint.
    pub fn of(config: types.Config, messages_url: []const u8) ?[]const u8 {
        if (config.metask_oauth_selected) return null;
        if (config.provider_kind != .anthropic) return null;
        if (config.provider_profile) |name| if (!std.ascii.eqlIgnoreCase(name, "metask")) return null;
        return gatewayOriginOf(messages_url);
    }

    /// `messages_url` without its `/v1/messages` path, or null when it does
    /// not end in one (the same rule `Client.fetchModelsList` derives its
    /// `/v1/models` URL by).
    pub fn gatewayOriginOf(messages_url: []const u8) ?[]const u8 {
        const suffix = "/v1/messages";
        if (!std.mem.endsWith(u8, messages_url, suffix)) return null;
        return messages_url[0 .. messages_url.len - suffix.len];
    }

    fn deinit(self: *MetaskKeyRoute, allocator: std.mem.Allocator) void {
        allocator.free(self.gateway_origin);
        if (self.models_json) |document| allocator.free(document);
        self.* = undefined;
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    config: types.Config,
    /// Owned `<$HOME>/.metacodes` when the host passed no `config.state_root`
    /// (embedders and tests that build an App directly); the CLI always passes one.
    state_root_default: ?[]u8 = null,
    api_key: []const u8,
    selected_api_key_owned: ?[]u8 = null,
    api_key_catalog: api_keys_mod.Catalog,
    /// When `api_key_catalog` is filled: never on this route, or once, the
    /// first time the `/models` key menu needs it (`ensureApiKeyCatalog`).
    api_key_catalog_load: ApiKeyCatalogLoad = .off,
    /// The background `/v1/models` fetch a cache-served start runs, until the
    /// REPL takes its answer (`adoptModelCatalogRefresh`) or the App ends.
    models_refresh: ?*models_cache_mod.Refresh = null,
    models_picker_key_index: ?usize = null,
    models_picker_model_index: ?usize = null,
    model_switch_owned: ?[]u8 = null,
    // ── issue #16: the provider control plane this session talks to ─────────
    /// Registry + catalog + kernel, created on first use. Null until something
    /// asks for a provider view, so a session that never opens the picker pays
    /// nothing for it.
    provider_host: ?*provider_host_mod.Host = null,
    /// Set when the session runs the historical Metask API-key route; null on
    /// every other route. See `MetaskKeyRoute`.
    metask_key_route: ?MetaskKeyRoute = null,
    /// Cross-UI picker state. Present whether or not it is on screen, so a
    /// reopened picker does not have to refetch the catalog.
    model_picker: model_picker_mod.Picker = undefined,
    /// The sign-in the picker's credential stage is running (#67); owned
    /// here because it outlives any one key press.
    login_worker: ?*login_worker.LoginWorker = null,
    /// `/login` sign-ins cancelled with Esc while their thread was still in a
    /// request it cannot abandon (the first device-code POST). The dialog
    /// closes at once; the thread is joined once it settles (`reapLoginWorkers`)
    /// or at exit.
    parked_login_workers: [4]?*login_worker.LoginWorker = .{null} ** 4,
    /// Strings a committed offer put into borrowing client fields. Owned here
    /// because `Client.base_url` and `api_key` are borrowed slices that must
    /// outlive every in-flight request.
    /// Strings a committed route lends to the live clients. Keeps one previous
    /// generation readable; see `app/route_strings.zig` for why.
    route_strings: route_strings_mod.RouteStrings = undefined,
    /// A slash command asked for a full-region overlay. Commands are handled
    /// after the input reader returns, so the request is parked here and the
    /// next read consumes it.
    pending_overlay: PendingOverlay = .none,
    /// One OAuth session per provider, kept for the process.
    ///
    /// Single flight is a property of a `Session` object, so a fresh one per
    /// call would let two concurrent callers both refresh — and with a rotating
    /// refresh token the loser presents one the server already invalidated.
    /// Holding it here makes the guarantee real across callers rather than
    /// within one call.
    oauth_session: ?provider_oauth_mod.Session = null,
    oauth_session_provider: ?provider_ids_mod.Slug = null,
    /// Last control-plane event projected into the TinyKG audit plane. Events
    /// are recorded once; a restart starts from the journal's current head
    /// rather than replaying a ring that may already have evicted.
    provider_audit_cursor: u64 = 0,
    /// Why the most recent catalog refresh skipped a provider, if it did. A
    /// per-catalog failure must not abort the others, so it is recorded rather
    /// than propagated — and reported, because a silently skipped refresh looks
    /// exactly like a successful one.
    last_catalog_refresh_error: ?[]const u8 = null,
    /// Why the last committed selection was not written durably, if it was not.
    /// The route is live regardless; what is lost is surviving a `/resume`.
    last_persist_error: ?[]const u8 = null,
    /// 模型档位表(<state root>/config.json 的 model_tiers;null=未配置)。
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
    /// Sessions this foreground handed to the background with Ctrl+B, oldest
    /// first. A background job keeps its origin session for routing, so the
    /// foreground that rotated away from it would otherwise lose sight of it
    /// (#219); the agent tree and switcher show `agentJobScope()`, which adds
    /// these. `/resume` clears the list: the resumed conversation is not their
    /// successor. Owned by `allocator`.
    handed_off_sessions: std.ArrayList(@import("core/session_id.zig").SessionId) = .empty,

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
    // mcp_sessions / worktree_stack / abort / permission_ctx / session_rules /
    // usage / transcript_writer / activated_tools / active_skill /
    // cwd_abs / project_dir / system_prompt。
    // 这些是会话状态,每 App 实例独立 = 天然 per-session 隔离。
    // **注:此分区是注释级"地图"(未来真拆分的指引),非编译器 enforced 边界——
    //   加字段时自觉归对区。真拆 struct 时才需 enforcement。**
    conversation: Conversation,
    /// The I/O runtime the process runs on; shared with every client and the
    /// kernel flows a command runs inline (`/login`, issue #33).
    io: std.Io,
    api_client: client_mod.Client,
    /// OpenAI 后端(config.provider_kind==.openai 时非 null)。与 api_client 二选一:
    /// provider() 据 config.provider_kind 选哪个的 .provider()。**core/UI 只见 App.provider()
    /// 返回的中立 Provider,不知道背后是哪家**(多 Provider 重构 P3 组装层)。
    openai_client: ?openai_mod.OpenAIClient = null,
    /// Gemini 后端(config.provider_kind==.gemini 时非 null)。持有状态缓存句柄表(C3)。
    gemini_client: ?gemini_mod.GeminiClient = null,
    /// Held while a route switch builds a transport client and while it moves
    /// `config.provider_kind`, and by `cancelInFlightRequest`: another thread
    /// calling `provider()` would otherwise read the new kind before the new
    /// client is visible to it (or the client half-written). Clients are never
    /// freed before `deinit`, so this is the only window.
    route_mutex: sync.Mutex = .{},
    /// Built once, after every MCP server has reported (`publishMcpServers`:
    /// in `init`, or at the interactive REPL's first join point), and kept for
    /// the whole session, so the slices, the dynamic descriptions
    /// (`describe_fn`, env overrides) and `enabled_tool_names` live in
    /// `tool_defs_arena`, released in `deinit`. A description may also be a
    /// static string, so the defs are never freed one by one. Empty while
    /// `tool_surface` is not `.ready`.
    tool_defs: []json_mod.ToolDefinition,
    /// Whether `tool_defs`, `enabled_tool_names` and `system_prompt` have
    /// been built, or what they are waiting for.
    tool_surface: ToolSurface = .unbuilt,
    tool_defs_arena: std.heap.ArenaAllocator,
    /// 当前启用的工具名（含动态 Skill/MCP）。用于 system prompt 的 # Using your tools
    /// 段按工具集裁剪 + 构造 PromptContext。在 `tool_defs_arena` 里。
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
    /// `skillOverrides` from the Claude Code settings files. `skills` and
    /// `skill_runtime` point here; `/skills` changes it (`applySkillOverrides`).
    skill_overrides: skill_overrides_mod.Overrides,
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
    /// 最近一次 loadHooks 发现的坏配置(每处被跳过的文件/事件/entry/hook 一条)。
    /// 坏 hook 不报错只是永不触发——`/hooks` 列出,启动横幅与 `/doctor` 计数。
    hook_diagnostics: ?@import("permission/hooks.zig").Diagnostics = null,
    /// 会话根目录:启动时对进程 cwd 拍的字符串快照。读它的有七处(Bash 子进程 chdir、
    /// Read/Write/Edit/Glob 的 base_dir、权限 match_ctx.cwd、沙箱 profile、系统提示词、
    /// project_dir、KG 项目目录),而 agent 的工作本身就会改名/搬走目录。写它的只有两条路:
    /// `refreshWorkspaceRoot`(每轮 run 装配前校验一次,改名了就整体跟过去)与
    /// `switchWorkingRoot`(EnterWorktree / ExitWorktree,run 中途也会发生;工具每次调用经
    /// HostServices.workingRoot 读当前值)。旧串一律退役,不释放。
    cwd_abs: ?[]u8 = null,
    /// `refreshWorkspaceRoot` 已就"目录不存在"提醒过(每个状态只提醒一次,不刷屏)。
    root_missing_warned: bool = false,
    /// 改名后退役的旧根 / 旧 project_dir / 旧 system prompt:不释放,留到 deinit。web 与 daemon
    /// 线程直接读 `cwdAbs()` / `project_dir_or_empty()`,正在跑的 run 也借着旧串;改名极少发生,
    /// 每次多留几个字符串,换来"借用者永不悬垂"。
    retired_workspace_strings: std.ArrayList([]u8) = .empty,
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
    /// 本 session 的 memdir 绝对路径(通道 B 自动记忆;`{home}/.metacodes/projects/<hash>/memory`,
    /// owned)。init 时算一次,挂 permission_ctx.memdir_abs(写豁免)。空串=禁用/无 home。
    memdir_abs: []u8 = &.{},
    /// TinyKG 客户端(记忆/计划/DAG;设计 KG_DESIGN v3-final)。null = 未初始化
    /// (缺 home 等);non-null 但 !ready = degraded。工具经 ctx.kg 拿指针。
    kg: ?@import("kg/client.zig").KgClient = null,
    /// Starts this install's TinyKG service when a session needs it; owned
    /// here, shared by `kg` and every clone of it (address-stable).
    kg_autostart: ?*@import("app/kg_autostart.zig").Autostart = null,
    /// per-project 指针目录 `{home}/.metacodes/projects/<hash>`(kg_root/kg_inbox 落此)。owned。
    kg_projects_dir: []u8 = &.{},
    /// KG 启动注入快照(kg/inject.zig;owned)。空串=空态(不注入)。
    kg_summary: []u8 = &.{},
    /// System-One advisor runtime (`src/jev/runtime.zig`); null = not configured.
    jev: ?*@import("jev/runtime.zig").Runtime = null,
    /// 模型长任务 scratchpad（Task* 工具共享）
    tasks: TaskStore,
    /// Session-scoped objective state for /goal and /loop.
    goal_state: GoalState,
    /// Issue #277: charges `goal_state` for every Run on this App - REPL,
    /// web, daemon, headless alike - and writes goal.json when it changes.
    /// Set once `app` has its final address.
    goal_meter: ?@import("core/goal.zig").Meter = null,
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
    /// Issue #276: the date `user_context` states and the date the model was
    /// last told; runs announce a later local date once (agent_loop).
    time_announcer: ?@import("core/time_context.zig").Announcer = null,
    /// 运行时工具表（Skill + MCP 工具都注册到这里）。
    dyn_registry: DynRegistry,
    /// 已连接的 MCP server。每个 owns 一个 McpClient + McpSession（一一对应）。
    /// 退出时 deinit 反向关闭：先 session（释放 binding 内存）再 client（关 transport）。
    mcp_sessions: std.ArrayList(McpSessionEntry),
    /// Every configured MCP server and its startup outcome (for /mcp).
    mcp_report: McpReport = .{},
    /// Owns the resolved MCP configuration, the startup jobs and `mcp_report`
    /// (child of `allocator`, released in deinit). Null until MCP servers are
    /// loaded.
    mcp_arena: ?*std.heap.ArenaAllocator = null,
    /// MCP startup progress for renderers on any thread (counters only).
    mcp_status: mcp_startup.Status = .{},
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

    /// What a host settles before `App.init` instead of leaving it to init.
    pub const InitOptions = struct {
        /// The TUI theme, already resolved (`resolveThemeVariant`). The CLI
        /// resolves it first so the startup splash can play while init runs;
        /// init must not query the terminal (OSC 11) while the splash owns it.
        /// Null resolves it here.
        theme_variant: ?@import("repl/tui/theme.zig").Variant = null,
        /// Answer `/v1/models` from the state root's copy of an earlier
        /// start's answer when it is fresh, refreshing it in the background
        /// (`api/models_cache.zig`). Only the REPL sets it: it is the host
        /// that takes the refreshed answer, at its idle points
        /// (`adoptModelCatalogRefresh`).
        models_cache: bool = false,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: types.Config,
        api_key: []const u8,
    ) !*App {
        return initWithOptions(allocator, io, config, api_key, .{});
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: types.Config,
        api_key: []const u8,
        options: InitOptions,
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
            .route_strings = route_strings_mod.RouteStrings.init(allocator),
            // 本会话身份(路由 + transcript 目录)。`--session <id>` 显式指定(subprocess resume 复用
            // 挂起 session 的目录,task#20);否则 gen 新的。非法/非 24-char id 回退 gen。
            .session_id = if (config.session_id) |s|
                (@import("core/session_id.zig").SessionId.fromSlice(s) orelse @import("core/session_id.zig").gen())
            else
                @import("core/session_id.zig").gen(),
            .conversation = Conversation.init(allocator),
            .file_change_journal = @import("core/file_change.zig").Journal.init(std.heap.c_allocator),
            .io = io,
            .api_client = client_mod.Client.initWithBaseUrl(allocator, io, api_key, config.model, config.base_url),
            .tool_defs = &.{}, // 占位，下面重建
            .tool_defs_arena = std.heap.ArenaAllocator.init(allocator),
            .permission_ctx = permission_mod.createContext(config.permission_mode, allocator),
            .abort = AbortSignal.init(),
            .skills = SkillSet.init(allocator),
            .skill_runtime = skill_cli_adapter.Runtime.init(allocator, io),
            .skill_overrides = skill_overrides_mod.Overrides.init(allocator),
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
        // The CLI resolves the state root (src/main.zig) and passes it in. An App
        // built without one keeps the historical `$HOME/.metacodes`.
        if (app.config.state_root.len == 0) if (platform_paths.homeDir()) |home| {
            app.state_root_default = try @import("util/state_root.zig").legacyDefault(allocator, home);
            app.config.state_root = app.state_root_default.?;
        };
        errdefer if (app.state_root_default) |owned| allocator.free(owned);
        errdefer app.tool_defs_arena.deinit();

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

        // A Metask login is process-scoped: retain the same Session object
        // used by turn-boundary refresh so a gateway 401 can force-refresh the
        // rotating token without opening a second single-flight domain.
        if (config.metask_oauth_selected) if (config.provider_profile) |profile_name| if (std.ascii.eqlIgnoreCase(profile_name, "metask")) {
            if (provider_ids_mod.Slug.parse("metask")) |provider_id| {
                app.oauth_session = provider_oauth_mod.Session.initHome(allocator, app.stateRoot(), provider_id) catch null;
                if (app.oauth_session) |*loaded| {
                    if (loaded.load() catch false) {
                        app.oauth_session_provider = provider_id;
                        app.api_client.setRefreshCallback(@ptrCast(app), refreshMetaskToken);
                        if (app.openai_client) |*client| client.setRefreshCallback(@ptrCast(app), refreshMetaskToken);
                    } else {
                        loaded.deinit();
                        app.oauth_session = null;
                    }
                }
            } else |_| {}
        };

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
            var add_dir_scratch = std.heap.ArenaAllocator.init(allocator);
            defer add_dir_scratch.deinit();
            const skill_add_dirs = cliAddDirs(add_dir_scratch.allocator(), config.add_dirs, cwd) catch &.{};
            app.skill_runtime.loadDefaultWithExtraSources(
                cwd,
                @import("platform").paths.homeDir() orelse "",
                app.stateRoot(),
                skill_add_dirs,
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
            app.stateRoot(),
        ) catch |err| {
            if (app.plugin_snapshot != null) return err;
        };
        // 缓存 project root(供 ${CLAUDE_PROJECT_DIR} 替换)
        if (cwd_for_skills) |cwd| {
            app.project_dir = @import("skills/skill.zig").findRepoRoot(allocator, cwd) catch null;
            app.cwd_abs = allocator.dupe(u8, cwd) catch null;
        }

        // 选 TUI 主题(见 resolveThemeVariant);宿主已解析过就沿用,不再探终端。
        const theme_mod = @import("repl/tui/theme.zig");
        app.theme_variant = options.theme_variant orelse resolveThemeVariant(allocator, config.no_theme, app.stateRoot());
        app.theme = theme_mod.select(app.theme_variant, @import("repl/tui/term.zig").detectFromEnv(1));

        // 模型档位表(model_tiers):同一份 <state root>/config.json。解析失败降级为
        // 未配置(档位名全 inherit)并告警——配置拼写错误不该炸启动,但绝不静默。
        if (app.stateRoot().len > 0) {
            app.model_tiers_table = @import("api/model_tiers.zig").loadFromHome(allocator, app.stateRoot()) catch |err| tier_err: {
                @import("util/log.zig").warn("config", "model_tiers 解析失败({s}),按未配置处理", .{@errorName(err)});
                break :tier_err null;
            };
        }

        // Session 级权限记忆挂到 permission_ctx(persist 路径复用 match_ctx.home/project_root,
        // 在 settings 加载处统一设,无需独立 persist context)。
        app.permission_ctx.session_rules = &app.session_rules;
        // The App's settings loader reads `.claude/settings*.json` back on the
        // next start, so here an "allow always" answer may outlive the Session.
        app.permission_ctx.always_allow = .settings_file;
        app.permission_ctx.session = app.session_id; // 权限对话框路由到本会话视图(M5/M6)

        // `skillOverrides` (user < project < local settings) shape the Skill
        // listings below and gate every activation from here on. The local
        // layer lives where `/skills` writes it: the project root, or the
        // working directory outside a repository (Claude Code).
        app.skill_overrides.load(
            @import("platform").paths.homeDir() orelse "",
            app.project_dir orelse app.cwd_abs,
        ) catch |err| {
            @import("util/log.zig").warn("skill", "skillOverrides not loaded: {s}", .{@errorName(err)});
        };
        app.skill_runtime.overrides = &app.skill_overrides;
        app.skills.overrides = &app.skill_overrides;

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

        // MCP servers connect from here on, each on a worker thread, while the
        // rest of init runs; failures are logged one by one and never stop the
        // start. Their tools are registered, and the tool surface built, only
        // once every server has reported (`publishMcpServers` below, or the
        // REPL's first join point).
        app.beginMcpStartup();
        // A failed init frees the App the workers count into: stop them first.
        errdefer app.cancelMcpStartup();

        // 加载模型上下文窗口表(~/.metacode/models.toml)并挂到 client。
        // precedence 高于 probe → auto-compact 阈值优先用此表(offline 可靠 + 用户可编辑)。
        app.model_context.loadOrBundle(app.stateRoot());
        app.api_client.model_context = &app.model_context;
        if (app.openai_client) |*client| {
            client.model_context = &app.model_context;
        }
        if (app.gemini_client) |*client| {
            client.model_context = &app.model_context;
        }

        // Metask's authenticated catalog is authoritative for this session.
        // Fetch it once with the bearer, project limits/capabilities into the
        // provider host, and retain unknown fields as unknown rather than
        // inheriting the historical static inventory.
        if (config.metask_oauth_selected) if (config.provider_profile) |profile_name| if (std.ascii.eqlIgnoreCase(profile_name, "metask")) metask_catalog: {
            if (app.oauth_session) |*session| if (session.tokens) |tokens| {
                const gateway = if (std.c.getenv("METASK_GATEWAY_URL")) |raw|
                    std.mem.trimEnd(u8, std.mem.span(raw), "/")
                else
                    std.mem.trimEnd(u8, tokens.gateway_url orelse "", "/");
                if (gateway.len == 0 or !metask_oauth_mod.isGatewayOrigin(gateway)) {
                    @import("util/log.zig").warn("catalog", "Metask gateway origin unavailable; keeping the compiled route", .{});
                    break :metask_catalog;
                }
                const models_url = std.fmt.allocPrint(app.allocator, "{s}/v1/models", .{gateway}) catch {
                    @import("util/log.zig").warn("catalog", "Metask catalog URL allocation failed", .{});
                    break :metask_catalog;
                };
                defer app.allocator.free(models_url);
                const fetched = @import("api/catalog_fetch.zig").fetchModelPages(app.allocator, io, .{
                    .url = models_url,
                    .bearer = app.api_key,
                }) catch |err| {
                    @import("util/log.zig").warn("catalog", "Metask /v1/models fetch failed: {s}", .{@errorName(err)});
                    break :metask_catalog;
                };
                defer app.allocator.free(fetched.body);
                const host = app.providerHost() catch |err| {
                    @import("util/log.zig").warn("catalog", "Metask provider host unavailable: {s}", .{@errorName(err)});
                    break :metask_catalog;
                };
                host.ingestMetask(gateway, fetched.body, .messages_and_chat) catch |err| {
                    @import("util/log.zig").warn("catalog", "Metask model ingestion failed: {s}", .{@errorName(err)});
                };
                // The route selected before App construction was derived
                // from this same gateway origin; re-seed it after the
                // dynamic profile replacement so picker/turn-boundary
                // state points at the new offer generation.
                app.seedStartupSelection(host);
                app.api_client.catalog.loadFromModelsListJson(fetched.body) catch |err| {
                    @import("util/log.zig").debug("catalog", "Metask client catalog parse failed: {s}", .{@errorName(err)});
                };
                app.syncClientCatalogs();
                // No snapshot refresh here: the registry and swarm do not exist yet; their
                // first snapshot is taken from the fully loaded catalog at registry init below.
            };
        };

        // 探测 <base_url>/v1/models 取 model catalog（max_tokens）。失败静默，走本地 fallback。
        // METACODES_NO_PROBE=1 跳过：离线/沙箱/TTY 测试下 probeModels 的网络调用会 hang,
        // 跳过让 REPL 立即可用(走本地 model 单价表)。
        // **仅 anthropic 模式 probe**:probeModels 打 Anthropic 的 /v1/models,openai 模式下
        // api_client 是死资源、且其 base_url 指向 Anthropic 端点——probe 它=对错端点发真请求
        // (用真 key),必须跳过。OpenAI/Gemini 的 context window 走 ModelContext，未命中时
        // 才退回各 client 的硬编码默认值。
        const metask_session_active =
            std.ascii.eqlIgnoreCase(config.provider_profile orelse "", "metask") and
            app.oauth_session != null;
        // Recorded whether or not the probe below runs or answers: a later
        // `/models` key switch probes this same gateway again.
        if (MetaskKeyRoute.of(config, app.api_client.base_url)) |origin| {
            app.metask_key_route = .{ .gateway_origin = try allocator.dupe(u8, origin), .startup_key = api_key };
        }
        errdefer if (app.metask_key_route) |*route| route.deinit(allocator);
        if (config.provider_kind == .anthropic) {
            if (std.c.getenv("METACODES_NO_PROBE") == null and !metask_session_active) {
                // The account's key list waits for the `/models` key menu (ensureApiKeyCatalog).
                app.api_key_catalog_load = .deferred;
                app.loadModelCatalog(options.models_cache);
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

        // 计算本 session 的 memdir 路径(通道 B 自动记忆)+ mkdir + 挂权限豁免。
        app.initMemdir();

        // 初始化 TinyKG(记忆/计划/DAG 真相源)。best-effort:失败 → kg=null/degraded,
        // 注入段不出现；允许 TinyKG 的 treatment 仍广告工具并显式返回 kg_unavailable。
        app.initKg();

        // System-One advisor (Jev): METACODES_JEV_* over `jev` in
        // <state root>/config.json over the built-in default (CLI only).
        // Off with an empty url. Never fatal.
        app.jev = @import("jev/runtime.zig").load(app.allocator, app.api_client.http_client.io, app.homeDir(), app.stateRoot(), app.config.jev_builtin_default);

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
        // registry/swarm receive an owned snapshot here and are refreshed after every parent
        // catalog mutation; workers never read &app.api_client.catalog concurrently.
        const model_limits = @import("api/model_limits.zig").ModelLimitsSource{
            .catalog = &app.api_client.catalog,
            .model_context = &app.model_context,
            .max_tokens_override = config.max_tokens,
        };
        app.agent_jobs = @import("core/agent_job_registry.zig").AgentJobRegistry.initWithDialectResolver(std.heap.c_allocator, app.api_key, config.base_url, app.config.model, app.config.provider_kind, app.config.openai_protocol, app_dialect_resolver) catch |err| blk: {
            @import("util/log.zig").warn("agent", "agent_jobs registry init failed: {s}", .{@errorName(err)});
            break :blk null;
        };
        if (app.agent_jobs) |*jobs| try jobs.setLimits(model_limits);
        // Child agents authenticate the way the parent's resolved route does.
        if (app.agent_jobs) |*jobs| jobs.auth_scheme = config.auth_scheme;

        // Swarm 会话状态(lead 视角)。teammates registry 惰性(TeamCreate 才建);此处只装
        // 构造参数 + home。api_key/base_url/model 借 App 生命周期稳定内存(App 存活期不变)。
        app.swarm = .{
            .allocator = allocator,
            .session = app.session_id,
            .state_root = app.stateRoot(),
            .api_key = app.api_key,
            .base_url = config.base_url,
            .model = app.config.model,
            .provider_kind = app.config.provider_kind,
            .openai_protocol = app.config.openai_protocol,
            .auth_scheme = app.config.auth_scheme,
            .dialect_resolver = app_dialect_resolver,
            .limits = model_limits,
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

        // Wait for the MCP servers, register their tools and build the tool
        // surface and system prompt (`publishMcpServers`). The interactive
        // REPL (`mcp_connect = .first_request`) shows its prompt first and
        // does this at its first join point, before any request is assembled.
        if (!app.mcpJoinDeferred()) try app.publishMcpServers();

        // 构造首条 user-context message(通道 A:CLAUDE.md 链 + currentDate,system-reminder 包裹)。
        // 向上递归从 cwd 收集 CLAUDE.md;User 级读 ~/.claude/CLAUDE.md。失败仅 log,保持 null。
        // 通道 B(AutoMem):读 memdir 的 MEMORY.md 索引(已截断)拼进同一 user message。
        const auto_mem: []u8 = blk: {
            if (app.memdir_abs.len == 0) break :blk &.{};
            const memdir = @import("core/memory/memdir.zig");
            const idx = memdir.readIndexTruncated(allocator, app.stateRoot(), app.cwdAbs()) catch null;
            break :blk (idx orelse &.{});
        };
        defer if (auto_mem.len > 0) allocator.free(auto_mem);
        // One instant and zone for the session-start date text and the
        // announcer that tracks what the model was told since (issue #276).
        const time_context = @import("core/time_context.zig");
        const session_start = @import("util/time.zig").nowUnix();
        const session_zone = time_context.systemZone(session_start);
        app.time_announcer = time_context.Announcer.init(session_start, &session_zone, time_context.Announcer.defaultNow);
        app.goal_meter = .{
            .state = &app.goal_state,
            .observer = .{ .ctx = app, .changed = goalChanged },
        };
        app.user_context = @import("core/memory/user_context.zig").build(allocator, .{
            .cwd = app.cwdAbs(),
            .home = app.homeDir(),
            .state_root = app.stateRoot(),
            .auto_mem = auto_mem,
            .kg_summary = app.kg_summary,
            .now = session_start,
            .zone = session_zone,
        }) catch |err| blk: {
            @import("util/log.zig").warn("memory", "user_context build failed: {s}", .{@errorName(err)});
            break :blk null;
        };

        return app;
    }

    fn refreshMetaskToken(ctx: *anyopaque, stale_access_token: []const u8) anyerror![]u8 {
        const app: *App = @ptrCast(@alignCast(ctx));
        const session = if (app.oauth_session) |*loaded| loaded else return error.NoTokens;
        var site_buf: [1024]u8 = undefined;
        const token_url = try metask_oauth_mod.tokenUrl(metask_oauth_mod.siteUrl(), &site_buf);
        var exchange = oauth_exchange_mod.MetaskHttpExchange{
            .allocator = app.allocator,
            .io = app.api_client.http_client.io,
            .token_url = token_url,
        };
        return session.refreshIfStale(@import("util/time.zig").nowUnix(), exchange.exchange(), stale_access_token);
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
        // `config.state_root` may borrow this buffer, so it goes last, after
        // `app` itself is destroyed: read both fields now, not from the freed App.
        const allocator = app.allocator;
        const state_root_default = app.state_root_default;
        defer if (state_root_default) |owned| allocator.free(owned);
        // Every background worker stops (and is joined) before anything it
        // shares is freed; a host may already have done this (idempotent).
        app.stopBackgroundWork();
        // 最先 drain 后台 subagent：abort 全部 running → join 全部线程 → free。
        // 必须早于任何共享资源（agents/dyn_registry/skills/allocator）释放，
        // 否则在跑的后台线程会触碰已释放内存（UAF）。job 用专属 Client，不依赖 api_client。
        if (app.agent_jobs) |*aj| aj.deinit();
        // Swarm:abort+join 全 teammate → free（必须早于共享资源释放，同 agent_jobs 理由）。
        app.swarm.deinit();
        if (app.transcript_writer) |*w| w.deinit();
        app.handed_off_sessions.deinit(app.allocator);
        app.api_client.deinit();
        app.api_key_catalog.deinit();
        // A refresh still in flight finishes (and frees itself) on its own thread.
        if (app.models_refresh) |refresh| refresh.release();
        if (app.metask_key_route) |*route| route.deinit(app.allocator);
        if (app.login_worker) |worker| {
            worker.cancel();
            worker.join();
            app.allocator.destroy(worker);
            app.login_worker = null;
        }
        for (&app.parked_login_workers) |*slot| if (slot.*) |worker| {
            worker.cancel();
            worker.join();
            app.allocator.destroy(worker);
            slot.* = null;
        };
        app.model_picker.deinit();
        if (app.oauth_session) |*session| session.deinit();
        if (app.provider_host) |host| host.destroy();
        app.route_strings.deinit();
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
        if (app.kg_autostart) |starter| starter.destroy();
        if (app.kg_projects_dir.len > 0) app.allocator.free(app.kg_projects_dir);
        if (app.kg_summary.len > 0) app.allocator.free(app.kg_summary);
        if (app.jev) |runtime| runtime.destroy(app.allocator);
        app.tool_defs_arena.deinit();
        if (app.active_skill) |*active| {
            active.deinit();
            app.active_skill = null;
            app.permission_ctx.active_skill = null;
        }
        app.skill_runtime.deinit();
        app.skills.deinit();
        app.skill_overrides.deinit();
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
        if (app.mcp_arena) |arena_state| {
            app.mcp_report = .{};
            arena_state.deinit();
            app.allocator.destroy(arena_state);
            app.mcp_arena = null;
        }
        app.dyn_registry.deinit();
        {
            var it = app.activated_tools.keyIterator();
            while (it.next()) |k| app.allocator.free(k.*);
            app.activated_tools.deinit();
        }
        if (app.project_dir) |p| app.allocator.free(p);
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
        if (app.hook_diagnostics) |*d| d.deinit();
        if (app.cwd_abs) |c| app.allocator.free(c);
        for (app.retired_workspace_strings.items) |s| app.allocator.free(s);
        app.retired_workspace_strings.deinit(app.allocator);
        if (app.jobs) |*j| j.deinit();
        if (app.system_prompt) |s| app.allocator.free(s);
        if (app.user_context) |u| app.allocator.free(u);
        app.allocator.destroy(app);
    }

    /// Fill `api_key_catalog` for the `/models` key menu, once, the first time
    /// the menu is drawn. Startup does not wait for it: only that menu reads
    /// the list, and with a plain API key the account endpoint refuses the
    /// request, so fetching at startup was a failed round trip on every start
    /// (`api_keys.bearerFor`). Whatever the outcome, an empty list falls back
    /// to the key in use.
    pub fn ensureApiKeyCatalog(app: *App) void {
        if (app.api_key_catalog_load != .deferred) return;
        app.api_key_catalog_load = .loaded;
        const log = @import("util/log.zig");
        const login_token = @import("core/auth.zig").resolveStoredOAuthBearer(app.allocator, app.stateRoot()) catch null;
        defer if (login_token) |token| {
            std.crypto.secureZero(u8, token);
            app.allocator.free(token);
        };
        if (api_keys_mod.bearerFor(login_token, app.api_key, api_keys_mod.endpointNamed())) |bearer| {
            api_keys_mod.fetchInto(&app.api_key_catalog, app.allocator, app.api_client.http_client.io, app.api_client.base_url, bearer) catch |err| {
                log.debug("auth", "api key list probe failed: {s}", .{@errorName(err)});
            };
        } else {
            log.debug("auth", "api key list skipped: no login token for the account endpoint", .{});
        }
        if (app.api_key_catalog.entries.items.len == 0) {
            app.api_key_catalog.addCurrentKeyFallback(app.api_key) catch |err| {
                log.debug("auth", "current API key fallback unavailable: {s}", .{@errorName(err)});
            };
        }
    }

    /// Fill `api_client.catalog` from the route's `/v1/models`. With the cache
    /// on, a fresh stored answer for this endpoint and credential answers now
    /// and a background refresh fetches the current one; otherwise (and on
    /// any miss) the answer is fetched before init returns, as it always was,
    /// and stored for the next start.
    fn loadModelCatalog(app: *App, use_cache: bool) void {
        if (!use_cache) return app.probeModelCatalog();
        const log = @import("util/log.zig");
        const auth = app.routeAuthHeader() orelse return app.probeModelCatalog();
        defer app.freeRouteAuthHeader(auth);
        const header: std.http.Header = .{ .name = auth.name, .value = auth.value };
        const base_url = app.api_client.base_url;
        const key = models_cache_mod.Key.of(base_url, header);
        const now = @import("util/time.zig").nowUnix();

        if (models_cache_mod.load(app.allocator, app.stateRoot(), key, base_url, now, models_cache_mod.TTL_SECONDS)) |body| {
            defer app.allocator.free(body);
            if (app.api_client.catalog.loadFromModelsListJson(body)) |_| {
                log.debug("catalog", "/v1/models from the cache; refreshing in the background", .{});
                app.adoptMetaskKeyModels(base_url, body);
                app.models_refresh = models_cache_mod.Refresh.start(key, base_url, header, app.stateRoot()) catch |err| blk: {
                    log.debug("catalog", "background /v1/models refresh not started: {s}", .{@errorName(err)});
                    break :blk null;
                };
                return;
            } else |err| {
                log.debug("catalog", "cached /v1/models unusable ({s}); fetching", .{@errorName(err)});
                app.api_client.catalog.deinit();
                app.api_client.catalog = @import("api/catalog.zig").Catalog.init(app.allocator);
            }
        }

        const body = app.api_client.fetchModelsList() catch |err| {
            log.debug("catalog", "probeModels: {s} (falling back to local table)", .{@errorName(err)});
            return;
        };
        defer app.allocator.free(body);
        app.api_client.catalog.loadFromModelsListJson(body) catch |err| {
            log.debug("catalog", "parse /v1/models failed: {s}", .{@errorName(err)});
            return;
        };
        app.adoptMetaskKeyModels(base_url, body);
        models_cache_mod.store(app.allocator, app.stateRoot(), key, base_url, body, now) catch |err| {
            log.debug("catalog", "models cache not written: {s}", .{@errorName(err)});
        };
    }

    /// The credential header the Anthropic client's requests carry now
    /// (owned; `freeRouteAuthHeader`). Null when it cannot build one, as the
    /// client's own requests would then fail.
    fn routeAuthHeader(app: *App) ?@import("api/auth_header.zig").Header {
        return app.api_client.credential.header(app.allocator, app.api_client.auth_scheme) catch null;
    }

    fn freeRouteAuthHeader(app: *App, header: @import("api/auth_header.zig").Header) void {
        std.crypto.secureZero(u8, header.value);
        app.allocator.free(header.value);
    }

    /// Take a finished background `/v1/models` refresh into the live catalog.
    /// The REPL calls it where nothing is reading the catalog: before it
    /// reads input and before a turn. An answer for a route or credential the
    /// session has since left (a key picked in `/models`, another route) is
    /// dropped; the answer it would replace was fetched for the current one.
    pub fn adoptModelCatalogRefresh(app: *App) void {
        const refresh = app.models_refresh orelse return;
        if (!refresh.finished()) return;
        app.models_refresh = null;
        const key = refresh.key;
        const body = refresh.take();
        refresh.release();
        const fresh_body = body orelse return;
        defer std.heap.c_allocator.free(fresh_body);
        const log = @import("util/log.zig");

        const auth = app.routeAuthHeader() orelse return;
        defer app.freeRouteAuthHeader(auth);
        if (!key.eql(models_cache_mod.Key.of(app.api_client.base_url, .{ .name = auth.name, .value = auth.value }))) {
            log.debug("catalog", "background /v1/models answer is for another route; dropped", .{});
            return;
        }
        var fresh = @import("api/catalog.zig").Catalog.init(app.allocator);
        fresh.loadFromModelsListJson(fresh_body) catch |err| {
            fresh.deinit();
            log.debug("catalog", "background /v1/models answer unusable: {s}", .{@errorName(err)});
            return;
        };
        app.api_client.catalog.deinit();
        app.api_client.catalog = fresh;
        app.adoptMetaskKeyModels(app.api_client.base_url, fresh_body);
        app.refreshChildCatalogSnapshots() catch |err| {
            log.warn("catalog", "child catalog snapshot refresh failed: {s}", .{@errorName(err)});
        };
        log.debug("catalog", "adopted the background /v1/models answer ({d} models)", .{app.api_client.catalog.entries.items.len});
    }

    /// GET the route's `/v1/models` into the client catalog. Failure is silent:
    /// the local tables still answer.
    fn probeModelCatalog(app: *App) void {
        const body = app.api_client.fetchModelsList() catch |err| {
            @import("util/log.zig").debug("catalog", "probeModels: {s} (falling back to local table)", .{@errorName(err)});
            return;
        };
        defer app.api_client.allocator.free(body);
        app.api_client.catalog.loadFromModelsListJson(body) catch |err| {
            @import("util/log.zig").debug("catalog", "parse /v1/models failed: {s}", .{@errorName(err)});
        };
        app.adoptMetaskKeyModels(app.api_client.base_url, body);
    }

    /// Make a `/v1/models` answer from the Metask API-key route's gateway the
    /// provider host's Metask inventory.
    ///
    /// The one seam for every such answer — the startup probe (fetched,
    /// cached, or refreshed in the background) and a `/models` key switch
    /// today — so the picker cannot keep listing an inventory the
    /// client catalog has already replaced. `probed_messages_url` is the
    /// Messages endpoint the document was fetched for: an answer from any
    /// other endpoint (the session has switched provider) is not Metask's and
    /// is ignored. The document is copied.
    pub fn adoptMetaskKeyModels(app: *App, probed_messages_url: []const u8, document: []const u8) void {
        const route = if (app.metask_key_route) |*value| value else return;
        const origin = MetaskKeyRoute.gatewayOriginOf(probed_messages_url) orelse return;
        if (!std.mem.eql(u8, origin, route.gateway_origin)) return;
        const owned = app.allocator.dupe(u8, document) catch {
            @import("util/log.zig").warn("catalog", "Metask gateway models not kept: out of memory", .{});
            return;
        };
        if (route.models_json) |previous| app.allocator.free(previous);
        route.models_json = owned;
        // A host built before this answer holds the previous inventory, and
        // a picker kept open (#220) would otherwise go on listing it.
        if (app.provider_host) |host| {
            app.applyMetaskKeyCatalog(host);
            app.seedStartupSelection(host);
            app.refreshModelPicker() catch app.model_picker.markFailed();
        }
    }

    /// Replace the host's compiled Metask inventory with the API-key route's
    /// gateway document, when there is one. A document the host refuses
    /// leaves the previous inventory in place.
    fn applyMetaskKeyCatalog(app: *App, host: *provider_host_mod.Host) void {
        const route = app.metask_key_route orelse return;
        const document = route.models_json orelse return;
        host.ingestMetask(route.gateway_origin, document, .messages) catch |err| {
            @import("util/log.zig").warn("catalog", "Metask gateway models not offered ({s}); the picker keeps the previous list", .{@errorName(err)});
        };
    }

    /// The key a commit onto `provider_id` authenticates with on the Metask
    /// API-key route: the one picked in `/models`, else the one the session
    /// started with, scoped to Metask. Null for every other provider and route.
    fn metaskKeyFor(app: *const App, provider_id: provider_ids_mod.Slug) ?provider_binding_mod.ScopedSecret {
        const route = app.metask_key_route orelse return null;
        if (!provider_id.eqlText("metask")) return null;
        return .{ .provider_id = provider_id, .secret = app.selected_api_key_owned orelse route.startup_key };
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
        var store = provider_config_store.Store.initHome(app.allocator, app.stateRoot()) catch {
            app.provider_host = host;
            return host;
        };
        defer store.deinit();
        host.adoptDurableState(&store);
        if (host.startup_warning) |why| {
            // Reported once, when the host is built. A broken section otherwise
            // surfaces much later as "unknown provider" with nothing to connect
            // it to the configuration that caused it.
            @import("util/log.zig").warn(
                "provider",
                "part of <state root>/config.json did not apply ({s}); run `metacodes --check-providers`",
                .{why},
            );
        }
        app.applyMetaskKeyCatalog(host);
        app.seedStartupSelection(host);
        app.provider_host = host;
        return host;
    }

    /// Tell the kernel which route this session actually started on.
    ///
    /// `--provider`/`--offer` and the stored global selection are resolved in
    /// `main.zig` before an `App` exists, so without this the kernel believes
    /// the session has no selection: the picker marks nothing current,
    /// `/alias pin` reports "no selected offer", `/providers` shows no `*`, and
    /// — the one that actually breaks a session — the turn-boundary OAuth
    /// refresh, which keys on the effective selection, never runs.
    fn seedStartupSelection(app: *App, host: *provider_host_mod.Host) void {
        const snapshot = host.kernel.catalogSnapshot();
        if (app.config.selected_offer_id) |rendered| {
            const offer_id = provider_ids_mod.OfferId.parse(rendered) catch return;
            if (snapshot.find(offer_id)) |found| {
                host.kernel.seedSessionSelection(provider_selection_mod.RuntimeSelection.pinned(
                    found.offer_id,
                    found.offer_revision,
                    .session,
                ));
                return;
            }
        } else if (app.metask_key_route == null) return;
        // An ingested Metask catalog replaces the compiled profile, so its
        // offer ids legitimately change when the server supplies a model
        // display/limit record. Preserve the startup route by matching the
        // running model and wire instead of silently losing the session
        // selection after ingestion. The API-key route never had a startup
        // offer id at all: the model it runs on its gateway is the offer it is
        // on — only if it is that gateway's offer (a compiled one points at the
        // default gateway, which a `--base-url` session is not talking to) —
        // and a re-ingest after a key switch moves the mark with it.
        if (std.ascii.eqlIgnoreCase(app.config.provider_profile orelse "", "metask") or app.metask_key_route != null) {
            const protocol = if (app.config.provider_kind == .openai) "openai_chat" else "anthropic_messages";
            for (snapshot.items()) |*candidate| {
                if (candidate.provider_id.eqlText("metask") and
                    std.mem.eql(u8, candidate.request_model_id, app.activeModel()) and
                    std.mem.eql(u8, candidate.protocol, protocol) and
                    (app.metask_key_route == null or std.mem.eql(u8, candidate.endpoint_ref, app.api_client.base_url)))
                {
                    host.kernel.replaceSessionSelection(provider_selection_mod.RuntimeSelection.pinned(
                        candidate.offer_id,
                        candidate.offer_revision,
                        .session,
                    ));
                    return;
                }
            }
        }
    }

    /// Materialize the configured credential pool for the current session.
    ///
    /// The document holds only references — an id, an environment variable
    /// name, a kind, a priority — so reading it never touches a secret. The
    /// secrets are read here, from the process environment, and borrowed for
    /// the duration of request setup.
    /// Load the configuration document, or null when there is none to read.
    /// The caller owns it — see `credentialPoolFrom` for why that matters.
    pub fn loadConfigDocument(app: *App) ?provider_config_doc.Document {
        var store = provider_config_store.Store.initHome(app.allocator, app.stateRoot()) catch return null;
        defer store.deinit();
        return store.load() catch null;
    }

    /// Materialize the configured credential pool.
    ///
    /// Takes the document by pointer and **does not own it**: the returned
    /// entries borrow the account label out of it, so a version of this that
    /// loaded and freed the document internally would hand back dangling
    /// slices. The caller keeps the document alive for as long as it uses the
    /// pool.
    ///
    /// Secrets come from the named environment variables, never from the
    /// document: that document is read by several tools and is not mode 0600.
    pub fn credentialPoolFrom(
        document: *const provider_config_doc.Document,
        buffer: []provider_credential_mod.PoolEntry,
    ) []const provider_credential_mod.PoolEntry {
        const env = provider_credential_mod.EnvLookup.process();
        var len: usize = 0;
        // Iterated by pointer, so `slice()` reads the stored entry rather than
        // a loop-local copy that dies at the end of the iteration.
        for (document.providers.items) |*entry| {
            if (!entry.enabled) continue;
            for (entry.credentials.items()) |*credential| {
                if (len == buffer.len) break;
                const secret = env.get(credential.env.slice()) orelse continue;
                const kind = provider_credential_mod.parseCredentialKind(credential.kind.slice()) orelse continue;
                buffer[len] = .{
                    .id = credential.id,
                    .kind = kind,
                    .secret = secret,
                    .priority = credential.priority,
                    .account_or_plan = if (credential.account_or_plan) |*label| label.slice() else null,
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
    /// Returns null for every profile that declares none. A provider with no
    /// token endpoint has no lifecycle to run.
    pub fn oauthAccessToken(
        app: *App,
        built: *const @import("provider/profile.zig").ProviderProfile,
        now_seconds: i64,
    ) !?[]u8 {
        if (built.id.eqlText("metask") and !app.config.metask_oauth_selected) return null;
        const token_url = built.oauth_token_url orelse return null;
        var serves = false;
        for (built.accepted_credential_kinds) |kind| {
            if (provider_oauth_mod.servesKind(kind)) serves = true;
        }
        if (!serves) return null;

        // One session per provider, kept for the process: single flight is a
        // property of the object, so a fresh one per call would let two callers
        // both refresh and make the loser present a rotated-away token.
        const same_provider = if (app.oauth_session_provider) |id| id.eql(built.id) else false;
        if (!same_provider) {
            if (app.oauth_session) |*old_session| old_session.deinit();
            app.oauth_session = try provider_oauth_mod.Session.initHome(app.allocator, app.stateRoot(), built.id);
            app.oauth_session_provider = built.id;
            // No stored login is not an error: the provider simply falls
            // through to its API-key aliases.
            if (!(app.oauth_session.?.load() catch false)) {
                app.oauth_session.?.deinit();
                app.oauth_session = null;
                app.oauth_session_provider = null;
                return null;
            }
        }
        const session = &app.oauth_session.?;

        // The refresh grant must present the same OAuth client the
        // authorization grant was issued to. The login records it; the profile
        // supplies it when it declares one; the provider id is the historical
        // last resort for a login persisted before either existed.
        const before = session.generation;
        // Metask's control plane is JSON-only and intentionally rejects the
        // generic form-encoded RFC 6749 request. Keep this branch here (rather
        // than relying only on main's startup path) because the picker/turn
        // boundary can also refresh the process-scoped session.
        const token = if (built.id.eqlText("metask")) blk: {
            var site_buf: [1024]u8 = undefined;
            const metask_token_url = metask_oauth_mod.tokenUrl(metask_oauth_mod.siteUrl(), &site_buf) catch
                return error.RefreshFailed;
            var exchange = oauth_exchange_mod.MetaskHttpExchange{
                .allocator = app.allocator,
                .io = app.api_client.http_client.io,
                .token_url = metask_token_url,
            };
            break :blk try session.accessToken(now_seconds, exchange.exchange());
        } else blk: {
            var exchange = oauth_exchange_mod.HttpExchange{
                .allocator = app.allocator,
                .io = app.api_client.http_client.io,
                .endpoint = .{
                    .token_url = token_url,
                    .client_id = session.clientIdFor(built.oauth_client_id),
                },
            };
            break :blk try session.accessToken(now_seconds, exchange.exchange());
        };

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
        var listing = try app.listModelOffers();
        defer listing.deinit(app.allocator);
        try app.adoptModelListing(&listing);
    }

    /// The kernel's model list, taken without touching the picker. A caller
    /// whose picker other threads draw (a reply's, #328) lists outside its
    /// lock and adopts under it (`picker_host`).
    pub const ModelListing = struct {
        page: std.ArrayList(provider_control_plane.OfferSummary) = .empty,
        /// Borrows `page`. Null when the kernel could not list the catalog.
        listed: ?provider_control_plane.ListPage = null,
        current: ?provider_control_plane.OfferId = null,

        pub fn deinit(listing: *ModelListing, allocator: std.mem.Allocator) void {
            listing.page.deinit(allocator);
        }
    };

    /// Fails only when the provider host cannot be built.
    pub fn listModelOffers(app: *App) !ModelListing {
        const host = try app.providerHost();
        var listing: ModelListing = .{};
        listing.listed = host.kernel.modelList(.{}, .{}, app.allocator, &listing.page) catch null;
        listing.current = host.kernel.currentOfferId();
        return listing;
    }

    /// Make `listing` the picker's snapshot; a catalog that could not be
    /// listed marks the picker failed.
    pub fn adoptModelListing(app: *App, listing: *const ModelListing) !void {
        const listed = listing.listed orelse return app.model_picker.markFailed();
        try app.model_picker.adopt(listed, listing.current);
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
        app.last_persist_error = null;
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
                app.applyCommittedReasoning(accepted.selection);
                if (accepted.requires_persist) try app.persistGlobalSelection(host, accepted.selection);
                // A session-scoped choice is durable *for this session*: it has
                // to survive a resume, and it must not reach any other session,
                // which is why it goes to the session's own file.
                if (accepted.scope == .session) app.persistSessionSelection(accepted.selection) catch |err| {
                    // The route is live either way; what is lost is surviving a
                    // `/resume`, and a user told nothing would find that out
                    // only after resuming.
                    app.last_persist_error = @errorName(err);
                };
            },
            // The kernel already refused; the old runtime is still the live one.
            .rejected, .conflict => {},
        }
        return outcome;
    }

    /// A reasoning level chosen with the route (the picker's options step) is
    /// the session's from here: the control is what the route declares, and
    /// the client is what sends it. A commit that carries none keeps the level
    /// the session already ran with, as `/model use` always has. The route is
    /// live either way; a provider that takes no level only logs.
    fn applyCommittedReasoning(app: *App, selection: provider_selection_mod.RuntimeSelection) void {
        const value = selection.controls.get("reasoning_effort") orelse return;
        if (value != .text) return;
        const effort = types.ReasoningEffort.parse(value.text.slice()) orelse return;
        app.setReasoningEffort(effort) catch |err| {
            @import("util/log.zig").warn("provider", "reasoning effort {s} not applied: {s}", .{ effort.name(), @errorName(err) });
        };
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
        var store = try provider_config_store.Store.initHome(app.allocator, app.stateRoot());
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

    /// `--api-key`, labelled with the provider it was given for.
    ///
    /// The flag names no provider, so its owner is the provider the session
    /// started on: Metask on the historical path (no provider named), otherwise
    /// the route `main` resolved — `--provider`, `--offer`, or a stored global
    /// selection — which is also the scope startup resolved the flag in. Same
    /// rule as `main.selectedProfileIsMetask`, including its failure mode: a
    /// named provider without a resolved id owns nothing, so the key reaches no
    /// provider instead of falling back to Metask.
    fn cliApiKey(config: types.Config) ?provider_binding_mod.ScopedSecret {
        const secret = config.api_key orelse return null;
        const owner = if (config.provider_profile == null)
            provider_ids_mod.Slug.lit("metask")
        else
            provider_ids_mod.Slug.parse(config.resolved_provider_id orelse return null) catch return null;
        return .{ .provider_id = owner, .secret = secret };
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
        var oauth_kind: provider_credential_mod.CredentialKind = .openai_oauth;
        defer if (oauth_token) |value| {
            std.crypto.secureZero(u8, value);
            app.allocator.free(value);
        };
        var committed_provider: ?provider_ids_mod.Slug = null;
        if (resolvedProfileFor(host, selection)) |built| {
            committed_provider = built.id;
            // The kind comes from the profile, not from a constant: a profile
            // that accepts only `openai_codex_oauth` would reject a token
            // labelled `openai_oauth`, and the failure would look like a
            // missing credential rather than a mislabelled one.
            for (built.accepted_credential_kinds) |kind| {
                if (provider_oauth_mod.servesKind(kind)) {
                    oauth_kind = kind;
                    break;
                }
            }
            oauth_token = app.oauthAccessToken(built, now) catch |err| blk: {
                // A dead login is worth saying out loud: resolution will fall
                // through to an environment key, and "it silently used a
                // different credential" is the confusing outcome.
                @import("util/log.zig").warn(
                    "provider",
                    "OAuth token for '{s}' unavailable ({s}); falling back to other credentials",
                    .{ built.id.slice(), @errorName(err) },
                );
                break :blk null;
            };
        }

        // The document outlives the pool it produces: the entries borrow the
        // account label out of it.
        var pool_document = app.loadConfigDocument();
        defer if (pool_document) |*value| value.deinit();
        var pool_buffer: [provider_config_doc.MAX_POOL_CREDENTIALS]provider_credential_mod.PoolEntry = undefined;
        const pool = if (pool_document) |*value|
            credentialPoolFrom(value, &pool_buffer)
        else
            &.{};

        // The key the user stored for this provider (`login --provider`), in
        // that provider's own file: it can only ever answer for that provider.
        var stored_key: ?provider_api_key_store.Stored = if (committed_provider) |id|
            provider_api_key_store.load(app.allocator, app.stateRoot(), id) catch |err| blk: {
                @import("util/log.zig").warn("provider", "the stored key for {s} cannot be used: {s}", .{ id.slice(), @errorName(err) });
                break :blk null;
            }
        else
            null;
        defer if (stored_key) |*key| key.deinit();

        const binding = try provider_binding_mod.bind(
            &host.registry,
            host.kernel.catalogSnapshot(),
            selection,
            .{
                .pool = pool,
                .stored_api_key = if (stored_key) |*key| key.entry() else null,
                // On the Metask API-key route the session's own key — stored
                // by `metacodes login`, picked in `/models`, or `--api-key` —
                // authenticates a Metask offer, ahead of the environment, as
                // it does every turn on the historical path. Without it a
                // stored key is invisible here and the commit asks for a
                // sign-in the session does not need. Any other pick sees only
                // `--api-key`, and only for the provider the session started
                // on (`cliApiKey`).
                .cli_api_key = (if (committed_provider) |id| app.metaskKeyFor(id) else null) orelse cliApiKey(app.config),
                .stored_oauth = if (oauth_token) |value| .{
                    .kind = oauth_kind,
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
        // A cancel from another thread (`cancelInFlightRequest`) must see a
        // complete client whenever it sees the kind that selects it.
        {
            app.route_mutex.lock();
            defer app.route_mutex.unlock();
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
        }

        try app.switchModel(binding.request_model_id);

        // From here on nothing can fail, so the switch is all-or-nothing.
        //
        // The previous endpoint and secret are *retired*, not freed: a
        // background request thread can read `Client.base_url` and `api_key` at
        // any moment, those fields carry no mutex, and a torn `{new_ptr,
        // old_len}` read of a freed buffer is out of bounds. One retained
        // generation makes the worst case a wrong-but-in-bounds string.
        app.route_strings.install(endpoint, secret);

        {
            // Published under the lock that built the client it selects.
            app.route_mutex.lock();
            defer app.route_mutex.unlock();
            app.config.provider_kind = binding.transport;
        }
        app.config.openai_protocol = binding.openai_protocol;
        app.config.auth_scheme = binding.auth_scheme;
        // `config` is the snapshot subagent and swarm workers are constructed
        // from, so it has to move with the route or a spawned worker would dial
        // the previous provider's endpoint.
        app.config.base_url = endpoint;
        app.api_key = secret;
        app.api_client.credential = .{ .fixed = secret };
        app.api_client.base_url = endpoint;
        app.api_client.auth_scheme = binding.auth_scheme;
        if (app.openai_client) |*client| {
            client.credential = .{ .fixed = secret };
            client.base_url = endpoint;
            client.protocol = binding.openai_protocol;
            client.auth_scheme = binding.auth_scheme;
        }
        if (app.gemini_client) |*client| {
            client.credential = .{ .fixed = secret };
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
        app.api_client.credential = .{ .fixed = owned };
        if (app.openai_client) |*oc| oc.credential = .{ .fixed = owned };
        if (app.gemini_client) |*gc| gc.credential = .{ .fixed = owned };
        if (app.agent_jobs) |*aj| try aj.setApiKey(owned);

        app.api_client.catalog.deinit();
        app.api_client.catalog = @import("api/catalog.zig").Catalog.init(app.allocator);
        app.probeModelCatalog();
        try app.refreshChildCatalogSnapshots();
        app.models_picker_key_index = idx;
    }

    /// The OpenAI and Gemini clients keep their own copy of the parent catalog,
    /// so its image_input declarations reach their serializers and capability
    /// answers as they reach the Anthropic client's (issue #273). A failed
    /// copy keeps the previous one: the family table still answers.
    fn syncClientCatalogs(app: *App) void {
        inline for (.{ &app.openai_client, &app.gemini_client }) |slot| {
            if (slot.*) |*client| sync: {
                const copy = app.api_client.catalog.clone(app.allocator) catch |err| {
                    @import("util/log.zig").warn("catalog", "client catalog copy failed: {s}", .{@errorName(err)});
                    break :sync;
                };
                if (client.catalog) |*old| old.deinit();
                client.catalog = copy;
            }
        }
    }

    /// Refresh worker-owned catalog snapshots after the mutable parent catalog changes.
    fn refreshChildCatalogSnapshots(app: *App) !void {
        app.syncClientCatalogs();
        const source = @import("api/model_limits.zig").ModelLimitsSource{
            .catalog = &app.api_client.catalog,
            .model_context = &app.model_context,
            .max_tokens_override = app.config.max_tokens,
        };
        if (app.agent_jobs) |*jobs| try jobs.setLimits(source);
        // `app.swarm` is a plain field (undefined until App init assigns it), so this must only
        // run after init: the sole startup catalog loads happen before registry/swarm exist and
        // are covered by the initial setLimits at registry creation.
        if (app.swarm.teammates) |*teammates| try teammates.setLimits(source);
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

        // The prompt names the switched model from here on (promptModelName).
        const sw_cwd = @import("util/fs.zig").getCwd(app.allocator) catch "";
        defer if (sw_cwd.len > 0) app.allocator.free(sw_cwd);
        if (app.buildSystemPrompt(sw_cwd)) |sp| {
            if (app.system_prompt) |old| app.allocator.free(old);
            app.system_prompt = sp;
        } else |err| {
            @import("util/log.zig").warn("sysprompt", "not rebuilt after the model switch: {s}", .{@errorName(err)});
        }
    }

    /// `/skills`: record `changes` in the local settings file, then bring the
    /// model-facing listings (the Skill tool description and the system
    /// prompt's skills section) up to date for the next request. The Skill
    /// Runtime enforces the new states for every caller at once; background
    /// jobs and teammates keep the listing they were started with. Runs on
    /// the REPL thread between turns.
    pub fn applySkillOverrides(app: *App, changes: []const skill_overrides_mod.Change) skill_overrides_mod.CommitError!void {
        if (changes.len == 0) return;
        try app.skill_overrides.commit(changes);
        app.refreshSkillListings();
    }

    fn refreshSkillListings(app: *App) void {
        const log = @import("util/log.zig");
        // Descriptions live in the tool-definition arena, which outlives every
        // borrower of `tool_defs` (jobs copy them when they start).
        _ = app.skill_runtime.refreshModelTool(app.tool_defs, app.tool_defs_arena.allocator()) catch |err| {
            log.warn("skill", "Skill tool listing not refreshed: {s}", .{@errorName(err)});
        };
        if (app.buildSystemPrompt(app.cwdAbs())) |sp| {
            if (app.system_prompt) |old| app.retireWorkspaceString(old);
            app.system_prompt = sp;
        } else |err| {
            log.warn("skill", "system prompt not rebuilt after a skillOverrides change: {s}", .{@errorName(err)});
        }
    }

    /// Broadcast the active model as `config_changed{model}` without switching:
    /// the confirmation a per-message model override gets when it names the
    /// model already in force (SessionService.setTurnModel).
    pub fn announceModel(app: *App) void {
        app.emitConfig(.{ .model = app.activeModel() });
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
        var stored = auth_mod.loadDefault(app.allocator, app.stateRoot()) catch |err| switch (err) {
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
        auth_mod.saveDefault(app.allocator, app.stateRoot(), stored) catch |err| {
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
        // A fresh foreground session cannot inherit the old session's live
        // team. Tear down workers and their durable team directory before the
        // routing key changes; otherwise the new session sees a team it
        // cannot address (entries remain owned by the old session).
        if (app.swarm.hasTeam()) app.swarm.detachTeam();
        // Clear the old session's skill projection while its session key is
        // still current. Background jobs retain their own policy-frame
        // reference, so this cannot invalidate a child worker.
        app.clearActiveSkill();
        app.session_id = transcript.genSessionId();
        app.permission_ctx.session = app.session_id;
        app.swarm.session = app.session_id;
        if (app.transcript_writer) |*w| w.deinit();
        app.transcript_writer = null;
        app.initTranscriptWriter() catch |err| {
            @import("util/log.zig").warn("transcript", "rotate writer failed: {s}", .{@errorName(err)});
        };
        // R4-3:goal 属于被转走的旧会话——不清则旧 goal 记进新会话目录、用量记错账,
        // /resume 旧会话时又读到陈旧快照。新会话从无 goal 起步(对齐"新空会话"语义)。
        app.goal_state.clearInMemory();
    }

    /// Take ownership of a cancelled `/login` worker whose thread has not
    /// finished. With every slot taken, the oldest is waited for.
    pub fn parkLoginWorker(app: *App, worker: *login_worker.LoginWorker) void {
        worker.cancel();
        app.reapLoginWorkers();
        for (&app.parked_login_workers) |*slot| if (slot.* == null) {
            slot.* = worker;
            return;
        };
        const oldest = app.parked_login_workers[0].?;
        oldest.join();
        app.allocator.destroy(oldest);
        std.mem.copyForwards(?*login_worker.LoginWorker, app.parked_login_workers[0..3], app.parked_login_workers[1..4]);
        app.parked_login_workers[3] = worker;
    }

    /// Join and free the parked sign-ins that have settled.
    pub fn reapLoginWorkers(app: *App) void {
        for (&app.parked_login_workers) |*slot| if (slot.*) |worker| if (worker.isSettled()) {
            worker.join();
            app.allocator.destroy(worker);
            slot.* = null;
        };
    }

    /// `/clear` (Claude Code): a new foreground session with empty context.
    /// The old conversation stays on disk under its id (`/resume` finds it);
    /// what the model read or changed in it no longer counts for the new one
    /// (must-read-first table, file-change journal). Work the old session
    /// started in the background keeps running and stays in view, exactly as
    /// after a Ctrl+B hand-off.
    pub fn clearConversation(app: *App) void {
        app.persistTranscript();
        app.conversation.deinit();
        app.conversation = Conversation.init(app.allocator);
        app.read_state.clearAll();
        app.file_change_journal.reset();
        if (app.prepareHandOff()) |_| {
            app.completeHandOff();
        } else |_| {
            app.rotateSessionIdentity();
        }
    }

    /// Ctrl+B, before the background job is spawned: make room to record the
    /// hand-off, so `completeHandOff` cannot fail once a job owns the
    /// conversation (#219).
    pub fn prepareHandOff(app: *App) !void {
        try app.handed_off_sessions.ensureUnusedCapacity(app.allocator, 1);
    }

    /// Ctrl+B, after a background job took the conversation in the current
    /// session: start a fresh foreground session. The job keeps its session
    /// (invariant 8 of doc/UTF8_AND_SESSION_BOUNDARY_DESIGN.md); the new
    /// foreground keeps that session in `agentJobScope()`, so the agent tree
    /// and switcher still show it and can stop it. Requires `prepareHandOff`.
    pub fn completeHandOff(app: *App) void {
        app.handed_off_sessions.appendAssumeCapacity(app.session_id);
        app.rotateSessionIdentity();
    }

    /// Rebind a process-mode teammate to its explicitly inherited parent
    /// session. App.init creates a writer before command-line teammate mode is
    /// known, so close that writer and reopen the exact parent directory before
    /// the first turn is persisted.
    pub fn adoptSessionIdentity(app: *App, session: @import("core/session_id.zig").SessionId) !void {
        if (std.mem.eql(u8, app.session_id.asSlice(), session.asSlice())) return;
        if (app.transcript_writer) |*w| w.deinit();
        app.transcript_writer = null;
        app.session_id = session;
        app.permission_ctx.session = session;
        app.swarm.session = session;
        app.initTranscriptWriter() catch |err| {
            @import("util/log.zig").warn("transcript", "adopt session writer failed: {s}", .{@errorName(err)});
            return err;
        };
    }

    fn initTranscriptWriter(app: *App) !void {
        const state_dir = app.stateRoot();
        if (state_dir.len == 0) return error.NoHome;

        const cwd = try @import("util/fs.zig").getCwd(app.allocator);
        defer app.allocator.free(cwd);

        // session_id 传入,使 transcript 目录名 == App.session_id(统一,不再两个独立 gen)。
        const w = try transcript.Writer.init(app.allocator, cwd, .{ .path = state_dir }, app.activeModel(), app.session_id);
        app.transcript_writer = w;
    }

    /// Agent loop 每轮结束后调用一次，把 conversation 新增的 message 刷到 transcript。
    pub fn persistTranscript(app: *App) void {
        if (app.transcript_writer) |*w| w.flush(&app.conversation);
    }

    fn goalChanged(raw: *anyopaque, _: *const GoalState, _: @import("core/goal.zig").Meter.Change) void {
        const app: *App = @ptrCast(@alignCast(raw));
        app.persistGoal();
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

    /// Rebuild the conversation persisted under this App's own session
    /// directory, for an App built with `config.session_id` naming a session
    /// that ran before and that has not run since (#254: the daemon's
    /// `POST /sessions/create {"resume":true}`). The same steps as `/resume`:
    /// `transcript.loadTranscript`, a writer reopened past the restored
    /// messages (App.init opened one at zero, which would append them a second
    /// time), the session's goal and its own model route (`--resume <id>`
    /// prints the result, as `/resume` does). Leaves the App unchanged on error.
    pub fn resumePersistedConversation(app: *App) !ResumedConversation {
        std.debug.assert(app.conversation.len() == 0);
        const writer = if (app.transcript_writer) |*w| w else return error.NoSessionDir;
        if (!app.hasPersistedTranscript()) return error.TranscriptNotFound;

        var staged = Conversation.init(app.allocator);
        errdefer staged.deinit();
        try transcript.loadTranscript(&staged, writer.dir, app.allocator);
        const dir_owned = try app.allocator.dupe(u8, writer.dir);
        // Nothing below fails: switch to the restored conversation and its writer.
        app.conversation.deinit();
        app.conversation = staged;
        writer.deinit();
        writer.* = transcript.Writer.openExisting(app.allocator, dir_owned, app.activeModel(), app.conversation.len());
        app.loadGoalFromSessionDir(dir_owned);
        const route = app.restoreSessionRoute();
        if (route == .unavailable) {
            @import("util/log.zig").warn("session", "stored model route of session {s} is unavailable ({s}); the current route is kept", .{ app.session_id.asSlice(), @errorName(route.unavailable) });
        }
        return .{ .messages = app.conversation.len(), .route = route };
    }

    /// What resuming a stored session restored.
    pub const ResumedConversation = struct {
        messages: usize,
        route: RouteRestore,
    };

    /// The resumed session's own model route (`restoreSessionSelection`).
    pub const RouteRestore = union(enum) {
        /// It stored none; the current route serves it.
        kept,
        restored,
        /// It stored one that no longer resolves; the current route is kept.
        unavailable: anyerror,
    };

    /// Restore the route the session being resumed committed, and keep the
    /// writer's `metadata.model` on the route that will serve it (the writer
    /// was opened before the route changed).
    pub fn restoreSessionRoute(app: *App) RouteRestore {
        const restored = app.restoreSessionSelection() catch |err| return .{ .unavailable = err };
        if (!restored) return .kept;
        if (app.transcript_writer) |*writer| writer.model = app.activeModel();
        return .restored;
    }

    /// This session's transcript is on disk: it persisted a turn, or it was
    /// resumed. A session without one has nothing to resume.
    pub fn hasPersistedTranscript(app: *App) bool {
        const dir = app.sessionDir() orelse return false;
        var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buffer, "{s}/transcript.jsonl", .{dir}) catch return false;
        return pfs.exists(path.ptr);
    }

    /// Stop the work this session runs beside its driver and wait for each
    /// piece to end: background agent jobs (nested ones included), swarm
    /// teammates (in-process and process ones; the team is detached as
    /// `deinit` would), and background shell jobs. Records stay readable
    /// (`/state` rosters, TaskOutput) until `deinit`, and no new background
    /// work can start afterwards. Call it once nothing drives the App. For a
    /// host that closes a session before it can free it (#254: the
    /// multi-session daemon's destroy stops the work at once; only memory waits
    /// for the last lease). Idempotent; `deinit` calls it first.
    pub fn stopBackgroundWork(app: *App) void {
        app.cancelMcpStartup();
        if (app.agent_jobs) |*jobs| jobs.stop();
        app.swarm.detachTeam();
        if (app.jobs) |*jobs| _ = jobs.killAll();
    }

    /// Shut down this App's in-flight provider request for `signal` (after the
    /// caller set it): the call another thread makes to wake a run blocked in a
    /// provider read. Serialized with a route switch, which may build the
    /// transport client `provider()` then selects (`route_mutex`).
    pub fn cancelInFlightRequest(app: *App, signal: *const AbortSignal) void {
        app.route_mutex.lock();
        defer app.route_mutex.unlock();
        app.provider().cancel(signal);
    }

    /// 当前 session 目录(transcript.jsonl / suspend.json 所在)。无 writer → null。
    pub fn sessionDir(app: *App) ?[]const u8 {
        if (app.transcript_writer) |*w| return w.dir;
        return null;
    }

    /// 计算本 session 的 memdir 绝对路径(通道 B)+ mkdir + 挂权限豁免。
    /// memdir 禁用(env)或无 home/cwd → 留空串(降级:不豁免、不注入 AutoMem)。
    fn initMemdir(app: *App) void {
        const memdir = @import("core/memory/memdir.zig");
        if (!app.config.long_horizon_arm.usesAutoMemory(memdir.isEnabled())) return;
        const state_dir = app.stateRoot();
        const cwd = app.cwdAbs();
        if (state_dir.len == 0 or cwd.len == 0) return;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = memdir.memdirPath(state_dir, cwd, &buf);
        if (path.len == 0) return;
        memdir.ensureDir(state_dir, cwd) catch {}; // mkdir 失败不致命:写盘时模型拿到错误
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
        var store = provider_config_store.Store.initHome(app.allocator, app.stateRoot()) catch return;
        defer store.deinit();
        const result = provider_config_store.noteCredentialFailure(
            &store,
            provider_id,
            credential_id,
            class,
            @import("util/time.zig").nowUnix(),
            CREDENTIAL_COOLDOWN_SECONDS,
            null,
        ) catch |err| {
            // Not fatal — the request already failed — but a limit that cannot
            // be recorded is a limit rediscovered by hitting it every run.
            @import("util/log.zig").warn(
                "provider",
                "could not record the credential failure for '{s}' ({s})",
                .{ credential_id.slice(), @errorName(err) },
            );
            return;
        };
        if (app.provider_host) |host| {
            host.kernel.adoptConfigRevision(result.config_revision);
            host.kernel.noteAuthChanged(
                provider_id,
                credential_id,
                if (class == .invalid) .invalid else .active,
            );
        }
    }

    /// Refresh this session's OAuth access token if it is near expiry, and
    /// repoint every borrower at the new one.
    ///
    /// Called at a turn boundary, not at commit time. A commit copies the token
    /// that was valid then; a session that runs past its expiry would otherwise
    /// keep presenting it and start failing with 401s that look like a broken
    /// key. The single-flight session upstream means concurrent turns still
    /// perform one exchange.
    ///
    /// Returns true when the token was replaced. Providers with no OAuth
    /// lifecycle — and API-key-only routes — are a no-op; Metask participates
    /// through its JSON refresh exchange.
    pub fn refreshRouteCredential(app: *App) !bool {
        // A session that named its provider on the command line and never
        // opened the picker has no host yet — and reading `provider_host`
        // directly meant its token was never refreshed at all, which is the
        // failure this whole path exists to prevent. Build it when the session
        // is actually on a resolved route; a plain Metask session has no offer
        // id and skips the work entirely.
        if (app.provider_host == null and app.config.selected_offer_id == null) return false;
        const host = try app.providerHost();
        const selection = host.kernel.effectiveSelection() orelse return false;
        const built = resolvedProfileFor(host, selection) orelse return false;
        const token = (try app.oauthAccessToken(built, @import("util/time.zig").nowUnix())) orelse
            return false;
        errdefer {
            std.crypto.secureZero(u8, token);
            app.allocator.free(token);
        }

        if (app.route_strings.secret) |current| {
            if (std.mem.eql(u8, current, token)) {
                std.crypto.secureZero(u8, token);
                app.allocator.free(token);
                return false;
            }
        }

        // Background jobs get the new token through the same all-or-nothing
        // call the route switch uses; a failure here leaves everything on the
        // previous token rather than splitting the session across two.
        if (app.agent_jobs) |*jobs| {
            try jobs.setRoute(
                token,
                app.config.base_url,
                app.config.provider_kind,
                app.config.openai_protocol,
                app.config.auth_scheme,
            );
        }

        // Repoint every borrower before releasing the old bytes: a background
        // request thread can read `api_key` at any moment.
        // Same retention rule as a full route switch: the previous secret stays
        // readable for one more generation because an in-flight background
        // request may still be reading it.
        app.route_strings.installSecret(token);
        app.api_key = token;
        app.api_client.credential = .{ .fixed = token };
        if (app.openai_client) |*client| client.credential = .{ .fixed = token };
        if (app.gemini_client) |*client| client.credential = .{ .fixed = token };
        app.swarm.api_key = token;
        return true;
    }

    /// Enable, disable, or remove a provider instance through the control
    /// plane, and re-apply the result to the live catalog.
    ///
    /// Disabling preserves the instance's configuration and credential
    /// references; removing does not. Both take effect in every UI at once,
    /// because they change the catalog every UI reads.
    pub fn setProviderEnabled(app: *App, id: provider_ids_mod.Slug, enabled: bool) !void {
        var store = try provider_config_store.Store.initHome(app.allocator, app.stateRoot());
        defer store.deinit();
        const result = try provider_config_store.setProviderEnabled(&store, id, enabled, null);
        try app.reapplyProviderConfiguration(&store, result.config_revision);
    }

    /// True when the session's committed route belongs to `id`.
    ///
    /// Disabling or removing a provider does not tear a session off the route
    /// it is running on — that would be a worse surprise — but saying only
    /// "Disabled" while the session keeps using it is a message that describes
    /// something other than what happened.
    pub fn isRoutedThrough(app: *App, id: provider_ids_mod.Slug) bool {
        // Creates the host if this is the first thing to need it, which also
        // seeds the route a `--provider` session started on — without that the
        // kernel has no current offer and this always answered "no".
        const host = app.providerHost() catch return false;
        const current = host.kernel.currentOfferId() orelse return false;
        // Read from the *retired* catalog too: the rebuild has already dropped
        // a disabled provider's offers, so the live catalog no longer knows.
        if (host.kernel.catalogSnapshot().find(current)) |offer| return offer.provider_id.eql(id);
        if (host.retired) |*previous| {
            if (previous.find(current)) |offer| return offer.provider_id.eql(id);
        }
        return false;
    }

    pub fn removeProviderConfiguration(app: *App, id: provider_ids_mod.Slug) !void {
        var store = try provider_config_store.Store.initHome(app.allocator, app.stateRoot());
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
        var store = provider_config_store.Store.initHome(app.allocator, app.stateRoot()) catch return false;
        defer store.deinit();
        var document = store.load() catch return false;
        defer document.deinit();
        const entry = document.alias(name) orelse return false;

        const host = try app.providerHost();
        const resolution = try provider_alias_mod.resolve(host.kernel.catalogSnapshot(), entry);

        // The same commit path the picker uses, so an alias switch is durable
        // for the session exactly like any other session-scoped choice — a
        // second path that only committed in memory would silently lose the
        // route on the next `/resume`.
        const outcome = try app.commitModelSelection(.{
            .offer_id = resolution.offer_id,
            .offer_revision = resolution.offer_revision,
            .controls = .{},
            .scope = .session,
        });
        if (outcome != .committed) return error.AliasUnavailable;
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
        var store = provider_config_store.Store.initHome(app.allocator, app.stateRoot()) catch return 0;
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
        app.last_catalog_refresh_error = null;

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
            }) catch |err| {
                app.last_catalog_refresh_error = @errorName(err);
                continue;
            };
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
                        }) catch |err| {
                            app.last_catalog_refresh_error = @errorName(err);
                            continue;
                        };
                        // The list owns the body from here; on a failed append
                        // nothing else would ever free it.
                        documents.append(app.allocator, document.body) catch |err| {
                            app.allocator.free(document.body);
                            return err;
                        };
                    }
                }
            }

            host.ingestOpenRouter(provider_id, models.body, documents.items) catch |err| {
                app.last_catalog_refresh_error = @errorName(err);
                continue;
            };
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
        const summary = kg_provider_audit.recordAll(
            .{ .ctx = @ptrCast(&bridge), .appendFn = Bridge.append },
            replay.events,
        );
        // Advance only when nothing failed. A transient TinyKG outage otherwise
        // drops a whole window of decisions silently, which is the one thing an
        // audit record must not do; the journal's own eviction bounds how long
        // an unreachable sink can keep the retry set alive.
        if (summary.failed == 0) {
            app.provider_audit_cursor = replay.events[replay.events.len - 1].stream_sequence;
        }
        return summary;
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
        const state_dir = app.stateRoot();
        const cwd = app.cwdAbs();
        if (state_dir.len == 0 or cwd.len == 0) return;

        // **domain/指针目录都锚定 git 根**(H5:同一仓库无论从哪个子目录启动都是同一
        // domain,否则记忆按 cwd 碎片化——BM25/隔离/global 全建立在"一仓一 domain"上)。
        // project_dir = findRepoRoot(沿 cwd 上溯 .git);非 git repo 退 cwd。
        const anchor = app.project_dir orelse cwd;
        const anchor_hash = @import("core/transcript.zig").hashCwd(anchor);
        app.kg_projects_dir = std.fmt.allocPrint(app.allocator, "{s}/projects/{s}", .{ state_dir, anchor_hash[0..] }) catch return;
        // **必须建目录**(Linus H1):否则从 git 子目录启动时 anchor_hash != cwd_hash,
        // projects/<anchor_hash> 无人 mkdir → plan 落图的 kg_root 指针 writeIdPointer 失败
        // 被 catch{} 吞 → frontier 永不呈现 → 整个 P2 跨会话恢复静默半死。逐级 mkdir。
        mkdirKgProjectsDir(app.allocator, state_dir, anchor_hash);

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

        // Nobody should have to remember `metacodes kgd`: the client asks this
        // host to provision and start the install's service when it needs it.
        if (app.kg_autostart == null) app.kg_autostart = @import("app/kg_autostart.zig").Autostart.create(app.allocator, state_dir);
        var client = @import("kg/client.zig").KgClient.init(app.allocator, .{
            .state_root = state_dir,
            .domain = domain,
            .config_bin = null, // config.json kg_bin(P2 接线)
            .config_store = null,
            // exe_dir 不传:与 rg / kernel 同走 platform.paths.selfExeRealPath(OS 级 self-exe +
            // realpath),不再从 argv[0] 推导;字段只留给测试注入。
            .io = app.api_client.http_client.io,
            .autostart = if (app.kg_autostart) |starter| starter.hook() else null,
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
        mirrorInboxFrontier(app.allocator, &app.kg.?, app.kg_projects_dir, &app.tasks);
    }

    /// rebuildInboxMirror 的本体,入参显式(组件测试用真 TinyKG 直接驱动)。
    pub fn mirrorInboxFrontier(
        allocator: std.mem.Allocator,
        kg: *@import("kg/client.zig").KgClient,
        kg_projects_dir: []const u8,
        tasks: *@import("core/task_store.zig").TaskStore,
    ) void {
        const inject = @import("kg/inject.zig");
        const inbox = inject.readIdPointer(allocator, kg_projects_dir, "kg_inbox") orelse return;
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
            // 记下真实的租约持有者:它可能是别的会话或队友,任务锚/关闭提示/溯源据此
            // 只看本 agent 认领的行(本进程的身份要到 agent_loop.run 才声明)。
            tasks.createWithIdHeldBy(kg_id, subject, r.text, status, r.claimed_by) catch {};
        }
    }

    /// 逐级建 `{home}/.metacodes/projects/<hash>`(Linus H1)。best-effort:失败静默
    /// (下游 writeIdPointer 会 log.warn;此处仅尽量把目录建出来)。
    fn mkdirKgProjectsDir(allocator: std.mem.Allocator, state_dir: []const u8, hash: [16]u8) void {
        // The state root itself is created with its parents (an install's
        // `<prefix>/state` or a --state-dir); below it, one level at a time.
        @import("util/fs.zig").mkdirParents(state_dir) catch return;
        {
            const dir = std.fmt.allocPrint(allocator, "{s}/projects", .{state_dir}) catch return;
            defer allocator.free(dir);
            const dz = allocator.dupeZ(u8, dir) catch return;
            defer allocator.free(dz);
            _ = pfs.mkdir(dz, 0o700);
        }
        const full = std.fmt.allocPrint(allocator, "{s}/projects/{s}", .{ state_dir, hash[0..] }) catch return;
        defer allocator.free(full);
        const fz = allocator.dupeZ(u8, full) catch return;
        defer allocator.free(fz);
        _ = pfs.mkdir(fz, 0o700);
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

    /// Shift+Tab 的纯状态机:当前 mode → 下一个 mode。
    /// 循环档(default/acceptEdits)两者轮转;非循环档(bypass/auto/dont_ask)→ default。
    /// 抽成纯函数让状态机可纯单测(不构造 App),cyclePermMode 只做副作用接线。
    pub fn nextPermMode(mode: types.PermissionMode) types.PermissionMode {
        return switch (mode) {
            .default, .prompt => .accept_edits,
            .accept_edits => .default,
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

    /// 设置权限模式。Shift+Tab 轮换与 `/mode` 命名设置(U11)共用此路。
    /// **只写 permission_ctx.mode(单一源,U2 S2)**;读方走 permMode()。
    pub fn setPermMode(app: *App, to: types.PermissionMode) void {
        app.permission_ctx.setMode(to);
    }

    /// Shift+Tab:循环权限模式 default → acceptEdits → default。
    pub fn cyclePermMode(app: *App) void {
        app.setPermMode(nextPermMode(app.permMode()));
    }

    /// 设置 TUI 主题(变体 → 派生 theme → 持久化 <state root>/config.json)。U2 S1:抽出
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
        const state_dir = app.stateRoot();
        if (state_dir.len == 0) return false;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        try tui_config.saveTheme(arena.allocator(), state_dir, variant);
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
        return jobs.killAllForOwner(app.session_id);
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

    /// The agent jobs this foreground shows and lets the user stop: its own
    /// plus those of the sessions it handed off with Ctrl+B. Borrows
    /// `handed_off_sessions`; use it within one registry call.
    pub fn agentJobScope(app: *const App) @import("core/agent_job_registry.zig").SessionScope {
        return .{ .current = app.session_id, .handed_off = app.handed_off_sessions.items };
    }

    /// cwd 绝对路径(sandbox profile 工作目录),空串 = 未知(用 process cwd)。
    pub fn cwdAbs(app: *const App) []const u8 {
        return app.cwd_abs orelse "";
    }

    pub const RootRefresh = union(enum) {
        /// 目录还在(或本 App 没有记录根目录)。
        unchanged,
        /// 记录的路径不存在,进程 cwd 也给不出新名字:目录被删了。字符串保留原样;
        /// Bash 的 working_dir_unavailable 错误负责向模型说明。
        missing,
        /// 目录被改名了:进程 cwd 是内核句柄,改名后照样解析出新名字。已整体切到新路径
        /// (cwd_abs、project_dir、settings/permission match_ctx、系统提示词);值借自 cwd_abs。
        renamed: []const u8,
    };

    /// 每轮 run 装配前调一次(`session_service.buildRunOptions` 是唯一装配点)。
    ///
    /// 事故 2026-09-22:agent 把自己的 cwd 改名后,记录的字符串失效,之后每次 Bash 都在
    /// 子进程里 chdir 失败,模型在 exit 127 里空转到 400 轮上限。子进程报告通道让那次失败
    /// 会说话;这里让根目录跟着改名走,失败根本不发生。
    ///
    /// 只在 App 里做:App 的 cwd_abs 就是从进程 cwd 拍的(init 与 teammate_process 两处),
    /// 所以"字符串失效而 getcwd() 成功且不同"= 同一个目录换了名字。嵌入宿主的 AgentSession
    /// 用 workspace.root,与进程 cwd 无关,不走这里。会话身份(transcript 目录、KG 项目目录)
    /// 不随之漂移:那是会话开始时的目录,改名不改变它是哪一次会话。
    pub fn refreshWorkspaceRoot(app: *App) RootRefresh {
        const current = app.cwd_abs orelse return .unchanged;
        var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (current.len >= path_buf.len) return .unchanged;
        @memcpy(path_buf[0..current.len], current);
        path_buf[current.len] = 0;
        if (pfs.exists(@ptrCast(&path_buf))) return .unchanged;

        const resolved = @import("util/fs.zig").getCwd(app.allocator) catch return .missing;
        if (std.mem.eql(u8, resolved, current)) {
            app.allocator.free(resolved);
            return .missing;
        }
        app.adoptWorkspaceRoot(resolved);
        return .{ .renamed = app.cwd_abs.? };
    }

    /// 把会话根切到 `resolved`(owned,接管所有权),并重建每个捕获过旧字符串的消费者。
    fn adoptWorkspaceRoot(app: *App, resolved: []u8) void {
        const log = @import("util/log.zig");
        log.warn("workspace", "working directory renamed: {s} -> {s}", .{ app.cwdAbs(), resolved });
        // project_dir 沿 cwd 上溯 .git;旧值可能就在改名的目录下。
        if (app.project_dir) |old| app.retireWorkspaceString(old);
        app.project_dir = @import("skills/skill.zig").findRepoRoot(app.allocator, resolved) catch null;
        const old_root = app.cwd_abs;
        app.cwd_abs = resolved;
        // permission match_ctx 借的是 cwd_abs 的切片,settings 的 project 层按 project_dir 找:
        // 与 addDirectory 同一套重建顺序(先 deinit 旧 settings,再 load)。load 失败时
        // match_ctx 仍指向旧串,下面无条件覆写,保证旧串释放后没有借用者。
        if (app.settings) |*s| s.deinit();
        app.settings = null;
        app.permission_ctx.settings = null;
        app.loadSettings() catch |err| {
            log.warn("workspace", "settings reload after working directory rename failed: {s}", .{@errorName(err)});
        };
        app.permission_ctx.match_ctx.cwd = resolved;
        app.permission_ctx.match_ctx.project_root = app.project_dir orelse resolved;
        // 系统提示词的环境段写死了 cwd;按新路径重建(与 /model 切换同一 builder)。
        if (app.buildSystemPrompt(resolved)) |sp| {
            if (app.system_prompt) |old| app.retireWorkspaceString(old);
            app.system_prompt = sp;
        } else |err| {
            log.warn("workspace", "system prompt rebuild after working directory rename failed: {s}", .{@errorName(err)});
        }
        if (old_root) |old| app.retireWorkspaceString(old);
        app.root_missing_warned = false;
    }

    /// 旧串退役:借用者(其它线程的 `cwdAbs()` 读、正在跑的 run 的 ToolContext)可能还拿着它,
    /// 所以只登记、不释放;记账本身 OOM 就任它泄漏——一个串泄漏比借用者悬垂强。
    fn retireWorkspaceString(app: *App, s: []u8) void {
        app.retired_workspace_strings.append(app.allocator, s) catch {};
    }

    /// HOME(sandbox ~/ 展开)。可移植:POSIX=$HOME,Windows=$USERPROFILE 回退(见 platform/paths.zig)。
    pub fn homeDir(app: *const App) []const u8 {
        _ = app;
        return platform_paths.homeDir() orelse "";
    }

    /// This install's state root (util/state_root.zig); "" when unresolvable,
    /// which every consumer already treats like a missing $HOME.
    pub fn stateRoot(app: *const App) []const u8 {
        return app.config.state_root;
    }

    /// The configured System-One advisor, if any (address-stable for the App's lifetime).
    pub fn jevAdvisor(app: *App) ?*@import("jev/advisor.zig").Advisor {
        const runtime = app.jev orelse return null;
        return &runtime.advisor;
    }

    /// EnterWorktree: the tool has moved the process into `wt_path` (absolute);
    /// record where it came from and make the worktree the session's working
    /// root. The stack is the App's: the paths the tool passes live in its
    /// per-call arena, gone when the call returns.
    pub fn worktreePushTrampoline(state: *anyopaque, wt_path: []const u8, original_cwd: []const u8) anyerror!void {
        const app: *App = @ptrCast(@alignCast(state));
        const worktree_path = try app.allocator.dupe(u8, wt_path);
        errdefer app.allocator.free(worktree_path);
        const original = try app.allocator.dupe(u8, original_cwd);
        errdefer app.allocator.free(original);
        try app.worktree_stack.append(app.allocator, .{ .worktree_path = worktree_path, .original_cwd = original });
        errdefer _ = app.worktree_stack.pop();
        try app.switchWorkingRoot(worktree_path, true);
    }

    /// ExitWorktree: make the top entry's original directory the working root
    /// again and hand the caller a copy of the entry in `allocator`. Nothing
    /// changes unless all of that succeeds. Null when not in a worktree.
    pub fn worktreePopTrampoline(state: *anyopaque, allocator: std.mem.Allocator) anyerror!?WorktreeEntry {
        const app: *App = @ptrCast(@alignCast(state));
        const top = if (app.worktree_stack.items.len > 0) app.worktree_stack.items[app.worktree_stack.items.len - 1] else return null;
        const copy = WorktreeEntry{
            .worktree_path = try allocator.dupe(u8, top.worktree_path),
            .original_cwd = try allocator.dupe(u8, top.original_cwd),
        };
        errdefer {
            allocator.free(copy.worktree_path);
            allocator.free(copy.original_cwd);
        }
        try app.switchWorkingRoot(top.original_cwd, app.worktree_stack.items.len > 1);
        _ = app.worktree_stack.pop();
        app.allocator.free(top.worktree_path);
        app.allocator.free(top.original_cwd);
        return copy;
    }

    /// The working root tools start each call from (`HostServices.workingRoot`).
    fn workingRootTrampoline(state: *anyopaque) []const u8 {
        const app: *App = @ptrCast(@alignCast(state));
        return app.cwdAbs();
    }

    /// Moves the session's working root to `path` (absolute) for EnterWorktree /
    /// ExitWorktree. Like `adoptWorkspaceRoot`, the old strings are retired, never
    /// freed: the running Run and other threads may still hold them. Unlike it,
    /// settings are not reloaded: a Run in flight borrows them (reloading frees
    /// what it holds), and a worktree branch's own `.metacodes/settings.json`
    /// must not widen the session's permissions behind its back. The session
    /// identity (transcript, KG project, memory) stays where the session began.
    fn switchWorkingRoot(app: *App, path: []const u8, in_worktree: bool) !void {
        const owned = try app.allocator.dupe(u8, path);
        const old_root = app.cwd_abs;
        app.cwd_abs = owned;
        app.permission_ctx.match_ctx.cwd = owned;
        // A worktree is a checkout of its own: edits anywhere in it are in the
        // working directory. Back home, the repository root applies again.
        app.permission_ctx.match_ctx.project_root = if (in_worktree) owned else app.project_dir orelse owned;
        // The prompt's environment names the working directory; the next Run
        // sees the new one (this Run keeps the prompt it was sent with).
        if (app.buildSystemPrompt(owned)) |sp| {
            if (app.system_prompt) |old| app.retireWorkspaceString(old);
            app.system_prompt = sp;
        } else |err| {
            @import("util/log.zig").warn("workspace", "system prompt rebuild after a worktree switch failed: {s}", .{@errorName(err)});
        }
        if (old_root) |old| app.retireWorkspaceString(old);
        app.root_missing_warned = false;
    }

    /// L5:把 App 提供给工具的宿主能力(Skill 激活 / ToolSearch 激活 / Worktree push-pop 与
    /// 当前工作根)聚合成一个 HostServices——一个 ctx(=app)+ 若干 trampoline。
    pub fn hostServices(app: *App) tools_mod.HostServices {
        return .{
            .ctx = @ptrCast(app),
            .activateSkillFn = &activateSkillTrampoline,
            .activateToolFn = &activateToolTrampoline,
            .worktreePushFn = &worktreePushTrampoline,
            .worktreePopFn = &worktreePopTrampoline,
            .workingRootFn = &workingRootTrampoline,
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

    /// Configuration that loaded with problems, counted by the command that
    /// lists the details. The startup banner and `/doctor` show the counts, so
    /// a broken hook, Skill or agent file is noticed without knowing where to
    /// look: a malformed one does not fail, it is skipped or silently degraded.
    pub const ConfigProblems = struct {
        /// `/hooks`: each skipped file, event, entry or hook.
        hooks: usize = 0,
        /// `/skills`: Skills that did not load, skipped roots, and Skills
        /// without a `description` or with a blank `name`, once each.
        skills: usize = 0,
        /// `/agents`: agent files that did not load, and agents without a
        /// `description`.
        agents: usize = 0,

        pub fn total(self: ConfigProblems) usize {
            return self.hooks + self.skills + self.agents;
        }
    };

    pub fn configProblems(app: *const App) ConfigProblems {
        var problems = ConfigProblems{};
        if (app.hook_diagnostics) |*diag| problems.hooks = diag.items().len;
        if (app.skill_runtime.snapshot) |snapshot| {
            problems.skills = snapshot.issues.len + snapshot.skipped_sources.len;
            for (snapshot.skills) |record| problems.skills += @intFromBool(record.definition.hasDefinitionProblem());
        }
        problems.agents = app.agents.load_failures.items.len + app.agents.missingDescriptionCount();
        return problems;
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

    /// 收集 project + user settings 的 hooks(5 类事件),**跨层合并**成一个 HookSet(不再首个覆盖)。
    /// 合并语义:各层 matcher entry 全部并入(project 与 user 的 hook 并存,org 全局 hook 不被项目覆盖)。
    /// 坏配置照旧跳过,但每处跳过记进 `hook_diagnostics`(整份替换:reload 时反映文件现状),
    /// 再按 warn 打日志。`.claude/settings.local.json` 与 `--settings` 不读 hook,其中写了
    /// `hooks` 也报告,而不是静默不生效。
    fn loadHooks(app: *App, home: ?[]const u8) !void {
        const hooks_mod = @import("permission/hooks.zig");
        const log = @import("util/log.zig");
        var diag = hooks_mod.Diagnostics.init(app.allocator);
        errdefer diag.deinit();

        const candidates = [_]?[]const u8{
            if (app.project_dir) |r| (std.fmt.allocPrint(app.allocator, "{s}/.claude/settings.json", .{r}) catch null) else null,
            if (home) |h| (std.fmt.allocPrint(app.allocator, "{s}/.claude/settings.json", .{h}) catch null) else null,
        };
        defer for (candidates) |p| if (p) |x| app.allocator.free(x);

        // 读各层文件内容 → 交给可测 seam parseAndMerge(5 类事件跨层合并 + 诊断)。
        var layers: std.ArrayList(hooks_mod.Layer) = .empty;
        defer {
            for (layers.items) |layer| app.allocator.free(layer.content);
            layers.deinit(app.allocator);
        }
        for (candidates) |maybe_path| {
            const path = maybe_path orelse continue;
            const content = readFileAlloc(app.allocator, path) catch continue;
            layers.append(app.allocator, .{ .path = path, .content = content }) catch app.allocator.free(content);
        }

        // metacodes 读权限、但不读 hook 的 settings 文件。
        const project_local = if (app.project_dir) |r| (std.fmt.allocPrint(app.allocator, "{s}/.claude/settings.local.json", .{r}) catch null) else null;
        defer if (project_local) |p| app.allocator.free(p);
        for ([_]?[]const u8{ project_local, app.config.settings_path }) |maybe_path| {
            const path = maybe_path orelse continue;
            const loaded = for (layers.items) |layer| {
                if (std.mem.eql(u8, layer.path, path)) break true;
            } else false;
            if (loaded) continue;
            const content = readFileAlloc(app.allocator, path) catch continue;
            defer app.allocator.free(content);
            try hooks_mod.reportUnreadFile(app.allocator, &diag, path, content);
        }

        var hs = try hooks_mod.parseAndMerge(app.allocator, layers.items, &diag);
        for (diag.items()) |problem| {
            log.warn("hook", "{s}{s}{s}: {s}", .{
                problem.source,
                if (problem.location.len != 0) " " else "",
                problem.location,
                problem.message,
            });
        }
        if (app.hook_diagnostics) |*old| old.deinit();
        app.hook_diagnostics = diag;

        if (hs.isEmpty()) {
            hs.deinit();
            return;
        }
        app.hooks = hs;
        app.permission_ctx.hooks = &app.hooks.?;
        log.info("hook", "loaded hooks: Pre={d} Post={d} Stop={d} PreCompact={d} PostCompact={d} (merged across layers)", .{ app.hooks.?.pre_tool_use.len, app.hooks.?.post_tool_use.len, app.hooks.?.stop.len, app.hooks.?.pre_compact.len, app.hooks.?.post_compact.len });
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
                // 权限链与 Bash 工具看同一份设置:autoAllowBashIfSandboxed 只放行
                // sandbox_exec.plan 判为 .sandboxed 的调用(不再凭"设置开着"放行)。
                app.permission_ctx.sandbox = app.sandboxPtr();
                @import("util/log.zig").info("sandbox", "enabled (from {s})", .{path});
                if (!@import("sandbox/exec.zig").hostSupported()) {
                    const consequence = if (sb.fail_if_unavailable)
                        "failIfUnavailable refuses every Bash command"
                    else
                        "Bash commands run unsandboxed and autoAllowBashIfSandboxed does not apply";
                    @import("util/log.zig").warn("sandbox", "enabled in {s}, but this host has no sandbox backend (macOS sandbox-exec only): {s}", .{ path, consequence });
                }
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

    /// 从 <state root>/config.json 读 permission_rules 数组。失败仅 log，不影响启动。
    /// 同时把加载的 rule_set 绑到 permission_ctx.rules。
    fn loadPermissionRules(app: *App) !void {
        const state_dir = app.stateRoot();
        if (state_dir.len == 0) return error.NoHome;
        var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "{s}/config.json\x00", .{state_dir});
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

    /// Start connecting every MCP server the configuration sources declare
    /// (mcp/config.zig: metacodes' own `<state root>/config.json`, Claude
    /// Code's and Codex's), each on a worker thread bounded by its startup
    /// timeout. Nothing is registered here: `publishMcpServers` does that on
    /// this thread once every server has reported. Failures are recorded per
    /// server (`mcp_report`, `/mcp`) and never stop the App.
    fn beginMcpStartup(app: *App) void {
        const log = @import("util/log.zig");
        const arena_state = app.allocator.create(std.heap.ArenaAllocator) catch |err| {
            log.warn("mcp", "no servers connected: {s}", .{@errorName(err)});
            return;
        };
        arena_state.* = std.heap.ArenaAllocator.init(app.allocator);
        app.mcp_arena = arena_state;
        const startup = mcp_startup.Startup.begin(arena_state.allocator(), &app.mcp_status, .{
            .io = app.io,
            .state_root = app.stateRoot(),
            .home = app.homeDir(),
            .cwd = app.cwdAbs(),
            .workspace_root = app.project_dir_or_empty(),
            .codex_home = @import("platform").paths.codexHomeEnv() orelse "",
        }) catch |err| {
            log.debug("mcp", "no servers connected: {s}", .{@errorName(err)});
            return;
        };
        app.tool_surface = .{ .connecting = startup };
    }

    /// Whether `init` leaves the MCP join to the interactive REPL: only with
    /// `mcp_connect = .first_request` and at least one server to wait for, so
    /// a session without MCP builds everything in `init` as before.
    fn mcpJoinDeferred(app: *const App) bool {
        if (app.config.mcp_connect != .first_request) return false;
        return switch (app.tool_surface) {
            .connecting => |startup| startup.jobs.len != 0,
            .ready, .unbuilt => false,
        };
    }

    /// True once the provider-visible tool surface is built.
    pub fn toolSurfaceReady(app: *const App) bool {
        return app.tool_surface == .ready;
    }

    /// Every MCP server has reported, so `publishMcpServers` will not block
    /// (the workers may still be exiting). True when nothing is connecting.
    pub fn mcpStartupSettled(app: *const App) bool {
        return switch (app.tool_surface) {
            .connecting => |startup| startup.settled(),
            .ready, .unbuilt => true,
        };
    }

    /// The servers still starting, for `/mcp` while they connect (null when
    /// nothing is connecting). Owner thread only.
    pub fn mcpStartupInFlight(app: *const App) ?*const mcp_startup.Startup {
        return switch (app.tool_surface) {
            .connecting => |startup| startup,
            .ready, .unbuilt => null,
        };
    }

    /// Join the MCP startup (blocking until every server has reported),
    /// register the connected servers' tools and build the tool surface:
    /// `tool_defs`, `enabled_tool_names` and the system prompt. Idempotent.
    /// The one thread that owns the App calls it, with no Run in flight:
    /// `init` for every frontend but the interactive REPL, which calls it
    /// before it assembles its first request. Callers that must stay
    /// responsive wait for `mcpStartupSettled` first.
    pub fn publishMcpServers(app: *App) !void {
        switch (app.tool_surface) {
            .ready => return,
            .connecting => |startup| {
                startup.join();
                app.tool_surface = .unbuilt;
                app.registerMcpOutcomes(startup);
            },
            .unbuilt => {},
        }
        try app.buildToolSurface();
        app.tool_surface = .ready;
        app.mcp_status.published.store(true, .release);
    }

    /// Stop an MCP startup nobody published (teardown): the connects still in
    /// flight are interrupted and the clients that did connect are closed.
    fn cancelMcpStartup(app: *App) void {
        switch (app.tool_surface) {
            .connecting => |startup| {
                startup.cancelAndJoin();
                app.tool_surface = .unbuilt;
            },
            .ready, .unbuilt => {},
        }
    }

    /// Register every connected server's tools, in configuration order, and
    /// record each server's outcome in `mcp_report`. A client that cannot be
    /// registered is closed here; none is left without an owner.
    fn registerMcpOutcomes(app: *App, startup: *mcp_startup.Startup) void {
        const log = @import("util/log.zig");
        const a = app.mcp_arena.?.allocator();
        var statuses = std.ArrayList(McpServerStatus).initCapacity(a, startup.jobs.len) catch null;
        for (startup.jobs) |*job| {
            var status = McpServerStatus{
                .name = job.server.name,
                .origin = job.server.origin,
                .origin_path = job.server.origin_path,
                .log_path = job.log_path,
                .state = .failed,
            };
            switch (job.result) {
                .pending => unreachable, // joined: every job has settled
                .failed => |err| {
                    status.detail = mcp_startup.failureDetail(err, job);
                    if (err == error.McpAuthRequired) {
                        status.state = .needs_auth;
                        status.detail = std.fmt.allocPrint(a, "the server requires authorization (401/403); run `metacodes mcp login {s}`, or configure a bearer token or headers", .{job.server.name}) catch status.detail;
                    }
                    log.warn("mcp", "server '{s}' ({s}) failed: {s}", .{ job.server.name, job.server.origin.label(), status.detail });
                },
                .connected => |connected| {
                    var client = connected.client;
                    const tools_json = connected.tools_json;
                    defer std.heap.c_allocator.free(tools_json);
                    status.protocol = client.protocol_version;
                    if (app.registerMcpServer(job.server, &client, tools_json)) |count| {
                        status.state = .connected;
                        status.tool_count = count;
                        log.info("mcp", "connected '{s}' ({s}, {d} tools)", .{ job.server.name, client.protocol_version, count });
                    } else |err| {
                        client.close();
                        status.detail = @errorName(err);
                        _ = app.mcp_status.failed.fetchAdd(1, .release);
                        log.warn("mcp", "server '{s}' tool registration failed: {s}", .{ job.server.name, @errorName(err) });
                    }
                },
            }
            if (statuses) |*list| list.appendAssumeCapacity(status);
        }
        app.mcp_report = .{
            .servers = if (statuses) |list| list.items else &.{},
            .pending = startup.pending,
            .disabled = startup.disabled,
            .problems = startup.problems,
        };
    }

    /// The model the system prompt names. `--model-display-name` is the
    /// identity of the startup route; an explicit `/model` switch selects a
    /// new real model, and from then on the prompt names that model, through
    /// every later rebuild (`/skills`, a renamed or switched working root).
    pub fn promptModelName(app: *const App) []const u8 {
        if (app.model_switch_owned != null) return app.activeModel();
        return app.config.model_display_name orelse app.config.model;
    }

    /// The system prompt for the session as it stands, with `cwd` in its
    /// environment section: the one builder every rebuild goes through, so
    /// none can name another model (owned by `app.allocator`).
    fn buildSystemPrompt(app: *const App, cwd: []const u8) ![]u8 {
        return system_prompt_mod.buildFullWithDefs(app.allocator, app.promptModelName(), &app.skills, &app.agents, app.enabled_tool_names, app.memdir_abs, app.kgReady(), cwd, app.tool_defs);
    }

    /// Build `tool_defs` (static + dynamic: Skill, process plugins, MCP),
    /// `enabled_tool_names` and the system prompt from the registry as it
    /// stands. Called once, by `publishMcpServers`.
    fn buildToolSurface(app: *App) !void {
        // Build once to learn every tool name (dynamic ones included), make the
        // PromptContext from them, then build again with it so core tools get
        // their context-dependent long descriptions (cc tool.prompt(ctx)). Both
        // live in tool_defs_arena; the first, temporary set goes with the App.
        // The probe pass uses the teams-aware bootstrap ctx so enabled_names
        // and the final tool_defs gate swarm tools alike (otherwise
        // `--agent-teams` would leave them out of "Using your tools").
        const defs_allocator = app.tool_defs_arena.allocator();
        const probe_ctx = tools_mod.PromptContext{
            .agent_teams = app.config.agent_teams,
            .tinykg_enabled = app.config.long_horizon_arm.usesTinyKg(),
        };
        const probe_defs = try tools_mod.toToolDefinitionsFull(defs_allocator, &app.dyn_registry, &probe_ctx);
        const enabled_names = try defs_allocator.alloc([]const u8, probe_defs.len);
        for (probe_defs, 0..) |d, i| enabled_names[i] = d.name;

        const prompt_ctx = tools_mod.PromptContext{
            .permission_mode = app.config.permission_mode,
            .enabled_tool_names = enabled_names,
            .agent_type = "", // 主对话
            .include_git = true,
            .agent_teams = app.config.agent_teams, // F5:门控 swarm 工具进 tool_defs
            .tinykg_enabled = app.config.long_horizon_arm.usesTinyKg(),
        };
        const defs = try tools_mod.toToolDefinitionsFull(defs_allocator, &app.dyn_registry, &prompt_ctx);
        // The Skill tool's listing follows the current `skillOverrides` (a
        // `/skills` change made before an interactive REPL's first join is in
        // it; otherwise the bytes are the ones registration produced).
        _ = try app.skill_runtime.refreshModelTool(defs, defs_allocator);
        app.enabled_tool_names = enabled_names;
        app.tool_defs = defs;

        // 构造 system prompt。显式 display identity 只作用于模型自述/knowledge
        // cutoff；真实 transport model 仍独立驱动 provider、catalog、pricing 与 context。
        // 动态裁剪（对应 cc getUsingYourToolsSection(enabledTools)）。失败仅 log，保持 null。
        // 环境段 cwd 用进程 cwd(CLI 语义);Session 库消费方用 workspace.root(见 agent_session)。
        const cli_cwd = @import("util/fs.zig").getCwd(app.allocator) catch "";
        defer if (cli_cwd.len > 0) app.allocator.free(cli_cwd);
        const built = app.buildSystemPrompt(cli_cwd) catch |err| blk: {
            @import("util/log.zig").warn("sysprompt", "build failed: {s} (continuing without system prompt)", .{@errorName(err)});
            break :blk null;
        };
        // A prompt an interactive REPL rebuilt before its first join (`/model`,
        // `/skills`) listed no tools; nothing borrows it, no Run has started.
        if (app.system_prompt) |old| app.retireWorkspaceString(old);
        app.system_prompt = built;
    }

    /// Move a connected client into App ownership and publish its tools.
    /// Returns the number of tools registered.
    fn registerMcpServer(app: *App, server: @import("mcp/config.zig").Server, client: *McpClient, tools_json: []const u8) !usize {
        // Reserve every App-owned resource before publishing any tool
        // definition into dyn_registry. After registration succeeds the
        // final session append is infallible, so registry ctx_ptr values
        // cannot outlive an unowned/freed McpSession.
        const name_owned = try app.allocator.dupe(u8, server.name);
        errdefer app.allocator.free(name_owned);
        try app.mcp_sessions.ensureUnusedCapacity(app.allocator, 1);
        const client_heap = try app.allocator.create(McpClient);
        errdefer app.allocator.destroy(client_heap);
        client_heap.* = client.*;

        // **诚实登记(elicitation UI 未接线)**:client.elicit 回调机制已实现+测试(见 mcp/client.zig),
        // 但此处**不设** handler → 生产中 MCP server 发 elicitation 一律安全 decline(协议正确闭合,
        // tool 继续/优雅失败,不 hang)。接真 UI 需一个 elicitation 渲染器(同 custom UiRequest,TUI 暂无);
        // 有渲染器后在此 per-session 设 client_heap.elicit=路由到 ui_requester 即可,MCP 层零改。
        var session = McpSession.init(app.allocator, client_heap);
        errdefer session.deinit();
        try session.registerToolsFromJsonFiltered(&app.dyn_registry, name_owned, tools_json, .{
            .enabled = server.enabled_tools,
            .disabled = server.disabled_tools,
            .http_param_headers = server.transport == .http,
        });
        const count = session.bindings.items.len;
        app.mcp_sessions.appendAssumeCapacity(.{
            .name = name_owned,
            .client = client_heap,
            .session = session,
        });
        return count;
    }

    /// 把 app.abort 绑到进程级 SIGINT handler。**只在前台(TUI N=1)会话调一次。**
    /// SIGINT 是进程级单一信号——一个进程只有一个 handler,只能指向一个 abort。这对 TUI
    /// 正确(N=1:唯一会话即前台会话)。**多 Session(GUI)不用 SIGINT 路由**:GUI 没有
    /// "Ctrl+C 打到哪个会话"的歧义,它对每个会话**直接调 `app.abort.abort(reason)`**
    /// (AbortSignal.abort 已 public,app.abort 是 per-instance,各会话独立中断,互不影响)。
    /// 故 g_abort_signal 单指针不是多 session 缺陷——它是 TUI 单终端的正确机制,GUI 旁路它。
    /// (不预包 requestStop wrapper:GUI 真来时直接调 abort.abort + 那时定确切语义,避孤儿 API。)
    pub fn installSigintHandler(app: *App) !void {
        @atomicStore(?*AbortSignal, &g_abort_signal, &app.abort, .seq_cst);
        // 可移植:POSIX=SIGINT sigaction;Windows=SetConsoleCtrlHandler(见 platform/signal.zig)。
        platform_signal.installInterrupt(onSigint);
        // A closed terminal (SIGHUP) or a `kill` (SIGTERM) would otherwise end
        // the process mid-Run by default, leaving the Run for the next process
        // to close as abandoned. Stop the Run so it closes itself, then leave.
        // A disposition inherited as ignored (`nohup`) is kept.
        platform_signal.installTerminateUnlessIgnored(onTerminate);
    }

    /// Stop SIGINT from aborting this App's run; SIGINT still requests process
    /// shutdown. For the multi-session daemon (#254), which frees the App it
    /// was started with while the process lives on (`--sessions 0`, or a
    /// destroy of the session that adopted it): a later SIGINT must not write
    /// into it. The daemon's shutdown path aborts every session itself. A
    /// no-op when another App is the target.
    pub fn detachSigintAbort(app: *App) void {
        _ = @cmpxchgStrong(?*AbortSignal, &g_abort_signal, &app.abort, null, .seq_cst, .seq_cst);
    }
};

/// The provider-visible tool surface (`tool_defs`, `enabled_tool_names`,
/// `system_prompt`) is built once from the registry with every MCP server's
/// outcome in it, never from a partial one: what a provider sees must not
/// depend on how fast a server answered (the cache contract).
pub const ToolSurface = union(enum) {
    /// Built; every request reads it.
    ready,
    /// MCP servers are connecting on worker threads (the interactive REPL's
    /// `mcp_connect = .first_request`); nothing is built yet. The REPL joins
    /// with `publishMcpServers` before it assembles a request.
    connecting: *mcp_startup.Startup,
    /// Every server's outcome is registered but the build has not happened
    /// (during `init`, or after it failed for lack of memory).
    unbuilt,
};

/// One configured MCP server and what became of it at startup (for /mcp).
pub const McpServerStatus = struct {
    name: []const u8,
    origin: @import("mcp/config.zig").Origin,
    origin_path: []const u8,
    /// `needs_auth`: the server answered 401/403 (a failure with its own
    /// remedy: credentials, not a restart).
    state: enum { connected, failed, needs_auth } = .failed,
    /// Failure reason ("" when connected).
    detail: []const u8 = "",
    /// Negotiated protocol revision ("" when not connected).
    protocol: []const u8 = "",
    tool_count: usize = 0,
    /// The server's stderr log ("" when none).
    log_path: []const u8 = "",
};

pub const McpReport = struct {
    servers: []const McpServerStatus = &.{},
    pending: []const @import("mcp/config.zig").Pending = &.{},
    disabled: []const []const u8 = &.{},
    problems: []const @import("mcp/config.zig").Problem = &.{},
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
    if (@atomicLoad(?*AbortSignal, &g_abort_signal, .seq_cst)) |s| {
        s.abort(.user_ctrl_c);
    }
}

/// SIGTERM / SIGHUP (Windows: console close, logoff, shutdown) arrived: the
/// interactive loop leaves at its next turn boundary instead of reading input.
pub fn terminateRequested() bool {
    return g_terminate_requested.load(.seq_cst);
}

var g_terminate_requested = std.atomic.Value(bool).init(false);

/// How long a requested termination may take before the process is ended
/// outright. A stopped Run with project rules re-attests its bundle before it
/// gives its lease up, and the project kernel may take up to 30 s
/// (`METACODES_PROJECT_KERNEL_TIMEOUT_MS`); ending the process inside that
/// would leave the session closed. Usually the process is gone in well under
/// a second. (Windows ends a process ~5 s after its console closes.)
const terminate_grace_s: c_uint = 45;

/// A termination request stops the process as Ctrl+C does (abort the Run,
/// request shutdown) and bounds how long that may take. Only the first one
/// acts: a terminal closing under a shell delivers SIGHUP twice, milliseconds
/// apart (the shell forwards its own; the kernel sends another as the shell
/// exits), and the second must not cut the first's shutdown short — nor
/// extend its bound. async-signal-safe: atomics and `alarm`.
fn onTerminate() void {
    const is_windows = @import("builtin").os.tag == .windows;
    if (!g_terminate_requested.swap(true, .seq_cst)) {
        onSigint();
        // SIGALRM's default action ends the process should the Run not stop.
        if (!is_windows) _ = std.c.alarm(terminate_grace_s);
    }
    // The console handler runs on its own thread, and Windows ends the process
    // as soon as it returns (or, for a closed console, after about 5 s): wait
    // here while the main thread stops the Run; the process exits under it.
    if (is_windows) Sleep(terminate_grace_s * 1000);
}

extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;

pub fn shouldQueueModelSwitchCompact(
    previous_model: []const u8,
    current_model: []const u8,
    previous_context_window: u32,
    current_context_window: u32,
) bool {
    return !std.mem.eql(u8, previous_model, current_model) and previous_context_window > current_context_window;
}

/// `--add-dir` values (NUL-separated, as `parseArgs` accumulates them) as
/// absolute paths resolved against `cwd`. Claude Code loads each directory's
/// `.claude/skills`; the Skill catalog reads the same directories.
fn cliAddDirs(arena: std.mem.Allocator, raw: ?[]const u8, cwd: []const u8) ![]const []const u8 {
    const list = raw orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, list, 0);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        try out.append(arena, if (std.fs.path.isAbsolute(part))
            part
        else
            try std.fs.path.resolve(arena, &.{ cwd, part }));
    }
    return out.toOwnedSlice(arena);
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

test "nextPermMode: Shift+Tab 循环状态机" {
    // 循环档两者轮转:default → acceptEdits → default(plan 模式已移除)。
    // 此前只有慢 PTY(test_mode_commit T08)覆盖;下沉成纯单测。
    try std.testing.expectEqual(types.PermissionMode.accept_edits, App.nextPermMode(.default));
    try std.testing.expectEqual(types.PermissionMode.default, App.nextPermMode(.accept_edits));
    // prompt 别名等价 default → acceptEdits。
    try std.testing.expectEqual(types.PermissionMode.accept_edits, App.nextPermMode(.prompt));
    // 非循环档(bypass/auto/dont_ask)→ default(对齐 cc:从特殊模式按一次回循环起点)。
    try std.testing.expectEqual(types.PermissionMode.default, App.nextPermMode(.bypass_permissions));
    try std.testing.expectEqual(types.PermissionMode.default, App.nextPermMode(.bypass));
    try std.testing.expectEqual(types.PermissionMode.default, App.nextPermMode(.auto));
    try std.testing.expectEqual(types.PermissionMode.default, App.nextPermMode(.dont_ask));
    // 两步回到起点(完整一圈)。
    try std.testing.expectEqual(
        types.PermissionMode.default,
        App.nextPermMode(App.nextPermMode(.default)),
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
    var io_rt = @import("platform").signal.threadedIo(std.testing.allocator, .{});
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
    app.permission_ctx.setMode(.auto);
    try std.testing.expectEqual(types.PermissionMode.auto, rec.last.?.mode);
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
    const EventJournal = @import("core/event_journal.zig").EventJournal; // test-scoped:不进 app.zig 非测试面
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
    const EventJournal = @import("core/event_journal.zig").EventJournal;

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
    // cyclePermMode 只触及 permission_ctx → 用 undefined App 只初始化这一个字段
    // (其余字段永不被读,安全)。锁住"config.permission_mode 不再是运行时真理源"这个不变式。
    var app: App = undefined;
    app.permission_ctx = permission_mod.createContext(.default, std.testing.allocator);

    try std.testing.expectEqual(types.PermissionMode.default, app.permMode());
    app.cyclePermMode(); // default → accept_edits
    try std.testing.expectEqual(types.PermissionMode.accept_edits, app.permMode());
    app.cyclePermMode(); // accept_edits → default
    try std.testing.expectEqual(types.PermissionMode.default, app.permMode());

    // task#14 修复机制:直写 permission_ctx.mode 的路径,permMode()=ctx 即时反映
    // (旧版靠 loop.zig sync-back 补 config,web 漏了它致 /state 陈旧)。
    app.permission_ctx.setMode(.auto);
    try std.testing.expectEqual(types.PermissionMode.auto, app.permMode()); // web /state 现在读这个,不陈旧
}

test "U3 syncModelMirrors: 所有 model 镜像同步(含 swarm.model,Linus U3 抓的第7点)" {
    const a = std.testing.allocator;
    var io_rt = @import("platform").signal.threadedIo(a, .{});
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
