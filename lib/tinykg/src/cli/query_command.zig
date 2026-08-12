const std = @import("std");

/// TinyQL `query` and `query-explain` CLI control plane.
///
/// Concrete AST, schema/catalog, Store, type-checker, planner, optimizer,
/// retained-reader, execution, and rendering representations stay behind
/// `Ops`. This owner keeps free-text option parsing ahead of AST parsing,
/// parses the AST before acquiring the locked Store context, permits one
/// persistent-index repair, and publishes output only after a complete render.
pub fn QueryCommand(comptime Ops: type) type {
    return struct {
        pub const Arguments = struct {
            db_path: []const u8,
            query: []u8,
            owned_db_path: ?[]u8,
            schema_path: ?[]const u8,
            max_postings_scanned: usize,
            timeout_ms: u64,

            pub fn deinit(self: Arguments, allocator: std.mem.Allocator) void {
                allocator.free(self.query);
                if (self.owned_db_path) |path| allocator.free(path);
            }
        };

        fn parseProfile(value: []const u8) !Ops.Profile {
            if (std.mem.eql(u8, value, "interactive")) return .interactive;
            if (std.mem.eql(u8, value, "agent-memory")) return .agent_memory;
            return error.InvalidLimit;
        }

        fn applyProfile(
            profile: Ops.Profile,
            max_postings_scanned: *usize,
            timeout_ms: *u64,
            max_postings_explicit: bool,
            timeout_explicit: bool,
        ) void {
            switch (profile) {
                .interactive => {},
                .agent_memory => {
                    if (!max_postings_explicit) max_postings_scanned.* = Ops.agentMemoryMaxPostings();
                    if (!timeout_explicit) timeout_ms.* = Ops.agentMemoryTimeoutMs();
                },
            }
        }

        pub fn parseArguments(
            allocator: std.mem.Allocator,
            io: std.Io,
            args: []const []const u8,
        ) !Arguments {
            var parsed = try Ops.parseFreeTextDbArguments(allocator, io, args);
            errdefer parsed.deinit(allocator);

            var schema_path: ?[]const u8 = null;
            var max_postings_scanned = Ops.defaultMaxPostings();
            var timeout_ms = Ops.defaultTimeoutMs();
            var max_postings_explicit = false;
            var timeout_explicit = false;
            var query_end = parsed.rest.len;
            while (query_end >= 2) {
                const option = parsed.rest[query_end - 2];
                const value = parsed.rest[query_end - 1];
                if (std.mem.eql(u8, option, "--schema")) {
                    schema_path = value;
                    query_end -= 2;
                } else if (std.mem.eql(u8, option, "--max-postings")) {
                    max_postings_scanned = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLimit;
                    if (max_postings_scanned > Ops.maxCliPostings()) return error.InvalidLimit;
                    max_postings_explicit = true;
                    query_end -= 2;
                } else if (std.mem.eql(u8, option, "--timeout-ms")) {
                    timeout_ms = std.fmt.parseInt(u64, value, 10) catch return error.InvalidLimit;
                    if (timeout_ms == 0 or timeout_ms > Ops.maxCliTimeoutMs()) return error.InvalidLimit;
                    timeout_explicit = true;
                    query_end -= 2;
                } else if (std.mem.eql(u8, option, "--profile")) {
                    applyProfile(
                        try parseProfile(value),
                        &max_postings_scanned,
                        &timeout_ms,
                        max_postings_explicit,
                        timeout_explicit,
                    );
                    query_end -= 2;
                } else if (std.mem.startsWith(u8, option, "--")) {
                    return error.UnknownOption;
                } else {
                    break;
                }
            }
            if (query_end == 0) return error.MissingArgument;
            return .{
                .db_path = parsed.db_path,
                .query = try Ops.joinArguments(allocator, parsed.rest[0..query_end]),
                .owned_db_path = parsed.owned_db_path,
                .schema_path = schema_path,
                .max_postings_scanned = max_postings_scanned,
                .timeout_ms = timeout_ms,
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
            explain: bool,
        ) !void {
            const parsed = try parseArguments(allocator, io, args);
            defer parsed.deinit(allocator);

            const syntax = try Ops.parseSyntax(allocator, parsed.query);
            defer Ops.deinitSyntax(allocator, syntax);

            var context = try Ops.Context.init(
                allocator,
                io,
                parsed.db_path,
                parsed.schema_path,
                syntax,
            );
            defer context.deinit();

            const output = context.render(
                allocator,
                parsed.max_postings_scanned,
                parsed.timeout_ms,
                explain,
            ) catch |err| retry: {
                if (!retryable(err)) return err;
                try context.repair();
                break :retry try context.render(
                    allocator,
                    parsed.max_postings_scanned,
                    parsed.timeout_ms,
                    explain,
                );
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
    pub const Profile = enum { interactive, agent_memory };
    pub const Syntax = struct {};

    const Step = enum {
        parse_db,
        parsed_db_deinit,
        join,
        parse_syntax,
        init_context,
        render,
        repair,
        context_deinit,
        syntax_deinit,
    };

    var steps: [64]Step = undefined;
    var step_count: usize = 0;
    var own_db_path = false;
    var syntax_failure: ?anyerror = null;
    var context_failure: ?anyerror = null;
    var render_failure: ?anyerror = null;
    var render_failures_remaining: usize = 0;
    var last_query_buffer: [256]u8 = undefined;
    var last_query_len: usize = 0;
    var last_schema_path: ?[]const u8 = null;
    var last_max_postings: usize = 0;
    var last_timeout_ms: u64 = 0;
    var last_explain = false;

    fn reset() void {
        step_count = 0;
        own_db_path = false;
        syntax_failure = null;
        context_failure = null;
        render_failure = null;
        render_failures_remaining = 0;
        last_query_len = 0;
        last_schema_path = null;
        last_max_postings = 0;
        last_timeout_ms = 0;
        last_explain = false;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn expectSteps(expected: []const Step) !void {
        try std.testing.expectEqualSlices(Step, expected, steps[0..step_count]);
    }

    pub const ParsedFreeText = struct {
        db_path: []const u8,
        rest: []const []const u8,
        owned_db_path: ?[]u8,

        pub fn deinit(self: ParsedFreeText, allocator: std.mem.Allocator) void {
            if (self.owned_db_path) |path| allocator.free(path);
            TestOps.record(.parsed_db_deinit);
        }
    };

    pub fn parseFreeTextDbArguments(
        allocator: std.mem.Allocator,
        _: std.Io,
        args: []const []const u8,
    ) !ParsedFreeText {
        record(.parse_db);
        if (args.len <= 2) return error.MissingArgument;
        if (own_db_path) {
            const path = try allocator.dupe(u8, "owned.kg");
            return .{ .db_path = path, .rest = args[2..], .owned_db_path = path };
        }
        return .{ .db_path = "db", .rest = args[2..], .owned_db_path = null };
    }

    pub fn joinArguments(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
        record(.join);
        return std.mem.join(allocator, " ", parts);
    }

    pub fn defaultMaxPostings() usize {
        return 40;
    }

    pub fn defaultTimeoutMs() u64 {
        return 50;
    }

    pub fn maxCliPostings() usize {
        return 10_000;
    }

    pub fn maxCliTimeoutMs() u64 {
        return 60_000;
    }

    pub fn agentMemoryMaxPostings() usize {
        return 4_000;
    }

    pub fn agentMemoryTimeoutMs() u64 {
        return 5_000;
    }

    pub fn parseSyntax(_: std.mem.Allocator, query: []const u8) !Syntax {
        record(.parse_syntax);
        if (query.len > last_query_buffer.len) return error.RecordTooLarge;
        @memcpy(last_query_buffer[0..query.len], query);
        last_query_len = query.len;
        if (syntax_failure) |err| return err;
        return .{};
    }

    pub fn deinitSyntax(_: std.mem.Allocator, _: Syntax) void {
        record(.syntax_deinit);
    }

    pub const Context = struct {
        pub fn init(
            _: std.mem.Allocator,
            _: std.Io,
            _: []const u8,
            schema_path: ?[]const u8,
            _: Syntax,
        ) !Context {
            TestOps.record(.init_context);
            TestOps.last_schema_path = schema_path;
            if (TestOps.context_failure) |err| return err;
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.record(.context_deinit);
        }

        pub fn render(
            _: *Context,
            allocator: std.mem.Allocator,
            max_postings_scanned: usize,
            timeout_ms: u64,
            explain: bool,
        ) ![]u8 {
            TestOps.record(.render);
            TestOps.last_max_postings = max_postings_scanned;
            TestOps.last_timeout_ms = timeout_ms;
            TestOps.last_explain = explain;
            if (TestOps.render_failure) |err| {
                if (TestOps.render_failures_remaining != 0) {
                    TestOps.render_failures_remaining -= 1;
                    return err;
                }
            }
            return allocator.dupe(u8, if (explain) "query explain output\n" else "query output\n");
        }

        pub fn repair(_: *Context) !void {
            TestOps.record(.repair);
        }
    };
};

const test_command = QueryCommand(TestOps);

test "query arguments preserve free text schema and default budgets" {
    TestOps.reset();
    var parsed = try test_command.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "query", "MATCH", "(n:task)", "RETURN", "n", "--schema", "schema.json" },
    );
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("db", parsed.db_path);
    try std.testing.expectEqualStrings("MATCH (n:task) RETURN n", parsed.query);
    try std.testing.expectEqualStrings("schema.json", parsed.schema_path.?);
    try std.testing.expectEqual(@as(usize, 40), parsed.max_postings_scanned);
    try std.testing.expectEqual(@as(u64, 50), parsed.timeout_ms);

    var literal = try test_command.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "query", "--schema" },
    );
    defer literal.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("--schema", literal.query);
    try std.testing.expectEqual(@as(?[]const u8, null), literal.schema_path);
}

test "query arguments preserve profile budgets and explicit overrides" {
    TestOps.reset();
    var profiled = try test_command.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "query", "MATCH (n) RETURN n", "--profile", "agent-memory" },
    );
    defer profiled.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4_000), profiled.max_postings_scanned);
    try std.testing.expectEqual(@as(u64, 5_000), profiled.timeout_ms);

    var override_after = try test_command.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "query", "MATCH (n) RETURN n", "--profile", "agent-memory", "--max-postings", "42", "--timeout-ms", "100" },
    );
    defer override_after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 42), override_after.max_postings_scanned);
    try std.testing.expectEqual(@as(u64, 100), override_after.timeout_ms);

    var override_before = try test_command.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "query", "MATCH (n) RETURN n", "--max-postings", "43", "--timeout-ms", "101", "--profile", "agent-memory" },
    );
    defer override_before.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 43), override_before.max_postings_scanned);
    try std.testing.expectEqual(@as(u64, 101), override_before.timeout_ms);
}

