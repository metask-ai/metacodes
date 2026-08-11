const std = @import("std");

/// `agent-write` command control plane.
///
/// Store locking, schema loading, endpoint validation, fact-edge mutation,
/// JSON materialization, and Markdown projection data stay behind `Ops`. This
/// owner keeps the historical first-token JSON mode, validates single-write
/// text metadata before context acquisition, owns one context lifetime, and
/// publishes the stable receipt only after the write succeeds.
pub fn AgentWriteCommand(comptime Ops: type) type {
    return struct {
        pub const SingleArguments = struct {
            db_path: []const u8,
            src_node_id: []const u8,
            rel_label: []const u8,
            dst_node_id: []const u8,
            document_node_id: ?[]const u8 = null,
            section_node_id: ?[]const u8 = null,
            agent_inbox: bool = false,
            text: []const u8,
            name: ?[]const u8 = null,
            summary: ?[]const u8 = null,
            retrieval_hints: ?[]const u8 = null,
            render_rel_label: []const u8 = "md:paragraph",
            schema_path: ?[]const u8 = null,
        };

        pub const JsonArguments = struct {
            db_path: []const u8,
            json_path: []const u8,
            schema_path: ?[]const u8 = null,
        };

        pub const Arguments = union(enum) {
            single: SingleArguments,
            json: JsonArguments,
        };

        const SingleValueOption = enum {
            src,
            rel,
            dst,
            document,
            section,
            text,
            name,
            summary,
            retrieval_hints,
            render_rel,
            schema,
        };

        const JsonValueOption = enum {
            json,
            schema,
        };

        fn usesJson(rest: []const []const u8) bool {
            return rest.len >= 2 and std.mem.eql(u8, rest[0], "--json");
        }

        fn parseSingle(rest: []const []const u8, db_path: []const u8) !SingleArguments {
            var src_node_id: ?[]const u8 = null;
            var rel_label: ?[]const u8 = null;
            var dst_node_id: ?[]const u8 = null;
            var document_node_id: ?[]const u8 = null;
            var section_node_id: ?[]const u8 = null;
            var agent_inbox = false;
            var text: ?[]const u8 = null;
            var name: ?[]const u8 = null;
            var summary: ?[]const u8 = null;
            var retrieval_hints: ?[]const u8 = null;
            var render_rel_label: []const u8 = "md:paragraph";
            var schema_path: ?[]const u8 = null;

            var pos: usize = 0;
            while (pos < rest.len) {
                const option = rest[pos];
                if (std.mem.eql(u8, option, "--agent-inbox")) {
                    agent_inbox = true;
                    pos += 1;
                    continue;
                }
                const value_option: SingleValueOption = if (std.mem.eql(u8, option, "--src"))
                    .src
                else if (std.mem.eql(u8, option, "--rel"))
                    .rel
                else if (std.mem.eql(u8, option, "--dst"))
                    .dst
                else if (std.mem.eql(u8, option, "--document"))
                    .document
                else if (std.mem.eql(u8, option, "--section"))
                    .section
                else if (std.mem.eql(u8, option, "--text"))
                    .text
                else if (std.mem.eql(u8, option, "--name"))
                    .name
                else if (std.mem.eql(u8, option, "--summary"))
                    .summary
                else if (std.mem.eql(u8, option, "--retrieval-hints") or
                    std.mem.eql(u8, option, "--retrieval-hint"))
                    .retrieval_hints
                else if (std.mem.eql(u8, option, "--render-rel"))
                    .render_rel
                else if (std.mem.eql(u8, option, "--schema"))
                    .schema
                else if (std.mem.startsWith(u8, option, "--"))
                    return error.UnknownOption
                else
                    return error.TooManyArguments;
                if (pos + 1 >= rest.len) return error.MissingArgument;
                const value = rest[pos + 1];
                switch (value_option) {
                    .src => src_node_id = value,
                    .rel => rel_label = value,
                    .dst => dst_node_id = value,
                    .document => document_node_id = value,
                    .section => section_node_id = value,
                    .text => text = value,
                    .name => name = value,
                    .summary => summary = value,
                    .retrieval_hints => retrieval_hints = value,
                    .render_rel => render_rel_label = value,
                    .schema => schema_path = value,
                }
                pos += 2;
            }

            const attach_target_count: usize =
                @as(usize, @intFromBool(document_node_id != null)) +
                @as(usize, @intFromBool(section_node_id != null)) +
                @as(usize, @intFromBool(agent_inbox));
            if (attach_target_count > 1) return error.MissingArgument;
            if (text) |value| try Ops.validateNodeText(value);
            try Ops.validateNodeMetadata(name, summary, retrieval_hints);
            return .{
                .db_path = db_path,
                .src_node_id = src_node_id orelse return error.MissingArgument,
                .rel_label = rel_label orelse return error.MissingArgument,
                .dst_node_id = dst_node_id orelse return error.MissingArgument,
                .document_node_id = document_node_id,
                .section_node_id = section_node_id,
                .agent_inbox = agent_inbox or attach_target_count == 0,
                .text = text orelse return error.MissingArgument,
                .name = name,
                .summary = summary,
                .retrieval_hints = retrieval_hints,
                .render_rel_label = render_rel_label,
                .schema_path = schema_path,
            };
        }

        fn parseJson(rest: []const []const u8, db_path: []const u8) !JsonArguments {
            var json_path: ?[]const u8 = null;
            var schema_path: ?[]const u8 = null;
            var pos: usize = 0;
            while (pos < rest.len) {
                const option = rest[pos];
                const value_option: JsonValueOption = if (std.mem.eql(u8, option, "--json"))
                    .json
                else if (std.mem.eql(u8, option, "--schema"))
                    .schema
                else if (std.mem.startsWith(u8, option, "--"))
                    return error.UnknownOption
                else
                    return error.TooManyArguments;
                if (pos + 1 >= rest.len) return error.MissingArgument;
                const value = rest[pos + 1];
                switch (value_option) {
                    .json => json_path = value,
                    .schema => schema_path = value,
                }
                pos += 2;
            }
            return .{
                .db_path = db_path,
                .json_path = json_path orelse return error.MissingArgument,
                .schema_path = schema_path,
            };
        }

        pub fn parseArguments(
            allocator: std.mem.Allocator,
            io: std.Io,
            args: []const []const u8,
        ) !Arguments {
            const parsed = try Ops.parseDbArguments(allocator, io, args);
            if (usesJson(parsed.rest)) {
                return .{ .json = try parseJson(parsed.rest, parsed.db_path) };
            }
            return .{ .single = try parseSingle(parsed.rest, parsed.db_path) };
        }

        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try parseArguments(allocator, io, args);
            switch (parsed) {
                .single => |single| {
                    const prepared = try Ops.prepareSingle(single);
                    var context = try Ops.Context.init(
                        allocator,
                        io,
                        single.db_path,
                        single.schema_path,
                    );
                    defer context.deinit();
                    const result = try context.writeSingle(single, prepared);
                    try writer.print(
                        "agent_write src={} rel={} dst={} fact_edge={} fact_created={} projection_root={} projection_content={} projection_edge={} projection_nodes_imported={} projection_edge_created={} content_node_properties={} projection_links={} agent_inbox_created={}\n",
                        .{
                            result.src,
                            result.rel,
                            result.dst,
                            result.fact_edge,
                            @intFromBool(result.fact_created),
                            result.projection_root,
                            result.projection_content,
                            result.projection_edge,
                            result.projection_nodes_imported,
                            @intFromBool(result.projection_edge_created),
                            result.content_node_properties,
                            result.projection_links,
                            @intFromBool(result.agent_inbox_created),
                        },
                    );
                },
                .json => |json| {
                    var context = try Ops.Context.init(
                        allocator,
                        io,
                        json.db_path,
                        json.schema_path,
                    );
                    defer context.deinit();
                    const result = try context.writeJson(json);
                    try writer.print(
                        "agent_write_json items={} fact_created={} projection_nodes_imported={} projection_edge_created={} content_node_properties={} projection_links={} fact_properties={} projection_properties={} agent_inbox_created={}\n",
                        .{
                            result.items,
                            result.fact_created,
                            result.projection_nodes_imported,
                            result.projection_edge_created,
                            result.content_node_properties,
                            result.projection_links,
                            result.fact_properties,
                            result.projection_properties,
                            result.agent_inbox_created,
                        },
                    );
                },
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
        parse_db,
        validate_text,
        validate_metadata,
        prepare_single,
        context_init,
        write_single,
        write_json,
        write,
        context_deinit,
    };

    const PreparedSingle = struct {
        src: u64,
        dst: u64,
        render_rel: u16,
    };

    const SingleResult = struct {
        src: u64 = 1,
        rel: u16 = 10,
        dst: u64 = 2,
        fact_edge: u64 = 3,
        fact_created: bool = true,
        projection_root: u64 = 4,
        projection_content: u64 = 5,
        projection_edge: u64 = 6,
        projection_nodes_imported: usize = 7,
        projection_edge_created: bool = true,
        content_node_properties: usize = 2,
        projection_links: usize = 2,
        agent_inbox_created: bool = true,
    };

    const JsonResult = struct {
        items: usize = 8,
        fact_created: usize = 7,
        projection_nodes_imported: usize = 6,
        projection_edge_created: usize = 5,
        content_node_properties: usize = 4,
        projection_links: usize = 3,
        fact_properties: usize = 2,
        projection_properties: usize = 1,
        agent_inbox_created: usize = 9,
    };

    var steps: [32]Step = undefined;
    var step_count: usize = 0;
    var context_error: ?anyerror = null;
    var execution_error: ?anyerror = null;
    var expected_schema_path: ?[]const u8 = null;

    fn reset() void {
        step_count = 0;
        context_error = null;
        execution_error = null;
        expected_schema_path = null;
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
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        record(.parse_db);
        if (args.len < 3) return error.MissingArgument;
        return .{ .db_path = "db", .rest = args[2..] };
    }

    pub fn validateNodeText(value: []const u8) !void {
        record(.validate_text);
        if (std.mem.eql(u8, value, "too-long")) return error.TextTooLong;
    }

    pub fn validateNodeMetadata(
        name: ?[]const u8,
        _: ?[]const u8,
        _: ?[]const u8,
    ) !void {
        record(.validate_metadata);
        if (name != null and std.mem.eql(u8, name.?, "bad-meta")) return error.MetadataTooLong;
    }

    pub fn prepareSingle(parsed: anytype) !PreparedSingle {
        record(.prepare_single);
        if (std.mem.eql(u8, parsed.src_node_id, "bad-id")) return error.InvalidId;
        return .{ .src = 1, .dst = 2, .render_rel = 3001 };
    }

    pub const Context = struct {
        pub fn init(
            _: std.mem.Allocator,
            _: std.Io,
            db_path: []const u8,
            schema_path: ?[]const u8,
        ) !Context {
            TestOps.record(.context_init);
            try std.testing.expectEqualStrings("db", db_path);
            if (TestOps.expected_schema_path) |expected| {
                try std.testing.expectEqualStrings(expected, schema_path.?);
            } else {
                try std.testing.expect(schema_path == null);
            }
            if (TestOps.context_error) |err| return err;
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.record(.context_deinit);
        }

        pub fn writeSingle(_: *Context, parsed: anytype, prepared: PreparedSingle) !SingleResult {
            TestOps.record(.write_single);
            try std.testing.expectEqualStrings("related_to", parsed.rel_label);
            try std.testing.expectEqual(@as(u64, 1), prepared.src);
            try std.testing.expectEqual(@as(u64, 2), prepared.dst);
            if (TestOps.execution_error) |err| return err;
            return .{};
        }

        pub fn writeJson(_: *Context, parsed: anytype) !JsonResult {
            TestOps.record(.write_json);
            try std.testing.expectEqualStrings("batch.json", parsed.json_path);
            if (TestOps.execution_error) |err| return err;
            return .{};
        }
    };
};

const test_command = AgentWriteCommand(TestOps);

test "agent write single arguments preserve defaults aliases and validation" {
    TestOps.reset();
    const parsed = try test_command.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{
            "tinykg",           "agent-write",
            "--src",            "1",
            "--rel",            "related_to",
            "--dst",            "2",
            "--document",       "3",
            "--text",           "hello",
            "--name",           "name",
            "--summary",        "summary",
            "--retrieval-hint", "hint",
            "--render-rel",     "md:h2",
            "--schema",         "schema.json",
        },
    );
    const single = parsed.single;
    try std.testing.expectEqualStrings("db", single.db_path);
    try std.testing.expectEqualStrings("1", single.src_node_id);
    try std.testing.expectEqualStrings("related_to", single.rel_label);
    try std.testing.expectEqualStrings("2", single.dst_node_id);
    try std.testing.expectEqualStrings("3", single.document_node_id.?);
    try std.testing.expect(!single.agent_inbox);
    try std.testing.expectEqualStrings("hello", single.text);
    try std.testing.expectEqualStrings("hint", single.retrieval_hints.?);
    try std.testing.expectEqualStrings("md:h2", single.render_rel_label);
    try std.testing.expectEqualStrings("schema.json", single.schema_path.?);
    try TestOps.expectSteps(&.{ .parse_db, .validate_text, .validate_metadata });

    TestOps.reset();
    const default_target = try test_command.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "agent-write", "--src", "1", "--rel", "related_to", "--dst", "2", "--text", "hello" },
    );
    try std.testing.expect(default_target.single.agent_inbox);
    try std.testing.expectEqualStrings("md:paragraph", default_target.single.render_rel_label);
}

