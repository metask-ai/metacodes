//! Canonical immutable per-Session availability over a Skill catalog.
//!
//! Discovery remains entirely in `catalog.zig`. A Selection owns only the
//! effective enabled state aligned to one exact immutable Snapshot; disabled
//! records therefore remain visible in the catalog descriptor.

const std = @import("std");
const catalog = @import("catalog.zig");

pub const State = enum(u8) {
    disabled,
    enabled,
};

pub const Exception = struct {
    skill_id: []const u8,
    state: State,
};

pub const Spec = struct {
    default_state: State,
    exceptions: []const Exception,
};

pub const Error = error{
    OutOfMemory,
    ResourceLimit,
    InvalidSkillId,
    DuplicateSkillId,
    ForeignSkillId,
};

pub const Selection = struct {
    allocator: std.mem.Allocator,
    snapshot: *const catalog.Snapshot,
    states: []State,

    pub fn init(
        allocator: std.mem.Allocator,
        snapshot: *const catalog.Snapshot,
        spec: Spec,
    ) Error!Selection {
        if (spec.exceptions.len > snapshot.skills.len)
            return error.ResourceLimit;
        const states = allocator.alloc(State, snapshot.skills.len) catch
            return error.OutOfMemory;
        errdefer allocator.free(states);
        @memset(states, spec.default_state);

        const seen = allocator.alloc(bool, snapshot.skills.len) catch
            return error.OutOfMemory;
        defer allocator.free(seen);
        @memset(seen, false);

        for (spec.exceptions) |exception| {
            if (!catalog.isLowerHex64(exception.skill_id))
                return error.InvalidSkillId;
            const index = findIndex(snapshot, exception.skill_id) orelse
                return error.ForeignSkillId;
            if (seen[index]) return error.DuplicateSkillId;
            seen[index] = true;
            states[index] = exception.state;
        }
        return .{
            .allocator = allocator,
            .snapshot = snapshot,
            .states = states,
        };
    }

    pub fn deinit(self: *Selection) void {
        self.allocator.free(self.states);
        self.* = undefined;
    }

    pub fn isEnabled(
        self: *const Selection,
        snapshot: *const catalog.Snapshot,
        skill: *const catalog.SkillRecord,
    ) bool {
        if (self.snapshot != snapshot or self.states.len != snapshot.skills.len)
            return false;
        for (snapshot.skills, 0..) |*candidate, index| {
            if (candidate == skill) return self.states[index] == .enabled;
        }
        return false;
    }

    pub fn isEnabledAt(
        self: *const Selection,
        snapshot: *const catalog.Snapshot,
        index: usize,
    ) bool {
        if (self.snapshot != snapshot or
            self.states.len != snapshot.skills.len or
            index >= snapshot.skills.len)
            return false;
        return self.states[index] == .enabled;
    }
};

/// Explicit availability view for shared Runtime callers. `.all` is for
/// products without Session selection; AgentCore always supplies `.selected`.
pub const View = union(enum) {
    all,
    selected: *const Selection,

    pub fn isEnabled(
        self: View,
        snapshot: *const catalog.Snapshot,
        skill: *const catalog.SkillRecord,
    ) bool {
        return switch (self) {
            .all => containsRecord(snapshot, skill),
            .selected => |selection| selection.isEnabled(snapshot, skill),
        };
    }

    pub fn isEnabledAt(
        self: View,
        snapshot: *const catalog.Snapshot,
        index: usize,
    ) bool {
        return switch (self) {
            .all => index < snapshot.skills.len,
            .selected => |selection| selection.isEnabledAt(snapshot, index),
        };
    }
};

fn findIndex(snapshot: *const catalog.Snapshot, skill_id: []const u8) ?usize {
    for (snapshot.skills, 0..) |*skill, index| {
        if (std.mem.eql(u8, &skill.skill_id, skill_id)) return index;
    }
    return null;
}

fn containsRecord(
    snapshot: *const catalog.Snapshot,
    skill: *const catalog.SkillRecord,
) bool {
    for (snapshot.skills) |*candidate| {
        if (candidate == skill) return true;
    }
    return false;
}

