const std = @import("std");
const core = @import("core.zig");

pub const Node = struct {
    id: core.NodeId,
    kind: core.NodeKind,
    text: []const u8,
    epistemic_status: core.EpistemicStatus = .asserted,
    status: core.RecordStatus = .active,
};

pub const Edge = struct {
    id: core.EdgeId,
    src: core.NodeId,
    dst: core.NodeId,
    rel: core.RelKind,
    epistemic_status: core.EpistemicStatus = .asserted,
    status: core.RecordStatus = .active,
};

pub fn validateNodeText(text: []const u8) !void {
    _ = text;
}

pub const Graph = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node),
    edges: std.ArrayList(Edge),
    node_by_id: std.AutoHashMap(u64, usize),
    edge_ids: std.AutoHashMap(u64, void),
    next_node_id: u64,
    next_edge_id: u64,

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .edges = .empty,
            .node_by_id = std.AutoHashMap(u64, usize).init(allocator),
            .edge_ids = std.AutoHashMap(u64, void).init(allocator),
            .next_node_id = 1,
            .next_edge_id = 1,
        };
    }

    pub fn deinit(self: *Graph) void {
        for (self.nodes.items) |node| {
            self.allocator.free(node.text);
        }
        self.nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.node_by_id.deinit();
        self.edge_ids.deinit();
    }

    pub fn addNode(self: *Graph, kind: core.NodeKind, text: []const u8) !core.NodeId {
        if (self.next_node_id == 0 or self.next_node_id == std.math.maxInt(u64)) return core.Error.InvalidId;
        try validateNodeText(text);
        const id = core.NodeId.fromInt(self.next_node_id);
        if (self.node_by_id.contains(id.toInt())) return core.Error.InvalidId;
        try self.nodes.ensureUnusedCapacity(self.allocator, 1);
        try self.node_by_id.ensureUnusedCapacity(1);
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        const node_index = self.nodes.items.len;
        self.nodes.appendAssumeCapacity(.{
            .id = id,
            .kind = kind,
            .text = owned_text,
        });
        self.node_by_id.putAssumeCapacityNoClobber(id.toInt(), node_index);
        self.next_node_id += 1;
        return id;
    }

    pub fn addEdgeUnchecked(self: *Graph, src: core.NodeId, rel: core.RelKind, dst: core.NodeId) !core.EdgeId {
        if (isReservedNodeId(src) or isReservedNodeId(dst)) return core.Error.InvalidId;
        if (!self.hasNode(src) or !self.hasNode(dst)) return core.Error.NotFound;
        if (self.next_edge_id == 0 or self.next_edge_id == std.math.maxInt(u64)) return core.Error.InvalidId;
        const id = core.EdgeId.fromInt(self.next_edge_id);
        if (self.edge_ids.contains(id.toInt())) return core.Error.InvalidId;
        try self.edges.ensureUnusedCapacity(self.allocator, 1);
        try self.edge_ids.ensureUnusedCapacity(1);
        self.edges.appendAssumeCapacity(.{
            .id = id,
            .src = src,
            .dst = dst,
            .rel = rel,
        });
        self.edge_ids.putAssumeCapacityNoClobber(id.toInt(), {});
        self.next_edge_id += 1;
        return id;
    }

    pub fn addNodeWithId(self: *Graph, id: core.NodeId, kind: core.NodeKind, text: []const u8) !void {
        if (id == .none or self.node_by_id.contains(id.toInt())) return core.Error.InvalidId;
        if (id.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;
        try validateNodeText(text);
        try self.nodes.ensureUnusedCapacity(self.allocator, 1);
        try self.node_by_id.ensureUnusedCapacity(1);
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        const node_index = self.nodes.items.len;
        self.nodes.appendAssumeCapacity(.{
            .id = id,
            .kind = kind,
            .text = owned_text,
        });
        self.node_by_id.putAssumeCapacityNoClobber(id.toInt(), node_index);
        self.next_node_id = @max(self.next_node_id, id.toInt() + 1);
    }

    pub fn addEdgeWithIdUnchecked(self: *Graph, id: core.EdgeId, src: core.NodeId, rel: core.RelKind, dst: core.NodeId) !void {
        if (id == .none or self.edge_ids.contains(id.toInt())) return core.Error.InvalidId;
        if (id.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;
        if (isReservedNodeId(src) or isReservedNodeId(dst)) return core.Error.InvalidId;
        if (!self.hasNode(src) or !self.hasNode(dst)) return core.Error.NotFound;
        try self.edges.ensureUnusedCapacity(self.allocator, 1);
        try self.edge_ids.ensureUnusedCapacity(1);
        self.edges.appendAssumeCapacity(.{
            .id = id,
            .src = src,
            .dst = dst,
            .rel = rel,
        });
        self.edge_ids.putAssumeCapacityNoClobber(id.toInt(), {});
        self.next_edge_id = @max(self.next_edge_id, id.toInt() + 1);
    }

    pub fn hasNode(self: *const Graph, id: core.NodeId) bool {
        return self.getNode(id) != null;
    }

    pub fn getNode(self: *const Graph, id: core.NodeId) ?Node {
        const node_index = self.node_by_id.get(id.toInt()) orelse return null;
        if (node_index >= self.nodes.items.len) return null;
        const node = self.nodes.items[node_index];
        if (node.id.toInt() != id.toInt() or node.status != .active) return null;
        return node;
    }

    pub fn findByText(self: *const Graph, kind_filter: ?core.NodeKind, text: []const u8) ?Node {
        var best: ?Node = null;
        for (self.nodes.items) |node| {
            if (node.status != .active) continue;
            if (kind_filter) |kind| {
                if (node.kind != kind) continue;
            }
            if (!std.mem.eql(u8, node.text, text)) continue;
            if (best == null or node.id.toInt() < best.?.id.toInt()) best = node;
        }
        return best;
    }

    pub fn removeLastNodeIfId(self: *Graph, id: core.NodeId) bool {
        if (self.nodes.items.len == 0) return false;
        const last = self.nodes.items[self.nodes.items.len - 1];
        if (last.id.toInt() != id.toInt()) return false;
        if (self.hasIncidentEdge(id)) return false;
        const removed = self.nodes.pop().?;
        self.allocator.free(removed.text);
        _ = self.node_by_id.remove(id.toInt());
        self.next_node_id = self.recomputeNextNodeId();
        return true;
    }

    pub fn removeLastEdgeIfId(self: *Graph, id: core.EdgeId) bool {
        if (self.edges.items.len == 0) return false;
        const last = self.edges.items[self.edges.items.len - 1];
        if (last.id.toInt() != id.toInt()) return false;
        _ = self.edges.pop();
        _ = self.edge_ids.remove(id.toInt());
        self.next_edge_id = self.recomputeNextEdgeId();
        return true;
    }

    pub fn deleteEdgeById(self: *Graph, id: core.EdgeId) !void {
        if (id == .none or id.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;
        for (self.edges.items) |*edge| {
            if (edge.id.toInt() != id.toInt()) continue;
            if (edge.status != .active) return core.Error.InvalidId;
            edge.status = .deleted;
            return;
        }
        return core.Error.InvalidId;
    }

    fn hasIncidentEdge(self: *const Graph, id: core.NodeId) bool {
        for (self.edges.items) |edge| {
            if (edge.src.toInt() == id.toInt() or edge.dst.toInt() == id.toInt()) return true;
        }
        return false;
    }

    fn recomputeNextNodeId(self: *const Graph) u64 {
        var max_seen: u64 = 0;
        for (self.nodes.items) |node| {
            max_seen = @max(max_seen, node.id.toInt());
        }
        if (max_seen == std.math.maxInt(u64)) return std.math.maxInt(u64);
        return max_seen + 1;
    }

    fn recomputeNextEdgeId(self: *const Graph) u64 {
        var max_seen: u64 = 0;
        for (self.edges.items) |edge| {
            max_seen = @max(max_seen, edge.id.toInt());
        }
        if (max_seen == std.math.maxInt(u64)) return std.math.maxInt(u64);
        return max_seen + 1;
    }
};

fn isReservedNodeId(id: core.NodeId) bool {
    return id == .none or id.toInt() == std.math.maxInt(u64);
}

test "graph adds nodes and edges" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    try std.testing.expectEqual(@as(usize, 2), graph.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), graph.edges.items.len);
    try std.testing.expectEqual(graph.nodes.items.len, graph.node_by_id.count());
    try std.testing.expectEqual(graph.edges.items.len, graph.edge_ids.count());
}