test "query arguments reject malformed trailing options before parsing" {
    TestOps.reset();
    try std.testing.expectError(
        error.InvalidLimit,
        test_command.parseArguments(std.testing.allocator, std.testing.io, &.{ "tinykg", "query", "MATCH (n) RETURN n", "--max-postings", "bad" }),
    );
    try std.testing.expectError(
        error.InvalidLimit,
        test_command.parseArguments(std.testing.allocator, std.testing.io, &.{ "tinykg", "query", "MATCH (n) RETURN n", "--timeout-ms", "0" }),
    );
    try std.testing.expectError(
        error.InvalidLimit,
        test_command.parseArguments(std.testing.allocator, std.testing.io, &.{ "tinykg", "query", "MATCH (n) RETURN n", "--profile", "batch" }),
    );
    try std.testing.expectError(
        error.UnknownOption,
        test_command.parseArguments(std.testing.allocator, std.testing.io, &.{ "tinykg", "query", "MATCH (n) RETURN n", "--unknown", "value" }),
    );
    try std.testing.expect(std.mem.indexOfScalar(TestOps.Step, TestOps.steps[0..TestOps.step_count], .parse_syntax) == null);
    try std.testing.expect(std.mem.indexOfScalar(TestOps.Step, TestOps.steps[0..TestOps.step_count], .init_context) == null);
}

