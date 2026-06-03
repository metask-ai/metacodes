//! Task 工具(Agent 兼容别名):父 agent spawn 子 agent。
//!
//! 完整规范见 doc/SUBAGENT_DESIGN.md(第 5 节)。
//!
//! Schema(已实现):
//! - subagent_type:str (必需) — Explore / Plan / general-purpose / <custom name>
//! - description:str  (必需) — 3-5 词 UI 标签
//! - prompt:str       (必需) — 委托消息
//! - max_turns:int    (可选) — 单次 spawn 覆盖子 agent 最大轮数
//! - model:str        (可选) — 单次 spawn 覆盖 model(haiku/sonnet/opus/全名/inherit)
//! - run_in_background:bool (可选) — true 则不阻塞,spawn 后台线程(agent_job_registry)
//!   立即返回 {agent_job_id, status:running};用 TaskOutput 轮询增量输出 / TaskStop 终止。
//!
//! 未实现:
//! - isolation:"worktree"   — 需要真 git worktree spawn + 清理。P3。当前**不解析**,传了无效果。
//!   不要在 schema required 里声明它。
//!
//! 兼容:不带 subagent_type 但带 prompt 时,等同 subagent_type="general-purpose"(旧 Agent 工具语义)。

const std = @import("std");
const ToolContext = @import("context.zig").ToolContext;
const subagent = @import("../core/subagent.zig");
const util_json = @import("../util/json.zig");
const filter_mod = @import("../agents/filter.zig");

