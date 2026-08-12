const std = @import("std");

/// `schema-scope` command control plane.
///
/// Project resolution, current-generation lookup, policy persistence, direct
/// membership traversal, and Store representations stay behind `Ops`. This
/// owner keeps database admission, policy syntax, one locked context lifetime,
/// idempotent declaration, bounded violation publication, and cleanup in one
/// directly testable command boundary.
pub fn SchemaScopeCommand(comptime Ops: type) type {
    return struct {
        pub const Arguments = struct {
            db_path: []const u8,
            scope_type: []const u8,
            project_specs: std.ArrayList([]const u8),
            enforce_value: []const u8 = "report",
            if_absent: bool = false,

            pub fn deinit(self: *Arguments, allocator: std.mem.Allocator) void {
                self.project_specs.deinit(allocator);
                self.* = undefined;
            }
        };

        const ResolvedPolicy = struct {
            project_ids: std.ArrayList(u64) = .empty,
            projects_json: std.ArrayList(u8) = .empty,

            fn deinit(self: *ResolvedPolicy, allocator: std.mem.Allocator) void {
                self.projects_json.deinit(allocator);
                self.project_ids.deinit(allocator);
                self.* = undefined;
            }
        };

        fn resolvePolicy(
            context: anytype,
            allocator: std.mem.Allocator,
            project_specs: []const []const u8,
        ) !ResolvedPolicy {
            var result = ResolvedPolicy{};
            errdefer result.deinit(allocator);
            for (project_specs) |project_spec| {
                const project_id = try context.resolveProject(allocator, project_spec);
                var duplicate = false;
                for (result.project_ids.items) |existing_id| {
                    if (existing_id == project_id) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) try result.project_ids.append(allocator, project_id);
            }

            try result.projects_json.append(allocator, '[');
            for (result.project_ids.items, 0..) |project_id, index| {
                if (index > 0) try result.projects_json.append(allocator, ',');
                var number_buffer: [20]u8 = undefined;
                const number = std.fmt.bufPrint(
                    &number_buffer,
                    "{d}",
                    .{project_id},
                ) catch unreachable;
                try result.projects_json.appendSlice(allocator, number);
            }
            try result.projects_json.append(allocator, ']');
            return result;
        }

        pub fn parseArguments(
            allocator: std.mem.Allocator,
            io: std.Io,
            args: []const []const u8,
        ) !Arguments {
            const parsed = try Ops.parseDbArguments(allocator, io, args);
            if (parsed.rest.len < 1) return error.InvalidRecord;
            const scope_type = parsed.rest[0];
            if (std.mem.eql(u8, scope_type, "schema_scope") or
                std.mem.eql(u8, scope_type, "project")) return error.InvalidRecord;

            var result = Arguments{
                .db_path = parsed.db_path,
                .scope_type = scope_type,
                .project_specs = .empty,
            };
            errdefer result.deinit(allocator);

            var pos: usize = 1;
            while (pos < parsed.rest.len) : (pos += 1) {
                const option = parsed.rest[pos];
                if (std.mem.eql(u8, option, "--project")) {
                    pos += 1;
                    if (pos >= parsed.rest.len) return error.InvalidRecord;
                    var projects = std.mem.splitScalar(u8, parsed.rest[pos], ',');
                    while (projects.next()) |project| {
                        const trimmed = std.mem.trim(u8, project, " \t");
                        if (trimmed.len > 0) try result.project_specs.append(allocator, trimmed);
                    }
                } else if (std.mem.eql(u8, option, "--enforce")) {
                    pos += 1;
                    if (pos >= parsed.rest.len) return error.InvalidRecord;
                    const value = parsed.rest[pos];
                    if (!std.mem.eql(u8, value, "block") and
                        !std.mem.eql(u8, value, "report")) return error.InvalidRecord;
                    result.enforce_value = value;
                } else if (std.mem.eql(u8, option, "--if-absent")) {
                    result.if_absent = true;
                } else {
                    return error.InvalidRecord;
                }
            }
            if (result.project_specs.items.len == 0) return error.InvalidRecord;
            return result;
        }

        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            var parsed = try parseArguments(allocator, io, args);
            defer parsed.deinit(allocator);

            var context = try Ops.Context.init(allocator, io, parsed.db_path);
            defer context.deinit();

            if (parsed.if_absent) {
                if (try context.findExistingPolicy(allocator, parsed.scope_type)) |policy_id| {
                    try writer.print(
                        "schema_scope node={} created=0 type={s} unchanged=1\n",
                        .{ policy_id, parsed.scope_type },
                    );
                    return;
                }
            }

            var resolved = try resolvePolicy(
                &context,
                allocator,
                parsed.project_specs.items,
            );
            defer resolved.deinit(allocator);
            const declaration = try context.upsertPolicy(
                allocator,
                parsed.scope_type,
                resolved.projects_json.items,
                parsed.enforce_value,
            );
            try writer.print(
                "schema_scope node={} created={} type={s} projects={s} enforce={s}\n",
                .{
                    declaration.policy_id,
                    @intFromBool(declaration.created),
                    parsed.scope_type,
                    resolved.projects_json.items,
                    parsed.enforce_value,
                },
            );

            var cursor = try context.beginViolationScan(
                allocator,
                parsed.scope_type,
                resolved.project_ids.items,
            );
            defer cursor.deinit();
            var published_samples: usize = 0;
            while (try cursor.next()) |node_id| {
                if (published_samples >= 20) continue;
                try writer.print("  violation node={} not in scope\n", .{node_id});
                published_samples += 1;
            }
            const summary = cursor.summary();
            try writer.print(
                "schema_scope_violations={} dangling_projects={}\n",
                .{ summary.violations, summary.dangling_projects },
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
        const rendered = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(rendered);
        try self.buffer.appendSlice(self.allocator, rendered);
    }
};

const FailingWriter = struct {
    fn print(_: *FailingWriter, comptime _: []const u8, _: anytype) error{OutputClosed}!void {
        return error.OutputClosed;
    }
};

const TestOps = struct {
    const Step = enum {
        parse_db,
        open,
        find_existing,
        resolve_project,
        upsert,
        begin_scan,
        next,
        close_scan,
        close,
    };

    const ParsedDb = struct {
        db_path: []const u8,
        rest: []const []const u8,
    };

    var steps: [128]Step = undefined;
    var step_count: usize = 0;
    var fail_context = false;
    var fail_upsert = false;
    var fail_scan = false;
    var existing_policy = false;
    var created = true;
    var sample_count: usize = 2;
    var dangling_projects: u64 = 0;

    fn reset() void {
        step_count = 0;
        fail_context = false;
        fail_upsert = false;
        fail_scan = false;
        existing_policy = false;
        created = true;
        sample_count = 2;
        dangling_projects = 0;
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
    ) !ParsedDb {
        record(.parse_db);
        if (args.len < 2) return error.InvalidRecord;
        if (args.len > 2 and std.mem.eql(u8, args[2], "existing.kg")) {
            return .{ .db_path = args[2], .rest = args[3..] };
        }
        return .{ .db_path = ".tinykg", .rest = args[2..] };
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, _: []const u8) !Context {
            TestOps.record(.open);
            if (TestOps.fail_context) return error.InvalidRecord;
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.record(.close);
        }

        pub fn findExistingPolicy(
            _: *Context,
            _: std.mem.Allocator,
            _: []const u8,
        ) !?u64 {
            TestOps.record(.find_existing);
            return if (TestOps.existing_policy) 41 else null;
        }

        pub fn resolveProject(
            _: *Context,
            _: std.mem.Allocator,
            project_spec: []const u8,
        ) !u64 {
            TestOps.record(.resolve_project);
            if (std.mem.eql(u8, project_spec, "alpha")) return 7;
            if (std.mem.eql(u8, project_spec, "beta")) return 9;
            if (std.mem.eql(u8, project_spec, "gamma")) return 9;
            return std.fmt.parseInt(u64, project_spec, 10) catch error.NotFound;
        }

        pub fn upsertPolicy(
            _: *Context,
            _: std.mem.Allocator,
            _: []const u8,
            projects_json: []const u8,
            _: []const u8,
        ) !struct { policy_id: u64, created: bool } {
            TestOps.record(.upsert);
            if (TestOps.fail_upsert) return error.InvalidRecord;
            try std.testing.expect(
                std.mem.eql(u8, projects_json, "[7]") or
                    std.mem.eql(u8, projects_json, "[7,9]"),
            );
            return .{ .policy_id = 41, .created = TestOps.created };
        }

        pub fn beginViolationScan(
            _: *Context,
            _: std.mem.Allocator,
            _: []const u8,
            _: []const u64,
        ) !ViolationCursor {
            TestOps.record(.begin_scan);
            if (TestOps.fail_scan) return error.InvalidRecord;
            return .{};
        }
    };

    const ViolationCursor = struct {
        index: usize = 0,

        pub fn deinit(_: *ViolationCursor) void {
            TestOps.record(.close_scan);
        }

        pub fn next(self: *ViolationCursor) !?u64 {
            TestOps.record(.next);
            if (self.index >= TestOps.sample_count) return null;
            const result = 100 + self.index;
            self.index += 1;
            return result;
        }

        pub fn summary(_: *const ViolationCursor) struct {
            violations: u64,
            dangling_projects: u64,
        } {
            return .{
                .violations = @intCast(TestOps.sample_count),
                .dangling_projects = TestOps.dangling_projects,
            };
        }
    };
};

