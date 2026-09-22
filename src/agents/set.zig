//! AgentSet:已加载的 subagent 集合 + 多路径加载 + 内置注入。
//!
//! 加载顺序(对齐 Claude Code 优先级,**低优先级先加载,高的后覆盖**):
//!   1. builtin(Explore / Plan / general-purpose)— 程序硬编码
//!   2. plugin(Host-admitted immutable plugin generation; namespaced)
//!   3. personal:~/.metacodes/agents + ~/.claude/agents(后者优先)
//!   4. project:沿 cwd 向上每级 .metacodes/agents + .claude/agents
//!   5. CLI --agents JSON(P3)
//!   6. managed enterprise(P3,/etc/metacodes/agents)
//!
//! 重名:后加载覆盖先加载(同 skill)。

const std = @import("std");
const pfs = @import("platform").fs;
const pdir = @import("platform").dir;
const def_mod = @import("def.zig");
const plugin_runtime = @import("../plugin/runtime.zig");
const plugin_contract = @import("../plugin/contract.zig");
pub const AgentDef = def_mod.AgentDef;
pub const Origin = def_mod.Origin;

pub const AgentSet = struct {
    allocator: std.mem.Allocator,
    agents: std.ArrayList(AgentDef),

    pub fn init(allocator: std.mem.Allocator) AgentSet {
        return .{ .allocator = allocator, .agents = .empty };
    }

    pub fn deinit(self: *AgentSet) void {
        for (self.agents.items) |a| a.deinit(self.allocator);
        self.agents.deinit(self.allocator);
    }

    /// 标准加载入口。cwd 用于沿父级向上扫 project 级;"" 跳过。
    pub fn loadFromStandardPaths(self: *AgentSet, cwd: []const u8) !void {
        return self.loadFromStandardPathsWithPluginSources(cwd, &.{});
    }

    /// 加载顺序严格保持 builtin < plugin < personal < project。插件 agent 的
    /// frontmatter name 和裸 preload skill 会被 Host namespace 限定，不能覆盖
    /// builtin/用户/project agent，也不能意外绑定同名外部 skill。
    pub fn loadFromStandardPathsWithPluginSources(
        self: *AgentSet,
        cwd: []const u8,
        plugin_sources: []const plugin_runtime.AgentSource,
    ) !void {
        // 0. builtin
        try injectBuiltins(self);

        // 1. plugin:Snapshot 已按稳定 PluginId 顺序发布。
        for (plugin_sources) |source| {
            try self.loadFromPluginDirRecursive(source.root, source.namespace);
        }

        // 2. personal: ~/.claude/agents 然后 ~/.metacodes/agents
        if (@import("platform").paths.homeDir()) |home| {
            const claude_path = try std.fmt.allocPrint(self.allocator, "{s}/.claude/agents", .{home});
            defer self.allocator.free(claude_path);
            try self.loadFromDirRecursive(claude_path, .personal);

            const cczig_path = try std.fmt.allocPrint(self.allocator, "{s}/.metacodes/agents", .{home});
            defer self.allocator.free(cczig_path);
            try self.loadFromDirRecursive(cczig_path, .personal);
        }

        // 2. project chain — 沿 cwd 向上找 .git
        if (cwd.len > 0) {
            const root = @import("../skills/skill.zig").findRepoRoot(self.allocator, cwd) catch null;
            if (root) |r| {
                defer self.allocator.free(r);
                try self.loadProjectChain(r, cwd);
            } else {
                try self.loadProjectDir(cwd);
            }
        }
    }

    fn loadProjectChain(self: *AgentSet, root: []const u8, cwd: []const u8) !void {
        if (!std.mem.startsWith(u8, cwd, root)) {
            try self.loadProjectDir(cwd);
            return;
        }
        try self.loadProjectDir(root);
        if (std.mem.eql(u8, root, cwd)) return;
        var cursor: usize = root.len;
        if (cursor < cwd.len and cwd[cursor] == '/') cursor += 1;
        while (cursor < cwd.len) {
            const next_slash = std.mem.indexOfScalarPos(u8, cwd, cursor, '/') orelse cwd.len;
            const sub = cwd[0..next_slash];
            try self.loadProjectDir(sub);
            cursor = next_slash + 1;
        }
    }

    fn loadProjectDir(self: *AgentSet, dir: []const u8) !void {
        const claude_path = try std.fmt.allocPrint(self.allocator, "{s}/.claude/agents", .{dir});
        defer self.allocator.free(claude_path);
        try self.loadFromDirRecursive(claude_path, .project);

        const cczig_path = try std.fmt.allocPrint(self.allocator, "{s}/.metacodes/agents", .{dir});
        defer self.allocator.free(cczig_path);
        try self.loadFromDirRecursive(cczig_path, .project);
    }

    /// 递归扫子目录,每个 `*.md` 都当 agent 定义。
    /// 子目录路径**不影响**调用名(只看 frontmatter `name`),这与 skill 不同。
    pub fn loadFromDirRecursive(self: *AgentSet, dir_path: []const u8, origin: Origin) !void {
        return self.loadFromDirRecursiveNamespaced(dir_path, origin, "");
    }

    fn loadFromPluginDirRecursive(self: *AgentSet, dir_path: []const u8, namespace: []const u8) !void {
        if (namespace.len == 0) return error.InvalidPluginNamespace;
        return self.loadFromDirRecursiveNamespaced(dir_path, .plugin, namespace);
    }

    fn loadFromDirRecursiveNamespaced(
        self: *AgentSet,
        dir_path: []const u8,
        origin: Origin,
        namespace: []const u8,
    ) !void {
        const path_z = try self.allocator.dupeZ(u8, dir_path);
        defer self.allocator.free(path_z);
        var it = pdir.open(path_z) orelse return;
        defer pdir.close(&it);

        while (pdir.next(&it)) |entry| {
            const name_slice = entry.name;
            if (name_slice.len == 0) continue;
            if (name_slice[0] == '.') continue;

            const child_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, name_slice });
            defer self.allocator.free(child_path);

            // 是 .md 文件 → parse;是目录 → 递归
            if (std.mem.endsWith(u8, name_slice, ".md")) {
                if (origin == .plugin) {
                    try self.loadAgentFile(child_path, origin, namespace);
                } else {
                    self.loadAgentFile(child_path, origin, namespace) catch |err| {
                        @import("../util/log.zig").warn("agent", "load failed {s}: {s}", .{ child_path, @errorName(err) });
                    };
                }
            } else {
                // 尝试当目录(if opendir 失败就是普通文件,忽略)
                try self.loadFromDirRecursiveNamespaced(child_path, origin, namespace);
            }
        }
    }

    fn loadAgentFile(self: *AgentSet, path: []const u8, origin: Origin, namespace: []const u8) !void {
        const md = try readAllFile(self.allocator, path);
        defer self.allocator.free(md);
        var a = try def_mod.parseAgentMd(self.allocator, md, path, origin);
        errdefer a.deinit(self.allocator);
        if (namespace.len != 0) try self.namespacePluginAgent(&a, namespace);
        try self.upsert(a);
    }

    fn namespacePluginAgent(self: *AgentSet, agent: *AgentDef, namespace: []const u8) !void {
        const qualified = try plugin_contract.qualifiedName(self.allocator, namespace, agent.name);
        self.allocator.free(agent.name);
        agent.name = qualified;
        if (agent.preload_skills.len == 0) return;

        const rewritten = try self.allocator.alloc([]const u8, agent.preload_skills.len);
        var initialized: usize = 0;
        errdefer {
            for (rewritten[0..initialized]) |skill| self.allocator.free(skill);
            self.allocator.free(rewritten);
        }
        for (agent.preload_skills) |skill| {
            rewritten[initialized] = if (std.mem.indexOfScalar(u8, skill, ':') != null)
                try self.allocator.dupe(u8, skill)
            else
                try plugin_contract.qualifiedName(self.allocator, namespace, skill);
            initialized += 1;
        }
        for (agent.preload_skills) |skill| self.allocator.free(skill);
        self.allocator.free(agent.preload_skills);
        agent.preload_skills = rewritten;
    }

    /// 添加或覆盖。重名时:相同 origin 内 Claude Code 行为是"静默丢弃一个"(由 fs 顺序决定);
    /// 不同 origin 时后加载的胜出(优先级低→高的加载顺序)。
    fn upsert(self: *AgentSet, a: AgentDef) !void {
        for (self.agents.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.name, a.name)) {
                self.agents.items[i].deinit(self.allocator);
                self.agents.items[i] = a;
                return;
            }
        }
        try self.agents.append(self.allocator, a);
    }

    pub fn find(self: *const AgentSet, name: []const u8) ?*const AgentDef {
        for (self.agents.items) |*a| {
            if (std.mem.eql(u8, a.name, name)) return a;
        }
        return null;
    }

    pub fn len(self: *const AgentSet) usize {
        return self.agents.items.len;
    }
};

