const std = @import("std");
const core = @import("../core.zig");
const index = @import("../index.zig");
const segment_mod = @import("../segment.zig");
const segment_node_catalog = @import("../segment_node_catalog.zig");
const optimizer = @import("optimizer.zig");
const executor = @import("executor.zig");

pub const ExactTextEntry = segment_node_catalog.ExactTextEntry;
pub const NodeInfoEntry = segment_node_catalog.NodeInfoEntry;
pub const SegmentNodeCatalog = segment_node_catalog.SegmentNodeCatalog;

pub const SegmentExecutionContext = struct {
    catalog: SegmentNodeCatalog,
    segment: *segment_mod.ImmutableAdjacencySegment,
};

const SupportedShape = struct {
    lookup: optimizer.PhysicalOp,
    first_expand: optimizer.PhysicalOp,
    second_expand: ?optimizer.PhysicalOp = null,
    limit: ?usize = null,
};

pub fn executeExactTextPath(
    allocator: std.mem.Allocator,
    context: SegmentExecutionContext,
    plan: optimizer.PhysicalPlan,
    budget: core.QueryBudget,
) !executor.ResultTable {
    return executeExactTextPathWithCatalog(allocator, context, plan, budget);
}

pub fn executeExactTextPathWithCatalog(
    allocator: std.mem.Allocator,
    context: anytype,
    plan: optimizer.PhysicalPlan,
    budget: core.QueryBudget,
) !executor.ResultTable {
    return executeExactTextPathWithCatalogTimed(allocator, context, plan, budget, null);
}

pub fn executeExactTextPathWithCatalogExplain(
    allocator: std.mem.Allocator,
    context: anytype,
    plan: optimizer.PhysicalPlan,
    budget: core.QueryBudget,
    timings: *executor.OperatorTimingRecorder,
) !executor.ResultTable {
    try timings.ensureCapacityForPlan(plan);
    timings.clearRetainingCapacity();
    return executeExactTextPathWithCatalogTimed(allocator, context, plan, budget, timings);
}

