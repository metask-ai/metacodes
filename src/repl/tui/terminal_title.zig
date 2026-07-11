//! 终端 tab 标题状态——在标签栏/窗口标题一眼看到本 session 在干嘛。
//!
//! 对齐 codex `codex-rs/tui/src/terminal_title.rs`(参考实现)。机制:向 stdout 写一条
//! OSC 0 序列 `\x1b]0;<title>\x07`,内容随 REPL 状态切换(idle / working / 需要输入)。
//!
//! **不读取/不恢复**终端原标题(跨终端不可移植);退出时清空我们写的标题(clear)。
//!
//! **消毒**:标题从不可信来源拼装(cwd/model 文本),写进 OSC 前必须剥离:
//! - 控制字符(会截断/重塑转义序列)
//! - bidi/不可见格式码点(Trojan-Source 式视觉重排/隐藏)
//! - 冗余空白(折叠成单空格)
//! 并按码点数上限截断。逻辑与消毒范围逐条对齐 codex。

const std = @import("std");
const app_mod = @import("../../app.zig");

/// REPL 三态:空闲等输入 / 生成中 / 需要用户操作(权限·问题·计划审批)。
pub const Phase = enum { idle, working, action_required };

/// 标题码点数上限(多数终端超几百字符会截断;留 OSC 框架字节余量)。对齐 codex 240。
const MAX_TITLE_CHARS: usize = 240;

/// 从 App 组标题并写入 tab(仅 tty + 未 opt-out)。REPL 状态切换点调用。
pub fn setFromApp(app: *const app_mod.App, phase: Phase) void {
    var buf: [768]u8 = undefined;
    set(compose(&buf, app, phase));
}

/// 写一条消毒后的 OSC 0 标题。非 tty / 已 opt-out / 消毒后空 → no-op。
pub fn set(title: []const u8) void {
    if (!enabled()) return;
    var sbuf: [MAX_TITLE_CHARS * 4]u8 = undefined;
    const clean = sanitize(&sbuf, title);
    if (clean.len == 0) return; // 消毒后全空:不清标题(清不清是上层策略),直接 no-op
    var out: [MAX_TITLE_CHARS * 4 + 8]u8 = undefined;
    const seq = buildSequence(&out, clean) orelse return;
    writeAll(1, seq);
}

/// OSC 0 框架:`\x1b]0;<sanitized>\x07`。一次组好整条再单次 write(避免多段写被日志切入)。
/// BEL(\x07)结尾对齐 crossterm/codex(某些标题集成对 ST 终止符处理不一致)。
fn buildSequence(out: []u8, sanitized: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(out, "\x1b]0;{s}\x07", .{sanitized}) catch null;
}

/// 清空我们写的标题(退出 REPL 时)。不恢复 shell/前一个程序设的原标题(不可移植)。
pub fn clear() void {
    if (std.c.isatty(1) == 0) return;
    writeAll(1, "\x1b]0;\x07");
}

/// 门控:stdout 是 tty 且未经 METACODES_NO_TERMINAL_TITLE 关闭。
fn enabled() bool {
    if (std.c.isatty(1) == 0) return false;
    if (std.c.getenv("METACODES_NO_TERMINAL_TITLE") != null) return false;
    return true;
}

/// 组标题:`<marker><basename> — <status>`。cwd basename 作为 session 身份(标签栏区分多开),
/// 加一个状态词/标记。marker 用广泛可渲染的符号;渲染不出也只是退化,不影响语义。
fn compose(buf: []u8, app: *const app_mod.App, phase: Phase) []const u8 {
    return composeTitle(buf, dirLabel(app), phase);
}

/// 纯组装(dir + phase → 标题文本),不依赖 App,便于直接单测三态输出。
fn composeTitle(buf: []u8, dir: []const u8, phase: Phase) []const u8 {
    return switch (phase) {
        .idle => std.fmt.bufPrint(buf, "{s} — metacodes", .{dir}) catch dir,
        .working => std.fmt.bufPrint(buf, "✳ {s} — working", .{dir}) catch dir,
        .action_required => std.fmt.bufPrint(buf, "● {s} — needs input", .{dir}) catch dir,
    };
}

fn dirLabel(app: *const app_mod.App) []const u8 {
    const cwd = app.cwd_abs orelse return "metacodes";
    return basename(cwd);
}

/// 路径最后一段(去尾斜杠)。空 → "metacodes";纯 "/" → "/"。
fn basename(path: []const u8) []const u8 {
    if (path.len == 0) return "metacodes";
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    if (end == 0) return "/";
    var start = end;
    while (start > 0 and path[start - 1] != '/') start -= 1;
    return path[start..end];
}

