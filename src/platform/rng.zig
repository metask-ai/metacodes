//! W5 可移植加密强随机字节（跨平台移植 roadmap，tinykg node 8870）。
//!
//! 现状病灶：4 处直接 `open("/dev/urandom")` 读熵（job id / auth token / cron id）。Windows 无
//! `/dev/urandom`。0.16 stud 已移除 `std.posix.getrandom` / `std.crypto.random`（Io/trim 重构）。
//!
//! 方案：POSIX 保留 `/dev/urandom`（Linux/macOS/BSD 通用，零行为变化）；Windows 用
//! `RtlGenRandom`（advapi32 的 `SystemFunction036`，Win XP+ 的经典熵源，免依赖 BCrypt/CNG）。

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const win = std.os.windows;

// RtlGenRandom：BOOLEAN SystemFunction036(PVOID buf, ULONG len)。std 未绑定，自 extern。
extern "advapi32" fn SystemFunction036(RandomBuffer: [*]u8, RandomBufferLength: win.ULONG) win.BOOLEAN;

/// 用加密强随机字节填满 `buf`。返回 `true`=成功；`false`=熵源不可用（调用方决定报错/兜底）。
pub fn randomBytes(buf: []u8) bool {
    if (is_windows) {
        if (buf.len == 0) return true;
        return SystemFunction036(buf.ptr, @intCast(buf.len)) != 0;
    }
    const fd = std.c.open("/dev/urandom", std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.c.read(fd, buf.ptr + off, buf.len - off);
        if (n <= 0) return false; // EOF/错误：熵源异常
        off += @intCast(n);
    }
    return true;
}

test "randomBytes 填满且非全零" {
    var buf: [32]u8 = @splat(0);
    try std.testing.expect(randomBytes(&buf));
    // 32 字节全零的概率是 2^-256，可安全断言至少一个非零。
    var any: u8 = 0;
    for (buf) |b| any |= b;
    try std.testing.expect(any != 0);
}

test "randomBytes 两次不同(极高概率)" {
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    try std.testing.expect(randomBytes(&a));
    try std.testing.expect(randomBytes(&b));
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}
