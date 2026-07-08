//! scoped 自动召回(一等公民 P1):按用户末条消息自动 KgRecall top-3,格式化成尾部注入块,
//! 让相关记忆**自动出现在上下文**——recall 从"模型主动调"升级为"harness 按请求装配"。
//!
//! 设计针对旧 proactive 否决:
//! ① **cache-safe**——调用方走 agent_loop 的 synthetic_user_input(**首轮尾注入**,在 stable
//!    prefix(system + user_context)之后),不使缓存前缀失效。
//! ② **有命中才注入**(无命中 = 返 null = 零输出,不制造噪声)。
//! ③ 琐碎消息(<12B)跳过(成本 + 噪声门)。
//! ④ 标注"自动召回,可能不全",模型仍可 KgRecall 深挖(可加 type= 过滤)。
//!
//! 不依赖 App(取 conversation/kg/abort 三件套)→ 交互(loop.zig)与 headless(headless.zig)共用,无循环 import。

const std = @import("std");
const client_mod = @import("client.zig");
const conv_mod = @import("../core/conversation.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

const MIN_QUERY_LEN = 12; // 琐碎消息门
const TOP_K = 3;

/// best-effort:kg 未就绪 / 无末条 user 文本 / 消息琐碎 / 无命中 / 失败 → null(不注入,绝不阻塞 turn)。
/// owned 返回,调用方 free。
pub fn build(
    allocator: std.mem.Allocator,
    kg: *client_mod.KgClient,
    conversation: *const conv_mod.Conversation,
    abort: *const AbortSignal,
) ?[]u8 {
    if (!kg.ready) return null;
    const query = lastUserText(conversation) orelse return null;
    if (query.len < MIN_QUERY_LEN) return null;
    kg.setAbort(abort); // ESC 可中断
    const hits = kg.recall(query, TOP_K, false) catch return null;
    defer {
        for (hits) |*h| h.deinit(allocator);
        allocator.free(hits);
    }
    if (hits.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    out.appendSlice(allocator, "<system-reminder>\n# 相关持久记忆(按你的请求自动召回,可能不全)\n") catch return null;
    for (hits) |h| {
        const type_str = if (h.schema_type.len > 0) h.schema_type else h.kind;
        const line = std.fmt.allocPrint(allocator, "- [{s}] {s}\n", .{ type_str, firstLine(h.text) }) catch return null;
        defer allocator.free(line);
        out.appendSlice(allocator, line) catch return null;
    }
    out.appendSlice(allocator, "需要更多或更深的记忆,用 KgRecall(可加 type= 过滤)。\n</system-reminder>") catch return null;
    return out.toOwnedSlice(allocator) catch null;
}

/// 末条 user 消息的首个 text block。
fn lastUserText(conversation: *const conv_mod.Conversation) ?[]const u8 {
    const msgs = conversation.messages.items;
    var i = msgs.len;
    while (i > 0) {
        i -= 1;
        if (msgs[i].role != .user) continue;
        for (msgs[i].blocks) |b| {
            switch (b) {
                .text => |t| return t,
                else => {},
            }
        }
    }
    return null;
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    var n = @min(end, 100);
    while (n > 0 and (text[n - 1] & 0xC0) == 0x80) n -= 1; // 不切半个 CJK 字
    return text[0..n];
}

test "build:kg 未就绪 → null(不阻塞)" {
    const a = std.testing.allocator;
    var conv = conv_mod.Conversation.init(a);
    defer conv.deinit();
    var kg = try client_mod.KgClient.init(a, .{ .home = "/tmp", .domain = "d", .env_bin = "", .env_store = "" });
    defer kg.deinit();
    // 未 ensureReady → not ready → null。
    var ab = AbortSignal{};
    try std.testing.expect(build(a, &kg, &conv, &ab) == null);
}
