const std = @import("std");
const task_mutation_arguments_mod = @import("task_mutation_arguments.zig");

const Arguments = task_mutation_arguments_mod.TaskMutationArguments;

/// Append-only controller for the `task-event` command.
///
/// Concrete storage, graph, governance, and clock types remain behind `Ops`.
/// This owner preserves the publication protocol: validate every target,
/// render and validate the complete event text, create and govern the event
/// node, publish the root edge and optional distinct task edge, then expose
/// success output.
pub fn TaskEventCommand(comptime Ops: type) type {
    return struct {
        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 2, std.math.maxInt(usize));
            const parsed = try Arguments.parseEvent(db.rest);
            const root_id = try Ops.parseNodeId(parsed.root_id);
            const task_id = if (parsed.task_id) |raw| try Ops.parseNodeId(raw) else null;
            const relation = if (parsed.relation_label) |label| try Ops.parseRelation(label) else null;

            var context = try Ops.Context.init(allocator, io, db.db_path);
            defer context.deinit();
            try context.validateTargets(allocator, root_id, task_id);

            const event_ns = context.eventNowNs();
            const event_text = try Ops.renderEventText(
                allocator,
                parsed.event_type,
                parsed.note,
            );
            defer allocator.free(event_text);
            try Ops.validateEventText(event_text);

            const event_id = try context.addEventNode(parsed.event_type, event_text);
            try context.applyEventGovernance(
                allocator,
                event_id,
                parsed.event_type,
                event_text,
                event_ns,
                root_id,
                task_id,
                relation,
            );
            try context.addTaskEventEdge(allocator, event_id, root_id);
            if (task_id) |id| {
                if (!Ops.nodeIdsEqual(id, root_id)) {
                    try context.addTaskEventEdge(allocator, event_id, id);
                }
            }

            try writer.print(
                "task_event node={} type={s}\n",
                .{ Ops.nodeIdValue(event_id), Arguments.eventTypeName(parsed.event_type) },
            );
        }
    };
}

const TestWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestWriter) void {
        self.buffer.deinit(self.allocator);
    }

    fn writeAll(self: *TestWriter, bytes: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    fn print(self: *TestWriter, comptime format: []const u8, args: anytype) !void {
        const rendered = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(rendered);
        try self.writeAll(rendered);
    }
};

const TestOps = struct {
    const Relation = enum { depends_on };
    const Step = enum {
        validate_targets,
        event_clock,
        render_text,
        validate_text,
        add_node,
        governance,
        add_edge,
    };

    var steps: [16]Step = undefined;
    var step_count: usize = 0;
    var edge_targets: [4]u64 = undefined;
    var edge_count: usize = 0;
    var deinitialized: usize = 0;
    var validation_error: ?anyerror = null;
    var governance_error: ?anyerror = null;
    var edge_error_call: ?usize = null;
    var governed_event_type: Arguments.EventType = .write_attempt;
    var governed_relation: ?Relation = null;

    fn reset() void {
        step_count = 0;
        edge_count = 0;
        deinitialized = 0;
        validation_error = null;
        governance_error = null;
        edge_error_call = null;
        governed_event_type = .write_attempt;
        governed_relation = null;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn expectSteps(expected: []const Step) !void {
        try std.testing.expectEqualSlices(Step, expected, steps[0..step_count]);
    }

    pub fn parseDbArguments(
        _: std.mem.Allocator,
        _: std.Io,
        args: []const []const u8,
        _: usize,
        _: usize,
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        if (args.len < 2) return error.MissingArgument;
        return .{ .db_path = "db", .rest = args[2..] };
    }

    pub fn parseNodeId(value: []const u8) !u64 {
        const id = std.fmt.parseInt(u64, value, 10) catch return error.InvalidId;
        if (id == 0) return error.InvalidId;
        return id;
    }

    pub fn parseRelation(value: []const u8) !Relation {
        if (std.mem.eql(u8, value, "depends_on")) return .depends_on;
        return error.InvalidRelKind;
    }

    pub fn nodeIdsEqual(a: u64, b: u64) bool {
        return a == b;
    }

    pub fn nodeIdValue(id: u64) u64 {
        return id;
    }

    pub fn renderEventText(
        allocator: std.mem.Allocator,
        event_type: Arguments.EventType,
        note: ?[]const u8,
    ) ![]const u8 {
        record(.render_text);
        return std.fmt.allocPrint(
            allocator,
            "task_event {s}{s}",
            .{ Arguments.eventTypeName(event_type), note orelse "" },
        );
    }

    pub fn validateEventText(text: []const u8) !void {
        record(.validate_text);
        if (!std.mem.startsWith(u8, text, "task_event ")) return error.InvalidRecord;
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, _: []const u8) !Context {
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.deinitialized += 1;
        }

        pub fn validateTargets(_: *Context, _: std.mem.Allocator, _: u64, _: ?u64) !void {
            TestOps.record(.validate_targets);
            if (TestOps.validation_error) |err| return err;
        }

        pub fn eventNowNs(_: *Context) u128 {
            TestOps.record(.event_clock);
            return 7_000;
        }

        pub fn addEventNode(_: *Context, _: Arguments.EventType, _: []const u8) !u64 {
            TestOps.record(.add_node);
            return 99;
        }

        pub fn applyEventGovernance(
            _: *Context,
            _: std.mem.Allocator,
            _: u64,
            event_type: Arguments.EventType,
            _: []const u8,
            _: u128,
            _: u64,
            _: ?u64,
            relation: ?Relation,
        ) !void {
            TestOps.record(.governance);
            TestOps.governed_event_type = event_type;
            TestOps.governed_relation = relation;
            if (TestOps.governance_error) |err| return err;
        }

        pub fn addTaskEventEdge(_: *Context, _: std.mem.Allocator, _: u64, target_id: u64) !void {
            TestOps.record(.add_edge);
            const call_index = TestOps.edge_count;
            TestOps.edge_targets[call_index] = target_id;
            TestOps.edge_count += 1;
            if (TestOps.edge_error_call) |failed_call| {
                if (failed_call == call_index) return error.InvalidRecord;
            }
        }
    };
};

