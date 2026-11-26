//! Adapter-neutral model-facing Skill tool semantics.
//!
//! Product adapters own registration and child execution, but the wire shape,
//! catalog description, and model-visible result envelope are canonical.

const std = @import("std");
const catalog = @import("catalog.zig");
const availability = @import("availability.zig");
const activation = @import("activation.zig");
const json = @import("metacodes-ai").json;

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

/// How a Skill appears in the model-facing listing. Claude Code
/// `skillOverrides`: "name-only" keeps the name and drops the description,
/// "user-invocable-only" and "off" leave the Skill out (and the Skill tool
/// refuses it).
pub const Listing = enum { full, name_only, hidden };

/// Resolve an exact required-first Skill only when the visible catalog is
/// unambiguous. Enumeration order never selects a winner: two required Skills
/// deliberately collapse to advisory model behavior.
pub fn requiredFirstInvocationWithAvailability(
    snapshot: *const catalog.Snapshot,
    available: availability.View,
) ?[]const u8 {
    return requiredFirstInvocationWithListing(snapshot, available, null);
}

/// As `requiredFirstInvocationWithAvailability`; a Skill hidden from the
/// model (`listings[i] == .hidden`, aligned with `snapshot.skills`) cannot
/// be required first.
pub fn requiredFirstInvocationWithListing(
    snapshot: *const catalog.Snapshot,
    available: availability.View,
    listings: ?[]const Listing,
) ?[]const u8 {
    var selected: ?[]const u8 = null;
    for (snapshot.skills, 0..) |skill, index| {
        if (!available.isEnabledAt(snapshot, index) or
            skill.definition.disable_model_invocation or
            listingAt(listings, index) == .hidden or
            skill.definition.model_activation != .required_first)
            continue;
        if (selected != null) return null;
        selected = skill.invocation_name;
    }
    return selected;
}

fn listingAt(listings: ?[]const Listing, index: usize) Listing {
    const values = listings orelse return .full;
    return values[index];
}

pub fn requiredFirstInvocation(snapshot: *const catalog.Snapshot) ?[]const u8 {
    return requiredFirstInvocationWithAvailability(snapshot, .all);
}

pub fn modelActivationWithAvailability(
    snapshot: *const catalog.Snapshot,
    available: availability.View,
) ?json.ModelToolActivation {
    return modelActivationWithListing(snapshot, available, null);
}

pub fn modelActivationWithListing(
    snapshot: *const catalog.Snapshot,
    available: availability.View,
    listings: ?[]const Listing,
) ?json.ModelToolActivation {
    const invocation = requiredFirstInvocationWithListing(snapshot, available, listings) orelse
        return null;
    return .{
        .mode = .required_first,
        .argument_name = "name",
        .argument_value = invocation,
    };
}

pub fn modelActivation(snapshot: *const catalog.Snapshot) ?json.ModelToolActivation {
    return modelActivationWithAvailability(snapshot, .all);
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
    return buildDescriptionWithListing(allocator, snapshot, available, null);
}

/// The Skill tool description with per-Skill `listings` (aligned with
/// `snapshot.skills`; null lists every Skill in full). A name-only Skill is
/// listed as `- name`, as Claude Code lists it.
pub fn buildDescriptionWithListing(
    allocator: std.mem.Allocator,
    snapshot: *const catalog.Snapshot,
    available: availability.View,
    listings: ?[]const Listing,
) ![]u8 {
    if (listings) |values| std.debug.assert(values.len == snapshot.skills.len);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll(
        "Execute one Skill from the bound immutable catalog. When a listed " ++
            "description clearly matches the current user request, calling Skill " ++
            "before any other tool or task response is a blocking requirement. " ++
            "Never merely imitate, mention, or summarize a matching Skill: call " ++
            "this tool with its exact canonical name and then follow the returned " ++
            "instructions. Do not guess a name or invoke a marginal match. Values " ++
            "are positional. Skill is a serialization boundary, so later calls use " ++
            "its narrowed policy. Available:\n",
    );
    for (snapshot.skills, 0..) |skill, index| {
        if (!available.isEnabledAt(snapshot, index) or
            skill.definition.disable_model_invocation)
            continue;
        switch (listingAt(listings, index)) {
            .hidden => continue,
            .name_only => {
                try output.writer.print("- {s}\n", .{skill.invocation_name});
                continue;
            },
            .full => {},
        }
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        try output.writer.print(
            "- {s}: {s}\n",
            .{
                skill.invocation_name,
                try listingDescription(scratch.allocator(), skill.definition.description, skill.definition.when_to_use),
            },
        );
    }
    return output.toOwnedSlice();
}

