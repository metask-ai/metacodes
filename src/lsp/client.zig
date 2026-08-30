//! LSP client:一个 client = 一个 language server 子进程 + 一个 reader 线程(对齐 hermes client.py)。
//!
//! **线程模型**(裁剪 std 无 Thread.Mutex,全仓惯例用 std.c.pthread_*):
//!   - reader 线程独占 transport.readMessage() 读循环,按 classify 路由:
//!       response → 唤醒对应 pending future(id 关联);
//!       textDocument/publishDiagnostics → 存 per-path 诊断 + **push_counter++** + broadcast;
//!       server→client request → 回 method-not-found(passive 模式不支持任何服务端请求)。
//!   - 主(agent)线程调 sendRequest(写 stdin + 等 pending cond)/ waitForDiagnostics(等 push_counter)。
//!   - transport:reader 只读 stdout_fd,主只写 stdin_fd,fd 不同 → 无需锁 transport 自身。
//!     **约束**:sendRequest/sendNotification 由**单一 caller 线程**串行调(Edit 工具顺序调用满足)。
//!
//! **等诊断的同步原语 = 单调计数器**(hermes 血泪:纯 condvar 有 sticky/丢信号陷阱):waiter 快照
//! push_counter,任何 increment 都重查 version 谓词(published_version >= sent_version)。
//! **seed-on-first-push**(TS 系):首个 publishDiagnostics 只存不 signal,防 waiter 命中 pre-edit 旧诊断。
const std = @import("std");
const sync = @import("platform").sync;
const pprocess = @import("platform").process;
const transport_mod = @import("transport.zig");
const protocol = @import("protocol.zig");
const reporter = @import("reporter.zig");
const lsp_symbols = @import("symbols.zig");

pub const LspSymbols = lsp_symbols.LspSymbols;

pub const Transport = transport_mod.Transport;

// M2:initialize 从 45s 降到 12s——首次 spawn 慢 server(rust-analyzer/clangd)超 12s 直接标 broken 不
// 阻塞后续编辑(下次编辑该 server 已 broken→立即返空,不再等)。多数 server(zls/pyright)<3s。
const INITIALIZE_TIMEOUT_MS: u64 = 12_000;
const REQUEST_TIMEOUT_MS: u64 = 10_000;
/// cond 等待的轮询步长:每步查一次 abort,保证 Ctrl+C 在 ~150ms 内中断(而非死等到 timeout)。
const WAIT_POLL_MS: u64 = 150;

/// 请求的 pending future:reader 填 result 后 broadcast,sendRequest 醒来取走。
const Pending = struct {
    done: bool = false,
    result: ?[]u8 = null, // owned:response 的整条 body(result 或 error 都在里面)
};

