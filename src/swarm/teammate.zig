//! Teammate 运行时(SW1):in-process teammate 线程 + 注册表。
//!
//! 对照 cc utils/swarm/inProcessRunner.ts + spawnInProcess.ts,but 长在 metacodes 的
//! AgentJobRegistry 线程模式上:每个 teammate = 一根 std.Thread,里面跑
//! **持久对话的多轮 agent_loop**(与一次性 subagent 的差别:conversation/TaskStore/
//! agent_ident 跨 turn 存活,turn 之间在 idle-wait 循环里等邮箱)。
//!
//! 生命周期:
//!   spawn(注册 config.json 成员) → [turn: agent_loop.run] → idle(config is_active=false
//!   + idle_notification→lead 邮箱) → waitForMail(500ms 轮询:abort→退出;shutdown_request
//!   →退出[SW1 过渡语义,SW4 升级为模型审批];plain 消息→拼下一轮 prompt) → 下一 turn …
//!
//! 关键铁律(全部继承 AgentJobRegistry 血泪):
//!   - **c_allocator**:teammate 线程做 HTTP/分配,App GPA 非线程安全。
//!   - **entry 堆分配指针存储**:ArrayList grow realloc 会悬挂线程持有的 *Entry。
//!   - **独立 AbortSignal**:中断 lead 不杀 teammate(cc spawnInProcess 同款设计)。
//!   - **deinit 铁律**:abort 全部 → join 全部 → 才 free(join 是唯一可靠 happens-before)。
//!   - **agent_ident 每 teammate 一个且跨 turn 稳定**(KG 租约连续性)。
//!
//! SW1 边界(登记,双 review 后修订):
//!   - shutdown_request 直接优雅退出,不经模型审批(SW4 接 cc 完整协议)。
//!   - 协议消息(plan/permission 归 SW4;task_assignment 归 SW3)**留在未读**等各自消费者
//!     (markReadAt 选择性标读,绝不 mark-all 吞;Linus MED-2/PM F4)。
//!   - teammate 不能再 spawn teammate/后台 job(agent_jobs=null,对齐 cc 扁平 roster;
//!     后台 Task 会得 AgentJobsUnavailable 具名错,同步 Task 正常——SW2 过滤工具集时留意)。
//!   - roster 摘除(removeMember)是 lead 的职责(SW2/SW4);teammate 只翻 is_active。
//!     推论:死名(terminated/failed)在 lead prune 前不可复用(addMember 撞 Duplicate),
//!     registry.entries 的尸体也等 deinit 统一收(SW2/SW4 做 prune 时一并处理)。
//!   - findByName 只按 name 匹配(team-blind):一个 registry 只服务一个 team;多 team
//!     场景要么每 team 一个 registry,要么改 key 为 agent_id(PM F6 登记给 SW2)。
//!   - idle notification 无 peer-DM summary / 无 pending 内存消息通道(cc 有;SW5 登记)。
//!
//! SW3 登记(双 review):
//!   - **H1 已修**:每 teammate 独立 KgClient(c_allocator),不共享 App arena 客户端(多线程
//!     定时 poll frontier/claim 会撞非线程安全 arena)。tinykg store 锁串行化执行。
//!   - **M2(register)**:模型忘了 TaskUpdate(completed) 闭合自领任务 → 该任务留 claimed_by=self
//!     被所有人 frontier 跳过、永不完成,而 idle 通知却报 available(信任模型闭合,同 cc)。
//!     缓解:退出时 releaseHeldTasks 释放租约(见下),但"活没干完"仍需模型自律。
//!   - **lease TTL 续期(未做,register)**:claim 一次不续;teammate 单任务跑 >7200s(TTL)会
//!     丢租约被别人重领 → 双执行。当前无长任务续租,靠 SELF_CLAIM 单任务通常远短于 TTL。
//!   - **task-event / parallel_hint 团队化(未做,register)**:frontier parallel_hint 仍指
//!     subagent 非 teammate;swarm 执行样本未记 task-event。归 SW5。
//!   - **claimed_by=name**:自领用 e.agent_id(name@team)做 claim 身份 → kanban 直接显示队友名
//!     (非随机 agent_ident hash)。
//!
//! SW4 边界(安全脊已做,审批 UX 部分登记):
//!   - ✅ **伪造防御(shutdown)**:shutdown_request 只认 from==team-lead(peer 冒充无效)+
//!     "team-lead" 保留名不可 spawn。**plan/permission 响应的 from-gate 尚未接线**——因为它们的
//!     消费者本身未建(pollLeadInbox 丢弃 plan/permission 回执);SW7 建消费者时必须同款加
//!     from==team-lead gate(PM 3d 登记,当前无消费者故伪造回执惰性无害)。
//!   - ✅ **shutdown 协议**:lead 发 shutdown → teammate 回 shutdown_approved(echo request_id)
//!     + 优雅退出(在 idle 处理,不打断进行中的 turn,比 cc 的模型审批更简洁安全)+ 释放持有租约。
//!     lead pollLeadInbox 消费回执 → 摘牌 + 提示。
//!   - ✅ **orphan 清理**:lead SwarmContext.deinit 删会话 team 目录(先 join 全线程再删)。
//!   - **permission 代理(register,SW7)**:teammate 命中权限询问时 ui_requester=null → 按语义
//!     兜底(deny/NotATty)。完整代理(teammate→lead 邮箱 permission_request→lead 弹框→回填)
//!     需模型在环审批语义,best validated with 真模型 e2e(SW7)。当前 teammate 常跑 bypass/继承
//!     模式,无交互 prompt。
//!   - **plan 审批(register,SW7)**:teammate 在 plan 模式的 plan_approval_request→lead auto-approve
//!     同上,归 SW7 真模型验证。
//!
//! SW5 边界(数据面 + 资源上限已做,tty 渲染登记 SW7):
//!   - ✅ **资源上限**:MAX_TEAMMATES(并发 cap)/ output_buf 512K cap / **reapTerminated**(spawn
//!     前回收死尸体,防 entries 反复 spawn+shutdown 无界累积)/ mailbox 软顶(裁最旧已读,未读不丢)
//!     + **硬顶**(MAILBOX_HARD_MAX 丢最旧未读 + log.warn,兜底 runaway sender/卡死消费者)。
//!   - ✅ **statusline roster 段**:swarmSegment(N👥 M⚙)已接线 render(liveCount/workingCount)。
//!   - ⚠️ **snapshotRoster:数据面就绪但无消费者**(Linus/PM SW5:声明≠接线)。它的消费者是
//!     SW7 的 agent-switcher teammate 视图(tty);在此之前它是**为 SW7 预置的数据函数**,不算
//!     "roster 可见"已交付。SW7 接 switcher 时消费它。
//!   - **register(tty,SW7)**:agent switcher 查看单 teammate transcript;readLineRaw idle 阻塞
//!     实时"N 条新消息—按回车"提示(SW2 已登记);idle notification 的 peer-DM summary。
//!   - **register(存量债)**:mailbox 软顶只裁已读——未读堆积(消费者一直不读:如 SW7 前的
//!     plan/permission 回执)仍靠硬顶兜底(丢弃+warn),非零丢失;SW0"无界增长"债由软+硬顶
//!     共同封顶(常态软顶,极端硬顶),不再无界但硬顶会丢未读(有 warn 留痕)。claimed_task_ids
//!     按 claim 累积、仅退出时清(单 teammate 一生内理论无界,8B/条,极小)——register。

