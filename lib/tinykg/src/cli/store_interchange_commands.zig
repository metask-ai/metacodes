const std = @import("std");

const Format = enum {
    jsonl,
    markdown,
};

const ImportArguments = struct {
    db_path: []const u8,
    dir_path: []const u8,
    warm_text: bool = false,
};

fn parseImportArguments(args: []const []const u8) !ImportArguments {
    if (args.len < 4) return error.MissingArgument;
    var parsed = ImportArguments{
        .db_path = args[2],
        .dir_path = args[3],
    };
    var pos: usize = 4;
    while (pos < args.len) {
        const option = args[pos];
        if (std.mem.eql(u8, option, "--warm-text")) {
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

/// Portable whole-Store interchange control for JSONL and Markdown.
///
/// The CLI façade retains format codecs, Store and lock representations,
/// transaction markers, staging, durability, recovery and persisted bytes.
/// This owner keeps the four public command protocols aligned without
/// absorbing document-oriented Markdown import/render commands.
pub fn StoreInterchangeCommands(comptime Ops: type) type {
    return struct {
        pub fn runImportJsonl(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            try runImport(.jsonl, args, writer, allocator, io);
        }

        pub fn runExportJsonl(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            try runExport(.jsonl, args, writer, allocator, io);
        }

        pub fn runImportMarkdown(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            try runImport(.markdown, args, writer, allocator, io);
        }

        pub fn runExportMarkdown(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            try runExport(.markdown, args, writer, allocator, io);
        }

        fn runImport(
            comptime format: Format,
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try parseImportArguments(args);
            const start_ns = Ops.startTimer(io);
            const result = switch (format) {
                .jsonl => try Ops.importJsonl(allocator, io, parsed.db_path, parsed.dir_path, parsed.warm_text),
                .markdown => try Ops.importMarkdown(allocator, io, parsed.db_path, parsed.dir_path, parsed.warm_text),
            };
            const elapsed_ns = Ops.elapsedSince(io, start_ns);
            switch (format) {
                .jsonl => try writer.print(
                    "import_jsonl db={s} dir={s} nodes_loaded={} nodes_imported={} edges_loaded={} edges_imported={} deferred_based_on_loaded={} deferred_based_on_imported={} text_warmed={} jsonl_bytes={} marker_cleanup_pending={} elapsed_ns={}\n",
                    .{
                        parsed.db_path,
                        parsed.dir_path,
                        result.nodes_loaded,
                        result.nodes_imported,
                        result.edges_loaded,
                        result.edges_imported,
                        result.deferred_based_on_loaded,
                        result.deferred_based_on_imported,
                        @intFromBool(result.text_warmed),
                        result.source_bytes,
                        @intFromBool(result.marker_cleanup_pending),
                        elapsed_ns,
                    },
                ),
                .markdown => try writer.print(
                    "import_markdown db={s} dir={s} nodes_loaded={} nodes_imported={} edges_loaded={} edges_imported={} deferred_based_on_loaded={} deferred_based_on_imported={} text_warmed={} markdown_bytes={} marker_cleanup_pending={} elapsed_ns={}\n",
                    .{
                        parsed.db_path,
                        parsed.dir_path,
                        result.nodes_loaded,
                        result.nodes_imported,
                        result.edges_loaded,
                        result.edges_imported,
                        result.deferred_based_on_loaded,
                        result.deferred_based_on_imported,
                        @intFromBool(result.text_warmed),
                        result.source_bytes,
                        @intFromBool(result.marker_cleanup_pending),
                        elapsed_ns,
                    },
                ),
            }
        }

        fn runExport(
            comptime format: Format,
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parseExportArguments(allocator, io, args);
            var source_exclusion = try Ops.ExportSourceExclusion.init(allocator, io, parsed.db_path);
            defer source_exclusion.deinit();

            const start_ns = Ops.startTimer(io);
            var export_context = try Ops.ExportContext.init(allocator, io, parsed.db_path);
            defer export_context.deinit();
            const result = switch (format) {
                .jsonl => try export_context.exportJsonl(parsed.dir_path),
                .markdown => try export_context.exportMarkdown(parsed.dir_path),
            };
            const elapsed_ns = Ops.elapsedSince(io, start_ns);
            switch (format) {
                .jsonl => try writer.print(
                    "export_jsonl db={s} dir={s} nodes_exported={} edges_exported={} deferred_based_on_exported={} jsonl_bytes={} cleanup_pending={} elapsed_ns={}\n",
                    .{
                        parsed.db_path,
                        parsed.dir_path,
                        result.nodes_exported,
                        result.edges_exported,
                        result.deferred_based_on_exported,
                        result.output_bytes,
                        @intFromBool(result.cleanup_pending),
                        elapsed_ns,
                    },
                ),
                .markdown => try writer.print(
                    "export_markdown db={s} dir={s} nodes_exported={} edges_exported={} deferred_based_on_exported={} markdown_bytes={} cleanup_pending={} elapsed_ns={}\n",
                    .{
                        parsed.db_path,
                        parsed.dir_path,
                        result.nodes_exported,
                        result.edges_exported,
                        result.deferred_based_on_exported,
                        result.output_bytes,
                        @intFromBool(result.cleanup_pending),
                        elapsed_ns,
                    },
                ),
            }
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
        if (TestOps.expect_export) {
            std.debug.assert(TestOps.exclusion_live);
            std.debug.assert(TestOps.context_live);
        }
        TestOps.record(.write);
        const rendered = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(rendered);
        try self.buffer.appendSlice(self.allocator, rendered);
    }
};

const FailingWriter = struct {
    fn print(_: *FailingWriter, comptime _: []const u8, _: anytype) error{OutputClosed}!void {
        if (TestOps.expect_export) {
            std.debug.assert(TestOps.exclusion_live);
            std.debug.assert(TestOps.context_live);
        }
        TestOps.record(.write);
        return error.OutputClosed;
    }
};

const TestOps = struct {
    const Step = enum {
        parse_export,
        exclusion_init,
        start_timer,
        context_init,
        import_jsonl,
        import_markdown,
        export_jsonl,
        export_markdown,
        elapsed,
        write,
        context_deinit,
        exclusion_deinit,
    };

    const ImportResult = struct {
        nodes_loaded: usize = 13,
        nodes_imported: usize = 11,
        edges_loaded: usize = 17,
        edges_imported: usize = 15,
        deferred_based_on_loaded: usize = 5,
        deferred_based_on_imported: usize = 3,
        source_bytes: u64 = 4097,
        text_warmed: bool = true,
        marker_cleanup_pending: bool = true,
    };

    const ExportResult = struct {
        nodes_exported: usize = 11,
        edges_exported: usize = 15,
        deferred_based_on_exported: usize = 3,
        output_bytes: u64 = 4097,
        cleanup_pending: bool = true,
    };

    var steps: [24]Step = undefined;
    var step_count: usize = 0;
    var expect_export: bool = false;
    var exclusion_live: bool = false;
    var context_live: bool = false;
    var parse_error: ?anyerror = null;
    var exclusion_error: ?anyerror = null;
    var context_error: ?anyerror = null;
    var import_error: ?anyerror = null;
    var export_error: ?anyerror = null;
    var elapsed_start_ns: u128 = 0;

    fn reset() void {
        step_count = 0;
        expect_export = false;
        exclusion_live = false;
        context_live = false;
        parse_error = null;
        exclusion_error = null;
        context_error = null;
        import_error = null;
        export_error = null;
        elapsed_start_ns = 0;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn expectSteps(expected: []const Step) !void {
        try std.testing.expectEqualSlices(Step, expected, steps[0..step_count]);
    }

    pub fn parseExportArguments(
        _: std.mem.Allocator,
        _: std.Io,
        args: []const []const u8,
    ) !struct { db_path: []const u8, dir_path: []const u8 } {
        record(.parse_export);
        if (parse_error) |err| return err;
        try std.testing.expect(args.len >= 2);
        return .{ .db_path = "source.kg", .dir_path = "portable-dir" };
    }

    pub const ExportSourceExclusion = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, db_path: []const u8) !ExportSourceExclusion {
            try std.testing.expectEqualStrings("source.kg", db_path);
            TestOps.record(.exclusion_init);
            if (TestOps.exclusion_error) |err| return err;
            TestOps.exclusion_live = true;
            return .{};
        }

        pub fn deinit(_: *ExportSourceExclusion) void {
            std.debug.assert(TestOps.exclusion_live);
            std.debug.assert(!TestOps.context_live);
            TestOps.record(.exclusion_deinit);
            TestOps.exclusion_live = false;
        }
    };

    pub fn startTimer(_: std.Io) u128 {
        if (expect_export) std.debug.assert(exclusion_live);
        record(.start_timer);
        return 103;
    }

    pub const ExportContext = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, db_path: []const u8) !ExportContext {
            try std.testing.expectEqualStrings("source.kg", db_path);
            std.debug.assert(TestOps.exclusion_live);
            TestOps.record(.context_init);
            if (TestOps.context_error) |err| return err;
            TestOps.context_live = true;
            return .{};
        }

        pub fn deinit(_: *ExportContext) void {
            std.debug.assert(TestOps.context_live);
            TestOps.record(.context_deinit);
            TestOps.context_live = false;
        }

        pub fn exportJsonl(_: *ExportContext, dir_path: []const u8) !ExportResult {
            try std.testing.expectEqualStrings("portable-dir", dir_path);
            std.debug.assert(TestOps.exclusion_live);
            std.debug.assert(TestOps.context_live);
            TestOps.record(.export_jsonl);
            if (TestOps.export_error) |err| return err;
            return .{};
        }

        pub fn exportMarkdown(_: *ExportContext, dir_path: []const u8) !ExportResult {
            try std.testing.expectEqualStrings("portable-dir", dir_path);
            std.debug.assert(TestOps.exclusion_live);
            std.debug.assert(TestOps.context_live);
            TestOps.record(.export_markdown);
            if (TestOps.export_error) |err| return err;
            return .{};
        }
    };

    pub fn importJsonl(
        _: std.mem.Allocator,
        _: std.Io,
        db_path: []const u8,
        dir_path: []const u8,
        warm_text: bool,
    ) !ImportResult {
        try std.testing.expectEqualStrings("target.kg", db_path);
        try std.testing.expectEqualStrings("portable-dir", dir_path);
        try std.testing.expect(warm_text);
        record(.import_jsonl);
        if (import_error) |err| return err;
        return .{};
    }

    pub fn importMarkdown(
        _: std.mem.Allocator,
        _: std.Io,
        db_path: []const u8,
        dir_path: []const u8,
        warm_text: bool,
    ) !ImportResult {
        try std.testing.expectEqualStrings("target.kg", db_path);
        try std.testing.expectEqualStrings("portable-dir", dir_path);
        try std.testing.expect(warm_text);
        record(.import_markdown);
        if (import_error) |err| return err;
        return .{};
    }

    pub fn elapsedSince(_: std.Io, start_ns: u128) u128 {
        if (expect_export) {
            std.debug.assert(exclusion_live);
            std.debug.assert(context_live);
        }
        record(.elapsed);
        elapsed_start_ns = start_ns;
        return 31;
    }
};

const store_interchange_commands = StoreInterchangeCommands(TestOps);

test "store interchange import arguments preserve defaults and warm text" {
    const defaults = try parseImportArguments(&.{ "tinykg", "import-jsonl", "target.kg", "portable-dir" });
    try std.testing.expectEqualStrings("target.kg", defaults.db_path);
    try std.testing.expectEqualStrings("portable-dir", defaults.dir_path);
    try std.testing.expect(!defaults.warm_text);

    const warmed = try parseImportArguments(&.{
        "tinykg",
        "import-markdown",
        "target.kg",
        "portable-dir",
        "--warm-text",
        "--warm-text",
    });
    try std.testing.expect(warmed.warm_text);
}

test "store interchange import arguments reject missing unknown and extra values" {
    try std.testing.expectError(error.MissingArgument, parseImportArguments(&.{ "tinykg", "import-jsonl", "target.kg" }));
    try std.testing.expectError(error.UnknownOption, parseImportArguments(&.{ "tinykg", "import-jsonl", "target.kg", "portable-dir", "--future" }));
    try std.testing.expectError(error.TooManyArguments, parseImportArguments(&.{ "tinykg", "import-jsonl", "target.kg", "portable-dir", "extra" }));
}

test "store interchange import commands preserve format result output" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try store_interchange_commands.runImportJsonl(&.{
        "tinykg",
        "import-jsonl",
        "target.kg",
        "portable-dir",
        "--warm-text",
    }, &writer, std.testing.allocator, std.testing.io);
    try TestOps.expectSteps(&.{ .start_timer, .import_jsonl, .elapsed, .write });
    try std.testing.expectEqual(@as(u128, 103), TestOps.elapsed_start_ns);
    try std.testing.expectEqualStrings(
        "import_jsonl db=target.kg dir=portable-dir nodes_loaded=13 nodes_imported=11 edges_loaded=17 edges_imported=15 deferred_based_on_loaded=5 deferred_based_on_imported=3 text_warmed=1 jsonl_bytes=4097 marker_cleanup_pending=1 elapsed_ns=31\n",
        writer.buffer.items,
    );

    writer.buffer.clearRetainingCapacity();
    TestOps.reset();
    try store_interchange_commands.runImportMarkdown(&.{
        "tinykg",
        "import-markdown",
        "target.kg",
        "portable-dir",
        "--warm-text",
    }, &writer, std.testing.allocator, std.testing.io);
    try TestOps.expectSteps(&.{ .start_timer, .import_markdown, .elapsed, .write });
    try std.testing.expectEqualStrings(
        "import_markdown db=target.kg dir=portable-dir nodes_loaded=13 nodes_imported=11 edges_loaded=17 edges_imported=15 deferred_based_on_loaded=5 deferred_based_on_imported=3 text_warmed=1 markdown_bytes=4097 marker_cleanup_pending=1 elapsed_ns=31\n",
        writer.buffer.items,
    );
}

