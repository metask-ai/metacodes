//! KG 记忆工具:KgRemember / KgRecall / KgContext(设计 v3-final §5)。
//!
//! - KgRemember:写记忆节点(kind 白名单 + scope project/global + 近重复搭车提示
//!   + provenance session_id)。免审但**必出可见工具卡**(注册处 resultRenderMode
//!   禁 hidden——hidden 吞卡血泪)。
//! - KgRecall:BM25 检索 + 客户端过滤(domain 当前项目+global;默认排除任务面)。
//! - KgContext:候选节点权威正文分页 + 有界、版本化的本地图邻域，用于证据验证。
//! - degraded:结构化说明返回(不 spawn、不硬错、不撞熔断器)。

const std = @import("std");
const ToolContext = @import("context.zig").ToolContext;
const kg_mod = @import("../kg/client.zig");
const util_json = @import("../util/json.zig");
const common = @import("common.zig");
const log = @import("../util/log.zig");
const retrieval_protocol = @import("../kg/retrieval_protocol.zig");
const lexical_query_plan = @import("../kg/lexical_query_plan.zig");
const scoped_recall_mod = @import("../kg/scoped_recall.zig");

fn requireKg(ctx: *const ToolContext) ?*kg_mod.KgClient {
    return ctx.kg;
}

/// degraded/未就绪 → 结构化 JSON(recoverable=false 但语气引导,不算工具错误——
/// 返回正常 content,模型读到说明即止,不触发同错熔断)。
fn degradedResult(allocator: std.mem.Allocator, kg: ?*kg_mod.KgClient) ![]u8 {
    const msg = if (kg) |k| k.degradedMessage() else "KG 未配置(缺 tinykg 二进制)";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"kg_unavailable\":true,\"reason\":");
    try appendJsonString(&out, allocator, msg);
    try out.appendSlice(allocator, "}");
    return out.toOwnedSlice(allocator);
}

pub fn executeRemember(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const kg = requireKg(ctx) orelse return degradedResult(ctx.allocator, null);
    if (!kg.ready) return degradedResult(ctx.allocator, kg);
    kg.setAbort(ctx.abort); // M1:ESC 可中断 spawn

    const text = util_json.extractStringField(args, "text") orelse {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRemember 缺少必填字段 text", .{});
        return error.MissingText;
    };
    const text_owned = try util_json.unescapeString(text, ctx.allocator);
    defer ctx.allocator.free(text_owned);
    if (std.mem.trim(u8, text_owned, " \t\r\n").len == 0) {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRemember text 为空", .{});
        return error.MissingText;
    }

    // 记忆类型 → (node kind, schema_type)。**项目本体演化**:内置基类型全局共用,项目可引入
    // 自定义类型(observation node + 自定义 schema_type,由 tinykg 项目级 schema 按 project 治理)。
    // concept 仍拒绝(催收池转世);空/非法字符/保留字拒绝,不静默。
    const resolved: kg_mod.ResolvedType = blk: {
        const raw = util_json.extractStringField(args, "kind") orelse break :blk .{ .node_kind = .observation, .schema_type = "observation" };
        break :blk kg_mod.resolveMemoryType(raw) orelse {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "kind 非法:基类型 decision|user_preference|module|bug|observation,或自定义类型(字母数字/_-:.、≤64字符);不接受 concept 或空/特殊字符", .{});
            return error.InvalidKind;
        };
    };
    const scope_global = blk: {
        const raw = util_json.extractStringField(args, "scope") orelse break :blk false;
        break :blk std.ascii.eqlIgnoreCase(raw, "global");
    };

    // 近重复搭车门(设计 §5):写前 recall,top1 **文本**与新文本高度重合时附提示——不硬拦。
    // 用文本比对而非 BM25 分数:实测 BM25 分数随语料规模变化(1 节点 9.8、2 节点 21),
    // 绝对阈值不可靠(Linus M4)。文本归一化重合是尺度无关的确定性信号。
    var dup_note: ?[]u8 = null;
    defer if (dup_note) |n| ctx.allocator.free(n);
    if (kg.recall(text_owned, 3, false)) |hits| {
        defer {
            // kg 内存契约:hits 是 kg.allocator 分的(subagent 线程 ctx.allocator 不同源)。
            for (hits) |*h| h.deinit(kg.allocator);
            kg.allocator.free(hits);
        }
        for (hits) |h| {
            if (isNearDuplicate(text_owned, h.text)) {
                dup_note = try std.fmt.allocPrint(ctx.allocator, "已有高度相似记忆 node {d},若为同一事实请考虑更新而非新增", .{h.node_id});
                break;
            }
        }
    } else |_| {} // 近重复检查失败不阻塞写入

    // 写侧类型分布埋点(PM:kill-criterion 的 load-bearing 仪器,measure observation 是否仍霸榜)。
    log.info("kg", "kg_remember type={s}", .{resolved.schema_type});
    const node_id = kg.remember(resolved.node_kind, text_owned, resolved.schema_type, scope_global) catch |e| {
        return kgErrorResult(ctx, kg, e, "KgRemember");
    };
    // provenance(best-effort)。
    const sid = ctx.session.asSlice();
    if (sid.len > 0) kg.tagProvenance(node_id, sid);
    // 溯源(乙方案第4条):任务执行中沉淀的记忆回链任务——本 session 有进行中的 kg 任务
    // 时挂 derived_from(记忆是任务的产物;task-ancestry/packet 双向可导航)。best-effort。
    if (activeKgTaskId(ctx)) |task_id| {
        kg.addEdge(node_id, "derived_from", task_id) catch {};
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    const head = try std.fmt.allocPrint(ctx.allocator, "{{\"remembered\":{{\"node_id\":{d},\"type\":\"{s}\",\"scope\":\"{s}\"}}", .{ node_id, resolved.schema_type, if (scope_global) "global" else "project" });
    defer ctx.allocator.free(head);
    try out.appendSlice(ctx.allocator, head);
    if (dup_note) |n| {
        try out.appendSlice(ctx.allocator, ",\"note\":");
        try appendJsonString(&out, ctx.allocator, n);
    }
    try out.appendSlice(ctx.allocator, "}");
    return out.toOwnedSlice(ctx.allocator);
}

/// 本 session 进行中的 kg 任务(store 镜像里 status=in_progress 且 id 形如 kg-<n>)。
/// 溯源锚:记忆/文档产物 derived_from 它。多个 in_progress 取第一个(主任务惯例)。
fn activeKgTaskId(ctx: *const ToolContext) ?u64 {
    const store = ctx.tasks orelse return null;
    for (store.tasks.items) |t| {
        if (t.status != .in_progress) continue;
        if (!std.mem.startsWith(u8, t.id, "kg-")) continue;
        return std.fmt.parseInt(u64, t.id["kg-".len..], 10) catch continue;
    }
    return null;
}

