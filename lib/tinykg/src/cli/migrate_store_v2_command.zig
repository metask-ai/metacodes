const std = @import("std");

/// Stable, representation-neutral command arguments for `migrate-store-v2`.
/// Concrete migration, path and persistence types remain in the CLI façade.
pub const Arguments = struct {
    source_path: []const u8,
    target_path: []const u8,
    backup_path: ?[]const u8 = null,
    profiles: []const u8 = "agent-dag,markdown-document",
    profiles_explicit: bool = false,
    warm_text: bool = false,
    verify: bool = true,
    dry_run: bool = false,
    strict: bool = false,
    task_status_v1: bool = false,
};

fn parseArguments(args: []const []const u8) !Arguments {
    if (args.len < 4) return error.MissingArgument;
    var parsed = Arguments{
        .source_path = args[2],
        .target_path = args[3],
    };
    var pos: usize = 4;
    while (pos < args.len) {
        const option = args[pos];
        if (std.mem.eql(u8, option, "--backup")) {
            if (parsed.backup_path != null) return error.TooManyArguments;
            if (pos + 1 >= args.len) return error.MissingArgument;
            parsed.backup_path = args[pos + 1];
            pos += 2;
        } else if (std.mem.eql(u8, option, "--profile")) {
            if (parsed.profiles_explicit) return error.TooManyArguments;
            if (pos + 1 >= args.len) return error.MissingArgument;
            parsed.profiles = args[pos + 1];
            parsed.profiles_explicit = true;
            pos += 2;
        } else if (std.mem.eql(u8, option, "--warm-text")) {
            parsed.warm_text = true;
            pos += 1;
        } else if (std.mem.eql(u8, option, "--verify")) {
            parsed.verify = true;
            pos += 1;
        } else if (std.mem.eql(u8, option, "--no-verify")) {
            parsed.verify = false;
            pos += 1;
        } else if (std.mem.eql(u8, option, "--dry-run")) {
            parsed.dry_run = true;
            pos += 1;
        } else if (std.mem.eql(u8, option, "--strict")) {
            parsed.strict = true;
            pos += 1;
        } else if (std.mem.eql(u8, option, "--task-status-v1")) {
            parsed.task_status_v1 = true;
            pos += 1;
        } else if (std.mem.startsWith(u8, option, "--")) {
            return error.UnknownOption;
        } else {
            return error.TooManyArguments;
        }
    }
    if (parsed.profiles.len == 0) return error.InvalidRecord;
    return parsed;
}

