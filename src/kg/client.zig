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
    text: []u8, // owned(截断后)
    score: f64,

    pub fn deinit(self: *const RecallHit, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.domain);
        allocator.free(self.text);
    }
};

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
        /// cc-zig 可执行文件所在目录(用于定位 vendor/;null = 跳过 vendor 查找)。
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

    /// bin 查找顺序:env > config > vendor/tinykg/tinykg(exe 同级向上找)> dev 兜底。
    /// 每个候选做 access 检查,全失败返 null(→ ensureReady 判 degraded)。
    fn resolveBinPath(allocator: std.mem.Allocator, opts: ResolveOptions) !?[]u8 {
        if (opts.env_bin orelse envGet("METACODES_KG_BIN")) |v| {
            if (v.len > 0 and isExecutable(v)) return try allocator.dupe(u8, v);
            if (v.len > 0) return null; // 显式指定但不可用 → 不静默回落,degraded 明示
        }
        if (opts.config_bin) |v| {
            if (v.len > 0 and isExecutable(v)) return try allocator.dupe(u8, v);
            if (v.len > 0) return null;
        }
        if (opts.exe_dir) |dir| {
            const vendored = try std.fmt.allocPrint(allocator, "{s}/../vendor/tinykg/tinykg", .{dir});
            if (isExecutable(vendored)) return vendored;
            allocator.free(vendored);
        }
        const dev = try std.fmt.allocPrint(allocator, "{s}/prj/tinykg/zig-out/bin/tinykg", .{opts.home});
        if (isExecutable(dev)) return dev;
        allocator.free(dev);
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
            self.setDegraded("tinykg 二进制未找到。设 METACODES_KG_BIN=<path>,或 scripts/build-tinykg.sh 生成 vendor/tinykg/tinykg(需从已安装路径启动 metacodes 才能定位 vendor)", .{});
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
        var limbuf: [16]u8 = undefined;
        // 2× 超采:客户端过滤后仍能凑满 limit。
        const raw_limit = std.fmt.bufPrint(&limbuf, "{d}", .{limit * 2 + 4}) catch unreachable;
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
            const t_owned = self.allocator.dupe(u8, truncateBytes(text, 800)) catch return KgError.OutOfMemory;
            errdefer self.allocator.free(t_owned);
            results.append(self.allocator, .{
                .node_id = node_id,
                .kind = k_owned,
                .domain = d_owned,
                .text = t_owned,
                .score = score,
            }) catch return KgError.OutOfMemory;
        }
        return results.toOwnedSlice(self.allocator) catch KgError.OutOfMemory;
    }

    /// 取节点全文(`get <id>` TSV 第 3 列,已 unescape)。owned;NotFound 返 error.Data。
    fn fetchNodeText(self: *KgClient, node_id: u64) KgError![]u8 {
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
        const n = extractInfoField(out.stdout, "nodes") orelse return 0;
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
        // BM25 无"列全部"——用高频虚词兜底召回;更完整的列举 P2 走 tinyql query。
        return self.recall("the a 的 是 用", limit, false) catch |e| switch (e) {
            KgError.Data => &.{}, // 空 store 等 → 空列表,不算错误
            else => e,
        };
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
