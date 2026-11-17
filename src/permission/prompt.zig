//! 用户交互:权限询问(prompt 模式的 yes/always/no/don't-ask)。
//!
//! 已设注入的 UI runner(PermissionContext.ui_request_fn)→ 发 .permission UiRequest 让前端
//! 渲染;无 runner → 退回最简文字 prompt。**不直接依赖任何 TUI 对话框**(库可在无 UI 时复用)。
//!
//! Session 级记忆("Yes always" / "Don't ask again")、persist 路径、UI runner 全部经
//! PermissionContext 携带(每 session 一份),不再用进程全局——多 Session 不串台。

const std = @import("std");
const pfs = @import("platform").fs;
const platform_term = @import("platform").terminal;
const shutdown = @import("../core/shutdown.zig");
const category = @import("category.zig");
const PermissionChoice = @import("../core/protocol/permission_choice.zig").PermissionChoice;
const ui_request = @import("../core/protocol/ui_request.zig");
const PermissionContext = @import("../permission.zig").PermissionContext;

/// Why a prompt ended with nobody's answer. Every one denies, and the caller
/// must not report it as the user's decision: it tells the model which it was
/// (agent_loop's `.ask` branch, doc/WIRE_PROTOCOL.md §1.4).
pub const Unanswered = error{
    /// The connected frontend declared it cannot render permission prompts
    /// (doc/WIRE_PROTOCOL.md §2.2): nobody was asked.
    PromptUnrenderable,
    /// Nobody answered before the Host's deadline.
    PromptTimedOut,
    /// An interrupt or a close cancelled the request before anyone answered.
    PromptCancelled,
    /// An answer arrived but could not be read.
    PromptAnswerUnreadable,
    /// This session has no way to ask and wait for an answer: no requester
    /// under `no_interactive_prompt`, or one that answered `.unavailable` or
    /// `.pending` (the gate is synchronous and cannot suspend).
    PromptNobodyToAsk,
    /// The requester failed before anyone answered.
    PromptRequestFailed,
};

/// 阻塞式询问用户。返回 true = 允许。ctx 携带 session 记忆 / UI runner / persist 路径。
/// **ctx 非 const**:本函数有副作用(写 session 记忆 rememberAllow/Deny、写 settings.local.json)。
/// 线程契约:M6 前假设单线程调用(SessionRules 无锁);M6 多 session 多线程化时给 SessionRules 加锁。
/// `false` is a person's deny (an answer, or one remembered for the session);
/// an `Unanswered` error is a deny nobody gave, and says why.
pub fn ask(ctx: *PermissionContext, tool_name: []const u8, args: []const u8) Unanswered!bool {
    return askWith(ctx, tool_name, args, false);
}

/// The prompt a `PermissionContext.confirm_gate` demands (sealed `confirm:
/// true`, doc/SEALED_SKILL_PROTOCOL.md §6.2): identical to `ask`, except that a
/// remembered "allow always" for the tool does not answer it. A remembered
/// deny still does, since the gate may only tighten; an "allow always" the
/// user gives here is still remembered for the tool's ordinary calls.
pub fn askForced(ctx: *PermissionContext, tool_name: []const u8, args: []const u8) Unanswered!bool {
    return askWith(ctx, tool_name, args, true);
}

