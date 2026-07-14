//! Session-scoped goal state.
//!
//! A goal is one persisted objective for the current session. This is deliberately
//! smaller than Codex's app-server thread goal system, but keeps the same core
//! invariants that matter for cc-zig: one goal per session, versioned updates,
//! explicit status transitions, and secret-free JSON persistence.

const std = @import("std");
const pfs = @import("platform").fs;
const session_id = @import("session_id.zig");
const time = @import("../util/time.zig");

pub const Status = enum {
    active,
    paused,
    blocked,
    usage_limited,
    budget_limited,
    complete,

    pub fn parse(s: []const u8) ?Status {
        inline for (@typeInfo(Status).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(Status, f.name);
        }
        return null;
    }

    pub fn isTerminal(self: Status) bool {
        return switch (self) {
            .blocked, .usage_limited, .budget_limited, .complete => true,
            .active, .paused => false,
        };
    }
};

pub const Goal = struct {
    id: [24]u8,
    objective: []u8,
    status: Status,
    token_budget: ?u64 = null,
    tokens_used: u64 = 0,
    time_used_ms: u64 = 0,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn deinit(self: *Goal, allocator: std.mem.Allocator) void {
        allocator.free(self.objective);
        self.* = undefined;
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    current: ?Goal = null,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        self.clearInMemory();
    }

    pub fn clearInMemory(self: *State) void {
        if (self.current) |*g| g.deinit(self.allocator);
        self.current = null;
    }

    pub fn setNew(self: *State, objective_raw: []const u8, token_budget: ?u64) !void {
        const objective = std.mem.trim(u8, objective_raw, " \t\r\n");
        if (objective.len == 0) return error.EmptyObjective;
        if (token_budget) |v| {
            if (v == 0) return error.InvalidBudget;
        }
        self.clearInMemory();
        const now = nowWallMs();
        const id = session_id.gen();
        self.current = .{
            .id = id.bytes,
            .objective = try self.allocator.dupe(u8, objective),
            .status = .active,
            .token_budget = token_budget,
            .created_at_ms = now,
            .updated_at_ms = now,
        };
    }

    pub fn editObjective(self: *State, objective_raw: []const u8) !void {
        const objective = std.mem.trim(u8, objective_raw, " \t\r\n");
        if (objective.len == 0) return error.EmptyObjective;
        if (self.current == null) return error.NoGoal;
        const dup = try self.allocator.dupe(u8, objective);
        errdefer self.allocator.free(dup);
        self.allocator.free(self.current.?.objective);
        self.current.?.objective = dup;
        self.touch();
    }

    pub fn setStatus(self: *State, status: Status) !void {
        if (self.current == null) return error.NoGoal;
        self.current.?.status = status;
        self.touch();
    }

    pub fn setBudget(self: *State, token_budget: ?u64) !void {
        if (self.current == null) return error.NoGoal;
        if (token_budget) |v| {
            if (v == 0) return error.InvalidBudget;
        }
        self.current.?.token_budget = token_budget;
        if (self.current.?.status == .budget_limited and
            (token_budget == null or self.current.?.tokens_used < token_budget.?))
        {
            self.current.?.status = .active;
        }
        self.touch();
    }

    pub fn accountTokens(self: *State, delta: u64, expected_id: ?[]const u8) !void {
        try self.accountProgress(delta, 0, expected_id);
    }

    pub fn accountProgress(self: *State, token_delta: u64, time_delta_ms: u64, expected_id: ?[]const u8) !void {
        if (token_delta == 0 and time_delta_ms == 0) return;
        if (self.current == null) return error.NoGoal;
        if (expected_id) |id| {
            if (!std.mem.eql(u8, self.current.?.id[0..], id)) return;
        }
        if (self.current.?.status != .active) return;
        self.current.?.tokens_used +|= token_delta;
        self.current.?.time_used_ms +|= time_delta_ms;
        if (self.current.?.token_budget) |budget| {
            if (self.current.?.tokens_used >= budget) self.current.?.status = .budget_limited;
        }
        self.touch();
    }

    pub fn loadFromDir(self: *State, session_dir: []const u8) !void {
        const path = try goalPath(self.allocator, session_dir);
        defer self.allocator.free(path);
        const content = try readFileAlloc(self.allocator, path);
        defer self.allocator.free(content);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();
        const g = try parseGoal(self.allocator, parsed.value);
        self.clearInMemory();
        self.current = g;
    }

    pub fn persistToDir(self: *const State, session_dir: []const u8) !void {
        const path = try goalPath(self.allocator, session_dir);
        defer self.allocator.free(path);
        if (self.current == null) {
            const path_z = try self.allocator.dupeZ(u8, path);
            defer self.allocator.free(path_z);
            _ = std.c.unlink(path_z.ptr);
            return;
        }
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp);
        const tmp_z = try self.allocator.dupeZ(u8, tmp);
        defer self.allocator.free(tmp_z);
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const bytes = try serializeGoal(self.allocator, self.current.?);
        defer self.allocator.free(bytes);
        const fd = pfs.open(tmp_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.OpenFailed;
        defer _ = pfs.close(fd);
        const n = pfs.write(fd, bytes);
        if (n < 0 or @as(usize, @intCast(n)) != bytes.len) return error.WriteFailed;
        if (std.c.rename(tmp_z.ptr, path_z.ptr) != 0) return error.RenameFailed;
    }

    fn touch(self: *State) void {
        self.current.?.updated_at_ms = nowWallMs();
    }
};

