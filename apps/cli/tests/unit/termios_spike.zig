//! M4.1 spike：验证 Zig 0.17-dev std.c 的 termios API 可以安全切换 raw mode
//! 并解析 CSI 转义序列（↑↓←→/Home/End/Del）。
//!
//! 关键决策：
//! - `std.c.tcgetattr(fd, *termios)` / `tcsetattr(fd, TCSA, *const termios)` 存在
//! - Linux 下 `termios.lflag` / `iflag` 是 packed struct，直接字段赋值
//! - cc 数组的索引名（VMIN/VTIME）从 std.c.V 获取
//!
//! CSI 序列（终端转义）：
//!   ESC [ A  → 上  (0x1b 0x5b 0x41)
//!   ESC [ B  → 下
//!   ESC [ C  → 右
//!   ESC [ D  → 左
//!   ESC [ H  → Home
//!   ESC [ F  → End
//!   ESC [ 3 ~ → Delete
//!
//! 本 spike 不跑真 tty——只用 byte stream parser 验证逻辑。

const std = @import("std");

pub const Key = union(enum) {
    char: u8, // 普通字符（ASCII/UTF-8 首字节）
    enter,
    backspace,
    ctrl_a,
    ctrl_e,
    ctrl_u,
    ctrl_k,
    ctrl_c,
    ctrl_d,
    up,
    down,
    left,
    right,
    home,
    end,
    delete,
    esc,
    unknown,
};

/// 状态机式 CSI 解析。喂字节，返回 ?Key。未成键时消耗输入返 null（等待更多字节）。
pub const KeyParser = struct {
    state: State = .normal,

    const State = enum {
        normal,
        esc_seen, // 收到 0x1b
        csi_seen, // 收到 0x1b 0x5b
        csi_digit, // 收到 0x1b 0x5b <digit>
    };

    pub fn feed(self: *KeyParser, b: u8) ?Key {
        switch (self.state) {
            .normal => {
                if (b == 0x1b) {
                    self.state = .esc_seen;
                    return null;
                }
                return byteToKey(b);
            },
            .esc_seen => {
                if (b == '[') {
                    self.state = .csi_seen;
                    return null;
                }
                self.state = .normal;
                return .esc;
            },
            .csi_seen => {
                self.state = .normal;
                switch (b) {
                    'A' => return .up,
                    'B' => return .down,
                    'C' => return .right,
                    'D' => return .left,
                    'H' => return .home,
                    'F' => return .end,
                    '3' => {
                        self.state = .csi_digit;
                        return null;
                    },
                    else => return .unknown,
                }
            },
            .csi_digit => {
                self.state = .normal;
                if (b == '~') return .delete;
                return .unknown;
            },
        }
    }
};

fn byteToKey(b: u8) Key {
    return switch (b) {
        '\r', '\n' => .enter,
        0x7f, 0x08 => .backspace,
        0x01 => .ctrl_a,
        0x03 => .ctrl_c,
        0x04 => .ctrl_d,
        0x05 => .ctrl_e,
        0x0b => .ctrl_k,
        0x15 => .ctrl_u,
        else => if (b >= 0x20 and b < 0x7f) Key{ .char = b } else .unknown,
    };
}

/// 尝试切到 raw mode（单字节读、无回显）。返回旧 termios 以便恢复。
/// 非 tty 或出错返 null——调用方应退化到行缓冲模式。
pub fn enterRawMode(fd: std.c.fd_t) ?std.c.termios {
    var orig: std.c.termios = undefined;
    if (std.c.tcgetattr(fd, &orig) != 0) return null;

    var raw = orig;
    // lflag 是 packed struct：字段式赋值
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false; // 禁 Ctrl+C 默认信号处理（我们自己处理）
    raw.lflag.IEXTEN = false;
    // iflag
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    // VMIN=1, VTIME=0：每次至少读 1 字节，无超时
    raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.c.V.TIME)] = 0;

    if (std.c.tcsetattr(fd, std.posix.TCSA.FLUSH, &raw) != 0) return null;
    return orig;
}

pub fn restoreMode(fd: std.c.fd_t, orig: std.c.termios) void {
    _ = std.c.tcsetattr(fd, std.posix.TCSA.FLUSH, &orig);
}

