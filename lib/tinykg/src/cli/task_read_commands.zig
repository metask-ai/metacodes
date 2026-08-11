const std = @import("std");

/// Read-only task CLI control plane. Argument/database adapters and the
/// storage-backed renderers stay private to `cli.zig`; this owner sequences
/// command selection, lock lifetime, repair-and-retry policy, and output
/// publication for the task inspection family.
pub fn TaskReadCommands(comptime Ops: type) type {
    return struct {
        fn retryable(err: anyerror) bool {
            return switch (err) {
                error.FileNotFound, error.InvalidRecord => true,
                else => false,
            };
        }

        pub fn runReady(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parseReadyArguments(allocator, io, args);
            var context = try Ops.ReadContext.init(allocator, io, parsed.db_path);
            defer context.deinit();
            const state = Ops.readReady(&context, allocator, parsed.task_id) catch |err| retry: {
                if (!retryable(err)) return err;
                try context.repair();
                break :retry try Ops.readReady(&context, allocator, parsed.task_id);
            };
            try writer.print("{s}\n", .{state});
        }

        pub fn runPacket(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parsePacketArguments(allocator, io, args);
            var context = try Ops.ReadContext.init(allocator, io, parsed.db_path);
            defer context.deinit();
            const output = Ops.renderPacket(&context, allocator, parsed.task_id, parsed.options) catch |err| retry: {
                if (!retryable(err)) return err;
                try context.repair();
                break :retry try Ops.renderPacket(&context, allocator, parsed.task_id, parsed.options);
            };
            defer allocator.free(output);
            try writer.writeAll(output);
        }

        pub fn runFrontier(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parseFrontierArguments(allocator, io, args);
            if (parsed.options.mine) |identity| _ = try Ops.validateTaskReadAgentIdentity(identity);
            var context = try Ops.ReadContext.init(allocator, io, parsed.db_path);
            defer context.deinit();
            const output = Ops.renderFrontier(&context, allocator, parsed.options) catch |err| retry: {
                if (!retryable(err)) return err;
                try context.repair();
                break :retry try Ops.renderFrontier(&context, allocator, parsed.options);
            };
            defer allocator.free(output);
            try writer.writeAll(output);
        }

        pub fn runAncestry(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parseAncestryArguments(allocator, io, args);
            var context = try Ops.ReadContext.init(allocator, io, parsed.db_path);
            defer context.deinit();
            const output = Ops.renderAncestry(&context, allocator, parsed.task_id, parsed.depth, parsed.limit) catch |err| retry: {
                if (!retryable(err)) return err;
                try context.repair();
                break :retry try Ops.renderAncestry(&context, allocator, parsed.task_id, parsed.depth, parsed.limit);
            };
            defer allocator.free(output);
            try writer.writeAll(output);
        }

        pub fn runMetrics(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parseMetricsArguments(allocator, io, args);
            var context = try Ops.ReadContext.init(allocator, io, parsed.db_path);
            defer context.deinit();
            const output = Ops.renderMetrics(&context, allocator, parsed.root_id, parsed.limit) catch |err| retry: {
                if (!retryable(err)) return err;
                try context.repair();
                break :retry try Ops.renderMetrics(&context, allocator, parsed.root_id, parsed.limit);
            };
            defer allocator.free(output);
            try writer.writeAll(output);
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
    var repaired: usize = 0;
    var deinitialized: usize = 0;
    var failures_remaining: usize = 0;

    fn reset() void {
        repaired = 0;
        deinitialized = 0;
        failures_remaining = 0;
    }

    pub const ReadContext = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, _: []const u8) !ReadContext {
            return .{};
        }

        pub fn deinit(_: *ReadContext) void {
            TestOps.deinitialized += 1;
        }

        pub fn repair(_: *ReadContext) !void {
            TestOps.repaired += 1;
            TestOps.failures_remaining = 0;
        }
    };

    const PacketOptions = struct { format: []const u8 = "text" };
    const FrontierOptions = struct { mine: ?[]const u8 = null };

    pub fn parseReadyArguments(_: std.mem.Allocator, _: std.Io, _: []const []const u8) !struct {
        db_path: []const u8,
        task_id: []const u8,
    } {
        return .{ .db_path = "db", .task_id = "1" };
    }

    pub fn parsePacketArguments(_: std.mem.Allocator, _: std.Io, _: []const []const u8) !struct {
        db_path: []const u8,
        task_id: []const u8,
        options: PacketOptions,
    } {
        return .{ .db_path = "db", .task_id = "1", .options = .{} };
    }

    pub fn parseFrontierArguments(_: std.mem.Allocator, _: std.Io, _: []const []const u8) !struct {
        db_path: []const u8,
        options: FrontierOptions,
    } {
        return .{ .db_path = "db", .options = .{ .mine = "agent" } };
    }

    pub fn parseAncestryArguments(_: std.mem.Allocator, _: std.Io, _: []const []const u8) !struct {
        db_path: []const u8,
        task_id: []const u8,
        depth: usize,
        limit: usize,
    } {
        return .{ .db_path = "db", .task_id = "1", .depth = 3, .limit = 8 };
    }

    pub fn parseMetricsArguments(_: std.mem.Allocator, _: std.Io, _: []const []const u8) !struct {
        db_path: []const u8,
        root_id: []const u8,
        limit: usize,
    } {
        return .{ .db_path = "db", .root_id = "1", .limit = 8 };
    }

    pub fn validateTaskReadAgentIdentity(identity: []const u8) ![]const u8 {
        if (!std.mem.eql(u8, identity, "agent")) return error.InvalidArgument;
        return identity;
    }

    pub fn readReady(_: *ReadContext, _: std.mem.Allocator, _: []const u8) ![]const u8 {
        if (failures_remaining != 0) {
            failures_remaining -= 1;
            return error.InvalidRecord;
        }
        return "ready";
    }

    pub fn renderPacket(_: *ReadContext, allocator: std.mem.Allocator, _: []const u8, _: PacketOptions) ![]u8 {
        if (failures_remaining != 0) {
            failures_remaining -= 1;
            return error.FileNotFound;
        }
        return allocator.dupe(u8, "packet\n");
    }

    pub fn renderFrontier(_: *ReadContext, allocator: std.mem.Allocator, _: FrontierOptions) ![]u8 {
        return allocator.dupe(u8, "frontier\n");
    }

    pub fn renderAncestry(_: *ReadContext, allocator: std.mem.Allocator, _: []const u8, _: usize, _: usize) ![]u8 {
        return allocator.dupe(u8, "ancestry\n");
    }

    pub fn renderMetrics(_: *ReadContext, allocator: std.mem.Allocator, _: []const u8, _: usize) ![]u8 {
        return allocator.dupe(u8, "metrics\n");
    }
};

