//! Issue #461: every model request gets one re-issue of its own after a
//! transient stream interruption (`agent_loop.STREAM_RETRIES_PER_REQUEST`),
//! with no Host budget and no headless option.
//!
//! The re-issue is for a connection that gave no answer only
//! (`isSilentRetryFailure`: a stall, a drop, a body that ended before its stop
//! report) and only while the failed response had not begun a tool call, not
//! even one whose arguments were still streaming. The failed attempt's output
//! (text and thinking) is discarded with it, the same request goes out again,
//! and an attempt that showed something is announced with `retry_notice`
//! before a short backoff that an abort cuts short. These tests drive the real
//! clients and the real loop against a cassette server and read the events and
//! request bodies the way a Host does.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;

// ── cassettes ────────────────────────────────────────────────────────────────

const START = "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n";

/// Partial text, then the connection's clean end without a stop report.
const TEXT_THEN_EOF = START ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"PARTIAL_SENTINEL\"}}\n\n";

/// Thinking only, then the same end.
const THINKING_THEN_EOF = START ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"THINKING_SENTINEL\"}}\n\n";

/// Partial text, then the server's own statement of failure.
const TEXT_THEN_ERROR = START ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"PARTIAL_SENTINEL\"}}\n\n" ++
    "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n";

/// A tool call whose arguments were still streaming when the body ended.
const TOOL_ARGS_THEN_EOF = START ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_cut\",\"name\":\"Glob\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"pattern\\\":\\\"*.m\"}}\n\n";

const CHAT_TOOL_ARGS_THEN_EOF =
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"index\":0,\"id\":\"call_cut\",\"type\":\"function\",\"function\":{\"name\":\"Glob\",\"arguments\":\"\"}}]}}]}\n\n" ++
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"pattern\\\":\"}}]}}]}\n\n";

const RESPONSES_TOOL_ARGS_THEN_EOF =
    "event: response.output_item.added\n" ++
    "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_cut\",\"call_id\":\"call_cut\",\"name\":\"Glob\",\"arguments\":\"\"}}\n\n" ++
    "event: response.function_call_arguments.delta\n" ++
    "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_cut\",\"output_index\":0,\"delta\":\"{\\\"pattern\\\":\"}\n\n";

const CHAT_COMPLETE =
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"complete answer\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

const RESPONSES_COMPLETE =
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_2\",\"output_index\":0,\"delta\":\"complete answer\"}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_2\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2}}}\n\n";

fn completeSse(comptime text: []const u8) []const u8 {
    return START ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"" ++ text ++ "\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
}

const COMPLETE = completeSse("complete answer");

/// One finished tool call `id` of `name` with `input` (a JSON object).
fn toolCallSse(a: std.mem.Allocator, id: []const u8, name: []const u8, input: []const u8) ![]u8 {
    var encoded: std.Io.Writer.Allocating = .init(a);
    defer encoded.deinit();
    try std.json.Stringify.encodeJsonString(input, .{}, &encoded.writer);
    return std.fmt.allocPrint(a, "{s}" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":2}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{ START, id, name, encoded.written() });
}

// ── a Host's view ────────────────────────────────────────────────────────────

const EventLog = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    /// Raised by the first `retry_notice`, when set (the backoff test).
    on_retry: ?*std.atomic.Value(bool) = null,

    fn deinit(self: *EventLog) void {
        self.text.deinit(self.allocator);
    }

    fn line(self: *EventLog, comptime fmt: []const u8, args: anytype) void {
        self.text.print(self.allocator, fmt ++ "\n", args) catch {};
    }

    fn emit(ctx: *anyopaque, _: cc.session_id.SessionId, ev: cc.ui_event.CoreEvent) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .output_segment_begin => |b| self.line("begin {d}", .{b.index}),
            .text_chunk => |t| self.line("text {d}", .{t.len}),
            .thinking_chunk => |t| self.line("thinking {d}", .{t.len}),
            .output_segment_end => |e| self.line("end {d} turn {d} {s} {d}", .{ e.index, e.turn, @tagName(e.disposition), e.bytes }),
            .thinking_discarded => |d| self.line("thinking_discarded {d} turn {d} {d}", .{ d.index, d.turn, d.bytes }),
            .retry_notice => |r| {
                self.line("retry {d}/{d} after {d}", .{ r.attempt, r.max, r.delay_ms });
                if (self.on_retry) |flag| flag.store(true, .release);
            },
            .tool_start => |t| self.line("tool_start {s}", .{t.name}),
            else => {},
        }
    }

    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }

    fn backend(self: *EventLog) cc.ui_backend.UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emit, .poll = poll };
    }

    fn count(self: *const EventLog, needle: []const u8) usize {
        return std.mem.count(u8, self.text.items, needle);
    }
};

