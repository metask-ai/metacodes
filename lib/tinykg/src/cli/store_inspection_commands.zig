const std = @import("std");

/// Read-only control plane for Store statistics and diagnostic snapshots.
///
/// Concrete locks, Store types, filesystem probes, text-catalog admission,
/// and manifest ownership stay behind `Ops.Context`. This owner ensures that
/// `store-info` performs every fallible read before publishing output and
/// only probes text staleness when the complete persistent text file set is
/// present.
pub fn StoreInspectionCommands(comptime Ops: type) type {
    return struct {
        pub fn runStats(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db_path = try Ops.parseDbPath(args, 2);
            var context = try Ops.Context.init(allocator, io, db_path);
            defer context.deinit();
            const stats = try context.stats();
            try writer.print("nodes={} edges={}\n", .{ stats.nodes, stats.edges });
        }

        pub fn runStoreInfo(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db_path = try Ops.parseDbPath(args, 2);
            var context = try Ops.Context.init(allocator, io, db_path);
            defer context.deinit();

            const stats = try context.stats();
            const store_bytes = try context.storeBytes(allocator);
            const text_docs_bytes = try context.textFileSize(allocator, "text_docs.idx");
            const text_terms_bytes = try context.textFileSize(allocator, "text_terms.idx");
            const text_postings_bytes = try context.textFileSize(allocator, "text_postings.dat");
            const text_files_present = text_docs_bytes != null and
                text_terms_bytes != null and
                text_postings_bytes != null;
            const text_current = text_files_present and
                !try context.textCatalogQuickStale(allocator);
            var manifest = try context.readManifest(allocator);
            defer context.deinitManifest(allocator, &manifest);

            try writer.print(
                "db={s}\nnodes={}\nedges={}\nstore_dir_bytes={}\ntext_warm={}\ntext_files_present={}\ntext_current={}\ntext_stale={}\nstore_manifest={s}\nstorage_format_version={s}\nschema_version={s}\nenabled_profiles={s}\ntext_docs_exists={}\ntext_terms_exists={}\ntext_postings_exists={}\n",
                .{
                    db_path,
                    stats.nodes,
                    stats.edges,
                    store_bytes,
                    @intFromBool(text_current),
                    @intFromBool(text_files_present),
                    @intFromBool(text_current),
                    @intFromBool(!text_current),
                    manifest.status,
                    manifest.storage_format_version,
                    manifest.schema_version,
                    manifest.enabled_profiles,
                    @intFromBool(text_docs_bytes != null),
                    @intFromBool(text_terms_bytes != null),
                    @intFromBool(text_postings_bytes != null),
                },
            );
            try printOptionalBytes(writer, "text_docs_bytes", text_docs_bytes);
            try printOptionalBytes(writer, "text_terms_bytes", text_terms_bytes);
            try printOptionalBytes(writer, "text_postings_bytes", text_postings_bytes);
        }

        fn printOptionalBytes(writer: anytype, comptime key: []const u8, value: ?u64) !void {
            try writer.print("{s}={}\n", .{ key, value orelse 0 });
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
        const rendered = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(rendered);
        try self.buffer.appendSlice(self.allocator, rendered);
    }
};

const FailingWriter = struct {
    fn print(_: *FailingWriter, comptime _: []const u8, _: anytype) !void {
        return error.WriteFailed;
    }
};

const TestOps = struct {
    const Step = enum {
        init,
        stats,
        store_bytes,
        docs_size,
        terms_size,
        postings_size,
        stale,
        manifest,
        manifest_deinit,
        context_deinit,
    };

    const Manifest = struct {
        status: []const u8 = "ready",
        storage_format_version: []const u8 = "2",
        schema_version: []const u8 = "3",
        enabled_profiles: []const u8 = "agent-memory",
    };

    var steps: [20]Step = undefined;
    var step_count: usize = 0;
    var docs_bytes: ?u64 = 101;
    var terms_bytes: ?u64 = 202;
    var postings_bytes: ?u64 = 303;
    var stale: bool = false;
    var stale_error: ?anyerror = null;
    var manifest_error: ?anyerror = null;

    fn reset() void {
        step_count = 0;
        docs_bytes = 101;
        terms_bytes = 202;
        postings_bytes = 303;
        stale = false;
        stale_error = null;
        manifest_error = null;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn expectSteps(expected: []const Step) !void {
        try std.testing.expectEqualSlices(Step, expected, steps[0..step_count]);
    }

    pub fn parseDbPath(args: []const []const u8, index: usize) ![]const u8 {
        if (args.len <= index) return "default-db";
        if (args.len == index + 1) return args[index];
        return error.TooManyArguments;
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, _: []const u8) !Context {
            TestOps.record(.init);
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.record(.context_deinit);
        }

        pub fn stats(_: *Context) !struct { nodes: u64, edges: u64 } {
            TestOps.record(.stats);
            return .{ .nodes = 7, .edges = 11 };
        }

        pub fn storeBytes(_: *Context, _: std.mem.Allocator) !u64 {
            TestOps.record(.store_bytes);
            return 4096;
        }

        pub fn textFileSize(_: *Context, _: std.mem.Allocator, file_name: []const u8) !?u64 {
            if (std.mem.eql(u8, file_name, "text_docs.idx")) {
                TestOps.record(.docs_size);
                return TestOps.docs_bytes;
            }
            if (std.mem.eql(u8, file_name, "text_terms.idx")) {
                TestOps.record(.terms_size);
                return TestOps.terms_bytes;
            }
            if (std.mem.eql(u8, file_name, "text_postings.dat")) {
                TestOps.record(.postings_size);
                return TestOps.postings_bytes;
            }
            return error.InvalidRecord;
        }

        pub fn textCatalogQuickStale(_: *Context, _: std.mem.Allocator) !bool {
            TestOps.record(.stale);
            if (TestOps.stale_error) |err| return err;
            return TestOps.stale;
        }

        pub fn readManifest(_: *Context, _: std.mem.Allocator) !Manifest {
            TestOps.record(.manifest);
            if (TestOps.manifest_error) |err| return err;
            return .{};
        }

        pub fn deinitManifest(_: *Context, _: std.mem.Allocator, _: *Manifest) void {
            TestOps.record(.manifest_deinit);
        }
    };
};

const store_inspection_commands = StoreInspectionCommands(TestOps);

test "store stats publishes exact snapshot and closes context" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try store_inspection_commands.runStats(
        &.{ "tinykg", "stats", "db" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .init, .stats, .context_deinit });
    try std.testing.expectEqualStrings("nodes=7 edges=11\n", writer.buffer.items);
}

