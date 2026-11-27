//! 权限对话框(替代 permission/prompt.zig 的 13 行 stdin print)。
//!
//! TUI_COMPONENTS.md §5.1。
//!
//! 功能:
//! - 边框 + 标题 "Permission required"
//! - 工具名 + 参数(按框宽折行,超过 10 行折叠,Tab 展开/收起)
//! - 选项:[y] 允许一次 / [a] 以后都允许这个工具(文字按 guard 写规则的位置说范围) / [n] 拒绝 /
//!   [d] 本会话里一律拒绝这个工具;
//!   难回滚的 Bash 命令(hard_to_undo.zig)不给 [a],默认停在 [n]
//! - 键盘选择(y/a/n/d 直接选 + ↑↓ 移动高亮 + Enter 确认)
//! - 返回 PermissionChoice
//!
//! 分层:
//! - render():纯渲染 → []u8(可 snapshot 测试)
//! - promptLoop():render + 读键循环(调用方负责 raw mode 与终端接管,见 TuiBackend)

const std = @import("std");
const pfs = @import("metacodes-internal").platform.fs;
const platform_term = @import("metacodes-internal").platform.terminal;
const ansi = @import("../ansi.zig");
const theme_mod = @import("../theme.zig");
const layout = @import("../layout.zig");
const term = @import("../term.zig");
const reflow = @import("../reflow.zig");
const input_mod = @import("../../input.zig");
const util_time = @import("metacodes-internal").util.time;
const answer_gate = @import("answer_gate.zig");
const hard_to_undo = @import("hard_to_undo.zig");
const Theme = theme_mod.Theme;

/// PermissionChoice 已移到中立协议位置(core/protocol/);此处 re-export 保 UI 端引用兼容。
pub const PermissionChoice = @import("metacodes-internal").core.protocol.permission_choice.PermissionChoice;

pub const Option = struct {
    key: u8,
    choice: PermissionChoice,
};

const every_option = [_]Option{
    .{ .key = 'y', .choice = .allow_once },
    .{ .key = 'a', .choice = .allow_always },
    .{ .key = 'n', .choice = .deny_once },
    .{ .key = 'd', .choice = .deny_tool_session },
};

const options_without_always = [_]Option{
    .{ .key = 'y', .choice = .allow_once },
    .{ .key = 'n', .choice = .deny_once },
    .{ .key = 'd', .choice = .deny_tool_session },
};

pub fn optionsFor(always_offered: bool) []const Option {
    return if (always_offered) &every_option else &options_without_always;
}

pub fn firstSelected(always_offered: bool) usize {
    return if (always_offered) 0 else 1;
}

pub const AlwaysScope = enum { project, everywhere, session };

pub fn optionLabel(buf: []u8, choice: PermissionChoice, tool_name: []const u8, always: AlwaysScope) []const u8 {
    return switch (choice) {
        .allow_once => "Yes, once",
        .allow_always => switch (always) {
            .project => std.fmt.bufPrint(buf, "Yes, and allow {s} in this project from now on", .{tool_name}) catch "Yes, and allow it in this project from now on",
            .everywhere => std.fmt.bufPrint(buf, "Yes, and allow {s} everywhere from now on", .{tool_name}) catch "Yes, and allow it everywhere from now on",
            .session => std.fmt.bufPrint(buf, "Yes, and allow {s} for the rest of this session", .{tool_name}) catch "Yes, and allow it for the rest of this session",
        },
        .deny_once => "No",
        .deny_tool_session => std.fmt.bufPrint(buf, "No, and deny {s} for the rest of this session", .{tool_name}) catch "No, and deny it for the rest of this session",
    };
}

pub const max_folded_arg_lines = 10;

const arg_cols = 60;

const dialog_chrome_rows = 12;

pub const View = struct {
    selected: usize = 0,
    expanded: bool = false,
    always_offered: bool = true,
    always_scope: AlwaysScope = .project,
    rows: u16 = 24,
};