const Wire = enum { anthropic, openai_chat, openai_responses };

/// One Run against a cassette, with the real tool set rooted at `root` (or no
/// tools), and nothing but test-only `Options` beyond that: no Host budget, no
/// headless retries.
const Fixture = struct {
    a: std.mem.Allocator,
    srv: *harness.MockServer,
    url: []u8,
    conv: cc.conversation.Conversation,
    events: EventLog,
    result: agent_loop.RunResult = undefined,

    fn init(a: std.mem.Allocator, bodies: []const []const u8) !Fixture {
        const srv = try harness.MockServer.startCassette(bodies, 0);
        errdefer srv.stop();
        const url = try srv.urlOwned(a);
        errdefer a.free(url);
        var conv = cc.conversation.Conversation.init(a);
        errdefer conv.deinit();
        try conv.appendText(.user, "do the task");
        return .{ .a = a, .srv = srv, .url = url, .conv = conv, .events = .{ .allocator = a } };
    }

    fn deinit(self: *Fixture) void {
        self.events.deinit();
        self.conv.deinit();
        self.a.free(self.url);
        self.srv.stop();
    }

    const RunSpec = struct {
        wire: Wire = .anthropic,
        root: ?[]const u8 = null,
        backoff_ms: u32 = 0,
        abort: ?*cc.util_abort.AbortSignal = null,
    };

    fn run(self: *Fixture, spec: RunSpec) !void {
        var io_rt = @import("platform").signal.threadedIo(self.a, .{});
        defer io_rt.deinit();
        const io = io_rt.io();
        switch (spec.wire) {
            .anthropic => {
                var client = cc.client_mod.Client.initWithBaseUrl(self.a, io, "key", "model", self.url);
                defer client.deinit();
                try self.runLoop(client.provider(), spec);
            },
            .openai_chat, .openai_responses => {
                var client = cc.api_openai.OpenAIClient.init(self.a, io, "key", "model", self.url);
                defer client.deinit();
                if (spec.wire == .openai_responses) client.protocol = .responses;
                try self.runLoop(client.provider(), spec);
            },
        }
    }

    fn runLoop(self: *Fixture, provider: cc.api_provider.Provider, spec: RunSpec) !void {
        var perm = cc.permission.createContext(.bypass_permissions, self.a);
        perm.no_interactive_prompt = true;
        const defs = try cc.tools.toToolDefinitions(self.a);
        defer self.a.free(defs);
        const tools: []const cc.json_mod.ToolDefinition = if (spec.root != null) defs else &.{};
        const be = self.events.backend();
        self.result = try agent_loop.run(&self.conv, provider, tools, &perm, .{
            .max_turns = 6,
            .cwd_abs = spec.root orelse "",
            .home_dir = spec.root orelse "",
            .auto_compact_threshold = std.math.maxInt(usize),
            .abort = spec.abort,
            .stream_retry_backoff_ms = spec.backoff_ms,
        }, &be, self.a);
    }

    fn body(self: *const Fixture, index: usize) ![]const u8 {
        return (self.srv.requestAt(index) orelse return error.MissingRequest).body();
    }

    fn requests(self: *const Fixture) usize {
        return self.srv.requestCount();
    }

    /// Every assistant block the Conversation kept, text and thinking.
    fn history(self: *const Fixture, a: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        for (self.conv.messages.items) |m| {
            if (m.role != .assistant) continue;
            for (m.blocks) |b| switch (b) {
                .text => |t| try out.print(a, "[text:{s}]", .{t}),
                .thinking => |t| try out.print(a, "[thinking:{s}]", .{t}),
                .tool_use => |t| try out.print(a, "[tool_use:{s}]", .{t.id}),
                else => {},
            };
        }
        return out.toOwnedSlice(a);
    }
};

