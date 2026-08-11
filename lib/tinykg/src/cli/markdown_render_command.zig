const std = @import("std");

/// `render-md-doc` read-only command control plane.
///
/// Store locking, node identities, projection traversal, persisted records and
/// JSON/meta rendering stay behind `Ops.Context`. This owner keeps the command
/// grammar, one locked read context, full-versus-paged routing, output
/// publication and allocation cleanup together. Markdown import and orphan GC
/// intentionally remain separate protocols.
pub fn MarkdownRenderCommand(comptime Ops: type) type {
    return struct {
        pub const Format = enum {
            text,
            json,
        };

        pub const Arguments = struct {
            document_id: u64,
            render_root_id: u64,
            format: Format = .text,
            meta: bool = false,
            preview_lines: usize = 20,
            page_size_bytes: ?usize = null,
            cursor: usize = 0,
        };

        fn parseFormat(value: []const u8) !Format {
            if (std.mem.eql(u8, value, "text")) return .text;
            if (std.mem.eql(u8, value, "json")) return .json;
            return error.InvalidFormat;
        }

        pub fn parseArguments(rest: []const []const u8) !Arguments {
            if (rest.len == 0) return error.MissingArgument;
            const document_id = try Ops.parseNodeId(rest[0]);
            var render_root_id = document_id;
            var format: Format = .text;
            var meta = false;
            var preview_lines: usize = 20;
            var preview_lines_explicit = false;
            var page_size_bytes: ?usize = null;
            var cursor: usize = 0;
            var cursor_explicit = false;
            var pos: usize = 1;
            while (pos < rest.len) {
                const arg = rest[pos];
                if (std.mem.eql(u8, arg, "--section") or std.mem.eql(u8, arg, "--subtree")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    if (render_root_id != document_id) return error.TooManyArguments;
                    render_root_id = try Ops.parseNodeId(rest[pos + 1]);
                    pos += 2;
                } else if (std.mem.eql(u8, arg, "--format")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    format = try parseFormat(rest[pos + 1]);
                    pos += 2;
                } else if (std.mem.eql(u8, arg, "--meta")) {
                    meta = true;
                    pos += 1;
                } else if (std.mem.eql(u8, arg, "--preview-lines")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    if (preview_lines_explicit) return error.TooManyArguments;
                    preview_lines = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
                    if (preview_lines > 200) return error.InvalidLimit;
                    preview_lines_explicit = true;
                    pos += 2;
                } else if (std.mem.eql(u8, arg, "--page-size-bytes") or std.mem.eql(u8, arg, "--page-bytes")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    if (page_size_bytes != null) return error.TooManyArguments;
                    const parsed_page_size = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
                    if (parsed_page_size == 0 or parsed_page_size > 2_000_000) return error.InvalidLimit;
                    page_size_bytes = parsed_page_size;
                    pos += 2;
                } else if (std.mem.eql(u8, arg, "--cursor")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    if (cursor_explicit) return error.TooManyArguments;
                    cursor = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
                    cursor_explicit = true;
                    pos += 2;
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    return error.UnknownOption;
                } else {
                    return error.TooManyArguments;
                }
            }
            if (meta and format != .json) return error.Unsupported;
            if (format != .json and preview_lines_explicit) return error.Unsupported;
            if (format != .json and (page_size_bytes != null or cursor_explicit)) return error.Unsupported;
            if (cursor_explicit and page_size_bytes == null) return error.Unsupported;
            return .{
                .document_id = document_id,
                .render_root_id = render_root_id,
                .format = format,
                .meta = meta,
                .preview_lines = preview_lines,
                .page_size_bytes = page_size_bytes,
                .cursor = cursor,
            };
        }

        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed_db = try Ops.parseDbArguments(allocator, io, args);
            const parsed = try parseArguments(parsed_db.rest);
            var context = try Ops.Context.init(allocator, io, parsed_db.db_path);
            defer context.deinit();

            if (parsed.format == .json and parsed.page_size_bytes != null) {
                const output = try context.renderPageJson(parsed);
                defer allocator.free(output);
                try writer.writeAll(output);
                return;
            }

            const rendered = try context.renderFull(parsed.render_root_id);
            defer allocator.free(rendered);
            if (parsed.format == .json) {
                const output = try context.renderJson(parsed, rendered);
                defer allocator.free(output);
                try writer.writeAll(output);
            } else {
                try writer.writeAll(rendered);
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

    fn writeAll(self: *TestWriter, text: []const u8) !void {
        std.debug.assert(TestOps.context_live);
        TestOps.record(.write);
        try self.buffer.appendSlice(self.allocator, text);
    }
};

const FailingWriter = struct {
    fn writeAll(_: *FailingWriter, _: []const u8) error{OutputClosed}!void {
        std.debug.assert(TestOps.context_live);
        TestOps.record(.write);
        return error.OutputClosed;
    }
};

const TestOps = struct {
    const Step = enum {
        parse_db,
        context_init,
        render_full,
        render_json,
        render_page_json,
        write,
        context_deinit,
    };

    const ParsedDb = struct {
        db_path: []const u8,
        rest: []const []const u8,
    };

    var steps: [24]Step = undefined;
    var step_count: usize = 0;
    var context_live = false;
    var context_error: ?anyerror = null;
    var render_error: ?anyerror = null;
    var last_root_id: u64 = 0;
    var last_document_id: u64 = 0;
    var last_cursor: usize = 0;

    fn reset() void {
        step_count = 0;
        context_live = false;
        context_error = null;
        render_error = null;
        last_root_id = 0;
        last_document_id = 0;
        last_cursor = 0;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn expectSteps(expected: []const Step) !void {
        try std.testing.expectEqualSlices(Step, expected, steps[0..step_count]);
    }

    pub fn parseNodeId(value: []const u8) !u64 {
        return std.fmt.parseInt(u64, value, 10) catch return error.InvalidId;
    }

    pub fn parseDbArguments(
        _: std.mem.Allocator,
        _: std.Io,
        args: []const []const u8,
    ) !ParsedDb {
        record(.parse_db);
        if (args.len < 4) return error.MissingArgument;
        return .{ .db_path = args[2], .rest = args[3..] };
    }

    pub const Context = struct {
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, _: std.Io, db_path: []const u8) !Context {
            TestOps.record(.context_init);
            try std.testing.expectEqualStrings("memory.kg", db_path);
            if (TestOps.context_error) |err| return err;
            TestOps.context_live = true;
            return .{ .allocator = allocator };
        }

        pub fn deinit(_: *Context) void {
            std.debug.assert(TestOps.context_live);
            TestOps.record(.context_deinit);
            TestOps.context_live = false;
        }

        pub fn renderFull(self: *Context, root_id: u64) ![]u8 {
            std.debug.assert(TestOps.context_live);
            TestOps.record(.render_full);
            TestOps.last_root_id = root_id;
            if (TestOps.render_error) |err| return err;
            return self.allocator.dupe(u8, "# rendered\n");
        }

        pub fn renderJson(self: *Context, args: anytype, rendered: []const u8) ![]u8 {
            std.debug.assert(TestOps.context_live);
            TestOps.record(.render_json);
            TestOps.last_document_id = args.document_id;
            TestOps.last_root_id = args.render_root_id;
            try std.testing.expectEqualStrings("# rendered\n", rendered);
            if (TestOps.render_error) |err| return err;
            return self.allocator.dupe(u8, "{\"mode\":\"full\"}\n");
        }

        pub fn renderPageJson(self: *Context, args: anytype) ![]u8 {
            std.debug.assert(TestOps.context_live);
            TestOps.record(.render_page_json);
            TestOps.last_document_id = args.document_id;
            TestOps.last_root_id = args.render_root_id;
            TestOps.last_cursor = args.cursor;
            if (TestOps.render_error) |err| return err;
            return self.allocator.dupe(u8, "{\"mode\":\"page\"}\n");
        }
    };
};

const test_command = MarkdownRenderCommand(TestOps);

test "markdown render arguments preserve default document and text mode" {
    const parsed = try test_command.parseArguments(&.{"17"});
    try std.testing.expectEqual(@as(u64, 17), parsed.document_id);
    try std.testing.expectEqual(@as(u64, 17), parsed.render_root_id);
    try std.testing.expectEqual(test_command.Format.text, parsed.format);
    try std.testing.expect(!parsed.meta);
    try std.testing.expectEqual(@as(usize, 20), parsed.preview_lines);
    try std.testing.expectEqual(@as(?usize, null), parsed.page_size_bytes);
    try std.testing.expectEqual(@as(usize, 0), parsed.cursor);
}

test "markdown render arguments preserve json subtree preview and pagination aliases" {
    const parsed = try test_command.parseArguments(&.{
        "17",
        "--subtree",
        "23",
        "--format",
        "json",
        "--meta",
        "--preview-lines",
        "12",
        "--page-bytes",
        "65536",
        "--cursor",
        "4",
    });
    try std.testing.expectEqual(@as(u64, 17), parsed.document_id);
    try std.testing.expectEqual(@as(u64, 23), parsed.render_root_id);
    try std.testing.expectEqual(test_command.Format.json, parsed.format);
    try std.testing.expect(parsed.meta);
    try std.testing.expectEqual(@as(usize, 12), parsed.preview_lines);
    try std.testing.expectEqual(@as(?usize, 65536), parsed.page_size_bytes);
    try std.testing.expectEqual(@as(usize, 4), parsed.cursor);
}

test "markdown render arguments reject conflicting selectors and duplicate bounded values" {
    try std.testing.expectError(error.TooManyArguments, test_command.parseArguments(&.{ "17", "--section", "23", "--subtree", "29" }));
    try std.testing.expectError(error.TooManyArguments, test_command.parseArguments(&.{ "17", "--format", "json", "--preview-lines", "4", "--preview-lines", "5" }));
    try std.testing.expectError(error.TooManyArguments, test_command.parseArguments(&.{ "17", "--format", "json", "--page-bytes", "4", "--page-size-bytes", "5" }));
    try std.testing.expectError(error.TooManyArguments, test_command.parseArguments(&.{ "17", "--format", "json", "--page-bytes", "4", "--cursor", "1", "--cursor", "2" }));
    try std.testing.expectError(error.InvalidLimit, test_command.parseArguments(&.{ "17", "--format", "json", "--preview-lines", "201" }));
    try std.testing.expectError(error.InvalidLimit, test_command.parseArguments(&.{ "17", "--format", "json", "--page-bytes", "0" }));
}

test "markdown render arguments reject missing unknown extra and incompatible options before context" {
    try std.testing.expectError(error.MissingArgument, test_command.parseArguments(&.{}));
    try std.testing.expectError(error.MissingArgument, test_command.parseArguments(&.{ "17", "--section" }));
    try std.testing.expectError(error.UnknownOption, test_command.parseArguments(&.{ "17", "--unknown" }));
    try std.testing.expectError(error.TooManyArguments, test_command.parseArguments(&.{ "17", "18" }));
    try std.testing.expectError(error.InvalidFormat, test_command.parseArguments(&.{ "17", "--format", "yaml" }));
    try std.testing.expectError(error.Unsupported, test_command.parseArguments(&.{ "17", "--meta" }));
    try std.testing.expectError(error.Unsupported, test_command.parseArguments(&.{ "17", "--preview-lines", "2" }));
    try std.testing.expectError(error.Unsupported, test_command.parseArguments(&.{ "17", "--format", "json", "--cursor", "2" }));
    try std.testing.expectError(error.Unsupported, test_command.parseArguments(&.{ "17", "--page-size-bytes", "4" }));
}

test "markdown render command opens one context after parsing and publishes text" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try test_command.run(
        &.{ "tinykg", "render-md-doc", "memory.kg", "17" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .parse_db, .context_init, .render_full, .write, .context_deinit });
    try std.testing.expectEqual(@as(u64, 17), TestOps.last_root_id);
    try std.testing.expectEqualStrings("# rendered\n", writer.buffer.items);
    try std.testing.expect(!TestOps.context_live);
}

test "markdown render command routes full json through rendered metadata" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try test_command.run(
        &.{ "tinykg", "render-md-doc", "memory.kg", "17", "--section", "23", "--format", "json", "--meta" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .parse_db, .context_init, .render_full, .render_json, .write, .context_deinit });
    try std.testing.expectEqual(@as(u64, 17), TestOps.last_document_id);
    try std.testing.expectEqual(@as(u64, 23), TestOps.last_root_id);
    try std.testing.expectEqualStrings("{\"mode\":\"full\"}\n", writer.buffer.items);
}

