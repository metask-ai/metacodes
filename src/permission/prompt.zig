//! 用户交互占位（prompt 模式的 y/n/A/q）。
//!
//! 现阶段保留最简实现：从 stdin 读一个字节，`y`/`Y` → 允许，其他拒绝。
//! 完整的 y/n/A(always)/q(quit) + TTY detection + 非 TTY 默认行为留给 M4 + 沙箱。
//!
//! TODO(sandbox): 加上 RuleSet 动态追加（A = 写入 ruleset）、非 tty 默认策略、历史记忆。

const std = @import("std");
const category = @import("category.zig");

/// 阻塞式询问用户。返回 true = 允许。
pub fn ask(tool_name: []const u8, args: []const u8) !bool {
    const risk = category.getRiskLevel(tool_name);
    const risk_str: []const u8 = switch (risk) {
        .low => "LOW",
        .medium => "MEDIUM",
        .high => "HIGH",
    };
    std.debug.print("\x1b[33m[Permission] {s} tool requires {s} risk action\x1b[0m\n", .{ tool_name, risk_str });
    std.debug.print("  Args: {s}\n", .{args});
    std.debug.print("Allow? [y/N]: ", .{});

    var buf: [10]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return false;
    if (n > 0 and (buf[0] == 'y' or buf[0] == 'Y')) return true;
    return false;
}
