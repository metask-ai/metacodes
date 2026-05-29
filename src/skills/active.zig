//! ActiveSkillState:某个 skill 激活期间的临时权限/池约束。
//!
//! 生命周期:Skill 工具 execute 时设;loop.zig 在下一条 user message 进来前清零。
//!
//! 字段:
//! - allowed_tools:激活时绕过 ask/prompt 直接 allow。支持精确名 + Bash(prefix) 形式。
//! - disallowed_tools:激活时被 dispatch 拒绝(返 ToolBlockedBySkill)。支持同样的语法。
//!
//! 与 tool_pool_filter.zig 双保险(SKILL_DESIGN §11 Stage B.8,硬隔离):
//! - **池裁剪**(agent_loop 调 tool_pool_filter.filterToolDefs):模型在请求体里
//!   看不见被禁工具 → 不会反复尝试。
//! - **权限检查**(本模块 isAllowed/isDisallowed 给 decision.check):即便上游绕过
//!   池裁剪走 dispatch 直入,仍被拦。
//! 池裁剪为主、权限为辅,语义对齐 Claude Code 官方 `allowed-tools`/`disallowed-tools`。

const std = @import("std");
const log = @import("../util/log.zig");

pub const ActiveSkillState = struct {
    skill_name: []const u8,
    /// 已 parse 的允许项(每项是 owned slice)。
    allowed_tools: []const []const u8,
    /// 已 parse 的禁用项。
    disallowed_tools: []const []const u8,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        skill_name: []const u8,
        allowed: []const []const u8,
        disallowed: []const []const u8,
    ) !ActiveSkillState {
        return .{
            .skill_name = try allocator.dupe(u8, skill_name),
            .allowed_tools = try dupeStrings(allocator, allowed),
            .disallowed_tools = try dupeStrings(allocator, disallowed),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ActiveSkillState) void {
        self.allocator.free(self.skill_name);
        for (self.allowed_tools) |s| self.allocator.free(s);
        self.allocator.free(self.allowed_tools);
        for (self.disallowed_tools) |s| self.allocator.free(s);
        self.allocator.free(self.disallowed_tools);
    }

    /// 返回 true 表示工具被 active skill 允许(应绕过权限检查直接 allow)。
    pub fn isAllowed(self: *const ActiveSkillState, tool_name: []const u8, args: []const u8) bool {
        return matchAny(self.allowed_tools, tool_name, args);
    }

    /// 返回 true 表示工具被 active skill 拒用(dispatch 应拒绝)。
    pub fn isDisallowed(self: *const ActiveSkillState, tool_name: []const u8, args: []const u8) bool {
        return matchAny(self.disallowed_tools, tool_name, args);
    }
};

fn dupeStrings(allocator: std.mem.Allocator, src: []const []const u8) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, src.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |s| allocator.free(s);
        allocator.free(out);
    }
    while (i < src.len) : (i += 1) {
        out[i] = try allocator.dupe(u8, src[i]);
    }
    return out;
}

fn matchAny(patterns: []const []const u8, tool_name: []const u8, args: []const u8) bool {
    for (patterns) |pat| {
        if (matchOne(pat, tool_name, args)) return true;
    }
    return false;
}