/// 某文件的一批诊断:arena 拥有诊断字符串,diags 借 arena。
const DiagSet = struct {
    arena: std.heap.ArenaAllocator,
    diags: []reporter.Diagnostic,
    version: i64,
    fn deinit(self: *DiagSet) void {
        self.arena.deinit();
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    reader_thread: ?std.Thread = null,

    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},

    pending: std.AutoHashMap(i64, *Pending),
    next_id: i64 = 1,

    diagnostics: std.StringHashMap(DiagSet), // path(owned key) → DiagSet
    files: std.StringHashMap(i64), // 已 open 文件 path(owned key) → 当前 version
    push_counter: u64 = 0,

    running: bool = true,
    seed_first_push: bool = false, // TS 系:首 push 不 signal
    seeded_paths: std.StringHashMap(void), // 已"吃掉首 push"的 path
    abort: ?transport_mod.AbortCheck = null, // M2:agent 的 abort;等待时轮询,Ctrl+C 可中断

    pub fn create(allocator: std.mem.Allocator, argv: []const ?[*:0]const u8, seed_first_push: bool, abort: ?transport_mod.AbortCheck) !*Client {
        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .transport = try Transport.spawn(allocator, argv),
            .pending = std.AutoHashMap(i64, *Pending).init(allocator),
            .diagnostics = std.StringHashMap(DiagSet).init(allocator),
            .files = std.StringHashMap(i64).init(allocator),
            .seeded_paths = std.StringHashMap(void).init(allocator),
            .seed_first_push = seed_first_push,
            .abort = abort,
        };
        self.transport.abort = abort; // reader 的 readMessage 也 abort-aware
        self.reader_thread = try std.Thread.spawn(.{}, readerLoop, .{self});
        return self;
    }

    /// 持锁调用:cond 等一步(WAIT_POLL_MS 或被 signal),返回 true 表示应继续等(未 abort/未超总 deadline)。
    /// 分片轮询让 abort 在 ~WAIT_POLL_MS 内生效(cond_timedwait 本身不查 abort)。
    fn abortedDuringWait(self: *Client) bool {
        if (self.abort) |ab| return ab.isAborted();
        return false;
    }

    fn lock(self: *Client) void {
        _ = self.mutex.lock();
    }
    fn unlock(self: *Client) void {
        _ = self.mutex.unlock();
    }

    // ── reader 线程 ────────────────────────────────────────────────────────
    fn readerLoop(self: *Client) void {
        while (true) {
            const msg = self.transport.readMessage() catch {
                // EOF/Aborted/ReadFailed → server 死了。唤醒所有 waiter,退出。
                self.lock();
                self.running = false;
                _ = self.cond.broadcast();
                self.unlock();
                return;
            };
            defer self.allocator.free(msg);
            self.dispatch(msg);
        }
    }

    fn dispatch(self: *Client, msg: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, msg, .{}) catch return;
        defer parsed.deinit();
        const c = protocol.classify(parsed.value);
        switch (c.kind) {
            .response => if (c.id) |id| self.resolveResponse(id, msg),
            .notification => if (c.method) |m| self.handleNotification(m, parsed.value),
            .request => if (c.id) |id| self.replyMethodNotFound(id),
            .invalid => {},
        }
    }

    fn resolveResponse(self: *Client, id: i64, msg: []const u8) void {
        self.lock();
        defer self.unlock();
        if (self.pending.get(id)) |p| {
            p.result = self.allocator.dupe(u8, msg) catch null;
            p.done = true;
            _ = self.cond.broadcast();
        }
    }

    fn replyMethodNotFound(self: *Client, id: i64) void {
        const reply = protocol.makeMethodNotFound(self.allocator, id) catch return;
        defer self.allocator.free(reply);
        self.transport.sendMessage(reply) catch {};
    }

    fn handleNotification(self: *Client, method: []const u8, root: std.json.Value) void {
        if (!std.mem.eql(u8, method, "textDocument/publishDiagnostics")) return;
        const params = root.object.get("params") orelse return;
        if (params != .object) return;
        const uri = (params.object.get("uri") orelse return);
        if (uri != .string) return;
        const path = uriToPath(uri.string);
        const version: i64 = if (params.object.get("version")) |v| (if (v == .integer) v.integer else -1) else -1;

        // 解析诊断数组 → DiagSet(arena owned)。
        var ds = parseDiagnostics(self.allocator, params.object.get("diagnostics"), version) catch return;

        self.lock();
        defer self.unlock();
        // 存/替换该 path 的诊断(free 旧的)。key 需 owned。
        self.storeDiagnostics(path, &ds);

        // seed-on-first-push:首个 push 只存不 signal(防 waiter 命中 pre-edit 基线)。
        if (self.seed_first_push and !self.seeded_paths.contains(path)) {
            const k = self.allocator.dupe(u8, path) catch {
                // dupe 失败 → 保守当作已 seed(不再吞),直接 signal。
                self.push_counter += 1;
                _ = self.cond.broadcast();
                return;
            };
            self.seeded_paths.put(k, {}) catch self.allocator.free(k);
            return; // 吞掉首 push,不 signal
        }
        self.push_counter += 1;
        _ = self.cond.broadcast();
    }

    /// 持锁调用:存 path→ds,free 旧 DiagSet;key owned(首次 dupe)。
    fn storeDiagnostics(self: *Client, path: []const u8, ds: *DiagSet) void {
        if (self.diagnostics.getEntry(path)) |e| {
            e.value_ptr.deinit();
            e.value_ptr.* = ds.*;
            return;
        }
        const k = self.allocator.dupe(u8, path) catch {
            ds.deinit();
            return;
        };
        self.diagnostics.put(k, ds.*) catch {
            self.allocator.free(k);
            ds.deinit();
        };
    }

    // ── 请求/通知(主线程)────────────────────────────────────────────────
    /// 发 request 并阻塞等 response(timeout)。返回 response 整条 body(owned),超时/死亡 → error。
    fn sendRequest(self: *Client, method: []const u8, params_json: ?[]const u8, timeout_ms: u64) ![]u8 {
        var p = Pending{};
        self.lock();
        const id = self.next_id;
        self.next_id += 1;
        // put 失败:立刻解锁返回,p 未进 map,无竞态。
        self.pending.put(id, &p) catch |e| {
            self.unlock();
            return e;
        };
        self.unlock();
        // errdefer:sendMessage 前失败也要把 p 从 map 摘掉(否则 reader 写已析构栈变量 = UAF)。
        errdefer {
            self.lock();
            _ = self.pending.remove(id);
            self.unlock();
        }

        const req = try protocol.makeRequest(self.allocator, id, method, params_json);
        defer self.allocator.free(req);
        try self.transport.sendMessage(req);

        // **remove + 取 result 原子在同一持锁内**(Linus ①):关掉 timeout 与 late-response 的竞态窗口。
        // remove 后 reader 的 get(id)=null,再不能写 p;已写入的 result 在此被捕获。
        self.lock();
        // 分片轮询:每 WAIT_POLL_MS 查一次 abort(Ctrl+C 可中断),总不超 timeout_ms。
        var steps_left = timeout_ms / WAIT_POLL_MS + 1;
        while (!p.done and self.running and steps_left > 0 and !self.abortedDuringWait()) : (steps_left -= 1) {
            _ = self.cond.timedWait(&self.mutex, WAIT_POLL_MS * std.time.ns_per_ms);
        }
        _ = self.pending.remove(id);
        const result = p.result;
        const done = p.done;
        self.unlock();
        if (!done) {
            if (result) |r| self.allocator.free(r); // 极端:超时后、remove 前 reader 刚写入 → 释放不泄漏
            return error.Timeout;
        }
        return result orelse error.NoResult;
    }

    fn sendNotification(self: *Client, method: []const u8, params_json: ?[]const u8) !void {
        const n = try protocol.makeNotification(self.allocator, method, params_json);
        defer self.allocator.free(n);
        try self.transport.sendMessage(n);
    }

    // ── 生命周期 ────────────────────────────────────────────────────────
    /// initialize 握手:发 initialize + 等 response + 发 initialized。root_uri 如 "file:///abs/path"。
    pub fn initialize(self: *Client, root_uri: []const u8) !void {
        var pbuf: std.ArrayList(u8) = .empty;
        defer pbuf.deinit(self.allocator);
        try pbuf.appendSlice(self.allocator, "{\"processId\":");
        var idbuf: [16]u8 = undefined;
        try pbuf.appendSlice(self.allocator, try std.fmt.bufPrint(&idbuf, "{d}", .{pprocess.currentPid()}));
        try pbuf.appendSlice(self.allocator, ",\"rootUri\":");
        try appendJsonStr(&pbuf, self.allocator, root_uri);
        // 声明支持 publishDiagnostics + utf-16(LSP 默认)。passive 模式能力最小化。
        try pbuf.appendSlice(self.allocator,
            \\,"capabilities":{"textDocument":{"publishDiagnostics":{"relatedInformation":false},"documentSymbol":{"hierarchicalDocumentSymbolSupport":true}},"general":{"positionEncodings":["utf-16"]}},"workspaceFolders":null}
        );
        const resp = try self.sendRequest("initialize", pbuf.items, INITIALIZE_TIMEOUT_MS);
        self.allocator.free(resp);
        try self.sendNotification("initialized", "{}");
    }

    /// open/touch 文件:首次 didOpen version0,后续 didChange(整文档替换)version+1。
    /// **返回 wait_token = 发送前的 push_counter 快照**——waitForDiagnostics 等 counter 涨过它,
    /// 即"本次 didOpen/didChange 之后到达的新 publishDiagnostics"。不靠 version(zls 等 server 不带 version)。
    /// text 是文件当前全文。
    pub fn openFile(self: *Client, path: []const u8, text: []const u8) !u64 {
        self.lock();
        const wait_token = self.push_counter; // 发送前快照:之后任何 push 都涨过它
        const existing = self.files.get(path);
        self.unlock();

        const uri = try pathToUri(self.allocator, path);
        defer self.allocator.free(uri);
        const lang_id = languageIdForPath(path);

        if (existing) |ver| {
            const new_ver = ver + 1;
            // didChange 整文档替换。
            var params: std.ArrayList(u8) = .empty;
            defer params.deinit(self.allocator);
            try params.appendSlice(self.allocator, "{\"textDocument\":{\"uri\":");
            try appendJsonStr(&params, self.allocator, uri);
            var vb: [16]u8 = undefined;
            try params.appendSlice(self.allocator, ",\"version\":");
            try params.appendSlice(self.allocator, try std.fmt.bufPrint(&vb, "{d}", .{new_ver}));
            try params.appendSlice(self.allocator, "},\"contentChanges\":[{\"text\":");
            try appendJsonStr(&params, self.allocator, text);
            try params.appendSlice(self.allocator, "}]}");
            try self.sendNotification("textDocument/didChange", params.items);
            self.lock();
            self.files.getEntry(path).?.value_ptr.* = new_ver;
            self.unlock();
            return wait_token;
        } else {
            var params: std.ArrayList(u8) = .empty;
            defer params.deinit(self.allocator);
            try params.appendSlice(self.allocator, "{\"textDocument\":{\"uri\":");
            try appendJsonStr(&params, self.allocator, uri);
            try params.appendSlice(self.allocator, ",\"languageId\":");
            try appendJsonStr(&params, self.allocator, lang_id);
            try params.appendSlice(self.allocator, ",\"version\":0,\"text\":");
            try appendJsonStr(&params, self.allocator, text);
            try params.appendSlice(self.allocator, "}}");
            try self.sendNotification("textDocument/didOpen", params.items);
            const k = try self.allocator.dupe(u8, path);
            self.lock();
            self.files.put(k, 0) catch self.allocator.free(k);
            self.unlock();
            return wait_token;
        }
    }

    /// didSave(某些 linter 只在 save 时重扫)。
    pub fn didSave(self: *Client, path: []const u8) !void {
        const uri = try pathToUri(self.allocator, path);
        defer self.allocator.free(uri);
        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.allocator);
        try params.appendSlice(self.allocator, "{\"textDocument\":{\"uri\":");
        try appendJsonStr(&params, self.allocator, uri);
        try params.appendSlice(self.allocator, "}}");
        try self.sendNotification("textDocument/didSave", params.items);
    }

    /// 请求 `textDocument/documentSymbol` 并解析为展平符号列表。文件须已 openFile(didOpen)。
    /// 同步阻塞(走 sendRequest pending 机制,REQUEST_TIMEOUT_MS 上限,可 abort)。
    /// server 无符号能力/超时/空 → 返回空 LspSymbols(caller deinit)。gpa 拥有返回 arena。
    pub fn documentSymbol(self: *Client, gpa: std.mem.Allocator, path: []const u8) !LspSymbols {
        const uri = try pathToUri(self.allocator, path);
        defer self.allocator.free(uri);
        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.allocator);
        try params.appendSlice(self.allocator, "{\"textDocument\":{\"uri\":");
        try appendJsonStr(&params, self.allocator, uri);
        try params.appendSlice(self.allocator, "}}");

        const resp = try self.sendRequest("textDocument/documentSymbol", params.items, REQUEST_TIMEOUT_MS);
        defer self.allocator.free(resp);

        // resp = {"jsonrpc":..,"id":N,"result":[...]} 或含 error。取 result 交解析器。
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, resp, .{}) catch {
            return lsp_symbols.parse(gpa, .null); // 解析失败 → 空(best-effort)
        };
        defer parsed.deinit();
        const result: std.json.Value = if (parsed.value == .object)
            (parsed.value.object.get("result") orelse .null)
        else
            .null;
        return lsp_symbols.parse(gpa, result);
    }

    /// 等一个**新** publishDiagnostics 到达(push_counter 涨过 wait_token)。wait_token 来自 openFile
    /// 发送前的快照,故这是"本次 didOpen/didChange 之后的诊断"。到点/超时/server 死 → 返回。
    /// **不靠 version**——zls 等 server 的 publishDiagnostics 不带 version,version 谓词会误命中旧诊断。
    /// 单文件 Edit 场景 push 都是本文件的,counter 即足够;多文件并发是 v1 已知局限(登记)。
    pub fn waitForDiagnostics(self: *Client, wait_token: u64, timeout_ms: u64) void {
        self.lock();
        defer self.unlock();
        var steps_left = timeout_ms / WAIT_POLL_MS + 1;
        while (self.running and self.push_counter <= wait_token and steps_left > 0 and !self.abortedDuringWait()) : (steps_left -= 1) {
            _ = self.cond.timedWait(&self.mutex, WAIT_POLL_MS * std.time.ns_per_ms);
        }
    }

    /// 拷贝 path 当前诊断到 caller allocator(owned;调用方 free 每条的 message/code/source + 外层)。
    /// 无 → 空 slice。
    pub fn diagnosticsFor(self: *Client, alloc: std.mem.Allocator, path: []const u8) ![]reporter.Diagnostic {
        self.lock();
        defer self.unlock();
        const ds = self.diagnostics.get(path) orelse return try alloc.alloc(reporter.Diagnostic, 0);
        const out = try alloc.alloc(reporter.Diagnostic, ds.diags.len);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |d| freeDiag(alloc, d);
            alloc.free(out);
        }
        for (ds.diags, 0..) |d, i| {
            out[i] = .{
                .severity = d.severity,
                .line = d.line,
                .col = d.col,
                .end_line = d.end_line,
                .end_col = d.end_col,
                .message = try alloc.dupe(u8, d.message),
                .code = try alloc.dupe(u8, d.code),
                .source = try alloc.dupe(u8, d.source),
            };
            filled += 1;
        }
        return out;
    }

    pub fn shutdown(self: *Client) void {
        self.shutdownWithTimeout(2000);
    }

    /// Shared lifecycle implementation. Production keeps the conservative 2 s
    /// LSP grace period; the stubborn-server regression injects a shorter
    /// finite deadline so it proves timeout -> TERM -> KILL escalation without
    /// turning the suite into a timer benchmark.
    fn shutdownWithTimeout(self: *Client, request_timeout_ms: u64) void {
        // 发 shutdown + exit(best-effort),再终止子进程 → reader EOF → join → 才关 fd(顺序防 UAF)。
        const resp = self.sendRequest("shutdown", null, request_timeout_ms) catch null;
        if (resp) |r| self.allocator.free(r);
        self.sendNotification("exit", null) catch {};
        self.transport.terminate(); // 杀子进程(TERM→KILL 升级)→ 子进程死 → reader 的 read 返 EOF
        if (self.reader_thread) |t| t.join(); // reader 退出(读到 EOF)
        self.transport.deinit(); // reader 已 join,现在关 stdout_fd + free read_buf 才安全

        // 清理 map(reader 已退,单线程安全)。
        var dit = self.diagnostics.iterator();
        while (dit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.deinit();
        }
        self.diagnostics.deinit();
        var fit = self.files.keyIterator();
        while (fit.next()) |k| self.allocator.free(k.*);
        self.files.deinit();
        var sit = self.seeded_paths.keyIterator();
        while (sit.next()) |k| self.allocator.free(k.*);
        self.seeded_paths.deinit();
        self.pending.deinit();
        const a = self.allocator;
        a.destroy(self);
    }
};

