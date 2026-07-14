//! Skill 类型 + 加载器（与 Claude Code 官方规范对齐）。
//!
//! 详细设计:doc/SKILL_DESIGN.md
//!
//! 一个 skill 是文件系统中的一个目录:
//!   <dir>/<skill-name>/SKILL.md     必需
//!   <dir>/<skill-name>/resources/   可选,@path 注入用
//!   <dir>/<skill-name>/scripts/     可选,!`<cmd>` 注入用
//!
//! SKILL.md frontmatter(字段名采用 Claude Code 中划线风格;旧版下划线兼容):
//!   ---
//!   name: my-skill                              # 显示名(命令名由目录决定)
//!   description: When to use this skill         # 必需,模型据此判断自动激活
//!   disable-model-invocation: false             # true = 仅人显式 /name 可调
//!   allowed-tools: Read, Grep, Bash(git *)      # 激活期间免权限询问
//!   disallowed-tools: AskUserQuestion           # 激活期间从工具池移除
//!   context: inline                             # inline(default) 或 fork
//!   agent: general-purpose                      # 配合 context: fork
//!   arguments: [issue, branch]                  # 命名参数,body 里 $issue $branch
//!   model: claude-haiku-4-5-20251001            # 激活时切换模型(fork 时生效)
//!   shell: bash                                 # bash(default) 或 powershell
//!   ---
//!   <markdown body, 支持 $ARGUMENTS $N $name ${CLAUDE_SKILL_DIR}
//!    以及 !`cmd` 行首注入和 ```! fenced 注入>
//!
//! 加载层级(覆盖优先级,高→低):
//!   1. enterprise:    /etc/metacodes/skills/<name>/
//!   2. personal:      ~/.metacodes/skills/<name>/  和  ~/.claude/skills/<name>/
//!   3. project-root:  <repo-root>/.metacodes/skills/<name>/  和  .claude/skills/<name>/
//!                     (沿 cwd 向上找 .git)
//!   4. plugin:        <plugin>/skills/<name>/  (命名空间 <plugin>:<name>)
//! 同名:高优先级覆盖低优先级。Plugin 不与其它级冲突。

const std = @import("std");
const pfs = @import("platform").fs;

/// 调用上下文 — fork 时跑独立 subagent,inline 在主对话内联。
pub const ExecContext = enum { inline_ctx, fork };

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    /// SKILL.md 的 body(frontmatter 后的内容)。激活时做替换 + 注入后再用。
    body: []const u8,
    /// 已 parse 的允许工具列表。空 = 无白名单(对齐 default)。
    allowed_tools: []const []const u8,
    /// 已 parse 的禁用工具列表。空 = 无黑名单。
    disallowed_tools: []const []const u8,
    /// 命名参数(arguments frontmatter)。body 替换时 $name → 第 N 个位置参数。
    arguments: []const []const u8,
    /// 仅人显式 /name 才能调用,模型不能自动触发。
    disable_model_invocation: bool,
    /// inline(default)在主对话激活;fork 在 subagent 独立跑(fresh context,
    /// 用 skill body 当 prompt;不继承主对话历史 = 那是 P3,见 SKILL_DESIGN 七节)。
    context: ExecContext,
    /// 配合 context=fork 指定 subagent 类型(空 = general-purpose)。
    agent: []const u8,
    /// 激活时切换的模型(空 = 沿用当前 model)。fork 时才生效。
    model: []const u8,
    /// shell 类型:"bash"(default) / "powershell"。
    shell: []const u8,
    /// 此 skill 目录路径(用于 ${CLAUDE_SKILL_DIR} + @path 注入根)。
    source_path: []const u8,

    pub fn deinit(self: Skill, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.body);
        for (self.allowed_tools) |t| allocator.free(t);
        allocator.free(self.allowed_tools);
        for (self.disallowed_tools) |t| allocator.free(t);
        allocator.free(self.disallowed_tools);
        for (self.arguments) |t| allocator.free(t);
        allocator.free(self.arguments);
        allocator.free(self.agent);
        allocator.free(self.model);
        allocator.free(self.shell);
        allocator.free(self.source_path);
    }
};

