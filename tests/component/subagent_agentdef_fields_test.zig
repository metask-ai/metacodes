//! L2/L3: AgentDef background/effort/memory_scope/mcp_servers/isolation 从 frontmatter
//! 贯穿 Task 工具、真实子 agent loop、HTTP 请求与文件系统副作用。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

// napi/metask-compatible formatting: spaces after separators and reordered
// fields. This exact shape previously streamed to the UI but was silently
// dropped from Conversation, making Task.final_text empty.
const PROXY_SPACED_END_TURN_SSE =
    "data: {\"message\": {\"id\": \"m\", \"role\": \"assistant\", \"model\": \"x\", \"usage\": {\"input_tokens\": 1, \"output_tokens\": 1}}, \"type\": \"message_start\"}\n\n" ++
    "data: {\"type\": \"content_block_start\", \"index\": 0, \"content_block\": {\"type\": \"text\", \"text\": \"\"}}\n\n" ++
    "data: {\"delta\": {\"text\": \"PROXY_FINAL_TEXT\", \"type\": \"text_delta\"}, \"index\": 0, \"type\": \"content_block_delta\"}\n\n" ++
    "data: {\"type\": \"content_block_stop\", \"index\": 0}\n\n" ++
    "data: {\"type\": \"message_delta\", \"delta\": {\"stop_reason\": \"end_turn\"}, \"usage\": {\"output_tokens\": 1}}\n\n" ++
    "data: {\"type\": \"message_stop\"}\n\n";

const OPENAI_END_TURN_SSE =
    "data: {\"choices\":[{\"delta\":{\"content\":\"done\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

const TOOL_USE_PREFIX =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n";
const TOOL_USE_SUFFIX =
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";
const MEM_PROBE_SSE = TOOL_USE_PREFIX ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"MemProbe\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++ TOOL_USE_SUFFIX;
const MCP_PROBE_SSE = TOOL_USE_PREFIX ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"allowed__probe\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++ TOOL_USE_SUFFIX;
const BG_PROBE_SSE = TOOL_USE_PREFIX ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"BgProbe\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++ TOOL_USE_SUFFIX;
const FIELD_PROBE_SSE = TOOL_USE_PREFIX ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"FieldProbe\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++ TOOL_USE_SUFFIX;
const LOCK_WORKTREE_SSE = TOOL_USE_PREFIX ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"LockWorktree\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++ TOOL_USE_SUFFIX;
const WRITE_SSE = TOOL_USE_PREFIX ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Write\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"file_path\\\":\\\"agent-output.txt\\\",\\\"content\\\":\\\"worktree-only\\\\n\\\"}\"}}\n\n" ++ TOOL_USE_SUFFIX;

fn addAgent(a: std.mem.Allocator, agents: *cc.agents_set.AgentSet, md: []const u8) !void {
    const def = try cc.agents_def.parseAgentMd(a, md, "/test/agent.md", .project);
    errdefer def.deinit(a);
    try agents.agents.append(a, def);
}

fn baseContext(
    a: std.mem.Allocator,
    client: *cc.client_mod.Client,
    agents: *const cc.agents_set.AgentSet,
    perm: *const cc.permission.PermissionContext,
    defs: []const cc.json_mod.ToolDefinition,
) cc.tool_context.ToolContext {
    return .{
        .allocator = a,
        .api_client = client,
        .tool_defs = defs,
        .permission_ctx = @constCast(perm),
        .agents = agents,
        .parent_model = "claude-sonnet-4-20250514",
    };
}

fn fieldProbe(ctx: *const cc.tool_context.ToolContext, _: []const u8, state_ptr: ?*anyopaque) anyerror![]u8 {
    const calls: *usize = @ptrCast(@alignCast(state_ptr.?));
    calls.* += 1;
    return ctx.allocator.dupe(u8, "{\"ok\":true}");
}

test "L2 AgentDef.background=true: Task 未传 run_in_background 仍返回 agent_job_id" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&.{END_TURN_SSE}, 100);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try addAgent(a, &agents, "---\nname: always-bg\nbackground: true\n---\nRun in the background.");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    var jobs = try cc.agent_job_registry.AgentJobRegistry.init(a, "k", url, "claude-sonnet-4-20250514", .anthropic);
    defer jobs.deinit();
    var ctx = baseContext(a, &client, &agents, &perm, &.{});
    ctx.agent_jobs = &jobs;

    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"always-bg\",\"prompt\":\"go\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"agent_job_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"status\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"final_text\"") == null);
}