test "graph rejects duplicate persisted ids" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const file = core.NodeId.fromInt(1);
    const func = core.NodeId.fromInt(2);
    try graph.addNodeWithId(file, .file, "src/main.zig");
    try std.testing.expectError(core.Error.InvalidId, graph.addNodeWithId(file, .file, "duplicate"));
    try graph.addNodeWithId(func, .function, "main");

    const edge = core.EdgeId.fromInt(1);
    try graph.addEdgeWithIdUnchecked(edge, file, .defines, func);
    try std.testing.expectError(core.Error.InvalidId, graph.addEdgeWithIdUnchecked(edge, file, .defines, func));
    try std.testing.expectEqual(graph.nodes.items.len, graph.node_by_id.count());
    try std.testing.expectEqual(graph.edges.items.len, graph.edge_ids.count());
}

test "graph exact-text lookup returns lowest matching node id" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    try graph.addNodeWithId(.fromInt(10), .repo, "shared");
    try graph.addNodeWithId(.fromInt(2), .task, "shared");

    try std.testing.expectEqual(@as(u64, 2), graph.findByText(null, "shared").?.id.toInt());
    try std.testing.expectEqual(@as(u64, 10), graph.findByText(.repo, "shared").?.id.toInt());
}

test "graph add node failure does not consume id" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var graph = Graph.init(failing.allocator());
    defer graph.deinit();

    try std.testing.expectError(error.OutOfMemory, graph.addNode(.file, "src/main.zig"));
    try std.testing.expectEqual(@as(u64, 1), graph.next_node_id);
    try std.testing.expectEqual(@as(usize, 0), graph.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), graph.node_by_id.count());
}