test "store interchange import failure stops before elapsed and output" {
    TestOps.reset();
    TestOps.import_error = error.ImportFailed;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.ImportFailed,
        store_interchange_commands.runImportJsonl(&.{ "tinykg", "import-jsonl", "target.kg", "portable-dir", "--warm-text" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{ .start_timer, .import_jsonl });
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "store interchange import writer failure happens after elapsed" {
    TestOps.reset();
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        store_interchange_commands.runImportMarkdown(&.{ "tinykg", "import-markdown", "target.kg", "portable-dir", "--warm-text" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{ .start_timer, .import_markdown, .elapsed, .write });
    try std.testing.expectEqual(@as(u128, 103), TestOps.elapsed_start_ns);
}

test "store interchange export commands preserve parse lock timer context execute and output order" {
    TestOps.reset();
    TestOps.expect_export = true;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try store_interchange_commands.runExportJsonl(&.{ "tinykg", "export-jsonl" }, &writer, std.testing.allocator, std.testing.io);
    try TestOps.expectSteps(&.{
        .parse_export,
        .exclusion_init,
        .start_timer,
        .context_init,
        .export_jsonl,
        .elapsed,
        .write,
        .context_deinit,
        .exclusion_deinit,
    });
    try std.testing.expectEqualStrings(
        "export_jsonl db=source.kg dir=portable-dir nodes_exported=11 edges_exported=15 deferred_based_on_exported=3 jsonl_bytes=4097 cleanup_pending=1 elapsed_ns=31\n",
        writer.buffer.items,
    );

    writer.buffer.clearRetainingCapacity();
    TestOps.reset();
    TestOps.expect_export = true;
    try store_interchange_commands.runExportMarkdown(&.{ "tinykg", "export-markdown" }, &writer, std.testing.allocator, std.testing.io);
    try TestOps.expectSteps(&.{
        .parse_export,
        .exclusion_init,
        .start_timer,
        .context_init,
        .export_markdown,
        .elapsed,
        .write,
        .context_deinit,
        .exclusion_deinit,
    });
    try std.testing.expectEqualStrings(
        "export_markdown db=source.kg dir=portable-dir nodes_exported=11 edges_exported=15 deferred_based_on_exported=3 markdown_bytes=4097 cleanup_pending=1 elapsed_ns=31\n",
        writer.buffer.items,
    );
}

test "store interchange export exclusion failure stops before timer" {
    TestOps.reset();
    TestOps.expect_export = true;
    TestOps.parse_error = error.InvalidExportArguments;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidExportArguments,
        store_interchange_commands.runExportJsonl(&.{ "tinykg", "export-jsonl" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{.parse_export});

    TestOps.reset();
    TestOps.expect_export = true;
    TestOps.exclusion_error = error.SourceLocked;
    try std.testing.expectError(
        error.SourceLocked,
        store_interchange_commands.runExportJsonl(&.{ "tinykg", "export-jsonl" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{ .parse_export, .exclusion_init });
}

test "store interchange export context failure releases source exclusion" {
    TestOps.reset();
    TestOps.expect_export = true;
    TestOps.context_error = error.StoreOpenFailed;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.StoreOpenFailed,
        store_interchange_commands.runExportJsonl(&.{ "tinykg", "export-jsonl" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{
        .parse_export,
        .exclusion_init,
        .start_timer,
        .context_init,
        .exclusion_deinit,
    });
}

test "store interchange export execution failure releases context and exclusion" {
    TestOps.reset();
    TestOps.expect_export = true;
    TestOps.export_error = error.ExportFailed;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.ExportFailed,
        store_interchange_commands.runExportMarkdown(&.{ "tinykg", "export-markdown" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{
        .parse_export,
        .exclusion_init,
        .start_timer,
        .context_init,
        .export_markdown,
        .context_deinit,
        .exclusion_deinit,
    });
}

test "store interchange export writer failure releases in reverse order" {
    TestOps.reset();
    TestOps.expect_export = true;
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        store_interchange_commands.runExportJsonl(&.{ "tinykg", "export-jsonl" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{
        .parse_export,
        .exclusion_init,
        .start_timer,
        .context_init,
        .export_jsonl,
        .elapsed,
        .write,
        .context_deinit,
        .exclusion_deinit,
    });
    try std.testing.expectEqual(@as(u128, 103), TestOps.elapsed_start_ns);
}
