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
const complete = @import("complete.zig");
const paste_mod = @import("paste.zig");
const history_mod = @import("history.zig");
const multiline_mod = @import("multiline.zig");
const render_mod = @import("render.zig");
const transcript_mod = @import("../core/transcript.zig");
const statusline = @import("statusline.zig");
const progress = @import("progress.zig");
const util_fs = @import("../util/fs.zig");

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

    // 进入 TUI：开启工具 progress 显示（非 TTY 不启用避免污染 pipe 输出）
    if (tty) progress.enable();
    defer if (tty) progress.disable();

    while (true) {
        if (tty) statusline.render(app);
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
                \\  /help            Show this help
                \\  /clear           Clear screen
                \\  /tools           List available tools
                \\  /skills          List installed skills
                \\  /history         Show recent commands
                \\  /model [name]    Show or switch the active model
                \\  /resume [id]     List recent sessions, or resume one by id
                \\  /retry           Resend the last user message
                \\  /compact         Compact oldest messages when over threshold
                \\  /doctor          Show environment/config diagnostics
                \\  /config [show|path]  Inspect config (~/.cc-zig/config.json)
                \\  /init            Create .cc-zig/ skeleton in the current directory
                \\  /mcp             List configured MCP servers
                \\  /agents          List available sub-agent capabilities
                \\  /permissions     Show permission mode + loaded rules
                \\  /memory [add ..] Show or append cross-session memory
                \\  /commit          Draft a git commit using the model
                \\  /review          Ask the model to review the current diff
                \\  /exit            Exit REPL
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
            // 动态工具（Skill / MCP）
            for (app.dyn_registry.entries.items) |e| {
                std.debug.print("  \x1b[36m{s}\x1b[0m - {s}\n", .{ e.name, e.description });
            }
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
        if (std.mem.eql(u8, trimmed, "/cost")) {
            const u = app.usage;
            const cost = u.costUsd(app.config.model);
            std.debug.print(
                \\Usage ({s}):
                \\  input         {d} tokens
                \\  output        {d} tokens
                \\  cache read    {d} tokens
                \\  cache create  {d} tokens
                \\  total cost    ${d:.6} USD
                \\
            , .{ app.config.model, u.input_tokens, u.output_tokens, u.cache_read_input_tokens, u.cache_creation_input_tokens, cost });
            continue;
        }
        // /model [name] —— 无参列当前 + 可选模型；有参切换
        if (std.mem.startsWith(u8, trimmed, "/model")) {
            const rest = std.mem.trim(u8, trimmed[6..], " \t");
            try handleModel(app, allocator, rest);
            continue;
        }
        // /resume [id] —— 无参列最近 10 个 session；有参加载
        if (std.mem.startsWith(u8, trimmed, "/resume")) {
            const rest = std.mem.trim(u8, trimmed[7..], " \t");
            try handleResume(app, allocator, rest);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/doctor")) {
            try handleDoctor(app, allocator);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/config")) {
            const rest = std.mem.trim(u8, trimmed[7..], " \t");
            try handleConfigCmd(app, allocator, rest);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/init")) {
            try handleInit(app, allocator);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/mcp")) {
            try handleMcp(app);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/agents")) {
            try handleAgents(app);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/permissions")) {
            handlePermissions(app);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/memory")) {
            const rest = std.mem.trim(u8, trimmed[7..], " \t");
            try handleMemory(app, allocator, rest);
            continue;
        }
        // /commit 和 /review：把预置 prompt 注入为 user message，走正常 agent_loop 路径
        if (std.mem.eql(u8, trimmed, "/commit")) {
            try app.conversation.appendText(.user, COMMIT_PROMPT);
            // 不 continue，让下面主流程跑一轮
            try runInjectedAgent(app, allocator, &writer);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/review")) {
            try app.conversation.appendText(.user, REVIEW_PROMPT);
            try runInjectedAgent(app, allocator, &writer);
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
        // 粘贴占位符 [Pasted text #N] → 展开成真实内容再喂给模型；history 保留紧凑占位符。
        const expanded = blk: {
            const home_c = std.c.getenv("HOME") orelse break :blk null;
            break :blk paste_mod.expandPlaceholders(allocator, std.mem.span(home_c), final_input) catch null;
        };
        defer if (expanded) |e| allocator.free(e);
        try app.conversation.appendText(.user, expanded orelse final_input);

        // 生成期间启动 stdin 监听线程：Esc / Ctrl+C / 'q' 字节 → 触发 app.abort
        // 这是因为 raw mode ISIG=false 禁用了 kernel 的 SIGINT 生成，我们必须自己读并翻译
        var watcher_stop = std.atomic.Value(bool).init(false);
        const watcher_thread = if (tty) try std.Thread.spawn(
            .{},
            stdinAbortWatcher,
            .{ stdin_fd, &app.abort, &watcher_stop },
        ) else null;

        const usage_sink = app.usageSink();
        const jobs_ptr: ?*@import("../core/job_registry.zig").JobRegistry = if (app.jobs) |*j| j else null;
        const result = agent_loop.run(
            &app.conversation,
            &app.api_client,
            app.tool_defs,
            &app.permission_ctx,
            .{ .verbose = app.config.verbose, .abort = &app.abort, .read_state = &app.read_state, .usage_sink = usage_sink, .jobs = jobs_ptr, .plan_prev_mode = &app.plan_prev_mode, .tasks = &app.tasks, .api_client = &app.api_client, .tool_defs = app.tool_defs, .system_prompt = app.system_prompt, .dyn_registry = &app.dyn_registry },
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

        // 每轮结束 flush transcript（含错误 / abort 路径；只要有变动都想落盘）
        app.persistTranscript();

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
/// 处理一次括号粘贴：从 paste_begin 之后读到 paste_end，累积原始文本。
/// 小粘贴内联插入；大粘贴存 ~/.cc-zig/pastes/<N>.txt 并插入占位符。
fn handlePaste(
    fd: std.c.fd_t,
    editor: *input.LineEditor,
    parser: *input.KeyParser,
    allocator: std.mem.Allocator,
) !void {
    var pasted = std.ArrayList(u8).empty;
    defer pasted.deinit(allocator);

    // 在粘贴内，原始字节直接收集；只有 paste_end 这个 CSI 序列需要靠 parser 识别。
    // 实现：逐字节喂 parser；若产出 .paste_end 则结束；产出 .char 收集其字节；
    // 其它控制键在粘贴内罕见，按其原始字节收集（保留 \n \t 等）。
    while (true) {
        var b: [1]u8 = undefined;
        const n = posix.read(fd, &b) catch break;
        if (n == 0) break;
        const key = parser.feed(b[0]) orelse {
            // parser 处于 CSI 中间态——字节已被吞，等下一个
            continue;
        };
        switch (key) {
            .paste_end => break,
            .char => |c| try pasted.append(allocator, c),
            .enter => try pasted.append(allocator, '\n'),
            .tab => try pasted.append(allocator, '\t'),
            else => {}, // 粘贴里的其它控制序列忽略
        }
    }

    const text = pasted.items;
    if (text.len == 0) return;

    if (paste_mod.isLarge(text)) {
        const home_c = std.c.getenv("HOME");
        if (home_c) |hc| {
            const home = std.mem.span(hc);
            g_paste_id += 1;
            if (paste_mod.store(allocator, home, g_paste_id, text) catch null) |placeholder| {
                defer allocator.free(placeholder);
                try insertAtCursor(editor, allocator, placeholder);
                return;
            }
        }
        // store 失败 / 无 HOME → 退回内联
    }
    try insertAtCursor(editor, allocator, text);
}

/// 在光标处插入一段文本，光标移到插入末尾。
fn insertAtCursor(editor: *input.LineEditor, allocator: std.mem.Allocator, text: []const u8) !void {
    const line = editor.view();
    var nl = std.ArrayList(u8).empty;
    defer nl.deinit(allocator);
    try nl.appendSlice(allocator, line[0..editor.cursor]);
    try nl.appendSlice(allocator, text);
    try nl.appendSlice(allocator, line[editor.cursor..]);
    const new_cursor = editor.cursor + text.len;
    try editor.setLine(nl.items);
    editor.cursor = new_cursor;
}

/// Session 内递增的粘贴编号（用于 [Pasted text #N] 占位符 + pastes/<N>.txt 文件名）。
var g_paste_id: usize = 0;

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

        // 括号粘贴：收集到 paste_end，决定内联还是外部存储 + 占位符
        if (key == .paste_begin) {
            try handlePaste(fd, &editor, &parser, allocator);
            try redrawLine(editor.view(), editor.cursor);
            continue;
        }

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
            .complete => {
                try handleCompletion(&editor, allocator);
                try redrawLine(editor.view(), editor.cursor);
            },
            .reverse_search => {
                try handleReverseSearch(fd, &editor, &parser, history, allocator);
                try redrawLine(editor.view(), editor.cursor);
            },
            .none => {},
        }
    }
}

