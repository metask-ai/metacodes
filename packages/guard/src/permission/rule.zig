//! Rule DSL 占位。
//!
//! 规划中的用途：解析 `Bash(git status:*)` / `Read(/tmp/**)` 这样的规则 → 结构化匹配器 → 与
//! `permission/decision.zig` 协作实现完整决策树。
//!
//! TODO(sandbox)：留给沙箱阶段实现。本期保留接口与文件位置不做实现。

const std = @import("std");

pub const RuleKind = enum { allow, deny, ask };

/// 匹配器占位。沙箱版本会扩展为 exact(hash) / prefix(cmd) / glob(path) 等。
pub const Matcher = union(enum) {
    any: void,
};

pub const Rule = struct {
    kind: RuleKind,
    tool: []const u8,
    matcher: Matcher,
};

pub const RuleSet = struct {
    rules: []const Rule = &.{},

    /// 未实现：沙箱版本会在此实现规则匹配返回 ?Rule。
    pub fn check(self: *const RuleSet, tool_name: []const u8, args: []const u8) ?Rule {
        _ = self;
        _ = tool_name;
        _ = args;
        return null; // 本期未实现
    }
};

test "RuleSet.check returns null in stub" {
    const rs = RuleSet{};
    try std.testing.expect(rs.check("Read", "{}") == null);
}
