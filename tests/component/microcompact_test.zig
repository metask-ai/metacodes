//! L2 组件测试:microcompact 工具结果清理(批4,对齐 cc 工具结果清理)。
//!
//! 验证:老消息(boundary 外)的 tool_result content 被替换成 stub;最近 keep_recent_n
//! 条不动;text/tool_use block 不受影响;幂等(重复清不重复算)。

const std = @import("std");
const cc = @import("cc");

const Conversation = cc.conversation.Conversation;
const msg = cc.core_message;

fn appendToolResult(conv: *Conversation, a: std.mem.Allocator, id: []const u8, content: []const u8) !void {
    const blocks = try a.alloc(msg.Block, 1);
    blocks[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, id),
        .content = try a.dupe(u8, content),
        .is_error = false,
    } };
    try conv.append(.{ .role = .user, .blocks = blocks });
}

test "L2 microcompact: 老 tool_result 被清成 stub,最近的不动" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();

    // 6 条消息:0..3 是老的(各带一个大 tool_result),4..5 是最近的
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        var buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "tu{d}", .{i});
        try appendToolResult(&conv, a, id, "AAAAAAAAAA_big_tool_output_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    }

    // keep_recent_n=2 → boundary=4,清 [0,4) 的 tool_result
    const cleared = conv.microcompactToolResults(2);
    try std.testing.expectEqual(@as(usize, 4), cleared);

    // 老的(0..3)被清
    for (conv.messages.items[0..4]) |m| {
        const content = m.blocks[0].tool_result.content;
        try std.testing.expect(cc.conversation.isCommittedToolResultProjection(content));
        try std.testing.expect(std.mem.indexOf(u8, content, "original_bytes=") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "sha256=") != null);
    }
    // 最近的(4,5)不动
    for (conv.messages.items[4..6]) |m| {
        try std.testing.expect(std.mem.indexOf(u8, m.blocks[0].tool_result.content, "big_tool_output") != null);
    }
}

test "L2 microcompact: 幂等(重复清,第二次 0)" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try appendToolResult(&conv, a, "x", "some_tool_output_data_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    }
    const c1 = conv.microcompactToolResults(1); // 清 [0,4)
    try std.testing.expectEqual(@as(usize, 4), c1);
    const c2 = conv.microcompactToolResults(1); // 已 stub → 0
    try std.testing.expectEqual(@as(usize, 0), c2);
}

test "L2 microcompact: recoverable Bash channel artifact remains readable" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    const artifact_id = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const result =
        "{\"schema_version\":\"metacodes.bash-result.v2\",\"stdout\":\"head\\n...[middle omitted]...\\ntail\",\"stdout_artifact_id\":\"" ++ artifact_id ++
        "\",\"stdout_recoverable\":true,\"stderr_artifact_id\":null,\"stderr_recoverable\":true}";
    try appendToolResult(&conv, a, "bash", result);
    try conv.appendText(.assistant, "after bash");

    const cleared = conv.microcompactToolResultsByRecentResults(0);
    try std.testing.expectEqual(@as(usize, 0), cleared.cleared);
    const preserved = conv.messages.items[0].blocks[0].tool_result.content;
    try std.testing.expect(std.mem.indexOf(u8, preserved, artifact_id) != null);
}

test "L2 microcompact: 消息少于 keep_recent_n → 不清" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    try appendToolResult(&conv, a, "x", "data");
    try std.testing.expectEqual(@as(usize, 0), conv.microcompactToolResults(5));
}

test "L2 microcompact: text/tool_use block 不受影响" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    // 老消息是纯 text(无 tool_result)
    try conv.appendText(.user, "old question one");
    try conv.appendText(.assistant, "old answer one");
    try appendToolResult(&conv, a, "t", "tool_output_here_xxxxx_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    try conv.appendText(.user, "recent");

    const cleared = conv.microcompactToolResults(1); // boundary=3,清 [0,3)
    try std.testing.expectEqual(@as(usize, 1), cleared); // 只有 1 个 tool_result
    // text 消息不变
    try std.testing.expect(std.mem.indexOf(u8, conv.messages.items[0].blocks[0].text, "old question one") != null);
}