/// TAB 补全：算候选，唯一则补全，多个则列出 + 补到公共前缀。
fn handleCompletion(editor: *input.LineEditor, allocator: std.mem.Allocator) !void {
    var r = complete.compute(allocator, editor.view(), editor.cursor) catch return;
    defer r.deinit(allocator);
    if (r.candidates.len == 0) return;

    const cursor = editor.cursor;
    const line = editor.view();
    // 当前 token = [replace_start, cursor)
    const replaced_len = cursor - r.replace_start;

    if (r.candidates.len == 1) {
        try applyCompletion(editor, allocator, r.replace_start, replaced_len, r.candidates[0]);
        return;
    }
    // 多候选：补到公共前缀（若比已输入更长）
    const pfx = complete.commonPrefix(r.candidates);
    if (pfx.len > replaced_len) {
        try applyCompletion(editor, allocator, r.replace_start, replaced_len, pfx);
    }
    // 列出候选
    std.debug.print("\n", .{});
    for (r.candidates) |c| std.debug.print("  {s}", .{c});
    std.debug.print("\n", .{});
    _ = line;
}

/// 用 candidate 替换 buffer 中 [start, start+old_len) 的内容，光标移到替换末尾。
fn applyCompletion(editor: *input.LineEditor, allocator: std.mem.Allocator, start: usize, old_len: usize, candidate: []const u8) !void {
    const line = editor.view();
    var new_line = std.ArrayList(u8).empty;
    defer new_line.deinit(allocator);
    try new_line.appendSlice(allocator, line[0..start]);
    try new_line.appendSlice(allocator, candidate);
    const tail_start = start + old_len;
    if (tail_start < line.len) try new_line.appendSlice(allocator, line[tail_start..]);
    try editor.setLine(new_line.items);
    editor.cursor = start + candidate.len;
}

