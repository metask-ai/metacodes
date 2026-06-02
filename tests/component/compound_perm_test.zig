//! L2 组件测试:Bash 复合命令(&&/||/;/|)的权限规则匹配(原零 L2)。
//!
//! 覆盖 rule_spec.matchesMode 对复合命令的拆分逻辑(splitCompound + 逐段 stripWrappers)。
//!
//! **重要行为(本测如实锁定 + 标注)**:matchesBashCompound 对所有 mode 都用
//! "每段都匹配才命中" 语义(allow 语义)。这意味着:
//!   - allow 规则 Bash(rm *):仅当**每段**都是 rm * 才放行(更严,正确)。
//!   - deny 规则 Bash(rm *):也要求**每段**都匹配才 deny → `ls && rm x` 因 ls 不匹配
//!     而**不被 deny**。即"安全前缀 + 危险后段"可绕过用户自定义 deny 规则。
//! 注:`rm -rf /` 这类硬危险命令另由 shell_lex.validate(DANGER_SUBSTRINGS,扫所有段)
//! 兜底,不依赖规则系统;但用户配置的 deny 规则有此 all-segments 盲点。
//! 与 matchesPathDual(deny/ask 用"任一匹配即命中")不对称——记录待评估。

const std = @import("std");
const cc = @import("cc");

const rs = cc.permission_rule_spec;

fn denyMatch(rule: []const u8, command: []const u8) !bool {
    const spec = try rs.parseRule(rule);
    const mctx = rs.MatchContext{ .cwd = "/x", .project_root = "/x", .home = "/h" };
    var abuf: [512]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"command\":\"{s}\"}}", .{command});
    return rs.matchesMode(&spec, &mctx, "Bash", args, .deny);
}

fn allowMatch(rule: []const u8, command: []const u8) !bool {
    const spec = try rs.parseRule(rule);
    const mctx = rs.MatchContext{ .cwd = "/x", .project_root = "/x", .home = "/h" };
    var abuf: [512]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"command\":\"{s}\"}}", .{command});
    return rs.matchesMode(&spec, &mctx, "Bash", args, .allow);
}

test "L2 复合命令: 单段 rm foo 命中 Bash(rm *)" {
    try std.testing.expect(try denyMatch("Bash(rm *)", "rm foo"));
}

test "L2 复合命令: 每段都 rm 时整体命中(allow 语义)" {
    try std.testing.expect(try denyMatch("Bash(rm *)", "rm a && rm b"));
    try std.testing.expect(try allowMatch("Bash(rm *)", "rm a; rm b"));
}

test "L2 复合命令: allow Bash(git *) 要求每段都 git(npm 段使整体不放行)" {
    try std.testing.expect(try allowMatch("Bash(git *)", "git add . && git commit -m x"));
    // 混入非 git 段 → allow 不命中(更严,正确)
    try std.testing.expect(!try allowMatch("Bash(git *)", "git add . && npm publish"));
}

test "L2 复合命令(已知盲点): deny Bash(rm *) 对 'ls && rm x' 不命中(安全前缀绕过)" {
    // 如实锁定当前行为:all-segments 语义 → ls 段不匹配 → 整体不 deny。
    // 这是 deny 规则的 all-segments 盲点(与 path deny 的 any-segment 不对称)。
    // 若将来改 deny 为 any-segment,此断言应翻转为 true 并删本注释。
    try std.testing.expect(!try denyMatch("Bash(rm *)", "ls && rm x"));
}

test "L2 复合命令: wrapper 剥离后再匹配(timeout/nohup)" {
    // stripWrappers 去掉 timeout/nohup 等前缀再比对 pattern。
    try std.testing.expect(try denyMatch("Bash(rm *)", "timeout 5 rm foo"));
    try std.testing.expect(try denyMatch("Bash(rm *)", "nohup rm foo"));
}