fn executeExactTextPathWithCatalogTimed(
    allocator: std.mem.Allocator,
    context: anytype,
    plan: optimizer.PhysicalPlan,
    budget: core.QueryBudget,
    timings: ?*executor.OperatorTimingRecorder,
) !executor.ResultTable {
    const shape = try supportedShape(plan);
    if (!context.catalog.validated) try context.catalog.validate();
    var table = executor.ResultTable.init();
    errdefer table.deinit(allocator);
    if (shape.limit != null and shape.limit.? == 0) return table;

    const lookup = shape.lookup.node_lookup_by_text;
    const first_expand = shape.first_expand.expand;
    const second_expand = if (shape.second_expand) |op| op.expand else null;
    const max_results = effectiveLimit(shape.limit, budget.max_results);
    const seed_cap = @min(max_results, budget.max_visited_nodes);
    const lookup_start_ns = if (timings) |recorder| recorder.nowNs() else 0;
    var candidates = try context.catalog.lookupExact(allocator, lookup.kind, lookup.text, seed_cap);
    defer candidates.deinit(allocator);

    var lookup_rows_output: usize = 0;
    var lookup_nodes_visited_delta: usize = 0;
    var lookup_budget_exceeded = false;
    const first_expand_start_ns = if (timings) |recorder| recorder.nowNs() else 0;
    const first_expand_input_rows = candidates.items.len;
    const first_expand_nodes_before = table.stats.nodes_visited;
    const first_expand_edges_before = table.stats.edges_visited;
    var first_expand_output_rows: usize = 0;
    var first_expand_budget_exceeded = false;
    var second_expand_elapsed_ns: u128 = 0;
    var second_expand_input_rows: usize = 0;
    var second_expand_nodes_visited_delta: usize = 0;
    var second_expand_edges_visited_delta: usize = 0;
    var second_expand_budget_exceeded = false;
    defer if (timings) |recorder| {
        const now_ns = recorder.nowNs();
        const lookup_elapsed_ns = if (first_expand_start_ns >= lookup_start_ns) first_expand_start_ns - lookup_start_ns else 0;
        const first_expand_total_ns = if (now_ns >= first_expand_start_ns) now_ns - first_expand_start_ns else 0;
        const first_expand_elapsed_ns = first_expand_total_ns -| second_expand_elapsed_ns;
        const first_expand_nodes_total = (table.stats.nodes_visited -| first_expand_nodes_before) -| lookup_nodes_visited_delta;
        const first_expand_edges_total = (table.stats.edges_visited -| first_expand_edges_before) -| second_expand_edges_visited_delta;
        const has_second_expand = second_expand != null;
        const project_index: usize = if (has_second_expand) 3 else 2;
        const limit_index: ?usize = if (shape.limit != null) project_index + 1 else null;
        recorder.recordAssumeCapacity(.{
            .op_index = 0,
            .op_name = "node_lookup_by_text",
            .elapsed_ns = lookup_elapsed_ns,
            .input_rows = 0,
            .output_rows = lookup_rows_output,
            .nodes_visited_delta = lookup_nodes_visited_delta,
            .edges_visited_delta = 0,
            .budget_exceeded = lookup_budget_exceeded,
        });
        recorder.recordAssumeCapacity(.{
            .op_index = 1,
            .op_name = "expand",
            .elapsed_ns = first_expand_elapsed_ns,
            .input_rows = first_expand_input_rows,
            .output_rows = first_expand_output_rows,
            .nodes_visited_delta = first_expand_nodes_total,
            .edges_visited_delta = first_expand_edges_total,
            .budget_exceeded = first_expand_budget_exceeded,
        });
        if (has_second_expand) {
            recorder.recordAssumeCapacity(.{
                .op_index = 2,
                .op_name = "expand",
                .elapsed_ns = second_expand_elapsed_ns,
                .input_rows = second_expand_input_rows,
                .output_rows = table.rows.items.len,
                .nodes_visited_delta = second_expand_nodes_visited_delta,
                .edges_visited_delta = second_expand_edges_visited_delta,
                .budget_exceeded = second_expand_budget_exceeded,
            });
        }
        recorder.recordAssumeCapacity(.{
            .op_index = project_index,
            .op_name = "project",
            .elapsed_ns = 0,
            .input_rows = table.rows.items.len,
            .output_rows = table.rows.items.len,
            .nodes_visited_delta = 0,
            .edges_visited_delta = 0,
            .budget_exceeded = false,
        });
        if (limit_index) |index_pos| {
            recorder.recordAssumeCapacity(.{
                .op_index = index_pos,
                .op_name = "limit",
                .elapsed_ns = 0,
                .input_rows = table.rows.items.len,
                .output_rows = table.rows.items.len,
                .nodes_visited_delta = 0,
                .edges_visited_delta = 0,
                .budget_exceeded = false,
            });
        }
    };

    for (candidates.items) |candidate_id| {
        if (table.stats.nodes_visited >= budget.max_visited_nodes) {
            table.stats.budget_exceeded = true;
            lookup_budget_exceeded = true;
            break;
        }
        try index.addVisitedNodes(&table.stats, 1);
        lookup_rows_output += 1;
        lookup_nodes_visited_delta += 1;
        var left = try executor.Row.initBinding(allocator, lookup.var_name, candidate_id);
        defer left.deinit(allocator);

        const first_direction = try segmentDirection(first_expand);
        var iterator = (try context.segment.neighborIterator(first_direction, candidate_id, first_expand.rel)) orelse continue;
        while (try iterator.next()) |edge| {
            if (table.rows.items.len >= max_results) return finish(table);
            if (table.stats.edges_visited >= budget.max_visited_edges) {
                table.stats.budget_exceeded = true;
                first_expand_budget_exceeded = true;
                return finish(table);
            }
            try index.addVisitedEdges(&table.stats, 1);
            const right_id = if (first_direction == .forward) edge.dst else edge.src;
            const matches = (try matchNodeWithinBudget(context.catalog, right_id, first_expand.right_kind, first_expand.right_text_eq, &table, budget)) orelse {
                if (table.stats.budget_exceeded) first_expand_budget_exceeded = true;
                if (table.stats.budget_exceeded) return finish(table);
                continue;
            };
            if (!matches) continue;
            if (second_expand) |expand| {
                var mid_row = (try left.cloneWithBinding(allocator, first_expand.right_var, right_id)) orelse continue;
                defer mid_row.deinit(allocator);
                first_expand_output_rows += 1;
                second_expand_input_rows += 1;
                const second_start_ns = if (timings) |recorder| recorder.nowNs() else 0;
                const second_nodes_before = table.stats.nodes_visited;
                const second_edges_before = table.stats.edges_visited;
                try appendSecondHopRows(allocator, context, &table, mid_row, expand, right_id, max_results, budget);
                if (timings) |recorder| {
                    const second_end_ns = recorder.nowNs();
                    second_expand_elapsed_ns += if (second_end_ns >= second_start_ns) second_end_ns - second_start_ns else 0;
                }
                second_expand_nodes_visited_delta += table.stats.nodes_visited -| second_nodes_before;
                second_expand_edges_visited_delta += table.stats.edges_visited -| second_edges_before;
                if (table.stats.budget_exceeded) second_expand_budget_exceeded = true;
                if (table.rows.items.len >= max_results or table.stats.budget_exceeded) return finish(table);
            } else {
                var row = (try left.cloneWithBinding(allocator, first_expand.right_var, right_id)) orelse continue;
                var row_owned = true;
                errdefer if (row_owned) row.deinit(allocator);
                try table.rows.append(allocator, row);
                row_owned = false;
                table.stats.results = table.rows.items.len;
                first_expand_output_rows = table.rows.items.len;
            }
        }
    }
    return finish(table);
}

