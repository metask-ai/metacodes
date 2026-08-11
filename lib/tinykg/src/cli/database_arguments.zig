const std = @import("std");

/// Resolves the optional database-path prefix shared by CLI commands.
///
/// The owner keeps fixed-arity and free-text ambiguity rules together while
/// delegating the environment default and real store probe to `cli.zig`.
pub fn DatabaseArguments(comptime Ops: type) type {
    return struct {
        pub const Parsed = struct {
            db_path: []const u8,
            rest: []const []const u8,
        };

        pub const ParsedFreeText = struct {
            db_path: []const u8,
            rest: []const []const u8,
            owned_db_path: ?[]u8 = null,

            pub fn deinit(self: ParsedFreeText, allocator: std.mem.Allocator) void {
                if (self.owned_db_path) |path| allocator.free(path);
            }
        };

        pub fn parse(
            allocator: std.mem.Allocator,
            io: std.Io,
            args: []const []const u8,
            start: usize,
            min_rest: usize,
            max_rest: usize,
            require_existing_db: bool,
        ) !Parsed {
            if (args.len < start) return error.MissingArgument;
            if (max_rest < min_rest) return error.InvalidPlan;

            const remaining_default = args[start..];
            const default_valid = remaining_default.len >= min_rest and remaining_default.len <= max_rest;
            if (args.len == start) {
                if (default_valid) return .{ .db_path = Ops.defaultPath(), .rest = remaining_default };
                return error.MissingArgument;
            }

            const candidate = args[start];
            const remaining_if_db = if (args.len > start + 1) args[start + 1 ..] else &.{};
            const db_valid = remaining_if_db.len >= min_rest and remaining_if_db.len <= max_rest;

            if (default_valid and db_valid) {
                if (try Ops.existingStorePath(allocator, io, candidate)) {
                    return .{ .db_path = candidate, .rest = remaining_if_db };
                }
                if (require_existing_db and looksLikeExplicitPath(candidate)) return error.FileNotFound;
                return .{ .db_path = Ops.defaultPath(), .rest = remaining_default };
            }
            if (default_valid) return .{ .db_path = Ops.defaultPath(), .rest = remaining_default };
            if (db_valid) {
                if (require_existing_db and !try Ops.existingStorePath(allocator, io, candidate)) {
                    if (remaining_default.len < min_rest) return error.MissingArgument;
                    if (looksLikeExplicitPath(candidate)) return error.FileNotFound;
                    return error.TooManyArguments;
                }
                return .{ .db_path = candidate, .rest = remaining_if_db };
            }
            if (remaining_default.len < min_rest) return error.MissingArgument;
            return error.TooManyArguments;
        }

        pub fn parseFreeText(
            allocator: std.mem.Allocator,
            io: std.Io,
            args: []const []const u8,
            start: usize,
            min_rest: usize,
        ) !ParsedFreeText {
            if (args.len <= start) return error.MissingArgument;

            const candidate = args[start];
            const remaining_if_db = if (args.len > start + 1) args[start + 1 ..] else &.{};
            if (try Ops.existingStorePath(allocator, io, candidate)) {
                if (remaining_if_db.len < min_rest) return error.MissingArgument;
                const owned = try allocator.dupe(u8, candidate);
                return .{ .db_path = owned, .rest = remaining_if_db, .owned_db_path = owned };
            }
            if (looksLikeExplicitPath(candidate)) return error.FileNotFound;

            const remaining_default = args[start..];
            if (remaining_default.len < min_rest) return error.MissingArgument;
            return .{ .db_path = Ops.defaultPath(), .rest = remaining_default };
        }

        fn looksLikeExplicitPath(value: []const u8) bool {
            if (std.mem.eql(u8, value, Ops.literalDefaultPath())) return true;
            return std.mem.indexOfScalar(u8, value, '/') != null or
                std.mem.indexOfScalar(u8, value, '\\') != null;
        }
    };
}

