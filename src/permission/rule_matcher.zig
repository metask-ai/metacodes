//! 细粒度权限规则匹配器。
//!
//! 规则 schema（config.json）：
//!   "permission_rules": [
//!     {"match": {"tool": "Bash", "command_prefix": "git "}, "decision": "allow"},
//!     {"match": {"tool": "Write", "path_glob": "./src/**"}, "decision": "allow"},
//!     {"match": {"tool": "Edit", "path_glob": "/etc/**"}, "decision": "deny"}
//!   ]
//!
//! 匹配顺序：规则数组按下标正序；第一个命中生效；都不命中 → 落四模式兜底。
//!
//! 字段支持：
//!   - match.tool              必填，精确匹配工具名
//!   - match.command_prefix    可选，对 Bash 的 args 里 "command" 字段做 startsWith
//!   - match.path_glob         可选，对 Write/Edit 的 args 里 "path"/"file_path" 做 glob
//! decision:
//!   - "allow" / "deny" / "ask"
//!
//! 当前简化：
//!   - glob 只支持 * ** ?；无 [a-z] 类
//!   - 所有 match 字段 AND（都要命中）
//!   - 无通配 tool（必填精确名）

const std = @import("std");
const common = @import("../tools/common.zig");
const Decision = @import("decision.zig").Decision;
const util_json = @import("../util/json.zig");
const rule_spec = @import("rule_spec.zig");

pub const Rule = struct {
    tool: []const u8,
    command_prefix: ?[]const u8 = null,
    path_glob: ?[]const u8 = null,
    decision: Decision,
};

/// 规则集：持有 owned 内存。
pub const RuleSet = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayList(Rule),

    pub fn init(allocator: std.mem.Allocator) RuleSet {
        return .{ .allocator = allocator, .rules = .empty };
    }

    pub fn deinit(self: *RuleSet) void {
        for (self.rules.items) |r| {
            self.allocator.free(r.tool);
            if (r.command_prefix) |p| self.allocator.free(p);
            if (r.path_glob) |p| self.allocator.free(p);
        }
        self.rules.deinit(self.allocator);
    }

    /// 手动追加一条规则（测试 / 运行时插入用）。
    pub fn append(self: *RuleSet, r: Rule) !void {
        try self.rules.append(self.allocator, r);
    }

    /// 尝试匹配：命中返回 decision；都不命中返回 null（调用方回退到四模式）
    pub fn match(self: *const RuleSet, tool_name: []const u8, args: []const u8) ?Decision {
        for (self.rules.items) |r| {
            if (!std.mem.eql(u8, r.tool, tool_name)) continue;

            if (r.command_prefix) |prefix| {
                const cmd = common.extractJsonArg(args, "command") orelse continue;
                if (!std.mem.startsWith(u8, cmd, prefix)) continue;
            }

            if (r.path_glob) |pattern| {
                // 优先 file_path（Edit），回退 path（Write）
                const path_raw = common.extractJsonArg(args, "file_path") orelse
                    common.extractJsonArg(args, "path") orelse continue;
                // **B1 修复(第5镜像点)**:globMatch 前 canonicalize——unescape(与工具层落盘
                // 同函数)+ 词法折叠 `..`(相对折叠,本匹配器无 cwd 锚)。否则 allow 规则
                // path_glob `src/**` 对 `src/../../etc/passwd` 匹配 → 静默放行逃逸写。
                // 折叠后 `../etc/passwd` 不再匹配 `src/**`。canonicalize 失败 → 保守用原文
                // (仅 OOM / 超长病态路径,工具层同样会拒)。
                const canon = canonicalizeForGlob(self.allocator, path_raw);
                defer if (canon.owned) |o| self.allocator.free(o);
                if (!globMatch(pattern, canon.path)) continue;
            }

            return r.decision;
        }
        return null;
    }
};

/// canonicalize 一个路径供 glob 匹配:unescape(util_json,与工具层同函数)+ 词法折叠 `..`
/// (rule_spec.foldLexicalRel,相对折叠——本匹配器无 cwd)。返回 {path, owned}:owned 非 null
/// 时 caller 须 free。任一步失败(OOM / 超长)→ 保守退回原文(owned=null)。
const Canon = struct { path: []const u8, owned: ?[]u8 };
fn canonicalizeForGlob(alloc: std.mem.Allocator, path_raw: []const u8) Canon {
    const unesc = util_json.unescapeString(path_raw, alloc) catch return .{ .path = path_raw, .owned = null };
    var fold_buf: [std.fs.max_path_bytes]u8 = undefined;
    const folded = rule_spec.foldLexicalRel(&fold_buf, unesc) orelse {
        // 折叠失败(超长):至少用 unescape 后的(owned),仍消除转义分歧
        return .{ .path = unesc, .owned = unesc };
    };
    // folded 指向栈 buf,需 dupe 逃逸;dupe 失败退回 unesc
    const owned = alloc.dupe(u8, folded) catch return .{ .path = unesc, .owned = unesc };
    alloc.free(unesc);
    return .{ .path = owned, .owned = owned };
}

/// 简化 glob 匹配：
/// - `?` 任意单个非 `/` 字符
/// - `*` 任意非 `/` 序列（含空）
/// - `**` 任意字符序列（含 `/`）
/// - 其他字符精确匹配
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    return globMatchImpl(pattern, 0, text, 0);
}

