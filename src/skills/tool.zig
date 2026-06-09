//! Skill 工具:LLM(或用户)激活某个 skill。
//!
//! 行为:
//! 1. 查找 skill;没有 → SkillNotFound
//! 2. 检查 disable-model-invocation:若 skill 标了 true 且当前是模型自主调用(非 explicit)→ 拒绝
//! 3. 渲染 body(render.zig):字符串替换 + bash 注入
//! 4. 激活权限态(ctx.activate_skill_fn):allowed-tools 直接 allow / disallowed-tools 直接 deny
//! 5. 按 context 分叉:
//!    - inline(default):返回 `# Skill: <name>\n\n<rendered_body>` 内联到主对话
//!    - fork:用 rendered body 当 prompt spawn 一个 subagent(复用 Agent 工具同路径),
//!      `agent` 字段选 subagent_type,`model` 字段切模型,返回 subagent 的 final_text。
//!      注意:这是 fresh-context fork(不继承主对话历史);带历史继承 + 强制后台的
//!      真 fork(CLAUDE_CODE_FORK_SUBAGENT)是 P3,见 doc/SKILL_DESIGN.md 七节。
//!      spawn 依赖缺失(无 api_client/tool_defs/permission_ctx 或超深)时降级回 inline + log warn。

const std = @import("std");
const common = @import("../tools/common.zig");
const ToolContext = @import("../tools/context.zig").ToolContext;
const DynRegistry = @import("../tools/dynamic.zig").DynRegistry;
const SkillSet = @import("skill.zig").SkillSet;
const render_mod = @import("render.zig");
const agent_tool = @import("../tools/agent.zig");
const subagent = @import("../core/subagent.zig");
const preload_mod = @import("../agents/preload.zig");
const log = @import("../util/log.zig");

pub fn registerSkillTool(registry: *DynRegistry, set: *SkillSet) !void {
    const required = [_][]const u8{"name"};
    try registry.register(
        "Skill",
        "Activate a named skill from the # Available skills list. Returns the skill's rendered instructions; follow them for the rest of the task. Optionally pass `args` (object) to bind to named parameters declared in the skill's frontmatter.",
        &required,
        execute,
        @ptrCast(set),
        false, // Skill 是单个常驻工具,不 deferred
    );
}