pub const SkillSet = struct {
    allocator: std.mem.Allocator,
    skills: std.ArrayList(Skill),

    pub fn init(allocator: std.mem.Allocator) SkillSet {
        return .{ .allocator = allocator, .skills = .empty };
    }

    pub fn deinit(self: *SkillSet) void {
        for (self.skills.items) |s| s.deinit(self.allocator);
        self.skills.deinit(self.allocator);
    }

    /// 标准 5 路径加载:enterprise / ~/.metacodes / ~/.claude / repo-root/.metacodes / repo-root/.claude。
    /// 加载顺序 = 低优先到高优先,这样后加载的覆盖前面的。
    /// cwd 用于沿父目录找 .git 定位 repo root;""则跳过 project 级。
    pub fn loadFromStandardPaths(self: *SkillSet, cwd: []const u8) !void {
        // 1. enterprise (最低优先级)
        const enterprise = enterprisePath();
        try self.loadFromDir(enterprise);

        // 2. personal — ~/.metacodes 优先于 ~/.claude(后加载覆盖)
        if (@import("platform").paths.homeDir()) |home| {
            const claude_path = try std.fmt.allocPrint(self.allocator, "{s}/.claude/skills", .{home});
            defer self.allocator.free(claude_path);
            try self.loadFromDir(claude_path);

            const cczig_path = try std.fmt.allocPrint(self.allocator, "{s}/.metacodes/skills", .{home});
            defer self.allocator.free(cczig_path);
            try self.loadFromDir(cczig_path);
        }

        // 3. project — 沿 cwd 向上找 .git,逐级加载 .claude/skills 和 .metacodes/skills。
        //    父级先加载、根级最后,保证近 cwd 的(更具体的)覆盖父级。
        if (cwd.len > 0) {
            const root = findRepoRoot(self.allocator, cwd) catch null;
            if (root) |r| {
                defer self.allocator.free(r);
                // 父级 ... cwd:逐级走,先父后子
                try self.loadProjectChain(r, cwd);
            } else {
                // 不在 git repo:只加载 cwd 本身
                try self.loadProjectDir(cwd);
            }
        }
    }

    /// 从 root 一路走到 cwd(包含),每级加载 .claude/skills 和 .metacodes/skills。
    /// 越深(越接近 cwd)的覆盖越浅的。
    fn loadProjectChain(self: *SkillSet, root: []const u8, cwd: []const u8) !void {
        // root 必须是 cwd 的前缀
        if (!std.mem.startsWith(u8, cwd, root)) {
            try self.loadProjectDir(cwd);
            return;
        }
        try self.loadProjectDir(root);
        if (std.mem.eql(u8, root, cwd)) return;

        // 从 root 后面开始,按 '/' 分段,逐级 push
        var cursor: usize = root.len;
        // 跳过开头的 /
        if (cursor < cwd.len and cwd[cursor] == '/') cursor += 1;
        while (cursor < cwd.len) {
            const next_slash = std.mem.indexOfScalarPos(u8, cwd, cursor, '/') orelse cwd.len;
            const sub = cwd[0..next_slash];
            try self.loadProjectDir(sub);
            cursor = next_slash + 1;
        }
    }

    fn loadProjectDir(self: *SkillSet, dir: []const u8) !void {
        const claude_path = try std.fmt.allocPrint(self.allocator, "{s}/.claude/skills", .{dir});
        defer self.allocator.free(claude_path);
        try self.loadFromDir(claude_path);

        const cczig_path = try std.fmt.allocPrint(self.allocator, "{s}/.metacodes/skills", .{dir});
        defer self.allocator.free(cczig_path);
        try self.loadFromDir(cczig_path);
    }

    pub fn loadFromDir(self: *SkillSet, dir_path: []const u8) !void {
        const path_z = try self.allocator.dupeZ(u8, dir_path);
        defer self.allocator.free(path_z);
        const dir = std.c.opendir(path_z) orelse return; // 不存在即 no-op
        defer _ = std.c.closedir(dir);

        while (std.c.readdir(dir)) |entry_ptr| {
            const entry = entry_ptr.*;
            const name_slice = std.mem.sliceTo(&entry.name, 0);
            if (name_slice.len == 0) continue;
            if (name_slice[0] == '.') continue; // . / ..

            const skill_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, name_slice });
            errdefer self.allocator.free(skill_path);

            const md_path = try std.fmt.allocPrint(self.allocator, "{s}/SKILL.md", .{skill_path});
            defer self.allocator.free(md_path);

            const md_contents = readAllFile(self.allocator, md_path) catch |err| switch (err) {
                error.FileNotFound => {
                    self.allocator.free(skill_path);
                    continue;
                },
                else => return err,
            };
            errdefer self.allocator.free(md_contents);

            // 目录名是 fallback name(若 frontmatter 没有 name)。Claude Code 规范:
            // 命令名来自目录名(plugin-root 除外);frontmatter name 仅是显示标签。
            const skill = parseSkillMdWithFallback(self.allocator, md_contents, skill_path, name_slice) catch |err| {
                // parse 错误(例:缺 description)只 log,不中止后续 skill 加载
                @import("../util/log.zig").warn("skill", "parse failed {s}: {s}", .{ md_path, @errorName(err) });
                self.allocator.free(md_contents);
                self.allocator.free(skill_path);
                continue;
            };
            self.allocator.free(md_contents);
            self.allocator.free(skill_path);

            // 重名:后加载覆盖先加载(对齐"高优先级最后加载")
            var replaced = false;
            for (self.skills.items, 0..) |existing, i| {
                if (std.mem.eql(u8, existing.name, skill.name)) {
                    self.skills.items[i].deinit(self.allocator);
                    self.skills.items[i] = skill;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try self.skills.append(self.allocator, skill);
        }
    }

    pub fn find(self: *const SkillSet, name: []const u8) ?*const Skill {
        for (self.skills.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    pub fn len(self: *const SkillSet) usize {
        return self.skills.items.len;
    }
};

/// 系统级 skill 路径(enterprise 分发用)。macOS / Linux 都用 /etc。
fn enterprisePath() []const u8 {
    return "/etc/metacodes/skills";
}

/// 从 start_dir 向上找 `.git` 目录(或文件,对应 git worktree)。
/// 找到返回 root 的 owned slice;到 / 还没找到返 error.NotInGitRepo。
pub fn findRepoRoot(allocator: std.mem.Allocator, start_dir: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (start_dir.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..start_dir.len], start_dir);
    var dir_len = start_dir.len;
    // 去掉尾部 /
    while (dir_len > 1 and buf[dir_len - 1] == '/') dir_len -= 1;

    while (dir_len > 0) {
        // 构造 <dir>/.git\0
        const git_suffix = "/.git";
        if (dir_len + git_suffix.len + 1 >= buf.len) return error.PathTooLong;
        @memcpy(buf[dir_len .. dir_len + git_suffix.len], git_suffix);
        buf[dir_len + git_suffix.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&buf);
        // 用 open 试探(目录或文件都接受 — git worktree 的 .git 是文件)
        const fd = pfs.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd >= 0) {
            _ = pfs.close(fd);
            return try allocator.dupe(u8, buf[0..dir_len]);
        }
        // 向上一级
        if (dir_len == 1) break; // 已经是 "/"
        var new_len = dir_len;
        while (new_len > 1 and buf[new_len - 1] != '/') new_len -= 1;
        while (new_len > 1 and buf[new_len - 1] == '/') new_len -= 1;
        if (new_len == dir_len) break;
        dir_len = new_len;
    }
    return error.NotInGitRepo;
}