/// 最深嵌套层数。parent=0,孙=2;>= 这个值就拒绝 spawn。
/// 嵌套 subagent 是允许的(子 agent 也能调 Task),但深度有限保护栈。
/// pub:skills/tool.zig 的 context:fork 分支复用同一深度上限。
pub const MAX_AGENT_DEPTH: u8 = 3;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    // Precondition: depth guard
    if (ctx.agent_depth >= MAX_AGENT_DEPTH) return error.AgentDepthExceeded;

    const api_client = ctx.api_client orelse return error.AgentUnavailable;
    const tool_defs = ctx.tool_defs orelse return error.AgentUnavailable;
    const perm = ctx.permission_ctx orelse return error.AgentUnavailable;

    // 缺 prompt:返回**具名** error(对齐 Bash=MissingCommand / Grep=MissingPattern 约定),
    // 让 agent_loop 的 "{name} failed with MissingPrompt" 现场告诉模型缺哪个字段,
    // 而非笼统 MissingField(模型据此原地空参重试,见 e2e Task input={} 风暴)。
    const prompt_raw = util_json.extractStringField(args, "prompt") orelse return error.MissingPrompt;
    const prompt = try util_json.unescapeString(prompt_raw, ctx.allocator);
    defer ctx.allocator.free(prompt);

    // subagent_type:缺省 "general-purpose"(向后兼容旧 Agent 调用)
    const subagent_type_raw = util_json.extractStringField(args, "subagent_type") orelse "general-purpose";

    // 找 AgentDef(builtin + personal + project)
    var maybe_def: ?*const @import("../agents/def.zig").AgentDef = null;
    if (ctx.agents) |as| {
        maybe_def = as.find(subagent_type_raw);
    }

    // 没找到 — 用 general-purpose 兜底(但若 general-purpose 也没注册说明 AgentSet 未挂)
    var fallback_def: ?*const @import("../agents/def.zig").AgentDef = null;
    if (maybe_def == null and ctx.agents != null) {
        fallback_def = ctx.agents.?.find("general-purpose");
    }
    const def_opt = maybe_def orelse fallback_def;

    // 准备 effective tool_defs:若 def 存在,filter;否则用父全集
    var effective_tool_defs: []const @import("../json.zig").ToolDefinition = tool_defs;
    var filtered_owned: ?[]@import("../json.zig").ToolDefinition = null;
    defer if (filtered_owned) |f| ctx.allocator.free(f);
    if (def_opt) |d| {
        const filtered = try filter_mod.filterToolDefs(ctx.allocator, tool_defs, d);
        filtered_owned = filtered;
        effective_tool_defs = filtered;

        // 动态耦合:用 subagent 的 PromptContext 重写有 describe_fn 工具的描述。
        // 只读 agent(Explore/Plan)的 Bash 会去掉 Git 段 + 加只读提醒(对齐 cc Explore)。
        // 描述里引用其它工具的判断基于过滤后的工具集。
        const tools_mod = @import("../tools.zig");
        var names = try ctx.allocator.alloc([]const u8, filtered.len);
        defer ctx.allocator.free(names);
        for (filtered, 0..) |fd, i| names[i] = fd.name;
        const sub_prompt_ctx = tools_mod.PromptContext{
            .permission_mode = if (d.permission_mode) |m| mapPermissionMode(m) else .default,
            .enabled_tool_names = names,
            .agent_type = d.name,
            .include_git = true,
        };
        try tools_mod.redescribeForContext(ctx.allocator, filtered, &sub_prompt_ctx);
    }

    // per-spawn overrides
    const max_turns_input = parseUintField(args, "max_turns") orelse 0;
    const max_turns: u32 = blk: {
        if (max_turns_input > 0) break :blk @intCast(max_turns_input);
        if (def_opt) |d| break :blk d.max_turns;
        break :blk 20;
    };

    // permission mode override
    var perm_override: ?@import("../types.zig").PermissionMode = null;
    if (def_opt) |d| {
        if (d.permission_mode) |m| perm_override = mapPermissionMode(m);
    }

    // model override:Task 工具参数 > AgentDef.model > null(继承父)
    // "inherit" / 空 / 缺失 → null;其它视作 model 名(short alias 或全名)。
    const model_arg = util_json.extractStringField(args, "model");
    const model_override: ?[]const u8 = blk: {
        if (model_arg) |m| if (m.len > 0 and !std.mem.eql(u8, m, "inherit")) break :blk resolveModelAlias(m);
        if (def_opt) |d| if (d.model.len > 0 and !std.mem.eql(u8, d.model, "inherit")) break :blk resolveModelAlias(d.model);
        break :blk null;
    };

    // subagent system prompt:def + 环境 + CLAUDE.md/git(Explore/Plan 跳过) + skills preload
    const preload_mod = @import("../agents/preload.zig");
    var sys_prompt: []const u8 = "";
    var sys_prompt_owned: ?[]u8 = null;
    defer if (sys_prompt_owned) |p| ctx.allocator.free(p);
    if (def_opt) |d| {
        const sp = try preload_mod.buildSubagentContext(ctx.allocator, d, .{
            .project_dir = ctx.project_dir,
            .parent_model = ctx.parent_model,
            .session_id = ctx.session_id,
            .skills = ctx.skills,
            .skip_codebase_context = preload_mod.shouldSkipCodebaseContext(d.name),
            .abort = ctx.abort,
        });
        sys_prompt_owned = sp;
        sys_prompt = sp;
    } else {
        sys_prompt = "You are a subagent. Complete the task and return a concise summary.\n";
    }

    // run_in_background:true → 不阻塞,spawn 后台线程,立即返回 agent-job-id。
    // 后续用 TaskOutput(agent_job_id) 轮询增量输出 / TaskStop(agent_job_id) 终止。
    const bg = util_json.extractBoolField(args, "run_in_background") orelse false;
    if (bg) {
        const reg = ctx.agent_jobs orelse return error.AgentJobsUnavailable;
        var desc_buf: [128]u8 = undefined;
        const job_id = try reg.spawnBackground(.{
            .prompt = prompt,
            .system_prompt = sys_prompt,
            .tool_defs = effective_tool_defs,
            .permission_ctx = perm.*,
            .agents = ctx.agents,
            .dyn_registry = ctx.dyn_registry,
            .skills = ctx.skills,
            .agent_depth = ctx.agent_depth + 1,
            .max_turns = max_turns,
            .model_override = model_override,
            .perm_override = perm_override,
            .project_dir = ctx.project_dir,
            .parent_model = ctx.parent_model,
            // desc 形如 "<type>: <description>"(对齐 agent 进度树 `├ Explore: inspect repo`);
            // 无 description 时退回纯 type。registry 内 dupe + 截断 80B,这里栈 buffer 即可。
            .desc = desc_blk: {
                const d = util_json.extractStringField(args, "description") orelse break :desc_blk subagent_type_raw;
                break :desc_blk std.fmt.bufPrint(&desc_buf, "{s}: {s}", .{ subagent_type_raw, d }) catch d;
            },
            .activate_skill_state = ctx.activate_skill_state,
            .activate_skill_fn = ctx.activate_skill_fn,
        });
        return std.fmt.allocPrint(
            ctx.allocator,
            "{{\"agent_job_id\":\"{s}\",\"status\":\"running\",\"subagent_type\":\"{s}\"}}",
            .{ job_id, subagent_type_raw },
        );
    }

    const result = try subagent.spawnAgent(
        ctx.allocator,
        api_client,
        tool_defs, // 父 tool_defs (override 通过 SpawnOptions 传)
        perm,
        ctx.abort,
        prompt,
        .{
            .max_turns = max_turns,
            .system_prompt = sys_prompt,
            .agent_depth = ctx.agent_depth + 1,
            .dyn_registry = ctx.dyn_registry,
            .tool_defs_override = if (filtered_owned != null) effective_tool_defs else null,
            .permission_mode_override = perm_override,
            .model_override = model_override,
            .activate_skill_state = ctx.activate_skill_state,
            .activate_skill_fn = ctx.activate_skill_fn,
            .project_dir = ctx.project_dir,
        },
    );
    defer result.deinit();

    // 输出 JSON
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator, "{\"subagent_type\":");
    try util_json.serializeString(if (def_opt) |d| d.name else "general-purpose", &out, ctx.allocator);
    try out.appendSlice(ctx.allocator, ",\"final_text\":");
    try util_json.serializeString(result.final_text, &out, ctx.allocator);
    try out.appendSlice(ctx.allocator, ",\"stop_reason\":\"");
    try out.appendSlice(ctx.allocator, @tagName(result.stop_reason));
    const tail = try std.fmt.allocPrint(
        ctx.allocator,
        "\",\"turns\":{d},\"tool_calls\":{d}}}",
        .{ result.turns, result.tool_calls },
    );
    defer ctx.allocator.free(tail);
    try out.appendSlice(ctx.allocator, tail);
    return try out.toOwnedSlice(ctx.allocator);
}