/// 匹配一条 pattern。语法:
///   "Read"            → tool_name == "Read"
///   "Bash"            → tool_name == "Bash" (任意命令)
///   "Bash(git *)"     → tool_name == "Bash" AND args.command 以 "git " 开头(* 是 prefix 通配)
///   "Bash(git status)" → tool_name == "Bash" AND args.command 完全匹配 "git status"
fn matchOne(pat: []const u8, tool_name: []const u8, args: []const u8) bool {
    const paren_open = std.mem.indexOfScalar(u8, pat, '(');
    if (paren_open == null) {
        // 单纯工具名
        return std.mem.eql(u8, pat, tool_name);
    }
    const name = pat[0..paren_open.?];
    if (!std.mem.eql(u8, name, tool_name)) return false;

    const paren_close = std.mem.lastIndexOfScalar(u8, pat, ')') orelse return false;
    if (paren_close <= paren_open.? + 1) return true; // "Bash()" 等同 "Bash"
    const cmd_pattern = pat[paren_open.? + 1 .. paren_close];

    // 从 args 抽 "command" 字段(对齐 Bash 工具)
    const command = extractCommand(args) orelse return false;

    // pattern 末尾 * 表示前缀匹配
    if (std.mem.endsWith(u8, cmd_pattern, " *") or std.mem.endsWith(u8, cmd_pattern, "*")) {
        const prefix_end = if (std.mem.endsWith(u8, cmd_pattern, " *")) cmd_pattern.len - 1 else cmd_pattern.len - 1;
        const prefix = std.mem.trim(u8, cmd_pattern[0..prefix_end], " \t");
        return std.mem.startsWith(u8, command, prefix);
    }
    return std.mem.eql(u8, command, cmd_pattern);
}

/// 极简从 JSON args 抽 "command" 字段值(只在被引号包裹时识别)。
fn extractCommand(args: []const u8) ?[]const u8 {
    const key = "\"command\":";
    const idx = std.mem.indexOf(u8, args, key) orelse return null;
    var pos = idx + key.len;
    while (pos < args.len and (args[pos] == ' ' or args[pos] == '\t')) : (pos += 1) {}
    if (pos >= args.len or args[pos] != '"') return null;
    pos += 1;
    var end = pos;
    while (end < args.len) : (end += 1) {
        if (args[end] == '\\') {
            end += 1;
            continue;
        }
        if (args[end] == '"') break;
    }
    if (end >= args.len) return null;
    return args[pos..end];
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "isAllowed: bare tool name match" {
    const pats = [_][]const u8{ "Read", "Grep" };
    var st = try ActiveSkillState.init(testing.allocator, "x", &pats, &.{});
    defer st.deinit();
    try testing.expect(st.isAllowed("Read", ""));
    try testing.expect(st.isAllowed("Grep", ""));
    try testing.expect(!st.isAllowed("Bash", ""));
}

test "isAllowed: Bash(git *) prefix" {
    const pats = [_][]const u8{"Bash(git *)"};
    var st = try ActiveSkillState.init(testing.allocator, "x", &pats, &.{});
    defer st.deinit();
    try testing.expect(st.isAllowed("Bash", "{\"command\":\"git status\"}"));
    try testing.expect(st.isAllowed("Bash", "{\"command\":\"git push origin main\"}"));
    try testing.expect(!st.isAllowed("Bash", "{\"command\":\"rm -rf /\"}"));
    try testing.expect(!st.isAllowed("Read", ""));
}

test "isAllowed: Bash(exact-cmd)" {
    const pats = [_][]const u8{"Bash(npm test)"};
    var st = try ActiveSkillState.init(testing.allocator, "x", &pats, &.{});
    defer st.deinit();
    try testing.expect(st.isAllowed("Bash", "{\"command\":\"npm test\"}"));
    try testing.expect(!st.isAllowed("Bash", "{\"command\":\"npm test -- --watch\"}"));
}

test "isDisallowed: blocks named tool" {
    const allowed = [_][]const u8{};
    const disallowed = [_][]const u8{ "AskUserQuestion", "Bash" };
    var st = try ActiveSkillState.init(testing.allocator, "x", &allowed, &disallowed);
    defer st.deinit();
    try testing.expect(st.isDisallowed("AskUserQuestion", "{}"));
    try testing.expect(st.isDisallowed("Bash", "{\"command\":\"ls\"}"));
    try testing.expect(!st.isDisallowed("Read", ""));
}

test "extractCommand: handles escaped quotes" {
    const args = "{\"command\":\"echo \\\"hi\\\"\",\"timeout\":1000}";
    const cmd = extractCommand(args).?;
    try testing.expectEqualStrings("echo \\\"hi\\\"", cmd);
}
