//! UI-neutral Runtime and stateful AgentCore Session owners.
//!
//! `AgentRuntime` owns the immutable built-in tool catalog and outlives all
//! Sessions. `AgentSession` owns provider, credentials, workspace, tool
//! selection, conversation, permission memory, jobs and Run lifecycle state.

const std = @import("std");
const sync = @import("platform").sync;
const types = @import("../types.zig");
const provider_factory = @import("../api/provider_factory.zig");
const provider_mod = @import("../api/provider.zig");
const Conversation = @import("conversation.zig").Conversation;
const permission = @import("../permission.zig");
const permission_settings = @import("../permission/settings.zig");
const compact_kernel = @import("compact_kernel.zig");
const abort_mod = @import("../util/abort.zig");
const AbortSignal = abort_mod.AbortSignal;
const ui_backend = @import("protocol/ui_backend.zig");
const ui_request = @import("protocol/ui_request.zig");
const CoreEvent = ui_backend.CoreEvent;
const UiEvent = ui_backend.UiEvent;
const SessionId = ui_backend.SessionId;
const agent_loop = @import("agent_loop.zig");
const secure = @import("../util/secure.zig");
const tool_catalog = @import("tool_catalog.zig");
const workspace_mod = @import("workspace_policy.zig");
const ReadState = @import("read_state.zig").ReadState;
const JobRegistry = @import("job_registry.zig").JobRegistry;
const SessionRules = @import("../permission/session_rules.zig").SessionRules;
const ToolExecutionPolicy = @import("../tools.zig").ToolExecutionPolicy;
const ToolDispatcher = @import("../tools.zig").ToolDispatcher;
const ToolDefinition = @import("../json.zig").ToolDefinition;

pub const DEFAULT_BUILTIN_TOOLS = [_][]const u8{ "Read", "Write", "Edit", "Glob", "Grep", "Bash", "BashOutput", "KillShell" };
/// Built-ins whose complete execution dependencies are owned by AgentSession.
/// Process-level tools (Task, Cron, KG, MCP, worktree, notifications, etc.) are
/// deliberately rejected at Runtime creation instead of being advertised with
/// null Host state.
pub const SESSION_BUILTIN_TOOLS = DEFAULT_BUILTIN_TOOLS ++ [_][]const u8{"AskUserQuestion"};

pub fn isSessionBuiltin(name: []const u8) bool {
    for (SESSION_BUILTIN_TOOLS) |supported| {
        if (std.mem.eql(u8, supported, name)) return true;
    }
    return false;
}

pub const RuntimeConfig = struct {
    builtin_tools: []const []const u8 = &DEFAULT_BUILTIN_TOOLS,
    host_sync_tools: []const tool_catalog.HostSyncTool = &.{},
};

pub const HostSyncTool = tool_catalog.HostSyncTool;
pub const HostToolResult = tool_catalog.HostToolResult;
pub const HostToolOutcome = tool_catalog.HostToolOutcome;
pub const RunIdentity = tool_catalog.RunIdentity;
pub const HostRunIdentity = tool_catalog.HostRunIdentity;
pub const UiRequester = ui_request.UiRequester;

pub const AgentSessionUiRequester = struct {
    ctx: *anyopaque,
    requestFn: *const fn (
        ctx: *anyopaque,
        identity: RunIdentity,
        allocator: std.mem.Allocator,
        req: *const ui_request.UiRequest,
        out: *ui_request.UiResponse,
    ) anyerror!ui_request.RequestOutcome,

    fn request(self: AgentSessionUiRequester, identity: RunIdentity, response_allocator: std.mem.Allocator, req: *const ui_request.UiRequest, out: *ui_request.UiResponse) anyerror!ui_request.RequestOutcome {
        return self.requestFn(self.ctx, identity, response_allocator, req, out);
    }
};

pub const RuntimeError = error{
    RuntimeBusy,
    RuntimeUnavailable,
};

const RuntimeState = enum { active, destroying };

const SessionIdSource = struct {
    ctx: ?*anyopaque = null,
    nextFn: *const fn (ctx: ?*anyopaque) SessionId = systemNext,

    fn next(self: SessionIdSource) SessionId {
        return self.nextFn(self.ctx);
    }

    fn systemNext(_: ?*anyopaque) SessionId {
        return @import("session_id.zig").gen();
    }
};

/// Private construction seams make collision and rollback paths deterministic
/// without exposing test controls through the public Runtime/Session config.
const SessionCreateHooks = struct {
    session_id_source: SessionIdSource = .{},
    ctx: ?*anyopaque = null,
    after_id_registered_fn: ?*const fn (ctx: ?*anyopaque) anyerror!void = null,

    fn afterIdRegistered(self: SessionCreateHooks) !void {
        if (self.after_id_registered_fn) |hook| try hook(self.ctx);
    }
};

pub const AgentRuntime = struct {
    allocator: std.mem.Allocator,
    catalog: tool_catalog.Catalog,
    mutex: sync.Mutex = .{},
    live_sessions: usize = 0,
    state: RuntimeState = .active,
    /// 并存 Session 的 session_id 唯一性由本 registry 主动保证(collision detection),
    /// 不是"生成两个 ID 然后断言不同"。key 为 [24]u8 **值语义**(SessionId.bytes 定长
    /// 拷贝)——禁止借用 slice key(本仓吃过 HashMap slice key 悬挂的亏)。
    session_ids: std.AutoHashMapUnmanaged([24]u8, void) = .empty,

    /// collision 重试上限:生成器故障(恒返同值)时报不可达级错误而非无限循环。
    const MAX_SESSION_ID_RETRIES: usize = 8;

    pub fn create(allocator: std.mem.Allocator, config: RuntimeConfig) !*AgentRuntime {
        for (config.builtin_tools) |name| {
            if (!isSessionBuiltin(name)) return error.UnsupportedBuiltinTool;
        }
        const self = try allocator.create(AgentRuntime);
        errdefer allocator.destroy(self);
        const catalog = try tool_catalog.Catalog.init(allocator, config.builtin_tools, config.host_sync_tools);
        self.* = .{ .allocator = allocator, .catalog = catalog };
        return self;
    }

    pub fn destroy(self: *AgentRuntime) RuntimeError!void {
        self.mutex.lock();
        if (self.state != .active) {
            self.mutex.unlock();
            return error.RuntimeUnavailable;
        }
        if (self.live_sessions != 0) {
            self.mutex.unlock();
            return error.RuntimeBusy;
        }
        self.state = .destroying;
        // 生命周期合同:live_sessions==0 时 registry 必须为空(创建失败已回滚、
        // destroy 已注销)。非空即内部记账错误——Debug 下必炸。
        std.debug.assert(self.session_ids.count() == 0);
        self.mutex.unlock();

        const allocator = self.allocator;
        self.session_ids.deinit(allocator);
        self.catalog.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }

    /// 原子注册:锁下 getOrPut,已存在 → false(调用方换新 ID 重试)。
    fn registerSessionId(self: *AgentRuntime, sid: SessionId) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = try self.session_ids.getOrPut(self.allocator, sid.bytes);
        return !gop.found_existing;
    }

    fn unregisterSessionId(self: *AgentRuntime, sid: SessionId) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.session_ids.remove(sid.bytes));
    }

    pub fn createSession(self: *AgentRuntime, config: SessionConfig) !*AgentSession {
        return AgentSession.create(self, config);
    }

    fn retainSession(self: *AgentRuntime) RuntimeError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .active) return error.RuntimeUnavailable;
        self.live_sessions += 1;
    }

    fn releaseSession(self: *AgentRuntime) void {
        self.mutex.lock();
        std.debug.assert(self.live_sessions > 0);
        self.live_sessions -= 1;
        self.mutex.unlock();
    }
};

pub const WorkspaceConfig = workspace_mod.Config;
pub const ShellPolicy = workspace_mod.ShellPolicy;

pub const SessionConfig = struct {
    provider_kind: types.ProviderKind,
    api_key: []const u8,
    model: []const u8,
    base_url: ?[]const u8 = null,
    permission_mode: types.PermissionMode = .default,
    permission_rules: ?permission_settings.RuleSetInput = null,
    workspace: WorkspaceConfig,
    /// Explicit authority ceiling. It can only select names present in the
    /// Runtime catalog; an empty list creates a text-only Session deliberately.
    allowed_tools: []const []const u8,
    /// Optional synchronous Host UI bridge. The Host-owned callback context
    /// must outlive this Session.
    ui_requester: ?UiRequester = null,
    run_ui_requester: ?AgentSessionUiRequester = null,
    /// Host tool 身份锚点(type-erased,注册方 adapter 才可解释;core 只透传不解引用)。
    /// 合法状态:未选任何 Host tool → 允许 null;选了 Host tool 而 null → create 拒绝
    /// (admission 校验,不留"理论上不可能"的运行期空态)。owner 为创建方,须活到
    /// destroy 成功。
    host_identity_ctx: ?*anyopaque = null,
};

pub const Config = SessionConfig;

pub const EventSink = struct {
    ctx: *anyopaque,
    /// The callback is synchronous. Returning false is fatal for this Session.
    emit: *const fn (ctx: *anyopaque, session_id: SessionId, run_id: u64, event: CoreEvent) bool,
};

/// Borrowed, immutable tool surface for one admitted Run. Facades may add
/// run-scoped tools without mutating the Session catalog or the shared agent
/// loop. The owner must keep both fields alive until the synchronous Run and
/// every tool worker have quiesced.
pub const RunToolSurface = struct {
    definitions: []const ToolDefinition,
    dispatcher: ToolDispatcher,
};

const State = enum {
    idle,
    running,
    abort_requested,
    compacting,
    compact_finishing,
    mutating,
    poisoned,
    destroying,
};

/// Reasons an external host may use to stop a synchronous Run. Internal
/// failures use private AbortSignal reasons and cannot be forged by callers.
pub const AbortReason = enum {
    user_interrupt,
    timeout,

    fn internal(self: AbortReason) abort_mod.Reason {
        return switch (self) {
            .user_interrupt => .user_interrupt,
            .timeout => .timeout,
        };
    }
};

pub const LifecycleError = error{
    SessionBusy,
    StaleRun,
    AbortTooLate,
    InvalidSessionState,
    CallbackFailed,
};

pub const ModelMutationError = error{
    SessionBusy,
    InvalidSessionState,
    InvalidModel,
    OutOfMemory,
};

pub const PermissionRuleMutationError = error{
    SessionBusy,
    InvalidSessionState,
    OutOfMemory,
    ResourceLimit,
    InvalidRule,
};

pub const CompactError = error{
    InvalidOperationId,
    StaleCompact,
    SessionBusy,
    InvalidSessionState,
    OutOfMemory,
    ConcurrentMutation,
};

pub const AbortCompactError = error{
    InvalidOperationId,
    StaleCompact,
    AbortTooLate,
    InvalidSessionState,
};

pub const CompactOptions = struct {
    keep_recent: usize = 10,
};

/// Synchronous isolated execution hook used by a facade that needs a fresh
/// child Conversation while retaining this Session's admitted Run lifecycle.
///
/// `out_final_text` is owned by AgentSession and starts empty. The executor
/// appends only the final assistant text that is safe to commit to the parent
/// Conversation. It must return only after every event producer is quiescent.
pub const IsolatedRunExecutor = struct {
    ctx: *anyopaque,
    executeFn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        identity: RunIdentity,
        backend: *const ui_backend.UiBackend,
        abort: *const AbortSignal,
        out_final_text: *std.ArrayList(u8),
    ) anyerror!agent_loop.RunResult,

    fn execute(
        self: IsolatedRunExecutor,
        allocator: std.mem.Allocator,
        identity: RunIdentity,
        backend: *const ui_backend.UiBackend,
        abort: *const AbortSignal,
        out_final_text: *std.ArrayList(u8),
    ) anyerror!agent_loop.RunResult {
        return self.executeFn(
            self.ctx,
            allocator,
            identity,
            backend,
            abort,
            out_final_text,
        );
    }
};

