//! AgentSet:已加载的 subagent 集合 + 多路径加载 + 内置注入。
//!
//! 加载顺序(对齐 Claude Code 优先级,**低优先级先加载,高的后覆盖**):
//!   1. builtin(Explore / Plan / general-purpose)— 程序硬编码
//!   2. plugin(~/.cc-zig/plugins/*/agents/ + project plugins;暂未实现,P3)
//!   3. personal:~/.cc-zig/agents + ~/.claude/agents(后者优先)
//!   4. project:沿 cwd 向上每级 .cc-zig/agents + .claude/agents
//!   5. CLI --agents JSON(P3)
//!   6. managed enterprise(P3,/etc/cc-zig/agents)
//!
//! 重名:后加载覆盖先加载(同 skill)。

const std = @import("std");
const def_mod = @import("def.zig");
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
        // 0. builtin
        try injectBuiltins(self);

        // 1. personal: ~/.claude/agents 然后 ~/.cc-zig/agents
        if (std.c.getenv("HOME")) |home_c| {
            const home = std.mem.span(home_c);
            const claude_path = try std.fmt.allocPrint(self.allocator, "{s}/.claude/agents", .{home});
            defer self.allocator.free(claude_path);
            try self.loadFromDirRecursive(claude_path, .personal);

            const cczig_path = try std.fmt.allocPrint(self.allocator, "{s}/.cc-zig/agents", .{home});
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

        const cczig_path = try std.fmt.allocPrint(self.allocator, "{s}/.cc-zig/agents", .{dir});
        defer self.allocator.free(cczig_path);
        try self.loadFromDirRecursive(cczig_path, .project);
    }

    /// 递归扫子目录,每个 `*.md` 都当 agent 定义。
    /// 子目录路径**不影响**调用名(只看 frontmatter `name`),这与 skill 不同。
    pub fn loadFromDirRecursive(self: *AgentSet, dir_path: []const u8, origin: Origin) !void {
        const path_z = try self.allocator.dupeZ(u8, dir_path);
        defer self.allocator.free(path_z);
        const dir = std.c.opendir(path_z) orelse return;
        defer _ = std.c.closedir(dir);

        while (std.c.readdir(dir)) |entry_ptr| {
            const entry = entry_ptr.*;
            const name_slice = std.mem.sliceTo(&entry.name, 0);
            if (name_slice.len == 0) continue;
            if (name_slice[0] == '.') continue;

            const child_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, name_slice });
            defer self.allocator.free(child_path);

            // 是 .md 文件 → parse;是目录 → 递归
            if (std.mem.endsWith(u8, name_slice, ".md")) {
                self.loadAgentFile(child_path, origin) catch |err| {
                    @import("../util/log.zig").warn("agent", "load failed {s}: {s}", .{ child_path, @errorName(err) });
                };
            } else {
                // 尝试当目录(if opendir 失败就是普通文件,忽略)
                try self.loadFromDirRecursive(child_path, origin);
            }
        }
    }

    fn loadAgentFile(self: *AgentSet, path: []const u8, origin: Origin) !void {
        const md = try readAllFile(self.allocator, path);
        defer self.allocator.free(md);
        const a = try def_mod.parseAgentMd(self.allocator, md, path, origin);
        try self.upsert(a);
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
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return error.ReadError;
    defer _ = std.c.close(fd);
    var buf: [65536]u8 = undefined;
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    while (true) {
        const n = std.posix.read(fd, &buf) catch return error.ReadError;
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
    \\You are read-only. Use Glob, Grep, and Read. You CANNOT use Write, Edit, or Bash for state-changing commands.
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
    const a = set.allocator;

    try set.upsert(.{
        .name = try a.dupe(u8, "Explore"),
        .description = try a.dupe(u8, EXPLORE_DESC),
        .prompt = try a.dupe(u8, EXPLORE_PROMPT),
        .tools = try dupeList(a, &.{ "Read", "Grep", "Glob", "Bash" }),
        .disallowed_tools = try dupeList(a, &.{ "Write", "Edit" }),
        .model = try a.dupe(u8, "haiku"),
        .permission_mode = .plan, // 等价于"读 allow,其它 deny" — 一定不写
        .max_turns = 30,
        .preload_skills = try dupeList(a, &.{}),
        .mcp_servers = try dupeList(a, &.{}),
        .memory_scope = .none,
        .background = false,
        .effort = try a.dupe(u8, ""),
        .isolation = try a.dupe(u8, ""),
        .color = .blue,
        .initial_prompt = try a.dupe(u8, ""),
        .origin = .builtin,
        .source_path = try a.dupe(u8, ""),
    });

    try set.upsert(.{
        .name = try a.dupe(u8, "Plan"),
        .description = try a.dupe(u8, PLAN_DESC),
        .prompt = try a.dupe(u8, PLAN_PROMPT),
        .tools = try dupeList(a, &.{ "Read", "Grep", "Glob" }),
        .disallowed_tools = try dupeList(a, &.{ "Write", "Edit", "Bash" }),
        .model = try a.dupe(u8, "inherit"),
        .permission_mode = .plan,
        .max_turns = 30,
        .preload_skills = try dupeList(a, &.{}),
        .mcp_servers = try dupeList(a, &.{}),
        .memory_scope = .none,
        .background = false,
        .effort = try a.dupe(u8, ""),
        .isolation = try a.dupe(u8, ""),
        .color = .purple,
        .initial_prompt = try a.dupe(u8, ""),
        .origin = .builtin,
        .source_path = try a.dupe(u8, ""),
    });

    try set.upsert(.{
        .name = try a.dupe(u8, "general-purpose"),
        .description = try a.dupe(u8, GENERAL_DESC),
        .prompt = try a.dupe(u8, GENERAL_PROMPT),
        .tools = try dupeList(a, &.{}), // 空 = inherit all
        .disallowed_tools = try dupeList(a, &.{}),
        .model = try a.dupe(u8, "inherit"),
        .permission_mode = null,
        .max_turns = 50,
        .preload_skills = try dupeList(a, &.{}),
        .mcp_servers = try dupeList(a, &.{}),
        .memory_scope = .none,
        .background = false,
        .effort = try a.dupe(u8, ""),
        .isolation = try a.dupe(u8, ""),
        .color = .green,
        .initial_prompt = try a.dupe(u8, ""),
        .origin = .builtin,
        .source_path = try a.dupe(u8, ""),
    });
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
    // Explore: 蓝色,Haiku
    try testing.expect(set.find("Explore").?.color == .blue);
    try testing.expectEqualStrings("haiku", set.find("Explore").?.model);
    // Plan: 紫色
    try testing.expect(set.find("Plan").?.color == .purple);
    // general-purpose: 绿色,继承父全部工具(tools 空 + disallowed 空)
    try testing.expect(set.find("general-purpose").?.tools.len == 0);
}

test "AgentSet: load custom from dir" {
    const a = testing.allocator;
    const dir = "/tmp/cc-zig-agents-test";
    defer cleanupDir(dir);
    try makeAgent(dir, "code-reviewer.md",
        "---\nname: code-reviewer\ndescription: review\n---\nYou review code.\n");

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
    const dir = "/tmp/cc-zig-agents-name";
    defer cleanupDir(dir);
    try makeAgent(dir, "wrong-filename.md",
        "---\nname: my-real-name\ndescription: x\n---\nbody\n");

    var set = AgentSet.init(a);
    defer set.deinit();
    try set.loadFromDirRecursive(dir, .personal);
    try testing.expect(set.find("my-real-name") != null);
    try testing.expect(set.find("wrong-filename") == null);
}

test "AgentSet: recursive subfolder discovery (path doesn't affect name)" {
    const a = testing.allocator;
    const dir = "/tmp/cc-zig-agents-sub";
    defer cleanupDir(dir);
    const sub_dir = dir ++ "/review";
    const sub_z = std.fmt.allocPrintSentinel(a, "{s}", .{sub_dir}, 0) catch unreachable;
    defer a.free(sub_z);
    _ = std.c.mkdir(dir, 0o755);
    _ = std.c.mkdir(sub_z, 0o755);
    try makeAgentInDir(sub_dir, "security.md",
        "---\nname: security\ndescription: sec review\n---\nbody\n");

    var set = AgentSet.init(a);
    defer set.deinit();
    try set.loadFromDirRecursive(dir, .personal);
    // 调用名只看 frontmatter `name`,子目录不参与
    try testing.expect(set.find("security") != null);

    // cleanup sub
    const md_z = std.fmt.allocPrintSentinel(a, "{s}/security.md", .{sub_dir}, 0) catch unreachable;
    defer a.free(md_z);
    _ = std.c.unlink(md_z);
    _ = std.c.rmdir(sub_z);
}

test "AgentSet: later load overwrites earlier (project beats personal)" {
    const a = testing.allocator;
    const p1 = "/tmp/cc-zig-agents-p1";
    const p2 = "/tmp/cc-zig-agents-p2";
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
    _ = std.c.mkdir(parent_z, 0o755);
    try makeAgentInDir(parent, filename, md);
}

fn makeAgentInDir(parent: []const u8, filename: []const u8, md: []const u8) !void {
    const a = testing.allocator;
    const md_path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ parent, filename }, 0);
    defer a.free(md_path);
    const fd = std.c.open(md_path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = std.c.write(fd, md.ptr, md.len);
    _ = std.c.close(fd);
}

fn cleanupDir(parent: []const u8) void {
    const a = testing.allocator;
    const parent_z = a.dupeZ(u8, parent) catch return;
    defer a.free(parent_z);
    const dir = std.c.opendir(parent_z) orelse return;
    defer _ = std.c.closedir(dir);
    while (std.c.readdir(dir)) |entry_ptr| {
        const entry = entry_ptr.*;
        const name = std.mem.sliceTo(&entry.name, 0);
        if (name.len == 0 or name[0] == '.') continue;
        const sub = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ parent, name }, 0) catch continue;
        defer a.free(sub);
        _ = std.c.unlink(sub);
    }
    _ = std.c.rmdir(parent_z);
}
