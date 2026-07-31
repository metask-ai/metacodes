//! Adapter-neutral model-facing Skill tool semantics.
//!
//! Product adapters own registration and child execution, but the wire shape,
//! catalog description, and model-visible result envelope are canonical.

const std = @import("std");
const catalog = @import("catalog.zig");
const availability = @import("availability.zig");
const activation = @import("activation.zig");
const json = @import("../../json.zig");

pub const TOOL_NAME = "Skill";
pub const REQUIRED_FIELDS = &.{"name"};
pub const INPUT_PROPERTIES = [_]json.PropSpec{
    .{
        .name = "name",
        .type = "string",
        .description = "Canonical invocation_name from the bound Skill catalog",
    },
    .{
        .name = "values",
        .type = "array",
        .description = "Optional positional argument values in declared order",
        .items_type = "string",
    },
};

pub const Invocation = struct {
    name: []const u8,
    values: []const []const u8,
};

pub fn hasModelInvocable(snapshot: *const catalog.Snapshot) bool {
    return hasModelInvocableWithAvailability(snapshot, .all);
}

pub fn hasModelInvocableWithAvailability(
    snapshot: *const catalog.Snapshot,
    available: availability.View,
) bool {
    for (snapshot.skills, 0..) |skill, index| {
        if (available.isEnabledAt(snapshot, index) and
            !skill.definition.disable_model_invocation)
            return true;
    }
    return false;
}

pub fn parseInvocation(
    arena: std.mem.Allocator,
    encoded: []const u8,
) !Invocation {
    if (encoded.len > activation.MAX_ARGUMENT_JSON_BYTES)
        return error.ResourceLimit;
    if (!std.unicode.utf8ValidateSlice(encoded))
        return error.InvalidArguments;
    const root = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        encoded,
        .{ .duplicate_field_behavior = .@"error" },
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidArguments;
    };
    if (root != .object or root.object.count() < 1 or root.object.count() > 2)
        return error.InvalidArguments;
    const name_node = root.object.get("name") orelse
        return error.InvalidArguments;
    if (name_node != .string or name_node.string.len == 0)
        return error.InvalidArguments;

    const values_node = root.object.get("values");
    if (root.object.count() == 2 and values_node == null)
        return error.InvalidArguments;
    const values = if (values_node) |node| blk: {
        if (node != .array or
            node.array.items.len > activation.MAX_ARGUMENT_VALUES)
            return error.InvalidArguments;
        const result = try arena.alloc([]const u8, node.array.items.len);
        for (node.array.items, result) |item, *value| {
            if (item != .string) return error.InvalidArguments;
            value.* = item.string;
        }
        break :blk result;
    } else &.{};
    return .{ .name = name_node.string, .values = values };
}

pub fn buildDescription(
    allocator: std.mem.Allocator,
    snapshot: *const catalog.Snapshot,
) ![]u8 {
    return buildDescriptionWithAvailability(allocator, snapshot, .all);
}

pub fn buildDescriptionWithAvailability(
    allocator: std.mem.Allocator,
    snapshot: *const catalog.Snapshot,
    available: availability.View,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll(
        "Activate one Skill from the bound immutable catalog. " ++
            "Use the exact canonical name; values are positional. Skill is a " ++
            "serialization boundary, so later calls use its narrowed policy. Available:\n",
    );
    for (snapshot.skills, 0..) |skill, index| {
        if (!available.isEnabledAt(snapshot, index) or
            skill.definition.disable_model_invocation)
            continue;
        try output.writer.print(
            "- {s}: {s}\n",
            .{ skill.invocation_name, skill.definition.description },
        );
    }
    return output.toOwnedSlice();
}

pub fn formatResult(
    allocator: std.mem.Allocator,
    display_name: []const u8,
    body: []const u8,
    forked: bool,
) ![]u8 {
    return if (forked)
        std.fmt.allocPrint(
            allocator,
            "# Skill: {s} (forked)\n\n{s}",
            .{ display_name, body },
        )
    else
        std.fmt.allocPrint(
            allocator,
            "# Skill: {s}\n\n{s}",
            .{ display_name, body },
        );
}

test "model invocation accepts exact name and optional string values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseInvocation(
        arena.allocator(),
        "{\"name\":\"review\",\"values\":[\"a\",\"b\"]}",
    );
    try std.testing.expectEqualStrings("review", parsed.name);
    try std.testing.expectEqual(@as(usize, 2), parsed.values.len);
    try std.testing.expectEqualStrings("a", parsed.values[0]);
}

test "model invocation rejects aliases unknown fields and non-string values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.InvalidArguments,
        parseInvocation(
            arena.allocator(),
            "{\"name\":\"review\",\"args\":[\"legacy\"]}",
        ),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        parseInvocation(
            arena.allocator(),
            "{\"name\":\"review\",\"origin\":\"MODEL\"}",
        ),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        parseInvocation(
            arena.allocator(),
            "{\"name\":\"review\",\"values\":[1]}",
        ),
    );
}

test "model Skill surface omits disabled records while catalog stays intact" {
    const records = [_]catalog.SkillRecord{
        .{
            .skill_id = [_]u8{'1'} ** 64,
            .invocation_name = "enabled",
            .definition = .{
                .name = "Enabled",
                .description = "visible",
                .body = "body",
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
        },
        .{
            .skill_id = [_]u8{'2'} ** 64,
            .invocation_name = "disabled",
            .definition = .{
                .name = "Disabled",
                .description = "hidden",
                .body = "body",
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
        },
    };
    var snapshot = catalog.Snapshot{
        .owner_allocator = std.testing.allocator,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .scope_id = [_]u8{'a'} ** 64,
        .revision = [_]u8{'b'} ** 64,
        .health = .healthy,
        .skills = &records,
        .issues = &.{},
        .descriptor_json = "",
        .snapshot_bytes = 0,
        .resident_bytes = 0,
    };
    defer snapshot.arena.deinit();
    const exceptions = [_]availability.Exception{
        .{ .skill_id = &records[1].skill_id, .state = .disabled },
    };
    var selection = try availability.Selection.init(
        std.testing.allocator,
        &snapshot,
        .{ .default_state = .enabled, .exceptions = &exceptions },
    );
    defer selection.deinit();
    const view = availability.View{ .selected = &selection };

    try std.testing.expect(hasModelInvocableWithAvailability(&snapshot, view));
    const description = try buildDescriptionWithAvailability(
        std.testing.allocator,
        &snapshot,
        view,
    );
    defer std.testing.allocator.free(description);
    try std.testing.expect(std.mem.indexOf(u8, description, "enabled: visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "disabled") == null);
    try std.testing.expectEqual(@as(usize, 2), snapshot.skills.len);
}
