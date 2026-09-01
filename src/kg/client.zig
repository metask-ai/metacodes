//! TinyKG 集成客户端(设计:KG_DESIGN v3-final §1 D1/D2、§6)。
//!
//! tinykg = 跨会话真相源(记忆 + 计划任务 DAG),本模块是 metacodes 侧唯一入口。
//! 默认 transport 是 Metacodes-owned local authenticated TinyKG Web → one
//! tinykgd → one StoreActor；本地 CLI 只供显式 exclusive-store compatibility
//! 与隔离测试使用。TinyKG Skill 的远程配置属于跨设备长期记忆平面，本
//! runtime 客户端绝不隐式读取或复用它。
//!
//! 纪律(全部实证,见设计 §9 原语核对表):
//! - spawn 超时 35s **必须大于** tinykg 30s 目录锁超时——绝不在锁等待中 killpg
//!   制造无主锁(无主锁要等满 30s 才能被下一个调用者回收)。
//! - 版本门:store-info 的 storage_format_version 必须 = 3、schema_version 必须 = 3;
//!   manifest-less legacy store 在 host migration lock 下自动 copy-on-write 迁移并保留
//!   rollback backup；其它不匹配（包括 schema v2）仍明确 degraded。
//!   绝不用不匹配的二进制碰 store(格式 skew 实证:直接 FileNotFound/损坏风险)。
//! - degraded 后不再 spawn:后续调用直接返回降级说明(防反复失败撞熔断器)。
//! - KG 是增强非依赖:任何失败都不影响 metacodes 其余功能。
//!
//! 错误三类(设计 §6):transient(锁竞争/spawn 失败,重试 2 次)、
//! permanent(二进制缺/版本不符 → degraded)、data(环/NotFound → 透传模型改参)。

const std = @import("std");
const pfs = @import("platform").fs;
const time = @import("../util/time.zig");
const sync = @import("platform").sync;
const common = @import("../tools/common.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const log = @import("../util/log.zig");
const execution_knowledge = @import("execution_knowledge.zig");
const file_lock = @import("../util/file_lock.zig");
const transport_mod = @import("transport.zig");

pub const EXPECTED_STORAGE_FORMAT_VERSION = "3";
pub const EXPECTED_SCHEMA_VERSION = "3";
/// > tinykg 目录锁 30s 超时(cli.zig:1733-1857)。
pub const SPAWN_TIMEOUT_MS: u64 = 35_000;
const TRANSIENT_RETRIES: u32 = 2;
const TRANSIENT_RETRY_DELAY_MS: u64 = 200;

pub const KgError = error{
    /// 瞬时:锁竞争/spawn 失败,已重试仍失败。本次调用失败,session 不降级。
    Transient,
    /// 永久:二进制缺失/版本不符/init 失败。session 已标记 degraded。
    Degraded,
    /// 数据:环检测/NotFound 等,模型可改参重试。detail 在 last_detail。
    Data,
    /// 写请求只尝试一次且无法确认 commit 结果；request id 保留供宿主重观测。
    AmbiguousCommit,
    /// daemon 的有界队列已满；调用方应退避而不是扩大并发。
    Backpressure,
    /// 认证入口或 daemon 暂时不可达，禁止回退到 raw Store。
    DaemonUnavailable,
    OutOfMemory,
};

/// 记忆节点写入的 kind 白名单(core kind,不经 schema JSON;设计 §5)。
pub const MemoryKind = enum {
    observation,
    decision,
    user_preference,
    concept,

    pub fn label(self: MemoryKind) []const u8 {
        return @tagName(self);
    }
    pub fn parse(s: []const u8) ?MemoryKind {
        inline for (@typeInfo(MemoryKind).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const RecallHit = struct {
    node_id: u64,
    kind: []u8, // owned
    domain: []u8, // owned
    schema_type: []u8, // owned(记忆类型维度:decision/module/bug/…;list-recent 路径为空)
    text: []u8, // owned(UTF-8 head/tail excerpt)
    /// Authoritative node-text size before the client-side recall excerpt.
    /// The tool envelope uses this to distinguish a complete body from a
    /// bounded preview without asking TinyKG for the same node again.
    text_total_bytes: usize = 0,
    text_truncated: bool = false,
    score: f64,
    /// 来源记忆文件(md 派生 document 根带;section/typed 节点为空)。owned。
    source_label: []u8 = &.{},

    pub fn deinit(self: *const RecallHit, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.domain);
        allocator.free(self.schema_type);
        allocator.free(self.text);
        if (self.source_label.len > 0) allocator.free(self.source_label);
    }
};

/// 记忆类型 → (node kind, schema_type 标签)。**项目本体随项目深入演化**:项目可引入
/// 自定义类型(migration/gui_feature/schema_review…),落 **observation** node + 自定义
/// schema_type 区分——**不建新 node kind**(concept+schema_type 催收池转世,Linus BLOCKER)。
/// 内置基类型全局共用;自定义类型由 tinykg 的项目级 schema(schema-scope)按 project 治理隔离。
///
/// 规则:内置基类型(observation/decision/user_preference/module/bug)→ 固定映射;
///   concept → 仍拒绝(Linus BLOCKER);其余合法自定义类型 → observation + 该 schema_type;
///   空/非法字符/tinykg 保留字 → null(调用方拒绝,不静默)。大小写:基类型不敏感,自定义保留原样。
pub const ResolvedType = struct { node_kind: MemoryKind, schema_type: []const u8 };
pub fn resolveMemoryType(raw: []const u8) ?ResolvedType {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(t, "observation")) return .{ .node_kind = .observation, .schema_type = "observation" };
    if (std.ascii.eqlIgnoreCase(t, "decision")) return .{ .node_kind = .decision, .schema_type = "decision" };
    if (std.ascii.eqlIgnoreCase(t, "user_preference")) return .{ .node_kind = .user_preference, .schema_type = "user_preference" };
    if (std.ascii.eqlIgnoreCase(t, "module")) return .{ .node_kind = .observation, .schema_type = "module" };
    if (std.ascii.eqlIgnoreCase(t, "bug")) return .{ .node_kind = .observation, .schema_type = "bug" };
    if (std.ascii.eqlIgnoreCase(t, "concept")) return null; // concept kind 转世,仍拒绝
    // 项目级演化本体:允许自定义类型(observation node + 自定义 schema_type)。
    if (isValidCustomSchemaType(t)) return .{ .node_kind = .observation, .schema_type = t };
    return null; // 空 / 非法字符 / tinykg 保留字 → 拒绝
}

/// 自定义 schema_type 合法性:与 tinykg propertyKeyNameValid 对齐([A-Za-z0-9_-:.],长度 1-64),
/// 排除 tinykg 保留字(schema_scope=政策节点标识 / project=结构类型)。
fn isValidCustomSchemaType(t: []const u8) bool {
    if (t.len == 0 or t.len > 64) return false;
    if (std.mem.eql(u8, t, "schema_scope") or std.mem.eql(u8, t, "project")) return false;
    for (t) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-' or c == ':' or c == '.';
        if (!ok) return false;
    }
    return true;
}

pub const FrontierRow = struct {
    task_id: u64,
    status: TaskStatus = .open,
    readiness: Readiness,
    /// v2 深遍历角色:leaf=可执行叶子(child_task)/ branch=开放复合节点(branch_task,
    /// 有开放子任务,靠子树闭合而闭合)/ related=关联任务(related_task,单层)。
    role: Role = .leaf,
    depth: usize = 1,
    claimed_by: ?[]u8 = null, // owned;null=无主(行内 "-" 或租约已过期)
    path: ?[]u8 = null, // owned 面包屑(祖先链);null=根直下
    text: []u8, // owned(unescaped)

    pub const Readiness = enum { ready, blocked, missing_dependencies };
    pub const Role = enum { leaf, branch, related, failed, related_failed };

    pub fn deinit(self: *const FrontierRow, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.claimed_by) |c| allocator.free(c);
        if (self.path) |p| allocator.free(p);
    }
};

