//! 终端背景色探测(OSC 11)→ 自动判明暗,供 theme variant=.auto 选 dark/light。
//!
//! 机制:进 raw 模式 → 写 `\x1b]11;?\x07`(查询背景色)→ 短超时读响应
//! `\x1b]11;rgb:RRRR/GGGG/BBBB\x07`(或 ST `\x1b\\` 结尾)→ 解析高字节 → BT.601 亮度判明暗。
//! 不支持/超时/非 tty → null,调用方沿用默认(dark)。
//!
//! 谨慎:① 只在交互 tty 启动期调一次;② 超时短(~120ms)不拖慢启动;③ 还原 termios;
//! ④ 管道/NO_PROBE/非 tty 由调用方跳过(本模块也自带非 tty 守卫)。
const std = @import("std");

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// BT.601 相对亮度 > 128 → 浅色背景(对齐 metacode color.zig is_light)。
pub fn isLight(c: Rgb) bool {
    const y = 0.299 * @as(f32, @floatFromInt(c.r)) +
        0.587 * @as(f32, @floatFromInt(c.g)) +
        0.114 * @as(f32, @floatFromInt(c.b));
    return y > 128.0;
}

/// 解析 OSC 11 响应里的 `rgb:RRRR/GGGG/BBBB`(各通道 1-4 hex,取高 8 位)。
/// 找不到/格式错 → null。容忍前后包裹(ESC]11; 前缀、BEL/ST 后缀)。
pub fn parseOsc11(resp: []const u8) ?Rgb {
    const marker = "rgb:";
    const idx = std.mem.indexOf(u8, resp, marker) orelse return null;
    var rest = resp[idx + marker.len ..];
    var ch: [3]u8 = undefined;
    var n: usize = 0;
    while (n < 3) : (n += 1) {
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        const seg = if (n < 2)
            (rest[0 .. slash orelse return null])
        else blk: {
            // 第三段:到非 hex 字符(BEL/ESC/\)或串尾。
            var e: usize = 0;
            while (e < rest.len and isHex(rest[e])) : (e += 1) {}
            break :blk rest[0..e];
        };
        if (seg.len == 0 or seg.len > 4) return null;
        const v16 = std.fmt.parseInt(u16, seg, 16) catch return null;
        // 通道值按 hex 位宽归一到 8 位:1位→<<4|x、2位→原、4位→取高字节。
        ch[n] = switch (seg.len) {
            1 => @intCast((v16 << 4) | v16),
            2 => @intCast(v16 & 0xFF),
            3 => @intCast(v16 >> 4),
            4 => @intCast(v16 >> 8),
            else => unreachable,
        };
        if (n < 2) rest = rest[(slash.?) + 1 ..];
    }
    return Rgb{ .r = ch[0], .g = ch[1], .b = ch[2] };
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// 探测终端背景色。非 tty / 不支持 / 超时 → null。会临时进 raw 再还原。
pub fn probeBackground(fd: std.c.fd_t) ?Rgb {
    if (std.c.isatty(fd) == 0) return null;

    var orig: std.c.termios = undefined;
    if (std.c.tcgetattr(fd, &orig) != 0) return null;
    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
    if (std.c.tcsetattr(fd, std.posix.TCSA.FLUSH, &raw) != 0) return null;
    defer _ = std.c.tcsetattr(fd, std.posix.TCSA.FLUSH, &orig);

    const query = "\x1b]11;?\x07";
    if (std.c.write(fd, query.ptr, query.len) < 0) return null;

    // poll 等响应,总超时 ~120ms,分多次(终端可能分片回)。
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    var waited_ms: i32 = 0;
    const timeout_ms: i32 = 120;
    while (waited_ms < timeout_ms and len < buf.len) {
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&pfd, 30) catch break;
        waited_ms += 30;
        if (ready == 0) {
            if (len > 0) break; // 已有数据且不再来 → 收尾
            continue;
        }
        const n = std.c.read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
        // 收到结束符(BEL 或 ST 的 \)即可停。
        if (std.mem.indexOfScalar(u8, buf[0..len], 0x07) != null) break;
        if (std.mem.indexOf(u8, buf[0..len], "\x1b\\") != null) break;
    }
    if (len == 0) return null;
    return parseOsc11(buf[0..len]);
}

// ============================================================================
// 测试
// ============================================================================
const testing = std.testing;

test "isLight: 黑→暗, 白→亮, 中灰边界" {
    try testing.expect(!isLight(.{ .r = 0, .g = 0, .b = 0 }));
    try testing.expect(isLight(.{ .r = 255, .g = 255, .b = 255 }));
    try testing.expect(!isLight(.{ .r = 30, .g = 30, .b = 30 })); // 典型暗终端
    try testing.expect(isLight(.{ .r = 240, .g = 240, .b = 240 })); // 典型亮终端
}

test "parseOsc11: 4-hex 各通道取高字节" {
    // 白:ffff/ffff/ffff → 255,255,255
    const w = parseOsc11("\x1b]11;rgb:ffff/ffff/ffff\x07").?;
    try testing.expectEqual(@as(u8, 255), w.r);
    try testing.expectEqual(@as(u8, 255), w.b);
    // 黑
    const b = parseOsc11("\x1b]11;rgb:0000/0000/0000\x1b\\").?;
    try testing.expectEqual(@as(u8, 0), b.r);
    // 典型暗背景 #1e1e1e → 1e1e/1e1e/1e1e
    const dark = parseOsc11("\x1b]11;rgb:1e1e/1e1e/1e1e\x07").?;
    try testing.expectEqual(@as(u8, 0x1e), dark.r);
    try testing.expect(!isLight(dark));
}

test "parseOsc11: 2-hex 通道" {
    const c = parseOsc11("rgb:ab/cd/ef").?;
    try testing.expectEqual(@as(u8, 0xab), c.r);
    try testing.expectEqual(@as(u8, 0xcd), c.g);
    try testing.expectEqual(@as(u8, 0xef), c.b);
}

test "parseOsc11: 畸形 → null" {
    try testing.expect(parseOsc11("garbage") == null);
    try testing.expect(parseOsc11("\x1b]11;rgb:zz/00/00\x07") == null);
    try testing.expect(parseOsc11("rgb:") == null);
}