fn supportedShape(plan: optimizer.PhysicalPlan) !SupportedShape {
    if (plan.ops.items.len < 3 or plan.ops.items.len > 5) return error.Unsupported;
    if (plan.ops.items[0] != .node_lookup_by_text) return error.Unsupported;
    if (plan.ops.items[1] != .expand) return error.Unsupported;
    const lookup = plan.ops.items[0].node_lookup_by_text;
    const first_expand = plan.ops.items[1].expand;
    if (!std.mem.eql(u8, first_expand.left_var, lookup.var_name)) return error.Unsupported;
    try requireExactDirectedOneHop(first_expand);
    var out = SupportedShape{
        .lookup = plan.ops.items[0],
        .first_expand = plan.ops.items[1],
    };
    var project_index: usize = 2;
    if (plan.ops.items[project_index] == .expand) {
        const second_expand = plan.ops.items[project_index].expand;
        try requireExactDirectedOneHop(second_expand);
        if (!std.mem.eql(u8, first_expand.right_var, second_expand.left_var)) return error.Unsupported;
        out.second_expand = plan.ops.items[project_index];
        project_index += 1;
    }
    if (plan.ops.items[project_index] != .project) return error.Unsupported;
    if (plan.ops.items.len > project_index + 2) return error.Unsupported;
    if (plan.ops.items.len == project_index + 2) {
        if (plan.ops.items[project_index + 1] != .limit) return error.Unsupported;
        out.limit = plan.ops.items[project_index + 1].limit;
    }
    return out;
}

fn requireExactDirectedOneHop(expand: @import("planner.zig").Expand) !void {
    if (expand.min_hops != 1 or expand.max_hops != 1) return error.Unsupported;
    if (expand.direction == .undirected) return error.Unsupported;
}

fn segmentDirection(expand: @import("planner.zig").Expand) !segment_mod.Direction {
    return switch (expand.direction) {
        .outgoing => .forward,
        .incoming => .reverse,
        .undirected => error.Unsupported,
    };
}