fn mapPermissionMode(mode: @import("../agents/def.zig").PermissionMode) @import("../types.zig").PermissionMode {
    return switch (mode) {
        .default => .default,
        .acceptEdits => .accept_edits,
        .auto => .auto,
        .dontAsk => .dont_ask,
        .bypassPermissions => .bypass_permissions,
        .plan => .plan,
    };
}

/// 短名 → 具体 model ID。"haiku" → "claude-3-5-haiku-20241022",
/// "sonnet"/"opus" 同理映射到当前主力版本。已是全名(含 "claude-")则原样返回。
/// 留 borrowed 引用,不分配(借 def.model 或 args 的字符串内存)。
/// pub:skills/tool.zig 的 context:fork 分支解析 skill.model 字段时复用。
pub fn resolveModelAlias(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "claude-")) return name; // 已是全名
    if (std.mem.eql(u8, name, "haiku")) return "claude-3-5-haiku-20241022";
    if (std.mem.eql(u8, name, "sonnet")) return "claude-sonnet-4-20250514";
    if (std.mem.eql(u8, name, "opus")) return "claude-opus-4-1-20250805";
    return name; // 未知短名:原样传给 API(由 API 判错)
}

fn parseUintField(data: []const u8, field: []const u8) ?u64 {
    var buf: [128]u8 = undefined;
    if (field.len > 100) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    buf[2 + field.len] = ':';
    const pat = buf[0 .. 3 + field.len];
    const idx = std.mem.indexOf(u8, data, pat) orelse return null;
    var p = idx + pat.len;
    while (p < data.len and (data[p] == ' ' or data[p] == '\t')) : (p += 1) {}
    var e = p;
    while (e < data.len and data[e] >= '0' and data[e] <= '9') : (e += 1) {}
    if (e == p) return null;
    return std.fmt.parseInt(u64, data[p..e], 10) catch null;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Task without deps returns AgentUnavailable" {
    const ctx = ToolContext{ .allocator = testing.allocator };
    try testing.expectError(error.AgentUnavailable, execute(&ctx, "{\"prompt\":\"hi\"}"));
}

test "Task depth guard rejects at MAX" {
    const ctx = ToolContext{
        .allocator = testing.allocator,
        .agent_depth = MAX_AGENT_DEPTH,
    };
    try testing.expectError(error.AgentDepthExceeded, execute(&ctx, "{\"prompt\":\"hi\"}"));
}

test "parseUintField extracts max_turns" {
    try testing.expect(parseUintField("{\"max_turns\":42}", "max_turns").? == 42);
    try testing.expect(parseUintField("{\"max_turns\": 7 }", "max_turns").? == 7);
    try testing.expect(parseUintField("{}", "max_turns") == null);
}
