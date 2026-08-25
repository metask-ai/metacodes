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

/// 语法高亮语义色(10 组)。复用 ansi.syntax_palette.Syntax 为单一真相源。
/// 由 select() 按 ColorCapability 填(b16/256/truecolor),basic_16 用历史色保兼容。
pub const SyntaxTheme = ansi.syntax_palette.Syntax;

pub const Theme = struct {
    // ============ 语义色 ============
    primary: []const u8,
    dim: []const u8,
    accent: []const u8,
    success: []const u8,
    warn: []const u8,
    danger: []const u8,
    info: []const u8,
    /// acceptEdits 模式色(对齐 cc autoAccept = ansi:magenta)。footer mode part 用。
    mode_accept: []const u8 = ansi.sgr.fg_magenta,

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
    /// 工具调用 bullet(对齐 cc BLACK_CIRCLE):`⏺`(unicode)/ `*`(ascii)。
    icon_act: []const u8,
    /// 工具结果 gutter 角符(对齐 cc `  ⎿  `):`⎿`(unicode)/ `\`(ascii)。
    gutter: []const u8,
    /// agent 进度树形字符(对齐 cc swarm 树):分支 ├ / 末枝 └ / 竖管 │。
    tree_branch: []const u8,
    tree_end: []const u8,
    tree_pipe: []const u8,
    /// diff 行背景色块(对齐 metacode):add/del 整行背景 tint。
    /// 空串 = 不画背景(basic_16/mono 退回纯前景)。由 select 按 ColorCapability 注入。
    diff_add_bg: []const u8 = "",
    diff_del_bg: []const u8 = "",
    /// 语法高亮语义色(代码 diff + markdown 代码块)。默认 b16(const dark/light 烤入),
    /// select() 对 256/truecolor 升级;monochrome 留空。空组 = 不上色。
    syntax: SyntaxTheme = ansi.syntax_palette.b16,

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
    .icon_act = "⏺",
    .gutter = "⎿",
    .tree_branch = "├",
    .tree_end = "└",
    .tree_pipe = "│",

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
    .accent = ansi.sgr.fg_blue, // 浅色背景下青色对比度低,改用蓝
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
    .icon_act = "⏺",
    .gutter = "⎿",
    .tree_branch = "├",
    .tree_end = "└",
    .tree_pipe = "│",

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
    .mode_accept = "",

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
    .icon_act = "*",
    .gutter = "\\",
    .tree_branch = "+",
    .tree_end = "\\",
    .tree_pipe = "|",

    // ASCII 边框
    .box_h = "-",
    .box_v = "|",
    .box_tl = "+",
    .box_tr = "+",
    .box_bl = "+",
    .box_br = "+",

    // 无语法高亮(mono):全空,渲染层退回纯文本/dim。
    .syntax = .{},

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
    const is_light = (variant == .light);
    var th: Theme = switch (variant) {
        .auto, .dark => dark,
        .light => light,
        .monochrome => monochrome,
    };
    // diff 背景色块:仅 256/truecolor 注入(basic_16 留空 → 纯前景,对齐 metacode)。
    switch (cap) {
        .truecolor => {
            th.diff_add_bg = if (is_light) ansi.diff_bg.tc_add_light else ansi.diff_bg.tc_add_dark;
            th.diff_del_bg = if (is_light) ansi.diff_bg.tc_del_light else ansi.diff_bg.tc_del_dark;
        },
        .extended_256 => {
            th.diff_add_bg = if (is_light) ansi.diff_bg.idx_add_light else ansi.diff_bg.idx_add_dark;
            th.diff_del_bg = if (is_light) ansi.diff_bg.idx_del_light else ansi.diff_bg.idx_del_dark;
        },
        else => {}, // basic_16:不画背景
    }
    // 语法高亮色:basic_16 用 const 烤入的 b16(零回归);256/truecolor 升级到丰富调色板。
    // monochrome 不升级(留空)。
    if (variant != .monochrome) {
        switch (cap) {
            .truecolor => th.syntax = if (is_light) ansi.syntax_palette.tc_light else ansi.syntax_palette.tc_dark,
            .extended_256 => th.syntax = if (is_light) ansi.syntax_palette.idx_light else ansi.syntax_palette.idx_dark,
            else => {}, // basic_16:保留 const 烤入的 b16
        }
    }
    return th;
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

test "select: diff 背景按 ColorCapability 注入" {
    // truecolor:RGB 背景转义。
    const tc = select(.dark, .truecolor);
    try testing.expectEqualStrings(ansi.diff_bg.tc_add_dark, tc.diff_add_bg);
    try testing.expectEqualStrings(ansi.diff_bg.tc_del_dark, tc.diff_del_bg);
    try testing.expect(std.mem.indexOf(u8, tc.diff_add_bg, "48;2;33;58;43") != null);
    // 256:索引背景。
    const c256 = select(.dark, .extended_256);
    try testing.expectEqualStrings(ansi.diff_bg.idx_add_dark, c256.diff_add_bg);
    try testing.expect(std.mem.indexOf(u8, c256.diff_add_bg, "48;5;22") != null);
    // basic_16:不画背景(留空,对齐 metacode fg-only)。
    const c16 = select(.dark, .basic_16);
    try testing.expectEqualStrings("", c16.diff_add_bg);
    try testing.expectEqualStrings("", c16.diff_del_bg);
    // light truecolor 用 GitHub pastel。
    const lt = select(.light, .truecolor);
    try testing.expectEqualStrings(ansi.diff_bg.tc_add_light, lt.diff_add_bg);
    // none → monochrome,无背景。
    const mono = select(.dark, .none);
    try testing.expectEqualStrings("", mono.diff_add_bg);
}

test "select: 语法高亮色按 ColorCapability 升级" {
    // basic_16 → b16(magenta keyword,保历史字节)。
    const b16 = select(.dark, .basic_16);
    try testing.expectEqualStrings(ansi.sgr.fg_magenta, b16.syntax.keyword);
    // truecolor → tc_dark(RGB 紫)。
    const tc = select(.dark, .truecolor);
    try testing.expect(std.mem.indexOf(u8, tc.syntax.keyword, "38;2;197;134;192") != null);
    // type 在 truecolor 是 teal RGB,与 basic_16 的 fg_blue 不同(证明升级)。
    try testing.expect(!std.mem.eql(u8, tc.syntax.type, b16.syntax.type));
    // 256 → idx,且与 b16 不同。
    const x256 = select(.dark, .extended_256);
    try testing.expect(!std.mem.eql(u8, x256.syntax.type, b16.syntax.type));
    // light ≠ dark(truecolor)。
    const lt = select(.light, .truecolor);
    try testing.expect(!std.mem.eql(u8, lt.syntax.keyword, tc.syntax.keyword));
    // monochrome → 全空(none cap)。
    const mono = select(.dark, .none);
    try testing.expectEqualStrings("", mono.syntax.keyword);
}

test "const dark 烤入 b16 syntax(独立用 theme_mod.dark 时高亮可用)" {
    // 现有测试直接用 theme_mod.dark(非 select),其 syntax 须有 basic-16 值。
    try testing.expectEqualStrings(ansi.sgr.fg_magenta, dark.syntax.keyword);
    try testing.expectEqualStrings(ansi.sgr.fg_green, dark.syntax.string);
    try testing.expectEqualStrings(ansi.sgr.fg_yellow, dark.syntax.number);
    // monochrome 烤入空。
    try testing.expectEqualStrings("", monochrome.syntax.keyword);
}
