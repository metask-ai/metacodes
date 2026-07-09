//! TinyKG 集成客户端(设计:KG_DESIGN v3-final §1 D1/D2、§6)。
//!
//! tinykg = 跨会话真相源(记忆 + 计划任务 DAG),本模块是 cc-zig 侧唯一入口:
//! 子进程 CLI 驱动(tinykg 无 daemon;每次调用开店-操作-退出,全店目录锁串行)。
//!
//! 纪律(全部实证,见设计 §9 原语核对表):
//! - spawn 超时 35s **必须大于** tinykg 30s 目录锁超时——绝不在锁等待中 killpg
//!   制造无主锁(无主锁要等满 30s 才能被下一个调用者回收)。
//! - 版本门:store-info 的 storage_format_version 必须 = 2;不符 → degraded,
//!   绝不用不匹配的二进制碰 store(格式 skew 实证:直接 FileNotFound/损坏风险)。
//! - degraded 后不再 spawn:后续调用直接返回降级说明(防反复失败撞熔断器)。
//! - KG 是增强非依赖:任何失败都不影响 cc-zig 其余功能。
//!
//! 错误三类(设计 §6):transient(锁竞争/spawn 失败,重试 2 次)、
//! permanent(二进制缺/版本不符 → degraded)、data(环/NotFound → 透传模型改参)。

const std = @import("std");
const common = @import("../tools/common.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const log = @import("../util/log.zig");

pub const EXPECTED_STORAGE_FORMAT_VERSION = "2";
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
    text: []u8, // owned(截断后)
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

/// 记忆类型(窄概念图谱最小切片)→ (node kind, schema_type 标签)。
/// module/bug 是概念类型:落 **observation** node + schema_type 区分——**不建 concept kind**
/// (concept+schema_type=concept 会变 observation 催收池转世,Linus BLOCKER)。
/// 其余 kind 与 schema_type 同名。concept/未知 → null(调用方拒绝,不静默)。大小写不敏感 + trim。
pub const ResolvedType = struct { node_kind: MemoryKind, schema_type: []const u8 };
pub fn resolveMemoryType(raw: []const u8) ?ResolvedType {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(t, "observation")) return .{ .node_kind = .observation, .schema_type = "observation" };
    if (std.ascii.eqlIgnoreCase(t, "decision")) return .{ .node_kind = .decision, .schema_type = "decision" };
    if (std.ascii.eqlIgnoreCase(t, "user_preference")) return .{ .node_kind = .user_preference, .schema_type = "user_preference" };
    if (std.ascii.eqlIgnoreCase(t, "module")) return .{ .node_kind = .observation, .schema_type = "module" };
    if (std.ascii.eqlIgnoreCase(t, "bug")) return .{ .node_kind = .observation, .schema_type = "bug" };
    return null; // concept / 未知类型 → 拒绝
}

pub const FrontierRow = struct {
    task_id: u64,
    readiness: Readiness,
    /// v2 深遍历角色:leaf=可执行叶子(child_task)/ branch=开放复合节点(branch_task,
    /// 有开放子任务,靠子树闭合而闭合)/ related=关联任务(related_task,单层)。
    role: Role = .leaf,
    depth: usize = 1,
    claimed_by: ?[]u8 = null, // owned;null=无主(行内 "-" 或租约已过期)
    path: ?[]u8 = null, // owned 面包屑(祖先链);null=根直下
    text: []u8, // owned(unescaped)

    pub const Readiness = enum { ready, blocked, missing_dependencies };
    pub const Role = enum { leaf, branch, related };

    pub fn deinit(self: *const FrontierRow, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.claimed_by) |c| allocator.free(c);
        if (self.path) |p| allocator.free(p);
    }
};

