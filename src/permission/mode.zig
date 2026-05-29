//! 权限模式(Mode):对齐 Claude Code 6 模式 + cc-zig 历史别名。
//!
//! 6 个官方模式见 doc/PERMISSION_DESIGN.md 第三节。
//! 解析支持驼峰(acceptEdits)和下划线(accept_edits)两种写法。

const std = @import("std");
const types = @import("../types.zig");

pub const Mode = types.PermissionMode;

/// 解析 CLI 参数中的 mode 字符串。未知值退化为 .default。
/// 接受:default/acceptEdits/plan/auto/dontAsk/bypassPermissions(官方驼峰)
///   + accept_edits/dont_ask/bypass_permissions(下划线变体)
///   + prompt/bypass(历史 cc-zig 名)
pub fn parse(s: []const u8) Mode {
    // 官方驼峰
    if (std.mem.eql(u8, s, "default")) return .default;
    if (std.mem.eql(u8, s, "acceptEdits")) return .accept_edits;
    if (std.mem.eql(u8, s, "plan")) return .plan;
    if (std.mem.eql(u8, s, "auto")) return .auto;
    if (std.mem.eql(u8, s, "dontAsk")) return .dont_ask;
    if (std.mem.eql(u8, s, "bypassPermissions")) return .bypass_permissions;
    // 下划线变体
    if (std.mem.eql(u8, s, "accept_edits")) return .accept_edits;
    if (std.mem.eql(u8, s, "dont_ask")) return .dont_ask;
    if (std.mem.eql(u8, s, "bypass_permissions")) return .bypass_permissions;
    // 历史别名
    if (std.mem.eql(u8, s, "prompt")) return .default;
    if (std.mem.eql(u8, s, "bypass")) return .bypass_permissions;
    return .default;
}

/// 把 Mode 标准化:把 prompt/bypass 历史别名映到 default/bypass_permissions。
pub fn canonical(m: Mode) Mode {
    return switch (m) {
        .prompt => .default,
        .bypass => .bypass_permissions,
        else => m,
    };
}

test "parse all official modes" {
    try std.testing.expect(parse("default") == .default);
    try std.testing.expect(parse("acceptEdits") == .accept_edits);
    try std.testing.expect(parse("plan") == .plan);
    try std.testing.expect(parse("auto") == .auto);
    try std.testing.expect(parse("dontAsk") == .dont_ask);
    try std.testing.expect(parse("bypassPermissions") == .bypass_permissions);
}

test "parse historic aliases" {
    try std.testing.expect(parse("prompt") == .default);
    try std.testing.expect(parse("bypass") == .bypass_permissions);
}

test "parse underscore variants" {
    try std.testing.expect(parse("accept_edits") == .accept_edits);
    try std.testing.expect(parse("dont_ask") == .dont_ask);
    try std.testing.expect(parse("bypass_permissions") == .bypass_permissions);
}

test "parse unknown → default" {
    try std.testing.expect(parse("garbage") == .default);
}

test "canonical maps aliases" {
    try std.testing.expect(canonical(.prompt) == .default);
    try std.testing.expect(canonical(.bypass) == .bypass_permissions);
    try std.testing.expect(canonical(.default) == .default);
    try std.testing.expect(canonical(.plan) == .plan);
}
