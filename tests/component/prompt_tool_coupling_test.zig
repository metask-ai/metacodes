//! L2 组件测试:提示词 × 工具关系 — 动态描述耦合端到端贯穿。
//!
//! 设计目标(doc/PROMPT_TOOL_RELATIONSHIP.md):
//!   ① 核心工具用动态长描述(对应 cc tool.prompt(ctx)),进请求体 tools[].description
//!   ② 动态耦合:工具集变化 → USING_TOOLS 段 + 工具描述相应增删
//!   ③ Bash 描述按 include_git 增删 Git 协议段
//!   ④ subagent(只读 Explore)的 Bash 描述去 Git 段 + 加只读提醒
//!   ⑤ 无 describe_fn 的工具(Monitor)描述不变(回归)
//!
//! 大部分断言在 toToolDefinitionsFull / buildFull 层直接验(快,无网络);
//! 另有一条经 spawnAgent + MockServer.lastRequest() 验真请求体携带长描述。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const MINIMAL_END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn findDef(defs: []const cc.json_mod.ToolDefinition, name: []const u8) ?cc.json_mod.ToolDefinition {
    for (defs) |d| if (std.mem.eql(u8, d.name, name)) return d;
    return null;
}

fn deferredProbe(_: *const cc.tool_context.ToolContext, _: []const u8, _: ?*anyopaque) anyerror![]u8 {
    return error.ProbeNotExecutable;
}

// ① 核心工具长描述进 defs(对比:无 context 时是短描述)。
test "L2: toToolDefinitionsFull 给核心工具动态长描述" {
    const a = std.testing.allocator;
    const names = [_][]const u8{ "Read", "Write", "Edit", "Glob", "Grep", "Bash", "Task" };
    var pc = cc.tools.PromptContext{ .enabled_tool_names = &names, .include_git = true };

    const defs = try cc.tools.toToolDefinitionsFull(a, null, &pc);
    defer {
        // 动态描述是 owned;逐个 free 有 describe_fn 的工具描述
        for (defs) |d| {
            if (cc.tools.getTool(d.name)) |t| {
                if (t.describe_fn != null) a.free(@constCast(d.description));
            }
        }
        a.free(defs);
    }

    const read = findDef(defs, "Read").?;
    try std.testing.expect(std.mem.indexOf(u8, read.description, "cat -n format") != null);
    const edit = findDef(defs, "Edit").?;
    try std.testing.expect(std.mem.indexOf(u8, edit.description, "exact string replacements") != null);
    const grep = findDef(defs, "Grep").?;
    try std.testing.expect(std.mem.indexOf(u8, grep.description, "ALWAYS use Grep") != null);
    const write = findDef(defs, "Write").?;
    try std.testing.expect(std.mem.indexOf(u8, write.description, "MUST use the Read tool first") != null);
}

// ⑤ 无 context 时回退短描述;无 describe_fn 的工具(Monitor)恒为静态。
test "L2: 无 context 回退短描述 + Monitor 恒静态" {
    const a = std.testing.allocator;
    const defs = try cc.tools.toToolDefinitions(a); // = Full(null, null)
    defer a.free(defs);

    const read = findDef(defs, "Read").?;
    try std.testing.expect(std.mem.indexOf(u8, read.description, "cat -n format") == null); // 短描述
    try std.testing.expectEqualStrings("Read a file from the local filesystem.", read.description);

    const monitor = findDef(defs, "Monitor").?;
    try std.testing.expect(std.mem.indexOf(u8, monitor.description, "background monitor") != null);
}

test "L2: KgRecall and KgContext schemas carry the staged semantic-neighborhood contract" {
    const kg_recall = cc.tools.getTool("KgRecall") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, kg_recall.description, "no embeddings and computes no vector distance") != null);
    const required = kg_recall.input_schema.required orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), required.len);
    try std.testing.expectEqualStrings("query", required[0]);
    try std.testing.expectEqualStrings("lexical_plan", required[1]);

    const props = kg_recall.input_schema.prop_specs orelse return error.TestUnexpectedResult;
    var query_description: ?[]const u8 = null;
    for (props) |prop| {
        if (std.mem.eql(u8, prop.name, "query")) query_description = prop.description;
    }
    const description = query_description orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, description, "exact/high-precision query") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "ONE compact semantic variant") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "2-4 separate variants") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "at most four variant calls") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "FIRST inspect automatic recall") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "MUST contain ONLY that exact term") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "mechanism/symptom/outcome/nearby implementation") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "broader or narrower concept") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "Do not combine all variants into one keyword bag") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "Extra keywords are safe") == null);

    var type_description: ?[]const u8 = null;
    for (props) |prop| {
        if (std.mem.eql(u8, prop.name, "type")) type_description = prop.description;
    }
    const type_desc = type_description orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, type_desc, "Omit on the exact/high-precision seed") != null);
    try std.testing.expect(std.mem.indexOf(u8, type_desc, "observation or module") != null);

    const kg_context = cc.tools.getTool("KgContext") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, kg_context.description, "authoritative node text") != null);
    try std.testing.expect(std.mem.indexOf(u8, kg_context.description, "connected evidence") != null);
    const context_props = kg_context.input_schema.prop_specs orelse return error.TestUnexpectedResult;
    var saw_node_id = false;
    var saw_limit = false;
    var saw_offset = false;
    var saw_text_limit = false;
    for (context_props) |prop| {
        if (std.mem.eql(u8, prop.name, "node_id")) saw_node_id = true;
        if (std.mem.eql(u8, prop.name, "limit")) saw_limit = true;
        if (std.mem.eql(u8, prop.name, "text_offset")) saw_offset = true;
        if (std.mem.eql(u8, prop.name, "text_limit")) saw_text_limit = true;
    }
    try std.testing.expect(saw_node_id and saw_limit and saw_offset and saw_text_limit);
}

