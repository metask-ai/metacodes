//! Settings 聚合 + 优先级合并 + 评估。
//!
//! 5 层优先级(高 → 低):
//!   1. Managed       /Library/Application Support/ClaudeCode/managed-settings.json
//!                    /etc/claude-code/managed-settings.json
//!   2. CLI           --settings <path>(显式)+ --allowedTools / --disallowedTools
//!   3. Local project <project>/.claude/settings.local.json
//!   4. Shared project <project>/.claude/settings.json
//!   5. User          ~/.claude/settings.json
//!
//! 评估语义(对齐 Claude Code permissions.md):
//!   - **Deny 优先**:任意层 deny 命中 → 整体 deny,搜索停止
//!   - 否则寻找 allow:任意层 allow → 整体 allow
//!   - 否则寻找 ask:任意层 ask → 整体 ask
//!   - 都没命中 → 由 mode 默认(undecided,交回 mode-decision)
//!
//! 不在本模块:
//!   - mode 默认决策(.default/.accept_edits/...):见 permission/decision.zig
//!   - protected paths 内建清单(Edit/Write to .git/.bashrc):见 settings.zig
//!     的 PROTECTED_PATHS + evaluate() 入口前置短路
//!   - sandbox 配置:同 settings 文件里 sandbox.* 段(Stage C 再处理)

const std = @import("std");
const rule_spec = @import("rule_spec.zig");

// ============================================================================
// Settings 数据结构
// ============================================================================

/// 单条规则字符串 + 来源层级(便于 debug)。
pub const Rule = struct {
    raw: []const u8,
    spec: rule_spec.RuleSpec,
    source: Source,
};

pub const Source = enum { managed, cli, local_project, shared_project, user, builtin };

/// 单层 permissions 段(从一个 JSON 文件里解析)。
pub const Layer = struct {
    source: Source,
    allow: []const Rule,
    ask: []const Rule,
    deny: []const Rule,
    additional_directories: []const []const u8 = &.{},
    disable_bypass_permissions_mode: bool = false,
    disable_auto_mode: bool = false,
};

/// 聚合后的 settings(所有层合在一起,按 source 区分)。
pub const MergedSettings = struct {
    layers: []const Layer,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MergedSettings) void {
        for (self.layers) |L| {
            for (L.allow) |r| self.allocator.free(r.raw);
            for (L.ask) |r| self.allocator.free(r.raw);
            for (L.deny) |r| self.allocator.free(r.raw);
            self.allocator.free(L.allow);
            self.allocator.free(L.ask);
            self.allocator.free(L.deny);
            for (L.additional_directories) |d| self.allocator.free(d);
            self.allocator.free(L.additional_directories);
        }
        self.allocator.free(self.layers);
    }

    /// 是否设置了 disableBypassPermissionsMode(任意层)
    pub fn isBypassDisabled(self: *const MergedSettings) bool {
        for (self.layers) |L| if (L.disable_bypass_permissions_mode) return true;
        return false;
    }

    pub fn isAutoModeDisabled(self: *const MergedSettings) bool {
        for (self.layers) |L| if (L.disable_auto_mode) return true;
        return false;
    }

    /// 收集所有 additionalDirectories
    pub fn collectAdditionalDirs(self: *const MergedSettings, alloc: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(alloc);
        for (self.layers) |L| {
            for (L.additional_directories) |d| {
                try out.append(alloc, d);
            }
        }
        return try out.toOwnedSlice(alloc);
    }
};

// ============================================================================
// Protected paths(内建,不可被 settings 覆盖)
// ============================================================================

/// 即便没 deny 规则,Edit/Write 命中这些 path → 必须 ask(无 auto-allow)。
/// 对齐 Claude Code 文档"Protected paths"段。
pub const PROTECTED_PATHS = [_][]const u8{
    ".git/",
    ".gitignore",
    ".vscode/",
    ".idea/",
    ".env",
    ".env.local",
    ".env.production",
    ".bashrc",
    ".bash_profile",
    ".zshrc",
    ".zprofile",
    ".profile",
    ".npmrc",
    ".yarnrc",
    ".ssh/",
    ".aws/",
    ".docker/config.json",
    ".kube/config",
    ".gnupg/",
    ".pypirc",
};