/// 消毒:剥控制符/不可见格式码点,折叠空白为单空格,截断到 MAX_TITLE_CHARS 码点。
/// 输入非法 UTF-8 → 返回空(调用方 no-op)。逻辑对齐 codex sanitize_terminal_title。
fn sanitize(out: []u8, title: []const u8) []const u8 {
    var w: usize = 0;
    var chars: usize = 0;
    var pending_space = false;
    const view = std.unicode.Utf8View.init(title) catch return out[0..0];
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (isTitleWhitespace(cp)) {
            pending_space = (w != 0); // 已有内容才记待插空格 → 顺带吃掉前导空白
            continue;
        }
        if (isDisallowed(cp)) continue;
        if (pending_space) {
            // 只有还能容下"空格+至少一个可见字符"时才插空格(截断偏向可见字符)。
            if (MAX_TITLE_CHARS - chars > 1) {
                out[w] = ' ';
                w += 1;
                chars += 1;
            }
            pending_space = false;
        }
        if (chars >= MAX_TITLE_CHARS) break;
        const n = std.unicode.utf8Encode(cp, out[w..]) catch continue;
        w += n;
        chars += 1;
    }
    return out[0..w];
}

/// 标题语境下的空白(ASCII + 常见 Unicode 空白)。先于 isDisallowed 判 → \t\n\r 折叠成空格而非丢弃。
fn isTitleWhitespace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// 应丢弃的码点:C0/C1 控制符 + Trojan-Source 式 bidi/不可见格式符(逐条对齐 codex)。
fn isDisallowed(cp: u21) bool {
    if (cp < 0x20 or (cp >= 0x7F and cp <= 0x9F)) return true; // C0 + C1 控制符
    return switch (cp) {
        0x00AD, 0x034F, 0x061C, 0x180E, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F, 0xFE00...0xFE0F, 0xFEFF, 0xFFF9...0xFFFB, 0x1BCA0...0x1BCA3, 0xE0100...0xE01EF => true,
        else => false,
    };
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8) void {
    var total: usize = 0;
    while (total < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + total, bytes.len - total);
        if (n <= 0) return; // 写不进就放弃(标题非关键)
        total += @as(usize, @intCast(n));
    }
}

test "sanitize collapses whitespace and strips controls" {
    var buf: [512]u8 = undefined;
    const s = sanitize(&buf, "  Project\t|\nWorking\x1b\x07\u{009D}\u{009C} |  Thread  ");
    try std.testing.expectEqualStrings("Project | Working | Thread", s);
}

test "sanitize strips invisible and bidi format chars" {
    var buf: [512]u8 = undefined;
    const s = sanitize(&buf, "Pro\u{202E}j\u{2066}e\u{200F}c\u{061C}t\u{200B} \u{FEFF}T\u{2060}itle");
    try std.testing.expectEqualStrings("Project Title", s);
}

test "sanitize truncates at max chars" {
    var buf: [MAX_TITLE_CHARS * 4]u8 = undefined;
    var input: [MAX_TITLE_CHARS + 10]u8 = undefined;
    @memset(&input, 'a');
    const s = sanitize(&buf, &input);
    try std.testing.expectEqual(MAX_TITLE_CHARS, s.len);
}

test "sanitize prefers visible char over pending space at boundary" {
    var buf: [MAX_TITLE_CHARS * 4]u8 = undefined;
    var input: [MAX_TITLE_CHARS + 1]u8 = undefined;
    @memset(input[0 .. MAX_TITLE_CHARS - 1], 'a');
    input[MAX_TITLE_CHARS - 1] = ' ';
    input[MAX_TITLE_CHARS] = 'b';
    const s = sanitize(&buf, &input);
    try std.testing.expectEqual(MAX_TITLE_CHARS, s.len);
    try std.testing.expectEqual(@as(u8, 'b'), s[s.len - 1]);
}

test "buildSequence frames OSC 0 with BEL terminator" {
    var buf: [64]u8 = undefined;
    const seq = buildSequence(&buf, "hello").?;
    try std.testing.expectEqualStrings("\x1b]0;hello\x07", seq);
}

test "sanitize + buildSequence end-to-end (bytes actually emitted)" {
    var sbuf: [512]u8 = undefined;
    const clean = sanitize(&sbuf, "cc-zig — working\x07\n");
    var obuf: [512]u8 = undefined;
    const seq = buildSequence(&obuf, clean).?;
    // \x07 被消毒剥除,换行折叠;最终序列只有一个结尾 BEL。
    try std.testing.expectEqualStrings("\x1b]0;cc-zig — working\x07", seq);
}

test "composeTitle renders all three phases" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("cc-zig — metacodes", composeTitle(&buf, "cc-zig", .idle));
    try std.testing.expectEqualStrings("✳ cc-zig — working", composeTitle(&buf, "cc-zig", .working));
    try std.testing.expectEqualStrings("● cc-zig — needs input", composeTitle(&buf, "cc-zig", .action_required));
}

test "basename extracts last path segment" {
    try std.testing.expectEqualStrings("cc-zig", basename("/Users/david/prj/cc-t2z/cc-zig"));
    try std.testing.expectEqualStrings("cc-zig", basename("/Users/david/prj/cc-t2z/cc-zig/"));
    try std.testing.expectEqualStrings("metacodes", basename(""));
    try std.testing.expectEqualStrings("root", basename("root"));
}