/// 渲染权限对话框为字符串。caller free。
pub fn render(alloc: std.mem.Allocator, th: Theme, tool_name: []const u8, args: []const u8, view: View) ![]u8 {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);

    try content.appendSlice(alloc, th.role_tool);
    try content.appendSlice(alloc, tool_name);
    try content.appendSlice(alloc, th.reset);
    try content.append(alloc, '\n');

    const arg_lines = try layout.wrapLines(alloc, args, arg_cols);
    defer alloc.free(arg_lines);
    const room = @max(max_folded_arg_lines, @as(usize, view.rows) -| dialog_chrome_rows);
    const shown = @min(arg_lines.len, if (view.expanded) room else max_folded_arg_lines);
    for (arg_lines[0..shown]) |line| {
        try content.appendSlice(alloc, th.dim);
        try content.appendSlice(alloc, line);
        try content.appendSlice(alloc, th.reset);
        try content.append(alloc, '\n');
    }
    if (arg_lines.len > max_folded_arg_lines) {
        try content.appendSlice(alloc, th.dim);
        if (!view.expanded) {
            try content.print(alloc, "tab to show all {d} lines", .{arg_lines.len});
        } else if (shown < arg_lines.len) {
            try content.print(alloc, "… {d} more lines · tab to show less", .{arg_lines.len - shown});
        } else {
            try content.appendSlice(alloc, "tab to show less");
        }
        try content.appendSlice(alloc, th.reset);
        try content.append(alloc, '\n');
    }
    try content.append(alloc, '\n');

    const opts = optionsFor(view.always_offered);
    for (opts, 0..) |opt, i| {
        if (i == view.selected) {
            try content.appendSlice(alloc, th.accent);
            try content.appendSlice(alloc, th.icon_arrow);
            try content.append(alloc, ' ');
        } else {
            const arrow_w = term.displayWidth(th.icon_arrow);
            var p: usize = 0;
            while (p < arrow_w + 1) : (p += 1) try content.append(alloc, ' ');
        }
        var label_buf: [192]u8 = undefined;
        try content.print(alloc, "[{c}] {s}", .{ opt.key, optionLabel(&label_buf, opt.choice, tool_name, view.always_scope) });
        if (i == view.selected) try content.appendSlice(alloc, th.reset);
        if (i + 1 < opts.len) try content.append(alloc, '\n');
    }

    return try layout.drawBox(alloc, th, content.items, .{
        .title = "Permission required",
        .width = arg_cols + 4,
        .padding = 1,
    });
}

/// 渲染 + 读键循环(不管 raw mode / 终端接管——调用方负责)。
/// TuiBackend 终端接管(停 watcher+持锁)后调,生成期的 raw mode 由 loop 进好:对话框自己不再进
/// 一层 raw mode(嵌套的 restoreMode 会把外层开着的括号粘贴、win32-input-mode 一起关掉)。
/// out_fd 输出(TuiBackend 接管用 stderr=2 与 region 同流)。
/// 重画用 render 实际行数(不再硬编码 8——参数长会折行变多行,硬编码会错位)。
/// 回顶按终端现在的宽度数上一帧占的行:框比终端宽时画的那一刻就折了行,终端变窄后
/// 又会把每行重排成多行(reflow.zig);回顶后 ED 0 清掉旧帧多出的行。
pub fn promptLoop(alloc: std.mem.Allocator, th: Theme, in_fd: c_int, out_fd: c_int, tool_name: []const u8, args: []const u8, always_scope: AlwaysScope) ?PermissionChoice {
    return answerLoop(alloc, th, in_fd, out_fd, tool_name, args, always_scope, .interactive);
}

fn promptLoopTimed(alloc: std.mem.Allocator, th: Theme, in_fd: c_int, out_fd: c_int, tool_name: []const u8, args: []const u8, timing: answer_gate.Timing) ?PermissionChoice {
    return answerLoop(alloc, th, in_fd, out_fd, tool_name, args, .project, timing);
}

