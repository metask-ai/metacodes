const std = @import("std");

/// Schema-aware exact-text lookup control plane for the `find` command.
///
/// Concrete node kinds, schema registries, Store records, generation checks,
/// and text rendering stay behind `Ops`. This owner keeps syntax ahead of
/// context acquisition, permits one persistent-index repair, and releases a
/// found record before closing the shared Store context.
pub fn FindCommand(comptime Ops: type) type {
    return struct {
        pub const Arguments = struct {
            db_path: []const u8,
            kind_label: []const u8,
            text: []const u8,
            schema_path: ?[]const u8 = null,
            include_history: bool = false,
        };

        pub fn parseArguments(
            allocator: std.mem.Allocator,
            io: std.Io,
            args: []const []const u8,
        ) !Arguments {
            const parsed = try Ops.parseDbArguments(allocator, io, args);
            var positionals: [2][]const u8 = undefined;
            var positional_count: usize = 0;
            var schema_path: ?[]const u8 = null;
            var include_history = false;
            var pos: usize = 0;
            while (pos < parsed.rest.len) {
                const arg = parsed.rest[pos];
                if (std.mem.eql(u8, arg, "--schema")) {
                    if (pos + 1 >= parsed.rest.len) return error.MissingArgument;
                    if (schema_path != null) return error.TooManyArguments;
                    schema_path = parsed.rest[pos + 1];
                    pos += 2;
                } else if (std.mem.eql(u8, arg, "--include-history")) {
                    include_history = true;
                    pos += 1;
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    return error.UnknownOption;
                } else {
                    if (positional_count >= positionals.len) return error.TooManyArguments;
                    positionals[positional_count] = arg;
                    positional_count += 1;
                    pos += 1;
                }
            }
            if (positional_count < 2) return error.MissingArgument;
            return .{
                .db_path = parsed.db_path,
                .kind_label = positionals[0],
                .text = positionals[1],
                .schema_path = schema_path,
                .include_history = include_history,
            };
        }

        fn retryable(err: anyerror) bool {
            return switch (err) {
                error.FileNotFound, error.InvalidRecord => true,
                else => false,
            };
        }

        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try parseArguments(allocator, io, args);
            var context = try Ops.Context.init(
                allocator,
                io,
                parsed.db_path,
                parsed.schema_path,
            );
            defer context.deinit();
            const kind = try context.parseNodeKind(parsed.kind_label);
            var found = context.lookup(
                allocator,
                kind,
                parsed.text,
                parsed.include_history,
            ) catch |err| retry: {
                if (!retryable(err)) return err;
                try context.repair();
                break :retry try context.lookup(
                    allocator,
                    kind,
                    parsed.text,
                    parsed.include_history,
                );
            };
            defer if (found) |*match| match.deinit(allocator);
            if (found) |*match| {
                try context.writeFound(writer, match);
            } else {
                try writer.writeAll("not found\n");
            }
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
    pub const NodeKind = enum {
        observation,
        decision,
    };

    const Step = enum {
        parse_db,
        init,
        parse_kind,
        lookup,
        repair,
        write_found,
        match_deinit,
        context_deinit,
    };

    var steps: [32]Step = undefined;
    var step_count: usize = 0;
    var parse_db_failure: ?anyerror = null;
    var lookup_failure: ?anyerror = null;
    var lookup_failures_remaining: usize = 0;
    var return_match = true;
    var last_schema_path: ?[]const u8 = null;
    var last_kind: ?NodeKind = null;
    var last_text: ?[]const u8 = null;
    var last_include_history = false;

    fn reset() void {
        step_count = 0;
        parse_db_failure = null;
        lookup_failure = null;
        lookup_failures_remaining = 0;
        return_match = true;
        last_schema_path = null;
        last_kind = null;
        last_text = null;
        last_include_history = false;
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
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        record(.parse_db);
        if (parse_db_failure) |err| return err;
        if (args.len < 4) return error.MissingArgument;
        if (args.len > 7) return error.TooManyArguments;
        return .{ .db_path = "db", .rest = args[2..] };
    }

    pub const Match = struct {
        id: u64,

        pub fn deinit(_: *Match, _: std.mem.Allocator) void {
            TestOps.record(.match_deinit);
        }
    };

    pub const Context = struct {
        pub fn init(
            _: std.mem.Allocator,
            _: std.Io,
            _: []const u8,
            schema_path: ?[]const u8,
        ) !Context {
            TestOps.record(.init);
            TestOps.last_schema_path = schema_path;
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.record(.context_deinit);
        }

        pub fn parseNodeKind(_: *Context, label: []const u8) !NodeKind {
            TestOps.record(.parse_kind);
            return std.meta.stringToEnum(NodeKind, label) orelse error.InvalidNodeKind;
        }

        pub fn lookup(
            _: *Context,
            _: std.mem.Allocator,
            kind: NodeKind,
            text: []const u8,
            include_history: bool,
        ) !?Match {
            TestOps.record(.lookup);
            TestOps.last_kind = kind;
            TestOps.last_text = text;
            TestOps.last_include_history = include_history;
            if (TestOps.lookup_failure) |err| {
                if (TestOps.lookup_failures_remaining != 0) {
                    TestOps.lookup_failures_remaining -= 1;
                    return err;
                }
            }
            if (!TestOps.return_match) return null;
            return .{ .id = 7 };
        }

        pub fn repair(_: *Context) !void {
            TestOps.record(.repair);
        }

        pub fn writeFound(_: *Context, writer: anytype, match: *const Match) !void {
            TestOps.record(.write_found);
            try std.testing.expectEqual(@as(u64, 7), match.id);
            try writer.writeAll("7\tdecision\texact value\n");
        }
    };
};

const test_command = FindCommand(TestOps);

test "find arguments preserve schema and history options" {
    TestOps.reset();
    const parsed = try test_command.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "find", "decision", "exact value", "--schema", "schema.json", "--include-history" },
    );
    try std.testing.expectEqualStrings("db", parsed.db_path);
    try std.testing.expectEqualStrings("decision", parsed.kind_label);
    try std.testing.expectEqualStrings("exact value", parsed.text);
    try std.testing.expectEqualStrings("schema.json", parsed.schema_path.?);
    try std.testing.expect(parsed.include_history);
    try TestOps.expectSteps(&.{.parse_db});
}

