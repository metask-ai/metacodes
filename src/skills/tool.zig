//! Skill 工具:LLM(或用户)激活某个 skill。
//!
//! 行为:
//! 1. 查找 skill;没有 → SkillNotFound
//! 2. 检查 disable-model-invocation:若 skill 标了 true 且当前是模型自主调用(非 explicit)→ 拒绝
//! 3. 渲染 body(render.zig):字符串替换 + bash 注入
//! 4. 激活权限态(ctx.activate_skill_fn):allowed-tools 直接 allow / disallowed-tools 直接 deny
//! 5. 返回 `# Skill: <name>\n\n<rendered_body>` 作为 tool_result

const std = @import("std");
const common = @import("../tools/common.zig");
const ToolContext = @import("../tools/context.zig").ToolContext;
const DynRegistry = @import("../tools/dynamic.zig").DynRegistry;
const SkillSet = @import("skill.zig").SkillSet;
const render_mod = @import("render.zig");

pub fn registerSkillTool(registry: *DynRegistry, set: *SkillSet) !void {
    const required = [_][]const u8{"name"};
    try registry.register(
        "Skill",
        "Activate a named skill from the # Available skills list. Returns the skill's rendered instructions; follow them for the rest of the task. Optionally pass `args` (object) to bind to named parameters declared in the skill's frontmatter.",
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

    // 激活权限态(若 setter 已 wire)
    if (ctx.activate_skill_fn) |setter_fn| {
        if (ctx.activate_skill_state) |state| {
            setter_fn(state, skill.name, skill.allowed_tools, skill.disallowed_tools) catch |err| {
                @import("../util/log.zig").warn("skill", "activate state failed: {s}", .{@errorName(err)});
            };
        }
    }

    // 组装最终回复
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