fn appendSecondHopRows(
    allocator: std.mem.Allocator,
    context: anytype,
    table: *executor.ResultTable,
    mid_row: executor.Row,
    expand: @import("planner.zig").Expand,
    left_id: core.NodeId,
    max_results: usize,
    budget: core.QueryBudget,
) !void {
    const direction = try segmentDirection(expand);
    var iterator = (try context.segment.neighborIterator(direction, left_id, expand.rel)) orelse return;
    while (try iterator.next()) |edge| {
        if (table.rows.items.len >= max_results) return;
        if (table.stats.edges_visited >= budget.max_visited_edges) {
            table.stats.budget_exceeded = true;
            return;
        }
        try index.addVisitedEdges(&table.stats, 1);
        const right_id = if (direction == .forward) edge.dst else edge.src;
        const matches = (try matchNodeWithinBudget(context.catalog, right_id, expand.right_kind, expand.right_text_eq, table, budget)) orelse {
            if (table.stats.budget_exceeded) return;
            continue;
        };
        if (!matches) continue;
        var row = (try mid_row.cloneWithBinding(allocator, expand.right_var, right_id)) orelse continue;
        var row_owned = true;
        errdefer if (row_owned) row.deinit(allocator);
        try table.rows.append(allocator, row);
        row_owned = false;
        table.stats.results = table.rows.items.len;
    }
}

fn matchNodeWithinBudget(
    catalog: anytype,
    id: core.NodeId,
    kind: ?core.NodeKind,
    text: ?[]const u8,
    table: *executor.ResultTable,
    budget: core.QueryBudget,
) !?bool {
    if (table.stats.nodes_visited >= budget.max_visited_nodes) {
        table.stats.budget_exceeded = true;
        return null;
    }
    const matches = (try catalog.matchNode(id, kind, text)) orelse return null;
    try index.addVisitedNodes(&table.stats, 1);
    return matches;
}

fn effectiveLimit(plan_limit: ?usize, budget_limit: usize) usize {
    if (plan_limit) |limit| return @min(limit, budget_limit);
    return budget_limit;
}

fn finish(table: executor.ResultTable) executor.ResultTable {
    var out = table;
    out.stats.results = out.rows.items.len;
    return out;
}

test "segment executor runs exact-text one-hop without graph materialization" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "segment" });
    defer std.testing.allocator.free(segment_path);

    const edges = [_]segment_mod.EdgeRecord{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
    };
    var segment = try segment_mod.ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &edges);
    defer segment.deinit();

    const exact_texts = [_]ExactTextEntry{
        .{ .kind = .file, .text = "src/main.zig", .id = .fromInt(1) },
        .{ .kind = .function, .text = "main", .id = .fromInt(2) },
        .{ .kind = .document, .text = "README", .id = .fromInt(3) },
    };
    const nodes_by_id = [_]NodeInfoEntry{
        .{ .kind = .file, .text = "src/main.zig", .id = .fromInt(1) },
        .{ .kind = .function, .text = "main", .id = .fromInt(2) },
        .{ .kind = .document, .text = "README", .id = .fromInt(3) },
    };

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "src/main.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
    } });
    try ops.append(std.testing.allocator, .{ .project = &.{} });
    try ops.append(std.testing.allocator, .{ .limit = 4 });

    var table = try executeExactTextPath(
        std.testing.allocator,
        .{ .catalog = .{ .exact_texts = &exact_texts, .nodes_by_id = &nodes_by_id }, .segment = &segment },
        .{ .ops = ops },
        .{},
    );
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(u64, 1), table.rows.items[0].get("f").?.toInt());
    try std.testing.expectEqual(@as(u64, 2), table.rows.items[0].get("s").?.toInt());
    try std.testing.expectEqual(@as(u64, 2), table.stats.nodes_visited);
    try std.testing.expectEqual(@as(u64, 1), table.stats.edges_visited);
}