fn askWith(ctx: *PermissionContext, tool_name: []const u8, args: []const u8, forced: bool) Unanswered!bool {
    // session 记忆优先(per-session,不串台)
    if (ctx.session_rules) |sr| {
        if (!forced and sr.isAllowed(tool_name)) return true;
        if (sr.isDenied(tool_name)) return false;
    }

    // `no_interactive_prompt` is an absolute ownership boundary: a requester
    // may answer, but every non-answer must fail closed instead of consulting
    // process-global answer queues or fd 0. This covers embedded libraries as
    // well as swarm teammates whose Host owns the surrounding process input.
    if (ctx.no_interactive_prompt and ctx.ui_requester == null) return error.PromptNobodyToAsk;

    // 预置应答队列曾加载(Stage 3 e2e)→ 强制走文字路径(askText 从队列弹/耗尽则
    // 安全默认 deny,**绝不**退回读 fd 0——它被 REPL 行流独占,会死等)。
    if (!ctx.no_interactive_prompt and
        @import("../core/answer_queue.zig").wasLoaded())
    {
        return askText(tool_name, args);
    }

    // 已注入 runner → 经 UiRequest 让前端渲染对话框。**不 gate 在 isatty 上**:
    // UiRequester 是 UI 中立抽象,web/GUI 前端无 tty 也能渲染(旧 isatty gate 是 TUI
    // 时代的泄漏——web 模式非 tty 启动会掉进 fd 0 文字 prompt 死等)。
    // 无 runner(库消费者未接 UI / 无 watcher 场景)→ 落到下方文字 prompt。
    if (ctx.ui_requester != null or platform_term.isatty(0)) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        // What a deny without an answer reports, if no fallback prompt asks.
        var unanswered: Unanswered = error.PromptNobodyToAsk;
        const choice_opt: ?PermissionChoice = blk: {
            if (ctx.ui_requester) |runner| {
                const req = ui_request.UiRequest{ .permission = .{ .tool = tool_name, .args = args } };
                var resp: ui_request.UiResponse = undefined;
                // permission 门是 executeSlots 前的同步门,不支持挂起(out of scope)——
                // 仅 .answered 读 resp;.pending/.unavailable 落文字 prompt 兜底。
                const outcome = runner.request(ctx.session, arena.allocator(), &req, &resp) catch |err| switch (err) {
                    // The request was announced and ended with nobody's answer
                    // (#463). The frontend was asked, so no terminal prompt
                    // stands in for it: deny at once, saying why.
                    error.UiRequestTimedOut => return error.PromptTimedOut,
                    error.UiRequestCancelled => return error.PromptCancelled,
                    error.UiAnswerUnreadable => return error.PromptAnswerUnreadable,
                    else => {
                        unanswered = error.PromptRequestFailed;
                        break :blk null;
                    },
                };
                switch (outcome) {
                    .answered => {},
                    // 连着的前端声明了渲染不了权限请求(doc/WIRE_PROTOCOL.md §2.2):没人能答,
                    // 终端也不是这个前端——不落文字 prompt,直接拒绝。调用方据此如实告诉模型
                    // 不是用户拒绝的。
                    .unrenderable => return error.PromptUnrenderable,
                    .pending, .unavailable => break :blk null,
                }
                break :blk switch (resp) {
                    .permission => |c| c,
                    else => {
                        unanswered = error.PromptAnswerUnreadable;
                        break :blk null;
                    },
                };
            }
            break :blk null; // 无 runner → 落文字 prompt(不再裸调 TUI dialog)
        };
        if (choice_opt) |choice| {
            switch (choice) {
                .allow_once => return true,
                .allow_always => {
                    if (ctx.session_rules) |sr| sr.rememberAllow(tool_name);
                    // A Session-scoped context never writes: no loader of an
                    // embedding Host reads the file back, so the write would
                    // only leave a whole-tool grant in the user's workspace
                    // for the next CLI started there.
                    if (ctx.always_allow == .session) return true;
                    // 持久化:写到 settings.local.json(project)或 ~/.claude/settings.json。
                    // 路径上下文复用 ctx.match_ctx(project_root / home)——App init 在 ask 之前填好。
                    const home = ctx.match_ctx.home;
                    if (home.len > 0) {
                        const writer = @import("settings_writer.zig");
                        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const project: ?[]const u8 = if (ctx.match_ctx.project_root.len > 0) ctx.match_ctx.project_root else null;
                        const written = writer.addAllowRule(arena.allocator(), project, home, tool_name, &path_buf) catch null;
                        if (written) |p| {
                            std.debug.print("\x1b[2m(persisted to {s})\x1b[0m\n", .{p});
                        }
                    } else {
                        // match_ctx 未填(理论上 ask 总在 init 后,home 非空)。仍 allow_always,
                        // 但 session 内有效、不落盘——显式 warn,避免"权限记不住"静默失败抓瞎。
                        @import("../util/log.zig").warn("permission", "allow_always persist skipped: match_ctx.home empty (only session-scoped)", .{});
                    }
                    return true;
                },
                .deny_once => return false,
                .deny_tool_session => {
                    if (ctx.session_rules) |sr| sr.rememberDeny(tool_name);
                    return false;
                },
            }
        }
        // requester 存在但未给出答案(异常/pending/unavailable)时，库消费者绝不
        // 回落到进程 stdin。交互产品仍保留既有文字 prompt 兜底。
        if (ctx.no_interactive_prompt) return unanswered;
        // requester 存在但未给出答案且无 tty 可回落 → 安全 deny。
        // 绝不读 fd 0:web/GUI daemon 的 fd 0 不属于权限系统(读它 = 死等或吞别人的输入)。
        // tty 场景保留 askText 回落(TUI dialog Esc 的存量语义不动)。
        if (!platform_term.isatty(0)) return unanswered;
        // dialog 返回 null(意外非 TTY)→ 落到文字
    }

    // Keep the invariant local to the only textual input edge as defense in
    // depth if the control flow above changes later.
    if (ctx.no_interactive_prompt) return error.PromptNobodyToAsk;
    // 非 TTY 退回文字 prompt
    return askText(tool_name, args);
}

