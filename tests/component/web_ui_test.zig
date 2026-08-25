//! L2 组件测试:web UI 全链 —— HTTP/SSE 面驱动 agent_loop(MockServer 假模型)。
//!
//! DoD(声明=接线=测试):--web 声明的能力必须有跨模块端到端断言:
//!   ① CoreEvent 流:agent_loop → WebBackend.emit → journal → GET /events(SSE 帧带 id)
//!   ② UiRequest 往返:AskUserQuestion 工具 → journal ui_request → POST /respond 回填
//!      → 工具拿到答案 → 模型收到 tool_result → 继续到 end_turn
//! ②是关键:它证明"同步阻塞 requester"跨 HTTP 线程交接正确,且 ask_user 的
//! 非 tty gate 放行 ui_requester(接口分离修复)真实生效——测试进程无 tty。
//!
//! 结构对照 session.zig,但不构造 App(组件层直驱 agent_loop,对齐 tool_loop_breaker_test)。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;
const EventJournal = cc.web_journal.EventJournal;
const WebBackend = cc.web_backend.WebBackend;
const WebServer = cc.web_server.WebServer;
const MsgQueue = cc.repl_msg_queue.MsgQueue;

/// 单 turn 纯文本回复。
const TEXT_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":7,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello web\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// turn 1:调 AskUserQuestion(一问两选项)。input 经 input_json_delta 分片流式。
const ASK_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_a\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":7,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_ask\",\"name\":\"AskUserQuestion\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"questions\\\":[{\\\"question\\\":\\\"Favorite color?\\\",\\\"header\\\":\\\"Color\\\",\\\"options\\\":[{\\\"label\\\":\\\"Red\\\",\\\"description\\\":\\\"r\\\"},{\\\"label\\\":\\\"Blue\\\",\\\"description\\\":\\\"b\\\"}],\\\"multiSelect\\\":false}]}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":3}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// turn 2:收到 tool_result 后的收尾文本。
const DONE_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_b\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":9,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"you picked Red\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// 组件级 web 会话装置:journal + backend + inbox + server(无 App)。
const Fixture = struct {
    journal: EventJournal,
    wb: WebBackend,
    inbox: MsgQueue,
    sig: cc.util_abort.AbortSignal,
    srv: *WebServer = undefined,

    fn init(a: std.mem.Allocator) Fixture {
        return .{
            .journal = EventJournal.init(a),
            .wb = undefined, // 指向 journal,须在定址后接线(见 start)
            .inbox = MsgQueue.init(a),
            .sig = cc.util_abort.AbortSignal.init(),
        };
    }

    fn start(self: *Fixture, a: std.mem.Allocator) !void {
        self.wb = WebBackend.init(a, &self.journal);
        self.wb.abort = &self.sig;
        const S = struct {
            fn state(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
                return allocator.dupe(u8, "{}");
            }
        };
        self.srv = try WebServer.start(a, 0, .{
            .journal = &self.journal,
            .web_backend = &self.wb,
            .inbox = &self.inbox,
            .abort = &self.sig,
            .state_ctx = @ptrCast(self),
            .state_fn = &S.state,
        });
    }

    fn deinit(self: *Fixture) void {
        self.journal.close();
        self.srv.stop();
        self.wb.deinit();
        self.inbox.deinit();
        self.journal.deinit();
    }
};

test "L2 web ①: agent_loop 文本流经 WebBackend 落 journal,SSE 读回带 id 帧" {
    const a = std.testing.allocator;

    var srv = try harness.MockServer.startCassette(&[_][]const u8{TEXT_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "m", url);
    defer client.deinit();

    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const be = fx.wb.backend();
    const result = try agent_loop.run(&conv, client.provider(), &.{}, &perm, .{ .abort = &fx.sig }, &be, a);
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    // 经真 HTTP 从 /events 读回(重放语义:事件先发生,连接后至)
    const resp = try httpGetUntil(a, fx.srv.port, "/events", "stream_done");
    defer a.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "id: 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"text_chunk\":\"hello web\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "stream_begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "stream_done") != null);
}