fn answerLoop(alloc: std.mem.Allocator, th: Theme, in_fd: c_int, out_fd: c_int, tool_name: []const u8, args: []const u8, always_scope: AlwaysScope, timing: answer_gate.Timing) ?PermissionChoice {
    const always_offered = !hard_to_undo.isHardToUndo(alloc, tool_name, args);
    const choices = optionsFor(always_offered);
    var view: View = .{ .selected = firstSelected(always_offered), .always_offered = always_offered, .always_scope = always_scope };
    var drawn: ?reflow.Anchor = null;
    const reflows = term.reflowFromEnv();
    var parser = input_mod.KeyParser{};
    var gate = answer_gate.Gate.init(timing, util_time.nowNs());
    while (true) {
        const size = term.getSize(out_fd);
        const cols: u16 = if (size) |known| known.cols else 80;
        view.rows = if (size) |known| known.rows else 24;
        if (drawn) |anchor| {
            var up_buf: [16]u8 = undefined;
            writeAll(out_fd, ansi.cursor.up(anchor.climb(cols, reflows), &up_buf));
            writeAll(out_fd, "\r");
            writeAll(out_fd, ansi.clear.to_end_of_screen);
        }
        const frame = render(alloc, th, tool_name, args, view) catch return .deny_once;
        defer alloc.free(frame);
        writeAll(out_fd, frame);
        drawn = reflow.Anchor.atEnd(frame, cols);

        const key = switch (input_mod.readKey(in_fd, &parser)) {
            .key => |key| key,
            .interrupted => continue,
            .closed => return .deny_once,
        };
        switch (key) {
            .ctrl_c => return .deny_once,
            .paste_begin => {
                if (skipPaste(in_fd, &parser)) |choice| return choice;
                gate.close(util_time.nowNs());
                continue;
            },
            .mouse, .cursor_position => continue,
            else => {},
        }
        if (!gate.admits(util_time.nowNs())) continue;
        if (gate.pasteFollows(in_fd, &parser)) {
            if (skipUnmarkedPaste(in_fd, &parser, &gate)) |choice| return choice;
            gate.close(util_time.nowNs());
            continue;
        }
        switch (key) {
            .char => |c| switch (c) {
                'y', 'Y' => return .allow_once,
                'a', 'A' => if (always_offered) return .allow_always else gate.close(util_time.nowNs()),
                'n', 'N' => return .deny_once,
                'd', 'D' => return .deny_tool_session,
                else => gate.close(util_time.nowNs()),
            },
            .backspace => gate.close(util_time.nowNs()),
            .enter => return choices[view.selected].choice,
            .up => view.selected = if (view.selected == 0) choices.len - 1 else view.selected - 1,
            .down => view.selected = (view.selected + 1) % choices.len,
            .tab => view.expanded = !view.expanded,
            else => {},
        }
    }
}

fn skipUnmarkedPaste(in_fd: c_int, parser: *input_mod.KeyParser, gate: *const answer_gate.Gate) ?PermissionChoice {
    while (gate.pasteFollows(in_fd, parser)) {
        switch (input_mod.readKey(in_fd, parser)) {
            .key => |key| switch (key) {
                .ctrl_c => return .deny_once,
                .paste_begin => if (skipPaste(in_fd, parser)) |choice| return choice,
                else => {},
            },
            .interrupted => {},
            .closed => return .deny_once,
        }
    }
    return null;
}

fn skipPaste(in_fd: c_int, parser: *input_mod.KeyParser) ?PermissionChoice {
    while (true) {
        switch (input_mod.readKey(in_fd, parser)) {
            .key => |key| switch (key) {
                .paste_end => return null,
                .ctrl_c => return .deny_once,
                else => {},
            },
            .interrupted => {},
            .closed => return .deny_once,
        }
    }
}