pub const KgClient = struct {
    allocator: std.mem.Allocator,
    /// tinykg 二进制绝对路径(owned)。null = 未解析到 → degraded。
    bin_path: ?[]u8 = null,
    /// store 目录绝对路径(owned)。
    store_path: []u8,
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
    detail_mu: std.c.pthread_mutex_t = .{},
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
        if (self.bin_path) |p| self.allocator.free(p);
        self.allocator.free(self.store_path);
        self.allocator.free(self.domain);
        if (self.degraded_reason) |r| self.allocator.free(r);
        if (self.last_detail) |d| self.allocator.free(d);
        if (self.autosync_last_err) |e| self.allocator.free(e);
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
        /// dev 兜底 opt-in 开关(METACODES_KG_DEV);测试注入,null = 读真实 env。
        env_dev: ?[]const u8 = null,
        /// 测试注入:覆盖 exe 目录(null = selfExeDirPath 真实定位,不再依赖 argv[0])。
        exe_dir: ?[]const u8 = null,
    };

    /// 解析 bin/store 路径并构造(不做 IO 探测;ensureReady 才探)。
    pub fn init(allocator: std.mem.Allocator, opts: ResolveOptions) !KgClient {
        const store = try resolveStorePath(allocator, opts);
        errdefer allocator.free(store);
        const domain = try allocator.dupe(u8, opts.domain);
        errdefer allocator.free(domain);
        const bin = try resolveBinPath(allocator, opts);
        return .{
            .allocator = allocator,
            .bin_path = bin,
            .store_path = store,
            .domain = domain,
        };
    }

    fn resolveStorePath(allocator: std.mem.Allocator, opts: ResolveOptions) ![]u8 {
        if (opts.env_store orelse envGet("METACODES_KG_STORE")) |v| {
            if (v.len > 0) return allocator.dupe(u8, v);
        }
        if (opts.config_store) |v| {
            if (v.len > 0) return allocator.dupe(u8, v);
        }
        return std.fmt.allocPrint(allocator, "{s}/.metacodes/kg/store.kg", .{opts.home});
    }

    /// bin 查找顺序:env METACODES_KG_BIN > config kg_bin > **vendored**(自真实 exe 目录
    /// 向上逐级找 vendor/tinykg/tinykg)> dev 兜底(**仅 METACODES_KG_DEV 显式 opt-in**)。
    /// 每候选 access 检查,全失败返 null(→ ensureReady 判 degraded)。
    ///
    /// PM review 修:旧版① vendored 用调用方传的 exe_dir(argv[0] 派生),裸名经 PATH 启动
    /// 时 exe_dir=null → 跳过 vendored;② 相对偏移写死 `../vendor`,从 zig-out/bin 启动时
    /// 算成 zig-out/vendor(不存在,真 vendored 在 cc-zig/vendor 上溯两级)→ 两者叠加 → 静默
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
        // vendored:真实 exe 目录(opts.exe_dir 为测试注入覆盖;否则 OS 级 selfExeDir)向上搜。
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_dir: ?[]const u8 = opts.exe_dir orelse selfExeDir(&exe_buf);
        if (exe_dir) |dir| {
            if (try findVendoredUpward(allocator, dir)) |p| return p;
        }
        // dev 兜底:仅显式 opt-in(METACODES_KG_DEV,非空非 "0")。默认绝不静默落 dev——那是
        // 会漂移的 live 树,正是 dev-degraded 痛点根源(PM review)。
        if (opts.env_dev orelse envGet("METACODES_KG_DEV")) |v| {
            if (v.len > 0 and !std.mem.eql(u8, v, "0")) {
                const dev = try std.fmt.allocPrint(allocator, "{s}/prj/tinykg/zig-out/bin/tinykg", .{opts.home});
                if (isExecutable(dev)) return dev;
                allocator.free(dev);
            }
        }
        return null;
    }

    extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

    /// OS 级真实 exe 目录(**不依赖 argv[0]**,PATH 裸名启动也可靠——修 exe_dir=null 静默落 dev
    /// 的根)。macOS `_NSGetExecutablePath` / Linux `/proc/self/exe`,realpath 解 symlink(安装
    /// 常经 /usr/local/bin symlink)。失败/不支持平台 → null。返回 slice 承接在 buf。
    fn selfExeDir(buf: []u8) ?[]const u8 {
        const builtin = @import("builtin");
        var raw: [std.fs.max_path_bytes:0]u8 = undefined;
        const exe_path: [:0]const u8 = switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos => blk: {
                var size: u32 = @intCast(raw.len);
                if (_NSGetExecutablePath(&raw, &size) != 0) return null;
                const len = std.mem.indexOfScalar(u8, raw[0..], 0) orelse return null;
                break :blk raw[0..len :0];
            },
            .linux => blk: {
                const n = std.c.readlink("/proc/self/exe", &raw, raw.len);
                if (n <= 0) return null;
                const un: usize = @intCast(n);
                if (un >= raw.len) return null;
                raw[un] = 0;
                break :blk raw[0..un :0];
            },
            else => return null,
        };
        var rp: [std.fs.max_path_bytes]u8 = undefined;
        const resolved = std.c.realpath(exe_path.ptr, &rp);
        const full: []const u8 = if (resolved != null) std.mem.span(resolved.?) else exe_path;
        const dir = std.fs.path.dirname(full) orelse return null;
        if (dir.len == 0 or dir.len >= buf.len) return null;
        @memcpy(buf[0..dir.len], dir);
        return buf[0..dir.len];
    }

    /// 自 start_dir 向上逐级(≤6 级)找 `<dir>/vendor/tinykg/tinykg`。
    /// zig-out/bin 布局需上溯两级到 cc-zig/vendor;安装布局 <prefix>/bin 上溯一级到 <prefix>/vendor。
    fn findVendoredUpward(allocator: std.mem.Allocator, start_dir: []const u8) !?[]u8 {
        var cur: []const u8 = start_dir;
        var level: usize = 0;
        while (level < 6) : (level += 1) {
            const cand = try std.fmt.allocPrint(allocator, "{s}/vendor/tinykg/tinykg", .{cur});
            if (isExecutable(cand)) return cand;
            allocator.free(cand);
            cur = std.fs.path.dirname(cur) orelse break;
        }
        return null;
    }

    fn envGet(name: [:0]const u8) ?[]const u8 {
        const v = std.c.getenv(name.ptr) orelse return null;
        return std.mem.span(v);
    }

    fn isExecutable(path: []const u8) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= buf.len) return false;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        return std.c.access(buf[0..path.len :0].ptr, std.c.X_OK) == 0;
    }

    // ── 就绪与版本门(设计 §1 D2、§6)────────────────────────────────

    /// 探测并建立就绪态:二进制存在 → store 存在(缺则 init)→ 版本门。
    /// 任何失败 → degraded(reason 含修复提示),**绝不 throw**——KG 是增强非依赖。
    pub fn ensureReady(self: *KgClient) void {
        if (self.ready) return;
        const bin = self.bin_path orelse {
            self.setDegraded("tinykg 二进制未找到。跑 scripts/build-tinykg.sh 生成 vendor/tinykg/tinykg,或设 METACODES_KG_BIN=<path>(dev 树用 METACODES_KG_DEV=1 显式开启)", .{});
            return;
        };
        // store 缺 → init(先建父目录)。
        if (!dirExists(self.store_path)) {
            ensureParentDir(self.allocator, self.store_path) catch {};
            const out = self.runRaw(&.{ "init", self.store_path }) catch {
                self.setDegraded("tinykg init 失败(bin={s} store={s});检查磁盘/权限", .{ bin, self.store_path });
                return;
            };
            defer self.freeOut(out);
            if (out.exit_code != 0) {
                self.setDegraded("tinykg init 退出码 {d}: {s}", .{ out.exit_code, trimForLog(out.stderr) });
                return;
            }
        }
        // 版本门。
        const out = self.runRaw(&.{ "store-info", self.store_path }) catch {
            self.setDegraded("tinykg store-info 失败(bin={s} store={s})", .{ bin, self.store_path });
            return;
        };
        defer self.freeOut(out);
        if (out.exit_code != 0) {
            self.setDegraded("tinykg store-info 退出码 {d}: {s}", .{ out.exit_code, trimForLog(out.stderr) });
            return;
        }
        const ver = extractInfoField(out.stdout, "storage_format_version") orelse "missing";
        if (!std.mem.eql(u8, ver, EXPECTED_STORAGE_FORMAT_VERSION)) {
            self.setDegraded("store 格式版本不符:期望 {s} 实际 {s}(bin={s} store={s});见 vendor/tinykg/VERSION.txt,勿混用二进制版本", .{ EXPECTED_STORAGE_FORMAT_VERSION, ver, bin, self.store_path });
            return;
        }
        self.ready = true;
        log.info("kg", "ready bin={s} store={s} domain={s}", .{ bin, self.store_path, self.domain });
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
        const out = self.runChecked(&.{ "find", self.store_path, "project", name }) catch |e| switch (e) {
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
    fn projectNodeId(self: *KgClient, scope_global: bool, create: bool) KgError!?u64 {
        const slot = if (scope_global) &self.global_project_node_id else &self.project_node_id;
        const miss = if (scope_global) &self.global_project_miss else &self.project_miss;
        if (slot.*) |cached| return cached;
        if (!create and miss.*) return null; // negative cache:本 session 已确认无
        const name = if (scope_global) "global" else self.domain;
        if (!create) {
            if (try self.lookupProjectNodeId(name)) |found| {
                slot.* = found;
                return found;
            }
            miss.* = true;
            return null;
        }
        const out = try self.runCheckedWrite(&.{
            "ensure-node", self.store_path, "project", name, "--schema-type", "project",
        });
        defer self.freeOut(out);
        const id = parseNodeIdLine(out.stdout) orelse return self.dataError("ensure project 节点输出不可解析: {s}", .{trimForLog(out.stdout)});
        slot.* = id;
        miss.* = false;
        return id;
    }

    /// 把节点挂到 project 子树(govern-node --parent,tinykg 增量路径)。
    /// **必带 --schema-type**:govern-node 无此参数时会用 kind_label 覆盖 schema_type
    /// (module/bug 是 observation kind + schema_type 区分,漏传即类型信息丢失,实证)。
    /// govern 失败 → 清 project 缓存槽(可能是缓存的 project 节点已被 forget → NotFound;
    /// 不清则本 session 后续所有写全灭,Linus 严重4附赠)。
    fn attachToProject(self: *KgClient, node_id: u64, schema_type: []const u8, scope_global: bool) KgError!void {
        const pid = (try self.projectNodeId(scope_global, true)) orelse
            return self.dataError("project 节点解析失败(node {d} 未挂接)", .{node_id});
        var nbuf: [24]u8 = undefined;
        var pbuf: [24]u8 = undefined;
        const n_str = std.fmt.bufPrint(&nbuf, "{d}", .{node_id}) catch unreachable;
        const p_str = std.fmt.bufPrint(&pbuf, "{d}", .{pid}) catch unreachable;
        const out = self.runCheckedWrite(&.{
            "govern-node", self.store_path, n_str, "--parent", p_str, "--schema-type", schema_type,
        }) catch |e| {
            // 缓存失效:下次写重新 ensure(stale project id 自愈)。
            if (scope_global) {
                self.global_project_node_id = null;
                self.global_project_miss = false;
            } else {
                self.project_node_id = null;
                self.project_miss = false;
            }
            return e;
        };
        self.freeOut(out);
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
            "add-node", self.store_path, kind.label(), text, "--schema-type", schema_type,
        });
        defer self.freeOut(out);
        const id = parseNodeIdLine(out.stdout) orelse return self.dataError("add-node 输出不可解析: {s}", .{trimForLog(out.stdout)});
        self.attachToProject(id, schema_type, scope_global) catch |e| {
            // **所有分支重包 detail 带 node id**(Linus 严重4:Data 分支的 last_detail 是 tinykg
            // 裸 stderr,无孤儿 id,模型无法 /kg forget;重试 remember = 每次新建节点 → 孤儿堆积)。
            const prior = if (self.last_detail) |d| d else "";
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
            try self.runCheckedWrite(&.{ "gc-md-orphans", self.store_path, "--apply" })
        else
            try self.runChecked(&.{ "gc-md-orphans", self.store_path });
        defer self.freeOut(out);
        return self.allocator.dupe(u8, std.mem.trim(u8, out.stdout, " \r\n")) catch KgError.OutOfMemory;
    }

    fn importMarkdownDocAt(self: *KgClient, markdown: []const u8, path_key: u64, attach: bool) KgError!u64 {
        return self.importMarkdownDocAtLabeled(markdown, path_key, attach, null);
    }

    fn importMarkdownDocAtLabeled(self: *KgClient, markdown: []const u8, path_key: u64, attach: bool, source_label: ?[]const u8) KgError!u64 {
        const tmp_path = std.fmt.allocPrint(self.allocator, "{s}.mdimport.{x}.tmp", .{ self.store_path, path_key }) catch return KgError.OutOfMemory;
        defer self.allocator.free(tmp_path);
        writeTmpFile(self.allocator, tmp_path, markdown) catch return self.dataError("写 md 临时文件失败", .{});
        defer deleteTmpFile(self.allocator, tmp_path);

        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);
        argv.appendSlice(self.allocator, &.{ "import-md-doc", self.store_path, tmp_path }) catch return KgError.OutOfMemory;
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

    /// 渲染文档回 markdown(/kg plan 人类可见)。owned。
    pub fn renderMarkdownDoc(self: *KgClient, doc_id: u64) KgError![]u8 {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{doc_id}) catch unreachable;
        const out = try self.runChecked(&.{ "render-md-doc", self.store_path, id_str });
        defer self.freeOut(out);
        return self.allocator.dupe(u8, out.stdout) catch KgError.OutOfMemory;
    }

    // ── 任务 DAG(P2:write-through + plan 落图 + 图驱动)──────────────
    // 契约见设计 §9 核对表:depends_on 串行、单次 revise 闭合;frontier v2 深遍历
    // (可执行叶子集:branch/leaf 角色 + 祖先聚合 readiness + path + claim 租约)。

    /// 建任务节点(schema_type=todo|plan_step)。返回 node id。best-effort provenance。
    /// 挂接进项目子树(list-recent --project / search --project 可见)。
    pub fn createTask(self: *KgClient, text: []const u8, schema_type: []const u8) KgError!u64 {
        const out = try self.runCheckedWrite(&.{
            "add-node", self.store_path, "task", text, "--schema-type", schema_type,
        });
        defer self.freeOut(out);
        const id = parseNodeIdLine(out.stdout) orelse return self.dataError("createTask 输出不可解析: {s}", .{trimForLog(out.stdout)});
        self.attachToProject(id, schema_type, false) catch |e| {
            const prior = if (self.last_detail) |d| d else "";
            return self.dataError("任务节点 {d} 已建但挂接项目失败({s}: {s})。请勿整体重试;可 /kg forget {d}", .{ id, @errorName(e), prior, id });
        };
        return id;
    }

    /// 建边(contains/depends_on/blocks…)。环检测由 tinykg dag 层强制 → data 错透传。
    pub fn addEdge(self: *KgClient, src: u64, rel: []const u8, dst: u64) KgError!void {
        var sbuf: [24]u8 = undefined;
        var dbuf: [24]u8 = undefined;
        const s_str = std.fmt.bufPrint(&sbuf, "{d}", .{src}) catch unreachable;
        const d_str = std.fmt.bufPrint(&dbuf, "{d}", .{dst}) catch unreachable;
        const out = try self.runCheckedWrite(&.{ "add-edge", self.store_path, s_str, rel, d_str });
        self.freeOut(out);
    }

    /// 闭合任务:`revise <id> verification "<evidence>"`(单步,解锁依赖链+出 frontier)。
    pub fn closeTask(self: *KgClient, task_id: u64, evidence: []const u8) KgError!void {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{task_id}) catch unreachable;
        // 新 tinykg revise 无 --domain(实证 UnknownOption);挂接沿袭原节点(revise 是版本追加)。
        const out = try self.runCheckedWrite(&.{
            "revise",        self.store_path, id_str, "verification",
            evidence,        "--schema-type", "verification",
        });
        self.freeOut(out);
    }

    /// 删任务(TaskUpdate deleted → delete-node)。
    pub fn deleteTask(self: *KgClient, task_id: u64) KgError!void {
        return self.forget(task_id);
    }

    /// 单任务 readiness(TaskList 排序/看板用)。
    pub fn taskReadiness(self: *KgClient, task_id: u64) KgError!FrontierRow.Readiness {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{task_id}) catch unreachable;
        const out = try self.runChecked(&.{ "task-ready", self.store_path, id_str });
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
            "set-property", self.store_path, id_str, "session_id", session_id,
        }) catch return;
        self.freeOut(out);
    }

    /// BM25 检索 + 客户端过滤(domain=当前项目+global;默认排除 task/verification
    /// 与 schema_type=todo——记忆检索面与任务面隔离,设计 §2 治理)。
    /// 返回 owned slice(caller 逐项 deinit + free slice)。
    pub fn recall(self: *KgClient, query: []const u8, limit: usize, include_tasks: bool) KgError![]RecallHit {
        return self.recallTyped(query, limit, include_tasks, null);
    }

    /// type_filter 非 null 时按 schema_type 过滤(typed recall)。
    /// **best-effort 契约(Linus HIGH-2)**:BM25 按相关度排序不按类型,稀有类型可能全排在超采窗口外
    /// → 库里有该类型却返空。拉高超采倍数缓解,但不保证:typed recall 可能少返相关度低的同类节点。
    /// 正解是 tinykg server-side --schema-type 下推(本切片 defer)。空返 ≠ 库中无该类型。
    pub fn recallTyped(self: *KgClient, query: []const u8, limit: usize, include_tasks: bool, type_filter: ?[]const u8) KgError![]RecallHit {
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
        if (proj_id) |pid| try self.searchSubtreeInto(&results, pid, self.domain, query, limit, include_tasks, type_filter);
        if (glob_id) |gid| {
            if (proj_id == null or gid != proj_id.?) // domain=="global" 时两者同节点,防重扫
                try self.searchSubtreeInto(&results, gid, "global", query, limit, include_tasks, type_filter);
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
            "search",    self.store_path, query,    "--project",      p_str, "--limit", raw_limit,
            "--profile", "agent-memory",  "--format", "json",         "--include-text",
        }) catch return KgError.OutOfMemory;
        if (type_filter) |tf| argv.appendSlice(self.allocator, &.{ "--schema-type", tf }) catch return KgError.OutOfMemory;
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
            const t_owned = self.allocator.dupe(u8, truncateBytes(text, 800)) catch return KgError.OutOfMemory;
            errdefer self.allocator.free(t_owned);
            const sl_owned: []u8 = if (src_label.len > 0) (self.allocator.dupe(u8, src_label) catch return KgError.OutOfMemory) else @constCast(&[_]u8{});
            errdefer if (sl_owned.len > 0) self.allocator.free(sl_owned);
            results.append(self.allocator, .{
                .node_id = node_id,
                .kind = k_owned,
                .domain = d_owned,
                .schema_type = s_owned,
                .text = t_owned,
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
        const out = self.runChecked(&.{ "get", self.store_path, id_str, "--format", "json" }) catch return none;
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
        const out = try self.runChecked(&.{ "list-recent", self.store_path, "--kind", "project", "--limit", "200" });
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
        const out = self.runChecked(&.{ "list-recent", self.store_path, "--kind", "project", "--limit", "200" }) catch return null;
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
        const out = try self.runCheckedWrite(&.{ "reparent-contain", self.store_path, f_str, t_str });
        defer self.freeOut(out);
        return self.allocator.dupe(u8, std.mem.trim(u8, out.stdout, " \r\n")) catch KgError.OutOfMemory;
    }

    /// 取节点全文(`get <id>` TSV 第 3 列,已 unescape)。owned;NotFound 返 error.Data。
    pub fn fetchNodeText(self: *KgClient, node_id: u64) KgError![]u8 {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{node_id}) catch unreachable;
        const out = try self.runChecked(&.{ "get", self.store_path, id_str });
        defer self.freeOut(out);
        // TSV: id\tkind\ttext(text 可能多列——取第 3 列到行尾)。
        const line_end = std.mem.indexOfScalar(u8, out.stdout, '\n') orelse out.stdout.len;
        const line = out.stdout[0..line_end];
        var cols = std.mem.splitScalar(u8, line, '\t');
        _ = cols.next(); // id
        _ = cols.next(); // kind
        const text_col = cols.rest();
        return unescapeTsv(self.allocator, text_col) catch KgError.OutOfMemory;
    }

    /// task-frontier(注入段/看板用)。返回 owned rows。
    pub fn frontier(self: *KgClient, root_id: u64, limit: usize) KgError![]FrontierRow {
        var idbuf: [24]u8 = undefined;
        var limbuf: [16]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{root_id}) catch unreachable;
        const lim_str = std.fmt.bufPrint(&limbuf, "{d}", .{limit}) catch unreachable;
        const out = try self.runChecked(&.{
            "task-frontier", self.store_path, id_str, "--limit", lim_str,
        });
        defer self.freeOut(out);

        var rows: std.ArrayList(FrontierRow) = .empty;
        errdefer {
            for (rows.items) |*r| r.deinit(self.allocator);
            rows.deinit(self.allocator);
        }
        var it = std.mem.splitScalar(u8, out.stdout, '\n');
        while (it.next()) |line| {
            // 行格式 v2(深遍历):<role>\t<edge>\t<rel>\t<task_id>\treadiness=<r>\tdepth=<n>\tclaimed_by=<v>\tpath=<v>\t<escaped text>
            // v1 兼容:readiness 后直接是 text(缺 depth= 列)。
            const role: FrontierRow.Role = if (std.mem.startsWith(u8, line, "child_task\t"))
                .leaf
            else if (std.mem.startsWith(u8, line, "branch_task\t"))
                .branch
            else if (std.mem.startsWith(u8, line, "related_task\t"))
                .related
            else
                continue;
            var cols = std.mem.splitScalar(u8, line, '\t');
            _ = cols.next(); // role
            _ = cols.next(); // edge id
            _ = cols.next(); // rel
            const id_col = cols.next() orelse continue;
            const ready_col = cols.next() orelse continue;

            const task_id = std.fmt.parseInt(u64, id_col, 10) catch continue;
            const readiness: FrontierRow.Readiness = blk: {
                const v = if (std.mem.startsWith(u8, ready_col, "readiness=")) ready_col["readiness=".len..] else ready_col;
                if (std.mem.eql(u8, v, "ready")) break :blk .ready;
                if (std.mem.eql(u8, v, "blocked")) break :blk .blocked;
                break :blk .missing_dependencies;
            };

            var depth: usize = 1;
            var claimed_by: ?[]u8 = null;
            errdefer if (claimed_by) |c| self.allocator.free(c);
            var path: ?[]u8 = null;
            errdefer if (path) |p| self.allocator.free(p);
            var text_col: []const u8 = undefined;
            const after_ready = cols.rest();
            if (std.mem.startsWith(u8, after_ready, "depth=")) {
                const depth_col = cols.next() orelse continue;
                depth = std.fmt.parseInt(usize, depth_col["depth=".len..], 10) catch 1;
                const claim_col = cols.next() orelse continue;
                if (std.mem.startsWith(u8, claim_col, "claimed_by=")) {
                    const v = claim_col["claimed_by=".len..];
                    if (v.len > 0 and !std.mem.eql(u8, v, "-")) claimed_by = try unescapeTsv(self.allocator, v);
                }
                const path_col = cols.next() orelse continue;
                if (std.mem.startsWith(u8, path_col, "path=")) {
                    const v = path_col["path=".len..];
                    if (v.len > 0 and !std.mem.eql(u8, v, "-")) path = try unescapeTsv(self.allocator, v);
                }
                text_col = cols.rest();
            } else {
                text_col = after_ready;
            }

            const text = try unescapeTsv(self.allocator, text_col);
            rows.append(self.allocator, .{
                .task_id = task_id,
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
        const out = try self.runChecked(&.{ "task-claim", self.store_path, id_str, "--by", agent });
        self.freeOut(out);
    }

    /// 释放租约(task-release --by;租约立即过期)。身份对称:只能放自己的活租约,
    /// 他人活租约会被 CLI 拒(ClaimHeld)。闭合任务后无需调用——闭合本身出 frontier。
    pub fn releaseTask(self: *KgClient, task_id: u64, agent: []const u8) KgError!void {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{task_id}) catch unreachable;
        const out = try self.runChecked(&.{ "task-release", self.store_path, id_str, "--by", agent });
        self.freeOut(out);
    }

    /// 本项目记忆节点数(启动锚:注入段告诉模型"存在 N 条记忆",提升 recall 采用率
    /// ——PM 反馈#3,对齐 A/B 结论"架构位置 > 措辞")。近似:store 总节点数(P1 无
    /// per-domain 计数原语;绝大多数早期用户单项目,误差可接受)。失败返 0(不阻塞)。
    pub fn memoryCount(self: *KgClient) usize {
        if (!self.ready) return 0;
        const out = self.runChecked(&.{ "stats", self.store_path }) catch return 0;
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
        const out = self.runChecked(&.{ "list-recent", self.store_path, "--project", p_str, "--with-type", "--limit", "200" }) catch return;
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
        const out = try self.runCheckedWrite(&.{ "delete-node", self.store_path, id_str });
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
        const out = self.runChecked(&.{ "list-recent", self.store_path, "--project", p_str, "--limit", raw }) catch |e| switch (e) {
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
            const t_owned = self.allocator.dupe(u8, truncateBytes(text_un, 800)) catch return KgError.OutOfMemory;
            errdefer self.allocator.free(t_owned);

            results.append(self.allocator, .{
                .node_id = node_id,
                .kind = k_owned,
                .domain = d_owned,
                .schema_type = s_owned,
                .text = t_owned,
                .score = 0,
            }) catch return KgError.OutOfMemory;
        }
    }

    /// 节点是否存在且为 task kind(stale kg_root 防御,设计 §3)。
    pub fn nodeIsTask(self: *KgClient, node_id: u64) KgError!bool {
        var idbuf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{node_id}) catch unreachable;
        const out = self.runChecked(&.{ "get", self.store_path, id_str }) catch |e| switch (e) {
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
        return common.spawnCaptureWithStderrTimed(argv.items, self.allocator, self.abort, SPAWN_TIMEOUT_MS, null);
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
        const data_errors = [_][]const u8{ "NotFound", "InvalidId", "InvalidNodeKind", "InvalidRelKind", "CycleDetected", "WouldCreateCycle", "InvalidRecord", "ClaimHeld" };
        for (data_errors) |d| {
            if (std.ascii.eqlIgnoreCase(name, d)) return .data;
        }
        return .transient; // Timeout(锁)/未知 → 瞬时,重试后上抛
    }

    fn dataError(self: *KgClient, comptime fmt: []const u8, args: anytype) KgError {
        self.setDetail(fmt, args);
        return KgError.Data;
    }

    fn setDetail(self: *KgClient, comptime fmt: []const u8, args: anytype) void {
        // 注意:args 可能借用旧 last_detail(prior 重包模式)——必须先 allocPrint 再换指针。
        const d = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        _ = std.c.pthread_mutex_lock(&self.detail_mu);
        defer _ = std.c.pthread_mutex_unlock(&self.detail_mu);
        if (self.last_detail) |old| self.allocator.free(old);
        self.last_detail = d;
    }

    pub fn detail(self: *const KgClient) []const u8 {
        return self.last_detail orelse "";
    }
};