test "L2 web ②: AskUserQuestion 经 HTTP /respond 回填 → 工具拿到答案 → end_turn(非 tty 放行 requester)" {
    const a = std.testing.allocator;

    var srv = try harness.MockServer.startCassette(&[_][]const u8{ ASK_SSE, DONE_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "m", url);
    defer client.deinit();

    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "ask me");

    // 模拟浏览器:HTTP 轮询 /events 等 ui_request 出现 → POST /respond 选 Red。
    const Browser = struct {
        fn run(port: u16, alloc: std.mem.Allocator) void {
            const events = httpGetUntil(alloc, port, "/events", "\"ui_request\"") catch return;
            defer alloc.free(events);
            // 从事件流抠 id(测试内恒 1;稳妥起见仍解析)
            const key = "{\"ui_request\":{\"id\":";
            const at = std.mem.indexOf(u8, events, key) orelse return;
            const rest = events[at + key.len ..];
            const end = std.mem.indexOfScalar(u8, rest, ',') orelse return;
            const id = std.fmt.parseInt(u64, rest[0..end], 10) catch return;
            var body_buf: [64]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf, "{{\"id\":{d},\"answers\":[\"Red\"]}}", .{id}) catch return;
            const resp = httpPost(alloc, port, "/respond", body) catch return;
            defer alloc.free(resp);
        }
    };
    const browser = try std.Thread.spawn(.{}, Browser.run, .{ fx.srv.port, a });
    defer browser.join();

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const be = fx.wb.backend();
    const result = try agent_loop.run(
        &conv,
        client.provider(),
        &.{},
        &perm,
        .{ .abort = &fx.sig, .ui_requester = fx.wb.requester() },
        &be,
        a,
    );
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 2), result.turns);

    // conversation 里 tool_result 应含选中的 Red(工具真拿到了浏览器的答案)
    var saw_red_result = false;
    for (conv.messages.items) |m| {
        if (m.role != .user) continue;
        for (m.blocks) |b| switch (b) {
            .tool_result => |tr| {
                if (std.mem.indexOf(u8, tr.content, "Red") != null) saw_red_result = true;
            },
            else => {},
        };
    }
    try std.testing.expect(saw_red_result);

    // journal 里有完整生命周期:ui_request → ui_request_done
    const all = (try fx.journal.waitSince(a, 0, 100)).?;
    defer {
        for (all) |l| a.free(l);
        a.free(all);
    }
    var saw_req = false;
    var saw_done = false;
    for (all) |l| {
        if (std.mem.indexOf(u8, l, "\"ui_request\"") != null) saw_req = true;
        if (std.mem.indexOf(u8, l, "\"ui_request_done\"") != null) saw_done = true;
    }
    try std.testing.expect(saw_req);
    try std.testing.expect(saw_done);
}

// Round 4 P?:CSRF — 跨域 POST(带 evil Origin)必须 403,且副作用未发生(消息不入队)。
test "L2 web: 跨域 POST 被 403 拒绝(CSRF 防线),同源/无 Origin 放行" {
    const a = std.testing.allocator;
    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a);

    // 恶意跨域:403,inbox 保持空
    {
        const resp = try roundtrip(a, fx.srv.port, "POST /message HTTP/1.1\r\nOrigin: http://evil.com\r\nContent-Length: 14\r\n\r\n{\"text\":\"pwn\"}", null);
        defer a.free(resp);
        try std.testing.expect(std.mem.indexOf(u8, resp, "403") != null);
    }
    try std.testing.expectEqual(@as(?[]u8, null), fx.inbox.popFront()); // 副作用未发生

    // 无 Origin(CLI):放行,消息入队
    {
        const resp = try roundtrip(a, fx.srv.port, "POST /message HTTP/1.1\r\nContent-Length: 14\r\n\r\n{\"text\":\"cli\"}", null);
        defer a.free(resp);
        try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    }
    const m = fx.inbox.popFront().?;
    defer a.free(m);
    try std.testing.expectEqualStrings("cli", m);
}

// 命令通道:POST /command → commandFn(只入队,不碰 App)+ extractStringKey。
// 并发安全设计:HTTP 线程仅 enqueue,driver 独占执行(见 session.zig execCommand)。
test "L2 web: /command 端点经 commandFn 入队 + extractStringKey" {
    const a = std.testing.allocator;
    // extractStringKey 纯函数
    const server = cc.web_server;
    const cmd = server.extractStringKey(a, "{\"cmd\":\"/mode\"}", "cmd").?;
    defer a.free(cmd);
    try std.testing.expectEqualStrings("/mode", cmd);
    try std.testing.expectEqual(@as(?[]u8, null), server.extractStringKey(a, "{\"other\":1}", "cmd"));

    // 端到端:mock commandFn 把命令 push 进一个队列(镜像 session 的 cmdbox 语义)。
    var j = EventJournal.init(a);
    defer j.deinit();
    var wb = WebBackend.init(a, &j);
    defer wb.deinit();
    var inbox = MsgQueue.init(a);
    defer inbox.deinit();
    var cmdbox = MsgQueue.init(a);
    defer cmdbox.deinit();
    var sig = cc.util_abort.AbortSignal.init();
    const S = struct {
        var box: *MsgQueue = undefined;
        fn state(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
            return allocator.dupe(u8, "{}");
        }
        fn command(_: *anyopaque, allocator: std.mem.Allocator, c: []const u8) anyerror![]u8 {
            _ = box.push(c);
            return std.json.Stringify.valueAlloc(allocator, .{ .ok = true, .message = "queued" }, .{});
        }
    };
    S.box = &cmdbox;
    var dummy: u8 = 0;
    const srv = try WebServer.start(a, 0, .{
        .journal = &j,
        .web_backend = &wb,
        .inbox = &inbox,
        .abort = &sig,
        .state_ctx = @ptrCast(&dummy),
        .state_fn = &S.state,
        .command_fn = &S.command,
    });
    defer srv.stop();
    defer j.close();

    const resp = try roundtrip(a, srv.port, "POST /command HTTP/1.1\r\nContent-Length: 15\r\n\r\n{\"cmd\":\"/mode\"}", null);
    defer a.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "queued") != null);
    // 命令真进了队列(HTTP 线程只入队,不执行)
    const queued = cmdbox.popFront().?;
    defer a.free(queued);
    try std.testing.expectEqualStrings("/mode", queued);
}

