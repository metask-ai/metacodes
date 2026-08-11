const std = @import("std");

/// Full-text `search` CLI control plane.
///
/// Concrete Store, BM25, membership, generation, candidate-window, deadline,
/// and JSON/TSV representations stay behind `Ops`. This owner keeps the
/// free-text/query allocation and trailing-option grammar together, prepares
/// membership filters outside the retry scope, retries one recoverable render,
/// and retains the complete context through output publication.
pub fn SearchCommand(comptime Ops: type) type {
    return struct {
        pub const Arguments = struct {
            db_path: []const u8,
            query: []u8,
            owned_db_path: ?[]u8,
            profile: Ops.Profile,
            kind_filter: ?Ops.NodeKind,
            project: ?[]const u8,
            schema_type: ?[]const u8,
            limit: usize,
            include_history: bool,
            include_text: bool,
            format: Ops.OutputFormat,
            meta: bool,
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

        fn parseOutputFormat(value: []const u8) !Ops.OutputFormat {
            if (std.mem.eql(u8, value, "text")) return .text;
            if (std.mem.eql(u8, value, "json")) return .json;
            return error.InvalidFormat;
        }

        pub fn parseArguments(
            allocator: std.mem.Allocator,
            io: std.Io,
            args: []const []const u8,
        ) !Arguments {
            var parsed = try Ops.parseFreeTextDbArguments(allocator, io, args);
            errdefer parsed.deinit(allocator);

            var kind_filter: ?Ops.NodeKind = null;
            var project: ?[]const u8 = null;
            var schema_type: ?[]const u8 = null;
            var limit = Ops.maxResultsDefault();
            var max_postings_scanned = Ops.defaultMaxPostings();
            var timeout_ms = Ops.defaultTimeoutMs();
            var profile: Ops.Profile = .interactive;
            var include_history = false;
            var include_text = false;
            var format: Ops.OutputFormat = .text;
            var meta = false;
            var max_postings_explicit = false;
            var timeout_explicit = false;
            var query_end = parsed.rest.len;
            while (query_end > 0) {
                if (std.mem.eql(u8, parsed.rest[query_end - 1], "--include-history")) {
                    include_history = true;
                    query_end -= 1;
                    continue;
                }
                if (std.mem.eql(u8, parsed.rest[query_end - 1], "--include-text")) {
                    include_text = true;
                    query_end -= 1;
                    continue;
                }
                if (std.mem.eql(u8, parsed.rest[query_end - 1], "--meta")) {
                    meta = true;
                    query_end -= 1;
                    continue;
                }
                if (query_end < 2) break;
                const option = parsed.rest[query_end - 2];
                const value = parsed.rest[query_end - 1];
                if (std.mem.eql(u8, option, "--kind")) {
                    kind_filter = Ops.parseNodeKind(value) orelse return error.InvalidNodeKind;
                    query_end -= 2;
                } else if (std.mem.eql(u8, option, "--project")) {
                    project = value;
                    query_end -= 2;
                } else if (std.mem.eql(u8, option, "--schema-type")) {
                    schema_type = value;
                    query_end -= 2;
                } else if (std.mem.eql(u8, option, "--limit")) {
                    limit = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLimit;
                    if (limit > Ops.maxResults()) return error.InvalidLimit;
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
                    profile = try parseProfile(value);
                    applyProfile(
                        profile,
                        &max_postings_scanned,
                        &timeout_ms,
                        max_postings_explicit,
                        timeout_explicit,
                    );
                    query_end -= 2;
                } else if (std.mem.eql(u8, option, "--format")) {
                    format = try parseOutputFormat(value);
                    query_end -= 2;
                } else if (std.mem.startsWith(u8, option, "--")) {
                    return error.UnknownOption;
                } else {
                    break;
                }
            }
            if (query_end == 0) return error.MissingArgument;
            if (meta and format != .json) return error.Unsupported;
            return .{
                .db_path = parsed.db_path,
                .query = try Ops.joinArguments(allocator, parsed.rest[0..query_end]),
                .owned_db_path = parsed.owned_db_path,
                .profile = profile,
                .kind_filter = kind_filter,
                .project = project,
                .schema_type = schema_type,
                .limit = limit,
                .include_history = include_history,
                .include_text = include_text,
                .format = format,
                .meta = meta,
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
        ) !void {
            const parsed = try parseArguments(allocator, io, args);
            defer parsed.deinit(allocator);
            var context = try Ops.Context.init(allocator, io, parsed.db_path);
            defer context.deinit();
            try context.prepare(allocator, io, parsed);
            const output = context.render(allocator, parsed) catch |err| retry: {
                if (!retryable(err)) return err;
                try context.repair();
                break :retry try context.render(allocator, parsed);
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
    pub const NodeKind = enum { observation, task };
    pub const Profile = enum { interactive, agent_memory };
    pub const OutputFormat = enum { text, json };

    const Step = enum {
        parse_db,
        parsed_db_deinit,
        parse_kind,
        join,
        init,
        prepare_filters,
        render,
        repair,
        context_deinit,
    };

    var steps: [48]Step = undefined;
    var step_count: usize = 0;
    var own_db_path = false;
    var prepare_failure: ?anyerror = null;
    var render_failure: ?anyerror = null;
    var render_failures_remaining: usize = 0;
    var last_project: ?[]const u8 = null;
    var last_schema_type: ?[]const u8 = null;
    var last_query_buffer: [256]u8 = undefined;
    var last_query_len: usize = 0;
    var last_profile: ?Profile = null;
    var last_kind: ?NodeKind = null;
    var last_limit: usize = 0;
    var last_include_history = false;
    var last_include_text = false;
    var last_format: ?OutputFormat = null;
    var last_meta = false;
    var last_max_postings: usize = 0;
    var last_timeout_ms: u64 = 0;

    fn reset() void {
        step_count = 0;
        own_db_path = false;
        prepare_failure = null;
        render_failure = null;
        render_failures_remaining = 0;
        last_project = null;
        last_schema_type = null;
        last_query_len = 0;
        last_profile = null;
        last_kind = null;
        last_limit = 0;
        last_include_history = false;
        last_include_text = false;
        last_format = null;
        last_meta = false;
        last_max_postings = 0;
        last_timeout_ms = 0;
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

    pub fn parseNodeKind(value: []const u8) ?NodeKind {
        record(.parse_kind);
        return std.meta.stringToEnum(NodeKind, value);
    }

    pub fn maxResultsDefault() usize {
        return 20;
    }

    pub fn maxResults() usize {
        return 100;
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

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, _: []const u8) !Context {
            TestOps.record(.init);
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.record(.context_deinit);
        }

        pub fn prepare(
            _: *Context,
            _: std.mem.Allocator,
            _: std.Io,
            parsed: anytype,
        ) !void {
            TestOps.record(.prepare_filters);
            TestOps.last_project = parsed.project;
            TestOps.last_schema_type = parsed.schema_type;
            if (TestOps.prepare_failure) |err| return err;
        }

        pub fn render(
            _: *Context,
            allocator: std.mem.Allocator,
            parsed: anytype,
        ) ![]u8 {
            TestOps.record(.render);
            if (parsed.query.len > TestOps.last_query_buffer.len) return error.RecordTooLarge;
            @memcpy(TestOps.last_query_buffer[0..parsed.query.len], parsed.query);
            TestOps.last_query_len = parsed.query.len;
            TestOps.last_profile = parsed.profile;
            TestOps.last_kind = parsed.kind_filter;
            TestOps.last_limit = parsed.limit;
            TestOps.last_include_history = parsed.include_history;
            TestOps.last_include_text = parsed.include_text;
            TestOps.last_format = parsed.format;
            TestOps.last_meta = parsed.meta;
            TestOps.last_max_postings = parsed.max_postings_scanned;
            TestOps.last_timeout_ms = parsed.timeout_ms;
            if (TestOps.render_failure) |err| {
                if (TestOps.render_failures_remaining != 0) {
                    TestOps.render_failures_remaining -= 1;
                    return err;
                }
            }
            return allocator.dupe(u8, "search output\n");
        }

        pub fn repair(_: *Context) !void {
            TestOps.record(.repair);
        }
    };
};

const test_command = SearchCommand(TestOps);

test "search arguments keep flag like query tokens and trailing flags" {
    TestOps.reset();
    var literal = try test_command.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "search", "--limit" },
    );
    defer literal.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("--limit", literal.query);
    try std.testing.expectEqual(@as(usize, 20), literal.limit);

    var flagged = try test_command.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "search", "edge", "index", "--include-history", "--include-text", "--format", "json", "--meta" },
    );
    defer flagged.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("edge index", flagged.query);
    try std.testing.expect(flagged.include_history);
    try std.testing.expect(flagged.include_text);
    try std.testing.expectEqual(TestOps.OutputFormat.json, flagged.format);
    try std.testing.expect(flagged.meta);
}

test "search arguments preserve profile budgets and explicit overrides" {
    TestOps.reset();
    var profiled = try test_command.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "search", "memory", "--profile", "agent-memory" },
    );
    defer profiled.deinit(std.testing.allocator);
    try std.testing.expectEqual(TestOps.Profile.agent_memory, profiled.profile);
    try std.testing.expectEqual(@as(usize, 4_000), profiled.max_postings_scanned);
    try std.testing.expectEqual(@as(u64, 5_000), profiled.timeout_ms);

    var override_after = try test_command.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "search", "memory", "--profile", "agent-memory", "--max-postings", "42", "--timeout-ms", "100" },
    );
    defer override_after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 42), override_after.max_postings_scanned);
    try std.testing.expectEqual(@as(u64, 100), override_after.timeout_ms);

    var override_before = try test_command.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "search", "memory", "--max-postings", "43", "--timeout-ms", "101", "--profile", "agent-memory" },
    );
    defer override_before.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 43), override_before.max_postings_scanned);
    try std.testing.expectEqual(@as(u64, 101), override_before.timeout_ms);
}

