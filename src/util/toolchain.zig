//! 外部工具链路径解析。
//!
//! 目前职责：找可用的 ripgrep 二进制（rg / rg.exe）。
//! 查找顺序：
//!   1. 环境变量 RG_BIN（用户手动指定）
//!   2. $PATH 逐目录探测（POSIX ':' / Windows ';' 分隔;文件名 rg / rg.exe）
//!   3. 几个常见路径的 fallback（vendored / apt / cargo / vscode / Windows 常见安装位）
//!
//! 未命中返回 error.RipgrepNotFound。结果缓存(进程内不变;并发 Grep 线程安全)。

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const pfs = @import("platform").fs;
const sync = @import("platform").sync;

const RG_NAME = if (is_windows) "rg.exe" else "rg";

const FALLBACK_PATHS = if (is_windows) [_][:0]const u8{
    ".\\vendor\\ripgrep\\rg.exe",
    "vendor\\ripgrep\\rg.exe",
    // scoop / choco / winget 常见位(用户目录展开在 PATH 搜索兜住,这里放系统级)
    "C:\\ProgramData\\chocolatey\\bin\\rg.exe",
} else [_][:0]const u8{
    "./vendor/ripgrep/rg",
    "/usr/bin/rg",
    "/usr/local/bin/rg",
    "/opt/homebrew/bin/rg",
    "/root/.cargo/bin/rg",
    "/usr/share/kiro/resources/app/node_modules/@vscode/ripgrep/bin/rg",
};

// 缓存:rg 路径进程内不变。PATH 搜索命中的路径存这里(静态生命周期)。
// **task#24 并发修**:cache_done atomic 只护"已缓存"读——首次 init 时多线程(并发后台 subagent
// 的 Glob)会同时进 resolve()→searchPath(),并发写**共享静态 path_buf** → 互相踩,返回的
// path_buf[0..need :0] sentinel 位是别的线程的字符 → sentinel mismatch 崩(test:new 后台 Glob 实证)。
// 修:init_mutex 双检锁串行首次 resolve;缓存后走无锁快路径(cache_done),path_buf 首次后不再写。
var cache_done = std.atomic.Value(bool).init(false);
var cached_path: [:0]const u8 = "";
var path_buf: [std.fs.max_path_bytes]u8 = undefined;
var init_mutex: sync.Mutex = .{};

/// 返回一个可执行的 rg 路径。优先 RG_BIN，其次 PATH，其次 fallback。返回值静态生命周期。
pub fn ripgrepPath() error{RipgrepNotFound}![:0]const u8 {
    if (cache_done.load(.acquire)) {
        if (cached_path.len == 0) return error.RipgrepNotFound;
        return cached_path;
    }
    // 首次 init:串行(双检)——否则并发 searchPath 踩共享 path_buf。
    _ = init_mutex.lock();
    defer _ = init_mutex.unlock();
    if (cache_done.load(.acquire)) {
        if (cached_path.len == 0) return error.RipgrepNotFound;
        return cached_path;
    }
    const result = resolve();
    cached_path = result orelse "";
    cache_done.store(true, .release);
    return result orelse error.RipgrepNotFound;
}

fn resolve() ?[:0]const u8 {
    // 1. RG_BIN
    if (std.c.getenv("RG_BIN")) |env_c| {
        if (pfs.exists(env_c)) return std.mem.span(env_c);
    }
    // 2. PATH 逐目录探测
    if (searchPath()) |p| return p;
    // 3. fallback
    for (FALLBACK_PATHS) |p| {
        if (pfs.exists(p.ptr)) return p;
    }
    return null;
}

/// PATH 逐目录拼 <dir><sep>rg[.exe],存在即返回(写进 path_buf,静态)。
fn searchPath() ?[:0]const u8 {
    const path_env = std.c.getenv("PATH") orelse return null;
    const path = std.mem.span(path_env);
    const list_sep: u8 = if (is_windows) ';' else ':';
    const dir_sep: u8 = if (is_windows) '\\' else '/';
    var it = std.mem.splitScalar(u8, path, list_sep);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const need = dir.len + 1 + RG_NAME.len;
        if (need + 1 > path_buf.len) continue;
        @memcpy(path_buf[0..dir.len], dir);
        path_buf[dir.len] = dir_sep;
        @memcpy(path_buf[dir.len + 1 ..][0..RG_NAME.len], RG_NAME);
        path_buf[need] = 0;
        if (pfs.exists(@ptrCast(&path_buf))) return path_buf[0..need :0];
    }
    return null;
}

test "ripgrepPath finds some rg or returns NotFound" {
    _ = ripgrepPath() catch |err| {
        try std.testing.expect(err == error.RipgrepNotFound);
        return;
    };
}