pub fn isProtectedPath(path: []const u8) bool {
    // 找最后一个 / 之后的部分作 basename
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    // basename 等于受保护名 → 命中
    inline for (PROTECTED_PATHS) |p| {
        // 去掉末尾 / 比 basename
        const trimmed = if (std.mem.endsWith(u8, p, "/")) p[0 .. p.len - 1] else p;
        if (std.mem.eql(u8, basename, trimmed)) return true;
        // 包含目录形 ".git/" → path 含 "/.git/" 或起始 ".git/"
        if (std.mem.endsWith(u8, p, "/")) {
            const seg = p[0 .. p.len - 1];
            if (std.mem.indexOf(u8, path, seg) != null) {
                // 必须是完整段:前面是 / 或开头,后面是 / 或末尾
                if (isPathSegmentMatch(path, seg)) return true;
            }
        }
    }
    return false;
}

fn isPathSegmentMatch(path: []const u8, seg: []const u8) bool {
    var i: usize = 0;
    while (i + seg.len <= path.len) : (i += 1) {
        if (!std.mem.startsWith(u8, path[i..], seg)) continue;
        const before_ok = (i == 0) or path[i - 1] == '/';
        const after_idx = i + seg.len;
        const after_ok = (after_idx == path.len) or path[after_idx] == '/';
        if (before_ok and after_ok) return true;
    }
    return false;
}

// ============================================================================
// 评估
// ============================================================================

pub const Decision = enum { allow, ask, deny, undecided };

/// 评估一个工具调用:在 settings 多层里按 deny→allow→ask 顺序找命中。
pub fn evaluate(
    s: *const MergedSettings,
    mctx: *const rule_spec.MatchContext,
    tool_name: []const u8,
    args: []const u8,
) Decision {
    // 先扫所有层的 deny(deny 优先)— symlink 任一路径匹配即触发
    for (s.layers) |L| {
        for (L.deny) |r| {
            if (rule_spec.matchesMode(&r.spec, mctx, tool_name, args, .deny)) return .deny;
        }
    }
    // 再扫所有层的 allow — symlink 要求原路径 + target 双匹配
    for (s.layers) |L| {
        for (L.allow) |r| {
            if (rule_spec.matchesMode(&r.spec, mctx, tool_name, args, .allow)) return .allow;
        }
    }
    // 最后 ask
    for (s.layers) |L| {
        for (L.ask) |r| {
            if (rule_spec.matchesMode(&r.spec, mctx, tool_name, args, .ask)) return .ask;
        }
    }
    return .undecided;
}

// ============================================================================
// Layer 解析(从 std.json.Value 转 Layer)
// ============================================================================

pub fn parseLayer(
    alloc: std.mem.Allocator,
    source: Source,
    root: std.json.Value,
) !Layer {
    if (root != .object) return Layer{
        .source = source,
        .allow = &.{},
        .ask = &.{},
        .deny = &.{},
    };

    var allow_l: std.ArrayList(Rule) = .empty;
    errdefer allow_l.deinit(alloc);
    var ask_l: std.ArrayList(Rule) = .empty;
    errdefer ask_l.deinit(alloc);
    var deny_l: std.ArrayList(Rule) = .empty;
    errdefer deny_l.deinit(alloc);
    var dirs_l: std.ArrayList([]const u8) = .empty;
    errdefer dirs_l.deinit(alloc);

    var disable_bypass = false;
    var disable_auto = false;

    if (root.object.get("permissions")) |p| {
        if (p == .object) {
            try collectArray(alloc, p.object.get("allow"), source, &allow_l);
            try collectArray(alloc, p.object.get("ask"), source, &ask_l);
            try collectArray(alloc, p.object.get("deny"), source, &deny_l);

            if (p.object.get("additionalDirectories")) |ad| {
                if (ad == .array) {
                    for (ad.array.items) |item| {
                        if (item == .string) {
                            try dirs_l.append(alloc, try alloc.dupe(u8, item.string));
                        }
                    }
                }
            }

            if (p.object.get("disableBypassPermissionsMode")) |v| {
                if (v == .bool) disable_bypass = v.bool;
            }
            if (p.object.get("disableAutoMode")) |v| {
                if (v == .bool) disable_auto = v.bool;
            }
        }
    }

    return Layer{
        .source = source,
        .allow = try allow_l.toOwnedSlice(alloc),
        .ask = try ask_l.toOwnedSlice(alloc),
        .deny = try deny_l.toOwnedSlice(alloc),
        .additional_directories = try dirs_l.toOwnedSlice(alloc),
        .disable_bypass_permissions_mode = disable_bypass,
        .disable_auto_mode = disable_auto,
    };
}