pub fn executeRecall(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const kg = requireKg(ctx) orelse return degradedResult(ctx.allocator, null);
    if (!kg.ready) return degradedResult(ctx.allocator, kg);
    kg.setAbort(ctx.abort); // M1:ESC 可中断 spawn

    var parsed_args = std.json.parseFromSlice(std.json.Value, ctx.allocator, args, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall 参数必须是合法 JSON object", .{});
            return error.InvalidArguments;
        },
    };
    defer parsed_args.deinit();
    if (parsed_args.value != .object) {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall 参数必须是合法 JSON object", .{});
        return error.InvalidArguments;
    }
    const object = parsed_args.value.object;
    const query_value = object.get("query") orelse {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall 缺少必填字段 query", .{});
        return error.MissingQuery;
    };
    if (query_value != .string) {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall query 必须是字符串", .{});
        return error.InvalidQuery;
    }
    const query = std.mem.trim(u8, query_value.string, " \t\r\n");
    if (!validRecallQuery(query)) {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall query 必须是 1..400 字节的 UTF-8 紧凑查询", .{});
        return error.InvalidQuery;
    }

    // 可选 type 过滤:归一化 + 集合校验,菜单外报错**不静默空返**(Linus MEDIUM-1)。
    var type_canon: ?[]const u8 = null;
    if (object.get("type")) |raw| {
        if (raw != .string) {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall type 必须是字符串", .{});
            return error.InvalidType;
        }
        const resolved = kg_mod.resolveMemoryType(raw.string) orelse {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "type 必须是 decision|user_preference|module|bug|observation 之一", .{});
            return error.InvalidType;
        };
        type_canon = resolved.schema_type;
    }

    var plan = lexical_query_plan.parse(ctx.allocator, object, query, type_canon) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall lexical_plan 非法: {s}", .{lexical_query_plan.diagnostic(err)});
        return error.InvalidLexicalPlan;
    };
    defer if (plan) |*value| value.deinit(ctx.allocator);

    // Do not trust model-declared seen ids. A governed plan must bind to the
    // run-scoped host ledger before TinyKG is touched; legacy query-only calls
    // intentionally preserve their old behavior.
    var ledger_guard: ?lexical_query_plan.Ledger.Guard = null;
    var ledger_seen_count: usize = 0;
    var ledger_scope: []const u8 = "agent_run_plan";
    defer if (ledger_guard) |*guard| guard.deinit();
    if (plan) |value| {
        const ledger = ctx.kg_lexical_ledger orelse {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall lexical_plan requires the session host ledger; governed information-gain metrics fail closed when it is unavailable", .{});
            return error.LexicalPlanLedgerUnavailable;
        };
        ledger_guard = ledger.lockPlan(value) catch |err| {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall lexical_plan host ledger rejected the call: {s}", .{lexical_query_plan.ledgerDiagnostic(err)});
            return error.InvalidLexicalPlanState;
        };
        ledger_seen_count = ledger_guard.?.seenCount();
        ledger_scope = ledger_guard.?.scope();
    }
    // 采用率埋点(PM:kill-criterion 的 load-bearing 仪器,measure 模型是否用 --type)。
    const plan_version = if (plan) |value| value.schema_version.text() else "query-only";
    log.info("kg", "kg_recall type_filter={s} lexical_plan={s}", .{ type_canon orelse "none", plan_version });

    // v36 读平面 supersede(p36 取证:毒经 6 次主动 KgRecall 绕过注入面):
    // 静默态已证工件的定义符号——提及它们的记忆命中盖 provenance 戳。
    var sym_storage: [scoped_recall_mod.MAX_SUPERSEDED_SYMBOLS][64]u8 = undefined;
    var sym_lens: [scoped_recall_mod.MAX_SUPERSEDED_SYMBOLS]usize = undefined;
    var sym_slices: [scoped_recall_mod.MAX_SUPERSEDED_SYMBOLS][]const u8 = undefined;
    var sym_count: usize = 0;
    if (std.c.getenv("METACODES_TASK_HINT")) |hint_c| {
        sym_count = scoped_recall_mod.artifactSupersededSymbols(
            ctx.allocator,
            kg,
            std.mem.span(hint_c),
            &sym_storage,
            &sym_lens,
        );
        for (0..sym_count) |i| sym_slices[i] = sym_storage[i][0..sym_lens[i]];
    }
    const superseded_symbols: []const []const u8 = sym_slices[0..sym_count];

    if (plan) |value| {
        if (value.executesAll()) {
            return executeRecallBatch(
                ctx,
                kg,
                value,
                type_canon,
                &ledger_guard.?,
                ledger_scope,
                ledger_seen_count,
                superseded_symbols,
            );
        }
    }

    // A recovered v3 seed executes the declared exact/alias text, never the
    // redundant compatibility query. v1/v2 already require the two to match.
    const effective_query = if (plan) |value| value.selected().text else query;
    const hits = kg.recallTyped(effective_query, 8, false, type_canon) catch |e| {
        return kgErrorResult(ctx, kg, e, "KgRecall");
    };
    defer {
        // kg 内存契约:hits 是 kg.allocator 分的(subagent 线程 ctx.allocator 不同源)。
        for (hits) |*h| h.deinit(kg.allocator);
        kg.allocator.free(hits);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    var new_hit_count: usize = 0;
    var repeated_hit_count: usize = 0;
    var hit_ids: [lexical_query_plan.MAX_SEEN_NODE_IDS]u64 = [_]u64{0} ** lexical_query_plan.MAX_SEEN_NODE_IDS;
    if (hits.len > hit_ids.len) {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall returned more hits than the governed 32-node ledger can represent", .{});
        return error.InvalidLexicalPlanState;
    }
    try out.appendSlice(ctx.allocator, "{\"hits\":[");
    for (hits, 0..) |h, i| {
        hit_ids[i] = h.node_id;
        if (i > 0) try out.appendSlice(ctx.allocator, ",");
        var seen_before = false;
        if (ledger_guard) |*guard| {
            seen_before = guard.wasSeen(h.node_id);
            const duplicate_in_batch = containsNodeId(hit_ids[0..i], h.node_id);
            if (!duplicate_in_batch) {
                if (seen_before) {
                    repeated_hit_count += 1;
                } else {
                    new_hit_count += 1;
                }
            }
        }
        const compact_repeat = if (plan) |value|
            (value.schema_version == .host_managed_v2 or value.isSeedShapeRewrite()) and seen_before
        else
            false;
        if (compact_repeat) {
            const row = try std.fmt.allocPrint(ctx.allocator, "{{\"node_id\":{d},\"seen_before\":true,\"content_ref\":\"exposed_elsewhere_in_run\"}}", .{h.node_id});
            defer ctx.allocator.free(row);
            try out.appendSlice(ctx.allocator, row);
            continue;
        }
        try appendRecallHitRow(&out, ctx.allocator, h, seen_before, ledger_guard != null, SINGLE_RECALL_HIT_TEXT_BYTES, superseded_symbols);
    }
    // 搭车 facet(PM:可见性,零额外调用):结果里各类型计数,让模型知道有哪些类型 → 可 --type 精化。
    const known_types = [_][]const u8{ "decision", "module", "bug", "user_preference", "observation" };
    var facet: std.ArrayList(u8) = .empty;
    defer facet.deinit(ctx.allocator);
    var facet_first = true;
    for (known_types) |tname| {
        var c: usize = 0;
        for (hits) |h| {
            if (std.mem.eql(u8, h.schema_type, tname)) c += 1;
        }
        if (c == 0) continue;
        if (!facet_first) try facet.appendSlice(ctx.allocator, ",");
        facet_first = false;
        const kv = try std.fmt.allocPrint(ctx.allocator, "\"{s}\":{d}", .{ tname, c });
        defer ctx.allocator.free(kv);
        try facet.appendSlice(ctx.allocator, kv);
    }
    try out.appendSlice(ctx.allocator, "],\"count\":");
    const count = try std.fmt.allocPrint(ctx.allocator, "{d}", .{hits.len});
    defer ctx.allocator.free(count);
    try out.appendSlice(ctx.allocator, count);
    try out.appendSlice(ctx.allocator, ",\"types_in_results\":{");
    try out.appendSlice(ctx.allocator, facet.items);
    try out.append(ctx.allocator, '}');
    if (plan) |value| {
        if (value.isSeedShapeRewrite()) {
            try appendSeedShapeRewriteReceipt(
                &out,
                ctx.allocator,
                value,
                ledger_scope,
                ledger_seen_count,
                hit_ids[0..hits.len],
                new_hit_count,
                repeated_hit_count,
            );
        } else {
            try appendLexicalPlanReceipt(&out, ctx.allocator, value, ledger_scope, ledger_seen_count, new_hit_count, repeated_hit_count);
        }
    }
    try appendRecallEnvelope(&out, ctx.allocator);
    try out.appendSlice(ctx.allocator, ",\"retrieval_mode\":\"lexical_bm25_no_embeddings\",\"knowledge_status\":\"unverified_candidates\",\"lexical_guidance\":");
    try appendJsonString(&out, ctx.allocator, retrieval_protocol.RESULT_GUIDANCE);
    const tail = "}";
    try out.appendSlice(ctx.allocator, tail);
    const owned = try out.toOwnedSlice(ctx.allocator);
    errdefer ctx.allocator.free(owned);
    if (owned.len > MAX_RECALL_RESULT_BYTES) {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall bounded envelope exceeded its {d}-byte contract", .{MAX_RECALL_RESULT_BYTES});
        return error.RecallEnvelopeTooLarge;
    }
    if (ledger_guard) |*guard| {
        guard.commit(hit_ids[0..hits.len]) catch |err| {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall lexical_plan host ledger could not commit the observed hits: {s}", .{lexical_query_plan.ledgerDiagnostic(err)});
            return error.InvalidLexicalPlanState;
        };
    }
    return owned;
}