fn readAllFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = pfs.openZ(path, .{ .ACCMODE = .RDONLY }, 0) catch return error.ReadError;
    defer _ = pfs.close(fd);
    var buf: [65536]u8 = undefined;
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    while (true) {
        const n = pfs.readZ(fd, &buf) catch return error.ReadError;
        if (n == 0) break;
        try result.appendSlice(allocator, buf[0..@as(usize, @intCast(n))]);
    }
    return try result.toOwnedSlice(allocator);
}

// ============================================================================
// 内置 subagent(对齐 Claude Code 三个核心)
// ============================================================================

/// Explore 内置 — 快速只读探索代码库。
const EXPLORE_DESC = "Fast, read-only agent for searching and analyzing code. Use for file discovery, code search, and codebase exploration. Specify thoroughness: \"quick\" / \"medium\" / \"very thorough\".";

const EXPLORE_PROMPT =
    \\You are an Explore subagent. Your job is to help the parent agent locate code and answer "where is X?" / "which files reference Y?" / "what does Z look like?" questions.
    \\
    \\You are read-only. Use Glob, Grep, and Read to find and analyze code. You CANNOT use Write or Edit.
    \\
    \\Return a concise summary that includes:
    \\- File paths (with line numbers where relevant)
    \\- Short excerpts of the most important code
    \\- A brief conclusion
    \\
    \\Be thorough proportional to the thoroughness level the parent requests.
    \\
