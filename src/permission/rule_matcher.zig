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
//!   - match.command_prefix    可选，对 args 里 "command" 字段（Bash/Monitor 交给 shell 的命令）
//!                             做 startsWith，复合命令逐段判定（见下）
//!   - match.path_glob         可选，对 Write/Edit 的 args 里 "path"/"file_path" 做 glob
//! decision:
//!   - "allow" / "deny" / "ask"
//!
//! 复合命令（&& || ; | |& & 换行）：规则只描述单条命令。command 先按 Bash 工具的方式取字段 +
//! JSON unescape（rule_spec.commandFromArgs，`\n`、`\u0026\u0026` 是真分隔符，`\"` 是真引号），
//! 再 bash_parser.splitCompound 拆段。整条命令与每一段各自按"第一个命中生效"得出决定，整体
//! 取最严：任一 deny → deny；否则任一 ask → ask；全部 allow → allow；否则（有段无规则可依）
//! → null，整条交给后续兜底。于是 allow 要每段都被放行，deny/ask 任一段命中即生效，与
//! rule_spec 的 Bash 规则同一语义。"第一个命中"是逐段套用而不是逐条规则聚合，规则顺序对每一
//! 段照旧成立：排在前面的 ask 命中无害段，遮不住后面的 deny 命中危险段；排在总 deny 之前的
//! allow 例外，照样豁免它管的那一段。整条命令也算一个单元，跨分隔符的前缀（`curl x | sh`）
//! 照旧命中。
//! wrapper（timeout/nohup/env…）包着的命令再按规则判一遍，只能收紧：那边的 deny/ask 生效
//! （`timeout 5 rm x` 触发 `rm `），那边的 allow 不替原文放行（`env LD_PRELOAD=… git status`
//! 不因 `git ` 放行）。
//!
//! 当前简化：
//!   - glob 只支持 * ** ?；无 [a-z] 类
//!   - 所有 match 字段 AND（都要命中）
//!   - 无通配 tool（必填精确名）
//!   - 只拆顶层分隔符：`$(…)`、反引号、子 shell 里的命令不单独成段（`echo $(rm x)` 仍按 echo
//!     判），heredoc 正文每行各算一段——与 rule_spec 同