fn validRecallQuery(query: []const u8) bool {
    if (query.len == 0 or query.len > lexical_query_plan.MAX_QUERY_BYTES or !std.unicode.utf8ValidateSlice(query)) return false;
    for (query) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn containsNodeId(values: []const u64, expected: u64) bool {
    for (values) |value| if (value == expected) return true;
    return false;
}

const BatchVariantReceipt = struct {
    node_ids: [8]u64 = [_]u64{0} ** 8,
    node_count: usize = 0,
    new_hit_count: usize = 0,
    repeated_hit_count: usize = 0,
};

/// Keep the complete versioned JSON below the generic tool-result projection
/// threshold. Raising that threshold would only move the cache/context failure;
/// KgRecall owns its provider-visible information budget instead.
pub const MAX_RECALL_RESULT_BYTES: usize = 24 * 1024;
const SINGLE_RECALL_HIT_TEXT_BYTES: usize = 512;
const AUTO_CONTEXT_TEXT_BYTES: usize = 2000;
const AUTO_CONTEXT_EDGES: usize = 6;

fn batchHitTextBytes(index: usize) usize {
    if (index < 4) return 640;
    if (index < 8) return 384;
    return 160;
}

/// Execute every member of a v3 plan under one host-ledger guard. TinyKG reads
/// remain ordered and read-only; the model receives one merged result envelope,
/// each node body at most once, plus replayable per-variant node-id receipts.
/// This deliberately does not claim a cross-query snapshot: a shared daemon
/// may accept a writer between probes, so freshness is rechecked via KgContext.
fn executeRecallBatch(
    ctx: *const ToolContext,
    kg: *kg_mod.KgClient,
    plan: lexical_query_plan.Plan,
    type_canon: ?[]const u8,
    guard: *lexical_query_plan.Ledger.Guard,
    ledger_scope: []const u8,
    ledger_seen_count: usize,
    superseded_symbols: []const []const u8,
) anyerror![]u8 {
    std.debug.assert(plan.schema_version == .host_batch_v3);
    std.debug.assert(plan.executesAll());

    var hit_rows: std.ArrayList(u8) = .empty;
    defer hit_rows.deinit(ctx.allocator);
    var receipts = [_]BatchVariantReceipt{.{}} ** lexical_query_plan.MAX_VARIANTS;
    var merged_ids: [lexical_query_plan.MAX_SEEN_NODE_IDS]u64 = [_]u64{0} ** lexical_query_plan.MAX_SEEN_NODE_IDS;
    var merged_count: usize = 0;
    var merged_new_count: usize = 0;
    var merged_previously_seen_count: usize = 0;
    var probe_new_count: usize = 0;
    var probe_repeated_count: usize = 0;
    var first_new_node_id: u64 = 0;
    var first_new_evidence_node_id: u64 = 0;
    const known_types = [_][]const u8{ "decision", "module", "bug", "user_preference", "observation" };
    var facet_counts = [_]usize{0} ** known_types.len;

    for (plan.variants, 0..) |variant, variant_index| {
        const hits = kg.recallTyped(variant.text, 8, false, type_canon) catch |e| {
            return kgErrorResult(ctx, kg, e, "KgRecall");
        };
        defer {
            for (hits) |*hit| hit.deinit(kg.allocator);
            kg.allocator.free(hits);
        }
        var receipt = &receipts[variant_index];
        for (hits) |hit| {
            if (containsNodeId(receipt.node_ids[0..receipt.node_count], hit.node_id)) continue;
            if (receipt.node_count == receipt.node_ids.len) {
                common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall batch variant returned more than eight distinct hits", .{});
                return error.InvalidLexicalPlanState;
            }
            receipt.node_ids[receipt.node_count] = hit.node_id;
            receipt.node_count += 1;

            const seen_before_run = guard.wasSeen(hit.node_id);
            const seen_earlier_in_batch = containsNodeId(merged_ids[0..merged_count], hit.node_id);
            if (seen_before_run or seen_earlier_in_batch) {
                receipt.repeated_hit_count += 1;
                probe_repeated_count += 1;
            } else {
                receipt.new_hit_count += 1;
                probe_new_count += 1;
            }
            if (seen_earlier_in_batch) continue;
            if (merged_count == merged_ids.len) {
                common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall batch exceeded the governed 32-node merged-result bound", .{});
                return error.InvalidLexicalPlanState;
            }
            if (merged_count > 0) try hit_rows.append(ctx.allocator, ',');
            merged_ids[merged_count] = hit.node_id;
            merged_count += 1;
            if (seen_before_run) {
                merged_previously_seen_count += 1;
                const row = try std.fmt.allocPrint(ctx.allocator, "{{\"node_id\":{d},\"seen_before\":true,\"content_ref\":\"exposed_elsewhere_in_run\"}}", .{hit.node_id});
                defer ctx.allocator.free(row);
                try hit_rows.appendSlice(ctx.allocator, row);
            } else {
                merged_new_count += 1;
                if (first_new_node_id == 0) first_new_node_id = hit.node_id;
                const exposed_type = if (hit.schema_type.len > 0) hit.schema_type else hit.kind;
                if (first_new_evidence_node_id == 0 and std.mem.eql(u8, exposed_type, "evidence")) {
                    first_new_evidence_node_id = hit.node_id;
                }
                try appendRecallHitRow(&hit_rows, ctx.allocator, hit, false, true, batchHitTextBytes(merged_count - 1), superseded_symbols);
            }
            const type_str = if (hit.schema_type.len > 0) hit.schema_type else hit.kind;
            for (known_types, 0..) |type_name, facet_index| {
                if (std.mem.eql(u8, type_str, type_name)) facet_counts[facet_index] += 1;
            }
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator, "{\"hits\":[");
    try out.appendSlice(ctx.allocator, hit_rows.items);
    try out.appendSlice(ctx.allocator, "],\"count\":");
    try out.print(ctx.allocator, "{d},\"types_in_results\":{{", .{merged_count});
    var facet_first = true;
    for (known_types, facet_counts) |type_name, count| {
        if (count == 0) continue;
        if (!facet_first) try out.append(ctx.allocator, ',');
        facet_first = false;
        try out.print(ctx.allocator, "\"{s}\":{d}", .{ type_name, count });
    }
    try out.appendSlice(ctx.allocator, "},\"lexical_query_plan\":{");
    try out.print(
        ctx.allocator,
        "\"schema_version\":\"{s}\",\"plan_sha256\":\"{s}\",\"intent\":\"{s}\",\"stage\":\"{s}\",\"variant_count\":{d},\"executed_variant_count\":{d},\"all_variants_executed\":true,\"seen_node_count\":{d},\"seen_state_verified\":true,\"ledger_scope\":\"{s}\",\"merged_hit_count\":{d},\"merged_new_hit_count\":{d},\"merged_previously_seen_count\":{d},\"probe_new_hit_count\":{d},\"probe_repeated_hit_count\":{d},\"query_anchor_rewritten\":{s},\"query_anchor_input_sha256\":\"{s}\",\"query_anchor_effective_sha256\":\"{s}\",\"variant_receipts\":[",
        .{ plan.schema_version.text(), plan.fingerprint, @tagName(plan.intent), @tagName(plan.stage), plan.variants.len, plan.variants.len, ledger_seen_count, ledger_scope, merged_count, merged_new_count, merged_previously_seen_count, probe_new_count, probe_repeated_count, if (plan.query_anchor_rewritten) "true" else "false", plan.query_anchor_input_sha256, plan.query_anchor_effective_sha256 },
    );
    for (plan.variants, 0..) |variant, variant_index| {
        if (variant_index > 0) try out.append(ctx.allocator, ',');
        const receipt = receipts[variant_index];
        try out.print(
            ctx.allocator,
            "{{\"variant_index\":{d},\"variant_kind\":\"{s}\",\"node_ids\":[",
            .{ variant_index, @tagName(variant.kind) },
        );
        for (receipt.node_ids[0..receipt.node_count], 0..) |node_id, node_index| {
            if (node_index > 0) try out.append(ctx.allocator, ',');
            try out.print(ctx.allocator, "{d}", .{node_id});
        }
        try out.print(
            ctx.allocator,
            "],\"new_hit_count\":{d},\"repeated_hit_count\":{d}}}",
            .{ receipt.new_hit_count, receipt.repeated_hit_count },
        );
    }
    try out.appendSlice(ctx.allocator, "],\"execution\":\"host_batch_all\"}");
    try appendRecallEnvelope(&out, ctx.allocator);
    try out.appendSlice(ctx.allocator, ",\"retrieval_mode\":\"lexical_bm25_no_embeddings\",\"knowledge_status\":\"unverified_candidates\",\"lexical_guidance\":");
    try appendJsonString(&out, ctx.allocator, retrieval_protocol.RESULT_GUIDANCE);
    // Enumeration needs one real graph re-observation, but spending a whole
    // provider turn merely to ask the model to echo a recalled node_id is pure
    // orchestration tax. Deterministically build the exact KgContext result in
    // the same tool envelope before committing either observation. Selection
    // prefers newly exposed evidence, then any new node, then the first merged
    // node. This does not decide truth; it only removes model-owned parameter
    // reconstruction from the governance read.
    var auto_context_node_id: ?u64 = null;
    if (plan.intent == .enumeration and plan.stage == .semantic_expansion and merged_count > 0) {
        const context_node_id = if (first_new_evidence_node_id != 0)
            first_new_evidence_node_id
        else if (first_new_node_id != 0)
            first_new_node_id
        else
            merged_ids[0];
        const context_args = try std.fmt.allocPrint(
            ctx.allocator,
            "{{\"node_id\":{d},\"limit\":{d},\"text_limit\":{d}}}",
            .{ context_node_id, AUTO_CONTEXT_EDGES, AUTO_CONTEXT_TEXT_BYTES },
        );
        defer ctx.allocator.free(context_args);
        const context_observation = try executeContextObserved(ctx, context_args);
        defer ctx.allocator.free(context_observation.result);
        try out.appendSlice(ctx.allocator, ",\"auto_context\":{\"schema_version\":\"metacodes-auto-context-v1\",\"selection_policy\":\"first_new_evidence_then_new_then_merged_v1\",\"context\":");
        try out.appendSlice(ctx.allocator, context_observation.result);
        try out.append(ctx.allocator, '}');
        auto_context_node_id = context_observation.observed_node_id;
    }
    try out.append(ctx.allocator, '}');

    const owned = try out.toOwnedSlice(ctx.allocator);
    errdefer ctx.allocator.free(owned);
    if (owned.len > MAX_RECALL_RESULT_BYTES) {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall bounded envelope exceeded its {d}-byte contract", .{MAX_RECALL_RESULT_BYTES});
        return error.RecallEnvelopeTooLarge;
    }
    // Commit only after every provider-visible byte, including auto_context,
    // has been constructed. Otherwise an OOM/protocol failure after commit
    // would mark node bodies as exposed even though the tool result was lost.
    guard.commitWithContext(merged_ids[0..merged_count], auto_context_node_id) catch |err| {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall lexical_plan host ledger could not commit the observed batch: {s}", .{lexical_query_plan.ledgerDiagnostic(err)});
        return error.InvalidLexicalPlanState;
    };
    return owned;
}

/// v36 读平面 supersede 判定(纯函数,L2 直测):非结局行命中提及任一
/// 已证工件定义符号 → 该记忆被 host_run 工件取代,须盖 provenance 戳。
/// 结局行(task_outcome)本身携带裁决,永不盖戳。
pub fn hitSupersededByArtifact(
    superseded_symbols: []const []const u8,
    hit_text: []const u8,
    hit_type: []const u8,
) bool {
    if (superseded_symbols.len == 0) return false;
    if (std.mem.eql(u8, hit_type, "task_outcome")) return false;
    for (superseded_symbols) |sym| {
        if (std.mem.indexOf(u8, hit_text, sym) != null) return true;
    }
    return false;
}

pub const SUPERSEDED_CAVEAT =
    "superseded_by_host_run_artifact: a host-run all-passing verdict for " ++
    "this task proves a specific artifact that defines the symbols this " ++
    "memory mentions; where this memory contradicts that artifact, the " ++
    "artifact wins (host_run outranks stored claims)";

/// v44 硬性撤回(etag 取证 KG 12738):v36 的 caveat 只是给冲突记忆加一行
/// 注解, 把裁决权交回模型——实测两次败于同一形态(p35 与 e2-dev):模型读到
/// caveat、复述了"已证配置胜出", 随后仍改主意采信冲突记忆, 同一分数 0.2727
/// 撞墙两次。既然 host_run 全过裁决在证据位阶上高于存量声明, 就不该把该
/// 声明的正文继续摆进上下文让模型权衡——正文换成撤回存根, 只留 node_id
/// 供显式取回。这不是删除记忆(库中原样保留), 是读平面的证据位阶执行。
/// Lean 镜面 withdrawn_carries_no_claim。
pub const SUPERSEDED_WITHDRAWN_TEXT =
    "[withdrawn by host-run artifact] this stored memory names symbols that " ++
    "a host-run all-passing verdict for this task defines differently. Its " ++
    "body is withheld because it has twice been followed over the proven " ++
    "artifact. Follow the artifact quoted in the attempt-history note. If " ++
    "you truly need this memory's body, fetch it explicitly by node_id.";

pub fn appendRecallHitRow(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    hit: kg_mod.RecallHit,
    seen_before: bool,
    include_seen: bool,
    max_text_bytes: usize,
    superseded_symbols: []const []const u8,
) !void {
    const type_str = if (hit.schema_type.len > 0) hit.schema_type else hit.kind;
    const row = try std.fmt.allocPrint(allocator, "{{\"node_id\":{d},\"type\":\"{s}\",\"scope\":\"{s}\",\"score\":{d:.2},\"text\":", .{
        hit.node_id, type_str, if (std.mem.eql(u8, hit.domain, "global")) "global" else "project", hit.score,
    });
    defer allocator.free(row);
    try out.appendSlice(allocator, row);
    // The budget is provider-visible JSON payload bytes, not merely decoded
    // source bytes. Control characters can expand 6x when escaped; budgeting
    // before serialization would recreate the oversized-result failure with
    // perfectly valid TinyKG text.
    // v44:被已证工件取代的记忆, 正文以撤回存根替代(证据位阶执行)。
    const superseded = hitSupersededByArtifact(superseded_symbols, hit.text, type_str);
    const excerpt = if (superseded)
        try allocator.dupe(u8, SUPERSEDED_WITHDRAWN_TEXT)
    else
        try boundedJsonTextExcerptAlloc(allocator, hit.text, max_text_bytes);
    defer allocator.free(excerpt);
    try appendJsonString(out, allocator, excerpt);
    const text_total_bytes = if (hit.text_total_bytes > 0) hit.text_total_bytes else hit.text.len;
    const text_truncated = hit.text_truncated or excerpt.len < hit.text.len;
    try out.print(
        allocator,
        ",\"text_returned_bytes\":{d},\"text_total_bytes\":{d},\"text_truncated\":{s},\"text_excerpt_policy\":\"utf8_head_tail_v1\"",
        .{ excerpt.len, text_total_bytes, if (text_truncated) "true" else "false" },
    );
    if (hit.source_label.len > 0) {
        try out.appendSlice(allocator, ",\"source\":");
        const source_excerpt = try boundedJsonTextExcerptAlloc(allocator, hit.source_label, 256);
        defer allocator.free(source_excerpt);
        try appendJsonString(out, allocator, source_excerpt);
        if (source_excerpt.len < hit.source_label.len) try out.appendSlice(allocator, ",\"source_truncated\":true");
    }
    if (include_seen) try out.appendSlice(allocator, if (seen_before) ",\"seen_before\":true" else ",\"seen_before\":false");
    if (superseded) {
        try out.appendSlice(allocator, ",\"provenance_caveat\":");
        try appendJsonString(out, allocator, SUPERSEDED_CAVEAT);
        try out.appendSlice(allocator, ",\"body_withheld\":true");
    }
    try out.append(allocator, '}');
}

fn appendRecallEnvelope(out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try out.print(
        allocator,
        ",\"recall_envelope\":{{\"schema_version\":\"metacodes-bounded-recall-v1\",\"complete_json\":true,\"max_result_bytes\":{d},\"text_excerpt_policy\":\"utf8_head_tail_v1\"}}",
        .{MAX_RECALL_RESULT_BYTES},
    );
}

fn appendLexicalPlanReceipt(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    plan: lexical_query_plan.Plan,
    ledger_scope: []const u8,
    seen_node_count: usize,
    new_hit_count: usize,
    repeated_hit_count: usize,
) !void {
    const variant_index = switch (plan.execution) {
        .single => |index| index,
        .batch_all, .seed_shape_rewrite => unreachable,
    };
    const selected = plan.selected();
    const receipt = try std.fmt.allocPrint(
        allocator,
        ",\"lexical_query_plan\":{{\"schema_version\":\"{s}\",\"plan_sha256\":\"{s}\",\"intent\":\"{s}\",\"stage\":\"{s}\",\"variant_index\":{d},\"variant_count\":{d},\"variant_kind\":\"{s}\",\"seen_node_count\":{d},\"seen_state_verified\":true,\"ledger_scope\":\"{s}\",\"new_hit_count\":{d},\"repeated_hit_count\":{d}}}",
        .{
            plan.schema_version.text(),
            plan.fingerprint,
            @tagName(plan.intent),
            @tagName(plan.stage),
            variant_index,
            plan.variants.len,
            @tagName(selected.kind),
            seen_node_count,
            ledger_scope,
            new_hit_count,
            repeated_hit_count,
        },
    );
    defer allocator.free(receipt);
    try out.appendSlice(allocator, receipt);
}

/// Emit a proof-carrying recovery receipt for the safe malformed v3 shapes:
/// semantic_expansion prefixed by an exact seed, or a seed carrying trailing
/// semantic declarations. The receipt
/// binds the complete input plan, the effective seed plan, and every omitted
/// semantic declaration. `all_variants_executed=false` is load-bearing: this
/// call can establish a seed but can never satisfy enumeration coverage.
fn appendSeedShapeRewriteReceipt(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    plan: lexical_query_plan.Plan,
    ledger_scope: []const u8,
    seen_node_count: usize,
    hit_ids: []const u64,
    new_hit_count: usize,
    repeated_hit_count: usize,
) !void {
    const rewrite = plan.seed_shape_rewrite orelse unreachable;
    const seed = plan.selected();
    var distinct_ids: [8]u64 = [_]u64{0} ** 8;
    var distinct_count: usize = 0;
    for (hit_ids) |node_id| {
        if (containsNodeId(distinct_ids[0..distinct_count], node_id)) continue;
        std.debug.assert(distinct_count < distinct_ids.len);
        distinct_ids[distinct_count] = node_id;
        distinct_count += 1;
    }

    try out.print(
        allocator,
        ",\"lexical_query_plan\":{{\"schema_version\":\"{s}\",\"plan_sha256\":\"{s}\",\"intent\":\"{s}\",\"stage\":\"{s}\",\"variant_count\":{d},\"executed_variant_count\":1,\"all_variants_executed\":false,\"seen_node_count\":{d},\"seen_state_verified\":true,\"ledger_scope\":\"{s}\",\"merged_hit_count\":{d},\"merged_new_hit_count\":{d},\"merged_previously_seen_count\":{d},\"probe_new_hit_count\":{d},\"probe_repeated_hit_count\":{d},\"query_anchor_rewritten\":{s},\"query_anchor_input_sha256\":\"{s}\",\"query_anchor_effective_sha256\":\"{s}\",\"variant_receipts\":[{{\"variant_index\":0,\"variant_kind\":\"{s}\",\"node_ids\":[",
        .{
            plan.schema_version.text(),
            rewrite.input_plan_sha256,
            @tagName(plan.intent),
            @tagName(rewrite.input_stage),
            rewrite.declared_variant_count,
            seen_node_count,
            ledger_scope,
            distinct_count,
            new_hit_count,
            repeated_hit_count,
            new_hit_count,
            repeated_hit_count,
            if (plan.query_anchor_rewritten) "true" else "false",
            plan.query_anchor_input_sha256,
            plan.query_anchor_effective_sha256,
            @tagName(seed.kind),
        },
    );
    for (distinct_ids[0..distinct_count], 0..) |node_id, index| {
        if (index > 0) try out.append(allocator, ',');
        try out.print(allocator, "{d}", .{node_id});
    }
    try out.print(
        allocator,
        "],\"new_hit_count\":{d},\"repeated_hit_count\":{d}}}],\"execution\":\"host_seed_shape_rewrite\",\"rewrite\":{{\"schema_version\":\"{s}\",\"reason\":\"{s}\",\"input_plan_sha256\":\"{s}\",\"effective_plan_sha256\":\"{s}\",\"effective_seed_sha256\":\"{s}\",\"input_stage\":\"{s}\",\"effective_stage\":\"seed\",\"declared_variant_count\":{d},\"executed_variant_count\":1,\"unexecuted_semantic_variant_count\":{d}}}}}",
        .{
            new_hit_count,
            repeated_hit_count,
            lexical_query_plan.SEED_SHAPE_REWRITE_SCHEMA_VERSION,
            rewrite.reason,
            rewrite.input_plan_sha256,
            plan.fingerprint,
            rewrite.effective_seed_sha256,
            @tagName(rewrite.input_stage),
            rewrite.declared_variant_count,
            rewrite.unexecuted_semantic_variant_count,
        },
    );
}

const DEFAULT_CONTEXT_EDGES: usize = 12;
const MAX_CONTEXT_EDGES: usize = 20;
const DEFAULT_TEXT_BYTES: usize = 6000;
const MAX_TEXT_BYTES: usize = 12000;
const MAX_GRAPH_BYTES: usize = 64 * 1024;

/// 读取一个候选节点的权威正文页 + 有界本地图邻域。检索与遍历分开：KgRecall 找种子，
/// KgContext 验证种子和 evidence；不能让模型仅凭 BM25 摘要或边名下结论。
pub fn executeContext(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const observation = try executeContextObserved(ctx, args);
    if (observation.observed_node_id) |node_id| {
        if (ctx.kg_lexical_ledger) |ledger| _ = ledger.commitContext(node_id);
    }
    return observation.result;
}

const ContextObservation = struct {
    result: []u8,
    /// Set only after both real TinyKG reads and the complete result body
    /// succeed. Degraded output is useful to the model but is not evidence.
    observed_node_id: ?u64 = null,
};

fn executeContextObserved(ctx: *const ToolContext, args: []const u8) anyerror!ContextObservation {
    const kg = requireKg(ctx) orelse return .{ .result = try degradedResult(ctx.allocator, null) };
    if (!kg.ready) return .{ .result = try degradedResult(ctx.allocator, kg) };
    kg.setAbort(ctx.abort);

    var parsed_args = std.json.parseFromSlice(std.json.Value, ctx.allocator, args, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgContext 参数必须是合法 JSON object", .{});
            return error.InvalidArguments;
        },
    };
    defer parsed_args.deinit();
    if (parsed_args.value != .object) {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgContext 参数必须是 JSON object", .{});
        return error.InvalidArguments;
    }
    const obj = parsed_args.value.object;

    const node_id = (try readU64Arg(ctx, obj, "node_id")) orelse {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgContext 缺少合法 node_id (>0)", .{});
        return error.InvalidNodeId;
    };
    if (node_id == 0) {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgContext node_id 必须大于 0", .{});
        return error.InvalidNodeId;
    }
    const limit_u64 = (try readU64Arg(ctx, obj, "limit")) orelse DEFAULT_CONTEXT_EDGES;
    if (limit_u64 < 1 or limit_u64 > MAX_CONTEXT_EDGES) {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgContext limit 必须在 1..20", .{});
        return error.InvalidLimit;
    }
    const limit = std.math.cast(usize, limit_u64) orelse return error.InvalidLimit;

    const offset_raw = (try readU64Arg(ctx, obj, "text_offset")) orelse 0;
    const requested_offset = std.math.cast(usize, offset_raw) orelse {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgContext text_offset 超出平台范围", .{});
        return error.InvalidOffset;
    };
    const text_limit_u64 = (try readU64Arg(ctx, obj, "text_limit")) orelse DEFAULT_TEXT_BYTES;
    if (text_limit_u64 < 4 or text_limit_u64 > MAX_TEXT_BYTES) {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgContext text_limit 必须在 4..12000，确保 UTF-8 分页前进", .{});
        return error.InvalidLimit;
    }
    const text_limit = std.math.cast(usize, text_limit_u64) orelse return error.InvalidLimit;

    const metadata_raw = kg.nodeMetadataJson(node_id, true) catch |e| return .{ .result = try kgErrorResult(ctx, kg, e, "KgContext") };
    defer kg.allocator.free(metadata_raw);
    var parsed_metadata = std.json.parseFromSlice(std.json.Value, ctx.allocator, metadata_raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgContext 收到无效 node metadata JSON", .{});
            return error.InvalidGraphProtocol;
        },
    };
    defer parsed_metadata.deinit();
    const metadata = parseNodeContextMetadata(parsed_metadata.value, node_id) orelse {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgContext 不支持当前 node metadata 协议", .{});
        return error.InvalidGraphProtocol;
    };
    const text = metadata.text;
    // TinyKG neighbors JSON intentionally omits node bodies and is already
    // structurally bounded by `limit` (root + at most N adjacent nodes/edges).
    // Do not pass a small --max-chars here: TinyKG applies that budget to the
    // authoritative bodies while selecting nodes, so a long root can be
    // omitted even though its body is not present in the JSON projection.
    const graph_raw = kg.neighborsJson(node_id, limit) catch |e| return .{ .result = try kgErrorResult(ctx, kg, e, "KgContext") };
    defer kg.allocator.free(graph_raw);
    const graph = std.mem.trim(u8, graph_raw, " \t\r\n");
    if (graph.len > MAX_GRAPH_BYTES) {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgContext 图邻域超过 64KiB；请降低 limit 或选择更精确的节点", .{});
        return error.ContextTooLarge;
    }

    // TinyKG 是外部版本化协议。不能把任意 stdout 嵌进工具 JSON；版本或 mode 漂移时
    // fail closed，让 vendor pin 升级显式更新适配器与 L2。
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, graph, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgContext 收到无效 neighbors JSON", .{});
            return error.InvalidGraphProtocol;
        },
    };
    defer parsed.deinit();
    const graph_node_count = validateNeighborGraph(parsed.value, node_id, limit, metadata.generation) orelse {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgContext 不支持当前 neighbors 协议版本", .{});
        return error.InvalidGraphProtocol;
    };
    const governance = buildKnowledgeGovernance(parsed.value, node_id, metadata.generation) orelse {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgContext 图协议缺少知识治理状态", .{});
        return error.InvalidGraphProtocol;
    };

    // Keep both decoded bytes and their JSON representation within text_limit.
    // Newline/control-heavy memories otherwise expand after paging and can
    // break the bounded batch envelope despite a small decoded page.
    const page = try textPageForJsonBudget(ctx.allocator, text, requested_offset, text_limit);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    const head = try std.fmt.allocPrint(ctx.allocator, "{{\"node_id\":{d},\"text\":", .{node_id});
    defer ctx.allocator.free(head);
    try out.appendSlice(ctx.allocator, head);
    try appendJsonString(&out, ctx.allocator, text[page.start..page.end]);
    const meta = try std.fmt.allocPrint(
        ctx.allocator,
        ",\"text_offset\":{d},\"text_returned_bytes\":{d},\"text_total_bytes\":{d},\"text_truncated\":{s},\"next_text_offset\":{d},\"graph_node_count\":{d},\"graph\":",
        .{ page.start, page.end - page.start, text.len, if (page.end < text.len) "true" else "false", page.end, graph_node_count },
    );
    defer ctx.allocator.free(meta);
    try out.appendSlice(ctx.allocator, meta);
    try out.appendSlice(ctx.allocator, graph);
    try appendKnowledgeGovernance(&out, ctx.allocator, governance);
    try out.appendSlice(ctx.allocator, ",\"verification_guidance\":");
    try appendJsonString(&out, ctx.allocator, retrieval_protocol.CONTEXT_RESULT_GUIDANCE);
    try out.appendSlice(ctx.allocator, "}");
    return .{
        .result = try out.toOwnedSlice(ctx.allocator),
        .observed_node_id = node_id,
    };
}