fn readAllFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.ReadError,
    };
    defer _ = pfs.close(fd);
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

/// 解析 SKILL.md;若 frontmatter 无 name 用目录名作 fallback。
/// 把 frontmatter 后的内容当 body。完整字段支持见 Skill struct 文档。
pub fn parseSkillMdWithFallback(allocator: std.mem.Allocator, md: []const u8, source_path: []const u8, dir_name: []const u8) !Skill {
    var name: []const u8 = "";
    var description: []const u8 = "";
    var allowed_raw: []const u8 = "";
    var disallowed_raw: []const u8 = "";
    var arguments_raw: []const u8 = "";
    var disable_invoke = false;
    var context_str: []const u8 = "inline";
    var agent_str: []const u8 = "";
    var model_str: []const u8 = "";
    var shell_str: []const u8 = "bash";
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
                if (trimmed[0] == '#') continue; // 注释
                const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
                const key = std.mem.trim(u8, trimmed[0..colon], " \t");
                const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                // Claude Code 字段(中划线) + 兼容旧版(下划线)
                if (std.mem.eql(u8, key, "name")) {
                    name = value;
                } else if (std.mem.eql(u8, key, "description")) {
                    description = value;
                } else if (std.mem.eql(u8, key, "allowed-tools") or std.mem.eql(u8, key, "allowed_tools")) {
                    allowed_raw = value;
                } else if (std.mem.eql(u8, key, "disallowed-tools") or std.mem.eql(u8, key, "disallowed_tools")) {
                    disallowed_raw = value;
                } else if (std.mem.eql(u8, key, "arguments")) {
                    arguments_raw = value;
                } else if (std.mem.eql(u8, key, "disable-model-invocation") or std.mem.eql(u8, key, "disable_model_invocation")) {
                    disable_invoke = parseBool(value);
                } else if (std.mem.eql(u8, key, "context")) {
                    context_str = value;
                } else if (std.mem.eql(u8, key, "agent")) {
                    agent_str = value;
                } else if (std.mem.eql(u8, key, "model")) {
                    model_str = value;
                } else if (std.mem.eql(u8, key, "shell")) {
                    shell_str = value;
                }
            }
        }
    }

    if (name.len == 0) name = dir_name;
    if (name.len == 0) return error.MissingSkillName;

    // 解析 allowed-tools / disallowed-tools / arguments(都是逗号或空格分隔,YAML list `[a, b]` 也支持)
    const allowed_tools = try parseStringList(allocator, allowed_raw);
    errdefer freeStringList(allocator, allowed_tools);
    const disallowed_tools = try parseStringList(allocator, disallowed_raw);
    errdefer freeStringList(allocator, disallowed_tools);
    const arguments = try parseStringList(allocator, arguments_raw);
    errdefer freeStringList(allocator, arguments);

    const ctx_enum: ExecContext = if (std.mem.eql(u8, context_str, "fork")) .fork else .inline_ctx;

    return .{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, description),
        .body = try allocator.dupe(u8, body),
        .allowed_tools = allowed_tools,
        .disallowed_tools = disallowed_tools,
        .arguments = arguments,
        .disable_model_invocation = disable_invoke,
        .context = ctx_enum,
        .agent = try allocator.dupe(u8, agent_str),
        .model = try allocator.dupe(u8, model_str),
        .shell = try allocator.dupe(u8, shell_str),
        .source_path = try allocator.dupe(u8, source_path),
    };
}