pub fn freeDiag(alloc: std.mem.Allocator, d: reporter.Diagnostic) void {
    alloc.free(d.message);
    alloc.free(d.code);
    alloc.free(d.source);
}

pub fn freeDiags(alloc: std.mem.Allocator, diags: []reporter.Diagnostic) void {
    for (diags) |d| freeDiag(alloc, d);
    alloc.free(diags);
}

// ── helpers ────────────────────────────────────────────────────────────────

fn parseDiagnostics(alloc: std.mem.Allocator, diags_v: ?std.json.Value, version: i64) !DiagSet {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const aa = arena.allocator();
    var list: std.ArrayList(reporter.Diagnostic) = .empty;
    if (diags_v) |dv| {
        if (dv == .array) {
            for (dv.array.items) |item| {
                if (item != .object) continue;
                const o = item.object;
                const range = o.get("range") orelse continue;
                if (range != .object) continue;
                const start = range.object.get("start") orelse continue;
                const end = range.object.get("end") orelse start;
                const sev: reporter.Severity = if (o.get("severity")) |s| (if (s == .integer) sevFromInt(s.integer) else .err) else .err;
                const msg = if (o.get("message")) |m| (if (m == .string) m.string else "") else "";
                const code = codeToStr(o.get("code"));
                const src = if (o.get("source")) |s| (if (s == .string) s.string else "") else "";
                try list.append(aa, .{
                    .severity = sev,
                    .line = jint(start.object.get("line")),
                    .col = jint(start.object.get("character")),
                    .end_line = jint(end.object.get("line")),
                    .end_col = jint(end.object.get("character")),
                    .message = try aa.dupe(u8, msg),
                    .code = try aa.dupe(u8, code),
                    .source = try aa.dupe(u8, src),
                });
            }
        }
    }
    return .{ .arena = arena, .diags = try list.toOwnedSlice(aa), .version = version };
}