const KnowledgeGovernance = struct {
    current_generation: bool,
    deprecated_by: ?u64,
    verification_edge_count: usize,
    evidence_edge_count: usize,
    provenance_edge_count: usize,
    resolution_edge_count: usize,
    contradiction_edge_count: usize,
    graph_truncated: bool,

    fn trustState(self: KnowledgeGovernance) []const u8 {
        if (!self.current_generation or self.deprecated_by != null) return "superseded";
        if (self.contradiction_edge_count > 0) return "contradicted";
        if (self.graph_truncated) return "incomplete_graph";
        if (self.verification_edge_count + self.evidence_edge_count > 0) return "evidence_connected_candidate";
        return "unverified_candidate";
    }
};

const NodeGeneration = struct {
    current_generation: bool,
    deprecated_by: ?u64,
};

const NodeContextMetadata = struct {
    text: []const u8,
    generation: NodeGeneration,
};

fn parseNodeContextMetadata(value: std.json.Value, requested_node_id: u64) ?NodeContextMetadata {
    if (value != .object or
        !jsonStringEquals(value.object.get("schema_version"), "tinykg-agent-retrieval-v1")) return null;
    const found = value.object.get("found") orelse return null;
    if (found != .bool or !found.bool) return null;
    const node = value.object.get("node") orelse return null;
    if (node != .object) return null;
    const node_id = node.object.get("id") orelse return null;
    if (node_id != .integer or node_id.integer < 1 or @as(u64, @intCast(node_id.integer)) != requested_node_id) return null;
    const text = node.object.get("text") orelse return null;
    if (text != .string) return null;
    const status = node.object.get("status") orelse return null;
    if (status != .object) return null;
    const current = status.object.get("current_generation") orelse return null;
    if (current != .bool) return null;
    const deprecated_value = status.object.get("deprecated_by") orelse return null;
    const deprecated_by: ?u64 = switch (deprecated_value) {
        .null => null,
        .integer => |raw| if (raw > 0) @intCast(raw) else return null,
        else => return null,
    };
    if (current.bool == (deprecated_by != null)) return null;
    return .{
        .text = text.string,
        .generation = .{ .current_generation = current.bool, .deprecated_by = deprecated_by },
    };
}

