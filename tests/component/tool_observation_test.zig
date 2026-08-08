//! L2: model tool_use -> real dispatcher -> typed observation, with the UI
//! projection deliberately disabled and a non-root agent depth.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const observation = cc.tools.tool_observation;

const Capture = struct {
    mutex: @import("platform").sync.Mutex = .{},
    starts: usize = 0,
    finishes: usize = 0,
    depth: u8 = 0,
    origin: observation.Origin = .speculative_prefetch,
    outcome: observation.Outcome = .tool_error,
    effect: ?observation.Effect = null,
    effect_valid: bool = false,
    input_bytes: usize = 0,
    input_sha256: [64]u8 = [_]u8{'0'} ** 64,
    result_present: bool = false,
    result_bytes: usize = 0,
    names_are_write: bool = false,
    schema_is_v1: bool = false,

    fn sink(self: *Capture) cc.tools.ToolObservationSink {
        return .{ .ctx = @ptrCast(self), .emitFn = emit };
    }

    fn emit(raw: *anyopaque, event: observation.Event) bool {
        const self: *Capture = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (event) {
            .dispatch_started => |started| {
                self.starts += 1;
                self.depth = started.agent_depth;
                self.origin = started.origin;
                self.input_bytes = started.input_bytes;
                self.input_sha256 = started.input_sha256;
                self.names_are_write = std.mem.eql(u8, started.requested_name, "Write") and
                    std.mem.eql(u8, started.dispatched_name, "Write");
                self.schema_is_v1 = std.mem.eql(u8, started.schema_version, observation.SCHEMA_VERSION);
            },
            .dispatch_finished => |finished| {
                self.finishes += 1;
                self.depth = finished.agent_depth;
                self.outcome = finished.outcome;
                self.effect = finished.effect;
                self.effect_valid = finished.effect_valid;
                self.result_present = finished.result_present;
                self.result_bytes = finished.result_bytes;
                self.names_are_write = self.names_are_write and
                    std.mem.eql(u8, finished.requested_name, "Write") and
                    std.mem.eql(u8, finished.dispatched_name, "Write");
                self.schema_is_v1 = self.schema_is_v1 and
                    std.mem.eql(u8, finished.schema_version, observation.SCHEMA_VERSION);
            },
        }
        return true;
    }
};

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"done\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "L2 actual tool observation is independent of UI projection and depth" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/l2-observed.txt",
        .{root_buffer[0..root_len]},
    );
    defer allocator.free(path);
    const arguments = try std.fmt.allocPrint(
        allocator,
        "{{\"file_path\":\"{s}\",\"content\":\"l2-grounded\"}}",
        .{path},
    );
    defer allocator.free(arguments);
    const encoded_arguments = try std.json.Stringify.valueAlloc(allocator, arguments, .{});
    defer allocator.free(encoded_arguments);
    const tool_sse = try std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"tool\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"write-l2\",\"name\":\"Write\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{encoded_arguments},
    );
    defer allocator.free(tool_sse);

    const responses = [_][]const u8{ tool_sse, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&responses, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(
        allocator,
        io_runtime.io(),
        "test-key",
        "claude-sonnet-4-20250514",
        url,
    );
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, "write the fixture");
    const permission = cc.permission.createContext(.bypass_permissions, allocator);
    const definitions = try cc.tools.toToolDefinitions(allocator);
    defer allocator.free(definitions);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    var capture = Capture{};

    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        definitions,
        &permission,
        .{
            .max_turns = 4,
            .agent_depth = 7,
            .emit_tool_cards = false,
            .event_projection = .legacy,
            .tool_observer = capture.sink(),
            .cwd_abs = root_buffer[0..root_len],
            .home_dir = root_buffer[0..root_len],
        },
        &backend,
        allocator,
    );

    try std.testing.expect(result.stop_reason == .end_turn);
    try std.testing.expectEqual(@as(usize, 1), capture.starts);
    try std.testing.expectEqual(@as(usize, 1), capture.finishes);
    try std.testing.expectEqual(@as(u8, 7), capture.depth);
    try std.testing.expect(capture.origin == .authoritative);
    try std.testing.expect(capture.outcome == .succeeded);
    try std.testing.expect(capture.effect_valid);
    try std.testing.expectEqual(arguments.len, capture.input_bytes);
    try std.testing.expectEqualSlices(u8, &observation.sha256Hex(arguments), &capture.input_sha256);
    try std.testing.expect(capture.result_present);
    try std.testing.expect(capture.result_bytes > 0);
    try std.testing.expect(capture.names_are_write);
    try std.testing.expect(capture.schema_is_v1);
    const effect = capture.effect orelse return error.MissingToolEffect;
    const mutation = switch (effect) {
        .file_mutation_v1 => |value| value,
    };
    try std.testing.expect(mutation.before_state == .missing);
    try std.testing.expect(mutation.change == .changed);
    try std.testing.expectEqual(@as(usize, "l2-grounded".len), mutation.after_bytes);
}
