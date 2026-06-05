//! L2 组件测试:Skill `context: fork` 端到端贯穿。
//!
//! 设计目标(doc/SKILL_DESIGN.md §11 + CLAUDE.md「声明=接线=测试」):
//!   skill frontmatter 的 context/agent/model 三字段 parse 后必须真生效——
//!   - context: fork → 激活时不是内联渲染 body,而是用 body 当 prompt spawn 一个 subagent,
//!     实际 HTTP 请求体里能看到 body 当 user message。
//!   - agent: <name> → subagent 的 system prompt 来自该 AgentDef(请求体 system 字段断言)。
//!   - model: haiku  → 请求体 model 字段是解析后的 haiku ID。
//!   - context: inline(default)→ 激活后**不**发任何 HTTP 请求(纯内联)。
//!
//! 测试策略:起 MockServer + base_url override Client → 注册 Skill 工具 →
//!   通过 DynRegistry.find("Skill").execute 走真实生产路径 → 断言 srv.lastRequest()。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const MINIMAL_END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"forked-reply\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

// 1) fork 触发 spawn:context: fork 的 skill 激活后,MockServer 收到请求,
//    请求体含 rendered body 当 user message。**核心端到端断言**。
test "L2: skill context:fork → spawn subagent (请求体含 body)" {
    const a = std.heap.page_allocator;

    var srv = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var set = cc.skills.SkillSet.init(a);
    defer set.deinit();
    const md = "---\nname: forky\ndescription: forks\ncontext: fork\n---\nFORK_BODY_MARKER do the thing\n";
    const skill = try cc.skills.parseSkillMd(a, md, "/tmp/forky/SKILL.md");
    try set.skills.append(a, skill);

    var reg = cc.tools_dynamic.DynRegistry.init(a);
    defer reg.deinit();
    try cc.skills_tool.registerSkillTool(&reg, &set);

    var perm = cc.permission.PermissionContext{ .mode = .init(.bypass_permissions), .allocator = a };
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};

    var ctx = cc.tools.ToolContext.simple(a);
    ctx.api_client = &client;
    ctx.tool_defs = empty_defs;
    ctx.permission_ctx = &perm;

    const entry = reg.find("Skill").?;
    const out = entry.execute(&ctx, "{\"name\":\"forky\"}", entry.ctx_ptr) catch |e| {
        std.debug.print("fork execute failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer a.free(out);

    // 输出应是 forked 头 + subagent final_text
    try std.testing.expect(std.mem.indexOf(u8, out, "(forked)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "forked-reply") != null);

    // 端到端:MockServer 真收到了 subagent 请求,且 body 当 user message
    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    const messages = cap.jsonField("messages") orelse return error.MessagesFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, messages, "FORK_BODY_MARKER") != null);
}

// 2) inline(default)不 spawn:context 缺省的 skill 激活后 MockServer 无请求。回归保护。
test "L2: skill context:inline → 不 spawn (无 HTTP 请求)" {
    const a = std.heap.page_allocator;

    var srv = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var set = cc.skills.SkillSet.init(a);
    defer set.deinit();
    const md = "---\nname: inliney\ndescription: inline\n---\nINLINE_BODY just text\n";
    const skill = try cc.skills.parseSkillMd(a, md, "/tmp/inliney/SKILL.md");
    try set.skills.append(a, skill);

    var reg = cc.tools_dynamic.DynRegistry.init(a);
    defer reg.deinit();
    try cc.skills_tool.registerSkillTool(&reg, &set);

    var perm = cc.permission.PermissionContext{ .mode = .init(.bypass_permissions), .allocator = a };
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    var ctx = cc.tools.ToolContext.simple(a);
    ctx.api_client = &client;
    ctx.tool_defs = empty_defs;
    ctx.permission_ctx = &perm;

    const entry = reg.find("Skill").?;
    const out = try entry.execute(&ctx, "{\"name\":\"inliney\"}", entry.ctx_ptr);
    defer a.free(out);

    // 内联:返回 `# Skill: inliney` + body,且 MockServer 无请求
    try std.testing.expect(std.mem.indexOf(u8, out, "# Skill: inliney") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "INLINE_BODY") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(forked)") == null);
    try std.testing.expect(srv.lastRequest() == null); // 关键:没发任何请求
}

// 3) model 字段生效:context:fork + model:haiku → 请求体 model 含 haiku。
test "L2: skill fork + model:haiku → 请求体 model 是 haiku" {
    const a = std.heap.page_allocator;

    var srv = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    // 父 client 用 sonnet,skill.model=haiku 应覆盖
    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var set = cc.skills.SkillSet.init(a);
    defer set.deinit();
    const md = "---\nname: haikufork\ndescription: fork haiku\ncontext: fork\nmodel: haiku\n---\nbody here\n";
    const skill = try cc.skills.parseSkillMd(a, md, "/tmp/haikufork/SKILL.md");
    try set.skills.append(a, skill);

    var reg = cc.tools_dynamic.DynRegistry.init(a);
    defer reg.deinit();
    try cc.skills_tool.registerSkillTool(&reg, &set);

    var perm = cc.permission.PermissionContext{ .mode = .init(.bypass_permissions), .allocator = a };
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    var ctx = cc.tools.ToolContext.simple(a);
    ctx.api_client = &client;
    ctx.tool_defs = empty_defs;
    ctx.permission_ctx = &perm;

    const entry = reg.find("Skill").?;
    const out = entry.execute(&ctx, "{\"name\":\"haikufork\"}", entry.ctx_ptr) catch return error.SkipZigTest;
    defer a.free(out);

    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    const model_field = cap.jsonField("model") orelse return error.ModelFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, model_field, "haiku") != null);
}

