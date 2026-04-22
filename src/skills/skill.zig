//! Skill 类型与加载器（对齐 Claude Code 用户文档）。
//!
//! 一个 skill 是文件系统中的一个目录：
//!   ~/.cc-zig/skills/<name>/
//!     SKILL.md           包含 YAML frontmatter + markdown body
//!     resources/         可选：skill 运行时可引用的辅助文件
//!
//! SKILL.md 格式：
//!   ---
//!   name: my-skill
//!   description: Short description / when to use.
//!   allowed_tools: Read, Grep         # 可选，逗号分隔，限制 skill 运行时工具集
//!   ---
//!   <markdown body>：skill 激活后注入到 conversation 的 system 增量
//!
//! 加载策略（优先级由高到低）：
//!   1. $CWD/.cc-zig/skills/*            项目级（覆盖全局同名）
//!   2. $HOME/.cc-zig/skills/*           全局
//! 重名：项目级覆盖全局。

const std = @import("std");

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    body: []const u8, // skill activation 时注入
    allowed_tools: []const []const u8,
    source_path: []const u8, // 目录路径（用于加载 resources）

    pub fn deinit(self: Skill, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.body);
        for (self.allowed_tools) |t| allocator.free(t);
        allocator.free(self.allowed_tools);
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

    /// 从 project + home 加载。project_root 可传 "" 跳过项目级。
    pub fn loadFromStandardPaths(self: *SkillSet, project_root: []const u8) !void {
        // 先加载全局（$HOME/.cc-zig/skills）
        if (std.c.getenv("HOME")) |home_c| {
            const home = std.mem.span(home_c);
            const global_path = try std.fmt.allocPrint(self.allocator, "{s}/.cc-zig/skills", .{home});
            defer self.allocator.free(global_path);
            try self.loadFromDir(global_path);
        }
        // 再加载项目（覆盖同名）
        if (project_root.len > 0) {
            const project_path = try std.fmt.allocPrint(self.allocator, "{s}/.cc-zig/skills", .{project_root});
            defer self.allocator.free(project_path);
            try self.loadFromDir(project_path);
        }
    }

    pub fn loadFromDir(self: *SkillSet, dir_path: []const u8) !void {
        const path_z = try self.allocator.dupeZ(u8, dir_path);
        defer self.allocator.free(path_z);
        const dir = std.c.opendir(path_z) orelse return; // 不存在即 no-op
        defer _ = std.c.closedir(dir);

        while (std.c.readdir(dir)) |entry_ptr| {
            const entry = entry_ptr.*;
            // entry.name 是 sentinel-terminated
            const name_slice = std.mem.sliceTo(&entry.name, 0);
            if (name_slice.len == 0) continue;
            if (name_slice[0] == '.') continue; // . / ..

            const skill_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, name_slice });
            errdefer self.allocator.free(skill_path);

            // 判断是不是目录：尝试 open SKILL.md
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

            const skill = try parseSkillMd(self.allocator, md_contents, skill_path);
            self.allocator.free(md_contents);
            self.allocator.free(skill_path); // parseSkillMd 内部 dup 了 source_path

            // 名字重复：用新的覆盖旧的（project 覆盖 home）
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

fn readAllFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.ReadError,
    };
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

/// 解析 SKILL.md：frontmatter + body。frontmatter 在 `---\n...\n---\n` 之间。
/// 字段：name / description / allowed_tools（逗号分隔）
pub fn parseSkillMd(allocator: std.mem.Allocator, md: []const u8, source_path: []const u8) !Skill {
    var name: []const u8 = "";
    var description: []const u8 = "";
    var allowed_tools_raw: []const u8 = "";
    var body: []const u8 = md;

    if (std.mem.startsWith(u8, md, "---\n")) {
        const fm_start = 4;
        if (std.mem.indexOfPos(u8, md, fm_start, "\n---\n")) |fm_end| {
            const fm = md[fm_start..fm_end];
            body = md[fm_end + 5 ..];
            // 解析 key: value 每行
            var line_it = std.mem.splitScalar(u8, fm, '\n');
            while (line_it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;
                const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
                const key = std.mem.trim(u8, trimmed[0..colon], " \t");
                const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                if (std.mem.eql(u8, key, "name")) name = value;
                if (std.mem.eql(u8, key, "description")) description = value;
                if (std.mem.eql(u8, key, "allowed_tools")) allowed_tools_raw = value;
            }
        }
    }

    if (name.len == 0) return error.MissingSkillName;

    // 拆 allowed_tools
    var tools_list = std.ArrayList([]const u8).empty;
    errdefer {
        for (tools_list.items) |t| allocator.free(t);
        tools_list.deinit(allocator);
    }
    if (allowed_tools_raw.len > 0) {
        var it = std.mem.splitScalar(u8, allowed_tools_raw, ',');
        while (it.next()) |tok| {
            const t = std.mem.trim(u8, tok, " \t");
            if (t.len > 0) try tools_list.append(allocator, try allocator.dupe(u8, t));
        }
    }

    return .{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, description),
        .body = try allocator.dupe(u8, body),
        .allowed_tools = try tools_list.toOwnedSlice(allocator),
        .source_path = try allocator.dupe(u8, source_path),
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseSkillMd: minimal frontmatter" {
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
}

test "parseSkillMd: with allowed_tools" {
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
    try testing.expectEqualStrings("Grep", s.allowed_tools[1]);
    try testing.expectEqualStrings("Glob", s.allowed_tools[2]);
}

test "parseSkillMd: missing name errors" {
    const md =
        "---\n" ++
        "description: no name\n" ++
        "---\n" ++
        "body";
    try testing.expectError(error.MissingSkillName, parseSkillMd(testing.allocator, md, "/tmp/fake"));
}

test "parseSkillMd: no frontmatter errors" {
    const md = "just body\n";
    try testing.expectError(error.MissingSkillName, parseSkillMd(testing.allocator, md, "/tmp/fake"));
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

test "SkillSet: duplicate name replaces" {
    const tmpdir1 = "/tmp/cc-zig-skills-dup1";
    const tmpdir2 = "/tmp/cc-zig-skills-dup2";
    defer cleanupDir(tmpdir1);
    defer cleanupDir(tmpdir2);
    try makeTestSkill(tmpdir1, "shared", "---\nname: shared\ndescription: from-global\n---\nglobal-body");
    try makeTestSkill(tmpdir2, "shared", "---\nname: shared\ndescription: from-project\n---\nproject-body");

    var set = SkillSet.init(testing.allocator);
    defer set.deinit();
    try set.loadFromDir(tmpdir1);
    try set.loadFromDir(tmpdir2); // 覆盖
    try testing.expect(set.len() == 1);
    try testing.expectEqualStrings("from-project", set.find("shared").?.description);
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
    const fd = std.c.open(md_path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = std.c.write(fd, md.ptr, md.len);
    _ = std.c.close(fd);
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