/// Ctrl+R 反向历史搜索：读字节构建 query，实时显示首个匹配；Enter 接受，Esc/Ctrl+C 取消。
fn handleReverseSearch(
    fd: std.c.fd_t,
    editor: *input.LineEditor,
    parser: *input.KeyParser,
    history: *history_mod.History,
    allocator: std.mem.Allocator,
) !void {
    _ = parser;
    var query = std.ArrayList(u8).empty;
    defer query.deinit(allocator);
    var match: ?[]const u8 = null;

    while (true) {
        // 渲染搜索提示
        std.debug.print("\r\x1b[2K(reverse-search)`{s}': {s}", .{ query.items, match orelse "" });

        var b: [1]u8 = undefined;
        const n = posix.read(fd, &b) catch return;
        if (n == 0) return;
        const c = b[0];

        if (c == 0x1b or c == 0x03) {
            // Esc / Ctrl+C：取消，保留原 buffer
            std.debug.print("\r\x1b[2K", .{});
            return;
        }
        if (c == '\r' or c == '\n') {
            // 接受当前匹配
            if (match) |m| {
                try editor.setLine(m);
            }
            std.debug.print("\r\x1b[2K", .{});
            return;
        }
        if (c == 0x7f or c == 0x08) {
            if (query.items.len > 0) _ = query.pop();
        } else if (c >= 0x20) {
            try query.append(allocator, c);
        } else {
            continue;
        }
        match = searchHistory(history, query.items);
    }
}

