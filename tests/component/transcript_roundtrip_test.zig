//! L2 组件测试:transcript 持久化 → 加载/resume 往返(原零覆盖盲区)。
//!
//! 验证:Conversation 写 JSONL(Writer.flush)→ loadTranscript 重建 Conversation,
//! 消息数/角色/text 内容一致。覆盖 transcript.zig 的 flush + loadTranscript +
//! parseMessageLine 全链路。纯文件 IO,无网络/模型。

const std = @import("std");
const cc = @import("cc");

const Conversation = cc.conversation.Conversation;
const transcript = cc.transcript;

fn firstText(m: anytype) []const u8 {
    for (m.blocks) |b| switch (b) {
        .text => |t| return t,
        else => {},
    };
    return "";
}

test "L2 transcript: 写 → loadTranscript 往返,消息数/角色/text 一致" {
    const a = std.testing.allocator;

    // 隔离 HOME(Writer.init 写 $HOME/.metacodes/projects/<hash>/<sid>/)
    const home = "/tmp/cc-transcript-l2";
    _ = std.c.mkdir(home, 0o755);

    // 1) 造一段对话
    var conv = Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "first user msg");
    try conv.appendText(.assistant, "first assistant reply");
    try conv.appendText(.user, "second user msg");

    // 2) 写盘
    var writer = try transcript.Writer.init(a, "/some/cwd", home, "claude-sonnet-4-20250514", transcript.genSessionId());
    const session_dir = try a.dupe(u8, writer.dir);
    defer a.free(session_dir);
    writer.flush(&conv);
    writer.deinit();

    // 3) loadTranscript 进全新 Conversation
    var loaded = Conversation.init(a);
    defer loaded.deinit();
    try transcript.loadTranscript(&loaded, session_dir, a);

    // 4) 断言往返一致
    try std.testing.expectEqual(@as(usize, 3), loaded.messages.items.len);
    try std.testing.expectEqual(cc.types_mod.MessageRole.user, loaded.messages.items[0].role);
    try std.testing.expectEqual(cc.types_mod.MessageRole.assistant, loaded.messages.items[1].role);
    try std.testing.expectEqual(cc.types_mod.MessageRole.user, loaded.messages.items[2].role);
    try std.testing.expectEqualStrings("first user msg", firstText(loaded.messages.items[0]));
    try std.testing.expectEqualStrings("first assistant reply", firstText(loaded.messages.items[1]));
    try std.testing.expectEqualStrings("second user msg", firstText(loaded.messages.items[2]));

    // 清理 session 目录
    var pbuf: [512]u8 = undefined;
    const tpath = std.fmt.bufPrintZ(&pbuf, "{s}/transcript.jsonl", .{session_dir}) catch return;
    _ = std.c.unlink(tpath.ptr);
    const mpath = std.fmt.bufPrintZ(&pbuf, "{s}/meta.json", .{session_dir}) catch return;
    _ = std.c.unlink(mpath.ptr);
}

test "L2 transcript: openExisting resume 续写不重复已刷盘消息" {
    const a = std.testing.allocator;
    const home = "/tmp/cc-transcript-l2b";
    _ = std.c.mkdir(home, 0o755);

    // 第一段:写 2 条
    var conv = Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "msg A");
    try conv.appendText(.assistant, "reply A");
    var w1 = try transcript.Writer.init(a, "/cwd", home, "m", transcript.genSessionId());
    const dir = try a.dupe(u8, w1.dir);
    defer a.free(dir);
    w1.flush(&conv);
    w1.deinit();

    // resume:openExisting(already_flushed=2),再追加 1 条,flush 只写新增
    try conv.appendText(.user, "msg B");
    var w2 = transcript.Writer.openExisting(a, try a.dupe(u8, dir), "m", 2);
    w2.flush(&conv);
    w2.deinit();

    // 加载应得 3 条(不重复)
    var loaded = Conversation.init(a);
    defer loaded.deinit();
    try transcript.loadTranscript(&loaded, dir, a);
    try std.testing.expectEqual(@as(usize, 3), loaded.messages.items.len);
    try std.testing.expectEqualStrings("msg B", firstText(loaded.messages.items[2]));

    var pbuf: [512]u8 = undefined;
    _ = std.c.unlink((std.fmt.bufPrintZ(&pbuf, "{s}/transcript.jsonl", .{dir}) catch return).ptr);
    _ = std.c.unlink((std.fmt.bufPrintZ(&pbuf, "{s}/meta.json", .{dir}) catch return).ptr);
}

test "L2 transcript R2/F1回归: /retry 回卷后 flush 全量重写,resume 不复活被丢弃回合" {
    // 缺陷形态:Writer.flushed_count 单调 + O_APPEND——回卷(4→3)再重生成(→4)后
    // flush 无事可写,盘上仍是回卷前的旧第 4 条;loadTranscript 复活被丢弃的回合、
    // 丢掉重生成的回合。修复:conversation.shrink_epoch 变更 → Writer 原子全量重写。
    const a = std.testing.allocator;
    const home = "/tmp/cc-transcript-l2";
    _ = std.c.mkdir(home, 0o755);

    var conv = Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "q1");
    try conv.appendText(.assistant, "a1");
    try conv.appendText(.user, "q2");
    try conv.appendText(.assistant, "a2-stale"); // 将被 /retry 丢弃的旧回合

    var writer = try transcript.Writer.init(a, "/some/cwd", home, "claude-sonnet-4-20250514", transcript.genSessionId());
    const dir = try a.dupe(u8, writer.dir);
    defer a.free(dir);
    writer.flush(&conv); // 盘上 4 条(含 a2-stale)

    // /retry 语义:回卷到最后一条 user(q2,idx=2),重生成新回合 → 长度又回到 4。
    conv.rollbackForRetry(2);
    try conv.appendText(.assistant, "a2-regenerated");
    writer.flush(&conv);
    writer.deinit();

    var loaded = Conversation.init(a);
    defer loaded.deinit();
    try transcript.loadTranscript(&loaded, dir, a);
    try std.testing.expectEqual(@as(usize, 4), loaded.messages.items.len);
    try std.testing.expectEqualStrings("a2-regenerated", firstText(loaded.messages.items[3]));
    // 旧回合绝不能复活。
    for (loaded.messages.items) |m| {
        try std.testing.expect(std.mem.indexOf(u8, firstText(m), "a2-stale") == null);
    }

    var pbuf: [512]u8 = undefined;
    _ = std.c.unlink((std.fmt.bufPrintZ(&pbuf, "{s}/transcript.jsonl", .{dir}) catch return).ptr);
    _ = std.c.unlink((std.fmt.bufPrintZ(&pbuf, "{s}/meta.json", .{dir}) catch return).ptr);
}