const std = @import("std");
const sync = @import("platform").sync;
const team_mod = @import("team.zig");
const mailbox = @import("mailbox.zig");
const pf = @import("../api/provider_factory.zig");
const dialect_mod = @import("../api/dialect.zig");
const types_mod = @import("../types.zig");
const json_mod = @import("../json.zig");
const permission_mod = @import("../permission.zig");
const agent_loop = @import("../core/agent_loop.zig");
const Conversation = @import("../core/conversation.zig").Conversation;
const TaskStore = @import("../core/task_store.zig").TaskStore;
const session_id_mod = @import("../core/session_id.zig");
const ui_backend_mod = @import("../core/protocol/ui_backend.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const util_time = @import("../util/time.zig");
const utf8 = @import("../util/utf8.zig");
const util_json = @import("../util/json.zig");
const log = @import("../util/log.zig");

/// 同队同时存活的 teammate 上限(线程/API 并发保护;正式产品语义归 SW5)。
pub const MAX_TEAMMATES: usize = 8;

/// 邮箱轮询间隔(cc inProcessRunner 500ms 同款)。
pub const IDLE_POLL_MS: u64 = 500;

pub const TeammateStatus = enum { working, idle, terminated, failed };

/// 一个 teammate(堆分配,地址稳定;线程与主线程共享)。
pub const TeammateEntry = struct {
    allocator: std.mem.Allocator,
    session: session_id_mod.SessionId = session_id_mod.SessionId.single,
    mutex: sync.Mutex = .{},
    status: TeammateStatus = .working,
    thread: ?std.Thread = null,
    abort: AbortSignal = undefined,

    // 身份(owned,spawn 时定)。
    name: []u8 = &.{}, // sanitized
    agent_id: []u8 = &.{}, // name@team
    team: []u8 = &.{}, // sanitized
    color: []u8 = &.{},
    agent_type: []u8 = &.{},
    /// KG 租约身份,跨 turn 稳定(spawn 时 gen 一次)。
    agent_ident: session_id_mod.SessionId = undefined,

    // 路径(owned)。
    inbox_path: []u8 = &.{},
    lead_inbox_path: []u8 = &.{},
    config_path: []u8 = &.{},

    // 可观测字段(mutex 保护)。**现状:只写不读**——SW5 接 roster 渲染时成为数据源
    // (PM F2 登记:写路径先行保正确,消费者在 SW5;err_name 对齐 agent_job_registry
    // 同名字段的 task_output 消费模式)。output_buf 由组件测试消费断言。
    output_buf: std.ArrayList(u8) = .empty,
    output_utf8_pending: [4]u8 = undefined,
    output_utf8_pending_len: u8 = 0,
    output_truncated: bool = false,
    tokens: u64 = 0, // = tokens_base + 当前 run 最新 usage 快照
    tokens_base: u64 = 0, // 已完成 run 的沉淀值(run 结束时 tokens→tokens_base)
    turns_total: u32 = 0,
    runs_total: u32 = 0, // 完成的 agent_loop.run 次数(≥1 idle 过一次)
    err_name: ?[]const u8 = null, // @errorName 静态串
    started_ms: util_time.Millis = 0,
    /// SW3/SW4:本 teammate 当前持有的 KG 任务租约(self-claim 得来)。shutdown/退出时
    /// 逐个 releaseTask,防任务卡到 TTL(7200s)才可被别人重领(PM F4)。mutex 保护。
    claimed_task_ids: std.ArrayList(u64) = .empty,

    pub fn lockPublic(self: *TeammateEntry) void {
        _ = self.mutex.lock();
    }
    pub fn unlockPublic(self: *TeammateEntry) void {
        _ = self.mutex.unlock();
    }

    fn setStatus(self: *TeammateEntry, s: TeammateStatus) void {
        self.lockPublic();
        defer self.unlockPublic();
        self.status = s;
    }

    pub fn statusSnapshot(self: *TeammateEntry) TeammateStatus {
        self.lockPublic();
        defer self.unlockPublic();
        return self.status;
    }

    /// teammate 的 agent_loop 输出经此 backend 进 entry(镜像 JobEntry:text→output_buf,
    /// usage→tokens)。emit 在 teammate 线程调,各分支自行持锁。
    pub fn backend(self: *TeammateEntry) ui_backend_mod.UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = &emitThunk, .poll = &pollThunk };
    }

    fn pollThunk(_: *anyopaque, _: ui_backend_mod.SessionId) ?ui_backend_mod.UiEvent {
        return null; // teammate 无键盘;输入=邮箱
    }

    fn emitThunk(state: *anyopaque, _: ui_backend_mod.SessionId, ev: ui_backend_mod.CoreEvent) void {
        const self: *TeammateEntry = @ptrCast(@alignCast(state));
        switch (ev) {
            .text_chunk => |t| {
                self.lockPublic();
                defer self.unlockPublic();
                // 上限保护(Linus LOW-2):长寿 teammate 的输出单调增长,cap 后丢尾
                // (SW5 若要完整 transcript 走落盘方案)。
                const OUTPUT_CAP: usize = 512 * 1024;
                if (self.output_buf.items.len < OUTPUT_CAP and self.output_truncated == false) {
                    if (self.output_utf8_pending_len > 0) {
                        const pending = self.output_utf8_pending[0..self.output_utf8_pending_len];
                        const room = OUTPUT_CAP - self.output_buf.items.len;
                        if (pending.len > room) {
                            self.output_truncated = true;
                            return;
                        }
                        self.output_buf.appendSlice(self.allocator, pending) catch return;
                        self.output_utf8_pending_len = 0;
                    }
                    const room = OUTPUT_CAP - self.output_buf.items.len;
                    const take = @min(t.len, room);
                    self.output_buf.appendSlice(self.allocator, t[0..take]) catch return;
                    if (take < t.len) self.output_truncated = true;
                    if (utf8.incompleteTailStart(self.output_buf.items)) |start| {
                        const tail_len = self.output_buf.items.len - start;
                        @memcpy(self.output_utf8_pending[0..tail_len], self.output_buf.items[start..]);
                        self.output_utf8_pending_len = @intCast(tail_len);
                        self.output_buf.items.len = start;
                    }
                }
            },
            .usage => |u| {
                self.lockPublic();
                defer self.unlockPublic();
                // run 内快照覆盖 + 跨 run 基数累计(Linus LOW-1)。
                self.tokens = self.tokens_base + u.input_tokens + u.output_tokens;
            },
            else => {},
        }
    }

    fn flushOutputPending(self: *TeammateEntry) void {
        self.lockPublic();
        defer self.unlockPublic();
        if (self.output_utf8_pending_len == 0) return;
        const pending = self.output_utf8_pending[0..self.output_utf8_pending_len];
        if (pending.len <= 512 * 1024 -| self.output_buf.items.len) {
            // Preserve source-byte offsets; JSON serialization repairs this
            // incomplete tail to U+FFFD at the transport boundary.
            self.output_buf.appendSlice(self.allocator, pending) catch return;
        } else {
            // The source tail could not fit in the bounded preview. Keep the
            // truncation signal instead of silently dropping captured bytes.
            self.output_truncated = true;
        }
        self.output_utf8_pending_len = 0;
    }
};

/// spawn 参数(borrowed;registry 内部 dupe)。
pub const SpawnTeammateParams = struct {
    /// 未清洗的期望名(内部 sanitize;重名由调用方[SW2 工具层]先做后缀去重)。
    name: []const u8,
    /// 已清洗 team 名(config.json 必须已存在——TeamCreate 先行)。
    team: []const u8,
    prompt: []const u8,
    /// Session routing key inherited from the lead. Every backend event and
    /// permission request from this teammate must remain in the parent's view.
    session: session_id_mod.SessionId = session_id_mod.SessionId.single,
    system_prompt: []const u8 = "",
    tool_defs: []const json_mod.ToolDefinition,
    permission_ctx: permission_mod.PermissionContext, // 值拷贝
    color: []const u8 = "",
    agent_type: []const u8 = "",
    max_turns_per_run: u32 = 0, // 0=默认 20
    model_override: ?[]const u8 = null,
    /// 档位表借用指针(App 生命周期只读;teammate 内嵌套 Task 解析 low/mid/high 用)。
    model_tiers: ?*const @import("../api/model_tiers.zig").ProviderTiers = null,
    reasoning_effort_override: ?types_mod.ReasoningEffort = null,
    perm_override: ?types_mod.PermissionMode = null,
    project_dir: []const u8 = "",
    cwd: []const u8 = "",
    // **task#12(Linus review):sandbox 透传到 teammate**——in-process teammate 也跑 agent_loop + Bash,
    // 缺 sandbox = 第三处后门(同 subagent 同步/后台路径)。sandbox 借 App 生命周期;home_dir/additional_dirs
    // 深拷贝(cwd 已有,复用作 sandbox cwd_abs)。
    sandbox: ?*const @import("../sandbox/config.zig").SandboxSettings = null,
    home_dir: []const u8 = "",
    artifact_root: []const u8 = "",
    tool_result_metrics: ?*@import("../core/tool_result_metrics.zig").Metrics = null,
    file_change_journal: ?*@import("../core/file_change.zig").Journal = null,
    additional_dirs: []const []const u8 = &.{},
    mcp_sessions: []const @import("../core/mcp_session.zig").McpSessionEntry = &.{},
    /// AgentDef.isolation=worktree 所有权；spawnTeammate consume-on-call。
    worktree: ?@import("../agents/isolation.zig").Worktree = null,
    // 借用(App 生命周期):
    dyn_registry: ?*const @import("../tools/dynamic.zig").DynRegistry = null,
    host_services: ?@import("../tools/context.zig").HostServices = null,
    kg: ?*@import("../kg/client.zig").KgClient = null,
    kg_projects_dir: []const u8 = "",
};

/// 线程拥有的输入(dupe 自 params;线程结束自行 cleanup)。
const TeammateInput = struct {
    allocator: std.mem.Allocator,
    entry: *TeammateEntry,
    prompt: []u8,
    session: session_id_mod.SessionId,
    system_prompt: []u8,
    tool_defs_owned: []json_mod.ToolDefinition,
    desc_copies: [][]u8, // 深拷贝的 description(同 AgentJobRegistry UAF 防护)
    project_dir: []u8,
    home: []u8, // teammate SwarmContext 路径根(SendMessage 用)
    model_override: ?[]u8,
    model_tiers: ?*const @import("../api/model_tiers.zig").ProviderTiers,
    reasoning_effort_override: ?types_mod.ReasoningEffort,
    permission_ctx: permission_mod.PermissionContext,
    perm_override: ?types_mod.PermissionMode,
    max_turns_per_run: u32,
    dyn_registry: ?*const @import("../tools/dynamic.zig").DynRegistry,
    host_services: ?@import("../tools/context.zig").HostServices,
    kg: ?*@import("../kg/client.zig").KgClient,
    kg_projects_dir: []const u8,
    // task#12:sandbox 借 App 生命周期(deinit 先 join teammates);cwd_abs/home_dir/additional_dirs 深拷贝。
    sandbox: ?*const @import("../sandbox/config.zig").SandboxSettings,
    cwd_abs: []u8,
    home_dir: []u8,
    artifact_root: []u8,
    tool_result_metrics: ?*@import("../core/tool_result_metrics.zig").Metrics,
    file_change_journal: ?*@import("../core/file_change.zig").Journal,
    additional_dirs: [][]u8,
    memdir_owned: []u8,
    mcp_sessions_owned: []@import("../core/mcp_session.zig").McpSessionEntry,
    worktree: ?@import("../agents/isolation.zig").Worktree,
    owned: pf.OwnedProvider,

    fn cleanup(self: *TeammateInput) void {
        const a = self.allocator;
        a.free(self.prompt);
        a.free(self.system_prompt);
        for (self.desc_copies) |d| a.free(d);
        a.free(self.desc_copies);
        a.free(self.tool_defs_owned);
        a.free(self.project_dir);
        a.free(self.home);
        a.free(self.cwd_abs); // task#12
        a.free(self.home_dir);
        a.free(self.artifact_root);
        for (self.additional_dirs) |d| a.free(d);
        a.free(self.additional_dirs);
        a.free(self.memdir_owned);
        a.free(self.mcp_sessions_owned);
        if (self.worktree) |*wt| {
            _ = wt.finalize(null);
            wt.deinit();
        }
        if (self.model_override) |m| a.free(m);
        self.owned.deinit();
        a.destroy(self);
    }
};

