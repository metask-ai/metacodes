//! KG 记忆工具:KgRemember / KgRecall(设计 v3-final §5)。
//!
//! - KgRemember:写记忆节点(kind 白名单 + scope project/global + 近重复搭车提示
//!   + provenance session_id)。免审但**必出可见工具卡**(注册处 resultRenderMode
//!   禁 hidden——hidden 吞卡血泪)。
//! - KgRecall:BM25 检索 + 客户端过滤(domain 当前项目+global;默认排除任务面)。
//! - degraded:结构化说明返回(不 spawn、不硬错、不撞熔断器)。

const std = @import("std");
const ToolContext = @import("context.zig").ToolContext;
const kg_mod = @import("../kg/client.zig");
const util_json = @import("../util/json.zig");
const common = @import("common.zig");
const log = @import("../util/log.zig");
const retrieval_protocol = @import("../kg/retrieval_protocol.zig");

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

    const query = util_json.extractStringField(args, "query") orelse {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall 缺少必填字段 query", .{});
        return error.MissingQuery;
    };
    const query_owned = try util_json.unescapeString(query, ctx.allocator);
    defer ctx.allocator.free(query_owned);

    // 可选 type 过滤:归一化 + 集合校验,菜单外报错**不静默空返**(Linus MEDIUM-1)。
    var type_canon: ?[]const u8 = null;
    if (util_json.extractStringField(args, "type")) |raw| {
        const resolved = kg_mod.resolveMemoryType(raw) orelse {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "type 必须是 decision|user_preference|module|bug|observation 之一", .{});
            return error.InvalidType;
        };
        type_canon = resolved.schema_type;
    }
    // 采用率埋点(PM:kill-criterion 的 load-bearing 仪器,measure 模型是否用 --type)。
    log.info("kg", "kg_recall type_filter={s}", .{type_canon orelse "none"});

    const hits = kg.recallTyped(query_owned, 8, false, type_canon) catch |e| {
        return kgErrorResult(ctx, kg, e, "KgRecall");
    };
    defer {
        // kg 内存契约:hits 是 kg.allocator 分的(subagent 线程 ctx.allocator 不同源)。
        for (hits) |*h| h.deinit(kg.allocator);
        kg.allocator.free(hits);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator, "{\"hits\":[");
    for (hits, 0..) |h, i| {
        if (i > 0) try out.appendSlice(ctx.allocator, ",");
        const type_str = if (h.schema_type.len > 0) h.schema_type else h.kind;
        const row = try std.fmt.allocPrint(ctx.allocator, "{{\"node_id\":{d},\"type\":\"{s}\",\"scope\":\"{s}\",\"score\":{d:.2},\"text\":", .{
            h.node_id, type_str, if (std.mem.eql(u8, h.domain, "global")) "global" else "project", h.score,
        });
        defer ctx.allocator.free(row);
        try out.appendSlice(ctx.allocator, row);
        try appendJsonString(&out, ctx.allocator, h.text);
        // 溯源(PM P0-2):hit 带 source 的是记忆 markdown 文件——模型该**更新该文件**而非
        // 另存/KgRemember(否则 "update rather than duplicate" 指令不可执行)。
        if (h.source_label.len > 0) {
            try out.appendSlice(ctx.allocator, ",\"source\":");
            try appendJsonString(&out, ctx.allocator, h.source_label);
        }
        try out.appendSlice(ctx.allocator, "}");
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
    try out.appendSlice(ctx.allocator, "},\"retrieval_mode\":\"lexical_bm25_no_embeddings\",\"lexical_guidance\":");
    try appendJsonString(&out, ctx.allocator, retrieval_protocol.RESULT_GUIDANCE);
    const tail = "}";
    try out.appendSlice(ctx.allocator, tail);
    return out.toOwnedSlice(ctx.allocator);
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