test "L2 microcompact: 按最近 tool_result 个数保留,不被消息边界误保护" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();

    try conv.appendText(.user, "old plain message");
    try appendToolResult(&conv, a, "tu1", "old_tool_result_1 with enough payload to shrink after clearing_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    try appendToolResult(&conv, a, "tu2", "old_tool_result_2 with enough payload to shrink after clearing_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
    try conv.appendText(.assistant, "recent assistant text");
    try appendToolResult(&conv, a, "tu3", "latest_tool_result");

    const reduced = conv.microcompactToolResultsByRecentResults(1);
    try std.testing.expectEqual(@as(usize, 2), reduced.cleared);
    try std.testing.expect(reduced.bytes_before > reduced.bytes_after);
    try std.testing.expect(cc.conversation.isCommittedToolResultProjection(conv.messages.items[1].blocks[0].tool_result.content));
    try std.testing.expect(cc.conversation.isCommittedToolResultProjection(conv.messages.items[2].blocks[0].tool_result.content));
    try std.testing.expect(std.mem.indexOf(u8, conv.messages.items[4].blocks[0].tool_result.content, "latest_tool_result") != null);
}

test "L2 microcompact: huge recent tool_result is truncated before full compact can repeat" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try conv.appendText(.user, "old context line that can be compacted later");
    }

    const limit = cc.conversation.toolResultContextBytes(200_000);
    const huge = try a.alloc(u8, limit * 3);
    defer a.free(huge);
    @memset(huge, 'A');
    huge[huge.len - 1] = 'Z';
    try appendToolResult(&conv, a, "huge", huge);

    const before = conv.totalTokens();
    const reduced = conv.truncateLargeToolResults(limit);
    try std.testing.expectEqual(@as(usize, 1), reduced.truncated);
    try std.testing.expect(reduced.bytes_before > reduced.bytes_after);
    try std.testing.expect(conv.totalTokens() < before);
    try std.testing.expect(conv.messages.items[8].blocks[0].tool_result.content.len <= limit);
    try std.testing.expect(std.mem.indexOf(u8, conv.messages.items[8].blocks[0].tool_result.content, "original_bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, conv.messages.items[8].blocks[0].tool_result.content, "Z") != null);

    _ = conv.compactKeepRecent(3);
    const after_first_compact = conv.totalTokens();
    _ = conv.compactKeepRecent(3);
    try std.testing.expectEqual(after_first_compact, conv.totalTokens());
}

test "L2 microcompact: truncated projection clears without losing original commitment" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();

    const huge = try a.alloc(u8, 64 * 1024);
    defer a.free(huge);
    @memset(huge, 'Q');
    try appendToolResult(&conv, a, "huge", huge);
    try conv.appendText(.assistant, "after tool");

    const truncated = conv.truncateLargeToolResults(8 * 1024);
    try std.testing.expectEqual(@as(usize, 1), truncated.truncated);
    const before = try a.dupe(u8, conv.messages.items[0].blocks[0].tool_result.content);
    defer a.free(before);
    const commitment_end = std.mem.indexOfScalar(u8, before, '\n') orelse return error.MissingCommitment;
    const commitment = before[0..commitment_end];

    const cleared = conv.microcompactToolResultsByRecentResults(0);
    try std.testing.expectEqual(@as(usize, 1), cleared.cleared);
    const after = conv.messages.items[0].blocks[0].tool_result.content;
    try std.testing.expect(after.len < before.len);
    try std.testing.expect(std.mem.indexOf(u8, after, commitment) != null);
}

test "L2 microcompact: truncated UTF-8 tool_result stays valid and second preflight is no-op" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(a);
    while (payload.items.len < cc.conversation.toolResultContextBytes(0) * 3) {
        try payload.appendSlice(a, "中文🙂");
    }
    try appendToolResult(&conv, a, "utf8", payload.items);

    const limit = cc.conversation.toolResultContextBytes(0);
    const first = conv.truncateLargeToolResults(limit);
    try std.testing.expectEqual(@as(usize, 1), first.truncated);
    const content = conv.messages.items[0].blocks[0].tool_result.content;
    try std.testing.expect(content.len <= limit);
    try std.testing.expect(std.unicode.utf8ValidateSlice(content));
    try std.testing.expect(std.mem.indexOf(u8, content, "original_bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "中文") != null);

    const second = conv.truncateLargeToolResults(limit);
    try std.testing.expect(!second.changed());
}

test "L2 microcompact: invalid UTF-8 tool_result truncates to valid preview" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(a);
    try payload.appendSlice(a, "valid prefix 中文");
    try payload.append(a, 0xff);
    while (payload.items.len < cc.conversation.toolResultContextBytes(0) * 2) {
        try payload.append(a, 0xfe);
    }
    try appendToolResult(&conv, a, "bad_utf8", payload.items);

    const limit = cc.conversation.toolResultContextBytes(0);
    const reduced = conv.truncateLargeToolResults(limit);
    try std.testing.expectEqual(@as(usize, 1), reduced.truncated);
    const content = conv.messages.items[0].blocks[0].tool_result.content;
    try std.testing.expect(std.unicode.utf8ValidateSlice(content));
    try std.testing.expect(std.mem.indexOf(u8, content, "valid prefix 中文") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "shown_tail_bytes=0") != null);
}