pub const TeammateRegistry = struct {
    allocator: std.mem.Allocator,
    list_mutex: sync.Mutex = .{},
    entries: std.ArrayList(*TeammateEntry) = .empty,
    closing: bool = false,
    starting: usize = 0,
    // per-teammate provider 构造参数(dupe 自 App;同 AgentJobRegistry)。
    api_key: []u8,
    base_url: ?[]u8,
    model: []u8,
    provider_kind: types_mod.ProviderKind = .anthropic,
    /// OpenAI wire 协议(仅 provider_kind==.openai 时消费):teammate 继承 lead 的显式选择。
    openai_protocol: types_mod.OpenAIProtocol = .chat_completions,
    /// issue #16:lead 已解析路由的 provider-declared auth scheme。null = 历史
    /// bearer 字节。由 `SwarmContext` 在 spawn 时注入。
    auth_scheme: ?@import("../provider/credential.zig").AuthScheme = null,
    dialect_resolver: dialect_mod.Resolver = .builtin(),
    limits: ?@import("../api/model_limits.zig").ModelLimitsSource = null,
    catalog_snapshot: ?@import("../api/catalog.zig").Catalog = null,
    home: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        base_url: ?[]const u8,
        model: []const u8,
        provider_kind: types_mod.ProviderKind,
        home: []const u8,
    ) !TeammateRegistry {
        return initWithDialectResolver(
            allocator,
            api_key,
            base_url,
            model,
            provider_kind,
            .chat_completions,
            home,
            .builtin(),
        );
    }

    pub fn initWithDialectResolver(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        base_url: ?[]const u8,
        model: []const u8,
        provider_kind: types_mod.ProviderKind,
        openai_protocol: types_mod.OpenAIProtocol,
        home: []const u8,
        dialect_resolver: dialect_mod.Resolver,
    ) !TeammateRegistry {
        if (home.len == 0) return error.NoHome; // 路径 helper 空 home 约束(team.zig F9)
        const key_owned = try allocator.dupe(u8, api_key);
        errdefer allocator.free(key_owned);
        const url_owned: ?[]u8 = if (base_url) |u| try allocator.dupe(u8, u) else null;
        errdefer if (url_owned) |u| allocator.free(u);
        const model_owned = try allocator.dupe(u8, model);
        errdefer allocator.free(model_owned);
        const home_owned = try allocator.dupe(u8, home);
        errdefer allocator.free(home_owned);
        return .{
            .allocator = allocator,
            .api_key = key_owned,
            .base_url = url_owned,
            .model = model_owned,
            .provider_kind = provider_kind,
            .openai_protocol = openai_protocol,
            .dialect_resolver = dialect_resolver,
            .home = home_owned,
        };
    }

    fn listLock(self: *TeammateRegistry) void {
        _ = self.list_mutex.lock();
    }
    fn listUnlock(self: *TeammateRegistry) void {
        _ = self.list_mutex.unlock();
    }

    /// Publish an owned catalog snapshot; worker teammates never read App's mutable catalog.
    pub fn setLimits(self: *TeammateRegistry, source: @import("../api/model_limits.zig").ModelLimitsSource) !void {
        var snapshot: ?@import("../api/catalog.zig").Catalog = null;
        if (source.catalog) |catalog| snapshot = try catalog.clone(self.allocator);
        self.listLock();
        defer self.listUnlock();
        if (self.catalog_snapshot) |*old| old.deinit();
        self.catalog_snapshot = snapshot;
        self.limits = source;
        self.limits.?.catalog = null;
    }

    fn makeProvider(self: *TeammateRegistry, model: []const u8) !pf.OwnedProvider {
        self.listLock();
        defer self.listUnlock();
        var limits = self.limits;
        if (limits) |*value| value.catalog = if (self.catalog_snapshot) |*catalog| catalog else null;
        return pf.makeProviderWithOptions(
            std.heap.c_allocator,
            self.provider_kind,
            self.api_key,
            model,
            self.base_url,
            self.openai_protocol,
            self.dialect_resolver,
            .{ .auth_scheme = self.auth_scheme, .limits = limits },
        );
    }

    pub fn findByName(self: *TeammateRegistry, name_sanitized: []const u8) ?*TeammateEntry {
        return self.findByNameForSession(name_sanitized, null);
    }

    pub fn findByNameForSession(self: *TeammateRegistry, name_sanitized: []const u8, session: ?session_id_mod.SessionId) ?*TeammateEntry {
        self.listLock();
        defer self.listUnlock();
        for (self.entries.items) |e| {
            if (session) |wanted| if (!std.mem.eql(u8, e.session.asSlice(), wanted.asSlice())) continue;
            if (std.mem.eql(u8, e.name, name_sanitized)) return e;
        }
        return null;
    }

    pub fn hasNameForSession(self: *TeammateRegistry, name_sanitized: []const u8, session: session_id_mod.SessionId) bool {
        self.listLock();
        defer self.listUnlock();
        for (self.entries.items) |e| {
            if (!std.mem.eql(u8, e.name, name_sanitized)) continue;
            if (std.mem.eql(u8, e.session.asSlice(), session.asSlice())) return true;
        }
        return false;
    }

    pub fn statusForNameForSession(self: *TeammateRegistry, name_sanitized: []const u8, session: session_id_mod.SessionId) ?TeammateStatus {
        self.listLock();
        defer self.listUnlock();
        for (self.entries.items) |e| {
            if (!std.mem.eql(u8, e.name, name_sanitized)) continue;
            if (!std.mem.eql(u8, e.session.asSlice(), session.asSlice())) continue;
            e.lockPublic();
            const status = e.status;
            e.unlockPublic();
            return status;
        }
        return null;
    }

    pub fn liveCount(self: *TeammateRegistry) usize {
        return self.liveCountForSession(null);
    }

    pub fn liveCountForSession(self: *TeammateRegistry, session: ?session_id_mod.SessionId) usize {
        self.listLock();
        defer self.listUnlock();
        return self.liveCountLockedForSession(session);
    }

    fn liveCountLocked(self: *TeammateRegistry) usize {
        return self.liveCountLockedForSession(null);
    }

    fn liveCountLockedForSession(self: *TeammateRegistry, session: ?session_id_mod.SessionId) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (session) |wanted| if (!std.mem.eql(u8, e.session.asSlice(), wanted.asSlice())) continue;
            const s = e.statusSnapshot();
            if (s == .working or s == .idle) n += 1;
        }
        return n;
    }

    fn hasActiveNameLocked(self: *TeammateRegistry, name: []const u8) bool {
        for (self.entries.items) |e| {
            if (!std.mem.eql(u8, e.name, name)) continue;
            const s = e.statusSnapshot();
            if (s == .working or s == .idle) return true;
        }
        return false;
    }

    /// 全部 entry 数(含 terminated/failed 尸体;测试断言 reap 用)。
    pub fn totalCount(self: *TeammateRegistry) usize {
        self.listLock();
        defer self.listUnlock();
        return self.entries.items.len;
    }

    /// 测试专用:注册一个无线程的假 entry(供离线验证 roster/statusline 计数,不 spawn 网络)。
    /// entry 由 deinit 统一释放(无 thread → 无 join)。
    pub fn pushTestEntry(self: *TeammateRegistry, name: []const u8, status: TeammateStatus) !void {
        const a = std.heap.c_allocator;
        const e = try a.create(TeammateEntry);
        e.* = .{ .allocator = a, .session = session_id_mod.SessionId.single };
        e.mutex = .{};
        e.abort = AbortSignal.init();
        e.status = status;
        e.name = try a.dupe(u8, name);
        e.agent_id = try a.dupe(u8, name);
        e.team = try a.dupe(u8, "test");
        e.color = try a.dupe(u8, "");
        e.agent_type = try a.dupe(u8, "general-purpose");
        e.inbox_path = try a.dupe(u8, "");
        e.lead_inbox_path = try a.dupe(u8, "");
        e.config_path = try a.dupe(u8, "");
        self.listLock();
        defer self.listUnlock();
        try self.entries.append(self.allocator, e);
    }

    /// 正在跑(.working)的 teammate 数(statusline "M⚙" 用;不含 idle)。
    pub fn workingCount(self: *TeammateRegistry) usize {
        return self.workingCountForSession(null);
    }

    pub fn workingCountForSession(self: *TeammateRegistry, session: ?session_id_mod.SessionId) usize {
        self.listLock();
        defer self.listUnlock();
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (session) |wanted| if (!std.mem.eql(u8, e.session.asSlice(), wanted.asSlice())) continue;
            if (e.statusSnapshot() == .working) n += 1;
        }
        return n;
    }

    /// SW5:roster 值语义快照(name/status/tokens/turns/agent_type),供 TUI statusline/switcher
    /// 渲染(不持锁/不持指针跨线程)。name 拷进调用者 allocator;用完 freeRoster。
    pub const RosterRow = struct {
        name: []u8,
        agent_type: []u8,
        status: TeammateStatus,
        tokens: u64,
        runs: u32,
    };
    pub fn snapshotRoster(self: *TeammateRegistry, allocator: std.mem.Allocator) ![]RosterRow {
        return self.snapshotRosterForSession(allocator, null);
    }

    pub fn snapshotRosterForSession(self: *TeammateRegistry, allocator: std.mem.Allocator, session: ?session_id_mod.SessionId) ![]RosterRow {
        self.listLock();
        defer self.listUnlock();
        var count: usize = 0;
        for (self.entries.items) |e| {
            if (session) |wanted| if (!std.mem.eql(u8, e.session.asSlice(), wanted.asSlice())) continue;
            count += 1;
        }
        var out = try allocator.alloc(RosterRow, count);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |r| {
                allocator.free(r.name);
                allocator.free(r.agent_type);
            }
            allocator.free(out);
        }
        for (self.entries.items) |e| {
            if (session) |wanted| if (!std.mem.eql(u8, e.session.asSlice(), wanted.asSlice())) continue;
            e.lockPublic();
            defer e.unlockPublic();
            // 分步 dupe + errdefer,防 name 成功但 agent_type OOM 时 name 泄漏(Linus SW5:
            // struct 字面量部分初始化,out[i]= 未赋值 → errdefer 的 out[0..i] 看不到它)。
            const nm = try allocator.dupe(u8, e.name);
            errdefer allocator.free(nm);
            const at = try allocator.dupe(u8, e.agent_type);
            out[i] = .{ .name = nm, .agent_type = at, .status = e.status, .tokens = e.tokens, .runs = e.runs_total };
            i += 1;
        }
        return out;
    }
    pub fn freeRoster(allocator: std.mem.Allocator, rows: []RosterRow) void {
        for (rows) |r| {
            allocator.free(r.name);
            allocator.free(r.agent_type);
        }
        allocator.free(rows);
    }

    /// spawn 一个 in-process teammate。前置:team config.json 已存在。
    /// 成功返回 entry 指针(registry 存活期内有效)。
    /// committed-flag 回滚模型(同 AgentJobRegistry.spawnBackground)。
    /// 回收已终止的 teammate entry(join 线程 + freeEntry + 从 entries/index 摘除)。
    /// SW5 内存纪律:否则 lead 反复 spawn+shutdown 会让 terminated 尸体在 entries 无界累积
    /// (只在 deinit 才收)。spawn 前调,把已死的先清掉。join 已退出的线程立即返回。
    pub fn reapTerminated(self: *TeammateRegistry) void {
        self.listLock();
        defer self.listUnlock();
        if (self.closing) return;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            const s = e.statusSnapshot();
            if (s == .terminated or s == .failed) {
                if (e.thread) |t| {
                    t.join();
                    e.thread = null;
                }
                // 也从 config.json 摘牌(名字可复用;lead poll 通常已摘,这里幂等兜底)。
                removeMemberBestEffort(e.allocator, e.config_path, e.name);
                _ = self.entries.orderedRemove(i);
                freeEntry(e);
                continue; // i 不前进(后一条补位)
            }
            i += 1;
        }
    }

    pub fn spawnTeammate(self: *TeammateRegistry, p: SpawnTeammateParams) !*TeammateEntry {
        self.listLock();
        if (self.closing) {
            self.listUnlock();
            return error.RegistryClosed;
        }
        self.starting += 1;
        self.listUnlock();
        defer {
            self.listLock();
            self.starting -= 1;
            self.listUnlock();
        }

        self.reapTerminated(); // 先清死尸体,防 entries 无界累积(SW5 内存纪律)
        if (self.liveCount() >= MAX_TEAMMATES) return error.TooManyTeammates;

        // **allocator 一致铁律**(agent_job_registry:397 同款,且本文件测试实测踩过):
        // teammate 线程里 provider 流式事件的所有权转移进 agent_loop,两者 allocator 必须
        // 一致;线程并发分配也要求线程安全 allocator。故 entry/input/provider/线程工作
        // 内存全部统一 c_allocator;registry 自身的 entries 列表仍用 registry allocator。
        const a = std.heap.c_allocator;
        var committed = false;
        var worktree = p.worktree;
        errdefer if (!committed) if (worktree) |*wt| {
            _ = wt.finalize(null);
            wt.deinit();
        };

        // 身份与路径预计算。
        var name_buf: [64]u8 = undefined;
        const name_s = team_mod.sanitizeAgentName(p.name[0..@min(p.name.len, 64)], &name_buf);
        if (name_s.len == 0) return error.BadName;
        // **安全**:"team-lead" 是保留名——精确 "team-lead" 能冒充 lead 发 shutdown/审批(伪造
        // 防御靠 from==team-lead 字符串比较)。大小写变体(Team-Lead)功能上是不同字符串不构成
        // 冒充,但视觉混淆——一并保留(defense-in-depth,case-insensitive)。SW4 review 前置堵死。
        if (std.ascii.eqlIgnoreCase(name_s, team_mod.TEAM_LEAD_NAME)) return error.ReservedName;
        // Name/admission is rechecked under the publication lock below. Do
        // not retain a pointer returned by findByName across this setup phase:
        // reapTerminated may remove that entry concurrently.
        var id_buf: [160]u8 = undefined;
        const agent_id = team_mod.formatAgentId(name_s, p.team, &id_buf) orelse return error.BadName;
        var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
        const config_path = team_mod.configPath(self.home, p.team, &cfg_buf);
        if (config_path.len == 0) return error.BadPath;
        var inbox_buf: [std.fs.max_path_bytes]u8 = undefined;
        const inbox_path = team_mod.inboxPath(self.home, p.team, name_s, &inbox_buf);
        var lead_buf: [std.fs.max_path_bytes]u8 = undefined;
        const lead_inbox_path = team_mod.inboxPath(self.home, p.team, team_mod.TEAM_LEAD_NAME, &lead_buf);

        // 1) entry(堆分配,地址稳定)。
        const entry = try a.create(TeammateEntry);
        errdefer if (!committed) a.destroy(entry);
        entry.* = .{ .allocator = a, .session = p.session };
        entry.mutex = .{};
        entry.abort = AbortSignal.init();
        entry.started_ms = util_time.nowMs();
        entry.agent_ident = session_id_mod.gen();
        entry.name = try a.dupe(u8, name_s);
        errdefer if (!committed) a.free(entry.name);
        entry.agent_id = try a.dupe(u8, agent_id);
        errdefer if (!committed) a.free(entry.agent_id);
        entry.team = try a.dupe(u8, p.team);
        errdefer if (!committed) a.free(entry.team);
        entry.color = try a.dupe(u8, p.color);
        errdefer if (!committed) a.free(entry.color);
        entry.agent_type = try a.dupe(u8, p.agent_type);
        errdefer if (!committed) a.free(entry.agent_type);
        entry.inbox_path = try a.dupe(u8, inbox_path);
        errdefer if (!committed) a.free(entry.inbox_path);
        entry.lead_inbox_path = try a.dupe(u8, lead_inbox_path);
        errdefer if (!committed) a.free(entry.lead_inbox_path);
        entry.config_path = try a.dupe(u8, config_path);
        errdefer if (!committed) a.free(entry.config_path);

        // 2) 注册进 config.json(锁内 RMW;team 不存在 → TeamNotFound,不留半成品)。
        const AddCtx = struct {
            agent_id: []const u8,
            name: []const u8,
            color: []const u8,
            agent_type: []const u8,
            model: []const u8,
            cwd: []const u8,
            session: []const u8,
        };
        const addMember = struct {
            fn f(ctx: AddCtx, tf: *team_mod.TeamFile) anyerror!void {
                if (tf.findMember(ctx.name) != null) return error.DuplicateTeammateName;
                try tf.addMember(.{
                    .agent_id = ctx.agent_id,
                    .name = ctx.name,
                    .agent_type = if (ctx.agent_type.len > 0) ctx.agent_type else null,
                    .model = if (ctx.model.len > 0) ctx.model else null,
                    .color = if (ctx.color.len > 0) ctx.color else null,
                    .joined_at_ms = @intCast(@divTrunc(util_time.nowWallNs(), 1_000_000)),
                    .cwd = ctx.cwd,
                    .session_id = ctx.session,
                    .backend_type = "in-process",
                    .is_active = true,
                });
            }
        }.f;
        try team_mod.updateTeam(a, config_path, AddCtx{
            .agent_id = agent_id,
            .name = name_s,
            .color = p.color,
            .agent_type = p.agent_type,
            .model = p.model_override orelse "",
            .cwd = p.cwd,
            .session = p.session.asSlice(),
        }, addMember);
        // 从这里起,失败要把成员摘回去。
        errdefer if (!committed) removeMemberBestEffort(a, config_path, name_s);

        // 3) 邮箱就位(空邮箱,ensure 幂等)。
        try mailbox.ensureInbox(inbox_path);
        try mailbox.ensureInbox(lead_inbox_path);

        // 4) 专属 provider(c_allocator:线程安全 + 与 agent_loop 事件所有权一致)。
        var owned = try self.makeProvider(p.model_override orelse self.model);
        errdefer if (!committed) owned.deinit();

        // 5) dupe 输入。
        const input = try a.create(TeammateInput);
        errdefer if (!committed) a.destroy(input);
        const prompt_owned = try a.dupe(u8, p.prompt);
        errdefer if (!committed) a.free(prompt_owned);
        const sys_owned = try a.dupe(u8, p.system_prompt);
        errdefer if (!committed) a.free(sys_owned);
        const defs_owned = try a.dupe(json_mod.ToolDefinition, p.tool_defs);
        errdefer if (!committed) a.free(defs_owned);
        const desc_copies = try a.alloc([]u8, defs_owned.len);
        errdefer if (!committed) a.free(desc_copies);
        var nd: usize = 0;
        errdefer if (!committed) for (desc_copies[0..nd]) |d| a.free(d);
        for (defs_owned, 0..) |*d, di| {
            const c = try a.dupe(u8, d.description);
            desc_copies[di] = c;
            nd = di + 1;
            d.description = c;
        }
        const pdir_owned = try a.dupe(u8, p.project_dir);
        errdefer if (!committed) a.free(pdir_owned);
        const home_owned = try a.dupe(u8, self.home);
        errdefer if (!committed) a.free(home_owned);
        const mover_owned: ?[]u8 = if (p.model_override) |m| try a.dupe(u8, m) else null;
        errdefer if (!committed) if (mover_owned) |m| a.free(m);
        // task#12:sandbox 快照(cwd_abs 用 p.cwd;home_dir dupe;additional_dirs 深拷贝防 realloc 悬挂)。
        const cwd_sb_owned = try a.dupe(u8, p.cwd);
        errdefer if (!committed) a.free(cwd_sb_owned);
        const home_sb_owned = try a.dupe(u8, p.home_dir);
        errdefer if (!committed) a.free(home_sb_owned);
        const artifact_root_owned = try a.dupe(u8, p.artifact_root);
        errdefer if (!committed) a.free(artifact_root_owned);
        const adirs_sb_owned = try a.alloc([]u8, p.additional_dirs.len);
        errdefer if (!committed) a.free(adirs_sb_owned);
        var nad_sb: usize = 0;
        errdefer if (!committed) for (adirs_sb_owned[0..nad_sb]) |d| a.free(d);
        for (p.additional_dirs, 0..) |d, di| {
            adirs_sb_owned[di] = try a.dupe(u8, d);
            nad_sb = di + 1;
        }
        const memdir_owned = try a.dupe(u8, p.permission_ctx.memdir_abs);
        errdefer if (!committed) a.free(memdir_owned);
        const mcp_sessions_owned = try a.dupe(@import("../core/mcp_session.zig").McpSessionEntry, p.mcp_sessions);
        errdefer if (!committed) a.free(mcp_sessions_owned);

        var permission_owned = p.permission_ctx.scopedDerive(null);
        permission_owned.allocator = a;
        permission_owned.session = p.session;
        permission_owned.memdir_abs = memdir_owned;
        permission_owned.match_ctx.cwd = cwd_sb_owned;
        permission_owned.match_ctx.project_root = pdir_owned;
        permission_owned.match_ctx.home = home_sb_owned;
        permission_owned.match_ctx.additional_dirs = adirs_sb_owned;
        permission_owned.match_ctx.alloc = a;

        input.* = .{
            .allocator = a,
            .entry = entry,
            .prompt = prompt_owned,
            .session = p.session,
            .system_prompt = sys_owned,
            .tool_defs_owned = defs_owned,
            .desc_copies = desc_copies,
            .project_dir = pdir_owned,
            .home = home_owned,
            .model_override = mover_owned,
            .model_tiers = p.model_tiers,
            .reasoning_effort_override = p.reasoning_effort_override,
            .permission_ctx = permission_owned,
            .perm_override = p.perm_override,
            .max_turns_per_run = p.max_turns_per_run,
            .dyn_registry = p.dyn_registry,
            .host_services = p.host_services,
            .kg = p.kg,
            .kg_projects_dir = p.kg_projects_dir,
            .sandbox = p.sandbox, // task#12:borrow(App-lifetime)
            .cwd_abs = cwd_sb_owned,
            .home_dir = home_sb_owned,
            .artifact_root = artifact_root_owned,
            .tool_result_metrics = p.tool_result_metrics,
            .file_change_journal = p.file_change_journal,
            .additional_dirs = adirs_sb_owned,
            .memdir_owned = memdir_owned,
            .mcp_sessions_owned = mcp_sessions_owned,
            .worktree = worktree,
            .owned = owned,
        };

        // 6) 注册 + spawn。entries 列表本身归 registry allocator(deinit 同款);entry 指针
        // 指向的内存归 c_allocator(freeEntry 用 e.allocator)。
        self.listLock();
        if (self.closing) {
            self.listUnlock();
            return error.RegistryClosed;
        }
        // The earlier checks are only a fast path. Recheck admission and the
        // sanitized name while publishing so concurrent spawns cannot exceed
        // MAX_TEAMMATES or create two live entries with the same name.
        if (self.liveCountLocked() >= MAX_TEAMMATES) {
            self.listUnlock();
            return error.TooManyTeammates;
        }
        if (self.hasActiveNameLocked(name_s)) {
            self.listUnlock();
            return error.DuplicateTeammateName;
        }
        self.entries.append(self.allocator, entry) catch |e| {
            self.listUnlock();
            return e;
        };
        self.listUnlock();
        errdefer if (!committed) {
            self.listLock();
            for (self.entries.items, 0..) |it, i| {
                if (it == entry) {
                    _ = self.entries.swapRemove(i);
                    break;
                }
            }
            self.listUnlock();
        };

        entry.thread = try std.Thread.spawn(.{}, teammateThreadMain, .{input});
        committed = true;
        log.info("swarm", "teammate spawned {s} (team {s})", .{ entry.agent_id, entry.team });
        return entry;
    }

    /// abort 全部 → join 全部 → free(deinit 铁律)。
    pub fn deinit(self: *TeammateRegistry) void {
        self.listLock();
        self.closing = true;
        self.listUnlock();
        while (true) {
            self.listLock();
            const starting = self.starting;
            self.listUnlock();
            if (starting == 0) break;
            util_time.sleepMs(1);
        }
        // Detach the backing array while holding the list lock. This makes
        // the post-close join/free phase immune to a concurrent reader or a
        // future maintenance path that might otherwise invalidate the slice.
        self.listLock();
        var detached = self.entries;
        self.entries = .empty;
        for (detached.items) |e| e.abort.abort(.user_ctrl_c);
        self.listUnlock();
        // join 不持 list 锁(线程退出路径不再注册新 entry,teammate 无嵌套 spawn)。
        for (detached.items) |e| {
            if (e.thread) |t| {
                t.join();
                e.thread = null;
            }
        }
        for (detached.items) |e| freeEntry(e);
        detached.deinit(self.allocator);
        // Provider workers borrow this snapshot through ModelLimitsSource;
        // release it only after every teammate has joined.
        if (self.catalog_snapshot) |*catalog| catalog.deinit();
        self.allocator.free(self.api_key);
        if (self.base_url) |u| self.allocator.free(u);
        self.allocator.free(self.model);
        self.allocator.free(self.home);
    }
};