/// 旧 API,保留向后兼容(测试 + 老代码用)。
pub fn parseSkillMd(allocator: std.mem.Allocator, md: []const u8, source_path: []const u8) !Skill {
    return parseSkillMdWithFallback(allocator, md, source_path, "");
}

/// 解析 frontmatter 列表值。支持:
///   `Read, Grep, Glob`       (逗号分隔)
///   `Read Grep Glob`         (空格分隔)
///   `[Read, Grep, Glob]`     (YAML list)
///   `Bash(git *), Read`      (Claude Code 权限语法,整体当一项,不在括号内拆)
fn parseStringList(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    // 去 YAML list 的 [ ]
    var s = std.mem.trim(u8, raw, " \t");
    if (s.len >= 2 and s[0] == '[' and s[s.len - 1] == ']') s = s[1 .. s.len - 1];
    if (s.len == 0) return try out.toOwnedSlice(allocator);

    // 按逗号拆,逗号在括号内的不拆(支持 Bash(git *))
    var depth: i32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (i == s.len or (s[i] == ',' and depth == 0)) {
            const seg = std.mem.trim(u8, s[start..i], " \t");
            if (seg.len > 0) {
                // 段内空格分隔再拆一次(只在 depth==0 段)
                if (!hasParen(seg)) {
                    var sp_it = std.mem.tokenizeAny(u8, seg, " \t");
                    while (sp_it.next()) |tok| {
                        const t = std.mem.trim(u8, tok, " \t");
                        if (t.len > 0) try out.append(allocator, try allocator.dupe(u8, t));
                    }
                } else {
                    try out.append(allocator, try allocator.dupe(u8, seg));
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

fn hasParen(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '(') != null;
}

fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |s| allocator.free(s);
    allocator.free(list);
}

fn parseBool(s: []const u8) bool {
    return std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "yes") or std.mem.eql(u8, s, "1");
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseSkillMd: minimal frontmatter (old api compat)" {
    const md =
        "---\n" ++
        "name: test-skill\n" ++
        "description: A test skill\n" ++
        "---\n" ++
        "Body content here.\n";
    var s = try parseSkillMd(testing.allocator, md, "/tmp/fake");
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("test-skill", s.name);
    try testing.expectEqualStrings("A test skill", s.description);
    try testing.expect(std.mem.indexOf(u8, s.body, "Body content") != null);
    try testing.expect(s.allowed_tools.len == 0);
    try testing.expect(s.disable_model_invocation == false);
    try testing.expect(s.context == .inline_ctx);
}

test "parseSkillMd: allowed_tools old underscore name" {
    const md =
        "---\n" ++
        "name: scoped\n" ++
        "description: desc\n" ++
        "allowed_tools: Read, Grep, Glob\n" ++
        "---\n" ++
        "body";
    var s = try parseSkillMd(testing.allocator, md, "/tmp/fake");
    defer s.deinit(testing.allocator);
    try testing.expect(s.allowed_tools.len == 3);
    try testing.expectEqualStrings("Read", s.allowed_tools[0]);
}

test "parseSkillMd: allowed-tools hyphen + Bash(git *) parens" {
    const md =
        "---\n" ++
        "name: gitops\n" ++
        "description: git ops\n" ++
        "allowed-tools: Read, Bash(git *), Grep\n" ++
        "---\n" ++
        "body";
    var s = try parseSkillMd(testing.allocator, md, "/x");
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), s.allowed_tools.len);
    try testing.expectEqualStrings("Read", s.allowed_tools[0]);
    try testing.expectEqualStrings("Bash(git *)", s.allowed_tools[1]);
    try testing.expectEqualStrings("Grep", s.allowed_tools[2]);
}

