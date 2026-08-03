//! AgentCore-owned durable authority projection for Revision 6 Sessions.
//!
//! The checkpoint envelope treats Skill, Permission and MCP state as opaque
//! bounded sections. This module owns the first canonical Skill section and
//! the internal describe/restore vocabulary. None of these types are wire DTOs.

const std = @import("std");
const core = @import("metacodes-core");

const skill_catalog = core.skills_runtime.catalog;
const skill_availability = core.skills_runtime.availability;

pub const SKILL_STATE_REVISION: u16 = 1;
pub const PERMISSION_STATE_REVISION: u16 = 1;
pub const MAX_SKILLS: usize = (skill_catalog.Limits{}).max_slots;

const skill_magic = "R6SKILL\x00";
const skill_header_bytes: usize = 80;
const skill_entry_bytes: usize = 72;
const permission_magic = "R6PERM\x00\x00";
const permission_bytes: usize = 16;

pub const Error = error{
    OutOfMemory,
    ResourceLimit,
    Corrupt,
    InvalidState,
};

pub const LogicalOrigin = enum {
    fresh,
    restored,
};

pub const RestoreHealth = enum {
    complete,
    degraded,
};

pub const Lifecycle = enum {
    idle,
    busy,
    poisoned,
};

pub const SkillDisposition = enum {
    not_bound,
    restored,
    narrowed,
    unavailable,
    changed,
};

pub const AuthoritySummary = struct {
    disposition: SkillDisposition = .not_bound,
    checkpoint_enabled: u32 = 0,
    restored_enabled: u32 = 0,
    invalidated: u32 = 0,
};

/// Internal canonical restore result. Exact C/Rust/Zig DTOs are deliberately
/// deferred until the Session, Permission and MCP seams all close.
pub const RestoreReport = struct {
    health: RestoreHealth,
    session_id: core.session_id.SessionId,
    checkpoint_generation: u64,
    policy_generation: u64,
    catalog_generation: u64,
    skill: AuthoritySummary = .{},
    permission_rules_restored: u32 = 0,
    permission_rules_invalidated: u32 = 0,
    mcp_bindings_restored: u32 = 0,
    mcp_bindings_invalidated: u32 = 0,
};

/// Owned/value-only description used to close internal identifier references
/// before a public ABI representation is selected.
pub const SessionDescription = struct {
    allocator: std.mem.Allocator,
    session_id: core.session_id.SessionId,
    origin: LogicalOrigin,
    lifecycle: Lifecycle,
    registered: bool,
    last_run_id: u64,
    last_compact_id: u64,
    checkpoint_generation: u64,
    policy_generation: u64,
    catalog_generation: u64,
    model: []u8,
    conversation_messages: u64,
    compact_boundary: u64,
    skill_revision: ?[64]u8,
    restore_health: RestoreHealth,
    invalidated_skill_authority: u32,
    invalidated_permission_rules: u32,
    invalidated_mcp_bindings: u32,

    pub fn deinit(self: *SessionDescription) void {
        self.allocator.free(self.model);
        self.* = undefined;
    }
};

pub const SkillEntry = struct {
    skill_id: [64]u8,
    state: skill_availability.State,
};

pub const PermissionState = struct {
    mode: core.types.PermissionMode,
};