fn freeEntry(e: *TeammateEntry) void {
    const a = e.allocator;
    a.free(e.name);
    a.free(e.agent_id);
    a.free(e.team);
    a.free(e.color);
    a.free(e.agent_type);
    a.free(e.inbox_path);
    a.free(e.lead_inbox_path);
    a.free(e.config_path);
    e.output_buf.deinit(a);
    e.claimed_task_ids.deinit(a);
    a.destroy(e);
}

/// 释放本 teammate 持有的所有 KG 任务租约(shutdown/退出收尾,PM F4:防卡 7200s TTL)。
/// best-effort;完成的任务已闭合出 frontier,release 是 no-op/ClaimHeld,无害。
fn releaseHeldTasks(e: *TeammateEntry, kg: ?*@import("../kg/client.zig").KgClient) void {
    const k = kg orelse return;
    e.lockPublic();
    const ids = e.claimed_task_ids.toOwnedSlice(e.allocator) catch {
        e.unlockPublic();
        return;
    };
    e.unlockPublic();
    defer e.allocator.free(ids);
    for (ids) |id| k.releaseTask(id, e.agent_id) catch {};
}

const NameCtx = struct { name: []const u8 };
fn removeMemberMutate(c: NameCtx, tf: *team_mod.TeamFile) anyerror!void {
    _ = tf.removeMember(c.name);
}

