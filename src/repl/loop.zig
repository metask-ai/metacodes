//! REPL 主循环（M4 完整版）。
//!
//! 行为：
//! - tty 输入：raw mode + LineEditor（↑↓←→/Home/End/Ctrl+A/E/U/K）+ History + Markdown 渲染
//! - 非 tty 输入（pipe / 重定向 / CI）：退化到行缓冲模式（保持 M0 行为，便于自动化测试）
//! - 多行：行尾 `\` 续行；独占 `"""` 切换块模式（M4.4 Accumulator）
//! - 命令：/help /clear /tools /exit /retry /compact /history
//! - Ctrl+C：输入阶段 → 清 buffer（ISIG=false 让字节 0x03 落到 LineEditor）；生成阶段 → SIGINT → app.abort

const std = @import("std");
const pfs = @import("platform").fs;
const platform_signal = @import("platform").signal;
const platform_term = @import("platform").terminal;
const posix = std.posix;
const app_mod = @import("../app.zig");
const Conversation = @import("../core/conversation.zig").Conversation;
const tools = @import("../tools.zig");
const agent_loop = @import("../core/agent_loop.zig");
const input = @import("input.zig");
const complete = @import("complete.zig");
const paste_mod = @import("paste.zig");
const history_mod = @import("history.zig");
const multiline_mod = @import("multiline.zig");
const render_mod = @import("render.zig");
const transcript_mod = @import("../core/transcript.zig");
const transcript_viewer = @import("transcript_viewer.zig");
const progress = @import("progress.zig");
const render_region_mod = @import("tui/render_region.zig");
const agent_job_registry_mod = @import("../core/agent_job_registry.zig");
const msg_queue_mod = @import("msg_queue.zig");
const tui_term_root = @import("tui/term.zig");
const util_fs = @import("../util/fs.zig");
const ui_backend_mod = @import("../core/protocol/ui_backend.zig");
const writer_backend_mod = @import("../core/writer_backend.zig");
const tee_backend_mod = @import("../core/tee_backend.zig");
const diagnostics_backend_mod = @import("../core/diagnostics_backend.zig");
const evaluation_backend_mod = @import("../core/evaluation_backend.zig");
const tui_backend_mod = @import("tui/tui_backend.zig");
const terminal_title = @import("tui/terminal_title.zig");
const goal_mod = @import("../core/goal.zig");
const usage_mod = @import("../core/usage.zig");
const types_mod = @import("../types.zig");
const dialect_mod = @import("../api/dialect.zig");
const request_overrides = @import("../api/request_overrides.zig");
const util_time = @import("../util/time.zig");
const model_command = @import("model_command.zig");
const skill_cli_adapter = @import("../skills/cli_adapter.zig");

/// 把 CoreEvent 的字节写到 std.debug.print(stderr)——非 TTY 交互 / cron / skill 等场景。
/// 对齐旧 DebugWriter.print 行为。
fn debugSink(_: *anyopaque, bytes: []const u8) void {
    std.debug.print("{s}", .{bytes});
}

/// 建一个走 std.debug.print 的 WriterBackend(colorize=true 复刻旧 DebugWriter 继承的默认)。
fn debugBackend(verbose: bool, show_retry: bool, usage_acc: ?*@import("../core/usage.zig").UsageTotals) writer_backend_mod.WriterBackend {
    return .{ .sink_ctx = undefined, .sink = debugSink, .colorize = true, .verbose = verbose, .show_retry = show_retry, .usage_acc = usage_acc };
}

