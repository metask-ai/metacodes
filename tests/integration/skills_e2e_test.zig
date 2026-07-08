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

test "Skills E2E: tools.dispatch routes Skill tool through dyn_registry" {
    const a = std.testing.allocator;
    const dir = "/tmp/cc-zig-skills-dispatch";
    defer {
        rmSkill(dir, "demo");
        if (a.dupeZ(u8, dir)) |dz| {
            defer a.free(dz);
            _ = std.c.rmdir(dz);
        } else |_| {}
    }
    try makeSkill(dir, "demo", "---\nname: demo\ndescription: Demo skill\nallowed_tools: Read, Grep\n---\nDemo body.\n");

    var set = cc.skills.SkillSet.init(a);
    defer set.deinit();
    try set.loadFromDir(dir);

    var reg = cc.tools_dynamic.DynRegistry.init(a);
    defer reg.deinit();
    try cc.skills_tool.registerSkillTool(&reg, &set);

    // 这才是真正的生产路径：模型通过 tools.dispatch 调用,而不是绕过 dispatch 直接 find
    var ctx = cc.tools.ToolContext.simple(a);
    ctx.dyn_registry = &reg;
    const out = try cc.tools.dispatch(&ctx, "Skill", "{\"name\":\"demo\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "# Skill: demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Demo body") != null);
    // allowed_tools 软约束被注入
    try std.testing.expect(std.mem.indexOf(u8, out, "Active tool grants: Read, Grep") != null);
}

test "Skills E2E: buildWithSkills injects skill list into system prompt" {
    const a = std.testing.allocator;
    const dir = "/tmp/cc-zig-skills-sysprompt";
    defer {
        rmSkill(dir, "inject-me");
        if (a.dupeZ(u8, dir)) |dz| {
            defer a.free(dz);
            _ = std.c.rmdir(dz);
        } else |_| {}
    }
    try makeSkill(dir, "inject-me", "---\nname: inject-me\ndescription: Should appear in sysprompt\n---\nbody\n");

    var set = cc.skills.SkillSet.init(a);
    defer set.deinit();
    try set.loadFromDir(dir);

    const sp = @import("cc").system_prompt;
    const prompt = try sp.buildWithSkills(a, "claude-opus-4-7", &set);
    defer a.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Available skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "**inject-me**") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Should appear in sysprompt") != null);
}

// =====================================================================
// Stage B/C/D 综合集成测试
// =====================================================================

test "Skills E2E: bash injection runs at activation time and emits stdout" {
    const a = std.testing.allocator;
    const dir = "/tmp/cc-zig-skills-bash-inject";
    defer {
        rmSkill(dir, "echoer");
        if (a.dupeZ(u8, dir)) |dz| {
            defer a.free(dz);
            _ = std.c.rmdir(dz);
        } else |_| {}
    }
    try makeSkill(dir, "echoer",
        "---\nname: echoer\ndescription: bash inject test\n---\n" ++
        "Output: !`echo hello-from-bash`\n");

    var set = cc.skills.SkillSet.init(a);
    defer set.deinit();
    try set.loadFromDir(dir);

    var reg = cc.tools_dynamic.DynRegistry.init(a);
    defer reg.deinit();
    try cc.skills_tool.registerSkillTool(&reg, &set);

    var ctx = cc.tools.ToolContext.simple(a);
    ctx.dyn_registry = &reg;
    const out = try cc.tools.dispatch(&ctx, "Skill", "{\"name\":\"echoer\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Output: hello-from-bash") != null);
}

test "Skills E2E: disable-model-invocation blocks auto, allows explicit" {
    const a = std.testing.allocator;
    const dir = "/tmp/cc-zig-skills-dmi";
    defer {
        rmSkill(dir, "deploy");
        if (a.dupeZ(u8, dir)) |dz| {
            defer a.free(dz);
            _ = std.c.rmdir(dz);
        } else |_| {}
    }
    try makeSkill(dir, "deploy",
        "---\nname: deploy\ndescription: deploys\ndisable-model-invocation: true\n---\nDeploy steps.\n");

    var set = cc.skills.SkillSet.init(a);
    defer set.deinit();
    try set.loadFromDir(dir);

    var reg = cc.tools_dynamic.DynRegistry.init(a);
    defer reg.deinit();
    try cc.skills_tool.registerSkillTool(&reg, &set);

    // 模型路径(explicit_invocation=false 默认):应被拒
    var ctx_auto = cc.tools.ToolContext.simple(a);
    ctx_auto.dyn_registry = &reg;
    const out_auto = try cc.tools.dispatch(&ctx_auto, "Skill", "{\"name\":\"deploy\"}");
    defer a.free(out_auto);
    try std.testing.expect(std.mem.indexOf(u8, out_auto, "SkillRequiresExplicitInvocation") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_auto, "Deploy steps") == null);

    // 用户显式路径(explicit_invocation=true):放行
    var ctx_explicit = cc.tools.ToolContext.simple(a);
    ctx_explicit.dyn_registry = &reg;
    ctx_explicit.explicit_invocation = true;
    const out_explicit = try cc.tools.dispatch(&ctx_explicit, "Skill", "{\"name\":\"deploy\"}");
    defer a.free(out_explicit);
    try std.testing.expect(std.mem.indexOf(u8, out_explicit, "Deploy steps") != null);
}

