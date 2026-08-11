const std = @import("std");

/// `import-md-doc` and `import-md-ast` command control plane.
///
/// Canonical paths, locks, bootstrap recovery, Store publication, Markdown
/// projection, mdast decoding and persisted representations remain behind
/// `Ops`. This owner keeps the two related input grammars, durability policy,
/// timer boundary, one transactional import call and stable receipts together.
/// Read-only rendering and destructive orphan collection are intentionally
/// separate command protocols.
pub fn MarkdownImportCommands(comptime Ops: type) type {
    return struct {
        pub const Durability = enum {
            safe,
            fast,
        };

        pub const DocumentArguments = struct {
            db_path: []const u8,
            file_path: []const u8,
            durability: Durability = .safe,
            source_label: ?[]const u8 = null,
        };

        pub const AstArguments = struct {
            db_path: []const u8,
            ast_path: []const u8,
            format: []const u8 = "mdast",
            source_id: []const u8 = "stdin",
            durability: Durability = .safe,
        };

        pub const Request = union(enum) {
            ast: AstArguments,
            document: DocumentArguments,
        };

        fn parseDurability(value: []const u8) !Durability {
            if (std.mem.eql(u8, value, "safe")) return .safe;
            if (std.mem.eql(u8, value, "fast")) return .fast;
            return error.InvalidRecord;
        }

        pub fn parseDocumentArguments(args: []const []const u8) !DocumentArguments {
            if (args.len < 4) return error.MissingArgument;
            var file_path: ?[]const u8 = null;
            var durability: Durability = .safe;
            var source_label: ?[]const u8 = null;
            var pos: usize = 3;
            while (pos < args.len) {
                const arg = args[pos];
                if (std.mem.eql(u8, arg, "--source-label")) {
                    if (pos + 1 >= args.len) return error.MissingArgument;
                    source_label = args[pos + 1];
                    pos += 2;
                } else if (std.mem.eql(u8, arg, "--durability")) {
                    if (pos + 1 >= args.len) return error.MissingArgument;
                    durability = try parseDurability(args[pos + 1]);
                    pos += 2;
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    return error.UnknownOption;
                } else {
                    if (file_path != null) return error.TooManyArguments;
                    file_path = arg;
                    pos += 1;
                }
            }
            return .{
                .db_path = args[2],
                .file_path = file_path orelse return error.MissingArgument,
                .durability = durability,
                .source_label = source_label,
            };
        }

        pub fn parseAstArguments(args: []const []const u8) !AstArguments {
            if (args.len < 4) return error.MissingArgument;
            var ast_path: ?[]const u8 = null;
            var source_id: ?[]const u8 = null;
            var format: []const u8 = "mdast";
            var durability: Durability = .safe;
            var pos: usize = 3;
            while (pos < args.len) {
                const arg = args[pos];
                if (std.mem.eql(u8, arg, "--source") or std.mem.eql(u8, arg, "--source-id")) {
                    if (pos + 1 >= args.len) return error.MissingArgument;
                    source_id = args[pos + 1];
                    pos += 2;
                } else if (std.mem.eql(u8, arg, "--format")) {
                    if (pos + 1 >= args.len) return error.MissingArgument;
                    format = args[pos + 1];
                    pos += 2;
                } else if (std.mem.eql(u8, arg, "--durability")) {
                    if (pos + 1 >= args.len) return error.MissingArgument;
                    durability = try parseDurability(args[pos + 1]);
                    pos += 2;
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    return error.UnknownOption;
                } else {
                    if (ast_path != null) return error.TooManyArguments;
                    ast_path = arg;
                    pos += 1;
                }
            }
            if (!std.mem.eql(u8, format, "mdast")) return error.InvalidRecord;
            const path = ast_path orelse return error.MissingArgument;
            return .{
                .db_path = args[2],
                .ast_path = path,
                .format = format,
                .source_id = source_id orelse if (std.mem.eql(u8, path, "-")) "stdin" else path,
                .durability = durability,
            };
        }

        pub fn runDocument(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try parseDocumentArguments(args);
            const import_start_ns = Ops.startTimer(io);
            const result = try Ops.execute(allocator, io, Request{ .document = parsed });
            const elapsed_ns = Ops.elapsedSince(io, import_start_ns);
            try writer.print(
                "import_md_doc db={s} file={s} document={} nodes_imported={} edges_imported={} projection_edges_deleted={} markdown_bytes={} marker_cleanup_pending={} elapsed_ns={}\n",
                .{
                    parsed.db_path,
                    parsed.file_path,
                    result.document_id,
                    result.nodes_imported,
                    result.edges_imported,
                    result.projection_edges_deleted,
                    result.markdown_bytes,
                    @intFromBool(result.marker_cleanup_pending),
                    elapsed_ns,
                },
            );
        }

        pub fn runAst(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try parseAstArguments(args);
            const import_start_ns = Ops.startTimer(io);
            const result = try Ops.execute(allocator, io, Request{ .ast = parsed });
            const elapsed_ns = Ops.elapsedSince(io, import_start_ns);
            try writer.print(
                "import_md_ast db={s} input={s} format={s} source={s} document={} nodes_imported={} edges_imported={} projection_edges_deleted={} ast_bytes={} text_chunks={} marker_cleanup_pending={} elapsed_ns={}\n",
                .{
                    parsed.db_path,
                    parsed.ast_path,
                    parsed.format,
                    parsed.source_id,
                    result.document_id,
                    result.nodes_imported,
                    result.edges_imported,
                    result.projection_edges_deleted,
                    result.markdown_bytes,
                    result.text_chunks,
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
        start_timer,
        execute_document,
        execute_ast,
        elapsed,
        write,
    };

    const Result = struct {
        document_id: u64 = 17,
        nodes_imported: usize = 3,
        edges_imported: usize = 4,
        projection_edges_deleted: usize = 2,
        markdown_bytes: u64 = 101,
        text_chunks: usize = 5,
        marker_cleanup_pending: bool = false,
    };

    var steps: [32]Step = undefined;
    var step_count: usize = 0;
    var execute_failure: ?anyerror = null;
    var last_db_path: []const u8 = "";
    var last_input_path: []const u8 = "";
    var last_source: ?[]const u8 = null;
    var last_durability: test_commands.Durability = .safe;

    fn reset() void {
        step_count = 0;
        execute_failure = null;
        last_db_path = "";
        last_input_path = "";
        last_source = null;
        last_durability = .safe;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn expectSteps(expected: []const Step) !void {
        try std.testing.expectEqualSlices(Step, expected, steps[0..step_count]);
    }

    pub fn startTimer(_: std.Io) u128 {
        record(.start_timer);
        return 41;
    }

    pub fn elapsedSince(_: std.Io, start_ns: u128) u128 {
        std.debug.assert(start_ns == 41);
        record(.elapsed);
        return 23;
    }

    pub fn execute(_: std.mem.Allocator, _: std.Io, request: anytype) !Result {
        switch (request) {
            .document => |parsed| {
                record(.execute_document);
                last_db_path = parsed.db_path;
                last_input_path = parsed.file_path;
                last_source = parsed.source_label;
                last_durability = parsed.durability;
            },
            .ast => |parsed| {
                record(.execute_ast);
                last_db_path = parsed.db_path;
                last_input_path = parsed.ast_path;
                last_source = parsed.source_id;
                last_durability = parsed.durability;
            },
        }
        if (execute_failure) |err| return err;
        return .{};
    }
};

const test_commands = MarkdownImportCommands(TestOps);

test "markdown document import arguments preserve source durability and positional file" {
    const parsed = try test_commands.parseDocumentArguments(&.{
        "tinykg",
        "import-md-doc",
        "memory.kg",
        "--source-label",
        "handbook",
        "doc.md",
        "--durability",
        "fast",
        "--source-label",
        "canonical-handbook",
    });
    try std.testing.expectEqualStrings("memory.kg", parsed.db_path);
    try std.testing.expectEqualStrings("doc.md", parsed.file_path);
    try std.testing.expectEqual(test_commands.Durability.fast, parsed.durability);
    try std.testing.expectEqualStrings("canonical-handbook", parsed.source_label.?);
}

test "markdown ast import arguments preserve aliases format source and stdin defaults" {
    const parsed = try test_commands.parseAstArguments(&.{
        "tinykg",
        "import-md-ast",
        "memory.kg",
        "doc.json",
        "--source-id",
        "draft",
        "--format",
        "mdast",
        "--durability",
        "fast",
        "--source",
        "canonical",
    });
    try std.testing.expectEqualStrings("doc.json", parsed.ast_path);
    try std.testing.expectEqualStrings("canonical", parsed.source_id);
    try std.testing.expectEqualStrings("mdast", parsed.format);
    try std.testing.expectEqual(test_commands.Durability.fast, parsed.durability);

    const stdin = try test_commands.parseAstArguments(&.{ "tinykg", "import-md-ast", "memory.kg", "-" });
    try std.testing.expectEqualStrings("stdin", stdin.source_id);
    const file_default = try test_commands.parseAstArguments(&.{ "tinykg", "import-md-ast", "memory.kg", "other.json" });
    try std.testing.expectEqualStrings("other.json", file_default.source_id);
}

test "markdown imports reject missing unknown and extra positional arguments" {
    try std.testing.expectError(error.MissingArgument, test_commands.parseDocumentArguments(&.{ "tinykg", "import-md-doc", "memory.kg" }));
    try std.testing.expectError(error.MissingArgument, test_commands.parseDocumentArguments(&.{ "tinykg", "import-md-doc", "memory.kg", "--source-label" }));
    try std.testing.expectError(error.UnknownOption, test_commands.parseDocumentArguments(&.{ "tinykg", "import-md-doc", "memory.kg", "doc.md", "--unknown" }));
    try std.testing.expectError(error.TooManyArguments, test_commands.parseDocumentArguments(&.{ "tinykg", "import-md-doc", "memory.kg", "first.md", "second.md" }));

    try std.testing.expectError(error.MissingArgument, test_commands.parseAstArguments(&.{ "tinykg", "import-md-ast", "memory.kg" }));
    try std.testing.expectError(error.MissingArgument, test_commands.parseAstArguments(&.{ "tinykg", "import-md-ast", "memory.kg", "doc.json", "--source" }));
    try std.testing.expectError(error.UnknownOption, test_commands.parseAstArguments(&.{ "tinykg", "import-md-ast", "memory.kg", "doc.json", "--unknown" }));
    try std.testing.expectError(error.TooManyArguments, test_commands.parseAstArguments(&.{ "tinykg", "import-md-ast", "memory.kg", "first.json", "second.json" }));
}

test "markdown imports reject unsupported format and durability before execution" {
    TestOps.reset();
    try std.testing.expectError(error.InvalidRecord, test_commands.parseDocumentArguments(&.{ "tinykg", "import-md-doc", "memory.kg", "doc.md", "--durability", "unsafe" }));
    try std.testing.expectError(error.InvalidRecord, test_commands.parseAstArguments(&.{ "tinykg", "import-md-ast", "memory.kg", "doc.json", "--format", "hast" }));
    try std.testing.expectError(error.InvalidRecord, test_commands.parseAstArguments(&.{ "tinykg", "import-md-ast", "memory.kg", "doc.json", "--durability", "unsafe" }));
    try TestOps.expectSteps(&.{});
}

test "markdown document import times one transaction and publishes stable receipt" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runDocument(
        &.{ "tinykg", "import-md-doc", "memory.kg", "doc.md", "--source-label", "handbook", "--durability", "fast" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("memory.kg", TestOps.last_db_path);
    try std.testing.expectEqualStrings("doc.md", TestOps.last_input_path);
    try std.testing.expectEqualStrings("handbook", TestOps.last_source.?);
    try std.testing.expectEqual(test_commands.Durability.fast, TestOps.last_durability);
    try std.testing.expectEqualStrings(
        "import_md_doc db=memory.kg file=doc.md document=17 nodes_imported=3 edges_imported=4 projection_edges_deleted=2 markdown_bytes=101 marker_cleanup_pending=0 elapsed_ns=23\n",
        writer.buffer.items,
    );
    try TestOps.expectSteps(&.{ .start_timer, .execute_document, .elapsed, .write });
}

test "markdown ast import times one transaction and publishes stable receipt" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runAst(
        &.{ "tinykg", "import-md-ast", "memory.kg", "-", "--source", "pipe", "--durability", "fast" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("-", TestOps.last_input_path);
    try std.testing.expectEqualStrings("pipe", TestOps.last_source.?);
    try std.testing.expectEqual(test_commands.Durability.fast, TestOps.last_durability);
    try std.testing.expectEqualStrings(
        "import_md_ast db=memory.kg input=- format=mdast source=pipe document=17 nodes_imported=3 edges_imported=4 projection_edges_deleted=2 ast_bytes=101 text_chunks=5 marker_cleanup_pending=0 elapsed_ns=23\n",
        writer.buffer.items,
    );
    try TestOps.expectSteps(&.{ .start_timer, .execute_ast, .elapsed, .write });
}

test "markdown import execution failures publish no receipt or elapsed sample" {
    TestOps.reset();
    TestOps.execute_failure = error.InvalidRecord;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRecord,
        test_commands.runDocument(
            &.{ "tinykg", "import-md-doc", "memory.kg", "doc.md" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
    try TestOps.expectSteps(&.{ .start_timer, .execute_document });
}

test "markdown import writer failures occur after transaction and elapsed capture" {
    TestOps.reset();
    var writer = FailingWriter{};
    try std.testing.expectError(
        error.OutputClosed,
        test_commands.runAst(
            &.{ "tinykg", "import-md-ast", "memory.kg", "doc.json" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .start_timer, .execute_ast, .elapsed, .write });
}