/// 摘成员(spawn 失败回滚/终止收尾;best-effort:锁忙/文件损坏不致命)。
fn removeMemberBestEffort(a: std.mem.Allocator, config_path: []const u8, name: []const u8) void {
    team_mod.updateTeam(a, config_path, NameCtx{ .name = name }, removeMemberMutate) catch {};
}

const ActiveCtx = struct { name: []const u8, session: session_id_mod.SessionId, active: bool };
fn setMemberActiveMutate(c: ActiveCtx, tf: *team_mod.TeamFile) anyerror!void {
    const m = tf.findMember(c.name) orelse return error.MemberNotFound;
    const member_session = m.session_id orelse return error.SessionMismatch;
    if (!std.mem.eql(u8, member_session, c.session.asSlice())) return error.SessionMismatch;
    m.is_active = c.active;
}

/// 翻 config.json 里成员的 is_active(best-effort)。
fn setMemberActiveBestEffort(a: std.mem.Allocator, config_path: []const u8, name: []const u8, session: session_id_mod.SessionId, active: bool) void {
    team_mod.updateTeam(a, config_path, ActiveCtx{ .name = name, .session = session, .active = active }, setMemberActiveMutate) catch {};
}

/// idle_notification 投递(best-effort;cc teammateInit Stop-hook 等价)。
/// reason 语义(Linus SW1 MED-1 / PM F1:绝不把截断/失败洗成 available):
///   "available"          — end_turn 正常收尾,可接新工作;
///   "needs_continuation" — max_turns/tool_loop/budget 等软截断,活没干完,带 stopReason;
///   "failed"             — run 抛错,带 failureReason。
fn sendIdleNotification(a: std.mem.Allocator, e: *TeammateEntry, reason: []const u8, stop_reason: ?[]const u8, failure: ?[]const u8) void {
    var ts_buf: [40]u8 = undefined;
    const ts = mailbox.formatIso8601(@divTrunc(util_time.nowWallNs(), 1_000_000), &ts_buf);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    out.writer.writeAll("{\"type\":\"idle_notification\",\"from\":") catch return;
    util_json.writeJsonString(&out.writer, e.name) catch return;
    out.writer.writeAll(",\"timestamp\":") catch return;
    util_json.writeJsonString(&out.writer, ts) catch return;
    out.writer.writeAll(",\"idleReason\":") catch return;
    util_json.writeJsonString(&out.writer, reason) catch return;
    if (stop_reason) |sr| {
        out.writer.writeAll(",\"stopReason\":") catch return;
        util_json.writeJsonString(&out.writer, sr) catch return;
    }
    if (failure) |f| {
        out.writer.writeAll(",\"failureReason\":") catch return;
        util_json.writeJsonString(&out.writer, f) catch return;
    }
    out.writer.writeByte('}') catch return;
    const body = out.toOwnedSlice() catch return;
    defer a.free(body);
    mailbox.deliver(a, e.lead_inbox_path, e.name, body, if (e.color.len > 0) e.color else null, null) catch |err| {
        log.warn("swarm", "idle notification delivery failed for {s}: {s}", .{ e.agent_id, @errorName(err) });
    };
}

