//! REPL 主循环（M4 完整版）。
//!
//! 行为：
//! - tty 输入：raw mode + LineEditor（↑↓←→/Home/End/Ctrl+A/E/U/K）+ History + Markdown 渲染
//! - 非 tty 输入（pipe / 重定向 / CI）：退化到行缓冲模式（保持 M0 行为，便于自动化测试）
//! - 多行：行尾 `\` 续行；独占 `"""` 切换块模式（M4.4 Accumulator）
//! - 命令：/help /clear /tools /exit /retry /compact /history
//! - Ctrl+C：输入阶段 → 清 buffer（ISIG=false 让字节 0x03 落到 LineEditor）；生成阶段 → SIGINT → app.abort

const std = @import("std");
const posix = std.posix;
const app_mod = @import("../app.zig");
const tools = @import("../tools.zig");
const agent_loop = @import("../core/agent_loop.zig");
const input = @import("input.zig");
const history_mod = @import("history.zig");
const multiline_mod = @import("multiline.zig");
const render_mod = @import("render.zig");

pub fn run(app: *app_mod.App, allocator: std.mem.Allocator) !void {
    std.debug.print("Metacode Super\nType your message or /help for commands\n\n", .{});

    var writer = DebugWriter{};
    var history = history_mod.History.init(allocator);
    defer history.deinit();

    // 历史文件路径：~/.cc-zig/history
    const hist_path = try historyPath(allocator);
    defer allocator.free(hist_path);
    history.loadFromFile(hist_path) catch {};
    defer history.saveToFile(hist_path) catch {};

    const stdin_fd: std.c.fd_t = 0;
    const tty = std.c.isatty(stdin_fd) != 0;

    while (true) {
        std.debug.print("> ", .{});

        const line = if (tty)
            readLineRaw(stdin_fd, allocator, &history) catch |err| switch (err) {
                error.Eof => {
                    std.debug.print("Goodbye!\n", .{});
                    break;
                },
                error.ExitRequested => {
                    std.debug.print("\nGoodbye!\n", .{});
                    break;
                },
                error.Cancelled => {
                    std.debug.print("^C\n", .{});
                    continue;
                },
                else => return err,
            }
        else
            readLineBuffered(allocator) catch {
                std.debug.print("Goodbye!\n", .{});
                break;
            };
        defer allocator.free(line);

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) {
            if (line.len == 0) {
                std.debug.print("Goodbye!\n", .{});
                break;
            }
            continue;
        }

        // 命令派发（不走多行累加）
        if (std.mem.eql(u8, trimmed, "/exit") or std.mem.eql(u8, trimmed, "exit")) {
            std.debug.print("Goodbye!\n", .{});
            break;
        }
        if (std.mem.eql(u8, trimmed, "/help")) {
            std.debug.print(
                \\Commands:
                \\  /help      Show this help
                \\  /clear     Clear screen
                \\  /tools     List available tools
                \\  /skills    List installed skills
                \\  /history   Show recent commands
                \\  /retry     Resend the last user message
                \\  /compact   Compact oldest messages when over threshold
                \\  /exit      Exit REPL
                \\
                \\Multi-line input:
                \\  Shift+Enter / Ctrl+Enter   insert a newline (requires CSI u capable terminal:
                \\                             kitty, WezTerm, foot, iTerm2 latest, xterm)
                \\  Enter                      submit the whole buffer
                \\  (non-tty fallback: end line with \ or wrap with """ on its own line)
                \\
            , .{});
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/clear")) {
            std.debug.print("\x1b[2J\x1b[H", .{});
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/tools")) {
            for (tools.registry) |*t| std.debug.print("  \x1b[32m{s}\x1b[0m - {s}\n", .{ t.name, t.description });
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/skills")) {
            if (app.skills.len() == 0) {
                std.debug.print("No skills installed. Put SKILL.md files under ~/.cc-zig/skills/<name>/ or <project>/.cc-zig/skills/<name>/\n", .{});
            } else {
                std.debug.print("Available skills ({d}):\n", .{app.skills.len()});
                for (app.skills.skills.items) |s| {
                    std.debug.print("  \x1b[36m{s}\x1b[0m — {s}\n", .{ s.name, s.description });
                }
            }
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/history")) {
            printHistory(&history);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/compact")) {
            const before = app.conversation.len();
            const dropped = app.conversation.compact(100_000) catch 0;
            std.debug.print("Compacted {d} old messages ({d} → {d}).\n", .{ dropped, before, app.conversation.len() });
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/retry")) {
            try retryLast(app, allocator, &writer);
            continue;
        }

        // tty 模式：LineEditor 已经在 buffer 里保存换行（Shift+Enter / Ctrl+Enter），一次提交
        // 非 tty 模式：保留 Accumulator fallback（行尾 `\` 续行 / 独占 `"""` 块）
        const final_input = if (tty)
            try allocator.dupe(u8, line)
        else blk: {
            var accum = multiline_mod.Accumulator.init(allocator);
            defer accum.deinit();
            var status = try accum.feedLine(line);
            while (status == .more) {
                const cont = readLineBuffered(allocator) catch break;
                defer allocator.free(cont);
                status = try accum.feedLine(cont);
            }
            if (status == .more) continue;
            break :blk try accum.finish();
        };
        defer allocator.free(final_input);

        if (final_input.len == 0) continue;

        try history.append(final_input);
        try app.conversation.appendText(.user, final_input);

        // 生成期间启动 stdin 监听线程：Esc / Ctrl+C / 'q' 字节 → 触发 app.abort
        // 这是因为 raw mode ISIG=false 禁用了 kernel 的 SIGINT 生成，我们必须自己读并翻译
        var watcher_stop = std.atomic.Value(bool).init(false);
        const watcher_thread = if (tty) try std.Thread.spawn(
            .{},
            stdinAbortWatcher,
            .{ stdin_fd, &app.abort, &watcher_stop },
        ) else null;

        const result = agent_loop.run(
            &app.conversation,
            &app.api_client,
            app.tool_defs,
            &app.permission_ctx,
            .{ .verbose = app.config.verbose, .abort = &app.abort },
            &writer,
            allocator,
        ) catch |err| {
            // 停 watcher + 清 stdin 缓冲
            watcher_stop.store(true, .release);
            if (watcher_thread) |t| t.join();
            if (tty) drainStdin(stdin_fd);
            std.debug.print("\x1b[31mError: {s}\x1b[0m\n", .{@errorName(err)});
            continue;
        };
        // 停 watcher + 清 stdin 缓冲（生成期间用户可能误按的键，别污染下一轮）
        watcher_stop.store(true, .release);
        if (watcher_thread) |t| t.join();
        if (tty) drainStdin(stdin_fd);

        if (result.stop_reason == .aborted) {
            std.debug.print("\x1b[33m^C (cancelled)\x1b[0m\n", .{});
            app.abort.resetForTesting();
        }
    }
}

/// 生成期间运行的 stdin 监听线程。
///
/// 用 poll(fd, 100ms) 循环——100ms 超时时检查 stop flag，有数据时 read 一字节判断：
///   - 0x03 (Ctrl+C)
///   - 0x1B (Esc)
///   - 'q' / 'Q'
///   任一 → 调 abort.abort(.user_ctrl_c)，退出线程
///
/// stop flag（由主线程在生成结束后 set）也会让线程干净退出。
fn stdinAbortWatcher(
    fd: std.c.fd_t,
    abort: *@import("../util/abort.zig").AbortSignal,
    stop: *std.atomic.Value(bool),
) void {
    while (!stop.load(.acquire)) {
        var pfd = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
        const rc = std.c.poll(&pfd, 1, 100);
        if (rc <= 0) continue;
        if ((pfd[0].revents & std.c.POLL.IN) == 0) continue;

        var b: [1]u8 = undefined;
        const n = std.c.read(fd, &b, 1);
        if (n <= 0) continue;

        // 生成期间：只有 Esc (0x1B) 触发 abort。其他字节吞掉（防止漏给后续 readLineRaw
        // 导致 CSI 序列被切断、出现乱码如 "99~99~"）。
        if (b[0] == 0x1B) {
            abort.abort(.user_ctrl_c);
            return;
        }
        // 其他按键：静默吞掉，不 abort
    }
}

/// Drain stdin buffer: 非阻塞读尽剩余字节。生成结束后调用，避免用户在 LLM 输出时
/// 误按的字符进入下一轮输入缓冲。
fn drainStdin(fd: std.c.fd_t) void {
    while (true) {
        var pfd = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
        const rc = std.c.poll(&pfd, 1, 0); // timeout=0 → 立即返回
        if (rc <= 0) return;
        if ((pfd[0].revents & std.c.POLL.IN) == 0) return;
        var buf: [256]u8 = undefined;
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) return;
    }
}

/// 非 tty / 管道模式下的朴素逐字节行读（保留 M0 行为）。
fn readLineBuffered(allocator: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        var b: [1]u8 = undefined;
        const n = posix.read(posix.STDIN_FILENO, &b) catch return error.ReadError;
        if (n == 0) {
            if (len == 0) return error.Eof;
            break;
        }
        if (b[0] == '\n') break;
        buf[len] = b[0];
        len += 1;
    }
    const r = try allocator.alloc(u8, len);
    @memcpy(r, buf[0..len]);
    return r;
}

/// tty raw mode 下的行编辑器主循环：按键驱动 LineEditor，支持历史 ↑↓。
/// 返回提交的行（owned，caller free）。
/// - Ctrl+C (buffer 非空) → error.Cancelled（清 buffer 回 prompt）
/// - Ctrl+C (buffer 空，首次) → 打印提示，留在同一行继续等输入
/// - Ctrl+C (buffer 空，连续第二次) → error.ExitRequested（退出 REPL）
/// - Ctrl+D (buffer 空) → error.Eof（退出 REPL）
fn readLineRaw(fd: std.c.fd_t, allocator: std.mem.Allocator, history: *history_mod.History) ![]u8 {
    const orig = input.enterRawMode(fd) orelse {
        // 无法进 raw mode：退化
        return readLineBuffered(allocator);
    };
    defer input.restoreMode(fd, orig);

    var editor = input.LineEditor.init(allocator);
    defer editor.deinit();

    var parser = input.KeyParser{};

    while (true) {
        var b: [1]u8 = undefined;
        const n = posix.read(fd, &b) catch return error.ReadError;
        if (n == 0) return error.Eof;

        const key = parser.feed(b[0]) orelse continue;
        const action = try editor.handle(key);
        switch (action) {
            .redraw => try redrawLine(editor.view(), editor.cursor),
            .commit => {
                std.debug.print("\n", .{});
                return try allocator.dupe(u8, editor.view());
            },
            .cancel => return error.Cancelled,
            .cancel_hint => {
                // 第一次 Ctrl+C 且 buffer 空 — 提示再按一次退出，当前行留空等下次按键
                std.debug.print("\r\x1b[2K(再次按 Ctrl+C 退出 REPL)\n> ", .{});
            },
            .exit_repl => return error.ExitRequested,
            .eof => return error.Eof,
            .history_prev => {
                if (try history.prev(editor.view())) |prev| {
                    try editor.setLine(prev);
                    try redrawLine(editor.view(), editor.cursor);
                }
            },
            .history_next => {
                if (history.next()) |nxt| {
                    try editor.setLine(nxt);
                    try redrawLine(editor.view(), editor.cursor);
                }
            },
            .none => {},
        }
    }
}

/// 在同一行重绘：回车 → 擦行 → 重写 "> " + buffer → 移动光标。
///
/// 光标定位按"显示列宽"算，而不是字节偏移——CJK 一字占 2 列、ASCII 占 1 列。
/// 否则每打一个汉字光标就相对文字末尾右漂 1 列。
fn redrawLine(line: []const u8, cursor: usize) !void {
    std.debug.print("\r\x1b[2K> {s}", .{line});
    const cols = displayWidthUpTo(line, cursor);
    // "> " 占 2 列 + 文本显示列数
    const pos = cols + 2;
    std.debug.print("\r\x1b[{d}C", .{pos});
}

/// 计算 bytes[0..byte_pos] 在终端上的显示列数（东亚全角 = 2，ASCII = 1）。
/// 非法 UTF-8 按 1 字节 = 1 列保底。
fn displayWidthUpTo(bytes: []const u8, byte_pos: usize) usize {
    const end = @min(byte_pos, bytes.len);
    var cols: usize = 0;
    var i: usize = 0;
    while (i < end) {
        const b = bytes[i];
        if (b < 0x80) {
            // ASCII
            cols += 1;
            i += 1;
            continue;
        }
        // UTF-8 多字节
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

/// 显示宽度（East Asian Width 的 W/F = 2，其他 = 1，控制字符 = 0）。
/// 简化表，覆盖 CJK + emoji 主要区段。
fn codepointDisplayWidth(cp: u21) usize {
    if (cp < 0x20 or cp == 0x7F) return 0;
    // 常见双宽区段
    if (cp >= 0x1100 and cp <= 0x115F) return 2; // Hangul Jamo
    if (cp >= 0x2E80 and cp <= 0x303E) return 2; // CJK Radicals + 部首补充
    if (cp >= 0x3041 and cp <= 0x33FF) return 2; // 日文假名 + CJK 符号
    if (cp >= 0x3400 and cp <= 0x4DBF) return 2; // CJK 扩展 A
    if (cp >= 0x4E00 and cp <= 0x9FFF) return 2; // CJK 统一
    if (cp >= 0xA000 and cp <= 0xA4CF) return 2; // 彝文
    if (cp >= 0xAC00 and cp <= 0xD7A3) return 2; // 韩文音节
    if (cp >= 0xF900 and cp <= 0xFAFF) return 2; // CJK 兼容
    if (cp >= 0xFE30 and cp <= 0xFE4F) return 2; // CJK 兼容形式
    if (cp >= 0xFF00 and cp <= 0xFF60) return 2; // 全角 ASCII
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2; // 全角货币符号
    if (cp >= 0x1F300 and cp <= 0x1FAFF) return 2; // emoji
    if (cp >= 0x20000 and cp <= 0x2FFFD) return 2; // CJK 扩展 B-F
    if (cp >= 0x30000 and cp <= 0x3FFFD) return 2; // CJK 扩展 G
    return 1;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "displayWidthUpTo ASCII only" {
    try testing.expect(displayWidthUpTo("hello", 5) == 5);
    try testing.expect(displayWidthUpTo("hello", 3) == 3);
    try testing.expect(displayWidthUpTo("hello", 0) == 0);
}

test "displayWidthUpTo: single Chinese char is 2 cols" {
    // 你 = E4 BD A0（3 字节，2 列）
    const s = [_]u8{ 0xE4, 0xBD, 0xA0 };
    try testing.expect(displayWidthUpTo(&s, 3) == 2);
}

test "displayWidthUpTo: 两个中文 = 4 列 = 6 字节" {
    // 你好
    const s = [_]u8{ 0xE4, 0xBD, 0xA0, 0xE5, 0xA5, 0xBD };
    try testing.expect(displayWidthUpTo(&s, 6) == 4);
    try testing.expect(displayWidthUpTo(&s, 3) == 2); // 光标在"你"后
}

test "displayWidthUpTo: 混合 ASCII + 中文" {
    // "a你b好"
    const s = [_]u8{ 'a', 0xE4, 0xBD, 0xA0, 'b', 0xE5, 0xA5, 0xBD };
    try testing.expect(displayWidthUpTo(&s, 8) == 6); // 1+2+1+2
    try testing.expect(displayWidthUpTo(&s, 4) == 3); // "a你" = 1+2
    try testing.expect(displayWidthUpTo(&s, 5) == 4); // "a你b" = 1+2+1
}

test "displayWidthUpTo: 部分截断（byte_pos 在 UTF-8 序列中间）" {
    const s = [_]u8{ 0xE4, 0xBD, 0xA0 };
    // 打到第 2 字节——不完整字符按 1 处理（保底）
    const w = displayWidthUpTo(&s, 2);
    try testing.expect(w == 0); // 不完整 → break
}

test "codepointDisplayWidth: emoji" {
    try testing.expect(codepointDisplayWidth(0x1F600) == 2); // 😀
    try testing.expect(codepointDisplayWidth(0x1F3C0) == 2);
}

test "codepointDisplayWidth: 控制字符 0 列" {
    try testing.expect(codepointDisplayWidth(0x00) == 0);
    try testing.expect(codepointDisplayWidth(0x1F) == 0);
}

test "decodeCodepoint: 3-byte" {
    const s = [_]u8{ 0xE4, 0xBD, 0xA0 };
    const cp = decodeCodepoint(&s).?;
    try testing.expect(cp == 0x4F60); // 你
}

fn printHistory(history: *const history_mod.History) void {
    std.debug.print("History ({d} entries):\n", .{history.entries.items.len});
    const start: usize = if (history.entries.items.len > 20) history.entries.items.len - 20 else 0;
    for (history.entries.items[start..], start..) |entry, i| {
        std.debug.print("  {d}  {s}\n", .{ i + 1, entry });
    }
}

/// /retry：找 conversation 里最后一条 user text，重发 agent_loop（不追加重复消息）。
fn retryLast(app: *app_mod.App, allocator: std.mem.Allocator, writer: *DebugWriter) !void {
    // 找最后一条 user 消息——删除所有后面的 assistant/user 回合，回到上一次 user 发出前的状态
    var idx: ?usize = null;
    var i = app.conversation.messages.items.len;
    while (i > 0) {
        i -= 1;
        if (app.conversation.messages.items[i].role == .user) {
            idx = i;
            break;
        }
    }
    if (idx == null) {
        std.debug.print("\x1b[33mNo user message to retry\x1b[0m\n", .{});
        return;
    }

    // 丢弃从 idx+1 起的所有消息
    var j = app.conversation.messages.items.len;
    while (j > idx.? + 1) {
        j -= 1;
        const m = app.conversation.messages.orderedRemove(j);
        m.deinit(app.conversation.allocator);
    }

    const result = agent_loop.run(
        &app.conversation,
        &app.api_client,
        app.tool_defs,
        &app.permission_ctx,
        .{ .verbose = app.config.verbose, .abort = &app.abort },
        writer,
        allocator,
    ) catch |err| {
        std.debug.print("\x1b[31mError: {s}\x1b[0m\n", .{@errorName(err)});
        return;
    };
    if (result.stop_reason == .aborted) {
        std.debug.print("\x1b[33m^C (cancelled)\x1b[0m\n", .{});
        app.abort.resetForTesting();
    }
}

fn historyPath(allocator: std.mem.Allocator) ![]u8 {
    const home_c = std.c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.span(home_c);
    return std.fmt.allocPrint(allocator, "{s}/.cc-zig/history", .{home});
}

/// 最小 writer，把格式化输出走 stderr（与 std.debug.print 同通道）。
const DebugWriter = struct {
    pub fn print(_: *@This(), comptime fmt: []const u8, args: anytype) !void {
        std.debug.print(fmt, args);
    }
};