test "markdown render command routes paged json without full rendering" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try test_command.run(
        &.{ "tinykg", "render-md-doc", "memory.kg", "17", "--format", "json", "--page-size-bytes", "1024", "--cursor", "3" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .parse_db, .context_init, .render_page_json, .write, .context_deinit });
    try std.testing.expectEqual(@as(usize, 3), TestOps.last_cursor);
    try std.testing.expectEqualStrings("{\"mode\":\"page\"}\n", writer.buffer.items);
}

test "markdown render command propagates context creation failure without cleanup" {
    TestOps.reset();
    TestOps.context_error = error.LockUnavailable;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try std.testing.expectError(
        error.LockUnavailable,
        test_command.run(
            &.{ "tinykg", "render-md-doc", "memory.kg", "17" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse_db, .context_init });
    try std.testing.expect(!TestOps.context_live);
}

test "markdown render command closes context after render failure" {
    TestOps.reset();
    TestOps.render_error = error.InvalidProjection;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try std.testing.expectError(
        error.InvalidProjection,
        test_command.run(
            &.{ "tinykg", "render-md-doc", "memory.kg", "17", "--format", "json", "--page-bytes", "1024" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse_db, .context_init, .render_page_json, .context_deinit });
    try std.testing.expect(!TestOps.context_live);
}

test "markdown render command closes context after writer failure" {
    TestOps.reset();
    var writer = FailingWriter{};
    try std.testing.expectError(
        error.OutputClosed,
        test_command.run(
            &.{ "tinykg", "render-md-doc", "memory.kg", "17", "--format", "json" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse_db, .context_init, .render_full, .render_json, .write, .context_deinit });
    try std.testing.expect(!TestOps.context_live);
}