const test_command = SchemaScopeCommand(TestOps);

test "schema scope arguments preserve database projects enforcement and if absent" {
    TestOps.reset();
    var parsed = try test_command.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "schema-scope", "existing.kg", "migration", "--project", "alpha", "--enforce", "block", "--if-absent" },
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("existing.kg", parsed.db_path);
    try std.testing.expectEqualStrings("migration", parsed.scope_type);
    try std.testing.expectEqualStrings("block", parsed.enforce_value);
    try std.testing.expect(parsed.if_absent);
    try std.testing.expectEqual(@as(usize, 1), parsed.project_specs.items.len);
    try std.testing.expectEqualStrings("alpha", parsed.project_specs.items[0]);
}

test "schema scope arguments trim project lists and preserve repeated project options" {
    TestOps.reset();
    var parsed = try test_command.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{ "tinykg", "schema-scope", "migration", "--project", " alpha, 7 , ,beta ", "--project", "gamma", "--enforce", "report" },
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(".tinykg", parsed.db_path);
    try std.testing.expectEqual(@as(usize, 4), parsed.project_specs.items.len);
    try std.testing.expectEqualStrings("alpha", parsed.project_specs.items[0]);
    try std.testing.expectEqualStrings("7", parsed.project_specs.items[1]);
    try std.testing.expectEqualStrings("beta", parsed.project_specs.items[2]);
    try std.testing.expectEqualStrings("gamma", parsed.project_specs.items[3]);
    try std.testing.expectEqualStrings("report", parsed.enforce_value);
}

