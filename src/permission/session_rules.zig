//! Session 级权限记忆:always-allow / session-deny 的工具名集合。
//!
//! 重构前是 permission/prompt.zig 里的进程全局 var(g_always_allow/g_session_deny/g_buf),
//! 注释写"session 级"但实现是进程全局——多 Session 下会串台(A 的 always-allow 影响 B)。
//! 本类型把它收成**每 session 一个实例**,挂在 PermissionContext 上(经指针,故 *const ctx
//! 仍可 remember)。不持久化(完整 settings.local.json 持久化由 App 层做)。
//!
//! 固定上限 + 内联存储(无堆分配):工具名拷进固定 buf,值语义,无外部生命周期依赖。
//!
//! **线程契约**:M6 前假设**单线程访问**(rememberAllow/Deny 改 buf_used 非原子)。
//! M6 多 Session 多线程化时,要么给本类型加 mutex(仿 ReadState),要么保证每 session 的
//! ask 串行。当前 TUI(N=1)单线程,安全。

const std = @import("std");

pub const MAX_REMEMBERED = 64;
const MAX_NAME = 64;

pub const SessionRules = struct {
    always_allow: [MAX_REMEMBERED][]const u8 = undefined,
    always_allow_count: usize = 0,
    session_deny: [MAX_REMEMBERED][]const u8 = undefined,
    session_deny_count: usize = 0,
    buf: [MAX_REMEMBERED * 2][MAX_NAME]u8 = undefined,
    buf_used: usize = 0,

    fn remember(self: *SessionRules, list: *[MAX_REMEMBERED][]const u8, count: *usize, name: []const u8) void {
        if (count.* >= MAX_REMEMBERED) return;
        if (self.buf_used >= self.buf.len or name.len > MAX_NAME) return;
        const slot = &self.buf[self.buf_used];
        self.buf_used += 1;
        @memcpy(slot[0..name.len], name);
        list[count.*] = slot[0..name.len];
        count.* += 1;
    }

    pub fn rememberAllow(self: *SessionRules, name: []const u8) void {
        self.remember(&self.always_allow, &self.always_allow_count, name);
    }

    pub fn rememberDeny(self: *SessionRules, name: []const u8) void {
        self.remember(&self.session_deny, &self.session_deny_count, name);
    }

    pub fn isAllowed(self: *const SessionRules, name: []const u8) bool {
        return contains(self.always_allow[0..self.always_allow_count], name);
    }

    pub fn isDenied(self: *const SessionRules, name: []const u8) bool {
        return contains(self.session_deny[0..self.session_deny_count], name);
    }
};

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

// ============================================================================
// Tests
// ============================================================================
const testing = std.testing;

test "rememberAllow/isAllowed + 与 deny 隔离" {
    var r = SessionRules{};
    try testing.expect(!r.isAllowed("Bash"));
    r.rememberAllow("Bash");
    try testing.expect(r.isAllowed("Bash"));
    try testing.expect(!r.isAllowed("Write"));
    try testing.expect(!r.isDenied("Bash"));
    r.rememberDeny("Write");
    try testing.expect(r.isDenied("Write"));
    try testing.expect(!r.isAllowed("Write"));
}

test "remember 上限/超长名安全(不越界)" {
    var r = SessionRules{};
    // 超长名拒绝
    const long = "x" ** (MAX_NAME + 1);
    r.rememberAllow(long);
    try testing.expect(!r.isAllowed(long));
    // 填满上限不崩
    var i: usize = 0;
    while (i < MAX_REMEMBERED + 5) : (i += 1) {
        var nb: [8]u8 = undefined;
        const nm = std.fmt.bufPrint(&nb, "t{d}", .{i}) catch unreachable;
        r.rememberAllow(nm);
    }
    try testing.expect(r.always_allow_count <= MAX_REMEMBERED);
}