/// 从最新到最旧找第一个包含 query 的历史项。
fn searchHistory(history: *history_mod.History, query: []const u8) ?[]const u8 {
    if (query.len == 0) return null;
    var i: usize = history.entries.items.len;
    while (i > 0) {
        i -= 1;
        const e = history.entries.items[i];
        if (std.mem.indexOf(u8, e, query) != null) return e;
    }
    return null;
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

    const usage_sink = app.usageSink();
    const jobs_ptr: ?*@import("../core/job_registry.zig").JobRegistry = if (app.jobs) |*jr| jr else null;
    const result = agent_loop.run(
        &app.conversation,
        &app.api_client,
        app.tool_defs,
        &app.permission_ctx,
        .{ .verbose = app.config.verbose, .abort = &app.abort, .read_state = &app.read_state, .usage_sink = usage_sink, .jobs = jobs_ptr, .plan_prev_mode = &app.plan_prev_mode, .tasks = &app.tasks, .api_client = &app.api_client, .tool_defs = app.tool_defs, .system_prompt = app.system_prompt, .dyn_registry = &app.dyn_registry },
        writer,
        allocator,
    ) catch |err| {
        std.debug.print("\x1b[31mError: {s}\x1b[0m\n", .{@errorName(err)});
        return;
    };
    app.persistTranscript();
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

// ============================================================================
// /doctor /config /init /mcp /commit /review handlers
// ============================================================================

const COMMIT_PROMPT =
    \\Please help create a git commit for the current working tree.
    \\
    \\Steps you should follow:
    \\  1) Run `git status` and `git diff --stat` (via the Bash tool) to see what changed.
    \\  2) Run `git log -n 5 --oneline` to match the project's commit style.
    \\  3) Draft a concise, conventional commit message summarising the WHY of the change.
    \\  4) Stage the intended files with `git add <path> ...` (do NOT use `git add -A`; skip secrets).
    \\  5) Run `git commit -m "..."`.
    \\  6) Show `git status` at the end to confirm.
    \\
    \\Do NOT push. If the diff is empty, say so and stop.
;

const REVIEW_PROMPT =
    \\Please review the current change set (unstaged + staged diff against HEAD).
    \\
    \\Steps:
    \\  1) Run `git diff HEAD` (via Bash) to see all pending changes.
    \\  2) Identify bugs, edge cases, missing error handling, broken invariants, style issues.
    \\  3) Group findings by severity: blockers → warnings → nits.
    \\  4) Quote the specific lines you are commenting on.
    \\  5) End with a one-line verdict: ready to merge / needs fixes.
;

/// /model：无参显示当前模型 + 已知候选；有参切换到指定模型并重建 system prompt。
fn handleModel(app: *app_mod.App, allocator: std.mem.Allocator, rest: []const u8) !void {
    if (rest.len == 0) {
        std.debug.print("current model: \x1b[36m{s}\x1b[0m\n", .{app.config.model});
        // 优先列 probe 到的 catalog；为空则列本地已知前缀
        if (app.api_client.catalog.entries.items.len > 0) {
            std.debug.print("available (from server):\n", .{});
            for (app.api_client.catalog.entries.items) |e| {
                std.debug.print("  {s}  (max_output={d})\n", .{ e.model_id, e.max_tokens });
            }
        } else {
            std.debug.print("known model families:\n", .{});
            std.debug.print("  claude-opus-4-7 / claude-opus-4-6 / claude-opus-4-5\n", .{});
            std.debug.print("  claude-sonnet-4-6 / claude-sonnet-4\n", .{});
            std.debug.print("  claude-haiku-4-5\n", .{});
        }
        std.debug.print("usage: /model <model-id>\n", .{});
        return;
    }

    // 基本校验：必须像一个 claude 模型 id（避免手滑切到无效值导致 401/404 满屏）。
    // 若 catalog 非空，也接受 catalog 里出现过的 id。
    const in_catalog = blk: {
        for (app.api_client.catalog.entries.items) |e| {
            if (std.mem.eql(u8, e.model_id, rest)) break :blk true;
        }
        break :blk false;
    };
    if (!in_catalog and !std.mem.startsWith(u8, rest, "claude-")) {
        std.debug.print("\x1b[31mrefused: '{s}' doesn't look like a model id (expected 'claude-...')\x1b[0m\n", .{rest});
        return;
    }

    const new_model = try allocator.dupe(u8, rest);
    app.config.model = new_model;
    app.api_client.model = new_model;

    // 重建 system prompt（含 knowledge cutoff、模型名）。失败保留旧的。
    const sp_mod = @import("../core/system_prompt.zig");
    if (sp_mod.buildWithSkills(allocator, new_model, &app.skills)) |sp| {
        if (app.system_prompt) |old| allocator.free(old);
        app.system_prompt = sp;
    } else |err| {
        std.debug.print("\x1b[33mwarn: system prompt rebuild failed ({s}); kept previous\x1b[0m\n", .{@errorName(err)});
    }

    std.debug.print("switched to \x1b[36m{s}\x1b[0m (max_output={d})\n", .{ new_model, app.api_client.resolveMaxTokens() });
}

