//! Subagent E2E:加载、内置、tool 过滤、context 注入、Task 工具签名。

const std = @import("std");
const cc = @import("cc");
const pfs = @import("platform").fs; // 可移植文件 IO(std.c.open 的 O 在 Windows 是 void)

fn makeAgent(parent: []const u8, filename: []const u8, md: []const u8) !void {
    const a = std.testing.allocator;
    const parent_z = try a.dupeZ(u8, parent);
    defer a.free(parent_z);
    _ = std.c.mkdir(parent_z, 0o755);
    const md_path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ parent, filename }, 0);
    defer a.free(md_path);
    const fd = pfs.open(md_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    _ = pfs.write(fd, md);
    pfs.close(fd);
}

fn rmAgent(parent: []const u8, filename: []const u8) void {
    const a = std.testing.allocator;
    const md_path = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ parent, filename }, 0) catch return;
    defer a.free(md_path);
    _ = std.c.unlink(md_path);
}

fn rmDir(p: []const u8) void {
    const a = std.testing.allocator;
    const pz = a.dupeZ(u8, p) catch return;
    defer a.free(pz);
    _ = std.c.rmdir(pz);
}

fn currentProjectRoot(allocator: std.mem.Allocator) ![]u8 {
    const cwd = try cc.util_fs.getCwd(allocator);
    defer allocator.free(cwd);
    return try cc.skills.findRepoRoot(allocator, cwd);
}

test "Subagents E2E: 3 builtins injected on init" {
    const a = std.testing.allocator;
    var set = cc.agents_set.AgentSet.init(a);
    defer set.deinit();
    try set.loadFromStandardPaths(""); // 无 project,只 builtin + ~

    try std.testing.expect(set.find("Explore") != null);
    try std.testing.expect(set.find("Plan") != null);
    try std.testing.expect(set.find("general-purpose") != null);
    // Explore: haiku + read-only(tools 含 Read/Grep/Glob/Bash,disallowed 含 Write/Edit)
    const expl = set.find("Explore").?;
    try std.testing.expectEqualStrings("haiku", expl.model);
    try std.testing.expect(expl.tools.len == 4);
    try std.testing.expect(expl.disallowed_tools.len == 2);
}

test "Subagents E2E: custom personal-level agent loaded" {
    const a = std.testing.allocator;
    const dir = "/tmp/cc-zig-agents-personal";
    defer {
        rmAgent(dir, "code-reviewer.md");
        rmDir(dir);
    }
    try makeAgent(dir, "code-reviewer.md",
        "---\nname: code-reviewer\ndescription: review code\ntools: Read, Grep\nmodel: haiku\n---\nYou review.\n");

    var set = cc.agents_set.AgentSet.init(a);
    defer set.deinit();
    try set.loadFromDirRecursive(dir, .personal);
    const def = set.find("code-reviewer").?;
    try std.testing.expectEqualStrings("review code", def.description);
    try std.testing.expectEqualStrings("haiku", def.model);
    try std.testing.expectEqual(@as(usize, 2), def.tools.len);
    try std.testing.expect(def.origin == .personal);
}

test "Subagents E2E: project overrides personal" {
    const a = std.testing.allocator;
    const p1 = "/tmp/cc-zig-ag-prio1";
    const p2 = "/tmp/cc-zig-ag-prio2";
    defer { rmAgent(p1, "x.md"); rmDir(p1); rmAgent(p2, "x.md"); rmDir(p2); }
    try makeAgent(p1, "x.md", "---\nname: shared\ndescription: personal\n---\nA\n");
    try makeAgent(p2, "x.md", "---\nname: shared\ndescription: project\n---\nB\n");

    var set = cc.agents_set.AgentSet.init(a);
    defer set.deinit();
    try set.loadFromDirRecursive(p1, .personal);
    try set.loadFromDirRecursive(p2, .project);
    const d = set.find("shared").?;
    try std.testing.expectEqualStrings("project", d.description);
    try std.testing.expect(d.origin == .project);
}

test "Subagents E2E: tool filter — Explore is read-only" {
    const a = std.testing.allocator;
    var set = cc.agents_set.AgentSet.init(a);
    defer set.deinit();
    try set.loadFromStandardPaths("");
    const expl = set.find("Explore").?;

    // 父全集
    const parent_defs = try cc.tools.toToolDefinitions(a);
    defer a.free(parent_defs);

    const filtered = try cc.agents_filter.filterToolDefs(a, parent_defs, expl);
    defer a.free(filtered);

    var saw_read = false;
    var saw_write = false;
    var saw_edit = false;
    for (filtered) |d| {
        if (std.mem.eql(u8, d.name, "Read")) saw_read = true;
        if (std.mem.eql(u8, d.name, "Write")) saw_write = true;
        if (std.mem.eql(u8, d.name, "Edit")) saw_edit = true;
    }
    try std.testing.expect(saw_read);
    try std.testing.expect(!saw_write);
    try std.testing.expect(!saw_edit);
}