/// tinykg frontier 自领节流(subprocess 每次 fork+35s timeout 很贵,不能每 500ms 打)。
pub const SELF_CLAIM_POLL_MS: i64 = 2500;
/// 空 frontier 指数退避上限:8 个空闲 teammate 固定 2.5s poll = 稳态 3.2 fork/秒,还抢同一
/// store 目录锁(30s 锁超时)。连续空手 → 间隔翻倍到此上限;领到任务/收到邮件即回落基准。
pub const SELF_CLAIM_POLL_MAX_MS: i64 = 30_000;

/// 下一次自领 poll 间隔:空手翻倍,cap 于 SELF_CLAIM_POLL_MAX_MS(纯函数,测试直断言)。
pub fn nextClaimBackoffMs(cur: i64) i64 {
    return @min(cur * 2, SELF_CLAIM_POLL_MAX_MS);
}

/// SW4:回 shutdown_approved 给 lead(echo request_id,对齐 cc handleShutdownApproval)。
/// lead 的 pollLeadInbox 据此摘牌 + 标记 teammate 完成。best-effort。
fn sendShutdownApproved(a: std.mem.Allocator, e: *TeammateEntry, request_text: []const u8) void {
    const rid = util_json.extractStringField(request_text, "request_id") orelse "";
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    out.writer.writeAll("{\"type\":\"shutdown_approved\",\"from\":") catch return;
    util_json.writeJsonString(&out.writer, e.name) catch return;
    out.writer.writeAll(",\"request_id\":") catch return;
    util_json.writeJsonString(&out.writer, rid) catch return;
    out.writer.writeByte('}') catch return;
    const body = out.toOwnedSlice() catch return;
    defer a.free(body);
    mailbox.deliver(a, e.lead_inbox_path, e.name, body, if (e.color.len > 0) e.color else null, null) catch {};
}

/// idle-wait:轮询自己邮箱直到有下一轮 prompt 或退出信号。
/// 返回 owned prompt(caller free);null = 该退出(abort / shutdown_request)。
/// 消费规则:一次吃光全部未读——lead 消息排前、peer 保持文件序;协议消息中
/// shutdown_request → 退出;其余协议消息 SW1 记日志跳过(SW4 路由)。
/// SW3:邮箱无 plain 工作时,节流 poll tinykg frontier 自领 ready 无主叶子(租约互斥)。
fn waitForMail(a: std.mem.Allocator, e: *TeammateEntry, kg: ?*@import("../kg/client.zig").KgClient, kg_projects_dir: []const u8) ?[]u8 {
    // 未处理协议消息计数缓存:只在数量变化时记一次日志(否则每 500ms 刷屏)。
    var last_unhandled: usize = 0;
    var last_claim_poll_ms: i64 = 0;
    var claim_backoff_ms: i64 = SELF_CLAIM_POLL_MS;
    while (true) {
        if (e.abort.isAborted()) return null;

        var unread = mailbox.readUnread(a, e.inbox_path) catch {
            util_time.sleepMs(IDLE_POLL_MS);
            continue;
        };
        defer unread.deinit();

        if (unread.items.items.len > 0) {
            // 先扫 shutdown(优先级最高,cc inProcessRunner:760 同款)。
            // **SW4 伪造防御**:只认 **team-lead** 发的 shutdown_request——peer teammate 冒充
            // lead 发 shutdown 不得终止别人(对齐 cc "plan/mode 响应仅认 from==team-lead")。
            for (unread.items.items) |*m| {
                if (mailbox.classify(a, m.text) != .shutdown_request) continue;
                if (!std.mem.eql(u8, m.from, team_mod.TEAM_LEAD_NAME)) {
                    // 非 lead 发的 shutdown:标读丢弃 + 记日志(不终止)。
                    const bad = [1]mailbox.Message{m.*};
                    mailbox.markReadAt(a, e.inbox_path, &bad) catch {};
                    log.warn("swarm", "teammate {s} ignored forged shutdown_request from '{s}' (only team-lead may shut down)", .{ e.agent_id, m.from });
                    continue;
                }
                // lead 发的 shutdown:回 shutdown_approved 回执给 lead(SW4 协议)+ 优雅退出。
                // 只标读 shutdown 本身;其它未读留给后续消费者。
                sendShutdownApproved(a, e, m.text);
                const one = [1]mailbox.Message{m.*};
                mailbox.markReadAt(a, e.inbox_path, &one) catch {};
                return null;
            }
            // 组装下一轮 prompt:lead 的 plain 消息在前,其余按文件序。
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(a);
            var consumed: std.ArrayList(mailbox.Message) = .empty;
            defer consumed.deinit(a); // 元素借 unread 的内存,不 free
            appendPlainFrom(a, &out, &unread, team_mod.TEAM_LEAD_NAME, true, &consumed);
            appendPlainFrom(a, &out, &unread, team_mod.TEAM_LEAD_NAME, false, &consumed);

            // **只标读真正消费的 plain**(Linus MED-2/PM F4):协议消息(task_assignment/
            // plan_approval_response…)留在未读,SW3/SW4 的消费者接手;绝不 mark-all 吞掉。
            if (consumed.items.len > 0) {
                mailbox.markReadAt(a, e.inbox_path, consumed.items) catch {};
                return out.toOwnedSlice(a) catch null;
            }
            // 只有协议消息且无 plain → 继续等(下面走 SW3 自领)。
            const unhandled = unread.items.items.len;
            if (unhandled != last_unhandled) {
                log.debug("swarm", "{d} unhandled protocol message(s) pending (SW3/SW4 consumers)", .{unhandled});
                last_unhandled = unhandled;
            }
        }

        // 【SW3】无邮件工作 → 节流 poll tinykg frontier 自领 ready 无主叶子(cc tryClaimNextTask
        // 等价)。claimTask 靠 tinykg 原子租约保证两 teammate 不撞车。
        const now_ms = util_time.nowMs();
        if (kg != null and now_ms - last_claim_poll_ms >= claim_backoff_ms) {
            last_claim_poll_ms = now_ms;
            // 用 human agent_id(name@team)做 claim 身份 → kanban 的 claimed_by 直接是队友名
            // (PM F3e:agent_ident 随机 hash 无法关联到人)。后续 TaskUpdate/TaskStop
            // 经 kg_agent_ident 注入同一 name@team，task-close 会校验有效租约 holder。
            if (tryClaimFrontierTask(a, kg.?, kg_projects_dir, e.agent_id)) |claim| {
                // SW4 seam(PM F4):记下持有的 task_id,shutdown 时释放租约防卡 7200s。
                e.lockPublic();
                e.claimed_task_ids.append(e.allocator, claim.task_id) catch {};
                e.unlockPublic();
                return claim.prompt;
            }
            // 空手:指数退避(下次 poll 间隔翻倍,cap 30s)。返回路径(领到任务/来邮件)天然回落
            // 基准——下次进 waitForMail 时 claim_backoff_ms 重新初始化。
            claim_backoff_ms = nextClaimBackoffMs(claim_backoff_ms);
        }

        util_time.sleepMs(IDLE_POLL_MS);
    }
}

