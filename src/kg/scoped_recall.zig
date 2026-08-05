//! scoped 自动召回(一等公民 P1):按用户末条消息自动 KgRecall,**相关性筛选**后把记忆装配进
//! 上下文尾部——recall 从"模型主动调"升级为"harness 按请求装配"。
//!
//! 设计针对旧 proactive 三大否决(Linus + PM 双 review 收口):
//! ① **cache-safe**——调用方走 agent_loop 的 synthetic_user_input(**首轮尾注入**,只在 turns==0
//!    请求期拼进 api_messages、**从不写回 conversation**),在 stable prefix 之后,不破缓存前缀(已核实)。
//! ② **相关性门(PM P0)**——读 BM25 score:绝对地板(top<floor→答案缺席→注入 0 条)+ 相对衰减
//!    (只留 ≥top×REL 的),**动态 0-3 条**。"有命中"≠"有相关",硬凑 top-3 是旧否决原话。
//! ③ **成本(Linus/PM P0)**——recall 走 search --include-text 一次 spawn 拿全,不再每 hit get;
//!    query 上界截断,避免粘贴长文变巨型 BM25 query。
//! ④ **可控 + 可观测**——METACODES_NO_AUTO_RECALL 开关(解耦 KG);每次注入打仪器(条数/top 分)。
//! ⑤ 标注"可能不全",模型仍可 KgRecall 深挖(不主动 nudge 重复召回)。
//!
//! 不依赖 App(取 conversation/kg/abort 三件套)→ 交互 + headless 两路共用,无循环 import。

const std = @import("std");
const client_mod = @import("client.zig");
const conv_mod = @import("../core/conversation.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const log = @import("../util/log.zig");
const retrieval_protocol = @import("retrieval_protocol.zig");

const MIN_QUERY_LEN = 16; // 琐碎接话轮门(下界)
const MAX_QUERY_LEN = 400; // BM25 query 上界(避免粘贴长文变噪声 query)
// 自动命中既是上下文，也是 lexical→semantic 的桥。100 bytes 会把中文记忆压到约 33 字，
// canonical alias/代码符号常在句尾被截掉，迫使模型重新宽搜。3 条×320B 仍是有界小预算。
const MAX_HIT_TEXT_BYTES = 320;
const TOP_K = 3;
const REL_RATIO: f64 = 0.5; // 相对门:只留 ≥ top×0.5 的命中
// 绝对地板(BM25;启发式,可 METACODES_RECALL_FLOOR 校准)。实测数据定初值:相关 query top≈7,
// 无关 query top≈2.7 → 3.0 分界(auto-inject 精度优先,宁漏勿噪——PM:注入无关记忆=负价值)。
// BM25 分跨 query 不可比,固定地板固有不精确;仪器日志(injected/top_score)供持续校准。
const DEFAULT_ABS_FLOOR: f64 = 3.0;

/// 相关性门 + 动态条数。best-effort:kg 未就绪 / 关闭 / 无末条 user 文本 / 消息琐碎 / 无相关命中
/// → null(不注入)。返回 error 仅内部分配失败(调用方 `catch null` 兜底,等价不注入)。owned。
pub fn build(
    allocator: std.mem.Allocator,
    kg: *client_mod.KgClient,
    conversation: *const conv_mod.Conversation,
    abort: *const AbortSignal,
) !?[]u8 {
    if (disabled()) return null; // escape hatch(解耦 KG)
    if (!kg.ready) return null;
    const raw = lastUserText(conversation) orelse return null;
    if (raw.len < MIN_QUERY_LEN) return null; // 琐碎轮不召回
    const query = raw[0..@min(raw.len, MAX_QUERY_LEN)]; // 上界截断

    kg.setAbort(abort); // ESC 可中断
    const hits = kg.recall(query, TOP_K, false) catch return null;
    defer {
        for (hits) |*h| h.deinit(allocator);
        allocator.free(hits);
    }
    if (hits.len == 0) return null;

    // 相关性门:top 分做绝对地板(答案缺席→0 条)+ 相对衰减(留 ≥top×REL)。
    var top: f64 = 0;
    for (hits) |h| {
        if (h.score > top) top = h.score;
    }
    const floor = absFloor();
    if (top < floor) {
        log.info("kg", "scoped_recall injected=0 top_score={d:.2} (below floor {d:.2})", .{ top, floor });
        return null; // 最相关的都弱 → 判为答案缺席,不注入噪声
    }
    const keep_min = top * REL_RATIO;

    var out: std.ArrayList(u8) = .empty;
    var injected: usize = 0;
    // 无 errdefer(本函数返回 !?[]u8;分配失败走 error 路径,显式 deinit 防泄漏——Linus 抓的死 errdefer)。
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "<system-reminder>\n# 相关持久记忆(按你的请求自动召回,可能不全)\n");
    try out.appendSlice(allocator, retrieval_protocol.AUTO_RECALL_NOTE);
    try out.appendSlice(allocator, "\n");
    for (hits) |h| {
        if (h.score < keep_min) continue; // 相对门:丢明显弱于最佳的
        const type_str = if (h.schema_type.len > 0) h.schema_type else h.kind;
        // 带来源的 hit(记忆 markdown)标注文件名:模型更新该文件而非另存(PM P0-2)。
        const line = if (h.source_label.len > 0)
            try std.fmt.allocPrint(allocator, "- [node_id={d} {s}:{s}] {s}\n", .{ h.node_id, type_str, h.source_label, firstLine(h.text) })
        else
            try std.fmt.allocPrint(allocator, "- [node_id={d} {s}] {s}\n", .{ h.node_id, type_str, firstLine(h.text) });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
        injected += 1;
    }
    try out.appendSlice(allocator, retrieval_protocol.AUTO_RECALL_NEXT_ACTION);
    try out.appendSlice(allocator, "\n");
    try out.appendSlice(allocator, "</system-reminder>");

    log.info("kg", "scoped_recall injected={d} top_score={d:.2} query_len={d}", .{ injected, top, query.len });
    return try out.toOwnedSlice(allocator);
}

