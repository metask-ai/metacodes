//! WebBackend —— UiBackend + UiRequester 的 web 实现(阶段:WsBackend 蓝图落地)。
//!
//! 这是 UI 解耦协议的**第一个进程外形态消费者**:emit 把 CoreEvent 序列化成 JSON
//! 落 EventJournal(SSE 连接重放/推送);UiRequester 把 UiRequest 序列化进 journal,
//! 阻塞等浏览器 POST /respond 回填 UiResponse。agent_loop/core 零改动——协议合不合理,
//! 这个文件写不写得顺就是答案。
//!
//! journal 行信封(浏览器按顶层唯一 key 分发):
//!   {"core_event":   {<CoreEvent tagged union>}}         — emit
//!   {"ui_request":   {"id":N,"request":{<UiRequest>}}}   — requester 发起
//!   {"ui_request_done":      {"id":N}}                   — 已回答(重放时关对话框)
//!   {"ui_request_cancelled": {"id":N}}                   — 中断取消(同上)
//!   {"user_message": "..."} / {"run_done":{...}}         — session driver(session.zig)
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
const journal_mod = @import("journal.zig");
const log = @import("../util/log.zig");

const CoreEvent = ui_event.CoreEvent;
const UiEvent = ui_event.UiEvent;
const UiBackend = ui_backend.UiBackend;
const SessionId = ui_backend.SessionId;
const UiRequest = ui_request.UiRequest;
const UiResponse = ui_request.UiResponse;
const RequestOutcome = ui_request.RequestOutcome;
const UiRequester = ui_request.UiRequester;
const PermissionChoice = @import("../core/protocol/permission_choice.zig").PermissionChoice;
const PlanApproval = @import("../tools/context.zig").ToolContext.PlanApproval;
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

    pub fn init(allocator: std.mem.Allocator, journal: *EventJournal) WebBackend {
        return .{ .allocator = allocator, .journal = journal };
    }

    pub fn deinit(self: *WebBackend) void {
        self.lock();
        if (self.response_json) |r| self.allocator.free(r);
        self.response_json = null;
        self.unlock();
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

    // ── UiBackend:emit / poll ──────────────────────────────────────────────

    fn emitThunk(ctx: *anyopaque, _: SessionId, ev: CoreEvent) void {
        const self: *WebBackend = @ptrCast(@alignCast(ctx));
        if (ev == .usage) {
            if (self.usage_totals) |u| u.apply(ev.usage);
        }
        // borrow slice 契约:序列化即拷贝,返回前完成消费。
        const line = std.json.Stringify.valueAlloc(self.allocator, .{ .core_event = ev }, .{}) catch {
            log.warn("web", "dropped CoreEvent .{s} (serialize OOM)", .{@tagName(ev)});
            return;
        };
        defer self.allocator.free(line);
        self.journal.append(line);
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

        const req_json = try ui_request.serializeUiRequest(self.allocator, req);
        defer self.allocator.free(req_json);

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

        const announce = try std.fmt.allocPrint(self.allocator, "{{\"ui_request\":{{\"id\":{d},\"request\":{s}}}}}", .{ id, req_json });
        defer self.allocator.free(announce);
        self.journal.append(announce);

        // 阻塞等响应;唯一提前退出路径 = 用户中断(POST /interrupt → AbortSignal)。
        self.lock();
        while (self.response_json == null) {
            if (self.abort) |a| if (a.isAborted()) {
                self.pending_id = 0;
                self.unlock();
                self.announceDone("ui_request_cancelled", id);
                return cancelOutcome(req, out);
            };
            _ = self.cond.timedWait(&self.mutex, 200 * std.time.ns_per_ms);
        }
        const resp_json = self.response_json.?;
        self.response_json = null;
        self.pending_id = 0;
        self.unlock();
        defer self.allocator.free(resp_json);

        self.announceDone("ui_request_done", id);
        return parseResponse(req, resp_json, allocator, out);
    }

    fn announceDone(self: *WebBackend, comptime kind: []const u8, id: u64) void {
        const line = std.fmt.allocPrint(self.allocator, "{{\"" ++ kind ++ "\":{{\"id\":{d}}}}}", .{id}) catch return;
        defer self.allocator.free(line);
        self.journal.append(line);
    }

    /// HTTP 线程:回填响应。id 必须匹配当前挂起(防 stale 对话框回填新请求)。
    /// 返回 false = 无此挂起请求(过期/重复提交),HTTP 层回 409。
    pub fn respond(self: *WebBackend, id: u64, resp_json: []const u8) bool {
        const owned = self.allocator.dupe(u8, resp_json) catch return false;
        self.lock();
        defer self.unlock();
        if (self.pending_id != id or self.response_json != null) {
            self.allocator.free(owned);
            return false;
        }
        self.response_json = owned;
        _ = self.cond.broadcast();
        return true;
    }
};

/// 中断取消时的安全兜底:permission/plan 用显式拒绝(绝不静默放行、绝不落回 fd 0
/// 文字 prompt——那属于另一个 UI 世界);ask/custom 报 InputAborted(对齐 TUI Esc 语义)。
fn cancelOutcome(req: *const UiRequest, out: *UiResponse) anyerror!RequestOutcome {
    switch (req.*) {
        .permission => {
            out.* = .{ .permission = .deny_once };
            return .answered;
        },
        .plan_approval => {
            out.* = .{ .plan_approval = .reject };
            return .answered;
        },
        else => return error.InputAborted,
    }
}