pub const ClaimResult = struct { task_id: u64, prompt: []u8 };

/// The file backlog is mutually exclusive with a live TinyKG control plane.
/// Public for the focused degraded-frontier L2 that guards stale mirror leakage.
pub fn shouldUseDegradedTaskMirror(shared_kg_ready: bool, kg_projects_dir: []const u8) bool {
    return !shared_kg_ready and kg_projects_dir.len > 0;
}

/// SW3 自领:解析共享 inbox root(lead 的 TaskCreate 落此)→ frontier → 领第一个 ready
/// 无主叶子(claimTask 原子租约)→ 组装成下一轮 prompt(owned)。无可领 → null。
/// 只领 role=leaf & status=open & readiness=ready & claimed_by=null 的行
/// (failed/claimed 绝不进入候选；有序边/未完依赖不 ready)。
pub fn tryClaimFrontierTask(a: std.mem.Allocator, kg: *@import("../kg/client.zig").KgClient, kg_projects_dir: []const u8, claim_agent: []const u8) ?ClaimResult {
    if (!kg.ready or kg_projects_dir.len == 0) return null;
    const inject = @import("../kg/inject.zig");
    const root = inject.readIdPointer(a, kg_projects_dir, "kg_inbox") orelse return null;
    const rows = kg.frontier(root, 50) catch return null;
    defer {
        for (rows) |*r| r.deinit(kg.allocator);
        kg.allocator.free(rows);
    }
    for (rows) |*r| {
        if (r.role != .leaf) continue;
        if (r.status != .open) continue;
        if (r.readiness != .ready) continue;
        if (r.claimed_by != null) continue; // 已有主(未过期租约)
        // 尝试原子领取——被别的 teammate 抢先则 ClaimHeld,跳下一个。
        kg.claimTask(r.task_id, claim_agent) catch continue;
        // Claim 之后立刻取 bounded packet。只给一行标题会丢掉父目标、依赖与既有证据；
        // packet 失败则释放租约，绝不让 teammate 在不完整上下文里盲做。
        const packet = kg.taskPacketMeta(r.task_id, 12, 8_000) catch {
            kg.releaseTask(r.task_id, claim_agent) catch {};
            continue;
        };
        defer kg.allocator.free(packet);
        // 组装 prompt(正文 + metadata-first packet；成功 completed，确认不可恢复则 failed；
        // 两者都保留稳定 task id，绝不把持久任务 deleted)。
        const prompt = std.fmt.allocPrint(
            a,
            "<assigned-task id=\"kg-{d}\">You have claimed this task from the team's shared task list as {s}. Read the bounded TinyKG packet before working. Complete it, then close it with TaskUpdate(taskId: \"kg-{d}\", status: \"completed\", conclusion: \"<concise verified result>\"). If verified evidence shows it cannot be completed, use status: \"failed\" with a concise conclusion instead. Never delete a persistent KG task.\n\n{s}\n<task-packet>{s}</task-packet>\n</assigned-task>",
            .{ r.task_id, claim_agent, r.task_id, r.text, packet },
        ) catch {
            // 组装失败:释放租约免得任务卡住。
            kg.releaseTask(r.task_id, claim_agent) catch {};
            return null;
        };
        return .{ .task_id = r.task_id, .prompt = prompt };
    }
    return null;
}

/// 把 unread 里 plain 消息按发件人过滤(match_lead=true 只取 lead;false 取非 lead)
/// 以 wire XML 追加进 out,同时把消费的消息记进 consumed(供选择性标读)。
/// 协议消息跳过(由 waitForMail 统一记日志)。
fn appendPlainFrom(
    a: std.mem.Allocator,
    out: *std.ArrayList(u8),
    unread: *mailbox.MessageList,
    lead_name: []const u8,
    match_lead: bool,
    consumed: *std.ArrayList(mailbox.Message),
) void {
    for (unread.items.items) |*m| {
        const is_lead = std.mem.eql(u8, m.from, lead_name);
        if (is_lead != match_lead) continue;
        if (mailbox.classify(a, m.text) != .plain) continue;
        const wire = mailbox.formatForModel(a, m) catch continue;
        defer a.free(wire);
        if (out.items.len > 0) out.appendSlice(a, "\n\n") catch {};
        out.appendSlice(a, wire) catch {};
        consumed.append(a, m.*) catch {};
    }
}