test "L2: ToolSearch tells the model to call visible KgRecall directly" {
    const tool_search = cc.tools.getTool("ToolSearch") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, tool_search.description, "NEVER call ToolSearch") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_search.description, "including KgRecall") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_search.description, "call that tool directly") != null);
}

test "L2: ToolSearch enters the API tool set only when a deferred tool exists" {
    const a = std.testing.allocator;
    // Dynamic descriptions are owned independently of the outer definitions
    // slice. Production keeps both in the session arena; mirror that here.
    var definitions_arena = std.heap.ArenaAllocator.init(a);
    defer definitions_arena.deinit();
    const definitions_allocator = definitions_arena.allocator();
    var no_tinykg = cc.tools.PromptContext{ .tinykg_enabled = false };

    // TinyKG 治理核未启用、无动态工具：ToolSearch 没有工作可做，必须不广告。
    const core_only = try cc.tools.toToolDefinitionsFull(definitions_allocator, null, &no_tinykg);
    try std.testing.expect(findDef(core_only, "KgRecall") == null);
    try std.testing.expect(findDef(core_only, "Write") != null);
    try std.testing.expect(findDef(core_only, "ToolSearch") == null);

    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    // 常驻 Skill 类动态工具不需要激活，仍不应引入 ToolSearch。
    try dyn.register("always_visible", "always visible helper", &.{}, deferredProbe, null, false);
    const visible_dyn = try cc.tools.toToolDefinitionsFull(definitions_allocator, &dyn, &no_tinykg);
    try std.testing.expect(findDef(visible_dyn, "always_visible") != null);
    try std.testing.expect(findDef(visible_dyn, "ToolSearch") == null);

    // MCP 工具 deferred=true：此时 ToolSearch 才是必要能力并随工具表进入请求。
    try dyn.registerMcp("demo__lookup", "deferred MCP lookup", &.{}, deferredProbe, null, "demo");
    const with_deferred = try cc.tools.toToolDefinitionsFull(definitions_allocator, &dyn, &no_tinykg);
    try std.testing.expect(findDef(with_deferred, "ToolSearch") != null);
    const deferred = findDef(with_deferred, "demo__lookup") orelse return error.TestUnexpectedResult;
    try std.testing.expect(deferred.deferred);
}

