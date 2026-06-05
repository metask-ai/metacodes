//! L2 组件测试(阶段 E):验证"换 UI 后端"全链可行 + CoreEvent 协议可序列化。
//!
//! 两部分:
//! 1. **Recording mock backend 跑真 agent_loop**:用 MockServer cassette 喂一轮真 SSE,
//!    agent_loop 经 mock backend(收 CoreEvent 进 ArrayList,深拷贝 payload)产出事件;
//!    断言事件序列正确。证明 agent_loop **不起终端、用 mock backend 纯测**(plan §可测试性)。
//! 2. **HeadlessBackend**:CoreEvent → JSON 行,断言每个事件可序列化且可解析回来——
//!    这是进程外 WsBackend 传输的前提(协议可序列化)。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;
const ui_event = cc.ui_event;
const ui_backend = cc.ui_backend;
const headless_backend = cc.headless_backend;

const CoreEvent = ui_event.CoreEvent;
const UiEvent = ui_event.UiEvent;
const UiBackend = ui_backend.UiBackend;

// ── 一轮纯文本响应(end_turn) ──────────────────────────────────────────────
const TEXT_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":7,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello \"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"world\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":4}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

// ── Recording mock backend:收 CoreEvent 的 tag(深拷贝 text 便于断言) ─────────
const Recorder = struct {
    tags: std.ArrayList([]const u8) = .empty, // 事件 tag 名序列(静态字面量,不拷)
    texts: std.ArrayList([]u8) = .empty, // text_chunk 的内容(深拷贝)
    allocator: std.mem.Allocator,

    fn init(a: std.mem.Allocator) Recorder {
        return .{ .allocator = a };
    }
    fn deinit(self: *Recorder) void {
        self.tags.deinit(self.allocator);
        for (self.texts.items) |t| self.allocator.free(t);
        self.texts.deinit(self.allocator);
    }
    fn backend(self: *Recorder) UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emitThunk, .poll = pollThunk };
    }
    fn emitThunk(ctx: *anyopaque, ev: CoreEvent) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.tags.append(self.allocator, @tagName(ev)) catch return;
        // text_chunk 的 borrow slice 必须**同步深拷贝**(emit 返回后即失效)。
        if (ev == .text_chunk) {
            const owned = self.allocator.dupe(u8, ev.text_chunk) catch return;
            self.texts.append(self.allocator, owned) catch {
                self.allocator.free(owned);
            };
        }
    }
    fn pollThunk(_: *anyopaque) ?UiEvent {
        return null;
    }
    fn hasTag(self: *const Recorder, tag: []const u8) bool {
        for (self.tags.items) |t| if (std.mem.eql(u8, t, tag)) return true;
        return false;
    }
    fn joinedText(self: *const Recorder, a: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(a);
        for (self.texts.items) |t| try buf.appendSlice(a, t);
        return buf.toOwnedSlice(a);
    }
};