/// `migrate-store-v2` copy-on-write command control plane.
///
/// The façade owns canonical-path mechanics, lock implementations, migration
/// transaction markers and all persisted bytes. This owner preserves the
/// alias preflight/recheck protocol, source-before-target exclusion order,
/// lock-scoped timing, one migration call, stable receipt publication and
/// reverse cleanup across every failure boundary.
pub fn MigrateStoreV2Command(comptime Ops: type) type {
    return struct {
        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try parseArguments(args);

            try Ops.validateRelationships(allocator, io, parsed);
            var canonical_target = try Ops.CanonicalTargetPath.init(
                allocator,
                io,
                parsed.target_path,
            );
            defer canonical_target.deinit();

            var source_exclusion = try Ops.SourceExclusion.init(
                allocator,
                io,
                parsed.source_path,
            );
            defer source_exclusion.deinit();

            try Ops.validateRelationships(allocator, io, parsed);
            var target_exclusion = try Ops.TargetExclusion.init(
                allocator,
                io,
                canonical_target.value(),
            );
            defer target_exclusion.deinit();

            const start_ns = Ops.startTimer(io);
            const result = try Ops.execute(allocator, io, parsed);
            const elapsed_ns = Ops.elapsedSince(io, start_ns);
            try writer.print(
                "migrate_store_v2 source={s} target={s} dry_run={} verified={} nodes_scanned={} nodes_written={} edges_scanned={} edges_written={} tombstone_nodes_skipped={} legacy_props_extracted={} legacy_text_repaired={} empty_text_physical_placeholders={} node_properties_written={} edge_properties_written={} task_statuses_written={} legacy_closed_tasks_converted={} backup={s} text_warmed={} marker_cleanup_pending={} elapsed_ns={}\n",
                .{
                    parsed.source_path,
                    parsed.target_path,
                    @intFromBool(parsed.dry_run),
                    @intFromBool(result.verified),
                    result.nodes_scanned,
                    result.nodes_written,
                    result.edges_scanned,
                    result.edges_written,
                    result.tombstone_nodes_skipped,
                    result.legacy_props_extracted,
                    result.legacy_text_repaired,
                    result.empty_text_physical_placeholders,
                    result.node_properties_written,
                    result.edge_properties_written,
                    result.task_statuses_written,
                    result.legacy_closed_tasks_converted,
                    parsed.backup_path orelse "",
                    @intFromBool(result.text_warmed),
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
        std.debug.assert(TestOps.canonical_live);
        std.debug.assert(TestOps.source_live);
        std.debug.assert(TestOps.target_live);
        TestOps.record(.write);
        const rendered = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(rendered);
        try self.buffer.appendSlice(self.allocator, rendered);
    }
};

const FailingWriter = struct {
    fn print(_: *FailingWriter, comptime _: []const u8, _: anytype) error{OutputClosed}!void {
        std.debug.assert(TestOps.canonical_live);
        std.debug.assert(TestOps.source_live);
        std.debug.assert(TestOps.target_live);
        TestOps.record(.write);
        return error.OutputClosed;
    }
};

const TestOps = struct {
    const Step = enum {
        validate_first,
        canonical_init,
        source_init,
        validate_second,
        target_init,
        start_timer,
        execute,
        elapsed,
        write,
        target_deinit,
        source_deinit,
        canonical_deinit,
    };

    const Result = struct {
        nodes_scanned: u64 = 13,
        nodes_written: u64 = 11,
        edges_scanned: u64 = 17,
        edges_written: u64 = 15,
        tombstone_nodes_skipped: u64 = 2,
        legacy_props_extracted: u64 = 19,
        legacy_text_repaired: u64 = 3,
        empty_text_physical_placeholders: u64 = 5,
        node_properties_written: u64 = 23,
        edge_properties_written: u64 = 29,
        task_statuses_written: u64 = 7,
        legacy_closed_tasks_converted: u64 = 1,
        text_warmed: bool = true,
        verified: bool = true,
        marker_cleanup_pending: bool = true,
    };

    var steps: [24]Step = undefined;
    var step_count: usize = 0;
    var validation_count: usize = 0;
    var fail_validation_call: usize = 0;
    var source_error: ?anyerror = null;
    var target_error: ?anyerror = null;
    var execute_error: ?anyerror = null;
    var canonical_live: bool = false;
    var source_live: bool = false;
    var target_live: bool = false;
    var elapsed_start_ns: u128 = 0;

    fn reset() void {
        step_count = 0;
        validation_count = 0;
        fail_validation_call = 0;
        source_error = null;
        target_error = null;
        execute_error = null;
        canonical_live = false;
        source_live = false;
        target_live = false;
        elapsed_start_ns = 0;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn expectSteps(expected: []const Step) !void {
        try std.testing.expectEqualSlices(Step, expected, steps[0..step_count]);
    }

    pub fn validateRelationships(_: std.mem.Allocator, _: std.Io, parsed: Arguments) !void {
        try std.testing.expectEqualStrings("source.kg", parsed.source_path);
        try std.testing.expectEqualStrings("target.kg", parsed.target_path);
        validation_count += 1;
        record(if (validation_count == 1) .validate_first else .validate_second);
        if (validation_count == fail_validation_call) return error.InvalidFileName;
    }

    pub const CanonicalTargetPath = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, target_path: []const u8) !CanonicalTargetPath {
            try std.testing.expectEqualStrings("target.kg", target_path);
            TestOps.record(.canonical_init);
            TestOps.canonical_live = true;
            return .{};
        }

        pub fn value(_: *const CanonicalTargetPath) []const u8 {
            std.debug.assert(TestOps.canonical_live);
            return "canonical-target.kg";
        }

        pub fn deinit(_: *CanonicalTargetPath) void {
            std.debug.assert(TestOps.canonical_live);
            std.debug.assert(!TestOps.source_live);
            std.debug.assert(!TestOps.target_live);
            TestOps.record(.canonical_deinit);
            TestOps.canonical_live = false;
        }
    };

    pub const SourceExclusion = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, source_path: []const u8) !SourceExclusion {
            try std.testing.expectEqualStrings("source.kg", source_path);
            std.debug.assert(TestOps.canonical_live);
            TestOps.record(.source_init);
            if (TestOps.source_error) |err| return err;
            TestOps.source_live = true;
            return .{};
        }

        pub fn deinit(_: *SourceExclusion) void {
            std.debug.assert(TestOps.source_live);
            std.debug.assert(!TestOps.target_live);
            TestOps.record(.source_deinit);
            TestOps.source_live = false;
        }
    };

    pub const TargetExclusion = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, canonical_path: []const u8) !TargetExclusion {
            try std.testing.expectEqualStrings("canonical-target.kg", canonical_path);
            std.debug.assert(TestOps.canonical_live);
            std.debug.assert(TestOps.source_live);
            TestOps.record(.target_init);
            if (TestOps.target_error) |err| return err;
            TestOps.target_live = true;
            return .{};
        }

        pub fn deinit(_: *TargetExclusion) void {
            std.debug.assert(TestOps.target_live);
            TestOps.record(.target_deinit);
            TestOps.target_live = false;
        }
    };

    pub fn startTimer(_: std.Io) u128 {
        std.debug.assert(canonical_live);
        std.debug.assert(source_live);
        std.debug.assert(target_live);
        record(.start_timer);
        return 103;
    }

    pub fn execute(_: std.mem.Allocator, _: std.Io, _: Arguments) !Result {
        std.debug.assert(canonical_live);
        std.debug.assert(source_live);
        std.debug.assert(target_live);
        record(.execute);
        if (execute_error) |err| return err;
        return .{};
    }

    pub fn elapsedSince(_: std.Io, start_ns: u128) u128 {
        std.debug.assert(target_live);
        record(.elapsed);
        elapsed_start_ns = start_ns;
        return 31;
    }
};