/// Exactly-once capability returned after Run admission but before any
/// Conversation mutation. AgentCore uses this narrow seam to materialize a
/// typed Skill without duplicating the Session lifecycle state machine.
pub const AdmittedRun = struct {
    session: *AgentSession,
    identity_value: RunIdentity,
    completed: bool = false,

    pub fn identity(self: *const AdmittedRun) RunIdentity {
        std.debug.assert(!self.completed);
        return self.identity_value;
    }

    pub fn abortSignal(self: *const AdmittedRun) *const AbortSignal {
        std.debug.assert(!self.completed);
        return &self.session.abort_signal;
    }

    /// Complete an admitted Run without appending to Conversation or entering
    /// the provider/tool loop. The Run ID remains consumed by admission.
    pub fn finishWithoutConversation(
        self: *AdmittedRun,
    ) LifecycleError!AdmittedCompletion {
        if (self.completed) return error.InvalidSessionState;
        const completion = try self.session.finishAdmittedRun(self.identity_value);
        self.completed = true;
        return completion;
    }

    /// Append the already-prepared root prompt and reuse the ordinary Run
    /// pipeline. Any failure after this call begins has normal admitted-Run
    /// poison semantics.
    pub fn runText(
        self: *AdmittedRun,
        prompt: []const u8,
        max_turns: u32,
    ) anyerror!agent_loop.RunResult {
        return self.runUserMessagesWithPolicy(&.{prompt}, max_turns, null);
    }

    /// Continue an admitted Run with a caller-defined sequence of user
    /// records and an immutable execution upper bound. Appends and provider
    /// execution retain the ordinary poison semantics.
    pub fn runUserMessagesWithPolicy(
        self: *AdmittedRun,
        prompts: []const []const u8,
        max_turns: u32,
        execution_policy: ?ToolExecutionPolicy,
    ) anyerror!agent_loop.RunResult {
        return self.runUserMessagesWithToolSurface(
            prompts,
            max_turns,
            execution_policy,
            null,
        );
    }

    /// Continue an admitted Run with a caller-owned tool overlay. This is the
    /// only shared-core seam needed by AgentCore's bound Skill catalog; it
    /// changes neither provider behavior nor the agent-loop tool protocol.
    pub fn runUserMessagesWithToolSurface(
        self: *AdmittedRun,
        prompts: []const []const u8,
        max_turns: u32,
        execution_policy: ?ToolExecutionPolicy,
        tool_surface: ?RunToolSurface,
    ) anyerror!agent_loop.RunResult {
        if (self.completed) return error.InvalidSessionState;
        if (prompts.len == 0) {
            _ = try self.finishWithoutConversation();
            return error.InvalidSessionState;
        }
        try self.session.claimAdmittedRun(self.identity_value);
        self.completed = true;
        for (prompts) |prompt| {
            self.session.conversation.appendText(.user, prompt) catch |err| {
                _ = self.session.poisonRun();
                return err;
            };
        }
        return self.session.runLoop(
            self.identity_value,
            max_turns,
            execution_policy,
            tool_surface,
        );
    }

    /// Run a synchronous child executor under this already-admitted Run. The
    /// parent Conversation receives the supplied root records and, only after
    /// successful quiescence, the executor's non-empty final assistant text.
    /// Errors poison through the same lifecycle as the ordinary agent loop.
    pub fn runIsolated(
        self: *AdmittedRun,
        root_records: []const []const u8,
        executor: IsolatedRunExecutor,
    ) anyerror!agent_loop.RunResult {
        if (self.completed) return error.InvalidSessionState;
        if (root_records.len == 0) {
            _ = try self.finishWithoutConversation();
            return error.InvalidSessionState;
        }
        try self.session.claimAdmittedRun(self.identity_value);
        self.completed = true;
        for (root_records) |record| {
            self.session.conversation.appendText(.user, record) catch |err| {
                _ = self.session.poisonRun();
                return err;
            };
        }

        var final_text = std.ArrayList(u8).empty;
        defer final_text.deinit(self.session.allocator);
        var backend = ui_backend.UiBackend{
            .ctx = @ptrCast(self.session),
            .emit = AgentSession.backendEmit,
            .poll = AgentSession.backendPoll,
        };
        var native_result = executor.execute(
            self.session.allocator,
            self.identity_value,
            &backend,
            &self.session.abort_signal,
            &final_text,
        ) catch |err| {
            const callback_failed = self.session.poisonRun();
            if (callback_failed) return error.CallbackFailed;
            return err;
        };

        // The executor contract guarantees event-producer quiescence here, so
        // callback_failed cannot change between this observation and terminal.
        if (!self.session.callbackFailed() and final_text.items.len != 0) {
            self.session.conversation.appendText(.assistant, final_text.items) catch |err| {
                if (native_result.suspend_info) |suspend_info| suspend_info.deinit();
                _ = self.session.poisonRun();
                return err;
            };
        }

        const completion = self.session.finishRunLifecycle();
        if (completion.callback_failed) {
            if (native_result.suspend_info) |suspend_info| suspend_info.deinit();
            return error.CallbackFailed;
        }
        if (completion.abort_requested) native_result.stop_reason = .aborted;
        return native_result;
    }
};

pub const AdmittedCompletion = struct {
    aborted: bool,
};

