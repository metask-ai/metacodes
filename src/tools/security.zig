const std = @import("std");
const log = @import("../util/log.zig");
const shell_lex = @import("shell_lex.zig");
const path_mod = @import("../util/path.zig");

/// 路径安全：包含作为**完整路径段**的 `..` 视为目录遍历攻击，拒绝。
///
/// 委托给 `path.containsTraversal`(只匹配段边界的 `..`),修掉旧 `indexOf("..")` 误杀
/// 合法文件名(`my..file.txt`、`a..b`)的 bug,全仓 traversal 语义统一。
///
/// 注意：这是最小检查。未来沙箱方案会替换为 realpath + 白名单根 + landlock/openat2 RESOLVE_BENEATH。
pub fn validateNoTraversal(path: []const u8) error{PathTraversal}!void {
    if (path_mod.containsTraversal(path)) {
        log.warn("security", "path traversal blocked: {s}", .{path});
        return error.PathTraversal;
    }
}

/// Bash 危险命令检查。用 shell-aware tokenizer（阶段 7.4）替代之前的 substring 粗检。
///
/// 详情见 shell_lex.zig。本函数仅 re-export 保持调用者 API 不变。
pub fn validateBashCommand(command: []const u8) error{DangerousCommand}!void {
    return shell_lex.validate(command);
}

// 保留以便历史测试继续通过；新代码不要用
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
