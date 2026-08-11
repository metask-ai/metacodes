const std = @import("std");

/// `import-metaknow-replay` command control plane.
///
/// Corpus identity, replay loading and planning, source-change and path-overlap
/// checks, the publication lock, staging and transaction markers, bulk Store
/// writes, task-status materialization, optional text rebuild, manifest sync,
/// rename and recovery remain behind `Ops`. This owner keeps the required
/// database/corpus grammar, positive chunk option, parse-before-timer order,
/// one offline copy-on-write import call and stable success-only receipt
/// together. A writer failure can occur after the Store was committed and must
/// never be interpreted as rollback evidence.
pub fn MetaknowReplayImportCommand(comptime Ops: type) type {
    return struct {
        const Arguments = struct {
            db_path: []const u8,
            corpus_dir_path: []const u8,
            chunk_size: usize,
            warm_text: bool = false,
        };

        fn parsePositiveCount(value: []const u8) !usize {
            const parsed = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLimit;
            if (parsed == 0) return error.InvalidLimit;
            return parsed;
        }

        fn parseArguments(args: []const []const u8) !Arguments {
            if (args.len < 4) return error.MissingArgument;
            var parsed = Arguments{
                .db_path = args[2],
                .corpus_dir_path = args[3],
                .chunk_size = Ops.defaultChunkSize(),
            };

            var pos: usize = 4;
            while (pos < args.len) {
                const option = args[pos];
                if (std.mem.eql(u8, option, "--chunk")) {
                    if (pos + 1 >= args.len) return error.MissingArgument;
                    parsed.chunk_size = try parsePositiveCount(args[pos + 1]);
                    pos += 2;
                } else if (std.mem.eql(u8, option, "--warm-text")) {
                    parsed.warm_text = true;
                    pos += 1;
                } else if (std.mem.startsWith(u8, option, "--")) {
                    return error.UnknownOption;
                } else {
                    return error.TooManyArguments;
                }
            }
            return parsed;
        }

        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try parseArguments(args);
            const import_start_ns = Ops.startTimer(io);
            const result = try Ops.execute(allocator, io, parsed);
            const elapsed_ns = Ops.elapsedSince(io, import_start_ns);
            try writer.print(
                "import_metaknow_replay db={s} corpus_dir={s} chunk={} nodes_loaded={} nodes_imported={} edges_loaded={} edges_imported={} edges_skipped_missing_endpoint={} text_warmed={} corpus_bytes={} marker_cleanup_pending={} elapsed_ns={}\n",
                .{
                    parsed.db_path,
                    parsed.corpus_dir_path,
                    parsed.chunk_size,
                    result.nodes_loaded,
                    result.nodes_imported,
                    result.edges_loaded,
                    result.edges_imported,
                    result.edges_skipped_missing_endpoint,
                    @intFromBool(result.text_warmed),
                    result.corpus_bytes,
                    @intFromBool(result.marker_cleanup_pending),
                    elapsed_ns,
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

    fn print(self: *TestWriter, comptime format: []const u8, args: anytype) !void {
        std.debug.assert(TestOps.committed);
        TestOps.record(.write);
        const rendered = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(rendered);
        try self.buffer.appendSlice(self.allocator, rendered);
    }
};

const FailingWriter = struct {
    fn print(_: *FailingWriter, comptime _: []const u8, _: anytype) error{OutputClosed}!void {
        std.debug.assert(TestOps.committed);
        TestOps.record(.write);
        return error.OutputClosed;
    }
};

const TestOps = struct {
    const Step = enum {
        start_timer,
        execute,
        elapsed,
        write,
    };

    const Result = struct {
        nodes_loaded: usize = 13,
        nodes_imported: usize = 11,
        edges_loaded: usize = 17,
        edges_imported: usize = 15,
        edges_skipped_missing_endpoint: usize = 2,
        corpus_bytes: u64 = 101,
        text_warmed: bool = true,
        marker_cleanup_pending: bool = true,
    };

    var steps: [16]Step = undefined;
    var step_count: usize = 0;
    var execute_error: ?anyerror = null;
    var execution_count: usize = 0;
    var committed: bool = false;
    var last_db_path: []const u8 = "";
    var last_corpus_dir_path: []const u8 = "";
    var last_chunk_size: usize = 0;
    var last_warm_text: bool = false;

    fn reset() void {
        step_count = 0;
        execute_error = null;
        execution_count = 0;
        committed = false;
        last_db_path = "";
        last_corpus_dir_path = "";
        last_chunk_size = 0;
        last_warm_text = false;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn expectSteps(expected: []const Step) !void {
        try std.testing.expectEqualSlices(Step, expected, steps[0..step_count]);
    }

    pub fn defaultChunkSize() usize {
        return 65_536;
    }

    pub fn startTimer(_: std.Io) u128 {
        record(.start_timer);
        return 100;
    }

    pub fn elapsedSince(_: std.Io, start_ns: u128) u128 {
        std.debug.assert(committed);
        std.debug.assert(start_ns == 100);
        record(.elapsed);
        return 29;
    }

    pub fn execute(_: std.mem.Allocator, _: std.Io, parsed: anytype) !Result {
        record(.execute);
        execution_count += 1;
        last_db_path = parsed.db_path;
        last_corpus_dir_path = parsed.corpus_dir_path;
        last_chunk_size = parsed.chunk_size;
        last_warm_text = parsed.warm_text;
        if (execute_error) |err| return err;
        committed = true;
        return .{};
    }
};

const test_command = MetaknowReplayImportCommand(TestOps);

test "metaknow replay import arguments preserve defaults repeated chunk and idempotent warm text" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_command.run(
        &.{ "tinykg", "import-metaknow-replay", "default.kg", "corpus" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("default.kg", TestOps.last_db_path);
    try std.testing.expectEqualStrings("corpus", TestOps.last_corpus_dir_path);
    try std.testing.expectEqual(@as(usize, 65_536), TestOps.last_chunk_size);
    try std.testing.expect(!TestOps.last_warm_text);

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_command.run(
        &.{
            "tinykg",
            "import-metaknow-replay",
            "explicit.kg",
            "replay",
            "--chunk",
            "7",
            "--warm-text",
            "--chunk",
            "11",
            "--warm-text",
        },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("explicit.kg", TestOps.last_db_path);
    try std.testing.expectEqualStrings("replay", TestOps.last_corpus_dir_path);
    try std.testing.expectEqual(@as(usize, 11), TestOps.last_chunk_size);
    try std.testing.expect(TestOps.last_warm_text);
}

test "metaknow replay import arguments reject missing invalid unknown and extra values before timing" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    try std.testing.expectError(
        error.MissingArgument,
        test_command.run(
            &.{ "tinykg", "import-metaknow-replay", "db" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{});

    TestOps.reset();
    try std.testing.expectError(
        error.MissingArgument,
        test_command.run(
            &.{ "tinykg", "import-metaknow-replay", "db", "corpus", "--chunk" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{});

    TestOps.reset();
    try std.testing.expectError(
        error.InvalidLimit,
        test_command.run(
            &.{ "tinykg", "import-metaknow-replay", "db", "corpus", "--chunk", "0" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{});

    TestOps.reset();
    try std.testing.expectError(
        error.UnknownOption,
        test_command.run(
            &.{ "tinykg", "import-metaknow-replay", "db", "corpus", "--bad" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{});

    TestOps.reset();
    try std.testing.expectError(
        error.TooManyArguments,
        test_command.run(
            &.{ "tinykg", "import-metaknow-replay", "db", "corpus", "extra" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{});
}

test "metaknow replay import command executes once times and publishes stable receipt" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_command.run(
        &.{ "tinykg", "import-metaknow-replay", "db", "corpus", "--chunk", "7", "--warm-text" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .start_timer, .execute, .elapsed, .write });
    try std.testing.expectEqual(@as(usize, 1), TestOps.execution_count);
    try std.testing.expectEqualStrings(
        "import_metaknow_replay db=db corpus_dir=corpus chunk=7 nodes_loaded=13 nodes_imported=11 edges_loaded=17 edges_imported=15 edges_skipped_missing_endpoint=2 text_warmed=1 corpus_bytes=101 marker_cleanup_pending=1 elapsed_ns=29\n",
        writer.buffer.items,
    );
}

test "metaknow replay import parse failures perform no operation or output" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidLimit,
        test_command.run(
            &.{ "tinykg", "import-metaknow-replay", "db", "corpus", "--chunk", "not-a-count" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{});
    try std.testing.expectEqual(@as(usize, 0), TestOps.execution_count);
    try std.testing.expect(!TestOps.committed);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "metaknow replay import execution failures skip elapsed time and output" {
    TestOps.reset();
    TestOps.execute_error = error.ImportSourceChanged;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.ImportSourceChanged,
        test_command.run(
            &.{ "tinykg", "import-metaknow-replay", "db", "corpus" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .start_timer, .execute });
    try std.testing.expectEqual(@as(usize, 1), TestOps.execution_count);
    try std.testing.expect(!TestOps.committed);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "metaknow replay import writer failure follows successful committed operation" {
    TestOps.reset();
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        test_command.run(
            &.{ "tinykg", "import-metaknow-replay", "db", "corpus" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .start_timer, .execute, .elapsed, .write });
    try std.testing.expectEqual(@as(usize, 1), TestOps.execution_count);
    try std.testing.expect(TestOps.committed);
}