;

/// Plan 内置 — plan-mode 下的研究 agent。
const PLAN_DESC = "Research agent used during plan mode to gather context. Read-only. Same role as Explore but optimized for planning decisions.";

const PLAN_PROMPT =
    \\You are a Plan subagent. Your job is to gather codebase context for the parent agent's planning step.
    \\
    \\You are read-only. Use Glob, Grep, and Read for current code. When KgRecall and KgContext are listed under Allowed tools, use them if prior decisions, constraints, failures, or project terminology may materially affect the plan. You CANNOT use Write, Edit, or Bash for state-changing commands.
    \\
    \\Return findings that directly inform the plan: which files need changes, dependencies, risks. Be specific.
    \\
;

/// general-purpose 内置 — 复杂多步任务。
const GENERAL_DESC = "Capable subagent for complex, multi-step tasks needing both exploration and modification. Use for: complex research, multi-step operations, code modifications that touch multiple files.";

const GENERAL_PROMPT =
    \\You are a general-purpose subagent. You have access to all tools the parent has.
    \\
    \\Work autonomously through the task using the tools you have. Return a concise summary of what you did, files changed (if any), and any open questions.
    \\
;

fn injectBuiltins(set: *AgentSet) !void {
    // Explore pin 档位名 "low"(非具体型号):按当前 provider 档位表解析;未配置
    // 档位表时 inherit 父模型——探索型任务用低档模型省成本,但绝不注入跨 provider
    // 的硬编码模型 ID(issue #11)。
    try addBuiltin(set, "Explore", EXPLORE_DESC, EXPLORE_PROMPT, &.{ "Read", "Grep", "Glob", "Bash" }, &.{ "Write", "Edit" }, "low", .plan, 30, .blue);
    try addBuiltin(set, "Plan", PLAN_DESC, PLAN_PROMPT, &.{ "Read", "Grep", "Glob", "KgRecall", "KgContext" }, &.{ "Write", "Edit", "Bash" }, "inherit", .plan, 30, .purple);
    try addBuiltin(set, "general-purpose", GENERAL_DESC, GENERAL_PROMPT, &.{}, &.{}, "inherit", null, 50, .green);
}

fn addBuiltin(
    set: *AgentSet,
    name: []const u8,
    description: []const u8,
    prompt: []const u8,
    tools: []const []const u8,
    disallowed_tools: []const []const u8,
    model: []const u8,
    permission_mode: ?def_mod.PermissionMode,
    max_turns: u32,
    color: def_mod.Color,
) !void {
    var builtin = try makeBuiltin(set.allocator, name, description, prompt, tools, disallowed_tools, model, permission_mode, max_turns, color);
    errdefer builtin.deinit(set.allocator);
    try set.upsert(builtin);
}