pub const DecodedSkillState = struct {
    allocator: std.mem.Allocator,
    revision: [64]u8,
    entries: []SkillEntry,

    pub fn deinit(self: *DecodedSkillState) void {
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn enabledCount(self: *const DecodedSkillState) u32 {
        var count: u32 = 0;
        for (self.entries) |entry| {
            if (entry.state == .enabled) count += 1;
        }
        return count;
    }
};

pub const SkillReconciliation = struct {
    disposition: SkillDisposition,
    checkpoint_enabled: u32,
    restored_enabled: u32,
    invalidated: u32,
    selection: ?skill_availability.Selection = null,

    pub fn summary(self: *const SkillReconciliation) AuthoritySummary {
        return .{
            .disposition = self.disposition,
            .checkpoint_enabled = self.checkpoint_enabled,
            .restored_enabled = self.restored_enabled,
            .invalidated = self.invalidated,
        };
    }

    pub fn takeSelection(self: *SkillReconciliation) ?skill_availability.Selection {
        const selection = self.selection;
        self.selection = null;
        return selection;
    }

    pub fn deinit(self: *SkillReconciliation) void {
        if (self.selection) |*selection| selection.deinit();
        self.* = undefined;
    }
};

/// Empty bytes mean that the logical Session had no Skill binding. A present
/// binding records the exact catalog revision and every effective state, so a
/// wider current Host selection cannot grant a restored Session new Skills.
pub fn encodeSkillState(
    allocator: std.mem.Allocator,
    snapshot: ?*const skill_catalog.Snapshot,
    selection: ?*const skill_availability.Selection,
) Error![]u8 {
    if ((snapshot == null) != (selection == null)) return error.InvalidState;
    const catalog_snapshot = snapshot orelse
        return allocator.alloc(u8, 0) catch error.OutOfMemory;
    const selected = selection.?;
    if (selected.snapshot != catalog_snapshot or
        selected.states.len != catalog_snapshot.skills.len)
        return error.InvalidState;
    if (catalog_snapshot.skills.len > MAX_SKILLS)
        return error.ResourceLimit;
    if (!skill_catalog.isLowerHex64(&catalog_snapshot.revision))
        return error.InvalidState;

    const entries_bytes = std.math.mul(
        usize,
        catalog_snapshot.skills.len,
        skill_entry_bytes,
    ) catch return error.ResourceLimit;
    const total_bytes = std.math.add(
        usize,
        skill_header_bytes,
        entries_bytes,
    ) catch return error.ResourceLimit;
    const encoded = allocator.alloc(u8, total_bytes) catch
        return error.OutOfMemory;
    errdefer allocator.free(encoded);
    @memset(encoded, 0);
    @memcpy(encoded[0..skill_magic.len], skill_magic);
    std.mem.writeInt(u16, encoded[8..10], SKILL_STATE_REVISION, .little);
    std.mem.writeInt(
        u32,
        encoded[12..16],
        @intCast(catalog_snapshot.skills.len),
        .little,
    );
    @memcpy(encoded[16..80], &catalog_snapshot.revision);

    for (catalog_snapshot.skills, 0..) |record, index| {
        if (!skill_catalog.isLowerHex64(&record.skill_id))
            return error.InvalidState;
        const offset = skill_header_bytes + index * skill_entry_bytes;
        @memcpy(encoded[offset..][0..64], &record.skill_id);
        encoded[offset + 64] = @intFromEnum(selected.states[index]);
    }
    return encoded;
}

pub fn decodeSkillState(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) Error!?DecodedSkillState {
    if (encoded.len == 0) return null;
    if (encoded.len < skill_header_bytes or
        !std.mem.eql(u8, encoded[0..skill_magic.len], skill_magic) or
        std.mem.readInt(u16, encoded[8..10], .little) != SKILL_STATE_REVISION or
        !allZero(encoded[10..12]))
        return error.Corrupt;
    const count: usize = @intCast(std.mem.readInt(u32, encoded[12..16], .little));
    if (count > MAX_SKILLS) return error.ResourceLimit;
    if (!skill_catalog.isLowerHex64(encoded[16..80]))
        return error.Corrupt;
    const entries_bytes = std.math.mul(usize, count, skill_entry_bytes) catch
        return error.ResourceLimit;
    const expected = std.math.add(usize, skill_header_bytes, entries_bytes) catch
        return error.ResourceLimit;
    if (encoded.len != expected) return error.Corrupt;

    const entries = allocator.alloc(SkillEntry, count) catch
        return error.OutOfMemory;
    errdefer allocator.free(entries);
    for (entries, 0..) |*entry, index| {
        const offset = skill_header_bytes + index * skill_entry_bytes;
        const id = encoded[offset..][0..64];
        if (!skill_catalog.isLowerHex64(id) or
            !allZero(encoded[offset + 65 .. offset + skill_entry_bytes]))
            return error.Corrupt;
        const state: skill_availability.State = switch (encoded[offset + 64]) {
            0 => .disabled,
            1 => .enabled,
            else => return error.Corrupt,
        };
        for (entries[0..index]) |previous| {
            if (std.mem.eql(u8, &previous.skill_id, id))
                return error.Corrupt;
        }
        entry.* = .{ .skill_id = id[0..64].*, .state = state };
    }
    return .{
        .allocator = allocator,
        .revision = encoded[16..80].*,
        .entries = entries,
    };
}

pub fn encodePermissionState(
    allocator: std.mem.Allocator,
    mode: core.types.PermissionMode,
) Error![]u8 {
    _ = canonicalPermissionMode(@intFromEnum(mode)) orelse
        return error.InvalidState;
    const encoded = allocator.alloc(u8, permission_bytes) catch
        return error.OutOfMemory;
    @memset(encoded, 0);
    @memcpy(encoded[0..permission_magic.len], permission_magic);
    std.mem.writeInt(u16, encoded[8..10], PERMISSION_STATE_REVISION, .little);
    encoded[10] = @intFromEnum(mode);
    return encoded;
}

pub fn decodePermissionState(encoded: []const u8) Error!PermissionState {
    if (encoded.len != permission_bytes or
        !std.mem.eql(u8, encoded[0..permission_magic.len], permission_magic) or
        std.mem.readInt(u16, encoded[8..10], .little) != PERMISSION_STATE_REVISION or
        !allZero(encoded[11..permission_bytes]))
        return error.Corrupt;
    return .{
        .mode = canonicalPermissionMode(encoded[10]) orelse
            return error.Corrupt,
    };
}

/// Intersect restored Skill authority with the current Host-provided binding.
/// Exact catalog identity is required because entry order is revision-bound.
/// The current selection is an authority ceiling, never a source of new grants.
pub fn reconcileSkillState(
    allocator: std.mem.Allocator,
    restored: ?*const DecodedSkillState,
    current_snapshot: ?*const skill_catalog.Snapshot,
    current_selection: ?*const skill_availability.Selection,
) Error!SkillReconciliation {
    if ((current_snapshot == null) != (current_selection == null))
        return error.InvalidState;
    const persisted = restored orelse return .{
        .disposition = .not_bound,
        .checkpoint_enabled = 0,
        .restored_enabled = 0,
        .invalidated = 0,
    };
    const enabled_before = persisted.enabledCount();
    const snapshot = current_snapshot orelse return .{
        .disposition = .unavailable,
        .checkpoint_enabled = enabled_before,
        .restored_enabled = 0,
        .invalidated = enabled_before,
    };
    const ceiling = current_selection.?;
    if (ceiling.snapshot != snapshot or ceiling.states.len != snapshot.skills.len)
        return error.InvalidState;
    if (!std.mem.eql(u8, &persisted.revision, &snapshot.revision) or
        persisted.entries.len != snapshot.skills.len)
        return .{
            .disposition = .changed,
            .checkpoint_enabled = enabled_before,
            .restored_enabled = 0,
            .invalidated = enabled_before,
        };
    for (persisted.entries, snapshot.skills) |entry, record| {
        if (!std.mem.eql(u8, &entry.skill_id, &record.skill_id))
            return .{
                .disposition = .changed,
                .checkpoint_enabled = enabled_before,
                .restored_enabled = 0,
                .invalidated = enabled_before,
            };
    }

    const states = allocator.alloc(skill_availability.State, persisted.entries.len) catch
        return error.OutOfMemory;
    errdefer allocator.free(states);
    var restored_enabled: u32 = 0;
    var invalidated: u32 = 0;
    for (persisted.entries, ceiling.states, 0..) |entry, ceiling_state, index| {
        states[index] = if (entry.state == .enabled and ceiling_state == .enabled)
            .enabled
        else
            .disabled;
        if (states[index] == .enabled) restored_enabled += 1;
        if (entry.state == .enabled and states[index] == .disabled)
            invalidated += 1;
    }
    return .{
        .disposition = if (invalidated == 0) .restored else .narrowed,
        .checkpoint_enabled = enabled_before,
        .restored_enabled = restored_enabled,
        .invalidated = invalidated,
        .selection = .{
            .allocator = allocator,
            .snapshot = snapshot,
            .states = states,
        },
    };
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn canonicalPermissionMode(raw: u8) ?core.types.PermissionMode {
    return switch (raw) {
        0 => .default,
        1 => .accept_edits,
        2 => .plan,
        3 => .auto,
        4 => .dont_ask,
        5 => .bypass_permissions,
        else => null,
    };
}

fn testRecord(id: u8, name: []const u8) skill_catalog.SkillRecord {
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

fn testSnapshot(records: []const skill_catalog.SkillRecord) skill_catalog.Snapshot {
    return .{
        .owner_allocator = std.testing.allocator,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .scope_id = [_]u8{'f'} ** 64,
        .revision = [_]u8{'a'} ** 64,
        .health = .healthy,
        .skills = records,
        .issues = &.{},
        .descriptor_json = "",
        .snapshot_bytes = 0,
        .resident_bytes = 0,
    };
}

test "Revision 6 Skill authority round-trips and never expands on restore" {
    const records = [_]skill_catalog.SkillRecord{
        testRecord('1', "one"),
        testRecord('2', "two"),
        testRecord('3', "three"),
    };
    var snapshot = testSnapshot(&records);
    defer snapshot.arena.deinit();
    const persisted_exceptions = [_]skill_availability.Exception{
        .{ .skill_id = &records[0].skill_id, .state = .enabled },
        .{ .skill_id = &records[1].skill_id, .state = .enabled },
    };
    var persisted_selection = try skill_availability.Selection.init(
        std.testing.allocator,
        &snapshot,
        .{ .default_state = .disabled, .exceptions = &persisted_exceptions },
    );
    defer persisted_selection.deinit();
    const encoded = try encodeSkillState(
        std.testing.allocator,
        &snapshot,
        &persisted_selection,
    );
    defer std.testing.allocator.free(encoded);
    var decoded = (try decodeSkillState(std.testing.allocator, encoded)).?;
    defer decoded.deinit();

    const ceiling_exceptions = [_]skill_availability.Exception{
        .{ .skill_id = &records[1].skill_id, .state = .disabled },
    };
    var ceiling = try skill_availability.Selection.init(
        std.testing.allocator,
        &snapshot,
        .{ .default_state = .enabled, .exceptions = &ceiling_exceptions },
    );
    defer ceiling.deinit();
    var reconciled = try reconcileSkillState(
        std.testing.allocator,
        &decoded,
        &snapshot,
        &ceiling,
    );
    defer reconciled.deinit();

    try std.testing.expectEqual(SkillDisposition.narrowed, reconciled.disposition);
    try std.testing.expectEqual(@as(u32, 2), reconciled.checkpoint_enabled);
    try std.testing.expectEqual(@as(u32, 1), reconciled.restored_enabled);
    try std.testing.expectEqual(@as(u32, 1), reconciled.invalidated);
    try std.testing.expect(reconciled.selection.?.states[0] == .enabled);
    try std.testing.expect(reconciled.selection.?.states[1] == .disabled);
    try std.testing.expect(reconciled.selection.?.states[2] == .disabled);

    const unavailable = try reconcileSkillState(
        std.testing.allocator,
        &decoded,
        null,
        null,
    );
    try std.testing.expectEqual(SkillDisposition.unavailable, unavailable.disposition);
    try std.testing.expectEqual(@as(u32, 2), unavailable.invalidated);
}

test "Revision 6 Skill authority rejects corrupt and oversized state" {
    const records = [_]skill_catalog.SkillRecord{testRecord('1', "one")};
    var snapshot = testSnapshot(&records);
    defer snapshot.arena.deinit();
    var selection = try skill_availability.Selection.init(
        std.testing.allocator,
        &snapshot,
        .{ .default_state = .enabled, .exceptions = &.{} },
    );
    defer selection.deinit();
    const encoded = try encodeSkillState(std.testing.allocator, &snapshot, &selection);
    defer std.testing.allocator.free(encoded);

    const corrupt_magic = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(corrupt_magic);
    corrupt_magic[0] = 'X';
    try std.testing.expectError(
        error.Corrupt,
        decodeSkillState(std.testing.allocator, corrupt_magic),
    );

    const corrupt_state = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(corrupt_state);
    corrupt_state[skill_header_bytes + 64] = 9;
    try std.testing.expectError(
        error.Corrupt,
        decodeSkillState(std.testing.allocator, corrupt_state),
    );

    const oversized = try std.testing.allocator.dupe(u8, encoded[0..skill_header_bytes]);
    defer std.testing.allocator.free(oversized);
    std.mem.writeInt(u32, oversized[12..16], MAX_SKILLS + 1, .little);
    try std.testing.expectError(
        error.ResourceLimit,
        decodeSkillState(std.testing.allocator, oversized),
    );

    try std.testing.expectError(
        error.Corrupt,
        decodeSkillState(std.testing.allocator, encoded[0 .. encoded.len - 1]),
    );
}

test "Revision 6 Permission authority preserves canonical mode" {
    const encoded = try encodePermissionState(
        std.testing.allocator,
        .dont_ask,
    );
    defer std.testing.allocator.free(encoded);
    const decoded = try decodePermissionState(encoded);
    try std.testing.expectEqual(core.types.PermissionMode.dont_ask, decoded.mode);

    const corrupt = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(corrupt);
    corrupt[10] = @intFromEnum(core.types.PermissionMode.prompt);
    try std.testing.expectError(error.Corrupt, decodePermissionState(corrupt));
    try std.testing.expectError(
        error.Corrupt,
        decodePermissionState(encoded[0 .. encoded.len - 1]),
    );
}