test "L2 AgentDef.effort=high: 子请求含 output_config.effort 且父 Client 恢复" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.start(END_TURN_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try addAgent(a, &agents, "---\nname: deliberate\neffort: high\n---\nReason carefully.");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const ctx = baseContext(a, &client, &agents, &perm, &.{});

    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"deliberate\",\"prompt\":\"go\"}");
    defer a.free(out);
    const body = (srv.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output_config\":{\"effort\":\"high\"}") != null);
    try std.testing.expect(client.reasoning_effort == null);
}

test "L2 Task preserves proxy-spaced text_delta in final_text" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.start(PROXY_SPACED_END_TURN_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "glm-5.2", url);
    defer client.deinit();
    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try addAgent(a, &agents, "---\nname: proxy-text\n---\nReturn text.");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const ctx = baseContext(a, &client, &agents, &perm, &.{});

    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"proxy-text\",\"prompt\":\"go\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"final_text\":\"PROXY_FINAL_TEXT\"") != null);
}

test "L2 AgentDef.effort=high: GLM-5.2 effort 走顶层 reasoning_effort body 且父 Provider 恢复" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.start(OPENAI_END_TURN_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.api_openai.OpenAIClient.init(a, io_rt.io(), "k", "glm-5.2", url);
    defer client.deinit();
    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try addAgent(a, &agents, "---\nname: deliberate-openai\neffort: high\n---\nReason carefully.");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    var ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .provider = client.provider(),
        .tool_defs = &.{},
        .permission_ctx = @constCast(&perm),
        .agents = &agents,
        .parent_model = "glm-5.2",
    };

    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"deliberate-openai\",\"prompt\":\"go\"}");
    defer a.free(out);
    const body = (srv.lastRequest() orelse return error.NoRequestCaptured).body();
    // GLM-5.2:顶层 reasoning_effort body 字段(7 档透传)+ thinking:{type:enabled}。
    // 来源:docs.z.ai/guides/capabilities/thinking(2026-08 KnowForge 调研)。
    // 不再注入 <reasoning_effort> system 标签(那是旧 GLM-4.6 时代格式)。
    try std.testing.expect(std.mem.indexOf(u8, body, "<reasoning_effort>") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"enabled\"}") != null);
    try std.testing.expect(client.reasoning_effort == null);
}

test "L2 AgentDef.overrides: frontmatter reaches child request and preserves parent cache policy" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.start(OPENAI_END_TURN_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.api_openai.OpenAIClient.init(a, io_rt.io(), "k", "gpt-4o", url);
    defer client.deinit();
    client.overrides = .{ .temperature = 0.7, .top_p = 0.8 };
    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try addAgent(a, &agents, "---\nname: sampled-agent\ntemperature: 0.5\n---\nUse the scoped sampling policy.");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .provider = client.provider(),
        .tool_defs = &.{},
        .permission_ctx = @constCast(&perm),
        .agents = &agents,
        .parent_model = "gpt-4o",
    };

    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"sampled-agent\",\"prompt\":\"go\"}");
    defer a.free(out);
    const body = (srv.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"top_p\":0.8") != null);
    try std.testing.expectEqual(@as(f32, 0.7), client.overrides.temperature.?);
    try std.testing.expectEqual(@as(f32, 0.8), client.overrides.top_p.?);
}

test "L2 AgentDef.model=haiku: Task 解析配置并覆盖真实子请求 model" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.start(END_TURN_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try addAgent(a, &agents, "---\nname: haiku-agent\nmodel: haiku\n---\nUse the configured model.");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const ctx = baseContext(a, &client, &agents, &perm, &.{});

    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"haiku-agent\",\"prompt\":\"go\"}");
    defer a.free(out);
    const model = (srv.lastRequest() orelse return error.NoRequestCaptured).jsonField("model") orelse return error.ModelFieldMissing;
    try std.testing.expectEqualStrings("\"claude-3-5-haiku-20241022\"", model);
}