/// 按请求 tag 解析浏览器回填的 JSON → UiResponse。
/// 响应格式(与 index.html 约定):
///   permission:    {"choice":"allow_once"|"allow_always"|"deny_once"|"deny_tool_session"}
///   plan_approval: {"choice":"approve_default"|"approve_accept_edits"|"reject"}
///   ask_question:  {"answers":["label", ...]}(每问一条,多选已 ", " 拼接)
///   custom:        {"result":<任意 JSON>}
/// 解析失败走 cancelOutcome 同款安全兜底(坏响应≠放行)。
fn parseResponse(req: *const UiRequest, resp_json: []const u8, allocator: std.mem.Allocator, out: *UiResponse) anyerror!RequestOutcome {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), resp_json, .{}) catch {
        log.warn("web", "ui response parse failed, safe-deny", .{});
        return cancelOutcome(req, out);
    };
    if (parsed != .object) return cancelOutcome(req, out);
    const obj = parsed.object;

    switch (req.*) {
        .permission => {
            const c = choiceField(obj, PermissionChoice) orelse return cancelOutcome(req, out);
            out.* = .{ .permission = c };
            return .answered;
        },
        .plan_approval => {
            const c = choiceField(obj, PlanApproval) orelse return cancelOutcome(req, out);
            out.* = .{ .plan_approval = c };
            return .answered;
        },
        .ask_question => |questions| {
            const answers_v = obj.get("answers") orelse return cancelOutcome(req, out);
            if (answers_v != .array) return cancelOutcome(req, out);
            if (answers_v.array.items.len != questions.len) return cancelOutcome(req, out);
            const answers = try allocator.alloc([]const u8, answers_v.array.items.len);
            var filled: usize = 0;
            errdefer {
                for (answers[0..filled]) |a| allocator.free(a);
                allocator.free(answers);
            }
            for (answers_v.array.items, 0..) |a, i| {
                if (a != .string) return error.InvalidUiResponse;
                answers[i] = try allocator.dupe(u8, a.string);
                filled += 1;
            }
            out.* = .{ .answers = answers };
            return .answered;
        },
        .custom => {
            const result_v = obj.get("result") orelse return cancelOutcome(req, out);
            // 原样回传结构化结果(重新序列化 value → owned by allocator)
            const result_json = try std.json.Stringify.valueAlloc(allocator, result_v, .{});
            out.* = .{ .custom = result_json };
            return .answered;
        },
    }
}

fn choiceField(obj: std.json.ObjectMap, comptime E: type) ?E {
    const v = obj.get("choice") orelse return null;
    if (v != .string) return null;
    return std.meta.stringToEnum(E, v.string);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "emit 把 CoreEvent 以 core_event 信封落 journal" {
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
    try testing.expect(std.mem.indexOf(u8, batch[0], "\"core_event\"") != null);
    try testing.expect(std.mem.indexOf(u8, batch[0], "text_chunk") != null);
    try testing.expect(std.mem.indexOf(u8, batch[0], "hello web") != null);
    try testing.expect(std.mem.indexOf(u8, batch[1], "stream_done") != null);
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
            if (std.mem.indexOf(u8, batch[0], "\"ui_request\"") == null) return;
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

    // journal 尾部应有 ui_request_done
    const all = (try j.waitSince(testing.allocator, 0, 10)).?;
    defer {
        for (all) |l| testing.allocator.free(l);
        testing.allocator.free(all);
    }
    try testing.expect(std.mem.indexOf(u8, all[all.len - 1], "ui_request_done") != null);
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
    try testing.expect(std.mem.indexOf(u8, all[all.len - 1], "ui_request_cancelled") != null);
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

test "parseResponse: ask_question 答案 dupe 到调用方 allocator" {
    const qs = [_]ui_request.AskQuestion{
        .{ .question = "a?", .header = "A", .multi = false, .options = &.{} },
        .{ .question = "b?", .header = "B", .multi = true, .options = &.{} },
    };
    const req = UiRequest{ .ask_question = &qs };
    var resp: UiResponse = undefined;
    const outcome = try parseResponse(&req, "{\"answers\":[\"x\",\"y, z\"]}", testing.allocator, &resp);
    try testing.expectEqual(RequestOutcome.answered, outcome);
    defer {
        for (resp.answers) |a| testing.allocator.free(a);
        testing.allocator.free(resp.answers);
    }
    try testing.expectEqual(@as(usize, 2), resp.answers.len);
    try testing.expectEqualStrings("x", resp.answers[0]);
    try testing.expectEqualStrings("y, z", resp.answers[1]);
}

test "parseResponse: 坏 JSON / 未知 choice → permission 安全 deny" {
    const req = UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    var resp: UiResponse = undefined;
    try testing.expectEqual(RequestOutcome.answered, try parseResponse(&req, "not json", testing.allocator, &resp));
    try testing.expectEqual(PermissionChoice.deny_once, resp.permission);
    try testing.expectEqual(RequestOutcome.answered, try parseResponse(&req, "{\"choice\":\"pretty_please\"}", testing.allocator, &resp));
    try testing.expectEqual(PermissionChoice.deny_once, resp.permission);
}

test "parseResponse: custom result 原样(重序列化)回传" {
    const req = UiRequest{ .custom = .{ .kind = "video_timeline", .payload_json = "{}" } };
    var resp: UiResponse = undefined;
    const outcome = try parseResponse(&req, "{\"result\":{\"in\":3,\"out\":42}}", testing.allocator, &resp);
    try testing.expectEqual(RequestOutcome.answered, outcome);
    defer testing.allocator.free(resp.custom);
    try testing.expect(std.mem.indexOf(u8, resp.custom, "\"in\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.custom, "42") != null);
}
