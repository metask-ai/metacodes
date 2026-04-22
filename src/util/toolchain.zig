//! 外部工具链路径解析。
//!
//! 目前职责：找可用的 ripgrep 二进制（rg）。
//! 查找顺序：
//!   1. 环境变量 RG_BIN（用户手动指定）
//!   2. $PATH（PATH 第一个命中的 rg 真实路径——用 execlp 风格的 execvp 可以绕过，但我们
//!      用 access 探测）
//!   3. 几个常见路径的 fallback（vendored / apt / cargo / snap vscode）
//!
//! 未命中返回 error.RipgrepNotFound。

const std = @import("std");

const FALLBACK_PATHS = [_][:0]const u8{
    // vendored（将来）
    "./vendor/ripgrep/rg",
    // apt 系统包
    "/usr/bin/rg",
    "/usr/local/bin/rg",
    // homebrew
    "/opt/homebrew/bin/rg",
    // cargo
    "/root/.cargo/bin/rg",
    // vscode 内嵌
    "/usr/share/kiro/resources/app/node_modules/@vscode/ripgrep/bin/rg",
};

/// 返回一个可执行的 rg 路径。优先 RG_BIN，其次系统 PATH，其次 fallback。
/// 返回值生命周期：静态字符串（无需释放）。
pub fn ripgrepPath() error{RipgrepNotFound}![:0]const u8 {
    // 先看环境变量（直接 libc getenv 避免 Zig 0.17 std.process.environ_map 的不稳定 API）
    if (std.c.getenv("RG_BIN")) |env_c| {
        const env = std.mem.span(env_c);
        if (existsExecutable(env)) {
            return env;
        }
    }

    // fallback 列表
    for (FALLBACK_PATHS) |p| {
        if (existsExecutable(p)) return p;
    }

    return error.RipgrepNotFound;
}

fn existsExecutable(path: []const u8) bool {
    // access(path, X_OK)
    const X_OK: c_int = 1;
    if (path.len == 0) return false;
    // 需要 z-string；已知 FALLBACK_PATHS 是 [:0]；getenv 返回值也是 sentinel-terminated
    // 构造一个临时 null-terminated 缓冲以防万一
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const z: [*:0]u8 = @ptrCast(&buf);
    return std.c.access(z, X_OK) == 0;
}

test "ripgrepPath finds some rg or returns NotFound" {
    _ = ripgrepPath() catch |err| {
        try std.testing.expect(err == error.RipgrepNotFound);
        return;
    };
}
