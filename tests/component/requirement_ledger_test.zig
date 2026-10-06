//! L2: the requirement-ledger closure obligation. The ledger prompt lands at
//! the first tool-result boundary (never the cacheable first request); a
//! premature final with open ledger items gets a bounded nudge; closing the
//! ledger satisfies the obligation; sessions without ledger or mutations are
//! never touched. Task-agnostic process machinery — no benchmark content.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const END_TURN =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"done\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn toolSse(allocator: std.mem.Allocator, id: []const u8, name: []const u8, input: []const u8) ![]u8 {
    var escaped: std.Io.Writer.Allocating = .init(allocator);
    defer escaped.deinit();
    try std.json.Stringify.encodeJsonString(input, .{}, &escaped.writer);
    const encoded = try escaped.toOwnedSlice();
    defer allocator.free(encoded);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_{s}\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ id, id, name, encoded },
    );
}

const LedgerRecordSink = struct {
    records: usize = 0,
    enforced: bool = false,
    prompt_emitted: bool = false,
    items_total: u32 = 0,
    items_open: u32 = 0,
    nudges: u8 = 255,

    fn emit(raw: *anyopaque, event: cc.tools.tool_observation.Event) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (event) {
            .requirement_ledger => |record| {
                self.records += 1;
                self.enforced = record.enforced;
                self.prompt_emitted = record.prompt_emitted;
                self.items_total = record.items_total;
                self.items_open = record.items_open_at_final;
                self.nudges = record.nudges;
            },
            else => {},
        }
        return true;
    }

    fn sink(self: *@This()) cc.tools.tool_observation.Sink {
        return .{ .ctx = @ptrCast(self), .emitFn = emit };
    }
};

const LedgerRun = struct {
    requests: usize,
    prompt_request: ?[]u8,
    nudge_request: ?[]u8,
    record: LedgerRecordSink,

    fn deinit(self: *LedgerRun, allocator: std.mem.Allocator) void {
        if (self.prompt_request) |bytes| allocator.free(bytes);
        if (self.nudge_request) |bytes| allocator.free(bytes);
    }
};

fn runLedger(
    allocator: std.mem.Allocator,
    root: []const u8,
    enforced: bool,
    observe: bool,
    responses: []const []const u8,
) !LedgerRun {
    var server = try harness.MockServer.startCassette(responses, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(allocator, io_runtime.io(), "key", "model", url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, "do the work");
    var permission = cc.permission.createContext(.bypass_permissions, allocator);
    permission.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(allocator);
    defer allocator.free(defs);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    var record = LedgerRecordSink{};
    var store = cc.task_store.TaskStore.init(allocator);
    defer store.deinit();
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        defs,
        &permission,
        .{
            .max_turns = 8,
            .system_prompt = "STABLE-PREFIX",
            .requirement_ledger = enforced,
            .requirement_ledger_observe = observe,
            .tasks = &store,
            .tool_observer = record.sink(),
            .cwd_abs = root,
            .home_dir = root,
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &backend,
        allocator,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    var prompt_request: ?[]u8 = null;
    var nudge_request: ?[]u8 = null;
    var index: usize = 0;
    while (server.requestAt(index)) |request| : (index += 1) {
        const body = request.body();
        if (prompt_request == null and
            std.mem.indexOf(u8, body, "decompose the task statement AND every") != null and
            std.mem.indexOf(u8, body, "host-injected requirement") != null)
        {
            prompt_request = try allocator.dupe(u8, body);
        }
        if (nudge_request == null and
            std.mem.indexOf(u8, body, "still") != null and
            std.mem.indexOf(u8, body, "task ledger") != null)
        {
            nudge_request = try allocator.dupe(u8, body);
        }
    }
    return .{
        .requests = server.requestCount(),
        .prompt_request = prompt_request,
        .nudge_request = nudge_request,
        .record = record,
    };
}

fn createTaskSse(allocator: std.mem.Allocator, id: []const u8, subject: []const u8) ![]u8 {
    const input = try std.fmt.allocPrint(
        allocator,
        "{{\"subject\":\"{s}\",\"description\":\"{s}\"}}",
        .{ subject, subject },
    );
    defer allocator.free(input);
    return toolSse(allocator, id, "TaskCreate", input);
}

test "L2 open ledger items nudge a premature final and closure then satisfies" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(buf[0..try tmp.dir.realPath(std.testing.io, &buf)]);
    const create = try createTaskSse(a, "task_1", "first requirement");
    defer a.free(create);
    const close = try toolSse(a, "task_2", "TaskUpdate", "{\"taskId\":\"1\",\"status\":\"completed\"}");
    defer a.free(close);
    // create item → premature final (nudged: 1 open) → close item → final.
    var run = try runLedger(a, root, true, false, &.{ create, END_TURN, close, END_TURN });
    defer run.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), run.requests);
    try std.testing.expect(run.prompt_request != null);
    try std.testing.expect(run.nudge_request != null);
    try std.testing.expect(
        std.mem.indexOf(u8, run.nudge_request.?, "1 item(s)") != null,
    );
    try std.testing.expectEqual(@as(usize, 1), run.record.records);
    try std.testing.expect(run.record.enforced);
    try std.testing.expect(run.record.prompt_emitted);
    try std.testing.expectEqual(@as(u32, 0), run.record.items_open);
    try std.testing.expectEqual(@as(u32, 1), run.record.items_total);
    try std.testing.expectEqual(@as(u8, 1), run.record.nudges);
}

