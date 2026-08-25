//! AgentDef:subagent 定义。对齐 Claude Code 官方 frontmatter 字段集。
//! 运行时字段语义见 src/tools/agent.zig 与 test:agentdef-fields L2 测试。
//!
//! 来源:`.metacodes/agents/<name>.md` 或 `~/.claude/agents/<name>.md` 等。
//! 关键:**身份只看 frontmatter `name` 字段**,文件名/子目录路径仅控制位置发现,不影响调用名。

const std = @import("std");
const types = @import("../types.zig");
const request_overrides = @import("../api/request_overrides.zig");

pub const RequestOverrides = request_overrides.RequestOverrides;

pub const PermissionMode = enum {
    /// 与官方 default 对齐:细粒度 ask
    default,
    /// 自动接受文件编辑(适合 trusted refactor agent)
    acceptEdits,
    /// 自动模式:read 直接 allow,其它仍 ask
    auto,
    /// dontAsk:跳过所有 prompt(危险)
    dontAsk,
    /// bypassPermissions:跳过所有权限检查
    bypassPermissions,
    /// plan:read 允许,write/exec 拒绝
    plan,
};

pub const Color = enum { default, red, blue, green, yellow, purple, orange, pink, cyan };

pub const MemoryScope = enum { none, user, project, local };

pub const Isolation = enum { none, worktree };

pub const Origin = enum {
    builtin, // Explore/Plan/general-purpose
    personal, // ~/.metacodes/agents 或 ~/.claude/agents
    project, // <repo>/.metacodes/agents 或 <repo>/.claude/agents
    plugin, // <plugin>/agents
    cli, // --agents JSON 临时定义
};

pub const AgentDef = struct {
    /// frontmatter `name` —— 唯一标识(小写 + 连字符)
    name: []const u8,
    /// frontmatter `description` —— Claude 用这个判断是否自动委托
    description: []const u8,
    /// frontmatter body 或 `prompt` 字段 —— subagent 的 system prompt 主体
    prompt: []const u8,
    /// 允许工具白名单。空 = 继承父全部(再扣永久禁用集)。
    tools: []const []const u8,
    /// 禁用工具黑名单。
    disallowed_tools: []const []const u8,
    /// 模型:`sonnet` / `opus` / `haiku` / 完整 model ID / `inherit`(default = inherit)
    model: []const u8,
    /// 权限模式覆盖
    permission_mode: ?PermissionMode,
    /// 最大轮数
    max_turns: u32,
    /// 预加载 skill 列表(skill name)
    preload_skills: []const []const u8,
    /// MCP server 列表(name 或 inline 名)
    mcp_servers: []const []const u8,
    /// 持久化 memory 范围
    memory_scope: MemoryScope,
    /// 总在后台跑
    background: bool,
    /// effort 等级。null = inherit；非法字符串在解析期拒绝，不能静默存入 struct。
    effort: ?types.ReasoningEffort,
    /// per-subagent 方言字段覆盖(null = inherit 父 provider 的 overrides)。
    /// 非 null 时,spawnAgent 在 subagent Provider 上临时覆盖,结束恢复。
    /// 字符串字段(prompt_cache_key)owned,deinit 释放。
    overrides: ?RequestOverrides,
    /// isolation。用 enum 让未知模式不可表示。
    isolation: Isolation,
    /// 颜色
    color: Color,
    /// 启动时自动作为第一条 user 消息(--agent 启动主线时用)
    initial_prompt: []const u8,
    /// 来源
    origin: Origin,
    /// 文件路径(builtin 是空串)
    source_path: []const u8,

    pub fn deinit(self: AgentDef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.prompt);
        for (self.tools) |t| allocator.free(t);
        allocator.free(self.tools);
        for (self.disallowed_tools) |t| allocator.free(t);
        allocator.free(self.disallowed_tools);
        allocator.free(self.model);
        for (self.preload_skills) |s| allocator.free(s);
        allocator.free(self.preload_skills);
        for (self.mcp_servers) |s| allocator.free(s);
        allocator.free(self.mcp_servers);
        allocator.free(self.initial_prompt);
        allocator.free(self.source_path);
        if (self.overrides) |o| {
            if (o.prompt_cache_key) |k| allocator.free(k);
        }
    }
};