test "segment executor exact-text catalog rejects unsorted non-contiguous matches" {
    const exact_texts = [_]ExactTextEntry{
        .{ .kind = .file, .text = "src/main.zig", .id = .fromInt(1) },
        .{ .kind = .function, .text = "main", .id = .fromInt(9) },
        .{ .kind = .file, .text = "src/main.zig", .id = .fromInt(2) },
    };
    const nodes_by_id = [_]NodeInfoEntry{
        .{ .kind = .file, .text = "src/main.zig", .id = .fromInt(1) },
        .{ .kind = .file, .text = "src/main.zig", .id = .fromInt(2) },
        .{ .kind = .function, .text = "main", .id = .fromInt(9) },
    };
    try std.testing.expectError(error.InvalidRecord, (SegmentNodeCatalog{
        .exact_texts = &exact_texts,
        .nodes_by_id = &nodes_by_id,
    }).validate());

    const missing_node = [_]ExactTextEntry{
        .{ .kind = .file, .text = "src/main.zig", .id = .fromInt(42) },
    };
    const single_node = [_]NodeInfoEntry{
        .{ .kind = .file, .text = "src/main.zig", .id = .fromInt(1) },
    };
    try std.testing.expectError(error.InvalidRecord, (SegmentNodeCatalog{
        .exact_texts = &missing_node,
        .nodes_by_id = &single_node,
    }).validate());

    const sorted_texts = [_]ExactTextEntry{
        .{ .kind = .file, .text = "src/main.zig", .id = .fromInt(1) },
        .{ .kind = .file, .text = "src/main.zig", .id = .fromInt(2) },
        .{ .kind = .function, .text = "main", .id = .fromInt(9) },
    };
    var ids = try (SegmentNodeCatalog{ .exact_texts = &sorted_texts, .nodes_by_id = &nodes_by_id }).lookupExact(std.testing.allocator, .file, "src/main.zig", 8);
    defer ids.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), ids.items.len);
    try std.testing.expectEqual(@as(u64, 1), ids.items[0].toInt());
    try std.testing.expectEqual(@as(u64, 2), ids.items[1].toInt());
}

test "segment executor runs exact-text two-hop without graph materialization" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "segment" });
    defer std.testing.allocator.free(segment_path);

    const edges = [_]segment_mod.EdgeRecord{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(2), .rel = .related_to, .dst = .fromInt(3) },
        .{ .edge_id = .fromInt(3), .src = .fromInt(2), .rel = .mentions, .dst = .fromInt(4) },
    };
    var segment = try segment_mod.ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &edges);
    defer segment.deinit();

    const exact_texts = [_]ExactTextEntry{
        .{ .kind = .file, .text = "src/main.zig", .id = .fromInt(1) },
        .{ .kind = .function, .text = "main", .id = .fromInt(2) },
        .{ .kind = .document, .text = "README", .id = .fromInt(4) },
        .{ .kind = .concept, .text = "entrypoint", .id = .fromInt(3) },
    };
    const nodes_by_id = [_]NodeInfoEntry{
        .{ .kind = .file, .text = "src/main.zig", .id = .fromInt(1) },
        .{ .kind = .function, .text = "main", .id = .fromInt(2) },
        .{ .kind = .concept, .text = "entrypoint", .id = .fromInt(3) },
        .{ .kind = .document, .text = "README", .id = .fromInt(4) },
    };

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "src/main.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
        .right_text_eq = "main",
    } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "s",
        .rel = .related_to,
        .right_var = "x",
        .right_kind = .concept,
        .right_text_eq = "entrypoint",
    } });
    try ops.append(std.testing.allocator, .{ .project = &.{} });
    try ops.append(std.testing.allocator, .{ .limit = 4 });

    var table = try executeExactTextPath(
        std.testing.allocator,
        .{ .catalog = .{ .exact_texts = &exact_texts, .nodes_by_id = &nodes_by_id }, .segment = &segment },
        .{ .ops = ops },
        .{},
    );
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(u64, 1), table.rows.items[0].get("f").?.toInt());
    try std.testing.expectEqual(@as(u64, 2), table.rows.items[0].get("s").?.toInt());
    try std.testing.expectEqual(@as(u64, 3), table.rows.items[0].get("x").?.toInt());
    try std.testing.expectEqual(@as(u64, 3), table.stats.nodes_visited);
    try std.testing.expectEqual(@as(u64, 2), table.stats.edges_visited);
}