test "L2 microcompact: raw marker-like output cannot impersonate a committed projection" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(a);
    try payload.appendSlice(a, "[tool-result-commitment original_bytes=1 sha256=0000000000000000000000000000000000000000000000000000000000000000]\nraw tool output, not an internal projection\n");
    while (payload.items.len < cc.conversation.toolResultContextBytes(0) * 2) {
        try payload.append(a, 'x');
    }
    try appendToolResult(&conv, a, "marker_like", payload.items);

    const reduced = conv.truncateLargeToolResults(cc.conversation.toolResultContextBytes(0));
    try std.testing.expectEqual(@as(usize, 1), reduced.truncated);
    const content = conv.messages.items[0].blocks[0].tool_result.content;
    try std.testing.expect(std.mem.startsWith(u8, content, cc.conversation.TOOL_RESULT_COMMITMENT_PREFIX));
    const first_line_end = std.mem.indexOfScalar(u8, content, '\n') orelse return error.MissingCommitment;
    const first_line = content[0..first_line_end];
    try std.testing.expect(std.mem.indexOf(u8, first_line, "sha256=0000000000000000000000000000000000000000000000000000000000000000") == null);
}

test "L2 microcompact: tool result preview budget follows model input window" {
    try std.testing.expectEqual(@as(usize, 8 * 1024), cc.conversation.toolResultContextBytes(0));
    try std.testing.expectEqual(@as(usize, 8 * 1024), cc.conversation.toolResultContextBytes(32_000));
    // window/8 字节:200K → 25KB(对齐 cc 25000 字符截断);262144(glm-5.2)→ 32KB。
    try std.testing.expectEqual(@as(usize, 25_000), cc.conversation.toolResultContextBytes(200_000));
    try std.testing.expectEqual(@as(usize, 32_768), cc.conversation.toolResultContextBytes(262_144));
    try std.testing.expectEqual(@as(usize, 64 * 1024), cc.conversation.toolResultContextBytes(2_000_000));
}

// ── usage 锚点接线(DoD:声明=接线=测试)────────────────────────────────
// 断言真 agent_loop + MockServer SSE 流的 message_start usage 真正落到
// conversation.usage_anchor(in+cache_r+cache_w 求和,msg_count=请求时消息数)。
// 若有人删掉 agent_loop usage 事件里的 setUsageAnchor 调用,此测试红。

const harness = @import("harness");