// 无 command_fn(单测默认)→ 501。
test "L2 web: /command 无 handler → 501" {
    const a = std.testing.allocator;
    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a); // Fixture 不接 command_fn
    const resp = try roundtrip(a, fx.srv.port, "POST /command HTTP/1.1\r\nContent-Length: 15\r\n\r\n{\"cmd\":\"/mode\"}", null);
    defer a.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "501") != null);
}

// ── Round 1 Linus review 回归测试 ──────────────────────────────────────────

// P2#5(声明=接线=测试):--web flag → Config.web_port。
test "L2 web: --web 解析(带端口/裸 flag 默认 7777/后跟别的 flag 不误吞)" {
    const a = std.testing.allocator;
    {
        const argv = [_][*:0]const u8{ "metacodes", "--web", "8080" };
        try std.testing.expectEqual(@as(?u16, 8080), cc.parseArgsForTest(&argv, a).web_port);
    }
    {
        const argv = [_][*:0]const u8{ "metacodes", "--web" };
        try std.testing.expectEqual(@as(?u16, 7777), cc.parseArgsForTest(&argv, a).web_port);
    }
    {
        // 裸 --web 后跟非数字 flag:不吞 --verbose,双双生效
        const argv = [_][*:0]const u8{ "metacodes", "--web", "--verbose" };
        const config = cc.parseArgsForTest(&argv, a);
        try std.testing.expectEqual(@as(?u16, 7777), config.web_port);
        try std.testing.expect(config.verbose);
    }
    {
        const argv = [_][*:0]const u8{"metacodes"};
        try std.testing.expectEqual(@as(?u16, null), cc.parseArgsForTest(&argv, a).web_port);
    }
}

test "U8: --resume-response 解析进 config.resume_response(内联 + @file)" {
    const a = std.testing.allocator;
    {
        // 内联 JSON 直接进 config。
        const argv = [_][*:0]const u8{ "metacodes", "--resume-response", "{\"choice\":\"Red\"}" };
        const cfg = cc.parseArgsForTest(&argv, a);
        defer if (cfg.resume_response) |r| a.free(r); // owned dupe,须释放(否则泄漏)
        try std.testing.expect(cfg.resume_response != null);
        try std.testing.expectEqualStrings("{\"choice\":\"Red\"}", cfg.resume_response.?);
    }
    {
        // @file:从文件读。写临时文件后解析。
        // 文件 IO 走 platform.fs + 路径走 paths.tempDir:std.c.open 的 `O` 在 Windows 是 void
        // (编不过),"/tmp" 在 Windows 不存在。所有测试模块现已接 platform dep(build.zig)。
        const ppaths = @import("platform").paths;
        const pfs = @import("platform").fs;
        var pbuf: [512]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&pbuf, "{s}/cc-zig-u8-resume-resp.json", .{ppaths.tempDir()});
        const fd = try pfs.openZ(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
        const content = "{\"answer\":42}";
        _ = pfs.write(fd, content);
        pfs.close(fd);
        defer _ = std.c.unlink(path.ptr);
        var argbuf: [600]u8 = undefined;
        const at_arg = try std.fmt.bufPrintZ(&argbuf, "@{s}", .{path});
        const argv = [_][*:0]const u8{ "metacodes", "--resume-response", at_arg.ptr };
        const cfg = cc.parseArgsForTest(&argv, a);
        defer if (cfg.resume_response) |r| a.free(r); // owned(readFileAll dupe),须释放
        try std.testing.expect(cfg.resume_response != null);
        try std.testing.expectEqualStrings(content, cfg.resume_response.?);
    }
    {
        // 无 flag → null(不启用 resume)。
        const argv = [_][*:0]const u8{"metacodes"};
        try std.testing.expectEqual(@as(?[]const u8, null), cc.parseArgsForTest(&argv, a).resume_response);
    }
}