fn buildKnowledgeGovernance(value: std.json.Value, requested_node_id: u64, generation: NodeGeneration) ?KnowledgeGovernance {
    if (value != .object) return null;
    const summary = value.object.get("summary") orelse return null;
    if (summary != .object) return null;
    const truncated = summary.object.get("truncated") orelse return null;
    if (truncated != .bool) return null;

    var result = KnowledgeGovernance{
        .current_generation = generation.current_generation,
        .deprecated_by = generation.deprecated_by,
        .verification_edge_count = 0,
        .evidence_edge_count = 0,
        .provenance_edge_count = 0,
        .resolution_edge_count = 0,
        .contradiction_edge_count = 0,
        .graph_truncated = truncated.bool,
    };
    countGovernanceEdges(value.object.get("edges") orelse return null, requested_node_id, &result) orelse return null;
    countGovernanceEdges(value.object.get("backrefs") orelse return null, requested_node_id, &result) orelse return null;
    return result;
}

fn countGovernanceEdges(value: std.json.Value, requested_node_id: u64, result: *KnowledgeGovernance) ?void {
    if (value != .array) return null;
    for (value.array.items) |edge| {
        if (edge != .object) return null;
        const src_value = edge.object.get("src") orelse return null;
        const dst_value = edge.object.get("dst") orelse return null;
        if (src_value != .integer or src_value.integer < 1 or dst_value != .integer or dst_value.integer < 1) return null;
        const src: u64 = @intCast(src_value.integer);
        const dst: u64 = @intCast(dst_value.integer);
        if (src != requested_node_id and dst != requested_node_id) continue;
        const rel_value = edge.object.get("rel") orelse return null;
        if (rel_value != .string) return null;
        const rel = rel_value.string;
        if (std.mem.eql(u8, rel, "verified_by")) result.verification_edge_count += 1;
        if (std.mem.eql(u8, rel, "evidences")) result.evidence_edge_count += 1;
        if (std.mem.eql(u8, rel, "derived_from") or std.mem.eql(u8, rel, "based_on")) result.provenance_edge_count += 1;
        if (std.mem.eql(u8, rel, "resolved_by")) result.resolution_edge_count += 1;
        if (std.mem.eql(u8, rel, "contradicts") or std.mem.eql(u8, rel, "conflicts_with")) result.contradiction_edge_count += 1;
    }
    return {};
}

