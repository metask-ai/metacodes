//! 主题:语义色 + 角色色 + 符号集。
//!
//! 三套预设:dark / light / monochrome。组件**只**通过 Theme 引用颜色,不直接写
//! ANSI 字节。这样改主题不用 grep 整个项目。
//!
//! 选择策略:
//!   detectColor() == .none → monochrome(全部空字符串 + ASCII 符号)
//!   其它 → 看 settings 的 theme 字段;default = dark
//!
//! 设计参考 TUI_COMPONENTS.md §三。

const std = @import("std");
const ansi = @import("ansi.zig");
const term = @import("term.zig");

pub const Theme = struct {
    // ============ 语义色 ============
    primary: []const u8,
    dim: []const u8,
    accent: []const u8,
    success: []const u8,
    warn: []const u8,
    danger: []const u8,
    info: []const u8,

    // ============ 角色色(消息渲染区分)============
    role_user: []const u8,
    role_assistant: []const u8,
    role_tool: []const u8,
    role_thinking: []const u8,

    // ============ 符号集 ============
    icon_tool: []const u8,
    icon_check: []const u8,
    icon_cross: []const u8,
    icon_arrow: []const u8,
    icon_bullet: []const u8,
    icon_thinking: []const u8,

    // ============ 边框字符 ============
    box_h: []const u8,
    box_v: []const u8,
    box_tl: []const u8,
    box_tr: []const u8,
    box_bl: []const u8,
    box_br: []const u8,

    /// 通用 reset。组件用法:`writer.print("{s}xxx{s}", .{theme.primary, theme.reset})`
    reset: []const u8,
};

// ============================================================================
// 预设
// ============================================================================

pub const dark: Theme = .{
    .primary = "", // 终端默认前景(白/灰)
    .dim = ansi.sgr.dim,
    .accent = ansi.sgr.fg_cyan,
    .success = ansi.sgr.fg_green,
    .warn = ansi.sgr.fg_yellow,
    .danger = ansi.sgr.fg_red,
    .info = ansi.sgr.fg_blue,

    .role_user = ansi.sgr.fg_cyan,
    .role_assistant = ansi.sgr.fg_green,
    .role_tool = ansi.sgr.fg_magenta,
    .role_thinking = ansi.sgr.fg_yellow,

    .icon_tool = "⚙",
    .icon_check = "✓",
    .icon_cross = "✗",
    .icon_arrow = "→",
    .icon_bullet = "•",
    .icon_thinking = "✻",

    .box_h = "─",
    .box_v = "│",
    .box_tl = "╭",
    .box_tr = "╮",
    .box_bl = "╰",
    .box_br = "╯",

    .reset = ansi.sgr.reset,
};

pub const light: Theme = .{
    .primary = "",
    .dim = ansi.sgr.dim,
    .accent = ansi.sgr.fg_blue,  // 浅色背景下青色对比度低,改用蓝
    .success = ansi.sgr.fg_green,
    .warn = ansi.sgr.fg_yellow,
    .danger = ansi.sgr.fg_red,
    .info = ansi.sgr.fg_cyan,

    .role_user = ansi.sgr.fg_blue,
    .role_assistant = ansi.sgr.fg_green,
    .role_tool = ansi.sgr.fg_magenta,
    .role_thinking = ansi.sgr.fg_yellow,

    .icon_tool = "⚙",
    .icon_check = "✓",
    .icon_cross = "✗",
    .icon_arrow = "→",
    .icon_bullet = "•",
    .icon_thinking = "✻",

    .box_h = "─",
    .box_v = "│",
    .box_tl = "╭",
    .box_tr = "╮",
    .box_bl = "╰",
    .box_br = "╯",

    .reset = ansi.sgr.reset,
};

pub const monochrome: Theme = .{
    // 全部空字符串:无 ANSI 输出。适合 NO_COLOR / 管道输出 / dumb 终端。
    .primary = "",
    .dim = "",
    .accent = "",
    .success = "",
    .warn = "",
    .danger = "",
    .info = "",

    .role_user = "",
    .role_assistant = "",
    .role_tool = "",
    .role_thinking = "",

    // ASCII fallback 符号
    .icon_tool = "*",
    .icon_check = "+",
    .icon_cross = "X",
    .icon_arrow = "->",
    .icon_bullet = "-",
    .icon_thinking = "~",

    // ASCII 边框
    .box_h = "-",
    .box_v = "|",
    .box_tl = "+",
    .box_tr = "+",
    .box_bl = "+",
    .box_br = "+",

    .reset = "",
};

// ============================================================================
// 选择
// ============================================================================

pub const Variant = enum { auto, dark, light, monochrome };

/// 根据用户偏好 + 终端能力选主题。
/// - variant=.auto:能力 .none → monochrome;否则 dark(默认)
/// - variant=.dark/light/monochrome:用户显式指定
/// 即便用户选 dark,能力是 .none 时也强制降级到 monochrome(否则 ANSI 在管道里乱码)。
pub fn select(variant: Variant, cap: term.ColorCapability) Theme {
    if (cap == .none) return monochrome;
    return switch (variant) {
        .auto, .dark => dark,
        .light => light,
        .monochrome => monochrome,
    };
}

/// 从字符串名解析(供 `/theme dark` 命令用)。
pub fn parseVariant(s: []const u8) ?Variant {
    if (std.mem.eql(u8, s, "auto")) return .auto;
    if (std.mem.eql(u8, s, "dark")) return .dark;
    if (std.mem.eql(u8, s, "light")) return .light;
    if (std.mem.eql(u8, s, "mono") or std.mem.eql(u8, s, "monochrome")) return .monochrome;
    return null;
}

pub fn variantName(v: Variant) []const u8 {
    return @tagName(v);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "三套预设字段非空(除 monochrome 颜色字段)" {
    // dark + light:颜色字段应非空(primary 除外,它是终端默认)
    try testing.expect(dark.dim.len > 0);
    try testing.expect(dark.accent.len > 0);
    try testing.expect(dark.success.len > 0);
    try testing.expect(light.dim.len > 0);

    // monochrome:所有颜色字段空,符号字段 ASCII
    try testing.expect(monochrome.dim.len == 0);
    try testing.expect(monochrome.accent.len == 0);
    try testing.expectEqualStrings("*", monochrome.icon_tool);
    try testing.expectEqualStrings("-", monochrome.icon_bullet);
    try testing.expectEqualStrings("|", monochrome.box_v);
    try testing.expectEqualStrings("+", monochrome.box_tl);
}

test "select: ColorCapability.none 强制 monochrome" {
    const t = select(.dark, .none);
    try testing.expect(t.dim.len == 0); // 验证是 monochrome
}

test "select: auto + basic_16 → dark" {
    const t = select(.auto, .basic_16);
    try testing.expectEqualStrings(ansi.sgr.dim, t.dim);
    try testing.expectEqualStrings(ansi.sgr.fg_cyan, t.accent); // dark.accent = cyan
}

test "select: light variant 在彩色终端下生效" {
    const t = select(.light, .truecolor);
    try testing.expectEqualStrings(ansi.sgr.fg_blue, t.accent); // light.accent = blue
}

test "parseVariant 支持别名" {
    try testing.expectEqual(Variant.dark, parseVariant("dark").?);
    try testing.expectEqual(Variant.light, parseVariant("light").?);
    try testing.expectEqual(Variant.monochrome, parseVariant("mono").?);
    try testing.expectEqual(Variant.monochrome, parseVariant("monochrome").?);
    try testing.expectEqual(Variant.auto, parseVariant("auto").?);
    try testing.expect(parseVariant("rainbow") == null);
}