/// teammate 线程主函数:多轮持久对话 + idle-wait 循环。
fn teammateThreadMain(input: *TeammateInput) void {
    const a = input.allocator;
    const e = input.entry;
    defer e.flushOutputPending();

    var ctx_override = input.permission_ctx.scopedDerive(input.perm_override);
    ctx_override.session = input.session;
    // teammate 线程绝不读 fd 0(与 lead REPL 争抢/卡死):`.ask` 无 ui_requester → fail-closed deny
    // (PM SW4 3c)。SW7 权限代理会给 teammate 一个转发到 lead 的 ui_requester。
    ctx_override.no_interactive_prompt = true;

    if (input.reasoning_effort_override) |effort| {
        input.owned.provider().setReasoningEffort(effort) catch {
            setMemberActiveBestEffort(a, e.config_path, e.name, input.session, false); // 先落盘再翻状态(#100)
            e.setStatus(.failed);
            sendIdleNotification(a, e, "failed", null, "AgentEffortUnsupportedProvider");
            input.cleanup();
            return;
        };
    }

    // 持久状态(跨 turn):conversation + teammate 自己的 TaskStore。
    var conv = Conversation.init(a);
    defer conv.deinit();
    conv.appendText(.user, input.prompt) catch {
        setMemberActiveBestEffort(a, e.config_path, e.name, input.session, false); // 先落盘再翻状态(#100)
        e.setStatus(.failed);
        sendIdleNotification(a, e, "failed", null, "OutOfMemory");
        input.cleanup();
        return;
    };
    var sub_tasks = TaskStore.init(a);
    defer sub_tasks.deinit();

    // Linus SW3 H1:每 teammate 一个**独立 KgClient**(c_allocator),不共享 App arena 客户端
    // (多线程定时 poll frontier/claim 会在非线程安全 arena 上并发 alloc/free → 堆损坏)。
    // tinykg store-dir 锁串行化跨客户端执行。ensureReady 一次(~ms 子进程)。失败 → 无 KG 协调
    // (自领关闭,mailbox 派活仍工作)。self-claim 与 teammate 的 task 工具都用它。
    var own_kg: ?@import("../kg/client.zig").KgClient = null;
    if (input.kg) |shared| {
        // Keep the whole session on one control plane. A degraded lead publishes the
        // file fallback; a teammate must not independently revive TinyKG and split the
        // backlog between graph and mirror.
        if (shared.ready) {
            if (shared.cloneForThread(std.heap.c_allocator, input.home)) |c| {
                own_kg = c;
                own_kg.?.ensureReady();
                if (!own_kg.?.ready) {
                    own_kg.?.deinit();
                    own_kg = null;
                }
            } else |_| {}
        }
    }
    defer if (own_kg) |*k| k.deinit();
    const kg_ptr: ?*@import("../kg/client.zig").KgClient = if (own_kg) |*k| k else null;

    // Only a lead that started degraded publishes `{kg_projects_dir}/tasks.json`.
    // Never open an old mirror while the lead's TinyKG is authoritative: a stale file
    // from an earlier degraded session would otherwise leak numeric tasks into TaskList
    // and teammate writes would recreate a second truth source beside TinyKG.
    const shared_kg_ready = if (input.kg) |shared| shared.ready else false;
    if (shouldUseDegradedTaskMirror(shared_kg_ready, input.kg_projects_dir)) {
        const mirror_path = std.fmt.allocPrint(a, "{s}/tasks.json", .{input.kg_projects_dir}) catch null;
        if (mirror_path) |mp| {
            defer a.free(mp);
            sub_tasks.setMirror(mp) catch |err| {
                log.warn("swarm", "teammate task mirror setup failed: {s}", .{@errorName(err)});
            };
            sub_tasks.loadFromMirror() catch |err| {
                log.warn("swarm", "teammate task mirror reopen failed: {s}", .{@errorName(err)});
            };
        }
    }

    // 每 teammate 一个 SwarmContext(is_lead=false):让 teammate 的 SendMessage 能回 lead/peer
    // (Linus/PM F1)。team_sanitized 借 entry.team、home 借 input.home——**不 deinit 本地 sw**
    // (teammates=null 无 registry;两串是借用,deinit 会误 free)。
    var teammate_sw = @import("context.zig").SwarmContext{
        .allocator = a,
        .session = input.session,
        .home = input.home,
        .self_name = e.name,
        .is_lead = false,
        .team_sanitized = e.team,
    };

    const be = e.backend();

    // The teammate shares DynRegistry but may only execute tools selected into
    // its AgentDef-derived definition snapshot.
    var child_tool_policy = @import("../tools/context.zig").ToolSetExecutionPolicy{
        .definitions = input.tool_defs_owned,
    };

    while (true) {
        // Degraded mode refreshes the complete locked snapshot each turn; when TinyKG is
        // authoritative mirror_path is null and this is a zero-cost no-op.
        sub_tasks.loadFromMirror() catch |err| {
            log.warn("swarm", "teammate task mirror refresh failed: {s}", .{@errorName(err)});
        };
        e.setStatus(.working);
        // 首轮此写与 spawn 的 addMember(is_active=true)重复,曾试图"只在值变化时写"去重——
        // 撤销(2026-07-18 实测):这次写恰好是 turn 前的天然停顿,满编 spawn 时把线程拖到
        // deinit 的 abort 之后,agent_loop turn 开始的 abort 检查得以生效;去重后线程立即
        // 进入**不可中断的 HTTP receiveHead**(慢 mock 下 deinit join 从 ~60s 恶化到 240s)。
        // 真正的修法是 abort 感知的 HTTP 等待(登记存量债);在那之前保留此写(也对齐 cc)。
        setMemberActiveBestEffort(a, e.config_path, e.name, input.session, true);

        const result = agent_loop.run(
            &conv,
            input.owned.provider(),
            input.tool_defs_owned,
            &ctx_override,
            .{
                .max_turns = if (input.max_turns_per_run > 0) input.max_turns_per_run else 20,
                .session = input.session,
                .system_prompt = if (input.system_prompt.len > 0) input.system_prompt else null,
                .abort = &e.abort,
                .api_client = input.owned.anthropicClient(),
                .tool_defs = input.tool_defs_owned,
                .agent_depth = 1, // teammate 不得再 spawn teammate(扁平 roster);Task 深度守卫沿用
                .dyn_registry = input.dyn_registry,
                .execution_policy = child_tool_policy.executionPolicy(),
                .host_services = input.host_services,
                .agent_jobs = null, // SW1 登记:teammate 无嵌套后台 job
                .project_dir = input.project_dir,
                .model_override = if (input.model_override) |m| m else null,
                .model_tiers = input.model_tiers,
                .tasks = &sub_tasks,
                .kg = kg_ptr,
                .kg_projects_dir = input.kg_projects_dir,
                .swarm = &teammate_sw, // teammate→lead/peer SendMessage(Linus/PM F1)
                .agent_ident = e.agent_ident, // 跨 turn 稳定(KG 租约连续)
                .kg_agent_ident = e.agent_id, // 与 tryClaimFrontierTask 的 name@team holder 完全一致
                .colorize = false,
                // task#12(Linus review):teammate Bash 继承父 sandbox(第三处后门堵上)。
                .sandbox = input.sandbox,
                .cwd_abs = input.cwd_abs,
                .home_dir = input.home_dir,
                .artifact_root = input.artifact_root,
                .tool_result_metrics = input.tool_result_metrics,
                .file_change_journal = input.file_change_journal,
                .additional_dirs = input.additional_dirs,
                .mcp_sessions = &input.mcp_sessions_owned,
            },
            &be,
            a,
        ) catch |err| {
            // 先放租约再翻 failed:failed 同样让 liveCount() 不再计入本 teammate,
            // lead 据此重派或收尸时租约必须已经不在 KG 里(理由同下方 terminated 路径)。
            releaseHeldTasks(e, kg_ptr); // 释放持有租约(PM F4/Linus M1:防卡 TTL)
            setMemberActiveBestEffort(a, e.config_path, e.name, input.session, false); // 先落盘再翻状态(#100)
            e.lockPublic();
            e.status = .failed;
            e.err_name = @errorName(err);
            e.unlockPublic();
            log.warn("swarm", "teammate {s} run failed: {s}", .{ e.agent_id, @errorName(err) });
            // 失败必须到达 lead 邮箱(PM F1:静默失败 = roster 里躺着一个与健康 idle
            // 无法区分的尸体;cc 同款发 idleReason:'failed'+failureReason)。
            sendIdleNotification(a, e, "failed", null, @errorName(err));
            input.cleanup();
            return;
        };

        e.lockPublic();
        e.turns_total += result.turns;
        e.runs_total += 1;
        // tokens 跨 run 累计:run 内 usage 事件是快照(最新覆盖),run 完把快照沉淀进基数
        // (Linus LOW-1:纯覆盖会让多 run teammate 只剩最后一轮的数)。
        e.tokens_base = e.tokens;
        e.unlockPublic();

        // abort 中断的 run:直接退出(deinit/kill 路径;保持静默——cc 的 interrupted
        // 通知对应单轮 Esc 交互,SW1 无此交互)。
        if (result.stop_reason == .aborted) break;

        // idle:翻牌 + 通知 lead。**软截断不得洗成 available**(Linus MED-1):end_turn
        // 才是"干完可接新活";max_turns/tool_loop/budget 等是"没干完",发 needs_continuation
        // + stopReason 让 lead 决定续跑/改派,而非误以为完工。
        // 与 terminated 同序(#100):先落盘 isActive=false,再翻 idle,再通知。
        setMemberActiveBestEffort(a, e.config_path, e.name, input.session, false);
        e.setStatus(.idle);
        switch (result.stop_reason) {
            .end_turn => sendIdleNotification(a, e, "available", null, null),
            // api_error 是失败不是截断(401/429/5xx 重试耗尽后正常返回此 reason,非 Zig error)。
            // 线程留在 idle-wait(可救:lead 可 shutdown 或修好后端后 nudge)。
            .api_error => sendIdleNotification(a, e, "failed", @tagName(result.stop_reason), null),
            else => sendIdleNotification(a, e, "needs_continuation", @tagName(result.stop_reason), null),
        }

        // 等下一轮工作(邮箱 + SW3 tinykg frontier 自领)。
        const next = waitForMail(a, e, kg_ptr, input.kg_projects_dir) orelse break;
        defer a.free(next);
        conv.appendText(.user, next) catch break;
    }

    // 先释放租约、先落盘,最后才翻 terminated。liveCount() 按 working/idle 计数,lead 一看到
    // "人没了"就可能重派或收尸;若此时租约还在 KG 里,它读到的是一个已退出 teammate
    // 卡着的叶子(#51 的 "退出但没释放"正是这个顺序造成的竞争,不是 releaseHeldTasks
    // 没生效)。config.json 同理(#100):观察到 terminated 的读者会紧接着 load config,
    // 若 isActive=false 还在写,Windows 上 renameReplace 的替换窗口会让它读到 null。
    // terminated 必须蕴含 "持有的租约已经放掉" 且 "config.json 的 isActive=false 已落盘"
    // (best-effort:写失败也不再重试,但此后不会再有写)。
    releaseHeldTasks(e, kg_ptr); // 退出前释放持有租约(PM F4/Linus M1:abort/shutdown 不卡 TTL)
    setMemberActiveBestEffort(a, e.config_path, e.name, input.session, false);
    e.setStatus(.terminated);
    input.cleanup();
}

// ============================================================================
// Tests(纯数据面;完整 spawn→idle→shutdown 链在 tests/component/teammate_runtime_test.zig)
// ============================================================================

const testing = std.testing;

test "TeammateRegistry init/deinit 空表干净" {
    var reg = try TeammateRegistry.init(testing.allocator, "k", null, "m", .anthropic, "/tmp");
    reg.deinit();
}

test "TeammateRegistry: 空 home 拒绝" {
    try testing.expectError(error.NoHome, TeammateRegistry.init(testing.allocator, "k", null, "m", .anthropic, ""));
}

test "snapshotRoster: 空表返回空;freeRoster 无泄漏" {
    var reg = try TeammateRegistry.init(testing.allocator, "k", null, "m", .anthropic, "/tmp");
    defer reg.deinit();
    const rows = try reg.snapshotRoster(testing.allocator);
    defer TeammateRegistry.freeRoster(testing.allocator, rows);
    try testing.expectEqual(@as(usize, 0), rows.len);
}

test "spawnTeammate: team 不存在 → TeamNotFound 且无残留 entry" {
    const a = testing.allocator;
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "/tmp/cc-zig-tm-noteam-{d}", .{util_time.nowNs()});
    defer @import("../util/fs.zig").testing.rmrfBestEffort(home);
    var reg = try TeammateRegistry.init(a, "k", null, "m", .anthropic, home);
    defer reg.deinit();

    const perm = permission_mod.createContext(.bypass_permissions, a);
    const empty_defs: []const json_mod.ToolDefinition = &.{};
    try testing.expectError(error.TeamNotFound, reg.spawnTeammate(.{
        .name = "bob",
        .team = "ghost",
        .prompt = "hi",
        .tool_defs = empty_defs,
        .permission_ctx = perm,
    }));
    try testing.expectEqual(@as(usize, 0), reg.entries.items.len);
}

test "nextClaimBackoffMs: 空手翻倍 2500→5000→10000→20000→cap 30000" {
    var b: i64 = SELF_CLAIM_POLL_MS;
    b = nextClaimBackoffMs(b);
    try std.testing.expectEqual(@as(i64, 5000), b);
    b = nextClaimBackoffMs(b);
    try std.testing.expectEqual(@as(i64, 10000), b);
    b = nextClaimBackoffMs(b);
    try std.testing.expectEqual(@as(i64, 20000), b);
    b = nextClaimBackoffMs(b);
    try std.testing.expectEqual(SELF_CLAIM_POLL_MAX_MS, b);
    // cap 后不再涨。
    try std.testing.expectEqual(SELF_CLAIM_POLL_MAX_MS, nextClaimBackoffMs(b));
}
