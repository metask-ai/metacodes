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
    // 快照锁:保护 messages.items 的结构性改动(append → 可能 realloc)与 transcript 快照
    // 遍历的互斥。生成期 watcher 线程按 Ctrl+O 调 transcript_viewer 遍历 messages.items,
    // 与主线程 agent_loop 的 append 并发——append 触发 ArrayList realloc 会使遍历中的旧
    // items slice 失效(UAF)。append 与 lockSnapshot/unlockSnapshot 包裹的快照读持同一锁。
    // 竞争极低:append 一轮几次、快照仅 Ctrl+O 时,故用粗粒度锁无性能问题。
    snapshot_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn init(allocator: std.mem.Allocator) Conversation {
        return .{ .allocator = allocator, .messages = .empty };
    }

    pub fn deinit(self: *Conversation) void {
        for (self.messages.items) |m| m.deinit(self.allocator);
        self.messages.deinit(self.allocator);
    }

    /// transcript 快照读前后持锁——与 append 互斥,防遍历 messages.items 时被 realloc 抽走。
    pub fn lockSnapshot(self: *Conversation) void {
        _ = std.c.pthread_mutex_lock(&self.snapshot_mutex);
    }
    pub fn unlockSnapshot(self: *Conversation) void {
        _ = std.c.pthread_mutex_unlock(&self.snapshot_mutex);
    }

    /// 追加消息（转移所有权）。传入的 Message 不得再手动 deinit。
    pub fn append(self: *Conversation, m: msg.Message) !void {
        _ = std.c.pthread_mutex_lock(&self.snapshot_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.snapshot_mutex);
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

    /// 深拷贝整个对话到 dst allocator(转后台续跑用)。返回的 Conversation 与源 **0 共享指针**
    /// (每 message/block 的字节都 dupe 到 dst),可安全交给后台线程,源在前台被 reset 不影响它。
    /// 持快照锁:防拷贝遍历时被并发 append realloc 抽走 items(同 transcript 快照纪律)。
    /// 失败回收已拷部分,不泄漏。
    pub fn cloneInto(self: *Conversation, dst: std.mem.Allocator) !Conversation {
        _ = std.c.pthread_mutex_lock(&self.snapshot_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.snapshot_mutex);
        var out = Conversation.init(dst);
        errdefer out.deinit();
        try out.messages.ensureTotalCapacity(dst, self.messages.items.len);
        for (self.messages.items) |m| {
            const mc = try m.dupe(dst);
            errdefer mc.deinit(dst);
            try out.messages.append(dst, mc);
        }
        return out;
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
                .thinking => |t| total += estimateTokens(t),
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
        const drop_count = self.compactBoundary(keep_n);
        if (drop_count == 0) return 0;
        var i: usize = 0;
        while (i < drop_count) : (i += 1) {
            const m = self.messages.orderedRemove(0);
            m.deinit(self.allocator);
        }
        return drop_count;
    }

    /// 计算 compactKeepRecent 会丢的消息数(boundary):total-keep_n,但把边界左移以避免
    /// 保留区首条是孤儿 tool_result。供 compactWithSummary 先总结再丢用。
    pub fn compactBoundary(self: *const Conversation, keep_n: usize) usize {
        const total = self.messages.items.len;
        if (total <= keep_n) return 0;
        var drop_count = total - keep_n;
        while (drop_count < total) {
            const first_kept = self.messages.items[drop_count];
            if (first_kept.role != .user) break;
            if (first_kept.blocks.len == 0) break;
            if (@as(std.meta.Tag(msg.Block), first_kept.blocks[0]) != .tool_result) break;
            drop_count += 1;
        }
        if (drop_count >= total) drop_count = total - 1;
        return drop_count;
    }

    /// 9 段结构化 compact:先把要丢的消息交给 summarize_fn 生成 summary,再丢老消息,
    /// 把 summary 作为一条 assistant 消息 prepend 到队首(保住早期上下文,对齐 cc)。
    /// summarize_fn 返回 null(无 client/失败)→ 退回纯 compactKeepRecent(降级)。
    /// 返回丢弃的消息数。
    pub fn compactWithSummary(
        self: *Conversation,
        keep_n: usize,
        ctx: anytype,
        comptime summarize_fn: fn (@TypeOf(ctx), []const msg.Message) ?[]u8,
    ) !usize {
        const drop_count = self.compactBoundary(keep_n);
        if (drop_count == 0) return 0;

        // 先总结要丢的 [0, drop_count)(在丢之前,内容还在)。
        const summary = summarize_fn(ctx, self.messages.items[0..drop_count]);

        // 丢老消息。
        var i: usize = 0;
        while (i < drop_count) : (i += 1) {
            const m = self.messages.orderedRemove(0);
            m.deinit(self.allocator);
        }

        // 有 summary → prepend 一条 assistant 消息(text block)到队首。
        if (summary) |s| {
            const blocks = try self.allocator.alloc(msg.Block, 1);
            blocks[0] = .{ .text = s }; // s 已是 owned(summarize_fn dupe 的),转移给 block
            try self.messages.insert(self.allocator, 0, .{ .role = .assistant, .blocks = blocks });
        }
        return drop_count;
    }

    /// Microcompact(批4,对齐 cc 的工具结果清理):把"较老"消息里的 tool_result 内容
    /// 替换成短 stub(释放 token),但**保留消息结构**(对话流不断、不调 API)。
    /// 比 compactKeepRecent 温和:不丢消息,只清旧工具结果(最占 token 的部分)。
    /// keep_recent_n:最近 N 条消息的 tool_result 不动(可能还要引用)。
    /// 返回清理的 tool_result 个数。
    pub fn microcompactToolResults(self: *Conversation, keep_recent_n: usize) usize {
        const total = self.messages.items.len;
        if (total <= keep_recent_n) return 0;
        const boundary = total - keep_recent_n; // [0, boundary) 是"老"消息
        const STUB = "[tool result cleared to save context]";

        var cleared: usize = 0;
        var mi: usize = 0;
        while (mi < boundary) : (mi += 1) {
            const m = self.messages.items[mi];
            for (m.blocks, 0..) |b, bi| {
                switch (b) {
                    .tool_result => |tr| {
                        // 已是 stub 的不重复清(幂等)。
                        if (std.mem.eql(u8, tr.content, STUB)) continue;
                        const new_content = self.allocator.dupe(u8, STUB) catch continue;
                        self.allocator.free(@constCast(tr.content));
                        m.blocks[bi] = .{ .tool_result = .{
                            .tool_use_id = tr.tool_use_id,
                            .content = new_content,
                            .is_error = tr.is_error,
                        } };
                        cleared += 1;
                    },
                    else => {},
                }
            }
        }
        return cleared;
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

test "cloneInto 深拷贝独立 + 源 reset 不影响副本 + 无泄漏" {
    const a = std.testing.allocator;
    var src = Conversation.init(a);
    // 含 text + tool_use + tool_result 的多消息对话。
    try src.appendText(.user, "q1");
    const au = try a.alloc(msg.Block, 1);
    au[0] = .{ .tool_use = .{ .id = try a.dupe(u8, "t1"), .name = try a.dupe(u8, "Bash"), .input = try a.dupe(u8, "{}") } };
    try src.append(.{ .role = .assistant, .blocks = au });
    const ur = try a.alloc(msg.Block, 1);
    ur[0] = .{ .tool_result = .{ .tool_use_id = try a.dupe(u8, "t1"), .content = try a.dupe(u8, "out"), .is_error = false } };
    try src.append(.{ .role = .user, .blocks = ur });

    var copy = try src.cloneInto(a);
    defer copy.deinit();
    try std.testing.expectEqual(@as(usize, 3), copy.len());
    // 指针不共享:首消息 text 字节地址不同。
    try std.testing.expect(src.messages.items[0].blocks[0].text.ptr != copy.messages.items[0].blocks[0].text.ptr);

    // 源 reset(deinit + 重 init)→ 副本仍完整有效。
    src.deinit();
    src = Conversation.init(a);
    src.deinit();
    try std.testing.expectEqualStrings("q1", copy.messages.items[0].blocks[0].text);
    try std.testing.expectEqualStrings("Bash", copy.messages.items[1].blocks[0].tool_use.name);
    try std.testing.expectEqualStrings("out", copy.messages.items[2].blocks[0].tool_result.content);
}