const migrate_store_v2_command = MigrateStoreV2Command(TestOps);

test "migrate store v2 arguments preserve defaults and option updates" {
    const defaults = try parseArguments(&.{ "tinykg", "migrate-store-v2", "source.kg", "target.kg" });
    try std.testing.expectEqualStrings("source.kg", defaults.source_path);
    try std.testing.expectEqualStrings("target.kg", defaults.target_path);
    try std.testing.expectEqual(@as(?[]const u8, null), defaults.backup_path);
    try std.testing.expectEqualStrings("agent-dag,markdown-document", defaults.profiles);
    try std.testing.expect(!defaults.profiles_explicit);
    try std.testing.expect(defaults.verify);
    try std.testing.expect(!defaults.warm_text);
    try std.testing.expect(!defaults.dry_run);
    try std.testing.expect(!defaults.strict);
    try std.testing.expect(!defaults.task_status_v1);

    const full = try parseArguments(&.{
        "tinykg",
        "migrate-store-v2",
        "source.kg",
        "target.kg",
        "--backup",
        "backup.kg",
        "--profile",
        "agent-dag",
        "--warm-text",
        "--no-verify",
        "--dry-run",
        "--strict",
        "--task-status-v1",
        "--verify",
    });
    try std.testing.expectEqualStrings("backup.kg", full.backup_path.?);
    try std.testing.expectEqualStrings("agent-dag", full.profiles);
    try std.testing.expect(full.profiles_explicit);
    try std.testing.expect(full.warm_text);
    try std.testing.expect(full.verify);
    try std.testing.expect(full.dry_run);
    try std.testing.expect(full.strict);
    try std.testing.expect(full.task_status_v1);
}

