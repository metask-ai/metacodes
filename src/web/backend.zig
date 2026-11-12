//! WebBackend —— UiBackend + UiRequester 的 web 实现(阶段:WsBackend 蓝图落地)。
//!
//! 这是 UI 解耦协议的**第一个进程外形态消费者**:emit 把 CoreEvent 序列化成 JSON
//! 落 EventJournal(SSE 连接重放/推送);UiRequester 把 UiRequest 序列化进 journal,
//! 阻塞等浏览器 POST /respond 回填 UiResponse。agent_loop/core 零改动——协议合不合理,
//! 这个文件写不写得顺就是答案。
//!
//! journal 行:本宿主写进 journal 的每一行都是 core/protocol/wire.zig 的 v1 行(带 "v" 与
//! "type"),与 SessionHost 及任何进程外 Host 收到的同一语法(doc/WIRE_PROTOCOL.md):
//!   {"v":1,"type":"<CoreEvent tag>","run_id":N,"data":...}         — Run 内 emit
//!   {"v":1,"type":"<CoreEvent tag>","data":...}                    — Run 外 emit
//!   {"v":1,"type":"<HostEvent tag>","data":{...}}                  — journalHost(driver 的
//!                                                                    user_message/run_done/
//!                                                                    command_result/message_rejected)
//!   {"v":1,"type":"ui_request","id":N,"kind":"...","request":{...}} — requester 发起
//!   {"v":1,"type":"ui_request_closed","id":N,"outcome":"answered"|"cancelled"}
//!                                                                  — 回答/中断(重放时关对话框)
//! Run 编号同 SessionHost:每会话从 1 起,driver 在 Run 开始时 beginRun(随即写 user_message),
//! endRun 写 run_done;其间 emit 的内核事件都带这个 run_id。本宿主不收 trace ID,故无 trace_id。
//! 浏览器回填的 JSON 由 wire.parseResponse 解析。
//!
//! 能力声明(doc/WIRE_PROTOCOL.md §2):前端 POST /capabilities 的帧经 declareCapabilities
//! 装进 `capabilities` 槽,并把 capabilities_accepted 行落 journal。之后 requester 先路由:
//! 声明里没有的 kind 不通告,落 ui_request_unavailable 行并立即返 .unavailable。未声明 =
//! 照旧全部通告。
//!
//! 线程性:emit 可能在 agent_loop 线程或工具线程被调(协议契约)——allocator **必须
//! 线程安全**(production 传 std.heap.c_allocator;单测 std.testing.allocator 自带锁)。
//! requester 由 agent_loop 线程同步阻塞调用;respond() 由 HTTP 连接线程调——pending
//! 槽用 pthread mutex+cond 交接。
//!
//! 中断:web 前端 POST /interrupt 直接打 AbortSignal(原子,与 TUI watcher 同通道);
//! poll 恒 null(生产路径无人消费 poll,与 TuiBackend 现状一致)。

const std = @import("std");
const sync = @import("platform").sync;
const ui_backend = @import("../core/protocol/ui_backend.zig");
const ui_event = @import("../core/protocol/ui_event.zig");
const ui_request = @import("../core/protocol/ui_request.zig");
const abort_mod = @import("../util/abort.zig");
const usage_mod = @import("../core/usage.zig");
const journal_mod = @import("../core/event_journal.zig");
const log = @import("../util/log.zig");
const wire = @import("../core/protocol/wire.zig");
const frontend_capabilities = @import("../core/protocol/frontend_capabilities.zig");

const CoreEvent = ui_event.CoreEvent;
const UiEvent = ui_event.UiEvent;
const UiBackend = ui_backend.UiBackend;
const SessionId = ui_backend.SessionId;
const UiRequest = ui_request.UiRequest;
const UiResponse = ui_request.UiResponse;
const RequestOutcome = ui_request.RequestOutcome;
const UiRequester = ui_request.UiRequester;
const PermissionChoice = @import("../core/protocol/permission_choice.zig").PermissionChoice;
const EventJournal = journal_mod.EventJournal;