/// 最简文字 prompt(非 TTY / dialog 不可用时)。
fn askText(tool_name: []const u8, args: []const u8) !bool {
    const aq = @import("../core/answer_queue.zig");
    // 预置应答队列(Stage 3 e2e):非 tty 下 fd 0 被 REPL 行流独占,从队列按序弹应答。
    // y/Y/a(always) → 允许;其余(n 等)→ 拒绝。
    if (aq.pop()) |ans| {
        const yes = ans.len > 0 and (ans[0] == 'y' or ans[0] == 'Y' or ans[0] == 'a' or ans[0] == 'A');
        std.debug.print("\x1b[2m[Permission] {s}: 预置应答 '{s}' → {s}\x1b[0m\n", .{ tool_name, ans, if (yes) "允许" else "拒绝" });
        return yes;
    }
    // 队列曾加载但已耗尽 → 安全默认 deny(不退回 fd 0 死等)。
    if (aq.wasLoaded()) {
        std.debug.print("\x1b[2m[Permission] {s}: 应答队列耗尽 → 默认拒绝\x1b[0m\n", .{tool_name});
        return false;
    }

    const risk = category.getRiskLevel(tool_name);
    const risk_str: []const u8 = switch (risk) {
        .low => "LOW",
        .medium => "MEDIUM",
        .high => "HIGH",
    };
    std.debug.print("\x1b[33m[Permission] {s} tool requires {s} risk action\x1b[0m\n", .{ tool_name, risk_str });
    std.debug.print("  Args: {s}\n", .{args});
    std.debug.print("Allow? [y/N]: ", .{});

    var buf: [10]u8 = undefined;
    const n = while (true) {
        const got = platform_term.readInput(0, &buf); // console 宽读统一入口(review-2 F4)
        if (got < 0 and readInterrupted()) continue;
        break got;
    };
    if (n > 0 and (buf[0] == 'y' or buf[0] == 'Y')) return true;
    return false;
}

/// Whether a failed answer read only lost a race with a signal. The REPL's
/// SIGWINCH handler has no SA_RESTART, so a resize turns the blocked read into
/// EINTR, which is no answer (it used to be a silent deny). A requested
/// shutdown still ends the prompt. This module is exported by lib.zig and
/// cannot use repl/'s `input.retryInterruptedRead`; same rule, minus the
/// terminal-mode reconcile that only raw mode needs. Windows console reads do
/// not set errno.
fn readInterrupted() bool {
    if (@import("builtin").os.tag == .windows) return false;
    return pfs.lastErrnoIs(.INTR) and !shutdown.requested();
}

// session 记忆的单测在 session_rules.zig;ask 的真链路(answer_queue → ask → askText)
// 在 tests/component/answer_queue_test.zig 覆盖。

test "an answer read a resize interrupted is read again unless the process is shutting down" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    defer shutdown.resetForTesting();
    std.c._errno().* = @intFromEnum(std.c.E.INTR);
    try std.testing.expect(readInterrupted());
    // A real read failure is still no answer: deny.
    std.c._errno().* = @intFromEnum(std.c.E.IO);
    try std.testing.expect(!readInterrupted());
    shutdown.request();
    std.c._errno().* = @intFromEnum(std.c.E.INTR);
    try std.testing.expect(!readInterrupted());
}

