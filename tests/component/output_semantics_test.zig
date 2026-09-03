//! L2: a real `agent_loop.run` classifies its visible output.
//!
//! Requirement: `doc/frommetawork/AGENT_OUTPUT_SEMANTICS_ISSUE.md`. The gap it
//! records is that a consumer seeing only `text_chunk` + `stream_done` cannot
//! tell an intermediate note from the answer, cannot join a max-token
//! continuation back into one result, and cannot tell a rolled-back fragment
//! from real output. Each test below drives the loop through one of those exact
//! shapes and asserts the loop states the answer instead of the consumer
//! guessing it.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const output_semantics = cc.output_semantics;
const Disposition = output_semantics.Disposition;

fn textSseAlloc(
    allocator: std.mem.Allocator,
    id: []const u8,
    text: []const u8,
    stop_reason: []const u8,
) ![]u8 {
    var escaped: std.Io.Writer.Allocating = .init(allocator);
    defer escaped.deinit();
    try std.json.Stringify.encodeJsonString(text, .{}, &escaped.writer);
    const encoded = try escaped.toOwnedSlice();
    defer allocator.free(encoded);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"{s}\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ id, encoded, stop_reason },
    );
}

/// Text, then a tool call, in one provider response.
fn textThenToolSse(
    allocator: std.mem.Allocator,
    id: []const u8,
    text: []const u8,
    tool_name: []const u8,
    tool_input: []const u8,
) ![]u8 {
    var text_escaped: std.Io.Writer.Allocating = .init(allocator);
    defer text_escaped.deinit();
    try std.json.Stringify.encodeJsonString(text, .{}, &text_escaped.writer);
    const text_encoded = try text_escaped.toOwnedSlice();
    defer allocator.free(text_encoded);

    var input_escaped: std.Io.Writer.Allocating = .init(allocator);
    defer input_escaped.deinit();
    try std.json.Stringify.encodeJsonString(tool_input, .{}, &input_escaped.writer);
    const input_encoded = try input_escaped.toOwnedSlice();
    defer allocator.free(input_encoded);

    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"{s}\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}_tu\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":1}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ id, text_encoded, id, tool_name, input_encoded },
    );
}

/// Collects the segment protocol exactly as an out-of-process consumer would:
/// buffer `text_chunk` into the open segment, then act on the disposition.
const SegmentCapture = struct {
    allocator: std.mem.Allocator,
    open: ?u32 = null,
    buffer: std.ArrayList(u8) = .empty,
    closed: std.ArrayList(Closed) = .empty,
    unbalanced: bool = false,
    thinking_bytes: usize = 0,

    const Closed = struct {
        index: u32,
        turn: u32,
        group: u32,
        disposition: Disposition,
        bytes: u64,
        text: []u8,
    };

    fn deinit(self: *SegmentCapture) void {
        self.buffer.deinit(self.allocator);
        for (self.closed.items) |c| self.allocator.free(c.text);
        self.closed.deinit(self.allocator);
    }

    fn emit(ctx: *anyopaque, _: cc.session_id.SessionId, ev: cc.ui_event.CoreEvent) void {
        const self: *SegmentCapture = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .output_segment_begin => |b| {
                if (self.open != null) self.unbalanced = true;
                self.open = b.index;
                self.buffer.clearRetainingCapacity();
            },
            .text_chunk => |t| {
                if (self.open == null) {
                    self.unbalanced = true;
                    return;
                }
                self.buffer.appendSlice(self.allocator, t) catch {};
            },
            // Thinking is never part of a visible segment and must never reach
            // a result. Counted so the test can assert it stayed separate.
            .thinking_chunk => |t| self.thinking_bytes += t.len,
            .output_segment_end => |e| {
                if (self.open == null or self.open.? != e.index) self.unbalanced = true;
                self.open = null;
                const text = self.allocator.dupe(u8, self.buffer.items) catch return;
                self.closed.append(self.allocator, .{
                    .index = e.index,
                    .turn = e.turn,
                    .group = e.group,
                    .disposition = e.disposition,
                    .bytes = e.bytes,
                    .text = text,
                }) catch self.allocator.free(text);
                self.buffer.clearRetainingCapacity();
            },
            else => {},
        }
    }

    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }

    fn backend(self: *SegmentCapture) cc.ui_backend.UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emit, .poll = poll };
    }

    /// The result an out-of-process consumer would assemble from the protocol
    /// alone, without reading the Conversation.
    fn assembledFinal(self: *const SegmentCapture, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        for (self.closed.items) |c| {
            if (c.disposition.contributesToFinal()) try out.appendSlice(allocator, c.text);
            // A group that ends in anything else was never an answer.
            if (c.disposition == .commentary or c.disposition == .partial) out.clearRetainingCapacity();
        }
    }
};

