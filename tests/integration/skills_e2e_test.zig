//! Skill E2E：造临时 skill 目录 → SkillSet 加载 → Skill tool 激活。

const std = @import("std");
const cc = @import("cc");

fn makeSkill(parent: []const u8, name: []const u8, md: []const u8) !void {
    const a = std.testing.allocator;
    const parent_z = try a.dupeZ(u8, parent);
    defer a.free(parent_z);
    _ = std.c.mkdir(parent_z, 0o755);
    const sd = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ parent, name }, 0);
    defer a.free(sd);
    _ = std.c.mkdir(sd, 0o755);
    const md_path = try std.fmt.allocPrintSentinel(a, "{s}/{s}/SKILL.md", .{ parent, name }, 0);
    defer a.free(md_path);
    const fd = std.c.open(md_path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = std.c.write(fd, md.ptr, md.len);
    _ = std.c.close(fd);
}

fn rmSkill(parent: []const u8, name: []const u8) void {
    const a = std.testing.allocator;
    const md_path = std.fmt.allocPrintSentinel(a, "{s}/{s}/SKILL.md", .{ parent, name }, 0) catch return;
    defer a.free(md_path);
    _ = std.c.unlink(md_path);
    const sd = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ parent, name }, 0) catch return;
    defer a.free(sd);
    _ = std.c.rmdir(sd);
}

test "Skills E2E: loadFromDir + Skill tool activation" {
    const a = std.testing.allocator;
    const dir = "/tmp/cc-zig-skills-e2e";
    defer {
        rmSkill(dir, "refactor");
        rmSkill(dir, "review");
        if (a.dupeZ(u8, dir)) |dir_z| {
            defer a.free(dir_z);
            _ = std.c.rmdir(dir_z);
        } else |_| {}
    }

    try makeSkill(dir, "refactor", "---\nname: refactor\ndescription: Refactor safely\n---\nSteps: 1. read 2. plan 3. edit\n");
    try makeSkill(dir, "review", "---\nname: review\ndescription: Review PR\n---\nChecklist: security, perf, clarity.\n");

    var set = cc.skills.SkillSet.init(a);
    defer set.deinit();
    try set.loadFromDir(dir);
    try std.testing.expect(set.len() == 2);
    try std.testing.expect(set.find("refactor") != null);
    try std.testing.expect(set.find("review") != null);

    // 激活 refactor skill
    var reg = cc.tools_dynamic.DynRegistry.init(a);
    defer reg.deinit();
    try cc.skills_tool.registerSkillTool(&reg, &set);

    const entry = reg.find("Skill").?;
    const ctx = cc.tools.ToolContext.simple(a);
    const out = try entry.execute(&ctx, "{\"name\":\"refactor\"}", entry.ctx_ptr);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "# Skill: refactor") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Steps:") != null);

    // renderSystemAddendum 包含两个 skill
    const sys = try cc.skills_discovery.renderSystemAddendum(&set, a);
    defer a.free(sys);
    try std.testing.expect(std.mem.indexOf(u8, sys, "refactor") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "review") != null);
}