test "Skills E2E: allowed-tools active skill overrides prompt-mode ask" {
    const a = std.testing.allocator;
    const active_mod = @import("cc").active_skill;

    // 模拟在 prompt mode 下(Bash 默认会 ask),激活 skill 后 Bash(git *) 应直接 allow
    const allowed = [_][]const u8{"Bash(git *)"};
    var st = try active_mod.ActiveSkillState.init(a, "test", &allowed, &.{});
    defer st.deinit();

    // 构造 PermissionContext with active_skill
    var ctx = cc.permission.createContext(.prompt, a);
    ctx.active_skill = &st;

    // git 命令应被 allow(active skill 覆盖 mode 的 ask)
    const d1 = cc.permission.checkPermission(&ctx, "Bash", "{\"command\":\"git status\"}");
    try std.testing.expect(d1 == .allow);

    // 不在白名单的 Bash 命令仍 ask(prompt mode 默认)
    const d2 = cc.permission.checkPermission(&ctx, "Bash", "{\"command\":\"rm -rf /\"}");
    try std.testing.expect(d2 == .ask);
}

test "Skills E2E: disallowed-tools active skill turns allow into deny" {
    const a = std.testing.allocator;
    const active_mod = @import("cc").active_skill;
    const disallowed = [_][]const u8{"AskUserQuestion"};
    var st = try active_mod.ActiveSkillState.init(a, "test", &.{}, &disallowed);
    defer st.deinit();

    // 在 bypass 模式下,默认本应 allow;但 disallowed 应胜出 deny
    var ctx = cc.permission.createContext(.bypass, a);
    ctx.active_skill = &st;
    const d = cc.permission.checkPermission(&ctx, "AskUserQuestion", "{}");
    try std.testing.expect(d == .deny);
}

test "Skills E2E: $ARGUMENTS rendering through dispatch" {
    const a = std.testing.allocator;
    const dir = "/tmp/cc-zig-skills-args";
    defer {
        rmSkill(dir, "greet");
        if (a.dupeZ(u8, dir)) |dz| {
            defer a.free(dz);
            _ = std.c.rmdir(dz);
        } else |_| {}
    }
    try makeSkill(dir, "greet",
        "---\nname: greet\ndescription: hello\n---\nHello $ARGUMENTS!\n");

    var set = cc.skills.SkillSet.init(a);
    defer set.deinit();
    try set.loadFromDir(dir);

    var reg = cc.tools_dynamic.DynRegistry.init(a);
    defer reg.deinit();
    try cc.skills_tool.registerSkillTool(&reg, &set);

    var ctx = cc.tools.ToolContext.simple(a);
    ctx.dyn_registry = &reg;
    const out = try cc.tools.dispatch(&ctx, "Skill", "{\"name\":\"greet\",\"args\":[\"world\"]}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello world!") != null);
}

test "Skills E2E: ${CLAUDE_SKILL_DIR} resolves to skill source path" {
    const a = std.testing.allocator;
    const dir = "/tmp/cc-zig-skills-dir";
    defer {
        rmSkill(dir, "pathy");
        if (a.dupeZ(u8, dir)) |dz| {
            defer a.free(dz);
            _ = std.c.rmdir(dz);
        } else |_| {}
    }
    try makeSkill(dir, "pathy",
        "---\nname: pathy\ndescription: path test\n---\nMy dir: ${CLAUDE_SKILL_DIR}/scripts\n");

    var set = cc.skills.SkillSet.init(a);
    defer set.deinit();
    try set.loadFromDir(dir);

    var reg = cc.tools_dynamic.DynRegistry.init(a);
    defer reg.deinit();
    try cc.skills_tool.registerSkillTool(&reg, &set);

    var ctx = cc.tools.ToolContext.simple(a);
    ctx.dyn_registry = &reg;
    const out = try cc.tools.dispatch(&ctx, "Skill", "{\"name\":\"pathy\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "My dir: /tmp/cc-zig-skills-dir/pathy/scripts") != null);
}

test "Skills E2E: project root cwd-walking loads .metacodes/skills in repo root" {
    const a = std.testing.allocator;
    const cwd = try cc.util_fs.getCwd(a);
    defer a.free(cwd);
    const root = try cc.skills.findRepoRoot(a, cwd);
    defer a.free(root);
    try std.testing.expect(std.mem.endsWith(u8, root, "cc-t2z"));
}