test "L2 a pure-text session is never prompted or nudged" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(buf[0..try tmp.dir.realPath(std.testing.io, &buf)]);
    var run = try runLedger(a, root, true, false, &.{END_TURN});
    defer run.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), run.requests);
    try std.testing.expect(run.prompt_request == null);
    try std.testing.expect(run.nudge_request == null);
    try std.testing.expect(!run.record.prompt_emitted);
    try std.testing.expectEqual(@as(u8, 0), run.record.nudges);
}

test "L2 mutations without a ledger get one coverage nudge" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(buf[0..try tmp.dir.realPath(std.testing.io, &buf)]);
    const write_input = try std.fmt.allocPrint(
        a,
        "{{\"file_path\":\"{s}/thing.txt\",\"content\":\"data\\n\"}}",
        .{root},
    );
    defer a.free(write_input);
    const write = try toolSse(a, "write_1", "Write", write_input);
    defer a.free(write);
    // write (prompt lands with its results) → premature final (coverage
    // nudge) → final.
    var run = try runLedger(a, root, true, false, &.{ write, END_TURN, END_TURN });
    defer run.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), run.requests);
    try std.testing.expect(run.prompt_request != null);
    try std.testing.expectEqual(@as(u8, 1), run.record.nudges);
    try std.testing.expectEqual(@as(u32, 0), run.record.items_total);
}

test "L2 observe mode records the ledger without prompting or nudging" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(buf[0..try tmp.dir.realPath(std.testing.io, &buf)]);
    const create = try createTaskSse(a, "task_1", "left open");
    defer a.free(create);
    var run = try runLedger(a, root, false, true, &.{ create, END_TURN });
    defer run.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), run.requests);
    try std.testing.expect(run.prompt_request == null);
    try std.testing.expect(run.nudge_request == null);
    try std.testing.expectEqual(@as(usize, 1), run.record.records);
    try std.testing.expect(!run.record.enforced);
    try std.testing.expectEqual(@as(u32, 1), run.record.items_open);
}

// PO-V2 M1(fstack-r2 断线):KG write-through 任务闭合时镜像被物理删除,
// 旧 ledgerCounts 只数存活行 → 健康的"全建全闭"会话被记 items_total=0,
// end-gate 据此误发"从未记录需求账本"。终身计数修复后,闭合不再抹掉
// "曾登记"的事实。
test "kg mirror closure keeps the lifetime ledger total" {
    const a = std.testing.allocator;
    var store = cc.task_store.TaskStore.init(a);
    defer store.deinit();

    try store.createWithId("kg-101", "requirement one", "desc", .pending);
    try store.createWithId("kg-102", "requirement two", "desc", .pending);
    var counts = store.ledgerCounts();
    try std.testing.expectEqual(@as(usize, 2), counts.open);
    try std.testing.expectEqual(@as(usize, 2), counts.total);

    // 终态处置 = 镜像删除 + 终身计数(removeKgMirror 的两步)。
    try store.updateStatus("kg-101", .deleted);
    store.noteKgMirrorClosed();
    counts = store.ledgerCounts();
    try std.testing.expectEqual(@as(usize, 1), counts.open);
    try std.testing.expectEqual(@as(usize, 2), counts.total);

    // 全部闭合:open 归零,total 保持——绝不能出**假 coverage**(修复前
    // 这里是 decide(0, 0, true) → 假 coverage nudge)。新政策下闭合且极短
    // (total=2 ≤ SHALLOW_FLOOR)的账本得到一次 shallow 重扫,消耗后归 none。
    try store.updateStatus("kg-102", .deleted);
    store.noteKgMirrorClosed();
    counts = store.ledgerCounts();
    try std.testing.expectEqual(@as(usize, 0), counts.open);
    try std.testing.expectEqual(@as(usize, 2), counts.total);
    var state = cc.requirement_ledger.State{ .prompt_emitted = true };
    try std.testing.expectEqual(
        cc.requirement_ledger.Decision.shallow,
        state.decide(counts.open, counts.total, true),
    );
    state.shallow_nudge_used = true;
    try std.testing.expectEqual(
        cc.requirement_ledger.Decision.none,
        state.decide(counts.open, counts.total, true),
    );
}

