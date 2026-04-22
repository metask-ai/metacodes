//! 权限模式（Mode）。
//!
//! 本期（M0-M4）支持 auto/prompt/plan/bypass 四模式——与旧 `types.PermissionMode` 相同。
//! 新计划后续会扩展到 accept_edits / dont_ask 等，并在沙箱版本中重构决策树。

const std = @import("std");
const types = @import("../types.zig");

/// Mode 直接复用 types.PermissionMode，保持单一事实源。
pub const Mode = types.PermissionMode;

/// 解析 CLI 参数中的 mode 字符串。未知值退化为 `.prompt`。
pub fn parse(s: []const u8) Mode {
    if (std.mem.eql(u8, s, "auto")) return .auto;
    if (std.mem.eql(u8, s, "prompt")) return .prompt;
    if (std.mem.eql(u8, s, "plan")) return .plan;
    if (std.mem.eql(u8, s, "bypass")) return .bypass;
    return .prompt;
}

test "parse all modes" {
    try std.testing.expect(parse("auto") == .auto);
    try std.testing.expect(parse("prompt") == .prompt);
    try std.testing.expect(parse("plan") == .plan);
    try std.testing.expect(parse("bypass") == .bypass);
    try std.testing.expect(parse("unknown") == .prompt);
}