test "parseSkillMd: YAML list form" {
    const md =
        "---\n" ++
        "name: yl\n" ++
        "description: yaml list\n" ++
        "allowed-tools: [Read, Grep]\n" ++
        "arguments: [issue, branch]\n" ++
        "---\n" ++
        "body";
    var s = try parseSkillMd(testing.allocator, md, "/x");
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), s.allowed_tools.len);
    try testing.expectEqual(@as(usize, 2), s.arguments.len);
    try testing.expectEqualStrings("issue", s.arguments[0]);
}

test "parseSkillMd: disable-model-invocation + context fork + agent + model" {
    const md =
        "---\n" ++
        "name: pr-summary\n" ++
        "description: Summarize PR\n" ++
        "disable-model-invocation: true\n" ++
        "context: fork\n" ++
        "agent: Explore\n" ++
        "model: claude-haiku-4-5-20251001\n" ++
        "shell: bash\n" ++
        "---\n" ++
        "body";
    var s = try parseSkillMd(testing.allocator, md, "/x");
    defer s.deinit(testing.allocator);
    try testing.expect(s.disable_model_invocation == true);
    try testing.expect(s.context == .fork);
    try testing.expectEqualStrings("Explore", s.agent);
    try testing.expectEqualStrings("claude-haiku-4-5-20251001", s.model);
    try testing.expectEqualStrings("bash", s.shell);
}

test "parseSkillMd: missing name uses dir_name fallback" {
    const md =
        "---\n" ++
        "description: no name in fm\n" ++
        "---\n" ++
        "body";
    var s = try parseSkillMdWithFallback(testing.allocator, md, "/tmp/auto", "auto-name");
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("auto-name", s.name);
}

test "parseSkillMd: no frontmatter at all" {
    const md = "just body\n";
    try testing.expectError(error.MissingSkillName, parseSkillMd(testing.allocator, md, "/x"));
}

test "parseSkillMd: comment lines in frontmatter are ignored" {
    const md =
        "---\n" ++
        "# this is a comment\n" ++
        "name: c\n" ++
        "description: d\n" ++
        "---\n" ++
        "body";
    var s = try parseSkillMd(testing.allocator, md, "/x");
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("c", s.name);
}

test "parseStringList: space and YAML list" {
    const list1 = try parseStringList(testing.allocator, "Read Grep Glob");
    defer freeStringList(testing.allocator, list1);
    try testing.expectEqual(@as(usize, 3), list1.len);

    const list2 = try parseStringList(testing.allocator, "[a, b, c]");
    defer freeStringList(testing.allocator, list2);
    try testing.expectEqual(@as(usize, 3), list2.len);
    try testing.expectEqualStrings("a", list2[0]);
}

test "parseStringList: empty" {
    const list = try parseStringList(testing.allocator, "");
    defer freeStringList(testing.allocator, list);
    try testing.expectEqual(@as(usize, 0), list.len);
}