/// 解析 frontmatter + body。frontmatter `name` 必填。
pub fn parseAgentMd(allocator: std.mem.Allocator, md: []const u8, source_path: []const u8, origin: Origin) !AgentDef {
    var name: []const u8 = "";
    var description: []const u8 = "";
    var tools_raw: []const u8 = "";
    var disallowed_raw: []const u8 = "";
    var model_str: []const u8 = "inherit";
    var permission_mode_str: []const u8 = "";
    var max_turns: u32 = 20;
    var skills_raw: []const u8 = "";
    var mcp_raw: []const u8 = "";
    var memory_str: []const u8 = "";
    var background = false;
    var effort: ?types.ReasoningEffort = null;
    var isolation: Isolation = .none;
    var color_str: []const u8 = "";
    var initial_prompt_str: []const u8 = "";
    // overrides 累积:任意字段设过 → 非 null。字符串(prompt_cache_key)延后 dupe。
    var ov_temperature: ?f32 = null;
    var ov_top_p: ?f32 = null;
    var ov_prompt_cache_key: ?[]const u8 = null;
    var ov_parallel_tool_calls: ?bool = null;
    var ov_response_format: ?[]const u8 = null; // "json_object"/"json_schema"
    var body: []const u8 = md;

    if (std.mem.startsWith(u8, md, "---\n")) {
        const fm_start = 4;
        if (std.mem.indexOfPos(u8, md, fm_start, "\n---\n")) |fm_end| {
            const fm = md[fm_start..fm_end];
            body = md[fm_end + 5 ..];
            var line_it = std.mem.splitScalar(u8, fm, '\n');
            while (line_it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;
                if (trimmed[0] == '#') continue;
                const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
                const key = std.mem.trim(u8, trimmed[0..colon], " \t");
                const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                // 官方字段(camelCase)与 underscore 兼容
                if (std.mem.eql(u8, key, "name")) {
                    name = value;
                } else if (std.mem.eql(u8, key, "description")) {
                    description = value;
                } else if (std.mem.eql(u8, key, "tools")) {
                    tools_raw = value;
                } else if (std.mem.eql(u8, key, "disallowedTools") or std.mem.eql(u8, key, "disallowed_tools")) {
                    disallowed_raw = value;
                } else if (std.mem.eql(u8, key, "model")) {
                    model_str = value;
                } else if (std.mem.eql(u8, key, "permissionMode") or std.mem.eql(u8, key, "permission_mode")) {
                    permission_mode_str = value;
                } else if (std.mem.eql(u8, key, "maxTurns") or std.mem.eql(u8, key, "max_turns")) {
                    max_turns = std.fmt.parseInt(u32, value, 10) catch return error.InvalidAgentMaxTurns;
                    if (max_turns == 0) return error.InvalidAgentMaxTurns;
                } else if (std.mem.eql(u8, key, "skills")) {
                    skills_raw = value;
                } else if (std.mem.eql(u8, key, "mcpServers") or std.mem.eql(u8, key, "mcp_servers")) {
                    mcp_raw = value;
                } else if (std.mem.eql(u8, key, "memory")) {
                    memory_str = value;
                } else if (std.mem.eql(u8, key, "background")) {
                    background = parseBool(value) orelse return error.InvalidAgentBackground;
                } else if (std.mem.eql(u8, key, "effort")) {
                    effort = types.ReasoningEffort.parse(value) orelse return error.InvalidAgentEffort;
                } else if (std.mem.eql(u8, key, "isolation")) {
                    isolation = if (std.mem.eql(u8, value, "worktree"))
                        .worktree
                    else
                        return error.InvalidAgentIsolation;
                } else if (std.mem.eql(u8, key, "color")) {
                    color_str = value;
                } else if (std.mem.eql(u8, key, "initialPrompt") or std.mem.eql(u8, key, "initial_prompt")) {
                    initial_prompt_str = value;
                } else if (std.mem.eql(u8, key, "prompt")) {
                    // CLI JSON 形式可能用 prompt 代替 body
                    body = value;
                } else if (std.mem.eql(u8, key, "temperature")) {
                    ov_temperature = std.fmt.parseFloat(f32, value) catch return error.InvalidAgentTemperature;
                } else if (std.mem.eql(u8, key, "top_p") or std.mem.eql(u8, key, "topP")) {
                    ov_top_p = std.fmt.parseFloat(f32, value) catch return error.InvalidAgentTopP;
                } else if (std.mem.eql(u8, key, "prompt_cache_key") or std.mem.eql(u8, key, "promptCacheKey")) {
                    ov_prompt_cache_key = value;
                } else if (std.mem.eql(u8, key, "parallel_tool_calls") or std.mem.eql(u8, key, "parallelToolCalls")) {
                    ov_parallel_tool_calls = parseBool(value) orelse return error.InvalidAgentParallelToolCalls;
                } else if (std.mem.eql(u8, key, "response_format") or std.mem.eql(u8, key, "responseFormat")) {
                    if (std.mem.eql(u8, value, "json_object") or std.mem.eql(u8, value, "json_schema")) {
                        ov_response_format = value;
                    } else return error.InvalidAgentResponseFormat;
                }
            }
        }
    }

    if (name.len == 0) return error.MissingAgentName;
    // Validate all scalar enum-like fields before taking ownership of any
    // slices. A malformed frontmatter entry must not leave a half-built
    // AgentDef behind, and allocation failures below must unwind explicitly.
    const permission_mode = try parsePermissionMode(permission_mode_str);
    const memory_scope = try parseMemoryScope(memory_str);
    const color = try parseColor(color_str);

    const tools = try parseStringList(allocator, tools_raw);
    errdefer freeStringList(allocator, tools);
    const disallowed_tools = try parseStringList(allocator, disallowed_raw);
    errdefer freeStringList(allocator, disallowed_tools);
    const skills = try parseStringList(allocator, skills_raw);
    errdefer freeStringList(allocator, skills);
    const mcp_servers = try parseStringList(allocator, mcp_raw);
    errdefer freeStringList(allocator, mcp_servers);

    const name_owned = try allocator.dupe(u8, name);
    errdefer allocator.free(name_owned);
    const description_owned = try allocator.dupe(u8, description);
    errdefer allocator.free(description_owned);
    const prompt_owned = try allocator.dupe(u8, body);
    errdefer allocator.free(prompt_owned);
    const model_owned = try allocator.dupe(u8, model_str);
    errdefer allocator.free(model_owned);
    const initial_prompt_owned = try allocator.dupe(u8, initial_prompt_str);
    errdefer allocator.free(initial_prompt_owned);
    const source_path_owned = try allocator.dupe(u8, source_path);
    errdefer allocator.free(source_path_owned);

    // overrides:任一字段非 null → 构造。prompt_cache_key dupe 取所有权。
    var overrides: ?RequestOverrides = null;
    if (ov_temperature != null or ov_top_p != null or ov_prompt_cache_key != null or
        ov_parallel_tool_calls != null or ov_response_format != null)
    {
        const rf_kind: @import("../api/dialect.zig").ResponseFormatKind = if (ov_response_format) |rf|
            if (std.mem.eql(u8, rf, "json_schema")) .json_schema else .json_object
        else
            .none;
        const rf: ?@import("../api/dialect.zig").ResponseFormatRequest = if (ov_response_format != null)
            .{ .kind = rf_kind, .schema = null }
        else
            null;
        const pck_owned = if (ov_prompt_cache_key) |k| try allocator.dupe(u8, k) else null;
        errdefer if (pck_owned) |k| allocator.free(k);
        overrides = .{
            .temperature = ov_temperature,
            .top_p = ov_top_p,
            .prompt_cache_key = pck_owned,
            .parallel_tool_calls = ov_parallel_tool_calls,
            .response_format = rf,
        };
    }

    return .{
        .name = name_owned,
        .description = description_owned,
        .prompt = prompt_owned,
        .tools = tools,
        .disallowed_tools = disallowed_tools,
        .model = model_owned,
        .permission_mode = permission_mode,
        .max_turns = max_turns,
        .preload_skills = skills,
        .mcp_servers = mcp_servers,
        .memory_scope = memory_scope,
        .background = background,
        .effort = effort,
        .overrides = overrides,
        .isolation = isolation,
        .color = color,
        .initial_prompt = initial_prompt_owned,
        .origin = origin,
        .source_path = source_path_owned,
    };
}