fn collectArray(
    alloc: std.mem.Allocator,
    maybe_v: ?std.json.Value,
    source: Source,
    out: *std.ArrayList(Rule),
) !void {
    const v = maybe_v orelse return;
    if (v != .array) return;
    for (v.array.items) |item| {
        if (item != .string) continue;
        const raw = try alloc.dupe(u8, item.string);
        const spec = rule_spec.parseRule(raw) catch continue; // 解析失败跳过
        try out.append(alloc, .{ .raw = raw, .spec = spec, .source = source });
    }
}

/// 从逗号分隔的 CLI 字符串构建一个 Layer。
/// allow_csv/ask_csv/deny_csv/dirs_csv 任一为 null/空就跳过。
/// 用于 --allowedTools / --disallowedTools / --add-dir。
pub fn buildInlineLayer(
    alloc: std.mem.Allocator,
    source: Source,
    allow_csv: ?[]const u8,
    ask_csv: ?[]const u8,
    deny_csv: ?[]const u8,
    dirs_nul: ?[]const u8,
) !Layer {
    var allow_l: std.ArrayList(Rule) = .empty;
    errdefer allow_l.deinit(alloc);
    var ask_l: std.ArrayList(Rule) = .empty;
    errdefer ask_l.deinit(alloc);
    var deny_l: std.ArrayList(Rule) = .empty;
    errdefer deny_l.deinit(alloc);
    var dirs_l: std.ArrayList([]const u8) = .empty;
    errdefer dirs_l.deinit(alloc);

    try collectCsv(alloc, allow_csv, ',', source, &allow_l);
    try collectCsv(alloc, ask_csv, ',', source, &ask_l);
    try collectCsv(alloc, deny_csv, ',', source, &deny_l);

    if (dirs_nul) |d| {
        var it = std.mem.splitScalar(u8, d, 0);
        while (it.next()) |seg| {
            const t = std.mem.trim(u8, seg, " \t");
            if (t.len == 0) continue;
            try dirs_l.append(alloc, try alloc.dupe(u8, t));
        }
    }

    return Layer{
        .source = source,
        .allow = try allow_l.toOwnedSlice(alloc),
        .ask = try ask_l.toOwnedSlice(alloc),
        .deny = try deny_l.toOwnedSlice(alloc),
        .additional_directories = try dirs_l.toOwnedSlice(alloc),
    };
}