// ── 纯函数区(可单测)──────────────────────────────────────────────

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
    var ts: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = std.c.nanosleep(&ts, null);
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
    // 拒绝 concept(催收池防线)+ 未知值 → null(调用方报错不静默)。
    try testing.expect(resolveMemoryType("concept") == null);
    try testing.expect(resolveMemoryType("function") == null);
    try testing.expect(resolveMemoryType("") == null);
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
    const info = "db=/x/y\nnodes=26\nstorage_format_version=2\nschema_version=2\n";
    try testing.expectEqualStrings("2", extractInfoField(info, "storage_format_version").?);
    try testing.expectEqualStrings("26", extractInfoField(info, "nodes").?);
    try testing.expect(extractInfoField(info, "missing") == null);
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
    try testing.expectEqualStrings("/env/store.kg", c1.store_path);
    try testing.expect(c1.bin_path == null); // 显式指定但不可执行 → null → degraded 明示

    var c2 = try KgClient.init(a, .{
        .home = "/home/u",
        .domain = "proj-x",
        .env_store = "",
        .config_store = "/cfg/s.kg",
        .env_bin = "",
    });
    defer c2.deinit();
    try testing.expectEqualStrings("/cfg/s.kg", c2.store_path);

    var c3 = try KgClient.init(a, .{ .home = "/home/u", .domain = "p", .env_store = "", .env_bin = "" });
    defer c3.deinit();
    try testing.expectEqualStrings("/home/u/.metacodes/kg/store.kg", c3.store_path);
}