pub const WebBackend = struct {
    /// 必须线程安全(见模块注释)。
    allocator: std.mem.Allocator,
    journal: *EventJournal,
    /// requester 等待响应期间感知用户中断(POST /interrupt)。null = 不感知(单测)。
    abort: ?*const abort_mod.AbortSignal = null,
    /// usage 事件累计目标(/state 的 token/cost 数据源)。backend 负责累计是全仓惯例
    /// (对齐 WriterBackend.initNullWithUsage/TUI statusline)。emit 单线程消费 usage
    /// 事件(agent_loop 线程),无锁累加与 TUI 同契约。
    usage_totals: ?*usage_mod.UsageTotals = null,

    // ── pending UI request 槽(一次一个:agent_loop 单线程同步问答;subagent 无 requester)──
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    next_req_id: u64 = 1,
    /// 0 = 无挂起请求。
    pending_id: u64 = 0,
    /// POST /respond 回填的原始 JSON(owned by allocator)。
    response_json: ?[]u8 = null,

    /// 前端声明的能力(POST /capabilities);空 = 未声明,全部通告。
    capabilities: frontend_capabilities.Slot = .{},

    /// The Run in progress, 0 between Runs. Set and cleared by the driver
    /// (`beginRun`/`endRun`); read by `emit` on any thread, so every kernel
    /// event journaled while it is set carries it as `run_id`.
    current_run: std.atomic.Value(u64) = .init(0),
    /// Runs begun so far; the next one is `runs + 1`. Driver thread only.
    runs: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, journal: *EventJournal) WebBackend {
        return .{ .allocator = allocator, .journal = journal };
    }

    pub fn deinit(self: *WebBackend) void {
        self.lock();
        if (self.response_json) |r| self.allocator.free(r);
        self.response_json = null;
        self.unlock();
        self.capabilities.deinit(self.allocator);
    }

    fn lock(self: *WebBackend) void {
        _ = self.mutex.lock();
    }
    fn unlock(self: *WebBackend) void {
        _ = self.mutex.unlock();
    }

    pub fn backend(self: *WebBackend) UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emitThunk, .poll = pollThunk };
    }

    pub fn requester(self: *WebBackend) UiRequester {
        return .{ .ctx = @ptrCast(self), .requestFn = &requestThunk };
    }

    /// 当前挂起请求 id(0 = 无)。GET /state 用,浏览器重连后可据此判断对话框还有效。
    pub fn pendingId(self: *WebBackend) u64 {
        self.lock();
        defer self.unlock();
        return self.pending_id;
    }

    /// HTTP 线程:装入前端的能力帧,返回 capabilities_accepted 行(owned by allocator;
    /// 先装,再把同一行落 journal)。此后发起的请求按它路由;已挂起的不受影响。帧被拒 →
    /// 返 RefusalError,什么都不变。
    pub fn declareCapabilities(self: *WebBackend, frame_json: []const u8) wire.DeclareError![]u8 {
        var accepted = try wire.acceptCapabilities(self.allocator, frame_json);
        errdefer {
            accepted.declaration.deinit();
            self.allocator.free(accepted.line);
        }
        const reply = try self.allocator.dupe(u8, accepted.line);
        errdefer self.allocator.free(reply);
        try self.capabilities.install(self.allocator, accepted.declaration, accepted.line);
        self.journal.append(reply);
        return reply;
    }

    /// GET /state:当前生效的 capabilities_accepted 行(owned by allocator),未声明 → null。
    pub fn acceptedCapabilities(self: *WebBackend, allocator: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
        return self.capabilities.acceptedLine(allocator);
    }

    // ── Runs and host lines (driver thread) ───────────────────────────────

    /// How a Run ended, as its `run_done` reports it: `stop_reason` when it
    /// returned (with `model_error` when the stop was a model failure),
    /// `error_name` when it failed.
    pub const RunEnd = struct {
        stop_reason: ?[]const u8 = null,
        error_name: ?[]const u8 = null,
        model_error: ?@import("../api/model_error.zig").Detail.View = null,
    };

    /// Driver thread: starts the next Run (1, 2, … per session, as
    /// SessionHost numbers them) and returns its id. The caller journals its
    /// `user_message` lines next, unless a macro or `/retry` started it.
    pub fn beginRun(self: *WebBackend) u64 {
        std.debug.assert(self.current_run.load(.acquire) == 0);
        self.runs += 1;
        self.current_run.store(self.runs, .release);
        return self.runs;
    }

    /// The Run in progress, 0 between Runs.
    pub fn runId(self: *WebBackend) u64 {
        return self.current_run.load(.acquire);
    }

    /// Driver thread: journals the Run's `run_done` and ends it.
    pub fn endRun(self: *WebBackend, end: RunEnd) void {
        const run_id = self.current_run.load(.acquire);
        std.debug.assert(run_id != 0);
        defer self.current_run.store(0, .release);
        var done = wire.HostEvent{ .run_done = .{
            .run_id = run_id,
            .stop_reason = end.stop_reason,
            .error_name = end.error_name,
            .model_error = end.model_error,
        } };
        if (self.appendLine(wire.writeHostEvent(self.allocator, done))) return;
        // The notification matters more than its detail.
        done.run_done.model_error = null;
        if (!self.appendLine(wire.writeHostEvent(self.allocator, done)))
            log.warn("web", "dropped run_done of run {d} (serialize OOM)", .{run_id});
    }

    /// Journals a host event (`user_message`, `command_result`,
    /// `message_rejected`; `run_done` goes through `endRun`).
    pub fn journalHost(self: *WebBackend, event: wire.HostEvent) void {
        if (!self.appendLine(wire.writeHostEvent(self.allocator, event)))
            log.warn("web", "dropped host event .{s} (serialize OOM)", .{@tagName(event)});
    }

    /// Journals a kernel event: with the Run's `run_id` while one is in
    /// progress, without one between Runs. Any thread.
    pub fn journalEvent(self: *WebBackend, ev: CoreEvent) void {
        const run_id = self.current_run.load(.acquire);
        // borrow slice 契约:序列化即拷贝,返回前完成消费。
        const line = if (run_id != 0)
            wire.writeRunEvent(self.allocator, .{ .run_id = run_id }, ev)
        else
            wire.writeEvent(self.allocator, ev);
        if (!self.appendLine(line)) log.warn("web", "dropped CoreEvent .{s} (serialize OOM)", .{@tagName(ev)});
    }

    fn appendLine(self: *WebBackend, line: error{OutOfMemory}![]u8) bool {
        const owned = line catch return false;
        defer self.allocator.free(owned);
        self.journal.append(owned);
        return true;
    }

    // ── UiBackend:emit / poll ──────────────────────────────────────────────

    fn emitThunk(ctx: *anyopaque, _: SessionId, ev: CoreEvent) void {
        const self: *WebBackend = @ptrCast(@alignCast(ctx));
        if (ev == .usage) {
            if (self.usage_totals) |u| u.apply(ev.usage);
        }
        self.journalEvent(ev);
    }

    fn pollThunk(_: *anyopaque, _: SessionId) ?UiEvent {
        return null; // 中断走 AbortSignal(POST /interrupt),不经 poll
    }

    // ── UiRequester:同步阻塞问浏览器 ────────────────────────────────────────

    fn requestThunk(
        state: *anyopaque,
        _: SessionId,
        allocator: std.mem.Allocator,
        req: *const UiRequest,
        out: *UiResponse,
    ) anyerror!RequestOutcome {
        const self: *WebBackend = @ptrCast(@alignCast(state));

        // 前端声明过、且不含这个 kind → 不通告、不占 id,立即 unrenderable(工具按语义兜底,
        // 给模型的文字说明是前端渲染不了)。
        switch (self.capabilities.route(req)) {
            .deliver => {},
            .unavailable => |reason| {
                if (wire.writeRequestUnavailable(self.allocator, req, reason)) |line| {
                    defer self.allocator.free(line);
                    self.journal.append(line);
                } else |_| log.warn("web", "dropped ui_request_unavailable (serialize OOM)", .{});
                return .unrenderable;
            },
        }

        // 注册挂起槽(先注册再 append:浏览器看到 ui_request 时 respond 一定有槽可回填)
        self.lock();
        const id = self.next_req_id;
        self.next_req_id += 1;
        self.pending_id = id;
        if (self.response_json) |old| {
            self.allocator.free(old);
            self.response_json = null;
        }
        self.unlock();

        const announce = wire.writeRequest(self.allocator, id, req) catch |err| {
            self.lock();
            self.pending_id = 0;
            self.unlock();
            return err;
        };
        defer self.allocator.free(announce);
        self.journal.append(announce);

        // 阻塞等响应;唯一提前退出路径 = 用户中断(POST /interrupt → AbortSignal)。
        self.lock();
        while (self.response_json == null) {
            if (self.abort) |a| if (a.isAborted()) {
                self.pending_id = 0;
                self.unlock();
                self.announceClosed(id, .cancelled);
                return wire.cancelResponse(req, out);
            };
            _ = self.cond.timedWait(&self.mutex, 200 * std.time.ns_per_ms);
        }
        // An answer that raced the user's interrupt loses: the interrupt is
        // already in force, so a late "allow" must not run the stopped tool.
        const cancelled = if (self.abort) |a| a.isAborted() else false;
        const resp_json = self.response_json.?;
        self.response_json = null;
        self.pending_id = 0;
        self.unlock();
        defer self.allocator.free(resp_json);

        if (cancelled) {
            self.announceClosed(id, .cancelled);
            return wire.cancelResponse(req, out);
        }
        const reading = wire.parseResponse(req, resp_json, allocator, out) catch |err| {
            self.announceClosed(id, if (err == error.InputAborted) .malformed else .cancelled);
            return err;
        };
        self.announceClosed(id, reading.closed());
        return .answered;
    }

    fn announceClosed(self: *WebBackend, id: u64, outcome: wire.RequestClosed) void {
        const line = wire.writeRequestClosed(self.allocator, id, outcome) catch return;
        defer self.allocator.free(line);
        self.journal.append(line);
    }

    /// HTTP 线程:回填响应。id 必须匹配当前挂起(防 stale 对话框回填新请求)。
    /// 返回 false = 无此挂起请求(过期/重复提交/已被中断取消),HTTP 层回 409。
    pub fn respond(self: *WebBackend, id: u64, resp_json: []const u8) bool {
        const owned = self.allocator.dupe(u8, resp_json) catch return false;
        self.lock();
        defer self.unlock();
        const interrupted = if (self.abort) |a| a.isAborted() else false;
        if (self.pending_id != id or self.response_json != null or interrupted) {
            self.allocator.free(owned);
            return false;
        }
        self.response_json = owned;
        _ = self.cond.broadcast();
        return true;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "emit 把 CoreEvent 以 wire v1 行落 journal" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    var wb = WebBackend.init(testing.allocator, &j);
    defer wb.deinit();
    const be = wb.backend();
    be.emitEvent(SessionId.single, .{ .text_chunk = "hello web" });
    be.emitEvent(SessionId.single, .stream_done);
    const batch = (try j.waitSince(testing.allocator, 0, 10)).?;
    defer {
        for (batch) |l| testing.allocator.free(l);
        testing.allocator.free(batch);
    }
    try testing.expectEqual(@as(usize, 2), batch.len);
    try testing.expect(std.mem.indexOf(u8, batch[0], "\"type\":\"text_chunk\"") != null);
    try testing.expect(std.mem.indexOf(u8, batch[0], "hello web") != null);
    try testing.expect(std.mem.indexOf(u8, batch[1], "stream_done") != null);
}

