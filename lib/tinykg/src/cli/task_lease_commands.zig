const std = @import("std");
const task_mutation_arguments_mod = @import("task_mutation_arguments.zig");

const Arguments = task_mutation_arguments_mod.TaskMutationArguments;

/// Task lease control plane for `task-claim` and `task-release`.
///
/// `cli.zig` retains concrete store, lock, node, and property types behind
/// `Ops.Context`. This owner controls lease conflict policy, authority
/// symmetry, TTL arithmetic, minimal release publication, and stable output.
pub fn TaskLeaseCommands(comptime Ops: type) type {
    return struct {
        pub fn runClaim(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 3, 6);
            const parsed = try Arguments.parseClaim(db.rest, Ops.defaultClaimTtlSeconds());
            const task_id = try Ops.parseTaskId(parsed.task_id);

            var context = try Ops.Context.init(allocator, io, db.db_path);
            defer context.deinit();

            // Preserve the command contract: claim identity is validated only
            // after the target store has been opened under the CLI lock.
            const agent_name = try Ops.validateTaskLeaseAgentIdentity(parsed.by orelse return error.MissingArgument);
            var inspection = try context.inspectClaim(allocator, task_id);
            defer inspection.deinit(allocator);

            const held_by_other = inspection.holder != null and inspection.holder.?.len > 0 and
                inspection.expires_ns > inspection.now_ns and
                !std.mem.eql(u8, inspection.holder.?, agent_name);
            if (held_by_other and !parsed.steal) {
                try writer.print("task_claim_held\t{}\tby=", .{Ops.taskIdValue(task_id)});
                try Ops.writeTaskLeaseEscapedText(writer, inspection.holder.?);
                try writer.print("\texpires_ns={}\n", .{inspection.expires_ns});
                return error.ClaimHeld;
            }

            const ttl_ns = std.math.mul(u64, parsed.ttl_s, std.time.ns_per_s) catch return error.InvalidLimit;
            const expires_ns = std.math.add(u64, inspection.now_ns, ttl_ns) catch return error.InvalidLimit;
            try context.publishClaim(allocator, task_id, agent_name, expires_ns, expires_ns > inspection.now_ns);
            try writer.print("task_claimed\t{}\tby=", .{Ops.taskIdValue(task_id)});
            try Ops.writeTaskLeaseEscapedText(writer, agent_name);
            try writer.print("\texpires_ns={}\n", .{expires_ns});
        }

        pub fn runRelease(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 1, 4);
            const parsed = try Arguments.parseRelease(db.rest);
            // Release historically validates authority before parsing the id
            // or opening the store; keep that observable error ordering.
            const release_by = if (parsed.by) |identity| try Ops.validateTaskLeaseAgentIdentity(identity) else null;
            const task_id = try Ops.parseTaskId(parsed.task_id);

            var context = try Ops.Context.init(allocator, io, db.db_path);
            defer context.deinit();
            var inspection = try context.inspectRelease(allocator, task_id);
            defer inspection.deinit(allocator);

            const lease_live = inspection.holder != null and inspection.holder.?.len > 0 and
                inspection.expires_ns > inspection.now_ns;
            if (lease_live and !parsed.force) {
                const by_matches = if (release_by) |by| std.mem.eql(u8, by, inspection.holder.?) else false;
                if (!by_matches) {
                    try writer.print("task_release_held\t{}\tby=", .{Ops.taskIdValue(task_id)});
                    try Ops.writeTaskLeaseEscapedText(writer, inspection.holder.?);
                    try writer.print("\texpires_ns={}\n", .{inspection.expires_ns});
                    return error.ClaimHeld;
                }
            }

            const expire_lease = inspection.expires_ns != 0;
            const set_open = !inspection.terminal and !inspection.status_is_open;
            const property_publish_count = try context.publishRelease(
                allocator,
                task_id,
                expire_lease,
                set_open,
            );
            try writer.print(
                "task_released\t{}\tproperty_publishes={}\n",
                .{ Ops.taskIdValue(task_id), property_publish_count },
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
    var opened: usize = 0;
    var deinitialized: usize = 0;
    var claim_published: usize = 0;
    var claim_agent: []const u8 = "";
    var claim_expires_ns: u64 = 0;
    var claim_status: bool = false;
    var holder: ?[]const u8 = null;
    var now_ns: u64 = 1_000;
    var expires_ns: u64 = 0;
    var terminal: bool = false;
    var status_is_open: bool = true;
    var release_expire: bool = false;
    var release_set_open: bool = false;
    var release_calls: usize = 0;
    var inspection_error: ?anyerror = null;

    fn reset() void {
        opened = 0;
        deinitialized = 0;
        claim_published = 0;
        claim_agent = "";
        claim_expires_ns = 0;
        claim_status = false;
        holder = null;
        now_ns = 1_000;
        expires_ns = 0;
        terminal = false;
        status_is_open = true;
        release_expire = false;
        release_set_open = false;
        release_calls = 0;
        inspection_error = null;
    }

    pub fn parseDbArguments(
        _: std.mem.Allocator,
        _: std.Io,
        args: []const []const u8,
        _: usize,
        _: usize,
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        if (args.len < 2) return error.MissingArgument;
        return .{ .db_path = "db", .rest = args[2..] };
    }

    pub fn defaultClaimTtlSeconds() u64 {
        return 7_200;
    }

    pub fn parseTaskId(value: []const u8) !u64 {
        const id = std.fmt.parseInt(u64, value, 10) catch return error.InvalidId;
        if (id == 0) return error.InvalidId;
        return id;
    }

    pub fn taskIdValue(task_id: u64) u64 {
        return task_id;
    }

    pub fn validateTaskLeaseAgentIdentity(identity: []const u8) ![]const u8 {
        if (identity.len == 0 or std.mem.eql(u8, identity, "invalid")) return error.InvalidArgument;
        return identity;
    }

    pub fn writeTaskLeaseEscapedText(writer: anytype, value: []const u8) !void {
        try writer.writeAll(value);
    }

    const ClaimInspection = struct {
        holder: ?[]const u8,
        now_ns: u64,
        expires_ns: u64,

        pub fn deinit(_: *ClaimInspection, _: std.mem.Allocator) void {}
    };

    const ReleaseInspection = struct {
        holder: ?[]const u8,
        now_ns: u64,
        expires_ns: u64,
        terminal: bool,
        status_is_open: bool,

        pub fn deinit(_: *ReleaseInspection, _: std.mem.Allocator) void {}
    };

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, _: []const u8) !Context {
            TestOps.opened += 1;
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.deinitialized += 1;
        }

        pub fn inspectClaim(_: *Context, _: std.mem.Allocator, _: u64) !ClaimInspection {
            if (TestOps.inspection_error) |err| return err;
            return .{
                .holder = TestOps.holder,
                .now_ns = TestOps.now_ns,
                .expires_ns = TestOps.expires_ns,
            };
        }

        pub fn publishClaim(
            _: *Context,
            _: std.mem.Allocator,
            _: u64,
            agent_name: []const u8,
            published_expires_ns: u64,
            claimed: bool,
        ) !void {
            TestOps.claim_published += 1;
            TestOps.claim_agent = agent_name;
            TestOps.claim_expires_ns = published_expires_ns;
            TestOps.claim_status = claimed;
        }

        pub fn inspectRelease(_: *Context, _: std.mem.Allocator, _: u64) !ReleaseInspection {
            if (TestOps.inspection_error) |err| return err;
            return .{
                .holder = TestOps.holder,
                .now_ns = TestOps.now_ns,
                .expires_ns = TestOps.expires_ns,
                .terminal = TestOps.terminal,
                .status_is_open = TestOps.status_is_open,
            };
        }

        pub fn publishRelease(
            _: *Context,
            _: std.mem.Allocator,
            _: u64,
            expire_lease: bool,
            set_open: bool,
        ) !usize {
            TestOps.release_calls += 1;
            TestOps.release_expire = expire_lease;
            TestOps.release_set_open = set_open;
            return @intFromBool(expire_lease or set_open);
        }
    };
};