test "SkillSet: loadFromDir finds skills" {
    const tmpdir = "/tmp/cc-zig-skills-test";
    defer cleanupDir(tmpdir);
    try makeTestSkill(tmpdir, "alpha", "---\nname: alpha\ndescription: first\n---\nbody-a");
    try makeTestSkill(tmpdir, "beta", "---\nname: beta\ndescription: second\n---\nbody-b");

    var set = SkillSet.init(testing.allocator);
    defer set.deinit();
    try set.loadFromDir(tmpdir);
    try testing.expect(set.len() == 2);
    try testing.expect(set.find("alpha") != null);
    try testing.expect(set.find("beta") != null);
    try testing.expect(set.find("gamma") == null);
}

test "SkillSet: missing dir is no-op" {
    var set = SkillSet.init(testing.allocator);
    defer set.deinit();
    try set.loadFromDir("/tmp/cc-zig-nonexistent-skills-xxxxx");
    try testing.expect(set.len() == 0);
}

test "SkillSet: duplicate name later loaded wins" {
    const tmpdir1 = "/tmp/cc-zig-skills-dup1";
    const tmpdir2 = "/tmp/cc-zig-skills-dup2";
    defer cleanupDir(tmpdir1);
    defer cleanupDir(tmpdir2);
    try makeTestSkill(tmpdir1, "shared", "---\nname: shared\ndescription: from-global\n---\nglobal-body");
    try makeTestSkill(tmpdir2, "shared", "---\nname: shared\ndescription: from-project\n---\nproject-body");

    var set = SkillSet.init(testing.allocator);
    defer set.deinit();
    try set.loadFromDir(tmpdir1);
    try set.loadFromDir(tmpdir2); // 后加载覆盖
    try testing.expect(set.len() == 1);
    try testing.expectEqualStrings("from-project", set.find("shared").?.description);
}

test "SkillSet: directory name as fallback skill name" {
    const tmpdir = "/tmp/cc-zig-skills-fallback";
    defer cleanupDir(tmpdir);
    // 不写 name 字段,依赖目录名 fallback
    try makeTestSkill(tmpdir, "auto-named", "---\ndescription: derived from dir\n---\nbody");

    var set = SkillSet.init(testing.allocator);
    defer set.deinit();
    try set.loadFromDir(tmpdir);
    try testing.expect(set.len() == 1);
    try testing.expect(set.find("auto-named") != null);
}

test "findRepoRoot: detects .git in current or parent" {
    const a = testing.allocator;
    const cwd = try @import("../util/fs.zig").getCwd(a);
    defer a.free(cwd);
    // 从当前测试工作目录向上找 repo root,避免绑定开发机绝对路径。
    const root = try findRepoRoot(a, cwd);
    defer a.free(root);
    try testing.expect(std.mem.endsWith(u8, root, "cc-t2z"));
}

test "findRepoRoot: returns error in non-repo dir" {
    try testing.expectError(error.NotInGitRepo, findRepoRoot(testing.allocator, "/tmp"));
}

fn makeTestSkill(parent: []const u8, name: []const u8, md: []const u8) !void {
    const allocator = testing.allocator;
    const parent_z = try allocator.dupeZ(u8, parent);
    defer allocator.free(parent_z);
    _ = std.c.mkdir(parent_z, 0o755);
    const skill_dir = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ parent, name }, 0);
    defer allocator.free(skill_dir);
    _ = std.c.mkdir(skill_dir, 0o755);
    const md_path = try std.fmt.allocPrintSentinel(allocator, "{s}/SKILL.md", .{skill_dir}, 0);
    defer allocator.free(md_path);
    const fd = pfs.open(md_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = pfs.write(fd, md[0..md.len]);
    _ = pfs.close(fd);
}

fn cleanupDir(parent: []const u8) void {
    const allocator = testing.allocator;
    const parent_z = allocator.dupeZ(u8, parent) catch return;
    defer allocator.free(parent_z);
    const dir = std.c.opendir(parent_z) orelse return;
    defer _ = std.c.closedir(dir);

    while (std.c.readdir(dir)) |entry_ptr| {
        const entry = entry_ptr.*;
        const name = std.mem.sliceTo(&entry.name, 0);
        if (name.len == 0 or name[0] == '.') continue;
        const md = std.fmt.allocPrintSentinel(allocator, "{s}/{s}/SKILL.md", .{ parent, name }, 0) catch continue;
        defer allocator.free(md);
        _ = std.c.unlink(md);
        const sub = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ parent, name }, 0) catch continue;
        defer allocator.free(sub);
        _ = std.c.rmdir(sub);
    }
    _ = std.c.rmdir(parent_z);
}
