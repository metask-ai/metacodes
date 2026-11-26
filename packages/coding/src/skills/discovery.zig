//! Skill 发现 + system prompt 注入。
//!
//! 启动时把所有 skill 的 name / description 作为 system prompt 的一段增量，
//! 让 LLM 知道有哪些 skill 可按需激活（通过 Skill 工具）。
//!
//! 注入格式：
//!   ## Available Skills
//!   - <name>: <description>
//!   - <name>: <description>
//!
//!   To use a skill, call the `Skill` tool with `{"name": "<name>"}`.

const std = @import("std");
const SkillSet = @import("skill.zig").SkillSet;

/// 生成 skill 部分的 system prompt 增量。
/// 返回 owned bytes，caller free。skill 集合为空时返 ""。
pub fn renderSystemAddendum(set: *const SkillSet, allocator: std.mem.Allocator) ![]u8 {
    if (set.len() == 0) return try allocator.dupe(u8, "");

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\n\n## Available Skills\n");
    for (set.skills.items) |s| {
        const line = try std.fmt.allocPrint(allocator, "- {s}: {s}\n", .{ s.name, s.description });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
    try out.appendSlice(allocator,
        \\
        \\To activate a skill, call the `Skill` tool with `{"name": "<name>"}`.
        \\
    );

    return try out.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const parseSkillMd = @import("skill.zig").parseSkillMd;

test "renderSystemAddendum empty set" {
    var set = SkillSet.init(testing.allocator);
    defer set.deinit();
    const out = try renderSystemAddendum(&set, testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "renderSystemAddendum lists skills" {
    var set = SkillSet.init(testing.allocator);
    defer set.deinit();
    const md1 = "---\nname: alpha\ndescription: first skill\n---\nbody";
    const md2 = "---\nname: beta\ndescription: second skill\n---\nbody";
    try set.skills.append(testing.allocator, try parseSkillMd(testing.allocator, md1, "/fake/alpha"));
    try set.skills.append(testing.allocator, try parseSkillMd(testing.allocator, md2, "/fake/beta"));

    const out = try renderSystemAddendum(&set, testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "## Available Skills") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- alpha: first skill") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- beta: second skill") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Skill` tool") != null);
}
