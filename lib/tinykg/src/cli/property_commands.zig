const std = @import("std");

/// Property-mutation command family.
///
/// This owner keeps the four public spellings on one syntax and sequencing
/// contract without importing concrete graph, storage, or schema types. The
/// façade supplies those representations through `Ops` and retains all
/// domain/schema validation behind that adapter.
pub fn PropertyCommands(comptime Ops: type) type {
    return struct {
        const PropertyOwner = Ops.PropertyOwner;

        const StringMutation = struct {
            owner: PropertyOwner,
            owner_label: []const u8,
            key: []const u8,
            value: []const u8,
        };

        const UintMutation = struct {
            owner: PropertyOwner,
            owner_label: []const u8,
            key: []const u8,
            value: u64,
        };

        fn requireArity(rest: []const []const u8, expected: usize) !void {
            if (rest.len != expected) return if (rest.len < expected) error.MissingArgument else error.TooManyArguments;
        }

        fn parseStringMutation(rest: []const []const u8) !StringMutation {
            try requireArity(rest, 4);
            if (std.mem.eql(u8, rest[0], "node")) {
                const owner = try Ops.parseNodeOwner(rest[1]);
                return .{
                    .owner = owner,
                    .owner_label = "node",
                    .key = try Ops.normalizeNodeStringKey(rest[2]),
                    .value = rest[3],
                };
            }
            if (std.mem.eql(u8, rest[0], "edge")) {
                const owner = try Ops.parseEdgeOwner(rest[1]);
                return .{
                    .owner = owner,
                    .owner_label = "edge",
                    .key = try Ops.normalizeEdgeStringKey(rest[2]),
                    .value = rest[3],
                };
            }
            return error.InvalidRecord;
        }

        fn parseUintMutation(rest: []const []const u8) !UintMutation {
            try requireArity(rest, 4);
            // Preserve the historical error precedence: malformed values are
            // rejected before owner-kind, id, or key validation.
            const value = std.fmt.parseInt(u64, rest[3], 10) catch return error.InvalidRecord;
            if (std.mem.eql(u8, rest[0], "node")) {
                const owner = try Ops.parseNodeOwner(rest[1]);
                return .{
                    .owner = owner,
                    .owner_label = "node",
                    .key = try Ops.normalizeNodeUintKey(rest[2]),
                    .value = value,
                };
            }
            if (std.mem.eql(u8, rest[0], "edge")) {
                const owner = try Ops.parseEdgeOwner(rest[1]);
                return .{
                    .owner = owner,
                    .owner_label = "edge",
                    .key = try Ops.normalizeEdgeUintKey(rest[2]),
                    .value = value,
                };
            }
            return error.InvalidRecord;
        }

        fn parseNodeStringMutation(rest: []const []const u8) !StringMutation {
            try requireArity(rest, 3);
            // The specialized command historically normalizes its key before
            // parsing the node id; keep that observable error ordering.
            const key = try Ops.normalizeNodeStringKey(rest[1]);
            return .{
                .owner = try Ops.parseNodeOwner(rest[0]),
                .owner_label = "node",
                .key = key,
                .value = rest[2],
            };
        }

        fn parseEdgeStringMutation(rest: []const []const u8) !StringMutation {
            try requireArity(rest, 3);
            const key = try Ops.normalizeEdgeStringKey(rest[1]);
            return .{
                .owner = try Ops.parseEdgeOwner(rest[0]),
                .owner_label = "edge",
                .key = key,
                .value = rest[2],
            };
        }

        pub fn runSetString(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 4, 6);
            const selection = try Ops.parseOptionalSchema(db.rest, 4, 4);
            const parsed = try parseStringMutation(selection.positionals);
            try Ops.validateString(parsed.owner, parsed.key, parsed.value);

            var context = try Ops.Context.init(allocator, io, db.db_path, selection.schema_path);
            defer context.deinit();
            try context.setString(parsed.owner, parsed.key, parsed.value);
            try writer.print(
                "property owner={s} id={} key={s} bytes={}\n",
                .{ parsed.owner_label, Ops.ownerId(parsed.owner), parsed.key, parsed.value.len },
            );
        }

        pub fn runSetUint(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 4, 6);
            const selection = try Ops.parseOptionalSchema(db.rest, 4, 4);
            const parsed = try parseUintMutation(selection.positionals);

            var context = try Ops.Context.init(allocator, io, db.db_path, selection.schema_path);
            defer context.deinit();
            try context.setUint(parsed.owner, parsed.key, parsed.value);
            try writer.print(
                "uint_property owner={s} id={} key={s} value={}\n",
                .{ parsed.owner_label, Ops.ownerId(parsed.owner), parsed.key, parsed.value },
            );
        }

        pub fn runSetNode(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 3, 5);
            const selection = try Ops.parseOptionalSchema(db.rest, 3, 3);
            const parsed = try parseNodeStringMutation(selection.positionals);
            try Ops.validateString(parsed.owner, parsed.key, parsed.value);

            var context = try Ops.Context.init(allocator, io, db.db_path, selection.schema_path);
            defer context.deinit();
            try context.setString(parsed.owner, parsed.key, parsed.value);
            try writer.print(
                "node_property node={} key={s} bytes={}\n",
                .{ Ops.ownerId(parsed.owner), parsed.key, parsed.value.len },
            );
        }


        /// Daemon-resident variants: identical parsing and validation, but the
        /// mutation runs on a store the caller keeps open (no CLI lock, no
        /// open/close). The parsed db path must match the borrowed store.
        pub fn runSetStringWithStore(
            store: anytype,
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 4, 6);
            const selection = try Ops.parseOptionalSchema(db.rest, 4, 4);
            const parsed = try parseStringMutation(selection.positionals);
            try Ops.validateString(parsed.owner, parsed.key, parsed.value);
            if (!std.mem.eql(u8, db.db_path, store.dir_path)) return error.StorePathMismatch;
            var context = try Ops.Context.initBorrowed(allocator, io, store, selection.schema_path);
            defer context.deinit();
            try context.setString(parsed.owner, parsed.key, parsed.value);
            try writer.print(
                "string_property owner={s} id={} key={s} bytes={}\n",
                .{ parsed.owner_label, Ops.ownerId(parsed.owner), parsed.key, parsed.value.len },
            );
        }

        pub fn runSetUintWithStore(
            store: anytype,
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 4, 6);
            const selection = try Ops.parseOptionalSchema(db.rest, 4, 4);
            const parsed = try parseUintMutation(selection.positionals);
            if (!std.mem.eql(u8, db.db_path, store.dir_path)) return error.StorePathMismatch;
            var context = try Ops.Context.initBorrowed(allocator, io, store, selection.schema_path);
            defer context.deinit();
            try context.setUint(parsed.owner, parsed.key, parsed.value);
            try writer.print(
                "uint_property owner={s} id={} key={s} value={}\n",
                .{ parsed.owner_label, Ops.ownerId(parsed.owner), parsed.key, parsed.value },
            );
        }

        pub fn runSetNodeWithStore(
            store: anytype,
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 3, 5);
            const selection = try Ops.parseOptionalSchema(db.rest, 3, 3);
            const parsed = try parseNodeStringMutation(selection.positionals);
            try Ops.validateString(parsed.owner, parsed.key, parsed.value);
            if (!std.mem.eql(u8, db.db_path, store.dir_path)) return error.StorePathMismatch;
            var context = try Ops.Context.initBorrowed(allocator, io, store, selection.schema_path);
            defer context.deinit();
            try context.setString(parsed.owner, parsed.key, parsed.value);
            try writer.print(
                "node_property node={} key={s} bytes={}\n",
                .{ Ops.ownerId(parsed.owner), parsed.key, parsed.value.len },
            );
        }

        pub fn runSetEdgeWithStore(
            store: anytype,
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 3, 5);
            const selection = try Ops.parseOptionalSchema(db.rest, 3, 3);
            const parsed = try parseEdgeStringMutation(selection.positionals);
            try Ops.validateString(parsed.owner, parsed.key, parsed.value);
            if (!std.mem.eql(u8, db.db_path, store.dir_path)) return error.StorePathMismatch;
            var context = try Ops.Context.initBorrowed(allocator, io, store, selection.schema_path);
            defer context.deinit();
            try context.setString(parsed.owner, parsed.key, parsed.value);
            try writer.print(
                "edge_property edge={} key={s} bytes={}\n",
                .{ Ops.ownerId(parsed.owner), parsed.key, parsed.value.len },
            );
        }

        pub fn runSetEdge(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 3, 5);
            const selection = try Ops.parseOptionalSchema(db.rest, 3, 3);
            const parsed = try parseEdgeStringMutation(selection.positionals);
            try Ops.validateString(parsed.owner, parsed.key, parsed.value);

            var context = try Ops.Context.init(allocator, io, db.db_path, selection.schema_path);
            defer context.deinit();
            try context.setString(parsed.owner, parsed.key, parsed.value);
            try writer.print(
                "edge_property edge={} key={s} bytes={}\n",
                .{ Ops.ownerId(parsed.owner), parsed.key, parsed.value.len },
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

const TestOps = struct {
    pub const PropertyOwner = union(enum) {
        node: u64,
        edge: u64,
    };

    const Selection = struct {
        positionals: []const []const u8,
        schema_path: ?[]const u8 = null,
    };

    const Step = enum { validate, open, set_string, set_uint, close };

    var steps: [16]Step = undefined;
    var step_count: usize = 0;
    var schema_path: ?[]const u8 = null;
    var last_owner: PropertyOwner = .{ .node = 0 };
    var last_key: []const u8 = "";
    var last_string: []const u8 = "";
    var last_uint: u64 = 0;
    var fail_validation = false;
    var fail_mutation = false;

    fn reset() void {
        step_count = 0;
        schema_path = null;
        last_owner = .{ .node = 0 };
        last_key = "";
        last_string = "";
        last_uint = 0;
        fail_validation = false;
        fail_mutation = false;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    pub fn parseDbArguments(
        _: std.mem.Allocator,
        _: std.Io,
        args: []const []const u8,
        min_rest: usize,
        max_rest: usize,
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        const rest = args[2..];
        if (rest.len < min_rest) return error.MissingArgument;
        if (rest.len > max_rest) return error.TooManyArguments;
        return .{ .db_path = "db", .rest = rest };
    }

    pub fn parseOptionalSchema(rest: []const []const u8, min_positionals: usize, max_positionals: usize) !Selection {
        const has_schema = rest.len >= 2 and std.mem.eql(u8, rest[rest.len - 2], "--schema");
        const positionals = if (has_schema) rest[0 .. rest.len - 2] else rest;
        if (positionals.len < min_positionals) return error.MissingArgument;
        if (positionals.len > max_positionals) return error.TooManyArguments;
        return .{ .positionals = positionals, .schema_path = if (has_schema) rest[rest.len - 1] else null };
    }

    pub fn parseNodeOwner(value: []const u8) !PropertyOwner {
        return .{ .node = std.fmt.parseInt(u64, value, 10) catch return error.InvalidNodeId };
    }

    pub fn parseEdgeOwner(value: []const u8) !PropertyOwner {
        return .{ .edge = std.fmt.parseInt(u64, value, 10) catch return error.InvalidEdgeId };
    }

    pub fn normalizeNodeStringKey(key: []const u8) ![]const u8 {
        if (std.mem.eql(u8, key, "retrieval-hints")) return "retrieval_hints";
        if (std.mem.eql(u8, key, "name")) return key;
        return error.InvalidRecord;
    }

    pub fn normalizeEdgeStringKey(key: []const u8) ![]const u8 {
        if (std.mem.eql(u8, key, "created-by")) return "created_by";
        if (std.mem.eql(u8, key, "confidence")) return key;
        return error.InvalidRecord;
    }

    pub fn normalizeNodeUintKey(key: []const u8) ![]const u8 {
        if (std.mem.eql(u8, key, "created-at")) return "created_at";
        return error.InvalidRecord;
    }

    pub fn normalizeEdgeUintKey(key: []const u8) ![]const u8 {
        if (std.mem.eql(u8, key, "order-key")) return "order_key";
        return error.InvalidRecord;
    }

    pub fn validateString(owner: PropertyOwner, key: []const u8, value: []const u8) !void {
        record(.validate);
        last_owner = owner;
        last_key = key;
        last_string = value;
        if (fail_validation) return error.PropertyTooLarge;
    }

    pub fn ownerId(owner: PropertyOwner) u64 {
        return switch (owner) {
            .node => |id| id,
            .edge => |id| id,
        };
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, _: []const u8, selected_schema_path: ?[]const u8) !Context {
            TestOps.record(.open);
            TestOps.schema_path = selected_schema_path;
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.record(.close);
        }

        pub fn setString(_: *Context, owner: PropertyOwner, key: []const u8, value: []const u8) !void {
            TestOps.record(.set_string);
            TestOps.last_owner = owner;
            TestOps.last_key = key;
            TestOps.last_string = value;
            if (TestOps.fail_mutation) return error.InvalidRecord;
        }

        pub fn setUint(_: *Context, owner: PropertyOwner, key: []const u8, value: u64) !void {
            TestOps.record(.set_uint);
            TestOps.last_owner = owner;
            TestOps.last_key = key;
            TestOps.last_uint = value;
            if (TestOps.fail_mutation) return error.InvalidRecord;
        }
    };
};

const test_commands = PropertyCommands(TestOps);

test "property commands route generic string and uint mutations" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runSetString(
        &.{ "tinykg", "set-property", "node", "7", "retrieval-hints", "alpha" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("property owner=node id=7 key=retrieval_hints bytes=5\n", writer.buffer.items);
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .validate, .open, .set_string, .close }, TestOps.steps[0..TestOps.step_count]);

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runSetUint(
        &.{ "tinykg", "set-uint-property", "edge", "9", "order-key", "42", "--schema", "schema.json" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("uint_property owner=edge id=9 key=order_key value=42\n", writer.buffer.items);
    try std.testing.expectEqualStrings("schema.json", TestOps.schema_path.?);
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .open, .set_uint, .close }, TestOps.steps[0..TestOps.step_count]);
}

