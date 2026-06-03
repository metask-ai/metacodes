//! StatusBar widget —— RenderRegion 的状态栏(1 行)。
//!
//! 两个形态(复刻 Claude Code 观感):
//! - **idle**(输入期):`{model} · {mode} · {N}tok · ${cost}[· Nbg][· Ncron]`
//!   等价于旧 statusline.render 的内容,被 RenderRegion 吸收。
//! - **generating**(生成期):`{spinner} {verb}… ({Xs} · ↑{in} ↓{out} · ${cost} · esc to interrupt)`
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
        const cost = u.costUsd(app.config.model);
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
            app.config.model,
            mode_str,
            tok_str,
            cost,
            extra,
            theme.reset,
        });
        return 1;
    }

    /// generating 形态:写一行(spinner + verb + 计时 + token + 中断提示),返回 1。
    /// max_w = 最大显示宽(= inner_w);超宽按显示宽截断(跳过 ANSI SGR 不计宽),
    /// 防 DECAWM 折行使生成期区实际行数 > R 导致 UP(R-1) 错位。
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
        const u = app.usage;
        const cost = u.costUsd(app.config.model);
        const secs = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        const fr = verbs.frame(frame_idx, use_unicode);

        var in_buf: [16]u8 = undefined;
        var out_buf: [16]u8 = undefined;
        const in_str = formatTokens(&in_buf, u.input_tokens);
        const out_str = formatTokens(&out_buf, u.output_tokens);

        // 当前工具段(执行中才显示):` · ⚒ <tool> (X.Ys)`。
        var tool_buf: [80]u8 = undefined;
        const tool_seg: []const u8 = if (current_tool.len > 0)
            std.fmt.bufPrint(&tool_buf, " · {s} {s} ({d:.1}s)", .{
                if (use_unicode) "⚒" else "*",
                current_tool,
                @as(f64, @floatFromInt(tool_ms)) / 1000.0,
            }) catch ""
        else
            "";

        // token 速率段:长 turn(>30s)才显示,对齐 cc `↓7.9k tokens` 速率语义。
        // 速率 = 输出 token / 耗时秒(输出 token 才是"生成"速率)。
        var rate_buf: [24]u8 = undefined;
        const rate_seg: []const u8 = if (elapsed_ms > 30_000 and secs > 0) blk: {
            const rate = @as(f64, @floatFromInt(u.output_tokens)) / secs;
            var rb: [16]u8 = undefined;
            const rstr = formatTokens(&rb, @intFromFloat(@max(rate, 0)));
            break :blk std.fmt.bufPrint(&rate_buf, " · {s} tok/s", .{rstr}) catch "";
        } else "";

        // 先格式化到栈 buffer,再按显示宽截断输出(跳过 SGR 转义)。
        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}{s} {s}…{s}{s} ({d:.0}s · ↑{s} ↓{s}{s} · ${d:.4}{s} · esc to interrupt){s}", .{
            theme.accent,
            fr,
            verb,
            theme.reset,
            theme.dim,
            secs,
            in_str,
            out_str,
            rate_seg,
            cost,
            tool_seg,
            theme.reset,
        }) catch {
            // 极端超长 → 退化为最简 spinner。
            try writer.print("{s}{s}{s}", .{ theme.accent, fr, theme.reset });
            return 1;
        };
        try writeTruncated(writer, line, max_w);
        return 1;
    }

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