test "store info publishes one complete current text snapshot" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try store_inspection_commands.runStoreInfo(
        &.{ "tinykg", "store-info", "db" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{
        .init,
        .stats,
        .store_bytes,
        .docs_size,
        .terms_size,
        .postings_size,
        .stale,
        .manifest,
        .manifest_deinit,
        .context_deinit,
    });
    try std.testing.expectEqualStrings(
        "db=db\nnodes=7\nedges=11\nstore_dir_bytes=4096\ntext_warm=1\ntext_files_present=1\ntext_current=1\ntext_stale=0\nstore_manifest=ready\nstorage_format_version=2\nschema_version=3\nenabled_profiles=agent-memory\ntext_docs_exists=1\ntext_terms_exists=1\ntext_postings_exists=1\ntext_docs_bytes=101\ntext_terms_bytes=202\ntext_postings_bytes=303\n",
        writer.buffer.items,
    );
}

test "store info skips staleness probe when text files are incomplete" {
    TestOps.reset();
    TestOps.terms_bytes = null;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try store_inspection_commands.runStoreInfo(
        &.{ "tinykg", "store-info", "db" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{
        .init,
        .stats,
        .store_bytes,
        .docs_size,
        .terms_size,
        .postings_size,
        .manifest,
        .manifest_deinit,
        .context_deinit,
    });
    try std.testing.expect(std.mem.indexOf(u8, writer.buffer.items, "text_files_present=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffer.items, "text_warm=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffer.items, "text_stale=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffer.items, "text_terms_bytes=0\n") != null);
}

test "store info read failure publishes no output and closes context" {
    TestOps.reset();
    TestOps.stale_error = error.InvalidRecord;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRecord,
        store_inspection_commands.runStoreInfo(
            &.{ "tinykg", "store-info", "db" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{
        .init,
        .stats,
        .store_bytes,
        .docs_size,
        .terms_size,
        .postings_size,
        .stale,
        .context_deinit,
    });
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "store info deinitializes manifest after writer failure" {
    TestOps.reset();
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.WriteFailed,
        store_inspection_commands.runStoreInfo(
            &.{ "tinykg", "store-info", "db" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{
        .init,
        .stats,
        .store_bytes,
        .docs_size,
        .terms_size,
        .postings_size,
        .stale,
        .manifest,
        .manifest_deinit,
        .context_deinit,
    });
}