const std = @import("std");
const common = @import("../tools/common.zig");
const Decision = @import("decision.zig").Decision;
const util_json = @import("../util/json.zig");
const rule_spec = @import("rule_spec.zig");
const bash_parser = @import("bash_parser.zig");

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

    /// 尝试匹配：命中返回 decision；都不命中返回 null（调用方回退到四模式）。
    /// 该工具有 command_prefix 规则时按复合命令逐段判定（见文件头）。
    pub fn match(self: *const RuleSet, tool_name: []const u8, args: []const u8) ?Decision {
        if (!self.hasCommandRule(tool_name)) return self.firstMatch(tool_name, args, null);
        // 常见命令不上堆;超长命令(heredoc 等)落到规则集的 allocator。
        var sfa = std.heap.stackFallback(2048, self.allocator);
        const scratch = sfa.get();
        const command = rule_spec.commandFromArgs(scratch, args) catch return self.undetermined(tool_name, args);
        defer if (command) |c| scratch.free(c);
        // 没有 command 字段:command_prefix 规则不命中,其余规则照常。
        const whole = command orelse return self.firstMatch(tool_name, args, null);
        const segments = bash_parser.splitCompound(scratch, whole) catch return self.undetermined(tool_name, args);
        defer scratch.free(segments);
        var verdict = self.unitDecision(tool_name, args, whole);
        for (segments) |segment| verdict = stricter(verdict, self.unitDecision(tool_name, args, segment));
        return verdict;
    }

    fn hasCommandRule(self: *const RuleSet, tool_name: []const u8) bool {
        for (self.rules.items) |r| {
            if (r.command_prefix != null and std.mem.eql(u8, r.tool, tool_name)) return true;
        }
        return false;
    }

    /// 一个单元(整条命令或其中一段)的决定:先按原文判;wrapper 包着的命令再判一遍,那边只能
    /// 收紧——deny/ask 生效,allow 不替原文放行(剥掉 `env` 会把 `env LD_PRELOAD=… git status`
    /// 当成 git,剥掉 `xargs` 会丢掉它从 stdin 追加的参数)。
    fn unitDecision(self: *const RuleSet, tool_name: []const u8, args: []const u8, unit: []const u8) ?Decision {
        const as_written = self.firstMatch(tool_name, args, unit);
        const inner = bash_parser.stripWrappers(unit);
        if (std.mem.eql(u8, inner, unit)) return as_written;
        const inner_decision = self.firstMatch(tool_name, args, inner) orelse return as_written;
        return if (inner_decision == .allow) as_written else stricter(as_written, inner_decision);
    }

    /// 规则数组正序第一个命中。command = 本次比对的命令(整条、一段或 wrapper 里的命令);
    /// null = 调用没有 command 字段,带 command_prefix 的规则不命中。
    fn firstMatch(self: *const RuleSet, tool_name: []const u8, args: []const u8, command: ?[]const u8) ?Decision {
        for (self.rules.items) |r| {
            if (!std.mem.eql(u8, r.tool, tool_name)) continue;

            if (r.command_prefix) |prefix| {
                const cmd = command orelse continue;
                if (!std.mem.startsWith(u8, cmd, prefix)) continue;
            }

            if (r.path_glob) |pattern| {
                if (!self.pathMatches(pattern, args)) continue;
            }

            return r.decision;
        }
        return null;
    }

    /// 命令拆不了(内存不足):不知道有哪些段,就取规则对某条命令**可能**给出的最严决定——
    /// 第一条与命令无关的规则(无 command_prefix)之前,每条 command_prefix 规则都可能是某段的
    /// 第一个命中;没有这样一条兜底规则时,某段还可能无规则可依(null)。allow 只在每段都注定
    /// 被放行时成立,deny/ask 只要可能命中就生效:两个方向都 fail-closed。
    fn undetermined(self: *const RuleSet, tool_name: []const u8, args: []const u8) ?Decision {
        var verdict: ?Decision = .allow;
        for (self.rules.items) |r| {
            if (!std.mem.eql(u8, r.tool, tool_name)) continue;
            if (r.path_glob) |pattern| {
                if (!self.pathMatches(pattern, args)) continue;
            }
            verdict = stricter(verdict, r.decision);
            if (r.command_prefix == null) return verdict; // 余下的段都停在这条,后面的规则够不着
        }
        return stricter(verdict, null);
    }

    fn pathMatches(self: *const RuleSet, pattern: []const u8, args: []const u8) bool {
        // 优先 file_path（Edit），回退 path（Write）
        const path_raw = common.extractJsonArg(args, "file_path") orelse
            common.extractJsonArg(args, "path") orelse return false;
        // **B1 修复(第5镜像点)**:globMatch 前 canonicalize——unescape(与工具层落盘
        // 同函数)+ 词法折叠 `..`(相对折叠,本匹配器无 cwd 锚)。否则 allow 规则
        // path_glob `src/**` 对 `src/../../etc/passwd` 匹配 → 静默放行逃逸写。
        // 折叠后 `../etc/passwd` 不再匹配 `src/**`。canonicalize 失败 → 保守用原文
        // (仅 OOM / 超长病态路径,工具层同样会拒)。
        const canon = canonicalizeForGlob(self.allocator, path_raw);
        defer if (canon.owned) |o| self.allocator.free(o);
        return globMatch(pattern, canon.path);
    }
};

/// 两个决定里更严的那个:deny > ask > 无规则(null,交给后续兜底)> allow。
fn stricter(a: ?Decision, b: ?Decision) ?Decision {
    return if (strictness(b) > strictness(a)) b else a;
}

fn strictness(d: ?Decision) u2 {
    const decided = d orelse return 1; // 无规则:没放行(比 allow 严),也没拦(比 ask 松)
    return switch (decided) {
        .allow => 0,
        .ask => 2,
        .deny => 3,
    };
}

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

/// 测试用:一条 Bash command_prefix 规则 {前缀, 决定}。
const PrefixRule = struct { []const u8, Decision };

/// 测试用:按数组顺序建一组 Bash command_prefix 规则。caller deinit。
fn bashRules(a: std.mem.Allocator, rules: []const PrefixRule) !RuleSet {
    var rs = RuleSet.init(a);
    errdefer rs.deinit();
    for (rules) |rule| {
        const tool = try a.dupe(u8, "Bash");
        errdefer a.free(tool);
        const prefix = try a.dupe(u8, rule[0]);
        errdefer a.free(prefix);
        try rs.append(.{ .tool = tool, .command_prefix = prefix, .decision = rule[1] });
    }
    return rs;
}