fn appendKnowledgeGovernance(out: *std.ArrayList(u8), allocator: std.mem.Allocator, governance: KnowledgeGovernance) !void {
    try out.appendSlice(allocator, ",\"knowledge_governance\":{\"schema_version\":\"metacodes-knowledge-governance-v1\",\"trust_state\":");
    try appendJsonString(out, allocator, governance.trustState());
    const head = try std.fmt.allocPrint(
        allocator,
        ",\"current_generation\":{s},\"deprecated_by\":",
        .{if (governance.current_generation) "true" else "false"},
    );
    defer allocator.free(head);
    try out.appendSlice(allocator, head);
    if (governance.deprecated_by) |node_id| {
        const rendered = try std.fmt.allocPrint(allocator, "{d}", .{node_id});
        defer allocator.free(rendered);
        try out.appendSlice(allocator, rendered);
    } else {
        try out.appendSlice(allocator, "null");
    }
    const counts = try std.fmt.allocPrint(
        allocator,
        ",\"verification_edge_count\":{d},\"evidence_edge_count\":{d},\"provenance_edge_count\":{d},\"resolution_edge_count\":{d},\"contradiction_edge_count\":{d},\"graph_truncated\":{s},\"freshness_state\":\"unknown_requires_current_state_check\",\"usage\":\"candidate_only\",\"required_action\":\"inspect evidence, supersession and conflict signals; do not use memory as a current fact until any required current-state check passes\"}}",
        .{ governance.verification_edge_count, governance.evidence_edge_count, governance.provenance_edge_count, governance.resolution_edge_count, governance.contradiction_edge_count, if (governance.graph_truncated) "true" else "false" },
    );
    defer allocator.free(counts);
    try out.appendSlice(allocator, counts);
}

