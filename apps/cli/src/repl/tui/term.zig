//! 终端能力检测 + 显示宽度。
//!
//! 用途:
//! - 启动时检测颜色支持(NO_COLOR/FORCE_COLOR/COLORTERM/TERM)→ 选合适主题
//! - 检测是否 TTY → 决定是否打 ANSI(管道输出走 monochrome 即可)
//! - 终端尺寸(TIOCGWINSZ)→ 布局/边框宽度
//! - UTF-8 + CJK 全角的显示宽度计算(从 loop.zig 抽出来共享给所有组件)

const std = @import("std");
const char_width = @import("char_width.zig");

pub const TerminalEnv = struct {
    term: ?[]const u8 = null,
    term_program: ?[]const u8 = null,
    lc_terminal: ?[]const u8 = null,
    tmux: bool = false,
    sty: bool = false,
    zellij: bool = false,
    xterm: bool = false,

    pub const Multiplexer = enum { none, tmux, gnu_screen, zellij, remote_tmux };

    pub fn fromProcess() TerminalEnv {
        return .{
            .term = value("TERM"),
            .term_program = value("TERM_PROGRAM"),
            .lc_terminal = value("LC_TERMINAL"),
            .tmux = nonEmpty("TMUX"),
            .sty = nonEmpty("STY"),
            .zellij = value("ZELLIJ") != null,
            .xterm = nonEmpty("XTERM_VERSION"),
        };
    }

    pub fn innerMultiplexer(self: TerminalEnv) Multiplexer {
        if (self.tmux) return .tmux;
        if (self.wrappedByGnuScreen()) return .gnu_screen;
        if (self.zellij) return .zellij;
        if (self.term) |term| if (std.mem.startsWith(u8, term, "tmux")) return .remote_tmux;
        return .none;
    }

    pub fn insideTmux(self: TerminalEnv) bool {
        return self.innerMultiplexer() == .tmux;
    }

    pub fn insideGnuScreen(self: TerminalEnv) bool {
        return self.innerMultiplexer() == .gnu_screen;
    }

    pub fn wrappedByGnuScreen(self: TerminalEnv) bool {
        if (self.sty) return true;
        const term = self.term orelse return false;
        return !self.tmux and std.mem.startsWith(u8, term, "screen");
    }

    pub fn resolvedTermProgram(self: TerminalEnv) ?[]const u8 {
        if (self.term_program) |program| if (program.len > 0) return program;
        if (self.lc_terminal) |terminal| if (std.mem.eql(u8, terminal, "iTerm2")) return "iTerm.app";
        return null;
    }

    fn value(name: [*:0]const u8) ?[]const u8 {
        return if (std.c.getenv(name)) |raw| std.mem.span(raw) else null;
    }

    fn nonEmpty(name: [*:0]const u8) bool {
        return if (value(name)) |raw| raw.len > 0 else false;
    }
};

