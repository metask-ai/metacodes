const std = @import("std");

/// Edge-segment operator command control plane.
///
/// Concrete database-path probing, CLI locking, Store/options/result identities,
/// persistent index repair, segment publication/merge, manifest leases and GC
/// stay behind `Ops`. This owner keeps the four related operator protocols
/// together: target preflight plus one recoverable publication retry, one
/// explicit compaction, positive budget parsing before a timed maintenance
/// context, and one lease-aware GC operation. Output is success-only; a writer
/// failure can occur after a persistent operation has committed.
pub fn EdgeSegmentCommands(comptime Ops: type) type {
    return struct {
        const MaintenanceArguments = struct {
            db_path: []const u8,
            max_segments: usize = 0,
            max_edges: u64 = 0,
            gc: bool = false,
        };

        fn parsePositive(comptime T: type, value: []const u8) !T {
            const parsed = std.fmt.parseInt(T, value, 10) catch return error.InvalidLimit;
            if (parsed == 0) return error.InvalidLimit;
            return parsed;
        }

        fn parseMaintenanceArguments(
            allocator: std.mem.Allocator,
            io: std.Io,
            args: []const []const u8,
        ) !MaintenanceArguments {
            const parsed = try Ops.parseDbArguments(
                allocator,
                io,
                args,
                0,
                std.math.maxInt(usize),
            );
            var result = MaintenanceArguments{ .db_path = parsed.db_path };
            var pos: usize = 0;
            while (pos < parsed.rest.len) {
                const option = parsed.rest[pos];
                if (std.mem.eql(u8, option, "--max-segments")) {
                    if (pos + 1 >= parsed.rest.len) return error.MissingArgument;
                    result.max_segments = try parsePositive(usize, parsed.rest[pos + 1]);
                    pos += 2;
                } else if (std.mem.eql(u8, option, "--max-edges")) {
                    if (pos + 1 >= parsed.rest.len) return error.MissingArgument;
                    result.max_edges = try parsePositive(u64, parsed.rest[pos + 1]);
                    pos += 2;
                } else if (std.mem.eql(u8, option, "--gc")) {
                    result.gc = true;
                    pos += 1;
                } else {
                    return error.UnknownOption;
                }
            }
            return result;
        }

        pub fn runCompactEdges(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parseDbArguments(allocator, io, args, 1, 1);
            const segment_dir_path = parsed.rest[0];
            if (try Ops.targetPathExists(io, segment_dir_path)) return error.AlreadyExists;

            var context = try Ops.Context.init(allocator, io, parsed.db_path);
            defer context.deinit();
            const edges = context.publish(segment_dir_path) catch |err| retry: {
                if (!Ops.isRecoverablePublishError(err)) return err;
                try context.repairPersistentIndexes();
                break :retry try context.publish(segment_dir_path);
            };
            try writer.print("edge_segment edges={} dir={s}\n", .{ edges, segment_dir_path });
        }

        pub fn runCompactEdgeSegments(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parseDbArguments(allocator, io, args, 1, 1);
            const segment_dir_path = parsed.rest[0];
            var context = try Ops.Context.init(allocator, io, parsed.db_path);
            defer context.deinit();
            const edges = try context.compact(segment_dir_path);
            try writer.print("edge_segment_compacted edges={} dir={s}\n", .{ edges, segment_dir_path });
        }

        pub fn runMaintainEdgeSegments(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try parseMaintenanceArguments(allocator, io, args);
            const start_ns = Ops.startTimer(io);
            var context = try Ops.MaintenanceContext.init(allocator, io, parsed.db_path, parsed.gc);
            defer context.deinit();
            const result = try context.execute(parsed.max_segments, parsed.max_edges);
            const elapsed_ns = Ops.elapsedSince(io, start_ns);
            try writer.print(
                "edge_segments_maintenance compacted={} compacted_edges={} compacted_segments={} gc_deleted_segments={} gc_deleted_manifests={} entries_before={} entries_after={} elapsed_ns={}\n",
                .{
                    result.compacted,
                    result.compacted_edges,
                    result.compacted_segments,
                    result.gc_deleted_segments,
                    result.gc_deleted_manifests,
                    result.manifest_entries_before,
                    result.manifest_entries_after,
                    elapsed_ns,
                },
            );
        }

        pub fn runGcEdgeSegments(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parseDbArguments(allocator, io, args, 0, 0);
            var context = try Ops.Context.init(allocator, io, parsed.db_path);
            defer context.deinit();
            const result = try context.gc();
            try writer.print(
                "edge_segments_gc deleted_segments={} deleted_manifests={}\n",
                .{ result.deleted_segments, result.deleted_manifests },
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
        std.debug.assert(TestOps.context_live or TestOps.maintenance_context_live);
        TestOps.record(.write);
        const rendered = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(rendered);
        try self.buffer.appendSlice(self.allocator, rendered);
    }
};

const FailingWriter = struct {
    fn print(_: *FailingWriter, comptime _: []const u8, _: anytype) error{OutputClosed}!void {
        std.debug.assert(TestOps.context_live or TestOps.maintenance_context_live);
        TestOps.record(.write);
        return error.OutputClosed;
    }
};

const TestOps = struct {
    const Step = enum {
        parse,
        path_exists,
        start_timer,
        context_init,
        maintenance_context_init,
        publish,
        repair,
        compact,
        maintain,
        gc,
        elapsed,
        write,
        context_deinit,
        maintenance_context_deinit,
    };

    const Parsed = struct {
        db_path: []const u8,
        rest: []const []const u8,
    };

    const MaintenanceResult = struct {
        compacted: bool = true,
        compacted_edges: u64 = 23,
        compacted_segments: usize = 3,
        gc_deleted_segments: u64 = 5,
        gc_deleted_manifests: u64 = 7,
        manifest_entries_before: usize = 11,
        manifest_entries_after: usize = 9,
    };

    const GcResult = struct {
        deleted_segments: u64 = 13,
        deleted_manifests: u64 = 17,
    };

    var steps: [64]Step = undefined;
    var step_count: usize = 0;
    var parse_error: ?anyerror = null;
    var path_exists: bool = false;
    var path_error: ?anyerror = null;
    var context_error: ?anyerror = null;
    var maintenance_context_error: ?anyerror = null;
    var publish_errors: [2]?anyerror = .{ null, null };
    var repair_error: ?anyerror = null;
    var compact_error: ?anyerror = null;
    var maintenance_error: ?anyerror = null;
    var gc_error: ?anyerror = null;
    var context_live: bool = false;
    var maintenance_context_live: bool = false;
    var publish_count: usize = 0;
    var repair_count: usize = 0;
    var compact_count: usize = 0;
    var maintenance_count: usize = 0;
    var gc_count: usize = 0;
    var last_db_path: []const u8 = "";
    var last_segment_dir_path: []const u8 = "";
    var last_max_segments: usize = 0;
    var last_max_edges: u64 = 0;
    var last_gc_option: bool = false;

    fn reset() void {
        step_count = 0;
        parse_error = null;
        path_exists = false;
        path_error = null;
        context_error = null;
        maintenance_context_error = null;
        publish_errors = .{ null, null };
        repair_error = null;
        compact_error = null;
        maintenance_error = null;
        gc_error = null;
        context_live = false;
        maintenance_context_live = false;
        publish_count = 0;
        repair_count = 0;
        compact_count = 0;
        maintenance_count = 0;
        gc_count = 0;
        last_db_path = "";
        last_segment_dir_path = "";
        last_max_segments = 0;
        last_max_edges = 0;
        last_gc_option = false;
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
        min_rest: usize,
        max_rest: usize,
    ) !Parsed {
        record(.parse);
        if (parse_error) |err| return err;
        if (args.len < 2) return error.MissingArgument;
        var db_path: []const u8 = "default.kg";
        var rest = args[2..];
        if (rest.len != 0 and std.mem.eql(u8, rest[0], "explicit.kg")) {
            db_path = rest[0];
            rest = rest[1..];
        }
        if (rest.len < min_rest) return error.MissingArgument;
        if (rest.len > max_rest) return error.TooManyArguments;
        return .{ .db_path = db_path, .rest = rest };
    }

    pub fn targetPathExists(_: std.Io, path: []const u8) !bool {
        record(.path_exists);
        last_segment_dir_path = path;
        if (path_error) |err| return err;
        return path_exists;
    }

    pub fn isRecoverablePublishError(err: anyerror) bool {
        return err == error.FileNotFound or err == error.InvalidRecord;
    }

    pub fn startTimer(_: std.Io) u128 {
        record(.start_timer);
        return 100;
    }

    pub fn elapsedSince(_: std.Io, start_ns: u128) u128 {
        std.debug.assert(maintenance_context_live);
        std.debug.assert(start_ns == 100);
        record(.elapsed);
        return 29;
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, db_path: []const u8) !Context {
            record(.context_init);
            last_db_path = db_path;
            if (context_error) |err| return err;
            std.debug.assert(!context_live and !maintenance_context_live);
            context_live = true;
            return .{};
        }

        pub fn deinit(_: *Context) void {
            std.debug.assert(context_live);
            record(.context_deinit);
            context_live = false;
        }

        pub fn publish(_: *Context, segment_dir_path: []const u8) !u64 {
            std.debug.assert(context_live);
            record(.publish);
            last_segment_dir_path = segment_dir_path;
            const call_index = publish_count;
            publish_count += 1;
            if (publish_errors[call_index]) |err| return err;
            return 17;
        }

        pub fn repairPersistentIndexes(_: *Context) !void {
            std.debug.assert(context_live);
            record(.repair);
            repair_count += 1;
            if (repair_error) |err| return err;
        }

        pub fn compact(_: *Context, segment_dir_path: []const u8) !u64 {
            std.debug.assert(context_live);
            record(.compact);
            compact_count += 1;
            last_segment_dir_path = segment_dir_path;
            if (compact_error) |err| return err;
            return 19;
        }

        pub fn gc(_: *Context) !GcResult {
            std.debug.assert(context_live);
            record(.gc);
            gc_count += 1;
            if (gc_error) |err| return err;
            return .{};
        }
    };

    pub const MaintenanceContext = struct {
        pub fn init(
            _: std.mem.Allocator,
            _: std.Io,
            db_path: []const u8,
            gc_option: bool,
        ) !MaintenanceContext {
            record(.maintenance_context_init);
            last_db_path = db_path;
            last_gc_option = gc_option;
            if (maintenance_context_error) |err| return err;
            std.debug.assert(!context_live and !maintenance_context_live);
            maintenance_context_live = true;
            return .{};
        }

        pub fn deinit(_: *MaintenanceContext) void {
            std.debug.assert(maintenance_context_live);
            record(.maintenance_context_deinit);
            maintenance_context_live = false;
        }

        pub fn execute(_: *MaintenanceContext, max_segments: usize, max_edges: u64) !MaintenanceResult {
            std.debug.assert(maintenance_context_live);
            record(.maintain);
            maintenance_count += 1;
            last_max_segments = max_segments;
            last_max_edges = max_edges;
            if (maintenance_error) |err| return err;
            return .{};
        }
    };
};

const test_commands = EdgeSegmentCommands(TestOps);

test "edge segment compact commands reject invalid arity before context" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    try std.testing.expectError(
        error.MissingArgument,
        test_commands.runCompactEdges(
            &.{ "tinykg", "compact-edges" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{.parse});

    TestOps.reset();
    try std.testing.expectError(
        error.TooManyArguments,
        test_commands.runCompactEdges(
            &.{ "tinykg", "compact-edges", "segment", "extra" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{.parse});

    TestOps.reset();
    try std.testing.expectError(
        error.MissingArgument,
        test_commands.runCompactEdgeSegments(
            &.{ "tinykg", "compact-edge-segments" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{.parse});

    TestOps.reset();
    try std.testing.expectError(
        error.TooManyArguments,
        test_commands.runCompactEdgeSegments(
            &.{ "tinykg", "compact-edge-segments", "segment", "extra" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{.parse});
}

test "compact edges rejects existing target before context" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    TestOps.path_exists = true;
    try std.testing.expectError(
        error.AlreadyExists,
        test_commands.runCompactEdges(
            &.{ "tinykg", "compact-edges", "occupied" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse, .path_exists });
    try std.testing.expect(!TestOps.context_live);

    TestOps.reset();
    TestOps.path_error = error.AccessDenied;
    try std.testing.expectError(
        error.AccessDenied,
        test_commands.runCompactEdges(
            &.{ "tinykg", "compact-edges", "unreadable" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse, .path_exists });
}

test "edge segment maintenance arguments preserve defaults repeated budgets and idempotent gc" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    try test_commands.runMaintainEdgeSegments(
        &.{ "tinykg", "maintain-edge-segments" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("default.kg", TestOps.last_db_path);
    try std.testing.expectEqual(@as(usize, 0), TestOps.last_max_segments);
    try std.testing.expectEqual(@as(u64, 0), TestOps.last_max_edges);
    try std.testing.expect(!TestOps.last_gc_option);

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runMaintainEdgeSegments(
        &.{
            "tinykg",
            "maintain-edge-segments",
            "explicit.kg",
            "--max-segments",
            "8",
            "--gc",
            "--max-edges",
            "64",
            "--max-segments",
            "11",
            "--max-edges",
            "101",
            "--gc",
        },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("explicit.kg", TestOps.last_db_path);
    try std.testing.expectEqual(@as(usize, 11), TestOps.last_max_segments);
    try std.testing.expectEqual(@as(u64, 101), TestOps.last_max_edges);
    try std.testing.expect(TestOps.last_gc_option);
}

test "edge segment maintenance arguments reject missing invalid unknown and extra values before timing" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    const cases = [_]struct { args: []const []const u8, expected: anyerror }{
        .{ .args = &.{ "tinykg", "maintain-edge-segments", "--max-segments" }, .expected = error.MissingArgument },
        .{ .args = &.{ "tinykg", "maintain-edge-segments", "--max-segments", "0" }, .expected = error.InvalidLimit },
        .{ .args = &.{ "tinykg", "maintain-edge-segments", "--max-segments", "invalid" }, .expected = error.InvalidLimit },
        .{ .args = &.{ "tinykg", "maintain-edge-segments", "--max-edges" }, .expected = error.MissingArgument },
        .{ .args = &.{ "tinykg", "maintain-edge-segments", "--max-edges", "0" }, .expected = error.InvalidLimit },
        .{ .args = &.{ "tinykg", "maintain-edge-segments", "--bad", "1" }, .expected = error.UnknownOption },
        .{ .args = &.{ "tinykg", "maintain-edge-segments", "extra" }, .expected = error.UnknownOption },
    };
    for (cases) |case| {
        TestOps.reset();
        try std.testing.expectError(
            case.expected,
            test_commands.runMaintainEdgeSegments(
                case.args,
                &writer,
                std.testing.allocator,
                std.testing.io,
            ),
        );
        try TestOps.expectSteps(&.{.parse});
        try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
    }
}

test "compact edges publishes once and repairs one recoverable failure" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    try test_commands.runCompactEdges(
        &.{ "tinykg", "compact-edges", "segment-a" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .parse, .path_exists, .context_init, .publish, .write, .context_deinit });
    try std.testing.expectEqual(@as(usize, 1), TestOps.publish_count);
    try std.testing.expectEqual(@as(usize, 0), TestOps.repair_count);
    try std.testing.expectEqualStrings("edge_segment edges=17 dir=segment-a\n", writer.buffer.items);

    const recoverable_errors = [_]anyerror{ error.FileNotFound, error.InvalidRecord };
    for (recoverable_errors) |recoverable_error| {
        TestOps.reset();
        writer.buffer.clearRetainingCapacity();
        TestOps.publish_errors[0] = recoverable_error;
        try test_commands.runCompactEdges(
            &.{ "tinykg", "compact-edges", "explicit.kg", "segment-b" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        );
        try TestOps.expectSteps(&.{ .parse, .path_exists, .context_init, .publish, .repair, .publish, .write, .context_deinit });
        try std.testing.expectEqual(@as(usize, 2), TestOps.publish_count);
        try std.testing.expectEqual(@as(usize, 1), TestOps.repair_count);
        try std.testing.expectEqualStrings("explicit.kg", TestOps.last_db_path);
    }
}

test "compact edges does not repair non recoverable failure" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    TestOps.publish_errors[0] = error.AccessDenied;
    try std.testing.expectError(
        error.AccessDenied,
        test_commands.runCompactEdges(
            &.{ "tinykg", "compact-edges", "segment" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse, .path_exists, .context_init, .publish, .context_deinit });
    try std.testing.expectEqual(@as(usize, 1), TestOps.publish_count);
    try std.testing.expectEqual(@as(usize, 0), TestOps.repair_count);

    TestOps.reset();
    TestOps.publish_errors[0] = error.FileNotFound;
    TestOps.repair_error = error.AccessDenied;
    try std.testing.expectError(
        error.AccessDenied,
        test_commands.runCompactEdges(
            &.{ "tinykg", "compact-edges", "segment" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse, .path_exists, .context_init, .publish, .repair, .context_deinit });
    try std.testing.expectEqual(@as(usize, 1), TestOps.publish_count);
    try std.testing.expectEqual(@as(usize, 1), TestOps.repair_count);
}

test "compact edge segments executes once and publishes stable receipt" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runCompactEdgeSegments(
        &.{ "tinykg", "compact-edge-segments", "explicit.kg", "merged" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .parse, .context_init, .compact, .write, .context_deinit });
    try std.testing.expectEqual(@as(usize, 1), TestOps.compact_count);
    try std.testing.expectEqualStrings("explicit.kg", TestOps.last_db_path);
    try std.testing.expectEqualStrings("merged", TestOps.last_segment_dir_path);
    try std.testing.expectEqualStrings("edge_segment_compacted edges=19 dir=merged\n", writer.buffer.items);
}

test "edge segment maintenance times one operation and publishes stable receipt" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runMaintainEdgeSegments(
        &.{ "tinykg", "maintain-edge-segments", "--max-segments", "3", "--max-edges", "101", "--gc" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .parse, .start_timer, .maintenance_context_init, .maintain, .elapsed, .write, .maintenance_context_deinit });
    try std.testing.expectEqual(@as(usize, 1), TestOps.maintenance_count);
    try std.testing.expectEqualStrings(
        "edge_segments_maintenance compacted=true compacted_edges=23 compacted_segments=3 gc_deleted_segments=5 gc_deleted_manifests=7 entries_before=11 entries_after=9 elapsed_ns=29\n",
        writer.buffer.items,
    );
}

test "edge segment maintenance failures preserve ordering and cleanup" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    TestOps.parse_error = error.InvalidRecord;
    try std.testing.expectError(
        error.InvalidRecord,
        test_commands.runMaintainEdgeSegments(
            &.{ "tinykg", "maintain-edge-segments" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{.parse});

    TestOps.reset();
    TestOps.maintenance_context_error = error.FileNotFound;
    try std.testing.expectError(
        error.FileNotFound,
        test_commands.runMaintainEdgeSegments(
            &.{ "tinykg", "maintain-edge-segments" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse, .start_timer, .maintenance_context_init });

    TestOps.reset();
    TestOps.maintenance_error = error.InvalidRecord;
    try std.testing.expectError(
        error.InvalidRecord,
        test_commands.runMaintainEdgeSegments(
            &.{ "tinykg", "maintain-edge-segments" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse, .start_timer, .maintenance_context_init, .maintain, .maintenance_context_deinit });
    try std.testing.expect(!TestOps.maintenance_context_live);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "edge segment gc executes once and publishes stable receipt" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runGcEdgeSegments(
        &.{ "tinykg", "gc-edge-segments", "explicit.kg" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .parse, .context_init, .gc, .write, .context_deinit });
    try std.testing.expectEqual(@as(usize, 1), TestOps.gc_count);
    try std.testing.expectEqualStrings("explicit.kg", TestOps.last_db_path);
    try std.testing.expectEqualStrings(
        "edge_segments_gc deleted_segments=13 deleted_manifests=17\n",
        writer.buffer.items,
    );

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try std.testing.expectError(
        error.TooManyArguments,
        test_commands.runGcEdgeSegments(
            &.{ "tinykg", "gc-edge-segments", "extra", "value" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{.parse});
}

test "edge segment writer failures close context after successful operations" {
    var writer = FailingWriter{};

    TestOps.reset();
    try std.testing.expectError(
        error.OutputClosed,
        test_commands.runCompactEdges(
            &.{ "tinykg", "compact-edges", "segment" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse, .path_exists, .context_init, .publish, .write, .context_deinit });
    try std.testing.expectEqual(@as(usize, 1), TestOps.publish_count);
    try std.testing.expect(!TestOps.context_live);

    TestOps.reset();
    try std.testing.expectError(
        error.OutputClosed,
        test_commands.runCompactEdgeSegments(
            &.{ "tinykg", "compact-edge-segments", "segment" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse, .context_init, .compact, .write, .context_deinit });
    try std.testing.expectEqual(@as(usize, 1), TestOps.compact_count);
    try std.testing.expect(!TestOps.context_live);

    TestOps.reset();
    try std.testing.expectError(
        error.OutputClosed,
        test_commands.runMaintainEdgeSegments(
            &.{ "tinykg", "maintain-edge-segments" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse, .start_timer, .maintenance_context_init, .maintain, .elapsed, .write, .maintenance_context_deinit });
    try std.testing.expectEqual(@as(usize, 1), TestOps.maintenance_count);
    try std.testing.expect(!TestOps.maintenance_context_live);

    TestOps.reset();
    try std.testing.expectError(
        error.OutputClosed,
        test_commands.runGcEdgeSegments(
            &.{ "tinykg", "gc-edge-segments" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse, .context_init, .gc, .write, .context_deinit });
    try std.testing.expectEqual(@as(usize, 1), TestOps.gc_count);
    try std.testing.expect(!TestOps.context_live);
}