fn handleDoctor(app: *app_mod.App, allocator: std.mem.Allocator) !void {
    std.debug.print("\x1b[1mcc-zig doctor\x1b[0m\n", .{});
    std.debug.print("  model:            {s}\n", .{app.config.model});
    std.debug.print("  permission mode:  {s}\n", .{@tagName(app.permission_ctx.mode)});
    std.debug.print("  api key:          {s}\n", .{if (app.api_key.len > 0) "set" else "MISSING"});
    std.debug.print("  max_tokens cfg:   {any}\n", .{app.config.max_tokens});
    std.debug.print("  verbose:          {}\n", .{app.config.verbose});
    std.debug.print("  transcript:       {s}\n", .{if (app.transcript_writer != null) "on" else "OFF"});
    std.debug.print("  job registry:     {s}\n", .{if (app.jobs != null) "on" else "OFF"});
    std.debug.print("  skills loaded:    {d}\n", .{app.skills.len()});
    std.debug.print("  conversation:     {d} messages\n", .{app.conversation.len()});
    std.debug.print("  tasks:            {d} in store\n", .{app.tasks.tasks.items.len});
    std.debug.print("  rules loaded:     {d}\n", .{if (app.rule_set) |r| r.rules.items.len else 0});

    // HOME + CWD + config file 检查
    const home_c = std.c.getenv("HOME");
    if (home_c) |h| {
        std.debug.print("  HOME:             {s}\n", .{std.mem.span(h)});
    } else {
        std.debug.print("  HOME:             UNSET\n", .{});
    }

    if (util_fs.getCwd(allocator)) |cwd| {
        defer allocator.free(cwd);
        std.debug.print("  CWD:              {s}\n", .{cwd});
    } else |_| {
        std.debug.print("  CWD:              (unreadable)\n", .{});
    }
}

fn handleConfigCmd(app: *app_mod.App, allocator: std.mem.Allocator, rest: []const u8) !void {
    _ = app;
    const home_c = std.c.getenv("HOME") orelse {
        std.debug.print("HOME not set\n", .{});
        return;
    };
    const home = std.mem.span(home_c);
    const cfg_path = try std.fmt.allocPrint(allocator, "{s}/.cc-zig/config.json", .{home});
    defer allocator.free(cfg_path);

    if (rest.len == 0 or std.mem.eql(u8, rest, "show")) {
        std.debug.print("config path: {s}\n", .{cfg_path});
        // 尝试读全文
        const path_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{cfg_path}, 0);
        defer allocator.free(path_z);
        const fd = std.c.open(path_z.ptr, std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) {
            std.debug.print("(file does not exist — use /init to create one)\n", .{});
            return;
        }
        defer _ = std.c.close(fd);
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &buf, buf.len);
            if (n <= 0) break;
            std.debug.print("{s}", .{buf[0..@intCast(n)]});
        }
        std.debug.print("\n", .{});
        return;
    }
    if (std.mem.eql(u8, rest, "path")) {
        std.debug.print("{s}\n", .{cfg_path});
        return;
    }
    std.debug.print("usage: /config [show|path]\n", .{});
}

