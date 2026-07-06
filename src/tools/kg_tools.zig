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

    // kind 白名单(默认 observation;白名单外报 data 错引导改参)。
    const kind: kg_mod.MemoryKind = blk: {
        const raw = util_json.extractStringField(args, "kind") orelse break :blk .observation;
        break :blk kg_mod.MemoryKind.parse(raw) orelse {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "kind 必须是 observation|decision|user_preference|concept 之一", .{});
            return error.InvalidKind;
        };
    };
    const scope_global = blk: {
        const raw = util_json.extractStringField(args, "scope") orelse break :blk false;
        break :blk std.ascii.eqlIgnoreCase(raw, "global");
    };

    // 近重复搭车门(设计 §5):写前 recall 一次,top1 高分附提示——不硬拦。
    var dup_note: ?[]u8 = null;
    defer if (dup_note) |n| ctx.allocator.free(n);
    if (kg.recall(text_owned, 1, false)) |hits| {
        defer {
            for (hits) |*h| h.deinit(ctx.allocator);
            ctx.allocator.free(hits);
        }
        if (hits.len > 0 and hits[0].score >= 18.0) {
            dup_note = try std.fmt.allocPrint(ctx.allocator, "已有相近记忆 node {d}(score {d:.1}),若为同一事实请考虑更新而非新增", .{ hits[0].node_id, hits[0].score });
        }
    } else |_| {} // 近重复检查失败不阻塞写入

    const schema_type = @tagName(kind);
    const node_id = kg.remember(kind, text_owned, schema_type, scope_global) catch |e| {
        return kgErrorResult(ctx, kg, e, "KgRemember");
    };
    // provenance(best-effort)。
    const sid = ctx.session.asSlice();
    if (sid.len > 0) kg.tagProvenance(node_id, sid);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    const head = try std.fmt.allocPrint(ctx.allocator, "{{\"remembered\":{{\"node_id\":{d},\"kind\":\"{s}\",\"scope\":\"{s}\"}}", .{ node_id, @tagName(kind), if (scope_global) "global" else "project" });
    defer ctx.allocator.free(head);
    try out.appendSlice(ctx.allocator, head);
    if (dup_note) |n| {
        try out.appendSlice(ctx.allocator, ",\"note\":");
        try appendJsonString(&out, ctx.allocator, n);
    }
    try out.appendSlice(ctx.allocator, "}");
    return out.toOwnedSlice(ctx.allocator);
}

pub fn executeRecall(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const kg = requireKg(ctx) orelse return degradedResult(ctx.allocator, null);
    if (!kg.ready) return degradedResult(ctx.allocator, kg);

    const query = util_json.extractStringField(args, "query") orelse {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KgRecall 缺少必填字段 query", .{});
        return error.MissingQuery;
    };
    const query_owned = try util_json.unescapeString(query, ctx.allocator);
    defer ctx.allocator.free(query_owned);

    const hits = kg.recall(query_owned, 8, false) catch |e| {
        return kgErrorResult(ctx, kg, e, "KgRecall");
    };
    defer {
        for (hits) |*h| h.deinit(ctx.allocator);
        ctx.allocator.free(hits);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator, "{\"hits\":[");
    for (hits, 0..) |h, i| {
        if (i > 0) try out.appendSlice(ctx.allocator, ",");
        const row = try std.fmt.allocPrint(ctx.allocator, "{{\"node_id\":{d},\"kind\":\"{s}\",\"scope\":\"{s}\",\"score\":{d:.2},\"text\":", .{
            h.node_id, h.kind, if (std.mem.eql(u8, h.domain, "global")) "global" else "project", h.score,
        });
        defer ctx.allocator.free(row);
        try out.appendSlice(ctx.allocator, row);
        try appendJsonString(&out, ctx.allocator, h.text);
        try out.appendSlice(ctx.allocator, "}");
    }
    const tail = try std.fmt.allocPrint(ctx.allocator, "],\"count\":{d}}}", .{hits.len});
    defer ctx.allocator.free(tail);
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

fn appendJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try util_json.serializeString(s, out, allocator);
}
