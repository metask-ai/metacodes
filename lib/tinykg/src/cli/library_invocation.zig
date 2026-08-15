const std = @import("std");

/// Stable in-process façade over the complete CLI parser and dispatcher.
/// `Ops` owns the concrete dispatch and environment scope so this module stays
/// independently testable and never imports command implementations.
pub fn LibraryInvocation(comptime Ops: type) type {
    return struct {
        pub const Invocation = struct {
            /// Complete argv, including the conventional program-name slot at
            /// index zero. Every executable command and compatibility alias is
            /// admitted by the same parser used by `src/main.zig`.
            argv: []const []const u8,

            /// Optional immutable environment snapshot for this invocation.
            /// The pointer and all of its strings must remain alive until the
            /// synchronous call returns. Null means no injected map; supported
            /// process-environment fallbacks remain backend policy.
            environment: ?*const std.process.Environ.Map = null,
        };

        /// Executes one CLI invocation without terminating the host process.
        /// Command failures are returned as Zig errors. Output written before
        /// an error remains the caller Writer's responsibility.
        pub fn invoke(
            invocation: Invocation,
            writer: *std.Io.Writer,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            var environment_scope = Ops.enterEnvironment(invocation.environment);
            defer environment_scope.deinit();
            try Ops.dispatch(invocation.argv, writer, allocator, io);
        }

        /// Executes one CLI invocation and returns stdout owned by `allocator`.
        /// On failure no partial output escapes; on success the caller frees
        /// the returned slice with the same allocator.
        pub fn invokeAlloc(
            invocation: Invocation,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) ![]u8 {
            var output = std.Io.Writer.Allocating.init(allocator);
            defer output.deinit();
            try invoke(invocation, &output.writer, allocator, io);
            return try output.toOwnedSlice();
        }
    };
}

const TestScope = struct {
    previous: ?*const std.process.Environ.Map,

    fn deinit(self: *TestScope) void {
        TestOps.current_environment = self.previous;
    }
};

const TestOps = struct {
    var current_environment: ?*const std.process.Environ.Map = null;
    var fail_after_write = false;

    pub fn enterEnvironment(environment: ?*const std.process.Environ.Map) TestScope {
        const scope = TestScope{ .previous = current_environment };
        current_environment = environment;
        return scope;
    }

    pub fn dispatch(
        argv: []const []const u8,
        writer: *std.Io.Writer,
        _: std.mem.Allocator,
        _: std.Io,
    ) !void {
        try std.testing.expect(argv.len >= 2);
        try writer.print("command={s} store={s}\n", .{
            argv[1],
            if (current_environment) |environment|
                environment.get("TINYKG_STORE") orelse ""
            else
                "",
        });
        if (fail_after_write) return error.CommandFailed;
    }
};

const test_invocation = LibraryInvocation(TestOps);

test "library invocation returns owned output and restores environment" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("TINYKG_STORE", "embedded.kg");

    TestOps.current_environment = null;
    TestOps.fail_after_write = false;
    const output = try test_invocation.invokeAlloc(.{
        .argv = &.{ "embedded", "store-info" },
        .environment = &environment,
    }, std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("command=store-info store=embedded.kg\n", output);
    try std.testing.expectEqual(@as(?*const std.process.Environ.Map, null), TestOps.current_environment);
}

test "library allocated invocation suppresses partial output on failure" {
    TestOps.current_environment = null;
    TestOps.fail_after_write = true;
    defer TestOps.fail_after_write = false;

    try std.testing.expectError(error.CommandFailed, test_invocation.invokeAlloc(.{
        .argv = &.{ "embedded", "stats" },
    }, std.testing.allocator, std.testing.io));
    try std.testing.expectEqual(@as(?*const std.process.Environ.Map, null), TestOps.current_environment);
}
