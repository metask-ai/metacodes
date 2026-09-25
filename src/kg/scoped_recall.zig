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
const jev_advisor = @import("../jev/advisor.zig");
const observation = @import("../tools/observation.zig");

pub const MIN_QUERY_LEN = 16; // 琐碎接话轮门(下界)
pub const MAX_QUERY_LEN = 400; // BM25 query 上界(避免粘贴长文变噪声 query)
// 自动命中既是上下文，也是 lexical→semantic 的桥。100 bytes 会把中文记忆压到约 33 字，
// canonical alias/代码符号常在句尾被截掉，迫使模型重新宽搜。3 条×320B 仍是有界小预算。
const MAX_HIT_TEXT_BYTES = 320;
pub const TOP_K = 3;
const REL_RATIO: f64 = 0.5; // 相对门:只留 ≥ top×0.5 的命中
// 绝对地板(BM25;启发式,可 METACODES_RECALL_FLOOR 校准)。实测数据定初值:相关 query top≈7,
// 无关 query top≈2.7 → 3.0 分界(auto-inject 精度优先,宁漏勿噪——PM:注入无关记忆=负价值)。
// BM25 分跨 query 不可比,固定地板固有不精确;仪器日志(injected/top_score)供持续校准。
pub const DEFAULT_ABS_FLOOR: f64 = 3.0;

// System-One relevance gate (Jev-Mem read path). With an advisor installed the
// host asks TinyKG for `JUDGED_CANDIDATES` rank-ordered hits instead of TOP_K
// and has the judge score each one. The first TOP_K of that pool are exactly
// the hits the baseline would have seen, so the BM25 floor stays computable
// alongside the judged policy (shadow compares both on identical input).
const JUDGED_CANDIDATES = jev_advisor.MAX_RECALL_CANDIDATES;
/// Floor of the judged policy below. A calibrated probability means the same
/// thing across queries, which is the property the BM25 floor above admits it
/// lacks. On the pinned LongMemEval-S dev split 40 kept the gold-evidence hit
/// rate of floors 20-30 while injecting the fewest non-evidence lines.
pub const RELEVANCE_THRESHOLD_PERCENT: u8 = 40;
/// Weight of the pool-normalized BM25 score in the judged rank. The judge
/// reads a JUDGE_WINDOW_BYTES window of each memory, BM25 the whole of it: on
/// whole-session memories (median 13.7 KB) the judge alone lost gold evidence
/// BM25 still ranked high (hit 0.700 vs 0.790 fused), while on turn-sized
/// memories fusion cost less (0.730 vs 0.685).
pub const BM25_FUSION_WEIGHT: f64 = 0.5;

pub const Options = struct {
    /// System-One judge; null keeps the BM25 floor path byte for byte.
    advisor: ?*jev_advisor.Advisor = null,
};

/// Indices into the rank-ordered hit list, in injection order.
pub const Selection = struct {
    indices: [TOP_K]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Selection) []const u8 {
        return self.indices[0..self.len];
    }

    fn contains(self: *const Selection, index: usize) bool {
        for (self.slice()) |selected| {
            if (selected == index) return true;
        }
        return false;
    }

    fn push(self: *Selection, index: usize) void {
        self.indices[self.len] = @intCast(index);
        self.len += 1;
    }
};

/// The deterministic baseline over the first TOP_K rank-ordered scores: no
/// injection when the best score is under the absolute floor, otherwise every
/// hit within REL_RATIO of the best.
pub fn baselineSelection(scores: []const f64, floor: f64) Selection {
    var selection: Selection = .{};
    const n = @min(scores.len, TOP_K);
    if (n == 0) return selection;
    var top: f64 = 0;
    for (scores[0..n]) |score| top = @max(top, score);
    if (top < floor) return selection;
    const keep_min = top * REL_RATIO;
    for (scores[0..n], 0..) |score, index| {
        if (score >= keep_min) selection.push(index);
    }
    return selection;
}

/// The judged policy. BM25 still decides whether any memory is injected (its
/// floor is the answer-absent signal) and which memories are plausible at all
/// (the baseline's own band, score >= top * REL_RATIO, now over the whole
/// pool); judge and BM25 together decide which plausible ones are injected.
/// They are ranked by `percent / 100 + BM25_FUSION_WEIGHT * score / top`
/// (BM25 rank breaks ties); the first TOP_K that clear
/// RELEVANCE_THRESHOLD_PERCENT are injected, or the first one alone when none
/// does.
///
/// The band is what keeps the judge from overruling a clear lexical winner.
/// In the paid procedural-transfer pilot the judge rated a sibling task's
/// protocol (BM25 top) below a concrete diff of that sibling (1/9 of its
/// score) in every offline pool, the unbanded policy injected the diff, and
/// the model replayed the sibling's edit. On LongMemEval-S, where pools are
/// flat, the band changed no hit: turn-level holdout 0.703 vs 0.633 for the
/// floor alone, whole-session holdout 0.740 vs 0.717, with 1.4-1.7 instead of
/// 3.0 lines injected.
pub fn judgedSelection(percents: []const u8, scores: []const f64, baseline: Selection) Selection {
    std.debug.assert(percents.len == scores.len and percents.len <= JUDGED_CANDIDATES);
    var selection: Selection = .{};
    if (baseline.len == 0 or percents.len == 0) return selection;
    var top: f64 = 0;
    for (scores) |score| top = @max(top, score);
    var fused: [JUDGED_CANDIDATES]f64 = undefined;
    var order: [JUDGED_CANDIDATES]u8 = undefined;
    var plausible: usize = 0;
    for (percents, scores, 0..) |percent, score, index| {
        // Outside the BM25 band: never injected, whatever the judge says.
        if (score < top * REL_RATIO) continue;
        const bm25 = if (top > 0) BM25_FUSION_WEIGHT * score / top else 0;
        fused[index] = @as(f64, @floatFromInt(percent)) / 100.0 + bm25;
        order[plausible] = @intCast(index);
        plausible += 1;
    }
    std.debug.assert(plausible > 0); // the top-scoring candidate is always in its own band
    // Stable, so equal fused scores keep BM25 rank order.
    std.sort.insertion(u8, order[0..plausible], @as([]const f64, &fused), fusedDescending);
    for (order[0..plausible]) |index| {
        if (selection.len == TOP_K) break;
        if (percents[index] >= RELEVANCE_THRESHOLD_PERCENT) selection.push(index);
    }
    if (selection.len == 0) selection.push(order[0]);
    return selection;
}