pub fn run(app: *app_mod.App, allocator: std.mem.Allocator) !void {
    // Evaluation is opt-in and fail-closed: without METACODES_EVAL_METADATA no
    // object is created; when set, malformed/incomplete grounding aborts before
    // any rollout can be mistaken for comparable evidence.
    var eval_runtime = try evaluation_backend_mod.RuntimeConfig.fromEnvironment(allocator);
    defer if (eval_runtime) |*runtime| runtime.deinit();

    printStartupBanner(app);

    // 启动 prompt 建议:基于 git 最近改动的文件给一条灰色提示(对齐 Claude Code)
    printStartupSuggestion(allocator);

    // 顶层 REPL 的辅助 backend(cron/skill/retry 等非主对话路径用):走 std.debug.print。
    // 主对话路径在生成期单独构造 TuiBackend/WriterBackend(见下)。
    var aux_wb = debugBackend(app.config.verbose, true, &app.usage);
    const aux_be = aux_wb.backend();
    var history = history_mod.History.init(allocator);
    defer history.deinit();

    // 历史文件路径：~/.metacodes/history
    const hist_path = try historyPath(allocator);
    defer allocator.free(hist_path);
    history.loadFromFile(hist_path) catch {};
    defer history.saveToFile(hist_path) catch {};

    const stdin_fd: c_int = 0;
    const tty = platform_term.isatty(stdin_fd);

    // 终端 tab 标题反映 session 状态(idle/working/需要输入)。仅 tty;退出时清空。
    if (tty) terminal_title.setFromApp(app, .idle);
    defer if (tty) terminal_title.clear();

    // 工具 progress 心跳:tty 下经 agent_loop Options.spawn_tick_fn 传入(per-session,非全局)。
    // 非 TTY 不接(避免污染 pipe 输出)。具体在每次 run() 的 Options 里设 .spawn_tick_fn。
    const spawn_tick: ?*const fn (u64, []const u8) void = if (tty) &progress.progressCb else null;

    // 待发送队列:生成期用户按回车提交的消息进此队列;本轮 LLM 结束后,主循环从队首
    // 逐条取出作为后续 input 续发,直到队空(对齐 Claude Code commandQueue)。
    var msg_queue = msg_queue_mod.MsgQueue.init(allocator);
    defer msg_queue.deinit();

    while (true) {
        // 检查到期的 cron 任务 —— 把它们的 prompt 作为 user message 注入并跑一轮
        try fireDueCrons(app, allocator, &aux_be);

        // Swarm lead 邮箱轮询(turn 边界):teammate 的回复/idle 通知在两轮之间拉进来,
        // 入队当作下一轮 user input(idle→立即;有 draft→排在队尾)。**SW5 债**:idle 阻塞在
        // readLineRaw 时的实时注入需接进输入 poll 循环(见 readLineRaw poll,当前需按回车触发)。
        if (app.swarm.hasTeam()) {
            if (@import("../swarm/tools.zig").pollLeadInbox(allocator, &app.swarm) catch null) |pulled| {
                _ = msg_queue.push(pulled);
                allocator.free(pulled);
            }
        }

        if (shouldRunLoopContinuation(app, msg_queue.len())) {
            try runLoopContinuation(app, allocator, &aux_be);
            continue;
        }

        // tty:输入框(含状态/footer)由 readLineRaw 内的 RenderRegion 自画(钉底)。
        // 非 tty:保留裸 "> " prompt 供 pipe 模式可读。
        const has_queued = msg_queue.len() > 0;
        if (!tty and !has_queued) std.debug.print("> ", .{});

        const line = if (msg_queue.popAllJoined("\n\n")) |q| blk: {
            // 待发送队列消费:上一轮生成期入队的(可能多条)消息一次性合并 → 本轮 input,
            // 回显 ❯ <内容> 到 scrollback。多条用空行分隔合成一次提交(对齐 cc 同模式批量)。
            echoUserSubmission(app, q);
            break :blk q; // q owned,与 readLine 返回所有权一致
        } else if (tty)
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
            // 空提交(空串/纯空白)→ 无操作,留在 REPL(对齐真 cc:空 enter 不做事、不退出)。
            // 退出只由真 EOF 触发:tty 由 readLineRaw 抛 error.Eof(上方 91-94),
            // 非 tty 由 readLineBuffered 抛 error.Eof(573 行起,read 返 0)。空串≠EOF。
            // 历史 bug:Warp 下 shift+enter 发裸 \n → 提交空 buffer → 旧代码当 EOF 退出整个程序。
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
                \\  /goal [cmd]      View/manage the session goal
                \\  /loop [cmd]      View/control automatic continuation
                \\  /doctor          Show environment/config diagnostics
                \\  /config [show|path]  Inspect config (~/.metacodes/config.json)
                \\  /init            Analyze the codebase and write CLAUDE.md (model-driven)
                \\  /mcp             List configured MCP servers
                \\  /agents          List available sub-agent capabilities
                \\  /permissions     Show permission mode + loaded rules
                \\  /theme [variant] Show/switch TUI theme (auto/dark/light/mono)
                \\  /add-dir <path>  Add a working directory (accept-edits auto-accept + sandbox write)
                \\  /memory [edit <slot>]  List memory files; edit user|project|local|auto in $EDITOR
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
        // 行首单独 `?` → 快捷键帮助(对齐 CC `?` for shortcuts)。仅整行 trim 后 == "?" 触发,
        // 不拦截含 ? 的正常句子。
        // 注:tty 下 `?` 由 dispatch 即时拦截 → 非模态 footer 区展开(help_open,见 ui.zig),
        // 永不提交到这;此分支是 headless/非-tty fallback(headless 无 footer 区,`?` 提交后打帮助文本)。
        if (std.mem.eql(u8, trimmed, "?")) {
            std.debug.print(
                \\Keyboard shortcuts:
                \\  Enter              Submit
                \\  Shift+Enter        Insert newline (CSI-u terminals)
                \\  Ctrl+A / Ctrl+E    Start / end of line
                \\  Alt+B / Alt+F      Word back / forward
                \\  Ctrl+U / Ctrl+K    Kill to start / end of line
                \\  Ctrl+W             Delete previous word
                \\  Ctrl+Y             Yank (paste last kill)
                \\  Ctrl+_             Undo
                \\  Ctrl+R             Reverse history search
                \\  Up / Down          History prev / next
                \\  Ctrl+L             Clear screen
                \\  Ctrl+T             Toggle task list
                \\  Ctrl+O             Open transcript viewer
                \\  Ctrl+G             Edit buffer in $EDITOR
                \\  Shift+Tab          Cycle permission mode
                \\  Ctrl+X Ctrl+K      Kill background tasks
                \\  Esc                Interrupt current task
                \\  Esc Esc            Clear draft (when idle)
                \\  Ctrl+C             Cancel / exit (twice when empty)
                \\  Ctrl+D             EOF / exit when empty
                \\  !<cmd>             Run shell command
                \\  /help              List commands
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
        // /task-test[:label] —— 测试专用:造一个 in_progress 任务驱动 TaskTab 渲染。
        // 无网/离线即可验证 TaskTab(任务通常靠模型 TaskCreate 产生,离线无从触发)。
        if (std.mem.eql(u8, trimmed, "/task-test") or std.mem.startsWith(u8, trimmed, "/task-test:")) {
            const label = if (trimmed.len > 11) trimmed[11..] else "test task running";
            const t = app.tasks.create(label, "test", label) catch {
                std.debug.print("[task-test] create failed\n", .{});
                continue;
            };
            app.tasks.updateStatus(t.id, .in_progress) catch {};
            continue;
        }
        // /task-test-done[:label] —— 测试专用:造一个 completed 任务,离线驱动完成态图标(✓)渲染。
        if (std.mem.eql(u8, trimmed, "/task-test-done") or std.mem.startsWith(u8, trimmed, "/task-test-done:")) {
            const label = if (trimmed.len > 16) trimmed[16..] else "test task done";
            const t = app.tasks.create(label, "test", label) catch {
                std.debug.print("[task-test-done] create failed\n", .{});
                continue;
            };
            app.tasks.updateStatus(t.id, .completed) catch {};
            continue;
        }
        // /agent-test[:desc] —— 测试专用:注册一个假 running subagent(无线程/无网络),
        // 离线驱动 agent 进度树渲染。
        if (std.mem.eql(u8, trimmed, "/agent-test") or std.mem.startsWith(u8, trimmed, "/agent-test:")) {
            const desc = if (trimmed.len > 12) trimmed[12..] else "inspect repo";
            if (app.agent_jobs) |*aj| {
                aj.pushTestEntryFull("Explore", desc, 1, 17300, "Read", "{\"file_path\":\"/Users/x/mod0.py\"}", .running) catch {
                    std.debug.print("[agent-test] push failed\n", .{});
                };
            }
            continue;
        }
        // /agent-test-multi —— 测试专用:造 3 个不同状态 Explore agent(驱动完整进度树
        // 三态 + 标题分组 + switcher)。① mid-tool(有 tokens) ② Initializing(0 tool) ③ Done。
        if (std.mem.eql(u8, trimmed, "/agent-test-multi")) {
            if (app.agent_jobs) |*aj| {
                aj.pushTestEntryFull("Explore", "Summarize mod0.py", 1, 17300, "Read", "{\"file_path\":\"/Users/x/mod0.py\"}", .running) catch {};
                aj.pushTestEntryFull("Explore", "Summarize mod1.py", 0, 0, "", "", .running) catch {};
                aj.pushTestEntryFull("Explore", "Summarize mod2.py", 3, 17700, "", "", .done) catch {};
                // 给首个 agent 填假 output_buf,使 viewing 它时能看到对话视口(离线 tty 测试用)。
                if (aj.entries.items.len > 0) {
                    const e0 = aj.entries.items[0];
                    e0.output_buf.appendSlice(aj.allocator,
                        \\⏺ 我来分析 mod0.py 的结构。
                        \\  ⎿ Read: /Users/x/mod0.py
                        \\⏺ 这是一个数据处理模块,核心是 transform 函数。
                        \\  ⎿ Grep: def transform
                        \\⏺ transform 在第 42 行,负责把原始记录归一化。
                        \\
                    ) catch {};
                }
            }
            continue;
        }
        // /agent-churn-test —— 测试专用:**离线确定性复现 bug#2**(生成期 spinner 遗留进 scrollback)。
        // 真模型才触发的条件 = subagent 树在生成期**动态变行数** + spinner tick + emit 交替。这里用
        // 临时 RenderRegion 离线驱动:enterGenerating → 循环{tickSpinner + 增 agent(树长高)+ 偶尔
        // writeGenText emit} → leaveGenerating。无网络/无真模型。若固定区 erase 几何在树长高时失准,
        // spinner 行会漏擦遗留进 scrollback(tty 测试数最终屏 spinner 行数 >1 = bug)。
        if (std.mem.eql(u8, trimmed, "/agent-churn-test") and tty) {
            if (app.agent_jobs) |*aj| {
                var creg = render_region_mod.RenderRegion.init(allocator, 2, app.theme, tui_term_root.detectFromEnv(1));
                defer creg.deinit();
                creg.enterGenerating(app, &msg_queue);
                var i: usize = 0;
                while (i < 12) : (i += 1) {
                    // 每 3 轮加一个 running agent → 进度树行数递增(模拟 subagent 陆续 spawn)。
                    if (i % 3 == 0 and aj.entries.items.len < 4) {
                        var nbuf: [32]u8 = undefined;
                        const desc = std.fmt.bufPrint(&nbuf, "subagent task {d}", .{aj.entries.items.len}) catch "task";
                        aj.pushTestEntryFull("Explore", desc, @intCast(i), @intCast(i * 100), "Bash", "{\"command\":\"x\"}", .running) catch {};
                    }
                    creg.tickSpinner(app); // 重画固定区(spinner + 当前高度的进度树)
                    // 偶尔 emit 一行进 scrollback(模拟主 agent 产文本/工具卡)。
                    if (i % 2 == 1) creg.writeGenText("⏺ main agent step\n");
                }
                creg.leaveGenerating(app);
                // 清掉测试 agent(不污染后续)。
                aj.clearTestEntries();
            }
            std.debug.print("\x1b[2m[agent-churn-test] done\x1b[0m\n", .{});
            continue;
        }
        // 供离线 tty 验证 Ctrl+O transcript 渲染等效(markdown 渲染、无 ▶/◀ 角色头、进出无源码残留)。
        if (std.mem.eql(u8, trimmed, "/md-test")) {
            app.conversation.appendText(.user, "你是谁") catch {};
            app.conversation.appendText(.assistant, "我是 **MetaCode**,一个本地 `CLI` 编程助手。\n- 阅读代码\n- 调试 bug") catch {};
            std.debug.print("\x1b[2m[md-test] 注入 1 user + 1 assistant(含 markdown)\x1b[0m\n", .{});
            continue;
        }
        if (std.c.getenv("METACODES_TEST_HOOKS") != null and std.mem.eql(u8, trimmed, "/compact-stress-test")) {
            try injectCompactStressHistory(app, allocator);
            std.debug.print("\x1b[2m[compact-stress-test] injected large history\x1b[0m\n", .{});
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/skills")) {
            if (app.skills.len() == 0) {
                std.debug.print("No skills installed. Put SKILL.md files under ~/.agents/skills/<name>/ or <project>/.agents/skills/<name>/\n", .{});
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
            // U2 S1:压缩逻辑下沉 App.compactWindow(与 web 共用),渲染留此。
            // 投影:len() 不变(原始不删),真正收缩的是活跃窗口 → 显示活跃计数,否则 N→N 误导用户。
            const r = app.compactWindow();
            std.debug.print("Compacted {d} old messages ({d} → {d} active).\n", .{ r.dropped, r.before, r.after });
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/goal") or std.mem.startsWith(u8, trimmed, "/goal ")) {
            const rest = std.mem.trim(u8, trimmed[5..], " \t");
            try handleGoal(app, rest);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/loop") or std.mem.startsWith(u8, trimmed, "/loop ")) {
            const rest = std.mem.trim(u8, trimmed[5..], " \t");
            handleLoop(app, rest);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/retry")) {
            try retryLast(app, allocator, &aux_be);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/kg") or std.mem.startsWith(u8, trimmed, "/kg ")) {
            const rest = std.mem.trim(u8, trimmed[3..], " \t");
            try handleKg(app, allocator, rest);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/cost")) {
            const u = app.usage;
            const cost = u.costUsd(app.activeModel());
            std.debug.print(
                \\Usage ({s}):
                \\  input         {d} tokens
                \\  output        {d} tokens
                \\  cache read    {d} tokens
                \\  cache create  {d} tokens
                \\  total cost    ${d:.6} USD
                \\
            , .{ app.activeModel(), u.input_tokens, u.output_tokens, u.cache_read_input_tokens, u.cache_creation_input_tokens, cost });
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/models")) {
            std.debug.print("/models is an interactive picker: choose an API key first, then choose a model. Use /model for text filters.\n", .{});
            continue;
        }
        // /model [name] —— 无参列当前 + 可选模型；有参切换
        if (std.mem.eql(u8, trimmed, "/model") or std.mem.startsWith(u8, trimmed, "/model ")) {
            const rest = std.mem.trim(u8, trimmed[6..], " \t");
            try handleModel(app, allocator, rest);
            continue;
        }
        // /effort [level] —— 无参显示当前 reasoning_effort;有参切换(none|minimal|low|medium|high|xhigh)
        if (std.mem.eql(u8, trimmed, "/effort") or std.mem.startsWith(u8, trimmed, "/effort ")) {
            const rest = std.mem.trim(u8, trimmed[7..], " \t");
            try handleEffort(app, allocator, rest);
            continue;
        }
        // /overrides [field value | clear] —— 查看/清/单字段设方言覆盖
        if (std.mem.eql(u8, trimmed, "/overrides") or std.mem.startsWith(u8, trimmed, "/overrides ")) {
            const rest = std.mem.trim(u8, trimmed[10..], " \t");
            try handleOverridesCmd(app, allocator, rest);
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
            // 对齐 cc:prompt 型命令——注入指令让模型扫码库写 CLAUDE.md(走正常 agent_loop)。
            try app.conversation.appendText(.user, INIT_PROMPT);
            try runInjectedAgent(app, allocator, &aux_be);
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
            const on = app.toggleVim(); // U2 S1:状态下沉 App.toggleVim,渲染留此
            std.debug.print("editor mode: \x1b[36m{s}\x1b[0m\n", .{if (on) "vim" else "emacs"});
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
        if (std.mem.eql(u8, trimmed, "/memory") or std.mem.startsWith(u8, trimmed, "/memory ")) {
            const rest = std.mem.trim(u8, trimmed[7..], " \t");
            try handleMemory(app, allocator, rest);
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
            try runInjectedAgent(app, allocator, &aux_be);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/review")) {
            try app.conversation.appendText(.user, REVIEW_PROMPT);
            try runInjectedAgent(app, allocator, &aux_be);
            continue;
        }
        // 用户显式 /<skill-name> [args] 触发。所有内建 Command 已先消费，
        // 因而同名 Skill 不会劫持 /review、/commit 等产品路由。
        if (trimmed.len > 0 and trimmed[0] == '/') {
            switch (try skill_cli_adapter.handleSlash(app, allocator, trimmed[1..])) {
                .handled => continue,
                .unknown_command => {
                    std.debug.print("Unknown command or unavailable Skill: {s}\n", .{trimmed});
                    continue;
                },
                .not_a_command => {},
            }
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
            const home_c = @import("platform").paths.homeDir() orelse break :blk null;
            break :blk paste_mod.expandPlaceholders(allocator, home_c, final_input) catch null;
        };
        defer if (expanded) |e| allocator.free(e);
        try app.conversation.appendText(.user, expanded orelse final_input);

        // 生成期间底部状态栏(spinner + 实时 token/cost)。仅 tty。
        // RenderRegion 在生成期维护一个底部 spinner 行;agent_loop 的文本输出经
        // RegionWriter 与 spinner 协调(文本来时擦 spinner,tick 在文本下方重画)。
        var gen_region: ?render_region_mod.RenderRegion = if (tty)
            render_region_mod.RenderRegion.init(allocator, 2, app.theme, tui_term_root.detectFromEnv(1))
        else
            null;
        defer if (gen_region) |*r| r.deinit();
        if (gen_region) |*r| r.enterGenerating(app, &msg_queue);
        if (tty) terminal_title.setFromApp(app, .working); // tab:生成中

        var region_writer: ?render_region_mod.RegionWriter =
            if (gen_region) |*r| .{ .region = r } else null;

        // 生成期间也要 raw mode:readLineRaw 返回时已 restoreMode(回 cooked),
        // cooked 下内核按行缓冲,未按 Enter 的键不会被 watcher 的 read 读到 → 边等边打字被吞。
        // 重进 raw 让 watcher 能逐字节读到输入(编辑 / 回车入队 / Esc 中断)。
        const gen_raw_orig = if (tty) input.enterRawMode(stdin_fd) else null; // ?platform.terminal.SavedMode
        defer if (gen_raw_orig) |o| input.restoreMode(stdin_fd, o);

        const jobs_ptr: ?*@import("../core/job_registry.zig").JobRegistry = if (app.jobs) |*j| j else null;
        // UI backend:TUI 路径用 TuiBackend(包 region,渲染工具卡 + 颜色 + owns 生成期键盘输入);
        // 非 TTY 用 WriterBackend(走 std.debug.print)。两者实现同一 UiBackend vtable。
        // 阶段 C:生成期 stdin watcher 线程归 TuiBackend(startInput/stopInput),loop 不再硬编码。
        //
        // 生命周期约束(隐式但必须守):`tui_be` 必须在整个生成期(直到 stopInput 返回)保持
        // 栈存活且**地址不被移动**。`ui_be.ctx` = `@ptrCast(&tui_be.?)`(经 `if(tui_be)|*tb|`
        // capture,指向 optional payload 在 tui_be 内部的稳定地址),watcher 线程的 `self` 也是
        // 同一地址——agent_loop(emit)与 watcher(键盘)共享这一个 TuiBackend 实例。
        // 不要把 tui_be 重新赋值 / 搬移 / 放进会 realloc 的容器,否则两个指针指向坟墓。
        var tui_be: ?tui_backend_mod.TuiBackend = if (region_writer) |*rw|
            .{ .region = rw.region, .theme = &app.theme, .alloc = allocator, .edit_hl_cache = &app.edit_hl_cache, .colorize = true, .verbose = app.config.verbose, .show_retry = true, .usage_acc = &app.usage, .queue = &msg_queue, .abort_signal = &app.abort, .input_abort = &app.abort }
        else
            null;
        var fallback_be = debugBackend(app.config.verbose, true, &app.usage);
        const ui_be: ui_backend_mod.UiBackend = if (tui_be) |*tb| tb.backend() else fallback_be.backend();

        // L4:METACODES_TRACE 开启时,旁挂 DiagnosticsBackend(经 TeeBackend 转发)收集结构化
        // trace,run 结束后 dump 成 NDJSON 到 stderr。关闭时直接用 ui_be,零开销。
        const trace_on = std.c.getenv("METACODES_TRACE") != null;
        var diag_be = diagnostics_backend_mod.DiagnosticsBackend.init(allocator);
        defer diag_be.deinit();
        var diag_ui = diag_be.backend();
        var tee = tee_backend_mod.TeeBackend{ .primary = &ui_be, .secondary = &diag_ui };
        const tee_ui = tee.backend();
        const traced_be: *const ui_backend_mod.UiBackend = if (trace_on) &tee_ui else &ui_be;
        defer if (trace_on) {
            const jsonl = diag_be.toJsonl(allocator) catch null;
            if (jsonl) |j| {
                defer allocator.free(j);
                std.debug.print("{s}", .{j});
            }
        };

        // Native evaluation events are a second decorator over the normal UI
        // (and optional diagnostics decorator). Each user submission is one
        // invocation inside the execution-grounded scenario rollout.
        var eval_be: ?evaluation_backend_mod.EvaluationBackend = if (eval_runtime) |*runtime| blk: {
            const active_provider = app.provider();
            runtime.configureBudgetReserve(
                active_provider.maxInputTokens(),
                active_provider.maxTokens(),
                app.activeModel(),
            );
            const evaluation = try runtime.initEvaluation(allocator, runtime.nextMetadata(
                @tagName(app.config.provider_kind),
                app.activeModel(),
                @tagName(app.permission_ctx.modeValue()),
            ));
            break :blk evaluation;
        } else null;
        const eval_request_gate = if (eval_runtime) |*runtime|
            runtime.requestGate(&app.abort)
        else
            null;
        defer if (eval_be) |*evaluation| {
            if (eval_runtime) |*runtime| {
                runtime.appendEvaluation(evaluation) catch |err| {
                    std.debug.print("evaluation artifact write failed: {s}\n", .{@errorName(err)});
                };
            }
            evaluation.deinit();
        };
        var eval_ui: ui_backend_mod.UiBackend = if (eval_be) |*evaluation| evaluation.backend() else ui_be;
        var eval_tee = tee_backend_mod.TeeBackend{ .primary = traced_be, .secondary = &eval_ui };
        const eval_tee_ui = eval_tee.backend();
        const effective_be: *const ui_backend_mod.UiBackend = if (eval_be != null) &eval_tee_ui else traced_be;

        // 生成期键盘监听:仅 tty + 有 TuiBackend 时启动(回车入队 / Esc 中断 / 超时 tickSpinner)。
        if (tty) {
            if (tui_be) |*tb| try tb.startInput(stdin_fd, app, allocator);
        }
        // 权限弹窗 UI runner:有 TuiBackend 时注入到 per-session permission_ctx(终端接管路径:
        // 停 watcher+持锁,不抢 fd0)。生成期结束统一清(defer),避免悬垂指向 tui_be 栈实例。
        if (tui_be) |*tb| {
            app.permission_ctx.ui_requester = .{ .ctx = @ptrCast(tb), .requestFn = &tui_backend_mod.TuiBackend.uiRequestTrampoline };
        }
        defer if (tui_be != null) {
            app.permission_ctx.ui_requester = null;
        };
        const usage_before = app.usage;
        const mode_before = app.permission_ctx.modeValue();
        const started_ns = util_time.nowNs();
        // scoped 自动召回(一等公民 P1):按用户请求自动装配相关记忆到尾部(cache-safe,有命中才注入)。
        const scoped_recall = if (app.kg) |*k| (scoped_recall_mod.build(allocator, k, &app.conversation, &app.abort) catch null) else null;
        defer if (scoped_recall) |s| allocator.free(s);
        const result = agent_loop.run(
            &app.conversation,
            app.provider(),
            app.tool_defs,
            &app.permission_ctx,
            .{ .session = app.session_id, .verbose = app.config.verbose, .abort = &app.abort, .request_gate = eval_request_gate, .background_request = &app.background_request, .read_state = &app.read_state, .edit_hl_cache = &app.edit_hl_cache, .lsp = app.lsp_service, .jobs = jobs_ptr, .agent_jobs = if (app.agent_jobs) |*aj| aj else null, .swarm = &app.swarm, .plan_prev_mode = &app.plan_prev_mode, .tasks = &app.tasks, .kg = if (app.kg) |*k| k else null, .kg_projects_dir = app.kg_projects_dir, .memdir_abs = app.memdir_abs, .api_client = app.anthropicClientOrNull(), .tool_defs = app.tool_defs, .system_prompt = app.system_prompt, .inject_user_context = app.user_context, .synthetic_user_input = scoped_recall, .max_turns = maxTurnsFromEnv(), .cost_budget_usd = costBudgetFromEnv(), .dyn_registry = &app.dyn_registry, .host_services = app.hostServices(), .activated_tools = &app.activated_tools, .project_dir = app.project_dir_or_empty(), .agents = &app.agents, .parent_model = app.activeModel(), .model_switch_compact = app.pendingModelSwitchCompact(), .skills_set = &app.skills, .ui_requester = if (tui_be) |*tb| .{ .ctx = @as(*anyopaque, @ptrCast(tb)), .requestFn = &tui_backend_mod.TuiBackend.uiRequestTrampoline } else null, .mcp_sessions = &app.mcp_sessions.items, .cron_registry = &app.cron_registry, .sandbox = app.sandboxPtr(), .cwd_abs = app.cwdAbs(), .additional_dirs = app.additionalDirs(), .home_dir = app.homeDir(), .plan_file_path = app.plan_file_path, .emit_tool_cards = true, .spawn_tick_fn = spawn_tick },
            effective_be,
            allocator,
        ) catch |err| {
            // 停 watcher + 清 stdin 缓冲
            if (tui_be) |*tb| tb.stopInput();
            if (gen_region) |*r| r.leaveGenerating(app);
            if (tty) terminal_title.setFromApp(app, .idle); // tab:回空闲
            if (tty) drainStdin(stdin_fd);
            app.clearPendingModelSwitchCompact();
            std.debug.print("\x1b[31mError: {s}\x1b[0m\n", .{@errorName(err)});
            continue;
        };
        app.clearPendingModelSwitchCompact();
        accountGoalUsageAfterRun(app, usage_before, mode_before, started_ns);
        // 停 watcher + 清 stdin 缓冲（生成期间用户可能误按的键，别污染下一轮）
        if (tui_be) |*tb| tb.stopInput();
        if (gen_region) |*r| r.leaveGenerating(app);
        if (tty) terminal_title.setFromApp(app, .idle); // tab:回空闲
        if (tty) drainStdin(stdin_fd);

        // 每轮结束 flush transcript（含错误 / abort 路径；只要有变动都想落盘）
        app.persistTranscript();

        // L3:挂起 → 落 suspend.json + 提示恢复方式。释放 suspend_info(owned)。
        if (result.suspend_info) |si| {
            defer si.deinit();
            if (app.sessionDir()) |dir| {
                const suspend_state = @import("../core/suspend_state.zig");
                suspend_state.writeFromSuspendInfo(dir, si, allocator) catch {};
                std.debug.print("\x1b[36m⏸ Suspended (kind={s}) — resume from: {s}\x1b[0m\n", .{ si.kind, dir });
            }
        }

        // U2 S2:删掉 config←ctx sync-back hack。permission_mode 单一源=permission_ctx.mode,
        // footer/border/statusline 都读 app.permMode()(=ctx),工具改 ctx 即时反映,无需回同步。
        // (旧版双存储靠此 hack 补,web 侧漏了它→/state 陈旧 bug task#14;单一源后根治。)

        if (app.abort.reason() == .evaluation_budget)
            return error.EvaluationBudgetExhausted;

        if (result.stop_reason == .aborted) {
            std.debug.print("\x1b[33m^C (cancelled)\x1b[0m\n", .{});
            app.abort.resetForTesting();
        }

        // 撞 backstop(防呆兜底,非防跑飞主闸):非静默 + 续接出口,不自动续(把"是否失控"
        // 交给唯一持全局意图的人——对齐 codex 只在有 pending 输入才续)。
        if (result.stop_reason == .max_turns) {
            const bd = toolCallBreakdown(app, allocator);
            defer if (bd) |b| allocator.free(b);
            std.debug.print("\x1b[33m已达 {d} 轮上限(共 {d} 次工具调用)。任务可能未完成——这可能是合法长任务,也可能在原地打转。\x1b[0m\n", .{ result.turns, result.tool_calls });
            if (bd) |b| std.debug.print("\x1b[33m  动作分布:{s}\x1b[0m\n", .{b});
            std.debug.print("\x1b[33m直接输入你的下一步(如\"继续\")续接对话,或调整方向。\x1b[0m\n", .{});
        }
        // 模型 API 撞墙:带真实错误现场告知(HTTP 状态 + body 摘要),不许塌缩成猜谜文案——
        // 2026-07-12 NUL 字节 bug 排障靠抓包才看到 "Failed to parse request body" 的教训。
        if (result.stop_reason == .api_error) {
            const last_error = @import("../api/last_error.zig");
            var detail_buf: [last_error.SUMMARY_BUF_LEN]u8 = undefined;
            if (last_error.take(&detail_buf)) |detail| {
                std.debug.print("\x1b[31m模型 API 请求失败,本轮中止。\n  {s}\n可直接重试,或换模型 / 精简上下文后继续。\x1b[0m\n", .{detail});
            } else {
                std.debug.print("\x1b[31m模型 API 请求失败(重试耗尽 / 后端错误 / 上下文超限),本轮中止。\n可直接重试,或换模型 / 精简上下文后继续。\x1b[0m\n", .{});
            }
        }
        // 工具不可恢复错误撞墙:明确告知,非静默。
        if (result.stop_reason == .tool_error) {
            std.debug.print("\x1b[31m工具执行遇到不可恢复的错误,本轮中止。\n查看上方错误现场,调整后输入下一步可继续。\x1b[0m\n", .{});
        }
        // 成本预算撞墙(次闸):明确告知累计成本,非静默,不自动续——由用户决定是否继续烧钱。
        if (result.stop_reason == .budget) {
            std.debug.print("\x1b[33m已达成本预算上限(本会话累计 ${d:.4})。本轮中止——由你决定是否继续。\n直接输入\"继续\"可续接,或调高 METACODES_COST_BUDGET / 调整方向。\x1b[0m\n", .{app.usage.costUsd(app.activeModel())});
        }

        // Ctrl+B 转后台:turn 边界返回 .backgrounded。深拷贝当前对话 → spawnBackground 续跑 →
        // 成功才 reset 前台开新会话。顺序铁律:先 clone 再 spawn 再 reset(失败不 reset,保留对话重试)。
        if (result.stop_reason == .backgrounded) {
            app.background_request.store(false, .monotonic); // 复位信号(否则下一轮 run 立即又转后台)
            backgroundCurrentSession(app) catch |err| {
                std.debug.print("\x1b[31m转后台失败: {s}(对话保留前台)\x1b[0m\n", .{@errorName(err)});
            };
        }
    }
}

/// Ctrl+B:把当前主对话深拷贝转后台续跑,成功后 reset 前台开新会话。
/// 顺序铁律:① clone(registry allocator)② spawnBackground(成功后 copy 所有权转移)③ reset 前台。
/// 任一步失败 → 不 reset 前台(保留对话让用户重试),copy 在失败路径释放。
///
/// **隐性契约(D)**:后台 job 借用 app.agents/skills/dyn_registry(只读,App 生命周期)。这些在
/// 后台 job 存活期间(可数分钟)**必须保持不可变**——前台若有运行时写入路径(动态加载 skill /
/// 注册 agent),与后台读并发就是竞争。当前无此类运行时写入,安全;新增前需重新评估。
/// conversation 是深拷贝(零共享);Client/io_runtime/abort 后台专属;故唯一隐患就是上述借用集。
///
/// **MVP 简化(E)**:单击即转后台,不可逆(无 foreground-back),无双击防抖。误触代价=对话被搬走、
/// 前台清空;靠转后台后的明确提示("⤳ 已转后台续跑")让用户知道发生了什么 + 去 agent switcher 找回。
/// 双击防抖 / foreground-back 列后续增强。
fn backgroundCurrentSession(app: *app_mod.App) !void {
    const reg = if (app.agent_jobs) |*aj| aj else return error.NoBackgroundRegistry;
    if (app.conversation.len() == 0) return; // 空对话无意义,静默忽略

    // ① 深拷贝到 registry allocator(后台线程独立持有,与前台 0 共享)。
    const copy = try app.conversation.cloneInto(reg.allocator);
    // 注:spawnBackground 是 consume-on-call —— 成败都接管 copy 所有权,故此处**不**加 errdefer,
    // 也不在成功后置空(传值进去后本地 copy 只是个失效别名,不再 deinit)。

    // desc = 对话首个 text block 首句(agent tree 标题);空兜底 "main session"。
    const desc = firstUserLine(&app.conversation);

    // ② spawnBackground(prebuilt=copy)。consume 语义:成功转移给 job,失败它自己释放 copy。
    _ = try reg.spawnBackground(.{
        .prompt = "", // 忽略(prebuilt 非 null)
        .system_prompt = app.system_prompt orelse "",
        .tool_defs = app.tool_defs,
        .permission_ctx = app.permission_ctx,
        .agents = &app.agents,
        .dyn_registry = &app.dyn_registry,
        .skills = &app.skills,
        .agent_depth = 0,
        .parent_model = app.activeModel(),
        .desc = desc,
        .agent_type = "main",
        .host_services = app.hostServices(),
        // task#12(Linus review 第四处):Ctrl+B 转后台的是**主会话**(全权限+Bash),更不能丢 sandbox。
        // 前台 agent_loop 有 sandbox,转后台若不透传则主会话 Bash 突然脱离 sandbox。
        .sandbox = app.sandboxPtr(),
        .cwd_abs = app.cwdAbs(),
        .home_dir = app.homeDir(),
        .additional_dirs = app.additionalDirs(),
        .prebuilt_conversation = copy,
    });

    // ③ reset 前台开新空会话(对齐 cc:转后台后前台清空)。后台拿的是副本,前台 deinit 不影响它。
    app.conversation.deinit();
    app.conversation = Conversation.init(app.allocator);
    std.debug.print("\x1b[36m⤳ 已转后台续跑(agent tree 可见进度);前台开新会话\x1b[0m\n", .{});
}

/// 取对话首个 user text block 首句(截断 80),供 agent tree 标题。空对话返 "main session"。
fn firstUserLine(conv: *const Conversation) []const u8 {
    for (conv.messages.items) |m| {
        for (m.blocks) |b| switch (b) {
            .text => |t| {
                const trimmed = std.mem.trim(u8, t, " \t\r\n");
                if (trimmed.len == 0) continue;
                const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
                return trimmed[0..@min(end, 80)];
            },
            else => {},
        };
    }
    return "main session";
}

/// Drain stdin buffer: 非阻塞读尽剩余字节。生成结束后调用，避免用户在 LLM 输出时
/// 误按的字符进入下一轮输入缓冲。
fn drainStdin(fd: c_int) void {
    while (true) {
        if (platform_term.waitReadable(fd, 0) <= 0) return; // 可移植:timeout=0 立即返回
        var buf: [256]u8 = undefined;
        const n = platform_term.readInput(fd, buf[0..buf.len]);
        if (n <= 0) return;
    }
}

/// 非 tty / 管道模式下的朴素逐字节行读（保留 M0 行为）。
fn readLineBuffered(allocator: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        var b: [1]u8 = undefined;
        const n_i = platform_term.readInput(0, &b);
        if (n_i < 0) return error.ReadError;
        const n: usize = @intCast(n_i);
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
/// 小粘贴内联插入；大粘贴存 ~/.metacodes/pastes/<N>.txt 并插入占位符。
fn handlePaste(
    fd: c_int,
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
        const n = platform_term.readInput(fd, &b);
        if (n <= 0) break;
        const key = parser.feed(b[0]) orelse {
            // parser 处于 CSI 中间态——字节已被吞，等下一个
            continue;
        };
        // feed 可能吐两个键(ESC+普通字符):先处理 feed 的,再排空 pending。
        var k: ?input.Key = key;
        var done = false;
        while (k) |kk| {
            switch (kk) {
                .paste_end => {
                    done = true;
                    break;
                },
                .char => |c| try pasted.append(allocator, c),
                .enter => try pasted.append(allocator, '\n'),
                .tab => try pasted.append(allocator, '\t'),
                else => {}, // 粘贴里的其它控制序列忽略
            }
            k = parser.drain();
        }
        if (done) break;
    }

    const text = pasted.items;
    if (text.len == 0) return;

    if (paste_mod.isLarge(text)) {
        const home_c = @import("platform").paths.homeDir();
        if (home_c) |home| {
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

/// SIGWINCH(终端 resize)标志。handler 只 atomic-store(async-signal-safe),
/// readLineRaw 的 poll 循环超时时观察它 → 立即重画输入框自适应新宽度。
var g_winch = std.atomic.Value(bool).init(false);
/// Windows resize 轮询的上次尺寸(无 SIGWINCH,poll 超时 tick 比对;仅 REPL 单线程读写)。
var g_last_ws: ?platform_term.TermSize = null;

fn onWinch() void {
    g_winch.store(true, .release);
}

fn installSigwinch() void {
    // 可移植:POSIX=SIGWINCH sigaction;Windows no-op(resize 归 W4 ConsoleInput,见 platform/signal.zig)。
    platform_signal.installResize(onWinch);
}

/// 把提交的输入回显到 scrollback(复刻 Claude Code:提交后历史里留 "❯ <内容>")。
/// 多行内容续行对齐 2 空格;空输入只打一个换行。commit 路径 + carryover 自动提交共用。
fn echoUserSubmission(app: *app_mod.App, submitted: []const u8) void {
    if (std.mem.trim(u8, submitted, " \t\r\n").len == 0) {
        std.debug.print("\n", .{});
        return;
    }
    const th = app.theme;
    // 软折 + 2 列悬挂缩进(对齐 cc:长输入回显续行缩进 2 列,不回第 0 列)。
    const cols: usize = if (tui_term_root.getSize(1)) |s| s.cols else 80;
    const avail: usize = if (cols > 6) cols - 2 else 0; // 0 = 不折
    var first_logical = true;
    var it = std.mem.splitScalar(u8, submitted, '\n');
    while (it.next()) |seg| {
        // 每个逻辑行按显示宽软折成多段;首段带前缀(❯/续行 2 空格),软折续段恒 2 空格。
        var start: usize = 0;
        var first_seg = true;
        while (start <= seg.len) {
            const end = if (avail == 0) seg.len else wrapPointAt(seg, start, avail);
            const piece = seg[start..end];
            if (first_logical and first_seg) {
                std.debug.print("{s}❯{s} {s}\n", .{ th.accent, th.reset, piece });
            } else {
                std.debug.print("  {s}\n", .{piece});
            }
            first_seg = false;
            if (end >= seg.len) break;
            start = end;
            // 续段跳过 1 个折点空格(对齐 cc 词折:断行处的空格不带到续行行首)。
            if (start < seg.len and seg[start] == ' ') start += 1;
        }
        first_logical = false;
    }
}

/// 从 start 起返回不超过 max_w 显示宽的最大 byte 终点(至少进 1 codepoint 防死循环)。纯文本用。
fn wrapPointAt(s: []const u8, start: usize, max_w: usize) usize {
    var i = start;
    var w: usize = 0;
    while (i < s.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const e = @min(i + cp_len, s.len);
        const cw = tui_term_root.displayWidth(s[i..e]);
        if (w + cw > max_w) {
            if (i == start) return e;
            return i;
        }
        w += cw;
        i = e;
    }
    return i;
}

fn readLineRaw(fd: c_int, allocator: std.mem.Allocator, history: *history_mod.History, app: *app_mod.App) ![]u8 {
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

    // 输入期固定底部区(复刻 Claude Code:圆角输入框 + ❯ + footer + 钉底)。
    var region = render_region_mod.RenderRegion.init(allocator, 2, app.theme, tui_term_root.detectFromEnv(1));
    defer region.deinit();
    // 终端 resize 监听:SIGWINCH → 下次 poll 超时时重画自适应。
    g_winch.store(false, .release);
    installSigwinch();
    // 退出 readLineRaw 前擦掉输入框,光标回干净行(覆盖所有 return 路径)。
    defer {
        region.setInput("", 0);
        region.clear();
        std.debug.print("\x1b[?25h", .{}); // 确保光标可见
    }
    // 初始画一个空输入框。
    region.setInput(editor.view(), editor.cursor);
    region.render(app);

    // 重画当前输入框(替代旧 redrawLine):同步 editor 状态 → 重画固定区。
    const redraw = struct {
        fn call(r: *render_region_mod.RenderRegion, ed: *input.LineEditor, a: *app_mod.App) void {
            if (!complete.modelsMenuOpen(ed.view())) a.models_picker_key_index = null;
            r.setInput(ed.view(), ed.cursor);
            r.render(a);
        }
    }.call;

    while (true) {
        var b: [1]u8 = undefined;
        // synthetic_key:无新字节但需立即处理的键。两个来源:
        //  (a) parser.drain():上一轮 feed(ESC+普通字符)吐出的第二个键暂存在 pending,先消费完;
        //  (b) parser.flushEsc():孤立 ESC 在 poll 超时时兑现为 .esc。
        // pending 优先于读新字节——否则 ESC 后那个字符会被吞(早期 bug)。
        var synthetic_key: ?input.Key = parser.drain();
        // 用 poll 带超时读,而非阻塞 read:超时时检查 SIGWINCH(终端 resize)→ 立即重画
        // 输入框自适应新宽度(否则要等下次按键才更新,真机 resize 卡旧宽)。
        if (synthetic_key == null) while (true) {
            if (g_winch.swap(false, .acquire)) {
                redraw(&region, &editor, app); // resize → 重测宽度重画
            }
            const rc = platform_term.waitReadable(fd, 200); // 可移植:200ms 超时等可读
            if (rc <= 0) {
                // 超时/EINTR:若 parser 卡在 esc_seen(收到孤立 ESC 等后续字节),
                // 此时无后续字节到来 → 兑现为 .esc(否则 Esc 永远到不了 dispatch/editor)。
                if (parser.flushEsc()) |k| {
                    synthetic_key = k;
                    break;
                }
                // Windows 无 SIGWINCH:超时 tick(200ms)轮询 console 尺寸,变化置
                // g_winch 走同一重画路径(W4 ConsoleInput resize 事件的轻量替代)。
                if (@import("builtin").os.tag == .windows) {
                    if (platform_term.windowSize(fd)) |ws| {
                        if (g_last_ws == null) {
                            g_last_ws = ws;
                        } else if (ws.rows != g_last_ws.?.rows or ws.cols != g_last_ws.?.cols) {
                            g_last_ws = ws;
                            g_winch.store(true, .release);
                        }
                    }
                }
                continue; // <0=EINTR(被 SIGWINCH 中断) / 0=超时 → 回头查 flag
            }
            if (rc > 0) break; // 有字节可读
        };

        // 取键:合成键(孤立 ESC 超时兑现)优先;否则读一字节喂 parser。
        // parser.feed 返 null = 序列未完成(如刚收 ESC / CSI 中段)→ 回头继续读。
        const key = if (synthetic_key) |sk| sk else blk: {
            const n = platform_term.readInput(fd, &b);
            if (n < 0) return error.ReadError;
            if (n == 0) return error.Eof;

            // vim 模式 + NORMAL/VISUAL:字节路由到 vim 状态机(Enter/Esc 例外)
            if (app.config.vim_mode and vim_state.mode != .insert) {
                if (b[0] == '\r' or b[0] == '\n') {
                    region.setInput("", 0);
                    region.clear();
                    std.debug.print("\n", .{});
                    return try allocator.dupe(u8, editor.view());
                }
                const changed = vim.handleNormal(&vim_state, &editor.buf, &editor.cursor, allocator, b[0]) catch false;
                if (changed) redraw(&region, &editor, app);
                continue;
            }

            break :blk parser.feed(b[0]) orelse continue;
        };

        // vim INSERT 模式下 Esc → 回 NORMAL(不走 LineEditor 的 esc 语义)
        if (app.config.vim_mode and key == .esc) {
            vim_state.mode = .normal;
            if (editor.cursor > 0) editor.cursor -= 1; // vim 习惯:Esc 后光标左移一格
            redraw(&region, &editor, app);
            continue;
        }

        // 括号粘贴：收集到 paste_end，决定内联还是外部存储 + 占位符
        if (key == .paste_begin) {
            try handlePaste(fd, &editor, &parser, allocator);
            redraw(&region, &editor, app);
            continue;
        }

        // 阶段1:overlay 分流(? help / Ctrl+O transcript)。非 vim 模式才介入。
        // dispatch 判断"空 buffer + ?"依赖 editor 投影,调前同步。
        if (!app.config.vim_mode) {
            region.ui.editor = .{ .view = editor.view(), .cursor = editor.cursor };
            const eff = region.applyEvent(app, &app.conversation, .{ .key = .{ .key = key } });
            switch (eff.action) {
                .pass_to_editor => {}, // 落到下面正常编辑
                .none, .commit, .cancel, .exit => continue, // overlay 消费了(已重画),不喂 editor
                // ── 全局快捷键:dispatch 上抛 → 在此执行 IO 体(单一真相源:键解析全在 dispatch)──
                // up/down:先试多行/软折【可视行】竖移(经 RenderRegion,它持 cols 算 inner_w);
                // moved=false(光标已在首/末可视行)才回退历史导航。对齐真 cc v2.1.172。
                .cursor_up, .cursor_down => {
                    const down = eff.action == .cursor_down;
                    const r = region.tryVerticalMove(editor.view(), editor.cursor, editor.goal_vcol, down);
                    if (r.moved) {
                        editor.cursor = r.cursor;
                        editor.goal_vcol = r.goal_vcol;
                        redraw(&region, &editor, app);
                    } else {
                        editor.goal_vcol = null;
                        if (down) {
                            if (history.next()) |nxt| {
                                try editor.setLine(nxt);
                                redraw(&region, &editor, app);
                            }
                        } else {
                            if (try history.prev(editor.view())) |prev| {
                                try editor.setLine(prev);
                                redraw(&region, &editor, app);
                            }
                        }
                    }
                    continue;
                },
                // 历史导航(保留:cursor_up/down 在可视行边界回退到这两个语义;
                // 也供未来直接上抛历史的路径用)。
                .history_prev => {
                    if (try history.prev(editor.view())) |prev| {
                        try editor.setLine(prev);
                        redraw(&region, &editor, app);
                    }
                    continue;
                },
                .history_next => {
                    if (history.next()) |nxt| {
                        try editor.setLine(nxt);
                        redraw(&region, &editor, app);
                    }
                    continue;
                },
                .complete => {
                    region.clear();
                    try handleCompletion(&editor, allocator);
                    redraw(&region, &editor, app);
                    continue;
                },
                .slash_complete => {
                    // Tab on slash 菜单:把 buffer 换成选中命令名(不提交,留补参数)。
                    if (complete.slashNthMatch(editor.view(), region.ui.slash_sel)) |cmd| {
                        try editor.setLine(cmd.name);
                    }
                    redraw(&region, &editor, app);
                    continue;
                },
                .slash_select => {
                    // Enter on slash 菜单:把 buffer 换成选中命令名后提交(对齐 cc:Enter 运行选中项)。
                    // 复刻 .commit 路径(下方 editor.handle(.enter)→.commit 同款):清区 + 回显 + 返回。
                    if (complete.slashNthMatch(editor.view(), region.ui.slash_sel)) |cmd| {
                        try editor.setLine(cmd.name);
                    }
                    region.ui.slash_sel = 0;
                    region.setInput("", 0);
                    region.clear();
                    echoUserSubmission(app, editor.view());
                    return try allocator.dupe(u8, editor.view());
                },
                .model_nav => {
                    // /model 服务端 catalog 菜单 ↑↓:只在已 probe 到服务端模型时移动选择。
                    const n = @min(app.api_client.catalog.entries.items.len, complete.MODEL_MENU_MAX_ROWS);
                    if (n > 0) {
                        if (region.ui.slash_sel >= n) region.ui.slash_sel = n - 1;
                        if (eff.at_nav_dir) {
                            region.ui.slash_sel = (region.ui.slash_sel + 1) % n;
                        } else {
                            region.ui.slash_sel = if (region.ui.slash_sel == 0) n - 1 else region.ui.slash_sel - 1;
                        }
                    }
                    redraw(&region, &editor, app);
                    continue;
                },
                .model_complete, .model_select => {
                    // Tab 填入 `/model use <id>` 继续编辑;Enter 直接提交同一条命令。
                    const entries = app.api_client.catalog.entries.items;
                    if (entries.len == 0) {
                        redraw(&region, &editor, app);
                        continue;
                    }
                    const visible_n = @min(entries.len, complete.MODEL_MENU_MAX_ROWS);
                    const idx = @min(region.ui.slash_sel, visible_n - 1);
                    const line = try std.fmt.allocPrint(allocator, "/model use {s}", .{entries[idx].model_id});
                    defer allocator.free(line);
                    try editor.setLine(line);
                    region.ui.slash_sel = 0;
                    if (eff.action == .model_complete) {
                        redraw(&region, &editor, app);
                        continue;
                    }
                    region.setInput("", 0);
                    region.clear();
                    echoUserSubmission(app, editor.view());
                    return try allocator.dupe(u8, editor.view());
                },
                .models_nav => {
                    const n = if (app.models_picker_key_index == null)
                        @min(app.api_key_catalog.entries.items.len, complete.MODEL_MENU_MAX_ROWS)
                    else if (app.models_picker_model_index == null)
                        @min(app.api_client.catalog.entries.items.len, complete.MODEL_MENU_MAX_ROWS)
                    else
                        reasoningOptionCount(app);
                    if (n > 0) {
                        if (region.ui.slash_sel >= n) region.ui.slash_sel = n - 1;
                        if (eff.at_nav_dir) {
                            region.ui.slash_sel = (region.ui.slash_sel + 1) % n;
                        } else {
                            region.ui.slash_sel = if (region.ui.slash_sel == 0) n - 1 else region.ui.slash_sel - 1;
                        }
                    }
                    redraw(&region, &editor, app);
                    continue;
                },
                .models_select => {
                    if (app.models_picker_key_index == null) {
                        const keys = app.api_key_catalog.entries.items;
                        if (keys.len == 0) {
                            redraw(&region, &editor, app);
                            continue;
                        }
                        const visible_n = @min(keys.len, complete.MODEL_MENU_MAX_ROWS);
                        const idx = @min(region.ui.slash_sel, visible_n - 1);
                        app.selectApiKeyForModels(idx) catch |err| {
                            region.clear();
                            std.debug.print("\x1b[31m/model key selection failed: {s}\x1b[0m\n", .{@errorName(err)});
                        };
                        app.models_picker_model_index = null;
                        region.ui.slash_sel = 0;
                        redraw(&region, &editor, app);
                        continue;
                    }

                    if (app.models_picker_model_index == null) {
                        const entries = app.api_client.catalog.entries.items;
                        if (entries.len == 0) {
                            redraw(&region, &editor, app);
                            continue;
                        }
                        const visible_n = @min(entries.len, complete.MODEL_MENU_MAX_ROWS);
                        const idx = @min(region.ui.slash_sel, visible_n - 1);
                        app.models_picker_model_index = idx;
                        region.ui.slash_sel = 0;
                        redraw(&region, &editor, app);
                        continue;
                    }

                    const entries = app.api_client.catalog.entries.items;
                    const model_idx = app.models_picker_model_index.?;
                    if (entries.len == 0 or model_idx >= entries.len) {
                        redraw(&region, &editor, app);
                        continue;
                    }
                    var efforts_buf: [5]types_mod.ReasoningEffort = undefined;
                    const efforts = reasoningOptionsForMask(entries[model_idx].reasoning_mask, &efforts_buf);
                    const effort_idx = @min(region.ui.slash_sel, efforts.len - 1);
                    try app.setReasoningEffort(efforts[effort_idx]);
                    const line = try std.fmt.allocPrint(allocator, "/model use {s}", .{entries[model_idx].model_id});
                    defer allocator.free(line);
                    try editor.setLine(line);
                    region.ui.slash_sel = 0;
                    app.models_picker_key_index = null;
                    app.models_picker_model_index = null;
                    region.setInput("", 0);
                    region.clear();
                    echoUserSubmission(app, editor.view());
                    return try allocator.dupe(u8, editor.view());
                },
                .at_nav => {
                    // @-mention 菜单 ↑↓:算文件候选数 → 移 slash_sel(循环)→ 重画。
                    var r = complete.atCandidates(allocator, editor.view(), editor.cursor) catch {
                        continue;
                    };
                    defer r.deinit(allocator);
                    const n = r.candidates.len;
                    if (n > 0) {
                        if (region.ui.slash_sel >= n) region.ui.slash_sel = n - 1;
                        if (eff.at_nav_dir) {
                            region.ui.slash_sel = (region.ui.slash_sel + 1) % n;
                        } else {
                            region.ui.slash_sel = if (region.ui.slash_sel == 0) n - 1 else region.ui.slash_sel - 1;
                        }
                    }
                    redraw(&region, &editor, app);
                    continue;
                },
                .at_select => {
                    // @-mention Enter/Tab:把 @token 后的路径换成选中候选(对齐 cc:插入引用,不提交)。
                    var r = complete.atCandidates(allocator, editor.view(), editor.cursor) catch {
                        continue;
                    };
                    defer r.deinit(allocator);
                    if (r.candidates.len > 0) {
                        const idx = @min(region.ui.slash_sel, r.candidates.len - 1);
                        const cand = r.candidates[idx];
                        // 替换 [replace_start, cursor) 为候选(保留 @ 前缀与已输入目录)。
                        const old_len = editor.cursor - @min(r.replace_start, editor.cursor);
                        try applyCompletion(&editor, allocator, r.replace_start, old_len, cand);
                    }
                    region.ui.slash_sel = 0;
                    redraw(&region, &editor, app);
                    continue;
                },
                .reverse_search => {
                    region.clear();
                    try handleReverseSearch(fd, &editor, &parser, history, allocator);
                    redraw(&region, &editor, app);
                    continue;
                },
                .open_transcript => {
                    // Ctrl+O 去抖:按住的 auto-repeat 连发会高频 toggle alt-screen,真终端(Warp)
                    // 跟不上 → footer 多行堆叠 + 退出后框不幂等。抑制紧随的 reopen,使按住一次只
                    // 产生一对 open/close。见 RenderRegion.noteCtrloAndShouldSuppressReopen(生成期同源处理)。
                    if (region.noteCtrloAndShouldSuppressReopen()) continue;
                    // Ctrl+O → inline transcript viewer(方案 A:不覆盖 banner)。region.clear() 擦固定区
                    // + 光标停区顶(=内容结束下一行,banner 在其上方保留)+ 清零 input_cursor_row;
                    // viewer 从区顶 DECSC 存档往下画 transcript,退出回区顶 + ESC[J 清掉,redraw 从区顶
                    // 相对重画固定区 → 跟随内容、幂等(不再 box_h 反推贴底,那是 box_top 漂移 bug 根源)。
                    const sz = tui_term_root.getSize(fd);
                    const rows: usize = if (sz) |s| s.rows else 24;
                    region.clear();
                    transcript_viewer.runWithTheme(fd, allocator, &app.conversation, rows, region.theme) catch {};
                    redraw(&region, &editor, app);
                    continue;
                },
                .cycle_perm_mode => {
                    app.cyclePermMode();
                    redraw(&region, &editor, app);
                    continue;
                },
                .redraw_screen => {
                    region.clear();
                    std.debug.print("\x1b[2J\x1b[H", .{});
                    redraw(&region, &editor, app);
                    continue;
                },
                .external_edit => {
                    region.clear();
                    input.restoreMode(fd, orig);
                    if (externalEdit(allocator, editor.view())) |edited| {
                        defer allocator.free(edited);
                        editor.setLine(edited) catch {};
                    } else |_| {}
                    _ = input.enterRawMode(fd);
                    redraw(&region, &editor, app);
                    continue;
                },
                .kill_background => {
                    region.clear();
                    const killed = app.killAllBackground();
                    std.debug.print("\x1b[33m[killed {d} background task(s)]\x1b[0m\n", .{killed});
                    redraw(&region, &editor, app);
                    continue;
                },
                .background_main => {}, // 输入期 Ctrl+B 无意义(无正在跑的 run);dispatch 已 gate,这里兜底
                .agents_view => {
                    // 持久 viewing 现在纯靠 dispatch 设 view=.viewing + render_region.drawAgentViewing
                    // 帧渲染(非 print)。dispatch 不再上抛此 action;保留防御性 redraw。
                    redraw(&region, &editor, app);
                    continue;
                },
                .agents_stop => {
                    // 停止选中 agent(registry.kill)。
                    region.clear();
                    stopSelectedAgent(app, &region) catch {};
                    redraw(&region, &editor, app);
                    continue;
                },
            }
        }

        // Ctrl+Y paste 提示(对齐 cc DIFF#9):杀行键(Ctrl+U/K/W)且确有删除内容 → 置提示;
        // 打字(char)→ 清提示。在 editor.handle 前后比对 yank_buf 长度判定"确有删除"。
        const yank_before = editor.yankLen();
        switch (key) {
            .char => region.ui.paste_hint = false,
            else => {},
        }
        const action = try editor.handle(key);
        switch (key) {
            .ctrl_u, .ctrl_k, .ctrl_w => {
                if (editor.yankLen() > yank_before) region.ui.paste_hint = true;
            },
            else => {},
        }
        switch (action) {
            .redraw => redraw(&region, &editor, app),
            .commit => {
                region.setInput("", 0);
                region.clear();
                // 提交回显 ❯ <内容> 到 scrollback(否则提交后输入凭空消失)。
                echoUserSubmission(app, editor.view());
                return try allocator.dupe(u8, editor.view());
            },
            .cancel => return error.Cancelled,
            .cancel_hint => {
                // 第一次 Ctrl+C 且 buffer 空 — 提示再按一次退出(打到 scrollback,夹在 clear/render 间)
                region.clear();
                std.debug.print("\x1b[2m(再次按 Ctrl+C 退出 REPL)\x1b[0m\n", .{});
                redraw(&region, &editor, app);
            },
            .exit_repl => return error.ExitRequested,
            .eof => return error.Eof,
            .clear_draft => {
                // 把当前 draft 存入历史(Up 可恢复),然后清空
                if (editor.view().len > 0) {
                    history.append(editor.view()) catch {};
                }
                editor.reset();
                redraw(&region, &editor, app);
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
    fd: c_int,
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
        const n = platform_term.readInput(fd, &b);
        if (n <= 0) return;
        const c = b[0];

        if (c == 0x1b) {
            // 可能是裸 Esc,或 Kitty CSI-u 编码的 Esc(\x1b[27u)/Enter(\x1b[13u)/方向键。读后续判定:
            // 非 '[' → 裸 Esc 取消;'[' → 解析 CSI codepoint(27=Esc 取消 / 13=Enter 接受 / 其余忽略并吞掉序列)。
            // 不解析会把 `[27u` 等字节漏给下一轮 read 成乱码(白名单终端 reverse-search 的 CSI-u 盲区)。
            var nb: [1]u8 = undefined;
            const nn_i = platform_term.readInput(fd, &nb);
            if (nn_i <= 0) return;
            const nn: usize = @intCast(nn_i);
            if (nn == 0 or nb[0] != '[') {
                std.debug.print("\r\x1b[2K", .{}); // 裸 Esc → 取消
                return;
            }
            // 读 CSI 序列到终止字母,解析首段 codepoint。
            var cp: u32 = 0;
            var in_mod = false;
            while (true) {
                var sx: [1]u8 = undefined;
                const sn_i = platform_term.readInput(fd, &sx);
                if (sn_i <= 0) break;
                const sn: usize = @intCast(sn_i);
                if (sn == 0) break;
                const ch = sx[0];
                if (ch >= '0' and ch <= '9') {
                    if (!in_mod) cp = cp * 10 + (ch - '0');
                } else if (ch == ';') {
                    in_mod = true;
                } else break; // 终止字母(u/~/letter)
            }
            if (cp == 13) {
                if (match) |m| try editor.setLine(m); // Kitty Enter → 接受
                std.debug.print("\r\x1b[2K", .{});
                return;
            }
            if (cp == 27 or cp == 0) { // CSI-u Esc(27)或裸 ESC[(无 codepoint)→ 取消
                std.debug.print("\r\x1b[2K", .{});
                return;
            }
            continue; // 其余 CSI(方向键等)忽略,继续搜索
        }
        if (c == 0x03) {
            // Ctrl+C:取消,保留原 buffer
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

test "shellQuoteSingle: 元字符被单引号包死,不被 shell 拆(Linus #1)" {
    const a = testing.allocator;
    // 含空格 + 分号 + $() + 反引号 + && 的恶意目录名
    const evil = "/tmp/a b; rm -rf ~/$(curl x)`id`&&echo/CLAUDE.md";
    const q = try shellQuoteSingle(a, evil);
    defer a.free(q);
    // 整体单引号包裹
    try testing.expect(q[0] == '\'');
    try testing.expect(q[q.len - 1] == '\'');
    // 原文里没有单引号,故内部应原样保留(元字符在单引号内对 shell 失效)
    try testing.expect(std.mem.indexOf(u8, q, "a b; rm -rf") != null);

    // 路径含单引号 → 转成 '\'' 序列(闭引号→转义引号→重开引号)
    const with_quote = "/tmp/o'brien/CLAUDE.md";
    const q2 = try shellQuoteSingle(a, with_quote);
    defer a.free(q2);
    try testing.expect(std.mem.indexOf(u8, q2, "'\\''") != null);
    // 转义后不应出现裸的 `o'brien`(那个 ' 已被打断)
    try testing.expect(std.mem.indexOf(u8, q2, "o'brien") == null);

    // 普通路径:首尾引号 + 中间原样
    const plain = "/home/u/.claude/CLAUDE.md";
    const q3 = try shellQuoteSingle(a, plain);
    defer a.free(q3);
    try testing.expectEqualStrings("'/home/u/.claude/CLAUDE.md'", q3);
}

fn printHistory(history: *const history_mod.History) void {
    std.debug.print("History ({d} entries):\n", .{history.entries.items.len});
    const start: usize = if (history.entries.items.len > 20) history.entries.items.len - 20 else 0;
    for (history.entries.items[start..], start..) |entry, i| {
        std.debug.print("  {d}  {s}\n", .{ i + 1, entry });
    }
}

/// /retry：找 conversation 里最后一条 user text，重发 agent_loop（不追加重复消息）。
fn retryLast(app: *app_mod.App, allocator: std.mem.Allocator, backend: *const ui_backend_mod.UiBackend) !void {
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

    const jobs_ptr: ?*@import("../core/job_registry.zig").JobRegistry = if (app.jobs) |*jr| jr else null;
    const usage_before = app.usage;
    const mode_before = app.permission_ctx.modeValue();
    const started_ns = util_time.nowNs();
    const result = agent_loop.run(
        &app.conversation,
        app.provider(),
        app.tool_defs,
        &app.permission_ctx,
        .{ .session = app.session_id, .verbose = app.config.verbose, .abort = &app.abort, .read_state = &app.read_state, .jobs = jobs_ptr, .agent_jobs = if (app.agent_jobs) |*aj| aj else null, .plan_prev_mode = &app.plan_prev_mode, .tasks = &app.tasks, .kg = if (app.kg) |*k| k else null, .kg_projects_dir = app.kg_projects_dir, .memdir_abs = app.memdir_abs, .api_client = app.anthropicClientOrNull(), .tool_defs = app.tool_defs, .system_prompt = app.system_prompt, .inject_user_context = app.user_context, .model_switch_compact = app.pendingModelSwitchCompact(), .dyn_registry = &app.dyn_registry, .sandbox = app.sandboxPtr(), .cwd_abs = app.cwdAbs(), .home_dir = app.homeDir(), .additional_dirs = app.additionalDirs() }, // task#12:辅助 REPL 路径也套 sandbox
        backend,
        allocator,
    ) catch |err| {
        std.debug.print("\x1b[31mError: {s}\x1b[0m\n", .{@errorName(err)});
        app.clearPendingModelSwitchCompact();
        return;
    };
    app.clearPendingModelSwitchCompact();
    accountGoalUsageAfterRun(app, usage_before, mode_before, started_ns);
    app.persistTranscript();
    if (result.stop_reason == .aborted) {
        std.debug.print("\x1b[33m^C (cancelled)\x1b[0m\n", .{});
        app.abort.resetForTesting();
    }
}

fn historyPath(allocator: std.mem.Allocator) ![]u8 {
    const home = @import("platform").paths.homeDir() orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.metacodes/history", .{home});
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

/// /init:对齐 cc OLD_INIT_PROMPT——让**模型**扫码库后写 CLAUDE.md(prompt 型命令,
/// 不是本地建 config.json)。注入为 user message 走正常 agent_loop。
const INIT_PROMPT =
    \\Please analyze this codebase and create a CLAUDE.md file in the repository root, which will be
    \\provided to future Claude Code sessions as project memory.
    \\
    \\What to do:
    \\  1) Explore the codebase (use Read/Glob/Grep/CodeMap and the Bash tool for `git`/build files) to
    \\     understand: build & test & lint commands, the high-level architecture, key modules and how they
    \\     fit together, and any non-obvious conventions.
    \\  2) If a CLAUDE.md already exists, improve it rather than overwrite — preserve anything still correct.
    \\  3) Also incorporate any existing rules files if present (e.g. .cursorrules, .github/copilot-instructions.md)
    \\     and useful pointers from README.
    \\  4) Write CLAUDE.md with the Write tool. Begin the file with this exact header:
    \\
    \\     # CLAUDE.md
    \\
    \\     This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.
    \\
    \\Keep it concise and high-signal: commands a developer actually runs, the architecture a newcomer needs,
    \\and conventions that are NOT obvious from reading a single file. Do not pad it with restated source code.
;

/// /model：按分组/能力浏览模型，或切换当前 provider 内的模型。
fn handleEffort(app: *app_mod.App, allocator: std.mem.Allocator, rest: []const u8) !void {
    _ = allocator;
    if (rest.len == 0) {
        // 无参:显示当前
        const cur = app.provider().reasoningEffort();
        const cur_str = if (cur) |e| @tagName(e) else "default (none)";
        std.debug.print("Current reasoning effort: {s}\n", .{cur_str});
        std.debug.print("Usage: /effort <none|minimal|low|medium|high|xhigh>\n", .{});
        return;
    }
    const effort = types_mod.ReasoningEffort.parse(rest) orelse {
        std.debug.print("\x1b[31minvalid effort '{s}'. Valid: none|minimal|low|medium|high|xhigh\x1b[0m\n", .{rest});
        return;
    };
    app.setReasoningEffort(effort) catch |err| {
        std.debug.print("\x1b[31m/effort failed: {s}\x1b[0m\n", .{@errorName(err)});
        return;
    };
    std.debug.print("reasoning effort set to {s}\n", .{@tagName(effort)});
}

fn handleOverridesCmd(app: *app_mod.App, allocator: std.mem.Allocator, rest: []const u8) !void {
    _ = allocator;
    if (rest.len == 0) {
        // 无参:显示当前所有 overrides
        const o = app.provider().requestOverrides();
        std.debug.print("Request overrides:\n", .{});
        std.debug.print("  temperature: {s}\n", .{fmtOptF32(o.temperature)});
        std.debug.print("  top_p:       {s}\n", .{fmtOptF32(o.top_p)});
        std.debug.print("  prompt_cache_key: {s}\n", .{fmtOptStr(o.prompt_cache_key)});
        std.debug.print("  parallel_tool_calls: {s}\n", .{fmtOptBool(o.parallel_tool_calls)});
        const rf_str = if (o.response_format) |rf| switch (rf.kind) {
            .json_object => "json_object",
            .json_schema => "json_schema",
            .none => "none",
        } else "(none)";
        std.debug.print("  response_format: {s}\n", .{rf_str});
        std.debug.print("Usage: /overrides <field> <value> | clear\n", .{});
        std.debug.print("  fields: temperature, top_p, prompt_cache_key, parallel_tool_calls, response_format\n", .{});
        return;
    }
    if (std.mem.eql(u8, rest, "clear")) {
        app.clearRequestOverrides();
        std.debug.print("All overrides cleared.\n", .{});
        return;
    }
    // /overrides <field> <value>
    const space = std.mem.indexOfScalar(u8, rest, ' ') orelse {
        std.debug.print("\x1b[31musage: /overrides <field> <value>\x1b[0m\n", .{});
        return;
    };
    const field = rest[0..space];
    const value = std.mem.trim(u8, rest[space + 1 ..], " \t");
    var ov = app.provider().requestOverrides();
    if (std.mem.eql(u8, field, "temperature")) {
        ov.temperature = std.fmt.parseFloat(f32, value) catch {
            std.debug.print("\x1b[31minvalid float: {s}\x1b[0m\n", .{value});
            return;
        };
    } else if (std.mem.eql(u8, field, "top_p")) {
        ov.top_p = std.fmt.parseFloat(f32, value) catch {
            std.debug.print("\x1b[31minvalid float: {s}\x1b[0m\n", .{value});
            return;
        };
    } else if (std.mem.eql(u8, field, "prompt_cache_key")) {
        ov.prompt_cache_key = value;
    } else if (std.mem.eql(u8, field, "parallel_tool_calls")) {
        if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) {
            ov.parallel_tool_calls = true;
        } else if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) {
            ov.parallel_tool_calls = false;
        } else {
            std.debug.print("\x1b[31minvalid bool: {s} (true|false)\x1b[0m\n", .{value});
            return;
        }
    } else if (std.mem.eql(u8, field, "response_format")) {
        const rf: dialect_mod.ResponseFormatRequest = if (std.mem.eql(u8, value, "json_object"))
            .{ .kind = .json_object, .schema = null }
        else if (std.mem.eql(u8, value, "json_schema"))
            .{ .kind = .json_schema, .schema = null }
        else {
            std.debug.print("\x1b[31minvalid response_format: {s} (json_object|json_schema)\x1b[0m\n", .{value});
            return;
        };
        ov.response_format = rf;
    } else {
        std.debug.print("\x1b[31munknown field: {s}. Valid: temperature, top_p, prompt_cache_key, parallel_tool_calls, response_format\x1b[0m\n", .{field});
        return;
    }
    app.setRequestOverrides(ov) catch |err| {
        std.debug.print("\x1b[31m/overrides failed (provider may not support dialect fields): {s}\x1b[0m\n", .{@errorName(err)});
        return;
    };
    std.debug.print("{s} set to {s}\n", .{ field, value });
}

fn fmtOptF32(v: ?f32) []const u8 {
    return if (v) |_| "(set)" else "(none)";
}

fn fmtOptStr(v: ?[]const u8) []const u8 {
    return if (v) |s| s else "(none)";
}

fn fmtOptBool(v: ?bool) []const u8 {
    return if (v) |b| if (b) "true" else "false" else "(none)";
}

fn handleModel(app: *app_mod.App, allocator: std.mem.Allocator, rest: []const u8) !void {
    const candidates = try model_command.collectCandidates(allocator, app.config.provider_kind, app.api_client.catalog.entries.items);
    defer allocator.free(candidates);

    switch (model_command.parseQuery(rest)) {
        .list => {
            printModelList(app, candidates, null, null);
            return;
        },
        .help => {
            printModelHelp();
            return;
        },
        .group => |group| {
            if (group.len == 0) {
                std.debug.print("usage: /model group <anthropic|opus|sonnet|haiku|openai|gemini>\n", .{});
                return;
            }
            printModelList(app, candidates, group, null);
            return;
        },
        .capability => |cap| {
            printModelList(app, candidates, null, cap);
            return;
        },
        .unknown => |value| {
            std.debug.print("\x1b[31munknown /model selector: {s}\x1b[0m\n", .{value});
            printModelHelp();
            return;
        },
        .use_model => |target_raw| {
            if (target_raw.len == 0) {
                std.debug.print("usage: /model use <model-id>\n", .{});
                return;
            }
            const resolved = @import("../tools/agent.zig").resolveModelAlias(target_raw);
            try switchModel(app, allocator, candidates, resolved);
            return;
        },
    }
}

fn printModelHelp() void {
    std.debug.print(
        \\usage:
        \\  /model
        \\  /model group <anthropic|opus|sonnet|haiku|openai|gemini>
        \\  /model capability <web_search|thinking|prompt_cache|structured_output|server_tool>
        \\  /model use <model-id>
        \\  /model <model-id>
        \\
        \\Model switching is limited to the provider selected at startup. Start with
        \\--model gpt-... or --model gemini-... to use another provider family.
        \\
    , .{});
}

fn printModelList(
    app: *app_mod.App,
    candidates: []const model_command.Candidate,
    group_filter: ?[]const u8,
    cap_filter: ?model_command.Capability,
) void {
    std.debug.print("current model: \x1b[36m{s}\x1b[0m  provider={s}\n", .{ app.activeModel(), @tagName(app.config.provider_kind) });
    if (group_filter) |g| std.debug.print("filter group: {s}\n", .{g});
    if (cap_filter) |cap| std.debug.print("filter capability: {s}\n", .{model_command.capabilityLabel(cap)});

    var listed: usize = 0;
    var last_group: []const u8 = "";
    for (candidates) |c| {
        if (group_filter) |g| if (!model_command.matchesGroup(c, g)) continue;
        if (cap_filter) |cap| if (!model_command.supports(c.provider, c.id, cap)) continue;
        if (!std.mem.eql(u8, last_group, c.group)) {
            last_group = c.group;
            std.debug.print("\n{s}:\n", .{c.group});
        }
        printModelCandidate(c, std.mem.eql(u8, c.id, app.activeModel()));
        listed += 1;
    }

    if (listed == 0) {
        std.debug.print("  no models match this selector for provider {s}\n", .{@tagName(app.config.provider_kind)});
    }
    std.debug.print("\nusage: /model use <model-id>  |  /model group <name>  |  /model capability <name>\n", .{});
}

fn printModelCandidate(c: model_command.Candidate, current: bool) void {
    if (current) {
        std.debug.print("  \x1b[36m*{s}\x1b[0m", .{c.id});
    } else {
        std.debug.print("   {s}", .{c.id});
    }
    std.debug.print("  [{s}/{s} {s}]", .{ @tagName(c.provider), c.group, @tagName(c.source) });
    if (c.max_input_tokens) |v| std.debug.print(" context={d}", .{v});
    if (c.max_tokens) |v| std.debug.print(" max_output={d}", .{v});
    std.debug.print(" capabilities=", .{});
    printCapabilities(c.provider, c.id);
    std.debug.print("\n", .{});
}

fn reasoningOptionsForMask(mask: u8, buf: *[5]types_mod.ReasoningEffort) []const types_mod.ReasoningEffort {
    const catalog = @import("../api/catalog.zig");
    const ordered = [_]types_mod.ReasoningEffort{ .low, .medium, .high, .xhigh };
    buf[0] = .none;
    var n: usize = 1;
    for (ordered) |effort| {
        if ((mask & catalog.reasoningBit(effort)) != 0) {
            buf[n] = effort;
            n += 1;
        }
    }
    return buf[0..n];
}

fn reasoningOptionCount(app: *const app_mod.App) usize {
    const idx = app.models_picker_model_index orelse return 0;
    if (idx >= app.api_client.catalog.entries.items.len) return 0;
    var buf: [5]types_mod.ReasoningEffort = undefined;
    return reasoningOptionsForMask(app.api_client.catalog.entries.items[idx].reasoning_mask, &buf).len;
}

fn printCapabilities(provider: types_mod.ProviderKind, model: []const u8) void {
    const caps = [_]model_command.Capability{ .web_search, .server_tool, .extended_thinking, .prompt_cache, .structured_output };
    var first = true;
    for (caps) |cap| {
        if (!model_command.supports(provider, model, cap)) continue;
        if (!first) std.debug.print(",", .{});
        std.debug.print("{s}", .{model_command.capabilityLabel(cap)});
        first = false;
    }
    if (first) std.debug.print("none", .{});
}

fn switchModel(
    app: *app_mod.App,
    allocator: std.mem.Allocator,
    candidates: []const model_command.Candidate,
    model: []const u8,
) !void {
    _ = allocator;
    if (!model_command.canUseInCurrentProvider(app.config.provider_kind, candidates, model)) {
        if (model_command.providerForModel(model)) |p| {
            std.debug.print(
                "\x1b[31mrefused: {s} belongs to provider {s}, but this session is {s}\x1b[0m\n",
                .{ model, @tagName(p), @tagName(app.config.provider_kind) },
            );
        } else {
            std.debug.print("\x1b[31mrefused: unknown model id '{s}'\x1b[0m\n", .{model});
        }
        std.debug.print("Start a new session with --model <id> to switch provider families.\n", .{});
        return;
    }

    app.switchModel(model) catch |err| {
        std.debug.print("\x1b[33mwarn: model sync failed ({s})\x1b[0m\n", .{@errorName(err)});
        return;
    };
    app.persistLoginSelection();

    std.debug.print("switched to \x1b[36m{s}\x1b[0m", .{app.activeModel()});
    if (app.config.reasoning_effort) |effort| std.debug.print(" reasoning={s}", .{effort.name()});
    std.debug.print(" (max_output={d})\n", .{app.provider().maxTokens()});
}

fn handleDoctor(app: *app_mod.App, allocator: std.mem.Allocator) !void {
    std.debug.print("\x1b[1mcc-zig doctor\x1b[0m\n", .{});
    std.debug.print("  model:            {s}\n", .{app.activeModel()});
    std.debug.print("  permission mode:  {s}\n", .{@tagName(app.permission_ctx.modeValue())});
    std.debug.print("  auth token:       {s}\n", .{if (app.api_key.len > 0) "set" else "MISSING"});
    std.debug.print("  max_tokens cfg:   {any}\n", .{app.config.max_tokens});
    std.debug.print("  verbose:          {}\n", .{app.config.verbose});
    std.debug.print("  transcript:       {s}\n", .{if (app.transcript_writer != null) "on" else "OFF"});
    std.debug.print("  job registry:     {s}\n", .{if (app.jobs != null) "on" else "OFF"});
    std.debug.print("  skills loaded:    {d}\n", .{app.skills.len()});
    std.debug.print("  conversation:     {d} messages\n", .{app.conversation.len()});
    std.debug.print("  tasks:            {d} in store\n", .{app.tasks.tasks.items.len});
    std.debug.print("  rules loaded:     {d}\n", .{if (app.rule_set) |r| r.rules.items.len else 0});

    // HOME + CWD + config file 检查
    const home_c = @import("platform").paths.homeDir();
    if (home_c) |h| {
        std.debug.print("  HOME:             {s}\n", .{h});
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

fn injectCompactStressHistory(app: *app_mod.App, allocator: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const text = try allocator.alloc(u8, 12_000);
        defer allocator.free(text);
        @memset(text, 'x');
        try app.conversation.appendText(if (i % 2 == 0) .user else .assistant, text);
    }
}

fn handleConfigCmd(app: *app_mod.App, allocator: std.mem.Allocator, rest: []const u8) !void {
    const home = @import("platform").paths.homeDir() orelse {
        std.debug.print("HOME not set\n", .{});
        return;
    };
    const cfg_path = try std.fmt.allocPrint(allocator, "{s}/.metacodes/config.json", .{home});
    defer allocator.free(cfg_path);

    if (rest.len == 0 or std.mem.eql(u8, rest, "show")) {
        // 当前生效配置(menu-style 摘要)
        std.debug.print("\x1b[1mActive configuration\x1b[0m\n", .{});
        std.debug.print("  model:           \x1b[36m{s}\x1b[0m\n", .{app.activeModel()});
        std.debug.print("  permission mode: \x1b[36m{s}\x1b[0m  \x1b[2m(Shift+Tab to cycle)\x1b[0m\n", .{@tagName(app.permMode())});
        std.debug.print("  verbose:         {}\n", .{app.config.verbose});
        std.debug.print("  no_theme:        {}\n", .{app.config.no_theme});
        std.debug.print("  skills loaded:   {d}\n", .{app.skills.len()});
        std.debug.print("  subagents:       {d}\n", .{app.agents.len()});
        std.debug.print("  MCP servers:     {d}\n", .{app.mcp_sessions.items.len});
        std.debug.print("\x1b[2mconfig file: {s}\x1b[0m\n", .{cfg_path});
        // 尝试读全文
        const path_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{cfg_path}, 0);
        defer allocator.free(path_z);
        const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) {
            std.debug.print("(file does not exist — use /init to create one)\n", .{});
            return;
        }
        defer _ = pfs.close(fd);
        std.debug.print("\x1b[1mfile contents:\x1b[0m\n", .{});
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = pfs.read(fd, buf[0..buf.len]);
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

pub const GoalCommand = union(enum) {
    view: void,
    help: void,
    clear: void,
    set: []const u8,
    edit: []const u8,
    budget: ?u64,
    pause: void,
    resume_goal: void,
    complete: void,
    blocked: void,
    invalid: void,
};

pub fn parseGoalCommand(rest_raw: []const u8) GoalCommand {
    const rest = std.mem.trim(u8, rest_raw, " \t");
    if (rest.len == 0 or std.mem.eql(u8, rest, "view") or std.mem.eql(u8, rest, "status")) return .{ .view = {} };
    if (std.mem.eql(u8, rest, "help")) return .{ .help = {} };
    if (std.mem.eql(u8, rest, "clear")) return .{ .clear = {} };
    if (std.mem.startsWith(u8, rest, "set ")) return .{ .set = std.mem.trim(u8, rest[4..], " \t") };
    if (std.mem.startsWith(u8, rest, "edit ")) return .{ .edit = std.mem.trim(u8, rest[5..], " \t") };
    if (std.mem.startsWith(u8, rest, "budget ")) {
        const arg = std.mem.trim(u8, rest[7..], " \t");
        if (std.mem.eql(u8, arg, "none") or std.mem.eql(u8, arg, "clear")) return .{ .budget = null };
        const budget = std.fmt.parseInt(u64, arg, 10) catch return .{ .invalid = {} };
        return .{ .budget = budget };
    }
    if (std.mem.eql(u8, rest, "pause")) return .{ .pause = {} };
    if (std.mem.eql(u8, rest, "resume")) return .{ .resume_goal = {} };
    if (std.mem.eql(u8, rest, "complete")) return .{ .complete = {} };
    if (std.mem.eql(u8, rest, "blocked") or std.mem.eql(u8, rest, "block")) return .{ .blocked = {} };
    return .{ .invalid = {} };
}

/// /kg —— KG 用户面(设计 v3-final §7:状态/记忆列表/删除/导出)。
/// 无参=状态;`mem`=最近记忆;`forget <id>`=删除(投毒自救);`export`=导出 markdown。
fn handleKg(app: *app_mod.App, allocator: std.mem.Allocator, rest: []const u8) !void {
    const kg = if (app.kg) |*k| k else {
        std.debug.print("KG 未配置(缺 tinykg 二进制)。运行 `zig build`(从 lib/tinykg 源交叉编译生成)。\n", .{});
        return;
    };
    if (!kg.ready) {
        std.debug.print("KG 已降级:{s}\n", .{kg.degradedMessage()});
        return;
    }
    const arg = std.mem.trim(u8, rest, " \t");

    if (arg.len == 0) {
        // 状态:store 路径 + domain + frontier(有 kg_root 时)。
        std.debug.print("KG store: {s}\ndomain:   {s}\n", .{ kg.store_path, kg.domain });
        // 记忆同步检视面(PM P1:autosync 静默失败要可见)。
        if (kg.autosync_ok + kg.autosync_fail > 0) {
            if (kg.autosync_last_err) |e| {
                std.debug.print("记忆同步(本 session): {d} ok / {d} fail(最近: {s})\n", .{ kg.autosync_ok, kg.autosync_fail, e });
            } else {
                std.debug.print("记忆同步(本 session): {d} ok / {d} fail\n", .{ kg.autosync_ok, kg.autosync_fail });
            }
        }
        if (app.memdir_abs.len > 0) std.debug.print("(手工编辑过记忆文件?/kg sync 重新同步入图)\n", .{});
        // 分类结晶发现面(PM 终审:tentative 边无人知晓就永远不结晶)。本 session 有任务
        // 产出待确认分类 → 提示人类去审阅(concept id 只能从 /kg refs 取,这是唯一入口)。
        {
            const pend = kg.pendingRefTasks(allocator);
            defer if (pend.len > 0) allocator.free(pend);
            if (pend.len > 0) {
                const color = std.c.getenv("NO_COLOR") == null;
                std.debug.print("{s}待确认分类:{d} 个任务产出了 tentative 分类投影(闭合时 agent 打的,待人类结晶)。{s}\n  审阅:", .{ if (color) "\x1b[36m" else "", pend.len, if (color) "\x1b[0m" else "" });
                for (pend, 0..) |t, i| {
                    if (i >= 8) {
                        std.debug.print(" …(共 {d})", .{pend.len});
                        break;
                    }
                    std.debug.print("{s}/kg refs {d}", .{ if (i == 0) "" else " · ", t });
                }
                std.debug.print("\n", .{});
            }
        }
        // 重复 project 检测(旧 bug 时代增殖的同名节点让一半记忆召回不可见,用户自己不可能发现)。
        if (kg.duplicateProjectHint(allocator)) |hint| {
            defer allocator.free(hint);
            // NO_COLOR 纪律(L1 血泪:Apple Terminal 系统级 NO_COLOR)。
            const color = std.c.getenv("NO_COLOR") == null;
            std.debug.print("{s}检测到同名重复 project:{s} —— /kg projects 查看,/kg merge <输家> <赢家> 合并。{s}\n", .{ if (color) "\x1b[33m" else "", hint, if (color) "\x1b[0m" else "" });
        }
        if (app.kg_projects_dir.len > 0) {
            // 12b 单入口:有 task 锚指针 → 一次深遍历看全(多计划+inbox,与模型侧
            // appendKgFrontier 同源);存量店退回双指针(kg_root+kg_inbox)。
            const inject_mod = @import("../kg/inject.zig");
            const has_anchor = inject_mod.readIdPointer(allocator, app.kg_projects_dir, "kg_task_anchor") != null;
            const shown_plan = if (has_anchor)
                printKgRootFrontier(allocator, kg, app.kg_projects_dir, "kg_task_anchor", "任务面")
            else
                printKgRootFrontier(allocator, kg, app.kg_projects_dir, "kg_root", "计划");
            const shown_inbox = if (has_anchor) false else printKgRootFrontier(allocator, kg, app.kg_projects_dir, "kg_inbox", "待办");
            if (!shown_plan and !shown_inbox) {
                std.debug.print("(本项目无活跃计划图/待办;计划批准或 TaskCreate 后从此恢复)\n", .{});
            }
        }
        return;
    }

    if (std.mem.eql(u8, arg, "mem")) {
        const hits = kg.listRecentMemories(15) catch {
            std.debug.print("(记忆列表查询失败)\n", .{});
            return;
        };
        defer {
            for (hits) |*h| h.deinit(allocator);
            allocator.free(hits);
        }
        if (hits.len == 0) {
            std.debug.print("(暂无记忆)\n", .{});
            return;
        }
        std.debug.print("最近记忆({d} 条):\n", .{hits.len});
        for (hits) |h| {
            // list-recent TSV 路径不带 source_label(PM P0-1:靠 struct 默认空判断是死代码)
            // —— document hit 现场补查(≤15 条列表,仅 document 才 spawn,成本可控)。
            const label: ?[]u8 = if (std.mem.eql(u8, h.kind, "document")) kg.nodeMemorySource(h.node_id).label else null;
            defer if (label) |l| allocator.free(l);
            if (label) |l| {
                std.debug.print("  [{d}] {s}({s}): {s}\n", .{ h.node_id, h.kind, l, firstLine(h.text) });
            } else {
                std.debug.print("  [{d}] {s}: {s}\n", .{ h.node_id, h.kind, firstLine(h.text) });
            }
        }
        return;
    }

    if (std.mem.eql(u8, arg, "plan")) {
        // TinyKG task graph is the sole progress source. `kg_plan_doc` is a
        // legacy approved-plan artifact, never an authority for lifecycle.
        const inject = @import("../kg/inject.zig");
        const root = if (app.kg_projects_dir.len > 0)
            inject.readIdPointer(allocator, app.kg_projects_dir, "kg_root")
        else
            null;
        const root_id = root orelse {
            std.debug.print("(本项目缺少 kg_root；无法从 TinyKG 生成计划投影)\n", .{});
            return;
        };
        const md = @import("../kg/plan_view.zig").render(allocator, kg, root_id) catch |err| {
            const detail = kg.detail();
            if (detail.len > 0) {
                std.debug.print("(TinyKG 计划投影失败:{s}: {s})\n", .{ @errorName(err), detail });
            } else {
                std.debug.print("(TinyKG 计划投影失败:{s})\n", .{@errorName(err)});
            }
            return;
        };
        defer allocator.free(md);
        std.debug.print("{s}", .{md});
        if (md.len == 0 or md[md.len - 1] != '\n') std.debug.print("\n", .{});
        return;
    }

    if (std.mem.eql(u8, arg, "projects")) {
        // PM P0-3:merge 的 <from>/<to> id 此前无处可查(mem 过滤 project kind)——本命令是唯一出口。
        const listing = kg.listProjects(allocator) catch {
            std.debug.print("(project 列表查询失败)\n", .{});
            return;
        };
        defer allocator.free(listing);
        if (listing.len == 0) {
            std.debug.print("(库中无 project 节点)\n", .{});
        } else {
            std.debug.print("project 节点(id  名称):\n{s}同名重复可 /kg merge <输家id> <赢家id> 合并。\n", .{listing});
        }
        return;
    }

    if (std.mem.eql(u8, arg, "sync")) {
        // PM P1:手工编辑(vim)不经 Write 钩子 → 图里旧版;sync 遍历 memdir 重跑幂等 upsert。
        const autosync = @import("../kg/autosync.zig");
        const stats = autosync.syncAll(allocator, kg, app.memdir_abs);
        std.debug.print("记忆同步完成:{d} 个文件已入图,{d} 失败,{d} 跳过(索引/非法路径)。\n", .{ stats.synced, stats.failed, stats.skipped });
        return;
    }

    if (std.mem.eql(u8, arg, "gc") or std.mem.eql(u8, arg, "gc!")) {
        // gc-md-orphans 接线。默认干跑预览,gc! 真删(对齐 forget/forget! 惯例:
        // 无预览直接删 + 裸机器输出,用户不敢按)。
        const apply = std.mem.eql(u8, arg, "gc!");
        const summary = kg.gcMdOrphans(apply) catch |e| {
            std.debug.print("gc 失败({s}): {s}\n", .{ @errorName(e), kg.detail() });
            return;
        };
        defer allocator.free(summary);
        const n = extractGcCount(summary, if (apply) "deleted=" else "candidates=");
        if (apply) {
            std.debug.print("已清理 {d} 个孤儿节点。\n", .{n});
        } else if (n == 0) {
            std.debug.print("无孤儿节点,无需清理。\n", .{});
        } else {
            std.debug.print("发现 {d} 个孤儿节点(记忆文件更新/删除的残留,不在召回范围)。执行清理:/kg gc!\n", .{n});
        }
        return;
    }

    if (std.mem.startsWith(u8, arg, "merge ")) {
        // 存量重复 project 节点合并(reparent-contain 增量迁移;输家空壳可再 forget)。
        var it2 = std.mem.tokenizeAny(u8, arg["merge ".len..], " \t");
        const from_s = it2.next() orelse "";
        const to_s = it2.next() orelse "";
        const from = std.fmt.parseInt(u64, from_s, 10) catch 0;
        const to = std.fmt.parseInt(u64, to_s, 10) catch 0;
        if (from == 0 or to == 0) {
            std.debug.print("用法:/kg merge <输家-project-id> <赢家-project-id>\n", .{});
            return;
        }
        const summary = kg.reparentContain(from, to) catch |e| {
            std.debug.print("merge 失败({s}): {s}\n", .{ @errorName(e), kg.detail() });
            return;
        };
        defer allocator.free(summary);
        std.debug.print("{s}\n(输家 {d} 已空,可 /kg forget {d} 删除)\n", .{ summary, from, from });
        return;
    }

    if (std.mem.startsWith(u8, arg, "forget ") or std.mem.startsWith(u8, arg, "forget! ")) {
        const force = std.mem.startsWith(u8, arg, "forget! ");
        const raw_id = if (force) arg["forget! ".len..] else arg["forget ".len..];
        const id_str = std.mem.trim(u8, raw_id, " \t");
        const id = std.fmt.parseInt(u64, id_str, 10) catch {
            std.debug.print("用法:/kg forget <node-id>(md 派生节点强删用 forget!)\n", .{});
            return;
        };
        // md 派生节点假删除防护(PM P1 + Linus 次要5):document 根**与 section/正文**都会被
        // 同文件 Write upsert 复活——同拦。有 label(document 根)且源文件仍在 → 给完整路径引导;
        // 源文件已不存在 → 放行(复活警告在此场景是误导);section(md_derived 无 label)→ 拦 +
        // 引导改源文件(文件名看所属 document,/kg mem 可查)。
        if (!force) {
            const msrc = kg.nodeMemorySource(id);
            defer if (msrc.label) |l| allocator.free(l);
            if (msrc.md_derived) {
                if (msrc.label) |label| {
                    var fbuf: [std.fs.max_path_bytes]u8 = undefined;
                    const full = if (app.memdir_abs.len > 0) std.fmt.bufPrint(&fbuf, "{s}/{s}", .{ app.memdir_abs, label }) catch label else label;
                    const exists = if (app.memdir_abs.len > 0) blk: {
                        var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
                        if (full.len >= zbuf.len) break :blk false;
                        @memcpy(zbuf[0..full.len], full);
                        zbuf[full.len] = 0;
                        break :blk std.c.access(@ptrCast(&zbuf), std.c.F_OK) == 0;
                    } else false;
                    if (exists) {
                        std.debug.print("注意:node {d} 来自记忆文件 {s} —— 直接 forget 会在下次写该文件时复活。\n正确删法:清空该文件(Write 空内容,或 vim 清空后 /kg sync)。仍要强删:/kg forget! {d}\n", .{ id, full, id });
                        return;
                    }
                    // 源文件已不存在 → 放行删除。
                } else {
                    // content: 前缀无法区分"md 文件正文"(会复活)与"KgRemember 投影节点"(不会)
                    // —— 文案不武断(Linus:安全闸给错误操作指引是半个 bug)。
                    std.debug.print("注意:node {d} 是派生投影节点(记忆文件正文,或 KgRemember 投影)。\n若来自记忆文件:forget 会在下次写该文件时复活,应修改/清空源文件(/kg mem 查 document 来源)。\n确认无源文件或仍要强删:/kg forget! {d}\n", .{ id, id });
                    return;
                }
            }
        }
        kg.forget(id) catch |e| {
            std.debug.print("删除失败({s}): {s}\n", .{ @errorName(e), kg.detail() });
            return;
        };
        std.debug.print("已删除 node {d}。\n", .{id});
        return;
    }

    // /kg refs（无参）—— 列出本 session 有待确认分类的任务,作为发现入口。
    if (std.mem.eql(u8, arg, "refs")) {
        const pend = kg.pendingRefTasks(allocator);
        defer if (pend.len > 0) allocator.free(pend);
        if (pend.len == 0) {
            std.debug.print("(本 session 无待确认分类;任务闭合填 acts_on/uses/produces 后在此出现)\n用法:/kg refs <task-id> 看单个任务的分类投影\n", .{});
            return;
        }
        std.debug.print("本 session 产出待确认分类的任务(/kg refs <id> 展开):\n", .{});
        for (pend) |t| std.debug.print("  /kg refs {d}\n", .{t});
        return;
    }

    // /kg refs <task-id> —— 看某任务的分类投影(acts_on/uses/produces/about + concept id + 两态)。
    // confirm/correct 需要 concept id,此视图是**获取 id 的唯一入口**——没它这两个命令没法用。
    if (std.mem.startsWith(u8, arg, "refs ")) {
        var id_str = std.mem.trim(u8, arg["refs ".len..], " \t");
        if (std.mem.startsWith(u8, id_str, "kg-")) id_str = id_str["kg-".len..]; // 容忍 TaskList 的 kg-<id> 形式
        const task = std.fmt.parseInt(u64, id_str, 10) catch {
            std.debug.print("用法:/kg refs <task-id>(task id 从 /kg plan 或 TaskList 的 kg-<id> 取)\n", .{});
            return;
        };
        const nb = kg.neighborsJson(task, 200) catch |e| {
            std.debug.print("查询失败({s}): {s}\n", .{ @errorName(e), kg.detail() });
            return;
        };
        defer kg.allocator.free(nb); // neighborsJson 用 kg.allocator 分配(契约,勿依赖实例同一)
        const Edge = struct { rel: []const u8, dst: u64, props: struct { state: ?[]const u8 = null } = .{} };
        const Doc = struct { edges: []const Edge };
        const parsed = std.json.parseFromSlice(Doc, allocator, nb, .{ .ignore_unknown_fields = true }) catch {
            std.debug.print("(neighbors 解析失败)\n", .{});
            return;
        };
        defer parsed.deinit();
        std.debug.print("task {d} 的分类投影:\n", .{task});
        var any = false;
        for (parsed.value.edges) |e| {
            if (!isRefRel(e.rel)) continue;
            any = true;
            const state = e.props.state orelse "tentative";
            var subject: []const u8 = "";
            const dtext = kg.fetchNodeText(e.dst) catch null;
            defer if (dtext) |t| kg.allocator.free(t);
            if (dtext) |t| {
                const nl = std.mem.indexOfScalar(u8, t, '\n');
                subject = if (nl) |i| t[0..i] else t;
            }
            std.debug.print("  {s:<9} concept {d} [{s}]  {s}\n", .{ e.rel, e.dst, state, subject });
        }
        if (!any) std.debug.print("(无——任务闭合时填 acts_on/uses/produces 才会产生)\n", .{});
        std.debug.print("确认:/kg confirm {d} <rel> <concept-id>  |  纠正:/kg correct {d} <rel> <old-concept-id> <new-name>\n", .{ task, task });
        return;
    }

    // /kg confirm <task-id> <rel> <concept-id> —— 人类背书一个分类(tentative→confirmed,改动三)。
    if (std.mem.startsWith(u8, arg, "confirm ")) {
        var it = std.mem.tokenizeScalar(u8, arg["confirm ".len..], ' ');
        const task = if (it.next()) |t| (std.fmt.parseInt(u64, t, 10) catch null) else null;
        const rel = it.next();
        const concept = if (it.next()) |c| (std.fmt.parseInt(u64, c, 10) catch null) else null;
        if (task == null or rel == null or concept == null or !isRefRel(rel.?)) {
            std.debug.print("用法:/kg confirm <task-id> <acts_on|uses|produces|about> <concept-id>\n", .{});
            return;
        }
        kg.confirmClassification(task.?, rel.?, concept.?) catch |e| {
            std.debug.print("确认失败({s}): {s}(该分类边不存在?先由任务闭合投影产生)\n", .{ @errorName(e), kg.detail() });
            return;
        };
        std.debug.print("已确认:task {d} {s} concept {d}(confirmed)。\n", .{ task.?, rel.?, concept.? });
        return;
    }

    // /kg correct <task-id> <rel> <old-concept-id> <new-name...> —— 纠正分类(改动四:覆盖+留痕)。
    if (std.mem.startsWith(u8, arg, "correct ")) {
        var it = std.mem.tokenizeScalar(u8, arg["correct ".len..], ' ');
        const task = if (it.next()) |t| (std.fmt.parseInt(u64, t, 10) catch null) else null;
        const rel = it.next();
        const old_concept = if (it.next()) |c| (std.fmt.parseInt(u64, c, 10) catch null) else null;
        const new_name = std.mem.trim(u8, it.rest(), " \t");
        if (task == null or rel == null or old_concept == null or new_name.len == 0 or !isRefRel(rel.?)) {
            std.debug.print("用法:/kg correct <task-id> <acts_on|uses|produces|about> <old-concept-id> <new-name>\n", .{});
            return;
        }
        kg.correctClassification(task.?, rel.?, old_concept.?, new_name) catch |e| {
            std.debug.print("纠正失败({s}): {s}\n", .{ @errorName(e), kg.detail() });
            return;
        };
        std.debug.print("已纠正:task {d} {s} {d} → \"{s}\"(旧边删除+confirmed 新边+error_event/fix 留痕)。\n", .{ task.?, rel.?, old_concept.?, new_name });
        return;
    }

    std.debug.print("用法:/kg(状态)| /kg mem(记忆)| /kg plan(计划)| /kg projects(project 列表)| /kg sync(重同步记忆文件)| /kg gc(孤儿预览,gc! 清理)| /kg merge <from> <to>(合并重复 project)| /kg forget <id>(删除,md 派生强删用 forget!)| /kg refs <task>(看分类投影)| /kg confirm <task> <rel> <concept>(背书分类)| /kg correct <task> <rel> <old> <new-name>(纠正分类)\n", .{});
}

/// ref 关系白名单(改动二的 3+1)。confirm/correct 只作用于分类性引用边。
fn isRefRel(rel: []const u8) bool {
    return std.mem.eql(u8, rel, "acts_on") or std.mem.eql(u8, rel, "uses") or
        std.mem.eql(u8, rel, "produces") or std.mem.eql(u8, rel, "about");
}

/// gc 输出提取计数("candidates=N"/"deleted=N")。解析失败返 0。
fn extractGcCount(summary: []const u8, key: []const u8) usize {
    const pos = std.mem.indexOf(u8, summary, key) orelse return 0;
    const rest = summary[pos + key.len ..];
    const end = std.mem.indexOfAny(u8, rest, " \n\t") orelse rest.len;
    return std.fmt.parseInt(usize, rest[0..end], 10) catch 0;
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    var n = @min(end, 100);
    while (n > 0 and (text[n - 1] & 0xC0) == 0x80) n -= 1; // 不切半个 CJK 字
    return text[0..n];
}

/// max_turns backstop 可配(METACODES_MAX_TURNS 覆盖;默认 400)。非法值退默认。
fn maxTurnsFromEnv() u32 {
    if (std.c.getenv("METACODES_MAX_TURNS")) |v| {
        return std.fmt.parseInt(u32, std.mem.span(v), 10) catch 400;
    }
    return 400;
}

/// 成本次闸预算(USD)可配(METACODES_COST_BUDGET;默认 null=不设)。非法/≤0 → null。
fn costBudgetFromEnv() ?f64 {
    const v = std.c.getenv("METACODES_COST_BUDGET") orelse return null;
    const b = std.fmt.parseFloat(f64, std.mem.span(v)) catch return null;
    return if (b > 0) b else null;
}

/// 统计对话里工具调用分类("31×Read · 13×Bash · 5×Grep"),撞 backstop 时展示,
/// 让用户一眼判"合法长任务"(动作多样)vs"原地打转"(某工具霸榜)。owned;空→null。
fn toolCallBreakdown(app: *app_mod.App, allocator: std.mem.Allocator) ?[]u8 {
    const Pair = struct { name: []const u8, n: u32 };
    var counts = std.StringHashMap(u32).init(allocator);
    defer counts.deinit();
    for (app.conversation.messages.items) |m| {
        for (m.blocks) |b| {
            switch (b) {
                .tool_use => |tu| {
                    const gop = counts.getOrPut(tu.name) catch continue;
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                },
                else => {},
            }
        }
    }
    if (counts.count() == 0) return null;
    var list: std.ArrayList(Pair) = .empty;
    defer list.deinit(allocator);
    var it = counts.iterator();
    while (it.next()) |e| list.append(allocator, .{ .name = e.key_ptr.*, .n = e.value_ptr.* }) catch return null;
    std.mem.sort(Pair, list.items, {}, struct {
        fn lt(_: void, a: Pair, c: Pair) bool {
            return a.n > c.n;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (list.items, 0..) |e, i| {
        if (i > 0) out.appendSlice(allocator, " · ") catch return null;
        const seg = std.fmt.allocPrint(allocator, "{d}×{s}", .{ e.n, e.name }) catch return null;
        defer allocator.free(seg);
        out.appendSlice(allocator, seg) catch return null;
    }
    return out.toOwnedSlice(allocator) catch null;
}

const scoped_recall_mod = @import("../kg/scoped_recall.zig");

/// 打印某个 root(kg_root/kg_inbox)的 frontier。返回是否显示了内容(供"全空"提示)。
fn printKgRootFrontier(allocator: std.mem.Allocator, kg: anytype, projects_dir: []const u8, pointer: []const u8, label: []const u8) bool {
    const inject = @import("../kg/inject.zig");
    const root = inject.readIdPointer(allocator, projects_dir, pointer) orelse return false;
    const rows = kg.frontier(root, 30) catch return false;
    defer {
        // kg 内存契约:kg.allocator 释放(见 KgClient 顶注)。
        for (rows) |*r| r.deinit(kg.allocator);
        kg.allocator.free(rows);
    }
    if (rows.len == 0) return false;
    var actionable: usize = 0;
    for (rows) |r| {
        if (r.role != .branch) actionable += 1;
    }
    std.debug.print("{s} root {d} — {d} 个未完成/失败任务:\n", .{ label, root, actionable });
    for (rows) |r| {
        // branch = 开放复合节点(等子树闭合)→ ▹;缩进按 depth 呈现树形。
        const mark = if (r.status == .failed)
            "✗"
        else if (r.role == .branch)
            "▹"
        else switch (r.readiness) {
            .ready => "○",
            .blocked => "⊘",
            .missing_dependencies => "…",
        };
        const depth = if (r.depth > 0) r.depth - 1 else 0;
        var indent_buf: [16]u8 = undefined;
        const indent_n = @min(depth * 2, indent_buf.len);
        @memset(indent_buf[0..indent_n], ' ');
        std.debug.print("  {s}{s} [{d}] {s}", .{ indent_buf[0..indent_n], mark, r.task_id, firstLine(r.text) });
        if (r.claimed_by) |c| std.debug.print("(认领:{s})", .{c});
        std.debug.print("\n", .{});
    }
    return true;
}

fn handleGoal(app: *app_mod.App, rest: []const u8) !void {
    switch (parseGoalCommand(rest)) {
        .view => {
            printGoal(app);
            return;
        },
        .help => {
            printGoalHelp();
            return;
        },
        .clear => {
            app.goal_state.clearInMemory();
            app.persistGoal();
            std.debug.print("Goal cleared.\n", .{});
            return;
        },
        .set => |objective| {
            app.goal_state.setNew(objective, null) catch |err| {
                printGoalError(err);
                return;
            };
            app.persistGoal();
            std.debug.print("Goal set.\n", .{});
            printGoal(app);
            return;
        },
        .edit => |objective| {
            app.goal_state.editObjective(objective) catch |err| {
                printGoalError(err);
                return;
            };
            app.persistGoal();
            std.debug.print("Goal updated.\n", .{});
            printGoal(app);
            return;
        },
        .budget => |budget| {
            app.goal_state.setBudget(budget) catch |err| {
                printGoalError(err);
                return;
            };
            app.persistGoal();
            printGoal(app);
            return;
        },
        .pause => {
            try setGoalStatus(app, .paused);
            return;
        },
        .resume_goal => {
            try setGoalStatus(app, .active);
            return;
        },
        .complete => {
            try setGoalStatus(app, .complete);
            return;
        },
        .blocked => {
            try setGoalStatus(app, .blocked);
            return;
        },
        .invalid => {},
    }
    std.debug.print("usage: /goal [view|set <objective>|edit <objective>|budget <tokens|none>|pause|resume|complete|blocked|clear]\n", .{});
}

fn setGoalStatus(app: *app_mod.App, status: goal_mod.Status) !void {
    app.goal_state.setStatus(status) catch |err| {
        printGoalError(err);
        return;
    };
    app.persistGoal();
    printGoal(app);
}

fn printGoal(app: *const app_mod.App) void {
    const g = app.goal_state.current orelse {
        std.debug.print("No goal set. Use /goal set <objective>.\n", .{});
        return;
    };
    std.debug.print("\x1b[1mGoal\x1b[0m [{s}]\n", .{@tagName(g.status)});
    std.debug.print("  id:      {s}\n", .{g.id[0..]});
    std.debug.print("  target:  {s}\n", .{g.objective});
    if (g.token_budget) |budget| {
        const remaining: u64 = if (g.tokens_used >= budget) 0 else budget - g.tokens_used;
        std.debug.print("  budget:  {d} tokens ({d} used, {d} left)\n", .{ budget, g.tokens_used, remaining });
    } else {
        std.debug.print("  budget:  none ({d} tokens used)\n", .{g.tokens_used});
    }
}

fn printGoalHelp() void {
    std.debug.print(
        \\Goal commands:
        \\  /goal                         Show current goal
        \\  /goal set <objective>         Create or replace the session goal
        \\  /goal edit <objective>        Edit the current objective
        \\  /goal budget <tokens|none>    Set or clear token budget
        \\  /goal pause|resume            Pause or resume continuation eligibility
        \\  /goal complete|blocked        Mark final status
        \\  /goal clear                   Remove the goal
        \\
    , .{});
}

fn printGoalError(err: anyerror) void {
    const msg = switch (err) {
        error.EmptyObjective => "empty objective",
        error.NoGoal => "no goal set",
        error.InvalidBudget => "invalid budget",
        else => @errorName(err),
    };
    std.debug.print("\x1b[31m/goal failed: {s}\x1b[0m\n", .{msg});
}

pub const LoopCommand = union(enum) {
    status: void,
    off: void,
    on: u32,
    invalid: void,
};

pub fn parseLoopCommand(rest_raw: []const u8) LoopCommand {
    const rest = std.mem.trim(u8, rest_raw, " \t");
    if (rest.len == 0 or std.mem.eql(u8, rest, "status")) return .{ .status = {} };
    if (std.mem.eql(u8, rest, "off") or std.mem.eql(u8, rest, "stop")) return .{ .off = {} };
    if (std.mem.eql(u8, rest, "on") or std.mem.startsWith(u8, rest, "on ")) {
        const n_raw = if (rest.len > 2) std.mem.trim(u8, rest[2..], " \t") else "";
        const n = if (n_raw.len == 0) @as(u32, 10) else std.fmt.parseInt(u32, n_raw, 10) catch return .{ .invalid = {} };
        if (n == 0) return .{ .invalid = {} };
        return .{ .on = n };
    }
    return .{ .invalid = {} };
}

fn handleLoop(app: *app_mod.App, rest: []const u8) void {
    switch (parseLoopCommand(rest)) {
        .status => {
            printLoopStatus(app);
            return;
        },
        .off => {
            app.loop_enabled = false;
            app.loop_remaining = 0;
            std.debug.print("Loop continuation stopped.\n", .{});
            return;
        },
        .on => |n| {
            if (app.goal_state.current == null) {
                std.debug.print("Set a goal first: /goal set <objective>\n", .{});
                return;
            }
            if (app.goal_state.current.?.status != .active) {
                std.debug.print("Goal must be active before loop continuation can start.\n", .{});
                return;
            }
            app.loop_enabled = true;
            app.loop_remaining = n;
            printLoopStatus(app);
            return;
        },
        .invalid => {},
    }
    std.debug.print("usage: /loop [status|on [max-continuations]|off]\n", .{});
}

fn printLoopStatus(app: *const app_mod.App) void {
    std.debug.print("Loop continuation: {s}", .{if (app.loop_enabled) "on" else "off"});
    if (app.loop_enabled) std.debug.print(" ({d} remaining)", .{app.loop_remaining});
    std.debug.print("\n", .{});
    if (app.goal_state.current) |g| {
        std.debug.print("Goal status: {s}\n", .{@tagName(g.status)});
    } else {
        std.debug.print("No goal set.\n", .{});
    }
}

fn shouldRunLoopContinuation(app: *const app_mod.App, queued_count: usize) bool {
    const goal_status = if (app.goal_state.current) |g| g.status else null;
    return shouldRunLoopContinuationInput(.{
        .loop_enabled = app.loop_enabled,
        .loop_remaining = app.loop_remaining,
        .queued_count = queued_count,
        .goal_status = goal_status,
        .permission_mode = app.permission_ctx.modeValue(),
        .aborted = app.abort.isAborted(),
    });
}

fn runLoopContinuation(app: *app_mod.App, allocator: std.mem.Allocator, backend: *const ui_backend_mod.UiBackend) !void {
    const g = app.goal_state.current orelse return;
    if (app.loop_remaining > 0) app.loop_remaining -= 1;
    const prompt = try std.fmt.allocPrint(
        allocator,
        "<system-reminder>Continue working toward the active goal. Goal: {s}. If the goal appears complete or genuinely blocked, say that explicitly in your response so the user can mark it with /goal complete or /goal blocked. Slash commands are user input controls; do not claim you executed one. Do not start unrelated work.</system-reminder>",
        .{g.objective},
    );
    defer allocator.free(prompt);
    std.debug.print("\x1b[2m[loop continuation: {d} remaining]\x1b[0m\n", .{app.loop_remaining});
    try runInjectedAgentWithSynthetic(app, allocator, backend, prompt);
    if (app.loop_remaining == 0) {
        app.loop_enabled = false;
        std.debug.print("\x1b[2m[loop continuation stopped: limit reached]\x1b[0m\n", .{});
    }
}

pub const LoopGateInput = struct {
    loop_enabled: bool,
    loop_remaining: u32,
    queued_count: usize,
    goal_status: ?goal_mod.Status,
    permission_mode: types_mod.PermissionMode,
    aborted: bool,
};

pub fn shouldRunLoopContinuationInput(input_state: LoopGateInput) bool {
    if (!input_state.loop_enabled or input_state.loop_remaining == 0) return false;
    if (input_state.queued_count > 0) return false;
    const status = input_state.goal_status orelse return false;
    if (status != .active) return false;
    if (input_state.permission_mode == .plan) return false;
    if (input_state.aborted) return false;
    return true;
}

fn accountGoalUsageAfterRun(app: *app_mod.App, before: usage_mod.UsageTotals, mode_before: types_mod.PermissionMode, started_ns: util_time.Nanos) void {
    if (mode_before == .plan) return;
    if (app.goal_state.current == null) return;
    const delta = goalBudgetTokenDelta(before, app.usage);
    const elapsed_ms = elapsedSinceMs(started_ns);
    if (delta == 0 and elapsed_ms == 0) return;
    const id = app.goal_state.current.?.id;
    app.goal_state.accountProgress(delta, elapsed_ms, id[0..]) catch |err| {
        @import("../util/log.zig").warn("goal", "usage accounting failed: {s}", .{@errorName(err)});
        return;
    };
    app.persistGoal();
    if (app.goal_state.current) |g| {
        if (g.status == .budget_limited) {
            app.loop_enabled = false;
            app.loop_remaining = 0;
            std.debug.print("\x1b[2m[goal budget reached]\x1b[0m\n", .{});
        }
    }
}

fn goalBudgetTokenDelta(before: usage_mod.UsageTotals, after: usage_mod.UsageTotals) u64 {
    const input_delta = after.input_tokens -| before.input_tokens;
    const output_delta = after.output_tokens -| before.output_tokens;
    return input_delta +| output_delta;
}

fn elapsedSinceMs(started_ns: util_time.Nanos) u64 {
    const now = util_time.nowNs();
    if (now <= started_ns) return 0;
    return @intCast(@divTrunc(now - started_ns, std.time.ns_per_ms));
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
        app.provider(),
        app.anthropicClientOrNull(),
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
    const prompt = try std.fmt.allocPrint(allocator, "Here is the current conversation so far:\n\n{s}\n\nSide question (answer concisely from context only, do not use tools): {s}", .{ ctx_text, question });
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
    const prompt = try std.fmt.allocPrint(allocator, "Summarize this session in ONE concise line (what was worked on, current state):\n\n{s}", .{ctx_text});
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
            \\Declare servers in ~/.metacodes/config.json:
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
    std.debug.print("permission mode: \x1b[36m{s}\x1b[0m\n", .{@tagName(app.permission_ctx.modeValue())});
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
        std.debug.print("rules: (none loaded — add a permission_rules array to ~/.metacodes/config.json)\n", .{});
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
    // U2 S1:状态操作(变体/theme/持久化)下沉 App.setTheme,渲染留此。
    std.debug.print("theme switched to \x1b[36m{s}\x1b[0m\n", .{theme_mod.variantName(variant)});
    const persisted = app.setTheme(variant) catch |e| {
        std.debug.print("\x1b[2m(persist failed: {s})\x1b[0m\n", .{@errorName(e)});
        return;
    };
    if (persisted) std.debug.print("\x1b[2m(saved to ~/.metacodes/config.json)\x1b[0m\n", .{});
}

/// libc system(3)(0.16 std.c 无绑定):fork + /bin/sh -c + waitpid,stdio 继承父进程。
/// 用于 /memory edit 启动交互式 $EDITOR(需继承 tty,Bash 工具捕获输出不适用)。
extern "c" fn system(command: [*:0]const u8) c_int;
fn c_system(command: [*:0]const u8) c_int {
    return system(command);
}

/// /memory:列出记忆文件槽位 + 用 $EDITOR 打开(对齐 cc /memory MemoryFileSelector)。
///   /memory               列出所有记忆文件槽位(User/Project/Local CLAUDE.md + 自动记忆目录)
///   /memory edit <slot>   用 $VISUAL/$EDITOR 打开指定槽位(user|project|local|auto);不存在则创建
/// 旧的 `/memory add <text>` 写 ~/.metacodes/memory.md 已废弃——那条链从不注入模型(死记忆),
/// 现对齐 cc:记忆 = CLAUDE.md 链(人写)+ memdir 自动记忆(模型写),都已真正喂给模型。
fn handleMemory(app: *app_mod.App, allocator: std.mem.Allocator, rest: []const u8) !void {
    const home = app.homeDir();
    const cwd = app.cwdAbs();

    if (std.mem.eql(u8, rest, "edit") or std.mem.startsWith(u8, rest, "edit ")) {
        const slot = std.mem.trim(u8, rest[4..], " \t");
        return editMemorySlot(app, allocator, home, cwd, slot);
    }

    // 列出槽位
    std.debug.print("Memory files (edit with: /memory edit <slot>):\n", .{});
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;

    if (home.len > 0) {
        const up = std.fmt.bufPrint(&pbuf, "{s}/.claude/CLAUDE.md", .{home}) catch "";
        printMemorySlot("user", up, "your global instructions for all projects");
    }
    if (cwd.len > 0) {
        var b2: [std.fs.max_path_bytes]u8 = undefined;
        const pp = std.fmt.bufPrint(&b2, "{s}/CLAUDE.md", .{cwd}) catch "";
        printMemorySlot("project", pp, "project instructions, checked into the repo");
        var b3: [std.fs.max_path_bytes]u8 = undefined;
        const lp = std.fmt.bufPrint(&b3, "{s}/CLAUDE.local.md", .{cwd}) catch "";
        printMemorySlot("local", lp, "private project instructions, gitignored");
    }
    if (app.memdir_abs.len > 0) {
        var b4: [std.fs.max_path_bytes]u8 = undefined;
        const ap = std.fmt.bufPrint(&b4, "{s}/MEMORY.md", .{app.memdir_abs}) catch "";
        printMemorySlot("auto", ap, "auto-memory index (model-managed, persists across sessions)");
    }
}

fn printMemorySlot(slot: []const u8, path: []const u8, desc: []const u8) void {
    if (path.len == 0) return;
    const exists = blk: {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len + 1 > buf.len) break :blk false;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        break :blk std.c.access(@ptrCast(&buf), std.c.F_OK) == 0;
    };
    const tag = if (exists) "        " else " (new)  ";
    std.debug.print("  \x1b[36m{s: <8}\x1b[0m{s}{s}\n    \x1b[2m{s}\x1b[0m\n", .{ slot, tag, path, desc });
}

/// 解析 slot → 路径,mkdir 父目录,$VISUAL/$EDITOR 打开(对齐 cc editFileInEditor)。
fn editMemorySlot(app: *app_mod.App, allocator: std.mem.Allocator, home: []const u8, cwd: []const u8, slot: []const u8) !void {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path: []const u8 = blk: {
        if (std.mem.eql(u8, slot, "user")) {
            if (home.len == 0) return std.debug.print("HOME not set\n", .{});
            break :blk std.fmt.bufPrint(&pbuf, "{s}/.claude/CLAUDE.md", .{home}) catch return;
        } else if (std.mem.eql(u8, slot, "project")) {
            if (cwd.len == 0) return std.debug.print("no cwd\n", .{});
            break :blk std.fmt.bufPrint(&pbuf, "{s}/CLAUDE.md", .{cwd}) catch return;
        } else if (std.mem.eql(u8, slot, "local")) {
            if (cwd.len == 0) return std.debug.print("no cwd\n", .{});
            break :blk std.fmt.bufPrint(&pbuf, "{s}/CLAUDE.local.md", .{cwd}) catch return;
        } else if (std.mem.eql(u8, slot, "auto")) {
            if (app.memdir_abs.len == 0) return std.debug.print("auto-memory disabled\n", .{});
            break :blk std.fmt.bufPrint(&pbuf, "{s}/MEMORY.md", .{app.memdir_abs}) catch return;
        } else {
            return std.debug.print("usage: /memory edit <user|project|local|auto>\n", .{});
        }
    };

    // mkdir 父目录(~/.claude 等可能不存在);创建空文件(保留已存在,wx 语义)。
    if (std.fs.path.dirname(path)) |d| @import("../util/fs.zig").mkdirParents(d) catch {};
    {
        var zb: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len + 1 <= zb.len) {
            @memcpy(zb[0..path.len], path);
            zb[path.len] = 0;
            // O_CREAT|O_EXCL:已存在不动,不存在建空。
            const fd = pfs.open(@ptrCast(&zb), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o644));
            if (fd >= 0) _ = pfs.close(fd);
        }
    }

    const editor = std.c.getenv("VISUAL") orelse std.c.getenv("EDITOR") orelse {
        std.debug.print("$VISUAL/$EDITOR not set. File is at:\n  {s}\n", .{path});
        return;
    };
    const ed = std.mem.span(editor);
    // 安全(Linus #1):path 含 cwd/home,目录名可合法含 shell 元字符(空格/;/$/`/&&/$(...))。
    // 未引用直接进 system() 的 /bin/sh -c 就是命令注入(`/tmp/a;rm -rf ~` 这种目录名触发)。
    // 修:path 用单引号包死 + 转义内部单引号(`'`→`'\''`),shell 单引号内一切元字符失效。
    // editor 不引(允许 `$EDITOR="code -w"` 带参数;它来自用户自己的 env,信任级别高于 cwd)。
    const quoted_path = try shellQuoteSingle(allocator, path);
    defer allocator.free(quoted_path);
    const cmd = try std.fmt.allocPrintSentinel(allocator, "{s} {s}", .{ ed, quoted_path }, 0);
    defer allocator.free(cmd);
    const rc = c_system(cmd.ptr);
    if (rc != 0) {
        std.debug.print("editor exited non-zero (rc={d}); file is at:\n  {s}\n", .{ rc, path });
        return;
    }
    std.debug.print("\x1b[2medited {s} (restart or /model to reload into context)\x1b[0m\n", .{path});
}

/// POSIX shell 单引号转义:把 s 包成可安全嵌入 `/bin/sh -c` 的单引号字符串。
/// 规则:整体单引号包裹;内部每个 `'` 替成 `'\''`(闭引号→转义引号→重开引号)。
/// 单引号内 shell 不解释任何元字符,故除 `'` 外无需处理。返回 owned。
fn shellQuoteSingle(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

/// 启动 banner:圆角 box(对齐 cc 2.1.x)。版本 + 模型 + cwd 三行。
/// 非 TTY 退化为纯文本两行(pipe 友好)。box 内宽固定取 min(cols-2, 64)。
fn printStartupBanner(app: *const app_mod.App) void {
    const th = app.theme;
    if (!platform_term.isatty(1)) {
        std.debug.print("cc-zig\nType your message or /help for commands\n\n", .{});
        return;
    }
    const cols: usize = blk: {
        if (platform_term.windowSize(1)) |sz| {
            if (sz.cols > 0) break :blk sz.cols;
        }
        break :blk 80;
    };
    // welcome 框宽度对齐输入分隔线:框总宽 = box_tl + inner×box_h + box_tr = inner+2,
    // 须等于输入分隔线宽 inner_w = cols-1(见 render_region.innerWidth)→ inner = cols-3。
    // 去掉旧的 64 封顶——宽窗口下旧版框 64 列、分隔线满宽,两条线不等长(用户实测割裂)。
    const inner: usize = if (cols > 3) cols - 3 else 60;

    const title = " cc-zig ";
    // 顶边框:╭─ cc-zig ───…──╮
    std.debug.print("{s}{s}{s}{s}", .{ th.accent, th.box_tl, th.box_h, title });
    var filled: usize = 1 + displayWidthAscii(title); // box_h(1) + title
    while (filled < inner) : (filled += 1) std.debug.print("{s}", .{th.box_h});
    std.debug.print("{s}{s}\n", .{ th.box_tr, th.reset });

    // 内容行:模型 + cwd。
    printBannerLine(th, inner, app.activeModel());
    printBannerLine(th, inner, app.cwdAbs());

    // 底边框。
    std.debug.print("{s}{s}", .{ th.accent, th.box_bl });
    var k: usize = 0;
    while (k < inner) : (k += 1) std.debug.print("{s}", .{th.box_h});
    std.debug.print("{s}{s}\n\n", .{ th.box_br, th.reset });
}

/// banner 一行内容:│ + inner 列(2 空格缩进 + text + 右补空格)+ │。
/// inner 列宽 == 顶/底边框的 box_h 数,保证左右竖线对齐。
fn printBannerLine(th: anytype, inner: usize, text: []const u8) void {
    const pad_left = 2;
    const avail = if (inner > pad_left) inner - pad_left else 0; // text 最多占 inner-2 列
    const shown = if (displayWidthAscii(text) > avail) text[0..@min(text.len, avail)] else text;
    std.debug.print("{s}{s}{s}  {s}", .{ th.accent, th.box_v, th.reset, shown });
    // 右补空格,使 pad_left + shown_width + fill == inner,再竖线。
    var w: usize = pad_left + displayWidthAscii(shown);
    while (w < inner) : (w += 1) std.debug.print(" ", .{});
    std.debug.print("{s}{s}{s}\n", .{ th.accent, th.box_v, th.reset });
}

/// 粗略显示宽(ASCII 1/字;非 ASCII 字节按 UTF-8 估算——banner 文本多为路径/模型名,ASCII 为主)。
fn displayWidthAscii(s: []const u8) usize {
    return @import("tui/term.zig").displayWidth(s);
}

/// 启动建议:跑 `git log` 找最近改动文件,给一条灰色提示。失败静默。
fn printStartupSuggestion(allocator: std.mem.Allocator) void {
    if (!platform_term.isatty(1)) return; // 非 TTY 不显示
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
    if (platform_term.windowSize(1)) |sz| {
        if (sz.rows > 0) return sz.rows;
    }
    return 24;
}

/// Ctrl+G:把当前 buffer 写临时文件,开 $VISUAL/$EDITOR 编辑,读回。
/// 实现移到 input.externalEdit(与 AskUserQuestion preview note 共用),此处转发。
fn externalEdit(allocator: std.mem.Allocator, current: []const u8) ![]u8 {
    return input.externalEdit(allocator, current);
}

/// 杀所有 running 后台任务,返回杀掉的数量。
/// 停止选中 agent(registry.kill)。region.ui.agents.sel 是 1-based agent index。
fn stopSelectedAgent(app: *app_mod.App, region: *render_region_mod.RenderRegion) !void {
    const reg = app.agentJobsPtr() orelse return;
    const sel = region.ui.agents.sel;
    if (sel == 0) return;
    const allocator = app.allocator;
    const snaps = reg.snapshotJobs(allocator) catch return;
    defer agent_job_registry_mod.AgentJobRegistry.freeSnapshots(allocator, snaps);
    if (sel - 1 >= snaps.len) return;
    reg.kill(snaps[sel - 1].id) catch {};
    std.debug.print("\r\x1b[2K\x1b[33m[stopped agent {s}]\x1b[0m\n", .{snaps[sel - 1].desc});
}

fn printTaskList(app: *app_mod.App) void {
    const tasks = app.tasks.tasks.items;
    std.debug.print("\r\x1b[2K", .{}); // 清当前行
    if (tasks.len == 0) {
        std.debug.print("\x1b[2m(no tasks)\x1b[0m\n", .{});
    } else {
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
                .completed => "\x1b[32m✓\x1b[0m", // 绿勾:完成
                .deleted => unreachable,
            };
            std.debug.print("  {s} {s}\n", .{ icon, t.subject });
            shown += 1;
        }
    }

    // 后台 subagent jobs(独立于 todo 任务):running/done/failed/killed。
    if (app.agent_jobs) |*reg| {
        const snaps = reg.snapshotJobs(app.allocator) catch return;
        defer @import("../core/agent_job_registry.zig").AgentJobRegistry.freeSnapshots(app.allocator, snaps);
        if (snaps.len == 0) return;
        std.debug.print("\x1b[1mSubagents ({d}):\x1b[0m\n", .{snaps.len});
        for (snaps) |s| {
            const icon = switch (s.status) {
                .running => "\x1b[33m◐\x1b[0m", // 黄半:跑
                .done => "\x1b[32m●\x1b[0m", // 绿实:完成
                .failed => "\x1b[31m✗\x1b[0m", // 红叉:失败
                .killed => "\x1b[90m○\x1b[0m", // 灰:终止
            };
            const label = if (s.desc.len > 0) s.desc else s.id;
            std.debug.print("  {s} {s} \x1b[2m({d} turns, {d} tool calls)\x1b[0m\n", .{ icon, label, s.turns, s.tool_calls });
        }
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
        .agent_jobs = if (app.agent_jobs) |*aj| aj else null,
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
fn fireDueCrons(app: *app_mod.App, allocator: std.mem.Allocator, backend: *const ui_backend_mod.UiBackend) !void {
    const due = app.cron_registry.collectDue(allocator) catch return;
    defer {
        for (due) |p| allocator.free(p);
        allocator.free(due);
    }
    for (due) |prompt| {
        std.debug.print("\x1b[2m[cron fired]\x1b[0m {s}\n", .{prompt});
        try app.conversation.appendText(.user, prompt);
        try runInjectedAgent(app, allocator, backend);
    }
}

/// 把预置 prompt 注入为 user message 后触发一次 agent_loop 执行。
fn runInjectedAgent(app: *app_mod.App, allocator: std.mem.Allocator, backend: *const ui_backend_mod.UiBackend) !void {
    return runInjectedAgentWithSynthetic(app, allocator, backend, null);
}

fn runInjectedAgentWithSynthetic(app: *app_mod.App, allocator: std.mem.Allocator, backend: *const ui_backend_mod.UiBackend, synthetic_user_input: ?[]const u8) !void {
    const jobs_ptr: ?*@import("../core/job_registry.zig").JobRegistry = if (app.jobs) |*jr| jr else null;
    // 辅助路径(skill 调用 / cron 注入),非用户盯着的主交互循环 → 不接 spawn_tick_fn(默认 null,Bash 长命令静默,故意不传非遗漏)。
    const usage_before = app.usage;
    const mode_before = app.permission_ctx.modeValue();
    const started_ns = util_time.nowNs();
    const result = agent_loop.run(
        &app.conversation,
        app.provider(),
        app.tool_defs,
        &app.permission_ctx,
        .{ .session = app.session_id, .verbose = app.config.verbose, .abort = &app.abort, .read_state = &app.read_state, .jobs = jobs_ptr, .agent_jobs = if (app.agent_jobs) |*aj| aj else null, .plan_prev_mode = &app.plan_prev_mode, .tasks = &app.tasks, .kg = if (app.kg) |*k| k else null, .kg_projects_dir = app.kg_projects_dir, .memdir_abs = app.memdir_abs, .api_client = app.anthropicClientOrNull(), .tool_defs = app.tool_defs, .system_prompt = app.system_prompt, .inject_user_context = app.user_context, .synthetic_user_input = synthetic_user_input, .model_switch_compact = app.pendingModelSwitchCompact(), .dyn_registry = &app.dyn_registry, .sandbox = app.sandboxPtr(), .cwd_abs = app.cwdAbs(), .home_dir = app.homeDir(), .additional_dirs = app.additionalDirs() }, // task#12:injected/synthetic 路径也套 sandbox
        backend,
        allocator,
    ) catch |err| {
        std.debug.print("\x1b[31mError: {s}\x1b[0m\n", .{@errorName(err)});
        app.clearPendingModelSwitchCompact();
        return;
    };
    app.clearPendingModelSwitchCompact();
    accountGoalUsageAfterRun(app, usage_before, mode_before, started_ns);
    app.persistTranscript();
    if (result.stop_reason == .aborted) {
        std.debug.print("\x1b[33m^C (cancelled)\x1b[0m\n", .{});
        app.abort.resetForTesting();
    }
}

/// /resume：rest == "" 时列出最近 session；rest 是 session id 时加载。
fn handleResume(app: *app_mod.App, allocator: std.mem.Allocator, rest: []const u8) !void {
    const home = @import("platform").paths.homeDir() orelse {
        std.debug.print("no HOME env set\n", .{});
        return;
    };

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
    var target_id: ?[]const u8 = null; // 会话身份:resume 后须切 app.session_id(路由键,#16)
    // 先尝试解析成数字
    if (std.fmt.parseInt(usize, rest, 10) catch null) |n| {
        if (n >= 1 and n <= list.len) {
            target_path = list[n - 1].path;
            target_id = list[n - 1].id;
        }
    }
    if (target_path == null) {
        // 按 id 精确匹配 / 前缀匹配
        for (list) |e| {
            if (std.mem.eql(u8, e.id, rest) or std.mem.startsWith(u8, e.id, rest)) {
                target_path = e.path;
                target_id = e.id;
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
        app.activeModel(),
        staged.len(),
    );

    // 到这里所有操作已经成功：真正 atomic 切换。
    app.conversation.deinit();
    app.conversation = staged;
    staged_owned_here = false; // ownership 已转移给 app.conversation
    if (app.transcript_writer) |*w| w.deinit();
    app.transcript_writer = new_writer;
    app.loadGoalFromSessionDir(path);

    // #16:切换会话身份——路由键(permission_ctx.session)与 transcript 落点必须一致。resume 前
    // app.session_id 是启动时 gen 的旧 id,writer 已指向 resumed 目录,但 session_id 没变 → 后续
    // agent_loop 的 Options.session / 权限对话框路由仍用旧 id(漂移)。同步切到 resumed session id。
    if (target_id) |tid| {
        if (@import("../core/session_id.zig").SessionId.fromSlice(tid)) |sid| {
            app.session_id = sid;
            app.permission_ctx.session = sid; // 权限对话框路由到本会话视图(M5/M6)
        }
    }

    std.debug.print("Resumed session ({d} messages). Continue by sending a message.\n", .{app.conversation.len()});
}

test "/loop gate: requires active goal, no queued input, non-plan mode, non-aborted run" {
    const base = LoopGateInput{
        .loop_enabled = true,
        .loop_remaining = 3,
        .queued_count = 0,
        .goal_status = .active,
        .permission_mode = .default,
        .aborted = false,
    };
    try std.testing.expect(shouldRunLoopContinuationInput(base));

    var no_goal = base;
    no_goal.goal_status = null;
    try std.testing.expect(!shouldRunLoopContinuationInput(no_goal));

    var paused = base;
    paused.goal_status = .paused;
    try std.testing.expect(!shouldRunLoopContinuationInput(paused));

    var completed_goal = base;
    completed_goal.goal_status = .complete;
    try std.testing.expect(!shouldRunLoopContinuationInput(completed_goal));

    var queued = base;
    queued.queued_count = 1;
    try std.testing.expect(!shouldRunLoopContinuationInput(queued));

    var plan = base;
    plan.permission_mode = .plan;
    try std.testing.expect(!shouldRunLoopContinuationInput(plan));

    var aborted = base;
    aborted.aborted = true;
    try std.testing.expect(!shouldRunLoopContinuationInput(aborted));

    var exhausted = base;
    exhausted.loop_remaining = 0;
    try std.testing.expect(!shouldRunLoopContinuationInput(exhausted));
}

test "/goal command parser covers user input command surface" {
    try std.testing.expectEqual(@as(std.meta.Tag(GoalCommand), .view), std.meta.activeTag(parseGoalCommand("")));
    try std.testing.expectEqual(@as(std.meta.Tag(GoalCommand), .view), std.meta.activeTag(parseGoalCommand("status")));
    try std.testing.expectEqual(@as(std.meta.Tag(GoalCommand), .help), std.meta.activeTag(parseGoalCommand("help")));
    try std.testing.expectEqual(@as(std.meta.Tag(GoalCommand), .clear), std.meta.activeTag(parseGoalCommand("clear")));

    const set_cmd = parseGoalCommand("set   ship oauth");
    try std.testing.expectEqual(@as(std.meta.Tag(GoalCommand), .set), std.meta.activeTag(set_cmd));
    try std.testing.expectEqualStrings("ship oauth", set_cmd.set);

    const edit_cmd = parseGoalCommand("edit revised goal ");
    try std.testing.expectEqual(@as(std.meta.Tag(GoalCommand), .edit), std.meta.activeTag(edit_cmd));
    try std.testing.expectEqualStrings("revised goal", edit_cmd.edit);

    const budget_cmd = parseGoalCommand("budget 123");
    try std.testing.expectEqual(@as(std.meta.Tag(GoalCommand), .budget), std.meta.activeTag(budget_cmd));
    try std.testing.expectEqual(@as(?u64, 123), budget_cmd.budget);

    const clear_budget = parseGoalCommand("budget none");
    try std.testing.expectEqual(@as(std.meta.Tag(GoalCommand), .budget), std.meta.activeTag(clear_budget));
    try std.testing.expectEqual(@as(?u64, null), clear_budget.budget);

    try std.testing.expectEqual(@as(std.meta.Tag(GoalCommand), .pause), std.meta.activeTag(parseGoalCommand("pause")));
    try std.testing.expectEqual(@as(std.meta.Tag(GoalCommand), .resume_goal), std.meta.activeTag(parseGoalCommand("resume")));
    try std.testing.expectEqual(@as(std.meta.Tag(GoalCommand), .complete), std.meta.activeTag(parseGoalCommand("complete")));
    try std.testing.expectEqual(@as(std.meta.Tag(GoalCommand), .blocked), std.meta.activeTag(parseGoalCommand("block")));
    try std.testing.expectEqual(@as(std.meta.Tag(GoalCommand), .invalid), std.meta.activeTag(parseGoalCommand("budget nope")));
}

test "/loop command parser covers user input command surface" {
    try std.testing.expectEqual(@as(std.meta.Tag(LoopCommand), .status), std.meta.activeTag(parseLoopCommand("")));
    try std.testing.expectEqual(@as(std.meta.Tag(LoopCommand), .status), std.meta.activeTag(parseLoopCommand("status")));
    try std.testing.expectEqual(@as(std.meta.Tag(LoopCommand), .off), std.meta.activeTag(parseLoopCommand("off")));
    try std.testing.expectEqual(@as(std.meta.Tag(LoopCommand), .off), std.meta.activeTag(parseLoopCommand("stop")));

    const on_default = parseLoopCommand("on");
    try std.testing.expectEqual(@as(std.meta.Tag(LoopCommand), .on), std.meta.activeTag(on_default));
    try std.testing.expectEqual(@as(u32, 10), on_default.on);

    const on_limited = parseLoopCommand("on 3");
    try std.testing.expectEqual(@as(std.meta.Tag(LoopCommand), .on), std.meta.activeTag(on_limited));
    try std.testing.expectEqual(@as(u32, 3), on_limited.on);

    try std.testing.expectEqual(@as(std.meta.Tag(LoopCommand), .invalid), std.meta.activeTag(parseLoopCommand("on 0")));
    try std.testing.expectEqual(@as(std.meta.Tag(LoopCommand), .invalid), std.meta.activeTag(parseLoopCommand("on nope")));
    try std.testing.expectEqual(@as(std.meta.Tag(LoopCommand), .invalid), std.meta.activeTag(parseLoopCommand("forever")));
}

test "L2 #16: /resume 切 app.session_id + permission_ctx.session(路由键随会话)" {
    const a = std.testing.allocator;
    const ppaths = @import("platform").paths;
    const home = "/tmp/cc-resume-l2-16";
    _ = std.c.mkdir(home, 0o755);
    // handleResume 走 homeDir()(env);setEnv HOME 后 defer 还原,免污染同 binary 其它测试(单线程顺序跑)。
    const old_home = std.c.getenv("HOME");
    ppaths.setEnv("HOME", home);
    defer if (old_home) |h| ppaths.setEnv("HOME", h) else ppaths.unsetEnv("HOME");
    ppaths.setEnv("METACODES_NO_PROBE", "1"); // 跳过 App.init 的终端背景 probe

    // App 用独立 arena(App 是 arena 生命周期设计,避免 testing.allocator 噪声);测试自身用 a。
    var app_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer app_arena.deinit();
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    const cfg = types_mod.Config{ .model = "claude-sonnet-4-20250514" };
    const app = try app_mod.App.init(app_arena.allocator(), io_rt.io(), cfg, "test-key");
    defer app.deinit();
    const old_id = app.session_id; // 启动时 gen 的旧 id

    // 造一个磁盘 session(与 handleResume 的 getCwd()+home 对齐 → listSessions 能找到)。
    const cwd = try util_fs.getCwd(a);
    defer a.free(cwd);
    var conv = Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "resume me");
    const sid = transcript_mod.genSessionId();
    var w = try transcript_mod.Writer.init(a, cwd, home, "claude-sonnet-4-20250514", sid);
    w.flush(&conv);
    w.deinit();

    // resume by id → 修复前 app.session_id 仍是 old_id(漂移);修复后切到 sid。
    // 传 app.allocator(生产同款:staged conversation 用 app.allocator,loadTranscript 须同源,否则
    // conversation 消息块 alloc/free 跨 allocator 泄漏)。
    try handleResume(app, app_arena.allocator(), sid.asSlice());
    try std.testing.expect(!std.mem.eql(u8, &old_id.bytes, &app.session_id.bytes)); // 变了
    try std.testing.expectEqualStrings(sid.asSlice(), app.session_id.asSlice()); // 切到 resumed
    try std.testing.expectEqualStrings(sid.asSlice(), app.permission_ctx.session.asSlice()); // 路由键同步
}

test "/goal accounting delta charges only input plus output usage" {
    const before = usage_mod.UsageTotals{
        .input_tokens = 10,
        .output_tokens = 20,
        .cache_read_input_tokens = 100,
        .cache_creation_input_tokens = 200,
    };
    const after = usage_mod.UsageTotals{
        .input_tokens = 15,
        .output_tokens = 27,
        .cache_read_input_tokens = 999,
        .cache_creation_input_tokens = 999,
    };
    try std.testing.expectEqual(@as(u64, 12), goalBudgetTokenDelta(before, after));
}