test "no_interactive_prompt: 无 ui_requester 时 .ask 直接 deny(绝不读 fd 0,PM SW4 3c)" {
    const testing = std.testing;
    // teammate 场景:no_interactive_prompt=true + ui_requester=null → ask 必 return false,
    // 不落 askText 读 fd 0(此测试在无 tty/CI 环境跑,若真读 fd 0 会 hang/EOF)。
    var ctx = PermissionContext{ .allocator = testing.allocator, .no_interactive_prompt = true };
    ctx.setMode(.default);
    // Fail-closed deny, and nobody's: there was no one to ask (#463).
    try testing.expectError(error.PromptNobodyToAsk, ask(&ctx, "Write", "{\"file_path\":\"/x\"}"));
    try testing.expectError(error.PromptNobodyToAsk, askForced(&ctx, "Write", "{\"file_path\":\"/x\"}"));
}

test "no_interactive_prompt: requester non-answer never falls back to process answer queue" {
    const testing = std.testing;
    const answer_queue = @import("../core/answer_queue.zig");
    const Unavailable = struct {
        calls: usize = 0,

        fn request(
            raw: *anyopaque,
            _: ui_request.SessionId,
            _: std.mem.Allocator,
            _: *const ui_request.UiRequest,
            _: *ui_request.UiResponse,
        ) anyerror!ui_request.RequestOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .unavailable;
        }
    };

    answer_queue.load("y\n");
    defer answer_queue.resetForTest();
    var unavailable = Unavailable{};
    var ctx = PermissionContext{
        .allocator = testing.allocator,
        .no_interactive_prompt = true,
        .ui_requester = .{ .ctx = &unavailable, .requestFn = Unavailable.request },
    };
    ctx.setMode(.default);
    try testing.expectError(error.PromptNobodyToAsk, ask(&ctx, "Write", "{\"file_path\":\"/x\"}"));
    try testing.expectEqual(@as(usize, 1), unavailable.calls);
    // The process-global answer was not consumed by the embedded Session.
    try testing.expectEqualStrings("y", answer_queue.pop().?);
}

test "a frontend that cannot render permission prompts denies without any fallback prompt" {
    const testing = std.testing;
    const Unrenderable = struct {
        calls: usize = 0,

        fn request(
            raw: *anyopaque,
            _: ui_request.SessionId,
            _: std.mem.Allocator,
            _: *const ui_request.UiRequest,
            _: *ui_request.UiResponse,
        ) anyerror!ui_request.RequestOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .unrenderable;
        }
    };
    var unrenderable = Unrenderable{};
    // A product context (not `no_interactive_prompt`): even here no terminal
    // prompt is the frontend, so nothing falls back to one.
    var ctx = PermissionContext{
        .allocator = testing.allocator,
        .ui_requester = .{ .ctx = &unrenderable, .requestFn = Unrenderable.request },
    };
    ctx.setMode(.default);
    try testing.expectError(error.PromptUnrenderable, ask(&ctx, "Write", "{\"file_path\":\"/x\"}"));
    try testing.expectError(error.PromptUnrenderable, askForced(&ctx, "Write", "{\"file_path\":\"/x\"}"));
    try testing.expectEqual(@as(usize, 2), unrenderable.calls);
}