pub const AgentSession = struct {
    allocator: std.mem.Allocator,
    runtime: *AgentRuntime,
    session_id: SessionId,
    api_key: []u8,
    model: []u8,
    base_url: ?[]u8,
    provider: provider_factory.OwnedProvider,
    conversation: Conversation,
    workspace: workspace_mod.WorkspacePolicy,
    tools: tool_catalog.Selection,
    read_state: ReadState,
    jobs: ?JobRegistry,
    session_rules: SessionRules,
    imported_permission_rules: ?permission_settings.MergedSettings,
    permission_ctx: permission.PermissionContext,
    host_ui_requester: ?UiRequester,
    host_run_ui_requester: ?AgentSessionUiRequester,
    /// Host tool 身份锚点(SessionConfig.host_identity_ctx,core 只透传)。
    host_identity_ctx: ?*anyopaque = null,
    abort_signal: AbortSignal,
    compact_abort_signal: AbortSignal,
    active_sink: ?EventSink = null,

    mutex: sync.Mutex = .{},
    callback_mutex: sync.Mutex = .{},
    state: State = .idle,
    active_run_id: u64 = 0,
    /// Shared exactly-once gate for copyable `AdmittedRun` values. False means
    /// no Conversation mutation has begun; the first continuation claims it.
    active_run_started: bool = false,
    /// Highest admitted Run ID. Zero is the no-Run sentinel; admission only
    /// replaces it with a strictly greater value, preventing ABA reuse.
    last_run_id: u64 = 0,
    active_compact_id: u64 = 0,
    active_compact_provider: ?provider_mod.Provider = null,
    /// Number of matching abort calls that borrowed a provider under `mutex`
    /// and have not yet returned from `Provider.cancel`. A terminal Run or
    /// compact may publish `.idle` first; all later activity admission remains
    /// BUSY until these borrows drain, so model replacement/destroy cannot free
    /// a provider still used by a cross-thread abort.
    in_flight_provider_cancels: usize = 0,
    last_admitted_compact_id: u64 = 0,
    last_terminal_compact_id: u64 = 0,
    callback_failed: bool = false,

    fn makeToolProvider(raw: *anyopaque) anyerror!provider_factory.OwnedProvider {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        return provider_factory.makeProvider(
            std.heap.c_allocator,
            self.provider.kind(),
            self.api_key,
            self.model,
            self.base_url,
        );
    }

    fn toolProviderFactory(self: *AgentSession) provider_factory.Factory {
        return .{ .ctx = @ptrCast(self), .makeFn = &makeToolProvider };
    }

    /// Allocate directly at the final address. This avoids the invalid
    /// init-by-value + bind(self) pattern where a later move leaves backend ctx
    /// pointing at stale storage.
    pub fn create(runtime: *AgentRuntime, config: SessionConfig) !*AgentSession {
        return createWithHooks(runtime, config, .{});
    }

    fn createWithHooks(runtime: *AgentRuntime, config: SessionConfig, hooks: SessionCreateHooks) !*AgentSession {
        try runtime.retainSession();
        errdefer runtime.releaseSession();
        const allocator = runtime.allocator;
        const self = try allocator.create(AgentSession);
        errdefer allocator.destroy(self);

        var workspace = try workspace_mod.WorkspacePolicy.init(allocator, config.workspace);
        errdefer workspace.deinit();
        var selected_tools = try tool_catalog.Selection.init(allocator, &runtime.catalog, config.allowed_tools);
        errdefer selected_tools.deinit();
        for (selected_tools.entries) |entry| {
            if (!workspace.allowsTool(entry.definition.name)) return error.ShellToolDisabled;
            // 选了 Host tool 却没有身份锚点 → admission 拒绝,消灭运行期空态。
            if (entry.executor == .host_sync and config.host_identity_ctx == null)
                return error.HostIdentityRequired;
        }
        var jobs: ?JobRegistry = null;
        if (selected_tools.contains("Bash") or selected_tools.contains("BashOutput") or selected_tools.contains("KillShell")) {
            jobs = try JobRegistry.init(allocator);
        }
        errdefer if (jobs) |*registry| registry.deinit();
        var imported_permission_rules: ?permission_settings.MergedSettings =
            if (config.permission_rules) |rules|
                if (rules.isEmpty())
                    null
                else
                    try permission_settings.buildRuleSet(allocator, rules, .{})
            else
                null;
        errdefer if (imported_permission_rules) |*rules| rules.deinit();

        const api_key = try allocator.dupe(u8, config.api_key);
        errdefer secureFree(allocator, api_key);
        const model = try allocator.dupe(u8, config.model);
        errdefer allocator.free(model);
        const base_url = if (config.base_url) |url| try allocator.dupe(u8, url) else null;
        errdefer if (base_url) |url| allocator.free(url);

        const owned_provider = try provider_factory.makeProvider(
            allocator,
            config.provider_kind,
            api_key,
            model,
            base_url,
        );
        errdefer owned_provider.deinit();

        // collision detection:锁下原子注册,冲突则重新生成;重试超限 = 生成器故障,
        // 报不可达级错误而非无限循环。创建失败由 errdefer 回滚注册。
        const session_id = blk: {
            var attempts: usize = 0;
            while (attempts < AgentRuntime.MAX_SESSION_ID_RETRIES) : (attempts += 1) {
                const candidate = hooks.session_id_source.next();
                if (try runtime.registerSessionId(candidate)) break :blk candidate;
            }
            return error.SessionIdGeneratorBroken;
        };
        errdefer runtime.unregisterSessionId(session_id);
        try hooks.afterIdRegistered();
        var permission_ctx = permission.createContext(config.permission_mode, allocator);
        permission_ctx.session = session_id;

        self.* = .{
            .allocator = allocator,
            .runtime = runtime,
            .session_id = session_id,
            .api_key = api_key,
            .model = model,
            .base_url = base_url,
            .provider = owned_provider,
            .conversation = Conversation.init(allocator),
            .workspace = workspace,
            .tools = selected_tools,
            .read_state = ReadState.init(allocator),
            .jobs = jobs,
            .session_rules = .{},
            .imported_permission_rules = imported_permission_rules,
            .permission_ctx = permission_ctx,
            .host_ui_requester = config.ui_requester,
            .host_run_ui_requester = config.run_ui_requester,
            .host_identity_ctx = config.host_identity_ctx,
            .abort_signal = AbortSignal.init(),
            .compact_abort_signal = AbortSignal.init(),
        };
        self.permission_ctx.session_rules = &self.session_rules;
        self.permission_ctx.settings = if (self.imported_permission_rules) |*rules|
            rules
        else
            null;
        self.permission_ctx.ui_requester = if (config.ui_requester != null or config.run_ui_requester != null)
            .{ .ctx = self, .requestFn = requestHostUi }
        else
            null;
        // A UI-neutral library must never fall back to process stdin. Until a
        // Host requester is attached, `.ask` decisions fail closed.
        self.permission_ctx.no_interactive_prompt = true;
        self.permission_ctx.match_ctx = .{
            .cwd = self.workspace.root,
            .project_root = self.workspace.root,
            .home = self.workspace.home,
        };
        self.permission_ctx.sandbox_enabled = self.workspace.shell == .sandboxed;
        self.permission_ctx.auto_allow_bash_if_sandboxed = self.workspace.shell == .sandboxed;
        return self;
    }

    /// Destroy requires unique ownership of `self` and is valid only after the
    /// synchronous activity and every matching abort call have returned. As
    /// with allocator.destroy, using the pointer again after success is invalid.
    pub fn destroy(self: *AgentSession) LifecycleError!void {
        self.mutex.lock();
        if (self.in_flight_provider_cancels != 0) {
            self.mutex.unlock();
            return error.SessionBusy;
        }
        switch (self.state) {
            .idle, .poisoned => self.state = .destroying,
            .running, .abort_requested, .compacting, .compact_finishing, .mutating => {
                self.mutex.unlock();
                return error.SessionBusy;
            },
            .destroying => {
                self.mutex.unlock();
                return error.InvalidSessionState;
            },
        }
        self.mutex.unlock();

        const allocator = self.allocator;
        const runtime = self.runtime;
        const sid = self.session_id;
        self.provider.deinit();
        self.conversation.deinit();
        if (self.jobs) |*registry| registry.deinit();
        if (self.imported_permission_rules) |*rules| rules.deinit();
        self.read_state.deinit();
        self.tools.deinit();
        self.workspace.deinit();
        if (self.base_url) |url| allocator.free(url);
        allocator.free(self.model);
        secureFree(allocator, self.api_key);
        self.* = undefined;
        allocator.destroy(self);
        // destroy 成功必须注销(先于 releaseSession:live==0 时 registry 必须已空)。
        runtime.unregisterSessionId(sid);
        runtime.releaseSession();
    }

    /// Return the core state machine's poison decision. Poisoned is terminal
    /// for a live Session, so callers may safely mirror a true result.
    pub fn isPoisoned(self: *AgentSession) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state == .poisoned;
    }

    /// Atomically replace the Session's effective model/provider pair.
    ///
    /// Provider construction happens after the mutation gate is acquired but
    /// before publication. A construction failure restores `.idle` and leaves
    /// every existing Session-owned object untouched.
    pub fn setModel(self: *AgentSession, requested_model: []const u8) ModelMutationError!void {
        if (requested_model.len == 0 or
            !std.unicode.utf8ValidateSlice(requested_model))
            return error.InvalidModel;

        self.mutex.lock();
        if (self.in_flight_provider_cancels != 0) {
            self.mutex.unlock();
            return error.SessionBusy;
        }
        switch (self.state) {
            .idle => {},
            .running, .abort_requested, .compacting, .compact_finishing, .mutating => {
                self.mutex.unlock();
                return error.SessionBusy;
            },
            .poisoned, .destroying => {
                self.mutex.unlock();
                return error.InvalidSessionState;
            },
        }
        if (std.mem.eql(u8, self.model, requested_model)) {
            self.mutex.unlock();
            return;
        }
        self.state = .mutating;
        const provider_kind = self.provider.kind();
        self.mutex.unlock();

        const replacement_model = self.allocator.dupe(u8, requested_model) catch {
            self.cancelMutation();
            return error.OutOfMemory;
        };
        errdefer self.allocator.free(replacement_model);
        var replacement_provider = provider_factory.makeProvider(
            self.allocator,
            provider_kind,
            self.api_key,
            replacement_model,
            self.base_url,
        ) catch |err| {
            self.cancelMutation();
            return err;
        };
        errdefer replacement_provider.deinit();

        self.mutex.lock();
        std.debug.assert(self.state == .mutating);
        const previous_model = self.model;
        const previous_provider = self.provider;
        self.model = replacement_model;
        self.provider = replacement_provider;
        self.mutex.unlock();

        // Concrete clients borrow their model bytes, so destroy the previous
        // provider before releasing its backing model slice. Keep the mutation
        // gate held until cleanup finishes so a direct Core destroy cannot
        // reclaim `self` while this call still reads its allocator.
        previous_provider.deinit();
        self.allocator.free(previous_model);

        self.mutex.lock();
        std.debug.assert(self.state == .mutating);
        self.state = .idle;
        self.mutex.unlock();
    }

    /// Atomically replace the Host-imported canonical permission rule layer.
    /// Session-local allow/deny memory is a distinct field and is preserved.
    pub fn updatePermissionRules(
        self: *AgentSession,
        input: permission_settings.RuleSetInput,
    ) PermissionRuleMutationError!void {
        self.mutex.lock();
        if (self.in_flight_provider_cancels != 0) {
            self.mutex.unlock();
            return error.SessionBusy;
        }
        switch (self.state) {
            .idle => self.state = .mutating,
            .running, .abort_requested, .compacting, .compact_finishing, .mutating => {
                self.mutex.unlock();
                return error.SessionBusy;
            },
            .poisoned, .destroying => {
                self.mutex.unlock();
                return error.InvalidSessionState;
            },
        }
        self.mutex.unlock();

        const replacement: ?permission_settings.MergedSettings =
            if (input.isEmpty())
                null
            else
                permission_settings.buildRuleSet(
                    self.allocator,
                    input,
                    .{},
                ) catch |err| {
                    self.cancelMutation();
                    return err;
                };

        self.mutex.lock();
        std.debug.assert(self.state == .mutating);
        const previous = self.imported_permission_rules;
        self.imported_permission_rules = replacement;
        self.permission_ctx.settings = if (self.imported_permission_rules) |*rules|
            rules
        else
            null;
        self.mutex.unlock();

        if (previous) |rules_value| {
            var rules = rules_value;
            rules.deinit();
        }

        self.mutex.lock();
        std.debug.assert(self.state == .mutating);
        self.state = .idle;
        self.mutex.unlock();
    }

    pub fn compact(
        self: *AgentSession,
        operation_id: u64,
        options: CompactOptions,
    ) CompactError!compact_kernel.Report {
        // The production provider snapshot is intentionally selected by
        // compactUsingProvider under the same mutex that admits `.compacting`.
        // Tests may pass an explicit provider through that private seam.
        return self.compactUsingProvider(
            operation_id,
            options,
            null,
        );
    }

    fn compactUsingProvider(
        self: *AgentSession,
        operation_id: u64,
        options: CompactOptions,
        provider_override: ?provider_mod.Provider,
    ) CompactError!compact_kernel.Report {
        if (operation_id == 0) return error.InvalidOperationId;
        self.mutex.lock();
        // A provider cancel borrow is a lifetime gate, not another operation-ID
        // state. Do not classify or admit a new compact until that borrow drains;
        // BUSY therefore intentionally takes precedence over stale-ID reporting.
        if (self.in_flight_provider_cancels != 0) {
            self.mutex.unlock();
            return error.SessionBusy;
        }
        if (operation_id <= self.last_admitted_compact_id) {
            self.mutex.unlock();
            return error.StaleCompact;
        }
        switch (self.state) {
            .idle => {},
            .running, .abort_requested, .compacting, .compact_finishing, .mutating => {
                self.mutex.unlock();
                return error.SessionBusy;
            },
            .poisoned, .destroying => {
                self.mutex.unlock();
                return error.InvalidSessionState;
            },
        }
        const provider = provider_override orelse self.provider.provider();
        self.state = .compacting;
        self.active_compact_id = operation_id;
        self.active_compact_provider = provider;
        self.last_admitted_compact_id = operation_id;
        self.compact_abort_signal = AbortSignal.init();
        self.mutex.unlock();
        defer self.finishCompact(operation_id);

        return compact_kernel.run(
            self.allocator,
            &self.conversation,
            provider,
            &self.compact_abort_signal,
            .{
                .keep_recent = options.keep_recent,
                .committer = .{
                    .ctx = self,
                    .commit_fn = commitCompact,
                },
            },
        );
    }

    fn commitCompact(
        raw: *anyopaque,
        live: *Conversation,
        suffix: *const Conversation.SuffixSnapshot,
        replacement: *Conversation,
        signal: *const AbortSignal,
    ) compact_kernel.CommitResult {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.state == .compacting);
        if (signal.isAborted()) return .aborted;
        if (!live.replaceWithOwnedIfSuffixUnchanged(suffix, replacement))
            return .concurrent_mutation;
        self.last_terminal_compact_id = self.active_compact_id;
        self.active_compact_id = 0;
        self.active_compact_provider = null;
        self.state = .compact_finishing;
        return .committed;
    }

    pub fn abortCompact(
        self: *AgentSession,
        operation_id: u64,
    ) AbortCompactError!void {
        if (operation_id == 0) return error.InvalidOperationId;
        self.mutex.lock();
        switch (self.state) {
            .compacting => {
                if (operation_id < self.active_compact_id) {
                    self.mutex.unlock();
                    return error.StaleCompact;
                }
                if (operation_id > self.active_compact_id) {
                    self.mutex.unlock();
                    return error.InvalidOperationId;
                }
                self.compact_abort_signal.abort(.user_interrupt);
                const provider = self.active_compact_provider.?;
                std.debug.assert(self.in_flight_provider_cancels < std.math.maxInt(usize));
                self.in_flight_provider_cancels += 1;
                self.mutex.unlock();
                defer self.finishProviderCancel();
                provider.cancel(&self.compact_abort_signal);
            },
            .compact_finishing => {
                const terminal = self.last_terminal_compact_id;
                self.mutex.unlock();
                if (operation_id == terminal) return error.AbortTooLate;
                if (operation_id < terminal) return error.StaleCompact;
                return error.InvalidOperationId;
            },
            .idle => {
                const terminal = self.last_terminal_compact_id;
                self.mutex.unlock();
                if (terminal != 0 and operation_id == terminal)
                    return error.AbortTooLate;
                if (terminal != 0 and operation_id < terminal)
                    return error.StaleCompact;
                return error.InvalidOperationId;
            },
            .running, .abort_requested, .mutating, .poisoned, .destroying => {
                self.mutex.unlock();
                return error.InvalidSessionState;
            },
        }
    }

    fn finishCompact(self: *AgentSession, operation_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (self.state) {
            .compacting => {
                std.debug.assert(self.active_compact_id == operation_id);
                self.active_compact_id = 0;
                self.active_compact_provider = null;
                self.last_terminal_compact_id = operation_id;
            },
            .compact_finishing => {
                std.debug.assert(self.active_compact_id == 0);
                std.debug.assert(self.last_terminal_compact_id == operation_id);
            },
            else => unreachable,
        }
        self.state = .idle;
    }

    fn finishProviderCancel(self: *AgentSession) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.in_flight_provider_cancels > 0);
        self.in_flight_provider_cancels -= 1;
    }

    fn cancelMutation(self: *AgentSession) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.state == .mutating);
        self.state = .idle;
    }

    fn callbackFailed(self: *AgentSession) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.callback_failed;
    }

    /// Run one text turn while preserving Conversation across successful Runs.
    pub fn runText(self: *AgentSession, run_id: u64, prompt: []const u8, max_turns: u32, sink: EventSink) anyerror!agent_loop.RunResult {
        var admitted = try self.admitRun(run_id, sink);
        return admitted.runText(prompt, max_turns);
    }

    pub fn admitRun(
        self: *AgentSession,
        run_id: u64,
        sink: EventSink,
    ) LifecycleError!AdmittedRun {
        return .{
            .session = self,
            .identity_value = try self.beginRun(run_id, sink),
        };
    }

    fn runLoop(
        self: *AgentSession,
        identity: RunIdentity,
        max_turns: u32,
        execution_policy: ?ToolExecutionPolicy,
        tool_surface: ?RunToolSurface,
    ) anyerror!agent_loop.RunResult {
        var backend = ui_backend.UiBackend{ .ctx = @ptrCast(self), .emit = backendEmit, .poll = backendPoll };
        const tool_definitions = if (tool_surface) |surface|
            surface.definitions
        else
            self.tools.definitions;
        const tool_dispatcher = if (tool_surface) |surface|
            surface.dispatcher
        else
            self.tools.dispatcher();
        var native_result = agent_loop.run(
            &self.conversation,
            self.provider.provider(),
            tool_definitions,
            &self.permission_ctx,
            .{
                .max_turns = max_turns,
                .session = identity.session_id,
                .session_id = identity.session_id.asSlice(),
                .abort = &self.abort_signal,
                .read_state = &self.read_state,
                .jobs = if (self.jobs) |*registry| registry else null,
                .provider_factory = self.toolProviderFactory(),
                .tool_defs = tool_definitions,
                .tool_dispatcher = tool_dispatcher,
                .execution_policy = execution_policy,
                // admission 处固定的 Run 身份,显式传值贯穿至 Host tool 执行点。
                .host_run = if (self.host_identity_ctx) |hctx| .{
                    .identity = identity,
                    .host_session_ctx = hctx,
                } else null,
                .ui_requester = self.permission_ctx.ui_requester,
                .emit_tool_cards = true,
                .project_dir = self.workspace.root,
                .cwd_abs = self.workspace.root,
                .resolve_relative_paths = true,
                .home_dir = self.workspace.home,
                .sandbox = self.workspace.sandbox(),
                .parent_model = self.model,
                .colorize = false,
            },
            &backend,
            self.allocator,
        ) catch |err| {
            if (err == error.HostToolFatal) {
                self.mutex.lock();
                self.callback_failed = true;
                self.mutex.unlock();
            }
            const callback_failed = self.poisonRun();
            if (callback_failed) return error.CallbackFailed;
            return err;
        };

        const completion = self.finishRunLifecycle();
        if (completion.callback_failed) {
            if (native_result.suspend_info) |suspend_info| suspend_info.deinit();
            return error.CallbackFailed;
        }
        if (completion.abort_requested) native_result.stop_reason = .aborted;
        return native_result;
    }

    const RunCompletion = struct {
        abort_requested: bool,
        callback_failed: bool,
    };

    fn finishRunLifecycle(self: *AgentSession) RunCompletion {
        self.callback_mutex.lock();
        self.mutex.lock();
        const completion = RunCompletion{
            .abort_requested = self.state == .abort_requested,
            .callback_failed = self.callback_failed,
        };
        if (completion.callback_failed) {
            self.state = .poisoned;
        } else {
            self.state = .idle;
        }
        self.active_run_id = 0;
        self.active_run_started = false;
        self.active_sink = null;
        self.mutex.unlock();
        self.callback_mutex.unlock();
        return completion;
    }

    pub fn abort(self: *AgentSession, run_id: u64, reason: AbortReason) LifecycleError!void {
        return self.abortUsingProvider(run_id, reason, null);
    }

    fn abortUsingProvider(
        self: *AgentSession,
        run_id: u64,
        reason: AbortReason,
        provider_override: ?provider_mod.Provider,
    ) LifecycleError!void {
        self.mutex.lock();
        if (self.active_run_id != 0 and self.active_run_id != run_id) {
            self.mutex.unlock();
            return error.StaleRun;
        }
        switch (self.state) {
            .running => {
                self.state = .abort_requested;
                // Store the abort flag under the same lock that linearizes the
                // state transition. The signal itself is atomic and nonblocking.
                self.abort_signal.abort(reason.internal());
                const provider = provider_override orelse self.provider.provider();
                std.debug.assert(self.in_flight_provider_cancels < std.math.maxInt(usize));
                self.in_flight_provider_cancels += 1;
                self.mutex.unlock();
                defer self.finishProviderCancel();
                provider.cancel(&self.abort_signal);
            },
            .abort_requested => self.mutex.unlock(),
            .idle => {
                const too_late = run_id != 0 and self.last_run_id == run_id;
                self.mutex.unlock();
                return if (too_late) error.AbortTooLate else error.StaleRun;
            },
            .compacting, .compact_finishing, .mutating, .poisoned, .destroying => {
                self.mutex.unlock();
                return error.InvalidSessionState;
            },
        }
    }

    /// Admission linearization point for the public nonzero, strictly
    /// increasing, Session-scoped Run ID contract.
    fn beginRun(self: *AgentSession, run_id: u64, sink: EventSink) LifecycleError!RunIdentity {
        self.mutex.lock();
        if (self.in_flight_provider_cancels != 0) {
            self.mutex.unlock();
            return error.SessionBusy;
        }
        switch (self.state) {
            .idle => {},
            .running, .abort_requested, .compacting, .compact_finishing, .mutating => {
                self.mutex.unlock();
                return error.SessionBusy;
            },
            .poisoned, .destroying => {
                self.mutex.unlock();
                return error.InvalidSessionState;
            },
        }
        if (run_id == 0 or run_id <= self.last_run_id) {
            self.mutex.unlock();
            return error.StaleRun;
        }
        self.abort_signal = AbortSignal.init();
        self.state = .running;
        self.active_run_id = run_id;
        self.active_run_started = false;
        self.last_run_id = run_id;
        self.callback_failed = false;
        self.active_sink = sink;
        const identity = RunIdentity{ .session_id = self.session_id, .run_id = run_id };
        self.mutex.unlock();
        return identity;
    }

    fn claimAdmittedRun(
        self: *AgentSession,
        identity: RunIdentity,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!std.mem.eql(u8, identity.session_id.asSlice(), self.session_id.asSlice()) or
            identity.run_id == 0 or
            identity.run_id != self.active_run_id or
            self.active_run_started)
            return error.InvalidSessionState;
        switch (self.state) {
            .running, .abort_requested => {},
            .idle, .compacting, .compact_finishing, .mutating, .poisoned, .destroying => return error.InvalidSessionState,
        }
        self.active_run_started = true;
    }

    fn finishAdmittedRun(
        self: *AgentSession,
        identity: RunIdentity,
    ) LifecycleError!AdmittedCompletion {
        self.callback_mutex.lock();
        defer self.callback_mutex.unlock();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!std.mem.eql(u8, identity.session_id.asSlice(), self.session_id.asSlice()) or
            identity.run_id == 0 or
            identity.run_id != self.active_run_id or
            self.active_run_started)
            return error.InvalidSessionState;
        switch (self.state) {
            .running, .abort_requested => {},
            .idle, .compacting, .compact_finishing, .mutating, .poisoned, .destroying => return error.InvalidSessionState,
        }
        const aborted = self.state == .abort_requested;
        if (self.callback_failed) {
            self.state = .poisoned;
        } else {
            self.state = .idle;
        }
        self.active_run_id = 0;
        self.active_run_started = false;
        self.active_sink = null;
        if (self.callback_failed) return error.CallbackFailed;
        return .{ .aborted = aborted };
    }

    /// Poison a failed Run and return whether delivery failure was the cause.
    fn poisonRun(self: *AgentSession) bool {
        // Quiesce event delivery before clearing active_sink. The lock order is
        // always callback_mutex -> mutex, matching backendEmit/runLoop.
        self.callback_mutex.lock();
        defer self.callback_mutex.unlock();
        self.mutex.lock();
        const failed = self.callback_failed;
        self.state = .poisoned;
        self.active_run_id = 0;
        self.active_run_started = false;
        self.active_sink = null;
        self.mutex.unlock();
        return failed;
    }

    fn backendEmit(ctx: *anyopaque, _: SessionId, event: CoreEvent) void {
        const self: *AgentSession = @ptrCast(@alignCast(ctx));

        // Serialize admission and delivery. This makes "first callback failure"
        // exact even when future tool threads emit concurrently, without holding
        // the lifecycle mutex across consumer code (abort reentrancy stays safe).
        self.callback_mutex.lock();
        defer self.callback_mutex.unlock();

        self.mutex.lock();
        const already_failed = self.callback_failed;
        const run_id = self.active_run_id;
        const sink = self.active_sink;
        self.mutex.unlock();
        if (already_failed or run_id == 0 or sink == null) return;

        if (!sink.?.emit(sink.?.ctx, self.session_id, run_id, event)) {
            self.mutex.lock();
            if (!self.callback_failed) {
                self.callback_failed = true;
                self.abort_signal.abort(.host_failure);
            }
            self.mutex.unlock();
        }
    }

    fn requestHostUi(
        raw: *anyopaque,
        session_id: SessionId,
        response_allocator: std.mem.Allocator,
        req: *const ui_request.UiRequest,
        out: *ui_request.UiResponse,
    ) anyerror!ui_request.RequestOutcome {
        const self: *AgentSession = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        const identity = switch (self.state) {
            .running, .abort_requested => if (std.mem.eql(u8, session_id.asSlice(), self.session_id.asSlice()) and self.active_run_id != 0)
                RunIdentity{ .session_id = self.session_id, .run_id = self.active_run_id }
            else
                null,
            .idle, .compacting, .compact_finishing, .mutating, .poisoned, .destroying => null,
        };
        if (identity == null and (self.state == .running or self.state == .abort_requested)) {
            if (!self.callback_failed) {
                self.callback_failed = true;
                self.abort_signal.abort(.host_failure);
            }
        }
        self.mutex.unlock();
        const admitted = identity orelse return error.HostUiFailed;

        const result = if (self.host_run_ui_requester) |requester|
            requester.request(admitted, response_allocator, req, out)
        else if (self.host_ui_requester) |requester|
            requester.request(session_id, response_allocator, req, out)
        else
            return .unavailable;
        return result catch |err| {
            // A user cancelling AskQuestion is a model-visible tool outcome,
            // not a broken Host transport. AgentCore is the only current
            // producer; every other callback error retains poison semantics.
            if (err == error.UiCancelled and req.* == .ask_question) return err;
            // A Host UI transport/decoding error is infrastructure failure,
            // not a model-visible tool error. Abort the current Run and let
            // finishRunLifecycle poison the Session consistently with event
            // callback failure.
            self.mutex.lock();
            if (!self.callback_failed) {
                self.callback_failed = true;
                self.abort_signal.abort(.host_failure);
            }
            self.mutex.unlock();
            return err;
        };
    }

    fn backendPoll(_: *anyopaque, _: SessionId) ?UiEvent {
        return null;
    }
};

