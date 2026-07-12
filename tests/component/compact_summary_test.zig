//! L2 组件测试:9 段结构化 compact 摘要(补真缺口,对齐 cc compact)。
//!
//! 用 stub summarizer(不调真 API,确定性)验证 compactWithSummary 的编排:
//! 丢老消息 + summary prepend 到队首 + 保留最近 N;summarizer 返 null → 降级纯丢。

const std = @import("std");
const cc = @import("cc");

const Conversation = cc.conversation.Conversation;
const msg = cc.core_message;

// stub:把要丢的消息数编进 summary(确定性,验 prepend 内容)。
fn stubSummarize(a: std.mem.Allocator, drop: []const msg.Message) ?[]u8 {
    return std.fmt.allocPrint(a, "SUMMARY of {d} dropped messages", .{drop.len}) catch null;
}
fn nullSummarize(_: std.mem.Allocator, _: []const msg.Message) ?[]u8 {
    return null;
}

const Ctx = struct { a: std.mem.Allocator };

test "L2 compact摘要: 丢老消息 + summary prepend 队首 + 保留最近 N" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var buf: [32]u8 = undefined;
        try conv.appendText(.user, try std.fmt.bufPrint(&buf, "message number {d}", .{i}));
    }

    const dropped = try conv.compactWithSummary(3, Ctx{ .a = a }, struct {
        fn f(c: Ctx, d: []const msg.Message) ?[]u8 {
            return stubSummarize(c.a, d);
        }
    }.f);

    // P1.5 投影语义:原始消息**不删**,压缩=推进 boundary + 存 summary。
    // 10 条留 3 → boundary=7(投影掉 7 条),dropped=7。
    try std.testing.expectEqual(@as(usize, 7), dropped);
    try std.testing.expectEqual(@as(usize, 7), conv.compact_boundary);
    // summary 在 compact_summary 字段(不再 insert 进 messages)。
    try std.testing.expect(conv.compact_summary != null);
    try std.testing.expect(std.mem.indexOf(u8, conv.compact_summary.?, "SUMMARY of 7 dropped") != null);
    // 原始 10 条全保留(供 transcript/resume/查看历史)。
    try std.testing.expectEqual(@as(usize, 10), conv.messages.items.len);
    // 活跃窗口(投影后发给模型的)= 最近 3 条:message 7,8,9。
    const active = conv.activeMessages();
    try std.testing.expectEqual(@as(usize, 3), active.len);
    try std.testing.expect(std.mem.indexOf(u8, active[0].blocks[0].text, "message number 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, active[active.len - 1].blocks[0].text, "message number 9") != null);
}

test "L2 compact摘要: summarizer 返 null → 降级纯丢(无 prepend)" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try conv.appendText(.user, "msg");
    }
    const dropped = try conv.compactWithSummary(2, Ctx{ .a = a }, struct {
        fn f(c: Ctx, d: []const msg.Message) ?[]u8 {
            _ = c;
            return nullSummarize(undefined, d);
        }
    }.f);
    try std.testing.expectEqual(@as(usize, 6), dropped);
    // P1.5 投影降级:boundary 前进但无 summary(summarizer 返 null);原始 8 条全保留,活跃剩 2。
    try std.testing.expectEqual(@as(usize, 6), conv.compact_boundary);
    try std.testing.expect(conv.compact_summary == null);
    try std.testing.expectEqual(@as(usize, 8), conv.messages.items.len);
    try std.testing.expectEqual(@as(usize, 2), conv.activeMessages().len);
}

test "L2 compact摘要: 消息少于 keep_n → 不丢不总结" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "only one");
    const dropped = try conv.compactWithSummary(5, Ctx{ .a = a }, struct {
        fn f(c: Ctx, d: []const msg.Message) ?[]u8 {
            return stubSummarize(c.a, d);
        }
    }.f);
    try std.testing.expectEqual(@as(usize, 0), dropped);
    try std.testing.expectEqual(@as(usize, 1), conv.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), conv.compact_boundary); // 未压缩
}