test "#444 a Run's kernel events carry its run_id, none between Runs; run_done ends it in SessionHost's form" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    var wb = WebBackend.init(testing.allocator, &j);
    defer wb.deinit();
    const be = wb.backend();
    be.emitEvent(SessionId.single, .stream_done);
    const first = wb.beginRun();
    try testing.expectEqual(@as(u64, 1), first);
    wb.journalHost(.{ .user_message = .{ .run_id = first, .text = "hi" } });
    be.emitEvent(SessionId.single, .{ .text_chunk = "on it" });
    wb.endRun(.{ .stop_reason = "end_turn" });
    be.emitEvent(SessionId.single, .stream_done);
    try testing.expectEqual(@as(u64, 2), wb.beginRun());
    wb.endRun(.{ .error_name = "RunControlUnavailable" });
    try testing.expectEqual(@as(u64, 0), wb.runId());

    const lines = (try j.waitSince(testing.allocator, 0, 10)).?;
    defer {
        for (lines) |l| testing.allocator.free(l);
        testing.allocator.free(lines);
    }
    const expected = [_][]const u8{
        "{\"v\":1,\"type\":\"stream_done\",\"data\":null}",
        "{\"v\":1,\"type\":\"user_message\",\"data\":{\"run_id\":1,\"trace_id\":null,\"text\":\"hi\",\"replaces\":null}}",
        "{\"v\":1,\"type\":\"text_chunk\",\"run_id\":1,\"data\":\"on it\"}",
        "{\"v\":1,\"type\":\"run_done\",\"data\":{\"run_id\":1,\"trace_id\":null,\"stop_reason\":\"end_turn\",\"error_name\":null,\"model_error\":null}}",
        "{\"v\":1,\"type\":\"stream_done\",\"data\":null}",
        "{\"v\":1,\"type\":\"run_done\",\"data\":{\"run_id\":2,\"trace_id\":null,\"stop_reason\":null,\"error_name\":\"RunControlUnavailable\",\"model_error\":null}}",
    };
    try testing.expectEqual(expected.len, lines.len);
    for (expected, lines) |want, got| try testing.expectEqualStrings(want, got);
}