/// TinyKG 的 canonical task 生命周期。kind 与生命周期正交，task id 从创建到终态
/// 始终可用于 task-packet / task-ancestry。
pub const TaskStatus = enum {
    open,
    claimed,
    completed,
    failed,

    pub fn parse(raw: []const u8) ?TaskStatus {
        inline for (@typeInfo(TaskStatus).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn isTerminal(self: TaskStatus) bool {
        return self == .completed or self == .failed;
    }
};

/// argv 里给 store 路径预留的槽位,在 daemon 拥有 store 时填这个占位符。
/// 具名而非内联:此前它是散在两处的裸字面量,没有共享常量——对齐 CHAT_SENTINEL 的做法。
pub const DAEMON_OWNED_SLOT = "daemon-owned";

/// 本 client 的 Store 在哪。
///
/// **刻意不是一个 `[]const u8`**:CLI 传输下本 client 拥有磁盘上的 Store,daemon 传输下
/// Store 归 daemon,这里没有任何东西是文件系统位置。两种含义共用一个字符串字段,正是
/// issue #30 里占位符一路流进 `tinykg init` 的原因——类型不携带信息,安全就只能靠
/// 跨字段的远距离不变量维持,而编译器查不了那种不变量。
pub const StoreRef = union(enum) {
    /// 本 client 拥有的 Store 绝对路径(owned)。可建、可改名、可派生兄弟路径。
    owned: []u8,
    /// Store 归 daemon。**这里不是路径**,任何文件系统调用都不许拿到它。
    daemon_owned,

    /// CLI 为 store 路径预留的 argv 槽位。两种状态都合法——daemon 传输会在发送前
    /// 剥掉 argv[1]。
    pub fn argvSlot(self: StoreRef) []const u8 {
        return switch (self) {
            .owned => |p| p,
            .daemon_owned => DAEMON_OWNED_SLOT,
        };
    }

    /// 磁盘位置;本 client 不拥有 Store 时为 null。**所有**文件系统调用必须经由此处
    /// 并处理 null——这正是这个 union 存在的全部意义:把一条没人写下来的不变量,变成
    /// 编译器当场强制的局部约束。
    pub fn fsPath(self: StoreRef) ?[]const u8 {
        return switch (self) {
            .owned => |p| p,
            .daemon_owned => null,
        };
    }
};

pub const KgClient = struct {
    const Transport = union(enum) {
        daemon: transport_mod.WebTransport,
        exclusive_cli,
        unconfigured,
    };

    /// **内存契约(血泪,真模型 e2e 抓的进程级 panic)**:本 client 所有返回 owned 内存
    /// (frontier rows/fetchNodeText/recall hits/…)都以 `self.allocator` 分配,调用方必须用
    /// **kg.allocator** 释放。主循环里 ctx.allocator 恰好同源(App gpa)侥幸工作;subagent
    /// 后台线程的 ctx.allocator 是另一个 allocator——用它 free 会 ArenaAllocator null panic
    /// 杀整个进程。新增调用点一律 `deinit(kg.allocator)` / `kg.allocator.free(...)`。
    allocator: std.mem.Allocator,
    transport: Transport,
    /// tinykg 二进制绝对路径(owned)。null = 未解析到 → degraded。
    bin_path: ?[]u8 = null,
    /// Store 的位置。`.owned` 携带绝对路径(owned 内存),`.daemon_owned` 不是路径。
    /// 取 argv 槽位用 `store.argvSlot()`,取磁盘路径用 `store.fsPath()`(返回 optional)。
    store: StoreRef,
    /// 当前项目 domain id(owned)。跨项目记忆用 "global"。
    domain: []u8,
    /// 就绪:二进制存在 + store 可用 + 版本门通过。
    ready: bool = false,
    /// 降级原因(owned;ready=false 且非 null 时有效)。含修复提示。
    degraded_reason: ?[]u8 = null,
    /// 最近一次 data 类错误的 detail(owned,透传给模型)。
    last_detail: ?[]u8 = null,
    /// last_detail 的 alloc/free 配对锁(pthread,全仓惯例——裁剪版 std 无 Thread.Mutex)。
    /// 多 agent loop(后台 subagent 线程)共享同一 KgClient:两线程并发 setDetail 会读到
    /// 同一旧指针 → double-free。锁只护配对;detail() 返回借用切片,约定**失败调用同线程
    /// 立即消费**(跨线程读 detail 是 best-effort 错误文案,不做数据依赖)。store 一致性
    /// 由 tinykg CliStoreLock 保证,调用本身无需串行。
    detail_mu: sync.Mutex = .{},
    /// 缓存槽锁(project_node_id/global/miss/anchor_ids):多 subagent 线程共享本 client,
    /// ?u64 是 tag+payload 两次 store——无锁撕裂读会拿垃圾 id 去建边(挂错节点=数据损坏)。
    /// 纪律:锁只护槽读写,**绝不跨 spawn 持有**(子进程毫秒~秒级)。
    cache_mu: sync.Mutex = .{},
    /// project-containment(tinykg ce3a7f0 起):本项目 project 节点 id(session 内缓存;
    /// lazy find-or-create,写路径才建,读路径只 lookup)。null=未解析/库中无。
    project_node_id: ?u64 = null,
    /// 跨项目 "global" project 节点 id(用户偏好等 scope_global 记忆挂此)。
    global_project_node_id: ?u64 = null,
    /// negative cache:读路径 lookup 确认"库中无该 project 节点"(scoped 自动召回每 turn 跑,
    /// 不缓存 miss 每 turn 白烧 spawn)。写路径 ensure 成功 / attach 失败缓存失效时复位。
    /// **契约(session 级)**:别的 session 建了 project 节点后,本 session 读路径对它保持盲,
    /// 直到自己发生一次写(ensure 复位)或重启——接受的权衡,不是 bug。
    project_miss: bool = false,
    global_project_miss: bool = false,
    /// 演化本体 auto-scope:本 session 已声明 scope 的自定义 schema_type(避免每写起子进程)。
    /// key owned;cache_mu 保护(多 subagent 线程共享 client)。init 建、deinit 释放全部 key。
    scoped_types: std.StringHashMap(void) = undefined,
    /// 本 session 产出过 tentative 分类投影的任务 node（发现面:闭合投影是 agent 打的模糊分类,
    /// 人类需知道"有料可结晶"才会去 /kg refs 审阅/确认,否则 tentative 边永远无人 crystallize）。
    /// cache_mu 保护;over-inclusive 无害(是"去看看"的提示,真相以 /kg refs 当场查为准)。
    pending_ref_tasks: std.AutoHashMap(u64, void) = undefined,
    /// 宿主观测的成功执行事实。只保存 bounded task/relation/sanitized-label，
    /// 不保存命令、query、工具正文或结果；与其它 session 缓存共用 cache_mu，
    /// 因为主 loop 的 arena allocator 本身不保证多线程安全。
    execution_ledger: execution_knowledge.Ledger = undefined,
    /// project 三锚 id 缓存(乙方案):[scope_global 0/1][AnchorKind]。写路径 lazy ensure;
    /// 失效纪律同 project 缓存:挂接失败清对应槽,下次写重新 ensure(stale 自愈)。
    anchor_ids: [2][3]?u64 = .{ .{ null, null, null }, .{ null, null, null } },
    /// AutoMem 自动入图 session 内计数(PM P1:静默失败要有检视面;/kg 状态页展示)。
    autosync_ok: u32 = 0,
    autosync_fail: u32 = 0,
    /// 最近一次 autosync 失败摘要(owned;/kg 状态页展示)。
    autosync_last_err: ?[]u8 = null,
    /// abort 信号(M1:ESC 中断——穿进 spawn,避免锁竞争时最坏 13 分钟不可中断)。
    /// 借用,不拥有;工具/​/kg 调用前 setAbort。
    abort: ?*const AbortSignal = null,

    /// 设 abort 信号(工具执行前调;领域方法内的 spawn 据此可中断)。
    pub fn setAbort(self: *KgClient, abort: ?*const AbortSignal) void {
        self.abort = abort;
    }

    pub fn deinit(self: *KgClient) void {
        switch (self.transport) {
            .daemon => |*daemon| daemon.deinit(),
            .exclusive_cli, .unconfigured => {},
        }
        if (self.bin_path) |p| self.allocator.free(p);
        switch (self.store) {
            .owned => |p| self.allocator.free(p),
            .daemon_owned => {}, // 占位符是编译期常量,没有 owned 内存
        }
        self.allocator.free(self.domain);
        if (self.degraded_reason) |r| self.allocator.free(r);
        if (self.last_detail) |d| self.allocator.free(d);
        if (self.autosync_last_err) |e| self.allocator.free(e);
        var kit = self.scoped_types.keyIterator();
        while (kit.next()) |k| self.allocator.free(k.*);
        self.scoped_types.deinit();
        self.pending_ref_tasks.deinit();
        self.execution_ledger.deinit();
    }

    // ── 路径解析(设计 §1 D2)─────────────────────────────────────────

    pub const ResolveOptions = struct {
        home: []const u8,
        /// 项目 domain(调用方算好:git 根目录名+hash / cwd basename+hash)。
        domain: []const u8,
        /// config.json 的 kg_bin / kg_store(可空)。
        config_bin: ?[]const u8 = null,
        config_store: ?[]const u8 = null,
        /// 测试注入:覆盖 env 读取(null = 读真实 env)。
        env_bin: ?[]const u8 = null,
        env_store: ?[]const u8 = null,
        /// 测试注入:覆盖 exe 目录(null = selfExeDirPath 真实定位,不再依赖 argv[0])。
        exe_dir: ?[]const u8 = null,
        /// App supplies process IO for authenticated Web transport.
        io: ?std.Io = null,
        /// Test/config injection. Production normally reads these env vars.
        daemon_url: ?[]const u8 = null,
        daemon_api_key: ?[]const u8 = null,
        daemon_expected_build_id: ?[]const u8 = null,
        daemon_expected_schema_digest: ?[]const u8 = null,
        /// Explicit compatibility escape hatch. It must own an isolated Store.
        exclusive_cli: bool = false,
    };

    /// 解析 bin/store 路径并构造(不做 IO 探测;ensureReady 才探)。
    pub fn init(allocator: std.mem.Allocator, opts: ResolveOptions) !KgClient {
        const injected_cli = opts.exclusive_cli or opts.config_bin != null or opts.config_store != null or
            opts.env_bin != null or opts.env_store != null;
        const env_cli = if (envGet("METACODES_KG_TRANSPORT")) |mode|
            std.mem.eql(u8, mode, "cli-exclusive")
        else
            false;
        const use_cli = injected_cli or env_cli;
        // 只有拥有 Store 时才有路径可言。非 CLI 传输拿到的是 `.daemon_owned` 这个
        // **不是路径**的状态,而不是一个恰好长得像路径的字符串。
        const store: StoreRef = if (use_cli)
            .{ .owned = try resolveStorePath(allocator, opts) }
        else
            .daemon_owned;
        errdefer switch (store) {
            .owned => |p| allocator.free(p),
            .daemon_owned => {},
        };
        const domain = try allocator.dupe(u8, opts.domain);
        errdefer allocator.free(domain);
        const bin = if (use_cli) try resolveBinPath(allocator, opts) else null;
        const transport: Transport = if (use_cli)
            .exclusive_cli
        else daemon: {
            const io = opts.io orelse break :daemon .unconfigured;
            const configured = initDaemonTransport(allocator, io, opts) catch
                break :daemon .unconfigured;
            break :daemon if (configured) |value| .{ .daemon = value } else .unconfigured;
        };
        return .{
            .allocator = allocator,
            .transport = transport,
            .bin_path = bin,
            .store = store,
            .domain = domain,
            .scoped_types = std.StringHashMap(void).init(allocator),
            .pending_ref_tasks = std.AutoHashMap(u64, void).init(allocator),
            .execution_ledger = execution_knowledge.Ledger.init(allocator),
        };
    }

    /// 为工作线程克隆一个独立 KgClient(同 store/domain/bin,但**独立 allocator**)。
    /// 用途(Linus SW3 H1):swarm teammate 各线程定时 poll frontier/claim,共享一个 client 会在
    /// **非线程安全的 App arena** 上并发 alloc/free(runRaw dupeZ + frontier 行解析都在 self.allocator
    /// 外锁)→ 堆损坏。每线程一个 c_allocator 客户端隔离 arena;tinykg 的 store-dir 锁仍串行化跨
    /// 客户端的执行,数据一致。self 的 store/domain/bin_path init 后不可变,并发读安全。
    /// 返回的 client 由调用线程 own(deinit 释放);未 ensureReady——调用方自行 ensureReady。
    pub fn cloneForThread(self: *const KgClient, allocator: std.mem.Allocator, home: []const u8) !KgClient {
        if (self.transport == .daemon) {
            const domain = try allocator.dupe(u8, self.domain);
            errdefer allocator.free(domain);
            const daemon = try self.transport.daemon.cloneForSession(allocator);
            return .{
                .allocator = allocator,
                .transport = .{ .daemon = daemon },
                .bin_path = null,
                .store = .daemon_owned,
                .domain = domain,
                .scoped_types = std.StringHashMap(void).init(allocator),
                .pending_ref_tasks = std.AutoHashMap(u64, void).init(allocator),
                .execution_ledger = execution_knowledge.Ledger.init(allocator),
            };
        }
        // issue #30:此前这里只判 `.daemon`,于是 `.unconfigured` 客户端落到下面的
        // CLI 重建路径——把不拥有 Store 的 client 提升成 `.exclusive_cli`,并重新解析出
        // 一个真 bin_path。而"没有 bin 就没法把 store 当路径用"正是另外三处窄守卫赖以
        // 安全的前提,这里亲手把它补上了,占位符随即被当成相对路径跑 `tinykg init`。
        //
        // 不拥有 Store 的客户端,克隆体也不该凭空拥有一个:保持未配置,由调用方的
        // ensureReady 照常 degraded。
        const owned_store = self.store.fsPath() orelse {
            const domain = try allocator.dupe(u8, self.domain);
            errdefer allocator.free(domain);
            return .{
                .allocator = allocator,
                .transport = .unconfigured,
                .bin_path = null,
                .store = .daemon_owned,
                .domain = domain,
                .scoped_types = std.StringHashMap(void).init(allocator),
                .pending_ref_tasks = std.AutoHashMap(u64, void).init(allocator),
                .execution_ledger = execution_knowledge.Ledger.init(allocator),
            };
        };
        return KgClient.init(allocator, .{
            .home = home,
            .domain = self.domain,
            .config_bin = self.bin_path,
            .config_store = owned_store,
            .env_bin = "", // 屏蔽 env 重解析,直接用 self 已解析的路径
            .env_store = "",
            .exclusive_cli = true,
        });
    }

    /// 登记一个产出待确认分类的任务(发现面)。best-effort：OOM 静默丢(提示不是关键路径)。
    /// cache_mu 保护(多 subagent 线程共享 client)。
    pub fn notePendingRefTask(self: *KgClient, task_node: u64) void {
        self.cacheLock();
        defer self.cacheUnlock();
        self.pending_ref_tasks.put(task_node, {}) catch {};
    }

    /// 待确认分类任务的快照(owned slice，调用方 free）。空 = 本 session 无待审阅投影。
    pub fn pendingRefTasks(self: *KgClient, allocator: std.mem.Allocator) []u64 {
        self.cacheLock();
        defer self.cacheUnlock();
        const n = self.pending_ref_tasks.count();
        if (n == 0) return &.{};
        const out = allocator.alloc(u64, n) catch return &.{};
        var i: usize = 0;
        var it = self.pending_ref_tasks.keyIterator();
        while (it.next()) |k| : (i += 1) out[i] = k.*;
        return out;
    }

    /// Record only a host-authorized, successful tool invocation against the
    /// one active persistent task selected by the caller. This is best-effort:
    /// bounded drops are counted in the ledger and surfaced at task closure.
    pub fn observeSuccessfulExecution(
        self: *KgClient,
        task_id: u64,
        tool_name: []const u8,
        input_json: []const u8,
        project_dir: []const u8,
    ) void {
        self.cacheLock();
        defer self.cacheUnlock();
        self.execution_ledger.observeSuccessfulTool(task_id, tool_name, input_json, project_dir);
    }

    pub fn executionKnowledgeSnapshot(
        self: *KgClient,
        allocator: std.mem.Allocator,
        task_id: u64,
    ) !execution_knowledge.Snapshot {
        self.cacheLock();
        defer self.cacheUnlock();
        return self.execution_ledger.snapshot(allocator, task_id);
    }

    pub fn acknowledgeExecutionFact(
        self: *KgClient,
        task_id: u64,
        relation: execution_knowledge.Relation,
        value: []const u8,
    ) bool {
        self.cacheLock();
        defer self.cacheUnlock();
        return self.execution_ledger.acknowledge(task_id, relation, value);
    }

    pub fn pendingExecutionFacts(self: *KgClient, task_id: u64) usize {
        self.cacheLock();
        defer self.cacheUnlock();
        return self.execution_ledger.pendingForTask(task_id);
    }

    /// Store 路径必须是绝对的。相对路径会让 Store(以及由它派生的 backup/quarantine/
    /// lock/tmp 五个兄弟产物)落在**进程 cwd**——对一个会 chdir 或从任意目录启动的
    /// 进程来说,那是不可预测的位置。仓库在 workspace_policy / rule_evaluation /
    /// project_rule_bundle 等处都强制 isAbsolute,这里补齐同一条纪律。
    /// 注:末尾的默认值由 `opts.home` 拼出,home 本身为相对时同样拒绝。
    fn resolveStorePath(allocator: std.mem.Allocator, opts: ResolveOptions) ![]u8 {
        if (opts.env_store orelse envGet("METACODES_KG_STORE")) |v| {
            if (v.len > 0) return absoluteStorePath(allocator, v, opts.home);
        }
        if (opts.config_store) |v| {
            if (v.len > 0) return absoluteStorePath(allocator, v, opts.home);
        }
        const derived = try std.fmt.allocPrint(allocator, "{s}/.metacodes/kg/store.kg", .{opts.home});
        errdefer allocator.free(derived);
        if (!std.fs.path.isAbsolute(derived)) return error.RelativeStorePath;
        return derived;
    }

    /// 用户配置的 store 路径补全成绝对路径。
    ///
    /// **相对路径不报错**:`init` 的错误被唯一的生产调用方 `app.zig` `catch return`
    /// 静默吞掉,把一个可信的笔误(`kg_store: "store.kg"`)变成 KG 无声消失。本模块的
    /// 通行做法是 setDegraded 带修复提示,从不让 init 失败。
    ///
    /// 但也不能原样采用:相对值会让 Store 以及由它派生的五个兄弟产物(backup /
    /// quarantine / auto-migrate marker / md-import tmp / daemon lock)全部落在
    /// **进程 cwd**——对一个会从任意目录启动的进程,那是不可预测的位置。所以在解析
    /// 处就以 home 为基准补全,下游每一处使用都继承这个保证,无需各自再校验。
    fn absoluteStorePath(allocator: std.mem.Allocator, path: []const u8, home: []const u8) ![]u8 {
        if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
        const joined = try std.fs.path.join(allocator, &.{ home, path });
        errdefer allocator.free(joined);
        // home 自身是相对的话补全也救不回来(home 来自 OS,正常不会发生)。
        if (!std.fs.path.isAbsolute(joined)) return error.RelativeStorePath;
        log.warn("kg", "relative store path {s} resolved against home: {s}", .{ path, joined });
        return joined;
    }

    /// bin 查找顺序:env METACODES_KG_BIN > config kg_bin > 构建时 staged 的
    /// 相邻 `vendor/tinykg/tinykg`（由目标匹配的 checked-in bundle staged）。
    /// 没有 PATH、源码树或开发 checkout 回退。
    /// 每候选 access 检查,全失败返 null(→ ensureReady 判 degraded)。
    ///
    /// PM review 修:旧版① vendored 用调用方传的 exe_dir(argv[0] 派生),裸名经 PATH 启动
    /// 时 exe_dir=null → 跳过 vendored;② 相对偏移写死 `../vendor`,从 zig-out/bin 启动时
    /// 算成错误的 zig-out/vendor 位置→ 与 staged artifact 分离 → 静默
    /// 落到会漂移的 dev 树 → "dev degraded"。新版:selfExeDirPath 真实定位(不依赖 argv[0])
    /// + 向上逐级搜(兼容 zig-out/bin 与 <prefix>/bin 布局)+ dev 兜底改 opt-in(默认绝不静默落 dev)。
    fn resolveBinPath(allocator: std.mem.Allocator, opts: ResolveOptions) !?[]u8 {
        if (opts.env_bin orelse envGet("METACODES_KG_BIN")) |v| {
            if (v.len > 0 and isExecutable(v)) return try allocator.dupe(u8, v);
            if (v.len > 0) return null; // 显式指定但不可用 → 不静默回落,degraded 明示
        }
        if (opts.config_bin) |v| {
            if (v.len > 0 and isExecutable(v)) return try allocator.dupe(u8, v);
            if (v.len > 0) return null;
        }
        // staged:真实 exe 目录(opts.exe_dir 为测试注入覆盖;否则 OS 级 selfExeDir)
        // 只接受已声明的 install/eval 相邻布局，不做开放式祖先搜索。
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_dir: ?[]const u8 = opts.exe_dir orelse selfExeDir(&exe_buf);
        if (exe_dir) |dir| {
            if (try findStagedAdjacent(allocator, dir)) |p| return p;
        }
        return null;
    }

    /// OS 级真实 exe 目录(**不依赖 argv[0]**,PATH 裸名启动也可靠——修 exe_dir=null 静默落 dev
    /// 的根)。三 OS 实现收敛在 platform.paths.selfExePath(macOS/Linux/Windows),此处补
    /// realpath 解 symlink(安装常经 /usr/local/bin symlink)+ 取 dirname。失败 → null。
    fn selfExeDir(buf: []u8) ?[]const u8 {
        var raw: [std.fs.max_path_bytes]u8 = undefined;
        const exe_slice = @import("platform").paths.selfExePath(&raw) orelse return null;
        var exe_z_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (exe_slice.len >= exe_z_buf.len) return null;
        @memcpy(exe_z_buf[0..exe_slice.len], exe_slice);
        exe_z_buf[exe_slice.len] = 0;
        var rp: [std.fs.max_path_bytes]u8 = undefined;
        const resolved = pfs.realpath(@ptrCast(&exe_z_buf), &rp);
        const full: []const u8 = if (resolved != null) std.mem.span(resolved.?) else exe_slice;
        const dir = std.fs.path.dirname(full) orelse return null;
        if (dir.len == 0 or dir.len >= buf.len) return null;
        @memcpy(buf[0..dir.len], dir);
        return buf[0..dir.len];
    }

    /// 仅接受两种构建声明的布局：
    /// - `<prefix>/bin/metacodes` → `<prefix>/vendor/tinykg/tinykg`
    /// - `<prefix>/eval/bin/metacodes-*` → 同一 `<prefix>/vendor/...`
    /// 不继续走向任意祖先，避免系统 `/vendor` 或相邻项目冒充 staged artifact。
    fn stagedSearchRoots(start_dir: []const u8, roots: *[2][]const u8) usize {
        const parent = std.fs.path.dirname(start_dir) orelse return 0;
        roots[0] = parent;
        if (std.mem.eql(u8, std.fs.path.basename(parent), "eval")) {
            roots[1] = std.fs.path.dirname(parent) orelse return 1;
            return 2;
        }
        return 1;
    }

    fn findStagedAdjacent(allocator: std.mem.Allocator, start_dir: []const u8) !?[]u8 {
        const bin_name = if (@import("builtin").os.tag == .windows) "tinykg.exe" else "tinykg";
        var roots: [2][]const u8 = undefined;
        const root_count = stagedSearchRoots(start_dir, &roots);
        for (roots[0..root_count]) |root| {
            const cand = try std.fmt.allocPrint(allocator, "{s}/vendor/tinykg/{s}", .{ root, bin_name });
            if (isExecutable(cand)) return cand;
            allocator.free(cand);
        }
        return null;
    }

    fn envGet(name: [:0]const u8) ?[]const u8 {
        const v = std.c.getenv(name.ptr) orelse return null;
        return std.mem.span(v);
    }

    const DaemonFile = struct {
        url: []const u8,
        api_key: []const u8 = "",
        expected_build_id: ?[]const u8 = null,
        expected_schema_digest: []const u8 = "",
    };

    /// Resolve only the Metacodes-owned local daemon configuration.  The
    /// TinyKG Skill remote plane deliberately uses a different file and
    /// TINYKG_REMOTE_* namespace; inheriting either here would couple local
    /// runtime task/ontology state to cross-device long-term memory.
    ///
    /// METACODES_KG_* remains an all-or-nothing explicit injection surface for
    /// tests and deliberate debugging against another endpoint. It is never
    /// populated from the Skill's credential store.
    fn initDaemonTransport(
        allocator: std.mem.Allocator,
        io: std.Io,
        opts: ResolveOptions,
    ) !?transport_mod.WebTransport {
        const explicit_url = opts.daemon_url orelse envGet("METACODES_KG_URL");
        const explicit_key = opts.daemon_api_key orelse envGet("METACODES_KG_API_KEY");
        const explicit_build = opts.daemon_expected_build_id orelse envGet("METACODES_KG_EXPECTED_BUILD_ID");
        const explicit_schema = opts.daemon_expected_schema_digest orelse envGet("METACODES_KG_EXPECTED_SCHEMA_DIGEST") orelse "";
        if (explicit_url != null or explicit_key != null or explicit_build != null or explicit_schema.len != 0) {
            return @as(?transport_mod.WebTransport, try transport_mod.WebTransport.init(allocator, .{
                .io = io,
                .url = explicit_url orelse return error.InvalidRemoteConfiguration,
                .api_key = explicit_key orelse return error.InvalidRemoteConfiguration,
                .expected_build_id = explicit_build orelse return error.InvalidRemoteConfiguration,
                .expected_schema_digest = explicit_schema,
            }));
        }

        const env_config_path = envGet("METACODES_KG_CONFIG");
        const file_path = try daemonConfigPath(allocator, opts.home);
        defer allocator.free(file_path);
        const file = readDaemonConfig(allocator, file_path) catch |err| {
            // A user-selected config is authoritative and must fail closed;
            // the default path being absent means daemon mode is simply not
            // configured. Other open/stat failures remain unsafe.
            if (err == error.FileNotFound and env_config_path == null) return null;
            return err;
        };
        defer if (file) |*loaded| loaded.deinit();
        const file_value: DaemonFile = if (file) |loaded| loaded.value else return null;
        return @as(?transport_mod.WebTransport, try transport_mod.WebTransport.init(allocator, .{
            .io = io,
            .url = file_value.url,
            .api_key = file_value.api_key,
            .expected_build_id = file_value.expected_build_id orelse return error.InvalidRemoteConfiguration,
            .expected_schema_digest = file_value.expected_schema_digest,
        }));
    }

    fn daemonConfigPath(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
        if (envGet("METACODES_KG_CONFIG")) |path| return allocator.dupe(u8, path);
        return std.fmt.allocPrint(allocator, "{s}/.metacodes/kg/daemon.json", .{home});
    }

    const ParsedDaemonFile = std.json.Parsed(DaemonFile);

    fn readDaemonConfig(allocator: std.mem.Allocator, path: []const u8) !?ParsedDaemonFile {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
        if (fd < 0) {
            if (!pfs.exists(path_z.ptr)) return error.FileNotFound;
            return error.InvalidRemoteConfiguration;
        }
        defer pfs.close(fd);
        const info = pfs.fileInfo(fd) catch return error.InvalidRemoteConfiguration;
        if (!info.is_regular or info.link_count != 1 or info.size > 64 * 1024)
            return error.InvalidRemoteConfiguration;
        if (@import("builtin").os.tag != .windows and (info.mode & 0o077) != 0)
            return error.InvalidRemoteConfiguration;
        const bytes = common.readAllFromFdCapped(fd, allocator, 64 * 1024) catch
            return error.InvalidRemoteConfiguration;
        defer allocator.free(bytes);
        var parsed = std.json.parseFromSlice(DaemonFile, allocator, bytes, .{
            .ignore_unknown_fields = false,
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        }) catch return error.InvalidRemoteConfiguration;
        errdefer parsed.deinit();
        if (parsed.value.url.len == 0 or parsed.value.api_key.len == 0 or
            parsed.value.expected_build_id == null)
            return error.InvalidRemoteConfiguration;
        return parsed;
    }

    fn isExecutable(path: []const u8) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= buf.len) return false;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        // Windows:CRT _access 无 X_OK 概念(mode 1 非法)→ 存在即可执行(.exe 语义)。
        const mode: c_uint = if (@import("builtin").os.tag == .windows) std.c.F_OK else std.c.X_OK;
        return std.c.access(buf[0..path.len :0].ptr, mode) == 0;
    }

    // ── 就绪与版本门(设计 §1 D2、§6)────────────────────────────────

    /// 探测并建立就绪态:二进制存在 → store 存在(缺则 init)→ 版本门。
    /// 任何失败 → degraded(reason 含修复提示),**绝不 throw**——KG 是增强非依赖。
    pub fn ensureReady(self: *KgClient) void {
        if (self.ready) return;
        switch (self.transport) {
            .unconfigured => {
                self.setDegraded("Metacodes 本地 TinyKG daemon 未配置或配置不安全。写入 ~/.metacodes/kg/daemon.json（或 METACODES_KG_CONFIG），也可完整设置 METACODES_KG_URL/METACODES_KG_API_KEY/METACODES_KG_EXPECTED_BUILD_ID；TinyKG Skill remote.json 不属于本地 runtime，且共享 Store 禁止 CLI fallback", .{});
                return;
            },
            .daemon => |*daemon| {
                const result = daemon.run("store-info", &.{}, false) catch |err| {
                    self.setDegraded("TinyKG daemon preflight 失败: {s}；未打开本地 Store", .{@errorName(err)});
                    return;
                };
                defer result.deinit(self.allocator);
                if (result.exit_code != 0) {
                    self.setDegraded("TinyKG daemon store-info 失败: {s}", .{trimForLog(result.stderr)});
                    return;
                }
                const ver = extractInfoField(result.stdout, "storage_format_version") orelse "missing";
                const schema_ver = extractInfoField(result.stdout, "schema_version") orelse "missing";
                if (!std.mem.eql(u8, ver, EXPECTED_STORAGE_FORMAT_VERSION) or
                    !std.mem.eql(u8, schema_ver, EXPECTED_SCHEMA_VERSION))
                {
                    self.setDegraded("TinyKG daemon Store contract mismatch: storage={s} schema={s}", .{ ver, schema_ver });
                    return;
                }
                self.ready = true;
                log.info("kg", "ready transport=authenticated-web store=daemon-owned domain={s} generation={d}", .{ self.domain, result.generation });
                return;
            },
            .exclusive_cli => {},
        }
        const bin = self.bin_path orelse {
            self.setDegraded("tinykg 二进制未找到。只接受 METACODES_KG_BIN、config kg_bin 或构建时从 checked-in bundle staged 的 <prefix>/vendor/tinykg/tinykg。源码仓库不构建 TinyKG；见 doc/TINYKG_INTEGRATION.md", .{});
            return;
        };
        // 与 bin 同一套写法:在边界解包一次,往下传参。`.daemon_owned` 到这里就是矛盾
        // ——daemon 拥有 Store 的 client 不该走到 CLI 的建库路径上(issue #30 正是从
        // cloneForThread 把这种 client 提升成 .exclusive_cli 溜进来的)。失败关闭。
        const store = self.store.fsPath() orelse {
            // 措辞刻意避开 "未打开本地 Store"——那是 daemon preflight 那条消息的规则标记,
            // 复用会让它不再唯一:原消息被删掉时规则仍会因为这条而通过。
            self.setDegraded("内部状态矛盾:CLI 传输却不拥有 Store(store=daemon-owned);拒绝在当前目录建库", .{});
            return;
        };
        // store 缺 → init(先建父目录)。
        if (!dirExists(store)) {
            switch (self.recoverInterruptedAutoMigration(bin, store)) {
                .not_needed => {},
                .recovered => {},
                .failed => return,
            }
        }
        if (!dirExists(store)) {
            ensureParentDir(self.allocator, store) catch {};
            const out = self.runRaw(&.{ "init", store }) catch {
                self.setDegraded("tinykg init 失败(bin={s} store={s});检查磁盘/权限", .{ bin, store });
                return;
            };
            defer self.freeOut(out);
            if (out.exit_code != 0) {
                self.setDegraded("tinykg init 退出码 {d}: {s}", .{ out.exit_code, trimForLog(out.stderr) });
                return;
            }
        }
        // 版本门(含 legacy 自动 migrate)。
        if (!self.checkStoreVersionOrMigrate(bin, store)) return;
        // v42 连续性完整性门(导入侧):版本门只读头部元数据,损坏 store 能带着
        // 完好版本字段通过,然后在首个作用域读上全灭。深探针 + 隔离重建。
        if (!self.deepProbeOrQuarantine(bin, store)) return;
        self.ready = true;
        log.info("kg", "ready bin={s} store={s} domain={s}", .{ bin, store, self.domain });
    }

    /// 版本门检查;legacy store 自动 migrate 到 v2 后重新验证。true=通过,false=已 setDegraded。
    fn checkStoreVersionOrMigrate(self: *KgClient, bin: []const u8, store: []const u8) bool {
        const out = self.runRaw(&.{ "store-info", store }) catch {
            self.setDegraded("tinykg store-info 失败(bin={s} store={s})", .{ bin, store });
            return false;
        };
        defer self.freeOut(out);
        if (out.exit_code != 0) {
            self.setDegraded("tinykg store-info 退出码 {d}: {s}", .{ out.exit_code, trimForLog(out.stderr) });
            return false;
        }
        const ver = extractInfoField(out.stdout, "storage_format_version") orelse "missing";
        if (std.mem.eql(u8, ver, EXPECTED_STORAGE_FORMAT_VERSION)) {
            // Normal startup stays one subprocess: the same store-info already carries
            // schema_version. A second probe here doubled every session's KG startup cost.
            const schema_ver = extractInfoField(out.stdout, "schema_version") orelse "missing";
            if (!std.mem.eql(u8, schema_ver, EXPECTED_SCHEMA_VERSION)) {
                self.setDegraded(
                    "store schema 版本不符:期望 {s} 实际 {s}(store={s})。不要原地改 canonical store;请先运行 `tinykg migrate-store-v2 {s} <new-store> --task-status-v1 --verify`,核验后再切换 store",
                    .{ EXPECTED_SCHEMA_VERSION, schema_ver, store, store },
                );
                return false;
            }
            return true;
        }
        // storage_format 不符:仅 legacy 自动 migrate,其它版本直接 degraded
        if (!std.mem.eql(u8, ver, "legacy")) {
            self.setDegraded("store 格式版本不符:期望 {s} 实际 {s}(bin={s} store={s});手动跑 `tinykg upgrade {s} <new-store>` 核验后替换,见 deps/tinykg.json", .{ EXPECTED_STORAGE_FORMAT_VERSION, ver, bin, store, store });
            return false;
        }
        // legacy → current format 自动 migrate(本机 KG 是基础特性,不应让用户手动跑 tinykg 命令)
        if (!self.autoMigrateLegacyStore(store)) {
            self.setDegraded("store legacy→v2 自动 migrate 失败(bin={s} store={s});手动跑 `tinykg migrate-store-v2 {s} <new> --task-status-v1 --verify` 后替换", .{ bin, store, store });
            return false;
        }
        log.info("kg", "legacy→v2 自动 migrate 成功 store={s}", .{store});
        // autoMigrateLegacyStore only returns true after probeStore reopens canonical
        // and sees the exact 2/3 pair; do not add a third redundant subprocess here.
        return true;
    }

    /// v42 导入侧完整性门。背景(p41 取证):store-info 只读头部,一个被
    /// 压实/删除路径写坏的 store 带着完好版本字段通过版本门,随后会话内
    /// 所有作用域读写以 InvalidRecord 全灭——记忆系统静默死亡,且坏店经
    /// 连续性导出链传染全部后代 trial(15/16 失去记忆)。这里在版本门后用
    /// findProjectNode 的真实读形态(list-recent --kind project)做一次深
    /// 探针:data 类失败 = 店对本引擎确定性不可读 → 原子改名隔离(字节保
    /// 全,可取证)+ 重建空店(剂量由结局根在 ingest 重新摄取,损失有界);
    /// transient 失败不隔离(环境抖动不该核爆记忆)。返回 false 仅当隔离/
    /// 重建本身失败(已 setDegraded)。
    fn deepProbeOrQuarantine(self: *KgClient, bin: []const u8, store: []const u8) bool {
        const out = self.runRaw(&.{ "list-recent", store, "--kind", "project", "--limit", "200" }) catch {
            // spawn 失败是环境问题不是店问题:交给后续 op 的重试/降级路径。
            return true;
        };
        const exit_code = out.exit_code;
        const err_name_owned: ?[]u8 = if (exit_code != 0) self.allocator.dupe(u8, parseCliError(out.stderr)) catch null else null;
        self.freeOut(out);
        if (exit_code == 0) return true;
        const err_name: []const u8 = err_name_owned orelse "OutOfMemory";
        defer if (err_name_owned) |n| self.allocator.free(n);
        if (classifyCliError(err_name) != .data) {
            log.warn("kg", "store deep probe transient failure err={s}; not quarantining", .{err_name});
            return true;
        }
        // 与 migrate 共用 host lock:并发进程只允许一个执行隔离。
        var lock = self.acquireMigrationLock(store) catch |err| {
            self.setDegraded("store integrity quarantine lock failed: {s}(store={s})", .{ @errorName(err), store });
            return false;
        };
        defer lock.release();
        // 等锁期间另一进程可能已隔离并重建:重探针,通过即完成。
        if (self.runRaw(&.{ "list-recent", store, "--kind", "project", "--limit", "200" })) |re_out| {
            const re_exit = re_out.exit_code;
            self.freeOut(re_out);
            if (re_exit == 0) return true;
        } else |_| {}
        const ts: u64 = @intCast(@max(0, time.nowUnix()));
        const quarantine_path = std.fmt.allocPrint(self.allocator, "{s}.quarantined.{d}", .{ store, ts }) catch {
            self.setDegraded("store integrity quarantine path allocation failed(err={s} store={s})", .{ err_name, store });
            return false;
        };
        defer self.allocator.free(quarantine_path);
        if (!renamePath(store, quarantine_path)) {
            self.setDegraded("store integrity quarantine rename failed(err={s} store={s})", .{ err_name, store });
            return false;
        }
        log.warn("kg", "store integrity quarantine: deep probe failed err={s}; broken store preserved at {s}; initializing FRESH store (outcome-root re-ingest restores dose)", .{ err_name, quarantine_path });
        const init_out = self.runRaw(&.{ "init", store }) catch {
            self.setDegraded("post-quarantine tinykg init failed(bin={s} store={s})", .{ bin, store });
            return false;
        };
        defer self.freeOut(init_out);
        if (init_out.exit_code != 0) {
            self.setDegraded("post-quarantine tinykg init exit={d}: {s}", .{ init_out.exit_code, trimForLog(init_out.stderr) });
            return false;
        }
        return true;
    }

    const StoreProbe = enum { expected, legacy, incompatible, unavailable };
    const MigrationRecovery = enum { not_needed, recovered, failed };

    fn probeStore(self: *KgClient, path: []const u8) StoreProbe {
        const out = self.runRaw(&.{ "store-info", path }) catch return .unavailable;
        defer self.freeOut(out);
        if (out.exit_code != 0) return .unavailable;
        const storage_ver = extractInfoField(out.stdout, "storage_format_version") orelse return .incompatible;
        const schema_ver = extractInfoField(out.stdout, "schema_version") orelse return .incompatible;
        if (std.mem.eql(u8, storage_ver, EXPECTED_STORAGE_FORMAT_VERSION) and
            std.mem.eql(u8, schema_ver, EXPECTED_SCHEMA_VERSION)) return .expected;
        if (std.mem.eql(u8, storage_ver, "legacy")) return .legacy;
        return .incompatible;
    }

    fn migrationBackupPath(self: *KgClient, store: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}.legacy.bak", .{store});
    }

    fn migrationLockTarget(self: *KgClient, store: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}.metacodes-auto-migrate", .{store});
    }

    fn acquireMigrationLock(self: *KgClient, store: []const u8) !file_lock.Lock {
        const target = try self.migrationLockTarget(store);
        defer self.allocator.free(target);
        // tinykg subprocess timeout is 35s. The host lock must not be stolen while that
        // child is alive, while a crashed holder must still be recoverable within the
        // waiter's retry budget (~52s > 45s stale threshold).
        return file_lock.acquire(target, .{ .retries = 520, .stale_ms = 45_000 });
    }

    /// Crash recovery runs before `init`: if canonical disappeared after legacy→backup,
    /// resume TinyKG's idempotent migration rather than creating a new empty store.
    fn recoverInterruptedAutoMigration(self: *KgClient, bin: []const u8, store: []const u8) MigrationRecovery {
        const backup = self.migrationBackupPath(store) catch {
            self.setDegraded("legacy migrate recovery path allocation failed(store={s})", .{store});
            return .failed;
        };
        defer self.allocator.free(backup);
        if (!dirExists(backup)) return .not_needed;

        var lock = self.acquireMigrationLock(store) catch |err| {
            self.setDegraded("legacy migrate recovery lock failed: {s}(store={s})", .{ @errorName(err), store });
            return .failed;
        };
        defer lock.release();
        if (dirExists(store)) return .recovered; // another process completed while we waited
        if (self.probeStore(backup) != .legacy) {
            self.setDegraded("legacy migrate recovery found an incompatible rollback artifact(bin={s} backup={s})", .{ bin, backup });
            return .failed;
        }
        if (self.migrateBackupToCanonical(backup, store)) return .recovered;
        if (!dirExists(store)) {
            if (!renamePath(backup, store)) {
                self.setDegraded("legacy migrate recovery failed and rollback rename failed(bin={s} backup={s} store={s})", .{ bin, backup, store });
                return .failed;
            }
        }
        self.setDegraded("legacy migrate recovery failed; original store restored, automatic retry disabled for this session(bin={s} store={s})", .{ bin, store });
        return .failed;
    }

    /// legacy → v2/v3：先在 host lock 内把 canonical 原子改名为 rollback backup，
    /// 再让 TinyKG 自己从 backup 事务化发布 canonical target。这样只有一个 host rename，
    /// 发布、verify、staging recovery 仍由 TinyKG 原生实现；backup 始终保留可回滚原店。
    fn autoMigrateLegacyStore(self: *KgClient, store: []const u8) bool {
        var lock = self.acquireMigrationLock(store) catch return false;
        defer lock.release();

        // Another metacodes process may have completed while this one waited.
        switch (self.probeStore(store)) {
            .expected => return true,
            .legacy => {},
            else => return false,
        }
        const backup = self.migrationBackupPath(store) catch return false;
        defer self.allocator.free(backup);
        // Never rotate or overwrite an unknown rollback artifact automatically.
        if (dirExists(backup)) return false;
        if (!renamePath(store, backup)) return false;

        if (self.migrateBackupToCanonical(backup, store)) {
            log.info("kg", "auto migrate: verified legacy backup retained at {s}", .{backup});
            return true;
        }
        // A failed/timeout migration is allowed to have published already; only restore
        // when canonical is still absent. Never overwrite a possibly committed target.
        if (!dirExists(store)) _ = renamePath(backup, store);
        return false;
    }

    fn migrateBackupToCanonical(self: *KgClient, backup: []const u8, store: []const u8) bool {
        const out = self.runRaw(&.{ "migrate-store-v2", backup, store, "--task-status-v1", "--verify" }) catch {
            return self.probeStore(store) == .expected;
        };
        defer self.freeOut(out);
        if (out.exit_code != 0) {
            log.warn("kg", "auto migrate subprocess failed exit={d}: {s}", .{ out.exit_code, trimForLog(out.stderr) });
            return self.probeStore(store) == .expected;
        }
        return self.probeStore(store) == .expected;
    }

    /// 同父目录 rename；canonical 缺失时 POSIX/Windows 都是原子路径切换。
    fn renamePath(from: []const u8, to: []const u8) bool {
        var from_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        var to_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        if (from.len >= from_buf.len or to.len >= to_buf.len) return false;
        @memcpy(from_buf[0..from.len], from);
        from_buf[from.len] = 0;
        @memcpy(to_buf[0..to.len], to);
        to_buf[to.len] = 0;
        return pfs.renameReplace(@ptrCast(&from_buf), @ptrCast(&to_buf)) == 0;
    }

    fn setDegraded(self: *KgClient, comptime fmt: []const u8, args: anytype) void {
        self.ready = false;
        const reason = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        if (self.degraded_reason) |old| self.allocator.free(old);
        self.degraded_reason = reason;
        log.warn("kg", "degraded: {s}", .{reason});
    }

    /// degraded 时给工具层的结构化说明(borrow;调用方勿 free)。
    pub fn degradedMessage(self: *const KgClient) []const u8 {
        return self.degraded_reason orelse "KG 未就绪";
    }

    // ── project-containment(tinykg ce3a7f0:domain_id 移除,图拓扑隔离)────
    // 项目隔离 = project 节点 + contain 子树。写路径:节点创建后 govern-node --parent 挂接
    // (tinykg 已改增量 incremental_append,频繁写安全)。读路径:search/list-recent --project。

    /// 在库中按 text 精确匹配查 project 节点(list-recent --kind project)。找不到 → null。
    /// 读路径专用:绝不创建(否则 recall/facet 会污染库)。
    /// server-side 精确 lookup(tinykg `find <db> project <text>`,原始 text 索引查)。
    /// **不用 list-recent + 客户端比较**(Linus 严重2:TSV text 列是 escaped,basename 含
    /// ,/:/\ 的项目会永远失配 → 召回静默全灭 + 重复 project 节点无上限增殖;且 --limit 有
    /// 200 上限窗口)。只把 Data 类(空 store 等)视作"没有";Degraded/Transient 传播——
    /// 吞掉会把降级伪装成"库中无记忆"(版本门测试抓的正是这个静默)。
    fn lookupProjectNodeId(self: *KgClient, name: []const u8) KgError!?u64 {
        const out = self.runChecked(&.{ "find", self.store.argvSlot(), "project", name }) catch |e| switch (e) {
            KgError.Data => return null,
            else => return e,
        };
        defer self.freeOut(out);
        const line_end = std.mem.indexOfScalar(u8, out.stdout, '\n') orelse out.stdout.len;
        const line = std.mem.trim(u8, out.stdout[0..line_end], " \r\n");
        if (line.len == 0) return null; // find 未命中输出空
        var cols = std.mem.splitScalar(u8, line, '\t');
        const id_str = cols.next() orelse return null;
        return std.fmt.parseInt(u64, id_str, 10) catch null;
    }

    /// 解析(scope_global ? "global" : 本项目)的 project 节点 id。
    /// create=true(写路径):无则 **ensure-node 原子 find-or-create**(tinykg 单锁内,灭
    /// 客户端 lookup/create 两次调用的竞态=同名双 project 节点记忆永久分裂,Linus 严重3);
    /// create=false(读路径):无则返 null 并记 negative cache(scoped 自动召回每 turn 跑,
    /// 不缓存 miss 会每 turn 白烧 spawn,Linus 次要5;写路径 ensure 成功后清除)。
    fn cacheLock(self: *KgClient) void {
        _ = self.cache_mu.lock();
    }
    fn cacheUnlock(self: *KgClient) void {
        _ = self.cache_mu.unlock();
    }

    fn projectNodeId(self: *KgClient, scope_global: bool, create: bool) KgError!?u64 {
        const slot = if (scope_global) &self.global_project_node_id else &self.project_node_id;
        const miss = if (scope_global) &self.global_project_miss else &self.project_miss;
        {
            self.cacheLock();
            defer self.cacheUnlock();
            if (slot.*) |cached| return cached;
            if (!create and miss.*) return null; // negative cache:本 session 已确认无
        }
        const name = if (scope_global) "global" else self.domain;
        if (!create) {
            if (try self.lookupProjectNodeId(name)) |found| {
                self.cacheLock();
                defer self.cacheUnlock();
                slot.* = found;
                return found;
            }
            self.cacheLock();
            defer self.cacheUnlock();
            miss.* = true;
            return null;
        }
        const out = try self.runCheckedWrite(&.{
            "ensure-node", self.store.argvSlot(), "project", name, "--schema-type", "project",
        });
        defer self.freeOut(out);
        const id = parseNodeIdLine(out.stdout) orelse return self.dataError("ensure project 节点输出不可解析: {s}", .{trimForLog(out.stdout)});
        self.cacheLock();
        defer self.cacheUnlock();
        slot.* = id;
        miss.* = false;
        return id;
    }

    /// 把节点挂到 project 子树(govern-node --parent,tinykg 增量路径)。
    /// **必带 --schema-type**:govern-node 无此参数时会用 kind_label 覆盖 schema_type
    /// (module/bug 是 observation kind + schema_type 区分,漏传即类型信息丢失,实证)。
    /// govern 失败 → 清 project 缓存槽(可能是缓存的 project 节点已被 forget → NotFound;
    /// 不清则本 session 后续所有写全灭,Linus 严重4附赠)。
    /// project 三锚(乙方案):任务面/文档面/记忆面。成员挂各面的锚(或面内的根),
    /// 不再全部直挂 project——孤儿是一个极端,拍平直挂是另一个极端;membership
    /// 查询(search/list-recent --project)沿 composition 下钻,挂根即可达。
    pub const AnchorKind = enum(u2) {
        task,
        docs,
        memory,

        fn cliName(self: AnchorKind) []const u8 {
            return switch (self) {
                .task => "task",
                .docs => "docs",
                .memory => "memory",
            };
        }
    };

    /// schema_type → 归属面。任务类(todo/plan_step/inbox_root)→ task 锚;
    /// document → docs 锚;其余(记忆 schema_type,含 agent 自定义类型)→ memory 锚。
    /// **锋利边(Linus)**:新增任务类 schema_type 忘了加进这张表 → 该任务被静默归入
    /// memory 锚(frontier(task锚) 看不见它)。加任务类型必改此表,DoD 含 L2 断言。
    fn anchorForSchemaType(schema_type: []const u8) AnchorKind {
        if (std.mem.eql(u8, schema_type, "todo") or
            std.mem.eql(u8, schema_type, "plan_step") or
            std.mem.eql(u8, schema_type, "inbox_root")) return .task;
        if (std.mem.eql(u8, schema_type, "document")) return .docs;
        return .memory;
    }

    /// 锚 id 解析(lazy ensure + session 缓存)。ensure-anchor 是 tinykg 原子 find-or-create,
    /// 每类每 project 唯一由原语保证。
    fn ensureAnchorId(self: *KgClient, scope_global: bool, kind: AnchorKind) KgError!u64 {
        const slot = &self.anchor_ids[@intFromBool(scope_global)][@intFromEnum(kind)];
        {
            self.cacheLock();
            defer self.cacheUnlock();
            if (slot.*) |id| return id;
        }
        const pid = (try self.projectNodeId(scope_global, true)) orelse
            return self.dataError("project 节点解析失败({s} 锚不可得)", .{kind.cliName()});
        var pbuf: [24]u8 = undefined;
        const p_str = std.fmt.bufPrint(&pbuf, "{d}", .{pid}) catch unreachable;
        const out = try self.runCheckedWrite(&.{ "ensure-anchor", self.store.argvSlot(), p_str, kind.cliName() });
        defer self.freeOut(out);
        const id = parseNodeIdLine(out.stdout) orelse
            return self.dataError("ensure-anchor 输出不可解析: {s}", .{trimForLog(out.stdout)});
        // 双线程同 miss → 两次 ensure(幂等同 id)→ 谁后写都一样。锁只防撕裂。
        self.cacheLock();
        defer self.cacheUnlock();
        slot.* = id;
        return id;
    }

    fn invalidateAnchor(self: *KgClient, scope_global: bool, kind: AnchorKind) void {
        self.cacheLock();
        defer self.cacheUnlock();
        self.anchor_ids[@intFromBool(scope_global)][@intFromEnum(kind)] = null;
        // project id 也可能 stale(锚失效常因整店重写)——连带清,下次写全链重 ensure。
        if (scope_global) {
            self.global_project_node_id = null;
            self.global_project_miss = false;
        } else {
            self.project_node_id = null;
            self.project_miss = false;
        }
    }

    /// task 锚 id(写路径 lazy ensure + 缓存)。12b:frontier/TaskList 的单一查询根
    /// ——锚=任务面总任务,深遍历一次看全(多计划树 + inbox todos)。
    pub fn ensureTaskAnchorId(self: *KgClient) KgError!u64 {
        return self.ensureAnchorId(false, .task);
    }

    fn attachToProject(self: *KgClient, node_id: u64, schema_type: []const u8, scope_global: bool) KgError!void {
        const kind = anchorForSchemaType(schema_type);
        const aid = try self.ensureAnchorId(scope_global, kind);
        var nbuf: [24]u8 = undefined;
        var abuf: [24]u8 = undefined;
        const n_str = std.fmt.bufPrint(&nbuf, "{d}", .{node_id}) catch unreachable;
        const a_str = std.fmt.bufPrint(&abuf, "{d}", .{aid}) catch unreachable;
        switch (kind) {
            // 任务面:锚=总任务,挂 canonical contain(frontier(锚) 可深遍历全览;
            // TinyKG 仍兼容旧 task→task contains)。contains 属于 markdown 有序组合。
            // add-edge 幂等(同 src/rel/dst 去重),schema_type 已在 add-node 时写。
            .task => {
                const out = self.runCheckedWrite(&.{ "add-edge", self.store.argvSlot(), a_str, "contain", n_str }) catch |e| {
                    self.invalidateAnchor(scope_global, kind);
                    return e;
                };
                self.freeOut(out);
            },
            // 文档/记忆面:治理归属 contain(govern-node 同时写 schema_type 属性)。
            .docs, .memory => {
                const out = self.runCheckedWrite(&.{
                    "govern-node", self.store.argvSlot(), n_str, "--parent", a_str, "--schema-type", schema_type,
                }) catch |e| {
                    self.invalidateAnchor(scope_global, kind);
                    return e;
                };
                self.freeOut(out);
            },
        }
        // **演化本体自动隔离(引入即 scope)**:项目 scope 下引入的自定义类型(非内置基类型),
        // 自动声明 scope 到当前 project(--if-absent,不覆盖已有;默认 report:类型归属其源 project、
        // 跨项目用由 governance 暴露,不硬拦 agent 写)。base 类型/global scope 保持全局共享。
        if (!scope_global and !isBaseMemoryType(schema_type)) {
            self.autoScopeCustomType(schema_type) catch |e| {
                // 自动 scope 失败不该让记忆写整体失败(隔离是增强,不是硬前提);记 warn 继续。
                log.warn("kg", "auto-scope custom type {s} failed: {s}", .{ schema_type, @errorName(e) });
            };
        }
    }

    /// 内置基类型(全局共用,不 auto-scope)。**单一真相源**:与 resolveMemoryType 的基类型
    /// 分支同表,避免双写漂移(Linus:双真相源风险)。
    const base_memory_types = [_][]const u8{ "observation", "decision", "user_preference", "module", "bug" };
    fn isBaseMemoryType(schema_type: []const u8) bool {
        for (base_memory_types) |b| if (std.mem.eql(u8, schema_type, b)) return true;
        return false;
    }

    /// 自定义类型 auto-scope 到当前 project(--if-absent 幂等,不覆盖已有 scope)。
    /// **默认 enforce=block(有牙齿)**:用户选严格精确=硬隔离。首次引入建 block 政策 scope 到源
    /// project;之后在别的 project 用同类型 → tinykg block-at-write 在 govern-node 阶段拒绝
    /// (SchemaProjectScopeViolation)→ remember 返带 node-id + /kg forget 引导的清晰错误。
    /// 消费侧因此活着:政策被 tinykg 写路径读回并强制,agent 当场收到反馈,不是"有账无牙"。
    /// session 缓存已声明的类型,避免每次写都起子进程(项目本体类型数有限,缓存命中率高)。
    fn autoScopeCustomType(self: *KgClient, schema_type: []const u8) KgError!void {
        {
            self.cacheLock();
            defer self.cacheUnlock();
            if (self.scoped_types.contains(schema_type)) return; // 本 session 已声明
        }
        const pid = (try self.projectNodeId(false, true)) orelse return; // 无 project 无从 scope
        var pbuf: [24]u8 = undefined;
        const p_str = std.fmt.bufPrint(&pbuf, "{d}", .{pid}) catch unreachable;
        const out = try self.runCheckedWrite(&.{
            "schema-scope", self.store.argvSlot(), schema_type, "--project", p_str, "--if-absent", "--enforce", "block",
        });
        self.freeOut(out);
        // 入 session 缓存(key 深拷贝,owned)。
        self.cacheLock();
        defer self.cacheUnlock();
        if (!self.scoped_types.contains(schema_type)) {
            const key = self.allocator.dupe(u8, schema_type) catch return;
            self.scoped_types.put(key, {}) catch self.allocator.free(key);
        }
    }

    /// `node <id>[ ...]` 行 → id(兼容 add-node `node 7` 与 ensure-node `node 7 created=1`)。
    fn parseNodeIdLine(stdout: []const u8) ?u64 {
        const line = std.mem.trim(u8, stdout, " \r\n");
        if (!std.mem.startsWith(u8, line, "node ")) return null;
        const rest = line["node ".len..];
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
    }

    // ── 领域方法(P1:记忆 + 注入)─────────────────────────────────────

    /// 写记忆节点。返回 node id。scope_global=true → 挂 "global" project 子树。
    /// 两步:add-node(orphan)→ govern-node 挂接(增量)。挂接失败报 data 错并带 node id
    /// (orphan 不进 --project 召回 = 静默丢失,必须让模型/用户可见可重试)。
    pub fn remember(self: *KgClient, kind: MemoryKind, text: []const u8, schema_type: []const u8, scope_global: bool) KgError!u64 {
        const out = try self.runCheckedWrite(&.{
            "add-node", self.store.argvSlot(), kind.label(), text, "--schema-type", schema_type,
        });
        defer self.freeOut(out);
        const id = parseNodeIdLine(out.stdout) orelse return self.dataError("add-node 输出不可解析: {s}", .{trimForLog(out.stdout)});
        self.attachToProject(id, schema_type, scope_global) catch |e| {
            // **所有分支重包 detail 带 node id**(Linus 严重4:Data 分支的 last_detail 是 tinykg
            // 裸 stderr,无孤儿 id,模型无法 /kg forget;重试 remember = 每次新建节点 → 孤儿堆积)。
            const prior = if (self.last_detail) |d| d else "";
            // **项目级 schema 隔离命中**(PM 终审:block 默认不该留孤儿)。tinykg block-at-write 拒绝
            // = 该类型属于别的 project,本 project 不可用。**自动 forget 刚建的孤儿**(不累积),
            // 给点名类型+隔离原因的可行动错误(比裸 SchemaProjectScopeViolation 清晰)。
            if (std.mem.indexOf(u8, prior, "SchemaProjectScopeViolation") != null) {
                self.forget(id) catch {}; // best-effort 清理,失败也不掩盖主错误
                return self.dataError("类型 '{s}' 是别的 project 的专属本体,本 project 不可用(严格精确隔离,无继承)。已自动清理未挂接节点 {d}。改用内置类型(observation/decision/…)或换一个本 project 的类型名", .{ schema_type, id });
            }
            return self.dataError("记忆节点 {d} 已建但挂接项目失败({s}: {s})。请勿整体重试(会重复建节点);可 /kg forget {d} 清理后重试", .{ id, @errorName(e), prior, id });
        };
        return id;
    }

    // ── markdown 文档(P3:plan 人类可见,设计 D3)────────────────────
    // import-md-doc 把 markdown 存成图(document+section+md:* 投影);render-md-doc 无损渲染回
    // markdown。图与文档同源两视图(实证)。
    //
    // **关键(Linus 抓的确定性 bug)**:tinykg 按 source path 派生 external_key,同 key 再导入走
    // **增量合并**——复用旧投影边并**保留其陈旧 order_key**,新边填空槽 → 兄弟节点 order_key 撞车
    // (schema_duplicate_order_key)→ render 用 edge_id 兜底排序 → 步骤**乱序**。所以每份**不同**
    // 计划必须走干净全新导入:tmp 路径带**内容 hash 后缀**→ 不同内容不同 path 不同 doc(单调
    // order_key);相同内容同 path → tinykg 真幂等(document_created=false, nodes_imported=0)。
    // 代价:不同计划迭代留旧 document 成孤儿,可 gc-md-orphans 清(低频,可接受)。

    /// 把 markdown 文本导入成文档图,返回 document node id。写临时 .md 文件喂 import-md-doc
    /// (它只接文件路径,不接 stdin)。best-effort:失败返 data 错。
    /// **content-hash 版(plan 用,render 顺序敏感)**:不同内容→不同 path→全新 document
    /// (避开增量合并 order_key 撞车致 render 乱序);相同内容→真幂等。
    pub fn importMarkdownDoc(self: *KgClient, markdown: []const u8) KgError!u64 {
        const content_hash = std.hash.Wyhash.hash(0x7ac3, markdown);
        return self.importMarkdownDocAt(markdown, content_hash, true);
    }

    /// **稳定 key 版(记忆文件用,Linus BLOCKER 修)**:同 key(如文件路径 hash)→ 同 source
    /// path → 同 external_key → tinykg 真 upsert(增量合并,projection_edges_deleted 删旧投影)
    /// → 旧正文变孤儿退出 --project membership,**召回永远只见最新版**。
    /// 为何不能用 content-hash 版 + 删旧 doc:每次编辑产生全新 document,且 import 按 text 复用
    /// section 节点(实证 "## root cause" 跨版本共享),共享节点持旧 md:* 出边把旧正文接进新
    /// 子树——删旧 doc 根也断不开。稳定 upsert 让 tinykg 自己替换投影边,才是干净语义。
    /// 代价:order_key 撞车乱 render 顺序——记忆召回不 render(真相在磁盘 md 文件),无影响。
    pub fn importMarkdownDocStable(self: *KgClient, markdown: []const u8, stable_key: u64) KgError!u64 {
        return self.importMarkdownDocLabeled(markdown, stable_key, null);
    }

    /// 带来源标注版(autosync 传记忆文件 basename;召回 hit / forget 可溯源)。
    pub fn importMarkdownDocLabeled(self: *KgClient, markdown: []const u8, stable_key: u64, source_label: ?[]const u8) KgError!u64 {
        return self.importMarkdownDocAtLabeled(markdown, stable_key, true, source_label);
    }

    /// 记忆文件删除语义(PM P0-2):同 stable_key 空内容 upsert → tinykg 增量合并把旧投影边
    /// 全删(projection_edges_deleted,实证)→ 旧正文孤儿退出召回。document 空壳留图但无正文
    /// 不可召回。不 attach(从未入图的文件清空时,新建的空壳保持 orphan 不进任何视图)。
    pub fn clearMarkdownDocStable(self: *KgClient, stable_key: u64) KgError!void {
        _ = try self.importMarkdownDocAt("", stable_key, false);
    }

    /// autosync 结果计数(检视面:/kg 状态页"记忆同步"行)。err_name=null 表示成功。
    pub fn noteAutosync(self: *KgClient, err_name: ?[]const u8, file_base: []const u8) void {
        if (err_name) |en| {
            self.autosync_fail += 1;
            const msg = std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ en, file_base }) catch return;
            if (self.autosync_last_err) |old_e| self.allocator.free(old_e);
            self.autosync_last_err = msg;
        } else {
            self.autosync_ok += 1;
        }
    }

    /// 跑 tinykg gc-md-orphans(清 upsert 产生的孤儿 markdown 派生节点)。apply=false 干跑。
    /// 返回 tinykg 输出摘要(owned)。
    pub fn gcMdOrphans(self: *KgClient, apply: bool) KgError![]u8 {
        const out = if (apply)
            try self.runCheckedWrite(&.{ "gc-md-orphans", self.store.argvSlot(), "--apply" })
        else
            try self.runChecked(&.{ "gc-md-orphans", self.store.argvSlot() });
        defer self.freeOut(out);
        return self.allocator.dupe(u8, std.mem.trim(u8, out.stdout, " \r\n")) catch KgError.OutOfMemory;
    }

    fn importMarkdownDocAt(self: *KgClient, markdown: []const u8, path_key: u64, attach: bool) KgError!u64 {
        return self.importMarkdownDocAtLabeled(markdown, path_key, attach, null);
    }

    fn importMarkdownDocAtLabeled(self: *KgClient, markdown: []const u8, path_key: u64, attach: bool, source_label: ?[]const u8) KgError!u64 {
        if (self.transport == .daemon) {
            const result = self.transport.daemon.importMarkdown(markdown, path_key, source_label) catch |err|
                return self.mapTransportError(err);
            defer result.deinit(self.allocator);
            if (result.exit_code != 0) {
                self.setDetail("{s}", .{trimForLog(result.stderr)});
                return KgError.Data;
            }
            const doc_id = extractKvU64(result.stdout, "document=") orelse
                return self.dataError("import-md-doc 输出无 document id: {s}", .{trimForLog(result.stdout)});
            if (!attach) return doc_id;
            self.attachToProject(doc_id, "document", false) catch |e| {
                const prior = if (self.last_detail) |d| d else "";
                return self.dataError("document {d} 已导入但挂接项目失败({s}: {s})。可 /kg forget {d}", .{ doc_id, @errorName(e), prior, doc_id });
            };
            return doc_id;
        }
        // 临时文件与 Store 同级(`{store}.mdimport.*.tmp`),所以必须先确认本 client 真的
        // 拥有 Store——否则这一行会在进程 cwd 里落文件。顺带纠正了顺序:原先文件先写出去,
        // ready 检查要到下面 runCheckedWrite 里才发生。
        const store = self.store.fsPath() orelse return KgError.Degraded;
        const tmp_path = std.fmt.allocPrint(self.allocator, "{s}.mdimport.{x}.tmp", .{ store, path_key }) catch return KgError.OutOfMemory;
        defer self.allocator.free(tmp_path);
        writeTmpFile(self.allocator, tmp_path, markdown) catch return self.dataError("写 md 临时文件失败", .{});
        defer deleteTmpFile(self.allocator, tmp_path);

        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);
        argv.appendSlice(self.allocator, &.{ "import-md-doc", store, tmp_path }) catch return KgError.OutOfMemory;
        if (source_label) |sl| argv.appendSlice(self.allocator, &.{ "--source-label", sl }) catch return KgError.OutOfMemory;
        const out = try self.runCheckedWrite(argv.items);
        defer self.freeOut(out);
        // stdout: `import_md_doc ... document=<id> nodes_imported=..`
        const doc_id = extractKvU64(out.stdout, "document=") orelse
            return self.dataError("import-md-doc 输出无 document id: {s}", .{trimForLog(out.stdout)});
        if (!attach) return doc_id;
        // 挂接 document 根进项目子树(section 后代经 md:* 投影边可达,search --project 的
        // membership 沿 composition 下钻)。upsert 重复挂接被 tinykg link 去重吸收。
        self.attachToProject(doc_id, "document", false) catch |e| {
            const prior = if (self.last_detail) |d| d else "";
            return self.dataError("document {d} 已导入但挂接项目失败({s}: {s})。可 /kg forget {d}", .{ doc_id, @errorName(e), prior, doc_id });
        };
        return doc_id;
    }

    /// 渲染 legacy markdown document artifact。任务进度投影不得走此入口。owned。
    pub fn renderMarkdownDoc(self: *KgClient, doc_id: u64) KgError![]u8 {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{doc_id}) catch unreachable;
        const out = try self.runChecked(&.{ "render-md-doc", self.store.argvSlot(), id_str });
        defer self.freeOut(out);
        return self.allocator.dupe(u8, out.stdout) catch KgError.OutOfMemory;
    }

    // ── 任务 DAG(P2:write-through + plan 落图 + 图驱动)──────────────
    // 契约见设计 §9 核对表:depends_on 串行、task-close 终态闭合且 task id/kind 稳定；
    // frontier 深遍历(可执行叶子集:branch/leaf/failed 角色 + canonical status +
    // 祖先聚合 readiness + path + claim 租约)。

    /// 建任务节点(schema_type=todo|plan_step)。返回 node id。best-effort provenance。
    /// 挂接进项目子树(list-recent --project / search --project 可见)。
    pub fn createTask(self: *KgClient, text: []const u8, schema_type: []const u8) KgError!u64 {
        const out = try self.runCheckedWrite(&.{
            "add-node", self.store.argvSlot(), "task", text, "--schema-type", schema_type,
        });
        defer self.freeOut(out);
        const id = parseNodeIdLine(out.stdout) orelse return self.dataError("createTask 输出不可解析: {s}", .{trimForLog(out.stdout)});
        self.attachToProject(id, schema_type, false) catch |e| {
            const prior = if (self.last_detail) |d| d else "";
            return self.dataError("任务节点 {d} 已建但挂接项目失败({s}: {s})。请勿整体重试;可 /kg forget {d}", .{ id, @errorName(e), prior, id });
        };
        return id;
    }

    /// 建**子**任务:挂父任务(canonical contain),**不**直挂 project/锚——归属经根传递
    /// (membership 下钻),直挂是拍平反模式。深树子任务/计划步骤/inbox todo 用此。
    pub fn createChildTask(self: *KgClient, parent_id: u64, text: []const u8, schema_type: []const u8) KgError!u64 {
        const out = try self.runCheckedWrite(&.{
            "add-node", self.store.argvSlot(), "task", text, "--schema-type", schema_type,
        });
        defer self.freeOut(out);
        const id = parseNodeIdLine(out.stdout) orelse return self.dataError("createChildTask 输出不可解析: {s}", .{trimForLog(out.stdout)});
        self.addEdge(parent_id, "contain", id) catch |e| {
            const prior = if (self.last_detail) |d| d else "";
            return self.dataError("子任务 {d} 已建但挂接父 {d} 失败({s}: {s})。请勿整体重试;可 /kg forget {d}", .{ id, parent_id, @errorName(e), prior, id });
        };
        return id;
    }

    /// 建边(contain/depends_on/blocks…)。环检测由 tinykg dag 层强制 → data 错透传。
    pub fn addEdge(self: *KgClient, src: u64, rel: []const u8, dst: u64) KgError!void {
        var sbuf: [24]u8 = undefined;
        var dbuf: [24]u8 = undefined;
        const s_str = std.fmt.bufPrint(&sbuf, "{d}", .{src}) catch unreachable;
        const d_str = std.fmt.bufPrint(&dbuf, "{d}", .{dst}) catch unreachable;
        const out = try self.runCheckedWrite(&.{ "add-edge", self.store.argvSlot(), s_str, rel, d_str });
        self.freeOut(out);
    }

    /// `edge <id>` 行 → edge id(add-edge 输出;幂等去重时也返已存在边 id)。
    fn parseEdgeIdLine(stdout: []const u8) ?u64 {
        const line = std.mem.trim(u8, stdout, " \r\n");
        if (!std.mem.startsWith(u8, line, "edge ")) return null;
        const rest = line["edge ".len..];
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
    }

    /// 分类性引用边(acts_on/uses/produces/about)+ 两态 state 标记(改动一/三)。
    /// **写入容忍模糊**:闭合投影默认 tentative(agent 执行中打的);人类确认/纠正后落 confirmed。
    /// 拿回 add-edge 返回的 edge id 后 set-edge-property state。
    /// state 是**一个 bit 的两态**(tentative|confirmed),不是连续置信度(禁)。
    /// 幂等:任务终态可能已发布，而闭合投影只写了一部分；甚至 add-edge
    /// 已成功但 set-edge-property 失败留下裸边。重试必须补齐缺失 state，
    /// tentative 只可升级为 confirmed，confirmed 绝不降级，也不叠重复边。
    pub fn addRefEdge(self: *KgClient, src: u64, rel: []const u8, dst: u64, confirmed: bool) KgError!void {
        if (try self.findEdge(src, rel, dst)) |existing| {
            return switch (existing.state) {
                .missing => self.setEdgeState(existing.id, confirmed), // repair a partial prior write
                .tentative => if (confirmed) self.setEdgeState(existing.id, true) else {},
                .confirmed => {}, // monotonic:agent retry never downgrades human confirmation
                .invalid => self.dataError("edge {d} 存在非法 state，拒绝覆盖", .{existing.id}),
            };
        }
        var sbuf: [24]u8 = undefined;
        var dbuf: [24]u8 = undefined;
        const s_str = std.fmt.bufPrint(&sbuf, "{d}", .{src}) catch unreachable;
        const d_str = std.fmt.bufPrint(&dbuf, "{d}", .{dst}) catch unreachable;
        const out = try self.runCheckedWrite(&.{ "add-edge", self.store.argvSlot(), s_str, rel, d_str });
        defer self.freeOut(out);
        const edge_id = parseEdgeIdLine(out.stdout) orelse return self.dataError("add-edge 输出不可解析: {s}", .{trimForLog(out.stdout)});
        try self.setEdgeState(edge_id, confirmed);
    }

    fn setEdgeState(self: *KgClient, edge_id: u64, confirmed: bool) KgError!void {
        var ebuf: [24]u8 = undefined;
        const e_str = std.fmt.bufPrint(&ebuf, "{d}", .{edge_id}) catch unreachable;
        const state: []const u8 = if (confirmed) "confirmed" else "tentative";
        const sp = try self.runCheckedWrite(&.{ "set-edge-property", self.store.argvSlot(), e_str, "state", state });
        self.freeOut(sp);
    }

    /// 人类背书一个既有分类(tentative→confirmed,改动三):**就地翻位**,不新建边。
    /// (add-edge 去重不可靠 → 必须先定位原边再翻,否则会留一条 tentative 加一条 confirmed。)
    pub fn confirmClassification(self: *KgClient, src: u64, rel: []const u8, dst: u64) KgError!void {
        const edge_id = try self.resolveEdgeId(src, rel, dst);
        try self.setEdgeState(edge_id, true);
    }

    /// find-or-create concept 节点(ref 边的目标:对象/方法/概念/产物)。返回 node id。
    /// 走 ensure-node concept <name>(kind+text 定身份,单锁内幂等)——**绕开 resolveMemoryType**
    /// (那个拒 concept 是**记忆 remember 路径**防催收池;投影目标是本体实体,concept 正确)。
    pub fn ensureConcept(self: *KgClient, name: []const u8) KgError!u64 {
        const out = try self.runCheckedWrite(&.{
            "ensure-node", self.store.argvSlot(), "concept", name, "--schema-type", "concept",
        });
        defer self.freeOut(out);
        return parseNodeIdLine(out.stdout) orelse self.dataError("ensure concept 输出不可解析: {s}", .{trimForLog(out.stdout)});
    }

    fn addKindNode(self: *KgClient, kind_label: []const u8, text: []const u8) KgError!u64 {
        const out = try self.runCheckedWrite(&.{ "add-node", self.store.argvSlot(), kind_label, text });
        defer self.freeOut(out);
        return parseNodeIdLine(out.stdout) orelse self.dataError("add-node {s} 输出不可解析: {s}", .{ kind_label, trimForLog(out.stdout) });
    }

    const RefEdgeState = enum { missing, tentative, confirmed, invalid };
    const RefEdgeMatch = struct { id: u64, state: RefEdgeState };

    /// 查 (src,rel,dst) 出边及其两态属性。null=无此边(非错误——供幂等探测,
    /// 不污染 last_detail)；
    /// 仅 subprocess/JSON 解析失败才返 error。**不能靠 add-edge 幂等**(去重按节点 external key,
    /// concept 节点未必有 → 盲加会重复建边)。**按 rel 过滤 neighbors**:只回该 rel 类的边,
    /// 高出度任务(结构边多)也不会把 ref 边挤出 --limit 预算(Linus #4)。
    fn findEdge(self: *KgClient, src: u64, rel: []const u8, dst: u64) KgError!?RefEdgeMatch {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{src}) catch unreachable;
        const out = try self.runChecked(&.{ "neighbors", self.store.argvSlot(), id_str, rel, "--limit", "200", "--format", "json" });
        defer self.freeOut(out);
        const Props = struct { state: ?[]const u8 = null };
        const Edge = struct { id: u64, rel: []const u8, dst: u64, props: Props = .{} };
        const Doc = struct { edges: []const Edge };
        const parsed = std.json.parseFromSlice(Doc, self.allocator, out.stdout, .{ .ignore_unknown_fields = true }) catch
            return self.dataError("findEdge 解析 neighbors 失败", .{});
        defer parsed.deinit();
        for (parsed.value.edges) |e| {
            if (e.dst != dst or !std.mem.eql(u8, e.rel, rel)) continue;
            const state: RefEdgeState = if (e.props.state) |value|
                if (std.mem.eql(u8, value, "tentative"))
                    .tentative
                else if (std.mem.eql(u8, value, "confirmed"))
                    .confirmed
                else
                    .invalid
            else
                .missing;
            return .{ .id = e.id, .state = state };
        }
        return null;
    }

    fn findEdgeId(self: *KgClient, src: u64, rel: []const u8, dst: u64) KgError!?u64 {
        const match = try self.findEdge(src, rel, dst);
        return if (match) |edge| edge.id else null;
    }

    /// 定位既有边 id(找不到 → data 错,带 src/rel/dst)。幂等探测用 findEdgeId。
    fn resolveEdgeId(self: *KgClient, src: u64, rel: []const u8, dst: u64) KgError!u64 {
        return (try self.findEdgeId(src, rel, dst)) orelse self.dataError("未找到边 {d} -{s}-> {d}", .{ src, rel, dst });
    }

    fn deleteEdge(self: *KgClient, edge_id: u64) KgError!void {
        var ebuf: [24]u8 = undefined;
        const e_str = std.fmt.bufPrint(&ebuf, "{d}", .{edge_id}) catch unreachable;
        const out = try self.runCheckedWrite(&.{ "delete-edge", self.store.argvSlot(), e_str });
        self.freeOut(out);
    }

    /// 人类纠正一个分类(改动四):**矛盾覆盖不并存** + 留痕(error_event→fix 审计对)。
    /// 旧边删除,新分类以 confirmed 落库;记 error_event(旧,derived_from 任务=来源)
    /// resolved_by fix(新)。复用既有 error_event/fix node kind + derived_from/resolved_by
    /// 关系,是**接线非新子系统**。幂等:old==new 退化为"确认"(仅翻 confirmed,不留错误痕)。
    pub fn correctClassification(
        self: *KgClient,
        task_node: u64,
        rel: []const u8,
        old_concept: u64,
        new_name: []const u8,
    ) KgError!void {
        // **先定位旧边**:旧分类不存在就直接报错,不创建任何新节点——否则 ensureConcept 已建的
        // 新 concept 会成零边孤儿(只能 gc 回收)。Linus #3。
        // 注:纠正**完全成功后**重跑同一命令会报"未找到边 old"(旧边已删)——这是安全的:数据已在
        // 正确终态,前置条件"旧分类存在"确实为假,非损坏。重试只在**部分失败**后幂等补齐。
        const old_edge = try self.resolveEdgeId(task_node, rel, old_concept);
        const new_concept = try self.ensureConcept(new_name);
        // old==new:这不是纠错而是确认(人类背书既有分类)——就地翻 confirmed,不写错误痕。
        if (old_concept == new_concept) {
            return self.setEdgeState(old_edge, true);
        }
        // **顺序 + 幂等**(非原子——每步独立子进程,任何一步可能瞬时失败被人类重试):
        // 1. 新分类以 confirmed 落库,**幂等**:若已存在(上次重试的半成品/裸边)只翻 confirmed,
        //    绝不盲 addRefEdge——add-edge 对 concept 节点不去重,盲加会在重试时叠出重复 confirmed 边
        //    (Linus #1/#2,直接违背"矛盾覆盖不并存")。
        if (try self.findEdgeId(task_node, rel, new_concept)) |existing| {
            try self.setEdgeState(existing, true);
        } else {
            try self.addRefEdge(task_node, rel, new_concept, true);
        }
        // 2. 删旧边(矛盾覆盖不并存)。到此新分类已在;删失败留"新 confirmed+旧 tentative"可辨并存,
        //    重试幂等完成(步骤1 探到新边不重复建,只补删)。
        try self.deleteEdge(old_edge);
        // 3. 审计对留痕(**纠正完成才记**,故中途失败不会留半截审计;重试成功后补齐)。
        //    best-effort:核心覆盖(1、2)已成,留痕失败不回滚。
        var tbuf: [512]u8 = undefined;
        const err_text = std.fmt.bufPrint(&tbuf, "misclassified: task {d} {s} concept {d} (corrected by human)", .{ task_node, rel, old_concept }) catch "misclassified (corrected)";
        const err_id = self.addKindNode("error_event", err_text) catch |e| {
            log.warn("kg", "correction audit: error_event 建节点失败(覆盖已成,仅缺留痕): {s}", .{@errorName(e)});
            return;
        };
        self.addEdge(err_id, "derived_from", task_node) catch |e|
            log.warn("kg", "correction audit: derived_from 边失败: {s}", .{@errorName(e)}); // 来源=任务闭合
        var fbuf: [512]u8 = undefined;
        const fix_text = std.fmt.bufPrint(&fbuf, "reclassified: task {d} {s} -> concept {d}", .{ task_node, rel, new_concept }) catch "reclassified";
        const fix_id = self.addKindNode("fix", fix_text) catch |e| {
            log.warn("kg", "correction audit: fix 建节点失败: {s}", .{@errorName(e)});
            return;
        };
        self.addEdge(err_id, "resolved_by", fix_id) catch |e|
            log.warn("kg", "correction audit: resolved_by 边失败: {s}", .{@errorName(e)});
    }

    /// 节点出边一览(neighbors 原文,owned)。溯源检视面:记忆/文档 derived_from 哪个任务。
    pub fn neighborsText(self: *KgClient, node_id: u64, limit: usize) KgError![]u8 {
        var idbuf: [24]u8 = undefined;
        var limbuf: [16]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{node_id}) catch unreachable;
        const lim_str = std.fmt.bufPrint(&limbuf, "{d}", .{limit}) catch unreachable;
        const out = try self.runChecked(&.{ "neighbors", self.store.argvSlot(), id_str, "--limit", lim_str });
        defer self.freeOut(out);
        return self.allocator.dupe(u8, out.stdout) catch KgError.OutOfMemory;
    }

    /// 节点出边 JSON(含边 props,即 state 两态位)。用于分类投影的检视/断言。
    pub fn neighborsJson(self: *KgClient, node_id: u64, limit: usize) KgError![]u8 {
        var idbuf: [24]u8 = undefined;
        var limbuf: [16]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{node_id}) catch unreachable;
        const lim_str = std.fmt.bufPrint(&limbuf, "{d}", .{limit}) catch unreachable;
        const out = try self.runChecked(&.{ "neighbors", self.store.argvSlot(), id_str, "--limit", lim_str, "--format", "json" });
        defer self.freeOut(out);
        return self.allocator.dupe(u8, out.stdout) catch KgError.OutOfMemory;
    }

    /// 取有界 task packet。终态 task 仍保持 kind=task，因此 fresh restart 后仍能按原 id
    /// 恢复目标、父子关系、依赖和 verified_by evidence。
    pub fn taskPacket(self: *KgClient, task_id: u64, limit: usize) KgError![]u8 {
        var idbuf: [24]u8 = undefined;
        var limbuf: [16]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{task_id}) catch unreachable;
        const lim_str = std.fmt.bufPrint(&limbuf, "{d}", .{limit}) catch unreachable;
        const out = try self.runChecked(&.{ "task-packet", self.store.argvSlot(), id_str, "--limit", lim_str });
        defer self.freeOut(out);
        return self.allocator.dupe(u8, out.stdout) catch KgError.OutOfMemory;
    }

    /// TinyKG snapshot commands frame their canonical JSON artifact on stdout
    /// as exactly `<artifact>` + one LF (documented CLI line framing; the
    /// artifact itself has no trailing newline). The framing byte is
    /// REQUIRED: stdout without it is not this CLI contract and returns null
    /// so the caller fails typed. Exactly one byte is stripped; any other
    /// suffix stays in the returned bytes so the downstream canonical-bytes
    /// check rejects it instead of this transport silently normalizing a
    /// corrupted wire.
    fn stripCliLineFraming(stdout: []const u8) ?[]const u8 {
        if (stdout.len < 1 or stdout[stdout.len - 1] != '\n') return null;
        return stdout[0 .. stdout.len - 1];
    }

    /// Fetch one bounded, deterministic task-subgraph snapshot under TinyKG's
    /// store lock. The JSON is intentionally left opaque here; the independent
    /// task_projection module owns schema and referential-integrity validation.
    pub fn taskSnapshot(self: *KgClient, root_id: u64) KgError![]u8 {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{root_id}) catch unreachable;
        const out = try self.runChecked(&.{
            "task-snapshot", self.store.argvSlot(), id_str,
            "--max-tasks",   "256",                 "--max-edges",
            "1024",          "--max-chars",         "200000",
        });
        defer self.freeOut(out);
        const snapshot = stripCliLineFraming(out.stdout) orelse
            return self.dataError("task-snapshot {d} 缺少 CLI LF 框架: {s}", .{ root_id, trimForLog(out.stdout) });
        if (snapshot.len < 2 or snapshot[0] != '{' or snapshot[snapshot.len - 1] != '}')
            return self.dataError("task-snapshot {d} 非 JSON object: {s}", .{ root_id, trimForLog(snapshot) });
        return self.allocator.dupe(u8, snapshot) catch KgError.OutOfMemory;
    }

    /// Fetch one bounded ontology snapshot for the isolated rule-author path.
    /// This is deliberately one TinyKG command: composing `list-recent` and
    /// `get --meta` in the host would cross store-lock/revision boundaries and
    /// manufacture a snapshot that TinyKG never observed atomically.
    pub fn ontologyRuleSnapshot(
        self: *KgClient,
        project_id: u64,
        expected_project_sha256: [64]u8,
        expected_project_key: []const u8,
    ) KgError![]u8 {
        if (project_id == 0 or expected_project_key.len == 0)
            return self.dataError("ontology-rule-snapshot project identity invalid", .{});
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{project_id}) catch unreachable;
        // 身份首次绑定(2026-08-18 selflearn 根因):tinykg 的快照命令要求
        // project 节点携 project_sha256/project_key 属性并与请求匹配,而
        // 本客户端建项目节点时从不写它们——真 store 上快照必拒(此前只在
        // mock 掉该命令的 pilot 里"通过")。store 为本项目私有,节点身份
        // 只可能由我们写入;恒等写入幂等,快照端仍做最终匹配校验。
        {
            const bind_sha = try self.runChecked(&.{
                "set-node-property", self.store.argvSlot(),        id_str,
                "project_sha256",    expected_project_sha256[0..],
            });
            self.freeOut(bind_sha);
            const bind_key = try self.runChecked(&.{
                "set-node-property", self.store.argvSlot(), id_str,
                "project_key",       expected_project_key,
            });
            self.freeOut(bind_key);
        }
        const out = try self.runChecked(&.{
            "ontology-rule-snapshot", self.store.argvSlot(),        id_str,
            "--project-sha256",       expected_project_sha256[0..], "--project-key",
            expected_project_key,     "--max-items",                "48",
            "--max-chars",            "200000",
        });
        defer self.freeOut(out);
        // This command's stdout is a canonical wire artifact plus the CLI's
        // mandatory single-LF line framing. Strip exactly that one framing
        // byte; a missing frame or any other suffix fails typed rather than
        // this transport silently normalizing bytes it will later hash.
        const snapshot = stripCliLineFraming(out.stdout) orelse
            return self.dataError(
                "ontology-rule-snapshot project={d} 缺少 CLI LF 框架: {s}",
                .{ project_id, trimForLog(out.stdout) },
            );
        if (snapshot.len < 2 or snapshot[0] != '{' or snapshot[snapshot.len - 1] != '}')
            return self.dataError(
                "ontology-rule-snapshot project={d} 非 JSON object: {s}",
                .{ project_id, trimForLog(snapshot) },
            );
        return self.allocator.dupe(u8, snapshot) catch KgError.OutOfMemory;
    }

    /// 写入一条受治理的本体条目(add-node + 三治理属性 + attach,单事务
    /// 语义)。tinykg 快照只导出 schema_type ∈ {proposition,prescription,
    /// concept,intent} 且 authority/falsifier/provenance 三属性齐全的节点;
    /// 缺属性对快照是**整体报错**而非跳过,而 schema_type 不可事后翻转
    /// (实测:set-node-property 值校验器无此分支,有意为之)。
    /// **attach 必须最后做(commit point)**:快照候选集=项目子树,未挂接
    /// 节点对投影不可见——进程在属性写完前被 SIGKILL(harness 超时杀)
    /// 只会留下一个不可见孤儿,而不是随 continuity 链传播、毒化所有后续
    /// 快照的裸 proposition。errdefer forget 兜其余失败路径。
    /// provenance 自引用该节点(存在性校验要求 ref 在库内),evidence 为
    /// 节点正文 sha256——host 观测记录的来源就是它自己的采集内容。
    pub fn rememberOntologyItem(
        self: *KgClient,
        text: []const u8,
        ontology_kind: []const u8,
        authority: []const u8,
        falsifier: []const u8,
        evidence_sha256_hex: *const [64]u8,
    ) KgError!u64 {
        const add_out = try self.runCheckedWrite(&.{
            "add-node", self.store.argvSlot(), MemoryKind.observation.label(), text, "--schema-type", ontology_kind,
        });
        const id = parseNodeIdLine(add_out.stdout) orelse {
            self.freeOut(add_out);
            return self.dataError("add-node 输出不可解析(本体条目)", .{});
        };
        self.freeOut(add_out);
        errdefer self.forget(id) catch {};
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{id}) catch unreachable;
        var prov_buffer: [256]u8 = undefined;
        const provenance = std.fmt.bufPrint(
            &prov_buffer,
            "{{\"schema_version\":\"tinykg-ontology-provenance-v1\",\"refs\":" ++
                "[{{\"kind\":\"host_observation\",\"node_id\":{d},\"evidence_sha256\":\"{s}\"}}]}}",
            .{ id, evidence_sha256_hex[0..] },
        ) catch unreachable;
        const steps = [_][2][]const u8{
            .{ "ontology_authority", authority },
            .{ "ontology_falsifier", falsifier },
            .{ "ontology_provenance", provenance },
        };
        for (steps) |step| {
            const out = try self.runChecked(&.{
                "set-node-property", self.store.argvSlot(), id_str, step[0], step[1],
            });
            self.freeOut(out);
        }
        // commit point:挂进项目子树,条目自此对快照可见(且三属性已齐)。
        try self.attachToProject(id, ontology_kind, false);
        return id;
    }

    /// Identity of the TinyKG control plane that produced canonical snapshot
    /// artifacts.  Exclusive mode hashes the actual executable; daemon mode
    /// returns the authenticated build pin used for every request.  Keeping
    /// this transport-neutral is required for ontology governance to work
    /// with multiple Metacodes clients behind one tinykgd StoreActor.
    pub fn controlPlaneBuildSha256(self: *KgClient) KgError![64]u8 {
        return switch (self.transport) {
            .daemon => |*daemon| daemon.buildSha256() catch KgError.Degraded,
            .exclusive_cli => self.binarySha256(),
            .unconfigured => KgError.Degraded,
        };
    }

    /// Content identity used by read-only control-plane adapters. The file is
    /// opened without following the final symlink and hashed from one stable
    /// descriptor; callers still re-hash after the child exits to detect a
    /// same-path replacement during the operation.
    pub fn binarySha256(self: *KgClient) KgError![64]u8 {
        const bin = self.bin_path orelse return KgError.Degraded;
        const path = self.allocator.dupeZ(u8, bin) catch return KgError.OutOfMemory;
        defer self.allocator.free(path);
        const fd = pfs.open(path.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
        if (fd < 0) return KgError.Degraded;
        defer _ = pfs.close(fd);
        const before = pfs.fileInfo(fd) catch return KgError.Transient;
        if (!before.is_regular or before.size == 0 or before.size > 128 * 1024 * 1024)
            return KgError.Degraded;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buffer: [64 * 1024]u8 = undefined;
        var observed: u64 = 0;
        while (true) {
            const count = pfs.read(fd, &buffer);
            if (count < 0) return KgError.Transient;
            if (count == 0) break;
            const used: usize = @intCast(count);
            observed = std.math.add(u64, observed, used) catch return KgError.Degraded;
            if (observed > before.size) return KgError.Degraded;
            hasher.update(buffer[0..used]);
        }
        const after = pfs.fileInfo(fd) catch return KgError.Transient;
        if (!after.is_regular or after.size != before.size or observed != before.size or
            after.device != before.device or after.inode != before.inode)
            return KgError.Transient;
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        return std.fmt.bytesToHex(digest, .lower);
    }

    /// Read-only project lookup for host control-plane adapters.  It never
    /// creates a project node: ontology/rule evolution must not mutate TinyKG
    /// merely because an evaluation trigger fired.
    pub fn existingProjectNodeId(self: *KgClient) KgError!?u64 {
        return self.projectNodeId(false, false);
    }

    /// Fresh read-only lookup for governance snapshots. Unlike ordinary
    /// recall, this deliberately bypasses the session negative cache because
    /// another Metacodes process may have created the project through the
    /// shared daemon since the last lookup.
    pub fn reobserveExistingProjectNodeId(self: *KgClient) KgError!?u64 {
        const found = try self.lookupProjectNodeId(self.domain);
        self.cacheLock();
        defer self.cacheUnlock();
        self.project_node_id = found;
        self.project_miss = found == null;
        return found;
    }

    /// Stable project key already selected by App/KgClient initialization.
    /// Borrowed for the client lifetime.
    pub fn projectKey(self: *const KgClient) []const u8 {
        return self.domain;
    }

    /// Agent-facing bounded packet. Unlike the text packet used by taskStatus,
    /// this returns TinyKG's metadata-first JSON envelope: parent goal,
    /// dependencies, evidence links, truncation diagnostics and continuations,
    /// without dumping every node body into the model context.
    pub fn taskPacketMeta(
        self: *KgClient,
        task_id: u64,
        limit: usize,
        max_chars: usize,
    ) KgError![]u8 {
        var idbuf: [24]u8 = undefined;
        var limbuf: [16]u8 = undefined;
        var charsbuf: [16]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{task_id}) catch unreachable;
        const lim_str = std.fmt.bufPrint(&limbuf, "{d}", .{limit}) catch unreachable;
        const chars_str = std.fmt.bufPrint(&charsbuf, "{d}", .{max_chars}) catch unreachable;
        const out = try self.runChecked(&.{
            "task-packet", self.store.argvSlot(), id_str,
            "--limit",     lim_str,               "--format",
            "json",        "--meta",              "--max-nodes",
            "16",          "--max-edges",         "24",
            "--max-chars", chars_str,
        });
        defer self.freeOut(out);
        const packet = std.mem.trim(u8, out.stdout, " \r\n\t");
        if (packet.len < 2 or packet[0] != '{' or packet[packet.len - 1] != '}')
            return self.dataError("task-packet meta {d} 非 JSON object: {s}", .{ task_id, trimForLog(packet) });
        return self.allocator.dupe(u8, packet) catch KgError.OutOfMemory;
    }

    /// 读取 TinyKG effective status；claimed 租约过期时由 TinyKG 返回 open。
    pub fn taskStatus(self: *KgClient, task_id: u64) KgError!TaskStatus {
        const packet = try self.taskPacket(task_id, 1);
        defer self.allocator.free(packet);
        return parseTaskPacketStatus(packet) orelse
            self.dataError("task-packet {d} 缺失/包含非法 status: {s}", .{ task_id, trimForLog(packet) });
    }

    /// 无租约身份的兼容入口；用于未 claim 的内部计划和既有调用点。
    pub fn closeTask(self: *KgClient, task_id: u64, evidence: []const u8) KgError!void {
        return self.closeTaskWithIdentity(task_id, .completed, evidence, null);
    }

    /// 带宿主注入 agent identity 的关闭入口。TaskUpdate/TaskStop 必须走这里，确保只能
    /// 关闭自己持有的有效租约；身份从程序上下文注入，不由 LLM 编造。
    pub fn closeTaskAs(self: *KgClient, task_id: u64, evidence: []const u8, agent_ident: []const u8) KgError!void {
        return self.closeTaskWithIdentity(task_id, .completed, evidence, agent_ident);
    }

    /// 显式失败终态；failed 不满足依赖，也不会被误当作已完成。
    pub fn failTask(self: *KgClient, task_id: u64, evidence: []const u8) KgError!void {
        return self.closeTaskWithIdentity(task_id, .failed, evidence, null);
    }

    pub fn failTaskAs(self: *KgClient, task_id: u64, evidence: []const u8, agent_ident: []const u8) KgError!void {
        return self.closeTaskWithIdentity(task_id, .failed, evidence, agent_ident);
    }

    fn closeTaskWithIdentity(self: *KgClient, task_id: u64, terminal: TaskStatus, evidence: []const u8, agent_ident: ?[]const u8) KgError!void {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{task_id}) catch unreachable;

        // Inline evidence is authorized and materialized by task-close under
        // one TinyKG store lock. The old client-side ensure-node call happened
        // before lease validation, so a wrong holder left orphan verification
        // nodes and added an avoidable subprocess/TOCTOU window.
        const verification_text = std.fmt.allocPrint(
            self.allocator,
            "task {d} {s} evidence: {s}",
            .{ task_id, if (terminal == .completed) "completion" else "failure", evidence },
        ) catch return KgError.OutOfMemory;
        defer self.allocator.free(verification_text);
        const terminal_str = @tagName(terminal);
        const out = if (agent_ident) |by| try self.runCheckedWrite(&.{
            "task-close", self.store.argvSlot(), id_str, terminal_str, "--by", by, "--evidence-text", verification_text,
        }) else try self.runCheckedWrite(&.{
            "task-close", self.store.argvSlot(), id_str, terminal_str, "--evidence-text", verification_text,
        });
        self.freeOut(out);
    }

    /// 显式治理删除。TaskUpdate 不调用：持久 task 的 failed/cancelled 必须保留稳定 id。
    pub fn deleteTask(self: *KgClient, task_id: u64) KgError!void {
        return self.forget(task_id);
    }

    /// 单任务 readiness(TaskList 排序/看板用)。
    pub fn taskReadiness(self: *KgClient, task_id: u64) KgError!FrontierRow.Readiness {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{task_id}) catch unreachable;
        const out = try self.runChecked(&.{ "task-ready", self.store.argvSlot(), id_str });
        defer self.freeOut(out);
        const v = std.mem.trim(u8, out.stdout, " \r\n");
        if (std.mem.eql(u8, v, "ready")) return .ready;
        if (std.mem.eql(u8, v, "blocked")) return .blocked;
        return .missing_dependencies;
    }

    /// 给节点打 provenance(session id)。best-effort:失败仅 log,不上抛。
    pub fn tagProvenance(self: *KgClient, node_id: u64, session_id: []const u8) void {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{node_id}) catch return;
        const out = self.runChecked(&.{
            "set-property", self.store.argvSlot(), id_str, "session_id", session_id,
        }) catch return;
        self.freeOut(out);
    }

    /// BM25 检索 + 客户端过滤(domain=当前项目+global;默认排除 task/verification
    /// 与 schema_type=todo——记忆检索面与任务面隔离,设计 §2 治理)。
    /// 返回 owned slice(caller 逐项 deinit + free slice)。
    pub fn recall(self: *KgClient, query: []const u8, limit: usize, include_tasks: bool) KgError![]RecallHit {
        return self.recallTyped(query, limit, include_tasks, null);
    }

    /// Retrieve only task nodes.  Experience feedback cannot rely on the
    /// ordinary mixed-kind result window: a dense set of decisions/concepts
    /// may otherwise crowd every completed task out before client filtering.
    /// The kind restriction is pushed into TinyKG's text-search plan.
    pub fn recallTasks(self: *KgClient, query: []const u8, limit: usize) KgError![]RecallHit {
        return self.recallFiltered(query, limit, true, null, "task");
    }

    /// type_filter 非 null 时按 schema_type 过滤(typed recall)。
    /// **best-effort 契约(Linus HIGH-2)**:BM25 按相关度排序不按类型,稀有类型可能全排在超采窗口外
    /// → 库里有该类型却返空。拉高超采倍数缓解,但不保证:typed recall 可能少返相关度低的同类节点。
    /// 正解是 tinykg server-side --schema-type 下推(本切片 defer)。空返 ≠ 库中无该类型。
    pub fn recallTyped(self: *KgClient, query: []const u8, limit: usize, include_tasks: bool, type_filter: ?[]const u8) KgError![]RecallHit {
        return self.recallFiltered(query, limit, include_tasks, type_filter, null);
    }

    fn recallFiltered(
        self: *KgClient,
        query: []const u8,
        limit: usize,
        include_tasks: bool,
        type_filter: ?[]const u8,
        kind_filter: ?[]const u8,
    ) KgError![]RecallHit {
        // project-containment 召回:项目子树 + global 子树各一次 search --project(图拓扑隔离,
        // 取代旧 domain_id 属性客户端过滤)。读路径不创建 project 节点:两个子树都不存在
        // (库中无任何挂接记忆)→ 零 spawn 返空。
        var results: std.ArrayList(RecallHit) = .empty;
        errdefer {
            for (results.items) |*h| h.deinit(self.allocator);
            results.deinit(self.allocator);
        }
        const proj_id = try self.projectNodeId(false, false);
        const glob_id = try self.projectNodeId(true, false);
        if (proj_id) |pid| try self.searchSubtreeInto(&results, pid, self.domain, query, limit, include_tasks, type_filter, kind_filter);
        if (glob_id) |gid| {
            if (proj_id == null or gid != proj_id.?) // domain=="global" 时两者同节点,防重扫
                try self.searchSubtreeInto(&results, gid, "global", query, limit, include_tasks, type_filter, kind_filter);
        }
        // 两路合并:按 BM25 分数降序(同库同查询,分数可比),截 limit。
        std.mem.sort(RecallHit, results.items, {}, recallHitScoreDescLessThan);
        if (results.items.len > limit) {
            for (results.items[limit..]) |*h| h.deinit(self.allocator);
            results.shrinkRetainingCapacity(limit);
        }
        return results.toOwnedSlice(self.allocator) catch KgError.OutOfMemory;
    }

    fn recallHitScoreDescLessThan(_: void, a: RecallHit, b: RecallHit) bool {
        return a.score > b.score;
    }

    /// 单子树 search(--project)+ 解析 + 客户端过滤(任务面/typed),追加进 results。
    /// domain_label 只做展示归属(RecallHit.domain);按 node_id 与已有结果去重
    /// (节点理论上可挂多 project,防双计)。
    fn searchSubtreeInto(
        self: *KgClient,
        results: *std.ArrayList(RecallHit),
        project_id: u64,
        domain_label: []const u8,
        query: []const u8,
        limit: usize,
        include_tasks: bool,
        type_filter: ?[]const u8,
        kind_filter: ?[]const u8,
    ) KgError!void {
        var limbuf: [16]u8 = undefined;
        var pbuf: [24]u8 = undefined;
        // 超采:任务面等客户端过滤后仍能凑满 limit(schema_type 已 server-side 下推,
        // 旧 8× 超采的"稀有类型排窗口外"问题由 tinykg --schema-type 成员集根治)。
        const oversample: usize = limit * 2 + 4;
        const raw_limit = std.fmt.bufPrint(&limbuf, "{d}", .{oversample}) catch unreachable;
        const p_str = std.fmt.bufPrint(&pbuf, "{d}", .{project_id}) catch unreachable;
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);
        argv.appendSlice(self.allocator, &.{
            "search",    self.store.argvSlot(), query,      "--project", p_str,            "--limit", raw_limit,
            "--profile", "agent-memory",        "--format", "json",      "--include-text",
        }) catch return KgError.OutOfMemory;
        if (type_filter) |tf| argv.appendSlice(self.allocator, &.{ "--schema-type", tf }) catch return KgError.OutOfMemory;
        if (kind_filter) |kind| argv.appendSlice(self.allocator, &.{ "--kind", kind }) catch return KgError.OutOfMemory;
        const out = try self.runChecked(argv.items);
        defer self.freeOut(out);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, out.stdout, .{}) catch
            return self.dataError("search JSON 解析失败", .{});
        defer parsed.deinit();
        if (parsed.value != .object) return self.dataError("search JSON 顶层非 object", .{});
        const hits_v = parsed.value.object.get("hits") orelse return self.dataError("search JSON 无 hits", .{});
        if (hits_v != .array) return self.dataError("search hits 非数组", .{});

        for (hits_v.array.items) |hit_v| {
            if (hit_v != .object) continue;
            const node_v = hit_v.object.get("node") orelse continue;
            if (node_v != .object) continue;
            const node = node_v.object;

            const kind = jsonStr(node.get("kind")) orelse continue;
            // Treat the server-side filter as a contract, not as permission to
            // trust malformed output from a skewed TinyKG binary.
            if (kind_filter) |expected_kind|
                if (!std.mem.eql(u8, kind, expected_kind)) continue;
            const schema_v = node.get("schema");
            const schema_type = if (schema_v != null and schema_v.? == .object)
                (jsonStr(schema_v.?.object.get("schema_type")) orelse "")
            else
                "";
            const src_label = if (schema_v != null and schema_v.? == .object)
                (jsonStr(schema_v.?.object.get("source_label")) orelse "")
            else
                "";

            // 任务面隔离。project 节点自身也不进记忆召回(容器非内容)。
            if (std.mem.eql(u8, kind, "project")) continue;
            if (!include_tasks) {
                if (std.mem.eql(u8, kind, "task") or std.mem.eql(u8, kind, "verification")) continue;
                if (std.mem.eql(u8, schema_type, "todo")) continue;
            }
            const id_v = node.get("id") orelse continue;
            const node_id: u64 = switch (id_v) {
                .integer => |i| if (i >= 0) @intCast(i) else continue,
                else => continue,
            };
            // 跨子树去重(节点可挂多 project)。
            var dup = false;
            for (results.items) |r| {
                if (r.node_id == node_id) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            const score: f64 = switch (hit_v.object.get("score") orelse std.json.Value{ .float = 0 }) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => 0,
            };
            // 文本:search --include-text 让 node 直接带全文 → 无需每 hit get spawn(成本修复,
            // Linus/PM P0:自动召回每 turn 都跑,旧的 per-hit get 4 spawn 前提已不成立)。
            // text 借用 parsed JSON(存活到函数尾),下面 dupe 成 owned。
            const text = jsonStr(node.get("text")) orelse "";

            // L1:先 dupe 各字段到局部 + errdefer,再 append——避免部分成功泄漏。
            const k_owned = self.allocator.dupe(u8, kind) catch return KgError.OutOfMemory;
            errdefer self.allocator.free(k_owned);
            const d_owned = self.allocator.dupe(u8, domain_label) catch return KgError.OutOfMemory;
            errdefer self.allocator.free(d_owned);
            const s_owned = self.allocator.dupe(u8, schema_type) catch return KgError.OutOfMemory;
            errdefer self.allocator.free(s_owned);
            const text_truncated = text.len > 800;
            const t_owned = boundedTextExcerptAlloc(self.allocator, text, 800) catch return KgError.OutOfMemory;
            errdefer self.allocator.free(t_owned);
            const sl_owned: []u8 = if (src_label.len > 0) (self.allocator.dupe(u8, src_label) catch return KgError.OutOfMemory) else @constCast(&[_]u8{});
            errdefer if (sl_owned.len > 0) self.allocator.free(sl_owned);
            results.append(self.allocator, .{
                .node_id = node_id,
                .kind = k_owned,
                .domain = d_owned,
                .schema_type = s_owned,
                .text = t_owned,
                .text_total_bytes = text.len,
                .text_truncated = text_truncated,
                .score = score,
                .source_label = sl_owned,
            }) catch return KgError.OutOfMemory;
        }
    }

    pub const MemorySource = struct {
        /// 来源记忆文件名(document 根有;section/正文无 → null)。owned。
        label: ?[]u8,
        /// 是否 md 派生节点(document 根 label 判定,或 external_key 前缀 md-doc:/content:
        /// ——section/正文节点无 label 但同样会被同文件 Write upsert 复活,防护必须同拦,
        /// Linus 次要5:只拦 document 根是半扇门)。
        md_derived: bool,
    };

    /// 节点的记忆来源(/kg forget 假删除防护 + 溯源提示)。查询失败 → 保守 .{null,false}。
    pub fn nodeMemorySource(self: *KgClient, node_id: u64) MemorySource {
        const none = MemorySource{ .label = null, .md_derived = false };
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{node_id}) catch unreachable;
        const out = self.runChecked(&.{ "get", self.store.argvSlot(), id_str, "--format", "json" }) catch return none;
        defer self.freeOut(out);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, out.stdout, .{}) catch return none;
        defer parsed.deinit();
        if (parsed.value != .object) return none;
        const node_v = parsed.value.object.get("node") orelse return none;
        if (node_v != .object) return none;
        const schema_v = node_v.object.get("schema") orelse return none;
        if (schema_v != .object) return none;
        const label_raw = jsonStr(schema_v.object.get("source_label")) orelse "";
        const ext_key = jsonStr(schema_v.object.get("external_key")) orelse "";
        const md_derived = label_raw.len > 0 or
            std.mem.startsWith(u8, ext_key, "md-doc:") or
            std.mem.startsWith(u8, ext_key, "content:");
        const label: ?[]u8 = if (label_raw.len > 0) (self.allocator.dupe(u8, label_raw) catch null) else null;
        return .{ .label = label, .md_derived = md_derived };
    }

    /// project 节点列表("  id  名称\n" 多行,owned;/kg projects 用——merge 的 id 唯一出口)。
    pub fn listProjects(self: *KgClient, allocator: std.mem.Allocator) KgError![]u8 {
        const out = try self.runChecked(&.{ "list-recent", self.store.argvSlot(), "--kind", "project", "--limit", "200" });
        defer self.freeOut(out);
        var b: std.ArrayList(u8) = .empty;
        errdefer b.deinit(allocator);
        var it = std.mem.splitScalar(u8, out.stdout, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            var cols = std.mem.splitScalar(u8, line, '\t');
            const id_str = cols.next() orelse continue;
            _ = cols.next() orelse continue; // kind
            const text_col = cols.rest();
            _ = std.fmt.parseInt(u64, id_str, 10) catch continue; // 跳过 `#` 诊断行
            const row = std.fmt.allocPrint(allocator, "  {s}  {s}\n", .{ id_str, text_col }) catch return KgError.OutOfMemory;
            defer allocator.free(row);
            b.appendSlice(allocator, row) catch return KgError.OutOfMemory;
        }
        return b.toOwnedSlice(allocator) catch KgError.OutOfMemory;
    }

    /// 重复 project 检测(状态页提示):同名(escaped text)project ≥2 → 返回名字串(owned);无 → null。
    /// 旧 bug 时代增殖的重复让一半记忆召回不可见,用户自己不可能发现,必须主动提示。
    pub fn duplicateProjectHint(self: *KgClient, allocator: std.mem.Allocator) ?[]u8 {
        const out = self.runChecked(&.{ "list-recent", self.store.argvSlot(), "--kind", "project", "--limit", "200" }) catch return null;
        defer self.freeOut(out);
        var seen = std.StringHashMap(void).init(allocator);
        defer {
            var kit = seen.keyIterator();
            while (kit.next()) |k| allocator.free(k.*);
            seen.deinit();
        }
        var it = std.mem.splitScalar(u8, out.stdout, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            var cols = std.mem.splitScalar(u8, line, '\t');
            const id_str = cols.next() orelse continue;
            _ = cols.next() orelse continue;
            const text_col = cols.rest();
            _ = std.fmt.parseInt(u64, id_str, 10) catch continue;
            // 借用 key 不进 map(Linus:dupe 失败时 map 持有指向 out.stdout 的借用指针 →
            // defer 清理循环 invalid free):先 contains,miss 才 dupe 后 put。
            if (seen.contains(text_col)) {
                return allocator.dupe(u8, text_col) catch null; // 首个重复名即够提示
            }
            const key_owned = allocator.dupe(u8, text_col) catch return null;
            seen.put(key_owned, {}) catch {
                allocator.free(key_owned);
                return null;
            };
        }
        return null;
    }

    /// merge 原语接线:reparent-contain(重复 project 节点合并;/kg merge 用)。返回摘要(owned)。
    pub fn reparentContain(self: *KgClient, from: u64, to: u64) KgError![]u8 {
        var fbuf: [24]u8 = undefined;
        var tbuf: [24]u8 = undefined;
        const f_str = std.fmt.bufPrint(&fbuf, "{d}", .{from}) catch unreachable;
        const t_str = std.fmt.bufPrint(&tbuf, "{d}", .{to}) catch unreachable;
        const out = try self.runCheckedWrite(&.{ "reparent-contain", self.store.argvSlot(), f_str, t_str });
        defer self.freeOut(out);
        return self.allocator.dupe(u8, std.mem.trim(u8, out.stdout, " \r\n")) catch KgError.OutOfMemory;
    }

    const NodeRecord = struct {
        kind: []u8,
        text: []u8,

        fn deinit(self: *NodeRecord, allocator: std.mem.Allocator) void {
            allocator.free(self.kind);
            allocator.free(self.text);
        }
    };

    /// 取节点 kind + 全文(`get <id>` TSV,已 unescape)。owned;NotFound 返 error.Data。
    fn fetchNodeRecord(self: *KgClient, node_id: u64) KgError!NodeRecord {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{node_id}) catch unreachable;
        const out = try self.runChecked(&.{ "get", self.store.argvSlot(), id_str });
        defer self.freeOut(out);
        const line_end = std.mem.indexOfScalar(u8, out.stdout, '\n') orelse out.stdout.len;
        const line = out.stdout[0..line_end];
        var cols = std.mem.splitScalar(u8, line, '\t');
        _ = cols.next() orelse return self.dataError("get {d} 输出缺 id", .{node_id});
        const kind_col = cols.next() orelse return self.dataError("get {d} 输出缺 kind", .{node_id});
        const kind = self.allocator.dupe(u8, kind_col) catch return KgError.OutOfMemory;
        errdefer self.allocator.free(kind);
        const text = unescapeTsv(self.allocator, cols.rest()) catch return KgError.OutOfMemory;
        return .{ .kind = kind, .text = text };
    }

    /// 取节点全文(`get <id>` TSV 第 3 列,已 unescape)。owned;NotFound 返 error.Data。
    pub fn fetchNodeText(self: *KgClient, node_id: u64) KgError![]u8 {
        const record = try self.fetchNodeRecord(node_id);
        self.allocator.free(record.kind);
        return record.text;
    }

    /// 取节点版本化 metadata JSON。KgContext 用它读取 current_generation/deprecated_by，
    /// 因为 TinyKG 会有意把历史节点从 neighbors 子图中省略为 history continuation。
    /// include_text=true 时同一次 subprocess 带权威正文，避免 metadata + get 双调用。
    pub fn nodeMetadataJson(self: *KgClient, node_id: u64, include_text: bool) KgError![]u8 {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{node_id}) catch unreachable;
        const out = if (include_text)
            try self.runChecked(&.{ "get", self.store.argvSlot(), id_str, "--format", "json", "--meta", "--include-text" })
        else
            try self.runChecked(&.{ "get", self.store.argvSlot(), id_str, "--format", "json", "--meta" });
        defer self.freeOut(out);
        return self.allocator.dupe(u8, std.mem.trim(u8, out.stdout, " \t\r\n")) catch KgError.OutOfMemory;
    }

    /// task-frontier(注入段/看板用)。返回 owned rows。
    pub fn frontier(self: *KgClient, root_id: u64, limit: usize) KgError![]FrontierRow {
        var idbuf: [24]u8 = undefined;
        var limbuf: [16]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{root_id}) catch unreachable;
        const lim_str = std.fmt.bufPrint(&limbuf, "{d}", .{limit}) catch unreachable;
        const out = try self.runChecked(&.{
            "task-frontier", self.store.argvSlot(), id_str, "--limit", lim_str,
        });
        defer self.freeOut(out);

        var rows: std.ArrayList(FrontierRow) = .empty;
        errdefer {
            for (rows.items) |*r| r.deinit(self.allocator);
            rows.deinit(self.allocator);
        }
        var it = std.mem.splitScalar(u8, out.stdout, '\n');
        while (it.next()) |line| {
            // 行格式 v3(稳定 task kind):<role>\t<edge>\t<rel>\t<task_id>\tstatus=<s>\treadiness=<r>\tdepth=<n>\tclaimed_by=<v>\tpath=<v>\t<escaped text>
            // v2 兼容:缺 status=；v1 兼容:readiness 后直接是 text(缺 depth= 列)。
            const role: FrontierRow.Role = if (std.mem.startsWith(u8, line, "child_task\t"))
                .leaf
            else if (std.mem.startsWith(u8, line, "branch_task\t"))
                .branch
            else if (std.mem.startsWith(u8, line, "related_failed_task\t"))
                .related_failed
            else if (std.mem.startsWith(u8, line, "related_task\t"))
                .related
            else if (std.mem.startsWith(u8, line, "failed_task\t"))
                .failed
            else
                continue;
            var cols = std.mem.splitScalar(u8, line, '\t');
            _ = cols.next(); // role
            _ = cols.next(); // edge id
            _ = cols.next(); // rel
            const id_col = cols.next() orelse continue;
            const lifecycle_or_ready_col = cols.next() orelse continue;

            const task_id = std.fmt.parseInt(u64, id_col, 10) catch continue;
            var has_explicit_status = false;
            var status: TaskStatus = .open;
            const ready_col: []const u8 = if (std.mem.startsWith(u8, lifecycle_or_ready_col, "status=")) blk: {
                has_explicit_status = true;
                status = TaskStatus.parse(lifecycle_or_ready_col["status=".len..]) orelse continue;
                break :blk cols.next() orelse continue;
            } else lifecycle_or_ready_col;
            const readiness: FrontierRow.Readiness = blk: {
                const v = if (std.mem.startsWith(u8, ready_col, "readiness=")) ready_col["readiness=".len..] else ready_col;
                if (std.mem.eql(u8, v, "ready")) break :blk .ready;
                if (std.mem.eql(u8, v, "blocked")) break :blk .blocked;
                break :blk .missing_dependencies;
            };

            var depth: usize = 1;
            var claimed_raw: ?[]const u8 = null;
            var path_raw: ?[]const u8 = null;
            var text_col: []const u8 = undefined;
            const after_ready = cols.rest();
            if (std.mem.startsWith(u8, after_ready, "depth=")) {
                const depth_col = cols.next() orelse continue;
                depth = std.fmt.parseInt(usize, depth_col["depth=".len..], 10) catch 1;
                const claim_col = cols.next() orelse continue;
                if (std.mem.startsWith(u8, claim_col, "claimed_by=")) {
                    const v = claim_col["claimed_by=".len..];
                    if (v.len > 0 and !std.mem.eql(u8, v, "-")) claimed_raw = v;
                }
                const path_col = cols.next() orelse continue;
                if (std.mem.startsWith(u8, path_col, "path=")) {
                    const v = path_col["path=".len..];
                    if (v.len > 0 and !std.mem.eql(u8, v, "-")) path_raw = v;
                }
                text_col = cols.rest();
            } else {
                text_col = after_ready;
            }

            const claimed_by = if (claimed_raw) |raw| try unescapeTsv(self.allocator, raw) else null;
            errdefer if (claimed_by) |c| self.allocator.free(c);
            const path = if (path_raw) |raw| try unescapeTsv(self.allocator, raw) else null;
            errdefer if (path) |p| self.allocator.free(p);
            if (!has_explicit_status and claimed_by != null) status = .claimed;
            const text = try unescapeTsv(self.allocator, text_col);
            rows.append(self.allocator, .{
                .task_id = task_id,
                .status = status,
                .readiness = readiness,
                .role = role,
                .depth = depth,
                .claimed_by = claimed_by,
                .path = path,
                .text = text,
            }) catch {
                self.allocator.free(text);
                return KgError.OutOfMemory;
            };
        }
        return rows.toOwnedSlice(self.allocator) catch KgError.OutOfMemory;
    }

    /// 认领任务租约(task-claim --by)。多 agent 并行防撞车:干活前 claim,
    /// TTL 到期自动视为无主(读侧过期,崩掉的 session 不会永久占坑)。
    /// 他人未过期租约 → KgError(detail 含 holder)。
    pub fn claimTask(self: *KgClient, task_id: u64, agent: []const u8) KgError!void {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{task_id}) catch unreachable;
        const out = try self.runCheckedWrite(&.{ "task-claim", self.store.argvSlot(), id_str, "--by", agent });
        self.freeOut(out);
    }

    /// 释放租约(task-release --by;租约立即过期)。身份对称:只能放自己的活租约,
    /// 他人活租约会被 CLI 拒(ClaimHeld)。闭合任务后无需调用——闭合本身出 frontier。
    pub fn releaseTask(self: *KgClient, task_id: u64, agent: []const u8) KgError!void {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{task_id}) catch unreachable;
        const out = try self.runCheckedWrite(&.{ "task-release", self.store.argvSlot(), id_str, "--by", agent });
        self.freeOut(out);
    }

    /// 本项目记忆节点数(启动锚:注入段告诉模型"存在 N 条记忆",提升 recall 采用率
    /// ——PM 反馈#3,对齐 A/B 结论"架构位置 > 措辞")。近似:store 总节点数(P1 无
    /// per-domain 计数原语;绝大多数早期用户单项目,误差可接受)。失败返 0(不阻塞)。
    pub fn memoryCount(self: *KgClient) usize {
        if (!self.ready) return 0;
        const out = self.runChecked(&.{ "stats", self.store.argvSlot() }) catch return 0;
        defer self.freeOut(out);
        // **bug 修复**:stats 输出是**空格分隔单行** `nodes=3 edges=0`,不能用按行的 extractInfoField
        // (它会返回 "3 edges=0" → parseInt 失败 → 恒 0 → "共 N 条持久记忆"注入锚永不出现)。
        const n = extractStatField(out.stdout, "nodes") orelse return 0;
        return std.fmt.parseInt(usize, n, 10) catch 0;
    }

    pub const MemoryFacet = struct {
        total: usize,
        breakdown: []u8, // owned,如 "5 decision · 3 module · 2 bug"(空=无 typed 记忆)
        pub fn deinit(self: *const MemoryFacet, allocator: std.mem.Allocator) void {
            allocator.free(self.breakdown);
        }
    };

    /// 记忆类型 facet:统计**当前 domain + global**的记忆按 schema_type 分布(排除任务面)。
    /// 供启动注入把 typed 知识做成一等公民可见("本项目 N 条:X decision · Y module · Z bug")。
    /// **domain 准确**——修 memoryCount 的"全库节点计数"seam(那个含别项目 + 任务节点)。
    /// best-effort:失败/无记忆 → null。scan 上限 200/domain(agent 语料够;超出低估,facet 是信号非精确)。
    pub fn memoryFacet(self: *KgClient, allocator: std.mem.Allocator) ?MemoryFacet {
        if (!self.ready) return null;
        const display = [_][]const u8{ "decision", "module", "bug", "user_preference", "observation" };
        var counts = [_]usize{0} ** display.len;
        var other: usize = 0;

        // project-containment:项目 + global 子树各扫一次(读路径不建 project 节点)。
        const proj_id: ?u64 = self.projectNodeId(false, false) catch null;
        const glob_id: ?u64 = self.projectNodeId(true, false) catch null;
        if (proj_id) |p| self.facetScan(p, display[0..], counts[0..], &other);
        if (glob_id) |g| {
            if (proj_id == null or g != proj_id.?) self.facetScan(g, display[0..], counts[0..], &other);
        }

        var total: usize = other;
        for (counts) |c| total += c;
        if (total == 0) return null;

        var b: std.ArrayList(u8) = .empty;
        errdefer b.deinit(allocator);
        var first = true;
        for (display, 0..) |name, i| {
            if (counts[i] == 0) continue;
            if (!first) b.appendSlice(allocator, " · ") catch return null;
            first = false;
            const seg = std.fmt.allocPrint(allocator, "{d} {s}", .{ counts[i], name }) catch return null;
            defer allocator.free(seg);
            b.appendSlice(allocator, seg) catch return null;
        }
        const breakdown = b.toOwnedSlice(allocator) catch return null;
        return .{ .total = total, .breakdown = breakdown };
    }

    /// 扫一个 project 子树的 list-recent --project --with-type,按 schema_type 累加计数
    /// (排除 task/verification/嵌套 project 容器)。`#` 诊断行天然被列解析跳过。
    fn facetScan(self: *KgClient, project_id: u64, display: []const []const u8, counts: []usize, other: *usize) void {
        var pbuf: [24]u8 = undefined;
        const p_str = std.fmt.bufPrint(&pbuf, "{d}", .{project_id}) catch unreachable;
        const out = self.runChecked(&.{ "list-recent", self.store.argvSlot(), "--project", p_str, "--with-type", "--limit", "200" }) catch return;
        defer self.freeOut(out);
        var it = std.mem.splitScalar(u8, out.stdout, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            var cols = std.mem.splitScalar(u8, line, '\t');
            _ = cols.next() orelse continue; // id
            const kind = cols.next() orelse continue;
            const st = cols.next() orelse continue; // schema_type(--with-type 第 3 列)
            if (std.mem.eql(u8, kind, "task") or std.mem.eql(u8, kind, "verification") or std.mem.eql(u8, kind, "project")) continue;
            var matched = false;
            for (display, 0..) |name, i| {
                if (std.mem.eql(u8, st, name)) {
                    counts[i] += 1;
                    matched = true;
                    break;
                }
            }
            if (!matched) other.* += 1;
        }
    }

    /// 删节点(/kg forget:用户删除权,投毒自救,设计 §7)。data 错(NotFound)透传。
    pub fn forget(self: *KgClient, node_id: u64) KgError!void {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{node_id}) catch unreachable;
        const out = try self.runCheckedWrite(&.{ "delete-node", self.store.argvSlot(), id_str });
        self.freeOut(out);
    }

    /// 最近记忆列表(/kg mem:用户可检视性,设计 §7)。用空查询近似"全部",
    /// 客户端过滤同 recall(domain + 排除任务面)。返回 owned hits。
    pub fn listRecentMemories(self: *KgClient, limit: usize) KgError![]RecallHit {
        // 枚举不走全文检索:用 tinykg list-recent 按 id 降序(=创建序)原生枚举,
        // 替换旧的虚词 search hack(受召回门槛/排序污染,实测仅列出部分且非最近)。
        // 作用域对齐 recall:当前项目 domain + global,合并后按 id 降序取 limit。
        var results: std.ArrayList(RecallHit) = .empty;
        errdefer {
            for (results.items) |*h| h.deinit(self.allocator);
            results.deinit(self.allocator);
        }
        // project-containment:项目 + global 子树(读路径不建 project 节点;都无 → 空列表)。
        const proj_id = try self.projectNodeId(false, false);
        const glob_id = try self.projectNodeId(true, false);
        if (proj_id) |p| try self.appendRecentForProject(&results, p, self.domain, limit);
        if (glob_id) |g| {
            if (proj_id == null or g != proj_id.?) try self.appendRecentForProject(&results, g, "global", limit);
        }
        std.mem.sort(RecallHit, results.items, {}, recallHitIdDescLessThan);
        if (results.items.len > limit) {
            for (results.items[limit..]) |*h| h.deinit(self.allocator);
            results.shrinkRetainingCapacity(limit);
        }
        return results.toOwnedSlice(self.allocator) catch KgError.OutOfMemory;
    }

    fn recallHitIdDescLessThan(_: void, a: RecallHit, b: RecallHit) bool {
        return a.node_id > b.node_id; // id 降序 = 最近在前
    }

    /// 把某 project 子树的最近节点(list-recent --project TSV:id\tkind\ttext)解析成 owned
    /// RecallHit 追加到 results。任务面隔离(task/verification/嵌套 project)对齐 recall。
    /// domain_label 只做展示归属。`#` 诊断行 parseInt 失败自然跳过。
    fn appendRecentForProject(self: *KgClient, results: *std.ArrayList(RecallHit), project_id: u64, domain_label: []const u8, limit: usize) KgError!void {
        var limbuf: [16]u8 = undefined;
        var pbuf: [24]u8 = undefined;
        const raw = std.fmt.bufPrint(&limbuf, "{d}", .{limit * 2 + 4}) catch unreachable;
        const p_str = std.fmt.bufPrint(&pbuf, "{d}", .{project_id}) catch unreachable;
        const out = self.runChecked(&.{ "list-recent", self.store.argvSlot(), "--project", p_str, "--limit", raw }) catch |e| switch (e) {
            KgError.Data => return, // 空 store / 空子树 → 跳过
            else => return e,
        };
        defer self.freeOut(out);
        var it = std.mem.splitScalar(u8, out.stdout, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            var cols = std.mem.splitScalar(u8, line, '\t');
            const id_str = cols.next() orelse continue;
            const kind = cols.next() orelse continue;
            const text_col = cols.rest();
            const node_id = std.fmt.parseInt(u64, id_str, 10) catch continue;
            if (std.mem.eql(u8, kind, "task") or std.mem.eql(u8, kind, "verification") or std.mem.eql(u8, kind, "project")) continue;
            // 空壳 document(记忆文件被清空后留下的 upsert 空根)不进 /kg mem(PM 验收观察①)。
            if (std.mem.eql(u8, kind, "document") and std.mem.indexOf(u8, text_col, "title=\"\"") != null) continue;

            // L1:先 dupe 三字段到局部 + errdefer,再 append——避免部分成功泄漏(对齐 recall)。
            const k_owned = self.allocator.dupe(u8, kind) catch return KgError.OutOfMemory;
            errdefer self.allocator.free(k_owned);
            const d_owned = self.allocator.dupe(u8, domain_label) catch return KgError.OutOfMemory;
            errdefer self.allocator.free(d_owned);
            const s_owned = self.allocator.dupe(u8, "") catch return KgError.OutOfMemory; // list-recent TSV 无 schema_type
            errdefer self.allocator.free(s_owned);
            const text_un = unescapeTsv(self.allocator, text_col) catch return KgError.OutOfMemory;
            defer self.allocator.free(text_un);
            const text_truncated = text_un.len > 800;
            const t_owned = boundedTextExcerptAlloc(self.allocator, text_un, 800) catch return KgError.OutOfMemory;
            errdefer self.allocator.free(t_owned);

            results.append(self.allocator, .{
                .node_id = node_id,
                .kind = k_owned,
                .domain = d_owned,
                .schema_type = s_owned,
                .text = t_owned,
                .text_total_bytes = text_un.len,
                .text_truncated = text_truncated,
                .score = 0,
            }) catch return KgError.OutOfMemory;
        }
    }

    /// 节点是否存在且为 task kind(stale kg_root 防御,设计 §3)。
    pub fn nodeIsTask(self: *KgClient, node_id: u64) KgError!bool {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{node_id}) catch unreachable;
        const out = self.runChecked(&.{ "get", self.store.argvSlot(), id_str }) catch |e| switch (e) {
            KgError.Data => return false, // NotFound → 不存在
            else => return e,
        };
        defer self.freeOut(out);
        // get 输出含 kind 列;粗判 "task" 词存在于首行。
        var it = std.mem.splitScalar(u8, out.stdout, '\n');
        const first = it.next() orelse return false;
        // 精确切第 2 列(id\tkind\ttext)比对,不用 " task " 空格兜底(text 含 " task " 会假阳性,L3)。
        var cols = std.mem.splitScalar(u8, first, '\t');
        _ = cols.next(); // id
        const kind = cols.next() orelse return false;
        return std.mem.eql(u8, kind, "task");
    }

    // ── spawn 与错误归一(设计 §6)────────────────────────────────────

    const Out = common.SpawnOut;

    fn freeOut(self: *KgClient, out: Out) void {
        self.allocator.free(out.stdout);
        self.allocator.free(out.stderr);
    }

    /// 跑一条 tinykg 命令(不做 ready 检查——ensureReady 自己用)。
    fn runRaw(self: *KgClient, args: []const []const u8) !Out {
        if (self.transport == .daemon) {
            if (args.len < 2 or !std.mem.eql(u8, args[1], self.store.argvSlot())) return error.InvalidRemoteCommandShape;
            const result = try self.transport.daemon.run(args[0], args[2..], false);
            return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = result.exit_code };
        }
        const bin = self.bin_path orelse return error.NoBin;
        // argv: bin + args + null。
        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        defer {
            for (argv.items) |a| if (a) |p| self.allocator.free(std.mem.span(p));
            argv.deinit(self.allocator);
        }
        // L2:先 dupeZ 到局部,append 失败时 free(否则 dupeZ 结果泄漏)。
        {
            const b = try self.allocator.dupeZ(u8, bin);
            argv.append(self.allocator, b) catch |e| {
                self.allocator.free(b);
                return e;
            };
        }
        for (args) |a| {
            const z = try self.allocator.dupeZ(u8, a);
            argv.append(self.allocator, z) catch |e| {
                self.allocator.free(z);
                return e;
            };
        }
        try argv.append(self.allocator, null);
        return common.spawnCaptureWithStderrTimed(argv.items, self.allocator, self.abort, SPAWN_TIMEOUT_MS, null, common.MAX_SPAWN_CAPTURE_BYTES, null);
    }

    /// ready 检查 + 瞬时重试 + 错误分类。exit!=0 时按 stderr 分类:
    /// `tinykg: error: Timeout` → transient(重试);NotFound/InvalidId/Cycle* → data;其余 → transient。
    /// **写操作不重试**(M3:add-node/delete-node/revise 非幂等——killpg 超时后子进程状态
    /// 未知,节点可能已落盘,重试=重复写)。读操作可安全重试。
    fn runChecked(self: *KgClient, args: []const []const u8) KgError!Out {
        return self.runCheckedRetry(args, true);
    }
    fn runCheckedWrite(self: *KgClient, args: []const []const u8) KgError!Out {
        return self.runCheckedRetry(args, false);
    }
    fn runCheckedRetry(self: *KgClient, args: []const []const u8, retry: bool) KgError!Out {
        if (!self.ready) return KgError.Degraded;
        if (self.transport == .daemon) {
            if (args.len < 2 or !std.mem.eql(u8, args[1], self.store.argvSlot()))
                return self.dataError("invalid remote command shape", .{});
            const result = self.transport.daemon.run(args[0], args[2..], !retry) catch |err|
                return self.mapTransportError(err);
            const out: Out = .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = result.exit_code };
            if (out.exit_code == 0) return out;
            const err_name = parseCliError(out.stderr);
            const class = classifyCliError(err_name);
            switch (class) {
                .data => {
                    self.setDetail("{s}", .{trimForLog(out.stderr)});
                    self.freeOut(out);
                    return KgError.Data;
                },
                .transient => {
                    self.freeOut(out);
                    return KgError.DaemonUnavailable;
                },
            }
        }
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            const out = self.runRaw(args) catch {
                if (retry and attempt < TRANSIENT_RETRIES) {
                    sleepMs(TRANSIENT_RETRY_DELAY_MS);
                    continue;
                }
                return KgError.Transient;
            };
            if (out.exit_code == 0) return out;
            const err_name = parseCliError(out.stderr);
            const class = classifyCliError(err_name);
            log.warn("kg", "tinykg {s} exit={d} err={s} class={s} attempt={d}", .{ args[0], out.exit_code, err_name, @tagName(class), attempt });
            switch (class) {
                .data => {
                    self.setDetail("{s}", .{trimForLog(out.stderr)});
                    self.freeOut(out);
                    return KgError.Data;
                },
                .transient => {
                    self.freeOut(out);
                    if (retry and attempt < TRANSIENT_RETRIES) {
                        sleepMs(TRANSIENT_RETRY_DELAY_MS);
                        continue;
                    }
                    return KgError.Transient;
                },
            }
        }
    }

    const ErrClass = enum { transient, data };

    /// stderr `tinykg: error: <Name>` → Name;无匹配返回整段(截断)。
    fn parseCliError(stderr: []const u8) []const u8 {
        const marker = "tinykg: error: ";
        if (std.mem.indexOf(u8, stderr, marker)) |i| {
            const rest = stderr[i + marker.len ..];
            const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            return rest[0..end];
        }
        return trimForLog(stderr);
    }

    fn classifyCliError(name: []const u8) ErrClass {
        // ClaimHeld 归 data:租约被他人持有是明确业务事实,重试只会白等 3 轮。
        // SchemaProjectScopeViolation/ProjectTreeViolation 归 data:确定性结构违规(该类型属别的
        // project / project 树约束),**重试无用**,且必须让 .data 分支 setDetail 把原因写进
        // last_detail,否则 remember 的 scope 违规检测(找 "SchemaProjectScopeViolation" 串)匹配
        // 不上 → 孤儿清理+清晰错误全失效,agent 只收到空的 "(Transient: )"(PM 终审抓的接线漏)。
        const data_errors = [_][]const u8{
            "NotFound",
            "InvalidId",
            "InvalidNodeKind",
            "InvalidRelKind",
            "CycleDetected",
            "WouldCreateCycle",
            "InvalidRecord",
            "InvalidTaskTransition",
            "TaskHasOpenChildren",
            "TaskNotReady",
            "ClaimHeld",
            "SchemaProjectScopeViolation",
            "ProjectTreeViolation",
            // A missing optional control-plane capability is deterministic.
            // Retrying the identical read cannot install a newer TinyKG and
            // only delays the required fail-closed result.
            "UnknownCommand",
            // Deterministic capability/index-state failure.  Retrying the
            // exact search only burns turns and is not lock contention.
            "Unsupported",
        };
        for (data_errors) |d| {
            if (std.ascii.eqlIgnoreCase(name, d)) return .data;
        }
        return .transient; // Timeout(锁)/未知 → 瞬时,重试后上抛
    }

    fn dataError(self: *KgClient, comptime fmt: []const u8, args: anytype) KgError {
        self.setDetail(fmt, args);
        return KgError.Data;
    }

    fn mapTransportError(self: *KgClient, err: transport_mod.Error) KgError {
        if (err == transport_mod.Error.AmbiguousCommit) {
            const request_id = self.transport.daemon.ambiguousRequestId() orelse "unavailable";
            self.setDetail("TinyKG daemon transport: AmbiguousCommit request_id={s}", .{request_id});
            return KgError.AmbiguousCommit;
        }
        self.setDetail("TinyKG daemon transport: {s}", .{@errorName(err)});
        return switch (err) {
            transport_mod.Error.AmbiguousCommit => unreachable,
            transport_mod.Error.Backpressure => KgError.Backpressure,
            transport_mod.Error.OutOfMemory => KgError.OutOfMemory,
            transport_mod.Error.AuthenticationFailed, transport_mod.Error.IncompatibleDaemon, transport_mod.Error.InvalidConfiguration, transport_mod.Error.InvalidUrl => blk: {
                self.setDegraded("TinyKG daemon contract 失败: {s}；禁止 CLI fallback", .{@errorName(err)});
                break :blk KgError.Degraded;
            },
            else => KgError.DaemonUnavailable,
        };
    }

    fn setDetail(self: *KgClient, comptime fmt: []const u8, args: anytype) void {
        // 注意:args 可能借用旧 last_detail(prior 重包模式)——必须先 allocPrint 再换指针。
        const d = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        _ = self.detail_mu.lock();
        defer _ = self.detail_mu.unlock();
        if (self.last_detail) |old| self.allocator.free(old);
        self.last_detail = d;
    }

    pub fn detail(self: *const KgClient) []const u8 {
        return self.last_detail orelse "";
    }
};