test "graph add edge failure does not consume id" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var graph = Graph.init(failing.allocator());
    defer graph.deinit();

    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    failing.fail_index = failing.alloc_index;

    try std.testing.expectError(error.OutOfMemory, graph.addEdgeUnchecked(file, .defines, func));
    try std.testing.expectEqual(@as(u64, 1), graph.next_edge_id);
    try std.testing.expectEqual(@as(usize, 0), graph.edges.items.len);
    try std.testing.expectEqual(@as(usize, 0), graph.edge_ids.count());
}

test "graph explicit-id insert failures do not leave id indexes" {
    var fail_offset: usize = 0;
    var saw_node_failure = false;
    while (fail_offset < 20) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var graph = Graph.init(failing.allocator());
        defer graph.deinit();

        const baseline_alloc_index = failing.alloc_index;
        failing.fail_index = baseline_alloc_index + fail_offset;
        const result = graph.addNodeWithId(.fromInt(10), .task, "rollback node");
        if (result) |_| {
            continue;
        } else |err| switch (err) {
            error.OutOfMemory => {
                saw_node_failure = true;
                try std.testing.expectEqual(@as(usize, 0), graph.nodes.items.len);
                try std.testing.expectEqual(@as(usize, 0), graph.node_by_id.count());
                try std.testing.expect(graph.getNode(.fromInt(10)) == null);
            },
            else => return err,
        }
    }
    try std.testing.expect(saw_node_failure);

    fail_offset = 0;
    var saw_edge_failure = false;
    while (fail_offset < 20) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var graph = Graph.init(failing.allocator());
        defer graph.deinit();
        try graph.addNodeWithId(.fromInt(1), .task, "a");
        try graph.addNodeWithId(.fromInt(2), .task, "b");

        const baseline_alloc_index = failing.alloc_index;
        failing.fail_index = baseline_alloc_index + fail_offset;
        const result = graph.addEdgeWithIdUnchecked(.fromInt(10), .fromInt(1), .depends_on, .fromInt(2));
        if (result) |_| {
            continue;
        } else |err| switch (err) {
            error.OutOfMemory => {
                saw_edge_failure = true;
                try std.testing.expectEqual(@as(usize, 0), graph.edges.items.len);
                try std.testing.expectEqual(@as(usize, 0), graph.edge_ids.count());
            },
            else => return err,
        }
    }
    try std.testing.expect(saw_edge_failure);
}

test "graph remove last node and edge keeps id indexes consistent" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const edge = try graph.addEdgeUnchecked(a, .depends_on, b);

    try std.testing.expect(!graph.removeLastNodeIfId(a));
    try std.testing.expect(!graph.removeLastNodeIfId(b));
    try std.testing.expectEqual(@as(usize, 2), graph.node_by_id.count());
    try std.testing.expect(graph.getNode(a) != null);
    try std.testing.expect(graph.getNode(b) != null);

    try std.testing.expect(graph.removeLastEdgeIfId(edge));
    try std.testing.expectEqual(@as(usize, 0), graph.edges.items.len);
    try std.testing.expectEqual(@as(usize, 0), graph.edge_ids.count());
    try std.testing.expectEqual(@as(u64, 1), graph.next_edge_id);
    const retry_edge = try graph.addEdgeUnchecked(a, .depends_on, b);
    try std.testing.expectEqual(edge.toInt(), retry_edge.toInt());
    try std.testing.expect(!graph.removeLastNodeIfId(b));
    try std.testing.expect(graph.removeLastEdgeIfId(retry_edge));

    try std.testing.expect(graph.removeLastNodeIfId(b));
    try std.testing.expectEqual(@as(usize, 1), graph.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), graph.node_by_id.count());
    try std.testing.expect(graph.getNode(b) == null);
    try std.testing.expectEqual(@as(u64, 2), graph.next_node_id);
    const retry_node = try graph.addNode(.task, "b");
    try std.testing.expectEqual(b.toInt(), retry_node.toInt());
}