// P0#1 回归:恶意 Content-Length(usize max,可 parse)不得溢出/panic,应 413。
test "L2 web: 巨型 Content-Length → 413(整数溢出回归)" {
    const a = std.testing.allocator;
    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a);
    const resp = try roundtrip(a, fx.srv.port, "POST /message HTTP/1.1\r\nContent-Length: 18446744073709551615\r\n\r\n", null);
    defer a.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "413") != null);
}

// P0#2 回归:/interrupt 只在 generating 时放行——空闲期不许打 abort(否则浏览器
// Stop 按钮会被 driver 的空闲循环当退出信号,击杀整个 daemon)。
test "L2 web: /interrupt 空闲期 409 不打 abort;生成期 200 打 abort" {
    const a = std.testing.allocator;
    var j = EventJournal.init(a);
    defer j.deinit();
    var wb = WebBackend.init(a, &j);
    defer wb.deinit();
    var inbox = MsgQueue.init(a);
    defer inbox.deinit();
    var sig = cc.util_abort.AbortSignal.init();
    var generating = std.atomic.Value(bool).init(false);
    const S = struct {
        fn state(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
            return allocator.dupe(u8, "{}");
        }
    };
    var dummy: u8 = 0;
    const srv = try WebServer.start(a, 0, .{
        .journal = &j,
        .web_backend = &wb,
        .inbox = &inbox,
        .abort = &sig,
        .generating = &generating,
        .state_ctx = @ptrCast(&dummy),
        .state_fn = &S.state,
    });
    defer srv.stop();
    defer j.close();

    { // 空闲:409,abort 未被打
        const resp = try roundtrip(a, srv.port, "POST /interrupt HTTP/1.1\r\nContent-Length: 0\r\n\r\n", null);
        defer a.free(resp);
        try std.testing.expect(std.mem.indexOf(u8, resp, "409") != null);
        try std.testing.expect(!sig.isAborted());
    }
    generating.store(true, .release);
    { // 生成期:200,abort 生效
        const resp = try roundtrip(a, srv.port, "POST /interrupt HTTP/1.1\r\nContent-Length: 0\r\n\r\n", null);
        defer a.free(resp);
        try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
        try std.testing.expect(sig.isAborted());
        // reason=user_interrupt(非 user_ctrl_c):driver 据此中断 run 不退出进程。
        try std.testing.expect(sig.reason() == .user_interrupt);
    }
}

test "L2 web:MAX_CONNS 连接上限——第 N+1 条被立即拒绝(close),存量连接不受影响" {
    const a = std.testing.allocator;
    const pnet = @import("platform").net;
    const MAX = cc.web_server.MAX_CONNS;

    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a);

    // 占满 MAX 条 idle 连接(不发请求,握手后挂着)。
    var held: [cc.web_server.MAX_CONNS]pnet.Socket = undefined;
    var opened: usize = 0;
    defer for (held[0..opened]) |s| pnet.closeSocket(s); // 关客户端侧 → handleConn 读到 EOF 退净
    while (opened < MAX) : (opened += 1) held[opened] = try pnet.connectLoopback(fx.srv.port);
    // 等 accept 线程消化完 backlog(connect 返回 ≠ 已 accept)。
    var waited: usize = 0;
    while (fx.srv.live_conns.load(.acquire) < MAX and waited < 5000) : (waited += 10) cc.util_time.sleepMs(10);
    try std.testing.expectEqual(MAX, fx.srv.live_conns.load(.acquire));

    // 第 MAX+1 条:server 应直接 close(recv 读到 EOF=0),且 live_conns 不增。
    const extra = try pnet.connectLoopback(fx.srv.port);
    defer pnet.closeSocket(extra);
    pnet.setRecvTimeoutMs(extra, 5000);
    var b: [16]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), pnet.recv(extra, &b));
    try std.testing.expectEqual(MAX, fx.srv.live_conns.load(.acquire));
}

// ── 极简 HTTP 客户端(raw socket;哑读到含 needle / EOF)───────────────────────

fn httpGetUntil(a: std.mem.Allocator, port: u16, path: []const u8, needle: []const u8) ![]u8 {
    var req_buf: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: l\r\n\r\n", .{path});
    return roundtrip(a, port, req, needle);
}

fn httpPost(a: std.mem.Allocator, port: u16, path: []const u8, body: []const u8) ![]u8 {
    var req_buf: [512]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "POST {s} HTTP/1.1\r\nHost: l\r\nContent-Length: {d}\r\n\r\n{s}", .{ path, body.len, body });
    return roundtrip(a, port, req, null);
}

fn roundtrip(a: std.mem.Allocator, port: u16, raw: []const u8, until: ?[]const u8) ![]u8 {
    // 收敛到 harness.clientRoundtrip(platform/net 双后端;裸 std.c socket 在 Windows 编不过)。
    return harness.clientRoundtrip(a, port, raw, until);
}
