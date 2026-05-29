//! 终端能力检测 + 显示宽度。
//!
//! 用途:
//! - 启动时检测颜色支持(NO_COLOR/FORCE_COLOR/COLORTERM/TERM)→ 选合适主题
//! - 检测是否 TTY → 决定是否打 ANSI(管道输出走 monochrome 即可)
//! - 终端尺寸(TIOCGWINSZ)→ 布局/边框宽度
//! - UTF-8 + CJK 全角的显示宽度计算(从 loop.zig 抽出来共享给所有组件)

const std = @import("std");

// ============================================================================
// 颜色能力
// ============================================================================

pub const ColorCapability = enum {
    /// 不输出任何 ANSI 颜色(NO_COLOR 环境变量 / 非 TTY / TERM=dumb)
    none,
    /// 基础 8/16 色(\x1b[3xm / \x1b[9xm)
    basic_16,
    /// 256 色(\x1b[38;5;Nm)
    extended_256,
    /// 24-bit true color(\x1b[38;2;R;G;Bm)
    truecolor,
};

/// 检测当前终端的颜色能力。
/// 优先级:NO_COLOR(强制 none)→ 非 TTY(none)→ COLORTERM=truecolor →
/// TERM 含 "256color" → TERM=xterm/screen/tmux(basic_16)→ none。
/// FORCE_COLOR=1/2/3 可强制对应级别(对齐 https://no-color.org / FORCE_COLOR 约定)。
pub fn detectColor(env_no_color: bool, env_force_color: ?u8, term: ?[]const u8, colorterm: ?[]const u8, tty: bool) ColorCapability {
    // NO_COLOR 强制关闭(规范:任何非空值即关)
    if (env_no_color) return .none;

    // FORCE_COLOR 优先级最高
    if (env_force_color) |level| {
        return switch (level) {
            0 => .none,
            1 => .basic_16,
            2 => .extended_256,
            3 => .truecolor,
            else => .basic_16,
        };
    }

    if (!tty) return .none;

    if (term) |t| {
        if (std.mem.eql(u8, t, "dumb")) return .none;
    }

    if (colorterm) |ct| {
        if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")) return .truecolor;
    }

    if (term) |t| {
        if (std.mem.indexOf(u8, t, "256color") != null) return .extended_256;
        // 常见 TERM 值默认 basic_16
        if (std.mem.startsWith(u8, t, "xterm") or
            std.mem.startsWith(u8, t, "screen") or
            std.mem.startsWith(u8, t, "tmux") or
            std.mem.startsWith(u8, t, "rxvt") or
            std.mem.eql(u8, t, "linux") or
            std.mem.eql(u8, t, "ansi")) return .basic_16;
    }

    return .none;
}

/// 从进程环境 + fd 检测。便利封装。
pub fn detectFromEnv(fd: c_int) ColorCapability {
    const tty = isatty(fd);
    const no_color = blk: {
        const v = std.c.getenv("NO_COLOR") orelse break :blk false;
        const s = std.mem.span(v);
        break :blk s.len > 0;
    };
    var force_color: ?u8 = null;
    if (std.c.getenv("FORCE_COLOR")) |v| {
        const s = std.mem.span(v);
        if (s.len > 0) {
            // 数字 0-3
            force_color = std.fmt.parseInt(u8, s, 10) catch 1; // 任何非空 = at least basic
        }
    }
    const term = if (std.c.getenv("TERM")) |t| std.mem.span(t) else null;
    const colorterm = if (std.c.getenv("COLORTERM")) |t| std.mem.span(t) else null;

    return detectColor(no_color, force_color, term, colorterm, tty);
}

// ============================================================================
// TTY 检测 + 终端尺寸
// ============================================================================

pub fn isatty(fd: c_int) bool {
    return std.c.isatty(fd) != 0;
}

pub const TermSize = struct {
    rows: u16,
    cols: u16,
};

/// 查终端尺寸(TIOCGWINSZ ioctl)。非 TTY / ioctl 失败 → null。
pub fn getSize(fd: c_int) ?TermSize {
    // struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; }
    // TIOCGWINSZ 在 macOS/Linux 都是 0x40087468(macOS) / 0x5413(Linux)。
    // 简化:用 std.c.ioctl + 平台分支。
    var ws: extern struct {
        row: u16,
        col: u16,
        xpixel: u16,
        ypixel: u16,
    } = undefined;

    const TIOCGWINSZ: c_ulong = switch (@import("builtin").os.tag) {
        .macos, .ios => 0x40087468,
        .linux => 0x5413,
        else => return null,
    };

    if (std.c.ioctl(fd, TIOCGWINSZ, &ws) != 0) return null;
    if (ws.row == 0 or ws.col == 0) return null;
    return .{ .rows = ws.row, .cols = ws.col };
}

// ============================================================================
// UTF-8 + CJK 显示宽度(从 loop.zig 抽出,共享)
// ============================================================================

/// 字符串在终端的显示列数(ASCII=1,CJK 全角=2,控制字符=0)。
/// 非法 UTF-8 字节按 1 列保底。
pub fn displayWidth(bytes: []const u8) usize {
    return displayWidthUpTo(bytes, bytes.len);
}