test "graph rollback removal preserves allocator above explicit high ids" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    try graph.addNodeWithId(.fromInt(10), .task, "high");
    try graph.addNodeWithId(.fromInt(2), .task, "low");
    try std.testing.expect(graph.removeLastNodeIfId(.fromInt(2)));
    try std.testing.expectEqual(@as(u64, 11), graph.next_node_id);
    const next_node = try graph.addNode(.task, "next");
    try std.testing.expectEqual(@as(u64, 11), next_node.toInt());

    const dst = try graph.addNode(.task, "dst");
    try graph.addEdgeWithIdUnchecked(.fromInt(10), next_node, .depends_on, dst);
    try graph.addEdgeWithIdUnchecked(.fromInt(2), next_node, .blocks, dst);
    try std.testing.expect(graph.removeLastEdgeIfId(.fromInt(2)));
    try std.testing.expectEqual(@as(u64, 11), graph.next_edge_id);
    const next_edge = try graph.addEdgeUnchecked(next_node, .mentions, dst);
    try std.testing.expectEqual(@as(u64, 11), next_edge.toInt());
}

test "graph rejects reserved edge endpoints before missing-node checks" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const file = try graph.addNode(.file, "src/main.zig");

    try std.testing.expectError(core.Error.InvalidId, graph.addEdgeUnchecked(.none, .defines, file));
    try std.testing.expectError(core.Error.InvalidId, graph.addEdgeUnchecked(file, .defines, .none));
    try std.testing.expectError(core.Error.InvalidId, graph.addEdgeUnchecked(.fromInt(std.math.maxInt(u64)), .defines, file));
    try std.testing.expectError(core.Error.InvalidId, graph.addEdgeUnchecked(file, .defines, .fromInt(std.math.maxInt(u64))));

    try std.testing.expectError(core.Error.InvalidId, graph.addEdgeWithIdUnchecked(.fromInt(1), .none, .defines, file));
    try std.testing.expectError(core.Error.InvalidId, graph.addEdgeWithIdUnchecked(.fromInt(1), file, .defines, .none));
    try std.testing.expectError(core.Error.InvalidId, graph.addEdgeWithIdUnchecked(.fromInt(1), .fromInt(std.math.maxInt(u64)), .defines, file));
    try std.testing.expectError(core.Error.InvalidId, graph.addEdgeWithIdUnchecked(.fromInt(1), file, .defines, .fromInt(std.math.maxInt(u64))));

    try std.testing.expectError(core.Error.NotFound, graph.addEdgeUnchecked(file, .defines, .fromInt(99)));
    try std.testing.expectEqual(@as(usize, 0), graph.edges.items.len);
    try std.testing.expectEqual(@as(u64, 1), graph.next_edge_id);
}

test "graph rejects id allocation overflow" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    graph.next_node_id = std.math.maxInt(u64);
    try std.testing.expectError(core.Error.InvalidId, graph.addNode(.file, "overflow"));
    try std.testing.expectError(core.Error.InvalidId, graph.addNodeWithId(.fromInt(std.math.maxInt(u64)), .file, "overflow"));

    graph.next_node_id = 1;
    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    graph.next_edge_id = std.math.maxInt(u64);
    try std.testing.expectError(core.Error.InvalidId, graph.addEdgeUnchecked(file, .defines, func));
    try std.testing.expectError(core.Error.InvalidId, graph.addEdgeWithIdUnchecked(.fromInt(std.math.maxInt(u64)), file, .defines, func));
}

test "graph allows zero-length node text" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const generated = try graph.addNode(.file, "");
    try graph.addNodeWithId(.fromInt(7), .file, "");
    try std.testing.expectEqual(@as(u64, 1), generated.toInt());
    try std.testing.expectEqualStrings("", graph.getNode(generated).?.text);
    try std.testing.expectEqualStrings("", graph.getNode(.fromInt(7)).?.text);
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.items.len);
    try std.testing.expectEqual(@as(u64, 8), graph.next_node_id);
}

test "graph hides non-active nodes from default lookup" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const active = try graph.addNode(.task, "shared");
    const stale = try graph.addNode(.task, "shared");
    for (graph.nodes.items) |*node| {
        if (node.id == stale) node.status = .stale;
    }

    try std.testing.expectEqual(active.toInt(), graph.getNode(active).?.id.toInt());
    try std.testing.expect(graph.getNode(stale) == null);
    try std.testing.expectEqual(active.toInt(), graph.findByText(.task, "shared").?.id.toInt());
    try std.testing.expectError(core.Error.NotFound, graph.addEdgeUnchecked(active, .depends_on, stale));
}
