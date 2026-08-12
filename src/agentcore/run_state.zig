//! Session-scoped RunState projection primitives.
//!
//! The projector owns every string retained in its snapshot. CoreEvent payloads
//! are borrowed and are consumed synchronously by the caller.

const std = @import("std");
const protocol = @import("metask_agentcore_protocol");

pub const MAX_IN_FLIGHT_TOOLS: usize = 64;

pub const Error = error{OutOfMemory} || error{ResourceLimit};

const OwnedTool = struct {
    tool_call_id: []u8,
    name: []u8,
};

pub const Projector = struct {
    allocator: std.mem.Allocator,
    run_id: u64 = 0,
    transition_seq: u64 = 0,
    phase: protocol.RunStatePhase = .starting,
    turn: u32 = 0,
    tool_calls: u32 = 0,
    tools: std.ArrayList(OwnedTool) = .empty,

    pub fn init(allocator: std.mem.Allocator) Projector {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Projector) void {
        self.clearTools();
        self.tools.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn begin(self: *Projector, run_id: u64) void {
        self.clearTools();
        self.run_id = run_id;
        self.transition_seq = 0;
        self.phase = .starting;
        self.turn = 0;
        self.tool_calls = 0;
    }

    pub fn setPhase(self: *Projector, phase: protocol.RunStatePhase) bool {
        if (self.phase == phase) return false;
        self.phase = phase;
        return true;
    }

    pub fn observeProgress(self: *Projector, turn: u32, tool_calls: u32) bool {
        const changed = self.turn != turn or self.tool_calls != tool_calls;
        self.turn = turn;
        self.tool_calls = tool_calls;
        return changed;
    }

    pub fn addTool(self: *Projector, tool_call_id: []const u8, name: []const u8) Error!bool {
        if (self.findTool(tool_call_id) != null) return false;
        if (self.tools.items.len >= MAX_IN_FLIGHT_TOOLS) return error.ResourceLimit;
        try self.tools.append(self.allocator, .{
            .tool_call_id = try self.allocator.dupe(u8, tool_call_id),
            .name = try self.allocator.dupe(u8, name),
        });
        return true;
    }

    pub fn removeTool(self: *Projector, tool_call_id: []const u8) bool {
        const index = self.findTool(tool_call_id) orelse return false;
        const removed = self.tools.orderedRemove(index);
        self.allocator.free(removed.tool_call_id);
        self.allocator.free(removed.name);
        return true;
    }

    pub fn inFlightCount(self: *const Projector) usize {
        return self.tools.items.len;
    }

    pub fn closeForTerminal(self: *Projector, phase: protocol.RunStatePhase) void {
        self.clearTools();
        self.phase = phase;
    }

    pub fn nextSnapshot(self: *Projector) Error!protocol.RunState {
        const view = try self.allocator.alloc(protocol.RunStateTool, self.tools.items.len);
        for (self.tools.items, view) |tool, *dest| {
            dest.* = .{ .tool_call_id = tool.tool_call_id, .name = tool.name };
        }
        // Allocate and populate the borrowed view before consuming a public
        // sequence number.  An allocation failure must not create an
        // unobservable transition gap.
        self.transition_seq += 1;
        return .{
            .run_id = self.run_id,
            .transition_seq = self.transition_seq,
            .phase = self.phase,
            .turn = self.turn,
            .tool_calls = self.tool_calls,
            .in_flight_tools = view,
        };
    }

    fn findTool(self: *const Projector, id: []const u8) ?usize {
        for (self.tools.items, 0..) |tool, index| {
            if (std.mem.eql(u8, tool.tool_call_id, id)) return index;
        }
        return null;
    }

    fn clearTools(self: *Projector) void {
        for (self.tools.items) |tool| {
            self.allocator.free(tool.tool_call_id);
            self.allocator.free(tool.name);
        }
        self.tools.clearRetainingCapacity();
    }
};

test "projector tracks concurrent tools and closes terminal snapshots" {
    var projector = Projector.init(std.testing.allocator);
    defer projector.deinit();
    projector.begin(9);
    try std.testing.expect(try projector.addTool("read", "Read"));
    try std.testing.expect(try projector.addTool("bash", "Bash"));
    try std.testing.expect(projector.setPhase(.executing_tools));
    const snapshot = try projector.nextSnapshot();
    try std.testing.expectEqual(@as(usize, 2), snapshot.in_flight_tools.len);
    std.testing.allocator.free(snapshot.in_flight_tools);
    try std.testing.expect(projector.removeTool("read"));
    try std.testing.expect(!projector.removeTool("read"));
    projector.closeForTerminal(.failed);
    const terminal_snapshot = try projector.nextSnapshot();
    defer std.testing.allocator.free(terminal_snapshot.in_flight_tools);
    try std.testing.expectEqual(@as(usize, 0), terminal_snapshot.in_flight_tools.len);
    try std.testing.expectEqual(protocol.RunStatePhase.failed, terminal_snapshot.phase);
}

test "projector owns tool references independently of input buffers" {
    var projector = Projector.init(std.testing.allocator);
    defer projector.deinit();
    var id = [_]u8{ 'a', 'b' };
    var name = [_]u8{ 'R', 'e', 'a', 'd' };
    projector.begin(1);
    _ = try projector.addTool(&id, &name);
    @memset(&id, 'x');
    @memset(&name, 'y');
    const snapshot = try projector.nextSnapshot();
    defer std.testing.allocator.free(snapshot.in_flight_tools);
    try std.testing.expectEqualStrings("ab", snapshot.in_flight_tools[0].tool_call_id);
    try std.testing.expectEqualStrings("Read", snapshot.in_flight_tools[0].name);
}
