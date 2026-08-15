const std = @import("std");

/// Node-by-id read command family.
///
/// Concrete node ids, Store/schema representations, version traversal, and
/// renderers stay behind `Ops`. This owner keeps the four public read paths on
/// one syntax/lifetime/retry contract while preserving the historical
/// distinction that `get` opens its context before parsing the node id and the
/// lower-level `node` command parses the id first.
pub fn NodeReadCommands(comptime Ops: type) type {
    return struct {
        const OutputFormat = enum { text, json };

        const GetArguments = struct {
            node_id: []const u8,
            format: OutputFormat = .text,
            meta: bool = false,
            include_text: bool = false,
        };

        const VersionArguments = struct {
            node_id: []const u8,
            limit: usize = 16,
        };

        fn retryable(err: anyerror) bool {
            return switch (err) {
                error.FileNotFound, error.InvalidRecord => true,
                else => false,
            };
        }

        fn parseGetArguments(rest: []const []const u8) !GetArguments {
            if (rest.len == 0) return error.MissingArgument;
            var parsed = GetArguments{ .node_id = rest[0] };
            var pos: usize = 1;
            while (pos < rest.len) {
                const option = rest[pos];
                if (std.mem.eql(u8, option, "--format")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    parsed.format = if (std.mem.eql(u8, rest[pos + 1], "text"))
                        .text
                    else if (std.mem.eql(u8, rest[pos + 1], "json"))
                        .json
                    else
                        return error.InvalidFormat;
                    pos += 2;
                } else if (std.mem.eql(u8, option, "--meta")) {
                    parsed.meta = true;
                    pos += 1;
                } else if (std.mem.eql(u8, option, "--include-text")) {
                    parsed.include_text = true;
                    pos += 1;
                } else if (std.mem.startsWith(u8, option, "--")) {
                    return error.UnknownOption;
                } else {
                    return error.TooManyArguments;
                }
            }
            if (parsed.include_text and parsed.format != .json) return error.Unsupported;
            if (parsed.meta and parsed.format != .json) return error.Unsupported;
            return parsed;
        }

        fn parseVersionArguments(rest: []const []const u8) !VersionArguments {
            var node_id: ?[]const u8 = null;
            var limit: usize = 16;
            var pos: usize = 0;
            while (pos < rest.len) {
                const arg = rest[pos];
                if (std.mem.eql(u8, arg, "--limit")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    const parsed_limit = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
                    if (parsed_limit == 0 or parsed_limit > Ops.maxResults()) return error.InvalidLimit;
                    limit = parsed_limit;
                    pos += 2;
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    return error.UnknownOption;
                } else {
                    if (node_id != null) return error.TooManyArguments;
                    node_id = arg;
                    pos += 1;
                }
            }
            return .{
                .node_id = node_id orelse return error.MissingArgument,
                .limit = limit,
            };
        }

        fn renderGetWithRepair(
            context: *Ops.Context,
            allocator: std.mem.Allocator,
            node_id: Ops.NodeId,
            parsed: GetArguments,
        ) ![]u8 {
            return context.renderGet(allocator, node_id, parsed) catch |err| retry: {
                if (!retryable(err)) return err;
                try context.repair();
                break :retry try context.renderGet(allocator, node_id, parsed);
            };
        }

        pub fn runGet(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 1, 6);
            const parsed = try parseGetArguments(db.rest);
            var context = try Ops.Context.init(allocator, io, db.db_path);
            defer context.deinit();
            // Preserve the established `get` error priority: opening an
            // explicit store precedes numeric node-id validation.
            const node_id = try Ops.parseNodeId(parsed.node_id);
            const output = try renderGetWithRepair(&context, allocator, node_id, parsed);
            defer allocator.free(output);
            try writer.writeAll(output);
        }

        pub fn runNode(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 1, 6);
            const parsed = try parseGetArguments(db.rest);
            // The lower-level `node` spelling historically validates the id
            // before acquiring the store context.
            const node_id = try Ops.parseNodeId(parsed.node_id);
            var context = try Ops.Context.init(allocator, io, db.db_path);
            defer context.deinit();
            const output = try renderGetWithRepair(&context, allocator, node_id, parsed);
            defer allocator.free(output);
            try writer.writeAll(output);
        }


        /// Daemon-resident point reads: identical parsing and rendering, but
        /// against a store the caller keeps open. No per-request store
        /// open/close, no CLI lock, and no repair from a borrowed context.
        pub fn runGetWithStore(
            store: anytype,
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 1, 6);
            const parsed = try parseGetArguments(db.rest);
            if (!std.mem.eql(u8, db.db_path, store.dir_path)) return error.StorePathMismatch;
            var context = Ops.Context.initBorrowed(store);
            defer context.deinit();
            const node_id = try Ops.parseNodeId(parsed.node_id);
            const output = try renderGetWithRepair(&context, allocator, node_id, parsed);
            defer allocator.free(output);
            try writer.writeAll(output);
        }

        pub fn runNodeWithStore(
            store: anytype,
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 1, 6);
            const parsed = try parseGetArguments(db.rest);
            const node_id = try Ops.parseNodeId(parsed.node_id);
            if (!std.mem.eql(u8, db.db_path, store.dir_path)) return error.StorePathMismatch;
            var context = Ops.Context.initBorrowed(store);
            defer context.deinit();
            const output = try renderGetWithRepair(&context, allocator, node_id, parsed);
            defer allocator.free(output);
            try writer.writeAll(output);
        }

        pub fn runVersions(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 1, 3);
            const parsed = try parseVersionArguments(db.rest);
            const node_id = try Ops.parseNodeId(parsed.node_id);
            var context = try Ops.Context.init(allocator, io, db.db_path);
            defer context.deinit();
            const output = context.renderVersions(allocator, node_id, parsed.limit) catch |err| retry: {
                if (!retryable(err)) return err;
                try context.repair();
                break :retry try context.renderVersions(allocator, node_id, parsed.limit);
            };
            defer allocator.free(output);
            try writer.writeAll(output);
        }

        pub fn runLatest(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 1, 3);
            const parsed = try parseVersionArguments(db.rest);
            const node_id = try Ops.parseNodeId(parsed.node_id);
            var context = try Ops.Context.init(allocator, io, db.db_path);
            defer context.deinit();
            const output = context.renderLatest(allocator, node_id, parsed.limit) catch |err| retry: {
                if (!retryable(err)) return err;
                try context.repair();
                break :retry try context.renderLatest(allocator, node_id, parsed.limit);
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
};