test "query arguments release owned database path after later parse failure" {
    TestOps.reset();
    TestOps.own_db_path = true;
    try std.testing.expectError(
        error.InvalidLimit,
        test_command.parseArguments(std.testing.allocator, std.testing.io, &.{ "tinykg", "query", "MATCH (n) RETURN n", "--timeout-ms", "0" }),
    );
    try TestOps.expectSteps(&.{ .parse_db, .parsed_db_deinit });
}

test "query command parses ast before opening context and publishes complete output" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_command.run(
        &.{ "tinykg", "query", "MATCH", "(n:task)", "RETURN", "n", "--schema", "schema.json", "--max-postings", "77", "--timeout-ms", "88" },
        &writer,
        std.testing.allocator,
        std.testing.io,
        false,
    );
    try std.testing.expectEqualStrings("query output\n", writer.buffer.items);
    try std.testing.expectEqualStrings("MATCH (n:task) RETURN n", TestOps.last_query_buffer[0..TestOps.last_query_len]);
    try std.testing.expectEqualStrings("schema.json", TestOps.last_schema_path.?);
    try std.testing.expectEqual(@as(usize, 77), TestOps.last_max_postings);
    try std.testing.expectEqual(@as(u64, 88), TestOps.last_timeout_ms);
    try std.testing.expect(!TestOps.last_explain);
    try TestOps.expectSteps(&.{ .parse_db, .join, .parse_syntax, .init_context, .render, .context_deinit, .syntax_deinit });
}

