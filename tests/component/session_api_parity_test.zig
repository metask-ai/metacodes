//! L2 组件测试(U11 / issue #3):**Session API 三前端等价性**。
//!
//! 锁定的契约:TUI(repl/loop.zig)、web(web/session.zig)、daemon(daemon/app_driver.zig)
//! 的会话业务全部经同一条 canonical 管线:
//!
//!   raw → session_intent.parse → SessionService.dispatch/execLine → outcome(+RunPlan)
//!   run 字段装配 → session_service.buildRunOptions(唯一装配点)
//!
//! 本测试在**真 App**(App.init 全初始化,非 undefined 最小化)上驱动 execLine——即 web/
//! daemon 的字面入口,也是 TUI 各命令分支的下沉终点——证明 mutation 语义单源。
//! 跨模块:session_intent + session_service + app + conversation + web/session(≥3,合 L2)。

const std = @import("std");
const cc = @import("cc");
const harness = @import("harness");
const ppaths = @import("platform").paths;

const session_service = cc.session_service;
const session_intent = cc.session_intent;

const EnvGuard = struct {
    allocator: std.mem.Allocator,
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(allocator: std.mem.Allocator, name: [*:0]const u8, value: [*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try allocator.dupeZ(u8, std.mem.span(raw)) else null;
        ppaths.setEnv(name, value);
        return .{ .allocator = allocator, .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            self.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
        self.* = undefined;
    }
};

/// 真 App fixture(对齐 plugin_runtime_test 惯例):tmp HOME + NO_PROBE,arena 生命周期。
const AppFixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    home_guard: EnvGuard,
    probe_guard: EnvGuard,
    app: *cc.app_module.App,

    /// **in-place** 初始化(self 必须是 caller 栈上的最终地址):arena.allocator()/io_rt.io()
    /// 捕获 &self.arena/&self.io_rt——按值返回会悬垂(App 持着搬走前的旧地址)。
    fn setup(self: *AppFixture) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(std.testing.io, &root_buffer);
        const root = root_buffer[0..len];

        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer self.arena.deinit();
        const allocator = self.arena.allocator();

        const home_z = try allocator.dupeZ(u8, root);
        self.home_guard = try EnvGuard.set(std.testing.allocator, "HOME", home_z.ptr);
        errdefer self.home_guard.restore();
        self.probe_guard = try EnvGuard.set(std.testing.allocator, "METACODES_NO_PROBE", "1");
        errdefer self.probe_guard.restore();

        const argv = [_][*:0]const u8{ "metacodes", "--permission", "bypassPermissions" };
        const config = cc.parseArgsForTest(&argv, allocator);
        try std.testing.expect(config.parse_error == null);

        self.io_rt = @import("platform").signal.threadedIo(allocator, .{});
        errdefer self.io_rt.deinit();
        self.app = try cc.app_module.App.init(allocator, self.io_rt.io(), config, "test-key");
    }

    fn deinit(self: *AppFixture) void {
        self.app.deinit();
        self.io_rt.deinit();
        self.probe_guard.restore();
        self.home_guard.restore();
        self.arena.deinit();
        self.tmp.cleanup();
    }
};

test "U11 parity: 意图表与 dispatch 分类一致(service 动词必被 service 消化)" {
    // 纯解析层:BUILTIN_VERBS 每个动词 `/verb` 都解析回同名 command + 同 class——
    // 三前端共用此表,新增动词漏登记会在此暴露。
    for (session_intent.BUILTIN_VERBS) |spec| {
        var buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "/{s}", .{spec.name});
        const intent = session_intent.parse(line);
        try std.testing.expect(intent == .command);
        try std.testing.expectEqualStrings(spec.name, intent.command.verb);
        try std.testing.expectEqual(spec.class, intent.command.class);
    }
    // 非表内 head 落 skill 车道(内建优先契约的另一半)。
    try std.testing.expect(session_intent.parse("/definitely-not-a-verb x") == .skill);
}

