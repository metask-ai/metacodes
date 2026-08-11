const std = @import("std");

/// `init` command bootstrap control plane.
///
/// Concrete Store allocation, empty-store publication, manifest bytes and
/// filesystem durability stay behind `Ops.Context`. This owner keeps optional
/// path validation ahead of context creation, preserves the historical
/// create-empty-before-manifest ordering, and publishes `ready` only after both
/// bootstrap phases succeed.
pub fn StoreInitCommand(comptime Ops: type) type {
    return struct {
        fn parseDbPath(args: []const []const u8, index: usize) ![]const u8 {
            if (args.len <= index) return Ops.defaultPath();
            if (args.len == index + 1) return args[index];
            return error.TooManyArguments;
        }

        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db_path = try parseDbPath(args, 2);
            var context = try Ops.Context.init(allocator, io, db_path);
            defer context.deinit();

            try context.createEmpty();
            try context.writeManifest();
            try writer.print("ready {s}\n", .{db_path});
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
        default_path,
        context_init,
        create_empty,
        write_manifest,
        write,
        context_deinit,
    };

    var steps: [12]Step = undefined;
    var step_count: usize = 0;
    var expected_path: []const u8 = "default.kg";
    var create_error: ?anyerror = null;
    var manifest_error: ?anyerror = null;
    var create_completed: bool = false;

    fn reset() void {
        step_count = 0;
        expected_path = "default.kg";
        create_error = null;
        manifest_error = null;
        create_completed = false;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn expectSteps(expected: []const Step) !void {
        try std.testing.expectEqualSlices(Step, expected, steps[0..step_count]);
    }

    pub fn defaultPath() []const u8 {
        record(.default_path);
        return "default.kg";
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, db_path: []const u8) !Context {
            TestOps.record(.context_init);
            try std.testing.expectEqualStrings(TestOps.expected_path, db_path);
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.record(.context_deinit);
        }

        pub fn createEmpty(_: *Context) !void {
            TestOps.record(.create_empty);
            if (TestOps.create_error) |err| return err;
            TestOps.create_completed = true;
        }

        pub fn writeManifest(_: *Context) !void {
            TestOps.record(.write_manifest);
            try std.testing.expect(TestOps.create_completed);
            if (TestOps.manifest_error) |err| return err;
        }
    };
};

const store_init_command = StoreInitCommand(TestOps);

test "store init command uses default path and publishes after manifest" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try store_init_command.run(
        &.{ "tinykg", "init" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{
        .default_path,
        .context_init,
        .create_empty,
        .write_manifest,
        .write,
        .context_deinit,
    });
    try std.testing.expectEqualStrings("ready default.kg\n", writer.buffer.items);
}

test "store init command accepts one explicit path and rejects extras before context" {
    TestOps.reset();
    TestOps.expected_path = "explicit.kg";
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try store_init_command.run(
        &.{ "tinykg", "init", "explicit.kg" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{
        .context_init,
        .create_empty,
        .write_manifest,
        .write,
        .context_deinit,
    });
    try std.testing.expectEqualStrings("ready explicit.kg\n", writer.buffer.items);

    TestOps.reset();
    try std.testing.expectError(
        error.TooManyArguments,
        store_init_command.run(
            &.{ "tinykg", "init", "one.kg", "two.kg" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{});
}

test "store init command closes context after empty store creation failure" {
    TestOps.reset();
    TestOps.expected_path = "broken.kg";
    TestOps.create_error = error.AlreadyExists;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.AlreadyExists,
        store_init_command.run(
            &.{ "tinykg", "init", "broken.kg" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .context_init, .create_empty, .context_deinit });
    try std.testing.expect(!TestOps.create_completed);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "store init command preserves created store boundary after manifest failure" {
    TestOps.reset();
    TestOps.expected_path = "manifest-failure.kg";
    TestOps.manifest_error = error.ManifestWriteFailed;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.ManifestWriteFailed,
        store_init_command.run(
            &.{ "tinykg", "init", "manifest-failure.kg" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{
        .context_init,
        .create_empty,
        .write_manifest,
        .context_deinit,
    });
    try std.testing.expect(TestOps.create_completed);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "store init command closes context after writer failure" {
    TestOps.reset();
    TestOps.expected_path = "writer-failure.kg";
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        store_init_command.run(
            &.{ "tinykg", "init", "writer-failure.kg" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{
        .context_init,
        .create_empty,
        .write_manifest,
        .write,
        .context_deinit,
    });
    try std.testing.expect(TestOps.create_completed);
}