const task_lease_commands = TaskLeaseCommands(TestOps);

test "task lease claim publishes one validated transition" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try task_lease_commands.runClaim(
        &.{ "tinykg", "task-claim", "7", "--by", "agent-a", "--ttl-s", "2" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqual(@as(usize, 1), TestOps.claim_published);
    try std.testing.expectEqualStrings("agent-a", TestOps.claim_agent);
    try std.testing.expectEqual(@as(u64, 2_000_001_000), TestOps.claim_expires_ns);
    try std.testing.expect(TestOps.claim_status);
    try std.testing.expectEqual(@as(usize, 1), TestOps.opened);
    try std.testing.expectEqual(@as(usize, 1), TestOps.deinitialized);
    try std.testing.expectEqualStrings(
        "task_claimed\t7\tby=agent-a\texpires_ns=2000001000\n",
        writer.buffer.items,
    );
}

test "task lease claim reports holder conflict and permits explicit steal" {
    TestOps.reset();
    TestOps.holder = "agent-a";
    TestOps.expires_ns = 9_000;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.ClaimHeld,
        task_lease_commands.runClaim(
            &.{ "tinykg", "task-claim", "7", "--by", "agent-b" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), TestOps.claim_published);
    try std.testing.expectEqualStrings(
        "task_claim_held\t7\tby=agent-a\texpires_ns=9000\n",
        writer.buffer.items,
    );

    writer.buffer.clearRetainingCapacity();
    try task_lease_commands.runClaim(
        &.{ "tinykg", "task-claim", "7", "--by", "agent-b", "--steal" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqual(@as(usize, 1), TestOps.claim_published);
    try std.testing.expectEqualStrings("agent-b", TestOps.claim_agent);
}

test "task lease release enforces live holder authority" {
    TestOps.reset();
    TestOps.holder = "agent-a";
    TestOps.expires_ns = 9_000;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.ClaimHeld,
        task_lease_commands.runRelease(
            &.{ "tinykg", "task-release", "7", "--by", "agent-b" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), TestOps.release_calls);
    try std.testing.expectEqualStrings(
        "task_release_held\t7\tby=agent-a\texpires_ns=9000\n",
        writer.buffer.items,
    );

    writer.buffer.clearRetainingCapacity();
    try task_lease_commands.runRelease(
        &.{ "tinykg", "task-release", "7", "--by", "agent-b", "--force" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqual(@as(usize, 1), TestOps.release_calls);
    try std.testing.expect(TestOps.release_expire);
    try std.testing.expect(!TestOps.release_set_open);
}

test "task lease release chooses the minimal lifecycle property batch" {
    TestOps.reset();
    TestOps.status_is_open = false;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try task_lease_commands.runRelease(
        &.{ "tinykg", "task-release", "7" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expect(!TestOps.release_expire);
    try std.testing.expect(TestOps.release_set_open);
    try std.testing.expectEqualStrings("task_released\t7\tproperty_publishes=1\n", writer.buffer.items);

    writer.buffer.clearRetainingCapacity();
    TestOps.expires_ns = 2_000;
    try task_lease_commands.runRelease(
        &.{ "tinykg", "task-release", "7" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expect(TestOps.release_expire);
    try std.testing.expect(TestOps.release_set_open);

    writer.buffer.clearRetainingCapacity();
    TestOps.terminal = true;
    try task_lease_commands.runRelease(
        &.{ "tinykg", "task-release", "7" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expect(TestOps.release_expire);
    try std.testing.expect(!TestOps.release_set_open);

    writer.buffer.clearRetainingCapacity();
    TestOps.expires_ns = 0;
    try task_lease_commands.runRelease(
        &.{ "tinykg", "task-release", "7" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expect(!TestOps.release_expire);
    try std.testing.expect(!TestOps.release_set_open);
    try std.testing.expectEqualStrings("task_released\t7\tproperty_publishes=0\n", writer.buffer.items);
}

test "task lease context closes after inspection failure" {
    TestOps.reset();
    TestOps.inspection_error = error.InvalidRecord;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRecord,
        task_lease_commands.runClaim(
            &.{ "tinykg", "task-claim", "7", "--by", "agent-a" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), TestOps.opened);
    try std.testing.expectEqual(@as(usize, 1), TestOps.deinitialized);
    try std.testing.expectEqual(@as(usize, 0), TestOps.claim_published);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}