test "U11 parity: execLine 在真 App 上的 config mutation 语义(mode/vim/compact)" {
    var fx: AppFixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const app = fx.app;
    var svc = session_service.SessionService.init(app);
    const alloc = fx.arena.allocator();

    // /mode <name>(web/daemon 的字面路径;TUI /mode 同一调用)。
    const d_mode = session_service.execLine(&svc, alloc, "/mode auto");
    try std.testing.expect(d_mode.run == null);
    try std.testing.expectEqual(session_service.CommandOutcome.Kind.mode_changed, d_mode.outcome.kind);
    try std.testing.expectEqual(cc.types_mod.PermissionMode.auto, app.permMode());
    // 连字符归一(web 客户端习惯)与非法名 fail-closed。
    try std.testing.expectEqual(session_service.CommandOutcome.Kind.mode_changed, session_service.execLine(&svc, alloc, "/mode accept-edits").outcome.kind);
    try std.testing.expectEqual(cc.types_mod.PermissionMode.accept_edits, app.permMode());
    const bad = session_service.execLine(&svc, alloc, "/mode not-a-mode");
    try std.testing.expectEqual(session_service.CommandOutcome.Kind.err, bad.outcome.kind);
    try std.testing.expectEqual(cc.types_mod.PermissionMode.accept_edits, app.permMode()); // 未变

    // /vim 翻转(TUI 渲染留终端,状态变更单源)。
    const vim_before = app.config.vim_mode;
    try std.testing.expectEqual(session_service.CommandOutcome.Kind.vim_changed, session_service.execLine(&svc, alloc, "/vim").outcome.kind);
    try std.testing.expect(app.config.vim_mode != vim_before);

    // /compact 结构化载荷(TUI/web 各自渲染同一份数据)。
    const d_compact = session_service.execLine(&svc, alloc, "/compact");
    try std.testing.expectEqual(session_service.CommandOutcome.Kind.compacted, d_compact.outcome.kind);

    // 终端表达类(.local)动词在 service 层 unhandled——web/daemon 报 unsupported,
    // TUI 自渲染;它们**不产生**任何会话 mutation。
    const before_len = app.conversation.messages.items.len;
    const d_local = session_service.execLine(&svc, alloc, "/help");
    try std.testing.expectEqual(session_service.CommandOutcome.Kind.unhandled, d_local.outcome.kind);
    try std.testing.expect(d_local.run == null);
    try std.testing.expectEqual(before_len, app.conversation.messages.items.len);
}