const TestOps = struct {
    var probe_count: usize = 0;
    var configured_default_path: []const u8 = ".tinykg";

    fn reset() void {
        probe_count = 0;
        configured_default_path = ".tinykg";
    }

    pub fn defaultPath() []const u8 {
        return configured_default_path;
    }

    pub fn literalDefaultPath() []const u8 {
        return ".tinykg";
    }

    pub fn existingStorePath(_: std.mem.Allocator, _: std.Io, path: []const u8) !bool {
        probe_count += 1;
        return std.mem.eql(u8, path, "existing.kg");
    }
};

const database_arguments = DatabaseArguments(TestOps);

test "database arguments prefer the default path for valid optional arguments" {
    TestOps.reset();

    const no_rest = try database_arguments.parse(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "governance" },
        2,
        0,
        0,
        true,
    );
    try std.testing.expectEqualStrings(".tinykg", no_rest.db_path);
    try std.testing.expectEqual(@as(usize, 0), no_rest.rest.len);

    const optional = try database_arguments.parse(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "neighbors", "1", "defines" },
        2,
        1,
        2,
        true,
    );
    try std.testing.expectEqualStrings(".tinykg", optional.db_path);
    try std.testing.expectEqualStrings("1", optional.rest[0]);
    try std.testing.expectEqualStrings("defines", optional.rest[1]);
    try std.testing.expectEqual(@as(usize, 1), TestOps.probe_count);
}

test "database arguments use an existing store to resolve fixed arity ambiguity" {
    TestOps.reset();

    const parsed = try database_arguments.parse(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "neighbors", "existing.kg", "1" },
        2,
        1,
        2,
        true,
    );
    try std.testing.expectEqualStrings("existing.kg", parsed.db_path);
    try std.testing.expectEqualStrings("1", parsed.rest[0]);
    try std.testing.expectEqual(@as(usize, 1), TestOps.probe_count);
}

test "database arguments reject missing explicit paths and invalid arity" {
    TestOps.reset();

    try std.testing.expectError(
        error.FileNotFound,
        database_arguments.parse(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "task-ready", "missing/store", "1" },
            2,
            1,
            1,
            true,
        ),
    );
    try std.testing.expectError(
        error.MissingArgument,
        database_arguments.parse(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "task-ready" },
            2,
            1,
            1,
            true,
        ),
    );
    try std.testing.expectError(
        error.TooManyArguments,
        database_arguments.parse(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "task-ready", "1", "extra" },
            2,
            1,
            1,
            true,
        ),
    );
    try std.testing.expectError(
        error.InvalidPlan,
        database_arguments.parse(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "task-ready", "1" },
            2,
            2,
            1,
            true,
        ),
    );

    TestOps.configured_default_path = "configured-store";
    try std.testing.expectError(
        error.FileNotFound,
        database_arguments.parse(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "task-ready", ".tinykg", "1" },
            2,
            1,
            1,
            true,
        ),
    );
}

test "free text database arguments preserve ownership and explicit path semantics" {
    TestOps.reset();

    var explicit = try database_arguments.parseFreeText(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "query", "existing.kg", "MATCH", "(n)" },
        2,
        1,
    );
    defer explicit.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("existing.kg", explicit.db_path);
    try std.testing.expect(explicit.owned_db_path != null);
    try std.testing.expectEqualStrings("MATCH", explicit.rest[0]);

    var implicit = try database_arguments.parseFreeText(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "query", "MATCH", "(n)" },
        2,
        1,
    );
    defer implicit.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(".tinykg", implicit.db_path);
    try std.testing.expectEqual(@as(?[]u8, null), implicit.owned_db_path);
    try std.testing.expectEqualStrings("MATCH", implicit.rest[0]);

    try std.testing.expectError(
        error.FileNotFound,
        database_arguments.parseFreeText(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "query", "missing/store", "MATCH" },
            2,
            1,
        ),
    );
    try std.testing.expectError(
        error.MissingArgument,
        database_arguments.parseFreeText(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "query", "existing.kg" },
            2,
            1,
        ),
    );
}