pub fn secureClear(bytes: []u8) void {
    secure.zero(bytes);
}

fn secureFree(allocator: std.mem.Allocator, bytes: []u8) void {
    secure.free(allocator, bytes);
}

const EraseObservingAllocator = struct {
    backing: std.mem.Allocator,
    target_len: usize,
    fail_index: ?usize = null,
    fail_after_target: bool = false,
    failed_after_target: bool = false,
    allocations: usize = 0,
    target_ptr: ?[*]u8 = null,
    target_freed: bool = false,
    target_was_zero: bool = false,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.fail_after_target and self.target_ptr != null and !self.failed_after_target) {
            self.failed_after_target = true;
            self.allocations += 1;
            return null;
        }
        if (self.fail_index == self.allocations) {
            self.allocations += 1;
            return null;
        }
        self.allocations += 1;
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        if (len == self.target_len and self.target_ptr == null) self.target_ptr = ptr;
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.target_ptr) |target| {
            if (memory.ptr == target) {
                self.target_freed = true;
                self.target_was_zero = std.mem.allEqual(u8, memory, 0);
            }
        }
        self.backing.rawFree(memory, alignment, ret_addr);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

const SinkProbe = struct {
    accept: bool = true,
    calls: usize = 0,
    session_id: ?SessionId = null,
    run_id: u64 = 0,

    fn emit(ctx: *anyopaque, session_id: SessionId, run_id: u64, _: CoreEvent) bool {
        const self: *SinkProbe = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.session_id = session_id;
        self.run_id = run_id;
        return self.accept;
    }

    fn sink(self: *SinkProbe) EventSink {
        return .{ .ctx = self, .emit = emit };
    }
};

fn createTestRuntime(allocator: std.mem.Allocator) !*AgentRuntime {
    return AgentRuntime.create(allocator, .{ .builtin_tools = &.{"Read"} });
}

fn testCwd() ![]u8 {
    return @import("../util/fs.zig").getCwd(std.testing.allocator);
}

fn createTestSession(runtime: *AgentRuntime, mode: types.PermissionMode, root: []const u8) !*AgentSession {
    return runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .permission_mode = mode,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"Read"},
    });
}

test "secureClear uses optimizer-resistant zeroing" {
    var key = [_]u8{ 1, 2, 3, 4 };
    secureClear(&key);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &key);
}

test "AgentSession zeroes the copied API key before normal free" {
    const key = "normal-destroy-key-with-unique-length-37";
    var observer = EraseObservingAllocator{ .backing = std.testing.allocator, .target_len = key.len };
    const runtime = try AgentRuntime.create(observer.allocator(), .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = key,
        .model = "m",
        .base_url = null,
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{},
    });
    try self.destroy();
    try std.testing.expect(observer.target_freed);
    try std.testing.expect(observer.target_was_zero);
}

