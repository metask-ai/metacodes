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
            std.mem.indexOf(u8, body, "decompose the task statement") != null)
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
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
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
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
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
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
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
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
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