test "property commands preserve specialized node and edge outputs" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runSetNode(
        &.{ "tinykg", "set-node-property", "11", "name", "node-name" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("node_property node=11 key=name bytes=9\n", writer.buffer.items);

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runSetEdge(
        &.{ "tinykg", "set-edge-property", "13", "created-by", "agent" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("edge_property edge=13 key=created_by bytes=5\n", writer.buffer.items);
}

test "property command arguments preserve arity and error precedence" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.MissingArgument,
        test_commands.runSetString(&.{ "tinykg", "set-property", "node", "1", "name" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectError(
        error.InvalidRecord,
        test_commands.runSetUint(&.{ "tinykg", "set-uint-property", "invalid-owner", "bad-id", "bad-key", "bad-value" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectError(
        error.InvalidRecord,
        test_commands.runSetNode(&.{ "tinykg", "set-node-property", "bad-id", "bad-key", "value" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 0), TestOps.step_count);
}

test "property command validation fails before context acquisition" {
    TestOps.reset();
    TestOps.fail_validation = true;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.PropertyTooLarge,
        test_commands.runSetEdge(&.{ "tinykg", "set-edge-property", "3", "confidence", "value" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqualSlices(TestOps.Step, &.{.validate}, TestOps.steps[0..TestOps.step_count]);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "property command context closes after mutation failure" {
    TestOps.reset();
    TestOps.fail_mutation = true;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRecord,
        test_commands.runSetString(&.{ "tinykg", "set-property", "edge", "5", "confidence", "value" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .validate, .open, .set_string, .close }, TestOps.steps[0..TestOps.step_count]);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "property command context closes after writer failure" {
    TestOps.reset();
    const FailingWriter = struct {
        fn print(_: *@This(), comptime _: []const u8, _: anytype) error{OutputClosed}!void {
            return error.OutputClosed;
        }
    };
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        test_commands.runSetUint(
            &.{ "tinykg", "set-uint-property", "node", "8", "created-at", "17" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .open, .set_uint, .close }, TestOps.steps[0..TestOps.step_count]);
}
