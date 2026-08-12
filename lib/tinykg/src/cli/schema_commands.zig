const std = @import("std");

/// One syntax owner for schema selection and schema-catalog commands.
///
/// These parsers deliberately retain the CLI's historical error distinctions:
/// missing values, duplicate options, unknown options, and excess positionals
/// remain separate contracts even when several commands share the same flags.
pub const SchemaArguments = struct {
    pub const Selection = struct {
        positionals: []const []const u8,
        schema_path: ?[]const u8 = null,
        profiles: ?[]const u8 = null,
    };

    pub const Catalog = struct {
        db_path: []const u8,
        schema_path: ?[]const u8,
        profiles: ?[]const u8,
    };

    pub const Migration = struct {
        old_db_path: []const u8,
        new_db_path: []const u8,
        from_schema_path: ?[]const u8,
        to_schema_path: ?[]const u8,
        profiles: ?[]const u8,
    };

    pub const Show = struct {
        db_path: ?[]const u8 = null,
        want_json: bool = false,
    };

    pub fn parseTrailing(rest: []const []const u8, positional_count: usize) !Selection {
        if (rest.len == positional_count) return .{ .positionals = rest };
        if (rest.len == positional_count + 2 and std.mem.eql(u8, rest[positional_count], "--schema")) {
            return .{ .positionals = rest[0..positional_count], .schema_path = rest[positional_count + 1] };
        }
        if (rest.len > positional_count and std.mem.startsWith(u8, rest[positional_count], "--")) return error.UnknownOption;
        return error.TooManyArguments;
    }

    pub fn parseOptionalTrailing(rest: []const []const u8, min_positionals: usize, max_positionals: usize) !Selection {
        if (max_positionals < min_positionals) return error.InvalidPlan;
        const has_schema = rest.len >= 2 and std.mem.eql(u8, rest[rest.len - 2], "--schema");
        const positionals = if (has_schema) rest[0 .. rest.len - 2] else rest;
        if (positionals.len < min_positionals) return error.MissingArgument;
        if (positionals.len > max_positionals) {
            if (positionals.len > min_positionals and std.mem.startsWith(u8, positionals[min_positionals], "--")) return error.UnknownOption;
            return error.TooManyArguments;
        }
        return .{
            .positionals = positionals,
            .schema_path = if (has_schema) rest[rest.len - 1] else null,
        };
    }

    pub fn parseOnlyRest(rest: []const []const u8) !Selection {
        return parseOnlySlice(rest, 0);
    }

    pub fn parseOptionalOnly(args: []const []const u8, start: usize) !Selection {
        return parseOnlySlice(args, start);
    }

    fn parseOnlySlice(args: []const []const u8, start: usize) !Selection {
        var parsed = Selection{ .positionals = &.{} };
        var pos = start;
        while (pos < args.len) {
            if (std.mem.eql(u8, args[pos], "--schema")) {
                if (parsed.schema_path != null) return error.TooManyArguments;
                if (pos + 1 >= args.len) return error.MissingArgument;
                parsed.schema_path = args[pos + 1];
                pos += 2;
                continue;
            }
            if (std.mem.eql(u8, args[pos], "--profile")) {
                if (parsed.profiles != null) return error.TooManyArguments;
                if (pos + 1 >= args.len) return error.MissingArgument;
                parsed.profiles = args[pos + 1];
                pos += 2;
                continue;
            }
            if (std.mem.startsWith(u8, args[pos], "--")) return error.UnknownOption;
            return error.TooManyArguments;
        }
        return parsed;
    }

    pub fn parseCatalog(args: []const []const u8, start: usize) !Catalog {
        if (args.len <= start) return error.MissingArgument;
        var parsed = Catalog{
            .db_path = args[start],
            .schema_path = null,
            .profiles = null,
        };
        var pos = start + 1;
        while (pos < args.len) {
            if (std.mem.eql(u8, args[pos], "--schema")) {
                if (parsed.schema_path != null) return error.TooManyArguments;
                if (pos + 1 >= args.len) return error.MissingArgument;
                parsed.schema_path = args[pos + 1];
                pos += 2;
            } else if (std.mem.eql(u8, args[pos], "--profile")) {
                if (parsed.profiles != null) return error.TooManyArguments;
                if (pos + 1 >= args.len) return error.MissingArgument;
                parsed.profiles = args[pos + 1];
                pos += 2;
            } else {
                return error.UnknownOption;
            }
        }
        if (parsed.schema_path == null) return error.MissingArgument;
        return parsed;
    }

    pub fn parseMigration(args: []const []const u8, start: usize) !Migration {
        if (args.len < start + 2) return error.MissingArgument;
        var parsed = Migration{
            .old_db_path = args[start],
            .new_db_path = args[start + 1],
            .from_schema_path = null,
            .to_schema_path = null,
            .profiles = null,
        };
        var pos = start + 2;
        while (pos < args.len) {
            if (std.mem.eql(u8, args[pos], "--from")) {
                if (parsed.from_schema_path != null) return error.TooManyArguments;
                if (pos + 1 >= args.len) return error.MissingArgument;
                parsed.from_schema_path = args[pos + 1];
                pos += 2;
            } else if (std.mem.eql(u8, args[pos], "--to")) {
                if (parsed.to_schema_path != null) return error.TooManyArguments;
                if (pos + 1 >= args.len) return error.MissingArgument;
                parsed.to_schema_path = args[pos + 1];
                pos += 2;
            } else if (std.mem.eql(u8, args[pos], "--profile")) {
                if (parsed.profiles != null) return error.TooManyArguments;
                if (pos + 1 >= args.len) return error.MissingArgument;
                parsed.profiles = args[pos + 1];
                pos += 2;
            } else {
                return error.UnknownOption;
            }
        }
        return parsed;
    }

    pub fn parseShow(args: []const []const u8, start: usize) !Show {
        var parsed = Show{};
        var pos = start;
        while (pos < args.len) : (pos += 1) {
            if (std.mem.eql(u8, args[pos], "--json")) {
                parsed.want_json = true;
            } else if (parsed.db_path == null) {
                parsed.db_path = args[pos];
            } else {
                return error.TooManyArguments;
            }
        }
        return parsed;
    }
};