test "agent write JSON mode stays first-token gated and preserves options" {
    TestOps.reset();
    const parsed = try test_command.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "agent-write", "--json", "batch.json", "--schema", "schema.json" },
    );
    try std.testing.expectEqualStrings("db", parsed.json.db_path);
    try std.testing.expectEqualStrings("batch.json", parsed.json.json_path);
    try std.testing.expectEqualStrings("schema.json", parsed.json.schema_path.?);
    try TestOps.expectSteps(&.{.parse_db});

    TestOps.reset();
    try std.testing.expectError(
        error.UnknownOption,
        test_command.parseArguments(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "agent-write", "--schema", "schema.json", "--json", "batch.json" },
        ),
    );
    try TestOps.expectSteps(&.{.parse_db});
}

test "agent write arguments reject missing conflicting unknown and extra values before context" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    try std.testing.expectError(
        error.MissingArgument,
        test_command.run(&.{ "tinykg", "agent-write", "--src" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{.parse_db});

    TestOps.reset();
    try std.testing.expectError(
        error.MissingArgument,
        test_command.run(
            &.{ "tinykg", "agent-write", "--src", "1", "--rel", "related_to", "--dst", "2", "--document", "3", "--section", "4", "--text", "hello" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{.parse_db});

    TestOps.reset();
    try std.testing.expectError(
        error.UnknownOption,
        test_command.run(&.{ "tinykg", "agent-write", "--unknown", "x" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{.parse_db});

    TestOps.reset();
    try std.testing.expectError(
        error.UnknownOption,
        test_command.run(&.{ "tinykg", "agent-write", "--unknown" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{.parse_db});

    TestOps.reset();
    try std.testing.expectError(
        error.TooManyArguments,
        test_command.run(&.{ "tinykg", "agent-write", "positional", "x" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{.parse_db});

    TestOps.reset();
    try std.testing.expectError(
        error.TooManyArguments,
        test_command.run(&.{ "tinykg", "agent-write", "positional" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{.parse_db});
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "agent write single command preserves context execute output and cleanup" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try test_command.run(
        &.{ "tinykg", "agent-write", "--src", "1", "--rel", "related_to", "--dst", "2", "--text", "hello" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings(
        "agent_write src=1 rel=10 dst=2 fact_edge=3 fact_created=1 projection_root=4 projection_content=5 projection_edge=6 projection_nodes_imported=7 projection_edge_created=1 content_node_properties=2 projection_links=2 agent_inbox_created=1\n",
        writer.buffer.items,
    );
    try TestOps.expectSteps(&.{
        .parse_db,
        .validate_text,
        .validate_metadata,
        .prepare_single,
        .context_init,
        .write_single,
        .write,
        .context_deinit,
    });
}

test "agent write JSON command preserves context execute output and cleanup" {
    TestOps.reset();
    TestOps.expected_schema_path = "schema.json";
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try test_command.run(
        &.{ "tinykg", "agent-write", "--json", "batch.json", "--schema", "schema.json" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings(
        "agent_write_json items=8 fact_created=7 projection_nodes_imported=6 projection_edge_created=5 content_node_properties=4 projection_links=3 fact_properties=2 projection_properties=1 agent_inbox_created=9\n",
        writer.buffer.items,
    );
    try TestOps.expectSteps(&.{ .parse_db, .context_init, .write_json, .write, .context_deinit });
}

test "agent write validation and context failures publish no output" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    try std.testing.expectError(
        error.TextTooLong,
        test_command.run(
            &.{ "tinykg", "agent-write", "--src", "1", "--rel", "related_to", "--dst", "2", "--text", "too-long" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse_db, .validate_text });

    TestOps.reset();
    TestOps.context_error = error.FileBusy;
    try std.testing.expectError(
        error.FileBusy,
        test_command.run(
            &.{ "tinykg", "agent-write", "--src", "1", "--rel", "related_to", "--dst", "2", "--text", "hello" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse_db, .validate_text, .validate_metadata, .prepare_single, .context_init });
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "agent write execution failures close context without output" {
    TestOps.reset();
    TestOps.execution_error = error.InvalidRecord;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRecord,
        test_command.run(
            &.{ "tinykg", "agent-write", "--src", "1", "--rel", "related_to", "--dst", "2", "--text", "hello" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{
        .parse_db,
        .validate_text,
        .validate_metadata,
        .prepare_single,
        .context_init,
        .write_single,
        .context_deinit,
    });
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "agent write writer failures close context after successful execution" {
    TestOps.reset();
    var writer = FailingWriter{};
    try std.testing.expectError(
        error.OutputClosed,
        test_command.run(
            &.{ "tinykg", "agent-write", "--src", "1", "--rel", "related_to", "--dst", "2", "--text", "hello" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{
        .parse_db,
        .validate_text,
        .validate_metadata,
        .prepare_single,
        .context_init,
        .write_single,
        .write,
        .context_deinit,
    });
}
