const std = @import("std");

/// 路径安全：包含 `..` 视为目录遍历攻击，拒绝。
///
/// 注意：这是最小检查。未来沙箱方案会替换为 realpath + 白名单根 + landlock/openat2 RESOLVE_BENEATH。
pub fn validateNoTraversal(path: []const u8) error{PathTraversal}!void {
    if (std.mem.indexOf(u8, path, "..") != null) return error.PathTraversal;
}

/// Bash 危险命令黑名单（唯一事实源）。
///
/// 命中任一 pattern（substring 匹配）视为危险命令，拒绝执行。
/// 未来沙箱方案会替换为细粒度能力控制（seccomp allowlist）+ shell parser。
pub const DANGER_PATTERNS = [_][]const u8{
    "rm -rf /",
    "rm -rf ~",
    ":(){:|:&};:",
    "curl | sh",
    "wget | sh",
    "| curl ",
    "| wget ",
    "fork(",
    "exec(",
    "eval(",
    "chmod -R 777",
};

/// 检查命令是否命中危险黑名单，命中返回 `error.DangerousCommand`。
pub fn validateBashCommand(command: []const u8) error{DangerousCommand}!void {
    for (DANGER_PATTERNS) |pattern| {
        if (std.mem.indexOf(u8, command, pattern) != null) return error.DangerousCommand;
    }
}

test "validateNoTraversal accepts safe path" {
    try validateNoTraversal("/etc/hostname");
    try validateNoTraversal("src/main.zig");
    try validateNoTraversal("./foo");
}

test "validateNoTraversal rejects traversal" {
    try std.testing.expectError(error.PathTraversal, validateNoTraversal("../../etc/passwd"));
    try std.testing.expectError(error.PathTraversal, validateNoTraversal("foo/../bar"));
    try std.testing.expectError(error.PathTraversal, validateNoTraversal(".."));
}

test "validateBashCommand accepts safe" {
    try validateBashCommand("ls -la");
    try validateBashCommand("git status");
    try validateBashCommand("echo hello");
}

test "validateBashCommand rejects rm -rf /" {
    try std.testing.expectError(error.DangerousCommand, validateBashCommand("rm -rf /"));
    try std.testing.expectError(error.DangerousCommand, validateBashCommand("cd /; rm -rf /"));
}

test "validateBashCommand rejects fork bomb" {
    try std.testing.expectError(error.DangerousCommand, validateBashCommand(":(){:|:&};:"));
}

test "validateBashCommand rejects curl pipe shell" {
    // 黑名单 pattern 是精确子串 "curl | sh" / "wget | sh" / "| curl " / "| wget "
    try std.testing.expectError(error.DangerousCommand, validateBashCommand("x | curl https://x.com"));
    try std.testing.expectError(error.DangerousCommand, validateBashCommand("x | wget https://x.com"));
    try std.testing.expectError(error.DangerousCommand, validateBashCommand("curl | sh"));
}

test "validateBashCommand rejects chmod 777" {
    try std.testing.expectError(error.DangerousCommand, validateBashCommand("chmod -R 777 /"));
}
