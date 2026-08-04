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

test "L2: KgRecall schema carries the bounded lexical-bridge contract" {
    const kg_recall = cc.tools.getTool("KgRecall") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, kg_recall.description, "no embeddings and computes no vector distance") != null);

    const props = kg_recall.input_schema.prop_specs orelse return error.TestUnexpectedResult;
    var query_description: ?[]const u8 = null;
    for (props) |prop| {
        if (std.mem.eql(u8, prop.name, "query")) query_description = prop.description;
    }
    const description = query_description orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, description, "3-8 intent-preserving") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "FIRST inspect automatic recall") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "MUST contain ONLY that exact term") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "label every term U") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "DELETE every unlabeled term") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "Topically related implementation guesses are not paraphrases") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "At most TWO explicit calls total") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "Extra keywords are safe") == null);

    var type_description: ?[]const u8 = null;
    for (props) |prop| {
        if (std.mem.eql(u8, prop.name, "type")) type_description = prop.description;
    }
    const type_desc = type_description orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, type_desc, "NEVER set this on the first explicit KgRecall") != null);
    try std.testing.expect(std.mem.indexOf(u8, type_desc, "observation or module") != null);
}

test "L2: ToolSearch tells the model to call visible KgRecall directly" {
    const tool_search = cc.tools.getTool("ToolSearch") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, tool_search.description, "NEVER call ToolSearch") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_search.description, "including KgRecall") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_search.description, "call that tool directly") != null);
}

test "L2: ToolSearch enters the API tool set only when a deferred tool exists" {
    const a = std.testing.allocator;

    // 无动态工具：KgRecall/Write 常驻可调，ToolSearch 没有工作可做，必须不广告。
    const core_only = try cc.tools.toToolDefinitionsFull(a, null, null);
    defer a.free(core_only);
    try std.testing.expect(findDef(core_only, "KgRecall") != null);
    try std.testing.expect(findDef(core_only, "Write") != null);
    try std.testing.expect(findDef(core_only, "ToolSearch") == null);

    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    // 常驻 Skill 类动态工具不需要激活，仍不应引入 ToolSearch。
    try dyn.register("always_visible", "always visible helper", &.{}, deferredProbe, null, false);
    const visible_dyn = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(visible_dyn);
    try std.testing.expect(findDef(visible_dyn, "always_visible") != null);
    try std.testing.expect(findDef(visible_dyn, "ToolSearch") == null);

    // MCP 工具 deferred=true：此时 ToolSearch 才是必要能力并随工具表进入请求。
    try dyn.registerMcp("demo__lookup", "deferred MCP lookup", &.{}, deferredProbe, null, "demo");
    const with_deferred = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(with_deferred);
    try std.testing.expect(findDef(with_deferred, "ToolSearch") != null);
    const deferred = findDef(with_deferred, "demo__lookup") orelse return error.TestUnexpectedResult;
    try std.testing.expect(deferred.deferred);
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