test "query explain command forwards explain mode" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_command.run(
        &.{ "tinykg", "query-explain", "MATCH (n) RETURN n" },
        &writer,
        std.testing.allocator,
        std.testing.io,
        true,
    );
    try std.testing.expectEqualStrings("query explain output\n", writer.buffer.items);
    try std.testing.expect(TestOps.last_explain);
}

test "query command repairs one recoverable render before publishing" {
    TestOps.reset();
    TestOps.render_failure = error.FileNotFound;
    TestOps.render_failures_remaining = 1;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_command.run(
        &.{ "tinykg", "query", "MATCH (n) RETURN n" },
        &writer,
        std.testing.allocator,
        std.testing.io,
        false,
    );
    try std.testing.expectEqualStrings("query output\n", writer.buffer.items);
    try TestOps.expectSteps(&.{ .parse_db, .join, .parse_syntax, .init_context, .render, .repair, .render, .context_deinit, .syntax_deinit });
}

test "query command does not repair parse context or nonrecoverable render failures" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    TestOps.syntax_failure = error.InvalidQuery;
    try std.testing.expectError(
        error.InvalidQuery,
        test_command.run(&.{ "tinykg", "query", "bad" }, &writer, std.testing.allocator, std.testing.io, false),
    );
    try TestOps.expectSteps(&.{ .parse_db, .join, .parse_syntax });

    TestOps.reset();
    TestOps.context_failure = error.FileNotFound;
    try std.testing.expectError(
        error.FileNotFound,
        test_command.run(&.{ "tinykg", "query", "MATCH (n) RETURN n" }, &writer, std.testing.allocator, std.testing.io, false),
    );
    try TestOps.expectSteps(&.{ .parse_db, .join, .parse_syntax, .init_context, .syntax_deinit });

    TestOps.reset();
    TestOps.render_failure = error.BudgetExceeded;
    TestOps.render_failures_remaining = 1;
    try std.testing.expectError(
        error.BudgetExceeded,
        test_command.run(&.{ "tinykg", "query", "MATCH (n) RETURN n" }, &writer, std.testing.allocator, std.testing.io, false),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
    try TestOps.expectSteps(&.{ .parse_db, .join, .parse_syntax, .init_context, .render, .context_deinit, .syntax_deinit });
}

test "query command releases plan and context after writer failure" {
    TestOps.reset();
    var writer = FailingWriter{};
    try std.testing.expectError(
        error.OutputClosed,
        test_command.run(&.{ "tinykg", "query", "MATCH (n) RETURN n" }, &writer, std.testing.allocator, std.testing.io, false),
    );
    try TestOps.expectSteps(&.{ .parse_db, .join, .parse_syntax, .init_context, .render, .context_deinit, .syntax_deinit });
}