test "U11 parity: prompt/宏/retry/shell 的对话 mutation 全在 service 层" {
    var fx: AppFixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const app = fx.app;
    var svc = session_service.SessionService.init(app);
    const alloc = fx.arena.allocator();

    // 空提交:无操作无计划(三前端一致的"空 enter 不做事")。
    try std.testing.expect(session_service.execLine(&svc, alloc, "   ").run == null);

    // prompt:append user + user_prompt 计划。
    const d1 = session_service.execLine(&svc, alloc, "hello parity");
    try std.testing.expect(d1.run != null);
    try std.testing.expectEqual(session_service.RunPlan.Kind.user_prompt, d1.run.?.kind);
    try std.testing.expectEqual(@as(usize, 1), app.conversation.messages.items.len);

    // /commit 宏:append COMMIT_PROMPT + injected_macro 计划(prompt 常量单源)。
    const d2 = session_service.execLine(&svc, alloc, "/commit");
    try std.testing.expectEqual(session_service.RunPlan.Kind.injected_macro, d2.run.?.kind);
    try std.testing.expectEqual(@as(usize, 2), app.conversation.messages.items.len);
    const last = app.conversation.messages.items[1];
    try std.testing.expect(std.mem.indexOf(u8, last.blocks[0].text, "git commit") != null);

    // 模拟一轮 assistant 响应后 /retry:回卷到最后一条 user(丢弃其后回合)。
    try app.conversation.appendText(.assistant, "draft answer");
    try std.testing.expectEqual(@as(usize, 3), app.conversation.messages.items.len);
    const d3 = session_service.execLine(&svc, alloc, "/retry");
    try std.testing.expectEqual(session_service.RunPlan.Kind.retry, d3.run.?.kind);
    try std.testing.expectEqual(@as(usize, 2), app.conversation.messages.items.len);

    // `!cmd` shell 车道:执行 + 输出进对话上下文(shell_ran,无 run 计划)。
    const d4 = session_service.execLine(&svc, alloc, "!echo parity-shell-ok");
    try std.testing.expectEqual(session_service.CommandOutcome.Kind.shell_ran, d4.outcome.kind);
    try std.testing.expect(d4.run == null);
    try std.testing.expectEqual(@as(usize, 3), app.conversation.messages.items.len);
    const shell_msg = app.conversation.messages.items[2];
    try std.testing.expect(std.mem.indexOf(u8, shell_msg.blocks[0].text, "[shell] $ echo parity-shell-ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, shell_msg.blocks[0].text, "parity-shell-ok") != null);

    // skill 车道:service 不消化(unhandled,宿主的 skill runtime 负责),零 mutation。
    const d5 = session_service.execLine(&svc, alloc, "/nopkg:noskill args");
    try std.testing.expectEqual(session_service.CommandOutcome.Kind.unhandled, d5.outcome.kind);
    try std.testing.expectEqual(@as(usize, 3), app.conversation.messages.items.len);
}

test "U11 parity: run Options 装配单源(web 只比 canonical 多 ui_requester)" {
    var fx: AppFixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const app = fx.app;

    var journal = cc.event_journal.EventJournal.init(std.testing.allocator);
    defer journal.deinit();
    var wb = cc.web_backend.WebBackend.init(std.testing.allocator, &journal);
    defer wb.deinit();

    const canonical = session_service.buildRunOptions(app, null);
    var web_opts = cc.web_session.buildWebOptions(app, &wb, null);
    // web 宿主专属字段:ui_requester(WebBackend 对话框)。抹平后必须与 canonical 完全一致
    // ——web 再漏字段(旧病:缺 lsp/swarm/background_request)会在此变红。
    try std.testing.expect(web_opts.ui_requester != null);
    web_opts.ui_requester = canonical.ui_requester;
    // 进度更新义务是宿主契约字段(#114):web 有人在看,自己接上;canonical 不带。抹平后比对。
    try std.testing.expect(web_opts.progress_updates);
    web_opts.progress_updates = canonical.progress_updates;
    web_opts.progress_updates_observe = canonical.progress_updates_observe;
    // 停滞闸门(stall gate)同属宿主契约字段:web 有人能一句话续接,默认 enforce;canonical 不带。
    try std.testing.expectEqual(@as(?cc.stall_gate.Mode, .enforce), web_opts.stall_gate);
    web_opts.stall_gate = canonical.stall_gate;
    try std.testing.expect(std.meta.eql(canonical, web_opts));
}

test "U11 parity: 过程义务门是宿主契约字段,canonical 不带(delivery_cadence 显式排除)" {
    // Codex round 6 (2026-09-21):注入宏 run / web 会话走 canonical 装配,若 canonical 带
    // cadence,一次 `/commit` 就多落一条终局记录,trace 契约(每份 journal 一条)作废。
    // 排除是设计决定,本测试让"顺手接上"变成显式改动。正向面见
    // tests/component/delivery_cadence_test.zig(REPL 主 run 与 headless 都接)。
    var fx: AppFixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const app = fx.app;
    app.config.delivery_cadence = true;
    app.config.delivery_cadence_observe = true;
    app.config.delivery_cadence_first = 1;
    app.config.delivery_cadence_second = 2;
    const canonical = session_service.buildRunOptions(app, null);
    const defaults = cc.agent_loop.Options{ .session = canonical.session, .abort = canonical.abort };
    try std.testing.expect(!canonical.delivery_cadence);
    try std.testing.expect(!canonical.delivery_cadence_observe);
    try std.testing.expect(std.meta.eql(defaults.delivery_cadence_thresholds, canonical.delivery_cadence_thresholds));
    try std.testing.expect(!canonical.verification_final_gate);
    try std.testing.expect(!canonical.requirement_ledger);
    // 宿主检查门同属宿主契约字段:canonical 不带,宏 run / skill run 不会跑检查命令。
    app.config.host_check_command = "make check";
    app.config.check_gate = true;
    app.config.check_gate_observe = true;
    try std.testing.expect(session_service.buildRunOptions(app, null).check_gate == null);
    // The learning turn rides the check gate's contract: canonical never
    // carries it; the headless primary run does once the gate is armed.
    app.config.learning_turn = true;
    try std.testing.expect(session_service.buildRunOptions(app, null).learning_turn == null);
    const headless_learning = cc.repl_headless.buildOptions(app, null, null, null, false, null, null, null).learning_turn.?;
    try std.testing.expectEqual(cc.learning_turn.Mode.enforce, headless_learning.mode);
    app.config.check_gate = false;
    app.config.check_gate_observe = false;
    try std.testing.expect(cc.repl_headless.buildOptions(app, null, null, null, false, null, null, null).learning_turn == null);
    app.config.learning_turn = false;
    // 测试完整性义务同属宿主契约字段:canonical 不带,宏 run 不比对测试、不发记录。
    app.config.test_integrity = true;
    app.config.test_integrity_observe = true;
    try std.testing.expect(session_service.buildRunOptions(app, null).test_integrity == null);
    // #114:进度更新门同样不进 canonical——即便 config 默认开着,宏 run / skill run 也不被提醒。
    app.config.progress_updates = true;
    app.config.progress_updates_observe = true;
    const again = session_service.buildRunOptions(app, null);
    try std.testing.expect(!again.progress_updates);
    try std.testing.expect(!again.progress_updates_observe);
    // 停滞闸门同样不进 canonical:宏 run / skill run 不会因"无新结果"被停。
    app.config.stall_gate = .enforce;
    try std.testing.expect(session_service.buildRunOptions(app, null).stall_gate == null);
}

test "R3-1回归: Ctrl+B 身份轮换 —— 新 session_id + 新 transcript 目录,权限路由同步" {
    // 缺陷形态:转后台后前台开新空会话(shrink_epoch=0)却复用旧 writer(seen>=1,
    // flushed=N)→ 下一次 flush 把旧 transcript 整个重写成新会话数条(历史被毁)。
    // 修复:App.rotateSessionIdentity 换 id + 新目录 writer,旧 transcript 封存。
    var fx: AppFixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const app = fx.app;

    const old_id = app.session_id;
    var old_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old_dir: ?[]const u8 = if (app.transcript_writer) |*w| blk: {
        @memcpy(old_dir_buf[0..w.dir.len], w.dir);
        break :blk old_dir_buf[0..w.dir.len];
    } else null;

    app.rotateSessionIdentity();

    try std.testing.expect(!std.meta.eql(old_id, app.session_id));
    try std.testing.expect(std.meta.eql(app.permission_ctx.session, app.session_id));
    if (old_dir) |d| {
        try std.testing.expect(app.transcript_writer != null);
        try std.testing.expect(!std.mem.eql(u8, d, app.transcript_writer.?.dir));
    }
}

test "#219: a main session handed off with Ctrl+B stays in the new foreground's agent view" {
    var fx: AppFixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const app = fx.app;
    const a = std.testing.allocator;
    const reg = app.agentJobsPtr() orelse return error.TestExpectedAgentRegistry;
    const Registry = @TypeOf(reg.*);

    const old_id = app.session_id;
    // Stands in for the job Ctrl+B spawns: it runs in the session it left.
    try reg.pushTestEntryFull(old_id, "main", "long refactor", 2, 300, "Bash", "{}", .running);
    try app.prepareHandOff();
    app.completeHandOff();
    try std.testing.expect(!std.meta.eql(old_id, app.session_id));

    // What the agent tree, footer and switcher read.
    const shown = try reg.snapshotJobsInScope(a, app.agentJobScope());
    defer Registry.freeSnapshots(a, shown);
    try std.testing.expectEqual(@as(usize, 1), shown.len);
    try std.testing.expectEqualStrings("long refactor", shown[0].desc);
    try std.testing.expectEqual(@as(usize, 1), reg.runningCountInScope(app.agentJobScope()));
    try std.testing.expectEqual(@as(usize, 1), reg.totalCountInScope(app.agentJobScope()));
    const out = (try reg.copyOutputBufInScope(shown[0].id, a, app.agentJobScope())) orelse return error.TestExpectedOutput;
    a.free(out);

    // Routing does not follow the foreground: the job is not the new
    // session's, and the new session's own projections do not see it.
    const routed = try reg.snapshotJobsForSession(a, app.session_id);
    defer Registry.freeSnapshots(a, routed);
    try std.testing.expectEqual(@as(usize, 0), routed.len);
    try std.testing.expectError(error.JobNotFound, reg.abortForSession(shown[0].id, app.session_id));

    // The switcher's stop reaches it through the same scope.
    try reg.abortInScope(shown[0].id, app.agentJobScope());
    try std.testing.expect(reg.entries.items[0].abort.isAborted());
}

const GOAL_FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":7,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "L2 goal (issue #277): every CLI Run charges the App's goal and goal.json follows" {
    const a = std.testing.allocator;
    var fx: AppFixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const app = fx.app;
    const meter = if (app.goal_meter) |*m| m else return error.MissingGoalMeter;

    // REPL, web, daemon and forked Skills build their Options canonically;
    // headless builds its own. Both carry the App's Meter and date announcer.
    const canonical = session_service.buildRunOptions(app, null);
    const headless = cc.repl_headless.buildOptions(app, null, null, null, false, null, null, null);
    try std.testing.expect(canonical.goal_meter == meter);
    try std.testing.expect(headless.goal_meter == meter);
    try std.testing.expect(canonical.time_announcer != null and canonical.time_announcer == headless.time_announcer);

    try app.goal_state.setNew("ship it", null);
    app.persistGoal();
    var srv = try harness.MockServer.startCassette(&.{GOAL_FINAL_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    // The App's allocator throughout, as the REPL uses it: the Run's records
    // join the App's Conversation.
    var client = cc.client_mod.Client.initWithBaseUrl(app.allocator, fx.io_rt.io(), "key", "model", url);
    defer client.deinit();
    try app.conversation.appendText(.user, "work on the goal");
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();
    var options = canonical;
    options.max_turns = 1;
    const result = try cc.agent_loop.run(&app.conversation, client.provider(), &.{}, &app.permission_ctx, options, &be, app.allocator);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    const charged = app.goal_state.current.?.tokens_used;
    try std.testing.expect(charged > 0);

    // The Meter's observer wrote goal.json when the Run settled.
    var loaded = cc.core_goal.State.init(a);
    defer loaded.deinit();
    try loaded.loadFromDir(app.sessionDir() orelse return error.NoSessionDir);
    try std.testing.expectEqual(charged, loaded.current.?.tokens_used);
}

/// The text of the message at 0-based `index` of `conversation`.
fn messageText(conversation: *const cc.conversation.Conversation, index: usize) []const u8 {
    return conversation.messages.items[index].blocks[0].text;
}

test "L2 /edit (issue #432): web/daemon/TUI edit user message n, rerun from it, and the transcript restores the edited history" {
    const a = std.testing.allocator;
    var fx: AppFixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const app = fx.app;
    var journal = cc.event_journal.EventJournal.init(a);
    defer journal.deinit();
    var wb = cc.web_backend.WebBackend.init(a, &journal);
    defer wb.deinit();

    try app.conversation.appendText(.user, "q1");
    try app.conversation.appendText(.assistant, "a1");
    try app.conversation.appendText(.user, "q2");
    try app.conversation.appendText(.assistant, "a2");
    try app.conversation.appendText(.user, "q3");
    try app.conversation.appendText(.assistant, "a3");
    try app.conversation.appendHostText("[runtime notice]");
    app.persistTranscript();
    try app.read_state.record("/tmp/read-in-a-dropped-turn", 1, 1);

    // Refusals: each names its reason, plans no run and changes nothing.
    const refused = [_]struct { line: []const u8, reason: []const u8 }{
        .{ .line = "/edit", .reason = "usage: /edit" },
        .{ .line = "/edit 3", .reason = "usage: /edit" },
        .{ .line = "/edit three new", .reason = "(InvalidPosition)" },
        .{ .line = "/edit 0 new", .reason = "(PositionOutOfRange)" },
        .{ .line = "/edit 99 new", .reason = "(PositionOutOfRange)" },
        .{ .line = "/edit 2 new", .reason = "(NotUserMessage)" },
        .{ .line = "/edit 7 new", .reason = "(NotUserMessage)" },
    };
    for (refused) |case| {
        var batch: cc.web_session.CommandBatch = .{};
        defer batch.deinit(a);
        try std.testing.expect(cc.web_session.execCommand(app, &wb, a, case.line, &batch) == null);
        try std.testing.expect(!batch.run_planned);
        var buf: [256]u8 = undefined;
        var svc = session_service.SessionService.init(app);
        const d = session_service.execLine(&svc, app.allocator, case.line);
        try std.testing.expect(d.run == null);
        try std.testing.expect(std.mem.indexOf(u8, d.outcome.render(&buf), case.reason) != null);
        try std.testing.expectEqual(@as(usize, 7), app.conversation.len());
    }

    // The TUI's `/edit` alone lists what can be edited, by the number it takes.
    var listing: std.Io.Writer.Allocating = .init(a);
    defer listing.deinit();
    try session_service.writeEditableMessages(&listing.writer, &app.conversation);
    try std.testing.expect(std.mem.indexOf(u8, listing.written(), "     3  q2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing.written(), "runtime notice") == null);
    try std.testing.expect(std.mem.indexOf(u8, listing.written(), "a1") == null);

    // The web/daemon entry (POST /command) edits message 3 and plans the run.
    var batch: cc.web_session.CommandBatch = .{};
    defer batch.deinit(a);
    const plan = cc.web_session.execCommand(app, &wb, a, "/edit 3   q2, edited  ", &batch) orelse return error.NoRunPlanned;
    try std.testing.expectEqual(session_service.RunPlan.Kind.edited_prompt, plan.kind);
    try std.testing.expectEqual(@as(usize, 3), app.conversation.len());
    try std.testing.expectEqualStrings("q1", messageText(&app.conversation, 0));
    try std.testing.expectEqualStrings("a1", messageText(&app.conversation, 1));
    try std.testing.expectEqualStrings("q2, edited", messageText(&app.conversation, 2));
    try std.testing.expect(app.read_state.get("/tmp/read-in-a-dropped-turn") == null);
    {
        // The Run begins once the batch has run: its user_message (wire v1, #444)
        // follows the command_result and carries the run_id and `replaces`.
        cc.web_session.beginPlannedRun(&wb, &batch);
        cc.web_session.announceRunFailed(&wb, "NotRunHere");
        const lines = (try journal.waitSince(a, 0, 1)) orelse return error.NoJournal;
        defer {
            for (lines) |line| a.free(line);
            a.free(lines);
        }
        const echo = "{\"v\":1,\"type\":\"user_message\",\"data\":{\"run_id\":1,\"trace_id\":null,\"text\":\"q2, edited\",\"replaces\":3}}";
        const queued = "{\"v\":1,\"type\":\"command_result\",\"data\":{\"command\":\"edit\",\"ok\":true,\"error_name\":null,\"message\":\"queued for run\"}}";
        var at_echo: ?usize = null;
        var at_queued: ?usize = null;
        for (lines, 0..) |line, index| {
            if (std.mem.eql(u8, line, echo)) at_echo = index;
            if (std.mem.eql(u8, line, queued)) at_queued = index;
        }
        try std.testing.expect(at_queued.? < at_echo.?);
    }

    // The transcript on disk follows the edit (a full rewrite), so a restart
    // restores messages 1-2 + the edited message, never the dropped turns.
    app.persistTranscript();
    var restored = cc.conversation.Conversation.init(a);
    defer restored.deinit();
    try cc.transcript.loadTranscript(&restored, app.sessionDir() orelse return error.NoSessionDir, a);
    try std.testing.expectEqual(@as(usize, 3), restored.len());
    try std.testing.expectEqualStrings("q1", messageText(&restored, 0));
    try std.testing.expectEqualStrings("q2, edited", messageText(&restored, 2));

    // A position the compact summary stands for cannot be rerun.
    try app.conversation.appendText(.assistant, "a2'");
    try app.conversation.restoreCompactState(2, "summary of q1/a1");
    var svc = session_service.SessionService.init(app);
    var buf: [256]u8 = undefined;
    const compacted = session_service.execLine(&svc, app.allocator, "/edit 1 q1 again");
    try std.testing.expect(compacted.run == null);
    try std.testing.expect(std.mem.indexOf(u8, compacted.outcome.render(&buf), "(PositionCompacted)") != null);
    try std.testing.expectEqual(@as(usize, 4), app.conversation.len());
    listing.clearRetainingCapacity();
    try session_service.writeEditableMessages(&listing.writer, &app.conversation);
    try std.testing.expect(std.mem.indexOf(u8, listing.written(), "     1  q1  (compacted; cannot be edited)\n") != null);
    // The first message after the boundary still can: the summary is the
    // context before it, as in every request since the compaction.
    try std.testing.expect(session_service.execLine(&svc, app.allocator, "/edit 3 q2 once more").run != null);
    try std.testing.expectEqual(@as(usize, 3), app.conversation.len());
    try std.testing.expectEqualStrings("q2 once more", messageText(&app.conversation, 2));
}