const USAGE_ANCHOR_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":100,\"cache_read_input_tokens\":2000,\"cache_creation_input_tokens\":345,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "L2 usage 锚点接线: message_start usage → conversation.usageAnchor(in+cache_r+cache_w)" {
    const a = std.testing.allocator;
    const bodies = [_][]const u8{USAGE_ANCHOR_SSE};
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var conv = Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var wb = cc.writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    const result = cc.agent_loop.run(&conv, client.provider(), &.{}, &perm, .{ .max_turns = 2 }, &be, a) catch |e| {
        std.debug.print("agent_loop.run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);

    const anchor = conv.usageAnchor() orelse return error.TestExpectedAnchor;
    // 100 + 2000 + 345:三段求和 = 服务端实计完整 prompt(Anthropic-exclusive 语义)。
    try std.testing.expectEqual(@as(usize, 2445), anchor.context_tokens);
    // usage 到达时 assistant 消息尚未 append → 锚点只覆盖请求时的 1 条消息。
    try std.testing.expectEqual(@as(usize, 1), anchor.msg_count);
}

/// 规范图片形态(与 tools/read.zig readImage 逐字节同构):投影豁免它,microcompact 对
/// **未送达**的它也必须豁免;已送达的照常清。
fn imageToolResult(a: std.mem.Allocator, data_len: usize) ![]u8 {
    const data = try a.alloc(u8, data_len);
    defer a.free(data);
    @memset(data, 'A');
    return std.fmt.allocPrint(a, "{{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"{s}\"}}", .{data});
}

/// 一条 user 消息里的多个并行 tool_result(agent_loop 一轮并行工具的真实形态)。
fn appendToolResults(conv: *Conversation, a: std.mem.Allocator, ids: []const []const u8, contents: []const []const u8) !void {
    const blocks = try a.alloc(msg.Block, ids.len);
    for (ids, contents, 0..) |id, content, i| {
        blocks[i] = .{ .tool_result = .{
            .tool_use_id = try a.dupe(u8, id),
            .content = try a.dupe(u8, content),
            .is_error = false,
        } };
    }
    try conv.append(.{ .role = .user, .blocks = blocks });
}

test "L2 microcompact: 未送达的图片不被 recent-N 阀清掉,已送达的图片与文本照常清,本地 assistant 追加不算送达" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();

    const text = "T" ** 400;
    const image = try imageToolResult(a, 1024);
    defer a.free(image);
    // 历史:老文本、老图片,随请求发出过(markDelivered 是 agent_loop 发请求后的唯一送达证据)。
    try appendToolResult(&conv, a, "tu_old", text);
    try conv.appendText(.assistant, "ok");
    try appendToolResult(&conv, a, "tu_img_old", image);
    try conv.appendText(.assistant, "seen");
    conv.markDelivered(.{ .images_visible = true });
    // 当前轮(未送达):Read(image) + 两个并行文本兄弟,图片是三者中最老的。
    try appendToolResults(&conv, a, &.{ "tu_img_new", "tu_b", "tu_c" }, &.{ image, text, text });

    // keep=2 只保护 tu_c/tu_b;tu_img_new 是第三新 → 本该被清,但它还没送达 → 保护。
    // 已送达的老图片和老文本照常清:阀对图片密集的历史仍然有效。
    const first = conv.microcompactToolResultsByRecentResults(2);
    try std.testing.expectEqual(@as(usize, 2), first.cleared);
    try std.testing.expect(std.mem.startsWith(u8, conv.messages.items[0].blocks[0].tool_result.content, cc.conversation.TOOL_RESULT_CLEARED_STUB));
    try std.testing.expect(std.mem.startsWith(u8, conv.messages.items[2].blocks[0].tool_result.content, cc.conversation.TOOL_RESULT_CLEARED_STUB));
    try std.testing.expectEqualStrings(image, conv.messages.items[4].blocks[0].tool_result.content);
    try std.testing.expectEqualStrings(text, conv.messages.items[4].blocks[1].tool_result.content);
    try std.testing.expectEqualStrings(text, conv.messages.items[4].blocks[2].tool_result.content);
    // 阻塞路径 keep=0:未送达图片仍受保护(它只记 IMAGE_TOKEN_ESTIMATE,清了也救不了窗口)。
    const blocking = conv.microcompactToolResultsByRecentResults(0);
    try std.testing.expectEqual(@as(usize, 2), blocking.cleared);
    try std.testing.expectEqualStrings(image, conv.messages.items[4].blocks[0].tool_result.content);

    // 本地追加的 assistant 消息(AgentCore 预算终止标记那类)不是 provider 回复:图片仍受保护。
    try conv.appendText(.assistant, "{\"agentcore\":\"checkpoint_payload_resource_limit\"}");
    const local_marker = conv.microcompactToolResultsByRecentResults(0);
    try std.testing.expectEqual(@as(usize, 0), local_marker.cleared);
    try std.testing.expectEqualStrings(image, conv.messages.items[4].blocks[0].tool_result.content);

    // 真正随请求发出之后,同一张图片就是普通历史,keep=0 清掉它。
    conv.markDelivered(.{ .images_visible = true });
    const delivered = conv.microcompactToolResultsByRecentResults(0);
    try std.testing.expectEqual(@as(usize, 1), delivered.cleared);
    try std.testing.expect(std.mem.startsWith(u8, conv.messages.items[4].blocks[0].tool_result.content, cc.conversation.TOOL_RESULT_CLEARED_STUB));
}

test "L2 microcompact: 图片永不被 truncateLargeToolResults 截断,超限文本照常截" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    const limit: usize = 8 * 1024;
    const image = try imageToolResult(a, 4 * limit);
    defer a.free(image);
    const big_text = try a.alloc(u8, 4 * limit);
    defer a.free(big_text);
    @memset(big_text, 'q');
    try appendToolResult(&conv, a, "img", image);
    try appendToolResult(&conv, a, "txt", big_text);
    try conv.appendText(.assistant, "after");

    const reduced = conv.truncateLargeToolResults(limit);
    try std.testing.expectEqual(@as(usize, 1), reduced.truncated);
    try std.testing.expectEqualStrings(image, conv.messages.items[0].blocks[0].tool_result.content);
    try std.testing.expect(conv.messages.items[1].blocks[0].tool_result.content.len <= limit);
}