// ── 纯函数区(可单测)──────────────────────────────────────────────

/// `task_packet\t<ID>\tstatus=<state>...` 首行解析。只接受 canonical 四态；
/// 不从 kind 或证据节点猜生命周期。
pub fn parseTaskPacketStatus(output: []const u8) ?TaskStatus {
    const line_end = std.mem.indexOfScalar(u8, output, '\n') orelse output.len;
    const line = output[0..line_end];
    if (!std.mem.startsWith(u8, line, "task_packet\t")) return null;
    var cols = std.mem.splitScalar(u8, line, '\t');
    _ = cols.next(); // task_packet
    _ = cols.next() orelse return null; // task id
    while (cols.next()) |col| {
        if (!std.mem.startsWith(u8, col, "status=")) continue;
        return TaskStatus.parse(col["status=".len..]);
    }
    return null;
}

/// tinykg TSV 转义(cli.zig:11001-11014 writeEscapedText)的逆:
/// `\\ \: \, \t \n \r \xNN` → 原字节。未知转义序列原样保留(容错)。
pub fn unescapeTsv(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c != '\\' or i + 1 >= text.len) {
            try out.append(allocator, c);
            continue;
        }
        i += 1;
        switch (text[i]) {
            '\\' => try out.append(allocator, '\\'),
            ':' => try out.append(allocator, ':'),
            ',' => try out.append(allocator, ','),
            't' => try out.append(allocator, '\t'),
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            'x' => {
                if (i + 2 < text.len) {
                    const hex = text[i + 1 .. i + 3];
                    if (std.fmt.parseInt(u8, hex, 16)) |b| {
                        try out.append(allocator, b);
                        i += 2;
                    } else |_| {
                        try out.appendSlice(allocator, text[i - 1 .. i + 1]);
                    }
                } else {
                    try out.appendSlice(allocator, text[i - 1 .. i + 1]);
                }
            },
            else => {
                // 未知转义:保留反斜杠与字符(容错,勿吞字节)。
                try out.append(allocator, '\\');
                try out.append(allocator, text[i]);
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

/// store-info 输出(`key=value` 每行)取字段。返回 borrow(指向 stdout)。
pub fn extractInfoField(stdout: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        if (line.len > key.len + 1 and std.mem.startsWith(u8, line, key) and line[key.len] == '=') {
            return std.mem.trim(u8, line[key.len + 1 ..], " \r");
        }
    }
    return null;
}

/// 从**空格分隔**输出(如 stats `nodes=3 edges=0`)按 whitespace 切 token 提取 `key=值`。
/// 区别于 extractInfoField(按**行**,用于 store-info 每行一字段);两种输出格式不同,不可混用。
pub fn extractStatField(stdout: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, stdout, " \t\r\n");
    while (it.next()) |tok| {
        if (tok.len > key.len + 1 and std.mem.startsWith(u8, tok, key) and tok[key.len] == '=') {
            return tok[key.len + 1 ..];
        }
    }
    return null;
}