fn writeAll(fd: c_int, bytes: []const u8) void {
    @import("../screen_mirror.zig").feed(fd, bytes);
    _ = pfs.writeAll(fd, bytes); // resize 打断(EINTR)重试,不丢半帧
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const capture = @import("../test_capture.zig");

test "render: the title, the tool, its arguments and the four answers saying what they allow, with no ANSI in monochrome" {
    const th = theme_mod.monochrome;
    const s = try render(testing.allocator, th, "Bash", "{\"command\":\"git status\"}", .{});
    defer testing.allocator.free(s);

    try capture.expectContains(s, "Permission required");
    try capture.expectContains(s, "Bash");
    try capture.expectContains(s, "git status");
    try capture.expectContains(s, "[y] Yes, once");
    try capture.expectContains(s, "[a] Yes, and allow Bash in this project from now on");
    try capture.expectContains(s, "[n] No");
    try capture.expectContains(s, "[d] No, and deny Bash for the rest of this session");
    try testing.expect(std.mem.indexOf(u8, s, "tab to show") == null);
    try capture.expectNoAnsi(s);
}

test "render: the always answer names where the rule goes: this project, everywhere, or only this session" {
    const th = theme_mod.monochrome;
    const cases = [_]struct { scope: AlwaysScope, label: []const u8 }{
        .{ .scope = .project, .label = "[a] Yes, and allow Edit in this project from now on" },
        .{ .scope = .everywhere, .label = "[a] Yes, and allow Edit everywhere from now on" },
        .{ .scope = .session, .label = "[a] Yes, and allow Edit for the rest of this session" },
    };
    for (cases) |c| {
        const s = try render(testing.allocator, th, "Edit", "{\"file_path\":\"/x\"}", .{ .always_scope = c.scope });
        defer testing.allocator.free(s);
        try capture.expectContains(s, c.label);
    }
    const everywhere = try render(testing.allocator, th, "Edit", "{}", .{ .always_scope = .everywhere });
    defer testing.allocator.free(everywhere);
    try testing.expect(std.mem.indexOf(u8, everywhere, "in this project") == null);
}

test "render: dark 含 ANSI + 高亮箭头" {
    const th = theme_mod.dark;
    const s = try render(testing.allocator, th, "Write", "{\"file_path\":\"/x\"}", .{});
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "\x1b") != null);
    try capture.expectContains(s, "→ [y]");
}

test "render: selected=2 高亮第三项 No" {
    const th = theme_mod.monochrome;
    const s = try render(testing.allocator, th, "Bash", "rm", .{ .selected = 2 });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "-> [n] No");
}

test "render: long arguments are shown whole, wrapped at the box width" {
    const th = theme_mod.monochrome;
    const long = "{\"command\":\"this is a very long command that definitely exceeds sixty columns for sure yes, and then some more\"}";
    const s = try render(testing.allocator, th, "Bash", long, .{});
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "…") == null);
    try capture.expectContains(s, "for sure yes");
    try capture.expectContains(s, "then some more");
}

fn argsOfLines(buf: []u8, n: usize) []const u8 {
    var len: usize = 0;
    for (0..n) |i| {
        const line = std.fmt.bufPrint(buf[len..], "{d:0>2}{s}", .{ i, "-" ** 58 }) catch unreachable;
        len += line.len;
    }
    return buf[0..len];
}

test "render: more than ten lines of arguments fold behind a tab hint, and expanding shows them all when the screen holds them" {
    const th = theme_mod.monochrome;
    var buf: [60 * 30]u8 = undefined;
    const args = argsOfLines(&buf, 25);
    const folded = try render(testing.allocator, th, "Bash", args, .{ .rows = 50 });
    defer testing.allocator.free(folded);
    try capture.expectContains(folded, "09-");
    try testing.expect(std.mem.indexOf(u8, folded, "10-") == null);
    try capture.expectContains(folded, "tab to show all 25 lines");

    const expanded = try render(testing.allocator, th, "Bash", args, .{ .rows = 50, .expanded = true });
    defer testing.allocator.free(expanded);
    try capture.expectContains(expanded, "24-");
    try capture.expectContains(expanded, "tab to show less");
    try testing.expect(std.mem.indexOf(u8, expanded, "more lines") == null);

    const short_screen = try render(testing.allocator, th, "Bash", args, .{ .rows = 24, .expanded = true });
    defer testing.allocator.free(short_screen);
    try capture.expectContains(short_screen, "11-");
    try testing.expect(std.mem.indexOf(u8, short_screen, "12-") == null);
    try capture.expectContains(short_screen, "… 13 more lines · tab to show less");
}