test "L2 AgentDef.permission_mode=plan: Task 注入真实子请求 Plan Mode" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.start(END_TURN_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try addAgent(a, &agents, "---\nname: planning-agent\npermissionMode: plan\n---\nPlan without changing files.");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const ctx = baseContext(a, &client, &agents, &perm, &.{});

    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"planning-agent\",\"prompt\":\"go\"}");
    defer a.free(out);
    const system = (srv.lastRequest() orelse return error.NoRequestCaptured).jsonField("system") orelse return error.SystemFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, system, "# Plan Mode (active)") != null);
    try std.testing.expect(std.mem.indexOf(u8, system, "<proposed_plan>") != null);
}

test "L2 AgentDef.max_turns=1: Task 在一次真实 tool_use 后停止" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&.{FIELD_PROBE_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try addAgent(a, &agents, "---\nname: one-turn-agent\ntools: FieldProbe\nmaxTurns: 1\n---\nCall the probe once.");

    var calls: usize = 0;
    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("FieldProbe", "count a real child tool call", &.{}, fieldProbe, &calls, false);
    const defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(defs);
    const perm = cc.permission.createContext(.bypass_permissions, a);
    var ctx = baseContext(a, &client, &agents, &perm, defs);
    ctx.dyn_registry = &dyn;

    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"one-turn-agent\",\"prompt\":\"go\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"stop_reason\":\"max_turns\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"turns\":1") != null);
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
}

test "L2 AgentDef.tools/disallowed_tools: 白名单与黑名单共同裁剪真实子请求" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.start(END_TURN_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try addAgent(a, &agents, "---\nname: readonly-custom\ntools: Read, Write, Grep\ndisallowedTools: Write\n---\nInspect without editing.");
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const ctx = baseContext(a, &client, &agents, &perm, defs);

    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"readonly-custom\",\"prompt\":\"inspect\"}");
    defer a.free(out);
    const tools = (srv.lastRequest() orelse return error.NoRequestCaptured).jsonField("tools") orelse return error.ToolsFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"name\":\"Read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"name\":\"Grep\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"name\":\"Write\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"name\":\"Bash\"") == null);
}

test "L2 Plan runtime tool snapshot keeps TinyKG capability and system prompt aligned" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.start(END_TURN_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try agents.loadFromStandardPaths("");

    const prompt_ctx = cc.tools.PromptContext{ .tinykg_enabled = false };
    var defs_arena = std.heap.ArenaAllocator.init(a);
    defer defs_arena.deinit();
    const defs = try cc.tools.toToolDefinitionsFull(defs_arena.allocator(), null, &prompt_ctx);
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const ctx = baseContext(a, &client, &agents, &perm, defs);

    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"Plan\",\"prompt\":\"inspect\"}");
    defer a.free(out);
    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    const tools = cap.jsonField("tools") orelse return error.ToolsFieldMissing;
    const system = cap.jsonField("system") orelse return error.SystemFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"name\":\"KgRecall\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"name\":\"KgContext\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, system, "- Allowed tools: Read, Glob, Grep\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, system, "- Allowed tools: Read, Glob, Grep, KgRecall") == null);
}

test "L2 AgentDef.preload_skills: skill 正文进入真实子请求 system" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.start(END_TURN_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try addAgent(a, &agents, "---\nname: api-dev\nskills: [api-conv]\n---\nFollow the preloaded conventions.");

    var skills = cc.skills.SkillSet.init(a);
    defer skills.deinit();
    const skill_md = "---\nname: api-conv\ndescription: API conventions\n---\nPRELOAD_L2_MARKER: use camelCase response fields.\n";
    try skills.skills.append(a, try cc.skills.parseSkillMd(a, skill_md, "/fake/api-conv/SKILL.md"));

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var ctx = baseContext(a, &client, &agents, &perm, &.{});
    ctx.skills = &skills;
    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"api-dev\",\"prompt\":\"design an API\"}");
    defer a.free(out);
    const system = (srv.lastRequest() orelse return error.NoRequestCaptured).jsonField("system") orelse return error.SystemFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, system, "# Skill preload: api-conv") != null);
    try std.testing.expect(std.mem.indexOf(u8, system, "PRELOAD_L2_MARKER: use camelCase response fields.") != null);
}