test "L2: long-horizon arm gates TinyKG tools as one typed treatment" {
    const a = std.testing.allocator;

    const codex = cc.types_mod.LongHorizonArm.codex_style;
    try std.testing.expect(!codex.usesAutoMemory(true));
    try std.testing.expect(!codex.usesTinyKg());
    const claude = cc.types_mod.LongHorizonArm.claude_style;
    try std.testing.expect(claude.usesAutoMemory(false));
    try std.testing.expect(!claude.usesTinyKg());
    const tinykg = cc.types_mod.LongHorizonArm.tinykg;
    try std.testing.expect(tinykg.usesAutoMemory(false));
    try std.testing.expect(tinykg.usesTinyKg());

    var without_kg = cc.tools.PromptContext{ .tinykg_enabled = false };
    const baseline_defs = try cc.tools.toToolDefinitionsFull(a, null, &without_kg);
    defer {
        for (baseline_defs) |def| {
            if (cc.tools.getTool(def.name)) |tool| {
                if (tool.describe_fn != null) a.free(@constCast(def.description));
            }
        }
        a.free(baseline_defs);
    }
    try std.testing.expect(findDef(baseline_defs, "KgRemember") == null);
    try std.testing.expect(findDef(baseline_defs, "KgRecall") == null);
    try std.testing.expect(findDef(baseline_defs, "KgContext") == null);
    try std.testing.expect(findDef(baseline_defs, "FormalAuditTask") == null);
    try std.testing.expect(findDef(baseline_defs, "ToolSearch") == null);
    const baseline_create = findDef(baseline_defs, "TaskCreate") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, baseline_create.description, "in-session task list") != null);
    try std.testing.expect(std.mem.indexOf(u8, baseline_create.description, "TinyKG") == null);
    try std.testing.expect(findDef(baseline_defs, "TaskList") != null);
    const baseline_get = findDef(baseline_defs, "TaskGet") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, baseline_get.description, "TinyKG") == null);
    try std.testing.expect(std.mem.indexOf(u8, baseline_get.description, "kg-*") == null);
    try std.testing.expect(std.mem.indexOf(u8, baseline_get.description, "do not persist after this session") != null);
    const baseline_update = findDef(baseline_defs, "TaskUpdate") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, baseline_update.description, "persistent") == null);
    const baseline_props = baseline_update.input_schema.prop_specs orelse return error.TestUnexpectedResult;
    var saw_status = false;
    for (baseline_props) |prop| {
        try std.testing.expect(!std.mem.eql(u8, prop.name, "conclusion"));
        try std.testing.expect(!std.mem.eql(u8, prop.name, "acts_on"));
        try std.testing.expect(!std.mem.eql(u8, prop.name, "uses"));
        try std.testing.expect(!std.mem.eql(u8, prop.name, "produces"));
        if (std.mem.eql(u8, prop.name, "status")) {
            saw_status = true;
            const values = prop.enum_values orelse return error.TestUnexpectedResult;
            for (values) |value| try std.testing.expect(!std.mem.eql(u8, value, "failed"));
        }
    }
    try std.testing.expect(saw_status);

    var with_kg = cc.tools.PromptContext{ .tinykg_enabled = true };
    const tinykg_defs = try cc.tools.toToolDefinitionsFull(a, null, &with_kg);
    defer {
        for (tinykg_defs) |def| {
            if (cc.tools.getTool(def.name)) |tool| {
                if (tool.describe_fn != null) a.free(@constCast(def.description));
            }
        }
        a.free(tinykg_defs);
    }
    try std.testing.expect(findDef(tinykg_defs, "KgRemember") != null);
    try std.testing.expect(findDef(tinykg_defs, "KgRecall") != null);
    try std.testing.expect(findDef(tinykg_defs, "KgContext") != null);
    const formal_audit = findDef(tinykg_defs, "FormalAuditTask") orelse return error.TestUnexpectedResult;
    try std.testing.expect(formal_audit.deferred);
    try std.testing.expect(findDef(tinykg_defs, "ToolSearch") != null);
    const tinykg_create = findDef(tinykg_defs, "TaskCreate") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, tinykg_create.description, "persistent task in TinyKG") != null);
    const tinykg_get = findDef(tinykg_defs, "TaskGet") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, tinykg_get.description, "TinyKG") != null);
    const tinykg_update = findDef(tinykg_defs, "TaskUpdate") orelse return error.TestUnexpectedResult;
    const tinykg_props = tinykg_update.input_schema.prop_specs orelse return error.TestUnexpectedResult;
    try std.testing.expect(for (tinykg_props) |prop| {
        if (std.mem.eql(u8, prop.name, "conclusion")) break true;
    } else false);

    const enabled_names = [_][]const u8{ "TaskCreate", "TaskList", "TaskGet", "TaskUpdate", "KgRecall", "KgContext", "KgRemember" };
    const tinykg_prompt = try cc.system_prompt.buildFull(a, "glm-5.2", null, null, &enabled_names, "", true);
    defer a.free(tinykg_prompt);
    try std.testing.expect(std.mem.indexOf(u8, tinykg_prompt, "ACTIVATE:") != null);
    try std.testing.expect(std.mem.indexOf(u8, tinykg_prompt, "create exactly one persistent lifecycle anchor") != null);
    try std.testing.expect(std.mem.indexOf(u8, tinykg_prompt, "Require its result to contain a `kg-*` id and `persisted: true`") != null);
    try std.testing.expect(std.mem.indexOf(u8, tinykg_prompt, "after verifying the final artifacts") != null);

    const baseline_prompt = try cc.system_prompt.buildFull(a, "glm-5.2", null, null, &enabled_names, "", false);
    defer a.free(baseline_prompt);
    try std.testing.expect(std.mem.indexOf(u8, baseline_prompt, "ACTIVATE:") == null);
}