test "multiplexer layers and terminal program resolution" {
    const screen: TerminalEnv = .{ .term = "screen-256color" };
    try testing.expect(screen.insideGnuScreen());
    try testing.expect(screen.wrappedByGnuScreen());
    const nested: TerminalEnv = .{ .tmux = true, .sty = true, .term = "tmux-256color" };
    try testing.expect(nested.insideTmux());
    try testing.expect(!nested.insideGnuScreen());
    try testing.expect(nested.wrappedByGnuScreen());
    try testing.expectEqual(TerminalEnv.Multiplexer.zellij, (TerminalEnv{ .zellij = true }).innerMultiplexer());
    try testing.expectEqual(TerminalEnv.Multiplexer.remote_tmux, (TerminalEnv{ .term = "tmux-256color" }).innerMultiplexer());
    try testing.expectEqualStrings("iTerm.app", (TerminalEnv{ .lc_terminal = "iTerm2" }).resolvedTermProgram().?);
    try testing.expectEqualStrings("vscode", (TerminalEnv{ .term_program = "vscode", .lc_terminal = "iTerm2" }).resolvedTermProgram().?);
    try testing.expectEqualStrings("iTerm.app", (TerminalEnv{ .term_program = "", .lc_terminal = "iTerm2" }).resolvedTermProgram().?);
}

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
    // FORCE_COLOR 优先级最高(对齐 no-color.org / chalk:FORCE_COLOR 显式压过 NO_COLOR)。
    // 必须在 NO_COLOR 之前判——否则 NO_COLOR 短路,用户用 FORCE_COLOR 强开颜色无效。
    if (env_force_color) |level| {
        return switch (level) {
            0 => .none,
            1 => .basic_16,
            2 => .extended_256,
            3 => .truecolor,
            else => .basic_16,
        };
    }

    // NO_COLOR 强制关闭(规范:任何非空值即关)。
    if (env_no_color) return .none;

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
    const env = TerminalEnv.fromProcess();
    const inherited = if (std.c.getenv("COLORTERM")) |t| std.mem.span(t) else null;
    const colorterm = if (env.wrappedByGnuScreen()) null else inherited;

    return detectColor(no_color, force_color, env.term, colorterm, tty);
}

pub fn effectiveColorterm(colorterm: ?[]const u8, sty: bool, tmux: bool, term: ?[]const u8) ?[]const u8 {
    return if (insideScreen(sty, tmux, term)) null else colorterm;
}

pub fn insideScreen(sty: bool, tmux: bool, term: ?[]const u8) bool {
    return (TerminalEnv{ .sty = sty, .tmux = tmux, .term = term }).wrappedByGnuScreen();
}

// ============================================================================
// TTY 检测 + 终端尺寸
// ============================================================================

const platform_term = @import("metacodes-internal").platform.terminal;

pub fn isatty(fd: c_int) bool {
    return platform_term.isatty(fd);
}

pub const TermSize = struct {
    rows: u16,
    cols: u16,
};

/// 查终端尺寸。非 TTY / 失败 / 0 尺寸 → null。可移植:POSIX ioctl(TIOCGWINSZ)/
/// Windows GetConsoleScreenBufferInfo(见 platform/terminal.zig)。
pub fn getSize(fd: c_int) ?TermSize {
    const sz = platform_term.windowSize(fd) orelse return null;
    if (sz.rows == 0 or sz.cols == 0) return null;
    return .{ .rows = sz.rows, .cols = sz.cols };
}

// ============================================================================
// resize 重排
// ============================================================================

/// Whether the terminal re-wraps the lines it shows when the window narrows.
/// Most POSIX terminals do (iTerm2, Terminal.app, kitty, Ghostty, WezTerm,
/// Alacritty, VTE, xterm.js, rxvt-unicode, tmux); xterm, GNU screen, st, PuTTY
/// and the Linux console clip instead. tmux re-wraps whatever runs inside it,
/// so its marker wins over the outer terminal's. A terminal nothing names
/// counts as re-wrapping. See reflow.zig for what the answer changes.
pub fn detectReflow(tmux: bool, screen: bool, xterm: bool, term: ?[]const u8) bool {
    if (tmux) return true;
    if (screen or xterm) return false;
    if (term) |t| if (termClips(t)) return false;
    return true;
}

fn termClips(term: []const u8) bool {
    return std.mem.eql(u8, term, "linux") or std.mem.eql(u8, term, "st") or std.mem.startsWith(u8, term, "st-") or
        std.mem.startsWith(u8, term, "stterm") or std.mem.startsWith(u8, term, "putty");
}

pub fn answersNameClippingTerminal(xtversion: []const u8, da2: []const u8) bool {
    return std.mem.startsWith(u8, xtversion, "XTerm(") or std.mem.eql(u8, da2, "0;136;0");
}

var g_answers_name_clipping_terminal = false;

pub fn recordProbeAnswers(xtversion: []const u8, da2: []const u8) void {
    g_answers_name_clipping_terminal = answersNameClippingTerminal(xtversion, da2);
}