fn fusedDescending(fused: []const f64, a: u8, b: u8) bool {
    return fused[a] > fused[b];
}

/// Candidates one policy injects and the other does not.
pub fn selectionDelta(a: Selection, b: Selection) u32 {
    var delta: u32 = 0;
    for (a.slice()) |index| {
        if (!b.contains(index)) delta += 1;
    }
    for (b.slice()) |index| {
        if (!a.contains(index)) delta += 1;
    }
    return delta;
}

/// What the System-One judge said about this recall and what the host did.
/// Node ids and percents are host evidence for replayable evaluation; they
/// never enter the provider request.
pub const SystemOneRecord = struct {
    audit: jev_advisor.Audit,
    actuated: bool = false,
    judged: u32 = 0,
    positive: u32 = 0,
    changed: u32 = 0,
    node_ids: [JUDGED_CANDIDATES]u64 = [_]u64{0} ** JUDGED_CANDIDATES,
    percents: [JUDGED_CANDIDATES]u8 = [_]u8{0} ** JUDGED_CANDIDATES,
    baseline: Selection = .{},
    judged_selection: Selection = .{},

    pub fn event(self: *const SystemOneRecord) observation.Event {
        return self.audit.event(self.actuated, self.judged, self.positive, self.changed);
    }
};

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
    /// Present whenever an advisor was consulted (shadow or advisory).
    system_one: ?SystemOneRecord = null,

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
    options: Options,
) !?[]u8 {
    const result = try buildWithReceipt(allocator, kg, conversation, abort, options);
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
    // v38:读窗 40→98(灌店残留清净前,40 窗看不到真实最新行——"最新行"
    // 冻结在旧 1.0 行,分支判定失真。98=CLI 硬帽 200 经客户端超采
    // limit*2+4 反推的最大可用值)。
    const hits = kg.recallTyped(query, 98, false, "task_outcome") catch return null;
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

/// 行内 failing=[...] 段(与 obligation_gate.appendDerived 同一定界契约:
/// note 字段在括号之后且 adapter 已剥方括号)。
fn failingSection(row_text: []const u8) ?[]const u8 {
    const open = std.mem.indexOf(u8, row_text, "failing=[") orelse return null;
    const start = open + "failing=[".len;
    // 首个 ']' 定界(名字是 node id、理由已剥括号 → 段内无 ']';行尾可能
    // 追加含任意括号的 artifact 块,last-index 定界会被它劫持)。
    const close = std.mem.indexOfScalarPos(u8, row_text, start, ']') orelse return null;
    if (close <= start) return null;
    return row_text[start..close];
}

const MAX_MODE_POINTS: usize = 5;
const MAX_HISTORY_ROWS: usize = 8;

/// 认知模式段:对最新失败名逐点计算**连续末尾败次**(仅在 failing 段内
/// 匹配,不受 note 字段污染),按 cognitive_mode.schedule 渲染强制读法。
/// 调度纯函数 Lean 已证(全函数/单调/默认 verify);此处只是渲染。
/// 在 failing 段里找 bare 名对应条目的括号注解内容("skipped: …"/"failed: …")。
/// 条目以 ", " 分隔且理由无逗号(adapter 逗号→分号纪律),尾括号即条目末尾。
pub fn entryAnnotation(section: []const u8, bare: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, section, ", ");
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " ");
        if (!std.mem.startsWith(u8, entry, bare)) continue;
        const rest = entry[bare.len..];
        if (!std.mem.startsWith(u8, rest, " (")) continue;
        if (!std.mem.endsWith(u8, rest, ")")) continue;
        return rest[2 .. rest.len - 1];
    }
    return null;
}

/// 有界追加(容量满则静默截断——mode 行是提示不是账本)。
fn appendBounded(buffer: []u8, used: *usize, bytes: []const u8) void {
    const room = buffer.len - used.*;
    const n = @min(room, bytes.len);
    @memcpy(buffer[used.* .. used.* + n], bytes[0..n]);
    used.* += n;
}