test "search arguments preserve filters formats and bounded limits" {
    TestOps.reset();
    var parsed = try test_command.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{
            "tinykg",        "search",   "bounded",   "query",
            "--kind",        "task",     "--project", "7",
            "--schema-type", "decision", "--limit",   "3",
            "--limit",       "9",        "--format",  "json",
            "--meta",
        },
    );
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("bounded query", parsed.query);
    try std.testing.expectEqual(TestOps.NodeKind.task, parsed.kind_filter.?);
    try std.testing.expectEqualStrings("7", parsed.project.?);
    try std.testing.expectEqualStrings("decision", parsed.schema_type.?);
    try std.testing.expectEqual(@as(usize, 3), parsed.limit);
    try std.testing.expectEqual(TestOps.OutputFormat.json, parsed.format);
    try std.testing.expect(parsed.meta);
}

test "search arguments reject malformed trailing options before context" {
    TestOps.reset();
    try std.testing.expectError(
        error.InvalidLimit,
        test_command.parseArguments(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "search", "query", "--limit", "bad" },
        ),
    );
    try std.testing.expectError(
        error.InvalidNodeKind,
        test_command.parseArguments(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "search", "query", "--kind", "missing" },
        ),
    );
    try std.testing.expectError(
        error.UnknownOption,
        test_command.parseArguments(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "search", "query", "--unknown", "value" },
        ),
    );
    try std.testing.expectError(
        error.Unsupported,
        test_command.parseArguments(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "search", "query", "--meta" },
        ),
    );
    try std.testing.expect(std.mem.indexOfScalar(TestOps.Step, TestOps.steps[0..TestOps.step_count], .init) == null);
}