test "AgentSession zeroes the copied API key when later construction fails" {
    const key = "failed-create-key-with-unique-length-41---";
    // Fail the first allocation after the sensitive copy, independent of how
    // many Workspace/catalog allocations Session construction adds before it.
    var observer = EraseObservingAllocator{
        .backing = std.testing.allocator,
        .target_len = key.len,
        .fail_after_target = true,
    };
    const runtime = try AgentRuntime.create(observer.allocator(), .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    try std.testing.expectError(error.OutOfMemory, runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = key,
        .model = "m",
        .base_url = null,
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{},
    }));
    try std.testing.expect(observer.target_freed);
    try std.testing.expect(observer.target_was_zero);
}

test "AgentSession initializes per-session permission state" {
    const runtime = try createTestRuntime(std.testing.allocator);
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try createTestSession(runtime, .plan, cwd);
    defer self.destroy() catch unreachable;
    try std.testing.expectEqual(types.PermissionMode.plan, self.permission_ctx.modeValue());
    try std.testing.expectEqualSlices(u8, self.session_id.asSlice(), self.permission_ctx.session.asSlice());
}

test "AgentSession model mutation is idle-only and preserves Session state" {
    const ApiErrorExecutor = struct {
        fn run(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: RunIdentity,
            _: *const ui_backend.UiBackend,
            _: *const AbortSignal,
            _: *std.ArrayList(u8),
        ) anyerror!agent_loop.RunResult {
            return .{ .stop_reason = .api_error, .turns = 1, .tool_calls = 0 };
        }
    };

    const runtime = try createTestRuntime(std.testing.allocator);
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try createTestSession(runtime, .default, cwd);
    defer self.destroy() catch unreachable;
    try self.conversation.appendText(.user, "preserve me");
    self.session_rules.rememberAllow("Read");
    self.session_rules.rememberDeny("Bash");

    var probe = SinkProbe{};
    _ = try self.beginRun(17, probe.sink());
    _ = self.finishRunLifecycle();

    const session_id = self.session_id;
    const messages_ptr = self.conversation.messages.items.ptr;
    const tools_ptr = self.tools.entries.ptr;
    const workspace_root_ptr = self.workspace.root.ptr;
    const previous_provider_ctx = self.provider.provider().ctx;
    try self.setModel("replacement-model");

    try std.testing.expectEqualStrings("replacement-model", self.model);
    try std.testing.expectEqualStrings("replacement-model", self.provider.provider().model());
    try std.testing.expect(self.provider.provider().ctx != previous_provider_ctx);
    try std.testing.expectEqual(State.idle, self.state);
    try std.testing.expectEqualSlices(u8, session_id.asSlice(), self.session_id.asSlice());
    try std.testing.expectEqual(@as(u64, 17), self.last_run_id);
    try std.testing.expectEqual(@as(usize, 1), self.conversation.messages.items.len);
    try std.testing.expect(self.conversation.messages.items.ptr == messages_ptr);
    try std.testing.expect(self.tools.entries.ptr == tools_ptr);
    try std.testing.expect(self.workspace.root.ptr == workspace_root_ptr);
    try std.testing.expect(self.session_rules.isAllowed("Read"));
    try std.testing.expect(self.session_rules.isDenied("Bash"));
    try std.testing.expect(!self.isPoisoned());

    const model_ptr = self.model.ptr;
    const provider_ctx = self.provider.provider().ctx;
    try self.setModel("replacement-model");
    try std.testing.expect(self.model.ptr == model_ptr);
    try std.testing.expect(self.provider.provider().ctx == provider_ctx);

    _ = try self.beginRun(18, probe.sink());
    try std.testing.expectError(error.SessionBusy, self.setModel("busy-model"));
    try std.testing.expectEqualStrings("replacement-model", self.model);
    _ = self.finishRunLifecycle();

    // Model existence is intentionally provider-validated by the next Run.
    // Its ordinary API-error outcome remains non-poisoning and the Host can
    // switch the same Session back to another model.
    try self.setModel("missing-model-is-locally-valid");
    var executor: u8 = 0;
    var admitted = try self.admitRun(19, probe.sink());
    const result = try admitted.runIsolated(
        &.{"provider validates the model"},
        .{ .ctx = &executor, .executeFn = ApiErrorExecutor.run },
    );
    try std.testing.expectEqual(agent_loop.StopReason.api_error, result.stop_reason);
    try std.testing.expect(!self.isPoisoned());
    try self.setModel("recovered-model");
    try std.testing.expectEqualStrings("recovered-model", self.model);
}

test "AgentSession model mutation rejects invalid input and poisoned state" {
    const runtime = try createTestRuntime(std.testing.allocator);
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try createTestSession(runtime, .default, cwd);
    defer {
        self.state = .idle;
        self.destroy() catch unreachable;
    }

    try std.testing.expectError(error.InvalidModel, self.setModel(""));
    try std.testing.expectError(error.InvalidModel, self.setModel(&.{0xff}));
    try std.testing.expectEqualStrings("test-model", self.model);

    self.state = .poisoned;
    try std.testing.expectError(error.InvalidSessionState, self.setModel("other-model"));
    try std.testing.expectEqualStrings("test-model", self.model);
}

test "AgentSession model mutation rolls back allocation failures" {
    var observer = EraseObservingAllocator{
        .backing = std.testing.allocator,
        .target_len = std.math.maxInt(usize),
    };
    const runtime = try createTestRuntime(observer.allocator());
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try createTestSession(runtime, .default, cwd);
    defer self.destroy() catch unreachable;
    try self.conversation.appendText(.user, "stable");

    const original_model_ptr = self.model.ptr;
    const original_provider_ctx = self.provider.provider().ctx;
    const original_message_ptr = self.conversation.messages.items.ptr;

    // The copied model is the first allocation after admission.
    observer.fail_index = observer.allocations;
    try std.testing.expectError(error.OutOfMemory, self.setModel("copy-fails"));
    observer.fail_index = null;
    try std.testing.expectEqual(State.idle, self.state);
    try std.testing.expect(self.model.ptr == original_model_ptr);
    try std.testing.expect(self.provider.provider().ctx == original_provider_ctx);
    try std.testing.expect(self.conversation.messages.items.ptr == original_message_ptr);
    try std.testing.expectEqualStrings("test-model", self.model);

    // The next allocation constructs the replacement provider after the model
    // copy, proving that partial replacement state is also discarded.
    observer.fail_index = observer.allocations + 1;
    try std.testing.expectError(error.OutOfMemory, self.setModel("provider-fails"));
    observer.fail_index = null;
    try std.testing.expectEqual(State.idle, self.state);
    try std.testing.expect(self.model.ptr == original_model_ptr);
    try std.testing.expect(self.provider.provider().ctx == original_provider_ctx);
    try std.testing.expect(self.conversation.messages.items.ptr == original_message_ptr);
    try std.testing.expectEqualStrings("test-model", self.model);
    try std.testing.expect(!self.isPoisoned());
}

test "AgentSession owns initial imported permission rules" {
    const runtime = try createTestRuntime(std.testing.allocator);
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    var borrowed_rule = [_]u8{ 'W', 'r', 'i', 't', 'e' };
    const self = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{"Read"},
        .permission_rules = .{ .allow = &.{&borrowed_rule} },
    });
    defer self.destroy() catch unreachable;
    borrowed_rule[0] = 'X';

    try std.testing.expectEqual(
        permission.PermissionResult.allow,
        permission.checkPermission(
            &self.permission_ctx,
            "Write",
            "{\"file_path\":\"ordinary.txt\"}",
        ),
    );
}

test "AgentSession permission rule update is idle-only atomic and preserves memory" {
    const runtime = try createTestRuntime(std.testing.allocator);
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try createTestSession(runtime, .default, cwd);
    defer self.destroy() catch unreachable;
    self.session_rules.rememberAllow("Bash");
    self.session_rules.rememberDeny("Write");

    try self.updatePermissionRules(.{
        .allow = &.{"Write"},
        .ask = &.{"Edit"},
        .deny = &.{"Bash"},
    });
    try std.testing.expectEqual(
        permission.PermissionResult.deny,
        permission.checkPermission(
            &self.permission_ctx,
            "Bash",
            "{\"command\":\"echo ok\"}",
        ),
    );
    try std.testing.expectEqual(
        permission.PermissionResult.deny,
        permission.checkPermission(
            &self.permission_ctx,
            "Write",
            "{\"file_path\":\"ordinary.txt\"}",
        ),
    );
    try std.testing.expectEqual(
        permission.PermissionResult.ask,
        permission.checkPermission(
            &self.permission_ctx,
            "Edit",
            "{\"file_path\":\"ordinary.txt\"}",
        ),
    );
    const previous_settings = self.permission_ctx.settings;
    try std.testing.expectError(
        error.InvalidRule,
        self.updatePermissionRules(.{ .allow = &.{"Bash("} }),
    );
    try std.testing.expect(self.permission_ctx.settings == previous_settings);
    try std.testing.expectEqual(State.idle, self.state);
    try std.testing.expect(!self.isPoisoned());

    var probe = SinkProbe{};
    _ = try self.beginRun(31, probe.sink());
    try std.testing.expectError(
        error.SessionBusy,
        self.updatePermissionRules(.{}),
    );
    try std.testing.expect(self.permission_ctx.settings == previous_settings);
    _ = self.finishRunLifecycle();

    try self.updatePermissionRules(.{ .ask = &.{"Bash"} });
    try std.testing.expectEqual(
        permission.PermissionResult.allow,
        permission.checkPermission(
            &self.permission_ctx,
            "Bash",
            "{\"command\":\"echo ok\"}",
        ),
    );
    try self.updatePermissionRules(.{});
    try std.testing.expect(self.permission_ctx.settings == null);
    try std.testing.expect(self.session_rules.isAllowed("Bash"));
    try std.testing.expect(self.session_rules.isDenied("Write"));
}