test "requester: permission 请求经 journal 通告,respond 回填 → answered + done 事件" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    var wb = WebBackend.init(testing.allocator, &j);
    defer wb.deinit();

    // 模拟 HTTP 线程:等 ui_request 出现在 journal → respond
    const Responder = struct {
        fn run(b: *WebBackend, jj: *EventJournal) void {
            const batch = (jj.waitSince(std.testing.allocator, 0, 2000) catch return) orelse return;
            defer {
                for (batch) |l| std.testing.allocator.free(l);
                std.testing.allocator.free(batch);
            }
            // 从通告行解析 id(测试里恒 1)
            if (std.mem.indexOf(u8, batch[0], "\"type\":\"ui_request\"") == null) return;
            _ = b.respond(1, "{\"choice\":\"allow_always\"}");
        }
    };
    const t = try std.Thread.spawn(.{}, Responder.run, .{ &wb, &j });
    defer t.join();

    const r = wb.requester();
    const req = UiRequest{ .permission = .{ .tool = "Bash", .args = "{\"command\":\"ls\"}" } };
    var resp: UiResponse = undefined;
    const outcome = try r.request(SessionId.single, testing.allocator, &req, &resp);
    try testing.expectEqual(RequestOutcome.answered, outcome);
    try testing.expectEqual(PermissionChoice.allow_always, resp.permission);
    try testing.expectEqual(@as(u64, 0), wb.pendingId()); // 槽已清

    // journal 尾部应有 ui_request_closed(answered)
    const all = (try j.waitSince(testing.allocator, 0, 10)).?;
    defer {
        for (all) |l| testing.allocator.free(l);
        testing.allocator.free(all);
    }
    try testing.expect(std.mem.indexOf(u8, all[all.len - 1], "\"outcome\":\"answered\"") != null);
}

