//! ANSI 转义序列原语(集中所有 SGR/cursor/clear/screen 编码)。
//!
//! 用途:替代 cc-zig 现有 18+ 处散落的 `\x1b[...]` 硬编码。
//!
//! 设计:**纯生成,无状态**。组件不直接调 ansi.zig,而是通过 theme 引用语义色;
//! ansi.zig 提供给 theme 和直接需要光标控制的代码(transcript_viewer / fullscreen)。
//!
//! 参考:
//! - ECMA-48 标准
//! - https://en.wikipedia.org/wiki/ANSI_escape_code
//! - cc-zig 现有用法:render.zig:21-31 颜色常量 / transcript_viewer.zig:90-91 alt screen
//!
//! 关键约定:
//! - 所有常量都是 `[]const u8`(comptime 字符串),适合 writeAll
//! - 运行时构造的(fg256/fgRgb/move 等)接收 caller 提供的 buf,返回 slice
//! - 调用方负责终端兼容(详见 term.zig 的能力检测;不在本模块决策)

const std = @import("std");

// ============================================================================
// SGR(Select Graphic Rendition)— 文字属性 + 颜色
// ============================================================================

pub const sgr = struct {
    pub const reset = "\x1b[0m";

    // 文字属性
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const italic = "\x1b[3m";
    pub const underline = "\x1b[4m";
    pub const reverse = "\x1b[7m";
    pub const strike = "\x1b[9m";

    // 8 标准前景色
    pub const fg_black = "\x1b[30m";
    pub const fg_red = "\x1b[31m";
    pub const fg_green = "\x1b[32m";
    pub const fg_yellow = "\x1b[33m";
    pub const fg_blue = "\x1b[34m";
    pub const fg_magenta = "\x1b[35m";
    pub const fg_cyan = "\x1b[36m";
    pub const fg_white = "\x1b[37m";

    // 8 高亮前景色(bright/light)
    pub const fg_bright_black = "\x1b[90m"; // 通常显示为灰
    pub const fg_bright_red = "\x1b[91m";
    pub const fg_bright_green = "\x1b[92m";
    pub const fg_bright_yellow = "\x1b[93m";
    pub const fg_bright_blue = "\x1b[94m";
    pub const fg_bright_magenta = "\x1b[95m";
    pub const fg_bright_cyan = "\x1b[96m";
    pub const fg_bright_white = "\x1b[97m";

    // 默认前景(取消颜色但保持属性)
    pub const fg_default = "\x1b[39m";

    /// 256 色前景。`\x1b[38;5;{N}m`,N=0..255。写 buf,返回 slice。
    pub fn fg256(idx: u8, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "\x1b[38;5;{d}m", .{idx}) catch return "";
    }

    /// RGB 24-bit 前景。`\x1b[38;2;{R};{G};{B}m`。
    pub fn fgRgb(r: u8, g: u8, b: u8, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "\x1b[38;2;{d};{d};{d}m", .{ r, g, b }) catch return "";
    }
};

// ============================================================================
// 光标控制
// ============================================================================

pub const cursor = struct {
    pub const hide = "\x1b[?25l";
    pub const show = "\x1b[?25h";
    pub const home = "\x1b[H"; // (1, 1)
    pub const save = "\x1b7";   // DECSC(更可靠,save SCO 用 \x1b[s 不所有终端兼容)
    pub const restore = "\x1b8"; // DECRC

    /// 移动到 (row, col),1-based。`\x1b[{R};{C}H`。
    pub fn move(row: u32, col: u32, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "\x1b[{d};{d}H", .{ row, col }) catch return "";
    }

    /// 上移 n 行(不滚屏)。`\x1b[{N}A`。
    pub fn up(n: u32, buf: []u8) []const u8 {
        if (n == 0) return "";
        return std.fmt.bufPrint(buf, "\x1b[{d}A", .{n}) catch return "";
    }
    pub fn down(n: u32, buf: []u8) []const u8 {
        if (n == 0) return "";
        return std.fmt.bufPrint(buf, "\x1b[{d}B", .{n}) catch return "";
    }
    pub fn forward(n: u32, buf: []u8) []const u8 {
        if (n == 0) return "";
        return std.fmt.bufPrint(buf, "\x1b[{d}C", .{n}) catch return "";
    }
    pub fn back(n: u32, buf: []u8) []const u8 {
        if (n == 0) return "";
        return std.fmt.bufPrint(buf, "\x1b[{d}D", .{n}) catch return "";
    }

    /// 移到当前行第 col 列。1-based。`\x1b[{C}G`。
    pub fn column(col: u32, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "\x1b[{d}G", .{col}) catch return "";
    }
};