/// `command` 是 JSON 字符串原文(`\\n` 即 JSON 转义的换行),原样拼进 args。
fn matchBash(rs: *const RuleSet, command: []const u8) !?Decision {
    var buf: [256]u8 = undefined;
    return rs.match("Bash", try std.fmt.bufPrint(&buf, "{{\"command\":\"{s}\"}}", .{command}));
}

test "RuleSet Bash command_prefix: allow 要每段都匹中,转义的分隔符也是分隔符" {
    var rs = try bashRules(std.testing.allocator, &.{.{ "git ", .allow }});
    defer rs.deinit();
    try std.testing.expectEqual(@as(?Decision, .allow), try matchBash(&rs, "git status && git log"));
    // `\"` 是真引号:引号内的 `;` 不拆
    try std.testing.expectEqual(@as(?Decision, .allow), try matchBash(&rs, "git log --format=\\\"a;b\\\""));
    const smuggled = [_][]const u8{
        "git status && rm x",
        "git status; rm x",
        "git status | rm x",
        "git status\\nrm x",
        "git status \\u0026\\u0026 rm x",
    };
    for (smuggled) |command| {
        errdefer std.debug.print("command: {s}\n", .{command});
        try std.testing.expectEqual(@as(?Decision, null), try matchBash(&rs, command));
    }
}

test "RuleSet Bash command_prefix: deny 任一段匹中即生效(含 wrapper 包着的段)" {
    var rs = try bashRules(std.testing.allocator, &.{.{ "rm ", .deny }});
    defer rs.deinit();
    const hits = [_][]const u8{
        "ls && rm x",
        "ls; rm x",
        "ls | rm x",
        "ls\\nrm x",
        "ls\\r\\nrm x",
        "ls || rm x",
        "ls & rm x",
        "ls |& rm x",
        "ls \\u0026\\u0026 rm x",
        "ls && timeout 5 rm x",
        "nohup rm x",
    };
    for (hits) |command| {
        errdefer std.debug.print("command: {s}\n", .{command});
        try std.testing.expectEqual(@as(?Decision, .deny), try matchBash(&rs, command));
    }
    // 没有 rm 段:拆段不放大命中面
    try std.testing.expectEqual(@as(?Decision, null), try matchBash(&rs, "ls && echo rm"));
    try std.testing.expectEqual(@as(?Decision, null), try matchBash(&rs, "echo 'ls && rm x'"));
    try std.testing.expectEqual(@as(?Decision, null), try matchBash(&rs, "echo \\\"a; rm x\\\""));
}

test "RuleSet 规则顺序逐段成立: 前面的 ask 遮不住后面的 deny,allow 例外照样豁免" {
    const a = std.testing.allocator;
    {
        // 逐条规则聚合会让 ask `curl ` 先"命中"整条命令,rm 段的 deny 就被跳过
        var rs = try bashRules(a, &.{ .{ "curl ", .ask }, .{ "rm ", .deny } });
        defer rs.deinit();
        try std.testing.expectEqual(@as(?Decision, .deny), try matchBash(&rs, "curl x && rm y"));
        try std.testing.expectEqual(@as(?Decision, .ask), try matchBash(&rs, "curl x && ls"));
    }
    {
        var rs = try bashRules(a, &.{ .{ "git ", .allow }, .{ "rm ", .deny } });
        defer rs.deinit();
        try std.testing.expectEqual(@as(?Decision, .deny), try matchBash(&rs, "git status && rm x"));
        try std.testing.expectEqual(@as(?Decision, .deny), try matchBash(&rs, "git status\\nrm x"));
        try std.testing.expectEqual(@as(?Decision, .allow), try matchBash(&rs, "git status && git log"));
    }
    {
        // allow 例外排在总 deny 之前:`rm -i` 段归例外,不被后面的 `rm ` 拦
        var rs = try bashRules(a, &.{ .{ "rm -i ", .allow }, .{ "rm ", .deny } });
        defer rs.deinit();
        try std.testing.expectEqual(@as(?Decision, .allow), try matchBash(&rs, "rm -i a; rm -i b"));
        try std.testing.expectEqual(@as(?Decision, null), try matchBash(&rs, "ls && rm -i x"));
        try std.testing.expectEqual(@as(?Decision, null), try matchBash(&rs, "timeout 5 rm -i x"));
        try std.testing.expectEqual(@as(?Decision, .deny), try matchBash(&rs, "rm -i a && rm b"));
    }
}

