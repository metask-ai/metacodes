//! Skill 工具：LLM 激活 skill 时调用，返回 skill 的 instructions body。
//!
//! 注册到 DynRegistry 时绑定一个 SkillSet 指针作为 ctx_ptr。
//! execute 收到 `{"name":"xxx"}` 参数，查 set 返回 body；未找到返错误。

const std = @import("std");
const common = @import("../tools/common.zig");
const ToolContext = @import("../tools/context.zig").ToolContext;
const DynRegistry = @import("../tools/dynamic.zig").DynRegistry;
const SkillSet = @import("skill.zig").SkillSet;

pub fn registerSkillTool(registry: *DynRegistry, set: *SkillSet) !void {
    const required = [_][]const u8{"name"};
    try registry.register(
        "Skill",
        "Activate a named skill. Returns the skill's instructions. Use to load specialized workflows when needed.",
        &required,
        execute,
        @ptrCast(set),
    );
}

fn execute(ctx: *const ToolContext, args: []const u8, ctx_ptr: ?*anyopaque) anyerror![]u8 {
    const set_ptr = ctx_ptr orelse return error.MissingSkillSet;
    const set: *SkillSet = @ptrCast(@alignCast(set_ptr));

    const name = common.extractJsonArg(args, "name") orelse return error.MissingSkillName;
    if (name.len == 0) return error.EmptySkillName;

    const skill = set.find(name) orelse return error.SkillNotFound;

    // allowed_tools 约束：当前 skill 走"内联注入指令"模型（非 fork 子 agent），
    // 无法在工具分发层硬隔离工具集。退而求其次：在 body 顶部显式声明只许用这些工具，
    // 让模型自我约束。硬隔离（forked subagent + tool pool 限制）见 [[skill-forked-exec]]。
    if (skill.allowed_tools.len > 0) {
        var out: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer out.deinit();
        try out.writer.print("# Skill: {s}\n\n", .{skill.name});
        try out.writer.writeAll("> Tool restriction: while following this skill, you may ONLY use these tools: ");
        for (skill.allowed_tools, 0..) |t, i| {
            if (i > 0) try out.writer.writeAll(", ");
            try out.writer.writeAll(t);
        }
        try out.writer.writeAll(". Do not call any other tool.\n\n");
        try out.writer.writeAll(skill.body);
        return try out.toOwnedSlice();
    }

    return try std.fmt.allocPrint(
        ctx.allocator,
        "# Skill: {s}\n\n{s}",
        .{ skill.name, skill.body },
    );
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const parseSkillMd = @import("skill.zig").parseSkillMd;

test "Skill tool: activates existing skill" {
    var set = SkillSet.init(testing.allocator);
    defer set.deinit();
    const md = "---\nname: writer\ndescription: a writer\n---\nWrite clearly.\n";
    try set.skills.append(testing.allocator, try parseSkillMd(testing.allocator, md, "/fake"));

    var reg = DynRegistry.init(testing.allocator);
    defer reg.deinit();
    try registerSkillTool(&reg, &set);

    const entry = reg.find("Skill").?;
    const ctx = ToolContext.simple(testing.allocator);
    const out = try entry.execute(&ctx, "{\"name\":\"writer\"}", entry.ctx_ptr);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "# Skill: writer") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Write clearly") != null);
}

test "Skill tool: not found returns error" {
    var set = SkillSet.init(testing.allocator);
    defer set.deinit();

    var reg = DynRegistry.init(testing.allocator);
    defer reg.deinit();
    try registerSkillTool(&reg, &set);

    const entry = reg.find("Skill").?;
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(
        error.SkillNotFound,
        entry.execute(&ctx, "{\"name\":\"missing\"}", entry.ctx_ptr),
    );
}

test "Skill tool: missing name arg" {
    var set = SkillSet.init(testing.allocator);
    defer set.deinit();
    var reg = DynRegistry.init(testing.allocator);
    defer reg.deinit();
    try registerSkillTool(&reg, &set);

    const entry = reg.find("Skill").?;
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(
        error.MissingSkillName,
        entry.execute(&ctx, "{}", entry.ctx_ptr),
    );
}

test "Skill tool: allowed_tools injects restriction directive" {
    var set = SkillSet.init(testing.allocator);
    defer set.deinit();
    const md = "---\nname: reader\ndescription: read-only\nallowed_tools: Read, Grep\n---\nLook around.\n";
    try set.skills.append(testing.allocator, try parseSkillMd(testing.allocator, md, "/fake"));

    var reg = DynRegistry.init(testing.allocator);
    defer reg.deinit();
    try registerSkillTool(&reg, &set);

    const entry = reg.find("Skill").?;
    const ctx = ToolContext.simple(testing.allocator);
    const out = try entry.execute(&ctx, "{\"name\":\"reader\"}", entry.ctx_ptr);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "ONLY use these tools: Read, Grep") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Look around") != null);
}