const MemoryProbe = struct {
    expected: []const u8,
    permission_seen: bool = false,
    additional_dir_seen: bool = false,
};

fn memoryProbe(ctx: *const cc.tool_context.ToolContext, _: []const u8, state_ptr: ?*anyopaque) anyerror![]u8 {
    const probe: *MemoryProbe = @ptrCast(@alignCast(state_ptr.?));
    if (ctx.permission_ctx) |p| probe.permission_seen = std.mem.eql(u8, p.memdir_abs, probe.expected);
    for (ctx.additional_dirs) |dir| {
        if (std.mem.eql(u8, dir, probe.expected)) probe.additional_dir_seen = true;
    }
    return ctx.allocator.dupe(u8, "{\"ok\":true}");
}

test "L2 AgentDef.memory_scope=project: prompt + tools + permission + sandbox dirs 同源" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    const expected = try std.fmt.allocPrint(a, "{s}/.metacodes/agent-memory/memory-agent-51d43e883ecfb483fa38290465fe0744", .{root});
    defer a.free(expected);

    const bodies = [_][]const u8{ MEM_PROBE_SSE, END_TURN_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try addAgent(a, &agents, "---\nname: memory-agent\ntools: MemProbe\nmemory: project\n---\nUse durable memory.");

    var probe = MemoryProbe{ .expected = expected };
    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("MemProbe", "inspect derived memory context", &.{}, memoryProbe, &probe, false);
    const defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(defs);
    const perm = cc.permission.createContext(.bypass_permissions, a);
    var ctx = baseContext(a, &client, &agents, &perm, defs);
    ctx.dyn_registry = &dyn;
    ctx.cwd_abs = root;
    ctx.project_dir = root;
    ctx.home_dir = root;

    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"memory-agent\",\"prompt\":\"go\"}");
    defer a.free(out);
    const req = srv.lastRequest() orelse return error.NoRequestCaptured;
    const system = req.jsonField("system") orelse return error.SystemFieldMissing;
    const tools = req.jsonField("tools") orelse return error.ToolsFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, system, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, system, "Persistent Agent Memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"Read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"Write\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"Edit\"") != null);
    try std.testing.expect(probe.permission_seen);
    try std.testing.expect(probe.additional_dir_seen);
    const expected_z = try a.dupeZ(u8, expected);
    defer a.free(expected_z);
    try std.testing.expect(cc.platform_fs.exists(expected_z.ptr));
}

const McpProbe = struct {
    count: usize = 0,
    saw_allowed: bool = false,
    saw_blocked: bool = false,
};

fn mcpProbe(ctx: *const cc.tool_context.ToolContext, _: []const u8, state_ptr: ?*anyopaque) anyerror![]u8 {
    const probe: *McpProbe = @ptrCast(@alignCast(state_ptr.?));
    if (ctx.mcp_sessions) |sessions| {
        probe.count = sessions.*.len;
        for (sessions.*) |entry| {
            if (std.mem.eql(u8, entry.name, "allowed")) probe.saw_allowed = true;
            if (std.mem.eql(u8, entry.name, "blocked")) probe.saw_blocked = true;
        }
    }
    return ctx.allocator.dupe(u8, "{\"ok\":true}");
}