pub fn reflowNeedsProbe() bool {
    if (platform_term.console_reflows != null) return false;
    return reflowNeedsProbeFor(TerminalEnv.fromProcess());
}

pub fn reflowNeedsProbeFor(env: TerminalEnv) bool {
    if (env.insideTmux() or env.insideGnuScreen() or env.xterm) return false;
    return if (env.term) |t| !termClips(t) else true;
}

/// detectReflow over the process environment (`TMUX`, GNU screen's `STY`,
/// xterm's `XTERM_VERSION`, `TERM`) and the startup probe's XTVERSION and DA2
/// answers, which name xterm and PuTTY where an SSH login dropped the rest.
/// Where the platform's console decides (Windows: conhost clips,
/// platform.terminal.console_reflows), neither is consulted.
pub fn reflowFromEnv() bool {
    if (platform_term.console_reflows) |reflows| return reflows;
    return reflowFor(TerminalEnv.fromProcess(), g_answers_name_clipping_terminal);
}

pub fn reflowFor(env: TerminalEnv, probe_clips: bool) bool {
    return detectReflow(env.insideTmux(), env.insideGnuScreen(), env.xterm or probe_clips, env.term);
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

pub fn codepointDisplayWidth(cp: u21) usize {
    if (cp < 0xA0) return if (cp < 0x20 or cp == 0x7F) 0 else 1;
    if (inRanges(&char_width.zero, cp)) return 0;
    if (inRanges(&char_width.wide, cp)) return 2;
    return 1;
}

fn inRanges(ranges: []const [2]u21, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid][0]) {
            hi = mid;
        } else if (cp > ranges[mid][1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
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

test "detectColor: FORCE_COLOR 压过 NO_COLOR(no-color.org 优先级)" {
    // FORCE_COLOR=3 + NO_COLOR=1 → 仍 truecolor(FORCE_COLOR 更高,显式压过 NO_COLOR)。
    try testing.expectEqual(ColorCapability.truecolor, detectColor(true, 3, "xterm-256color", null, true));
    // FORCE_COLOR=0 + NO_COLOR=1 → none(两者都要关,一致)。
    try testing.expectEqual(ColorCapability.none, detectColor(true, 0, "xterm-256color", null, true));
}

test "insideScreen: STY, or a screen TERM outside tmux" {
    try testing.expect(insideScreen(true, false, "screen.xterm-256color"));
    try testing.expect(insideScreen(true, false, null));
    try testing.expect(insideScreen(true, true, "tmux-256color"));
    try testing.expect(insideScreen(false, false, "screen"));
    try testing.expect(insideScreen(false, false, "screen-256color"));
    try testing.expect(!insideScreen(false, true, "screen-256color"));
    try testing.expect(!insideScreen(false, false, "xterm-256color"));
    try testing.expect(!insideScreen(false, false, null));
}

test "detectColor: inside GNU screen the inherited COLORTERM is dropped and the TERM screen set decides; FORCE_COLOR still wins" {
    const screen_256 = "screen.xterm-256color";
    try testing.expectEqual(ColorCapability.extended_256, detectColor(false, null, screen_256, effectiveColorterm("truecolor", true, false, screen_256), true));
    try testing.expectEqual(ColorCapability.basic_16, detectColor(false, null, "screen", effectiveColorterm("truecolor", true, false, "screen"), true));
    try testing.expectEqual(ColorCapability.basic_16, detectColor(false, null, "screen", effectiveColorterm("24bit", false, false, "screen"), true));
    try testing.expectEqual(ColorCapability.truecolor, detectColor(false, 3, "screen", effectiveColorterm("truecolor", true, false, "screen"), true));
    try testing.expectEqual(ColorCapability.none, detectColor(true, null, screen_256, effectiveColorterm("truecolor", true, false, screen_256), true));
    try testing.expectEqual(ColorCapability.truecolor, detectColor(false, null, "screen-256color", effectiveColorterm("truecolor", false, true, "screen-256color"), true));
    try testing.expectEqual(ColorCapability.truecolor, detectColor(false, null, "xterm-256color", effectiveColorterm("truecolor", false, false, "xterm-256color"), true));
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

test "detectReflow: xterm, GNU screen and the Linux console clip; tmux re-wraps inside them" {
    try testing.expect(detectReflow(false, false, false, "xterm-256color"));
    try testing.expect(detectReflow(false, false, false, null));
    try testing.expect(!detectReflow(false, false, true, "xterm-256color"));
    try testing.expect(!detectReflow(false, true, false, "screen-256color"));
    try testing.expect(!detectReflow(false, false, false, "linux"));
    // tmux running in xterm or in screen still re-wraps its own panes.
    try testing.expect(detectReflow(true, false, true, "tmux-256color"));
    try testing.expect(detectReflow(true, true, false, "screen-256color"));
}

test "detectReflow: st and PuTTY clip, rxvt-unicode and an unnamed terminal re-wrap" {
    for ([_][]const u8{ "st", "st-256color", "stterm-256color", "putty", "putty-256color" }) |t| try testing.expect(!detectReflow(false, false, false, t));
    for ([_][]const u8{ "rxvt-unicode-256color", "xterm-256color", "xterm-kitty", "xterm-ghostty", "wezterm", "stx" }) |t| try testing.expect(detectReflow(false, false, false, t));
    try testing.expect(detectReflow(true, false, false, "st-256color"));
}

test "answersNameClippingTerminal: xterm's XTVERSION and PuTTY's DA2" {
    try testing.expect(answersNameClippingTerminal("XTerm(390)", ""));
    try testing.expect(answersNameClippingTerminal("", "0;136;0"));
    try testing.expect(!answersNameClippingTerminal("tmux 3.5a", "84;0;0"));
    try testing.expect(!answersNameClippingTerminal("iTerm2 3.5.10", "0;95;0"));
    try testing.expect(!answersNameClippingTerminal("", "41;390;0"));
    try testing.expect(!answersNameClippingTerminal("", ""));
}

test "reflowFromEnv: the platform's console answer wins over the environment" {
    const reflows = platform_term.console_reflows orelse return error.SkipZigTest;
    // Windows: no TMUX, STY, XTERM_VERSION or TERM=linux is set by a console,
    // so detectReflow alone would answer true.
    try testing.expectEqual(reflows, reflowFromEnv());
    try testing.expect(!reflows);
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

test "displayWidth: wide emoji outside the U+1F300 block take two columns" {
    for ([_][]const u8{ "✅", "❌", "⭐", "⚡", "⌛", "⏳", "☕", "✨" }) |emoji| try testing.expectEqual(@as(usize, 2), displayWidth(emoji));
}

test "displayWidth: combining marks take no column, joiners and zero width spaces one as Terminal.app draws them" {
    try testing.expectEqual(@as(usize, 1), displayWidth("e\u{301}"));
    try testing.expectEqual(@as(usize, 1), displayWidth("\u{200B}"));
    try testing.expectEqual(@as(usize, 5), displayWidth("\u{1F468}\u{200D}\u{1F4BB}"));
    try testing.expectEqual(@as(usize, 8), displayWidth("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"));
}

test "displayWidth: emoji presentation, flags and decomposed Hangul count at least what a terminal draws" {
    try testing.expectEqual(@as(usize, 2), displayWidth("\u{26A0}\u{FE0F}"));
    try testing.expectEqual(@as(usize, 2), displayWidth("1\u{FE0F}\u{20E3}"));
    try testing.expectEqual(@as(usize, 4), displayWidth("\u{1F1E8}\u{1F1F3}"));
    try testing.expectEqual(@as(usize, 4), displayWidth("\u{1112}\u{1161}\u{11AB}"));
    try testing.expectEqual(@as(usize, 1), displayWidth("\u{1F321}"));
}