fn sevFromInt(v: i64) reporter.Severity {
    return switch (v) {
        1 => .err,
        2 => .warn,
        3 => .info,
        else => .hint,
    };
}
fn jint(v: ?std.json.Value) u32 {
    if (v) |x| if (x == .integer and x.integer >= 0) return @intCast(x.integer);
    return 0;
}
fn codeToStr(v: ?std.json.Value) []const u8 {
    if (v) |x| return switch (x) {
        .string => x.string,
        else => "", // code 可能是 integer;简化只取 string code
    };
    return "";
}

/// file:// URI → 本地路径(简化:剥 "file://" 前缀;不处理 % 编码,LSP server 一般不编码常规路径)。
///
/// **POSIX 形状,Windows 未支持**(与 `pathToUri` 成对,登记在 `lsp.zig` 的 Windows 状态表)。
fn uriToPath(uri: []const u8) []const u8 {
    if (std.mem.startsWith(u8, uri, "file://")) return uri["file://".len..];
    return uri;
}

/// 本地绝对路径 → file:// URI(owned)。简化不做 % 编码。
///
/// **POSIX 形状,Windows 未支持**:`C:\proj\a.zig` 会出成 `file://C:\proj\a.zig`,而 LSP
/// 规范要的是 `file:///c%3A/proj/a.zig`(盘符前多一个斜杠 + `:` 百分号编码 + 反斜杠转正斜杠)。
/// 改这里必须同时改 `uriToPath` 并补往返测试。见 `lsp.zig` 的 Windows 状态表。
fn pathToUri(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "file://{s}", .{path});
}