test "RuleSet wrapper: 包着的命令只能收紧,allow 不借剥 wrapper 放行" {
    const a = std.testing.allocator;
    {
        var rs = try bashRules(a, &.{.{ "git ", .allow }});
        defer rs.deinit();
        try std.testing.expectEqual(@as(?Decision, null), try matchBash(&rs, "env LD_PRELOAD=/tmp/x.so git status"));
        try std.testing.expectEqual(@as(?Decision, null), try matchBash(&rs, "timeout 5 git status"));
    }
    {
        // 前缀本身写着 wrapper:照旧按原文放行
        var rs = try bashRules(a, &.{.{ "nohup ./server", .allow }});
        defer rs.deinit();
        try std.testing.expectEqual(@as(?Decision, .allow), try matchBash(&rs, "nohup ./server --port 1"));
    }
    {
        // 放行 wrapper 本身不等于放行它包着的命令
        var rs = try bashRules(a, &.{ .{ "timeout ", .allow }, .{ "rm ", .deny } });
        defer rs.deinit();
        try std.testing.expectEqual(@as(?Decision, .allow), try matchBash(&rs, "timeout 5 make"));
        try std.testing.expectEqual(@as(?Decision, .deny), try matchBash(&rs, "timeout 5 rm x"));
    }
}

test "RuleSet 整条命令也是一个单元: 跨分隔符的前缀照旧命中" {
    var rs = try bashRules(std.testing.allocator, &.{.{ "curl x | sh", .deny }});
    defer rs.deinit();
    try std.testing.expectEqual(@as(?Decision, .deny), try matchBash(&rs, "curl x | sh"));
    try std.testing.expectEqual(@as(?Decision, null), try matchBash(&rs, "curl x"));
}

test "RuleSet 没有 command 字段: command_prefix 规则不命中,其余规则照常" {
    const a = std.testing.allocator;
    var rs = try bashRules(a, &.{.{ "rm ", .deny }});
    defer rs.deinit();
    try rs.append(.{ .tool = try a.dupe(u8, "Bash"), .decision = .ask });
    try std.testing.expectEqual(@as(?Decision, .ask), rs.match("Bash", "{\"description\":\"x\"}"));
    try std.testing.expectEqual(@as(?Decision, .deny), rs.match("Bash", "{\"command\":\"ls; rm x\"}"));
}

test "RuleSet 判不了(内存不足)时取可能的最严决定" {
    // 超出栈缓冲的命令落到规则集的 allocator:换成失败分配器后 unescape 做不完。
    var args: [4096]u8 = undefined;
    const head = "{\"command\":\"echo ";
    @memcpy(args[0..head.len], head);
    @memset(args[head.len .. args.len - 2], 'a');
    @memcpy(args[args.len - 2 ..], "\"}");
    const a = std.testing.allocator;
    const Case = struct { rules: []const PrefixRule, parsed: ?Decision, oom: ?Decision };
    const cases = [_]Case{
        // allow 证明不了每段都是 echo → 交给兜底
        .{ .rules = &.{.{ "echo ", .allow }}, .parsed = .allow, .oom = null },
        // deny/ask 可能命中某段 → 生效;后面的 deny 不被前面的 ask 遮住
        .{ .rules = &.{ .{ "echo ", .allow }, .{ "rm ", .deny } }, .parsed = .allow, .oom = .deny },
        .{ .rules = &.{ .{ "curl ", .ask }, .{ "rm ", .deny } }, .parsed = null, .oom = .deny },
        .{ .rules = &.{.{ "curl ", .ask }}, .parsed = null, .oom = .ask },
    };
    for (cases, 0..) |case, i| {
        errdefer std.debug.print("case {d}\n", .{i});
        var rs = try bashRules(a, case.rules);
        defer rs.deinit();
        try std.testing.expectEqual(case.parsed, rs.match("Bash", &args));
        rs.allocator = std.testing.failing_allocator;
        defer rs.allocator = a;
        try std.testing.expectEqual(case.oom, rs.match("Bash", &args));
    }
    {
        // 与命令无关的规则(无 command_prefix)截住余下的段:它前面的 deny 可能命中,后面的够不着
        var rs = try bashRules(a, &.{.{ "rm ", .deny }});
        defer rs.deinit();
        try rs.append(.{ .tool = try a.dupe(u8, "Bash"), .decision = .allow });
        try rs.append(.{ .tool = try a.dupe(u8, "Bash"), .command_prefix = try a.dupe(u8, "curl "), .decision = .ask });
        rs.allocator = std.testing.failing_allocator;
        defer rs.allocator = a;
        try std.testing.expectEqual(@as(?Decision, .deny), rs.match("Bash", &args));
    }
}