fn makeBuiltin(
    a: std.mem.Allocator,
    name: []const u8,
    description: []const u8,
    prompt: []const u8,
    tools: []const []const u8,
    disallowed_tools: []const []const u8,
    model: []const u8,
    permission_mode: ?def_mod.PermissionMode,
    max_turns: u32,
    color: def_mod.Color,
) !AgentDef {
    const name_owned = try a.dupe(u8, name);
    errdefer a.free(name_owned);
    const description_owned = try a.dupe(u8, description);
    errdefer a.free(description_owned);
    const prompt_owned = try a.dupe(u8, prompt);
    errdefer a.free(prompt_owned);
    const tools_owned = try dupeList(a, tools);
    errdefer freeList(a, tools_owned);
    const disallowed_owned = try dupeList(a, disallowed_tools);
    errdefer freeList(a, disallowed_owned);
    const model_owned = try a.dupe(u8, model);
    errdefer a.free(model_owned);
    const preload_owned = try dupeList(a, &.{});
    errdefer freeList(a, preload_owned);
    const mcp_owned = try dupeList(a, &.{});
    errdefer freeList(a, mcp_owned);
    const initial_prompt_owned = try a.dupe(u8, "");
    errdefer a.free(initial_prompt_owned);
    const source_path_owned = try a.dupe(u8, "");
    errdefer a.free(source_path_owned);
    return .{
        .name = name_owned,
        .description = description_owned,
        .prompt = prompt_owned,
        .tools = tools_owned,
        .disallowed_tools = disallowed_owned,
        .model = model_owned,
        .permission_mode = permission_mode,
        .max_turns = max_turns,
        .preload_skills = preload_owned,
        .mcp_servers = mcp_owned,
        .memory_scope = .none,
        .background = false,
        .effort = null,
        .overrides = null,
        .isolation = .none,
        .color = color,
        .initial_prompt = initial_prompt_owned,
        .origin = .builtin,
        .source_path = source_path_owned,
    };
}

fn freeList(a: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| a.free(item);
    a.free(list);
}

