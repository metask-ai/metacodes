//! Subagent 启动 context 组装器。
//!
//! 输出:一段完整的 subagent system prompt,**已包含**:
//!   - def.prompt(基础)
//!   - 环境信息(model, cwd, agent type, tool 限制提示)
//!   - CLAUDE.md 链(~/.claude/CLAUDE.md + repo/CLAUDE.md + CLAUDE.local.md)
//!     除非 def.name 是 Explore 或 Plan(对齐 Claude Code)
//!   - git status 快照(同上跳过条件)
//!   - skills preload:def.preload_skills 列出的每个 skill 全文(渲染后)
//!
//! 调用方:`tools/agent.zig` 在 spawnAgent 前调本函数生成 sys_prompt。

const std = @import("std");
const AgentDef = @import("def.zig").AgentDef;
const SkillSet = @import("../skills/skill.zig").SkillSet;
const render_mod = @import("../skills/render.zig");
const log = @import("../util/log.zig");

pub const ContextOptions = struct {
    cwd: []const u8 = "",
    project_dir: []const u8 = "",
    parent_model: []const u8 = "",
    session_id: []const u8 = "",
    skills: ?*const SkillSet = null,
    /// true = 跳过 CLAUDE.md + git status(Explore/Plan 用)
    skip_codebase_context: bool = false,
    /// AbortSignal 透传给 skill 渲染时的 bash 注入
    abort: ?*const @import("../util/abort.zig").AbortSignal = null,
};

pub fn buildSubagentContext(
    allocator: std.mem.Allocator,
    def: *const AgentDef,
    opts: ContextOptions,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    // 1. 基础 prompt
    try out.writer.writeAll(def.prompt);

    // 2. 环境
    try out.writer.writeAll("\n\n# Environment\n");
    try out.writer.print("- You are running as a subagent (agent type: {s}).\n", .{def.name});
    if (opts.cwd.len > 0) try out.writer.print("- Working directory: {s}\n", .{opts.cwd});
    if (opts.project_dir.len > 0) try out.writer.print("- Project root: {s}\n", .{opts.project_dir});
    const effective_model = if (std.mem.eql(u8, def.model, "inherit") or def.model.len == 0)
        opts.parent_model
    else
        def.model;
    if (effective_model.len > 0) try out.writer.print("- Model: {s}\n", .{effective_model});
    if (def.tools.len > 0) {
        try out.writer.writeAll("- Allowed tools: ");
        for (def.tools, 0..) |t, i| {
            if (i > 0) try out.writer.writeAll(", ");
            try out.writer.writeAll(t);
        }
        try out.writer.writeByte('\n');
    }
    if (def.disallowed_tools.len > 0) {
        try out.writer.writeAll("- Disallowed tools: ");
        for (def.disallowed_tools, 0..) |t, i| {
            if (i > 0) try out.writer.writeAll(", ");
            try out.writer.writeAll(t);
        }
        try out.writer.writeByte('\n');
    }

    // 3. CLAUDE.md 链(Explore/Plan 跳过)
    if (!opts.skip_codebase_context) {
        try injectClaudeMd(allocator, &out, opts);
        try injectGitStatus(allocator, &out, opts);
    }

    // 4. preload skills 全文(builtin agents 通常 def.preload_skills 为空,custom 才有)
    if (opts.skills) |skset| {
        for (def.preload_skills) |skill_name| {
            const skill = skset.find(skill_name) orelse {
                log.warn("agent.preload", "skill not found: {s}", .{skill_name});
                continue;
            };
            if (skill.disable_model_invocation) {
                log.warn("agent.preload", "skipping disable-model-invocation skill: {s}", .{skill_name});
                continue;
            }
            try out.writer.print("\n\n# Skill preload: {s}\n\n", .{skill.name});
            // 渲染 skill body(无 args,但允许 ${CLAUDE_SKILL_DIR} 等替换)
            const ropts = render_mod.RenderOptions{
                .skill_dir = skill.source_path,
                .project_dir = opts.project_dir,
                .session_id = opts.session_id,
                .shell = skill.shell,
                .abort = opts.abort,
            };
            const rendered = render_mod.renderBody(allocator, skill.body, ropts) catch |err| {
                log.warn("agent.preload", "render failed for {s}: {s}", .{ skill_name, @errorName(err) });
                continue;
            };
            defer allocator.free(rendered);
            try out.writer.writeAll(rendered);
        }
    }

    return try out.toOwnedSlice();
}

/// 读 ~/.claude/CLAUDE.md + <project>/CLAUDE.md + <project>/CLAUDE.local.md,顺序追加。
/// 缺失静默跳过。
fn injectClaudeMd(allocator: std.mem.Allocator, out: *std.Io.Writer.Allocating, opts: ContextOptions) !void {
    if (std.c.getenv("HOME")) |home_c| {
        const home = std.mem.span(home_c);
        try injectFile(allocator, out, home, ".claude/CLAUDE.md", "User CLAUDE.md");
        try injectFile(allocator, out, home, ".cc-zig/CLAUDE.md", "User cc-zig CLAUDE.md");
    }
    if (opts.project_dir.len > 0) {
        try injectFile(allocator, out, opts.project_dir, "CLAUDE.md", "Project CLAUDE.md");
        try injectFile(allocator, out, opts.project_dir, "CLAUDE.local.md", "Project CLAUDE.local.md");
    }
}

fn injectFile(
    allocator: std.mem.Allocator,
    out: *std.Io.Writer.Allocating,
    base: []const u8,
    rel: []const u8,
    label: []const u8,
) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, rel });
    defer allocator.free(path);
    const content = readFile(allocator, path) catch return;
    defer allocator.free(content);
    if (content.len == 0) return;
    try out.writer.print("\n\n# {s}\n\n", .{label});
    try out.writer.writeAll(content);
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return error.NotFound;
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