const task_event_command = TaskEventCommand(TestOps);

test "task event validates and governs before publishing edges and output" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try task_event_command.run(
        &.{ "tinykg", "task-event", "7", "dependency_edge_created", "--task", "8", "--relation", "depends_on", "--note", "start" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{
        .validate_targets,
        .event_clock,
        .render_text,
        .validate_text,
        .add_node,
        .governance,
        .add_edge,
        .add_edge,
    });
    try std.testing.expectEqual(Arguments.EventType.dependency_edge_created, TestOps.governed_event_type);
    try std.testing.expectEqual(TestOps.Relation.depends_on, TestOps.governed_relation.?);
    try std.testing.expectEqualSlices(u64, &.{ 7, 8 }, TestOps.edge_targets[0..TestOps.edge_count]);
    try std.testing.expectEqual(@as(usize, 1), TestOps.deinitialized);
    try std.testing.expectEqualStrings(
        "task_event node=99 type=dependency_edge_created\n",
        writer.buffer.items,
    );
}

test "task event target failure performs no mutation or output" {
    TestOps.reset();
    TestOps.validation_error = error.NotFound;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.NotFound,
        task_event_command.run(
            &.{ "tinykg", "task-event", "7", "write_attempt", "--task", "8" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{.validate_targets});
    try std.testing.expectEqual(@as(usize, 0), TestOps.edge_count);
    try std.testing.expectEqual(@as(usize, 1), TestOps.deinitialized);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "task event avoids duplicate edge when task equals root" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try task_event_command.run(
        &.{ "tinykg", "task-event", "7", "prompt_adherence_ok", "--task", "7" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualSlices(u64, &.{7}, TestOps.edge_targets[0..TestOps.edge_count]);
    try std.testing.expectEqual(@as(usize, 1), TestOps.edge_count);
}

test "task event governance failure publishes no edges or output" {
    TestOps.reset();
    TestOps.governance_error = error.InvalidRecord;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRecord,
        task_event_command.run(
            &.{ "tinykg", "task-event", "7", "write_error", "--task", "8" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{
        .validate_targets,
        .event_clock,
        .render_text,
        .validate_text,
        .add_node,
        .governance,
    });
    try std.testing.expectEqual(@as(usize, 0), TestOps.edge_count);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "task event edge failure suppresses success output" {
    TestOps.reset();
    TestOps.edge_error_call = 1;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRecord,
        task_event_command.run(
            &.{ "tinykg", "task-event", "7", "write_attempt", "--task", "8" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{
        .validate_targets,
        .event_clock,
        .render_text,
        .validate_text,
        .add_node,
        .governance,
        .add_edge,
        .add_edge,
    });
    try std.testing.expectEqualSlices(u64, &.{ 7, 8 }, TestOps.edge_targets[0..TestOps.edge_count]);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}
