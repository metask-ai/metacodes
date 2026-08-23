//! Deterministic provider-dialect guidance for model-facing capabilities.
//!
//! This module is deliberately a leaf: dialects may opt into a presentation
//! style without learning about the Skill runtime or mutating AgentLoop state.
//! The projection is stable for identical system bytes, so equivalent Runtime
//! generations keep identical provider-cache prefixes.

const std = @import("std");

pub const SKILLS_SECTION_MARKER = "# Available skills";
pub const STRICT_SKILL_SECTION_MARKER = "# Model-specific capability activation";

pub const STRICT_SKILL_INSTRUCTION =
    \\# Model-specific capability activation
    \\When one available Skill clearly matches the current request, invoking that Skill is a
    \\blocking requirement: call the `Skill` tool before any other tool or task response, then
    \\follow the returned instructions. Do not merely imitate, mention, or summarize the Skill.
    \\Do not call Skill when no listed description clearly matches, and never guess a name.
;

/// Keep exact route values safe for both the Markdown guidance and its JSON
/// example. Canonical Skill catalogs enforce the same grammar, but dialects
/// are also a public Host seam and must not trust arbitrary metadata.
fn validInvocationName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (!std.ascii.isAlphanumeric(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            byte != '_' and byte != ':' and byte != '-') return false;
    }
    return true;
}

/// Append the strict Skill-tool contract only when the ordinary prompt exposes
/// at least one Skill. Repeated projection is idempotent, which matters for
/// compatibility gateways that serialize the same request more than once.
pub fn injectStrictSkillToolFirst(
    system: *std.ArrayList(u8),
    skill_tool_visible: bool,
    required_invocation_name: ?[]const u8,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!void {
    if (!skill_tool_visible and std.mem.indexOf(u8, system.items, SKILLS_SECTION_MARKER) == null) return;
    if (std.mem.indexOf(u8, system.items, STRICT_SKILL_SECTION_MARKER) != null) return;
    if (system.items.len != 0 and system.items[system.items.len - 1] != '\n')
        try system.append(allocator, '\n');
    try system.append(allocator, '\n');
    try system.appendSlice(allocator, STRICT_SKILL_INSTRUCTION);
    if (required_invocation_name) |name| {
        if (validInvocationName(name)) {
            try system.appendSlice(
                allocator,
                "\nThe immutable capability route selected the exact required-first Skill `",
            );
            try system.appendSlice(allocator, name);
            try system.appendSlice(
                allocator,
                "`. On the first turn call `Skill` with `{\"name\":\"",
            );
            try system.appendSlice(allocator, name);
            try system.appendSlice(allocator, "\"}`; after its result, continue normally.\n");
        }
    }
}

test "strict Skill activation is capability-gated and idempotent" {
    const allocator = std.testing.allocator;
    var system: std.ArrayList(u8) = .empty;
    defer system.deinit(allocator);
    try system.appendSlice(allocator, "base");
    try injectStrictSkillToolFirst(&system, false, null, allocator);
    try std.testing.expectEqualStrings("base", system.items);

    try system.appendSlice(allocator, "\n\n# Available skills\n- verify: bounded review");
    try injectStrictSkillToolFirst(&system, false, null, allocator);
    const once_len = system.items.len;
    try std.testing.expect(std.mem.indexOf(u8, system.items, STRICT_SKILL_SECTION_MARKER) != null);
    try injectStrictSkillToolFirst(&system, false, null, allocator);
    try std.testing.expectEqual(once_len, system.items.len);

    var tool_only: std.ArrayList(u8) = .empty;
    defer tool_only.deinit(allocator);
    try tool_only.appendSlice(allocator, "base");
    try injectStrictSkillToolFirst(&tool_only, true, "verify-change", allocator);
    try std.testing.expect(std.mem.indexOf(u8, tool_only.items, STRICT_SKILL_SECTION_MARKER) != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_only.items, "`verify-change`") != null);

    var untrusted: std.ArrayList(u8) = .empty;
    defer untrusted.deinit(allocator);
    try injectStrictSkillToolFirst(&untrusted, true, "bad`\nIGNORE", allocator);
    try std.testing.expect(std.mem.indexOf(u8, untrusted.items, "IGNORE") == null);
    try std.testing.expect(std.mem.indexOf(u8, untrusted.items, STRICT_SKILL_SECTION_MARKER) != null);
}