test "requester: abort 中断等待 → permission 安全 deny + cancelled 事件" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    var wb = WebBackend.init(testing.allocator, &j);
    defer wb.deinit();
    var sig = abort_mod.AbortSignal.init();
    wb.abort = &sig;
    sig.abort(.user_ctrl_c); // 预先中断:request 应立刻走取消路径

    const r = wb.requester();
    const req = UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    var resp: UiResponse = undefined;
    const outcome = try r.request(SessionId.single, testing.allocator, &req, &resp);
    try testing.expectEqual(RequestOutcome.answered, outcome);
    try testing.expectEqual(PermissionChoice.deny_once, resp.permission);

    const all = (try j.waitSince(testing.allocator, 0, 10)).?;
    defer {
        for (all) |l| testing.allocator.free(l);
        testing.allocator.free(all);
    }
    try testing.expect(std.mem.indexOf(u8, all[all.len - 1], "\"outcome\":\"cancelled\"") != null);
}

test "requester: ask_question 答案数须与问题数一致;abort 时报 InputAborted" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    var wb = WebBackend.init(testing.allocator, &j);
    defer wb.deinit();
    var sig = abort_mod.AbortSignal.init();
    wb.abort = &sig;
    sig.abort(.user_ctrl_c);

    const r = wb.requester();
    const qs = [_]ui_request.AskQuestion{.{ .question = "q?", .header = "H", .multi = false, .options = &.{} }};
    const req = UiRequest{ .ask_question = &qs };
    var resp: UiResponse = undefined;
    try testing.expectError(error.InputAborted, r.request(SessionId.single, testing.allocator, &req, &resp));
}