fn languageIdForPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "plaintext";
    const ext = base[dot + 1 ..];
    const table = [_]struct { e: []const u8, id: []const u8 }{
        .{ .e = "zig", .id = "zig" },
        .{ .e = "py", .id = "python" },
        .{ .e = "ts", .id = "typescript" },
        .{ .e = "tsx", .id = "typescriptreact" },
        .{ .e = "js", .id = "javascript" },
        .{ .e = "jsx", .id = "javascriptreact" },
        .{ .e = "go", .id = "go" },
        .{ .e = "rs", .id = "rust" },
        .{ .e = "c", .id = "c" },
        .{ .e = "cpp", .id = "cpp" },
        .{ .e = "h", .id = "c" },
    };
    for (table) |t| if (std.mem.eql(u8, ext, t.e)) return t.id;
    return "plaintext";
}

fn appendJsonStr(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.json.Stringify.encodeJsonString(s, .{}, &aw.writer);
    try out.appendSlice(alloc, aw.written());
}

// ============================================================================
// Tests(用 mock LSP server:tests/_harness/mock_lsp_server.py)
// ============================================================================

const testing = std.testing;
const MOCK_LSP = "tests/_harness/mock_lsp_server.py";
const MOCK_LSP_STUBBORN = "tests/_harness/mock_lsp_stubborn.py";
const X_OK: c_int = 1;