test "render: a call that is hard to undo offers no always and starts on No" {
    const th = theme_mod.monochrome;
    const s = try render(testing.allocator, th, "Bash", "{\"command\":\"rm -rf build\"}", .{ .always_offered = false, .selected = firstSelected(false) });
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "[a]") == null);
    try capture.expectContains(s, "-> [n] No");
    try capture.expectContains(s, "[d] No, and deny Bash for the rest of this session");
}

test "options: four answers, or three without always, each with its choice" {
    try testing.expectEqual(@as(usize, 4), optionsFor(true).len);
    try testing.expectEqual(PermissionChoice.allow_once, optionsFor(true)[0].choice);
    try testing.expectEqual(PermissionChoice.allow_always, optionsFor(true)[1].choice);
    try testing.expectEqual(PermissionChoice.deny_once, optionsFor(true)[2].choice);
    try testing.expectEqual(PermissionChoice.deny_tool_session, optionsFor(true)[3].choice);
    try testing.expectEqual(@as(usize, 3), optionsFor(false).len);
    for (optionsFor(false)) |opt| try testing.expect(opt.choice != .allow_always);
    try testing.expectEqual(PermissionChoice.deny_once, optionsFor(false)[firstSelected(false)].choice);
    try testing.expectEqual(PermissionChoice.allow_once, optionsFor(true)[firstSelected(true)].choice);
}

test "VISUAL demo (打印到 stderr,看真实渲染)" {
    if (std.c.getenv("TUI_DEMO") == null) return error.SkipZigTest;
    const s = try render(testing.allocator, theme_mod.dark, "Bash", "{\"command\":\"rm -rf /tmp/build\",\"timeout\":30000}", .{});
    defer testing.allocator.free(s);
    std.debug.print("\n{s}\n", .{s});
}

test "promptLoop: a call that is hard to undo answers Enter with No, has no a, and Up reaches Yes, once" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const sink = pfs.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    try testing.expect(sink >= 0);
    defer _ = pfs.close(sink);
    const Later = struct {
        fn send(fd: c_int, bytes: []const u8) void {
            @import("metacodes-internal").platform.sync.sleepMs(300);
            _ = pfs.writeAll(fd, bytes);
            _ = std.c.close(fd);
        }
    };
    const cases = [_]struct { now: []const u8, later: []const u8, choice: PermissionChoice }{
        .{ .now = "\r", .later = "", .choice = .deny_once },
        .{ .now = "a", .later = "y", .choice = .allow_once },
        .{ .now = "\x1b[A\r", .later = "", .choice = .allow_once },
        .{ .now = "\x1b[B\r", .later = "", .choice = .deny_tool_session },
    };
    for (cases) |c| {
        var fds: [2]std.c.fd_t = undefined;
        try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
        defer _ = std.c.close(fds[0]);
        try testing.expect(pfs.writeAll(fds[1], c.now));
        const thread = try std.Thread.spawn(.{}, Later.send, .{ fds[1], c.later });
        const got = promptLoopTimed(testing.allocator, theme_mod.monochrome, fds[0], sink, "Bash", "{\"command\":\"git push origin main\"}", .immediate);
        thread.join();
        try testing.expectEqual(c.choice, got.?);
    }
}