fn tmpRoot(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    return harness.normalizeSlashes(buf[0..try tmp.dir.realPath(std.testing.io, buf)]);
}

// ── acceptance (#461) ────────────────────────────────────────────────────────

test "issue #461: after a file-writing tool, a response cut after partial text is re-issued once and only the retry's answer is kept" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);
    const target = try std.fmt.allocPrint(a, "{s}/note-461.txt", .{root});
    defer a.free(target);
    var input: std.Io.Writer.Allocating = .init(a);
    defer input.deinit();
    try input.writer.writeAll("{\"file_path\":");
    try std.json.Stringify.encodeJsonString(target, .{}, &input.writer);
    try input.writer.writeAll(",\"content\":\"written once\"}");
    const write_call = try toolCallSse(a, "toolu_write", "Write", input.written());
    defer a.free(write_call);

    var fx = try Fixture.init(a, &.{ write_call, TEXT_THEN_EOF, completeSse("RETRY_ANSWER") });
    defer fx.deinit();
    try fx.run(.{ .root = root, .backoff_ms = 5 });

    try std.testing.expectEqual(agent_loop.StopReason.end_turn, fx.result.stop_reason);
    // Three model requests: the tool call, the cut answer, its re-issue.
    try std.testing.expectEqual(@as(usize, 3), fx.requests());
    // The re-issue repeats the second request byte for byte: the tool's result
    // from the earlier turn is kept, nothing of the cut answer is added.
    try std.testing.expectEqualStrings(try fx.body(1), try fx.body(2));
    try std.testing.expect(std.mem.indexOf(u8, try fx.body(2), "\"tool_use_id\":\"toolu_write\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, try fx.body(2), "PARTIAL_SENTINEL") == null);
    // The tool ran exactly once.
    try std.testing.expectEqual(@as(u32, 1), fx.result.tool_calls);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, try fx.body(2), "\"tool_use_id\":\"toolu_write\""));
    var file_buf: [64]u8 = undefined;
    const written = try tmp.dir.readFile(std.testing.io, "note-461.txt", &file_buf);
    try std.testing.expectEqualStrings("written once", written);
    // One notice, before the backoff: one failed stream of at most two.
    try std.testing.expectEqual(@as(usize, 1), fx.events.count("retry "));
    try std.testing.expectEqual(@as(usize, 1), fx.events.count("retry 1/2 after 5\n"));
    try std.testing.expectEqual(@as(usize, 1), fx.events.count(" discarded 16\n"));
    // The final answer is the retry's alone.
    const history = try fx.history(a);
    defer a.free(history);
    try std.testing.expectEqualStrings("[tool_use:toolu_write][text:RETRY_ANSWER]", history);
}

test "issue #461: a response cut after thinking only is re-issued and its thinking stays out of the history" {
    const a = std.testing.allocator;
    var fx = try Fixture.init(a, &.{ THINKING_THEN_EOF, COMPLETE, completeSse("NEXT_ANSWER") });
    defer fx.deinit();
    try fx.run(.{});

    try std.testing.expectEqual(agent_loop.StopReason.end_turn, fx.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), fx.requests());
    try std.testing.expectEqualStrings(try fx.body(0), try fx.body(1));
    try std.testing.expectEqualStrings(
        "begin 0\n" ++
            "thinking 17\n" ++
            "end 0 turn 1 discarded 0\n" ++
            "thinking_discarded 0 turn 1 17\n" ++
            "retry 1/2 after 0\n" ++
            "begin 1\n" ++
            "text 15\n" ++
            "end 1 turn 1 final 15\n",
        fx.events.text.items,
    );
    const history = try fx.history(a);
    defer a.free(history);
    try std.testing.expectEqualStrings("[text:complete answer]", history);
    // The next request of the Session carries none of it either.
    try fx.conv.appendText(.user, "and then");
    try fx.run(.{});
    try std.testing.expectEqual(@as(usize, 3), fx.requests());
    try std.testing.expect(std.mem.indexOf(u8, try fx.body(2), "THINKING_SENTINEL") == null);
    try std.testing.expect(std.mem.indexOf(u8, try fx.body(2), "complete answer") != null);
}