const FailingWriter = struct {
    fn writeAll(_: *FailingWriter, _: []const u8) error{OutputClosed}!void {
        return error.OutputClosed;
    }
};

const TestOps = struct {
    pub const NodeId = u64;

    const Step = enum {
        parse_db,
        parse_node_id,
        open,
        render_get,
        render_versions,
        render_latest,
        repair,
        close,
    };

    var steps: [32]Step = undefined;
    var step_count: usize = 0;
    var next_failure: ?anyerror = null;
    var failures_remaining: usize = 0;

    fn reset() void {
        step_count = 0;
        next_failure = null;
        failures_remaining = 0;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn expectSteps(expected: []const Step) !void {
        try std.testing.expectEqualSlices(Step, expected, steps[0..step_count]);
    }

    pub fn maxResults() usize {
        return 64;
    }

    pub fn parseDbArguments(
        _: std.mem.Allocator,
        _: std.Io,
        args: []const []const u8,
        min_rest: usize,
        max_rest: usize,
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        record(.parse_db);
        const rest = args[2..];
        if (rest.len < min_rest) return error.MissingArgument;
        if (rest.len > max_rest) return error.TooManyArguments;
        return .{ .db_path = "db", .rest = rest };
    }

    pub fn parseNodeId(value: []const u8) !NodeId {
        record(.parse_node_id);
        return std.fmt.parseInt(u64, value, 10) catch return error.InvalidNodeId;
    }

    fn render(allocator: std.mem.Allocator, step: Step, output: []const u8) ![]u8 {
        record(step);
        if (failures_remaining != 0) {
            failures_remaining -= 1;
            return next_failure.?;
        }
        return allocator.dupe(u8, output);
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, _: []const u8) !Context {
            TestOps.record(.open);
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.record(.close);
        }

        pub fn repair(_: *Context) !void {
            TestOps.record(.repair);
        }

        pub fn renderGet(
            _: *Context,
            allocator: std.mem.Allocator,
            node_id: NodeId,
            parsed: anytype,
        ) ![]u8 {
            try std.testing.expectEqual(@as(u64, 7), node_id);
            if (parsed.format == .json) return TestOps.render(allocator, .render_get, "{\"id\":7}\n");
            return TestOps.render(allocator, .render_get, "7\tnote\tvalue\n");
        }

        pub fn renderVersions(_: *Context, allocator: std.mem.Allocator, node_id: NodeId, limit: usize) ![]u8 {
            try std.testing.expectEqual(@as(u64, 7), node_id);
            try std.testing.expectEqual(@as(usize, 8), limit);
            return TestOps.render(allocator, .render_versions, "node_versions\t7\tlimit=8\n");
        }

        pub fn renderLatest(_: *Context, allocator: std.mem.Allocator, node_id: NodeId, limit: usize) ![]u8 {
            try std.testing.expectEqual(@as(u64, 7), node_id);
            try std.testing.expectEqual(@as(usize, 8), limit);
            return TestOps.render(allocator, .render_latest, "node_latest\t7\tlimit=8\n");
        }
    };
};