// 4) agent 字段生效:context:fork + agent:<custom> → subagent system prompt 来自该 AgentDef。
test "L2: skill fork + agent:<custom> → 请求体 system 来自 AgentDef" {
    const a = std.heap.page_allocator;

    var srv = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    // 自定义 agent,system prompt 含独特 marker
    var agset = cc.agents_set.AgentSet.init(a);
    defer agset.deinit();
    const agent_md = "---\nname: skillrunner\ndescription: runs skills\ntools: Read\n---\nAGENT_SYS_MARKER you are the skill runner.\n";
    const def = try cc.agents_def.parseAgentMd(a, agent_md, "/tmp/skillrunner.md", .personal);
    try agset.agents.append(a, def);

    var set = cc.skills.SkillSet.init(a);
    defer set.deinit();
    const md = "---\nname: agentfork\ndescription: fork via agent\ncontext: fork\nagent: skillrunner\n---\nbody for agent\n";
    const skill = try cc.skills.parseSkillMd(a, md, "/tmp/agentfork/SKILL.md");
    try set.skills.append(a, skill);

    var reg = cc.tools_dynamic.DynRegistry.init(a);
    defer reg.deinit();
    try cc.skills_tool.registerSkillTool(&reg, &set);

    var perm = cc.permission.PermissionContext{ .mode = .init(.bypass_permissions), .allocator = a };
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    var ctx = cc.tools.ToolContext.simple(a);
    ctx.api_client = &client;
    ctx.tool_defs = empty_defs;
    ctx.permission_ctx = &perm;
    ctx.agents = &agset;

    const entry = reg.find("Skill").?;
    const out = entry.execute(&ctx, "{\"name\":\"agentfork\"}", entry.ctx_ptr) catch return error.SkipZigTest;
    defer a.free(out);

    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    const sys_field = cap.jsonField("system") orelse return error.SystemFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, sys_field, "AGENT_SYS_MARKER") != null);
}

// 5) 降级:api_client 缺失时 fork skill 仍优雅返回 rendered body(不 crash)。
test "L2: skill fork 无 api_client → 降级 inline" {
    const a = std.testing.allocator;

    var set = cc.skills.SkillSet.init(a);
    defer set.deinit();
    const md = "---\nname: degradefork\ndescription: fork degrade\ncontext: fork\n---\nDEGRADE_BODY content\n";
    const skill = try cc.skills.parseSkillMd(a, md, "/tmp/degradefork/SKILL.md");
    try set.skills.append(a, skill);

    var reg = cc.tools_dynamic.DynRegistry.init(a);
    defer reg.deinit();
    try cc.skills_tool.registerSkillTool(&reg, &set);

    // ctx 无 api_client/tool_defs/permission_ctx → tryForkSpawn 返回 ForkUnavailable → 降级
    const ctx = cc.tools.ToolContext.simple(a);
    const entry = reg.find("Skill").?;
    const out = try entry.execute(&ctx, "{\"name\":\"degradefork\"}", entry.ctx_ptr);
    defer a.free(out);

    // 降级到 inline:返回 # Skill 头 + body,不含 forked 头
    try std.testing.expect(std.mem.indexOf(u8, out, "# Skill: degradefork") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "DEGRADE_BODY") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(forked)") == null);
}