test "a prompt nobody answered says why and never falls back to a terminal prompt (#463)" {
    const testing = std.testing;
    const answer_queue = @import("../core/answer_queue.zig");
    const Scripted = struct {
        calls: usize = 0,
        result: anyerror!ui_request.RequestOutcome = .answered,
        response: ui_request.UiResponse = .{ .permission = .deny_once },

        fn request(
            raw: *anyopaque,
            _: ui_request.SessionId,
            _: std.mem.Allocator,
            _: *const ui_request.UiRequest,
            out: *ui_request.UiResponse,
        ) anyerror!ui_request.RequestOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            const outcome = try self.result;
            if (outcome == .answered) out.* = self.response;
            return outcome;
        }
    };
    const Case = struct {
        result: anyerror!ui_request.RequestOutcome,
        response: ui_request.UiResponse = .{ .permission = .deny_once },
        expected: Unanswered,
    };
    const cases = [_]Case{
        .{ .result = error.UiRequestTimedOut, .expected = error.PromptTimedOut },
        .{ .result = error.UiRequestCancelled, .expected = error.PromptCancelled },
        .{ .result = error.UiAnswerUnreadable, .expected = error.PromptAnswerUnreadable },
        .{ .result = .pending, .expected = error.PromptNobodyToAsk },
        .{ .result = .unavailable, .expected = error.PromptNobodyToAsk },
        .{ .result = error.HostUiFailed, .expected = error.PromptRequestFailed },
        .{ .result = .answered, .response = .{ .answers = &.{} }, .expected = error.PromptAnswerUnreadable },
    };
    // A loaded answer queue would grant if anything fell back to it.
    answer_queue.load("y\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\n");
    defer answer_queue.resetForTest();
    for (cases) |case| {
        var scripted = Scripted{ .result = case.result, .response = case.response };
        var ctx = PermissionContext{
            .allocator = testing.allocator,
            .no_interactive_prompt = true,
            .ui_requester = .{ .ctx = &scripted, .requestFn = Scripted.request },
        };
        ctx.setMode(.default);
        try testing.expectError(case.expected, ask(&ctx, "Write", "{\"file_path\":\"/x\"}"));
        try testing.expectError(case.expected, askForced(&ctx, "Write", "{\"file_path\":\"/x\"}"));
        try testing.expectEqual(@as(usize, 2), scripted.calls);
    }
    try testing.expectEqualStrings("y", answer_queue.pop().?);
    // The causes the Host reported deny at once even in a product context
    // (no `no_interactive_prompt`): the frontend was asked, so no terminal
    // prompt stands in for it. (A loaded queue is consulted before any
    // requester in a product context, so it is cleared here.)
    answer_queue.resetForTest();
    for (cases[0..3]) |case| {
        var scripted = Scripted{ .result = case.result };
        var ctx = PermissionContext{
            .allocator = testing.allocator,
            .ui_requester = .{ .ctx = &scripted, .requestFn = Scripted.request },
        };
        ctx.setMode(.default);
        try testing.expectError(case.expected, ask(&ctx, "Write", "{\"file_path\":\"/x\"}"));
    }

    // A person's deny stays a plain `false`.
    var denied = Scripted{};
    var ctx = PermissionContext{
        .allocator = testing.allocator,
        .no_interactive_prompt = true,
        .ui_requester = .{ .ctx = &denied, .requestFn = Scripted.request },
    };
    ctx.setMode(.default);
    try testing.expect(!try ask(&ctx, "Write", "{\"file_path\":\"/x\"}"));
}

const AllowAlwaysAnswer = struct {
    calls: usize = 0,

    fn request(
        raw: *anyopaque,
        _: ui_request.SessionId,
        _: std.mem.Allocator,
        _: *const ui_request.UiRequest,
        out: *ui_request.UiResponse,
    ) anyerror!ui_request.RequestOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        out.* = .{ .permission = .allow_always };
        return .answered;
    }
};

/// Answers "allow always" for `Bash` with `root` as both project root and
/// home, and reports whether either settings file appeared below `root`.
fn allowAlwaysWrites(scope: @import("../permission.zig").AlwaysAllowScope, root: []const u8) !bool {
    const testing = std.testing;
    var rules: @import("session_rules.zig").SessionRules = .{};
    var answer = AllowAlwaysAnswer{};
    var ctx = PermissionContext{
        .allocator = testing.allocator,
        .no_interactive_prompt = true,
        .session_rules = &rules,
        .always_allow = scope,
        .ui_requester = .{ .ctx = &answer, .requestFn = AllowAlwaysAnswer.request },
        .match_ctx = .{ .cwd = root, .project_root = root, .home = root },
    };
    ctx.setMode(.default);
    try testing.expect(try ask(&ctx, "Bash", "{\"command\":\"touch x\"}"));
    try testing.expectEqual(@as(usize, 1), answer.calls);
    try testing.expect(rules.isAllowed("Bash"));

    var local_buf: [std.fs.max_path_bytes]u8 = undefined;
    const local = try std.fmt.bufPrintZ(&local_buf, "{s}/.claude/settings.local.json", .{root});
    var user_buf: [std.fs.max_path_bytes]u8 = undefined;
    const user = try std.fmt.bufPrintZ(&user_buf, "{s}/.claude/settings.json", .{root});
    return pfs.exists(local.ptr) or pfs.exists(user.ptr);
}

test "allow_always: a Session-scoped context remembers the tool and writes no settings file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root_buf);
    try std.testing.expect(!try allowAlwaysWrites(.session, root_buf[0..len]));
}

test "allow_always: a settings_file context also writes the project settings file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root_buf);
    try std.testing.expect(try allowAlwaysWrites(.settings_file, root_buf[0..len]));
}