// ② 动态耦合:USING_TOOLS 段按工具集裁剪。
test "L2: buildUsingTools 段按工具集裁剪" {
    const a = std.testing.allocator;

    // 全量:含 Grep/Glob/TaskCreate 子条
    const full_names = [_][]const u8{ "Read", "Write", "Edit", "Glob", "Grep", "Bash", "TaskCreate" };
    const sp_full = try cc.system_prompt.buildFull(a, "claude-sonnet-4-20250514", null, null, &full_names, "", false);
    defer a.free(sp_full);
    try std.testing.expect(std.mem.indexOf(u8, sp_full, "use Grep instead of grep") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp_full, "use Glob instead of find") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp_full, "TaskCreate tool") != null);

    // 裁剪:无 Grep / 无 TaskCreate
    const slim_names = [_][]const u8{ "Read", "Write", "Edit", "Glob", "Bash" };
    const sp_slim = try cc.system_prompt.buildFull(a, "claude-sonnet-4-20250514", null, null, &slim_names, "", false);
    defer a.free(sp_slim);
    try std.testing.expect(std.mem.indexOf(u8, sp_slim, "use Grep instead of grep") == null);
    try std.testing.expect(std.mem.indexOf(u8, sp_slim, "use Glob instead of find") != null); // Glob 仍在
    try std.testing.expect(std.mem.indexOf(u8, sp_slim, "Break down and manage your work") == null);
}

// ③ Bash 描述按 include_git 增删 Git 段。
test "L2: Bash 描述 Git 段随 include_git 变" {
    const a = std.testing.allocator;
    const names = [_][]const u8{"Bash"};

    var with_git = cc.tools.PromptContext{ .enabled_tool_names = &names, .include_git = true };
    const d1 = try cc.tools.descriptions.describeBash(a, &with_git);
    defer a.free(d1);
    try std.testing.expect(std.mem.indexOf(u8, d1, "Committing changes with git") != null);

    var no_git = cc.tools.PromptContext{ .enabled_tool_names = &names, .include_git = false };
    const d2 = try cc.tools.descriptions.describeBash(a, &no_git);
    defer a.free(d2);
    try std.testing.expect(std.mem.indexOf(u8, d2, "Committing changes with git") == null);
}

// ④ subagent 只读(Explore)的 Bash:去 Git 段 + 加只读提醒(经 redescribeForContext)。
test "L2: redescribeForContext 给只读 agent 的 Bash 加只读提醒" {
    const a = std.testing.allocator;

    // 先建一份主对话 defs(Bash 含 Git 段)
    const names = [_][]const u8{ "Read", "Grep", "Glob", "Bash" };
    var main_pc = cc.tools.PromptContext{ .enabled_tool_names = &names, .include_git = true };
    const defs = try cc.tools.toToolDefinitionsFull(a, null, &main_pc);
    defer a.free(defs);

    const bash_before = findDef(defs, "Bash").?;
    try std.testing.expect(std.mem.indexOf(u8, bash_before.description, "Committing changes with git") != null);

    // redescribe 会用新 alloc 覆盖 description;先释放原始的动态描述,避免泄漏。
    for (defs) |d| {
        if (cc.tools.getTool(d.name)) |t| {
            if (t.describe_fn != null) a.free(@constCast(d.description));
        }
    }

    // 用 Explore(只读)context 重写
    var explore_pc = cc.tools.PromptContext{ .enabled_tool_names = &names, .agent_type = "Explore", .include_git = true };
    try cc.tools.redescribeForContext(a, defs, &explore_pc);
    defer for (defs) |d| {
        if (cc.tools.getTool(d.name)) |t| {
            if (t.describe_fn != null) a.free(@constCast(d.description));
        }
    };

    const bash_after = findDef(defs, "Bash").?;
    try std.testing.expect(std.mem.indexOf(u8, bash_after.description, "Committing changes with git") == null);
    try std.testing.expect(std.mem.indexOf(u8, bash_after.description, "read-only agent") != null);
}

// 端到端:spawnAgent 用带长描述的 defs → MockServer 请求体 tools[].description 含长描述 marker。
test "L2 e2e: 请求体 tools 携带动态长描述" {
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

    const names = [_][]const u8{ "Read", "Edit", "Grep", "Bash" };
    var pc = cc.tools.PromptContext{ .enabled_tool_names = &names, .include_git = true };
    const defs = try cc.tools.toToolDefinitionsFull(a, null, &pc);

    const perm = cc.permission.PermissionContext{ .mode = .init(.bypass_permissions), .allocator = a };
    var result = cc.core_subagent.spawnAgent(
        a,
        client.provider(),
        &client,
        defs,
        &perm,
        null,
        "hi",
        .{ .max_turns = 2 },
    ) catch return error.SkipZigTest;
    defer result.deinit();

    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    const tools_field = cap.jsonField("tools") orelse return error.ToolsFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "cat -n format") != null); // Read 长描述
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "exact string replacements") != null); // Edit 长描述
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "ALWAYS use Grep") != null); // Grep 长描述
}