fn globMatchImpl(pattern: []const u8, pi: usize, text: []const u8, ti: usize) bool {
    var p = pi;
    var t = ti;

    while (p < pattern.len) {
        const pc = pattern[p];

        if (pc == '*') {
            // 判断是 * 还是 **
            const is_double = p + 1 < pattern.len and pattern[p + 1] == '*';
            if (is_double) {
                // ** 跳过；消耗任意字符（含 /）
                const next_p = p + 2;
                if (next_p == pattern.len) return true; // trailing ** 匹配一切
                var k = t;
                while (true) {
                    if (globMatchImpl(pattern, next_p, text, k)) return true;
                    if (k >= text.len) return false;
                    k += 1;
                }
            } else {
                // * 匹配非 / 序列
                const next_p = p + 1;
                var k = t;
                while (true) {
                    if (globMatchImpl(pattern, next_p, text, k)) return true;
                    if (k >= text.len) return false;
                    if (text[k] == '/') return false;
                    k += 1;
                }
            }
        }

        if (t >= text.len) return false;

        if (pc == '?') {
            if (text[t] == '/') return false;
            p += 1;
            t += 1;
            continue;
        }

        if (pc == text[t]) {
            p += 1;
            t += 1;
            continue;
        }

        return false;
    }
    return t == text.len;
}

// ============================================================================
// 测试
// ============================================================================

test "globMatch literal" {
    try std.testing.expect(globMatch("abc", "abc"));
    try std.testing.expect(!globMatch("abc", "abd"));
    try std.testing.expect(!globMatch("abc", "ab"));
    try std.testing.expect(!globMatch("abc", "abcd"));
}

test "globMatch star" {
    try std.testing.expect(globMatch("foo*", "foo"));
    try std.testing.expect(globMatch("foo*", "foobar"));
    try std.testing.expect(!globMatch("foo*", "foo/bar"));
    try std.testing.expect(globMatch("*.txt", "readme.txt"));
    try std.testing.expect(!globMatch("*.txt", "dir/readme.txt"));
}

test "globMatch double-star" {
    try std.testing.expect(globMatch("src/**", "src/foo.zig"));
    try std.testing.expect(globMatch("src/**", "src/a/b/c.zig"));
    try std.testing.expect(globMatch("**/*.zig", "src/foo.zig"));
    try std.testing.expect(globMatch("**/*.zig", "a/b/c.zig"));
    try std.testing.expect(!globMatch("src/**", "other/foo.zig"));
}

test "globMatch question mark" {
    try std.testing.expect(globMatch("a?c", "abc"));
    try std.testing.expect(!globMatch("a?c", "a/c"));
}

test "RuleSet match Bash command_prefix" {
    const a = std.testing.allocator;
    var rs = RuleSet.init(a);
    defer rs.deinit();
    try rs.append(.{
        .tool = try a.dupe(u8, "Bash"),
        .command_prefix = try a.dupe(u8, "git "),
        .decision = .allow,
    });

    try std.testing.expect(rs.match("Bash", "{\"command\":\"git status\"}") == .allow);
    try std.testing.expect(rs.match("Bash", "{\"command\":\"rm foo\"}") == null);
    try std.testing.expect(rs.match("Read", "{\"command\":\"git status\"}") == null);
}

test "RuleSet match Write path_glob" {
    const a = std.testing.allocator;
    var rs = RuleSet.init(a);
    defer rs.deinit();
    try rs.append(.{
        .tool = try a.dupe(u8, "Write"),
        .path_glob = try a.dupe(u8, "src/**"),
        .decision = .allow,
    });

    try std.testing.expect(rs.match("Write", "{\"path\":\"src/foo.zig\"}") == .allow);
    try std.testing.expect(rs.match("Write", "{\"path\":\"other/foo.zig\"}") == null);
    try std.testing.expect(rs.match("Write", "{\"file_path\":\"src/bar.zig\"}") == .allow);
}

test "B1 绕过修复(第5镜像点·旧 rule_matcher): allow path_glob src/** 不放行 .. 逃逸" {
    const a = std.testing.allocator;
    var rs = RuleSet.init(a);
    defer rs.deinit();
    try rs.append(.{
        .tool = try a.dupe(u8, "Write"),
        .path_glob = try a.dupe(u8, "src/**"),
        .decision = .allow,
    });
    // sanity:src 内正常文件 allow(规则生效)
    try std.testing.expect(rs.match("Write", "{\"file_path\":\"src/foo.zig\"}") == .allow);
    // 明文 .. 逃逸:折叠成 ../etc/passwd 不再匹配 src/** → null(修复前 == .allow → 写 /etc/passwd)
    try std.testing.expect(rs.match("Write", "{\"file_path\":\"src/../../etc/passwd\"}") == null);
    // 转义 .. 逃逸:unescape + 折叠 同样 null
    try std.testing.expect(rs.match("Write", "{\"file_path\":\"src/\\u002e\\u002e/\\u002e\\u002e/etc/passwd\"}") == null);
    // src 内经 . / 冗余仍 allow(canonicalize 不误伤)
    try std.testing.expect(rs.match("Write", "{\"file_path\":\"src/./sub/foo.zig\"}") == .allow);
}

test "RuleSet order: first match wins" {
    const a = std.testing.allocator;
    var rs = RuleSet.init(a);
    defer rs.deinit();
    try rs.append(.{
        .tool = try a.dupe(u8, "Bash"),
        .command_prefix = try a.dupe(u8, "rm "),
        .decision = .deny,
    });
    try rs.append(.{
        .tool = try a.dupe(u8, "Bash"),
        .command_prefix = try a.dupe(u8, "rm "),
        .decision = .allow, // 不生效
    });

    try std.testing.expect(rs.match("Bash", "{\"command\":\"rm foo\"}") == .deny);
}