/// 计算 bytes[0..byte_pos] 的显示列数(loop.zig 行编辑用)。
pub fn displayWidthUpTo(bytes: []const u8, byte_pos: usize) usize {
    const end = @min(byte_pos, bytes.len);
    var cols: usize = 0;
    var i: usize = 0;
    while (i < end) {
        const b = bytes[i];
        if (b < 0x80) {
            // ASCII:控制字符(< 0x20 或 0x7F DEL)显示宽度 0,其它 1。
            if (b < 0x20 or b == 0x7F) {
                i += 1;
                continue;
            }
            cols += 1;
            i += 1;
            continue;
        }
        const cp_len: usize = if (b & 0b1110_0000 == 0b1100_0000) 2 else if (b & 0b1111_0000 == 0b1110_0000) 3 else if (b & 0b1111_1000 == 0b1111_0000) 4 else 1;
        if (i + cp_len > end) break;
        const cp = decodeCodepoint(bytes[i .. i + cp_len]) orelse {
            cols += 1;
            i += 1;
            continue;
        };
        cols += codepointDisplayWidth(cp);
        i += cp_len;
    }
    return cols;
}

fn decodeCodepoint(s: []const u8) ?u21 {
    return switch (s.len) {
        2 => @as(u21, s[0] & 0x1F) << 6 | @as(u21, s[1] & 0x3F),
        3 => @as(u21, s[0] & 0x0F) << 12 | @as(u21, s[1] & 0x3F) << 6 | @as(u21, s[2] & 0x3F),
        4 => @as(u21, s[0] & 0x07) << 18 | @as(u21, s[1] & 0x3F) << 12 | @as(u21, s[2] & 0x3F) << 6 | @as(u21, s[3] & 0x3F),
        else => null,
    };
}

/// East Asian Width 主要区段(简化表)。
fn codepointDisplayWidth(cp: u21) usize {
    if (cp < 0x20 or cp == 0x7F) return 0;
    if (cp >= 0x1100 and cp <= 0x115F) return 2; // Hangul Jamo
    if (cp >= 0x2E80 and cp <= 0x303E) return 2;
    if (cp >= 0x3041 and cp <= 0x33FF) return 2;
    if (cp >= 0x3400 and cp <= 0x4DBF) return 2;
    if (cp >= 0x4E00 and cp <= 0x9FFF) return 2;
    if (cp >= 0xA000 and cp <= 0xA4CF) return 2;
    if (cp >= 0xAC00 and cp <= 0xD7A3) return 2;
    if (cp >= 0xF900 and cp <= 0xFAFF) return 2;
    if (cp >= 0xFE30 and cp <= 0xFE4F) return 2;
    if (cp >= 0xFF00 and cp <= 0xFF60) return 2;
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2;
    if (cp >= 0x1F300 and cp <= 0x1FAFF) return 2;
    if (cp >= 0x20000 and cp <= 0x2FFFD) return 2;
    if (cp >= 0x30000 and cp <= 0x3FFFD) return 2;
    return 1;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "detectColor: NO_COLOR 强制关闭" {
    try testing.expectEqual(ColorCapability.none, detectColor(true, null, "xterm-256color", "truecolor", true));
}

test "detectColor: 非 TTY → none" {
    try testing.expectEqual(ColorCapability.none, detectColor(false, null, "xterm-256color", null, false));
}

test "detectColor: FORCE_COLOR 优先" {
    try testing.expectEqual(ColorCapability.truecolor, detectColor(false, 3, null, null, false));
    try testing.expectEqual(ColorCapability.extended_256, detectColor(false, 2, null, null, false));
    try testing.expectEqual(ColorCapability.basic_16, detectColor(false, 1, null, null, false));
    try testing.expectEqual(ColorCapability.none, detectColor(false, 0, null, null, false));
}

test "detectColor: COLORTERM=truecolor" {
    try testing.expectEqual(ColorCapability.truecolor, detectColor(false, null, "xterm", "truecolor", true));
    try testing.expectEqual(ColorCapability.truecolor, detectColor(false, null, null, "24bit", true));
}

test "detectColor: TERM 含 256color" {
    try testing.expectEqual(ColorCapability.extended_256, detectColor(false, null, "xterm-256color", null, true));
    try testing.expectEqual(ColorCapability.extended_256, detectColor(false, null, "screen-256color", null, true));
}

test "detectColor: TERM=dumb / 无 TERM → none" {
    try testing.expectEqual(ColorCapability.none, detectColor(false, null, "dumb", null, true));
    try testing.expectEqual(ColorCapability.none, detectColor(false, null, null, null, true));
}

test "detectColor: TERM=xterm → basic_16" {
    try testing.expectEqual(ColorCapability.basic_16, detectColor(false, null, "xterm", null, true));
    try testing.expectEqual(ColorCapability.basic_16, detectColor(false, null, "tmux-direct", null, true));
}

test "displayWidth: ASCII" {
    try testing.expectEqual(@as(usize, 5), displayWidth("hello"));
    try testing.expectEqual(@as(usize, 0), displayWidth(""));
}

test "displayWidth: CJK 全角 = 2" {
    // "你好" = 2 个汉字 = 4 列
    try testing.expectEqual(@as(usize, 4), displayWidth("你好"));
    // 混合:ASCII + 汉字
    try testing.expectEqual(@as(usize, 7), displayWidth("hi 你好"));
}

test "displayWidth: emoji = 2" {
    // ✻ U+273B 不在 CJK / 标记的 emoji 区段(0x1F300..) → 1 列
    try testing.expectEqual(@as(usize, 1), displayWidth("✻"));
    // 真 emoji 在 0x1F300..0x1FAFF → 2 列
    try testing.expectEqual(@as(usize, 2), displayWidth("🎯"));
}

test "displayWidth: 控制字符 = 0" {
    try testing.expectEqual(@as(usize, 0), displayWidth("\x01\x02"));
    try testing.expectEqual(@as(usize, 5), displayWidth("\x01hello"));
}