const CompactTestProvider = struct {
    block: bool = false,
    block_cancel: bool = false,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release_cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stream_stage: u8 = 0,

    fn provider(self: *@This()) provider_mod.Provider {
        return .{
            .ctx = self,
            .modelFn = model,
            .sendStreamFn = sendStream,
            .sendStreamRetryFn = sendStreamRetry,
            .sendFn = send,
            .cancelFn = cancel,
            .maxTokensFn = maxTokens,
            .maxInputTokensFn = maxInputTokens,
            .reasoningEffortFn = reasoningEffort,
            .supportsFn = supports,
        };
    }

    fn cast(raw: *anyopaque) *@This() {
        return @ptrCast(@alignCast(raw));
    }
    fn model(_: *anyopaque) []const u8 {
        return "compact-test";
    }
    fn sendStream(
        raw: *anyopaque,
        _: []const types.ApiMessage,
        _: ?[]const u8,
        _: ?[]const @import("../json.zig").ToolDefinition,
        _: ?*const AbortSignal,
        _: ?[]const u8,
        _: ?@import("../json.zig").ToolChoice,
        _: []const u8,
    ) anyerror!provider_mod.StreamHandle {
        const self = cast(raw);
        if (!self.block) return error.ProviderFailed;
        self.stream_stage = 0;
        return .{
            .ctx = raw,
            .nextFn = next,
            .deinitFn = deinitStream,
            .stopReasonFn = stopReason,
            .requestIdFn = requestId,
        };
    }
    fn sendStreamRetry(
        raw: *anyopaque,
        messages: []const types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const @import("../json.zig").ToolDefinition,
        abort: ?*const AbortSignal,
        model_override: ?[]const u8,
        tool_choice: ?@import("../json.zig").ToolChoice,
        _: u32,
        _: u64,
        _: ?provider_mod.RetryReporter,
        user_query: []const u8,
    ) anyerror!provider_mod.StreamHandle {
        return sendStream(raw, messages, system, tools, abort, model_override, tool_choice, user_query);
    }
    fn next(raw: *anyopaque) anyerror!?@import("../api/stream.zig").StreamEvent {
        const self = cast(raw);
        if (self.stream_stage == 0) {
            self.stream_stage = 1;
            return .{ .usage = .{ .input_tokens = 5, .output_tokens = 2 } };
        }
        self.started.store(true, .release);
        while (!self.cancelled.load(.acquire)) std.Thread.yield() catch {};
        return error.Aborted;
    }
    fn deinitStream(_: *anyopaque) void {}
    fn stopReason(_: *anyopaque) @import("../api/stream.zig").StopReason {
        return .unknown;
    }
    fn requestId(_: *anyopaque) @import("../util/log.zig").RequestId {
        return .{ .bytes = [_]u8{'c'} ** 12 };
    }
    fn send(
        _: *anyopaque,
        _: []const types.ApiMessage,
        _: ?[]const u8,
        _: ?[]const @import("../json.zig").ToolDefinition,
        _: ?[]const u8,
    ) anyerror!provider_mod.ApiResponse {
        return error.Unused;
    }
    fn cancel(raw: *anyopaque, _: *const AbortSignal) void {
        const self = cast(raw);
        self.cancelled.store(true, .release);
        self.cancel_started.store(true, .release);
        while (self.block_cancel and !self.release_cancel.load(.acquire))
            std.Thread.yield() catch {};
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
};

test "AgentSession compact admission consumes only admitted operation ids" {
    const runtime = try createTestRuntime(std.testing.allocator);
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try createTestSession(runtime, .default, cwd);
    defer self.destroy() catch unreachable;
    try self.conversation.appendText(.user, "old user context");
    try self.conversation.appendText(.assistant, "old assistant context");
    try self.conversation.appendText(.user, "recent user context");

    var fake = CompactTestProvider{};
    try std.testing.expectError(
        error.InvalidOperationId,
        self.compactUsingProvider(0, .{ .keep_recent = 1 }, fake.provider()),
    );
    const first = try self.compactUsingProvider(
        1,
        .{ .keep_recent = 1 },
        fake.provider(),
    );
    try std.testing.expectEqual(compact_kernel.Outcome.degraded, first.outcome);
    try std.testing.expect(first.dropped > 0);
    try std.testing.expectEqual(@as(u64, 1), self.last_admitted_compact_id);
    try std.testing.expectEqual(@as(u64, 1), self.last_terminal_compact_id);
    try std.testing.expectEqual(@as(u64, 0), self.last_run_id);
    try std.testing.expectError(
        error.StaleCompact,
        self.compactUsingProvider(1, .{}, fake.provider()),
    );
    try std.testing.expectError(error.AbortTooLate, self.abortCompact(1));
    try std.testing.expectError(error.InvalidOperationId, self.abortCompact(2));

    var sink_probe = SinkProbe{};
    _ = try self.beginRun(7, sink_probe.sink());
    try std.testing.expectError(
        error.SessionBusy,
        self.compactUsingProvider(2, .{}, fake.provider()),
    );
    _ = self.finishRunLifecycle();
    const second = try self.compactUsingProvider(2, .{}, fake.provider());
    try std.testing.expectEqual(compact_kernel.Outcome.no_change, second.outcome);
    try std.testing.expectError(error.StaleCompact, self.abortCompact(1));
    try std.testing.expectError(error.AbortTooLate, self.abortCompact(2));
}

test "AgentSession compact abort is bounded terminal and leaves Conversation unchanged" {
    const runtime = try createTestRuntime(std.testing.allocator);
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try createTestSession(runtime, .default, cwd);
    defer self.destroy() catch unreachable;
    try self.conversation.appendText(.user, "old user context");
    try self.conversation.appendText(.assistant, "old assistant context");
    try self.conversation.appendText(.user, "recent user context");
    const boundary_before = self.conversation.compact_boundary;
    var fake = CompactTestProvider{ .block = true };
    const Worker = struct {
        session: *AgentSession,
        provider: provider_mod.Provider,
        report: ?compact_kernel.Report = null,
        failure: ?anyerror = null,

        fn run(ctx: *@This()) void {
            ctx.report = ctx.session.compactUsingProvider(
                3,
                .{ .keep_recent = 1 },
                ctx.provider,
            ) catch |err| {
                ctx.failure = err;
                return;
            };
        }
    };
    var worker = Worker{ .session = self, .provider = fake.provider() };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    while (!fake.started.load(.acquire)) std.Thread.yield() catch {};

    try std.testing.expectError(error.InvalidOperationId, self.abortCompact(0));
    try std.testing.expectError(error.StaleCompact, self.abortCompact(2));
    try std.testing.expectError(error.InvalidOperationId, self.abortCompact(4));
    try std.testing.expectError(
        error.SessionBusy,
        self.compactUsingProvider(4, .{}, fake.provider()),
    );
    try std.testing.expectError(error.SessionBusy, self.destroy());
    try self.abortCompact(3);
    thread.join();

    try std.testing.expect(worker.failure == null);
    try std.testing.expectEqual(compact_kernel.Outcome.aborted, worker.report.?.outcome);
    try std.testing.expectEqual(@as(u64, 5), worker.report.?.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 2), worker.report.?.usage.output_tokens);
    try std.testing.expectEqual(boundary_before, self.conversation.compact_boundary);
    try std.testing.expectEqual(State.idle, self.state);
    try std.testing.expectEqual(@as(u64, 3), self.last_terminal_compact_id);
    try std.testing.expectError(error.AbortTooLate, self.abortCompact(3));
}

test "AgentSession keeps every activity busy until compact provider cancel returns" {
    const runtime = try createTestRuntime(std.testing.allocator);
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try createTestSession(runtime, .default, cwd);
    defer self.destroy() catch unreachable;
    try self.conversation.appendText(.user, "old user context");
    try self.conversation.appendText(.assistant, "old assistant context");
    try self.conversation.appendText(.user, "recent user context");

    var fake = CompactTestProvider{ .block = true, .block_cancel = true };
    const CompactWorker = struct {
        session: *AgentSession,
        provider: provider_mod.Provider,
        report: ?compact_kernel.Report = null,
        failure: ?anyerror = null,

        fn run(ctx: *@This()) void {
            ctx.report = ctx.session.compactUsingProvider(
                3,
                .{ .keep_recent = 1 },
                ctx.provider,
            ) catch |err| {
                ctx.failure = err;
                return;
            };
        }
    };
    const AbortWorker = struct {
        session: *AgentSession,
        failure: ?anyerror = null,

        fn run(ctx: *@This()) void {
            ctx.session.abortCompact(3) catch |err| {
                ctx.failure = err;
            };
        }
    };
    var compact_worker = CompactWorker{ .session = self, .provider = fake.provider() };
    var abort_worker = AbortWorker{ .session = self };
    const compact_thread = try std.Thread.spawn(.{}, CompactWorker.run, .{&compact_worker});
    while (!fake.started.load(.acquire)) std.Thread.yield() catch {};
    const abort_thread = try std.Thread.spawn(.{}, AbortWorker.run, .{&abort_worker});
    while (!fake.cancel_started.load(.acquire)) std.Thread.yield() catch {};
    compact_thread.join();

    try std.testing.expect(compact_worker.failure == null);
    try std.testing.expectEqual(compact_kernel.Outcome.aborted, compact_worker.report.?.outcome);
    try std.testing.expectError(error.SessionBusy, self.setModel("model-while-cancel-borrowed"));
    try std.testing.expectError(error.SessionBusy, self.updatePermissionRules(.{}));
    var sink_probe = SinkProbe{};
    try std.testing.expectError(error.SessionBusy, self.beginRun(1, sink_probe.sink()));
    try std.testing.expectError(
        error.SessionBusy,
        self.compactUsingProvider(4, .{}, fake.provider()),
    );
    try std.testing.expectEqual(@as(u64, 3), self.last_admitted_compact_id);
    try std.testing.expectError(error.SessionBusy, self.destroy());

    fake.release_cancel.store(true, .release);
    abort_thread.join();
    try std.testing.expect(abort_worker.failure == null);
    try std.testing.expectEqual(@as(usize, 0), self.in_flight_provider_cancels);
    try self.setModel("model-after-cancel-returned");
}

test "AgentSession keeps every activity busy until Run provider cancel returns" {
    const runtime = try createTestRuntime(std.testing.allocator);
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try createTestSession(runtime, .default, cwd);
    defer self.destroy() catch unreachable;
    var sink_probe = SinkProbe{};
    _ = try self.beginRun(1, sink_probe.sink());

    var fake = CompactTestProvider{ .block_cancel = true };
    const AbortWorker = struct {
        session: *AgentSession,
        provider: provider_mod.Provider,
        failure: ?anyerror = null,

        fn run(ctx: *@This()) void {
            ctx.session.abortUsingProvider(
                1,
                .user_interrupt,
                ctx.provider,
            ) catch |err| {
                ctx.failure = err;
            };
        }
    };
    var abort_worker = AbortWorker{ .session = self, .provider = fake.provider() };
    const abort_thread = try std.Thread.spawn(.{}, AbortWorker.run, .{&abort_worker});
    while (!fake.cancel_started.load(.acquire)) std.Thread.yield() catch {};
    const completion = self.finishRunLifecycle();
    try std.testing.expect(completion.abort_requested);

    try std.testing.expectError(error.SessionBusy, self.setModel("model-while-cancel-borrowed"));
    try std.testing.expectError(error.SessionBusy, self.updatePermissionRules(.{}));
    try std.testing.expectError(error.SessionBusy, self.beginRun(2, sink_probe.sink()));
    try std.testing.expectError(
        error.SessionBusy,
        self.compactUsingProvider(1, .{}, fake.provider()),
    );
    try std.testing.expectError(error.SessionBusy, self.destroy());

    fake.release_cancel.store(true, .release);
    abort_thread.join();
    try std.testing.expect(abort_worker.failure == null);
    try std.testing.expectEqual(@as(usize, 0), self.in_flight_provider_cancels);
    _ = try self.beginRun(2, sink_probe.sink());
    _ = self.finishRunLifecycle();
}

test "AgentSession enforces one active Run and monotonic nonzero run ids" {
    const runtime = try createTestRuntime(std.testing.allocator);
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try createTestSession(runtime, .default, cwd);
    var probe = SinkProbe{};
    try std.testing.expect(!self.isPoisoned());

    try std.testing.expectError(error.StaleRun, self.beginRun(0, probe.sink()));
    const first_identity = try self.beginRun(1, probe.sink());
    try std.testing.expectEqual(@as(u64, 1), first_identity.run_id);
    try std.testing.expectEqualSlices(u8, self.session_id.asSlice(), first_identity.session_id.asSlice());
    try std.testing.expectEqual(State.running, self.state);
    try std.testing.expectError(error.SessionBusy, self.beginRun(2, probe.sink()));
    try std.testing.expectError(error.SessionBusy, self.destroy());

    const first = self.finishRunLifecycle();
    try std.testing.expect(!first.abort_requested);
    try std.testing.expect(!first.callback_failed);
    try std.testing.expectEqual(State.idle, self.state);
    try std.testing.expectError(error.StaleRun, self.beginRun(1, probe.sink()));

    _ = try self.beginRun(2, probe.sink());
    _ = self.finishRunLifecycle();
    _ = try self.beginRun(20, probe.sink());
    _ = self.finishRunLifecycle();
    const max_run_id = std.math.maxInt(u64);
    _ = try self.beginRun(max_run_id, probe.sink());
    _ = self.finishRunLifecycle();
    try std.testing.expectError(error.StaleRun, self.beginRun(1, probe.sink()));
    try std.testing.expectError(error.StaleRun, self.beginRun(max_run_id, probe.sink()));
    try std.testing.expect(!self.isPoisoned());
    try self.destroy();
}

