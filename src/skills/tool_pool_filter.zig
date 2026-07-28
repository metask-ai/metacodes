//! Tool-pool projection for an active Skill.
//!
//! The canonical PolicyFrame owns every rule decision. This module only hides
//! definitions the frame cannot execute, preserving the existing generic
//! call shape without retaining a second policy engine.

const std = @import("std");
const json = @import("../json.zig");
const ActiveSkillState = @import("active.zig").ActiveSkillState;

pub fn filterToolDefs(
    allocator: std.mem.Allocator,
    parent_defs: []const json.ToolDefinition,
    active: ?*const ActiveSkillState,
) !?[]json.ToolDefinition {
    const state = active orelse return null;

    var visible_count: usize = 0;
    for (parent_defs) |definition| {
        if (state.allowsTool(definition.name)) visible_count += 1;
    }
    if (visible_count == parent_defs.len) return null;

    const filtered = try allocator.alloc(json.ToolDefinition, visible_count);
    var index: usize = 0;
    for (parent_defs) |definition| {
        if (!state.allowsTool(definition.name)) continue;
        filtered[index] = definition;
        index += 1;
    }
    return filtered;
}

pub fn freeFiltered(
    allocator: std.mem.Allocator,
    filtered: ?[]json.ToolDefinition,
) void {
    if (filtered) |definitions| allocator.free(definitions);
}

const testing = std.testing;
const PolicyFrame = @import("runtime/policy_frame.zig").PolicyFrame;
const MatchContext = @import("../permission/rule_spec.zig").MatchContext;

fn fakeDefs(allocator: std.mem.Allocator) ![]json.ToolDefinition {
    const names = [_][]const u8{ "Read", "Write", "Edit", "Bash", "Grep" };
    const definitions = try allocator.alloc(json.ToolDefinition, names.len);
    for (names, definitions) |name, *definition| {
        definition.* = .{
            .name = name,
            .description = "",
            .input_schema = .{
                .type = "object",
                .properties = null,
                .required = &.{},
            },
        };
    }
    return definitions;
}

fn projectedState(
    allocator: std.mem.Allocator,
    allowed: []const []const u8,
    disallowed: []const []const u8,
) !ActiveSkillState {
    const session_tools = [_][]const u8{ "Read", "Write", "Edit", "Bash", "Grep" };
    const root = try PolicyFrame.createRoot(
        allocator,
        &session_tools,
        .unrestricted,
        .default,
        MatchContext{
            .cwd = "/workspace",
            .project_root = "/workspace",
            .home = "/home/test",
            .alloc = allocator,
        },
    );
    defer root.release();
    const child = try PolicyFrame.derive(root, allowed, disallowed);
    defer child.release();
    return ActiveSkillState.initFromPolicyFrame(allocator, "test", child);
}

fn containsByName(
    definitions: []json.ToolDefinition,
    name: []const u8,
) bool {
    for (definitions) |definition| {
        if (std.mem.eql(u8, definition.name, name)) return true;
    }
    return false;
}

test "tool-pool projection is zero-copy when every tool remains visible" {
    const allocator = testing.allocator;
    const parent = try fakeDefs(allocator);
    defer allocator.free(parent);
    var state = try projectedState(allocator, &.{}, &.{});
    defer state.deinit();
    try testing.expect(
        try filterToolDefs(allocator, parent, &state) == null,
    );
}

test "tool-pool projection follows PolicyFrame intersection and denial" {
    const allocator = testing.allocator;
    const parent = try fakeDefs(allocator);
    defer allocator.free(parent);
    var state = try projectedState(
        allocator,
        &.{ "Read", "Bash(git *)" },
        &.{"Bash"},
    );
    defer state.deinit();
    const filtered = try filterToolDefs(allocator, parent, &state);
    defer freeFiltered(allocator, filtered);
    try testing.expectEqual(@as(usize, 1), filtered.?.len);
    try testing.expect(containsByName(filtered.?, "Read"));
    try testing.expect(!containsByName(filtered.?, "Bash"));
    try testing.expect(!containsByName(filtered.?, "Write"));
}

test "tool-pool projection with no active Skill is zero-copy" {
    const allocator = testing.allocator;
    const parent = try fakeDefs(allocator);
    defer allocator.free(parent);
    try testing.expect(try filterToolDefs(allocator, parent, null) == null);
}
