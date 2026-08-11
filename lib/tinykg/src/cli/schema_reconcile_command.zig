const std = @import("std");

/// Narrow command owner for the certified catalog-reconciliation actuator.
///
/// The concrete Store lock, catalog bytes, candidate registry, validation
/// scan, rollback and parity checks remain behind `Ops.Context`.  This module
/// owns only the public grammar and the guarantee that one locked context
/// lives through the complete transaction and final receipt publication.
pub const Arguments = struct {
    db_path: []const u8,
    schema_path: []const u8,
    plan_path: []const u8,
    profiles: ?[]const u8 = null,

    pub fn parse(args: []const []const u8) !Arguments {
        if (args.len <= 2) return error.MissingArgument;
        var result = Arguments{
            .db_path = args[2],
            .schema_path = "",
            .plan_path = "",
        };
        var has_schema = false;
        var has_plan = false;
        var pos: usize = 3;
        while (pos < args.len) {
            const option = args[pos];
            if (pos + 1 >= args.len) return error.MissingArgument;
            const value = args[pos + 1];
            if (std.mem.eql(u8, option, "--schema")) {
                if (has_schema) return error.TooManyArguments;
                has_schema = true;
                result.schema_path = value;
            } else if (std.mem.eql(u8, option, "--plan")) {
                if (has_plan) return error.TooManyArguments;
                has_plan = true;
                result.plan_path = value;
            } else if (std.mem.eql(u8, option, "--profile")) {
                if (result.profiles != null) return error.TooManyArguments;
                result.profiles = value;
            } else {
                return error.UnknownOption;
            }
            pos += 2;
        }
        if (!has_schema or !has_plan) return error.MissingArgument;
        return result;
    }
};

pub fn SchemaReconcileCommand(comptime Ops: type) type {
    return struct {
        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Arguments.parse(args);
            var context = try Ops.Context.init(allocator, io, parsed.db_path);
            defer context.deinit();
            try context.reconcile(writer, parsed.schema_path, parsed.plan_path, parsed.profiles);
        }
    };
}

const TestWriter = struct {
    buffer: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestWriter) void {
        self.buffer.deinit(std.testing.allocator);
    }

    fn writeAll(self: *TestWriter, bytes: []const u8) !void {
        try self.buffer.appendSlice(std.testing.allocator, bytes);
    }
};

const TestOps = struct {
    const Step = enum { init, reconcile, deinit };
    var steps: [4]Step = undefined;
    var len: usize = 0;
    var last_db_path: []const u8 = "";
    var last_schema_path: []const u8 = "";
    var last_plan_path: []const u8 = "";
    var last_profiles: ?[]const u8 = null;
    var reconcile_error: ?anyerror = null;

    fn reset() void {
        len = 0;
        last_db_path = "";
        last_schema_path = "";
        last_plan_path = "";
        last_profiles = null;
        reconcile_error = null;
    }

    fn record(step: Step) void {
        steps[len] = step;
        len += 1;
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, path: []const u8) !Context {
            TestOps.record(.init);
            TestOps.last_db_path = path;
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.record(.deinit);
        }

        pub fn reconcile(_: *Context, writer: anytype, schema_path: []const u8, plan_path: []const u8, profiles: ?[]const u8) !void {
            TestOps.record(.reconcile);
            TestOps.last_schema_path = schema_path;
            TestOps.last_plan_path = plan_path;
            TestOps.last_profiles = profiles;
            if (TestOps.reconcile_error) |err| return err;
            try writer.writeAll("receipt\n");
        }
    };
};

const test_command = SchemaReconcileCommand(TestOps);

test "schema reconcile arguments require one schema and one plan" {
    const parsed = try Arguments.parse(&.{
        "tinykg",    "schema-reconcile", "store.kg",
        "--plan",    "plan.json",        "--profile",
        "agent-dag", "--schema",         "schema.json",
    });
    try std.testing.expectEqualStrings("store.kg", parsed.db_path);
    try std.testing.expectEqualStrings("schema.json", parsed.schema_path);
    try std.testing.expectEqualStrings("plan.json", parsed.plan_path);
    try std.testing.expectEqualStrings("agent-dag", parsed.profiles.?);
    try std.testing.expectError(error.MissingArgument, Arguments.parse(&.{ "tinykg", "schema-reconcile", "db", "--schema", "schema.json" }));
    try std.testing.expectError(error.TooManyArguments, Arguments.parse(&.{ "tinykg", "schema-reconcile", "db", "--schema", "a", "--schema", "b", "--plan", "p" }));
    try std.testing.expectError(error.UnknownOption, Arguments.parse(&.{ "tinykg", "schema-reconcile", "db", "--schema", "a", "--plan", "p", "--force", "yes" }));
}

test "schema reconcile command keeps the locked context through receipt publication" {
    TestOps.reset();
    var writer = TestWriter{};
    defer writer.deinit();
    try test_command.run(&.{ "tinykg", "schema-reconcile", "db", "--schema", "s", "--plan", "p" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .init, .reconcile, .deinit }, TestOps.steps[0..TestOps.len]);
    try std.testing.expectEqualStrings("receipt\n", writer.buffer.items);

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    TestOps.reconcile_error = error.ReconciliationInputChanged;
    try std.testing.expectError(
        error.ReconciliationInputChanged,
        test_command.run(&.{ "tinykg", "schema-reconcile", "db", "--schema", "s", "--plan", "p" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .init, .reconcile, .deinit }, TestOps.steps[0..TestOps.len]);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}