test "L2 AgentDef.mcp_servers: 请求 tools 与子 ToolContext sessions 使用同一 allowlist" {
    const a = std.testing.allocator;
    const bodies = [_][]const u8{ MCP_PROBE_SSE, END_TURN_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try addAgent(a, &agents, "---\nname: mcp-agent\ntools: allowed__probe, blocked__probe, local__helper\nmcpServers: allowed\n---\nUse only allowed MCP.");

    var probe = McpProbe{};
    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.registerMcp("allowed__probe", "allowed MCP probe", &.{}, mcpProbe, &probe, "allowed");
    try dyn.registerMcp("blocked__probe", "blocked MCP probe", &.{}, mcpProbe, &probe, "blocked");
    // A legal non-MCP dynamic tool may contain `__`; mcpServers must not infer
    // provenance from the spelling and accidentally remove it.
    try dyn.register("local__helper", "local dynamic helper", &.{}, mcpProbe, &probe, false);
    const defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(defs);

    var dummy_allowed: cc.mcp_client.McpClient = undefined;
    var dummy_blocked: cc.mcp_client.McpClient = undefined;
    var sess_allowed = cc.mcp_registry_bridge.McpSession.init(a, &dummy_allowed);
    defer sess_allowed.deinit();
    var sess_blocked = cc.mcp_registry_bridge.McpSession.init(a, &dummy_blocked);
    defer sess_blocked.deinit();
    const allowed_name = try a.dupe(u8, "allowed");
    defer a.free(allowed_name);
    const blocked_name = try a.dupe(u8, "blocked");
    defer a.free(blocked_name);
    var entries = [_]cc.mcp_session.McpSessionEntry{
        .{ .name = allowed_name, .client = &dummy_allowed, .session = sess_allowed },
        .{ .name = blocked_name, .client = &dummy_blocked, .session = sess_blocked },
    };
    var session_slice: []cc.mcp_session.McpSessionEntry = &entries;
    const perm = cc.permission.createContext(.bypass_permissions, a);
    var ctx = baseContext(a, &client, &agents, &perm, defs);
    ctx.dyn_registry = &dyn;
    ctx.mcp_sessions = &session_slice;

    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"mcp-agent\",\"prompt\":\"go\"}");
    defer a.free(out);
    const tools = (srv.lastRequest() orelse return error.NoRequestCaptured).jsonField("tools") orelse return error.ToolsFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, tools, "allowed__probe") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "blocked__probe") == null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "local__helper") != null);
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    try std.testing.expect(probe.saw_allowed);
    try std.testing.expect(!probe.saw_blocked);

    // Execution-time boundary: sharing the parent DynRegistry must not make a
    // filtered MCP tool callable by guessing its exact name. ToolSearch must
    // apply the same ceiling and therefore cannot reveal/reactivate it either.
    const policy_defs = [_]cc.json_mod.ToolDefinition{
        .{ .name = "ToolSearch", .description = "", .input_schema = .{} },
        .{ .name = "allowed__probe", .description = "", .input_schema = .{}, .deferred = true },
    };
    var policy = cc.tool_context.ToolSetExecutionPolicy{ .definitions = &policy_defs };
    ctx.execution_policy = policy.executionPolicy();

    var allowed_out = try cc.tools.dispatch(&ctx, "allowed__probe", "{}");
    allowed_out.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), probe.count);

    try std.testing.expectError(
        error.ToolPolicyDenied,
        cc.tools.dispatch(&ctx, "blocked__probe", "{}"),
    );
    try std.testing.expectEqual(@as(usize, 2), probe.count);

    try std.testing.expectError(
        error.NoToolMatch,
        cc.tools.dispatch(&ctx, "ToolSearch", "{\"query\":\"select:blocked__probe\"}"),
    );
    var search_allowed = try cc.tools.dispatch(
        &ctx,
        "ToolSearch",
        "{\"query\":\"select:allowed__probe\"}",
    );
    defer search_allowed.deinit(a);
    switch (search_allowed) {
        .ok => |body| try std.testing.expect(std.mem.indexOf(u8, body.@"inline".bytes, "allowed__probe") != null),
        else => return error.UnexpectedDispatchOutcome,
    }
}

const BackgroundProbe = struct {
    repo: []const u8,
    memory: []const u8,
    isolated_cwd_seen: bool = false,
    memory_seen: bool = false,
    allowed_mcp_only: bool = false,
};

fn backgroundProbe(ctx: *const cc.tool_context.ToolContext, _: []const u8, state_ptr: ?*anyopaque) anyerror![]u8 {
    const probe: *BackgroundProbe = @ptrCast(@alignCast(state_ptr.?));
    probe.isolated_cwd_seen = ctx.cwd_abs.len > 0 and !std.mem.eql(u8, ctx.cwd_abs, probe.repo);
    probe.memory_seen = if (ctx.permission_ctx) |p| std.mem.eql(u8, p.memdir_abs, probe.memory) else false;
    if (ctx.mcp_sessions) |sessions| {
        probe.allowed_mcp_only = sessions.*.len == 1 and std.mem.eql(u8, sessions.*[0].name, "allowed");
    }
    return ctx.allocator.dupe(u8, "{\"ok\":true}");
}