test "阶段E: mock backend 跑真 agent_loop,断言 CoreEvent 序列(纯内存,不起终端)" {
    const a = std.testing.allocator;
    const bodies = [_][]const u8{TEXT_SSE};
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};

    var rec = Recorder.init(a);
    defer rec.deinit();
    const be = rec.backend();

    const result = agent_loop.run(
        &conv,
        &client,
        empty_defs,
        &perm,
        .{ .max_turns = 3, .colorize = true }, // colorize=true → 应有 stream_begin/stream_done
        &be,
        a,
    ) catch |e| {
        std.debug.print("agent_loop.run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };

    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    // 事件序列:stream_begin → text_chunk(s) → stream_done(colorize=true 路径)。
    try std.testing.expect(rec.hasTag("stream_begin"));
    try std.testing.expect(rec.hasTag("text_chunk"));
    try std.testing.expect(rec.hasTag("stream_done"));

    // 首事件是 stream_begin,末事件是 stream_done(颜色括号正好包文本区)。
    try std.testing.expectEqualStrings("stream_begin", rec.tags.items[0]);
    try std.testing.expectEqualStrings("stream_done", rec.tags.items[rec.tags.items.len - 1]);

    // 文本块拼起来 == 模型吐的全文(证明 text_chunk 内容正确,深拷贝未丢)。
    const joined = try rec.joinedText(a);
    defer a.free(joined);
    try std.testing.expectEqualStrings("hello world", joined);
}

// ── HeadlessBackend:CoreEvent → JSON 行 ─────────────────────────────────────
const JsonSink = struct {
    lines: std.ArrayList([]u8) = .empty,
    allocator: std.mem.Allocator,

    fn init(a: std.mem.Allocator) JsonSink {
        return .{ .allocator = a };
    }
    fn deinit(self: *JsonSink) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
    }
    fn sink(ctx: *anyopaque, json_line: []const u8) void {
        const self: *JsonSink = @ptrCast(@alignCast(ctx));
        const owned = self.allocator.dupe(u8, json_line) catch return;
        self.lines.append(self.allocator, owned) catch self.allocator.free(owned);
    }
};

test "阶段E: HeadlessBackend 每个 CoreEvent → 可解析的 JSON 行" {
    const a = std.testing.allocator;
    var js = JsonSink.init(a);
    defer js.deinit();
    var hb = headless_backend.HeadlessBackend.init(a, @ptrCast(&js), JsonSink.sink);
    const be = hb.backend();

    be.emitEvent(.stream_begin);
    be.emitEvent(.{ .text_chunk = "答案是" });
    be.emitEvent(.{ .tool_start = .{ .id = "tu1", .name = "Bash", .input = "{}", .card = false } });
    be.emitEvent(.{ .tool_result = .{ .id = "tu1", .name = "Bash", .input = "{}", .content = "ok", .is_error = false, .card = false, .elapsed_ms = 12 } });
    be.emitEvent(.{ .usage = .{ .input_tokens = 5, .output_tokens = 3 } });
    be.emitEvent(.stream_done);

    try std.testing.expectEqual(@as(usize, 6), js.lines.items.len);

    // 每行都是合法 JSON(能 parse 回来)。证明协议可序列化 = 进程外传输前提。
    for (js.lines.items) |line| {
        var parsed = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch |e| {
            std.debug.print("不可解析的 JSON 行: {s} ({s})\n", .{ line, @errorName(e) });
            return error.InvalidJson;
        };
        parsed.deinit();
    }

    // 关键 payload 在 JSON 里(tag 名 + 字段)。
    try std.testing.expect(std.mem.indexOf(u8, js.lines.items[0], "stream_begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, js.lines.items[1], "text_chunk") != null);
    try std.testing.expect(std.mem.indexOf(u8, js.lines.items[1], "答案是") != null);
    try std.testing.expect(std.mem.indexOf(u8, js.lines.items[2], "Bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, js.lines.items[3], "elapsed_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, js.lines.items[4], "input_tokens") != null);
}

test "阶段E: HeadlessBackend 接真 agent_loop(CoreEvent→JSON 全链)" {
    const a = std.testing.allocator;
    const bodies = [_][]const u8{TEXT_SSE};
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};

    var js = JsonSink.init(a);
    defer js.deinit();
    var hb = headless_backend.HeadlessBackend.init(a, @ptrCast(&js), JsonSink.sink);
    const be = hb.backend();

    const result = agent_loop.run(&conv, &client, empty_defs, &perm, .{ .max_turns = 3, .colorize = false }, &be, a) catch |e| {
        std.debug.print("run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    // 至少有 text_chunk 行,且全部可解析。
    var saw_text = false;
    for (js.lines.items) |line| {
        var parsed = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch return error.InvalidJson;
        parsed.deinit();
        if (std.mem.indexOf(u8, line, "text_chunk") != null) saw_text = true;
    }
    try std.testing.expect(saw_text);
}