test "promptLoop: Tab shows the rest of long arguments, and Tab again folds them" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const sync = @import("metacodes-internal").platform.sync;
    const Screen = struct {
        bytes: std.ArrayList(u8) = .empty,
        fn take(self: *@This(), fd: c_int) void {
            var chunk: [4096]u8 = undefined;
            while (true) {
                const n = pfs.read(fd, &chunk);
                if (n == 0) return;
                if (n < 0) continue;
                self.bytes.appendSlice(testing.allocator, chunk[0..@intCast(n)]) catch return;
            }
        }
        fn typeKeys(fd: c_int) void {
            for ([_][]const u8{ "\t", "\t", "n" }) |key| {
                sync.sleepMs(150);
                _ = pfs.writeAll(fd, key);
            }
            sync.sleepMs(300);
            _ = std.c.close(fd);
        }
    };
    var out: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&out));
    defer _ = std.c.close(out[0]);
    var keys: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&keys));
    defer _ = std.c.close(keys[0]);
    var screen: Screen = .{};
    defer screen.bytes.deinit(testing.allocator);
    const reader = try std.Thread.spawn(.{}, Screen.take, .{ &screen, out[0] });
    const typist = try std.Thread.spawn(.{}, Screen.typeKeys, .{keys[1]});
    var buf: [60 * 30]u8 = undefined;
    const got = promptLoopTimed(testing.allocator, theme_mod.monochrome, keys[0], out[1], "Write", argsOfLines(&buf, 25), .immediate);
    _ = std.c.close(out[1]);
    typist.join();
    reader.join();
    try testing.expectEqual(PermissionChoice.deny_once, got.?);
    const written = screen.bytes.items;
    const first = std.mem.indexOf(u8, written, "tab to show all") orelse return error.TestUnexpectedResult;
    const shown = std.mem.indexOfPos(u8, written, first, "tab to show less") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOfPos(u8, written, shown, "tab to show all") != null);
    try testing.expect(std.mem.indexOfPos(u8, written, first, "11-") != null);
}

test "promptLoop 读 Windows 控制台送来的按键记录:y、n、Ctrl+C 各是一个回答" {
    // win32-input-mode 开着时每个键都是一条记录(控制台逐字符排进队列,sendChars)。对话框读的是
    // 还原后的键;读原始字节时一个也认不出,工具调用一直等着(#388 审查)。
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var console = try @import("metacodes-internal").platform.test_support.PrivateConsole.begin();
    defer console.end();
    defer platform_term.resetConsoleInputForTesting();
    platform_term.decodeKeyRecords();
    const sink = pfs.open("NUL", .{ .ACCMODE = .WRONLY }, 0);
    try testing.expect(sink >= 0);
    defer _ = pfs.close(sink);
    const cases = [_]struct { records: []const u8, choice: PermissionChoice }{
        .{ .records = "\x1b[89;21;121;1;32;1_\x1b[89;21;121;0;32;1_", .choice = .allow_once },
        .{ .records = "\x1b[78;49;110;1;32;1_\x1b[78;49;110;0;32;1_", .choice = .deny_once },
        .{ .records = "\x1b[17;29;0;1;40;1_\x1b[67;46;3;1;40;1_\x1b[67;46;3;0;40;1_\x1b[17;29;0;0;32;1_", .choice = .deny_once },
    };
    for (cases) |c| {
        try console.sendChars(c.records);
        try testing.expectEqual(c.choice, promptLoopTimed(testing.allocator, theme_mod.dark, 0, sink, "Write", "{}", .immediate).?);
    }
}

test "promptLoop with no answer delay reads whole keys: Ctrl+C sent as CSI u refuses, keys written together each count, a paste never answers" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const sink = pfs.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    try testing.expect(sink >= 0);
    defer _ = pfs.close(sink);
    const Later = struct {
        fn send(fd: c_int, bytes: []const u8) void {
            @import("metacodes-internal").platform.sync.sleepMs(300);
            _ = pfs.writeAll(fd, bytes);
            _ = std.c.close(fd);
        }
    };
    const cases = [_]struct { now: []const u8, later: []const u8, choice: PermissionChoice }{
        .{ .now = "\x1b[99;5u", .later = "y", .choice = .deny_once },
        .{ .now = "\x1b[27u", .later = "d", .choice = .deny_tool_session },
        .{ .now = "\x1b[B\x1b[B\x1b[B\r", .later = "y", .choice = .deny_tool_session },
        .{ .now = "\x1b[200~yes\x1b[201~", .later = "d", .choice = .deny_tool_session },
        .{ .now = "\x1b[200~a\x03", .later = "\x1b[201~d", .choice = .deny_once },
    };
    for (cases) |c| {
        var fds: [2]std.c.fd_t = undefined;
        try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
        defer _ = std.c.close(fds[0]);
        try testing.expect(pfs.writeAll(fds[1], c.now));
        const thread = try std.Thread.spawn(.{}, Later.send, .{ fds[1], c.later });
        const got = promptLoopTimed(testing.allocator, theme_mod.monochrome, fds[0], sink, "Write", "{}", .immediate);
        thread.join();
        try testing.expectEqual(c.choice, got.?);
    }
}