const Scenario = struct {
    capture: SegmentCapture,
    ledger: output_semantics.Ledger,
    result: cc.agent_loop.RunResult,

    fn deinit(self: *Scenario) void {
        self.capture.deinit();
        self.ledger.deinit();
    }
};

fn runCassette(
    allocator: std.mem.Allocator,
    responses: []const []const u8,
    root: []const u8,
    abort: ?*cc.util_abort.AbortSignal,
    max_stream_turn_retries: u8,
) !Scenario {
    return runCassetteRouted(allocator, responses, root, abort, max_stream_turn_retries, null);
}

/// `required_first_tool` 非 null → 给该内置工具打 required_first 激活路由
/// (无参数对:任一次成功调用即满足),复现 required_first 门与输出段协议的交互。
fn runCassetteRouted(
    allocator: std.mem.Allocator,
    responses: []const []const u8,
    root: []const u8,
    abort: ?*cc.util_abort.AbortSignal,
    max_stream_turn_retries: u8,
    required_first_tool: ?[]const u8,
) !Scenario {
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
    if (required_first_tool) |tool_name| {
        for (defs) |*d| {
            if (std.mem.eql(u8, d.name, tool_name)) d.model_activation = .{ .mode = .required_first };
        }
    }

    var capture = SegmentCapture{ .allocator = allocator };
    errdefer capture.deinit();
    var ledger = output_semantics.Ledger.init(allocator);
    errdefer ledger.deinit();
    const backend = capture.backend();

    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        defs,
        &permission,
        .{
            .max_turns = 8,
            .abort = abort,
            .output_ledger = &ledger,
            .cwd_abs = root,
            .home_dir = root,
            .max_stream_turn_retries = max_stream_turn_retries,
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &backend,
        allocator,
    );
    return .{ .capture = capture, .ledger = ledger, .result = result };
}

fn tmpRoot(dir: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    return harness.normalizeSlashes(buf[0..try dir.dir.realPath(std.testing.io, buf)]);
}

test "L2 输出语义:工具调用前的文本是 commentary,end_turn 的文本才是 final" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    const glob_input = try std.fmt.allocPrint(a, "{{\"pattern\":\"*.none\",\"path\":\"{s}\"}}", .{root});
    defer a.free(glob_input);
    const turn1 = try textThenToolSse(a, "m1", "Let me look around.", "Glob", glob_input);
    defer a.free(turn1);
    const turn2 = try textSseAlloc(a, "m2", "Nothing there.", "end_turn");
    defer a.free(turn2);

    var scenario = try runCassette(a, &.{ turn1, turn2 }, root, null, 2);
    defer scenario.deinit();

    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, scenario.result.stop_reason);
    try std.testing.expect(!scenario.capture.unbalanced);
    try std.testing.expectEqual(@as(usize, 2), scenario.capture.closed.items.len);

    const first = scenario.capture.closed.items[0];
    try std.testing.expectEqual(Disposition.commentary, first.disposition);
    try std.testing.expectEqualStrings("Let me look around.", first.text);
    try std.testing.expectEqual(@as(u64, "Let me look around.".len), first.bytes);
    try std.testing.expectEqual(@as(u32, 1), first.turn);

    const second = scenario.capture.closed.items[1];
    try std.testing.expectEqual(Disposition.final, second.disposition);
    try std.testing.expectEqualStrings("Nothing there.", second.text);
    try std.testing.expectEqual(@as(u32, 2), second.turn);
    // A tool round closed the first group, so the answer is its own group.
    try std.testing.expect(second.group != first.group);

    // Core states the answer; nothing downstream re-derives it.
    try std.testing.expectEqualStrings("Nothing there.", scenario.ledger.finalText().?);
    try std.testing.expect(scenario.ledger.partialText() == null);
    try std.testing.expect(!scenario.ledger.truncated);

    // The event protocol alone reproduces the same answer.
    var assembled: std.ArrayList(u8) = .empty;
    defer assembled.deinit(a);
    try scenario.capture.assembledFinal(&assembled, a);
    try std.testing.expectEqualStrings("Nothing there.", assembled.items);
}

