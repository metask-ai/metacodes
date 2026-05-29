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

    // 启动 prompt 建议:基于 git 最近改动的文件给一条灰色提示(对齐 Claude Code)
    printStartupSuggestion(allocator);

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
        // 检查到期的 cron 任务 —— 把它们的 prompt 作为 user message 注入并跑一轮
        try fireDueCrons(app, allocator, &writer);

        if (tty) statusline.render(app);
        std.debug.print("> ", .{});

        const line = if (tty)
            readLineRaw(stdin_fd, allocator, &history, app) catch |err| switch (err) {
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
                \\  /theme [variant] Show/switch TUI theme (auto/dark/light/mono)
                \\  /add-dir <path>  Grant read/write access to an extra directory
                \\  /memory [add ..] Show or append cross-session memory
                \\  /commit          Draft a git commit using the model
                \\  /btw <q>         Side question (uses context, not added to history)
                \\  /recap           One-line summary of this session
                \\  /vim             Toggle vim editor mode
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
        // /btw <question>:侧问,不进对话历史(用临时 conversation 跑一次)
        if (std.mem.startsWith(u8, trimmed, "/btw ")) {
            try handleBtw(app, allocator, std.mem.trim(u8, trimmed[5..], " \t"));
            continue;
        }
        // /recap:生成会话一行总结(不进历史)
        if (std.mem.eql(u8, trimmed, "/recap")) {
            try handleRecap(app, allocator);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/vim")) {
            app.config.vim_mode = !app.config.vim_mode;
            std.debug.print("editor mode: \x1b[36m{s}\x1b[0m\n", .{if (app.config.vim_mode) "vim" else "emacs"});
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
        if (std.mem.startsWith(u8, trimmed, "/theme")) {
            const rest = std.mem.trim(u8, trimmed[6..], " \t");
            handleTheme(app, rest);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/add-dir")) {
            const rest = std.mem.trim(u8, trimmed[8..], " \t");
            if (rest.len == 0) {
                std.debug.print("usage: /add-dir <path>\n", .{});
            } else {
                app.addDirectory(rest) catch |e| {
                    std.debug.print("/add-dir failed: {s}\n", .{@errorName(e)});
                    continue;
                };
                std.debug.print("added directory: {s}\n", .{rest});
            }
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/memory")) {
            const rest = std.mem.trim(u8, trimmed[7..], " \t");
            try handleMemory(app, allocator, rest);
            continue;
        }

        // 用户显式 /<skill-name> [args] 触发 — 在内建命令之后兜底。
        // 必须以 / 开头且看起来像 skill 名(无 / 之外的特殊字符)。
        if (trimmed.len > 1 and trimmed[0] == '/' and try handleSkillInvocation(app, allocator, trimmed[1..])) {
            continue;
        }
        // ! shell mode:直接执行 shell 命令,输出加入对话上下文(不走模型)
        if (trimmed.len > 1 and trimmed[0] == '!') {
            try handleShellMode(app, allocator, std.mem.trim(u8, trimmed[1..], " \t"));
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

        // 新一条 user message → 清掉上一次 skill 激活的临时白/黑名单
        app.clearActiveSkill();

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
            .{ .verbose = app.config.verbose, .abort = &app.abort, .read_state = &app.read_state, .usage_sink = usage_sink, .jobs = jobs_ptr, .plan_prev_mode = &app.plan_prev_mode, .tasks = &app.tasks, .api_client = &app.api_client, .tool_defs = app.tool_defs, .system_prompt = app.system_prompt, .dyn_registry = &app.dyn_registry, .activate_skill_state = @ptrCast(app), .activate_skill_fn = &app_mod.App.activateSkillTrampoline, .project_dir = app.project_dir_or_empty(), .agents = &app.agents, .parent_model = app.config.model, .skills_set = &app.skills, .worktree_state = @ptrCast(app), .worktree_push_fn = &app_mod.App.worktreePushTrampoline, .worktree_pop_fn = &app_mod.App.worktreePopTrampoline, .mcp_sessions = &app.mcp_sessions.items, .cron_registry = &app.cron_registry, .sandbox = app.sandboxPtr(), .cwd_abs = app.cwdAbs(), .home_dir = app.homeDir() },
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

fn readLineRaw(fd: std.c.fd_t, allocator: std.mem.Allocator, history: *history_mod.History, app: *app_mod.App) ![]u8 {
    const orig = input.enterRawMode(fd) orelse {
        // 无法进 raw mode：退化
        return readLineBuffered(allocator);
    };
    defer input.restoreMode(fd, orig);

    var editor = input.LineEditor.init(allocator);
    defer editor.deinit();

    var parser = input.KeyParser{};

    // vim 模式状态(仅 app.config.vim_mode 时生效)。默认 INSERT,Esc 进 NORMAL。
    const vim = @import("vim.zig");
    var vim_state = vim.VimState.init(allocator);
    defer vim_state.deinit();

    while (true) {
        var b: [1]u8 = undefined;
        const n = posix.read(fd, &b) catch return error.ReadError;
        if (n == 0) return error.Eof;

        // vim 模式 + NORMAL/VISUAL:字节路由到 vim 状态机(Enter/Esc 例外)
        if (app.config.vim_mode and vim_state.mode != .insert) {
            if (b[0] == '\r' or b[0] == '\n') {
                std.debug.print("\n", .{});
                return try allocator.dupe(u8, editor.view());
            }
            const changed = vim.handleNormal(&vim_state, &editor.buf, &editor.cursor, allocator, b[0]) catch false;
            if (changed) try redrawLine(editor.view(), editor.cursor);
            continue;
        }

        const key = parser.feed(b[0]) orelse continue;

        // vim INSERT 模式下 Esc → 回 NORMAL(不走 LineEditor 的 esc 语义)
        if (app.config.vim_mode and key == .esc) {
            vim_state.mode = .normal;
            if (editor.cursor > 0) editor.cursor -= 1; // vim 习惯:Esc 后光标左移一格
            try redrawLine(editor.view(), editor.cursor);
            continue;
        }

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
            .cycle_perm_mode => {
                // Claude Code Shift+Tab 标准循环:default → acceptEdits → plan → default
                // (auto/dontAsk/bypassPermissions 不在默认循环;通过 CLI flag 启用)
                app.config.permission_mode = switch (app.config.permission_mode) {
                    .default, .prompt => .accept_edits,
                    .accept_edits => .plan,
                    .plan => .default,
                    // 非循环模式按下也回 default
                    .auto, .dont_ask, .bypass_permissions, .bypass => .default,
                };
                app.permission_ctx.mode = app.config.permission_mode;
                std.debug.print("\r\x1b[2K\x1b[36m[permission mode: {s}]\x1b[0m\n", .{@tagName(app.config.permission_mode)});
                std.debug.print("> ", .{});
                try redrawLine(editor.view(), editor.cursor);
            },
            .redraw_screen => {
                std.debug.print("\x1b[2J\x1b[H", .{});
                std.debug.print("> ", .{});
                try redrawLine(editor.view(), editor.cursor);
            },
            .toggle_task_list => {
                printTaskList(app);
                std.debug.print("> ", .{});
                try redrawLine(editor.view(), editor.cursor);
            },
            .open_transcript => {
                input.restoreMode(fd, orig); // 暂退 raw mode 让 viewer 自管
                const tv = @import("transcript_viewer.zig");
                tv.runWithTheme(fd, allocator, &app.conversation, termRows(), app.theme) catch {};
                _ = input.enterRawMode(fd);
                std.debug.print("> ", .{});
                try redrawLine(editor.view(), editor.cursor);
            },
            .kill_background => {
                const killed = killAllBackground(app);
                std.debug.print("\r\x1b[2K\x1b[33m[killed {d} background task(s)]\x1b[0m\n> ", .{killed});
                try redrawLine(editor.view(), editor.cursor);
            },
            .external_edit => {
                input.restoreMode(fd, orig);
                if (externalEdit(allocator, editor.view())) |edited| {
                    defer allocator.free(edited);
                    editor.setLine(edited) catch {};
                } else |_| {}
                _ = input.enterRawMode(fd);
                std.debug.print("> ", .{});
                try redrawLine(editor.view(), editor.cursor);
            },
            .clear_draft => {
                // 把当前 draft 存入历史(Up 可恢复),然后清空
                if (editor.view().len > 0) {
                    history.append(editor.view()) catch {};
                }
                editor.reset();
                std.debug.print("\r\x1b[2K> ", .{});
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
    if (sp_mod.buildWithSkillsAndAgents(allocator, new_model, &app.skills, &app.agents)) |sp| {
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
    const home_c = std.c.getenv("HOME") orelse {
        std.debug.print("HOME not set\n", .{});
        return;
    };
    const home = std.mem.span(home_c);
    const cfg_path = try std.fmt.allocPrint(allocator, "{s}/.cc-zig/config.json", .{home});
    defer allocator.free(cfg_path);

    if (rest.len == 0 or std.mem.eql(u8, rest, "show")) {
        // 当前生效配置(menu-style 摘要)
        std.debug.print("\x1b[1mActive configuration\x1b[0m\n", .{});
        std.debug.print("  model:           \x1b[36m{s}\x1b[0m\n", .{app.config.model});
        std.debug.print("  permission mode: \x1b[36m{s}\x1b[0m  \x1b[2m(Shift+Tab to cycle)\x1b[0m\n", .{@tagName(app.config.permission_mode)});
        std.debug.print("  verbose:         {}\n", .{app.config.verbose});
        std.debug.print("  no_theme:        {}\n", .{app.config.no_theme});
        std.debug.print("  skills loaded:   {d}\n", .{app.skills.len()});
        std.debug.print("  subagents:       {d}\n", .{app.agents.len()});
        std.debug.print("  MCP servers:     {d}\n", .{app.mcp_sessions.items.len});
        std.debug.print("\x1b[2mconfig file: {s}\x1b[0m\n", .{cfg_path});
        // 尝试读全文
        const path_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{cfg_path}, 0);
        defer allocator.free(path_z);
        const fd = std.c.open(path_z.ptr, std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) {
            std.debug.print("(file does not exist — use /init to create one)\n", .{});
            return;
        }
        defer _ = std.c.close(fd);
        std.debug.print("\x1b[1mfile contents:\x1b[0m\n", .{});
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

/// 把当前 conversation 拍平成纯文本(role: text),用于 /btw /recap 的上下文喂养。
fn flattenConversation(app: *app_mod.App, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (app.conversation.messages.items) |m| {
        const role = switch (m.role) {
            .user => "User",
            .assistant => "Assistant",
        };
        for (m.blocks) |b| switch (b) {
            .text => |t| {
                try out.appendSlice(allocator, role);
                try out.appendSlice(allocator, ": ");
                try out.appendSlice(allocator, t);
                try out.append(allocator, '\n');
            },
            else => {},
        };
    }
    return try out.toOwnedSlice(allocator);
}

/// 用临时 subagent 跑一个不进主历史的查询(/btw /recap 共用)。
fn runEphemeral(app: *app_mod.App, allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    const subagent = @import("../core/subagent.zig");
    const result = try subagent.spawnAgent(
        allocator,
        &app.api_client,
        app.tool_defs,
        &app.permission_ctx,
        &app.abort,
        prompt,
        .{ .max_turns = 1, .agent_depth = 1 }, // 单轮,无工具(纯回答)
    );
    defer result.deinit();
    return try allocator.dupe(u8, result.final_text);
}

/// /btw <question>:侧问。看当前对话上下文,但不进主历史。
fn handleBtw(app: *app_mod.App, allocator: std.mem.Allocator, question: []const u8) !void {
    if (question.len == 0) {
        std.debug.print("usage: /btw <question>\n", .{});
        return;
    }
    const ctx_text = try flattenConversation(app, allocator);
    defer allocator.free(ctx_text);
    const prompt = try std.fmt.allocPrint(allocator,
        "Here is the current conversation so far:\n\n{s}\n\nSide question (answer concisely from context only, do not use tools): {s}",
        .{ ctx_text, question });
    defer allocator.free(prompt);

    const answer = runEphemeral(app, allocator, prompt) catch |err| {
        std.debug.print("\x1b[31m/btw failed: {s}\x1b[0m\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(answer);
    std.debug.print("\x1b[2m─── btw ───\x1b[0m\n{s}\n\x1b[2m───────────\x1b[0m\n", .{answer});
}

/// /recap:一行会话总结(不进历史)。
fn handleRecap(app: *app_mod.App, allocator: std.mem.Allocator) !void {
    if (app.conversation.len() < 2) {
        std.debug.print("(not enough conversation to recap)\n", .{});
        return;
    }
    const ctx_text = try flattenConversation(app, allocator);
    defer allocator.free(ctx_text);
    const prompt = try std.fmt.allocPrint(allocator,
        "Summarize this session in ONE concise line (what was worked on, current state):\n\n{s}",
        .{ctx_text});
    defer allocator.free(prompt);

    const recap = runEphemeral(app, allocator, prompt) catch |err| {
        std.debug.print("\x1b[31m/recap failed: {s}\x1b[0m\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(recap);
    std.debug.print("\x1b[36m↻ {s}\x1b[0m\n", .{std.mem.trim(u8, recap, " \n")});
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

/// /agents:列出已加载的 subagent 定义(builtin / personal / project / plugin)。
fn handleAgents(app: *app_mod.App) !void {
    if (app.agents.len() == 0) {
        std.debug.print("(no subagents loaded)\n", .{});
        return;
    }

    // 按来源分组打印
    const Origin = @import("../agents/def.zig").Origin;
    const origins = [_]struct { tag: Origin, label: []const u8, color: []const u8 }{
        .{ .tag = .builtin, .label = "Built-in", .color = "\x1b[33m" },
        .{ .tag = .personal, .label = "Personal", .color = "\x1b[36m" },
        .{ .tag = .project, .label = "Project", .color = "\x1b[32m" },
        .{ .tag = .plugin, .label = "Plugin", .color = "\x1b[35m" },
        .{ .tag = .cli, .label = "CLI", .color = "\x1b[34m" },
    };

    std.debug.print("\x1b[1mAvailable subagents ({d})\x1b[0m\n", .{app.agents.len()});
    for (origins) |og| {
        var first = true;
        for (app.agents.agents.items) |*a| {
            if (a.origin != og.tag) continue;
            if (first) {
                std.debug.print("\n{s}{s}\x1b[0m:\n", .{ og.color, og.label });
                first = false;
            }
            // tools 提示
            const tools_label = if (a.tools.len == 0) "(inherits parent tools)" else "";
            std.debug.print("  \x1b[1m{s}\x1b[0m — {s}\n", .{ a.name, a.description });
            if (a.tools.len > 0) {
                std.debug.print("    tools: ", .{});
                for (a.tools, 0..) |t, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}", .{t});
                }
                std.debug.print("\n", .{});
            } else {
                std.debug.print("    {s}\n", .{tools_label});
            }
            if (a.disallowed_tools.len > 0) {
                std.debug.print("    disallowed: ", .{});
                for (a.disallowed_tools, 0..) |t, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}", .{t});
                }
                std.debug.print("\n", .{});
            }
            if (!std.mem.eql(u8, a.model, "inherit") and a.model.len > 0) {
                std.debug.print("    model: {s}\n", .{a.model});
            }
            if (a.permission_mode) |m| {
                std.debug.print("    permissionMode: {s}\n", .{@tagName(m)});
            }
            if (a.preload_skills.len > 0) {
                std.debug.print("    preloaded skills: ", .{});
                for (a.preload_skills, 0..) |s, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}", .{s});
                }
                std.debug.print("\n", .{});
            }
            if (a.source_path.len > 0) {
                std.debug.print("    \x1b[2msource: {s}\x1b[0m\n", .{a.source_path});
            }
        }
    }

    std.debug.print(
        \\
        \\Use via the `Task` tool: `Task(subagent_type="<name>", description="...", prompt="...")`.
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

    // 新 schema settings 层(permissions.allow/ask/deny)
    if (app.settings) |*s| {
        std.debug.print("\nsettings layers ({d}):\n", .{s.layers.len});
        for (s.layers) |L| {
            std.debug.print("  [{s}] allow={d} ask={d} deny={d}\n", .{
                @tagName(L.source), L.allow.len, L.ask.len, L.deny.len,
            });
            for (L.allow) |r| std.debug.print("      allow: {s}\n", .{r.raw});
            for (L.ask) |r| std.debug.print("      ask:   {s}\n", .{r.raw});
            for (L.deny) |r| std.debug.print("      deny:  {s}\n", .{r.raw});
            for (L.additional_directories) |d| std.debug.print("      +dir:  {s}\n", .{d});
        }
        if (s.isBypassDisabled()) std.debug.print("  disableBypassPermissionsMode: true\n", .{});
        if (s.isAutoModeDisabled()) std.debug.print("  disableAutoMode: true\n", .{});
    }
}

/// /theme:列当前 / 切预设(dark / light / mono / auto)
fn handleTheme(app: *app_mod.App, rest: []const u8) void {
    const theme_mod = @import("tui/theme.zig");
    const tui_term = @import("tui/term.zig");
    if (rest.len == 0) {
        const variants = [_][]const u8{ "auto", "dark", "light", "mono" };
        std.debug.print("current theme: \x1b[36m{s}\x1b[0m\n", .{theme_mod.variantName(app.theme_variant)});
        std.debug.print("available: ", .{});
        for (variants, 0..) |v, i| {
            std.debug.print("{s}{s}", .{ v, if (i + 1 < variants.len) ", " else "" });
        }
        std.debug.print("\nusage: /theme <variant>\n", .{});
        return;
    }
    const variant = theme_mod.parseVariant(rest) orelse {
        std.debug.print("unknown theme '{s}'. try: auto, dark, light, mono\n", .{rest});
        return;
    };
    app.theme_variant = variant;
    const cap = tui_term.detectFromEnv(1);
    app.theme = theme_mod.select(variant, cap);
    std.debug.print("theme switched to \x1b[36m{s}\x1b[0m\n", .{theme_mod.variantName(variant)});

    // 持久化到 ~/.cc-zig/config.json
    const tui_config = @import("tui/config.zig");
    const home = std.c.getenv("HOME");
    if (home) |h| {
        const home_slice = std.mem.span(h);
        // 临时 arena 给 saveTheme 用
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        tui_config.saveTheme(arena.allocator(), home_slice, variant) catch |e| {
            std.debug.print("\x1b[2m(persist failed: {s})\x1b[0m\n", .{@errorName(e)});
            return;
        };
        std.debug.print("\x1b[2m(saved to ~/.cc-zig/config.json)\x1b[0m\n", .{});
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

/// 用户显式 /<skill-name> [args] 调用。
/// 返回 true 表示已处理(skill 命中或不存在但语法看起来像 skill 名);
/// false 表示不是 skill 调用,继续走普通用户消息。
///
/// 处理流程:
/// 1. 拆 head [args...](shell-style 引号)
/// 2. head 在 skillset 找;没找到 → 友好提示后返 true(避免被当成普通消息发给模型)
/// 3. 找到 → 构造 user message 写入 transcript "/name [args]"
///    然后**直接调用 Skill 工具**(explicit_invocation=true),把结果作为 user-side
///    tool_result 形态注入 conversation(模拟 Skill 工具被用户那边触发了一次)。
/// 4. 让 agent_loop 跑一轮 — 模型基于激活的 skill 内容回应。
fn handleSkillInvocation(app: *app_mod.App, allocator: std.mem.Allocator, rest: []const u8) !bool {
    // 拆 head + args(空格分;不深入引号支持,使用 skills/tool.zig 内的 parseShellQuoted 通过 Skill tool args 处理)
    var head_end: usize = 0;
    while (head_end < rest.len and rest[head_end] != ' ' and rest[head_end] != '\t') : (head_end += 1) {}
    const head = rest[0..head_end];
    if (head.len == 0) return false;

    // 不允许嵌套斜杠/其它特殊字符 — 那不像 skill 名
    for (head) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != ':') return false;
    }

    // 是否真有这个 skill
    if (app.skills.find(head) == null) return false;

    const args_tail = std.mem.trim(u8, rest[head_end..], " \t");

    // 构造 Skill 工具 args:用 args 字符串透传(parseShellQuoted 在 tool.zig 内拆)
    var skill_args_buf: std.Io.Writer.Allocating = .init(allocator);
    defer skill_args_buf.deinit();
    try skill_args_buf.writer.writeAll("{\"name\":");
    try std.json.Stringify.encodeJsonString(head, .{}, &skill_args_buf.writer);
    if (args_tail.len > 0) {
        try skill_args_buf.writer.writeAll(",\"args\":");
        try std.json.Stringify.encodeJsonString(args_tail, .{}, &skill_args_buf.writer);
    }
    try skill_args_buf.writer.writeByte('}');
    const skill_args_json = try skill_args_buf.toOwnedSlice();
    defer allocator.free(skill_args_json);

    // 直接调 Skill 工具(绕过模型) — 通过 dyn_registry
    const skill_entry = app.dyn_registry.find("Skill") orelse {
        std.debug.print("\x1b[31m/{s}: Skill tool not registered\x1b[0m\n", .{head});
        return true;
    };
    // 上一个 user message 是新的 → 清掉之前的激活态
    app.clearActiveSkill();
    var tool_ctx = @import("../tools.zig").ToolContext{
        .allocator = allocator,
        .abort = &app.abort,
        .read_state = &app.read_state,
        .permission_ctx = &app.permission_ctx,
        .dyn_registry = &app.dyn_registry,
        .activate_skill_state = @ptrCast(app),
        .activate_skill_fn = &app_mod.App.activateSkillTrampoline,
        .explicit_invocation = true, // 关键:用户显式触发,disable-model-invocation 跳过
        .project_dir = app.project_dir_or_empty(),
        .session_id = "",
    };
    const skill_result = skill_entry.execute(&tool_ctx, skill_args_json, skill_entry.ctx_ptr) catch |err| {
        std.debug.print("\x1b[31m/{s}: skill activation failed: {s}\x1b[0m\n", .{ head, @errorName(err) });
        return true;
    };
    defer allocator.free(skill_result);

    // 把命令和激活结果作为用户消息注入 conversation
    const user_msg = if (args_tail.len > 0)
        try std.fmt.allocPrint(allocator, "/{s} {s}", .{ head, args_tail })
    else
        try std.fmt.allocPrint(allocator, "/{s}", .{head});
    defer allocator.free(user_msg);
    try app.conversation.appendText(.user, user_msg);

    // 把渲染好的 skill 内容紧接其后,作为一段额外 user 上下文(skill 激活的标准做法)
    try app.conversation.appendText(.user, skill_result);

    // 显示给用户看
    std.debug.print("\x1b[36m{s}\x1b[0m\n", .{skill_result});

    // 让模型基于激活态回应
    var writer = DebugWriter{};
    const usage_sink = app.usageSink();
    const jobs_ptr: ?*@import("../core/job_registry.zig").JobRegistry = if (app.jobs) |*jr| jr else null;
    const result = agent_loop.run(
        &app.conversation,
        &app.api_client,
        app.tool_defs,
        &app.permission_ctx,
        .{ .verbose = app.config.verbose, .abort = &app.abort, .read_state = &app.read_state, .usage_sink = usage_sink, .jobs = jobs_ptr, .plan_prev_mode = &app.plan_prev_mode, .tasks = &app.tasks, .api_client = &app.api_client, .tool_defs = app.tool_defs, .system_prompt = app.system_prompt, .dyn_registry = &app.dyn_registry, .activate_skill_state = @ptrCast(app), .activate_skill_fn = &app_mod.App.activateSkillTrampoline, .project_dir = app.project_dir_or_empty(), .sandbox = app.sandboxPtr(), .cwd_abs = app.cwdAbs(), .home_dir = app.homeDir() },
        &writer,
        allocator,
    ) catch |err| {
        std.debug.print("\x1b[31mError after /{s}: {s}\x1b[0m\n", .{ head, @errorName(err) });
        return true;
    };
    app.persistTranscript();
    if (result.stop_reason == .aborted) app.abort.resetForTesting();
    return true;
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

/// 启动建议:跑 `git log` 找最近改动文件,给一条灰色提示。失败静默。
fn printStartupSuggestion(allocator: std.mem.Allocator) void {
    if (std.c.isatty(1) == 0) return; // 非 TTY 不显示
    const argv = [_]?[*:0]const u8{ "/usr/bin/env", "git", "log", "-1", "--name-only", "--pretty=format:", null };
    const out = @import("../tools/common.zig").spawnCaptureStdoutAbortableTimed(argv[0..], allocator, null, 2000) catch return;
    defer allocator.free(out);
    // 取第一个非空行作为最近改动文件
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const f = std.mem.trim(u8, line, " \t\r");
        if (f.len == 0) continue;
        std.debug.print("\x1b[2m  suggestion: explain or improve {s}\x1b[0m\n\n", .{f});
        return;
    }
}

/// 取终端行数(失败回退 24)。
fn termRows() usize {
    var ws: std.c.winsize = undefined;
    const TIOCGWINSZ: c_ulong = if (@import("builtin").os.tag == .macos) 0x40087468 else 0x5413;
    if (std.c.ioctl(1, TIOCGWINSZ, &ws) == 0 and ws.row > 0) return ws.row;
    return 24;
}

/// Ctrl+G:把当前 buffer 写临时文件,开 $VISUAL/$EDITOR 编辑,读回。
/// 返回编辑后的内容(owned)。失败返 error。
fn externalEdit(allocator: std.mem.Allocator, current: []const u8) ![]u8 {
    const editor_env = std.c.getenv("VISUAL") orelse std.c.getenv("EDITOR") orelse return error.NoEditor;
    const editor_cmd = std.mem.span(editor_env);

    const tmp_path = "/tmp/cc-zig-edit-buffer.txt";
    // 写当前 buffer
    {
        const fd = std.c.open(tmp_path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.WriteFailed;
        defer _ = std.c.close(fd);
        if (current.len > 0) _ = std.c.write(fd, current.ptr, current.len);
    }

    // spawn editor(继承 stdin/stdout/stderr,前台阻塞)
    const editor_z = try allocator.dupeZ(u8, editor_cmd);
    defer allocator.free(editor_z);
    const path_z = try allocator.dupeZ(u8, tmp_path);
    defer allocator.free(path_z);
    var argv = [_]?[*:0]const u8{ "/bin/sh", "-c", undefined, null };
    const sh_cmd = try std.fmt.allocPrintSentinel(allocator, "{s} {s}", .{ editor_cmd, tmp_path }, 0);
    defer allocator.free(sh_cmd);
    argv[2] = sh_cmd.ptr;

    const pid = std.c.fork();
    if (pid == 0) {
        _ = std.c.execve("/bin/sh", @ptrCast(&argv), @ptrCast(std.c.environ));
        std.c._exit(127);
    } else if (pid < 0) {
        return error.ForkFailed;
    }
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    // 读回
    const rfd = std.c.open(path_z.ptr, std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (rfd < 0) return error.ReadFailed;
    defer _ = std.c.close(rfd);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(rfd, &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    _ = std.c.unlink(path_z.ptr);
    // 去掉编辑器常加的尾换行
    var result = try out.toOwnedSlice(allocator);
    if (result.len > 0 and result[result.len - 1] == '\n') {
        result = try allocator.realloc(result, result.len - 1);
    }
    return result;
}

/// 杀所有 running 后台任务,返回杀掉的数量。
fn killAllBackground(app: *app_mod.App) usize {
    const jobs = if (app.jobs) |*j| j else return 0;
    var killed: usize = 0;
    // 收集 running id(避免迭代中改 collection)
    for (jobs.jobs.items) |*j| {
        if (j.status != .running) continue;
        var id_copy: [12]u8 = j.id;
        jobs.kill(id_copy[0..]) catch continue;
        killed += 1;
    }
    return killed;
}

/// Ctrl+T:打印任务列表(最多 5 个,带状态图标)。覆盖到 prompt 上方。
fn printTaskList(app: *app_mod.App) void {
    const tasks = app.tasks.tasks.items;
    std.debug.print("\r\x1b[2K", .{}); // 清当前行
    if (tasks.len == 0) {
        std.debug.print("\x1b[2m(no tasks)\x1b[0m\n", .{});
        return;
    }
    std.debug.print("\x1b[1mTasks ({d}):\x1b[0m\n", .{tasks.len});
    var shown: usize = 0;
    for (tasks) |t| {
        if (t.status == .deleted) continue;
        if (shown >= 5) {
            std.debug.print("  \x1b[2m... more\x1b[0m\n", .{});
            break;
        }
        const icon = switch (t.status) {
            .pending => "\x1b[90m○\x1b[0m", // 灰圈
            .in_progress => "\x1b[33m◐\x1b[0m", // 黄半
            .completed => "\x1b[32m●\x1b[0m", // 绿实
            .deleted => unreachable,
        };
        std.debug.print("  {s} {s}\n", .{ icon, t.subject });
        shown += 1;
    }
}

/// ! shell mode:执行 shell 命令,实时输出 + 加入对话上下文(不经模型审批/解释)。
fn handleShellMode(app: *app_mod.App, allocator: std.mem.Allocator, command: []const u8) !void {
    if (command.len == 0) return;
    // 直接调 Bash 工具 execute(走 bypass — 用户显式 ! 等于授权)
    const bash = @import("../tools/bash.zig");
    var tool_ctx = @import("../tools.zig").ToolContext{
        .allocator = allocator,
        .abort = &app.abort,
        .jobs = if (app.jobs) |*j| j else null,
    };
    // 组 args JSON
    var args_buf: std.Io.Writer.Allocating = .init(allocator);
    defer args_buf.deinit();
    try args_buf.writer.writeAll("{\"command\":");
    try std.json.Stringify.encodeJsonString(command, .{}, &args_buf.writer);
    try args_buf.writer.writeByte('}');
    const args_json = try args_buf.toOwnedSlice();
    defer allocator.free(args_json);

    const result = bash.execute(&tool_ctx, args_json) catch |err| {
        std.debug.print("\x1b[31m! error: {s}\x1b[0m\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(result);

    // 显示 stdout/stderr(从 result JSON 抽)
    const common = @import("../tools/common.zig");
    if (common.extractJsonArg(result, "stdout")) |so| {
        const unesc = @import("../util/json.zig").unescapeString(so, allocator) catch null;
        if (unesc) |u| {
            defer allocator.free(u);
            if (u.len > 0) std.debug.print("{s}", .{u});
        }
    }
    if (common.extractJsonArg(result, "stderr")) |se| {
        const unesc = @import("../util/json.zig").unescapeString(se, allocator) catch null;
        if (unesc) |u| {
            defer allocator.free(u);
            if (u.len > 0) std.debug.print("\x1b[33m{s}\x1b[0m", .{u});
        }
    }

    // 把命令 + 输出加入对话上下文(让模型后续能引用)
    const ctx_msg = try std.fmt.allocPrint(allocator, "[shell] $ {s}\n{s}", .{ command, result });
    defer allocator.free(ctx_msg);
    try app.conversation.appendText(.user, ctx_msg);
}

/// 检查到期 cron,逐个把其 prompt 作为 user message 注入并跑一轮 agent_loop。
fn fireDueCrons(app: *app_mod.App, allocator: std.mem.Allocator, writer: *DebugWriter) !void {
    const due = app.cron_registry.collectDue(allocator) catch return;
    defer {
        for (due) |p| allocator.free(p);
        allocator.free(due);
    }
    for (due) |prompt| {
        std.debug.print("\x1b[2m[cron fired]\x1b[0m {s}\n", .{prompt});
        try app.conversation.appendText(.user, prompt);
        try runInjectedAgent(app, allocator, writer);
    }
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
