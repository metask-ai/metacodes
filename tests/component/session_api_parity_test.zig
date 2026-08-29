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

        self.io_rt = std.Io.Threaded.init(allocator, .{});
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
    const d_mode = session_service.execLine(&svc, alloc, "/mode plan");
    try std.testing.expect(d_mode.run == null);
    try std.testing.expectEqual(session_service.CommandOutcome.Kind.mode_changed, d_mode.outcome.kind);
    try std.testing.expectEqual(cc.types_mod.PermissionMode.plan, app.permMode());
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

    var journal = cc.web_journal.EventJournal.init(std.testing.allocator);
    defer journal.deinit();
    var wb = cc.web_backend.WebBackend.init(std.testing.allocator, &journal);
    defer wb.deinit();

    const canonical = session_service.buildRunOptions(app, null);
    var web_opts = cc.web_session.buildWebOptions(app, &wb, null);
    // web 宿主专属字段:ui_requester(WebBackend 对话框)。抹平后必须与 canonical 完全一致
    // ——web 再漏字段(旧病:缺 lsp/swarm/background_request)会在此变红。
    try std.testing.expect(web_opts.ui_requester != null);
    web_opts.ui_requester = canonical.ui_requester;
    try std.testing.expect(std.meta.eql(canonical, web_opts));
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
