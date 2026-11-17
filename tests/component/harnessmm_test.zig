//! L2: omitted callbacks still consume the ordinary AgentLoop turn budget.
const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const PLAN = cc.harnessmm.OPEN ++
    \\{"schema_version":1,"root":{"tool":"Bash","arguments":{"command":"printf root"}},"nodes":[{"id":"A","after":"root","tool":"Bash","arguments":{"command":"printf one"},"guard":{"kind":"exit_zero"}},{"id":"B","after":"A","tool":"Bash","arguments":{"command":"printf two"},"guard":{"kind":"exit_zero"}}]}
++ cc.harnessmm.CLOSE;

fn rootResponse(a: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n");
    try w.writeAll("data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n");
    try w.print("data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":{f}}}}}\n\n", .{std.json.fmt(PLAN, .{})});
    try w.writeAll("data: {\"type\":\"content_block_stop\",\"index\":0}\n\n");
    try w.writeAll("data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"root_call\",\"name\":\"Bash\",\"input\":{}}}\n\n");
    try w.print("data: {{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{f}}}}}\n\n", .{std.json.fmt("{\"command\":\"printf root\"}", .{})});
    try w.writeAll("data: {\"type\":\"content_block_stop\",\"index\":1}\n\n");
    try w.writeAll("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\ndata: {\"type\":\"message_stop\"}\n\n");
    return out.toOwnedSlice();
}

test "L2 HarnessMM: fast native calls consume turns and stop before the next EDG node" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX fixture commands
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);
    const response = try rootResponse(a);
    defer a.free(response);
    var server = try harness.MockServer.startCassette(&.{response}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(a);
    defer conversation.deinit();
    try conversation.appendText(.user, "run the bounded chain");
    var permission = cc.permission.createContext(.bypass_permissions, a);
    permission.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    var render = cc.writer_backend.WriterBackend.initNull();
    const backend = render.backend();
    const result = try cc.agent_loop.run(&conversation, client.provider(), defs, &permission, .{
        .harnessmm = true,
        .max_turns = 2,
        .cwd_abs = root,
        .home_dir = root,
        .artifact_root = root,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &backend, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.max_turns, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 2), result.turns);
    try std.testing.expectEqual(@as(u32, 2), result.tool_calls);
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
    var receipts: usize = 0;
    var host_calls: usize = 0;
    for (conversation.messages.items) |message| for (message.blocks) |block| {
        if (block == .tool_result) receipts += 1;
        if (block == .tool_use and message.origin == .host) {
            host_calls += 1;
            try std.testing.expectEqualStrings("{\"command\":\"printf one\"}", block.tool_use.input);
        }
    };
    try std.testing.expectEqual(@as(usize, 2), receipts);
    try std.testing.expectEqual(@as(usize, 1), host_calls);
    const journal = try tmp.dir.readFileAlloc(std.testing.io, cc.harnessmm.JOURNAL_NAME, a, .limited(65536));
    defer a.free(journal);
    var certificate = try std.json.parseFromSlice(std.json.Value, a, std.mem.trim(u8, journal, "\n"), .{});
    defer certificate.deinit();
    try std.testing.expectEqualStrings("A", certificate.value.object.get("decision_id").?.string);
    try std.testing.expectEqual(@as(i64, 2), certificate.value.object.get("omitted_callback_turn").?.integer);
}