test "find arguments reject duplicate schema unknown options and missing values before context" {
    TestOps.reset();
    try std.testing.expectError(
        error.MissingArgument,
        test_command.parseArguments(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "find", "decision", "exact value", "--schema" },
        ),
    );
    try TestOps.expectSteps(&.{.parse_db});

    TestOps.reset();
    try std.testing.expectError(
        error.TooManyArguments,
        test_command.parseArguments(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "find", "decision", "--schema", "one", "--schema", "two" },
        ),
    );
    try TestOps.expectSteps(&.{.parse_db});

    TestOps.reset();
    try std.testing.expectError(
        error.UnknownOption,
        test_command.parseArguments(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "find", "decision", "exact value", "--unknown" },
        ),
    );
    try TestOps.expectSteps(&.{.parse_db});
}

test "find arguments preserve database parser failure before command syntax" {
    TestOps.reset();
    TestOps.parse_db_failure = error.InvalidRecord;
    try std.testing.expectError(
        error.InvalidRecord,
        test_command.parseArguments(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "find", "--unknown", "value" },
        ),
    );
    try TestOps.expectSteps(&.{.parse_db});
}

test "find command owns schema kind lookup and found output publication" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try test_command.run(
        &.{ "tinykg", "find", "decision", "exact value", "--schema", "schema.json", "--include-history" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("7\tdecision\texact value\n", writer.buffer.items);
    try std.testing.expectEqualStrings("schema.json", TestOps.last_schema_path.?);
    try std.testing.expectEqual(TestOps.NodeKind.decision, TestOps.last_kind.?);
    try std.testing.expectEqualStrings("exact value", TestOps.last_text.?);
    try std.testing.expect(TestOps.last_include_history);
    try TestOps.expectSteps(&.{
        .parse_db,
        .init,
        .parse_kind,
        .lookup,
        .write_found,
        .match_deinit,
        .context_deinit,
    });
}

test "find command repairs one recoverable exact lookup before publishing" {
    TestOps.reset();
    TestOps.lookup_failure = error.FileNotFound;
    TestOps.lookup_failures_remaining = 1;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try test_command.run(
        &.{ "tinykg", "find", "observation", "exact value" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("7\tdecision\texact value\n", writer.buffer.items);
    try TestOps.expectSteps(&.{
        .parse_db,
        .init,
        .parse_kind,
        .lookup,
        .repair,
        .lookup,
        .write_found,
        .match_deinit,
        .context_deinit,
    });
}

test "find command publishes stable not found output" {
    TestOps.reset();
    TestOps.return_match = false;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try test_command.run(
        &.{ "tinykg", "find", "observation", "missing" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("not found\n", writer.buffer.items);
    try TestOps.expectSteps(&.{
        .parse_db,
        .init,
        .parse_kind,
        .lookup,
        .context_deinit,
    });
}

test "find command does not repair or publish non-recoverable lookup failures" {
    TestOps.reset();
    TestOps.lookup_failure = error.AccessDenied;
    TestOps.lookup_failures_remaining = 1;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try std.testing.expectError(
        error.AccessDenied,
        test_command.run(
            &.{ "tinykg", "find", "observation", "exact value" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
    try TestOps.expectSteps(&.{
        .parse_db,
        .init,
        .parse_kind,
        .lookup,
        .context_deinit,
    });
}

test "find command releases matches and context after output failure" {
    TestOps.reset();
    var writer = FailingWriter{};
    try std.testing.expectError(
        error.OutputClosed,
        test_command.run(
            &.{ "tinykg", "find", "decision", "exact value" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{
        .parse_db,
        .init,
        .parse_kind,
        .lookup,
        .write_found,
        .match_deinit,
        .context_deinit,
    });
}
