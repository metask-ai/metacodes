//! LSP service:管理多个 client(按 server_id+root 缓存)+ broken-set + delta baseline + idle-reap
//! (对齐 hermes manager.py 的 LSPService)。被动诊断入口:snapshotBaseline(写前)/ getDiagnostics(写后)。
//!
//! **delta**:v1 = 当前诊断 − baseline(按 diagKey 去重),然后 roll baseline forward。range_shift 行移
//! 校正(编辑插删行导致下游诊断行号偏移误判"新")列为后续精化(hermes range_shift.py),v1 先不做——
//! 多行编辑会略微多报,但不漏报、不崩。
//!
//! **broken-set**:spawn/init 失败的 (server_id, root) 永不重试(本进程内)。gate + spawn 都查。
//! **idle-reap**:后台线程每 30s 扫,关闭 idle > IDLE_TIMEOUT 的 client(hermes 只写不读 _last_used,
//! 这里真做)。
//! **graceful degradation**:任何失败 → 无诊断(空串),绝不 fail 调用方(Edit 写入)。
//!
//! **已知取舍(非精确 delta,登记)**:
//!  - 冷启动误报(Linus #3):大仓首次 spawn(rust-analyzer/gopls 建索引)8s baseline 窗口内诊断
//!    出不完 → baseline 偏空 → 写后 delta 把文件**存量**错误误算成"本次编辑引入"。warm server(zls
//!    /pyright ~1s)无此问题;冷启动仅首编辑一次,之后 client 缓存 warm。best-effort 可接受,不漏报。
//!  - per-edit 延迟税(Linus #4):gated 仓里每次 Edit/Write 在盘写**后**串行阻塞
//!    snapshotBaseline(≤8s)+getDiagnostics(≤6s);盘写本身不被阻塞(安全第一),但 tool 结果返回
//!    多等 ≤14s(warm)/≤26s(冷 spawn)。可被 abort 打断。未来若嫌重可换 didChange delta 免全等。
const std = @import("std");
const pfs = @import("platform").fs;
const sync = @import("platform").sync;
const client_mod = @import("client.zig");
const servers = @import("servers.zig");
const workspace = @import("workspace.zig");
const reporter = @import("reporter.zig");
const transport = @import("transport.zig");

const Client = client_mod.Client;

const BASELINE_WAIT_MS: u64 = 8_000;
const DIAGNOSTICS_WAIT_MS: u64 = 6_000;
const IDLE_TIMEOUT_MS: u64 = 10 * 60 * 1000; // 10 分钟
const REAP_INTERVAL_MS: u64 = 30 * 1000;

/// baseline:某 path 上次的诊断集(owned),供 delta 去重。
const Baseline = struct {
    arena: std.heap.ArenaAllocator,
    keys: std.StringHashMap(void), // diagKey 集合(借 arena)
    fn deinit(self: *Baseline) void {
        self.keys.deinit();
        self.arena.deinit();
    }
};