fn testSnapshot(records: []const catalog.SkillRecord) catalog.Snapshot {
    return .{
        .owner_allocator = std.testing.allocator,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .scope_id = [_]u8{'a'} ** 64,
        .revision = [_]u8{'b'} ** 64,
        .health = .healthy,
        .skills = records,
        .issues = &.{},
        .descriptor_json = "",
        .snapshot_bytes = 0,
        .resident_bytes = 0,
    };
}

fn testRecord(id: u8, name: []const u8) catalog.SkillRecord {
    return .{
        .skill_id = [_]u8{id} ** 64,
        .invocation_name = name,
        .definition = .{
            .name = name,
            .description = name,
            .body = name,
            .allowed_tools = &.{},
            .disallowed_tools = &.{},
            .arguments = &.{},
            .disable_model_invocation = false,
            .context = .inline_ctx,
            .agent = "",
            .model = "",
            .shell = "bash",
            .source_path = "",
        },
        .directories = &.{},
        .files = &.{},
    };
}

test "Skill Selection applies explicit defaults and exceptions" {
    const records = [_]catalog.SkillRecord{
        testRecord('1', "one"),
        testRecord('2', "two"),
        testRecord('3', "three"),
    };
    var snapshot = testSnapshot(&records);
    defer snapshot.arena.deinit();
    const exceptions = [_]Exception{
        .{ .skill_id = &records[1].skill_id, .state = .disabled },
    };
    var selection = try Selection.init(std.testing.allocator, &snapshot, .{
        .default_state = .enabled,
        .exceptions = &exceptions,
    });
    defer selection.deinit();

    try std.testing.expect(selection.isEnabled(&snapshot, &records[0]));
    try std.testing.expect(!selection.isEnabled(&snapshot, &records[1]));
    try std.testing.expect(selection.isEnabled(&snapshot, &records[2]));
}

test "Skill Selection rejects duplicate malformed and foreign IDs atomically" {
    const records = [_]catalog.SkillRecord{
        testRecord('1', "one"),
        testRecord('2', "two"),
    };
    var snapshot = testSnapshot(&records);
    defer snapshot.arena.deinit();

    const duplicate = [_]Exception{
        .{ .skill_id = &records[0].skill_id, .state = .disabled },
        .{ .skill_id = &records[0].skill_id, .state = .enabled },
    };
    try std.testing.expectError(error.DuplicateSkillId, Selection.init(
        std.testing.allocator,
        &snapshot,
        .{ .default_state = .enabled, .exceptions = &duplicate },
    ));
    const malformed = [_]Exception{
        .{ .skill_id = "not-a-skill-id", .state = .disabled },
    };
    try std.testing.expectError(error.InvalidSkillId, Selection.init(
        std.testing.allocator,
        &snapshot,
        .{ .default_state = .enabled, .exceptions = &malformed },
    ));
    const foreign_id = [_]u8{'f'} ** 64;
    const foreign = [_]Exception{
        .{ .skill_id = &foreign_id, .state = .disabled },
    };
    try std.testing.expectError(error.ForeignSkillId, Selection.init(
        std.testing.allocator,
        &snapshot,
        .{ .default_state = .enabled, .exceptions = &foreign },
    ));
}

test "Skill Selection fails closed for another snapshot" {
    const records = [_]catalog.SkillRecord{testRecord('1', "one")};
    var snapshot = testSnapshot(&records);
    defer snapshot.arena.deinit();
    var other = testSnapshot(&records);
    defer other.arena.deinit();
    var selection = try Selection.init(std.testing.allocator, &snapshot, .{
        .default_state = .enabled,
        .exceptions = &.{},
    });
    defer selection.deinit();

    try std.testing.expect(selection.isEnabled(&snapshot, &records[0]));
    try std.testing.expect(!selection.isEnabled(&other, &records[0]));
}

test "Skill Selection reports allocation failure without publishing state" {
    const records = [_]catalog.SkillRecord{testRecord('1', "one")};
    var snapshot = testSnapshot(&records);
    defer snapshot.arena.deinit();
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(error.OutOfMemory, Selection.init(
        failing.allocator(),
        &snapshot,
        .{ .default_state = .enabled, .exceptions = &.{} },
    ));
}
