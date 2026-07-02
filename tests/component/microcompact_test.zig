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
        try appendToolResult(&conv, a, id, "AAAAAAAAAA_big_tool_output_AAAAAAAAAA");
    }

    // keep_recent_n=2 → boundary=4,清 [0,4) 的 tool_result
    const cleared = conv.microcompactToolResults(2);
    try std.testing.expectEqual(@as(usize, 4), cleared);

    const STUB = cc.conversation.TOOL_RESULT_CLEARED_STUB;
    // 老的(0..3)被清
    for (conv.messages.items[0..4]) |m| {
        try std.testing.expectEqualStrings(STUB, m.blocks[0].tool_result.content);
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
        try appendToolResult(&conv, a, "x", "some_tool_output_data");
    }
    const c1 = conv.microcompactToolResults(1); // 清 [0,4)
    try std.testing.expectEqual(@as(usize, 4), c1);
    const c2 = conv.microcompactToolResults(1); // 已 stub → 0
    try std.testing.expectEqual(@as(usize, 0), c2);
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
    try appendToolResult(&conv, a, "t", "tool_output_here_xxxxx");
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
    try appendToolResult(&conv, a, "tu1", "old_tool_result_1 with enough payload to shrink after clearing");
    try appendToolResult(&conv, a, "tu2", "old_tool_result_2 with enough payload to shrink after clearing");
    try conv.appendText(.assistant, "recent assistant text");
    try appendToolResult(&conv, a, "tu3", "latest_tool_result");

    const reduced = conv.microcompactToolResultsByRecentResults(1);
    try std.testing.expectEqual(@as(usize, 2), reduced.cleared);
    try std.testing.expect(reduced.bytes_before > reduced.bytes_after);
    try std.testing.expectEqualStrings(cc.conversation.TOOL_RESULT_CLEARED_STUB, conv.messages.items[1].blocks[0].tool_result.content);
    try std.testing.expectEqualStrings(cc.conversation.TOOL_RESULT_CLEARED_STUB, conv.messages.items[2].blocks[0].tool_result.content);
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

test "L2 microcompact: tool result preview budget follows model input window" {
    try std.testing.expectEqual(@as(usize, 8 * 1024), cc.conversation.toolResultContextBytes(0));
    try std.testing.expectEqual(@as(usize, 8 * 1024), cc.conversation.toolResultContextBytes(32_000));
    try std.testing.expectEqual(@as(usize, 12_500), cc.conversation.toolResultContextBytes(200_000));
    try std.testing.expectEqual(@as(usize, 64 * 1024), cc.conversation.toolResultContextBytes(2_000_000));
}