fn jsonStr(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn truncateBytes(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    // 退到 UTF-8 边界。
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

pub fn boundedTextExcerptAlloc(allocator: std.mem.Allocator, text: []const u8, max: usize) ![]u8 {
    if (text.len <= max) return allocator.dupe(u8, text);
    const separator = "\n...\n";
    if (max <= separator.len + 1) return allocator.dupe(u8, truncateBytes(text, max));

    const content_budget = max - separator.len;
    const desired_head = content_budget - content_budget / 4;
    const head = truncateBytes(text, desired_head);
    const desired_tail = content_budget - head.len;
    var tail_start = text.len - @min(desired_tail, text.len);
    while (tail_start < text.len and (text[tail_start] & 0xC0) == 0x80) tail_start += 1;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, head.len + separator.len + text.len - tail_start);
    try out.appendSlice(allocator, head);
    try out.appendSlice(allocator, separator);
    try out.appendSlice(allocator, text[tail_start..]);
    return out.toOwnedSlice(allocator);
}

test "bounded recall excerpt preserves UTF-8 head and tail" {
    const text = "开头-alpha-中间内容需要省略-omega-结尾";
    const excerpt = try boundedTextExcerptAlloc(std.testing.allocator, text, 24);
    defer std.testing.allocator.free(excerpt);
    try std.testing.expect(excerpt.len <= 24);
    try std.testing.expect(std.unicode.utf8ValidateSlice(excerpt));
    try std.testing.expect(std.mem.startsWith(u8, excerpt, "开头"));
    try std.testing.expect(std.mem.endsWith(u8, excerpt, "结尾"));
    try std.testing.expect(std.mem.indexOf(u8, excerpt, "\n...\n") != null);
}

fn trimForLog(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \r\n\t");
    return if (t.len > 200) t[0..200] else t;
}

/// 从 `key=value` 行式输出提 u64(如 `document=5`)。
fn extractKvU64(text: []const u8, key: []const u8) ?u64 {
    const i = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[i + key.len ..];
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

/// 写临时文件(md 导入用;tinykg import-md-doc 只接文件路径)。
fn writeTmpFile(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const pz = try allocator.dupeZ(u8, path);
    defer allocator.free(pz);
    const f = std.c.fopen(pz.ptr, "w") orelse return error.WriteFailed;
    defer _ = std.c.fclose(f);
    if (bytes.len > 0) _ = std.c.fwrite(bytes.ptr, 1, bytes.len, f);
}

fn deleteTmpFile(allocator: std.mem.Allocator, path: []const u8) void {
    const pz = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(pz);
    _ = std.c.unlink(pz.ptr);
}

fn dirExists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    // F_OK: 存在即可(store 是目录;不存在 → init)。tinykg init 幂等,误判无害。
    return std.c.access(buf[0..path.len :0].ptr, std.c.F_OK) == 0;
}

fn ensureParentDir(allocator: std.mem.Allocator, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    // 逐级 mkdir(仿 memdir.ensureDir 精神;两级足够:~/.metacodes/kg)。
    const grand = std.fs.path.dirname(parent);
    if (grand) |g| {
        const gz = try allocator.dupeZ(u8, g);
        defer allocator.free(gz);
        _ = std.c.mkdir(gz, 0o755);
    }
    const pz = try allocator.dupeZ(u8, parent);
    defer allocator.free(pz);
    _ = std.c.mkdir(pz, 0o755);
}

fn sleepMs(ms: u64) void {
    time.sleepMs(ms); // 可移植(POSIX nanosleep / Windows Sleep)
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "resolveMemoryType:sharp 类型映射 + 大小写不敏感 + 拒绝 concept/未知" {
    // 概念类型 module/bug → observation node + schema_type 区分(不建 concept 催收池)。
    const m = resolveMemoryType("module").?;
    try testing.expectEqual(MemoryKind.observation, m.node_kind);
    try testing.expectEqualStrings("module", m.schema_type);
    const b = resolveMemoryType("bug").?;
    try testing.expectEqual(MemoryKind.observation, b.node_kind);
    try testing.expectEqualStrings("bug", b.schema_type);
    // 记忆 kind:node kind 与 schema_type 同名。
    try testing.expectEqual(MemoryKind.decision, resolveMemoryType("decision").?.node_kind);
    try testing.expectEqualStrings("decision", resolveMemoryType("decision").?.schema_type);
    try testing.expectEqual(MemoryKind.user_preference, resolveMemoryType("user_preference").?.node_kind);
    // 大小写不敏感 + trim(Linus MEDIUM-1)。
    try testing.expectEqualStrings("module", resolveMemoryType("Module").?.schema_type);
    try testing.expectEqualStrings("bug", resolveMemoryType("  BUG ").?.schema_type);
    // 拒绝 concept(催收池防线)+ 空 + tinykg 保留字 → null(调用方报错不静默)。
    try testing.expect(resolveMemoryType("concept") == null);
    try testing.expect(resolveMemoryType("") == null);
    try testing.expect(resolveMemoryType("schema_scope") == null); // tinykg 政策节点保留
    try testing.expect(resolveMemoryType("project") == null); // tinykg 结构类型保留
    // 项目级演化本体:自定义类型现在被接受(observation node + 自定义 schema_type)。
    const mig = resolveMemoryType("migration").?;
    try testing.expectEqual(MemoryKind.observation, mig.node_kind);
    try testing.expectEqualStrings("migration", mig.schema_type);
    try testing.expectEqualStrings("gui_feature", resolveMemoryType("gui_feature").?.schema_type);
    try testing.expectEqualStrings("schema_review", resolveMemoryType("  schema_review ").?.schema_type); // trim
    // 非法字符 / 超长 → 拒绝(不静默)。
    try testing.expect(resolveMemoryType("has space") == null);
    try testing.expect(resolveMemoryType("bad/slash") == null);
    try testing.expect(resolveMemoryType("x" ** 65) == null);
}

test "isBaseMemoryType:内置基类型不 auto-scope,自定义类型 auto-scope" {
    // 基类型(全局共用)→ true(不触发 auto-scope)。
    try testing.expect(KgClient.isBaseMemoryType("observation"));
    try testing.expect(KgClient.isBaseMemoryType("decision"));
    try testing.expect(KgClient.isBaseMemoryType("user_preference"));
    try testing.expect(KgClient.isBaseMemoryType("module"));
    try testing.expect(KgClient.isBaseMemoryType("bug"));
    // 自定义类型 → false(触发 auto-scope 到源 project,演化本体隔离)。
    try testing.expect(!KgClient.isBaseMemoryType("migration"));
    try testing.expect(!KgClient.isBaseMemoryType("gui_feature"));
    try testing.expect(!KgClient.isBaseMemoryType("schema_review"));
}

test "unescapeTsv 全转义表逆变换" {
    const a = testing.allocator;
    const out = try unescapeTsv(a, "a\\tb\\nc\\\\d\\:e\\,f\\rg\\x01h");
    defer a.free(out);
    try testing.expectEqualStrings("a\tb\nc\\d:e,f\rg\x01h", out);
}

test "unescapeTsv 容错:未知转义保留,尾部悬挂反斜杠保留" {
    const a = testing.allocator;
    const out = try unescapeTsv(a, "x\\qy\\");
    defer a.free(out);
    try testing.expectEqualStrings("x\\qy\\", out);
}

test "extractStatField 解析空格分隔 stats 行(memoryCount DoD,回归防注入死)" {
    // stats 真实输出:空格分隔单行。旧 bug:memoryCount 用按行的 extractInfoField 返 "3 edges=0"
    // → parseInt 失败 → 恒 0 → "共 N 条持久记忆"注入锚永不出现(启动注入静默半死)。
    try testing.expectEqualStrings("3", extractStatField("nodes=3 edges=0", "nodes").?);
    try testing.expectEqualStrings("0", extractStatField("nodes=3 edges=0", "edges").?);
    try testing.expect(extractStatField("nodes=3 edges=0", "missing") == null);
    try testing.expectEqual(@as(usize, 3), std.fmt.parseInt(usize, extractStatField("nodes=3 edges=0", "nodes").?, 10) catch 0);
}

test "extractInfoField 提取 store-info 键值" {
    const info = "db=/x/y\nnodes=26\nstorage_format_version=2\nschema_version=3\n";
    try testing.expectEqualStrings("2", extractInfoField(info, "storage_format_version").?);
    try testing.expectEqualStrings("3", extractInfoField(info, "schema_version").?);
    try testing.expectEqualStrings("26", extractInfoField(info, "nodes").?);
    try testing.expect(extractInfoField(info, "missing") == null);
}

test "task packet status 只接受 canonical 四态" {
    try testing.expectEqual(TaskStatus.open, parseTaskPacketStatus("task_packet\t7\tstatus=open\treadiness=ready\tlimit=1\n").?);
    try testing.expectEqual(TaskStatus.claimed, parseTaskPacketStatus("task_packet\t7\tstatus=claimed\treadiness=ready\tlimit=1\n").?);
    try testing.expectEqual(TaskStatus.completed, parseTaskPacketStatus("task_packet\t7\tstatus=completed\treadiness=-\tlimit=1\n").?);
    try testing.expectEqual(TaskStatus.failed, parseTaskPacketStatus("task_packet\t7\tstatus=failed\treadiness=-\tlimit=1\n").?);
    try testing.expect(parseTaskPacketStatus("task_packet\t7\tstatus=done\n") == null);
    try testing.expect(parseTaskPacketStatus("not_a_packet\t7\tstatus=open\n") == null);
}

test "MemoryKind parse 大小写不敏感 + 白名单外拒绝" {
    try testing.expectEqual(MemoryKind.decision, MemoryKind.parse("Decision").?);
    try testing.expectEqual(MemoryKind.user_preference, MemoryKind.parse("user_preference").?);
    try testing.expect(MemoryKind.parse("task") == null); // 任务 kind 不在记忆白名单
    try testing.expect(MemoryKind.parse("") == null);
}

test "路径解析优先级:env > config > 默认;显式 bin 不可用不静默回落" {
    const a = testing.allocator;
    var c1 = try KgClient.init(a, .{
        .home = "/home/u",
        .domain = "proj-x",
        .env_store = "/env/store.kg",
        .env_bin = "/nonexistent/bin/tinykg",
    });
    defer c1.deinit();
    try testing.expectEqualStrings("/env/store.kg", c1.store.fsPath().?);
    try testing.expect(c1.bin_path == null); // 显式指定但不可执行 → null → degraded 明示

    var c2 = try KgClient.init(a, .{
        .home = "/home/u",
        .domain = "proj-x",
        .env_store = "",
        .config_store = "/cfg/s.kg",
        .env_bin = "",
    });
    defer c2.deinit();
    try testing.expectEqualStrings("/cfg/s.kg", c2.store.fsPath().?);

    var c3 = try KgClient.init(a, .{ .home = "/home/u", .domain = "p", .env_store = "", .env_bin = "" });
    defer c3.deinit();
    try testing.expectEqualStrings("/home/u/.metacodes/kg/store.kg", c3.store.fsPath().?);
}

test "issue #30: 相对 store 路径以 home 为基准补全,绝不落在 cwd" {
    const a = testing.allocator;
    // 相对配置**不报错**(init 的错误会被 app.zig `catch return` 静默吞掉),而是补全。
    var rel = try KgClient.init(a, .{
        .home = "/home/u",
        .domain = "p",
        .env_store = "",
        .config_store = "relative/store.kg",
        .env_bin = "",
    });
    defer rel.deinit();
    try testing.expectEqualStrings("/home/u/relative/store.kg", rel.store.fsPath().?);
    try testing.expect(std.fs.path.isAbsolute(rel.store.fsPath().?));

    // 绝对路径原样保留。
    var abs = try KgClient.init(a, .{
        .home = "/home/u",
        .domain = "p",
        .env_store = "",
        .config_store = "/abs/store.kg",
        .env_bin = "",
    });
    defer abs.deinit();
    try testing.expectEqualStrings("/abs/store.kg", abs.store.fsPath().?);
}

test "issue #30: cloneForThread 不把未配置客户端提升成 CLI-exclusive" {
    const a = testing.allocator;
    // env/config 一个都不传 → injected_cli 假、无 io → transport=.unconfigured,
    // store 被赋成哨兵 "daemon-owned"(不是路径),bin_path=null。
    var parent = try KgClient.init(a, .{ .home = "/home/u", .domain = "p" });
    defer parent.deinit();
    try testing.expect(parent.transport == .unconfigured);
    try testing.expect(parent.bin_path == null);
    // 占位符是**协议可见**的:daemon 传输拿 argv[1] 与它做等值匹配后再剥掉
    // (runRaw / runCheckedRetry 的 shape 检查)。改动它会静默改变线上形状,所以钉死。
    try testing.expectEqualStrings("daemon-owned", parent.store.argvSlot());
    try testing.expect(parent.store.fsPath() == null);

    // 工作线程克隆。父客户端不拥有任何 store,克隆体也不该凭空拥有一个:
    // 提升成 .exclusive_cli 会重新解析出真 bin_path,而 store 仍是哨兵 →
    // ensureReady 拿它当相对路径跑 `tinykg init daemon-owned`,在 cwd 建库。
    var child = try parent.cloneForThread(a, "/home/u");
    defer child.deinit();
    try testing.expect(child.transport == .unconfigured);
    // 与探针同强度:不拥有 Store、没有 bin(被提升成 CLI 时正是它凭空出现),
    // 且 ensureReady 必须降级而不是去建库。ensureReady 会分配降级原因,走
    // testing allocator 顺带覆盖这条路径的泄漏。
    try testing.expect(child.store.fsPath() == null);
    try testing.expect(child.bin_path == null);
    child.ensureReady();
    try testing.expect(!child.ready);
}

test "bin 解析:没有 staged artifact 时绝不回退 PATH 或开发 checkout" {
    const a = testing.allocator;
    // 即便本机存在 TinyKG checkout，无显式路径或 staged artifact 也必须为 null。
    var c = try KgClient.init(a, .{
        .home = "/home/u",
        .domain = "p",
        .env_bin = "",
        .env_store = "",
        .exe_dir = "/tmp/definitely-no-vendor-xyzzy/bin",
    });
    defer c.deinit();
    try testing.expect(c.bin_path == null);
}

test "staged TinyKG 搜索只接受 install 和 eval 两种相邻布局" {
    var roots: [2][]const u8 = undefined;
    var count = KgClient.stagedSearchRoots("/opt/metacodes/bin", &roots);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqualStrings("/opt/metacodes", roots[0]);

    count = KgClient.stagedSearchRoots("/opt/metacodes/eval/bin", &roots);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("/opt/metacodes/eval", roots[0]);
    try testing.expectEqualStrings("/opt/metacodes", roots[1]);

    count = KgClient.stagedSearchRoots("/tmp/a/b/c/bin", &roots);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqualStrings("/tmp/a/b/c", roots[0]);
}

test "classifyCliError 三类归一" {
    try testing.expectEqual(KgClient.ErrClass.data, KgClient.classifyCliError("NotFound"));
    try testing.expectEqual(KgClient.ErrClass.data, KgClient.classifyCliError("WouldCreateCycle"));
    try testing.expectEqual(KgClient.ErrClass.transient, KgClient.classifyCliError("Timeout"));
    try testing.expectEqual(KgClient.ErrClass.transient, KgClient.classifyCliError("SomethingNew"));
    try testing.expectEqual(KgClient.ErrClass.data, KgClient.classifyCliError("Unsupported"));
    // 项目级 schema:确定性结构违规归 data(重试无用 + 让 .data 分支 setDetail 兜住原因,
    // 否则 remember 的 scope 违规检测匹配不上 → agent 收到空 Transient。PM 终审接线漏抓)。
    try testing.expectEqual(KgClient.ErrClass.data, KgClient.classifyCliError("SchemaProjectScopeViolation"));
    try testing.expectEqual(KgClient.ErrClass.data, KgClient.classifyCliError("ProjectTreeViolation"));
}

test "parseCliError 提取错误名" {
    try testing.expectEqualStrings("NotFound", KgClient.parseCliError("tinykg: error: NotFound\n"));
    try testing.expectEqualStrings("garbage", KgClient.parseCliError("garbage"));
}