test "search arguments release owned database path after later parse failure" {
    TestOps.reset();
    TestOps.own_db_path = true;
    try std.testing.expectError(
        error.InvalidNodeKind,
        test_command.parseArguments(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "search", "query", "--kind", "missing" },
        ),
    );
    try TestOps.expectSteps(&.{ .parse_db, .parse_kind, .parsed_db_deinit });
}

test "search command prepares filters before render and publishes complete output" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try test_command.run(
        &.{ "tinykg", "search", "memory", "query", "--project", "7", "--schema-type", "decision", "--kind", "task", "--limit", "3", "--format", "json", "--meta" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("search output\n", writer.buffer.items);
    try std.testing.expectEqualStrings("7", TestOps.last_project.?);
    try std.testing.expectEqualStrings("decision", TestOps.last_schema_type.?);
    try std.testing.expectEqualStrings("memory query", TestOps.last_query_buffer[0..TestOps.last_query_len]);
    try std.testing.expectEqual(TestOps.NodeKind.task, TestOps.last_kind.?);
    try std.testing.expectEqual(@as(usize, 3), TestOps.last_limit);
    try std.testing.expectEqual(TestOps.OutputFormat.json, TestOps.last_format.?);
    try std.testing.expect(TestOps.last_meta);
    try TestOps.expectSteps(&.{
        .parse_db,
        .parse_kind,
        .join,
        .init,
        .prepare_filters,
        .render,
        .context_deinit,
    });
}

test "search command repairs one recoverable render before publishing" {
    TestOps.reset();
    TestOps.render_failure = error.InvalidRecord;
    TestOps.render_failures_remaining = 1;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try test_command.run(
        &.{ "tinykg", "search", "repair" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("search output\n", writer.buffer.items);
    try TestOps.expectSteps(&.{
        .parse_db,
        .join,
        .init,
        .prepare_filters,
        .render,
        .repair,
        .render,
        .context_deinit,
    });
}

test "search command does not repair filter or nonrecoverable render failures" {
    TestOps.reset();
    TestOps.prepare_failure = error.FileNotFound;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try std.testing.expectError(
        error.FileNotFound,
        test_command.run(
            &.{ "tinykg", "search", "filter" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{
        .parse_db,
        .join,
        .init,
        .prepare_filters,
        .context_deinit,
    });

    TestOps.reset();
    TestOps.render_failure = error.AccessDenied;
    TestOps.render_failures_remaining = 1;
    try std.testing.expectError(
        error.AccessDenied,
        test_command.run(
            &.{ "tinykg", "search", "render" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{
        .parse_db,
        .join,
        .init,
        .prepare_filters,
        .render,
        .context_deinit,
    });
}

test "search command releases context after writer failure" {
    TestOps.reset();
    var writer = FailingWriter{};
    try std.testing.expectError(
        error.OutputClosed,
        test_command.run(
            &.{ "tinykg", "search", "output" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{
        .parse_db,
        .join,
        .init,
        .prepare_filters,
        .render,
        .context_deinit,
    });
}