test "respond: id 不匹配拒绝(stale 对话框防回填)" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    var wb = WebBackend.init(testing.allocator, &j);
    defer wb.deinit();
    try testing.expect(!wb.respond(1, "{\"choice\":\"allow_once\"}")); // 无挂起
}

test "respond: 中断已生效时拒绝回填(迟到的允许不能放行被停止的工具)" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    var wb = WebBackend.init(testing.allocator, &j);
    defer wb.deinit();
    var sig = abort_mod.AbortSignal.init();
    wb.abort = &sig;
    wb.lock();
    wb.pending_id = 7;
    wb.unlock();
    sig.abort(.user_ctrl_c);
    try testing.expect(!wb.respond(7, "{\"choice\":\"allow_once\"}"));
}

test "requester: 与中断赛跑的应答作废,按取消处理并记 cancelled" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    var wb = WebBackend.init(testing.allocator, &j);
    defer wb.deinit();
    var sig = abort_mod.AbortSignal.init();
    wb.abort = &sig;

    // The browser answers "allow", then the interrupt lands before the
    // requester wakes up: the answer must not be used.
    const Racer = struct {
        fn run(b: *WebBackend, jj: *EventJournal, s: *abort_mod.AbortSignal) void {
            const batch = (jj.waitSince(std.testing.allocator, 0, 2000) catch return) orelse return;
            for (batch) |l| std.testing.allocator.free(l);
            std.testing.allocator.free(batch);
            b.lock();
            b.response_json = b.allocator.dupe(u8, "{\"choice\":\"allow_once\"}") catch null;
            s.abort(.user_ctrl_c);
            _ = b.cond.broadcast();
            b.unlock();
        }
    };
    const t = try std.Thread.spawn(.{}, Racer.run, .{ &wb, &j, &sig });
    defer t.join();
    const req = UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    var resp: UiResponse = undefined;
    try testing.expectEqual(RequestOutcome.answered, try wb.requester().request(SessionId.single, testing.allocator, &req, &resp));
    try testing.expectEqual(PermissionChoice.deny_once, resp.permission);
    const all = (try j.waitSince(testing.allocator, 0, 10)).?;
    defer {
        for (all) |l| testing.allocator.free(l);
        testing.allocator.free(all);
    }
    try testing.expect(std.mem.indexOf(u8, all[all.len - 1], "\"outcome\":\"cancelled\"") != null);
}

test "requester: 读不懂的应答按取消处理,记 malformed 而非 answered" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    var wb = WebBackend.init(testing.allocator, &j);
    defer wb.deinit();
    const Responder = struct {
        fn run(b: *WebBackend, jj: *EventJournal) void {
            const batch = (jj.waitSince(std.testing.allocator, 0, 2000) catch return) orelse return;
            for (batch) |l| std.testing.allocator.free(l);
            std.testing.allocator.free(batch);
            _ = b.respond(1, "{\"choice\":\"pretty_please\"}");
        }
    };
    const t = try std.Thread.spawn(.{}, Responder.run, .{ &wb, &j });
    defer t.join();
    const req = UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    var resp: UiResponse = undefined;
    try testing.expectEqual(RequestOutcome.answered, try wb.requester().request(SessionId.single, testing.allocator, &req, &resp));
    try testing.expectEqual(PermissionChoice.deny_once, resp.permission);
    const all = (try j.waitSince(testing.allocator, 0, 10)).?;
    defer {
        for (all) |l| testing.allocator.free(l);
        testing.allocator.free(all);
    }
    try testing.expect(std.mem.indexOf(u8, all[all.len - 1], "\"outcome\":\"malformed\"") != null);
}
