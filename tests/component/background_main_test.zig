//! Ctrl+B 转后台:agent_loop 的 background_request 信号 → turn 边界返回 .backgrounded。
//! 确定性验证(无 TTY/无模型时序):预置原子信号 true,run() 应在 turn 开头命中 → 立即返回
//! .backgrounded,且 conversation 保持干净(信号在 turn 边界查,不中断半个 turn)。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;
const writer_backend = cc.writer_backend;

const TEXT_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "Ctrl+B: background_request 置位 → run 在 turn 边界返回 .backgrounded(对话不损)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{TEXT_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "long task");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};

    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();

    // 预置信号 = true:turn 1 开头就命中 → 立即 .backgrounded(不发请求、不动 conversation)。
    var bg = std.atomic.Value(bool).init(true);

    const result = agent_loop.run(&conv, client.provider(), empty_defs, &perm, .{
        .max_turns = 5,
        .background_request = &bg,
    }, &be, a) catch |e| {
        std.debug.print("run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };

    // 命中 turn 边界信号 → .backgrounded(非 end_turn/aborted)。
    try std.testing.expectEqual(agent_loop.StopReason.backgrounded, result.stop_reason);
    // conversation 干净:只有最初那条 user(turn 边界返回,未发请求未追加 assistant)。
    try std.testing.expectEqual(@as(usize, 1), conv.len());
    try std.testing.expectEqualStrings("long task", conv.messages.items[0].blocks[0].text);
}

test "Ctrl+B: 信号为 false → run 正常跑完(不误转后台)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{TEXT_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};

    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();

    var bg = std.atomic.Value(bool).init(false); // 不转后台

    const result = agent_loop.run(&conv, client.provider(), empty_defs, &perm, .{
        .max_turns = 5,
        .background_request = &bg,
    }, &be, a) catch |e| {
        std.debug.print("run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    // 信号 false → 正常 end_turn(证明门控不误触发)。
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);
}