fn dupeList(a: std.mem.Allocator, src: []const []const u8) ![]const []const u8 {
    var out = try a.alloc([]const u8, src.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |s| a.free(s);
        a.free(out);
    }
    while (i < src.len) : (i += 1) {
        out[i] = try a.dupe(u8, src[i]);
    }
    return out;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "AgentSet: injectBuiltins gives Explore/Plan/general-purpose" {
    var set = AgentSet.init(testing.allocator);
    defer set.deinit();
    try injectBuiltins(&set);
    try testing.expectEqual(@as(usize, 3), set.len());
    try testing.expect(set.find("Explore") != null);
    try testing.expect(set.find("Plan") != null);
    try testing.expect(set.find("general-purpose") != null);
    // Explore: 蓝色,low 档位
    try testing.expect(set.find("Explore").?.color == .blue);
    try testing.expectEqualStrings("low", set.find("Explore").?.model);
    // Plan: 紫色
    const plan = set.find("Plan").?;
    try testing.expect(plan.color == .purple);
    var saw_recall = false;
    var saw_context = false;
    for (plan.tools) |tool_name| {
        if (std.mem.eql(u8, tool_name, "KgRecall")) saw_recall = true;
        if (std.mem.eql(u8, tool_name, "KgContext")) saw_context = true;
        try testing.expect(!std.mem.eql(u8, tool_name, "KgRemember"));
    }
    try testing.expect(saw_recall);
    try testing.expect(saw_context);
    // general-purpose: 绿色,继承父全部工具(tools 空 + disallowed 空)
    try testing.expect(set.find("general-purpose").?.tools.len == 0);
}

test "AgentSet: load custom from dir" {
    const a = testing.allocator;
    var dir_buf: [512]u8 = undefined;
    const dir = @import("../util/fs.zig").testing.perPidDir(&dir_buf, "cc-zig-agents-test");
    defer cleanupDir(dir);
    try makeAgent(dir, "code-reviewer.md", "---\nname: code-reviewer\ndescription: review\n---\nYou review code.\n");

    var set = AgentSet.init(a);
    defer set.deinit();
    try set.loadFromDirRecursive(dir, .personal);
    try testing.expectEqual(@as(usize, 1), set.len());
    const cr = set.find("code-reviewer").?;
    try testing.expect(cr.origin == .personal);
    try testing.expect(std.mem.indexOf(u8, cr.prompt, "review code") != null);
}

test "AgentSet: name from frontmatter wins over filename" {
    const a = testing.allocator;
    var dir_buf: [512]u8 = undefined;
    const dir = @import("../util/fs.zig").testing.perPidDir(&dir_buf, "cc-zig-agents-name");
    defer cleanupDir(dir);
    try makeAgent(dir, "wrong-filename.md", "---\nname: my-real-name\ndescription: x\n---\nbody\n");

    var set = AgentSet.init(a);
    defer set.deinit();
    try set.loadFromDirRecursive(dir, .personal);
    try testing.expect(set.find("my-real-name") != null);
    try testing.expect(set.find("wrong-filename") == null);
}

test "AgentSet: recursive subfolder discovery (path doesn't affect name)" {
    const a = testing.allocator;
    var dir_buf: [512]u8 = undefined;
    const dir = @import("../util/fs.zig").testing.perPidDir(&dir_buf, "cc-zig-agents-sub");
    defer cleanupDir(dir);
    var sub_buf: [512]u8 = undefined;
    const sub_dir = try std.fmt.bufPrint(&sub_buf, "{s}/review", .{dir});
    const sub_z = std.fmt.allocPrintSentinel(a, "{s}", .{sub_dir}, 0) catch unreachable;
    defer a.free(sub_z);
    _ = pfs.mkdir(dir.ptr, 0o755);
    _ = pfs.mkdir(sub_z, 0o755);
    try makeAgentInDir(sub_dir, "security.md", "---\nname: security\ndescription: sec review\n---\nbody\n");

    var set = AgentSet.init(a);
    defer set.deinit();
    try set.loadFromDirRecursive(dir, .personal);
    // 调用名只看 frontmatter `name`,子目录不参与
    try testing.expect(set.find("security") != null);

    // cleanup sub
    const md_z = std.fmt.allocPrintSentinel(a, "{s}/security.md", .{sub_dir}, 0) catch unreachable;
    defer a.free(md_z);
    pfs.unlinkPath(md_z) catch {};
    _ = pfs.rmdir(sub_z);
}

test "AgentSet: later load overwrites earlier (project beats personal)" {
    const a = testing.allocator;
    var p1_buf: [512]u8 = undefined;
    const p1 = @import("../util/fs.zig").testing.perPidDir(&p1_buf, "cc-zig-agents-p1");
    var p2_buf: [512]u8 = undefined;
    const p2 = @import("../util/fs.zig").testing.perPidDir(&p2_buf, "cc-zig-agents-p2");
    defer cleanupDir(p1);
    defer cleanupDir(p2);
    try makeAgent(p1, "x.md", "---\nname: shared\ndescription: from-personal\n---\nA\n");
    try makeAgent(p2, "x.md", "---\nname: shared\ndescription: from-project\n---\nB\n");

    var set = AgentSet.init(a);
    defer set.deinit();
    try set.loadFromDirRecursive(p1, .personal);
    try set.loadFromDirRecursive(p2, .project);
    try testing.expectEqual(@as(usize, 1), set.len());
    try testing.expectEqualStrings("from-project", set.find("shared").?.description);
    try testing.expect(set.find("shared").?.origin == .project);
}

fn makeAgent(parent: []const u8, filename: []const u8, md: []const u8) !void {
    const a = testing.allocator;
    const parent_z = try a.dupeZ(u8, parent);
    defer a.free(parent_z);
    _ = pfs.mkdir(parent_z, 0o755);
    try makeAgentInDir(parent, filename, md);
}

fn makeAgentInDir(parent: []const u8, filename: []const u8, md: []const u8) !void {
    const a = testing.allocator;
    const md_path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ parent, filename }, 0);
    defer a.free(md_path);
    const fd = pfs.open(md_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = pfs.write(fd, md[0..md.len]);
    _ = pfs.close(fd);
}

fn cleanupDir(parent: []const u8) void {
    const a = testing.allocator;
    const parent_z = a.dupeZ(u8, parent) catch return;
    defer a.free(parent_z);
    var it = pdir.open(parent_z) orelse return;
    defer pdir.close(&it);
    while (pdir.next(&it)) |entry| {
        const name = entry.name;
        if (name.len == 0 or name[0] == '.') continue;
        const sub = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ parent, name }, 0) catch continue;
        defer a.free(sub);
        pfs.unlinkPath(sub) catch {};
    }
    _ = pfs.rmdir(parent_z);
}
