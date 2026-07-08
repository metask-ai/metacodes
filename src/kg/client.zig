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

    pub fn deinit(self: *const RecallHit, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.domain);
        allocator.free(self.schema_type);
        allocator.free(self.text);
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
    text: []u8, // owned(unescaped)

    pub const Readiness = enum { ready, blocked, missing_dependencies };

    pub fn deinit(self: *const FrontierRow, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
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
        return std.fmt.allocPrint(allocator, "{s}/.cc-zig/kg/store.kg", .{opts.home});
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

    // ── 领域方法(P1:记忆 + 注入)─────────────────────────────────────

    /// 写记忆节点。返回 node id。scope_global=true → domain=global。
    pub fn remember(self: *KgClient, kind: MemoryKind, text: []const u8, schema_type: []const u8, scope_global: bool) KgError!u64 {
        const domain = if (scope_global) "global" else self.domain;
        const out = try self.runCheckedWrite(&.{
            "add-node",         self.store_path, kind.label(), text,
            "--domain",         domain,          "--schema-type", schema_type,
        });
        defer self.freeOut(out);
        // stdout: `node <id>`
        const line = std.mem.trim(u8, out.stdout, " \r\n");
        if (std.mem.startsWith(u8, line, "node ")) {
            return std.fmt.parseInt(u64, line["node ".len..], 10) catch self.dataError("add-node 输出不可解析: {s}", .{line});
        }
        return self.dataError("add-node 输出不可解析: {s}", .{line});
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
    pub fn importMarkdownDoc(self: *KgClient, markdown: []const u8) KgError!u64 {
        // 内容 hash 后缀:保证"不同计划→不同 source path→不同 document 节点"(避开增量合并的
        // order_key 撞车),"相同计划→同 path→真幂等"。
        const content_hash = std.hash.Wyhash.hash(0x7ac3, markdown);
        const tmp_path = std.fmt.allocPrint(self.allocator, "{s}.mdimport.{x}.tmp", .{ self.store_path, content_hash }) catch return KgError.OutOfMemory;
        defer self.allocator.free(tmp_path);
        writeTmpFile(self.allocator, tmp_path, markdown) catch return self.dataError("写 md 临时文件失败", .{});
        defer deleteTmpFile(self.allocator, tmp_path);

        const out = try self.runCheckedWrite(&.{
            "import-md-doc", self.store_path, tmp_path, "--domain", self.domain,
        });
        defer self.freeOut(out);
        // stdout: `import_md_doc ... document=<id> nodes_imported=..`
        if (extractKvU64(out.stdout, "document=")) |id| return id;
        return self.dataError("import-md-doc 输出无 document id: {s}", .{trimForLog(out.stdout)});
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
    // 契约见设计 §9 核对表:depends_on 串行、单次 revise 闭合、frontier 单层。

    /// 建任务节点(schema_type=todo|plan_step)。返回 node id。best-effort provenance。
    pub fn createTask(self: *KgClient, text: []const u8, schema_type: []const u8) KgError!u64 {
        const out = try self.runCheckedWrite(&.{
            "add-node",         self.store_path, "task",          text,
            "--domain",         self.domain,     "--schema-type", schema_type,
        });
        defer self.freeOut(out);
        const line = std.mem.trim(u8, out.stdout, " \r\n");
        if (std.mem.startsWith(u8, line, "node ")) {
            return std.fmt.parseInt(u64, line["node ".len..], 10) catch self.dataError("createTask 输出不可解析: {s}", .{line});
        }
        return self.dataError("createTask 输出不可解析: {s}", .{line});
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
        const out = try self.runCheckedWrite(&.{
            "revise",           self.store_path, id_str,          "verification",
            evidence,           "--domain",      self.domain,     "--schema-type",
            "verification",
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
        var limbuf: [16]u8 = undefined;
        // 超采:客户端过滤后仍能凑满 limit。typed recall 多一道 schema_type 过滤 → 8× 超采抗稀有类型少返。
        const oversample: usize = if (type_filter != null) limit * 8 + 8 else limit * 2 + 4;
        const raw_limit = std.fmt.bufPrint(&limbuf, "{d}", .{oversample}) catch unreachable;
        const out = try self.runChecked(&.{
            "search", self.store_path, query, "--limit", raw_limit, "--profile", "agent-memory", "--format", "json",
        });
        defer self.freeOut(out);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, out.stdout, .{}) catch
            return self.dataError("search JSON 解析失败", .{});
        defer parsed.deinit();
        if (parsed.value != .object) return self.dataError("search JSON 顶层非 object", .{});
        const hits_v = parsed.value.object.get("hits") orelse return self.dataError("search JSON 无 hits", .{});
        if (hits_v != .array) return self.dataError("search hits 非数组", .{});

        var results: std.ArrayList(RecallHit) = .empty;
        errdefer {
            for (results.items) |*h| h.deinit(self.allocator);
            results.deinit(self.allocator);
        }
        for (hits_v.array.items) |hit_v| {
            if (results.items.len >= limit) break;
            if (hit_v != .object) continue;
            const node_v = hit_v.object.get("node") orelse continue;
            if (node_v != .object) continue;
            const node = node_v.object;

            const kind = jsonStr(node.get("kind")) orelse continue;
            const schema_v = node.get("schema");
            const domain = if (schema_v != null and schema_v.? == .object)
                (jsonStr(schema_v.?.object.get("domain_id")) orelse "")
            else
                "";
            const schema_type = if (schema_v != null and schema_v.? == .object)
                (jsonStr(schema_v.?.object.get("schema_type")) orelse "")
            else
                "";

            // domain 过滤:当前项目 + global(tinykg search 无 --domain,实证)。
            if (!(std.mem.eql(u8, domain, self.domain) or std.mem.eql(u8, domain, "global"))) continue;
            // 任务面隔离。
            if (!include_tasks) {
                if (std.mem.eql(u8, kind, "task") or std.mem.eql(u8, kind, "verification")) continue;
                if (std.mem.eql(u8, schema_type, "todo")) continue;
            }
            // typed recall:按 schema_type 过滤(第三道客户端过滤,故上面 8× 超采)。
            if (type_filter) |tf| {
                if (!std.mem.eql(u8, schema_type, tf)) continue;
            }

            const id_v = node.get("id") orelse continue;
            const node_id: u64 = switch (id_v) {
                .integer => |i| if (i >= 0) @intCast(i) else continue,
                else => continue,
            };
            const score: f64 = switch (hit_v.object.get("score") orelse std.json.Value{ .float = 0 }) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => 0,
            };
            // 文本:search JSON 的 node **不含全文**(实证:只有 has_text 标志 + context_size),
            // 全文经 `get <id>` 取(TSV:id\tkind\ttext)。对返回的每条 hit 补一次 get。
            // 代价:每 hit 一次 spawn(recall 低频、limit≤8,可接受;P2 若上游给 search --include-text 可省)。
            const text = self.fetchNodeText(node_id) catch "";
            defer if (text.len > 0) self.allocator.free(text);

            // L1:先 dupe 三字段到局部 + errdefer,再 append——避免"kind 成功、domain 失败"泄漏。
            const k_owned = self.allocator.dupe(u8, kind) catch return KgError.OutOfMemory;
            errdefer self.allocator.free(k_owned);
            const d_owned = self.allocator.dupe(u8, domain) catch return KgError.OutOfMemory;
            errdefer self.allocator.free(d_owned);
            const s_owned = self.allocator.dupe(u8, schema_type) catch return KgError.OutOfMemory;
            errdefer self.allocator.free(s_owned);
            const t_owned = self.allocator.dupe(u8, truncateBytes(text, 800)) catch return KgError.OutOfMemory;
            errdefer self.allocator.free(t_owned);
            results.append(self.allocator, .{
                .node_id = node_id,
                .kind = k_owned,
                .domain = d_owned,
                .schema_type = s_owned,
                .text = t_owned,
                .score = score,
            }) catch return KgError.OutOfMemory;
        }
        return results.toOwnedSlice(self.allocator) catch KgError.OutOfMemory;
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
            // 行格式(实证):child_task\t<edge>\t<rel>\t<task_id>\treadiness=<r>\t<escaped text>
            if (!std.mem.startsWith(u8, line, "child_task\t") and !std.mem.startsWith(u8, line, "related_task\t")) continue;
            var cols = std.mem.splitScalar(u8, line, '\t');
            _ = cols.next(); // role
            _ = cols.next(); // edge id
            _ = cols.next(); // rel
            const id_col = cols.next() orelse continue;
            const ready_col = cols.next() orelse continue;
            const text_col = cols.rest();

            const task_id = std.fmt.parseInt(u64, id_col, 10) catch continue;
            const readiness: FrontierRow.Readiness = blk: {
                const v = if (std.mem.startsWith(u8, ready_col, "readiness=")) ready_col["readiness=".len..] else ready_col;
                if (std.mem.eql(u8, v, "ready")) break :blk .ready;
                if (std.mem.eql(u8, v, "blocked")) break :blk .blocked;
                break :blk .missing_dependencies;
            };
            const text = try unescapeTsv(self.allocator, text_col);
            rows.append(self.allocator, .{ .task_id = task_id, .readiness = readiness, .text = text }) catch {
                self.allocator.free(text);
                return KgError.OutOfMemory;
            };
        }
        return rows.toOwnedSlice(self.allocator) catch KgError.OutOfMemory;
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
        try self.appendRecentForDomain(&results, self.domain, limit);
        if (!std.mem.eql(u8, self.domain, "global")) {
            try self.appendRecentForDomain(&results, "global", limit);
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

    /// 把某 domain 的最近节点(list-recent TSV:id\tkind\ttext)解析成 owned RecallHit 追加到 results。
    /// 任务面隔离(task/verification)对齐 recall(include_tasks=false)。空 domain/空 store 静默跳过。
    fn appendRecentForDomain(self: *KgClient, results: *std.ArrayList(RecallHit), domain: []const u8, limit: usize) KgError!void {
        var limbuf: [16]u8 = undefined;
        const raw = std.fmt.bufPrint(&limbuf, "{d}", .{limit * 2 + 4}) catch unreachable;
        const out = self.runChecked(&.{ "list-recent", self.store_path, "--domain", domain, "--limit", raw }) catch |e| switch (e) {
            KgError.Data => return, // 空 store / 无此 domain → 跳过
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
            if (std.mem.eql(u8, kind, "task") or std.mem.eql(u8, kind, "verification")) continue;

            // L1:先 dupe 三字段到局部 + errdefer,再 append——避免部分成功泄漏(对齐 recall)。
            const k_owned = self.allocator.dupe(u8, kind) catch return KgError.OutOfMemory;
            errdefer self.allocator.free(k_owned);
            const d_owned = self.allocator.dupe(u8, domain) catch return KgError.OutOfMemory;
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
        const data_errors = [_][]const u8{ "NotFound", "InvalidId", "InvalidNodeKind", "InvalidRelKind", "CycleDetected", "WouldCreateCycle", "InvalidRecord" };
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
        const d = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
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
    // 逐级 mkdir(仿 memdir.ensureDir 精神;两级足够:~/.cc-zig/kg)。
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
    try testing.expectEqualStrings("/home/u/.cc-zig/kg/store.kg", c3.store_path);
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
