//! L2 component test: compacted history is serialized into the next request
//! without leaking the internal compact prompt/marker text.

const std = @import("std");
const cc = @import("cc");

const Conversation = cc.conversation.Conversation;
const msg = cc.core_message;

const Ctx = struct { a: std.mem.Allocator };

fn stubSummary(c: Ctx, dropped: []const msg.Message) ?[]u8 {
    return std.fmt.allocPrint(c.a, "SUMMARY_FROM_COMPACT_MODEL dropped={d}", .{dropped.len}) catch null;
}

test "L2 auto-compact request: summary enters next request without compact prompt leakage" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const text = try std.fmt.allocPrint(a, "old message {d} with enough content to cross compact threshold", .{i});
        defer a.free(text);
        try conv.appendText(.user, text);
    }

    const threshold: usize = 20;
    try std.testing.expect(conv.totalTokens() > threshold);
    const report = try conv.compactWithSummaryReport(2, Ctx{ .a = a }, struct {
        fn f(c: Ctx, dropped: []const msg.Message) ?[]u8 {
            return stubSummary(c, dropped);
        }
    }.f);
    try std.testing.expect(report.summary_used);
    try std.testing.expect(report.dropped > 0);

    var api_messages = std.ArrayList(cc.types_mod.ApiMessage).empty;
    defer {
        for (api_messages.items) |m| a.free(m.content);
        api_messages.deinit(a);
    }
    // P1.5 纯投影:发给模型 = [compact_summary(若有)] + activeMessages()(边界后)。原始全量仍在
    // conv.messages(供 transcript/resume),但**不发**。这里模拟 buildApiMessages 的投影构造。
    if (conv.compact_summary) |s| {
        const content = try a.alloc(cc.types_mod.ApiContent, 1);
        content[0] = .{ .text = s };
        try api_messages.append(a, .{ .role = .assistant, .content = content });
    }
    for (conv.activeMessages()) |m| {
        const content = try a.alloc(cc.types_mod.ApiContent, m.blocks.len);
        for (m.blocks, 0..) |b, bi| {
            content[bi] = switch (b) {
                .text => |t| .{ .text = t },
                else => .{ .text = "" },
            };
        }
        try api_messages.append(a, .{ .role = m.role, .content = content });
    }

    const body = try cc.json_mod.serializeMessagesRequest(.{
        .model = "claude-sonnet-4-20250514",
        .max_tokens = 1024,
        .messages = api_messages.items,
        .system = "normal system prompt",
        .stream = true,
        .tools = &.{},
    }, a);
    defer a.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "SUMMARY_FROM_COMPACT_MODEL") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "old message 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "old message 11") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Summarize this conversation") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "You are summarizing a software-engineering conversation") == null);
}