test "issue #461: two distinct model requests in one Run each get their own re-issue" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "marker-461.md", .data = "x" });
    var input: std.Io.Writer.Allocating = .init(a);
    defer input.deinit();
    try input.writer.writeAll("{\"pattern\":\"*.md\",\"path\":");
    try std.json.Stringify.encodeJsonString(root, .{}, &input.writer);
    try input.writer.writeAll("}");
    const glob_call = try toolCallSse(a, "toolu_glob", "Glob", input.written());
    defer a.free(glob_call);

    // Request 1 is cut, re-issued, and calls Glob; request 2 is cut,
    // re-issued, and answers.
    var fx = try Fixture.init(a, &.{ TEXT_THEN_EOF, glob_call, THINKING_THEN_EOF, COMPLETE });
    defer fx.deinit();
    try fx.run(.{ .root = root });

    try std.testing.expectEqual(agent_loop.StopReason.end_turn, fx.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 4), fx.requests());
    try std.testing.expectEqualStrings(try fx.body(0), try fx.body(1));
    try std.testing.expectEqualStrings(try fx.body(2), try fx.body(3));
    try std.testing.expect(!std.mem.eql(u8, try fx.body(1), try fx.body(2)));
    try std.testing.expect(std.mem.indexOf(u8, try fx.body(3), "marker-461.md") != null);
    // The first turn's re-issue did not use up the second's: each is the
    // first of its request.
    try std.testing.expectEqual(@as(usize, 2), fx.events.count("retry 1/2 after 0\n"));
    try std.testing.expectEqual(@as(usize, 2), fx.events.count("retry "));
    try std.testing.expectEqual(@as(u32, 1), fx.result.tool_calls);
}

test "issue #461: when both attempts of one request are cut, the Run ends api_error after two" {
    const a = std.testing.allocator;
    // The cassette repeats its last body: every attempt is cut.
    var fx = try Fixture.init(a, &.{TEXT_THEN_EOF});
    defer fx.deinit();
    try fx.run(.{});

    try std.testing.expectEqual(agent_loop.StopReason.api_error, fx.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), fx.requests());
    try std.testing.expectEqualStrings(try fx.body(0), try fx.body(1));
    try std.testing.expectEqualStrings(
        "begin 0\n" ++
            "text 16\n" ++
            "end 0 turn 1 discarded 16\n" ++
            "retry 1/2 after 0\n" ++
            "begin 1\n" ++
            "text 16\n" ++
            // The second failure is not re-issued: no notice follows it.
            "end 1 turn 1 discarded 16\n",
        fx.events.text.items,
    );
    const history = try fx.history(a);
    defer a.free(history);
    try std.testing.expectEqualStrings("", history);
}

const Canceller = struct {
    retried: std.atomic.Value(bool) = .init(false),
    signal: *cc.util_abort.AbortSignal,

    /// Waits for the notice, then cancels while the backoff is under way.
    fn run(self: *Canceller) void {
        while (!self.retried.load(.acquire)) cc.util_time.sleepMs(1);
        cc.util_time.sleepMs(50);
        self.signal.abort(.user_interrupt);
    }
};

test "issue #461: a cancel during the backoff ends the Run aborted and sends no re-issue" {
    const a = std.testing.allocator;
    var fx = try Fixture.init(a, &.{ TEXT_THEN_EOF, COMPLETE });
    defer fx.deinit();
    var signal = cc.util_abort.AbortSignal.init();
    var canceller = Canceller{ .signal = &signal };
    fx.events.on_retry = &canceller.retried;
    const thread = try std.Thread.spawn(.{}, Canceller.run, .{&canceller});

    const started = cc.util_time.nowNs();
    // A backoff far longer than the test: only the cancel can end it.
    fx.run(.{ .backoff_ms = 60_000, .abort = &signal }) catch |err| {
        signal.abort(.user_interrupt);
        thread.join();
        return err;
    };
    thread.join();
    const elapsed_ms = @divTrunc(cc.util_time.nowNs() - started, std.time.ns_per_ms);

    try std.testing.expectEqual(agent_loop.StopReason.aborted, fx.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), fx.requests());
    try std.testing.expectEqual(@as(usize, 1), fx.events.count("retry 1/2 after 60000\n"));
    try std.testing.expect(elapsed_ms < 30_000);
}