test "segment executor two-hop respects edge budget before second hop result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "segment" });
    defer std.testing.allocator.free(segment_path);

    const edges = [_]segment_mod.EdgeRecord{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(2), .rel = .related_to, .dst = .fromInt(3) },
    };
    var segment = try segment_mod.ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &edges);
    defer segment.deinit();

    const exact_texts = [_]ExactTextEntry{
        .{ .kind = .file, .text = "src/main.zig", .id = .fromInt(1) },
        .{ .kind = .function, .text = "main", .id = .fromInt(2) },
        .{ .kind = .concept, .text = "entrypoint", .id = .fromInt(3) },
    };
    const nodes_by_id = [_]NodeInfoEntry{
        .{ .kind = .file, .text = "src/main.zig", .id = .fromInt(1) },
        .{ .kind = .function, .text = "main", .id = .fromInt(2) },
        .{ .kind = .concept, .text = "entrypoint", .id = .fromInt(3) },
    };

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "src/main.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "s", .rel = .related_to, .right_var = "x", .right_kind = .concept } });
    try ops.append(std.testing.allocator, .{ .project = &.{} });

    var table = try executeExactTextPath(
        std.testing.allocator,
        .{ .catalog = .{ .exact_texts = &exact_texts, .nodes_by_id = &nodes_by_id }, .segment = &segment },
        .{ .ops = ops },
        .{ .max_visited_edges = 1 },
    );
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expectEqual(@as(u64, 1), table.stats.edges_visited);
    try std.testing.expect(table.stats.budget_exceeded);
}

test "segment executor two-hop respects node budget before second hop result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "segment" });
    defer std.testing.allocator.free(segment_path);

    const edges = [_]segment_mod.EdgeRecord{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(2), .rel = .related_to, .dst = .fromInt(3) },
    };
    var segment = try segment_mod.ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &edges);
    defer segment.deinit();

    const exact_texts = [_]ExactTextEntry{
        .{ .kind = .file, .text = "src/main.zig", .id = .fromInt(1) },
        .{ .kind = .function, .text = "main", .id = .fromInt(2) },
        .{ .kind = .concept, .text = "entrypoint", .id = .fromInt(3) },
    };
    const nodes_by_id = [_]NodeInfoEntry{
        .{ .kind = .file, .text = "src/main.zig", .id = .fromInt(1) },
        .{ .kind = .function, .text = "main", .id = .fromInt(2) },
        .{ .kind = .concept, .text = "entrypoint", .id = .fromInt(3) },
    };

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "src/main.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "s", .rel = .related_to, .right_var = "x", .right_kind = .concept } });
    try ops.append(std.testing.allocator, .{ .project = &.{} });

    var table = try executeExactTextPath(
        std.testing.allocator,
        .{ .catalog = .{ .exact_texts = &exact_texts, .nodes_by_id = &nodes_by_id }, .segment = &segment },
        .{ .ops = ops },
        .{ .max_visited_nodes = 2 },
    );
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expectEqual(@as(u64, 2), table.stats.nodes_visited);
    try std.testing.expectEqual(@as(u64, 2), table.stats.edges_visited);
    try std.testing.expect(table.stats.budget_exceeded);
}

test "segment executor rejects unsupported scans and multi-hop shapes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "segment" });
    defer std.testing.allocator.free(segment_path);

    const edge = [_]segment_mod.EdgeRecord{.{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) }};
    var segment = try segment_mod.ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &edge);
    defer segment.deinit();

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "n", .kind = .file } });
    try ops.append(std.testing.allocator, .{ .project = &.{} });
    try std.testing.expectError(
        error.Unsupported,
        executeExactTextPath(
            std.testing.allocator,
            .{ .catalog = .{ .exact_texts = &.{}, .nodes_by_id = &.{} }, .segment = &segment },
            .{ .ops = ops },
            .{},
        ),
    );

    ops.clearRetainingCapacity();
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "src/main.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
        .min_hops = 1,
        .max_hops = 2,
    } });
    try ops.append(std.testing.allocator, .{ .project = &.{} });
    try std.testing.expectError(
        error.Unsupported,
        executeExactTextPath(
            std.testing.allocator,
            .{ .catalog = .{ .exact_texts = &.{}, .nodes_by_id = &.{} }, .segment = &segment },
            .{ .ops = ops },
            .{},
        ),
    );
}