fn execute(ctx: *const ToolContext, args: []const u8, ctx_ptr: ?*anyopaque) anyerror![]u8 {
    const set_ptr = ctx_ptr orelse return error.MissingSkillSet;
    const set: *SkillSet = @ptrCast(@alignCast(set_ptr));

    const name = common.extractJsonArg(args, "name") orelse return error.MissingSkillName;
    if (name.len == 0) return error.EmptySkillName;

    const skill = set.find(name) orelse return error.SkillNotFound;

    // disable-model-invocation 检查:除非用户显式触发,否则拒绝
    if (skill.disable_model_invocation and !ctx.explicit_invocation) {
        return try std.fmt.allocPrint(ctx.allocator,
            \\{{"error":"SkillRequiresExplicitInvocation","skill":"{s}","hint":"This skill must be invoked by the user typing /{s}, not by the model."}}
        , .{ skill.name, skill.name });
    }

    // 收集 arguments:从 args.args.* 或 args 顶层(若用户简单调用 Skill{name})。
    // 简化处理:若 args 含 "args" 数组,取它;否则空。
    const arg_list = parseArgs(ctx.allocator, args) catch &.{};
    defer freeArgList(ctx.allocator, arg_list);

    const opts = render_mod.RenderOptions{
        .arguments = arg_list,
        .arg_names = skill.arguments,
        .skill_dir = skill.source_path,
        .project_dir = ctx.project_dir,
        .session_id = ctx.session_id,
        .shell = skill.shell,
        .abort = ctx.abort,
        .disable_shell_execution = ctx.disable_shell_execution,
    };

    const rendered = try render_mod.renderBody(ctx.allocator, skill.body, opts);
    defer ctx.allocator.free(rendered);

    // 激活权限态(若 setter 已 wire)。inline 与 fork 都需要(fork 的 subagent 也复用同回调)。
    if (ctx.skill_activator) |act| {
        act.activate(skill.name, skill.allowed_tools, skill.disallowed_tools) catch |err| {
            log.warn("skill", "activate state failed: {s}", .{@errorName(err)});
        };
    }

    // context: fork → 用 rendered body 当 prompt spawn subagent。
    // 依赖任一缺失或超深 → 降级 inline(下方),绝不静默吞掉。
    if (skill.context == .fork) {
        if (tryForkSpawn(ctx, skill, rendered)) |forked| {
            return forked; // owned by ctx.allocator
        } else |err| {
            log.warn("skill", "fork spawn unavailable for '{s}' ({s}); falling back to inline", .{ skill.name, @errorName(err) });
            // 落到下方 inline 组装
        }
    }

    // inline(default,或 fork 降级):组装最终回复
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    try out.writer.print("# Skill: {s}\n\n", .{skill.name});
    if (skill.allowed_tools.len > 0) {
        // 软提示给模型(权限是硬执行的,但额外提醒能减少模型尝试被禁工具)
        try out.writer.writeAll("> Active tool grants: ");
        for (skill.allowed_tools, 0..) |t, i| {
            if (i > 0) try out.writer.writeAll(", ");
            try out.writer.writeAll(t);
        }
        try out.writer.writeAll("\n\n");
    }
    if (skill.disallowed_tools.len > 0) {
        try out.writer.writeAll("> Tools disabled while this skill is active: ");
        for (skill.disallowed_tools, 0..) |t, i| {
            if (i > 0) try out.writer.writeAll(", ");
            try out.writer.writeAll(t);
        }
        try out.writer.writeAll("\n\n");
    }
    try out.writer.writeAll(rendered);
    return try out.toOwnedSlice();
}

/// context: fork 分支:用 rendered body 当 prompt spawn 一个 fresh-context subagent。
/// 返回 subagent 的 final_text(包一层 `# Skill: <name> (forked)` 头)。
/// 任一 spawn 依赖缺失/超深 → 返回 error,调用方降级回 inline。
fn tryForkSpawn(
    ctx: *const ToolContext,
    skill: *const @import("skill.zig").Skill,
    rendered: []const u8,
) anyerror![]u8 {
    // spawn 依赖:与 Agent 工具同前置(api_client / tool_defs / permission_ctx)。
    const api_client = ctx.api_client orelse return error.ForkUnavailable;
    const tool_defs = ctx.tool_defs orelse return error.ForkUnavailable;
    const perm = ctx.permission_ctx orelse return error.ForkUnavailable;
    if (ctx.agent_depth >= agent_tool.MAX_AGENT_DEPTH) return error.AgentDepthExceeded;

    // subagent def:skill.agent 非空时查 AgentSet;空 → general-purpose 兜底。
    var def_opt: ?*const @import("../agents/def.zig").AgentDef = null;
    if (ctx.agents) |as| {
        if (skill.agent.len > 0) def_opt = as.find(skill.agent);
        if (def_opt == null) def_opt = as.find("general-purpose");
    }

    // system prompt:def 存在 → buildSubagentContext;否则兜底(与 agent.zig 一致)。
    var sys_prompt: []const u8 = "You are a subagent. Complete the task and return a concise summary.\n";
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
    }

    // model override:skill.model 经 resolveModelAlias("inherit"/空 → null)。
    const model_override: ?[]const u8 = blk: {
        if (skill.model.len > 0 and !std.mem.eql(u8, skill.model, "inherit"))
            break :blk agent_tool.resolveModelAlias(skill.model);
        break :blk null;
    };

    const result = try subagent.spawnAgent(
        ctx.allocator,
        api_client,
        tool_defs,
        perm,
        ctx.abort,
        rendered, // skill body 当 prompt
        .{
            .system_prompt = sys_prompt,
            .agent_depth = ctx.agent_depth + 1,
            .dyn_registry = ctx.dyn_registry,
            .model_override = model_override,
            .skill_activator = ctx.skill_activator,
            .project_dir = ctx.project_dir,
        },
    );
    defer result.deinit();

    return try std.fmt.allocPrint(
        ctx.allocator,
        "# Skill: {s} (forked)\n\n{s}",
        .{ skill.name, result.final_text },
    );
}

