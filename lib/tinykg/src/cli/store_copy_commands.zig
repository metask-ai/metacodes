const std = @import("std");

/// Physical Store backup/restore command control plane.
///
/// Canonical path handling, content hashing, transaction markers, staging,
/// recursive durability, publication recovery, and concrete Store types stay
/// behind `Ops`. This owner keeps command syntax ahead of side effects, holds
/// backup source exclusion through result publication, invokes each copy
/// transaction once, and reports only a successful transaction result.
pub fn StoreCopyCommands(comptime Ops: type) type {
    return struct {
        pub fn runBackup(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parseDbArguments(allocator, io, args, 2, 1, 1, true);
            const start_ns = Ops.startTimeNs(io);
            var context = try Ops.BackupContext.init(allocator, io, parsed.db_path);
            defer context.deinit();

            const result = try context.execute(parsed.rest[0]);
            const elapsed_ns = Ops.elapsedTimeNs(io, start_ns);
            try writer.print(
                "backup source={s} target={s} nodes={} edges={} source_store_bytes={} backup_store_bytes={} marker_cleanup_pending={} elapsed_ns={}\n",
                .{
                    parsed.db_path,
                    parsed.rest[0],
                    result.nodes,
                    result.edges,
                    result.source_store_bytes,
                    result.backup_store_bytes,
                    @intFromBool(result.marker_cleanup_pending),
                    elapsed_ns,
                },
            );
        }

        pub fn runRestore(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            if (args.len != 4) {
                return if (args.len < 4) error.MissingArgument else error.TooManyArguments;
            }
            const start_ns = Ops.startTimeNs(io);
            const result = try Ops.restore(allocator, io, args[2], args[3]);
            const elapsed_ns = Ops.elapsedTimeNs(io, start_ns);
            try writer.print(
                "restore source={s} target={s} nodes={} edges={} source_store_bytes={} restored_store_bytes={} marker_cleanup_pending={} elapsed_ns={}\n",
                .{
                    args[2],
                    args[3],
                    result.nodes,
                    result.edges,
                    result.source_store_bytes,
                    result.backup_store_bytes,
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
        TestOps.record(.write);
        const rendered = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(rendered);
        try self.buffer.appendSlice(self.allocator, rendered);
    }
};

const FailingWriter = struct {
    fn print(_: *FailingWriter, comptime _: []const u8, _: anytype) error{OutputClosed}!void {
        TestOps.record(.write);
        return error.OutputClosed;
    }
};

const TestOps = struct {
    const Step = enum {
        parse_backup,
        clock_start,
        backup_init,
        backup_execute,
        restore_execute,
        clock_elapsed,
        write,
        backup_deinit,
    };

    const Result = struct {
        nodes: u64 = 7,
        edges: u64 = 11,
        source_store_bytes: u64 = 101,
        backup_store_bytes: u64 = 103,
        marker_cleanup_pending: bool = true,
    };

    var steps: [16]Step = undefined;
    var step_count: usize = 0;
    var backup_error: ?anyerror = null;
    var restore_error: ?anyerror = null;

    fn reset() void {
        step_count = 0;
        backup_error = null;
        restore_error = null;
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
        start: usize,
        min_rest: usize,
        max_rest: usize,
        require_existing_db: bool,
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        record(.parse_backup);
        try std.testing.expectEqual(@as(usize, 2), start);
        try std.testing.expectEqual(@as(usize, 1), min_rest);
        try std.testing.expectEqual(@as(usize, 1), max_rest);
        try std.testing.expect(require_existing_db);
        if (args.len < start + min_rest) return error.MissingArgument;
        if (args.len > start + max_rest) return error.TooManyArguments;
        return .{ .db_path = "db", .rest = args[start..] };
    }

    pub fn startTimeNs(_: std.Io) u64 {
        record(.clock_start);
        return 100;
    }

    pub fn elapsedTimeNs(_: std.Io, start_ns: u64) u64 {
        record(.clock_elapsed);
        std.testing.expectEqual(@as(u64, 100), start_ns) catch unreachable;
        return 23;
    }

    pub const BackupContext = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, db_path: []const u8) !BackupContext {
            TestOps.record(.backup_init);
            try std.testing.expectEqualStrings("db", db_path);
            return .{};
        }

        pub fn deinit(_: *BackupContext) void {
            TestOps.record(.backup_deinit);
        }

        pub fn execute(_: *BackupContext, target_path: []const u8) !Result {
            TestOps.record(.backup_execute);
            try std.testing.expectEqualStrings("backup.kg", target_path);
            if (TestOps.backup_error) |err| return err;
            return .{};
        }
    };

    pub fn restore(
        _: std.mem.Allocator,
        _: std.Io,
        source_path: []const u8,
        target_path: []const u8,
    ) !Result {
        record(.restore_execute);
        try std.testing.expectEqualStrings("backup.kg", source_path);
        try std.testing.expectEqualStrings("restored.kg", target_path);
        if (restore_error) |err| return err;
        return .{};
    }
};

const store_copy_commands = StoreCopyCommands(TestOps);

test "store backup command preserves source exclusion timing and exact output" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try store_copy_commands.runBackup(
        &.{ "tinykg", "backup", "backup.kg" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{
        .parse_backup,
        .clock_start,
        .backup_init,
        .backup_execute,
        .clock_elapsed,
        .write,
        .backup_deinit,
    });
    try std.testing.expectEqualStrings(
        "backup source=db target=backup.kg nodes=7 edges=11 source_store_bytes=101 backup_store_bytes=103 marker_cleanup_pending=1 elapsed_ns=23\n",
        writer.buffer.items,
    );
}

test "store backup command rejects invalid arguments before timing and exclusion" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.MissingArgument,
        store_copy_commands.runBackup(
            &.{ "tinykg", "backup" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{.parse_backup});

    TestOps.reset();
    try std.testing.expectError(
        error.TooManyArguments,
        store_copy_commands.runBackup(
            &.{ "tinykg", "backup", "one", "two" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{.parse_backup});
}

test "store backup command closes source exclusion after operation failure" {
    TestOps.reset();
    TestOps.backup_error = error.BackupSourceChanged;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.BackupSourceChanged,
        store_copy_commands.runBackup(
            &.{ "tinykg", "backup", "backup.kg" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{
        .parse_backup,
        .clock_start,
        .backup_init,
        .backup_execute,
        .backup_deinit,
    });
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "store backup command closes source exclusion after writer failure" {
    TestOps.reset();
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        store_copy_commands.runBackup(
            &.{ "tinykg", "backup", "backup.kg" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{
        .parse_backup,
        .clock_start,
        .backup_init,
        .backup_execute,
        .clock_elapsed,
        .write,
        .backup_deinit,
    });
}

test "store restore command preserves exact arity transaction timing and output" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try store_copy_commands.runRestore(
        &.{ "tinykg", "restore", "backup.kg", "restored.kg" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .clock_start, .restore_execute, .clock_elapsed, .write });
    try std.testing.expectEqualStrings(
        "restore source=backup.kg target=restored.kg nodes=7 edges=11 source_store_bytes=101 restored_store_bytes=103 marker_cleanup_pending=1 elapsed_ns=23\n",
        writer.buffer.items,
    );
}

test "store restore command rejects invalid arity before timing and transaction" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.MissingArgument,
        store_copy_commands.runRestore(
            &.{ "tinykg", "restore", "backup.kg" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{});

    try std.testing.expectError(
        error.TooManyArguments,
        store_copy_commands.runRestore(
            &.{ "tinykg", "restore", "backup.kg", "restored.kg", "extra" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{});
}

test "store restore command publishes no result after transaction failure" {
    TestOps.reset();
    TestOps.restore_error = error.RestoreSourceChanged;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.RestoreSourceChanged,
        store_copy_commands.runRestore(
            &.{ "tinykg", "restore", "backup.kg", "restored.kg" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .clock_start, .restore_execute });
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}