/// 跑 `git status --porcelain` 拿当前快照,带 5s 超时。失败/非 git repo 静默。
fn injectGitStatus(allocator: std.mem.Allocator, out: *std.Io.Writer.Allocating, opts: ContextOptions) !void {
    if (opts.project_dir.len == 0) return;
    // 走 /usr/bin/env 让 git 跟随 PATH
    const env_z: [*:0]const u8 = "/usr/bin/env";
    const git_z: [*:0]const u8 = "git";
    const opt1: [*:0]const u8 = "-C";
    const cwd_z = try allocator.dupeZ(u8, opts.project_dir);
    defer allocator.free(cwd_z);
    const opt2: [*:0]const u8 = "status";
    const opt3: [*:0]const u8 = "--porcelain";
    var argv: [6]?[*:0]const u8 = .{ env_z, git_z, opt1, cwd_z.ptr, opt2, opt3 };
    var argv_full: [7]?[*:0]const u8 = undefined;
    @memcpy(argv_full[0..6], argv[0..6]);
    argv_full[6] = null;

    const common = @import("../tools/common.zig");
    const status_out = common.spawnCaptureStdoutAbortableTimed(argv_full[0..], allocator, opts.abort, 5_000) catch return;
    defer allocator.free(status_out);

    try out.writer.writeAll("\n\n# Git status (parent session snapshot)\n\n");
    if (status_out.len == 0) {
        try out.writer.writeAll("(clean)\n");
    } else {
        try out.writer.writeAll("```\n");
        try out.writer.writeAll(status_out);
        if (!std.mem.endsWith(u8, status_out, "\n")) try out.writer.writeByte('\n');
        try out.writer.writeAll("```\n");
    }
}

/// 是否是会跳过 CLAUDE.md/git 的内置 subagent(Explore/Plan)。
pub fn shouldSkipCodebaseContext(name: []const u8) bool {
    return std.mem.eql(u8, name, "Explore") or std.mem.eql(u8, name, "Plan");
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const parseAgentMd = @import("def.zig").parseAgentMd;

test "buildSubagentContext: base prompt + environment" {
    const a = testing.allocator;
    var d = try parseAgentMd(a,
        "---\nname: code-reviewer\ndescription: r\n---\nYou review code.\n",
        "/x", .personal,
    );
    defer d.deinit(a);

    const ctx = try buildSubagentContext(a, &d, .{
        .cwd = "/repo/sub",
        .project_dir = "/repo",
        .parent_model = "claude-opus-4-7",
    });
    defer a.free(ctx);

    try testing.expect(std.mem.indexOf(u8, ctx, "You review code") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "# Environment") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "agent type: code-reviewer") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "Working directory: /repo/sub") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "Project root: /repo") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "Model: claude-opus-4-7") != null);
}

test "buildSubagentContext: tools listed" {
    const a = testing.allocator;
    var d = try parseAgentMd(a,
        "---\nname: t\ndescription: x\ntools: Read, Grep\ndisallowedTools: Write\n---\nbody\n",
        "/x", .personal,
    );
    defer d.deinit(a);

    const ctx = try buildSubagentContext(a, &d, .{});
    defer a.free(ctx);
    try testing.expect(std.mem.indexOf(u8, ctx, "Allowed tools: Read, Grep") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "Disallowed tools: Write") != null);
}

test "buildSubagentContext: skip_codebase_context omits CLAUDE.md/git" {
    const a = testing.allocator;
    var d = try parseAgentMd(a, "---\nname: Explore\ndescription: x\n---\nbody\n", "/x", .builtin);
    defer d.deinit(a);
    const cwd = try @import("../util/fs.zig").getCwd(a);
    defer a.free(cwd);
    const project_dir = try @import("../skills/skill.zig").findRepoRoot(a, cwd);
    defer a.free(project_dir);

    const ctx = try buildSubagentContext(a, &d, .{
        .project_dir = project_dir,
        .skip_codebase_context = true,
    });
    defer a.free(ctx);

    try testing.expect(std.mem.indexOf(u8, ctx, "# Git status") == null);
    try testing.expect(std.mem.indexOf(u8, ctx, "# Project CLAUDE.md") == null);
}

test "shouldSkipCodebaseContext: Explore and Plan only" {
    try testing.expect(shouldSkipCodebaseContext("Explore"));
    try testing.expect(shouldSkipCodebaseContext("Plan"));
    try testing.expect(!shouldSkipCodebaseContext("general-purpose"));
    try testing.expect(!shouldSkipCodebaseContext("code-reviewer"));
}

test "buildSubagentContext: preload skill body" {
    const a = testing.allocator;
    var d = try parseAgentMd(a,
        "---\nname: api-dev\ndescription: x\nskills: [api-conv]\n---\nbody\n",
        "/x", .personal,
    );
    defer d.deinit(a);

    var skset = SkillSet.init(a);
    defer skset.deinit();
    const skill_mod = @import("../skills/skill.zig");
    const skill_md = "---\nname: api-conv\ndescription: API conventions\n---\nUse camelCase for fields.\n";
    try skset.skills.append(a, try skill_mod.parseSkillMd(a, skill_md, "/fake"));

    const ctx = try buildSubagentContext(a, &d, .{
        .skills = &skset,
    });
    defer a.free(ctx);
    try testing.expect(std.mem.indexOf(u8, ctx, "# Skill preload: api-conv") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "Use camelCase") != null);
}
