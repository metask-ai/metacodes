//! StatusBar widget —— RenderRegion 的状态栏(1 行)。
//!
//! 两个形态(复刻 Claude Code 观感):
//! - **idle**(输入期):`{model} · {mode} · {N}tok · ${cost}[· Nbg][· Ncron]`
//!   等价于旧 statusline.render 的内容,被 RenderRegion 吸收。
//! - **generating**(生成期):`{spinner} {verb}… ({Xs} · ↓ {out} tokens)`(对齐 cc;esc 在 footer)
//!
//! 约定:不自己 write,把行字节(含 SGR+reset,不含尾随 \r\n)写进调用方提供的 writer
//! (RenderRegion 持有 Io.Writer.Allocating over scratch),返回 line_count(恒 1)。
//! 颜色走 theme.*,monochrome 自动无 ANSI。

const std = @import("std");
const app_mod = @import("../../../app.zig");
const types = @import("../../../types.zig");
const verbs = @import("../verbs.zig");
const Theme = @import("../theme.zig").Theme;

pub const StatusBar = struct {
    /// idle 形态:写一行到 writer,返回 1。
    pub fn renderIdle(
        writer: anytype,
        app: *const app_mod.App,
        theme: Theme,
    ) !usize {
        const u = app.usage;
        const total_tokens = u.input_tokens + u.output_tokens;
        const cost = u.costUsd(app.activeModel());
        const mode_str = modeName(app.config.permission_mode);

        var tok_buf: [16]u8 = undefined;
        const tok_str = formatTokens(&tok_buf, total_tokens);

        const bg_count = if (app.jobs) |*j| j.runningCount() else 0;
        const cron_count = app.cron_registry.count();

        var extra_buf: [64]u8 = undefined;
        var extra: []const u8 = "";
        if (bg_count > 0 and cron_count > 0) {
            extra = std.fmt.bufPrint(&extra_buf, " · {d}bg · {d}cron", .{ bg_count, cron_count }) catch "";
        } else if (bg_count > 0) {
            extra = std.fmt.bufPrint(&extra_buf, " · {d}bg", .{bg_count}) catch "";
        } else if (cron_count > 0) {
            extra = std.fmt.bufPrint(&extra_buf, " · {d}cron", .{cron_count}) catch "";
        }

        try writer.print("{s}{s} · {s} · {s} tok · ${d:.4}{s}{s}", .{
            theme.dim,
            app.activeModel(),
            mode_str,
            tok_str,
            cost,
            extra,
            theme.reset,
        });
        return 1;
    }

    /// generating 形态:写一行 spinner,返回 1。对齐 napicc v2.1.170(2026-06-10 实测纠正):
    /// **2s 门控**——前 2 秒只显 `{char} {verb}…`(无计时/token);≥2s 才显
    /// `{char} {verb}… ({Ns} · ↓ {N} tokens)`(token>0 才含 token 段)。旧"30s 门控"认知被实拍推翻。
    /// `esc to interrupt` 在 footer(drawFooter 生成期),非此行。
    /// 留 current_tool/tool_ms 形参不读(调用方签名稳定,工具进度走下方 per-toolUse 卡)。
    /// max_w = 最大显示宽(= inner_w);超宽按显示宽截断(跳过 ANSI SGR 不计宽)。
    pub fn renderGenerating(
        writer: anytype,
        app: *const app_mod.App,
        theme: Theme,
        use_unicode: bool,
        frame_idx: u8,
        verb: []const u8,
        elapsed_ms: u64,
        current_tool: []const u8,
        tool_ms: u64,
        max_w: usize,
    ) !usize {
        _ = current_tool;
        _ = tool_ms;
        const fr = verbs.frame(frame_idx, use_unicode);

        var line_buf: [256]u8 = undefined;
        // 计时/token 门控(2s,对齐 napicc v2.1.170 实拍):未到阈值 → 极简 `{char} {verb}…`。
        if (elapsed_ms < SHOW_TOKENS_AFTER_MS) {
            const line = std.fmt.bufPrint(&line_buf, "{s}{s} {s}{s}…{s}", .{
                theme.accent, fr, theme.reset, verb, theme.reset,
            }) catch {
                try writer.print("{s}{s}{s}", .{ theme.accent, fr, theme.reset });
                return 1;
            };
            try writeTruncated(writer, line, max_w);
            return 1;
        }

        // ≥30s → 显计时 + token(token>0 才含 `· ↓ N tokens`)。
        const secs = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        const out_tok = app.usage.output_tokens;
        const arrow = if (use_unicode) "↓" else "v";
        var meta_buf: [48]u8 = undefined;
        var tok_buf: [16]u8 = undefined;
        const meta: []const u8 = if (out_tok > 0)
            (std.fmt.bufPrint(&meta_buf, " ({d:.0}s · {s} {s} tokens)", .{ secs, arrow, formatTokens(&tok_buf, out_tok) }) catch "")
        else
            (std.fmt.bufPrint(&meta_buf, " ({d:.0}s)", .{secs}) catch "");
        const line = std.fmt.bufPrint(&line_buf, "{s}{s} {s}{s}…{s}{s}{s}{s}", .{
            theme.accent, fr, theme.reset, verb, theme.reset, theme.dim, meta, theme.reset,
        }) catch {
            try writer.print("{s}{s}{s}", .{ theme.accent, fr, theme.reset });
            return 1;
        };
        try writeTruncated(writer, line, max_w);
        return 1;
    }

    /// cc spinner 显示计时+token 的最小生成耗时。
    /// **2026-06-10 实测纠正(napicc v2.1.170 金标准)**:真 cc 2-3s 就显 `(Ns · ↓Nk tokens)`,
    /// 非旧认知的 30s 门控(SHOW_TOKENS_AFTER_MS=30000,可能 cc 旧版/源码推测有误)。降到 2s 对齐实拍。
    /// golden=tmp/tty_golden/napicc_gen_single_step.raw(样本 (2s·thinking)/(3s·↓40 tokens))。
    const SHOW_TOKENS_AFTER_MS: u64 = 2_000;


    /// 把含 SGR 的字符串按可见显示宽 max_w 截断后写出。ANSI 转义(\x1b[...m 等)不计宽且原样保留;
    /// 截断点后剩余的可见字符丢弃,但补一个 reset 防染色泄漏。
    fn writeTruncated(writer: anytype, s: []const u8, max_w: usize) !void {
        var vis_w: usize = 0;
        var i: usize = 0;
        var truncated = false;
        while (i < s.len) {
            if (s[i] == 0x1b) {
                // 透传整个 ESC 序列(到字母结尾 / 简单两字节)。
                const start = i;
                i += 1;
                if (i < s.len and s[i] == '[') {
                    i += 1;
                    while (i < s.len and !std.ascii.isAlphabetic(s[i])) : (i += 1) {}
                    if (i < s.len) i += 1; // 含结尾字母
                } else if (i < s.len) {
                    i += 1; // 两字节转义(如 \x1b7)
                }
                try writer.writeAll(s[start..i]);
                continue;
            }
            // 一个可见字符:算字节数 + 显示宽。
            const b = s[i];
            const nb: usize = if (b < 0x80) 1 else if (b >= 0xF0) 4 else if (b >= 0xE0) 3 else if (b >= 0xC0) 2 else 1;
            const end = @min(i + nb, s.len);
            const cw = displayWidth(s[i..end]);
            if (vis_w + cw > max_w) {
                truncated = true;
                break;
            }
            try writer.writeAll(s[i..end]);
            vis_w += cw;
            i = end;
        }
        if (truncated) try writer.writeAll("\x1b[0m");
    }
};