fn lockWorktreeProbe(ctx: *const cc.tool_context.ToolContext, _: []const u8, _: ?*anyopaque) anyerror![]u8 {
    if (!runGit(ctx.allocator, ctx.cwd_abs, &.{ "worktree", "lock", ctx.cwd_abs })) {
        return error.LockWorktreeFailed;
    }
    return ctx.allocator.dupe(u8, "{\"locked\":true}");
}

test "L2 后台组合: effort/memory_scope/mcp_servers/isolation 穿过 JobInput 且终态原子" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var base_buf: [160]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "/tmp/metacodes-agentdef-background-{d}", .{cc.util_time.nowNs()});
    defer cc.util_fs.testing.rmrfBestEffort(base);
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{base});
    defer a.free(repo);
    const home = try std.fmt.allocPrint(a, "{s}/home", .{base});
    defer a.free(home);
    try cc.util_fs.mkdirParents(repo);
    try cc.util_fs.mkdirParents(home);
    const repo_canon = try canonicalPath(a, repo);
    defer a.free(repo_canon);
    const memory = try std.fmt.allocPrint(a, "{s}/.metacodes/agent-memory/background-all-c217f584b787b9426ac709c7188b02a6", .{repo_canon});
    defer a.free(memory);
    if (!runGit(a, repo, &.{ "init", "-q" })) return error.SkipZigTest;
    _ = runGit(a, repo, &.{ "config", "user.email", "test@metacodes.local" });
    _ = runGit(a, repo, &.{ "config", "user.name", "metacodes-test" });
    const seed = try std.fmt.allocPrint(a, "{s}/README", .{repo});
    defer a.free(seed);
    try writeFile(seed, "seed\n");
    _ = runGit(a, repo, &.{ "add", "-A" });
    if (!runGit(a, repo, &.{ "commit", "-q", "-m", "seed" })) return error.SkipZigTest;

    const bodies = [_][]const u8{ BG_PROBE_SSE, END_TURN_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try addAgent(a, &agents, "---\nname: background-all\ntools: BgProbe\nbackground: true\neffort: high\nmemory: project\nmcpServers: allowed\nisolation: worktree\n---\nExercise every background field.");

    var bg_probe = BackgroundProbe{ .repo = repo, .memory = memory };
    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("BgProbe", "inspect background derived context", &.{}, backgroundProbe, &bg_probe, false);
    const defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(defs);

    var dummy_allowed: cc.mcp_client.McpClient = undefined;
    var dummy_blocked: cc.mcp_client.McpClient = undefined;
    var sess_allowed = cc.mcp_registry_bridge.McpSession.init(a, &dummy_allowed);
    defer sess_allowed.deinit();
    var sess_blocked = cc.mcp_registry_bridge.McpSession.init(a, &dummy_blocked);
    defer sess_blocked.deinit();
    const allowed_name = try a.dupe(u8, "allowed");
    defer a.free(allowed_name);
    const blocked_name = try a.dupe(u8, "blocked");
    defer a.free(blocked_name);
    var entries = [_]cc.mcp_session.McpSessionEntry{
        .{ .name = allowed_name, .client = &dummy_allowed, .session = sess_allowed },
        .{ .name = blocked_name, .client = &dummy_blocked, .session = sess_blocked },
    };
    var session_slice: []cc.mcp_session.McpSessionEntry = &entries;
    const perm = cc.permission.createContext(.bypass_permissions, a);
    var jobs = try cc.agent_job_registry.AgentJobRegistry.init(a, "k", url, "claude-sonnet-4-20250514", .anthropic);
    defer jobs.deinit();
    var ctx = baseContext(a, &client, &agents, &perm, defs);
    ctx.agent_jobs = &jobs;
    ctx.dyn_registry = &dyn;
    ctx.mcp_sessions = &session_slice;
    ctx.cwd_abs = repo;
    ctx.project_dir = repo;
    ctx.home_dir = home;

    const spawn_out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"background-all\",\"prompt\":\"go\"}");
    defer a.free(spawn_out);
    const job_id = try extractJsonString(a, spawn_out, "agent_job_id");
    defer a.free(job_id);
    const worktree_path = try extractJsonString(a, spawn_out, "worktree_path");
    defer a.free(worktree_path);
    const query = try std.fmt.allocPrint(a, "{{\"agent_job_id\":\"{s}\"}}", .{job_id});
    defer a.free(query);

    var terminal: ?[]u8 = null;
    defer if (terminal) |value| a.free(value);
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        const status = try cc.task_output_tool.execute(&ctx, query);
        if (std.mem.indexOf(u8, status, "\"status\":\"done\"") != null) {
            terminal = status;
            break;
        }
        a.free(status);
        cc.util_time.sleepMs(10);
    }
    const done = terminal orelse return error.BackgroundDidNotFinish;
    try std.testing.expect(std.mem.indexOf(u8, done, "\"worktree_kept\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, done, "\"worktree_cleanup_complete\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, done, worktree_path) != null);
    try std.testing.expect(bg_probe.isolated_cwd_seen);
    try std.testing.expect(bg_probe.memory_seen);
    try std.testing.expect(bg_probe.allowed_mcp_only);
    const body = (srv.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output_config\":{\"effort\":\"high\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, memory) != null);
    const worktree_z = try a.dupeZ(u8, worktree_path);
    defer a.free(worktree_z);
    try std.testing.expect(!cc.platform_fs.exists(worktree_z.ptr));
}

test "L3 AgentDef.isolation=worktree: 相对 Write 只落隔离树，有变化则返回并保留路径" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var base_buf: [160]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "/tmp/metacodes-agentdef-isolation-{d}", .{cc.util_time.nowNs()});
    defer cc.util_fs.testing.rmrfBestEffort(base);
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{base});
    defer a.free(repo);
    const home = try std.fmt.allocPrint(a, "{s}/home", .{base});
    defer a.free(home);
    try cc.util_fs.mkdirParents(repo);
    try cc.util_fs.mkdirParents(home);
    if (!runGit(a, repo, &.{ "init", "-q" })) return error.SkipZigTest;
    _ = runGit(a, repo, &.{ "config", "user.email", "test@metacodes.local" });
    _ = runGit(a, repo, &.{ "config", "user.name", "metacodes-test" });
    const seed = try std.fmt.allocPrint(a, "{s}/README", .{repo});
    defer a.free(seed);
    try writeFile(seed, "seed\n");
    _ = runGit(a, repo, &.{ "add", "-A" });
    if (!runGit(a, repo, &.{ "commit", "-q", "-m", "seed" })) return error.SkipZigTest;

    const bodies = [_][]const u8{ WRITE_SSE, END_TURN_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try addAgent(a, &agents, "---\nname: isolated-agent\ntools: Write\nisolation: worktree\n---\nWrite only in your worktree.");
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    const perm = cc.permission.createContext(.bypass_permissions, a);
    var ctx = baseContext(a, &client, &agents, &perm, defs);
    ctx.cwd_abs = repo;
    ctx.project_dir = repo;
    ctx.home_dir = home;

    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"isolated-agent\",\"prompt\":\"write it\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"worktree_kept\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"worktree_cleanup_complete\":true") != null);
    const worktree_path = try extractJsonString(a, out, "worktree_path");
    defer a.free(worktree_path);
    defer cc.swarm_teammate_process.removeWorktree(a, worktree_path, repo, null);

    const parent_file = try std.fmt.allocPrint(a, "{s}/agent-output.txt", .{repo});
    defer a.free(parent_file);
    const isolated_file = try std.fmt.allocPrint(a, "{s}/agent-output.txt", .{worktree_path});
    defer a.free(isolated_file);
    const parent_z = try a.dupeZ(u8, parent_file);
    defer a.free(parent_z);
    const isolated_z = try a.dupeZ(u8, isolated_file);
    defer a.free(isolated_z);
    try std.testing.expect(!cc.platform_fs.exists(parent_z.ptr));
    try std.testing.expect(cc.platform_fs.exists(isolated_z.ptr));
}