test "schema scope arguments reject missing reserved invalid and unknown values before context" {
    const cases = [_][]const []const u8{
        &.{ "tinykg", "schema-scope" },
        &.{ "tinykg", "schema-scope", "schema_scope", "--project", "alpha" },
        &.{ "tinykg", "schema-scope", "project", "--project", "alpha" },
        &.{ "tinykg", "schema-scope", "migration", "--project" },
        &.{ "tinykg", "schema-scope", "migration", "--project", " , " },
        &.{ "tinykg", "schema-scope", "migration", "--project", "alpha", "--enforce" },
        &.{ "tinykg", "schema-scope", "migration", "--project", "alpha", "--enforce", "warn" },
        &.{ "tinykg", "schema-scope", "migration", "--project", "alpha", "--unknown" },
    };
    for (cases) |args| {
        TestOps.reset();
        var writer = TestWriter{ .allocator = std.testing.allocator };
        defer writer.deinit();
        try std.testing.expectError(
            error.InvalidRecord,
            test_command.run(args, &writer, std.testing.allocator, std.testing.io),
        );
        try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
        try TestOps.expectSteps(&.{.parse_db});
    }
}

test "schema scope command publishes changed policy and bounded violations in order" {
    TestOps.reset();
    TestOps.created = false;
    TestOps.sample_count = 25;
    TestOps.dangling_projects = 2;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_command.run(
        &.{ "tinykg", "schema-scope", "migration", "--project", "alpha,beta", "--enforce", "block" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        writer.buffer.items,
        "schema_scope node=41 created=0 type=migration projects=[7,9] enforce=block\n  violation node=100 not in scope\n",
    ));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffer.items, "violation node=119 not in scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffer.items, "violation node=120 not in scope") == null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        writer.buffer.items,
        "schema_scope_violations=25 dangling_projects=2\n",
    ));
    try std.testing.expectEqual(TestOps.Step.parse_db, TestOps.steps[0]);
    try std.testing.expectEqual(TestOps.Step.open, TestOps.steps[1]);
    try std.testing.expectEqual(TestOps.Step.resolve_project, TestOps.steps[2]);
    try std.testing.expectEqual(TestOps.Step.resolve_project, TestOps.steps[3]);
    try std.testing.expectEqual(TestOps.Step.upsert, TestOps.steps[4]);
    try std.testing.expectEqual(TestOps.Step.begin_scan, TestOps.steps[5]);
    var next_steps: usize = 0;
    for (TestOps.steps[0..TestOps.step_count]) |step| {
        if (step == .next) next_steps += 1;
    }
    try std.testing.expectEqual(@as(usize, 26), next_steps);
    try std.testing.expectEqualSlices(
        TestOps.Step,
        &.{ .close_scan, .close },
        TestOps.steps[TestOps.step_count - 2 .. TestOps.step_count],
    );
}

