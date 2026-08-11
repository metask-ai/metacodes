const std = @import("std");

/// Segment-bundle CLI control plane. Query planning, export publication, and
/// garbage-collection sequencing live here; the façade-provided `Ops` keeps
/// Store locks, storage representations, and rendering data planes private.
pub fn SegmentCommands(comptime Ql: type, comptime Ops: type) type {
    return struct {
        pub fn runQuery(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
            explain: bool,
        ) !void {
            if (args.len < 4) return error.MissingArgument;
            const root_dir = args[2];
            const source = try Ops.joinArguments(allocator, args[3..]);
            defer allocator.free(source);

            const ast_query = try Ql.parser.parse(allocator, source);
            defer Ql.ast.freeQuery(allocator, ast_query);
            var type_env = try Ql.typecheck.check(allocator, ast_query);
            defer type_env.deinit(allocator);
            var logical = try Ql.planner.plan(allocator, ast_query);
            defer logical.deinit(allocator);
            var physical = try Ql.optimizer.optimize(allocator, logical);
            defer physical.deinit(allocator);

            const output = try Ops.renderQueryOutput(allocator, io, root_dir, physical, explain);
            defer allocator.free(output);
            try writer.writeAll(output);
        }

        pub fn runExport(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parseExportArguments(allocator, io, args);
            var context = try Ops.ExportContext.init(allocator, io, parsed.db_path);
            defer context.deinit();
            try context.publish(parsed.root_dir);
            const meta = try context.readMeta();
            try writer.print(
                "segment_bundle root={s} nodes={} edges={}\n",
                .{ parsed.root_dir, meta.nodes, meta.edges },
            );
        }

        pub fn runGc(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            if (args.len != 3) return error.MissingArgument;
            const result = try Ops.gcUnpinned(allocator, io, args[2]);
            try writer.print(
                "segment_bundle_gc root={s} manifests={} trees={}\n",
                .{ args[2], result.deleted_manifests, result.deleted_trees },
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

    fn writeAll(self: *TestWriter, bytes: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    fn print(self: *TestWriter, comptime format: []const u8, args: anytype) !void {
        const rendered = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(rendered);
        try self.writeAll(rendered);
    }
};

const TestAstQuery = struct {
    source: []u8,
};

const TestTypeEnvironment = struct {
    marker: []u8,

    pub fn deinit(self: *TestTypeEnvironment, allocator: std.mem.Allocator) void {
        allocator.free(self.marker);
    }
};

const TestLogicalPlan = struct {
    source: []u8,

    pub fn deinit(self: *TestLogicalPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
    }
};

const TestPhysicalPlan = struct {
    source: []u8,

    pub fn deinit(self: *TestPhysicalPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
    }
};

const TestQl = struct {
    pub const parser = struct {
        pub fn parse(allocator: std.mem.Allocator, source: []const u8) !TestAstQuery {
            if (std.mem.eql(u8, source, "parse-error")) return error.InvalidRecord;
            return .{ .source = try allocator.dupe(u8, source) };
        }
    };

    pub const ast = struct {
        pub fn freeQuery(allocator: std.mem.Allocator, query: TestAstQuery) void {
            allocator.free(query.source);
        }
    };

    pub const typecheck = struct {
        pub fn check(allocator: std.mem.Allocator, query: TestAstQuery) !TestTypeEnvironment {
            if (query.source.len == 0) return error.InvalidRecord;
            return .{ .marker = try allocator.dupe(u8, "checked") };
        }
    };

    pub const planner = struct {
        pub fn plan(allocator: std.mem.Allocator, query: TestAstQuery) !TestLogicalPlan {
            return .{ .source = try allocator.dupe(u8, query.source) };
        }
    };

    pub const optimizer = struct {
        pub fn optimize(allocator: std.mem.Allocator, logical: TestLogicalPlan) !TestPhysicalPlan {
            return .{ .source = try allocator.dupe(u8, logical.source) };
        }
    };
};

const TestOps = struct {
    pub fn joinArguments(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
        return std.mem.join(allocator, " ", parts);
    }

    pub fn renderQueryOutput(
        allocator: std.mem.Allocator,
        _: std.Io,
        root_dir: []const u8,
        physical: anytype,
        explain: bool,
    ) ![]u8 {
        if (std.mem.eql(u8, root_dir, "render-error")) return error.FileNotFound;
        return std.fmt.allocPrint(
            allocator,
            "segment_query root={s} explain={} source={s}\n",
            .{ root_dir, @intFromBool(explain), physical.source },
        );
    }

    pub fn parseExportArguments(_: std.mem.Allocator, _: std.Io, args: []const []const u8) !struct {
        db_path: []const u8,
        root_dir: []const u8,
    } {
        if (args.len < 4) return error.MissingArgument;
        if (args.len > 4) return error.TooManyArguments;
        return .{ .db_path = args[2], .root_dir = args[3] };
    }

    pub const ExportContext = struct {
        allocator: std.mem.Allocator,
        db_path: []u8,
        published_root: ?[]const u8 = null,

        pub fn init(allocator: std.mem.Allocator, _: std.Io, db_path: []const u8) !ExportContext {
            return .{
                .allocator = allocator,
                .db_path = try allocator.dupe(u8, db_path),
            };
        }

        pub fn deinit(self: *ExportContext) void {
            self.allocator.free(self.db_path);
        }

        pub fn publish(self: *ExportContext, root_dir: []const u8) !void {
            if (std.mem.eql(u8, root_dir, "publish-error")) return error.InvalidRecord;
            self.published_root = root_dir;
        }

        pub fn readMeta(self: *ExportContext) !struct { nodes: u64, edges: u64 } {
            if (self.published_root == null) return error.InvalidRecord;
            return .{ .nodes = 7, .edges = 11 };
        }
    };

    pub fn gcUnpinned(_: std.mem.Allocator, _: std.Io, root_dir: []const u8) !struct {
        deleted_manifests: usize,
        deleted_trees: usize,
    } {
        if (std.mem.eql(u8, root_dir, "gc-error")) return error.InvalidRecord;
        return .{ .deleted_manifests = 2, .deleted_trees = 3 };
    }
};

const test_commands = SegmentCommands(TestQl, TestOps);

test "segment query command owns checked plan and explain routing" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runQuery(
        &.{ "tinykg", "segment-query", "bundle", "MATCH", "(n)" },
        &writer,
        std.testing.allocator,
        std.testing.io,
        false,
    );
    try std.testing.expectEqualStrings(
        "segment_query root=bundle explain=0 source=MATCH (n)\n",
        writer.buffer.items,
    );

    writer.buffer.clearRetainingCapacity();
    try test_commands.runQuery(
        &.{ "tinykg", "segment-query-explain", "bundle", "RETURN", "n" },
        &writer,
        std.testing.allocator,
        std.testing.io,
        true,
    );
    try std.testing.expectEqualStrings(
        "segment_query root=bundle explain=1 source=RETURN n\n",
        writer.buffer.items,
    );
}

test "segment query command rejects incomplete and failed pipelines before output" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.MissingArgument,
        test_commands.runQuery(
            &.{ "tinykg", "segment-query", "bundle" },
            &writer,
            std.testing.allocator,
            std.testing.io,
            false,
        ),
    );
    try std.testing.expectError(
        error.InvalidRecord,
        test_commands.runQuery(
            &.{ "tinykg", "segment-query", "bundle", "parse-error" },
            &writer,
            std.testing.allocator,
            std.testing.io,
            false,
        ),
    );
    try std.testing.expectError(
        error.FileNotFound,
        test_commands.runQuery(
            &.{ "tinykg", "segment-query", "render-error", "MATCH" },
            &writer,
            std.testing.allocator,
            std.testing.io,
            false,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "segment export command sequences publication metadata and summary" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runExport(
        &.{ "tinykg", "export-segment-bundle", "db", "bundle" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings(
        "segment_bundle root=bundle nodes=7 edges=11\n",
        writer.buffer.items,
    );

    writer.buffer.clearRetainingCapacity();
    try std.testing.expectError(
        error.InvalidRecord,
        test_commands.runExport(
            &.{ "tinykg", "export-segment-bundle", "db", "publish-error" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "segment gc command preserves arity errors and deletion summary" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runGc(
        &.{ "tinykg", "gc-segment-bundle", "bundle" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings(
        "segment_bundle_gc root=bundle manifests=2 trees=3\n",
        writer.buffer.items,
    );

    writer.buffer.clearRetainingCapacity();
    try std.testing.expectError(
        error.MissingArgument,
        test_commands.runGc(
            &.{ "tinykg", "gc-segment-bundle" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectError(
        error.MissingArgument,
        test_commands.runGc(
            &.{ "tinykg", "gc-segment-bundle", "bundle", "extra" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
}