test "L2 AgentDef isolation cleanup failure reports worktree_kept true" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var base_buf: [160]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "/tmp/metacodes-agentdef-cleanup-{d}", .{cc.util_time.nowNs()});
    defer cc.util_fs.testing.rmrfBestEffort(base);
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{base});
    defer a.free(repo);
    const home = try std.fmt.allocPrint(a, "{s}/home", .{base});
    defer a.free(home);
    try cc.util_fs.mkdirParents(repo);
    try cc.util_fs.mkdirParents(home);
    if (!runGit(a, repo, &.{ "init", "-q" })) return error.SkipZigTest;
    _ = runGit(a, repo, &.{ "config", "user.email", "test@metacodes.local" });
    _ = runGit(a, repo, &.{ "config", "user.name", "metacodes-test" });
    const seed = try std.fmt.allocPrint(a, "{s}/README", .{repo});
    defer a.free(seed);
    try writeFile(seed, "seed\n");
    _ = runGit(a, repo, &.{ "add", "-A" });
    if (!runGit(a, repo, &.{ "commit", "-q", "-m", "seed" })) return error.SkipZigTest;

    const bodies = [_][]const u8{ LOCK_WORKTREE_SSE, END_TURN_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try addAgent(a, &agents, "---\nname: cleanup-agent\ntools: LockWorktree\nisolation: worktree\n---\nLock the worktree to simulate cleanup failure.");
    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("LockWorktree", "lock current test worktree", &.{}, lockWorktreeProbe, null, false);
    const defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(defs);
    const perm = cc.permission.createContext(.bypass_permissions, a);
    var ctx = baseContext(a, &client, &agents, &perm, defs);
    ctx.dyn_registry = &dyn;
    ctx.cwd_abs = repo;
    ctx.project_dir = repo;
    ctx.home_dir = home;

    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"cleanup-agent\",\"prompt\":\"lock it\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"worktree_kept\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"worktree_cleanup_complete\":false") != null);
    const worktree_path = try extractJsonString(a, out, "worktree_path");
    defer a.free(worktree_path);
    const worktree_z = try a.dupeZ(u8, worktree_path);
    defer a.free(worktree_z);
    try std.testing.expect(cc.platform_fs.exists(worktree_z.ptr));
    try std.testing.expect(runGit(a, repo, &.{ "worktree", "unlock", worktree_path }));
    try cc.swarm_teammate_process.removeWorktreeStrict(a, worktree_path, repo, null);
}