const ClientEntry = struct {
    client: *Client,
    last_used_ms: i64,
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    cwd: []const u8, // owned;git workspace 门用
    abort: ?transport.AbortCheck = null, // M2:透传给每个 client 的等待,Ctrl+C 可中断

    mutex: sync.Mutex = .{},
    reaper_cond: sync.Condition = .{}, // reaper 间隔等待,shutdown 立即唤醒
    clients: std.StringHashMap(ClientEntry), // key="server_id\x00root"(owned)
    broken: std.StringHashMap(void), // key 同上(owned);永久
    baselines: std.StringHashMap(Baseline), // path(owned) → baseline

    reaper: ?std.Thread = null,
    stop: bool = false,

    pub fn create(allocator: std.mem.Allocator, cwd: []const u8, abort: ?transport.AbortCheck) !*Service {
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .cwd = try allocator.dupe(u8, cwd),
            .abort = abort,
            .clients = std.StringHashMap(ClientEntry).init(allocator),
            .broken = std.StringHashMap(void).init(allocator),
            .baselines = std.StringHashMap(Baseline).init(allocator),
        };
        self.reaper = std.Thread.spawn(.{}, reaperLoop, .{self}) catch null;
        return self;
    }

    fn lock(self: *Service) void {
        _ = self.mutex.lock();
    }
    fn unlock(self: *Service) void {
        _ = self.mutex.unlock();
    }

    /// 该文件是否应启动 LSP:git workspace 内 + 有对应 server + 未 broken。
    /// 返回 {def, git_root, server_root}(root 写进 caller 的 buf)或 null。
    fn resolve(self: *Service, path: []const u8, git_buf: []u8, root_buf: []u8) ?struct {
        def: *const servers.ServerDef,
        server_root: []const u8,
    } {
        const def = servers.findServerForFile(path) orelse return null;
        const wsr = workspace.resolveWorkspaceForFile(path, self.cwd, git_buf);
        if (!wsr.gated_in) return null; // 不在 git 仓 → 不启动
        const git_root = wsr.root;
        const server_root = servers.resolveServerRoot(def, path, git_root, root_buf) orelse return null;
        return .{ .def = def, .server_root = server_root };
    }

    fn clientKey(self: *Service, server_id: []const u8, root: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ server_id, root });
    }

    /// 取或 spawn client(缓存 by server_id+root)。broken → null。spawn/init 失败 → 标 broken + null。
    fn getOrSpawn(self: *Service, def: *const servers.ServerDef, root: []const u8) ?*Client {
        const key = self.clientKey(def.server_id, root) catch return null;
        defer self.allocator.free(key);

        self.lock();
        if (self.broken.contains(key)) {
            self.unlock();
            return null;
        }
        if (self.clients.getEntry(key)) |e| {
            e.value_ptr.last_used_ms = nowMs();
            const c = e.value_ptr.client;
            self.unlock();
            return c;
        }
        self.unlock();

        // 解析 binary。
        var bin_buf: [std.fs.max_path_bytes]u8 = undefined;
        const bin = servers.which(def.binary, &bin_buf) orelse {
            self.markBroken(key);
            return null;
        };

        // 构造 argv(binary + args,null 结尾)。
        var argv_store = std.ArrayList(?[*:0]const u8).empty;
        defer {
            for (argv_store.items) |a| if (a) |p| self.allocator.free(std.mem.span(p));
            argv_store.deinit(self.allocator);
        }
        const bin_z = self.allocator.dupeZ(u8, bin) catch {
            self.markBroken(key);
            return null;
        };
        argv_store.append(self.allocator, bin_z.ptr) catch {
            self.allocator.free(bin_z); // append 失败:bin_z 未进 store,手动 free(对齐下方 def.args 循环)
            self.markBroken(key);
            return null;
        };
        for (def.args) |arg| {
            const z = self.allocator.dupeZ(u8, arg) catch {
                self.markBroken(key);
                return null;
            };
            argv_store.append(self.allocator, z.ptr) catch {
                self.allocator.free(z);
                self.markBroken(key);
                return null;
            };
        }
        argv_store.append(self.allocator, null) catch {
            self.markBroken(key);
            return null;
        };

        const cl = Client.create(self.allocator, argv_store.items, def.seed_first_push, self.abort) catch {
            self.markBroken(key);
            return null;
        };
        // initialize(root → file:// URI)。失败 → shutdown + broken。
        var uri_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
        const root_uri = std.fmt.bufPrint(&uri_buf, "file://{s}", .{root}) catch {
            cl.shutdown();
            self.markBroken(key);
            return null;
        };
        cl.initialize(root_uri) catch {
            cl.shutdown();
            self.markBroken(key);
            return null;
        };

        // 缓存(key owned 转给 map)。
        const owned_key = self.allocator.dupe(u8, key) catch {
            cl.shutdown();
            return null;
        };
        self.lock();
        // double-check(Linus #1):getOrSpawn 是 check-then-spawn,spawn 期间(无锁,最长 12s)
        // 别的 caller 可能已抢先 put 同 key。getOrPut 命中已存在 → 我们这个 client 多余,shutdown
        // 它复用缓存里那个,杜绝孤儿 language server 进程 + fd 泄漏。今天单 caller 不可达,但
        // roadmap 要把 lsp 透传进 subagent(并发),这里必须提前修死。
        const gop = self.clients.getOrPut(owned_key) catch {
            self.unlock();
            self.allocator.free(owned_key);
            cl.shutdown();
            return null;
        };
        if (gop.found_existing) {
            const existing = gop.value_ptr.client; // unlock 前快照(value_ptr 释锁后可能失效)
            gop.value_ptr.last_used_ms = nowMs();
            self.unlock();
            self.allocator.free(owned_key); // 被抢先:owned_key 未被 map 采用,free
            cl.shutdown(); // 关掉我们多余 spawn 的那个
            return existing;
        }
        gop.value_ptr.* = .{ .client = cl, .last_used_ms = nowMs() }; // owned_key 已转给 map,不 free
        self.unlock();
        return cl;
    }

    fn markBroken(self: *Service, key: []const u8) void {
        const k = self.allocator.dupe(u8, key) catch return;
        self.lock();
        self.broken.put(k, {}) catch self.allocator.free(k);
        self.unlock();
    }

    /// 写前快照 baseline:open 文件 + 等诊断 + 存为 baseline(供后续 delta 去重)。best-effort。
    pub fn snapshotBaseline(self: *Service, path: []const u8, text: []const u8) void {
        var git_buf: [std.fs.max_path_bytes]u8 = undefined;
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const r = self.resolve(path, &git_buf, &root_buf) orelse return;
        const cl = self.getOrSpawn(r.def, r.server_root) orelse return;
        const ver = cl.openFile(path, text) catch return;
        cl.waitForDiagnostics(ver, BASELINE_WAIT_MS);
        self.storeBaseline(path, cl);
    }

    /// 写后取 delta 诊断,格式化成 `<diagnostics>` 块(owned;无诊断/未 gate → 空串)。best-effort。
    pub fn getDiagnostics(self: *Service, alloc: std.mem.Allocator, path: []const u8, text: []const u8) []u8 {
        return self.getDiagnosticsInner(alloc, path, text) catch alloc.dupe(u8, "") catch "";
    }

    fn getDiagnosticsInner(self: *Service, alloc: std.mem.Allocator, path: []const u8, text: []const u8) ![]u8 {
        // LSP 子系统保持自包含(不 import core/util,test:lsp 隔离可编)。observability 由集成层
        // (app/edit)负责;此处失败静默返空(graceful degradation)。
        var git_buf: [std.fs.max_path_bytes]u8 = undefined;
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const r = self.resolve(path, &git_buf, &root_buf) orelse return alloc.dupe(u8, "");
        const cl = self.getOrSpawn(r.def, r.server_root) orelse return alloc.dupe(u8, "");
        const ver = cl.openFile(path, text) catch return alloc.dupe(u8, "");
        cl.waitForDiagnostics(ver, DIAGNOSTICS_WAIT_MS);

        const diags = try cl.diagnosticsFor(alloc, path);
        defer client_mod.freeDiags(alloc, diags);

        // delta:滤掉 baseline 已有的(按 diagKey)。
        var new_diags = std.ArrayList(reporter.Diagnostic).empty;
        defer new_diags.deinit(alloc);
        self.lock();
        const base = self.baselines.get(path);
        for (diags) |d| {
            var kbuf: [512]u8 = undefined;
            const k = diagKey(&kbuf, d);
            const in_base = if (base) |b| b.keys.contains(k) else false;
            if (!in_base) new_diags.append(alloc, d) catch {};
        }
        self.unlock();

        const out = try reporter.reportForFile(alloc, path, new_diags.items, &reporter.DEFAULT_SEVERITIES);
        errdefer alloc.free(out);
        const capped = try reporter.truncate(alloc, out);
        alloc.free(out);

        // roll baseline forward:当前全量存为新 baseline(下次 delta 相对此)。
        self.storeBaseline(path, cl);
        return capped;
    }

    /// 取文件符号(documentSymbol,替 tree-sitter 供 CodeMap/FindSymbol/Read-outline)。
    /// best-effort:无 server/非 git workspace/请求失败 → 空 LspSymbols。gpa 拥有返回 arena,caller deinit。
    /// text = 文件当前全文(先 didOpen/didChange 同步给 server 再请求)。
    pub fn getSymbols(self: *Service, gpa: std.mem.Allocator, path: []const u8, text: []const u8) client_mod.LspSymbols {
        return self.getSymbolsInner(gpa, path, text) catch emptySymbols(gpa);
    }

    fn getSymbolsInner(self: *Service, gpa: std.mem.Allocator, path: []const u8, text: []const u8) !client_mod.LspSymbols {
        var git_buf: [std.fs.max_path_bytes]u8 = undefined;
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const r = self.resolve(path, &git_buf, &root_buf) orelse return emptySymbols(gpa);
        const cl = self.getOrSpawn(r.def, r.server_root) orelse return emptySymbols(gpa);
        _ = cl.openFile(path, text) catch return emptySymbols(gpa); // 同步文档 → server 有 overlay
        return cl.documentSymbol(gpa, path);
    }

    fn emptySymbols(gpa: std.mem.Allocator) client_mod.LspSymbols {
        return .{ .items = &.{}, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    /// 存 path 的当前诊断为 baseline(diagKey 集合)。持锁内替换旧的。
    fn storeBaseline(self: *Service, path: []const u8, cl: *Client) void {
        const diags = cl.diagnosticsFor(self.allocator, path) catch return;
        defer client_mod.freeDiags(self.allocator, diags);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const aa = arena.allocator();
        var keys = std.StringHashMap(void).init(self.allocator);
        for (diags) |d| {
            var kbuf: [512]u8 = undefined;
            const k = diagKey(&kbuf, d);
            const owned = aa.dupe(u8, k) catch continue;
            keys.put(owned, {}) catch {};
        }
        var bl = Baseline{ .arena = arena, .keys = keys };

        self.lock();
        defer self.unlock();
        if (self.baselines.getEntry(path)) |e| {
            e.value_ptr.deinit();
            e.value_ptr.* = bl;
        } else {
            const pk = self.allocator.dupe(u8, path) catch {
                bl.deinit();
                return;
            };
            self.baselines.put(pk, bl) catch {
                self.allocator.free(pk);
                bl.deinit();
            };
        }
    }

    // ── idle-reap ──────────────────────────────────────────────────────────
    fn reaperLoop(self: *Service) void {
        while (true) {
            // 等 REAP_INTERVAL 或被 shutdown 立即唤醒(cond timedwait,非 nanosleep——否则 shutdown
            // 要等满一个 30s 周期,join 阻塞)。
            self.lock();
            while (!self.stop) {
                // 相对超时：被 shutdown signal 唤醒(true)→重查 !self.stop 退出；超时(false)→做一轮 reap。
                if (!self.reaper_cond.timedWait(&self.mutex, REAP_INTERVAL_MS * std.time.ns_per_ms)) break;
            }
            if (self.stop) {
                self.unlock();
                return;
            }
            const now = nowMs();
            // 收集 idle 的 key(避免遍历时改 map)。
            var to_reap = std.ArrayList([]const u8).empty;
            defer to_reap.deinit(self.allocator);
            var it = self.clients.iterator();
            while (it.next()) |e| {
                if (now - e.value_ptr.last_used_ms > IDLE_TIMEOUT_MS) {
                    to_reap.append(self.allocator, e.key_ptr.*) catch {};
                }
            }
            // 逐个移除 + shutdown(shutdown 在锁外做,避免长持锁)。
            var reaped = std.ArrayList(*Client).empty;
            defer reaped.deinit(self.allocator);
            for (to_reap.items) |k| {
                if (self.clients.fetchRemove(k)) |kv| {
                    self.allocator.free(kv.key);
                    reaped.append(self.allocator, kv.value.client) catch {};
                }
            }
            self.unlock();
            for (reaped.items) |c| c.shutdown();
        }
    }

    pub fn shutdown(self: *Service) void {
        self.lock();
        self.stop = true;
        _ = self.reaper_cond.broadcast(); // 立即唤醒 reaper(不等满 30s 周期)
        self.unlock();
        if (self.reaper) |t| t.join();

        var it = self.clients.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.client.shutdown();
        }
        self.clients.deinit();
        var bit = self.broken.keyIterator();
        while (bit.next()) |k| self.allocator.free(k.*);
        self.broken.deinit();
        var blit = self.baselines.iterator();
        while (blit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.deinit();
        }
        self.baselines.deinit();
        self.allocator.free(self.cwd);
        const a = self.allocator;
        a.destroy(self);
    }
};