const test_commands = NodeReadCommands(TestOps);

test "node read command family routes all four complete outputs" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    try test_commands.runGet(&.{ "tinykg", "get", "7" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("7\tnote\tvalue\n", writer.buffer.items);
    try TestOps.expectSteps(&.{ .parse_db, .open, .parse_node_id, .render_get, .close });

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runNode(&.{ "tinykg", "node", "7", "--format", "json" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("{\"id\":7}\n", writer.buffer.items);
    try TestOps.expectSteps(&.{ .parse_db, .parse_node_id, .open, .render_get, .close });

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runVersions(&.{ "tinykg", "node-versions", "7", "--limit", "8" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("node_versions\t7\tlimit=8\n", writer.buffer.items);
    try TestOps.expectSteps(&.{ .parse_db, .parse_node_id, .open, .render_versions, .close });

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runLatest(&.{ "tinykg", "node-latest", "7", "--limit", "8" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("node_latest\t7\tlimit=8\n", writer.buffer.items);
    try TestOps.expectSteps(&.{ .parse_db, .parse_node_id, .open, .render_latest, .close });
}

test "node read commands preserve get and node id error precedence" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    try std.testing.expectError(
        error.InvalidNodeId,
        test_commands.runGet(&.{ "tinykg", "get", "bad" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{ .parse_db, .open, .parse_node_id, .close });

    TestOps.reset();
    try std.testing.expectError(
        error.InvalidNodeId,
        test_commands.runNode(&.{ "tinykg", "node", "bad" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{ .parse_db, .parse_node_id });
}

test "node read arguments fail before context acquisition" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    try std.testing.expectError(
        error.Unsupported,
        test_commands.runGet(&.{ "tinykg", "get", "7", "--meta" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{.parse_db});

    TestOps.reset();
    try std.testing.expectError(
        error.InvalidLimit,
        test_commands.runVersions(&.{ "tinykg", "node-versions", "7", "--limit", "65" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{.parse_db});
}

test "node read command family repairs one recoverable read before output" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    TestOps.next_failure = error.FileNotFound;
    TestOps.failures_remaining = 1;
    try test_commands.runGet(&.{ "tinykg", "get", "7" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("7\tnote\tvalue\n", writer.buffer.items);
    try TestOps.expectSteps(&.{ .parse_db, .open, .parse_node_id, .render_get, .repair, .render_get, .close });

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    TestOps.next_failure = error.InvalidRecord;
    TestOps.failures_remaining = 1;
    try test_commands.runLatest(&.{ "tinykg", "node-latest", "7", "--limit", "8" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("node_latest\t7\tlimit=8\n", writer.buffer.items);
    try TestOps.expectSteps(&.{ .parse_db, .parse_node_id, .open, .render_latest, .repair, .render_latest, .close });
}

test "node read command family never repairs twice or publishes failed output" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    TestOps.next_failure = error.FileNotFound;
    TestOps.failures_remaining = 2;
    try std.testing.expectError(
        error.FileNotFound,
        test_commands.runVersions(&.{ "tinykg", "node-versions", "7", "--limit", "8" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
    try TestOps.expectSteps(&.{ .parse_db, .parse_node_id, .open, .render_versions, .repair, .render_versions, .close });
}

test "node read non-recoverable failures close context without output" {
    TestOps.reset();
    TestOps.next_failure = error.BudgetExceeded;
    TestOps.failures_remaining = 1;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.BudgetExceeded,
        test_commands.runLatest(&.{ "tinykg", "node-latest", "7", "--limit", "8" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
    try TestOps.expectSteps(&.{ .parse_db, .parse_node_id, .open, .render_latest, .close });
}

test "node read lifetimes close after writer failure" {
    TestOps.reset();
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        test_commands.runNode(&.{ "tinykg", "node", "7" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{ .parse_db, .parse_node_id, .open, .render_get, .close });
}