/// Schema command-family control plane.
///
/// Concrete Registry, Store, catalog renderers, locks, and migration
/// transactions remain behind `Ops`; this owner binds each command to the
/// shared syntax contract and guarantees that opened contexts are closed on
/// both rendering and mutation failures.
pub fn SchemaCommands(comptime Ops: type) type {
    return struct {
        pub fn runInfo(args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !void {
            const parsed = try SchemaArguments.parseOptionalOnly(args, 2);
            var context = try Ops.InfoContext.init(allocator, io, parsed.schema_path, parsed.profiles);
            defer context.deinit();
            try context.render(writer);
        }

        pub fn runListKinds(args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !void {
            const parsed = try SchemaArguments.parseOptionalOnly(args, 2);
            var context = try Ops.ListContext.init(allocator, io, parsed.schema_path, parsed.profiles);
            defer context.deinit();
            try context.renderKinds(writer);
        }

        pub fn runListRelations(args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !void {
            const parsed = try SchemaArguments.parseOptionalOnly(args, 2);
            var context = try Ops.ListContext.init(allocator, io, parsed.schema_path, parsed.profiles);
            defer context.deinit();
            try context.renderRelations(writer);
        }

        pub fn runShow(args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !void {
            const parsed = try SchemaArguments.parseShow(args, 2);
            const db_path = parsed.db_path orelse Ops.resolveDefaultDbPath();
            var context = try Ops.StoreContext.init(allocator, io, db_path);
            defer context.deinit();
            try context.renderShow(writer, parsed.want_json);
        }

        pub fn runApply(args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !void {
            const parsed = try SchemaArguments.parseCatalog(args, 2);
            var context = try Ops.StoreContext.init(allocator, io, parsed.db_path);
            defer context.deinit();
            try context.apply(writer, parsed.schema_path.?, parsed.profiles);
        }

        pub fn runValidate(args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !void {
            const parsed = try SchemaArguments.parseCatalog(args, 2);
            var context = try Ops.StoreContext.init(allocator, io, parsed.db_path);
            defer context.deinit();
            try context.validate(writer, parsed.schema_path.?, parsed.profiles);
        }

        pub fn runMigrate(args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !void {
            const parsed = try SchemaArguments.parseMigration(args, 2);
            try Ops.runMigrate(
                allocator,
                io,
                writer,
                parsed.old_db_path,
                parsed.new_db_path,
                parsed.from_schema_path,
                parsed.to_schema_path,
                parsed.profiles,
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
};

const TestOps = struct {
    const Step = enum {
        info_init,
        info_render,
        info_deinit,
        list_init,
        list_kinds,
        list_relations,
        list_deinit,
        store_init,
        show,
        apply,
        validate,
        store_deinit,
        migrate,
    };

    var steps: [32]Step = undefined;
    var step_count: usize = 0;
    var last_db_path: []const u8 = "";
    var last_schema_path: ?[]const u8 = null;
    var last_profiles: ?[]const u8 = null;
    var last_from_schema: ?[]const u8 = null;
    var last_to_schema: ?[]const u8 = null;
    var fail_store_operation = false;
    var fail_list_render = false;

    fn reset() void {
        step_count = 0;
        last_db_path = "";
        last_schema_path = null;
        last_profiles = null;
        last_from_schema = null;
        last_to_schema = null;
        fail_store_operation = false;
        fail_list_render = false;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    pub fn resolveDefaultDbPath() []const u8 {
        return "default-db";
    }

    pub const InfoContext = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, schema_path: ?[]const u8, profiles: ?[]const u8) !InfoContext {
            TestOps.record(.info_init);
            TestOps.last_schema_path = schema_path;
            TestOps.last_profiles = profiles;
            return .{};
        }

        pub fn deinit(_: *InfoContext) void {
            TestOps.record(.info_deinit);
        }

        pub fn render(_: *InfoContext, writer: anytype) !void {
            TestOps.record(.info_render);
            try writer.writeAll("info\n");
        }
    };

    pub const StoreContext = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, db_path: []const u8) !StoreContext {
            TestOps.record(.store_init);
            TestOps.last_db_path = db_path;
            return .{};
        }

        pub fn deinit(_: *StoreContext) void {
            TestOps.record(.store_deinit);
        }

        pub fn renderShow(_: *StoreContext, writer: anytype, want_json: bool) !void {
            TestOps.record(.show);
            if (TestOps.fail_store_operation) return error.InvalidRecord;
            try writer.writeAll(if (want_json) "show-json\n" else "show-text\n");
        }

        pub fn apply(_: *StoreContext, writer: anytype, schema_path: []const u8, profiles: ?[]const u8) !void {
            TestOps.record(.apply);
            TestOps.last_schema_path = schema_path;
            TestOps.last_profiles = profiles;
            if (TestOps.fail_store_operation) return error.InvalidRecord;
            try writer.writeAll("apply\n");
        }

        pub fn validate(_: *StoreContext, writer: anytype, schema_path: []const u8, profiles: ?[]const u8) !void {
            TestOps.record(.validate);
            TestOps.last_schema_path = schema_path;
            TestOps.last_profiles = profiles;
            if (TestOps.fail_store_operation) return error.InvalidRecord;
            try writer.writeAll("validate\n");
        }
    };

    pub const ListContext = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, schema_path: ?[]const u8, profiles: ?[]const u8) !ListContext {
            TestOps.record(.list_init);
            TestOps.last_schema_path = schema_path;
            TestOps.last_profiles = profiles;
            return .{};
        }

        pub fn deinit(_: *ListContext) void {
            TestOps.record(.list_deinit);
        }

        pub fn renderKinds(_: *ListContext, writer: anytype) !void {
            TestOps.record(.list_kinds);
            if (TestOps.fail_list_render) return error.InvalidRecord;
            try writer.writeAll("kinds\n");
        }

        pub fn renderRelations(_: *ListContext, writer: anytype) !void {
            TestOps.record(.list_relations);
            if (TestOps.fail_list_render) return error.InvalidRecord;
            try writer.writeAll("relations\n");
        }
    };

    pub fn runMigrate(
        _: std.mem.Allocator,
        _: std.Io,
        writer: anytype,
        old_db_path: []const u8,
        new_db_path: []const u8,
        from_schema_path: ?[]const u8,
        to_schema_path: ?[]const u8,
        profiles: ?[]const u8,
    ) !void {
        record(.migrate);
        try std.testing.expectEqualStrings("old-db", old_db_path);
        last_db_path = new_db_path;
        last_from_schema = from_schema_path;
        last_to_schema = to_schema_path;
        last_profiles = profiles;
        try writer.writeAll("migrate\n");
    }
};

const test_commands = SchemaCommands(TestOps);

test "schema arguments preserve trailing selection arity and errors" {
    const exact = try SchemaArguments.parseTrailing(&.{ "node", "kind", "text" }, 3);
    try std.testing.expectEqual(@as(usize, 3), exact.positionals.len);
    try std.testing.expectEqual(@as(?[]const u8, null), exact.schema_path);

    const selected = try SchemaArguments.parseTrailing(&.{ "node", "kind", "text", "--schema", "schema.json" }, 3);
    try std.testing.expectEqualStrings("schema.json", selected.schema_path.?);
    try std.testing.expectError(error.UnknownOption, SchemaArguments.parseTrailing(&.{ "node", "--bad" }, 1));
    try std.testing.expectError(error.TooManyArguments, SchemaArguments.parseTrailing(&.{ "node", "extra" }, 1));

    const optional = try SchemaArguments.parseOptionalTrailing(&.{ "owner", "key", "value", "--schema", "schema.json" }, 3, 4);
    try std.testing.expectEqual(@as(usize, 3), optional.positionals.len);
    try std.testing.expectEqualStrings("schema.json", optional.schema_path.?);
    try std.testing.expectError(error.MissingArgument, SchemaArguments.parseOptionalTrailing(&.{"owner"}, 2, 3));
    try std.testing.expectError(error.InvalidPlan, SchemaArguments.parseOptionalTrailing(&.{}, 2, 1));
}

test "schema arguments accept schema and profiles exactly once" {
    const parsed = try SchemaArguments.parseOnlyRest(&.{ "--profile", "agent-dag", "--schema", "schema.json" });
    try std.testing.expectEqualStrings("schema.json", parsed.schema_path.?);
    try std.testing.expectEqualStrings("agent-dag", parsed.profiles.?);
    try std.testing.expectError(error.TooManyArguments, SchemaArguments.parseOnlyRest(&.{ "--schema", "a", "--schema", "b" }));
    try std.testing.expectError(error.MissingArgument, SchemaArguments.parseOnlyRest(&.{"--profile"}));
    try std.testing.expectError(error.UnknownOption, SchemaArguments.parseOnlyRest(&.{"--unknown"}));
    try std.testing.expectError(error.TooManyArguments, SchemaArguments.parseOnlyRest(&.{"positional"}));
}

test "schema catalog migration and show arguments preserve command syntax" {
    const catalog = try SchemaArguments.parseCatalog(&.{ "tinykg", "schema-apply", "db", "--profile", "agent-dag", "--schema", "schema.json" }, 2);
    try std.testing.expectEqualStrings("db", catalog.db_path);
    try std.testing.expectEqualStrings("schema.json", catalog.schema_path.?);
    try std.testing.expectEqualStrings("agent-dag", catalog.profiles.?);
    try std.testing.expectError(error.MissingArgument, SchemaArguments.parseCatalog(&.{ "tinykg", "schema-apply", "db" }, 2));
    try std.testing.expectError(error.UnknownOption, SchemaArguments.parseCatalog(&.{ "tinykg", "schema-apply", "db", "plain" }, 2));

    const migration = try SchemaArguments.parseMigration(&.{ "tinykg", "schema-migrate", "old", "new", "--from", "old.json", "--to", "new.json", "--profile", "agent-dag" }, 2);
    try std.testing.expectEqualStrings("old", migration.old_db_path);
    try std.testing.expectEqualStrings("new", migration.new_db_path);
    try std.testing.expectEqualStrings("old.json", migration.from_schema_path.?);
    try std.testing.expectEqualStrings("new.json", migration.to_schema_path.?);
    try std.testing.expectEqualStrings("agent-dag", migration.profiles.?);
    try std.testing.expectError(error.MissingArgument, SchemaArguments.parseMigration(&.{ "tinykg", "schema-migrate", "old" }, 2));

    const show = try SchemaArguments.parseShow(&.{ "tinykg", "schema-show", "--json", "db", "--json" }, 2);
    try std.testing.expect(show.want_json);
    try std.testing.expectEqualStrings("db", show.db_path.?);
    try std.testing.expectError(error.TooManyArguments, SchemaArguments.parseShow(&.{ "tinykg", "schema-show", "a", "b" }, 2));
}

test "schema command family routes operations through bounded contexts" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runInfo(&.{ "tinykg", "schema-info", "--schema", "info.json", "--profile", "agent-dag" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .info_init, .info_render, .info_deinit }, TestOps.steps[0..TestOps.step_count]);
    try std.testing.expectEqualStrings("info.json", TestOps.last_schema_path.?);

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runShow(&.{ "tinykg", "schema-show", "--json" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("default-db", TestOps.last_db_path);
    try std.testing.expectEqualStrings("show-json\n", writer.buffer.items);
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .store_init, .show, .store_deinit }, TestOps.steps[0..TestOps.step_count]);

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runApply(&.{ "tinykg", "schema-apply", "db", "--schema", "apply.json" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .store_init, .apply, .store_deinit }, TestOps.steps[0..TestOps.step_count]);

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runValidate(&.{ "tinykg", "schema-validate", "db", "--schema", "validate.json" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .store_init, .validate, .store_deinit }, TestOps.steps[0..TestOps.step_count]);

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runMigrate(&.{ "tinykg", "schema-migrate", "old-db", "new-db", "--from", "old.json", "--to", "new.json" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualSlices(TestOps.Step, &.{.migrate}, TestOps.steps[0..TestOps.step_count]);
    try std.testing.expectEqualStrings("new-db", TestOps.last_db_path);
}

test "schema command context closes after operation failure" {
    TestOps.reset();
    TestOps.fail_store_operation = true;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRecord,
        test_commands.runValidate(&.{ "tinykg", "schema-validate", "db", "--schema", "schema.json" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .store_init, .validate, .store_deinit }, TestOps.steps[0..TestOps.step_count]);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "schema list commands preserve registry-only lifetime and streaming output" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runListKinds(
        &.{ "tinykg", "list-kinds", "--profile", "agent-dag", "--schema", "schema.json" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("schema.json", TestOps.last_schema_path.?);
    try std.testing.expectEqualStrings("agent-dag", TestOps.last_profiles.?);
    try std.testing.expectEqualStrings("kinds\n", writer.buffer.items);
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .list_init, .list_kinds, .list_deinit }, TestOps.steps[0..TestOps.step_count]);

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runListRelations(
        &.{ "tinykg", "list-rels", "--profile", "markdown-document" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("markdown-document", TestOps.last_profiles.?);
    try std.testing.expectEqualStrings("relations\n", writer.buffer.items);
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .list_init, .list_relations, .list_deinit }, TestOps.steps[0..TestOps.step_count]);
}

test "schema list command context closes after render or writer failure" {
    TestOps.reset();
    TestOps.fail_list_render = true;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRecord,
        test_commands.runListKinds(&.{ "tinykg", "list-kinds" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .list_init, .list_kinds, .list_deinit }, TestOps.steps[0..TestOps.step_count]);

    TestOps.reset();
    var failing_writer = struct {
        fn writeAll(_: *@This(), _: []const u8) error{OutputClosed}!void {
            return error.OutputClosed;
        }
    }{};
    try std.testing.expectError(
        error.OutputClosed,
        test_commands.runListRelations(&.{ "tinykg", "list-rels" }, &failing_writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .list_init, .list_relations, .list_deinit }, TestOps.steps[0..TestOps.step_count]);
}