/// diagKey:severity|line:col-endline:endcol|code|source|message(唯一标识一条诊断,供 delta 去重)。
fn diagKey(buf: []u8, d: reporter.Diagnostic) []const u8 {
    return std.fmt.bufPrint(buf, "{d}|{d}:{d}-{d}:{d}|{s}|{s}|{s}", .{
        @intFromEnum(d.severity), d.line, d.col, d.end_line, d.end_col, d.code, d.source, d.message,
    }) catch buf[0..0];
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "diagKey: 唯一 + 稳定" {
    var b1: [512]u8 = undefined;
    var b2: [512]u8 = undefined;
    const d1 = reporter.Diagnostic{ .severity = .err, .line = 1, .col = 2, .end_line = 1, .end_col = 5, .message = "m", .code = "C", .source = "s" };
    const d2 = reporter.Diagnostic{ .severity = .err, .line = 1, .col = 2, .end_line = 1, .end_col = 5, .message = "m", .code = "C", .source = "s" };
    const d3 = reporter.Diagnostic{ .severity = .err, .line = 9, .col = 2, .end_line = 1, .end_col = 5, .message = "m", .code = "C", .source = "s" };
    try testing.expectEqualStrings(diagKey(&b1, d1), diagKey(&b2, d2)); // 同 → 同 key
    try testing.expect(!std.mem.eql(u8, diagKey(&b1, d1), diagKey(&b2, d3))); // 异行 → 异 key
}

test "Service: 无 git workspace → getDiagnostics 空串(graceful gate)" {
    const a = testing.allocator;
    var svc = try Service.create(a, "/nonexistent_xyz_cwd", null);
    defer svc.shutdown();
    // 文件不在 git 仓 → gate off → 空串,不崩不 spawn。
    const d = svc.getDiagnostics(a, "/nonexistent_xyz_cwd/foo.py", "x = 1\n");
    defer a.free(d);
    try testing.expectEqualStrings("", d);
}

fn mkdirZ(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    _ = std.c.mkdir(z.ptr, 0o755);
}
fn writeFileZ(path: []const u8, content: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = pfs.close(fd);
    _ = pfs.write(fd, content[0..content.len]);
}

test "Service e2e: 真 zls 报类型错误的 delta 诊断(需装 zls)" {
    const a = testing.allocator;
    var zbuf: [std.fs.max_path_bytes]u8 = undefined;
    if (servers.which("zls", &zbuf) == null) return; // 未装 zls → skip

    // 建 /tmp/cc_lsp_zls_<pid>/{.git, main.zig}。fake .git 让 workspace gate 过。
    const base = std.fmt.allocPrint(a, "/tmp/cc_lsp_zls_{d}", .{std.c.getpid()}) catch return;
    defer a.free(base);
    mkdirZ(base);
    const gitdir = std.fmt.allocPrint(a, "{s}/.git", .{base}) catch return;
    defer a.free(gitdir);
    mkdirZ(gitdir);
    const file = std.fmt.allocPrint(a, "{s}/main.zig", .{base}) catch return;
    defer a.free(file);

    // 用 undeclared identifier(zls 可靠报 severity=1 ERROR;类型不匹配 zls 默认不查——探针实证)。
    const clean = "pub fn main() void {}\n";
    const buggy = "pub fn main() void {\n    _ = undeclared_thing_xyz;\n}\n";
    writeFileZ(file, clean);

    var svc = try Service.create(a, base, null);
    defer svc.shutdown();

    // 写前 baseline(干净,无诊断)。
    svc.snapshotBaseline(file, clean);
    // 写后 delta(引入 undeclared 错误)。
    writeFileZ(file, buggy);
    const diag = svc.getDiagnostics(a, file, buggy);
    defer a.free(diag);

    // delta:baseline 干净 → 新 ERROR 出现。zls 已装且 ~1s 响应(探针实证),8s baseline+6s wait 充裕。
    try testing.expect(diag.len > 0);
    try testing.expect(std.mem.indexOf(u8, diag, "<diagnostics") != null);
    try testing.expect(std.mem.indexOf(u8, diag, "main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, diag, "ERROR") != null);
    try testing.expect(std.mem.indexOf(u8, diag, "undeclared") != null);
}

test "Service e2e: 真 zls documentSymbol 抽 struct/function 符号(需装 zls)" {
    const a = testing.allocator;
    var zbuf: [std.fs.max_path_bytes]u8 = undefined;
    if (servers.which("zls", &zbuf) == null) return; // 未装 → skip

    const base = std.fmt.allocPrint(a, "/tmp/cc_lsp_sym_{d}", .{std.c.getpid()}) catch return;
    defer a.free(base);
    mkdirZ(base);
    const gitdir = std.fmt.allocPrint(a, "{s}/.git", .{base}) catch return;
    defer a.free(gitdir);
    mkdirZ(gitdir);
    const file = std.fmt.allocPrint(a, "{s}/mod.zig", .{base}) catch return;
    defer a.free(file);

    const src =
        \\pub const Point = struct {
        \\    x: i32,
        \\    y: i32,
        \\};
        \\
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
        \\
    ;
    writeFileZ(file, src);

    var svc = try Service.create(a, base, null);
    defer svc.shutdown();

    var syms = svc.getSymbols(a, file, src);
    defer syms.deinit();

    // zls 应报 Point 与 add(Function=12)。**真 zls 语义差异**(登记):`pub const X = struct`
    // 被 zls 报成 SymbolKind.Constant(14)/Struct(23),按 zls 版本而定——它按"const 绑定"而非
    // tree-sitter 的"struct 定义"语义分类。故 Point 的 kind 不 pin,只验存在 + 行号;add 是明确 Function。
    try testing.expect(syms.items.len >= 2);
    var found_point = false;
    var found_add = false;
    for (syms.items) |s| {
        if (std.mem.eql(u8, s.name, "Point")) {
            found_point = true;
            try testing.expect(s.kind == 14 or s.kind == 23); // Constant 或 Struct(版本相关)
            try testing.expectEqual(@as(u32, 1), s.line_start); // 1-based:第 1 行
        }
        if (std.mem.eql(u8, s.name, "add")) {
            found_add = true;
            try testing.expectEqual(@as(i64, 12), s.kind); // SymbolKind.Function
            try testing.expectEqual(@as(u32, 6), s.line_start); // 第 6 行
        }
    }
    try testing.expect(found_point);
    try testing.expect(found_add);
}
