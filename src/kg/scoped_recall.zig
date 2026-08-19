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

pub const RECEIPT_SCHEMA_VERSION = "metacodes-scoped-recall-v1";

/// Redacted execution receipt for evaluation. It commits to the exact query
/// and synthetic block without exposing either one in the native event log.
/// Counts remain zero on every non-injection path, so replay can distinguish a
/// real host recall miss from a missing/forged activation claim.
pub const Receipt = struct {
    schema_version: []const u8 = RECEIPT_SCHEMA_VERSION,
    status: []const u8,
    query_sha256: [64]u8 = .{'0'} ** 64,
    result_count: usize = 0,
    injected_count: usize = 0,
    injected_bytes: usize = 0,
    injection_sha256: [64]u8 = .{'0'} ** 64,
};

pub const BuildResult = struct {
    text: ?[]u8,
    receipt: Receipt,

    pub fn deinit(self: *BuildResult, allocator: std.mem.Allocator) void {
        if (self.text) |text| allocator.free(text);
        self.* = undefined;
    }
};

/// 相关性门 + 动态条数。best-effort:kg 未就绪 / 关闭 / 无末条 user 文本 / 消息琐碎 / 无相关命中
/// → null(不注入)。返回 error 仅内部分配失败(调用方 `catch null` 兜底,等价不注入)。owned。
pub fn build(
    allocator: std.mem.Allocator,
    kg: *client_mod.KgClient,
    conversation: *const conv_mod.Conversation,
    abort: *const AbortSignal,
) !?[]u8 {
    const result = try buildWithReceipt(allocator, kg, conversation, abort);
    return result.text;
}

/// 结局行正文前缀(与 core/self_evolution.OUTCOME_MARKER comptime 锁定一致)。
pub const OUTCOME_NOTE_MARKER = "task-outcome-v1";
const TASK_HINT_ENV = "METACODES_TASK_HINT";

/// 确定性同题结局注入:host 经 env 声明本 run 的任务名,把该任务上一次
/// 尝试的判定结局(reward/计数/错题名)钉进注入尾。**独立于 BM25 相关性
/// 门**——两遍法生产取证:被动召回 16 trial 仅 4 次命中且全是别题的成绩
/// 单,同题行从未到达,反馈等于没发。best-effort:无 hint/无匹配 → null。
/// 返回 `allocator` 所有。
/// 取 hint 任务最近一次尝试的结局行原文(owned by `allocator`)。注入与
/// author 任务上下文共用(单一取数路径)。无 hint 匹配 → null。
pub fn sameTaskOutcomeRow(
    allocator: std.mem.Allocator,
    kg: *client_mod.KgClient,
    hint: []const u8,
) ?[]u8 {
    if (hint.len == 0 or hint.len > 200) return null;
    var needle_buffer: [232]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buffer, " task={s} ", .{hint}) catch return null;
    var query_buffer: [280]u8 = undefined;
    const query = std.fmt.bufPrint(&query_buffer, OUTCOME_NOTE_MARKER ++ " {s}", .{hint}) catch return null;
    const hits = kg.recallTyped(query, 40, false, "task_outcome") catch return null;
    defer {
        for (hits) |*h| h.deinit(kg.allocator);
        kg.allocator.free(hits);
    }
    // 同题可能多条(多次尝试):取 node_id 最大 = 最近一次。
    var best_id: u64 = 0;
    var best_text: ?[]const u8 = null;
    var best_truncated = false;
    for (hits) |h| {
        if (std.mem.indexOf(u8, h.text, needle) == null) continue;
        if (best_text != null and h.node_id <= best_id) continue;
        best_id = h.node_id;
        best_text = h.text;
        best_truncated = h.text_truncated;
    }
    var body: []const u8 = best_text orelse return null;
    // 错题名在行尾,截断摘录会砍掉 payload → 补取全文。
    var full_owned: ?[]u8 = null;
    defer if (full_owned) |full| kg.allocator.free(full);
    if (best_truncated) {
        if (kg.fetchNodeText(best_id)) |full| {
            full_owned = full;
            body = full;
        } else |_| {}
    }
    return allocator.dupe(u8, body) catch null;
}