test "Subagents E2E: permanently-disabled removed (Agent/Task/AskUserQuestion)" {
    const a = std.testing.allocator;
    var set = cc.agents_set.AgentSet.init(a);
    defer set.deinit();
    try set.loadFromStandardPaths("");

    // general-purpose: 没有 tools/disallowed,只有永久禁用集
    const gp = set.find("general-purpose").?;
    const parent_defs = try cc.tools.toToolDefinitions(a);
    defer a.free(parent_defs);
    const filtered = try cc.agents_filter.filterToolDefs(a, parent_defs, gp);
    defer a.free(filtered);

    for (filtered) |d| {
        try std.testing.expect(!std.mem.eql(u8, d.name, "Agent"));
        try std.testing.expect(!std.mem.eql(u8, d.name, "Task"));
        try std.testing.expect(!std.mem.eql(u8, d.name, "AskUserQuestion"));
        try std.testing.expect(!std.mem.eql(u8, d.name, "EnterPlanMode"));
        try std.testing.expect(!std.mem.eql(u8, d.name, "ExitPlanMode"));
    }
}

test "Subagents E2E: Plan sees TinyKG history read tools without memory write access" {
    const a = std.testing.allocator;
    var set = cc.agents_set.AgentSet.init(a);
    defer set.deinit();
    try set.loadFromStandardPaths("");

    const plan = set.find("Plan").?;
    const parent_defs = try cc.tools.toToolDefinitions(a);
    defer a.free(parent_defs);
    const filtered = try cc.agents_filter.filterToolDefs(a, parent_defs, plan);
    defer a.free(filtered);

    var saw_recall = false;
    var saw_context = false;
    for (filtered) |d| {
        if (std.mem.eql(u8, d.name, "KgRecall")) saw_recall = true;
        if (std.mem.eql(u8, d.name, "KgContext")) saw_context = true;
        try std.testing.expect(!std.mem.eql(u8, d.name, "KgRemember"));
    }
    try std.testing.expect(saw_recall);
    try std.testing.expect(saw_context);
}

test "Subagents E2E: buildSubagentContext for Explore skips CLAUDE.md+git" {
    const a = std.testing.allocator;
    var set = cc.agents_set.AgentSet.init(a);
    defer set.deinit();
    try set.loadFromStandardPaths("");

    const expl = set.find("Explore").?;
    const preload = @import("cc").agents_preload;
    const project_dir = try currentProjectRoot(a);
    defer a.free(project_dir);
    const sys = try preload.buildSubagentContext(a, expl, .{
        .project_dir = project_dir,
        .parent_model = "claude-opus-4-7",
        .skip_codebase_context = preload.shouldSkipCodebaseContext(expl.name),
    });
    defer a.free(sys);
    try std.testing.expect(std.mem.indexOf(u8, sys, "agent type: Explore") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "# Project CLAUDE.md") == null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "# Git status") == null);
}

test "Subagents E2E: buildSubagentContext for general-purpose includes git status" {
    const a = std.testing.allocator;
    var set = cc.agents_set.AgentSet.init(a);
    defer set.deinit();
    try set.loadFromStandardPaths("");

    const gp = set.find("general-purpose").?;
    const preload = @import("cc").agents_preload;
    const project_dir = try currentProjectRoot(a);
    defer a.free(project_dir);
    const sys = try preload.buildSubagentContext(a, gp, .{
        .project_dir = project_dir,
        .parent_model = "claude-opus-4-7",
        .skip_codebase_context = preload.shouldSkipCodebaseContext(gp.name),
    });
    defer a.free(sys);
    // git status section 应出现(repo 状态可能 clean 或 dirty,都行)
    try std.testing.expect(std.mem.indexOf(u8, sys, "# Git status") != null);
}

test "Subagents E2E: subagents section in system prompt" {
    const a = std.testing.allocator;
    var skset = cc.skills.SkillSet.init(a);
    defer skset.deinit();
    var agset = cc.agents_set.AgentSet.init(a);
    defer agset.deinit();
    try agset.loadFromStandardPaths("");

    const sp = @import("cc").system_prompt;
    const prompt = try sp.buildWithSkillsAndAgents(a, "claude-opus-4-7", &skset, &agset, "/tmp");
    defer a.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Available subagents") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "**Explore**") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "**Plan**") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "**general-purpose**") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Task(subagent_type") != null);
}

test "Subagents E2E: Task tool registered in static registry (Agent 兼容别名)" {
    try std.testing.expect(cc.tools.getTool("Task") != null); // 主名(SFT 锚点)
    try std.testing.expect(cc.tools.getTool("Agent") != null); // 兼容别名仍可路由
}

test "Subagents E2E: Task tool fails clean without subagent_type if no Agents set" {
    const a = std.testing.allocator;
    var ctx = cc.tools.ToolContext.simple(a);
    // 没有 api_client → 应早返 AgentUnavailable
    try std.testing.expectError(error.AgentUnavailable, cc.tools.dispatch(&ctx, "Task", "{\"subagent_type\":\"Explore\",\"description\":\"d\",\"prompt\":\"p\"}"));
}