fn disabled() bool {
    return std.c.getenv("METACODES_NO_AUTO_RECALL") != null;
}

fn absFloor() f64 {
    if (std.c.getenv("METACODES_RECALL_FLOOR")) |v| {
        const s = std.mem.span(v);
        return std.fmt.parseFloat(f64, s) catch DEFAULT_ABS_FLOOR;
    }
    return DEFAULT_ABS_FLOOR;
}

/// 末条 user 消息的首个 text block。倒扫跳过纯 tool_result 的 user 消息(无 .text block)。
/// **刻意近似**:多 block 消息(图片/@引用把文件内容作为独立 text block)可能取到非问题文本;
/// 召回质量的可接受降级,非 correctness bug。
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
    var n = @min(end, MAX_HIT_TEXT_BYTES);
    while (n > 0 and (text[n - 1] & 0xC0) == 0x80) n -= 1; // 不切半个 CJK 字
    return text[0..n];
}

test "firstLine keeps a canonical bridge placed after the old 100-byte cutoff" {
    const text = "长期任务被中断以后重新接续时，先从历史记录恢复精确并发规则；该规则的 canonical alias 是 orion-k9，后续应使用它聚焦检索。";
    try std.testing.expect(text.len > 100);
    const visible = firstLine(text);
    try std.testing.expect(std.mem.indexOf(u8, visible, "orion-k9") != null);
}

test "build:kg 未就绪 → null(不阻塞)" {
    const a = std.testing.allocator;
    var conv = conv_mod.Conversation.init(a);
    defer conv.deinit();
    var kg = try client_mod.KgClient.init(a, .{ .home = "/tmp", .domain = "d", .env_bin = "", .env_store = "" });
    defer kg.deinit();
    var ab = AbortSignal.init();
    try std.testing.expect((try build(a, &kg, &conv, &ab)) == null);
}