fn displayWidth(s: []const u8) usize {
    return @import("../term.zig").displayWidth(s);
}

pub fn modeName(m: types.PermissionMode) []const u8 {
    return switch (m) {
        .default => "default",
        .accept_edits => "acceptEdits",
        .plan => "plan",
        .auto => "auto",
        .dont_ask => "dontAsk",
        .bypass_permissions => "bypassPermissions",
        .prompt => "prompt",
        .bypass => "bypass",
    };
}

/// footer mode part 的人话标题(对齐 cc PermissionMode.ts title,小写化后接 " on")。
/// default/prompt 返回 ""——调用方据此跳过 mode part(对齐 cc isDefaultMode)。
pub fn modeTitle(m: types.PermissionMode) []const u8 {
    return switch (m) {
        .default, .prompt => "",
        .plan => "plan mode",
        .accept_edits => "accept edits",
        .bypass_permissions, .bypass => "bypass permissions",
        .dont_ask => "don't ask",
        .auto => "auto mode",
    };
}

/// footer mode part 前缀符号(对齐 cc PermissionMode.ts symbol)。
/// plan=⏸(U+23F8 PAUSE_ICON),其余非 default=⏵⏵。
pub fn modeSymbol(m: types.PermissionMode) []const u8 {
    return switch (m) {
        .default, .prompt => "",
        .plan => "\u{23f8}",
        .accept_edits, .bypass_permissions, .bypass, .dont_ask, .auto => "\u{23f5}\u{23f5}",
    };
}

