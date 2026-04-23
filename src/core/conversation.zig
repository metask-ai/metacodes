//! 对话历史管理。
//!
//! 与旧的 `App.messages: std.ArrayList(Message(role, content: []const u8))` 不同，
//! 这里 Message 持结构化 blocks，能正确表达 `.tool_use` / `.tool_result` content blocks。
//!
//! 所有权：`append` 消费传入的 Message（Message.blocks 的字节必须是 allocator 拥有）。
//! `deinit` 释放所有 blocks。不做 compact 的实现（留给未来 M6）。

const std = @import("std");
const msg = @import("message.zig");

pub const Conversation = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(msg.Message),

    pub fn init(allocator: std.mem.Allocator) Conversation {
        return .{ .allocator = allocator, .messages = .empty };
    }

    pub fn deinit(self: *Conversation) void {
        for (self.messages.items) |m| m.deinit(self.allocator);
        self.messages.deinit(self.allocator);
    }

    /// 追加消息（转移所有权）。传入的 Message 不得再手动 deinit。
    pub fn append(self: *Conversation, m: msg.Message) !void {
        try self.messages.append(self.allocator, m);
    }

    /// 便利方法：追加仅 text 的消息。字节被复制。
    pub fn appendText(self: *Conversation, role: msg.Role, text: []const u8) !void {
        const m = try msg.textMessage(role, text, self.allocator);
        errdefer m.deinit(self.allocator);
        try self.append(m);
    }

    pub fn len(self: *const Conversation) usize {
        return self.messages.items.len;
    }

    /// UTF-8 感知的 token 估算。规则（与原 client.zig:estimateTokens 对齐）：
    /// - ASCII 字符 1 token
    /// - CJK 字符 (U+4E00..U+9FFF) 1 token
    /// - 其他 1 token
    /// - 空字符串 0
    /// - 无效 UTF-8 退化为 `len/4`
    pub fn estimateTokens(text: []const u8) usize {
        if (text.len == 0) return 0;
        var count: usize = 0;
        var view = std.unicode.Utf8View.init(text) catch return text.len / 4;
        var it = view.iterator();
        while (it.nextCodepoint()) |_| count += 1;
        return @max(count, text.len / 4);
    }

    /// 全部消息的 text block 字节数估算总和。tool_use/tool_result 的 JSON 也算入。
    pub fn totalTokens(self: *const Conversation) usize {
        var total: usize = 0;
        for (self.messages.items) |m| {
            for (m.blocks) |b| switch (b) {
                .text => |t| total += estimateTokens(t),
                .tool_use => |tu| total += estimateTokens(tu.input) + estimateTokens(tu.name),
                .tool_result => |tr| total += estimateTokens(tr.content),
            };
        }
        return total;
    }

    /// Token 估算是否已超过阈值。上层据此决定是否 compact。
    pub fn isOverThreshold(self: *const Conversation, threshold: usize) bool {
        return self.totalTokens() > threshold;
    }

    /// 压缩：丢弃最老的一半消息（保留最近 N/2）。
    /// 本期"诚实 MVP"——不调 API 生成摘要（那需要 API key）；
    /// 这个简单策略能在 token 压力下腾出空间而不撒谎。
    ///
    /// 注意：这种粗暴压缩可能破坏 tool_use / tool_result 的 pair——留给后续
    /// 完整版本（调 haiku 生成摘要并保持语义完整性）。
    pub fn compact(self: *Conversation, threshold: usize) !usize {
        if (!self.isOverThreshold(threshold)) return 0;

        const total = self.messages.items.len;
        if (total < 4) return 0;

        const drop_count = total / 2;
        var i: usize = 0;
        while (i < drop_count) : (i += 1) {
            const m = self.messages.orderedRemove(0);
            m.deinit(self.allocator);
        }
        return drop_count;
    }

    /// 保留最近 keep_n 条 message，丢前面的。对 tool_use/tool_result 配对友好：
    /// 若保留区的第一条是 tool_result（orphan——它指向已丢的 tool_use），则把
    /// 这条也往前扩展一条"再往前找"，直到保留区首条是 user 非 tool_result 或 assistant 非 tool_use。
    ///
    /// 注意：仍会丢老的 user 消息 + 它们对应的 assistant 回答；这是故意的（这是 compact 的本意）。
    /// 只保证 *边界处* 不留孤儿。
    pub fn compactKeepRecent(self: *Conversation, keep_n: usize) usize {
        const total = self.messages.items.len;
        if (total <= keep_n) return 0;

        var drop_count = total - keep_n;
        // 把边界左移：只要 messages[drop_count] 是 user 且开头是 tool_result，把它也丢掉
        // （它指向 messages[drop_count-1] 的 tool_use，两者都属于老上下文）
        while (drop_count < total) {
            const first_kept = self.messages.items[drop_count];
            if (first_kept.role != .user) break;
            if (first_kept.blocks.len == 0) break;
            const first_block = first_kept.blocks[0];
            const is_tool_result = @as(std.meta.Tag(msg.Block), first_block) == .tool_result;
            if (!is_tool_result) break;
            drop_count += 1;
        }

        if (drop_count == 0) return 0;
        if (drop_count >= total) {
            // 全丢了——至少保留最后一条（应该不会走到，但防御）
            drop_count = total - 1;
        }

        var i: usize = 0;
        while (i < drop_count) : (i += 1) {
            const m = self.messages.orderedRemove(0);
            m.deinit(self.allocator);
        }
        return drop_count;
    }
};

test "Conversation init / deinit empty" {
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    try std.testing.expect(c.len() == 0);
}