pub fn goalPath(allocator: std.mem.Allocator, session_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/goal.json", .{session_dir});
}

fn serializeGoal(allocator: std.mem.Allocator, goal: Goal) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"id\":");
    try std.json.Stringify.encodeJsonString(goal.id[0..], .{}, &aw.writer);
    try aw.writer.writeAll(",\"objective\":");
    try std.json.Stringify.encodeJsonString(goal.objective, .{}, &aw.writer);
    try aw.writer.print(",\"status\":\"{s}\"", .{@tagName(goal.status)});
    if (goal.token_budget) |b| {
        try aw.writer.print(",\"token_budget\":{d}", .{b});
    } else {
        try aw.writer.writeAll(",\"token_budget\":null");
    }
    try aw.writer.print(
        ",\"tokens_used\":{d},\"time_used_ms\":{d},\"created_at_ms\":{d},\"updated_at_ms\":{d}}}\n",
        .{ goal.tokens_used, goal.time_used_ms, goal.created_at_ms, goal.updated_at_ms },
    );
    return try aw.toOwnedSlice();
}

fn parseGoal(allocator: std.mem.Allocator, value: std.json.Value) !Goal {
    if (value != .object) return error.InvalidGoal;
    const obj = value.object;
    const id_s = try getString(obj, "id");
    if (id_s.len != 24) return error.InvalidGoal;
    var id: [24]u8 = undefined;
    @memcpy(id[0..], id_s);
    const status = Status.parse(try getString(obj, "status")) orelse return error.InvalidGoal;
    const objective = try allocator.dupe(u8, try getString(obj, "objective"));
    errdefer allocator.free(objective);
    return .{
        .id = id,
        .objective = objective,
        .status = status,
        .token_budget = try getOptionalU64(obj, "token_budget"),
        .tokens_used = try getU64(obj, "tokens_used"),
        .time_used_ms = try getU64(obj, "time_used_ms"),
        .created_at_ms = try getI64(obj, "created_at_ms"),
        .updated_at_ms = try getI64(obj, "updated_at_ms"),
    };
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = obj.get(key) orelse return error.InvalidGoal;
    if (v != .string) return error.InvalidGoal;
    return v.string;
}

fn getU64(obj: std.json.ObjectMap, key: []const u8) !u64 {
    const v = obj.get(key) orelse return error.InvalidGoal;
    if (v != .integer) return error.InvalidGoal;
    if (v.integer < 0) return error.InvalidGoal;
    return @intCast(v.integer);
}

fn getI64(obj: std.json.ObjectMap, key: []const u8) !i64 {
    const v = obj.get(key) orelse return error.InvalidGoal;
    if (v != .integer) return error.InvalidGoal;
    return @intCast(v.integer);
}

fn getOptionalU64(obj: std.json.ObjectMap, key: []const u8) !?u64 {
    const v = obj.get(key) orelse return null;
    if (v == .null) return null;
    if (v != .integer or v.integer <= 0) return error.InvalidGoal;
    return @intCast(v.integer);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.NotFound;
    defer _ = pfs.close(fd);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buf);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
        if (out.items.len > 1024 * 1024) return error.FileTooLarge;
    }
    return try out.toOwnedSlice(allocator);
}

fn nowWallMs() i64 {
    return @intCast(@divTrunc(time.nowWallNs(), std.time.ns_per_ms));
}

test "goal state set/edit/status/budget/account" {
    const a = std.testing.allocator;
    var st = State.init(a);
    defer st.deinit();
    try std.testing.expectError(error.InvalidBudget, st.setNew("bad budget", 0));
    try st.setNew(" ship it ", 10);
    try std.testing.expectEqual(Status.active, st.current.?.status);
    try std.testing.expectEqualStrings("ship it", st.current.?.objective);
    try st.accountProgress(11, 250, st.current.?.id[0..]);
    try std.testing.expectEqual(@as(u64, 250), st.current.?.time_used_ms);
    try std.testing.expectEqual(Status.budget_limited, st.current.?.status);
    try st.setBudget(20);
    try std.testing.expectEqual(Status.active, st.current.?.status);
    try st.editObjective("ship it safely");
    try std.testing.expectEqualStrings("ship it safely", st.current.?.objective);
    try st.setStatus(.complete);
    try std.testing.expect(st.current.?.status.isTerminal());
}

test "goal state persist/load roundtrip" {
    const a = std.testing.allocator;
    const dir = "/tmp/cc-zig-goal-test";
    ensureTestDir(dir) catch {};
    var st = State.init(a);
    defer st.deinit();
    try st.setNew("round trip", 123);
    try st.accountTokens(7, null);
    try st.persistToDir(dir);

    var loaded = State.init(a);
    defer loaded.deinit();
    try loaded.loadFromDir(dir);
    try std.testing.expectEqualStrings(st.current.?.id[0..], loaded.current.?.id[0..]);
    try std.testing.expectEqualStrings("round trip", loaded.current.?.objective);
    try std.testing.expectEqual(@as(u64, 123), loaded.current.?.token_budget.?);
    try std.testing.expectEqual(@as(u64, 7), loaded.current.?.tokens_used);

    loaded.clearInMemory();
    try loaded.persistToDir(dir);
    try std.testing.expectError(error.NotFound, loaded.loadFromDir(dir));
}

fn ensureTestDir(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    if (std.c.mkdir(@ptrCast(&buf), 0o700) != 0) {
        const e: std.c.E = @enumFromInt(std.c._errno().*);
        if (e != .EXIST) return error.MkdirFailed;
    }
}