const test_commands = TaskReadCommands(TestOps);

test "task read command family routes all inspection outputs through one context" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runReady(&.{ "tinykg", "task-ready", "1" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("ready\n", writer.buffer.items);
    writer.buffer.clearRetainingCapacity();
    try test_commands.runPacket(&.{ "tinykg", "task-packet", "1" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("packet\n", writer.buffer.items);
    writer.buffer.clearRetainingCapacity();
    try test_commands.runFrontier(&.{ "tinykg", "task-frontier", "1" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("frontier\n", writer.buffer.items);
    writer.buffer.clearRetainingCapacity();
    try test_commands.runAncestry(&.{ "tinykg", "task-ancestry", "1" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("ancestry\n", writer.buffer.items);
    writer.buffer.clearRetainingCapacity();
    try test_commands.runMetrics(&.{ "tinykg", "task-metrics", "1" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("metrics\n", writer.buffer.items);
    try std.testing.expectEqual(@as(usize, 5), TestOps.deinitialized);
}

test "task read command family repairs one recoverable read before publishing output" {
    TestOps.reset();
    TestOps.failures_remaining = 1;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runReady(&.{ "tinykg", "task-ready", "1" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("ready\n", writer.buffer.items);
    try std.testing.expectEqual(@as(usize, 1), TestOps.repaired);
    try std.testing.expectEqual(@as(usize, 1), TestOps.deinitialized);

    writer.buffer.clearRetainingCapacity();
    TestOps.failures_remaining = 1;
    try test_commands.runPacket(&.{ "tinykg", "task-packet", "1" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("packet\n", writer.buffer.items);
    try std.testing.expectEqual(@as(usize, 2), TestOps.repaired);
}

test "task read command family does not repair non-recoverable failures" {
    TestOps.reset();
    const FailingOps = struct {
        const ReadContext = TestOps.ReadContext;
        pub fn parseReadyArguments(_: std.mem.Allocator, _: std.Io, _: []const []const u8) !struct { db_path: []const u8, task_id: []const u8 } {
            return .{ .db_path = "db", .task_id = "1" };
        }
        pub fn readReady(_: *ReadContext, _: std.mem.Allocator, _: []const u8) ![]const u8 {
            return error.PermissionDenied;
        }
    };
    const FailingCommands = TaskReadCommands(FailingOps);
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.PermissionDenied,
        FailingCommands.runReady(&.{ "tinykg", "task-ready", "1" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 0), TestOps.repaired);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}