/// footer mode part 着色(对齐 cc getModeColor 的 ansi 降级列):
/// plan→planMode(ansi:cyan=accent) / acceptEdits→autoAccept(ansi:magenta) /
/// bypass·dontAsk→error(ansi:red=danger) / auto→warning(ansi:yellow=warn)。
pub fn modeColor(theme: Theme, m: types.PermissionMode) []const u8 {
    return switch (m) {
        .default, .prompt => theme.dim,
        .plan => theme.accent,
        .accept_edits => theme.mode_accept,
        .bypass_permissions, .bypass, .dont_ask => theme.danger,
        .auto => theme.warn,
    };
}


/// token 数紧凑格式:<1K 原样;<1M "1.2K";>=1M "1.23M"。(从 statusline.zig 收敛)
pub fn formatTokens(buf: []u8, n: u64) []const u8 {
    if (n < 1000) {
        return std.fmt.bufPrint(buf, "{d}", .{n}) catch buf[0..0];
    } else if (n < 1_000_000) {
        const k = @as(f64, @floatFromInt(n)) / 1000.0;
        return std.fmt.bufPrint(buf, "{d:.1}K", .{k}) catch buf[0..0];
    } else {
        const m = @as(f64, @floatFromInt(n)) / 1_000_000.0;
        return std.fmt.bufPrint(buf, "{d:.2}M", .{m}) catch buf[0..0];
    }
}

test "formatTokens ranges" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0", formatTokens(&buf, 0));
    try std.testing.expectEqualStrings("999", formatTokens(&buf, 999));
    try std.testing.expectEqualStrings("1.0K", formatTokens(&buf, 1000));
    try std.testing.expectEqualStrings("12.3K", formatTokens(&buf, 12345));
    try std.testing.expectEqualStrings("1.23M", formatTokens(&buf, 1_234_567));
}

test "modeName covers all" {
    try std.testing.expectEqualStrings("default", modeName(.default));
    try std.testing.expectEqualStrings("plan", modeName(.plan));
    try std.testing.expectEqualStrings("bypassPermissions", modeName(.bypass_permissions));
}

test "modeTitle/Symbol: default 隐藏 mode part, 非 default 对齐 cc" {
    // default/prompt → 空 title(footer 据此跳过 mode part,对齐 cc isDefaultMode)
    try std.testing.expectEqualStrings("", modeTitle(.default));
    try std.testing.expectEqualStrings("", modeTitle(.prompt));
    try std.testing.expectEqualStrings("", modeSymbol(.default));
    // 非 default:title 小写人话 + symbol
    try std.testing.expectEqualStrings("plan mode", modeTitle(.plan));
    try std.testing.expectEqualStrings("accept edits", modeTitle(.accept_edits));
    try std.testing.expectEqualStrings("bypass permissions", modeTitle(.bypass_permissions));
    try std.testing.expectEqualStrings("don't ask", modeTitle(.dont_ask));
    try std.testing.expectEqualStrings("auto mode", modeTitle(.auto));
    // plan symbol = ⏸ (U+23F8);其余非 default = ⏵⏵
    try std.testing.expectEqualStrings("\u{23f8}", modeSymbol(.plan));
    try std.testing.expectEqualStrings("\u{23f5}\u{23f5}", modeSymbol(.accept_edits));
}

test "modeColor 对齐 cc getModeColor 的 ansi 降级映射" {
    const th = @import("../theme.zig").dark;
    // plan→planMode(cyan=accent) / acceptEdits→autoAccept(magenta=mode_accept) /
    // bypass·dontAsk→error(red=danger) / auto→warning(yellow=warn)
    try std.testing.expectEqualStrings(th.accent, modeColor(th, .plan));
    try std.testing.expectEqualStrings(th.mode_accept, modeColor(th, .accept_edits));
    try std.testing.expectEqualStrings(th.danger, modeColor(th, .bypass_permissions));
    try std.testing.expectEqualStrings(th.danger, modeColor(th, .dont_ask));
    try std.testing.expectEqualStrings(th.warn, modeColor(th, .auto));
    // acceptEdits 色应区别于 plan 色(确认 6 档不再全同 accent)
    try std.testing.expect(!std.mem.eql(u8, modeColor(th, .accept_edits), modeColor(th, .plan)));
    try std.testing.expect(!std.mem.eql(u8, modeColor(th, .bypass_permissions), modeColor(th, .plan)));
}