test "AdmittedRun consumes run id without mutating Conversation" {
    const runtime = try createTestRuntime(std.testing.allocator);
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try createTestSession(runtime, .default, cwd);
    defer self.destroy() catch unreachable;
    var probe = SinkProbe{};
    const initial_messages = self.conversation.messages.items.len;

    var first = try self.admitRun(1, probe.sink());
    var copied = first;
    try std.testing.expectEqual(@as(u64, 1), first.identity().run_id);
    try std.testing.expect(!first.abortSignal().isAborted());
    const first_completion = try first.finishWithoutConversation();
    try std.testing.expect(!first_completion.aborted);
    try std.testing.expectEqual(initial_messages, self.conversation.messages.items.len);
    try std.testing.expectError(error.InvalidSessionState, first.finishWithoutConversation());
    try std.testing.expectError(error.InvalidSessionState, copied.finishWithoutConversation());
    try std.testing.expectError(error.StaleRun, self.admitRun(1, probe.sink()));

    var second = try self.admitRun(2, probe.sink());
    try self.abort(2, .timeout);
    const second_completion = try second.finishWithoutConversation();
    try std.testing.expect(second_completion.aborted);
    try std.testing.expectEqual(initial_messages, self.conversation.messages.items.len);

    var third = try self.admitRun(3, probe.sink());
    _ = try third.finishWithoutConversation();

    var fourth = try self.admitRun(4, probe.sink());
    try std.testing.expectError(
        error.InvalidSessionState,
        fourth.runUserMessagesWithPolicy(&.{}, 1, null),
    );
    try std.testing.expectEqual(initial_messages, self.conversation.messages.items.len);
    try std.testing.expectError(error.StaleRun, self.admitRun(4, probe.sink()));
}

test "AdmittedRun isolated executor shares identity and commits only final assistant text" {
    const Executor = struct {
        seen_run_id: u64 = 0,
        seen_session: ?SessionId = null,

        fn run(
            raw: *anyopaque,
            allocator: std.mem.Allocator,
            identity: RunIdentity,
            backend: *const ui_backend.UiBackend,
            _: *const AbortSignal,
            out_final_text: *std.ArrayList(u8),
        ) anyerror!agent_loop.RunResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.seen_run_id = identity.run_id;
            self.seen_session = identity.session_id;
            backend.emitEvent(identity.session_id, .{ .text_chunk = "provisional" });
            backend.emitEvent(identity.session_id, .stream_done);
            try out_final_text.appendSlice(allocator, "final");
            return .{ .stop_reason = .end_turn, .turns = 2, .tool_calls = 1 };
        }
    };

    const runtime = try createTestRuntime(std.testing.allocator);
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try createTestSession(runtime, .default, cwd);
    defer self.destroy() catch unreachable;
    var probe = SinkProbe{};
    var executor = Executor{};
    var admitted = try self.admitRun(7, probe.sink());
    const result = try admitted.runIsolated(
        &.{"invocation"},
        .{ .ctx = &executor, .executeFn = Executor.run },
    );

    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 2), result.turns);
    try std.testing.expectEqual(@as(u64, 7), executor.seen_run_id);
    try std.testing.expectEqualSlices(
        u8,
        self.session_id.asSlice(),
        executor.seen_session.?.asSlice(),
    );
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectEqual(@as(u64, 7), probe.run_id);
    try std.testing.expectEqual(@as(usize, 2), self.conversation.messages.items.len);
    try std.testing.expectEqualStrings(
        "invocation",
        self.conversation.messages.items[0].blocks[0].text,
    );
    try std.testing.expectEqualStrings(
        "final",
        self.conversation.messages.items[1].blocks[0].text,
    );
    try std.testing.expectEqual(State.idle, self.state);
}

test "AdmittedRun isolated callback failure poisons and does not commit final text" {
    const Executor = struct {
        fn run(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            identity: RunIdentity,
            backend: *const ui_backend.UiBackend,
            _: *const AbortSignal,
            out_final_text: *std.ArrayList(u8),
        ) anyerror!agent_loop.RunResult {
            backend.emitEvent(identity.session_id, .{ .text_chunk = "rejected" });
            try out_final_text.appendSlice(allocator, "must-not-commit");
            return .{ .stop_reason = .aborted, .turns = 1, .tool_calls = 0 };
        }
    };

    const runtime = try createTestRuntime(std.testing.allocator);
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try createTestSession(runtime, .default, cwd);
    defer self.destroy() catch unreachable;
    var probe = SinkProbe{ .accept = false };
    var executor: u8 = 0;
    var admitted = try self.admitRun(9, probe.sink());
    try std.testing.expectError(
        error.CallbackFailed,
        admitted.runIsolated(
            &.{"invocation"},
            .{ .ctx = &executor, .executeFn = Executor.run },
        ),
    );

    try std.testing.expect(self.isPoisoned());
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), self.conversation.messages.items.len);
    try std.testing.expectEqualStrings(
        "invocation",
        self.conversation.messages.items[0].blocks[0].text,
    );
}

test "AdmittedRun isolated executor shares outer abort and closes cleanly" {
    const Executor = struct {
        session: *AgentSession,

        fn run(
            raw: *anyopaque,
            allocator: std.mem.Allocator,
            identity: RunIdentity,
            _: *const ui_backend.UiBackend,
            abort: *const AbortSignal,
            out_final_text: *std.ArrayList(u8),
        ) anyerror!agent_loop.RunResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try self.session.abort(identity.run_id, .timeout);
            try std.testing.expect(abort.isAborted());
            try out_final_text.appendSlice(allocator, "closed-before-abort");
            return .{ .stop_reason = .end_turn, .turns = 1, .tool_calls = 0 };
        }
    };

    const runtime = try createTestRuntime(std.testing.allocator);
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try createTestSession(runtime, .default, cwd);
    defer self.destroy() catch unreachable;
    var probe = SinkProbe{};
    var executor = Executor{ .session = self };
    var admitted = try self.admitRun(11, probe.sink());
    const result = try admitted.runIsolated(
        &.{"invocation"},
        .{ .ctx = &executor, .executeFn = Executor.run },
    );

    try std.testing.expectEqual(agent_loop.StopReason.aborted, result.stop_reason);
    try std.testing.expectEqual(State.idle, self.state);
    try std.testing.expectEqual(@as(usize, 2), self.conversation.messages.items.len);
    try std.testing.expectEqualStrings(
        "closed-before-abort",
        self.conversation.messages.items[1].blocks[0].text,
    );
}

test "AgentSession abort is run-scoped, idempotent and reports late requests" {
    const runtime = try createTestRuntime(std.testing.allocator);
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try createTestSession(runtime, .default, cwd);
    var probe = SinkProbe{};

    try std.testing.expectError(error.StaleRun, self.abort(0, .user_interrupt));
    _ = try self.beginRun(3, probe.sink());
    try std.testing.expectError(error.StaleRun, self.abort(4, .user_interrupt));
    try self.abort(3, .timeout);
    try std.testing.expectEqual(State.abort_requested, self.state);
    try std.testing.expect(self.abort_signal.isAborted());
    try std.testing.expectEqual(abort_mod.Reason.timeout, self.abort_signal.reason());

    // A repeated abort is harmless and preserves the first reason.
    try self.abort(3, .user_interrupt);
    try std.testing.expectEqual(abort_mod.Reason.timeout, self.abort_signal.reason());
    try std.testing.expectError(error.SessionBusy, self.destroy());

    const completion = self.finishRunLifecycle();
    try std.testing.expect(completion.abort_requested);
    try std.testing.expect(!completion.callback_failed);
    try std.testing.expectError(error.AbortTooLate, self.abort(3, .user_interrupt));
    try self.destroy();
}

test "AgentSession callback failure aborts delivery and poisons the Session" {
    const runtime = try createTestRuntime(std.testing.allocator);
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try createTestSession(runtime, .default, cwd);
    var probe = SinkProbe{ .accept = false };
    _ = try self.beginRun(7, probe.sink());

    AgentSession.backendEmit(self, self.session_id, .stream_begin);
    AgentSession.backendEmit(self, self.session_id, .stream_done);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(u64, 7), probe.run_id);
    try std.testing.expectEqualSlices(u8, self.session_id.asSlice(), probe.session_id.?.asSlice());
    try std.testing.expect(self.abort_signal.isAborted());
    try std.testing.expectEqual(abort_mod.Reason.host_failure, self.abort_signal.reason());

    const completion = self.finishRunLifecycle();
    try std.testing.expect(completion.callback_failed);
    try std.testing.expectEqual(State.poisoned, self.state);
    try std.testing.expect(self.isPoisoned());
    try std.testing.expectError(error.InvalidSessionState, self.beginRun(8, probe.sink()));
    try self.destroy();
}

test "unexpected pre-run allocation failure poisons the Session" {
    const allocator = std.testing.allocator;
    const runtime = try createTestRuntime(allocator);
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const self = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = "http://127.0.0.1:1/v1/messages",
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{"Read"},
    });
    defer self.destroy() catch unreachable;

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    self.conversation.allocator = failing.allocator();
    var sink_state: u8 = 0;
    const Sink = struct {
        fn emit(_: *anyopaque, _: SessionId, _: u64, _: CoreEvent) bool {
            return true;
        }
    };
    try std.testing.expectError(error.OutOfMemory, self.runText(1, "must fail before provider I/O", 1, .{
        .ctx = &sink_state,
        .emit = Sink.emit,
    }));
    try std.testing.expectEqual(State.poisoned, self.state);
    try std.testing.expectError(error.InvalidSessionState, self.beginRun(2, .{
        .ctx = &sink_state,
        .emit = Sink.emit,
    }));
    try std.testing.expectError(error.InvalidSessionState, self.abort(1, .user_interrupt));
}

test "AgentRuntime refuses destruction while Sessions are live" {
    const runtime = try createTestRuntime(std.testing.allocator);
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const first = try createTestSession(runtime, .default, cwd);
    const second = try createTestSession(runtime, .default, cwd);
    try std.testing.expectError(error.RuntimeBusy, runtime.destroy());
    try first.destroy();
    try std.testing.expectError(error.RuntimeBusy, runtime.destroy());
    try second.destroy();
    try runtime.destroy();
}

test "AgentRuntime rejects process-only built-ins that AgentSession cannot wire" {
    try std.testing.expectError(error.UnsupportedBuiltinTool, AgentRuntime.create(std.testing.allocator, .{
        .builtin_tools = &.{"TaskCreate"},
    }));
}

test "Host UI requester failure aborts and poisons the active Run" {
    const FailingUi = struct {
        fn request(
            _: *anyopaque,
            _: SessionId,
            _: std.mem.Allocator,
            _: *const ui_request.UiRequest,
            _: *ui_request.UiResponse,
        ) anyerror!ui_request.RequestOutcome {
            return error.HostUiFailed;
        }
    };

    const runtime = try AgentRuntime.create(std.testing.allocator, .{ .builtin_tools = &.{"AskUserQuestion"} });
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    var ui_state: u8 = 0;
    const self = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{"AskUserQuestion"},
        .ui_requester = .{ .ctx = &ui_state, .requestFn = FailingUi.request },
    });
    defer self.destroy() catch unreachable;
    var sink_probe = SinkProbe{};
    _ = try self.beginRun(11, sink_probe.sink());

    const req = ui_request.UiRequest{ .permission = .{ .tool = "Write", .args = "{}" } };
    var response: ui_request.UiResponse = undefined;
    try std.testing.expectError(error.HostUiFailed, self.permission_ctx.ui_requester.?.request(
        self.session_id,
        std.testing.allocator,
        &req,
        &response,
    ));
    try std.testing.expect(self.abort_signal.isAborted());
    try std.testing.expectEqual(abort_mod.Reason.host_failure, self.abort_signal.reason());
    const completion = self.finishRunLifecycle();
    try std.testing.expect(completion.callback_failed);
    try std.testing.expectEqual(State.poisoned, self.state);
}