test "promptLoop answers only a key that follows a quiet spell: keys typed as the box opens, typing that goes on and a paste without markers never answer" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const sink = pfs.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    try testing.expect(sink >= 0);
    defer _ = pfs.close(sink);
    const Step = struct { after_ms: u32, bytes: []const u8 };
    const Script = struct {
        fn play(fd: c_int, steps: []const Step) void {
            for (steps) |step| {
                @import("metacodes-internal").platform.sync.sleepMs(step.after_ms);
                _ = pfs.writeAll(fd, step.bytes);
            }
            @import("metacodes-internal").platform.sync.sleepMs(300);
            _ = std.c.close(fd);
        }
    };
    const timing: answer_gate.Timing = .{ .quiet_ms = 200, .paste_gap_ms = answer_gate.Timing.interactive.paste_gap_ms };
    const cases = [_]struct { steps: []const Step, choice: PermissionChoice }{
        .{ .steps = &.{ .{ .after_ms = 0, .bytes = "a" }, .{ .after_ms = 450, .bytes = "d" } }, .choice = .deny_tool_session },
        .{ .steps = &.{ .{ .after_ms = 0, .bytes = "\r" }, .{ .after_ms = 450, .bytes = "d" } }, .choice = .deny_tool_session },
        .{ .steps = &.{
            .{ .after_ms = 0, .bytes = "t" },   .{ .after_ms = 20, .bytes = "e" }, .{ .after_ms = 20, .bytes = "a" },
            .{ .after_ms = 20, .bytes = "y" },  .{ .after_ms = 20, .bytes = "n" }, .{ .after_ms = 20, .bytes = "\r" },
            .{ .after_ms = 450, .bytes = "d" },
        }, .choice = .deny_tool_session },
        .{ .steps = &.{ .{ .after_ms = 450, .bytes = "say hi\r" }, .{ .after_ms = 450, .bytes = "d" } }, .choice = .deny_tool_session },
        .{ .steps = &.{ .{ .after_ms = 450, .bytes = "yes\r" }, .{ .after_ms = 450, .bytes = "d" } }, .choice = .deny_tool_session },
        .{ .steps = &.{ .{ .after_ms = 450, .bytes = "t" }, .{ .after_ms = 20, .bytes = "y" }, .{ .after_ms = 450, .bytes = "d" } }, .choice = .deny_tool_session },
        .{ .steps = &.{.{ .after_ms = 450, .bytes = "y" }}, .choice = .allow_once },
        .{ .steps = &.{ .{ .after_ms = 450, .bytes = "\x1b[B" }, .{ .after_ms = 60, .bytes = "\r" } }, .choice = .allow_always },
        .{ .steps = &.{ .{ .after_ms = 0, .bytes = "\x1b[99;5u" }, .{ .after_ms = 450, .bytes = "y" } }, .choice = .deny_once },
    };
    for (cases) |c| {
        var fds: [2]std.c.fd_t = undefined;
        try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
        defer _ = std.c.close(fds[0]);
        const thread = try std.Thread.spawn(.{}, Script.play, .{ fds[1], c.steps });
        const got = promptLoopTimed(testing.allocator, theme_mod.monochrome, fds[0], sink, "Write", "{}", timing);
        thread.join();
        try testing.expectEqual(c.choice, got.?);
    }
}

test {
    _ = answer_gate;
    _ = hard_to_undo;
}