test "issue #461: a server-declared error, a local parse failure and a cut during tool arguments are sent once" {
    const a = std.testing.allocator;
    {
        var fx = try Fixture.init(a, &.{ TEXT_THEN_ERROR, COMPLETE });
        defer fx.deinit();
        try fx.run(.{});
        try std.testing.expectEqual(agent_loop.StopReason.api_error, fx.result.stop_reason);
        try std.testing.expectEqual(@as(usize, 1), fx.requests());
        try std.testing.expectEqual(@as(usize, 0), fx.events.count("retry "));
    }
    {
        // Visible text, then one data line past the line cap: StreamTooLong,
        // which a resend would hit again.
        const prefix = START ++
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"PARTIAL_SENTINEL\"}}\n\n" ++
            "data: ";
        const line_len = cc.api_stream.MAX_SSE_LINE_BYTES + 2;
        const huge = try a.alloc(u8, prefix.len + line_len + 2);
        defer a.free(huge);
        @memcpy(huge[0..prefix.len], prefix);
        @memset(huge[prefix.len..][0..line_len], 'x');
        @memcpy(huge[huge.len - 2 ..], "\n\n");
        var fx = try Fixture.init(a, &.{ huge, COMPLETE });
        defer fx.deinit();
        try fx.run(.{});
        try std.testing.expectEqual(agent_loop.StopReason.api_error, fx.result.stop_reason);
        try std.testing.expectEqual(@as(usize, 1), fx.requests());
        try std.testing.expectEqual(@as(usize, 0), fx.events.count("retry "));
    }
    // The body ends while a tool call's arguments stream: the loop never
    // received the call, but the parser saw it start. On every wire whose
    // calls stream their arguments.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);
    const cases = [_]struct { wire: Wire, cut: []const u8, complete: []const u8 }{
        .{ .wire = .anthropic, .cut = TOOL_ARGS_THEN_EOF, .complete = COMPLETE },
        .{ .wire = .openai_chat, .cut = CHAT_TOOL_ARGS_THEN_EOF, .complete = CHAT_COMPLETE },
        .{ .wire = .openai_responses, .cut = RESPONSES_TOOL_ARGS_THEN_EOF, .complete = RESPONSES_COMPLETE },
    };
    for (cases) |case| {
        errdefer std.debug.print("wire={s}\n", .{@tagName(case.wire)});
        var fx = try Fixture.init(a, &.{ case.cut, case.complete });
        defer fx.deinit();
        try fx.run(.{ .wire = case.wire, .root = root });
        try std.testing.expectEqual(agent_loop.StopReason.api_error, fx.result.stop_reason);
        try std.testing.expectEqual(@as(usize, 1), fx.requests());
        try std.testing.expectEqual(@as(usize, 0), fx.events.count("retry "));
        try std.testing.expectEqual(@as(u32, 0), fx.result.tool_calls);
    }
}

test "issue #461: an attempt that showed nothing is re-issued at once and without a notice" {
    const a = std.testing.allocator;
    var fx = try Fixture.init(a, &.{ START, COMPLETE });
    defer fx.deinit();
    // A backoff the test would notice: a silent re-issue does not wait.
    const started = cc.util_time.nowNs();
    try fx.run(.{ .backoff_ms = 60_000 });
    const elapsed_ms = @divTrunc(cc.util_time.nowNs() - started, std.time.ns_per_ms);
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, fx.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), fx.requests());
    try std.testing.expectEqual(@as(usize, 0), fx.events.count("retry "));
    try std.testing.expect(elapsed_ms < 30_000);
}