fn collectCsv(
    alloc: std.mem.Allocator,
    csv: ?[]const u8,
    sep: u8,
    source: Source,
    out: *std.ArrayList(Rule),
) !void {
    const s = csv orelse return;
    var it = std.mem.splitScalar(u8, s, sep);
    while (it.next()) |seg| {
        const t = std.mem.trim(u8, seg, " \t");
        if (t.len == 0) continue;
        const raw = try alloc.dupe(u8, t);
        const spec = rule_spec.parseRule(raw) catch {
            alloc.free(raw);
            continue;
        };
        try out.append(alloc, .{ .raw = raw, .spec = spec, .source = source });
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "isProtectedPath: env / git / ssh" {
    try testing.expect(isProtectedPath("/home/u/.bashrc"));
    try testing.expect(isProtectedPath(".bashrc"));
    try testing.expect(isProtectedPath("/proj/.env"));
    try testing.expect(isProtectedPath("/proj/.env.local"));
    try testing.expect(isProtectedPath("/proj/.git/config"));
    try testing.expect(isProtectedPath("/proj/sub/.git/HEAD"));
    try testing.expect(isProtectedPath("/home/u/.ssh/id_rsa"));
    try testing.expect(!isProtectedPath("/proj/src/main.zig"));
    try testing.expect(!isProtectedPath("/proj/git-helper.sh")); // git- 不算 .git
}

test "parseLayer: permissions.allow/ask/deny arrays" {
    const src =
        \\{"permissions":{
        \\  "allow":["Bash(git status)", "Read(./**)"],
        \\  "ask":["Bash(npm *)"],
        \\  "deny":["Bash(rm *)", "Write(//*)"]
        \\}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    const L = try parseLayer(testing.allocator, .user, parsed.value);
    defer {
        for (L.allow) |r| testing.allocator.free(r.raw);
        for (L.ask) |r| testing.allocator.free(r.raw);
        for (L.deny) |r| testing.allocator.free(r.raw);
        testing.allocator.free(L.allow);
        testing.allocator.free(L.ask);
        testing.allocator.free(L.deny);
        testing.allocator.free(L.additional_directories);
    }
    try testing.expectEqual(@as(usize, 2), L.allow.len);
    try testing.expectEqual(@as(usize, 1), L.ask.len);
    try testing.expectEqual(@as(usize, 2), L.deny.len);
}

test "parseLayer: additionalDirectories + disable flags" {
    const src =
        \\{"permissions":{
        \\  "additionalDirectories":["/extra/a","/extra/b"],
        \\  "disableBypassPermissionsMode":true,
        \\  "disableAutoMode":true
        \\}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    const L = try parseLayer(testing.allocator, .managed, parsed.value);
    defer {
        for (L.additional_directories) |d| testing.allocator.free(d);
        testing.allocator.free(L.allow);
        testing.allocator.free(L.ask);
        testing.allocator.free(L.deny);
        testing.allocator.free(L.additional_directories);
    }
    try testing.expectEqual(@as(usize, 2), L.additional_directories.len);
    try testing.expectEqualStrings("/extra/a", L.additional_directories[0]);
    try testing.expect(L.disable_bypass_permissions_mode);
    try testing.expect(L.disable_auto_mode);
}

test "evaluate: deny precedence over allow" {
    const alloc = testing.allocator;
    const user_src =
        \\{"permissions":{"allow":["Bash(git *)"]}}
    ;
    const managed_src =
        \\{"permissions":{"deny":["Bash(git push)"]}}
    ;
    var p1 = try std.json.parseFromSlice(std.json.Value, alloc, user_src, .{});
    defer p1.deinit();
    var p2 = try std.json.parseFromSlice(std.json.Value, alloc, managed_src, .{});
    defer p2.deinit();

    const L_user = try parseLayer(alloc, .user, p1.value);
    const L_mgr = try parseLayer(alloc, .managed, p2.value);
    defer {
        for (L_user.allow) |r| alloc.free(r.raw);
        for (L_user.ask) |r| alloc.free(r.raw);
        for (L_user.deny) |r| alloc.free(r.raw);
        alloc.free(L_user.allow);
        alloc.free(L_user.ask);
        alloc.free(L_user.deny);
        alloc.free(L_user.additional_directories);
        for (L_mgr.allow) |r| alloc.free(r.raw);
        for (L_mgr.ask) |r| alloc.free(r.raw);
        for (L_mgr.deny) |r| alloc.free(r.raw);
        alloc.free(L_mgr.allow);
        alloc.free(L_mgr.ask);
        alloc.free(L_mgr.deny);
        alloc.free(L_mgr.additional_directories);
    }

    const layers = try alloc.alloc(Layer, 2);
    defer alloc.free(layers);
    layers[0] = L_mgr;
    layers[1] = L_user;
    const s = MergedSettings{ .layers = layers, .allocator = alloc };

    var mctx = rule_spec.MatchContext{};
    // git status:user allow → allow
    try testing.expectEqual(Decision.allow, evaluate(&s, &mctx, "Bash", "{\"command\":\"git status\"}"));
    // git push:managed deny 优先,即使 user allow Bash(git *) → deny
    try testing.expectEqual(Decision.deny, evaluate(&s, &mctx, "Bash", "{\"command\":\"git push\"}"));
    // git log:user allow → allow
    try testing.expectEqual(Decision.allow, evaluate(&s, &mctx, "Bash", "{\"command\":\"git log\"}"));
    // rm:无规则 → undecided
    try testing.expectEqual(Decision.undecided, evaluate(&s, &mctx, "Bash", "{\"command\":\"rm foo\"}"));
}