test "Client: initialize + didOpen → publishDiagnostics 端到端(mock LSP server)" {
    const a = testing.allocator;
    // POSIX 专属测试脚手架:mock server 是靠 shebang 直接当 argv[0] 执行的 .py 脚本,
    // Windows 既没有 shebang 也不能用 `_access(X_OK)` 判可执行(mode 只认 0/2/4/6)。
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // mock 脚本不可执行(如异机)→ skip,不 45s 挂死。
    if (std.c.access(MOCK_LSP, X_OK) != 0) return;

    const argv = [_]?[*:0]const u8{ MOCK_LSP, null };
    var cl = Client.create(a, argv[0..], false, null) catch return;
    defer cl.shutdown();

    try cl.initialize("file:///tmp/proj");
    const path = "/tmp/proj/foo.zig";
    const ver = try cl.openFile(path, "const x = 1;\nconst y = 2;\nbad line here\n");
    cl.waitForDiagnostics(ver, 5000);

    const diags = try cl.diagnosticsFor(a, path);
    defer freeDiags(a, diags);
    try testing.expect(diags.len >= 1);
    try testing.expectEqual(reporter.Severity.err, diags[0].severity);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "MOCK_LSP_DIAG") != null);
    try testing.expectEqualStrings("E123", diags[0].code);
    try testing.expectEqualStrings("mocklsp", diags[0].source);
    try testing.expectEqual(@as(u32, 2), diags[0].line); // 0-based line 2
    try testing.expectEqual(@as(u32, 4), diags[0].col);
}