// ============================================================================
// 清屏 / 清行
// ============================================================================

pub const clear = struct {
    pub const screen = "\x1b[2J"; // 全屏(不动光标)
    pub const screen_and_home = "\x1b[2J\x1b[H";
    pub const to_end_of_screen = "\x1b[0J";
    pub const to_start_of_screen = "\x1b[1J";

    pub const line = "\x1b[2K";       // 整行
    pub const to_end_of_line = "\x1b[0K";
    pub const to_start_of_line = "\x1b[1K";
};

// ============================================================================
// 屏幕模式 / 输入特性
// ============================================================================

pub const screen = struct {
    /// Alternate screen buffer(进入 = vim/htop 全屏;退出恢复原终端)
    pub const alt_enter = "\x1b[?1049h";
    pub const alt_exit = "\x1b[?1049l";

    /// Bracketed paste:粘贴时终端用 ESC[200~ ... ESC[201~ 包裹
    pub const bracketed_paste_on = "\x1b[?2004h";
    pub const bracketed_paste_off = "\x1b[?2004l";

    /// 鼠标 SGR 模式(支持 1000+ 列,坐标 1-based)
    pub const mouse_enable = "\x1b[?1000h\x1b[?1006h"; // 基础 + SGR
    pub const mouse_disable = "\x1b[?1000l\x1b[?1006l";

    /// 自动换行(默认开),关闭后写超过行宽不换行而是覆盖
    pub const wrap_on = "\x1b[?7h";
    pub const wrap_off = "\x1b[?7l";
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "sgr 常量正确" {
    try testing.expectEqualStrings("\x1b[0m", sgr.reset);
    try testing.expectEqualStrings("\x1b[2m", sgr.dim);
    try testing.expectEqualStrings("\x1b[31m", sgr.fg_red);
    try testing.expectEqualStrings("\x1b[90m", sgr.fg_bright_black);
}

test "sgr.fg256 编码" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("\x1b[38;5;240m", sgr.fg256(240, &buf));
    try testing.expectEqualStrings("\x1b[38;5;0m", sgr.fg256(0, &buf));
    try testing.expectEqualStrings("\x1b[38;5;255m", sgr.fg256(255, &buf));
}

test "sgr.fgRgb 编码" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("\x1b[38;2;255;128;0m", sgr.fgRgb(255, 128, 0, &buf));
    try testing.expectEqualStrings("\x1b[38;2;0;0;0m", sgr.fgRgb(0, 0, 0, &buf));
}

test "cursor 常量" {
    try testing.expectEqualStrings("\x1b[?25l", cursor.hide);
    try testing.expectEqualStrings("\x1b[?25h", cursor.show);
    try testing.expectEqualStrings("\x1b[H", cursor.home);
}

test "cursor.move 编码" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("\x1b[1;1H", cursor.move(1, 1, &buf));
    try testing.expectEqualStrings("\x1b[24;80H", cursor.move(24, 80, &buf));
}

test "cursor.up/down/forward/back" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("", cursor.up(0, &buf));     // 0 → 空(避免无效转义)
    try testing.expectEqualStrings("\x1b[1A", cursor.up(1, &buf));
    try testing.expectEqualStrings("\x1b[5B", cursor.down(5, &buf));
    try testing.expectEqualStrings("\x1b[10C", cursor.forward(10, &buf));
    try testing.expectEqualStrings("\x1b[3D", cursor.back(3, &buf));
}

test "cursor.column 编码" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("\x1b[1G", cursor.column(1, &buf));
    try testing.expectEqualStrings("\x1b[40G", cursor.column(40, &buf));
}

test "clear 常量" {
    try testing.expectEqualStrings("\x1b[2J", clear.screen);
    try testing.expectEqualStrings("\x1b[2K", clear.line);
    try testing.expectEqualStrings("\x1b[2J\x1b[H", clear.screen_and_home);
}

test "screen alt screen + bracketed paste" {
    try testing.expectEqualStrings("\x1b[?1049h", screen.alt_enter);
    try testing.expectEqualStrings("\x1b[?1049l", screen.alt_exit);
    try testing.expectEqualStrings("\x1b[?2004h", screen.bracketed_paste_on);
}