test "schema scope command publishes unchanged policy without violation summary" {
    TestOps.reset();
    TestOps.existing_policy = true;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_command.run(
        &.{ "tinykg", "schema-scope", "migration", "--project", "alpha", "--if-absent" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings(
        "schema_scope node=41 created=0 type=migration unchanged=1\n",
        writer.buffer.items,
    );
    try TestOps.expectSteps(&.{ .parse_db, .open, .find_existing, .close });
}

test "schema scope context and execution failures publish no output" {
    TestOps.reset();
    TestOps.fail_context = true;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try std.testing.expectError(
        error.InvalidRecord,
        test_command.run(
            &.{ "tinykg", "schema-scope", "migration", "--project", "alpha" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
    try TestOps.expectSteps(&.{ .parse_db, .open });

    TestOps.reset();
    TestOps.fail_upsert = true;
    try std.testing.expectError(
        error.InvalidRecord,
        test_command.run(
            &.{ "tinykg", "schema-scope", "migration", "--project", "alpha" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
    try TestOps.expectSteps(&.{ .parse_db, .open, .resolve_project, .upsert, .close });
}

test "schema scope command failures close context and release arguments" {
    TestOps.reset();
    TestOps.fail_scan = true;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try std.testing.expectError(
        error.InvalidRecord,
        test_command.run(
            &.{ "tinykg", "schema-scope", "migration", "--project", "alpha,beta" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqualStrings(
        "schema_scope node=41 created=1 type=migration projects=[7,9] enforce=report\n",
        writer.buffer.items,
    );
    try TestOps.expectSteps(&.{ .parse_db, .open, .resolve_project, .resolve_project, .upsert, .begin_scan, .close });
}

test "schema scope writer failures close context after successful execution" {
    TestOps.reset();
    var writer = FailingWriter{};
    try std.testing.expectError(
        error.OutputClosed,
        test_command.run(
            &.{ "tinykg", "schema-scope", "migration", "--project", "alpha" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse_db, .open, .resolve_project, .upsert, .close });
}