test "L2 输出语义:max_tokens 续写的多段合成一个 final" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    const cut = try textSseAlloc(a, "m1", "first half ", "max_tokens");
    defer a.free(cut);
    const rest = try textSseAlloc(a, "m2", "second half", "end_turn");
    defer a.free(rest);

    var scenario = try runCassette(a, &.{ cut, rest }, root, null, 2);
    defer scenario.deinit();

    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, scenario.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), scenario.capture.closed.items.len);

    const cut_seg = scenario.capture.closed.items[0];
    const final_seg = scenario.capture.closed.items[1];
    try std.testing.expectEqual(Disposition.continued, cut_seg.disposition);
    try std.testing.expectEqual(Disposition.final, final_seg.disposition);
    // One logical output ⇒ one group; `stream_done` fired twice and meant
    // nothing about completion.
    try std.testing.expectEqual(cut_seg.group, final_seg.group);

    try std.testing.expectEqualStrings("first half second half", scenario.ledger.finalText().?);

    var assembled: std.ArrayList(u8) = .empty;
    defer assembled.deinit(a);
    try scenario.capture.assembledFinal(&assembled, a);
    try std.testing.expectEqualStrings("first half second half", assembled.items);
}

test "L2 输出语义:中断产出的文本是 partial,永远不是 final" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    // Abort before the run starts: the loop stops at the first checkpoint with
    // no visible output, which must still not be reported as an answer.
    var abort = cc.util_abort.AbortSignal.init();
    abort.abort(.user_ctrl_c);
    const only = try textSseAlloc(a, "m1", "unreachable", "end_turn");
    defer a.free(only);

    var scenario = try runCassette(a, &.{only}, root, &abort, 2);
    defer scenario.deinit();

    try std.testing.expectEqual(cc.agent_loop.StopReason.aborted, scenario.result.stop_reason);
    try std.testing.expect(scenario.ledger.finalText() == null);
    // An aborted Run never claims a completed result — that is the whole point.
    for (scenario.capture.closed.items) |c| {
        try std.testing.expect(c.disposition != .final);
    }
}

test "L2 输出语义:流内失败回滚的那段标 discarded,重试后的才是 final" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    // A stream that emits text and then dies mid-body: the loop discards the
    // fragment (never committed to the Conversation) and re-issues the turn.
    const truncated =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"half-writ\"}}\n\n" ++
        "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"boom\"}}\n\n";
    const good = try textSseAlloc(a, "m2", "clean answer", "end_turn");
    defer a.free(good);

    var scenario = try runCassette(a, &.{ truncated, good }, root, null, 2);
    defer scenario.deinit();

    if (scenario.result.stop_reason != .end_turn) return error.SkipZigTest;
    try std.testing.expect(scenario.capture.closed.items.len >= 2);

    const rolled_back = scenario.capture.closed.items[0];
    try std.testing.expectEqual(Disposition.discarded, rolled_back.disposition);
    try std.testing.expect(!rolled_back.disposition.isVisible());

    const answer = scenario.capture.closed.items[scenario.capture.closed.items.len - 1];
    try std.testing.expectEqual(Disposition.final, answer.disposition);

    // The discarded fragment must not leak into the result, and the index it
    // consumed proves the rollback happened rather than being invisible.
    try std.testing.expectEqualStrings("clean answer", scenario.ledger.finalText().?);
    try std.testing.expectEqual(@as(u32, 0), rolled_back.index);
    try std.testing.expect(answer.index > rolled_back.index);
    // 回滚不切换 group:一次逻辑输出的重试仍属同一组,否则按 group 拼接的消费者会把
    // 之前的续写段丢在一个 final 不再属于的组里。
    try std.testing.expectEqual(rolled_back.group, answer.group);

    var assembled: std.ArrayList(u8) = .empty;
    defer assembled.deinit(a);
    try scenario.capture.assembledFinal(&assembled, a);
    try std.testing.expectEqualStrings("clean answer", assembled.items);
}

test "L2 输出语义:headless 结果行按 core 的定性给 text_kind" {
    const a = std.testing.allocator;
    var ledger = output_semantics.Ledger.init(a);
    defer ledger.deinit();

    // No output yet.
    try std.testing.expectEqualStrings("none", cc.repl_headless.projectRunText(&ledger).kind);

    ledger.record(.{ .index = 0, .turn = 1, .group = 0, .disposition = .partial, .bytes = 4 }, "frag");
    const partial = cc.repl_headless.projectRunText(&ledger);
    try std.testing.expectEqualStrings("partial", partial.kind);
    try std.testing.expectEqualStrings("frag", partial.text.?);

    ledger.record(.{ .index = 1, .turn = 2, .group = 1, .disposition = .final, .bytes = 6 }, "answer");
    const final = cc.repl_headless.projectRunText(&ledger);
    try std.testing.expectEqualStrings("final", final.kind);
    try std.testing.expectEqualStrings("answer", final.text.?);

    const usage = cc.app_module.UsageTotals{};
    const line = try cc.repl_headless.buildResultLine(
        a,
        final.text.?,
        final.kind,
        null,
        .{ .stop_reason = .end_turn, .turns = 2, .tool_calls = 0 },
        &usage,
        "m",
    );
    defer a.free(line);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, std.mem.trimEnd(u8, line, "\n"), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("final", parsed.value.object.get("text_kind").?.string);
    try std.testing.expectEqualStrings("answer", parsed.value.object.get("text").?.string);
}