fn appendModeSection(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    history_ascending: []const []const u8,
) !usize {
    var max_streak: usize = 0;
    if (history_ascending.len == 0) return 0;
    const cognitive_mode = @import("../core/cognitive_mode.zig");
    const newest = history_ascending[history_ascending.len - 1];
    const newest_failing = failingSection(newest) orelse return 0;
    var rendered: usize = 0;
    var it = std.mem.splitSequence(u8, newest_failing, ", ");
    while (it.next()) |raw_name| {
        if (rendered >= MAX_MODE_POINTS) break;
        const annotated = std.mem.trim(u8, raw_name, " ");
        // 身份=裸 node id(截首个 " ("):理由注解逐轮变化,拿全串匹配会把
        // streak 归零;旧行 "(skipped)"/新行 "(skipped: reason)" 都含裸名。
        const name = if (std.mem.indexOf(u8, annotated, " (")) |cut|
            annotated[0..cut]
        else
            annotated;
        if (name.len < 4) continue;
        var streak: usize = 1;
        var back = history_ascending.len - 1;
        while (back > 0) {
            back -= 1;
            const section = failingSection(history_ascending[back]) orelse break;
            if (std.mem.indexOf(u8, section, name) == null) break;
            streak += 1;
        }
        if (streak > max_streak) max_streak = streak;
        if (rendered == 0)
            try out.appendSlice(allocator, "Per-point reading mode (host-computed from your attempt history):\n");
        const mode = cognitive_mode.schedule(streak);
        // 累积规格回携(p15 取证:结构信号与形状信号住在相邻两行,body
        // 只引最新行 → 振荡遗忘)。每点附历史中最近一次**更早的**注解理由,
        // 与最新行的注解在同屏共存。
        // 约束累积(p22 取证:模型每轮最多整合一条修正,sync/len/签名轮流
        // 丢。历史所有**去重**报告同行呈现——harness 替它记,它只需同时
        // 满足)。newest 自己的注解已在 body,排除;每点至多 3 条。
        const newest_ann = entryAnnotation(newest_failing, name);
        var distinct: [3][]const u8 = undefined;
        var distinct_n: usize = 0;
        var pback = history_ascending.len - 1;
        while (pback > 0 and distinct_n < distinct.len) {
            pback -= 1;
            const psec = failingSection(history_ascending[pback]) orelse continue;
            const ann = entryAnnotation(psec, name) orelse continue;
            if (newest_ann != null and std.mem.eql(u8, ann, newest_ann.?)) continue;
            var dup = false;
            for (distinct[0..distinct_n]) |seen| {
                if (std.mem.eql(u8, seen, ann)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            distinct[distinct_n] = ann;
            distinct_n += 1;
        }
        var reason_buffer: [420]u8 = undefined;
        var reason_used: usize = 0;
        if (distinct_n > 0) {
            appendBounded(&reason_buffer, &reason_used, " | every past report for this point: ");
            for (distinct[0..distinct_n], 0..) |r, ri| {
                if (ri > 0) appendBounded(&reason_buffer, &reason_used, "  PLUS  ");
                var end: usize = @min(r.len, 110);
                while (end > 0 and end < r.len and (r[end] & 0xC0) == 0x80) end -= 1;
                appendBounded(&reason_buffer, &reason_used, r[0..end]);
            }
        }
        const prev_part: []const u8 = reason_buffer[0..reason_used];
        const line = try std.fmt.allocPrint(
            allocator,
            "- {s} — failed {d} consecutive attempt(s): {s}{s}\n",
            .{ name, streak, mode.directive(), prev_part },
        );
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
        rendered += 1;
    }
    return max_streak;
}

/// 历史里 reward 严格高于 newest 的最高行(同分不注,避免冗余)。
/// reward 解析失败按 -1 处理(绝不虚报最佳)。
fn rowReward(row: []const u8) f64 {
    const tag = std.mem.indexOf(u8, row, " reward=") orelse return -1;
    const start = tag + " reward=".len;
    var end = start;
    while (end < row.len and (row[end] == '.' or (row[end] >= '0' and row[end] <= '9'))) end += 1;
    return std.fmt.parseFloat(f64, row[start..end]) catch -1;
}

/// 行的溯源层级(无 prov 字段 → external_oracle,存量行如实兼容)。
fn rowProvenanceRank(row: []const u8) u8 {
    const verdict = @import("../core/verdict.zig");
    const tag = std.mem.indexOf(u8, row, " prov=") orelse
        return verdict.Provenance.external_oracle.rank();
    const start = tag + " prov=".len;
    const end = std.mem.indexOfScalarPos(u8, row, start, ' ') orelse row.len;
    return verdict.Provenance.parse(row[start..end]).rank();
}

pub fn bestHistoryRow(history: []const []u8, newest: []const u8) ?[]const u8 {
    const newest_reward = rowReward(newest);
    var best: ?[]const u8 = null;
    var best_reward: f64 = newest_reward;
    // 字典序 (reward, provenance rank, recency):自跑检查的行绝不压过
    // 同分的权威行——策略 Lean 镜面 VerdictProvenance.better。
    var best_rank: u8 = 0;
    for (history) |row| {
        if (std.mem.eql(u8, row, newest)) continue;
        const r = rowReward(row);
        const rank = rowProvenanceRank(row);
        if (r > best_reward) {
            best_reward = r;
            best_rank = rank;
            best = row;
        } else if (best != null and r == best_reward) {
            if (rank > best_rank) {
                best_rank = rank;
                best = row;
            } else if (rank == best_rank) {
                // 同分同级取更新(工件升级复本在后;history 升序=recency)。
                best = row;
            }
        }
    }
    return best;
}

/// v37 note 载体的逐字复现指令(与 obligation_gate.appendArtifactFirst 同一
/// "--- path ---" 定界契约):工件未截断 → FIRST-edit UNCHANGED 逐字令;
/// 截断 → 参考-重建语义(半个文件+UNCHANGED=语法错误毒药)。
fn appendVerbatimDirective(out: *std.ArrayList(u8), allocator: std.mem.Allocator, best: []const u8) void {
    const marker = std.mem.indexOf(u8, best, "best-attempt artifact") orelse return;
    const path_open = std.mem.indexOfPos(u8, best, marker, "--- ") orelse return;
    const path_close = std.mem.indexOfPos(u8, best, path_open + 4, " ---") orelse return;
    var path = best[path_open + 4 .. path_close];
    // v43 多文件工件:修改型段的定界是 "--- <path> (apply-diff) ---",
    // 提取到的 path 会带该后缀;剥掉并切到 diff 语义指令。
    var first_is_diff = false;
    if (std.mem.endsWith(u8, path, " (apply-diff)")) {
        first_is_diff = true;
        path = path[0 .. path.len - " (apply-diff)".len];
    }
    if (path.len == 0 or path.len > 160) return;
    if (std.mem.indexOfScalar(u8, path, '\n') != null) return;
    const has_diff_sections = std.mem.indexOfPos(u8, best, marker, " (apply-diff) ---") != null;
    const truncated = std.mem.indexOfPos(u8, best, marker, "HOST-TRUNCATED") != null;
    if (truncated) {
        out.appendSlice(allocator, "FIRST EDIT: rebuild the complete file at `") catch return;
        out.appendSlice(allocator, path) catch return;
        out.appendSlice(allocator, "` using the quoted artifact above as the authoritative reference for " ++
            "signature, imports and shape (it is HOST-TRUNCATED — do not copy it " ++
            "verbatim). Only then apply the expected-side fixes the reports demand.\n") catch return;
        return;
    }
    if (first_is_diff) {
        out.appendSlice(allocator, "FIRST EDIT: apply the diff hunks quoted above to `") catch return;
        out.appendSlice(allocator, path) catch return;
        out.appendSlice(allocator, "` exactly as written — every hunk, no re-derivation. Then apply every " ++
            "other quoted section the same way before anything else.\n") catch return;
        return;
    }
    out.appendSlice(allocator, "FIRST EDIT: write the artifact quoted above to `") catch return;
    out.appendSlice(allocator, path) catch return;
    out.appendSlice(allocator, "` byte-for-byte UNCHANGED — do not retype it from memory, do not adjust " ++
        "signatures, file modes or imports; every free-hand rewrite so far has " ++
        "regressed an already-solved facet. Only after that file is in place " ++
        "apply the expected-side fixes the reports demand.\n") catch return;
    if (has_diff_sections) {
        out.appendSlice(allocator, "The sections marked (apply-diff) are unified-diff hunks against " ++
            "existing files — apply every quoted hunk exactly (do not re-derive " ++
            "the change) before running checks.\n") catch return;
    }
}

/// v36 卡滞平台判定:最近 3 行(升序尾部)reward 相同且 failing 段逐字节
/// 相同 → 压力栈已被证明非因果。任何变化(新失败名/新分数)即打破。
pub fn stuckPlateau(history: []const []u8) bool {
    if (history.len < 3) return false;
    const tail = history[history.len - 3 ..];
    const r0 = rowReward(tail[0]);
    const f0 = failingSection(tail[0]) orelse return false;
    for (tail[1..]) |row| {
        if (rowReward(row) != r0) return false;
        const f = failingSection(row) orelse return false;
        if (!std.mem.eql(u8, f, f0)) return false;
    }
    return true;
}

pub const MAX_SUPERSEDED_SYMBOLS: usize = 4;

/// v36 读平面 supersede(p36 取证:v35 针钉住了工件路径,模型却经 6 次主动
/// KgRecall 拉回冲突 CORRECTION 记忆,在正确路径写了 async 版——毒经读
/// 平面绕过注入面)。曾经全过且最佳行携带工件时,从工件正文**词法**提取
/// 定义符号(def/class/fn/function 后的标识符,≥4 字符,上限 4 个);
/// KgRecall 对提及这些符号的非结局行命中盖 provenance_caveat 戳。
/// 符号内存由 out_storage(调用方 buffer)持有;返回符号数,0=非静默态或
/// 无工件。内容盲、任务无关:符号来自该任务自己的已证工件。
pub fn artifactSupersededSymbols(
    allocator: std.mem.Allocator,
    kg: *client_mod.KgClient,
    hint: []const u8,
    out_storage: *[MAX_SUPERSEDED_SYMBOLS][64]u8,
    out_lens: *[MAX_SUPERSEDED_SYMBOLS]usize,
) usize {
    if (hint.len == 0 or hint.len > 200) return 0;
    const gate = @import("../core/obligation_gate.zig");
    var history = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (history.items) |row| allocator.free(row);
        history.deinit();
    }
    collectHistory(allocator, kg, hint, &history);
    const newest = sameTaskOutcomeRow(allocator, kg, hint) orelse return 0;
    defer allocator.free(newest);
    var ever_solved = gate.rowSolved(newest);
    if (!ever_solved) for (history.items) |row| {
        if (gate.rowSolved(row)) {
            ever_solved = true;
            break;
        }
    };
    // v44 更正(v43 潜在缺陷, 由收紧宽限后的 artifact-task pin 暴露):
    // supersede **不随声明失信关闭**。它不是静默决策而是**证据位阶**决策——
    // host_run 全过裁决所证明的工件, 其定义符号压过存量声明这件事, 与"本轮
    // 是否复现成功"无关。v43 曾把失信一并用在这里, 结果是:复现失败 → 失信
    // → supersede 关闭 → 冲突记忆恢复全力, 而复现失败往往**正是**冲突记忆
    // 造成的(etag: node 698 的 async 版赢过逐字工件)。那会把下滑环再加一档。
    if (!ever_solved) return 0;
    const best = bestHistoryRow(history.items, newest) orelse newest;
    const marker = std.mem.indexOf(u8, best, "best-attempt artifact") orelse return 0;
    const body = best[marker..];
    var count: usize = 0;
    const keywords = [_][]const u8{ "def ", "class ", "fn ", "function " };
    var pos: usize = 0;
    while (pos < body.len and count < MAX_SUPERSEDED_SYMBOLS) {
        var next_hit: ?usize = null;
        var next_len: usize = 0;
        for (keywords) |kw| {
            if (std.mem.indexOfPos(u8, body, pos, kw)) |at| {
                // 词首边界:行首或前一字符非标识符成分(排除 "undef "/"async def" 的
                // "def" 误配不重要——async def 的 def 也算词首,提取同一个符号)。
                if (at > 0) {
                    const prev = body[at - 1];
                    const prev_ident = (prev >= 'a' and prev <= 'z') or (prev >= 'A' and prev <= 'Z') or
                        (prev >= '0' and prev <= '9') or prev == '_';
                    if (prev_ident) continue;
                }
                if (next_hit == null or at < next_hit.?) {
                    next_hit = at;
                    next_len = kw.len;
                }
            }
        }
        const at = next_hit orelse break;
        var i = at + next_len;
        const sym_start = i;
        while (i < body.len) : (i += 1) {
            const c = body[i];
            const ident = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or c == '_';
            if (!ident) break;
        }
        const sym = body[sym_start..i];
        pos = i;
        if (sym.len < 4 or sym.len > 64) continue;
        var dup = false;
        for (0..count) |k| {
            if (std.mem.eql(u8, out_storage[k][0..out_lens[k]], sym)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        @memcpy(out_storage[count][0..sym.len], sym);
        out_lens[count] = sym.len;
        count += 1;
    }
    return count;
}

pub fn sameTaskOutcomeNote(allocator: std.mem.Allocator, kg: *client_mod.KgClient) ?[]u8 {
    const hint_c = std.c.getenv(TASK_HINT_ENV) orelse return null;
    const hint = std.mem.span(hint_c);
    const body = sameTaskOutcomeRow(allocator, kg, hint) orelse return null;
    defer allocator.free(body);
    // 尝试历史(升序 node_id,cap 8):失败名 streak 的数据面。
    var history = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (history.items) |row| allocator.free(row);
        history.deinit();
    }
    collectHistory(allocator, kg, hint, &history);
    // 框架语:输入审计(GIGO)+ 目标读法 + 前沿推进 + 认知模式调度段。
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    out.appendSlice(allocator, "<system-reminder>\n# 本任务上一次尝试的判定结局(host 声明,确定性注入)\n") catch return null;
    out.appendSlice(allocator, body) catch return null;
    out.appendSlice(allocator, "\n") catch return null;
    // 最佳尝试锚(p19 取证:攻克的面在失败反馈里零痕迹——p18 的 sync 胜利
    // 随工作区重置蒸发。历史最高 reward 行=已验证可达的最优配置,其剩余
    // 败点=最短路径)。仅当最佳行严格优于最新行时注入,避免冗余。
    if (bestHistoryRow(history.items, body)) |best| {
        out.appendSlice(allocator, "# 历史最佳尝试(host 声明;先复现它的构型,再只修它剩下的败点)\n") catch return null;
        out.appendSlice(allocator, best) catch return null;
        out.appendSlice(allocator, "\n") catch return null;
        // v44:引用了最佳工件就必须附上机械化的写入指令。此前逐字令只挂在
        // 已解静默的回归分支上, 于是"声明失信 → 回到未解路径"会连同指令一起
        // 丢掉已证工件——失信的正确回应是**加压**, 不是丢掉唯一已证配置。
        // (同一类错误在 v43 出现三处:supersede 通道、逐字令、这里。)
        appendVerbatimDirective(&out, allocator, best);
    }
    // 已解决静默(p33/p34 取证):键**曾经全过**(最佳行或最新行)。
    // 最新行回归时仍静默——已证配置存在,正确剂量="复现最佳",重新
    // 施压只会让 agent 追自己的回归鬼影(filterwarnings 1.0→0.5→0.5)。
    {
        const gate = @import("../core/obligation_gate.zig");
        var ever_solved = gate.rowSolved(body);
        if (!ever_solved) for (history.items) |row| {
            if (gate.rowSolved(row)) {
                ever_solved = true;
                break;
            }
        };
        // v43 重放自证伪(p44b/p45 取证:声明 1.0 的工件重放两轮逐字节
        // 0.4545——静默 + 不完整工件 = 平台自锁):连续 REPRO_GRACE_ROUNDS
        // 轮未达声明 → 静默失效,落回未解路径(最佳行引用仍在,压力栈恢复)。
        if (ever_solved and gate.claimNotReproduced(history.items)) ever_solved = false;
        if (ever_solved) {
            if (!gate.rowSolved(body)) {
                // 最新回归:引用最佳全过行(含 final_note 的已证方案)。
                var best_for_directive: ?[]const u8 = null;
                if (bestHistoryRow(history.items, body)) |best| {
                    out.appendSlice(allocator, "# 历史最佳尝试(全过;host 声明)\n") catch return null;
                    out.appendSlice(allocator, best) catch return null;
                    out.appendSlice(allocator, "\n") catch return null;
                    best_for_directive = best;
                }
                out.appendSlice(allocator, "The newest attempt REGRESSED from an already-proven configuration. " ++
                    "Reproduce the all-passing best attempt above exactly; treat the newest " ++
                    "failing names as damage introduced by that regression, not as new " ++
                    "requirements. Where a stored memory, note, or correction contradicts " ++
                    "the proven configuration above, the proven configuration wins — treat " ++
                    "the contradicting memory as stale. Re-run your whole check suite to " ++
                    "confirm.\n") catch return null;
                // v37(p37 取证):VERBATIM 逐字指令原先只挂在 nudge 文本里——
                // agent 提前自己碰了工件路径 → 义务提前 met → nudge 永不触发
                // → 指令丢失,模型第三次徒手重打实现(漏 'rb',6×TypeError)。
                // 指令改由 note 正文携带:note 无触发条件、每轮必达。路径从
                // 工件块机械提取,与 appendArtifactFirst 同一定界契约。
                if (best_for_directive) |best| appendVerbatimDirective(&out, allocator, best);
                out.appendSlice(allocator, "</system-reminder>\n") catch return null;
                return out.toOwnedSlice(allocator) catch null;
            }
            out.appendSlice(allocator, "This task's best configuration is already proven by the verdict above: " ++
                "reproduce that approach, re-run your whole check suite to confirm, and " ++
                "do not innovate beyond what the task statement asks. Where a stored " ++
                "memory, note, or correction contradicts the proven configuration above, " ++
                "the proven configuration wins — treat the contradicting memory as stale.\n" ++
                "</system-reminder>\n") catch return null;
            return out.toOwnedSlice(allocator) catch null;
        }
    }
    const max_streak = appendModeSection(&out, allocator, history.items) catch 0;
    // v36 卡滞平台冷却(p36 取证:filterwarnings 106→124 请求/轮,reward
    // 恒 0.5,失败集恒定——压力栈在该任务上已被证明非因果,纯烧预算。
    // 键=(最近 3 行 reward 相同 ∧ failing 段相同):任何新剂量(新机制发
    // 新针/reward 动/失败集动)都会打破键、恢复全额压力——etag 式破墙
    // 靠的是新剂量内容,不会被冷却误杀)。Lean 镜面 plateau_caps_pressure。
    if (max_streak >= 3 and stuckPlateau(history.items)) {
        out.appendSlice(allocator, "COOLED. This task's reward and failing set have been unchanged across " ++
            "the last attempts while the full pressure playbook ran — that playbook " ++
            "is proven non-causal here, so it is withdrawn this attempt. Work from " ++
            "the task statement and the verdict facts above; make ONE deliberately " ++
            "different attempt instead of re-executing the previous playbook. " ++
            "Re-run your whole check suite before closing.\n" ++
            "</system-reminder>\n") catch return null;
        return out.toOwnedSlice(allocator) catch null;
    }
    if (max_streak >= 3) {
        // 升级态瘦身(提示饱和对策):union/invert 级别的点在场时,九层
        // 说教稀释关键指令——只留判决+模式+三行硬约束,短促命令式。
        out.appendSlice(allocator, "ESCALATED. The mandated modes above are orders, not suggestions — execute them " ++
            "literally this attempt. FIRST ACTION: enter every point above — each " ++
            "failing name, each verifier reason, each artifact it names — into your " ++
            "task ledger (TaskCreate) as acceptance criteria; work that displaces " ++
            "these items repeats the last failure. Constraints: the verifier runs OUTSIDE this workspace " ++
            "and scores ONLY its own tests — equivalent checks you write yourself do not " ++
            "score, so \"conceptually verified\" is worth zero. A referenced-but-absent " ++
            "artifact (module, file, function) is something the verifier expects YOU to " ++
            "have created; creating it at the location its name implies is compliance, " ++
            "not gaming. One verdict per attempt — an unchanged approach is a wasted " ++
            "attempt. The quoted note above is a FAILING attempt's own words: where " ++
            "it claims completion or success, the reward on the same line refutes " ++
            "it — never inherit its claims. " ++
            "Re-run your whole check suite before closing.\n" ++
            "</system-reminder>\n") catch return null;
        return out.toOwnedSlice(allocator) catch null;
    }
    out.appendSlice(allocator,
        // p10 教训:旧句"cover each point with your own equivalent check"
        // 字面授权了等价替代(agent 最终自辩逐字执行它)。计分语义是
        // 字面制:只有被点名的测试本身可收集、可通过才得分。
        "This verdict was produced by a verifier that runs outside your workspace and " ++
            "scores only its own named tests: never dismiss their names as stale or " ++
            "hallucinated — an absent referenced file is a requirement you have not built " ++
            "yet, not evidence against the requirement. " ++
            "Garbage In, Garbage Out: misread inputs become wrong code — audit the task " ++
            "statement and the feedback above word by word before acting. Failing tests are " ++
            "executable specifications, and every word in a failing or skipped test name is " ++
            "part of the spec: each name references concrete artifacts (a file, a module, " ++
            "a class, a function) — build exactly those artifacts at the locations the name " ++
            "implies so the named test itself could collect and pass; a private equivalent " ++
            "check of your own scores nothing. " ++
            "Enter each requirement above into your task ledger (TaskCreate) before " ++
            "other work — a plan not on the ledger does not survive a long session. " ++
            "Reproduce before you fix: make it fail, then make it pass. " ++
            "A failing requirement is a goal to make true, not a claim to falsify — when the " ++
            "thing it names does not exist, creating it is usually the requirement itself. " ++
            "When two readings are possible, decide from verifiable facts in the workspace, " ++
            "not intuition or convention. You get exactly one verdict per attempt: never " ++
            "resubmit an approach whose verdict you already know (your own previous " ++
            "conclusion is quoted above when available) — change something material. " ++
            "No regressions: re-run your whole check suite before closing.\n" ++
            "</system-reminder>\n") catch return null;
    return out.toOwnedSlice(allocator) catch null;
}

pub fn collectHistory(
    allocator: std.mem.Allocator,
    kg: *client_mod.KgClient,
    hint: []const u8,
    out: *std.array_list.Managed([]u8),
) void {
    var needle_buffer: [232]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buffer, " task={s} ", .{hint}) catch return;
    var query_buffer: [280]u8 = undefined;
    const query = std.fmt.bufPrint(&query_buffer, OUTCOME_NOTE_MARKER ++ " {s}", .{hint}) catch return;
    // v38:读窗 40→98(灌店残留清净前,40 窗看不到真实最新行——"最新行"
    // 冻结在旧 1.0 行,分支判定失真。98=CLI 硬帽 200 经客户端超采
    // limit*2+4 反推的最大可用值)。
    const hits = kg.recallTyped(query, 98, false, "task_outcome") catch return;
    defer {
        for (hits) |*h| h.deinit(kg.allocator);
        kg.allocator.free(hits);
    }
    const Entry = struct { id: u64, text: []u8 };
    var entries = std.array_list.Managed(Entry).init(allocator);
    defer entries.deinit();
    for (hits) |h| {
        if (std.mem.indexOf(u8, h.text, needle) == null) continue;
        // p10 取证:召回摘录 800 字符封顶,8 个长 pytest 名的 failing 列表
        // 必被截断在闭括号前 → failingSection=null → mode 段/升级态整体
        // 静默失效(任务越难列表越长越必然)。与 sameTaskOutcomeRow 同款
        // 补取全文;补取失败保留摘录(streak 宁可低估不虚增)。
        var text_src: []const u8 = h.text;
        var full_owned: ?[]u8 = null;
        defer if (full_owned) |full| kg.allocator.free(full);
        if (h.text_truncated) {
            if (kg.fetchNodeText(h.node_id)) |full| {
                full_owned = full;
                text_src = full;
            } else |_| {}
        }
        const copy = allocator.dupe(u8, text_src) catch continue;
        entries.append(.{ .id = h.node_id, .text = copy }) catch {
            allocator.free(copy);
            continue;
        };
    }
    std.sort.pdq(Entry, entries.items, {}, struct {
        fn lessThan(_: void, x: Entry, y: Entry) bool {
            return x.id < y.id;
        }
    }.lessThan);
    const start = if (entries.items.len > MAX_HISTORY_ROWS) entries.items.len - MAX_HISTORY_ROWS else 0;
    // v35(p35 取证):cap 只留最新窗口会驱逐最老的最佳证据行——曾经全过
    // 判定随之失明,鬼义务复武装,投毒自续(棘轮定律的数据面:cap 永不
    // 驱逐最佳行)。窗口外存在严格更优行时按时序前置钉住,序保持升序。
    var pinned_best: ?usize = null;
    if (start > 0) {
        var best_reward: f64 = -1.0;
        var best_rank: u8 = 0;
        for (entries.items, 0..) |entry, idx| {
            const r = rowReward(entry.text);
            const rank = rowProvenanceRank(entry.text);
            if (pinned_best == null or r > best_reward or
                (r == best_reward and rank >= best_rank))
            {
                best_reward = r;
                best_rank = rank;
                pinned_best = idx;
            }
        }
        // 最佳已在窗口内则无须钉。
        if (pinned_best) |idx| {
            if (idx >= start) pinned_best = null;
        }
    }
    for (entries.items, 0..) |entry, index| {
        const keep = index >= start or (pinned_best != null and index == pinned_best.?);
        if (!keep) {
            allocator.free(entry.text);
            continue;
        }
        out.append(entry.text) catch allocator.free(entry.text);
    }
}

pub fn buildWithReceipt(
    allocator: std.mem.Allocator,
    kg: *client_mod.KgClient,
    conversation: *const conv_mod.Conversation,
    abort: *const AbortSignal,
    options: Options,
) !BuildResult {
    var scored = try buildScoredReceipt(allocator, kg, conversation, abort, options);
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
    return .{ .text = text, .receipt = receipt, .system_one = scored.system_one };
}

fn buildScoredReceipt(
    allocator: std.mem.Allocator,
    kg: *client_mod.KgClient,
    conversation: *const conv_mod.Conversation,
    abort: *const AbortSignal,
    options: Options,
) !BuildResult {
    if (disabled()) return noInjection("disabled"); // escape hatch(解耦 KG)
    if (!kg.ready) return noInjection("kg_not_ready");
    const raw = lastUserText(conversation) orelse return noInjection("no_user_text");
    if (raw.len < MIN_QUERY_LEN) return noInjection("query_too_short"); // 琐碎轮不召回
    const query = raw[0..@min(raw.len, MAX_QUERY_LEN)]; // 上界截断
    const query_sha256 = sha256Hex(query);

    kg.setAbort(abort); // ESC 可中断
    // An advisor that does not advise this surface leaves the path as if absent.
    const advisor_here: ?*jev_advisor.Advisor = if (options.advisor) |advisor|
        (if (advisor.advises(.scoped_recall)) advisor else null)
    else
        null;
    const pool: usize = if (advisor_here != null) JUDGED_CANDIDATES else TOP_K;
    const hits = kg.recall(query, pool, false) catch return .{
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
    std.debug.assert(hits.len <= pool);
    // The receipt keeps its v1 meaning (hits the BM25 gate saw), so a shadow
    // run's receipt is byte-identical to a run without an advisor.
    const gate_visible = @min(hits.len, TOP_K);

    // 相关性门:top 分做绝对地板(答案缺席→0 条)+ 相对衰减(留 ≥top×REL)。
    var scores: [JUDGED_CANDIDATES]f64 = undefined;
    for (hits, 0..) |h, index| scores[index] = h.score;
    const top = scores[0];
    const floor = absFloor();
    const baseline = baselineSelection(scores[0..hits.len], floor);

    var selection = baseline;
    var system_one: ?SystemOneRecord = null;
    // Below the floor the judged policy injects nothing either, so the judge
    // is not consulted there: it would only add latency to every turn whose
    // memory is irrelevant.
    const consulted = if (baseline.len > 0) advisor_here else null;
    if (consulted) |advisor| {
        var candidates: [JUDGED_CANDIDATES]jev_advisor.RecallCandidate = undefined;
        for (hits, 0..) |h, index| candidates[index] = .{
            .type_label = hitType(h),
            .text = if (h.focus_text.len > 0) h.focus_text else h.text,
        };
        const judgment = try advisor.judgeRecallRelevance(allocator, abort, query, candidates[0..hits.len]);
        var record: SystemOneRecord = .{ .audit = judgment.audit, .baseline = baseline };
        for (hits, 0..) |h, index| record.node_ids[index] = h.node_id;
        if (judgment.answered()) {
            const judged = judgedSelection(judgment.percents[0..judgment.count], scores[0..judgment.count], baseline);
            @memcpy(record.percents[0..judgment.count], judgment.percents[0..judgment.count]);
            record.judged = @intCast(judgment.count);
            record.positive = judgment.countAtLeast(RELEVANCE_THRESHOLD_PERCENT);
            record.changed = selectionDelta(baseline, judged);
            record.judged_selection = judged;
            if (advisor.actuates()) {
                selection = judged;
                record.actuated = record.changed > 0;
            }
        }
        log.info("kg", "scoped_recall system_one mode={s} outcome={s} judged={d} relevant={d} changed={d} actuated={}", .{
            @tagName(record.audit.mode), @tagName(record.audit.outcome), record.judged, record.positive, record.changed, record.actuated,
        });
        system_one = record;
    }

    // The judged policy injects only when the floor passed, so an empty
    // selection always means the BM25 floor judged the answer absent.
    if (selection.len == 0) {
        log.info("kg", "scoped_recall injected=0 top_score={d:.2} (below floor {d:.2})", .{ top, floor });
        return .{
            .text = null,
            .receipt = .{
                .status = "below_floor",
                .query_sha256 = query_sha256,
                .result_count = gate_visible,
            },
            .system_one = system_one,
        }; // 最相关的都弱 → 判为答案缺席,不注入噪声
    }

    var out: std.ArrayList(u8) = .empty;
    // 无 errdefer(本函数返回 !?[]u8;分配失败走 error 路径,显式 deinit 防泄漏——Linus 抓的死 errdefer)。
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "<system-reminder>\n# 相关持久记忆(按你的请求自动召回,可能不全)\n");
    try out.appendSlice(allocator, retrieval_protocol.AUTO_RECALL_NOTE);
    try out.appendSlice(allocator, "\n");
    for (selection.slice()) |index| {
        const h = hits[index];
        const type_str = hitType(h);
        // 带来源的 hit(记忆 markdown)标注文件名:模型更新该文件而非另存(PM P0-2)。
        const line = if (h.source_label.len > 0)
            try std.fmt.allocPrint(allocator, "- [node_id={d} {s}:{s}] {s}\n", .{ h.node_id, type_str, h.source_label, firstLine(h.text) })
        else
            try std.fmt.allocPrint(allocator, "- [node_id={d} {s}] {s}\n", .{ h.node_id, type_str, firstLine(h.text) });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
    try out.appendSlice(allocator, retrieval_protocol.AUTO_RECALL_NEXT_ACTION);
    try out.appendSlice(allocator, "\n");
    try out.appendSlice(allocator, "</system-reminder>");

    const text = try out.toOwnedSlice(allocator);
    log.info("kg", "scoped_recall injected={d} top_score={d:.2} query_len={d}", .{ selection.len, top, query.len });
    return .{
        .text = text,
        .receipt = .{
            .status = "injected",
            .query_sha256 = query_sha256,
            .result_count = gate_visible,
            .injected_count = selection.len,
            .injected_bytes = text.len,
            .injection_sha256 = sha256Hex(text),
        },
        .system_one = system_one,
    };
}

fn hitType(hit: client_mod.RecallHit) []const u8 {
    return if (hit.schema_type.len > 0) hit.schema_type else hit.kind;
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
    if (end <= MAX_HIT_TEXT_BYTES) return text[0..end];
    // 不切半个 CJK 字。旧写法看切点前一字节，切进多字节字符时会留下孤立首字节:
    // 注入回执哈希的是坏字节，provider 收到的是 U+FFFD。
    return text[0..@import("../util/utf8.zig").prefixEnd(text, MAX_HIT_TEXT_BYTES)];
}

test "firstLine never ends inside a multi-byte character" {
    // Every cut position inside the three-byte "中" at the 320-byte limit.
    inline for (.{ 318, 319, 320 }) |ascii| {
        const text = "a" ** ascii ++ "中文 tail";
        const visible = firstLine(text);
        try std.testing.expect(visible.len <= MAX_HIT_TEXT_BYTES);
        try std.testing.expect(std.unicode.utf8ValidateSlice(visible));
    }
    try std.testing.expectEqual(@as(usize, 317 + 3), firstLine("a" ** 317 ++ "中文").len);
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
    try std.testing.expect((try build(a, &kg, &conv, &ab, .{})) == null);
}

test "baselineSelection keeps the BM25 floor and relative gate over the first TOP_K only" {
    // Below the floor: nothing, even if a later pool member scores high.
    try std.testing.expectEqual(@as(usize, 0), baselineSelection(&.{ 2.9, 2.0, 1.0, 9.0 }, 3.0).len);
    // Relative gate: 7.0 keeps >= 3.5.
    const kept = baselineSelection(&.{ 7.0, 4.0, 3.0, 6.9, 6.8 }, 3.0);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1 }, kept.slice());
    try std.testing.expectEqual(@as(usize, 0), baselineSelection(&.{}, 3.0).len);
}