fn sameTaskOutcomeNote(allocator: std.mem.Allocator, kg: *client_mod.KgClient) ?[]u8 {
    const hint_c = std.c.getenv(TASK_HINT_ENV) orelse return null;
    const hint = std.mem.span(hint_c);
    const body = sameTaskOutcomeRow(allocator, kg, hint) orelse return null;
    defer allocator.free(body);
    // 框架语对冲"按笔记写不自测"的过度自信模式(schema_drift 验尸),并
    // 要求把每个失败名转成可执行检查(p4 取证:名字送达后仍原样重败同
    // 4 测——缺的是"名字→在工作区复现它的检查"这一步);带路径/模块名的
    // 失败(pytest id、skipped 模块)指向可直接阅读的真实文件。
    return std.fmt.allocPrint(
        allocator,
        "<system-reminder>\n# 本任务上一次尝试的判定结局(host 声明,确定性注入)\n" ++
            "{s}\n" ++
            "This verdict was produced by a verifier that runs outside your workspace: its " ++
            "test files may not exist locally, so do not expect to find or run them, and " ++
            "never dismiss their names as stale or hallucinated — an absent referenced file " ++
            "is expected here, not evidence against the requirement. " ++
            "Garbage In, Garbage Out: misread inputs become wrong code — audit the task " ++
            "statement and the feedback above word by word before acting. Failing tests are " ++
            "executable specifications, and every word in a failing or skipped test name is " ++
            "part of the spec; cover each point with your own equivalent check. " ++
            "Reproduce before you fix: make it fail, then make it pass. " ++
            "When two readings are possible, decide from verifiable facts in the workspace, " ++
            "not intuition or convention. No regressions: re-run your whole check suite " ++
            "before closing.\n" ++
            "</system-reminder>\n",
        .{body},
    ) catch null;
}

pub fn buildWithReceipt(
    allocator: std.mem.Allocator,
    kg: *client_mod.KgClient,
    conversation: *const conv_mod.Conversation,
    abort: *const AbortSignal,
) !BuildResult {
    var scored = try buildScoredReceipt(allocator, kg, conversation, abort);
    if (disabled() or !kg.ready) return scored;
    const note = sameTaskOutcomeNote(allocator, kg) orelse return scored;
    defer allocator.free(note);
    // 合并:确定性段在前,BM25 段在后;回执如实覆盖合并后全文(注入审计
    // 面不得旁路)。
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, note);
    if (scored.text) |scored_text| {
        try out.appendSlice(allocator, scored_text);
        allocator.free(scored_text);
        scored.text = null;
    }
    const text = try out.toOwnedSlice(allocator);
    var receipt = scored.receipt;
    receipt.status = "injected";
    receipt.injected_count += 1;
    receipt.injected_bytes = text.len;
    receipt.injection_sha256 = sha256Hex(text);
    // warn 级:host 定向注入是显著干预,必须在生产可审计(trial 的 stderr
    // 由 Harbor 收进 trial.log;p3 取证时无任何面能证明注入到达,只能靠
    // 行为侧写间接推断——不再允许这种盲区)。
    const note_sha = sha256Hex(note);
    log.warn("kg", "deterministic outcome note injected bytes={d} sha256={s}", .{
        note.len, note_sha[0..16],
    });
    return .{ .text = text, .receipt = receipt };
}

fn buildScoredReceipt(
    allocator: std.mem.Allocator,
    kg: *client_mod.KgClient,
    conversation: *const conv_mod.Conversation,
    abort: *const AbortSignal,
) !BuildResult {
    if (disabled()) return noInjection("disabled"); // escape hatch(解耦 KG)
    if (!kg.ready) return noInjection("kg_not_ready");
    const raw = lastUserText(conversation) orelse return noInjection("no_user_text");
    if (raw.len < MIN_QUERY_LEN) return noInjection("query_too_short"); // 琐碎轮不召回
    const query = raw[0..@min(raw.len, MAX_QUERY_LEN)]; // 上界截断
    const query_sha256 = sha256Hex(query);

    kg.setAbort(abort); // ESC 可中断
    const hits = kg.recall(query, TOP_K, false) catch return .{
        .text = null,
        .receipt = .{ .status = "search_error", .query_sha256 = query_sha256 },
    };
    defer {
        for (hits) |*h| h.deinit(allocator);
        allocator.free(hits);
    }
    if (hits.len == 0) return .{
        .text = null,
        .receipt = .{ .status = "no_hits", .query_sha256 = query_sha256 },
    };

    // 相关性门:top 分做绝对地板(答案缺席→0 条)+ 相对衰减(留 ≥top×REL)。
    var top: f64 = 0;
    for (hits) |h| {
        if (h.score > top) top = h.score;
    }
    const floor = absFloor();
    if (top < floor) {
        log.info("kg", "scoped_recall injected=0 top_score={d:.2} (below floor {d:.2})", .{ top, floor });
        return .{
            .text = null,
            .receipt = .{
                .status = "below_floor",
                .query_sha256 = query_sha256,
                .result_count = hits.len,
            },
        }; // 最相关的都弱 → 判为答案缺席,不注入噪声
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

    const text = try out.toOwnedSlice(allocator);
    log.info("kg", "scoped_recall injected={d} top_score={d:.2} query_len={d}", .{ injected, top, query.len });
    return .{
        .text = text,
        .receipt = .{
            .status = "injected",
            .query_sha256 = query_sha256,
            .result_count = hits.len,
            .injected_count = injected,
            .injected_bytes = text.len,
            .injection_sha256 = sha256Hex(text),
        },
    };
}

fn noInjection(status: []const u8) BuildResult {
    return .{ .text = null, .receipt = .{ .status = status } };
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
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