test "run-aware Host UI adapter snapshots identity and allows callback abort" {
    const Probe = struct {
        session: ?*AgentSession = null,
        calls: usize = 0,
        seen: ?RunIdentity = null,

        fn request(
            raw: *anyopaque,
            identity: RunIdentity,
            _: std.mem.Allocator,
            _: *const ui_request.UiRequest,
            _: *ui_request.UiResponse,
        ) anyerror!ui_request.RequestOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.seen = identity;
            try self.session.?.abort(identity.run_id, .user_interrupt);
            return .unavailable;
        }
    };

    const runtime = try AgentRuntime.create(std.testing.allocator, .{ .builtin_tools = &.{"AskUserQuestion"} });
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    var probe = Probe{};
    const self = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{"AskUserQuestion"},
        .run_ui_requester = .{ .ctx = &probe, .requestFn = Probe.request },
    });
    defer self.destroy() catch unreachable;
    probe.session = self;
    const req = ui_request.UiRequest{ .permission = .{ .tool = "Write", .args = "{}" } };
    var response: ui_request.UiResponse = undefined;

    // Idle state is defensive failure and never enters Host code.
    try std.testing.expectError(error.HostUiFailed, self.permission_ctx.ui_requester.?.request(
        self.session_id,
        std.testing.allocator,
        &req,
        &response,
    ));
    try std.testing.expectEqual(@as(usize, 0), probe.calls);

    var sink_probe = SinkProbe{};
    const admitted = try self.beginRun(41, sink_probe.sink());
    try std.testing.expectEqual(
        ui_request.RequestOutcome.unavailable,
        try self.permission_ctx.ui_requester.?.request(self.session_id, std.testing.allocator, &req, &response),
    );
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(u64, 41), probe.seen.?.run_id);
    try std.testing.expectEqualSlices(u8, admitted.session_id.asSlice(), probe.seen.?.session_id.asSlice());
    const completion = self.finishRunLifecycle();
    try std.testing.expect(completion.abort_requested);
    try std.testing.expect(!completion.callback_failed);
    try std.testing.expectEqual(State.idle, self.state);
}

test "run-aware Host UI adapter rejects cross-Session identity and poisons only the target" {
    const Probe = struct {
        calls: usize = 0,

        fn request(
            raw: *anyopaque,
            _: RunIdentity,
            _: std.mem.Allocator,
            _: *const ui_request.UiRequest,
            _: *ui_request.UiResponse,
        ) anyerror!ui_request.RequestOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .unavailable;
        }
    };

    const runtime = try AgentRuntime.create(std.testing.allocator, .{ .builtin_tools = &.{"AskUserQuestion"} });
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    var probe_a = Probe{};
    var probe_b = Probe{};
    const common = SessionConfig{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{"AskUserQuestion"},
    };
    var config_a = common;
    config_a.run_ui_requester = .{ .ctx = &probe_a, .requestFn = Probe.request };
    const session_a = try runtime.createSession(config_a);
    defer session_a.destroy() catch unreachable;
    var config_b = common;
    config_b.run_ui_requester = .{ .ctx = &probe_b, .requestFn = Probe.request };
    const session_b = try runtime.createSession(config_b);
    defer session_b.destroy() catch unreachable;

    var sink_a = SinkProbe{};
    _ = try session_a.beginRun(51, sink_a.sink());
    const req = ui_request.UiRequest{ .permission = .{ .tool = "Write", .args = "{}" } };
    var response: ui_request.UiResponse = undefined;
    try std.testing.expectError(error.HostUiFailed, session_a.permission_ctx.ui_requester.?.request(
        session_b.session_id,
        std.testing.allocator,
        &req,
        &response,
    ));
    try std.testing.expectEqual(@as(usize, 0), probe_a.calls);
    try std.testing.expect(session_a.abort_signal.isAborted());
    try std.testing.expectEqual(abort_mod.Reason.host_failure, session_a.abort_signal.reason());
    const completion = session_a.finishRunLifecycle();
    try std.testing.expect(completion.callback_failed);
    try std.testing.expectEqual(State.poisoned, session_a.state);
    try std.testing.expectEqual(State.idle, session_b.state);
    try std.testing.expectEqual(@as(usize, 0), probe_b.calls);

    // Poisoned state remains a defensive short circuit with no callback.
    try std.testing.expectError(error.HostUiFailed, session_a.permission_ctx.ui_requester.?.request(
        session_a.session_id,
        std.testing.allocator,
        &req,
        &response,
    ));
    try std.testing.expectEqual(@as(usize, 0), probe_a.calls);

    var sink_b = SinkProbe{};
    _ = try session_b.beginRun(1, sink_b.sink());
    _ = session_b.finishRunLifecycle();
    try std.testing.expectEqual(State.idle, session_b.state);
}

test "Workspace shell policy is an authority ceiling for Session tools" {
    const runtime = try AgentRuntime.create(std.testing.allocator, .{ .builtin_tools = &.{ "Read", "Bash" } });
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    try std.testing.expectError(error.ShellToolDisabled, runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{ .root = cwd, .shell = .disabled },
        .allowed_tools = &.{ "Read", "Bash" },
    }));

    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{ .root = cwd, .shell = .disabled },
        .allowed_tools = &.{"Read"},
    });
    defer session.destroy() catch unreachable;
    try std.testing.expect(session.tools.contains("Read"));
    try std.testing.expect(!session.tools.contains("Bash"));
}

test "Sessions sharing one Runtime keep independent tool selections" {
    const runtime = try AgentRuntime.create(std.testing.allocator, .{ .builtin_tools = &.{ "Read", "Grep" } });
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const read_session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "read-key",
        .model = "test-model",
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{"Read"},
    });
    defer read_session.destroy() catch unreachable;
    const grep_session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "grep-key",
        .model = "test-model",
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{"Grep"},
    });
    defer grep_session.destroy() catch unreachable;

    try std.testing.expect(read_session.tools.contains("Read"));
    try std.testing.expect(!read_session.tools.contains("Grep"));
    try std.testing.expect(grep_session.tools.contains("Grep"));
    try std.testing.expect(!grep_session.tools.contains("Read"));
    try std.testing.expect(!std.mem.eql(u8, read_session.session_id.asSlice(), grep_session.session_id.asSlice()));
}

// —— T1 矩阵测试:session_id registry 生命周期(31/36)与 host identity 校验 ——

test "Runtime session registry:原子注册、destroy 注销、Runtime destroy 时为空" {
    const runtime = try AgentRuntime.create(std.testing.allocator, .{ .builtin_tools = &.{"Read"} });
    defer runtime.destroy() catch unreachable; // destroy 内 assert registry 为空
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);

    const a = try createTestSession(runtime, .default, cwd);
    const b = try createTestSession(runtime, .default, cwd);
    // 并存 Session 的 id 互异且均已注册(值语义 key)。
    try std.testing.expect(!std.mem.eql(u8, &a.session_id.bytes, &b.session_id.bytes));
    try std.testing.expectEqual(@as(usize, 2), runtime.session_ids.count());
    // 原子注册:已存在的 id 二次注册 → false(collision detection 的判定分支)。
    try std.testing.expect(!(try runtime.registerSessionId(a.session_id)));
    try std.testing.expectEqual(@as(usize, 2), runtime.session_ids.count());

    const a_id = a.session_id;
    try a.destroy();
    // destroy 成功必须注销。
    try std.testing.expectEqual(@as(usize, 1), runtime.session_ids.count());
    try std.testing.expect(!runtime.session_ids.contains(a_id.bytes));
    try b.destroy();
    try std.testing.expectEqual(@as(usize, 0), runtime.session_ids.count());
}

test "Runtime session registry retries an injected collision and registers the next value" {
    const SequenceSource = struct {
        ids: []const SessionId,
        calls: usize = 0,

        fn next(raw: ?*anyopaque) SessionId {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const index = @min(self.calls, self.ids.len - 1);
            self.calls += 1;
            return self.ids[index];
        }
    };

    const ids = [_]SessionId{
        SessionId.fromSlice("000000000000000000000001").?,
        SessionId.fromSlice("000000000000000000000001").?,
        SessionId.fromSlice("000000000000000000000002").?,
    };
    var source = SequenceSource{ .ids = &ids };
    const runtime = try AgentRuntime.create(std.testing.allocator, .{ .builtin_tools = &.{"Read"} });
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const config = SessionConfig{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{"Read"},
    };
    const hooks = SessionCreateHooks{ .session_id_source = .{
        .ctx = &source,
        .nextFn = SequenceSource.next,
    } };

    const first = try AgentSession.createWithHooks(runtime, config, hooks);
    var first_live = true;
    defer if (first_live) first.destroy() catch {};
    const second = try AgentSession.createWithHooks(runtime, config, hooks);
    var second_live = true;
    defer if (second_live) second.destroy() catch {};

    try std.testing.expectEqual(@as(usize, 3), source.calls);
    try std.testing.expectEqualStrings(ids[0].asSlice(), first.session_id.asSlice());
    try std.testing.expectEqualStrings(ids[2].asSlice(), second.session_id.asSlice());
    try std.testing.expectEqual(@as(usize, 2), runtime.session_ids.count());

    try first.destroy();
    first_live = false;
    try second.destroy();
    second_live = false;
}

test "Runtime session registry bounds repeated collisions without leaking registration or liveness" {
    const ConstantSource = struct {
        id: SessionId,
        calls: usize = 0,

        fn next(raw: ?*anyopaque) SessionId {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return self.id;
        }
    };

    var source = ConstantSource{ .id = SessionId.fromSlice("000000000000000000000003").? };
    const runtime = try AgentRuntime.create(std.testing.allocator, .{ .builtin_tools = &.{"Read"} });
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const config = SessionConfig{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{"Read"},
    };
    const hooks = SessionCreateHooks{ .session_id_source = .{
        .ctx = &source,
        .nextFn = ConstantSource.next,
    } };
    const first = try AgentSession.createWithHooks(runtime, config, hooks);
    defer first.destroy() catch unreachable;

    try std.testing.expectError(error.SessionIdGeneratorBroken, AgentSession.createWithHooks(runtime, config, hooks));
    try std.testing.expectEqual(@as(usize, 1 + AgentRuntime.MAX_SESSION_ID_RETRIES), source.calls);
    try std.testing.expectEqual(@as(usize, 1), runtime.session_ids.count());
    try std.testing.expectEqual(@as(usize, 1), runtime.live_sessions);
}

test "Session creation failure after ID registration rolls the registry and live count back" {
    const FailingHook = struct {
        fn run(_: ?*anyopaque) anyerror!void {
            return error.InjectedCreationFailure;
        }
    };

    const runtime = try AgentRuntime.create(std.testing.allocator, .{ .builtin_tools = &.{"Read"} });
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);
    const config = SessionConfig{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{"Read"},
    };

    try std.testing.expectError(error.InjectedCreationFailure, AgentSession.createWithHooks(runtime, config, .{
        .after_id_registered_fn = FailingHook.run,
    }));
    try std.testing.expectEqual(@as(usize, 0), runtime.session_ids.count());
    try std.testing.expectEqual(@as(usize, 0), runtime.live_sessions);

    const recovered = try runtime.createSession(config);
    defer recovered.destroy() catch unreachable;
    try std.testing.expectEqual(@as(usize, 1), runtime.session_ids.count());
    try std.testing.expectEqual(@as(usize, 1), runtime.live_sessions);
}

test "选择 Host tool 而无 host_identity_ctx → 创建拒绝且 registry 无残留" {
    var probe_ctx: u8 = 0;
    const HostFn = struct {
        fn execute(_: *anyopaque, _: HostRunIdentity, _: []const u8) error{OutOfMemory}!HostToolOutcome {
            return .{ .failed = null };
        }
    };
    const runtime = try AgentRuntime.create(std.testing.allocator, .{
        .builtin_tools = &.{"Read"},
        .host_sync_tools = &.{.{
            .definition = .{
                .name = "HostX",
                .description = "probe",
                .input_schema = .{ .type = "object", .prop_specs = &.{}, .required = &.{} },
            },
            .ctx = &probe_ctx,
            .execute = HostFn.execute,
        }},
    });
    defer runtime.destroy() catch unreachable;
    const cwd = try testCwd();
    defer std.testing.allocator.free(cwd);

    // 选 Host tool + null ctx → admission 拒绝;registry 与 live_sessions 双双无残留。
    try std.testing.expectError(error.HostIdentityRequired, runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "k",
        .model = "m",
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{"HostX"},
    }));
    try std.testing.expectEqual(@as(usize, 0), runtime.session_ids.count());
    try std.testing.expectEqual(@as(usize, 0), runtime.live_sessions);

    // 带 ctx → 创建成功,runLoop 将以 admission 固定身份贯穿(此处验证接线存在)。
    const ok = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "k",
        .model = "m",
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{"HostX"},
        .host_identity_ctx = &probe_ctx,
    });
    try std.testing.expectEqual(@as(?*anyopaque, &probe_ctx), ok.host_identity_ctx);
    try ok.destroy();
}