test "judgedSelection never lets the judge pick outside the BM25 band" {
    const passed = baselineSelection(&.{ 9.0, 1.0, 1.0 }, 3.0);
    // The procedural-transfer failure: a sibling's diff the judge loves but
    // BM25 scores at 1/9 of the protocol memory stays out.
    const banded = judgedSelection(&.{ 27, 68, 19, 32, 19 }, &.{ 9.0, 1.0, 0.6, 0.6, 0.5 }, passed);
    try std.testing.expectEqualSlices(u8, &.{0}, banded.slice());
    // Inside the band the judge still reorders and filters.
    const inside = judgedSelection(&.{ 20, 90, 95 }, &.{ 9.0, 5.0, 4.0 }, passed);
    try std.testing.expectEqualSlices(u8, &.{1}, inside.slice());
}

test "judgedSelection ranks by judge and BM25 together and keeps candidates that clear the floor" {
    const passed = baselineSelection(&.{ 9.0, 8.0, 1.0 }, 3.0);
    const flat = [_]f64{1.0} ** 8;
    const selected = judgedSelection(&.{ 61, 12, 95, 61, 80, 3, 99, 40 }, &flat, passed);
    try std.testing.expectEqualSlices(u8, &.{ 6, 2, 4 }, selected.slice());
    // Equal fused scores keep BM25 rank order; a candidate below the floor is dropped.
    const tie = judgedSelection(&.{ 70, 70, 10 }, &.{ 5.0, 5.0, 5.0 }, passed);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1 }, tie.slice());
    // BM25 separates candidates the judge scores alike: 0.60 + 0.50 beats 0.65 + 0.30.
    const fused = judgedSelection(&.{ 60, 65 }, &.{ 10.0, 6.0 }, passed);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1 }, fused.slice());
    // Nothing clears the floor: the single best fused candidate remains.
    const weak = judgedSelection(&.{ 9, 30, 0 }, &.{ 9.0, 8.0, 1.0 }, passed);
    try std.testing.expectEqualSlices(u8, &.{1}, weak.slice());
    const bm25_top = judgedSelection(&.{ 10, 20, 0 }, &.{ 9.0, 1.0, 1.0 }, passed);
    try std.testing.expectEqualSlices(u8, &.{0}, bm25_top.slice());
    // The BM25 floor still decides that the answer is absent.
    try std.testing.expectEqual(@as(usize, 0), judgedSelection(&.{ 99, 99 }, &.{ 1.0, 1.0 }, .{}).len);
}

test "selectionDelta counts candidates only one policy injects" {
    const baseline = baselineSelection(&.{ 7.0, 6.0, 1.0 }, 3.0); // {0,1}
    try std.testing.expectEqual(@as(u32, 0), selectionDelta(baseline, baseline));
    const judged = judgedSelection(&.{ 90, 10, 10, 10, 85 }, &.{ 7.0, 6.0, 1.0, 1.0, 5.0 }, baseline); // {0,4}
    try std.testing.expectEqual(@as(u32, 2), selectionDelta(baseline, judged));
    try std.testing.expectEqual(@as(u32, 2), selectionDelta(baseline, .{}));
}