// ---- helpers ----

fn parseBool(s: []const u8) ?bool {
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "yes") or std.mem.eql(u8, s, "1")) return true;
    if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "no") or std.mem.eql(u8, s, "0")) return false;
    return null;
}

fn parsePermissionMode(s: []const u8) !?PermissionMode {
    if (s.len == 0) return null;
    if (std.mem.eql(u8, s, "default")) return .default;
    if (std.mem.eql(u8, s, "acceptEdits")) return .acceptEdits;
    if (std.mem.eql(u8, s, "auto")) return .auto;
    if (std.mem.eql(u8, s, "dontAsk")) return .dontAsk;
    if (std.mem.eql(u8, s, "bypassPermissions")) return .bypassPermissions;
    if (std.mem.eql(u8, s, "plan")) return .plan;
    return error.InvalidAgentPermissionMode;
}

fn parseMemoryScope(s: []const u8) !MemoryScope {
    if (s.len == 0 or std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "user")) return .user;
    if (std.mem.eql(u8, s, "project")) return .project;
    if (std.mem.eql(u8, s, "local")) return .local;
    return error.InvalidAgentMemoryScope;
}

fn parseColor(s: []const u8) !Color {
    if (s.len == 0 or std.mem.eql(u8, s, "default")) return .default;
    if (std.mem.eql(u8, s, "red")) return .red;
    if (std.mem.eql(u8, s, "blue")) return .blue;
    if (std.mem.eql(u8, s, "green")) return .green;
    if (std.mem.eql(u8, s, "yellow")) return .yellow;
    if (std.mem.eql(u8, s, "purple")) return .purple;
    if (std.mem.eql(u8, s, "orange")) return .orange;
    if (std.mem.eql(u8, s, "pink")) return .pink;
    if (std.mem.eql(u8, s, "cyan")) return .cyan;
    return error.InvalidAgentColor;
}

