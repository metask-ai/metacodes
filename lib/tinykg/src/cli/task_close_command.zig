const std = @import("std");
const task_mutation_arguments_mod = @import("task_mutation_arguments.zig");

const Arguments = task_mutation_arguments_mod.TaskMutationArguments;

/// Transaction controller for the `task-close` command.
///
/// Concrete storage and graph primitives remain behind `Ops.Context`. This
/// owner preserves the command's critical order: authorize the transition,
/// create or attach idempotent evidence, publish one terminal property batch,
/// then expose output. Same-status retries ignore changed inline prose while
/// still accepting an explicit supplemental evidence id.
pub fn TaskCloseCommand(comptime Ops: type) type {
    return struct {
        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 2, 8);
            const parsed = try Arguments.parseClose(db.rest);
            const task_id = try Ops.parseTaskId(parsed.task_id);
            const explicit_evidence_id = if (parsed.evidence_id) |raw|
                try Ops.parseTaskId(raw)
            else
                null;

            var context = try Ops.Context.init(allocator, io, db.db_path);
            defer context.deinit();
            const transition = try context.validateTransition(
                allocator,
                task_id,
                parsed.status,
                parsed.by,
                parsed.force,
            );

            const effective_evidence_id = explicit_evidence_id orelse if (!transition.already_terminal)
                if (parsed.evidence_text) |text|
                    try context.ensureInlineEvidence(allocator, text, transition.recorded_ns)
                else
                    null
            else
                null;
            if (effective_evidence_id) |evidence_id| {
                try context.ensureEvidenceEdge(allocator, task_id, evidence_id);
            }

            const property_publish_count = try context.publishClose(
                allocator,
                task_id,
                parsed.status,
                transition.now_ns,
                transition.already_terminal,
            );
            try writer.print(
                "task_closed\t{}\tstatus={s}\tidempotent={}\tproperty_publishes={}\n",
                .{
                    Ops.taskIdValue(task_id),
                    @tagName(parsed.status),
                    @intFromBool(transition.already_terminal),
                    property_publish_count,
                },
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
    const Step = enum { validate, inline_evidence, evidence_edge, publish };

    var steps: [8]Step = undefined;
    var step_count: usize = 0;
    var deinitialized: usize = 0;
    var validation_error: ?anyerror = null;
    var inline_evidence_error: ?anyerror = null;
    var evidence_edge_error: ?anyerror = null;
    var already_terminal: bool = false;
    var publish_count: usize = 1;
    var published_status: Arguments.CloseStatus = .completed;
    var published_idempotent: bool = false;
    var attached_evidence_id: u64 = 0;
    var inline_evidence_text: []const u8 = "";

    fn reset() void {
        step_count = 0;
        deinitialized = 0;
        validation_error = null;
        inline_evidence_error = null;
        evidence_edge_error = null;
        already_terminal = false;
        publish_count = 1;
        published_status = .completed;
        published_idempotent = false;
        attached_evidence_id = 0;
        inline_evidence_text = "";
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

    pub fn parseTaskId(value: []const u8) !u64 {
        const id = std.fmt.parseInt(u64, value, 10) catch return error.InvalidId;
        if (id == 0) return error.InvalidId;
        return id;
    }

    pub fn taskIdValue(task_id: u64) u64 {
        return task_id;
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, _: []const u8) !Context {
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.deinitialized += 1;
        }

        pub fn validateTransition(
            _: *Context,
            _: std.mem.Allocator,
            _: u64,
            _: Arguments.CloseStatus,
            _: ?[]const u8,
            _: bool,
        ) !struct { recorded_ns: u128, now_ns: u64, already_terminal: bool } {
            TestOps.record(.validate);
            if (TestOps.validation_error) |err| return err;
            return .{
                .recorded_ns = 7_000,
                .now_ns = 7_000,
                .already_terminal = TestOps.already_terminal,
            };
        }

        pub fn ensureInlineEvidence(
            _: *Context,
            _: std.mem.Allocator,
            text: []const u8,
            _: u128,
        ) !u64 {
            TestOps.record(.inline_evidence);
            TestOps.inline_evidence_text = text;
            if (TestOps.inline_evidence_error) |err| return err;
            return 9;
        }

        pub fn ensureEvidenceEdge(
            _: *Context,
            _: std.mem.Allocator,
            _: u64,
            evidence_id: u64,
        ) !void {
            TestOps.record(.evidence_edge);
            TestOps.attached_evidence_id = evidence_id;
            if (TestOps.evidence_edge_error) |err| return err;
        }

        pub fn publishClose(
            _: *Context,
            _: std.mem.Allocator,
            _: u64,
            status: Arguments.CloseStatus,
            _: u64,
            idempotent: bool,
        ) !usize {
            TestOps.record(.publish);
            TestOps.published_status = status;
            TestOps.published_idempotent = idempotent;
            return TestOps.publish_count;
        }
    };
};

const task_close_command = TaskCloseCommand(TestOps);

test "task close validates before inline evidence and terminal publication" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try task_close_command.run(
        &.{ "tinykg", "task-close", "7", "completed", "--by", "agent", "--evidence-text", "verified" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .validate, .inline_evidence, .evidence_edge, .publish });
    try std.testing.expectEqualStrings("verified", TestOps.inline_evidence_text);
    try std.testing.expectEqual(@as(u64, 9), TestOps.attached_evidence_id);
    try std.testing.expectEqual(Arguments.CloseStatus.completed, TestOps.published_status);
    try std.testing.expect(!TestOps.published_idempotent);
    try std.testing.expectEqual(@as(usize, 1), TestOps.deinitialized);
    try std.testing.expectEqualStrings(
        "task_closed\t7\tstatus=completed\tidempotent=0\tproperty_publishes=1\n",
        writer.buffer.items,
    );
}

test "task close rejection leaves evidence and lifecycle state untouched" {
    TestOps.reset();
    TestOps.validation_error = error.ClaimHeld;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.ClaimHeld,
        task_close_command.run(
            &.{ "tinykg", "task-close", "7", "completed", "--evidence-text", "must not exist" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{.validate});
    try std.testing.expectEqual(@as(usize, 1), TestOps.deinitialized);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "task close terminal retry ignores inline prose but accepts explicit evidence" {
    TestOps.reset();
    TestOps.already_terminal = true;
    TestOps.publish_count = 0;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try task_close_command.run(
        &.{ "tinykg", "task-close", "7", "failed", "--evidence-text", "changed retry prose" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .validate, .publish });
    try std.testing.expect(TestOps.published_idempotent);
    try std.testing.expectEqualStrings(
        "task_closed\t7\tstatus=failed\tidempotent=1\tproperty_publishes=0\n",
        writer.buffer.items,
    );

    TestOps.step_count = 0;
    writer.buffer.clearRetainingCapacity();
    try task_close_command.run(
        &.{ "tinykg", "task-close", "7", "failed", "--evidence", "11" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .validate, .evidence_edge, .publish });
    try std.testing.expectEqual(@as(u64, 11), TestOps.attached_evidence_id);
}

test "task close evidence failure prevents terminal publication" {
    TestOps.reset();
    TestOps.evidence_edge_error = error.InvalidRecord;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRecord,
        task_close_command.run(
            &.{ "tinykg", "task-close", "7", "completed", "--evidence-text", "broken evidence" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .validate, .inline_evidence, .evidence_edge });
    try std.testing.expectEqual(@as(usize, 1), TestOps.deinitialized);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}