fn handleInit(app: *app_mod.App, allocator: std.mem.Allocator) !void {
    _ = app;

    // 1. 在 CWD 创建 .cc-zig/ 目录
    const cwd = util_fs.getCwd(allocator) catch {
        std.debug.print("getcwd failed\n", .{});
        return;
    };
    defer allocator.free(cwd);

    const dir = try std.fmt.allocPrintSentinel(allocator, "{s}/.cc-zig", .{cwd}, 0);
    defer allocator.free(dir);
    if (std.c.mkdir(dir.ptr, @as(std.c.mode_t, 0o755)) != 0) {
        const errno: std.c.E = @enumFromInt(std.c._errno().*);
        if (errno != .EXIST) {
            std.debug.print("mkdir {s}: errno={s}\n", .{ dir, @tagName(errno) });
            return;
        }
    }

    const cfg_path = try std.fmt.allocPrintSentinel(allocator, "{s}/config.json", .{dir}, 0);
    defer allocator.free(cfg_path);

    // 存在性检查：用 access(F_OK) 明确表达"文件是否存在"。
    // open(RDONLY) 会把"没权限读取 / 不是常规文件 / 符号链接循环"等情况和 ENOENT 混成
    // 同一个 "fd<0"，后续 CREAT|TRUNC 会截断已存在但我们没读权限的 config。
    if (std.c.access(cfg_path.ptr, std.c.F_OK) == 0) {
        std.debug.print("already exists: {s}\n", .{cfg_path});
        return;
    }
    {
        const errno: std.c.E = @enumFromInt(std.c._errno().*);
        if (errno != .NOENT) {
            std.debug.print("access {s}: errno={s}\n", .{ cfg_path, @tagName(errno) });
            return;
        }
    }

    // 2. 写默认 config.json 骨架（只在 access 返 ENOENT 时走到这里）
    const skeleton =
        \\{
        \\  "model": "claude-opus-4-7",
        \\  "permission_mode": "prompt",
        \\  "permission_rules": [
        \\    { "match": { "tool": "Read" }, "decision": "allow" },
        \\    { "match": { "tool": "Glob" }, "decision": "allow" },
        \\    { "match": { "tool": "Grep" }, "decision": "allow" }
        \\  ]
        \\}
        \\
    ;
    // 用 O_EXCL 防 TOCTOU：两次 access/open 之间若有人建了同名文件，EXCL 会 fail 而非覆盖
    const fd = std.c.open(cfg_path.ptr, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) {
        const errno: std.c.E = @enumFromInt(std.c._errno().*);
        if (errno == .EXIST) {
            // access 后 open 前有并发创建；语义等价 "already exists"，不要让用户困惑
            std.debug.print("already exists (race): {s}\n", .{cfg_path});
        } else {
            std.debug.print("create {s}: errno={s}\n", .{ cfg_path, @tagName(errno) });
        }
        return;
    }
    // close 延后到 write 完成后——但若 write 失败需要 unlink，close 要在 unlink 前
    // 调用。用 explicit close + unlink，不用 defer（defer 会让 unlink 先于 close）。
    const n = std.c.write(fd, skeleton.ptr, skeleton.len);
    _ = std.c.close(fd);
    const wrote: usize = if (n < 0) 0 else @intCast(n);
    if (wrote != skeleton.len) {
        const errno: std.c.E = if (n < 0) @enumFromInt(std.c._errno().*) else .SUCCESS;
        std.debug.print(
            "write {s}: errno={s}, wrote {d}/{d} — rolling back\n",
            .{ cfg_path, @tagName(errno), wrote, skeleton.len },
        );
        // 原子性：要么完整写入，要么盘上没有残留文件。部分写入的 config 会让下次
        // /config show 解析报错，用户无法 debug。unlink 清掉，让他们重跑 /init。
        _ = std.c.unlink(cfg_path.ptr);
        return;
    }
    std.debug.print("created {s}\n", .{cfg_path});
}

fn handleMcp(app: *app_mod.App) !void {
    if (app.mcp_sessions.items.len == 0) {
        std.debug.print(
            \\MCP servers: (none connected)
            \\
            \\Declare servers in ~/.cc-zig/config.json:
            \\  {{"mcp_servers":[{{"name":"foo","command":["/path/to/server","--flag"]}}]}}
            \\
        , .{});
        return;
    }
    std.debug.print("MCP servers ({d}):\n", .{app.mcp_sessions.items.len});
    for (app.mcp_sessions.items) |*entry| {
        std.debug.print("  \x1b[36m{s}\x1b[0m  ({d} tools registered as {s}__*)\n", .{ entry.name, entry.session.bindings.items.len, entry.name });
    }
}

/// /agents：列出可用的 sub-agent 能力。当前无独立 agent 定义文件系统，
/// agent 通过内建 Agent 工具内联 spawn——这里说明可用性 + 嵌套上限。
fn handleAgents(app: *app_mod.App) !void {
    _ = app;
    std.debug.print(
        \\Sub-agents:
        \\  Agent (built-in tool) — spawn an isolated sub-agent for a focused sub-task.
        \\    The sub-agent shares the same tool set + permissions as the parent and
        \\    runs in its own conversation (does not pollute the parent context).
        \\    Max nesting depth: 3.  Args: prompt (required), description, max_turns.
        \\
        \\Note: file-based agent definitions (~/.cc-zig/agents/<name>.md) are not yet
        \\loaded; a future release will let you register named agents with custom
        \\system prompts + tool allowlists.
        \\
    , .{});
}