// --------------------------------------------------------------------------
// Tests（用 byte stream 驱动，不依赖真 tty）
// --------------------------------------------------------------------------

test "KeyParser: ASCII char" {
    var p = KeyParser{};
    try std.testing.expect(p.feed('a').? == .char);
}

test "KeyParser: enter" {
    var p = KeyParser{};
    try std.testing.expect(p.feed('\n').? == .enter);
    try std.testing.expect(p.feed('\r').? == .enter);
}

test "KeyParser: backspace" {
    var p = KeyParser{};
    try std.testing.expect(p.feed(0x7f).? == .backspace);
    try std.testing.expect(p.feed(0x08).? == .backspace);
}

test "KeyParser: Ctrl+C" {
    var p = KeyParser{};
    try std.testing.expect(p.feed(0x03).? == .ctrl_c);
}

test "KeyParser: arrow keys (full CSI sequence)" {
    var p = KeyParser{};
    // ESC [ A → up：前两字节应返 null
    try std.testing.expect(p.feed(0x1b) == null);
    try std.testing.expect(p.feed('[') == null);
    try std.testing.expect(p.feed('A').? == .up);
}

test "KeyParser: all four arrows" {
    inline for ([_]struct { b: u8, expected_tag: std.meta.Tag(Key) }{
        .{ .b = 'A', .expected_tag = .up },
        .{ .b = 'B', .expected_tag = .down },
        .{ .b = 'C', .expected_tag = .right },
        .{ .b = 'D', .expected_tag = .left },
    }) |t| {
        var p = KeyParser{};
        _ = p.feed(0x1b);
        _ = p.feed('[');
        const got = p.feed(t.b).?;
        try std.testing.expect(@as(std.meta.Tag(Key), got) == t.expected_tag);
    }
}

test "KeyParser: Home / End" {
    var p = KeyParser{};
    _ = p.feed(0x1b);
    _ = p.feed('[');
    try std.testing.expect(p.feed('H').? == .home);
    _ = p.feed(0x1b);
    _ = p.feed('[');
    try std.testing.expect(p.feed('F').? == .end);
}

test "KeyParser: Delete (ESC [ 3 ~)" {
    var p = KeyParser{};
    try std.testing.expect(p.feed(0x1b) == null);
    try std.testing.expect(p.feed('[') == null);
    try std.testing.expect(p.feed('3') == null);
    try std.testing.expect(p.feed('~').? == .delete);
}

test "KeyParser: bare ESC (no CSI follow-up)" {
    var p = KeyParser{};
    _ = p.feed(0x1b);
    // ESC 后跟普通字符 'a'：应先返 .esc，然后 'a' 进入 normal state
    try std.testing.expect(p.feed('a').? == .esc);
    // 此时状态已经回 normal，下一次 feed 直接出 .char
    try std.testing.expect(p.feed('b').? == .char);
}

test "KeyParser: unknown CSI swallowed" {
    var p = KeyParser{};
    _ = p.feed(0x1b);
    _ = p.feed('[');
    try std.testing.expect(p.feed('Z').? == .unknown);
    // 状态回 normal
    try std.testing.expect(p.feed('x').? == .char);
}

test "KeyParser: mixed stream multi keys" {
    var p = KeyParser{};
    // "a\nESC[B"
    const stream = [_]u8{ 'a', '\n', 0x1b, '[', 'B' };
    var keys = std.ArrayList(Key).empty;
    defer keys.deinit(std.testing.allocator);
    for (stream) |b| {
        if (p.feed(b)) |k| try keys.append(std.testing.allocator, k);
    }
    try std.testing.expect(keys.items.len == 3);
    try std.testing.expect(@as(std.meta.Tag(Key), keys.items[0]) == .char);
    try std.testing.expect(@as(std.meta.Tag(Key), keys.items[1]) == .enter);
    try std.testing.expect(@as(std.meta.Tag(Key), keys.items[2]) == .down);
}

test "enterRawMode on non-tty returns null" {
    // stdin 在 test 环境通常不是 tty（或是 pty 看运行方式）。
    // 不管是不是 tty，不应 panic；如果是 tty 成功则立刻恢复。
    const fd: std.c.fd_t = 0; // STDIN
    const orig = enterRawMode(fd);
    if (orig) |o| restoreMode(fd, o);
}