test "Client: didChange 版本递增 + 诊断刷新(mock)" {
    const a = testing.allocator;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属:shebang .py 脚手架
    if (std.c.access(MOCK_LSP, X_OK) != 0) return;
    const argv = [_]?[*:0]const u8{ MOCK_LSP, null };
    var cl = Client.create(a, argv[0..], false, null) catch return;
    defer cl.shutdown();
    try cl.initialize("file:///tmp/proj");
    const path = "/tmp/proj/bar.py";
    const t0 = try cl.openFile(path, "line0\nline1\nx\n"); // wait_token(发送前 counter 快照)
    try testing.expectEqual(@as(u64, 0), t0); // 首次 didOpen 前 counter=0
    cl.waitForDiagnostics(t0, 5000);
    // 二次编辑 → didChange → 新 publishDiagnostics 涨 counter。
    const t1 = try cl.openFile(path, "line0\nline1\nyy\n");
    try testing.expect(t1 >= 1); // 首个 push 后 counter 已涨
    cl.waitForDiagnostics(t1, 5000);
    const diags = try cl.diagnosticsFor(a, path);
    defer freeDiags(a, diags);
    try testing.expect(diags.len >= 1); // 刷新后仍有诊断
}

test "Client: shutdown 对 ignore-SIGTERM server 升级 SIGKILL 不挂死(Linus ③ 回归)" {
    const a = testing.allocator;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属:shebang .py 脚手架
    if (std.c.access(MOCK_LSP_STUBBORN, X_OK) != 0) return;
    const argv = [_]?[*:0]const u8{ MOCK_LSP_STUBBORN, null };
    var cl = Client.create(a, argv[0..], false, null) catch return;
    try cl.initialize("file:///tmp/proj");
    // 顽固 server 吞 SIGTERM 且不响应 shutdown:短 deadline 超时 → terminate SIGTERM 被吞 →
    // WNOHANG 查未死 → SIGKILL 强杀 → reader EOF → join **有界返回**。到这行没挂死即证升级生效。
    cl.shutdownWithTimeout(100);
}