test "bin 解析:dev 兜底默认关(opt-in),vendored 缺失不静默落 dev" {
    const a = testing.allocator;
    // exe_dir 指向无 vendored 的目录 + dev 未 opt-in(env_dev="")→ bin_path null——
    // **即便本机 ~/prj/tinykg 有 dev 树也绝不静默落**(旧 bug:静默落漂移 dev 树 = degraded 根源)。
    var c = try KgClient.init(a, .{
        .home = "/home/u",
        .domain = "p",
        .env_bin = "",
        .env_store = "",
        .env_dev = "", // dev 兜底关
        .exe_dir = "/tmp/definitely-no-vendor-xyzzy/bin",
    });
    defer c.deinit();
    try testing.expect(c.bin_path == null);

    // "0" 也算关。
    var c0 = try KgClient.init(a, .{
        .home = "/home/u",
        .domain = "p",
        .env_bin = "",
        .env_store = "",
        .env_dev = "0",
        .exe_dir = "/tmp/definitely-no-vendor-xyzzy/bin",
    });
    defer c0.deinit();
    try testing.expect(c0.bin_path == null);
    // 注:vendored 向上搜的正确性由真机验证(metacodes 从 zig-out/bin 启动解析到
    // cc-zig/vendor/tinykg/tinykg)——比 mock 文件系统更强的证据。
}

test "classifyCliError 三类归一" {
    try testing.expectEqual(KgClient.ErrClass.data, KgClient.classifyCliError("NotFound"));
    try testing.expectEqual(KgClient.ErrClass.data, KgClient.classifyCliError("WouldCreateCycle"));
    try testing.expectEqual(KgClient.ErrClass.transient, KgClient.classifyCliError("Timeout"));
    try testing.expectEqual(KgClient.ErrClass.transient, KgClient.classifyCliError("SomethingNew"));
}

test "parseCliError 提取错误名" {
    try testing.expectEqualStrings("NotFound", KgClient.parseCliError("tinykg: error: NotFound\n"));
    try testing.expectEqualStrings("garbage", KgClient.parseCliError("garbage"));
}