test "migrate store v2 arguments reject missing duplicate unknown and empty values" {
    try std.testing.expectError(error.MissingArgument, parseArguments(&.{ "tinykg", "migrate-store-v2", "source.kg" }));
    try std.testing.expectError(error.MissingArgument, parseArguments(&.{ "tinykg", "migrate-store-v2", "source.kg", "target.kg", "--backup" }));
    try std.testing.expectError(error.TooManyArguments, parseArguments(&.{ "tinykg", "migrate-store-v2", "source.kg", "target.kg", "--backup", "one.kg", "--backup", "two.kg" }));
    try std.testing.expectError(error.TooManyArguments, parseArguments(&.{ "tinykg", "migrate-store-v2", "source.kg", "target.kg", "--profile", "agent-dag", "--profile", "markdown-document" }));
    try std.testing.expectError(error.UnknownOption, parseArguments(&.{ "tinykg", "migrate-store-v2", "source.kg", "target.kg", "--future" }));
    try std.testing.expectError(error.TooManyArguments, parseArguments(&.{ "tinykg", "migrate-store-v2", "source.kg", "target.kg", "extra" }));
    try std.testing.expectError(error.InvalidRecord, parseArguments(&.{ "tinykg", "migrate-store-v2", "source.kg", "target.kg", "--profile", "" }));
}

test "migrate store v2 command keeps preflight canonical source recheck target and timer order" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try migrate_store_v2_command.run(&.{
        "tinykg",
        "migrate-store-v2",
        "source.kg",
        "target.kg",
        "--backup",
        "backup.kg",
        "--dry-run",
    }, &writer, std.testing.allocator, std.testing.io);
    try TestOps.expectSteps(&.{
        .validate_first,
        .canonical_init,
        .source_init,
        .validate_second,
        .target_init,
        .start_timer,
        .execute,
        .elapsed,
        .write,
        .target_deinit,
        .source_deinit,
        .canonical_deinit,
    });
    try std.testing.expectEqual(@as(u128, 103), TestOps.elapsed_start_ns);
    try std.testing.expectEqualStrings(
        "migrate_store_v2 source=source.kg target=target.kg dry_run=1 verified=1 nodes_scanned=13 nodes_written=11 edges_scanned=17 edges_written=15 tombstone_nodes_skipped=2 legacy_props_extracted=19 legacy_text_repaired=3 empty_text_physical_placeholders=5 node_properties_written=23 edge_properties_written=29 task_statuses_written=7 legacy_closed_tasks_converted=1 backup=backup.kg text_warmed=1 marker_cleanup_pending=1 elapsed_ns=31\n",
        writer.buffer.items,
    );
}

test "migrate store v2 command stops before locks when preflight fails" {
    TestOps.reset();
    TestOps.fail_validation_call = 1;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidFileName,
        migrate_store_v2_command.run(&.{ "tinykg", "migrate-store-v2", "source.kg", "target.kg" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{.validate_first});
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "migrate store v2 command closes source and canonical path after relationship recheck failure" {
    TestOps.reset();
    TestOps.fail_validation_call = 2;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidFileName,
        migrate_store_v2_command.run(&.{ "tinykg", "migrate-store-v2", "source.kg", "target.kg" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{
        .validate_first,
        .canonical_init,
        .source_init,
        .validate_second,
        .source_deinit,
        .canonical_deinit,
    });
}

test "migrate store v2 command closes source after target exclusion failure" {
    TestOps.reset();
    TestOps.target_error = error.TargetLocked;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.TargetLocked,
        migrate_store_v2_command.run(&.{ "tinykg", "migrate-store-v2", "source.kg", "target.kg" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{
        .validate_first,
        .canonical_init,
        .source_init,
        .validate_second,
        .target_init,
        .source_deinit,
        .canonical_deinit,
    });
}

test "migrate store v2 command closes both exclusions after migration failure" {
    TestOps.reset();
    TestOps.execute_error = error.MigrationFailed;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.MigrationFailed,
        migrate_store_v2_command.run(&.{ "tinykg", "migrate-store-v2", "source.kg", "target.kg" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{
        .validate_first,
        .canonical_init,
        .source_init,
        .validate_second,
        .target_init,
        .start_timer,
        .execute,
        .target_deinit,
        .source_deinit,
        .canonical_deinit,
    });
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "migrate store v2 command captures elapsed before writer and closes exclusions in reverse order" {
    TestOps.reset();
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        migrate_store_v2_command.run(&.{ "tinykg", "migrate-store-v2", "source.kg", "target.kg" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{
        .validate_first,
        .canonical_init,
        .source_init,
        .validate_second,
        .target_init,
        .start_timer,
        .execute,
        .elapsed,
        .write,
        .target_deinit,
        .source_deinit,
        .canonical_deinit,
    });
    try std.testing.expectEqual(@as(u128, 103), TestOps.elapsed_start_ns);
}