fn readU64Arg(ctx: *const ToolContext, obj: std.json.ObjectMap, name: []const u8) anyerror!?u64 {
    const value = obj.get(name) orelse return null;
    if (value != .integer or value.integer < 0) {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgContext {s} 必须是非负整数", .{name});
        return error.InvalidArguments;
    }
    return @intCast(value.integer);
}

const TextPage = struct { start: usize, end: usize };

fn textPage(text: []const u8, requested_offset: usize, max_bytes: usize) TextPage {
    var start = @min(requested_offset, text.len);
    while (start > 0 and start < text.len and isUtf8Continuation(text[start])) start -= 1;
    var end = @min(text.len, start +| max_bytes);
    while (end > start and end < text.len and isUtf8Continuation(text[end])) end -= 1;
    return .{ .start = start, .end = end };
}

fn textPageForJsonBudget(
    allocator: std.mem.Allocator,
    text: []const u8,
    requested_offset: usize,
    max_bytes: usize,
) !TextPage {
    var page = textPage(text, requested_offset, max_bytes);
    while (page.end > page.start) {
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(allocator);
        try util_json.serializeString(text[page.start..page.end], &encoded, allocator);
        const payload_bytes = encoded.items.len - 2;
        if (payload_bytes <= max_bytes) return page;

        const current_bytes = page.end - page.start;
        var next_bytes = current_bytes * max_bytes / payload_bytes;
        if (next_bytes >= current_bytes) next_bytes = current_bytes - 1;
        // text_limit's primary contract is forward progress. A single JSON
        // control character needs six wire bytes, so a caller's legal minimum
        // limit=4 cannot satisfy both the wire budget and progress. Preserve
        // one complete code point in that degenerate case; the overage is at
        // most two bytes and next_text_offset still advances deterministically.
        if (next_bytes == 0) {
            const first_len = std.unicode.utf8ByteSequenceLength(text[page.start]) catch 1;
            page.end = @min(text.len, page.start + first_len);
            return page;
        }
        page = textPage(text, page.start, next_bytes);
    }
    return page;
}

fn boundedJsonTextExcerptAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_json_payload_bytes: usize,
) ![]u8 {
    var source_budget = @min(text.len, max_json_payload_bytes);
    while (true) {
        const excerpt = try kg_mod.boundedTextExcerptAlloc(allocator, text, source_budget);
        errdefer allocator.free(excerpt);

        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(allocator);
        try util_json.serializeString(excerpt, &encoded, allocator);
        const payload_bytes = encoded.items.len - 2;
        if (payload_bytes <= max_json_payload_bytes) return excerpt;

        allocator.free(excerpt);
        if (source_budget == 0) return allocator.dupe(u8, "");
        var next_budget = source_budget * max_json_payload_bytes / payload_bytes;
        if (next_budget >= source_budget) next_budget = source_budget - 1;
        source_budget = next_budget;
    }
}

fn isUtf8Continuation(byte: u8) bool {
    return (byte & 0xC0) == 0x80;
}

fn jsonStringEquals(value: ?std.json.Value, expected: []const u8) bool {
    const v = value orelse return false;
    return v == .string and std.mem.eql(u8, v.string, expected);
}

fn validateNeighborGraph(value: std.json.Value, requested_node_id: u64, limit: usize, generation: NodeGeneration) ?u64 {
    if (value != .object or
        !jsonStringEquals(value.object.get("schema_version"), "tinykg-agent-retrieval-v1") or
        !jsonStringEquals(value.object.get("mode"), "neighbors")) return null;
    const query = value.object.get("query") orelse return null;
    if (query != .object) return null;
    const root_id = query.object.get("root_id") orelse return null;
    if (root_id != .integer or root_id.integer < 1 or @as(u64, @intCast(root_id.integer)) != requested_node_id) return null;
    const summary = value.object.get("summary") orelse return null;
    if (summary != .object) return null;
    const count = summary.object.get("node_count") orelse return null;
    if (count != .integer or count.integer < 0) return null;
    const node_count: u64 = @intCast(count.integer);
    // TinyKG `--limit N` bounds neighbor edges; the JSON node set may contain
    // the root plus N adjacent nodes.
    if (node_count > limit + 1) return null;
    const root = value.object.get("root") orelse return null;
    if (generation.current_generation) {
        if (node_count < 1 or root != .object) return null;
        const graph_root_id = root.object.get("id") orelse return null;
        if (graph_root_id != .integer or graph_root_id.integer < 1 or @as(u64, @intCast(graph_root_id.integer)) != requested_node_id) return null;
    } else {
        // Historical generations are intentionally omitted from TinyKG's
        // neighbor graph. Metadata remains authoritative for deprecated_by;
        // the empty history continuation is the only accepted sentinel.
        if (node_count != 0 or root != .null) return null;
        const truncated = summary.object.get("truncated") orelse return null;
        if (truncated != .bool or !truncated.bool or
            !jsonStringEquals(summary.object.get("truncate_reason"), "history")) return null;
    }
    return node_count;
}