/// /permissions：显示当前权限模式 + 已从 config.json 加载的细粒度规则。
fn handlePermissions(app: *app_mod.App) void {
    std.debug.print("permission mode: \x1b[36m{s}\x1b[0m\n", .{@tagName(app.permission_ctx.mode)});
    if (app.rule_set) |rs| {
        if (rs.rules.items.len == 0) {
            std.debug.print("rules: (none)\n", .{});
        } else {
            std.debug.print("rules ({d}):\n", .{rs.rules.items.len});
            for (rs.rules.items) |r| {
                const dec = switch (r.decision) {
                    .allow => "allow",
                    .deny => "deny",
                    .ask => "ask",
                };
                std.debug.print("  [{s}] tool={s}", .{ dec, r.tool });
                if (r.command_prefix) |p| std.debug.print(" command_prefix=\"{s}\"", .{p});
                if (r.path_glob) |g| std.debug.print(" path_glob=\"{s}\"", .{g});
                std.debug.print("\n", .{});
            }
        }
    } else {
        std.debug.print("rules: (none loaded — add a permission_rules array to ~/.cc-zig/config.json)\n", .{});
    }
}

/// /memory：跨 session 记忆，存于 ~/.cc-zig/memory.md。
///   /memory            显示全部
///   /memory add <text> 追加一条（带时间戳）
fn handleMemory(app: *app_mod.App, allocator: std.mem.Allocator, rest: []const u8) !void {
    _ = app;
    const home_c = std.c.getenv("HOME") orelse {
        std.debug.print("HOME not set\n", .{});
        return;
    };
    const home = std.mem.span(home_c);

    if (std.mem.startsWith(u8, rest, "add ")) {
        const text = std.mem.trim(u8, rest[4..], " \t");
        if (text.len == 0) {
            std.debug.print("usage: /memory add <text>\n", .{});
            return;
        }
        try appendMemory(allocator, home, text);
        std.debug.print("remembered.\n", .{});
        return;
    }

    // 显示
    const content = readMemory(allocator, home) catch null;
    defer if (content) |c| allocator.free(c);
    if (content) |c| {
        if (c.len == 0) {
            std.debug.print("(memory is empty — use /memory add <text>)\n", .{});
        } else {
            std.debug.print("{s}", .{c});
            if (c[c.len - 1] != '\n') std.debug.print("\n", .{});
        }
    } else {
        std.debug.print("(no memory yet — use /memory add <text>)\n", .{});
    }
}

fn memoryPath(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.cc-zig/memory.md", .{home});
}

fn appendMemory(allocator: std.mem.Allocator, home: []const u8, text: []const u8) !void {
    const dir_z = try std.fmt.allocPrintSentinel(allocator, "{s}/.cc-zig", .{home}, 0);
    defer allocator.free(dir_z);
    _ = std.c.mkdir(dir_z.ptr, 0o700);

    const path = try memoryPath(allocator, home);
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = std.c.open(path_z.ptr, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.WriteError;
    defer _ = std.c.close(fd);

    const line = try std.fmt.allocPrint(allocator, "- {s}\n", .{text});
    defer allocator.free(line);
    _ = std.c.write(fd, line.ptr, line.len);
}

fn readMemory(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    const path = try memoryPath(allocator, home);
    defer allocator.free(path);
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return error.NotFound;
    defer _ = std.c.close(fd);
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &chunk) catch break;
        if (n == 0) break;
        try buf.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    return try buf.toOwnedSlice(allocator);
}

/// 把预置 prompt 注入为 user message 后触发一次 agent_loop 执行。
fn runInjectedAgent(app: *app_mod.App, allocator: std.mem.Allocator, writer: *DebugWriter) !void {
    const usage_sink = app.usageSink();
    const jobs_ptr: ?*@import("../core/job_registry.zig").JobRegistry = if (app.jobs) |*jr| jr else null;
    const result = agent_loop.run(
        &app.conversation,
        &app.api_client,
        app.tool_defs,
        &app.permission_ctx,
        .{ .verbose = app.config.verbose, .abort = &app.abort, .read_state = &app.read_state, .usage_sink = usage_sink, .jobs = jobs_ptr, .plan_prev_mode = &app.plan_prev_mode, .tasks = &app.tasks, .api_client = &app.api_client, .tool_defs = app.tool_defs, .system_prompt = app.system_prompt, .dyn_registry = &app.dyn_registry },
        writer,
        allocator,
    ) catch |err| {
        std.debug.print("\x1b[31mError: {s}\x1b[0m\n", .{@errorName(err)});
        return;
    };
    app.persistTranscript();
    if (result.stop_reason == .aborted) {
        std.debug.print("\x1b[33m^C (cancelled)\x1b[0m\n", .{});
        app.abort.resetForTesting();
    }
}