test "L2 输出语义:required_first 修复轮的文本是 commentary,段协议保持配对" {
    // 回归:required_first 门的 repair-continue 出口曾不收段 → 段跨轮悬开,
    // 下一轮 begin 静默覆盖 → 一个 output_segment_begin 永远没有配对的 end
    // (capture.unbalanced),Ledger 也漏记。修后:与其它 nudge 路径同款,
    // 主机拒绝的过早"最终答案"定性 .commentary。
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    // turn1:路由未满足就交"答案"(违约,触发 repair);turn2:补上 Glob 调用
    // (满足路由);turn3:真正的最终答案。
    const premature = try textSseAlloc(a, "m1", "I am done now.", "end_turn");
    defer a.free(premature);
    const glob_input = try std.fmt.allocPrint(a, "{{\"pattern\":\"*.none\",\"path\":\"{s}\"}}", .{root});
    defer a.free(glob_input);
    const comply = try textThenToolSse(a, "m2", "Let me comply.", "Glob", glob_input);
    defer a.free(comply);
    const answer = try textSseAlloc(a, "m3", "All set.", "end_turn");
    defer a.free(answer);

    var scenario = try runCassetteRouted(a, &.{ premature, comply, answer }, root, null, 2, "Glob");
    defer scenario.deinit();

    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, scenario.result.stop_reason);
    try std.testing.expect(!scenario.capture.unbalanced);
    try std.testing.expectEqual(@as(usize, 3), scenario.capture.closed.items.len);

    const rejected = scenario.capture.closed.items[0];
    try std.testing.expectEqual(Disposition.commentary, rejected.disposition);
    try std.testing.expectEqualStrings("I am done now.", rejected.text);
    try std.testing.expectEqual(@as(u64, "I am done now.".len), rejected.bytes);

    try std.testing.expectEqual(Disposition.commentary, scenario.capture.closed.items[1].disposition);
    const final = scenario.capture.closed.items[2];
    try std.testing.expectEqual(Disposition.final, final.disposition);
    try std.testing.expectEqualStrings("All set.", final.text);

    // Ledger 与事件流同一结论:被拒的"答案"不是答案。
    try std.testing.expectEqual(@as(usize, 2), scenario.ledger.countOf(.commentary));
    try std.testing.expectEqualStrings("All set.", scenario.ledger.finalText().?);
    try std.testing.expect(scenario.ledger.partialText() == null);
}

test "L2 输出语义:required_first 修复额度耗尽 fail-closed,partial 正文进 Ledger" {
    // 回归:fail-closed return 出口曾靠 run 顶 defer 兜底收段——定性 .partial 与
    // 字节数都对,但兜底拿不到正文,Ledger 里这段 partial 是空串。修后显式收段。
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    const try1 = try textSseAlloc(a, "m1", "try one", "end_turn");
    defer a.free(try1);
    const try2 = try textSseAlloc(a, "m2", "try two", "end_turn");
    defer a.free(try2);
    const try3 = try textSseAlloc(a, "m3", "try three", "end_turn");
    defer a.free(try3);

    var scenario = try runCassetteRouted(a, &.{ try1, try2, try3 }, root, null, 2, "Glob");
    defer scenario.deinit();

    // MAX_REQUIRED_FIRST_REPAIRS=2:两次修复后第三次违约 fail-closed。
    try std.testing.expectEqual(cc.agent_loop.StopReason.tool_loop, scenario.result.stop_reason);
    try std.testing.expect(!scenario.capture.unbalanced);
    try std.testing.expectEqual(@as(usize, 3), scenario.capture.closed.items.len);
    try std.testing.expectEqual(Disposition.commentary, scenario.capture.closed.items[0].disposition);
    try std.testing.expectEqual(Disposition.commentary, scenario.capture.closed.items[1].disposition);

    const last = scenario.capture.closed.items[2];
    try std.testing.expectEqual(Disposition.partial, last.disposition);
    try std.testing.expectEqual(@as(u64, "try three".len), last.bytes);

    // 核心回归断言:partial 正文必须落进 Ledger(兜底路径只有空串)。
    try std.testing.expectEqualStrings("try three", scenario.ledger.partialText().?);
    try std.testing.expect(scenario.ledger.finalText() == null);
}