/// Per-Skill cap on `description` + `when_to_use` in a listing (Claude Code
/// `skillListingMaxDescChars` default, counted here in bytes).
pub const LISTING_MAX_DESCRIPTION_BYTES: usize = 1536;

/// `description` and `when_to_use` joined on one line with whitespace runs
/// collapsed (a folded YAML description keeps paragraph breaks), capped at
/// `LISTING_MAX_DESCRIPTION_BYTES` on a UTF-8 boundary.
pub fn listingDescription(arena: std.mem.Allocator, description: []const u8, when_to_use: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ description, when_to_use }) |part| {
        var words = std.mem.tokenizeAny(u8, part, " \t\r\n");
        while (words.next()) |word| {
            if (out.items.len != 0) try out.append(arena, ' ');
            try out.appendSlice(arena, word);
        }
    }
    return truncateUtf8(arena, out.items, LISTING_MAX_DESCRIPTION_BYTES);
}

pub fn truncateUtf8(arena: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]const u8 {
    if (text.len <= max_bytes) return text;
    const ellipsis = "…";
    var end = max_bytes - ellipsis.len;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    return std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, text[0..end], " "), ellipsis });
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
                .when_to_use = "",
                .description_source = .frontmatter,
                .warnings = .{},
                .argument_hint = "",
                .user_invocable = true,
                .model_activation = .required_first,
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
                .when_to_use = "",
                .description_source = .frontmatter,
                .warnings = .{},
                .argument_hint = "",
                .user_invocable = true,
                .model_activation = .required_first,
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
        .content_bytes = 0,
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
    try std.testing.expect(std.mem.indexOf(u8, description, "blocking requirement") != null);
    try std.testing.expectEqualStrings(
        "enabled",
        requiredFirstInvocationWithAvailability(&snapshot, view).?,
    );
    const route = modelActivationWithAvailability(&snapshot, view).?;
    try std.testing.expectEqualStrings("name", route.argument_name.?);
    try std.testing.expectEqualStrings("enabled", route.argument_value.?);
    // With both records visible, enumeration order must never pick a winner.
    try std.testing.expect(requiredFirstInvocation(&snapshot) == null);
    try std.testing.expect(modelActivation(&snapshot) == null);
    try std.testing.expectEqual(@as(usize, 2), snapshot.skills.len);
}

fn testRecord(comptime id: u8, name: []const u8, description: []const u8) catalog.SkillRecord {
    return .{
        .skill_id = [_]u8{id} ** 64,
        .invocation_name = name,
        .definition = .{
            .name = name,
            .description = description,
            .body = "body",
            .allowed_tools = &.{},
            .disallowed_tools = &.{},
            .arguments = &.{},
            .disable_model_invocation = false,
            .when_to_use = "",
            .description_source = .frontmatter,
            .warnings = .{},
            .argument_hint = "",
            .user_invocable = true,
            .model_activation = .required_first,
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

test "listing: name-only drops the description, hidden drops the Skill" {
    const records = [_]catalog.SkillRecord{
        testRecord('1', "full-skill", "described"),
        testRecord('2', "named-skill", "not shown"),
        testRecord('3', "hidden-skill", "not shown either"),
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
        .content_bytes = 0,
        .resident_bytes = 0,
    };
    defer snapshot.arena.deinit();

    const listings = [_]Listing{ .full, .name_only, .hidden };
    const description = try buildDescriptionWithListing(std.testing.allocator, &snapshot, .all, &listings);
    defer std.testing.allocator.free(description);
    try std.testing.expect(std.mem.indexOf(u8, description, "- full-skill: described\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "- named-skill\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "not shown") == null);
    try std.testing.expect(std.mem.indexOf(u8, description, "hidden-skill") == null);

    // Null listings are the full listing, byte for byte.
    const all = try buildDescriptionWithListing(std.testing.allocator, &snapshot, .all, null);
    defer std.testing.allocator.free(all);
    const plain = try buildDescription(std.testing.allocator, &snapshot);
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings(plain, all);

    // Three required-first Skills are ambiguous; hiding two leaves one.
    try std.testing.expect(requiredFirstInvocationWithListing(&snapshot, .all, null) == null);
    const one = [_]Listing{ .hidden, .name_only, .hidden };
    try std.testing.expectEqualStrings("named-skill", requiredFirstInvocationWithListing(&snapshot, .all, &one).?);
    const none = [_]Listing{ .hidden, .hidden, .hidden };
    try std.testing.expect(modelActivationWithListing(&snapshot, .all, &none) == null);
}