/// KgError → 工具层结果。data 错带 detail 引导模型改参;transient 报可重试。
fn kgErrorResult(ctx: *const ToolContext, kg: *kg_mod.KgClient, e: kg_mod.KgError, tool: []const u8) anyerror![]u8 {
    switch (e) {
        kg_mod.KgError.Data => {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "{s} 数据错误: {s}", .{ tool, kg.detail() });
            return error.KgDataError;
        },
        kg_mod.KgError.Transient => {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "{s} 暂时失败(KG 忙/锁竞争),稍后可重试", .{tool});
            return error.KgTransient;
        },
        kg_mod.KgError.AmbiguousCommit => {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "{s} 写入结果不确定；保留 request id 并核验应用状态后再继续: {s}", .{ tool, kg.detail() });
            return error.KgAmbiguousCommit;
        },
        kg_mod.KgError.Backpressure => {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "{s} TinyKG daemon 队列已满；请有界退避后重试", .{tool});
            return error.KgBackpressure;
        },
        kg_mod.KgError.DaemonUnavailable => {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "{s} TinyKG daemon 不可达；禁止回退为直接打开共享 Store", .{tool});
            return error.KgDaemonUnavailable;
        },
        kg_mod.KgError.Degraded => return degradedResult(ctx.allocator, kg),
        kg_mod.KgError.OutOfMemory => return error.OutOfMemory,
    }
}

/// 近重复判定(尺度无关,不依赖 BM25 分数):归一化空白后,一方是另一方前缀,或
/// 归一化后完全相等。保守——只认高度重合,漏判(不提示)优于误判(阻扰正常写入)。
fn isNearDuplicate(new_text: []const u8, existing: []const u8) bool {
    const a = std.mem.trim(u8, new_text, " \t\r\n");
    const b = std.mem.trim(u8, existing, " \t\r\n");
    if (a.len == 0 or b.len == 0) return false;
    if (std.mem.eql(u8, a, b)) return true;
    // 一方是另一方前缀(existing 常是被截断到 800 字节的)且重合 ≥ 短串的 90%。
    const shorter = @min(a.len, b.len);
    const longer = @max(a.len, b.len);
    if (shorter * 10 < longer * 9) return false; // 长度差 >10% → 不算重复
    return std.mem.startsWith(u8, a, b[0..@min(b.len, shorter)]) or std.mem.startsWith(u8, b, a[0..@min(a.len, shorter)]);
}

fn appendJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try util_json.serializeString(s, out, allocator);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "isNearDuplicate: 尺度无关文本重合判定(替代不可靠的 BM25 分数门,M4)" {
    // 完全相同 → dup。
    try testing.expect(isNearDuplicate("auth 用 JWT", "auth 用 JWT"));
    // 归一化空白后相同 → dup。
    try testing.expect(isNearDuplicate("  auth 用 JWT \n", "auth 用 JWT"));
    // existing 是 new 的前缀(被截断到 800 字节的情况)且长度接近 → dup。
    try testing.expect(isNearDuplicate("auth 用 JWT 存 header 15 分钟", "auth 用 JWT 存 header 15 分"));
    // 完全不同 → 非 dup。
    try testing.expect(!isNearDuplicate("auth 用 JWT", "数据库用 postgres 分区"));
    // 长度差 >10% → 非 dup(不同信息量)。
    try testing.expect(!isNearDuplicate("auth 用 JWT 存 header 15 分钟过期 refresh token httponly", "auth"));
    // 空串 → 非 dup(不阻扰)。
    try testing.expect(!isNearDuplicate("", "x"));
    try testing.expect(!isNearDuplicate("x", ""));
}

test "textPage preserves UTF-8 boundaries and supports deterministic paging" {
    const text = "ab中文cd";
    const first = textPage(text, 0, 4); // would split 文 without boundary repair
    try testing.expectEqualStrings("ab", text[first.start..first.end]);
    const second = textPage(text, first.end, 6);
    try testing.expectEqualStrings("中文", text[second.start..second.end]);
    const inside_codepoint = textPage(text, 3, 6);
    try testing.expectEqualStrings("中文", text[inside_codepoint.start..inside_codepoint.end]);
}

test "bounded recall excerpts budget escaped JSON bytes" {
    const raw = [_]u8{0x01} ** 512;
    const excerpt = try boundedJsonTextExcerptAlloc(testing.allocator, &raw, 64);
    defer testing.allocator.free(excerpt);

    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(testing.allocator);
    try util_json.serializeString(excerpt, &encoded, testing.allocator);
    try testing.expect(encoded.items.len >= 2);
    try testing.expect(encoded.items.len - 2 <= 64);
    try testing.expect(excerpt.len < raw.len);
}

test "KgContext page budgets escaped JSON without breaking UTF-8" {
    const text = "开头\x01\x01\x01\x01\x01\x01\x01\x01结尾";
    const page = try textPageForJsonBudget(testing.allocator, text, 0, 16);
    try testing.expect(page.end > page.start);
    try testing.expect(std.unicode.utf8ValidateSlice(text[page.start..page.end]));

    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(testing.allocator);
    try util_json.serializeString(text[page.start..page.end], &encoded, testing.allocator);
    try testing.expect(encoded.items.len - 2 <= 16);

    const control_only = [_]u8{0x01} ** 8;
    const minimum = try textPageForJsonBudget(testing.allocator, &control_only, 0, 4);
    try testing.expectEqual(@as(usize, 1), minimum.end - minimum.start);
}

test "validateNeighborGraph binds version, root, and requested limit" {
    const raw =
        \\{"schema_version":"tinykg-agent-retrieval-v1","mode":"neighbors","query":{"root_id":42},"summary":{"node_count":6},"root":{"id":42}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
    defer parsed.deinit();
    const current = NodeGeneration{ .current_generation = true, .deprecated_by = null };
    try testing.expectEqual(@as(?u64, 6), validateNeighborGraph(parsed.value, 42, 5, current));
    try testing.expect(validateNeighborGraph(parsed.value, 41, 5, current) == null);
    try testing.expect(validateNeighborGraph(parsed.value, 42, 4, current) == null);
}

test "node metadata and historical neighbor sentinel fail closed around supersession" {
    const metadata_raw =
        \\{"schema_version":"tinykg-agent-retrieval-v1","found":true,"node":{"id":7,"status":{"current_generation":false,"deprecated_by":9},"text":"old fact"}}
    ;
    var metadata = try std.json.parseFromSlice(std.json.Value, testing.allocator, metadata_raw, .{});
    defer metadata.deinit();
    const parsed_metadata = parseNodeContextMetadata(metadata.value, 7) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("old fact", parsed_metadata.text);
    try testing.expect(!parsed_metadata.generation.current_generation);
    try testing.expectEqual(@as(?u64, 9), parsed_metadata.generation.deprecated_by);
    try testing.expect(parseNodeContextMetadata(metadata.value, 8) == null);

    const history_raw =
        \\{"schema_version":"tinykg-agent-retrieval-v1","mode":"neighbors","query":{"root_id":7},"summary":{"node_count":0,"truncated":true,"truncate_reason":"history"},"root":null}
    ;
    var history = try std.json.parseFromSlice(std.json.Value, testing.allocator, history_raw, .{});
    defer history.deinit();
    try testing.expectEqual(@as(?u64, 0), validateNeighborGraph(history.value, 7, 12, parsed_metadata.generation));
    const current = NodeGeneration{ .current_generation = true, .deprecated_by = null };
    try testing.expect(validateNeighborGraph(history.value, 7, 12, current) == null);
}