/// 跑一次只认领任务 1 的 loop,返回任务行记下的认领者(owned)。
fn claimantRecordedByLoop(
    a: std.mem.Allocator,
    root: []const u8,
    session: cc.session_id.SessionId,
    agent_ident: ?cc.session_id.SessionId,
) ![]u8 {
    const create = try createTaskSse(a, "c1", "work");
    defer a.free(create);
    const claim = try toolSse(a, "c2", "TaskUpdate", "{\"taskId\":\"1\",\"status\":\"in_progress\"}");
    defer a.free(claim);
    var server = try harness.MockServer.startCassette(&.{ create, claim, END_TURN }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "key", "model", url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(a);
    defer conversation.deinit();
    try conversation.appendText(.user, "do the work");
    var permission = cc.permission.createContext(.bypass_permissions, a);
    permission.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    var store = cc.task_store.TaskStore.init(a);
    defer store.deinit();
    const result = try cc.agent_loop.run(&conversation, client.provider(), defs, &permission, .{
        .max_turns = 6,
        .system_prompt = "STABLE-PREFIX",
        .tasks = &store,
        .session = session,
        .agent_ident = agent_ident,
        .cwd_abs = root,
        .home_dir = root,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &backend, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    return a.dupe(u8, store.get("1").?.claimed_by orelse return error.ClaimNotRecorded);
}

// 主会话没有 kg_agent_ident:认领身份退到 agent_ident,再退到 session——与工具 kgAgentIdent 同源。
test "L2 without a KG identity the loop claims as its agent identity, else as its session" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(buf[0..try tmp.dir.realPath(std.testing.io, &buf)]);
    const session = cc.session_id.SessionId.fromSlice("0123456789abcdef01234567").?;
    const subagent = cc.session_id.SessionId.fromSlice("fedcba9876543210fedcba98").?;

    const as_session = try claimantRecordedByLoop(a, root, session, null);
    defer a.free(as_session);
    try std.testing.expectEqualStrings("0123456789abcdef01234567", as_session);

    const as_agent = try claimantRecordedByLoop(a, root, session, subagent);
    defer a.free(as_agent);
    try std.testing.expectEqualStrings("fedcba9876543210fedcba98", as_agent);
}

// agent_loop.run 声明的认领身份 = 工具认领 KG 租约的身份(kg_agent_ident orelse agent_ident):
// 认领记进任务行,关闭提示只列本 agent 的其它进行中任务——同一清单里队友认领的行不出现。
test "L2 the loop claims under its KG identity and a close lists only its own other claims" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(buf[0..try tmp.dir.realPath(std.testing.io, &buf)]);

    var store = cc.task_store.TaskStore.init(a);
    defer store.deinit();
    // 队友在同一清单(降级共享镜像)里的活认领。
    try store.createWithIdHeldBy("teammate-1", "TEAMMATE-ROW", "claimed by someone else", .in_progress, "teammate@team");

    const create_old = try createTaskSse(a, "t1", "own old");
    defer a.free(create_old);
    const create_cur = try createTaskSse(a, "t2", "own current");
    defer a.free(create_cur);
    const claim_old = try toolSse(a, "t3", "TaskUpdate", "{\"taskId\":\"1\",\"status\":\"in_progress\"}");
    defer a.free(claim_old);
    const claim_cur = try toolSse(a, "t4", "TaskUpdate", "{\"taskId\":\"2\",\"status\":\"in_progress\"}");
    defer a.free(claim_cur);
    const close_cur = try toolSse(a, "t5", "TaskUpdate", "{\"taskId\":\"2\",\"status\":\"completed\"}");
    defer a.free(close_cur);

    var server = try harness.MockServer.startCassette(&.{ create_old, create_cur, claim_old, claim_cur, close_cur, END_TURN }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "key", "model", url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(a);
    defer conversation.deinit();
    try conversation.appendText(.user, "do the work");
    var permission = cc.permission.createContext(.bypass_permissions, a);
    permission.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    const result = try cc.agent_loop.run(&conversation, client.provider(), defs, &permission, .{
        .max_turns = 10,
        .system_prompt = "STABLE-PREFIX",
        .tasks = &store,
        .kg_agent_ident = "worker@team",
        .cwd_abs = root,
        .home_dir = root,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &backend, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);

    try std.testing.expectEqualStrings("worker@team", store.get("1").?.claimed_by.?);
    try std.testing.expectEqualStrings("teammate@team", store.get("teammate-1").?.claimed_by.?);

    // 关闭 2 之后的那次请求带着它的工具结果:只列本 agent 的 1,不列队友的行。
    try std.testing.expectEqual(@as(usize, 6), server.requestCount());
    const after_close = server.requestAt(5).?.body();
    try std.testing.expect(std.mem.indexOf(u8, after_close, "still_in_progress\\\":{\\\"tasks\\\":[{\\\"id\\\":\\\"1\\\",\\\"subject\\\":\\\"own old\\\"}]") != null);
    for (0..server.requestCount()) |index| {
        try std.testing.expect(std.mem.indexOf(u8, server.requestAt(index).?.body(), "TEAMMATE-ROW") == null);
    }
}