/// 解析 `Read, Grep, Glob` / `Read Grep Glob` / `[Read, Grep]` 列表(同 skill 端实现)
pub fn parseStringList(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    var s = std.mem.trim(u8, raw, " \t");
    if (s.len >= 2 and s[0] == '[' and s[s.len - 1] == ']') s = s[1 .. s.len - 1];
    if (s.len == 0) return try out.toOwnedSlice(allocator);

    var depth: i32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (i == s.len or (s[i] == ',' and depth == 0)) {
            const seg = std.mem.trim(u8, s[start..i], " \t");
            if (seg.len > 0) {
                if (std.mem.indexOfScalar(u8, seg, '(') == null) {
                    var sp_it = std.mem.tokenizeAny(u8, seg, " \t");
                    while (sp_it.next()) |tok| {
                        const t = std.mem.trim(u8, tok, " \t");
                        if (t.len > 0) {
                            const owned = try allocator.dupe(u8, t);
                            errdefer allocator.free(owned);
                            try out.append(allocator, owned);
                        }
                    }
                } else {
                    const owned = try allocator.dupe(u8, seg);
                    errdefer allocator.free(owned);
                    try out.append(allocator, owned);
                }
            }
            start = i + 1;
            continue;
        }
        if (i < s.len) {
            if (s[i] == '(') depth += 1;
            if (s[i] == ')') depth -= 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |s| allocator.free(s);
    allocator.free(list);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseAgentMd: minimal name+description+body" {
    const md =
        "---\n" ++
        "name: code-reviewer\n" ++
        "description: review pending changes\n" ++
        "---\n" ++
        "You are a senior reviewer. Focus on security.\n";
    var d = try parseAgentMd(testing.allocator, md, "/x", .personal);
    defer d.deinit(testing.allocator);
    try testing.expectEqualStrings("code-reviewer", d.name);
    try testing.expectEqualStrings("review pending changes", d.description);
    try testing.expect(std.mem.indexOf(u8, d.prompt, "senior reviewer") != null);
    try testing.expectEqualStrings("inherit", d.model);
    try testing.expectEqual(@as(u32, 20), d.max_turns);
    try testing.expect(d.permission_mode == null);
    try testing.expect(d.tools.len == 0);
    try testing.expect(d.background == false);
    try testing.expect(d.color == .default);
    try testing.expect(d.origin == .personal);
}

test "parseAgentMd: tools list" {
    const md =
        "---\n" ++
        "name: safe\n" ++
        "description: safe\n" ++
        "tools: Read, Grep, Glob, Bash\n" ++
        "---\n" ++
        "body";
    var d = try parseAgentMd(testing.allocator, md, "/x", .personal);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), d.tools.len);
    try testing.expectEqualStrings("Read", d.tools[0]);
    try testing.expectEqualStrings("Bash", d.tools[3]);
}

test "parseAgentMd: disallowedTools" {
    const md =
        "---\n" ++
        "name: nowrite\n" ++
        "description: x\n" ++
        "disallowedTools: Write, Edit\n" ++
        "---\n" ++
        "body";
    var d = try parseAgentMd(testing.allocator, md, "/x", .personal);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), d.disallowed_tools.len);
}