/// 从 tool args 抽 arguments 列表。
/// 支持两种写法:
///   {"name":"foo","args":["a","b"]}      → ["a","b"]
///   {"name":"foo","args":"a b c"}        → ["a","b","c"] (空格拆,支持 "x y" 引号包整体)
///   {"name":"foo"}                       → []
fn parseArgs(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    // 尝试找 "args":[...]
    if (findArrayValue(raw, "args")) |arr| {
        return parseJsonStringArray(allocator, arr);
    }
    // 再尝试 "args":"<str>"
    if (common.extractJsonArg(raw, "args")) |s| {
        return parseShellQuoted(allocator, s);
    }
    var out = try allocator.alloc([]const u8, 0);
    _ = &out;
    return out;
}

fn findArrayValue(data: []const u8, field: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "\"{s}\":", .{field}) catch return null;
    const idx = std.mem.indexOf(u8, data, key) orelse return null;
    var pos = idx + key.len;
    while (pos < data.len and (data[pos] == ' ' or data[pos] == '\t')) : (pos += 1) {}
    if (pos >= data.len or data[pos] != '[') return null;
    var depth: i32 = 0;
    var in_str = false;
    var escaped = false;
    var i = pos;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') {
            in_str = !in_str;
            continue;
        }
        if (in_str) continue;
        if (c == '[') depth += 1;
        if (c == ']') {
            depth -= 1;
            if (depth == 0) return data[pos .. i + 1];
        }
    }
    return null;
}

fn parseJsonStringArray(allocator: std.mem.Allocator, arr: []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }
    var i: usize = 1; // skip [
    while (i < arr.len) {
        while (i < arr.len and (arr[i] == ' ' or arr[i] == ',' or arr[i] == '\n' or arr[i] == '\t')) : (i += 1) {}
        if (i >= arr.len or arr[i] == ']') break;
        if (arr[i] != '"') {
            i += 1;
            continue;
        }
        i += 1;
        const start = i;
        while (i < arr.len) {
            if (arr[i] == '\\') {
                i += 2;
                continue;
            }
            if (arr[i] == '"') break;
            i += 1;
        }
        if (i >= arr.len) break;
        try list.append(allocator, try allocator.dupe(u8, arr[start..i]));
        i += 1;
    }
    return try list.toOwnedSlice(allocator);
}

/// shell 风格拆分:空格分,双引号包裹的整段当一个。
fn parseShellQuoted(allocator: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |x| allocator.free(x);
        list.deinit(allocator);
    }
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
        if (i >= s.len) break;
        if (s[i] == '"') {
            i += 1;
            const start = i;
            while (i < s.len and s[i] != '"') : (i += 1) {}
            try list.append(allocator, try allocator.dupe(u8, s[start..i]));
            if (i < s.len) i += 1;
        } else {
            const start = i;
            while (i < s.len and s[i] != ' ' and s[i] != '\t') : (i += 1) {}
            try list.append(allocator, try allocator.dupe(u8, s[start..i]));
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn freeArgList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |s| allocator.free(s);
    allocator.free(list);
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

test "Skill tool: allowed_tools surfaces tool grants in result" {
    var set = SkillSet.init(testing.allocator);
    defer set.deinit();
    const md = "---\nname: reader\ndescription: read-only\nallowed-tools: Read, Grep\n---\nLook around.\n";
    try set.skills.append(testing.allocator, try parseSkillMd(testing.allocator, md, "/fake"));

    var reg = DynRegistry.init(testing.allocator);
    defer reg.deinit();
    try registerSkillTool(&reg, &set);

    const entry = reg.find("Skill").?;
    const ctx = ToolContext.simple(testing.allocator);
    const out = try entry.execute(&ctx, "{\"name\":\"reader\"}", entry.ctx_ptr);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Active tool grants: Read, Grep") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Look around") != null);
}