fn extractJsonString(a: std.mem.Allocator, json: []const u8, key: []const u8) ![]u8 {
    const needle = try std.fmt.allocPrint(a, "\"{s}\":\"", .{key});
    defer a.free(needle);
    const at = std.mem.indexOf(u8, json, needle) orelse return error.JsonFieldMissing;
    const start = at + needle.len;
    const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return error.JsonFieldMissing;
    return a.dupe(u8, json[start..end]);
}

fn canonicalPath(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = cc.platform_fs.realpath(path_z.ptr, &out) orelse return error.RealpathFailed;
    return a.dupe(u8, std.mem.span(@as([*:0]u8, @ptrCast(resolved))));
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(z);
    const fd = cc.platform_fs.openZ(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch return error.WriteFailed;
    defer cc.platform_fs.close(fd);
    if (cc.platform_fs.write(fd, content) != @as(isize, @intCast(content.len))) return error.WriteFailed;
}

fn runGit(a: std.mem.Allocator, cwd: []const u8, args: []const []const u8) bool {
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        for (argv.items) |item| if (item) |z| a.free(std.mem.span(z));
        argv.deinit(a);
    }
    argv.append(a, (a.dupeZ(u8, "/usr/bin/env") catch return false).ptr) catch return false;
    argv.append(a, (a.dupeZ(u8, "git") catch return false).ptr) catch return false;
    argv.append(a, (a.dupeZ(u8, "-C") catch return false).ptr) catch return false;
    argv.append(a, (a.dupeZ(u8, cwd) catch return false).ptr) catch return false;
    for (args) |arg| argv.append(a, (a.dupeZ(u8, arg) catch return false).ptr) catch return false;
    argv.append(a, null) catch return false;
    const out = cc.tools_common.spawnCaptureWithStderrTimed(argv.items, a, null, 15_000, null, cc.tools_common.MAX_SPAWN_CAPTURE_BYTES, null) catch return false;
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    return out.exit_code == 0;
}