/// /resume：rest == "" 时列出最近 session；rest 是 session id 时加载。
fn handleResume(app: *app_mod.App, allocator: std.mem.Allocator, rest: []const u8) !void {
    const home_c = std.c.getenv("HOME") orelse {
        std.debug.print("no HOME env set\n", .{});
        return;
    };
    const home = std.mem.span(home_c);

    const cwd = util_fs.getCwd(allocator) catch {
        std.debug.print("getcwd failed\n", .{});
        return;
    };
    defer allocator.free(cwd);

    if (rest.len == 0) {
        const list = transcript_mod.listSessions(cwd, home, allocator) catch |err| {
            std.debug.print("listSessions failed: {s}\n", .{@errorName(err)});
            return;
        };
        defer transcript_mod.freeSessionList(list, allocator);

        if (list.len == 0) {
            std.debug.print("No previous sessions in this project.\n", .{});
            return;
        }

        const show = @min(list.len, 10);
        std.debug.print("Recent sessions (most recent first):\n", .{});
        for (list[0..show], 0..) |e, i| {
            const title = if (e.title.len == 0) "(no title)" else e.title;
            std.debug.print("  \x1b[36m{d})\x1b[0m \x1b[90m{s}\x1b[0m  {s}  ({d} msgs, model={s})\n", .{ i + 1, e.id, title, e.message_count, e.model });
        }
        std.debug.print("\nUse /resume <id> (or /resume <N>) to load a session.\n", .{});
        return;
    }

    // rest 是 session id 或纯数字（对应列表位置 1..N）
    const list = transcript_mod.listSessions(cwd, home, allocator) catch |err| {
        std.debug.print("listSessions failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer transcript_mod.freeSessionList(list, allocator);

    var target_path: ?[]const u8 = null;
    // 先尝试解析成数字
    if (std.fmt.parseInt(usize, rest, 10) catch null) |n| {
        if (n >= 1 and n <= list.len) target_path = list[n - 1].path;
    }
    if (target_path == null) {
        // 按 id 精确匹配 / 前缀匹配
        for (list) |e| {
            if (std.mem.eql(u8, e.id, rest) or std.mem.startsWith(u8, e.id, rest)) {
                target_path = e.path;
                break;
            }
        }
    }
    const path = target_path orelse {
        std.debug.print("No session matching '{s}'\n", .{rest});
        return;
    };

    // 事务性加载：先在临时 conversation 加载，成功后才 atomic 切换。
    // 失败时保持原 conversation 和 writer 不变，用户下次输入仍写到原 session。
    const Conversation = @import("../core/conversation.zig").Conversation;
    var staged = Conversation.init(app.allocator);
    // ownership 转移标志：true 时下面的 errdefer 不释放（已交给 app.conversation）。
    // 不用 errdefer staged.deinit() 是因为 Zig 的 errdefer 无法 cancel；
    // 在 ownership 转移后若后续 error，errdefer 会 double-free。
    var staged_owned_here = true;
    errdefer if (staged_owned_here) staged.deinit();

    transcript_mod.loadTranscript(&staged, path, allocator) catch |err| {
        std.debug.print("load failed: {s} (session state unchanged)\n", .{@errorName(err)});
        staged.deinit();
        staged_owned_here = false;
        return;
    };

    // 预构造新 writer（dup 可能 OOM，放在切换之前）
    const dir_owned = try app.allocator.dupe(u8, path);
    errdefer app.allocator.free(dir_owned);
    const new_writer = transcript_mod.Writer.openExisting(
        app.allocator,
        dir_owned,
        app.config.model,
        staged.len(),
    );

    // 到这里所有操作已经成功：真正 atomic 切换。
    app.conversation.deinit();
    app.conversation = staged;
    staged_owned_here = false; // ownership 已转移给 app.conversation
    if (app.transcript_writer) |*w| w.deinit();
    app.transcript_writer = new_writer;

    std.debug.print("Resumed session ({d} messages). Continue by sending a message.\n", .{app.conversation.len()});
}

/// 最小 writer，把格式化输出走 stderr（与 std.debug.print 同通道）。
const DebugWriter = struct {
    pub fn print(_: *@This(), comptime fmt: []const u8, args: anytype) !void {
        std.debug.print(fmt, args);
    }
};