test "Conversation appendText roundtrip" {
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    try c.appendText(.user, "hello");
    try c.appendText(.assistant, "hi");
    try std.testing.expect(c.len() == 2);
    try std.testing.expect(c.messages.items[0].role == .user);
    try std.testing.expectEqualStrings("hello", c.messages.items[0].blocks[0].text);
}

test "Conversation append structured message" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    const blocks = try a.alloc(msg.Block, 1);
    blocks[0] = .{ .tool_use = .{
        .id = try a.dupe(u8, "t1"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{\"path\":\"/tmp/x\"}"),
    } };
    try c.append(.{ .role = .assistant, .blocks = blocks });
    try std.testing.expect(c.len() == 1);
}

test "estimateTokens ASCII" {
    try std.testing.expect(Conversation.estimateTokens("hello world") >= 2);
}

test "estimateTokens CJK" {
    try std.testing.expect(Conversation.estimateTokens("你好") == 2);
}

test "estimateTokens empty" {
    try std.testing.expect(Conversation.estimateTokens("") == 0);
}

test "estimateTokens invalid utf8 falls back to len/4" {
    try std.testing.expect(Conversation.estimateTokens("\xff\xff\xff\xff\xff\xff\xff\xff") == 2);
}

test "totalTokens across mixed blocks" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "hello");
    const blocks = try a.alloc(msg.Block, 1);
    blocks[0] = .{ .tool_use = .{
        .id = try a.dupe(u8, "t1"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{\"path\":\"/x\"}"),
    } };
    try c.append(.{ .role = .assistant, .blocks = blocks });
    try std.testing.expect(c.totalTokens() > 0);
}

test "compact returns NotImplemented" {
    // 本期改为：低于阈值 → 返回 0（不压缩）
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    try c.appendText(.user, "tiny");
    const dropped = try c.compact(10_000);
    try std.testing.expect(dropped == 0);
}

test "compact drops oldest half when over threshold" {
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    // 塞 10 条消息，每条含一个带汉字的 text 增加 token
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try c.appendText(.user, "这是一条很长的中文消息用来凑 token 数量");
    }
    const before = c.len();
    const dropped = try c.compact(1);
    try std.testing.expect(dropped == before / 2);
    try std.testing.expect(c.len() == before - dropped);
}

test "compact is no-op for short conversation even over threshold" {
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    try c.appendText(.user, "a");
    try c.appendText(.user, "b");
    const dropped = try c.compact(0);
    try std.testing.expect(dropped == 0);
}

test "isOverThreshold" {
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    try c.appendText(.user, "hello");
    try std.testing.expect(!c.isOverThreshold(10_000));
    try std.testing.expect(c.isOverThreshold(0));
}

test "Conversation append takes ownership (no double free)" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit(); // 应负责释放所有 append 过的 blocks
    const blks = try a.alloc(msg.Block, 1);
    blks[0] = .{ .text = try a.dupe(u8, "owned") };
    try c.append(.{ .role = .user, .blocks = blks });
    // 不要手动 deinit 传入的 Message——conversation 拥有所有权
}

test "appendText multiple messages order preserved" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "1");
    try c.appendText(.assistant, "2");
    try c.appendText(.user, "3");
    try std.testing.expect(c.len() == 3);
    try std.testing.expectEqualStrings("1", c.messages.items[0].blocks[0].text);
    try std.testing.expectEqualStrings("2", c.messages.items[1].blocks[0].text);
    try std.testing.expectEqualStrings("3", c.messages.items[2].blocks[0].text);
}

test "totalTokens zero on empty" {
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    try std.testing.expect(c.totalTokens() == 0);
}

test "compactKeepRecent keeps last N" {
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    try c.appendText(.user, "m1");
    try c.appendText(.assistant, "m2");
    try c.appendText(.user, "m3");
    try c.appendText(.assistant, "m4");
    try c.appendText(.user, "m5");

    const dropped = c.compactKeepRecent(2);
    try std.testing.expect(dropped == 3);
    try std.testing.expect(c.len() == 2);
    try std.testing.expectEqualStrings("m4", c.messages.items[0].blocks[0].text);
    try std.testing.expectEqualStrings("m5", c.messages.items[1].blocks[0].text);
}

test "compactKeepRecent no-op when under keep_n" {
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    try c.appendText(.user, "m1");
    const dropped = c.compactKeepRecent(5);
    try std.testing.expect(dropped == 0);
    try std.testing.expect(c.len() == 1);
}

test "compactKeepRecent avoids orphan tool_result at boundary" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    // user msg, assistant w/ tool_use, user w/ tool_result, assistant text, user text
    try c.appendText(.user, "initial user");

    const au_blks = try a.alloc(msg.Block, 1);
    au_blks[0] = .{ .tool_use = .{
        .id = try a.dupe(u8, "t1"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{}"),
    } };
    try c.append(.{ .role = .assistant, .blocks = au_blks });

    const ur_blks = try a.alloc(msg.Block, 1);
    ur_blks[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, "t1"),
        .content = try a.dupe(u8, "result"),
    } };
    try c.append(.{ .role = .user, .blocks = ur_blks });

    try c.appendText(.assistant, "answer");
    try c.appendText(.user, "follow up");

    // keep_n=3 → 理论上应丢前 2，留最后 3（tool_result + answer + follow-up）
    // 但 tool_result 是 orphan（其 tool_use 在 index=1 被丢）→ 应该往右挪一个
    const dropped = c.compactKeepRecent(3);
    try std.testing.expect(dropped == 3); // 多丢一个 tool_result
    try std.testing.expect(c.len() == 2);
    try std.testing.expectEqualStrings("answer", c.messages.items[0].blocks[0].text);
    try std.testing.expectEqualStrings("follow up", c.messages.items[1].blocks[0].text);
}