test "Skill tool: disable-model-invocation rejects model trigger" {
    var set = SkillSet.init(testing.allocator);
    defer set.deinit();
    const md = "---\nname: deploy\ndescription: deploys\ndisable-model-invocation: true\n---\nDoing dangerous thing.\n";
    try set.skills.append(testing.allocator, try parseSkillMd(testing.allocator, md, "/fake"));

    var reg = DynRegistry.init(testing.allocator);
    defer reg.deinit();
    try registerSkillTool(&reg, &set);

    const entry = reg.find("Skill").?;
    var ctx = ToolContext.simple(testing.allocator);
    ctx.explicit_invocation = false;
    const out = try entry.execute(&ctx, "{\"name\":\"deploy\"}", entry.ctx_ptr);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "SkillRequiresExplicitInvocation") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Doing dangerous thing") == null);
}

test "Skill tool: explicit invocation bypasses disable-model-invocation" {
    var set = SkillSet.init(testing.allocator);
    defer set.deinit();
    const md = "---\nname: deploy\ndescription: deploys\ndisable-model-invocation: true\n---\nDoing dangerous thing.\n";
    try set.skills.append(testing.allocator, try parseSkillMd(testing.allocator, md, "/fake"));

    var reg = DynRegistry.init(testing.allocator);
    defer reg.deinit();
    try registerSkillTool(&reg, &set);

    const entry = reg.find("Skill").?;
    var ctx = ToolContext.simple(testing.allocator);
    ctx.explicit_invocation = true;
    const out = try entry.execute(&ctx, "{\"name\":\"deploy\"}", entry.ctx_ptr);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "# Skill: deploy") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Doing dangerous thing") != null);
}

test "Skill tool: arguments + $ARGUMENTS render" {
    var set = SkillSet.init(testing.allocator);
    defer set.deinit();
    const md = "---\nname: greet\ndescription: hi\n---\nHello $ARGUMENTS, welcome.\n";
    try set.skills.append(testing.allocator, try parseSkillMd(testing.allocator, md, "/fake"));

    var reg = DynRegistry.init(testing.allocator);
    defer reg.deinit();
    try registerSkillTool(&reg, &set);

    const entry = reg.find("Skill").?;
    const ctx = ToolContext.simple(testing.allocator);
    const out = try entry.execute(&ctx, "{\"name\":\"greet\",\"args\":[\"alice\",\"bob\"]}", entry.ctx_ptr);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Hello alice bob, welcome.") != null);
}

test "Skill tool: named arguments via arg_names" {
    var set = SkillSet.init(testing.allocator);
    defer set.deinit();
    const md = "---\nname: pr-fix\ndescription: fix\narguments: [issue, branch]\n---\nfix $issue on $branch\n$ARGUMENTS\n";
    try set.skills.append(testing.allocator, try parseSkillMd(testing.allocator, md, "/fake"));

    var reg = DynRegistry.init(testing.allocator);
    defer reg.deinit();
    try registerSkillTool(&reg, &set);

    const entry = reg.find("Skill").?;
    const ctx = ToolContext.simple(testing.allocator);
    const out = try entry.execute(&ctx, "{\"name\":\"pr-fix\",\"args\":[\"#42\",\"main\"]}", entry.ctx_ptr);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "fix #42 on main") != null);
}

test "parseShellQuoted: quoted segments preserved as one" {
    const args = try parseShellQuoted(testing.allocator, "alpha \"hello world\" gamma");
    defer freeArgList(testing.allocator, args);
    try testing.expectEqual(@as(usize, 3), args.len);
    try testing.expectEqualStrings("alpha", args[0]);
    try testing.expectEqualStrings("hello world", args[1]);
    try testing.expectEqualStrings("gamma", args[2]);
}