test "parseAgentMd: model + permissionMode + maxTurns + background + color" {
    const md =
        "---\n" ++
        "name: x\n" ++
        "description: d\n" ++
        "model: haiku\n" ++
        "permissionMode: plan\n" ++
        "maxTurns: 5\n" ++
        "background: true\n" ++
        "color: cyan\n" ++
        "effort: high\n" ++
        "isolation: worktree\n" ++
        "---\n" ++
        "body";
    var d = try parseAgentMd(testing.allocator, md, "/x", .project);
    defer d.deinit(testing.allocator);
    try testing.expectEqualStrings("haiku", d.model);
    try testing.expect(d.permission_mode.? == .plan);
    try testing.expectEqual(@as(u32, 5), d.max_turns);
    try testing.expect(d.background == true);
    try testing.expect(d.color == .cyan);
    try testing.expectEqual(types.ReasoningEffort.high, d.effort.?);
    try testing.expectEqual(Isolation.worktree, d.isolation);
}

test "parseAgentMd: invalid effort and isolation are rejected" {
    try testing.expectError(
        error.InvalidAgentEffort,
        parseAgentMd(testing.allocator, "---\nname: x\neffort: turbo\n---\nbody", "/x", .personal),
    );
    try testing.expectError(
        error.InvalidAgentIsolation,
        parseAgentMd(testing.allocator, "---\nname: x\nisolation: process\n---\nbody", "/x", .personal),
    );
    try testing.expectError(
        error.InvalidAgentMemoryScope,
        parseAgentMd(testing.allocator, "---\nname: x\nmemory: shared-ish\n---\nbody", "/x", .personal),
    );
    try testing.expectError(
        error.InvalidAgentPermissionMode,
        parseAgentMd(testing.allocator, "---\nname: x\npermissionMode: permissive\n---\nbody", "/x", .personal),
    );
    try testing.expectError(
        error.InvalidAgentMaxTurns,
        parseAgentMd(testing.allocator, "---\nname: x\nmaxTurns: zero\n---\nbody", "/x", .personal),
    );
    try testing.expectError(
        error.InvalidAgentBackground,
        parseAgentMd(testing.allocator, "---\nname: x\nbackground: sometimes\n---\nbody", "/x", .personal),
    );
    try testing.expectError(
        error.InvalidAgentColor,
        parseAgentMd(testing.allocator, "---\nname: x\ncolor: ultraviolet\n---\nbody", "/x", .personal),
    );
}

test "parseAgentMd: skills + mcpServers + memory + initialPrompt" {
    const md =
        "---\n" ++
        "name: y\n" ++
        "description: d\n" ++
        "skills: [api-conventions, error-handling]\n" ++
        "mcpServers: github, slack\n" ++
        "memory: user\n" ++
        "initialPrompt: Begin by listing all TODOs\n" ++
        "---\n" ++
        "body";
    var d = try parseAgentMd(testing.allocator, md, "/x", .personal);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), d.preload_skills.len);
    try testing.expectEqualStrings("api-conventions", d.preload_skills[0]);
    try testing.expectEqual(@as(usize, 2), d.mcp_servers.len);
    try testing.expect(d.memory_scope == .user);
    try testing.expectEqualStrings("Begin by listing all TODOs", d.initial_prompt);
}

test "parseAgentMd: missing name errors" {
    const md = "---\ndescription: d\n---\nbody";
    try testing.expectError(error.MissingAgentName, parseAgentMd(testing.allocator, md, "/x", .personal));
}

test "parseAgentMd: comment lines ignored" {
    const md =
        "---\n" ++
        "# comment\n" ++
        "name: c\n" ++
        "description: d\n" ++
        "---\n" ++
        "body";
    var d = try parseAgentMd(testing.allocator, md, "/x", .personal);
    defer d.deinit(testing.allocator);
    try testing.expectEqualStrings("c", d.name);
}

test "parseAgentMd: JSON-form prompt field" {
    const md =
        "---\n" ++
        "name: js\n" ++
        "description: js\n" ++
        "prompt: You are a JavaScript expert.\n" ++
        "---\n";
    var d = try parseAgentMd(testing.allocator, md, "/x", .cli);
    defer d.deinit(testing.allocator);
    try testing.expectEqualStrings("You are a JavaScript expert.", d.prompt);
}
