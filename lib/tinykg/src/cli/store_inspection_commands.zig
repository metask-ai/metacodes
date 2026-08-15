const std = @import("std");

/// Store statistics and diagnostic snapshot control plane.
///
/// Concrete locks, Store types, filesystem probes, text-catalog admission,
/// and manifest ownership stay behind `Ops.Context`. This owner ensures that
/// Ordinary `store-info` reads fixed-size logical-content/footprint and index
/// metadata. The explicit `--refresh-size` path audits canonical current
/// content plus the filesystem behind `Ops.Context` and publishes output only
/// after its atomic metadata replacement succeeds.
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
            const parsed = try Ops.parseStoreInfoArgs(args, 2);
            var context = try Ops.Context.init(allocator, io, parsed.db_path);
            defer context.deinit();

            const stats = try context.indexStats();
            const size_snapshot = try context.sizeSnapshot(parsed.refresh_size);
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
                "db={s}\nnodes={}\nedges={}\nlogical_content_bytes={}\nlogical_node_text_bytes={}\nlogical_property_value_bytes={}\nlogical_edge_bytes={}\nlogical_property_count={}\nlogical_accounting_version={}\nphysical_bytes={}\nstore_dir_bytes={}\nstore_size_state={s}\nstore_regular_files={}\nstore_size_generation={}\nstore_size_refreshed_ns={}\n",
                .{
                    parsed.db_path,
                    stats.nodes,
                    stats.edges,
                    if (size_snapshot) |snapshot| snapshot.logical_content_bytes else 0,
                    if (size_snapshot) |snapshot| snapshot.logical_node_text_bytes else 0,
                    if (size_snapshot) |snapshot| snapshot.logical_property_value_bytes else 0,
                    if (size_snapshot) |snapshot| snapshot.logical_edge_bytes else 0,
                    if (size_snapshot) |snapshot| snapshot.property_count else 0,
                    if (size_snapshot) |snapshot| snapshot.logical_accounting_version else 0,
                    if (size_snapshot) |snapshot| snapshot.physical_bytes else 0,
                    if (size_snapshot) |snapshot| snapshot.physical_bytes else 0,
                    if (size_snapshot != null)
                        if (parsed.refresh_size) "refreshed" else "cached"
                    else
                        "unavailable",
                    if (size_snapshot) |snapshot| snapshot.regular_files else 0,
                    if (size_snapshot) |snapshot| snapshot.generation else 0,
                    if (size_snapshot) |snapshot| snapshot.refreshed_ns else 0,
                },
            );
            if (size_snapshot) |snapshot| {
                try printRatio(writer, "compression_ratio", snapshot.logical_content_bytes, snapshot.physical_bytes);
                try printRatio(writer, "storage_amplification", snapshot.physical_bytes, snapshot.logical_content_bytes);
            } else {
                try writer.print("compression_ratio=0.000000\nstorage_amplification=0.000000\n", .{});
            }
            try writer.print(
                "text_warm={}\ntext_files_present={}\ntext_current={}\ntext_stale={}\nstore_manifest={s}\nstorage_format_version={s}\nschema_version={s}\nenabled_profiles={s}\ntext_docs_exists={}\ntext_terms_exists={}\ntext_postings_exists={}\n",
                .{
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

        fn printRatio(writer: anytype, comptime key: []const u8, numerator: u64, denominator: u64) !void {
            if (denominator == 0) {
                try writer.print("{s}=0.000000\n", .{key});
                return;
            }
            const scale: u128 = 1_000_000;
            const scaled = (@as(u128, numerator) * scale) / denominator;
            try writer.print("{s}={d}.{d:0>6}\n", .{ key, scaled / scale, scaled % scale });
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
        index_stats,
        size_read,
        size_refresh,
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
    var size_snapshot: ?SizeSnapshot = .{
        .logical_content_bytes = 8000,
        .logical_node_text_bytes = 7000,
        .logical_property_value_bytes = 824,
        .logical_edge_bytes = 176,
        .physical_bytes = 4096,
        .regular_files = 23,
        .property_count = 17,
        .logical_accounting_version = 1,
        .generation = 4,
        .refreshed_ns = 99,
    };

    const SizeSnapshot = struct {
        logical_content_bytes: u64,
        logical_node_text_bytes: u64,
        logical_property_value_bytes: u64,
        logical_edge_bytes: u64,
        physical_bytes: u64,
        regular_files: u64,
        property_count: u64,
        logical_accounting_version: u16,
        generation: u64,
        refreshed_ns: u64,
    };

    const ParsedStoreInfoArgs = struct {
        db_path: []const u8,
        refresh_size: bool,
    };

    fn reset() void {
        step_count = 0;
        docs_bytes = 101;
        terms_bytes = 202;
        postings_bytes = 303;
        stale = false;
        stale_error = null;
        manifest_error = null;
        size_snapshot = .{
            .logical_content_bytes = 8000,
            .logical_node_text_bytes = 7000,
            .logical_property_value_bytes = 824,
            .logical_edge_bytes = 176,
            .physical_bytes = 4096,
            .regular_files = 23,
            .property_count = 17,
            .logical_accounting_version = 1,
            .generation = 4,
            .refreshed_ns = 99,
        };
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

    pub fn parseStoreInfoArgs(args: []const []const u8, index: usize) !ParsedStoreInfoArgs {
        var db_path: []const u8 = "default-db";
        var seen_db = false;
        var refresh_size = false;
        for (args[index..]) |arg| {
            if (std.mem.eql(u8, arg, "--refresh-size")) {
                if (refresh_size) return error.InvalidArgument;
                refresh_size = true;
            } else {
                if (seen_db or std.mem.startsWith(u8, arg, "--")) return error.TooManyArguments;
                db_path = arg;
                seen_db = true;
            }
        }
        return .{ .db_path = db_path, .refresh_size = refresh_size };
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

        pub fn indexStats(_: *Context) !struct { nodes: u64, edges: u64 } {
            TestOps.record(.index_stats);
            return .{ .nodes = 7, .edges = 11 };
        }

        pub fn sizeSnapshot(_: *Context, refresh: bool) !?SizeSnapshot {
            TestOps.record(if (refresh) .size_refresh else .size_read);
            return TestOps.size_snapshot;
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
        .index_stats,
        .size_read,
        .docs_size,
        .terms_size,
        .postings_size,
        .stale,
        .manifest,
        .manifest_deinit,
        .context_deinit,
    });
    try std.testing.expectEqualStrings(
        "db=db\nnodes=7\nedges=11\nlogical_content_bytes=8000\nlogical_node_text_bytes=7000\nlogical_property_value_bytes=824\nlogical_edge_bytes=176\nlogical_property_count=17\nlogical_accounting_version=1\nphysical_bytes=4096\nstore_dir_bytes=4096\nstore_size_state=cached\nstore_regular_files=23\nstore_size_generation=4\nstore_size_refreshed_ns=99\ncompression_ratio=1.953125\nstorage_amplification=0.512000\ntext_warm=1\ntext_files_present=1\ntext_current=1\ntext_stale=0\nstore_manifest=ready\nstorage_format_version=2\nschema_version=3\nenabled_profiles=agent-memory\ntext_docs_exists=1\ntext_terms_exists=1\ntext_postings_exists=1\ntext_docs_bytes=101\ntext_terms_bytes=202\ntext_postings_bytes=303\n",
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
        .index_stats,
        .size_read,
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

test "store info refreshes size through the same command" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try store_inspection_commands.runStoreInfo(
        &.{ "tinykg", "store-info", "--refresh-size", "db" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expect(std.mem.indexOf(u8, writer.buffer.items, "db=db\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffer.items, "store_size_state=refreshed\n") != null);
    try std.testing.expect(std.mem.indexOfScalar(TestOps.Step, TestOps.steps[0..TestOps.step_count], .size_refresh) != null);
    try std.testing.expect(std.mem.indexOfScalar(TestOps.Step, TestOps.steps[0..TestOps.step_count], .size_read) == null);
}

test "store info reports unavailable without inventing zero as measured" {
    TestOps.reset();
    TestOps.size_snapshot = null;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try store_inspection_commands.runStoreInfo(
        &.{ "tinykg", "store-info", "db" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expect(std.mem.indexOf(u8, writer.buffer.items, "store_dir_bytes=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffer.items, "store_size_state=unavailable\n") != null);
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
        .index_stats,
        .size_read,
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
        .index_stats,
        .size_read,
        .docs_size,
        .terms_size,
        .postings_size,
        .stale,
        .manifest,
        .manifest_deinit,
        .context_deinit,
    });
}
