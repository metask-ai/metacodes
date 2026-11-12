//! L2: per-message runtime configuration on web and daemon messages (#255).
//!
//! `POST /message` (and the UDS `message` op) may carry `model` and
//! `permission_mode`. The session's driver applies them right before the turn
//! that message starts; the journal shows `config_changed` for each given field,
//! then the turn's `user_message`, then the turn. The provider request carries
//! the new model, `/state` reports the new mode, and the login's saved model
//! selection (what `/model` writes) is left alone. A bad `permission_mode` is
//! refused with 400 before anything is queued; a model the provider cannot
//! serve applies neither field, runs no turn and journals `message_rejected`.
//!
//! A real App (temporary HOME, a MockServer provider) under both drivers: the
//! `--web` loop (`web_session.run`) and the daemon driver
//! (`daemon/app_driver.zig` behind a SessionHost, reached over HTTP and UDS).
//!
//! The same drivers write every journal line as wire v1 (#444,
//! doc/WIRE_PROTOCOL.md): a session's whole journal, through a Run with a
//! permission prompt, a command, a refused message and a Run a `/command`
//! planned, parses line by line as `{"v":1,"type":...}` of a known type, and
//! every line of a Run carries that Run's `run_id` (`expectWireJournal`); the
//! SSE stream and the UDS attachment carry exactly the journal's lines.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const pnet = @import("platform").net;
const pfs = @import("platform").fs;
const ppaths = @import("platform").paths;

const START_MODEL = "claude-sonnet-4-20250514";
const TURN_MODEL = "claude-opus-4-6";
/// Inferred as an OpenAI model: not available to this Anthropic session.
const FOREIGN_MODEL = "gpt-5.6-luna";

const TEXT_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":7,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done here\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const ASK_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_a\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":7,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_ask\",\"name\":\"AskUserQuestion\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"questions\\\":[{\\\"question\\\":\\\"Favorite color?\\\",\\\"header\\\":\\\"Color\\\",\\\"options\\\":[{\\\"label\\\":\\\"Red\\\",\\\"description\\\":\\\"r\\\"},{\\\"label\\\":\\\"Blue\\\",\\\"description\\\":\\\"b\\\"}],\\\"multiSelect\\\":false}]}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":3}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const EnvGuard = struct {
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(name: [*:0]const u8, value: ?[*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try std.testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
        return .{ .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            std.testing.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
        self.* = undefined;
    }
};

/// A real App over a temporary HOME/state root, talking to a MockServer.
/// Set up in place: the App keeps pointers to `arena` and `io_rt`.
const AppFixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    guards: [4]EnvGuard,
    guard_count: usize,
    mock: *harness.MockServer,
    app: *cc.app_module.App,

    fn setup(self: *AppFixture, responses: []const []const u8) !void {
        return self.setupWithSettings(responses, null);
    }

    /// `settings_json`, when given, is the session's `--settings` layer.
    fn setupWithSettings(self: *AppFixture, responses: []const []const u8, settings_json: ?[]const u8) !void {
        self.guard_count = 0;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer self.arena.deinit();
        const allocator = self.arena.allocator();

        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try allocator.dupe(u8, root_buf[0..try self.tmp.dir.realPath(std.testing.io, &root_buf)]);
        errdefer self.restoreGuards();
        try self.guard("HOME", (try allocator.dupeZ(u8, root)).ptr);
        try self.guard("METACODES_NO_PROBE", "1");
        try self.guard("METACODES_KG_AUTOSTART", "0");
        // The saved login lives at <state root>/auth.json, not wherever the developer points it.
        try self.guard("METACODES_AUTH_FILE", null);

        self.mock = try harness.MockServer.startCassette(responses, 0);
        errdefer self.mock.stop();
        const url_z = try allocator.dupeZ(u8, try self.mock.urlOwned(allocator));

        const argv = [_][*:0]const u8{ "metacodes", "--base-url", url_z.ptr, "--model", START_MODEL, "--permission", "default" };
        var config = cc.parseArgsForTest(&argv, allocator);
        try std.testing.expect(config.parse_error == null);
        config.state_root = root;
        config.long_horizon_arm = .codex_style; // no TinyKG service in a unit of this size
        if (settings_json) |bytes| {
            try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cli-settings.json", .data = bytes });
            config.settings_path = try std.fs.path.join(allocator, &.{ root, "cli-settings.json" });
        }

        self.io_rt = @import("platform").signal.threadedIo(allocator, .{});
        errdefer self.io_rt.deinit();
        self.app = try cc.app_module.App.init(allocator, self.io_rt.io(), config, "test-key");
    }

    fn guard(self: *AppFixture, name: [*:0]const u8, value: ?[*:0]const u8) !void {
        self.guards[self.guard_count] = try EnvGuard.set(name, value);
        self.guard_count += 1;
    }

    fn restoreGuards(self: *AppFixture) void {
        while (self.guard_count > 0) {
            self.guard_count -= 1;
            self.guards[self.guard_count].restore();
        }
    }

    fn deinit(self: *AppFixture) void {
        self.app.deinit();
        self.io_rt.deinit();
        self.mock.stop();
        self.restoreGuards();
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// Save a login whose selected model is `model`, as `/model` would.
    fn saveLoginModel(self: *AppFixture, model: []const u8) !void {
        const a = std.testing.allocator;
        var stored: cc.core_auth.StoredCredentials = .{ .selected_model = try a.dupe(u8, model) };
        defer stored.deinit(a);
        try cc.core_auth.saveDefault(a, self.app.stateRoot(), stored);
    }

    fn expectLoginModel(self: *AppFixture, model: []const u8) !void {
        const a = std.testing.allocator;
        var stored = try cc.core_auth.loadDefault(a, self.app.stateRoot());
        defer stored.deinit(a);
        try std.testing.expectEqualStrings(model, stored.selected_model orelse return error.TestExpectedSavedModel);
    }

    fn conversationHas(self: *AppFixture, text: []const u8) bool {
        for (self.app.conversation.messages.items) |m| {
            if (m.role != .user) continue;
            for (m.blocks) |b| switch (b) {
                .text => |t| if (std.mem.indexOf(u8, t, text) != null) return true,
                else => {},
            };
        }
        return false;
    }
};

// ── HTTP helpers ─────────────────────────────────────────────────────────────

fn request(a: std.mem.Allocator, port: u16, method: []const u8, path: []const u8, body: []const u8, until: ?[]const u8) ![]u8 {
    var buf: [1024]u8 = undefined;
    const raw = try std.fmt.bufPrint(&buf, "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ method, path, body.len, body });
    return roundtrip(a, port, raw, until);
}

/// Send `raw`, read until `until` appears (null: until the server closes),
/// for at most 10 s: each recv waits 500 ms and a timed-out one is retried, so
/// a reply that arrives only when the driver gets to the message is still read.
fn roundtrip(a: std.mem.Allocator, port: u16, raw: []const u8, until: ?[]const u8) ![]u8 {
    const deadline = cc.util_time.nowMs() + 10_000;
    const conn = pnet.connectLoopback(port) catch return error.ConnectFailed;
    defer pnet.closeSocket(conn);
    pnet.setRecvTimeoutMs(conn, 500);
    var pos: usize = 0;
    while (pos < raw.len) {
        const n = pnet.send(conn, raw[pos..]);
        if (n > 0) {
            pos += @intCast(n);
        } else if (n == 0 or !pnet.recvRetriable() or cc.util_time.nowMs() > deadline) {
            return error.WriteFailed;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var chunk: [4096]u8 = undefined;
    while (cc.util_time.nowMs() <= deadline) {
        const n = pnet.recv(conn, &chunk);
        if (n == 0) break;
        if (n < 0) {
            if (!pnet.recvRetriable()) break; // the 500 ms timeout: keep waiting
            continue;
        }
        try out.appendSlice(a, chunk[0..@intCast(n)]);
        if (until) |u| {
            if (std.mem.indexOf(u8, out.items, u) != null) break;
        }
    }
    return out.toOwnedSlice(a);
}

fn responseBody(resp: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return "";
    return resp[sep + 4 ..];
}

fn postMessage(a: std.mem.Allocator, port: u16, body: []const u8) ![]u8 {
    return request(a, port, "POST", "/message", body, null);
}

const State = struct {
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: *State) void {
        self.parsed.deinit();
    }
    fn field(self: *const State, key: []const u8) std.json.Value {
        return self.parsed.value.object.get(key) orelse .null;
    }
    fn int(self: *const State, key: []const u8) i64 {
        return switch (self.field(key)) {
            .integer => |i| i,
            else => -1,
        };
    }
    fn str(self: *const State, key: []const u8) []const u8 {
        return switch (self.field(key)) {
            .string => |s| s,
            else => "",
        };
    }
};

fn getState(a: std.mem.Allocator, port: u16) !State {
    const resp = try request(a, port, "GET", "/state", "", null);
    defer a.free(resp);
    if (std.mem.indexOf(u8, resp, "200 OK") == null) return error.TestStateUnavailable;
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, a, responseBody(resp), .{}) };
}

/// The SSE stream from the position `/state` reported, read until `until`.
fn eventsFrom(a: std.mem.Allocator, port: u16, from: *const State, until: []const u8) ![]u8 {
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/events?since={d}&epoch={s}", .{ from.int("seq"), from.str("epoch") });
    return request(a, port, "GET", path, "", until);
}

/// The `data:` payloads of an SSE body, in order (slices borrow `sse`).
fn dataLines(a: std.mem.Allocator, sse: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(a);
    var it = std.mem.splitScalar(u8, sse, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "data: ")) try out.append(a, line["data: ".len..]);
    }
    return out.toOwnedSlice(a);
}

fn find(lines: []const []const u8, needle: []const u8) ?usize {
    for (lines, 0..) |l, i| if (std.mem.indexOf(u8, l, needle) != null) return i;
    return null;
}

fn expectLine(lines: []const []const u8, needle: []const u8) !usize {
    return find(lines, needle) orelse {
        std.debug.print("no journal line contains {s}; lines:\n", .{needle});
        for (lines) |l| std.debug.print("  {s}\n", .{l});
        return error.TestExpectedJournalLine;
    };
}

fn countLines(lines: []const []const u8, needle: []const u8) usize {
    var n: usize = 0;
    for (lines) |l| {
        if (std.mem.indexOf(u8, l, needle) != null) n += 1;
    }
    return n;
}

/// The model field of provider request `index`, quotes included.
fn requestModel(mock: *harness.MockServer, index: usize) ![]const u8 {
    const captured = mock.requestAt(index) orelse return error.TestExpectedProviderRequest;
    return captured.jsonField("model") orelse error.TestExpectedModelField;
}

// ── the `--web` loop on its own thread ────────────────────────────────────────

const WebRun = struct {
    app: *cc.app_module.App,
    port: u16,
    thread: std.Thread = undefined,
    exit_code: u8 = 255,
    failure: ?anyerror = null,

    fn start(self: *WebRun) !void {
        self.thread = try std.Thread.spawn(.{}, main, .{self});
        // run() binds the port itself; wait until /state answers.
        var waited: usize = 0;
        while (waited < 10_000) : (waited += 20) {
            var st = getState(std.testing.allocator, self.port) catch {
                cc.util_time.sleepMs(20);
                continue;
            };
            st.deinit();
            return;
        }
        // Stop the loop before reporting: the caller tears the App down next,
        // and a run() still serving on it would read freed memory.
        self.app.abort.abort(.user_ctrl_c);
        self.thread.join();
        if (self.failure) |err| return err;
        return error.TestWebRunDidNotListen;
    }

    fn main(self: *WebRun) void {
        self.exit_code = cc.web_session.run(self.app, self.app.allocator, .{ .address = pnet.loopback(self.port), .version = "0.0.0-test" }) catch |err| {
            self.failure = err;
            return;
        };
    }

    /// The terminal's Ctrl+C: the idle loop exits and run() tears down.
    fn stop(self: *WebRun) !void {
        self.app.abort.abort(.user_ctrl_c);
        self.thread.join();
        if (self.failure) |err| return err;
        try std.testing.expectEqual(@as(u8, 0), self.exit_code);
    }
};

fn freePort() !u16 {
    const listener = try pnet.listenLoopback(0, 1);
    defer pnet.closeSocket(listener.sock);
    return listener.port;
}

/// One message with configuration, its order on the stream, the provider
/// request, /state afterwards and the saved login; then a bare message that
/// keeps it all. Shared by the `--web` and daemon drivers.
fn expectAppliedBeforeTurn(a: std.mem.Allocator, fx: *AppFixture, port: u16) !void {
    var before = try getState(a, port);
    defer before.deinit();
    try std.testing.expectEqualStrings(START_MODEL, before.str("model"));
    try std.testing.expectEqualStrings("default", before.str("permission_mode"));

    const requests_before = fx.mock.requestCount();
    const ack = try postMessage(a, port, "{\"text\":\"turn one\",\"model\":\"" ++ TURN_MODEL ++ "\",\"permission_mode\":\"accept-edits\"}");
    defer a.free(ack);
    try std.testing.expect(std.mem.indexOf(u8, ack, "200 OK") != null);

    const sse = try eventsFrom(a, port, &before, "\"run_done\"");
    defer a.free(sse);
    const lines = try dataLines(a, sse);
    defer a.free(lines);
    // config_changed for each given field, then the turn's user_message, then the turn.
    const user = try expectLine(lines, "{\"v\":1,\"type\":\"user_message\",\"data\":{\"run_id\":1,\"trace_id\":null,\"text\":\"turn one\",\"replaces\":null}}");
    const model_changed = try expectLine(lines, "{\"v\":1,\"type\":\"config_changed\",\"data\":{\"model\":\"" ++ TURN_MODEL ++ "\"}}");
    const mode_changed = try expectLine(lines, "{\"v\":1,\"type\":\"config_changed\",\"data\":{\"mode\":\"accept_edits\"}}");
    try std.testing.expectEqual(user, model_changed + 2);
    try std.testing.expectEqual(user, mode_changed + 1);
    try std.testing.expect(user < try expectLine(lines, "\"type\":\"text_chunk\""));
    try std.testing.expect(user < try expectLine(lines, "\"run_done\""));
    try std.testing.expectEqual(@as(usize, 2), countLines(lines, "\"type\":\"config_changed\""));

    // The turn ran on the message's model.
    try std.testing.expect(fx.mock.requestCount() > requests_before);
    try std.testing.expectEqualStrings("\"" ++ TURN_MODEL ++ "\"", try requestModel(fx.mock, requests_before));

    var after = try getState(a, port);
    defer after.deinit();
    try std.testing.expectEqualStrings("accept_edits", after.str("permission_mode"));
    try std.testing.expectEqualStrings(TURN_MODEL, after.str("model"));
    try std.testing.expect(after.int("seq") > before.int("seq"));

    // A per-message model is not the user's new default.
    try fx.expectLoginModel(START_MODEL);

    // Omitted fields keep what is in force: nothing is reset, nothing announced.
    const requests_bare = fx.mock.requestCount();
    const ack2 = try postMessage(a, port, "{\"text\":\"turn two\"}");
    defer a.free(ack2);
    try std.testing.expect(std.mem.indexOf(u8, ack2, "200 OK") != null);
    const sse2 = try eventsFrom(a, port, &after, "\"run_done\"");
    defer a.free(sse2);
    const lines2 = try dataLines(a, sse2);
    defer a.free(lines2);
    _ = try expectLine(lines2, "{\"v\":1,\"type\":\"user_message\",\"data\":{\"run_id\":2,\"trace_id\":null,\"text\":\"turn two\",\"replaces\":null}}");
    try std.testing.expectEqual(@as(usize, 0), countLines(lines2, "\"type\":\"config_changed\""));
    try std.testing.expectEqualStrings("\"" ++ TURN_MODEL ++ "\"", try requestModel(fx.mock, requests_bare));
    var after2 = try getState(a, port);
    defer after2.deinit();
    try std.testing.expectEqualStrings("accept_edits", after2.str("permission_mode"));
    try std.testing.expectEqualStrings(TURN_MODEL, after2.str("model"));
    try std.testing.expect(after2.int("seq") > after.int("seq"));

    // Fields that name what is already in force are still announced for the turn.
    const ack3 = try postMessage(a, port, "{\"text\":\"turn three\",\"model\":\"" ++ TURN_MODEL ++ "\",\"permission_mode\":\"acceptEdits\"}");
    defer a.free(ack3);
    try std.testing.expect(std.mem.indexOf(u8, ack3, "200 OK") != null);
    const sse3 = try eventsFrom(a, port, &after2, "\"run_done\"");
    defer a.free(sse3);
    const lines3 = try dataLines(a, sse3);
    defer a.free(lines3);
    const user3 = try expectLine(lines3, "{\"v\":1,\"type\":\"user_message\",\"data\":{\"run_id\":3,\"trace_id\":null,\"text\":\"turn three\",\"replaces\":null}}");
    try std.testing.expectEqual(user3, 2 + try expectLine(lines3, "{\"v\":1,\"type\":\"config_changed\",\"data\":{\"model\":\"" ++ TURN_MODEL ++ "\"}}"));
    try std.testing.expectEqual(user3, 1 + try expectLine(lines3, "{\"v\":1,\"type\":\"config_changed\",\"data\":{\"mode\":\"accept_edits\"}}"));
    try fx.expectLoginModel(START_MODEL);
}

test "L2 web: message model/permission_mode apply before the turn, in order, without saving the login model" {
    const a = std.testing.allocator;
    var fx: AppFixture = undefined;
    try fx.setup(&.{TEXT_SSE});
    defer fx.deinit();
    try fx.saveLoginModel(START_MODEL);

    var web = WebRun{ .app = fx.app, .port = try freePort() };
    try web.start();
    var stopped = false;
    defer if (!stopped) web.stop() catch {};

    try expectAppliedBeforeTurn(a, &fx, web.port);

    try web.stop();
    stopped = true;
    try std.testing.expect(fx.conversationHas("turn one"));
    try std.testing.expect(fx.conversationHas("turn two"));
    try std.testing.expect(fx.conversationHas("turn three"));
}

/// A stream frame carrying a business code this codebase has never heard of.
const BUSINESS_ERROR_SSE = "data: {\"type\":\"error\",\"error\":{\"type\":\"billing_error\",\"code\":\"insufficient_balance\",\"message\":\"Balance too low\"},\"request_id\":\"req-web-1\"}\n\n";

/// The completion notification of issue #408: a failed turn says why in the
/// journal line a frontend already reads, and the next turn's line is clean.
fn expectModelFailureOnRunDone(a: std.mem.Allocator, port: u16) !void {
    var before = try getState(a, port);
    defer before.deinit();
    const ack = try postMessage(a, port, "{\"text\":\"fails\"}");
    defer a.free(ack);
    const failed = try eventsFrom(a, port, &before, "\"run_done\"");
    defer a.free(failed);
    const failed_lines = try dataLines(a, failed);
    defer a.free(failed_lines);
    _ = try expectLine(failed_lines, "{\"v\":1,\"type\":\"run_done\",\"data\":{\"run_id\":1,\"trace_id\":null,\"stop_reason\":\"api_error\",\"error_name\":null,\"model_error\":{\"category\":\"unknown\",\"code\":\"insufficient_balance\",\"type\":\"billing_error\",\"message\":\"Balance too low\",\"http_status\":200,\"request_id\":\"req-web-1\",\"retry\":\"unknown\",\"retry_after_ms\":null,\"attempts\":1,\"truncated\":false}}}");

    var after = try getState(a, port);
    defer after.deinit();
    const ack2 = try postMessage(a, port, "{\"text\":\"succeeds\"}");
    defer a.free(ack2);
    const clean = try eventsFrom(a, port, &after, "\"run_done\"");
    defer a.free(clean);
    const clean_lines = try dataLines(a, clean);
    defer a.free(clean_lines);
    _ = try expectLine(clean_lines, "{\"v\":1,\"type\":\"run_done\",\"data\":{\"run_id\":2,\"trace_id\":null,\"stop_reason\":\"end_turn\",\"error_name\":null,\"model_error\":null}}");
}

test "L2 web: run_done carries the model failure's detail and a later success carries none (#408)" {
    const a = std.testing.allocator;
    var fx: AppFixture = undefined;
    try fx.setup(&.{ BUSINESS_ERROR_SSE, TEXT_SSE });
    defer fx.deinit();
    var web = WebRun{ .app = fx.app, .port = try freePort() };
    try web.start();
    var stopped = false;
    defer if (!stopped) web.stop() catch {};
    try expectModelFailureOnRunDone(a, web.port);
    try web.stop();
    stopped = true;
}

test "L2 web: a refused field queues nothing; an unusable model applies neither field and runs no turn" {
    const a = std.testing.allocator;
    var fx: AppFixture = undefined;
    try fx.setup(&.{TEXT_SSE});
    defer fx.deinit();
    try fx.saveLoginModel(START_MODEL);

    var web = WebRun{ .app = fx.app, .port = try freePort() };
    try web.start();
    var stopped = false;
    defer if (!stopped) web.stop() catch {};

    var before = try getState(a, web.port);
    defer before.deinit();

    // Refused at the transport: 400, nothing queued.
    for ([_][]const u8{
        "{\"text\":\"bad mode\",\"permission_mode\":\"plan\"}",
        "{\"text\":\"bad mode\",\"permission_mode\":\"\"}",
        "{\"text\":\"bad model\",\"model\":\"\"}",
        "{\"text\":\"bad model\",\"model\":7}",
        // Refused, not ignored: this host does not de-duplicate (#447).
        "{\"text\":\"bad key\",\"idempotency_key\":\"im:evt-0001\"}",
    }) |body| {
        const resp = try postMessage(a, web.port, body);
        defer a.free(resp);
        std.testing.expect(std.mem.indexOf(u8, resp, "400 Bad Request") != null) catch |err| {
            std.debug.print("expected 400 for {s}, got:\n{s}\n", .{ body, resp });
            return err;
        };
    }
    {
        const resp = try postMessage(a, web.port, "{\"text\":\"bad mode\",\"permission_mode\":\"plan\"}");
        defer a.free(resp);
        try std.testing.expect(std.mem.indexOf(u8, responseBody(resp), "invalid permission_mode") != null);
    }
    {
        const resp = try postMessage(a, web.port, "{\"text\":\"bad key\",\"idempotency_key\":\"im:evt-0001\"}");
        defer a.free(resp);
        try std.testing.expectEqualStrings("{\"error\":\"idempotency_key not supported: this host does not de-duplicate messages\"}", responseBody(resp));
    }

    // Accepted, but the model is not this provider's: neither field applies, no turn runs.
    const requests_before = fx.mock.requestCount();
    const ack = try postMessage(a, web.port, "{\"text\":\"turn three\",\"model\":\"" ++ FOREIGN_MODEL ++ "\",\"permission_mode\":\"bypassPermissions\"}");
    defer a.free(ack);
    try std.testing.expect(std.mem.indexOf(u8, ack, "200 OK") != null);
    const sse = try eventsFrom(a, web.port, &before, "\"message_rejected\"");
    defer a.free(sse);
    const lines = try dataLines(a, sse);
    defer a.free(lines);
    const rejected = lines[try expectLine(lines, "\"message_rejected\"")];
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"type\":\"message_rejected\",\"data\":{\"message\":\"model not available for current provider\",\"text\":\"turn three\",\"model\":\"" ++ FOREIGN_MODEL ++ "\",\"permission_mode\":\"bypass_permissions\"}}",
        rejected,
    );
    // FIFO: the refused bodies would have been taken before this one.
    try std.testing.expectEqual(@as(usize, 0), countLines(lines, "\"user_message\""));
    try std.testing.expectEqual(@as(usize, 0), countLines(lines, "\"type\":\"config_changed\""));
    try std.testing.expectEqual(@as(usize, 0), countLines(lines, "bad mode"));
    try std.testing.expectEqual(@as(usize, 0), countLines(lines, "bad model"));
    try std.testing.expectEqual(@as(usize, 0), countLines(lines, "bad key"));

    var after = try getState(a, web.port);
    defer after.deinit();
    try std.testing.expectEqualStrings("default", after.str("permission_mode"));
    try std.testing.expectEqualStrings(START_MODEL, after.str("model"));
    try std.testing.expect(!after.field("generating").bool);
    try std.testing.expectEqual(requests_before, fx.mock.requestCount());
    try fx.expectLoginModel(START_MODEL);

    try web.stop();
    stopped = true;
    try std.testing.expect(!fx.conversationHas("turn three"));
    try std.testing.expect(!fx.conversationHas("bad mode"));
    try std.testing.expect(!fx.conversationHas("bad model"));
    try std.testing.expect(!fx.conversationHas("bad key"));
}

test "L2 web: /state seq grows across a run; pending_request_id names the open question, then 0" {
    const a = std.testing.allocator;
    var fx: AppFixture = undefined;
    try fx.setup(&.{ ASK_SSE, TEXT_SSE });
    defer fx.deinit();

    var web = WebRun{ .app = fx.app, .port = try freePort() };
    try web.start();
    var stopped = false;
    defer if (!stopped) web.stop() catch {};

    var idle = try getState(a, web.port);
    defer idle.deinit();
    try std.testing.expectEqual(@as(i64, 0), idle.int("pending_request_id"));

    const ack = try postMessage(a, web.port, "{\"text\":\"ask me\",\"permission_mode\":\"bypassPermissions\"}");
    defer a.free(ack);
    try std.testing.expect(std.mem.indexOf(u8, ack, "200 OK") != null);

    const asked = try eventsFrom(a, web.port, &idle, "\"type\":\"ui_request\"");
    defer a.free(asked);
    const key = "\"type\":\"ui_request\",\"id\":";
    const at = std.mem.indexOf(u8, asked, key) orelse return error.TestExpectedUiRequest;
    const rest = asked[at + key.len ..];
    const id = try std.fmt.parseInt(i64, rest[0 .. std.mem.indexOfScalar(u8, rest, ',') orelse return error.TestExpectedUiRequest], 10);
    try std.testing.expect(id > 0);

    var pending = try getState(a, web.port);
    defer pending.deinit();
    try std.testing.expectEqual(id, pending.int("pending_request_id"));
    try std.testing.expect(pending.field("generating").bool);
    try std.testing.expectEqualStrings("bypass_permissions", pending.str("permission_mode"));
    try std.testing.expect(pending.int("seq") > idle.int("seq"));

    var answer_buf: [64]u8 = undefined;
    const answer = try std.fmt.bufPrint(&answer_buf, "{{\"id\":{d},\"answers\":[\"Red\"]}}", .{id});
    const resp = try request(a, web.port, "POST", "/respond", answer, null);
    defer a.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);

    const finished = try eventsFrom(a, web.port, &pending, "\"run_done\"");
    defer a.free(finished);
    var done = try getState(a, web.port);
    defer done.deinit();
    try std.testing.expectEqual(@as(i64, 0), done.int("pending_request_id"));
    try std.testing.expect(done.int("seq") > pending.int("seq"));
    try std.testing.expectEqualStrings(idle.str("epoch"), done.str("epoch"));

    try web.stop();
    stopped = true;
}

// ── modes the settings disable (disableBypassPermissionsMode, disableAutoMode) ─

fn postCommand(a: std.mem.Allocator, port: u16, cmd: []const u8) !void {
    var body_buf: [128]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "{{\"cmd\":\"{s}\"}}", .{cmd});
    const resp = try request(a, port, "POST", "/command", body, null);
    defer a.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
}

/// The `command_result` line for `cmd`, posted after `from` (caller frees). A
/// refused command must not have announced a change on the way.
fn commandResult(a: std.mem.Allocator, port: u16, cmd: []const u8, from: *const State) ![]u8 {
    try postCommand(a, port, cmd);
    const sse = try eventsFrom(a, port, from, "\"command_result\"");
    defer a.free(sse);
    const lines = try dataLines(a, sse);
    defer a.free(lines);
    const result = lines[try expectLine(lines, "\"command_result\"")];
    if (std.mem.indexOf(u8, result, "\"ok\":false") != null)
        try std.testing.expectEqual(@as(usize, 0), countLines(lines, "\"type\":\"config_changed\""));
    return a.dupe(u8, result);
}

const ESCALATE = "{\"text\":\"escalate\",\"model\":\"" ++ TURN_MODEL ++ "\",\"permission_mode\":\"bypassPermissions\"}";

test "L2 web: a mode the settings disable is refused on a message and by /mode, and nothing else applies" {
    const a = std.testing.allocator;
    var fx: AppFixture = undefined;
    try fx.setupWithSettings(&.{TEXT_SSE}, "{\"permissions\":{\"disableBypassPermissionsMode\":true}}");
    defer fx.deinit();
    try fx.saveLoginModel(START_MODEL);

    var web = WebRun{ .app = fx.app, .port = try freePort() };
    try web.start();
    var stopped = false;
    defer if (!stopped) web.stop() catch {};

    var before = try getState(a, web.port);
    defer before.deinit();
    const requests_before = fx.mock.requestCount();

    // The message also names a valid model: it must not be switched either.
    const ack = try postMessage(a, web.port, ESCALATE);
    defer a.free(ack);
    try std.testing.expect(std.mem.indexOf(u8, ack, "200 OK") != null);
    const sse = try eventsFrom(a, web.port, &before, "\"message_rejected\"");
    defer a.free(sse);
    const lines = try dataLines(a, sse);
    defer a.free(lines);
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"type\":\"message_rejected\",\"data\":{\"message\":\"bypassPermissions is disabled by settings\",\"text\":\"escalate\",\"model\":\"" ++ TURN_MODEL ++ "\",\"permission_mode\":\"bypass_permissions\"}}",
        lines[try expectLine(lines, "\"message_rejected\"")],
    );
    try std.testing.expectEqual(@as(usize, 0), countLines(lines, "\"user_message\""));
    try std.testing.expectEqual(@as(usize, 0), countLines(lines, "\"type\":\"config_changed\""));

    var after_message = try getState(a, web.port);
    defer after_message.deinit();
    try std.testing.expectEqualStrings("default", after_message.str("permission_mode"));
    try std.testing.expectEqualStrings(START_MODEL, after_message.str("model"));

    // `/mode` goes through the same check (SessionService.setPermMode), on every surface.
    for ([_][]const u8{ "/mode bypass", "/mode bypassPermissions", "/mode bypass-permissions" }) |cmd| {
        var from = try getState(a, web.port);
        defer from.deinit();
        const result = try commandResult(a, web.port, cmd, &from);
        defer a.free(result);
        try std.testing.expectEqualStrings("{\"v\":1,\"type\":\"command_result\",\"data\":{\"command\":\"mode\",\"ok\":false,\"error_name\":\"CommandRefused\",\"message\":\"bypassPermissions is disabled by settings\"}}", result);
        var after = try getState(a, web.port);
        defer after.deinit();
        try std.testing.expectEqualStrings("default", after.str("permission_mode"));
    }

    try std.testing.expectEqual(requests_before, fx.mock.requestCount());
    try fx.expectLoginModel(START_MODEL);
    try web.stop();
    stopped = true;
    try std.testing.expect(!fx.conversationHas("escalate"));
    try std.testing.expectEqual(cc.types_mod.PermissionMode.default, fx.app.permMode());
}

test "L2 web: without that setting the same message and /mode apply; disableAutoMode refuses auto" {
    const a = std.testing.allocator;
    var fx: AppFixture = undefined;
    try fx.setupWithSettings(&.{TEXT_SSE}, "{\"permissions\":{\"disableAutoMode\":true}}");
    defer fx.deinit();
    try fx.saveLoginModel(START_MODEL);

    var web = WebRun{ .app = fx.app, .port = try freePort() };
    try web.start();
    var stopped = false;
    defer if (!stopped) web.stop() catch {};

    var before = try getState(a, web.port);
    defer before.deinit();
    const requests_before = fx.mock.requestCount();
    const ack = try postMessage(a, web.port, ESCALATE);
    defer a.free(ack);
    try std.testing.expect(std.mem.indexOf(u8, ack, "200 OK") != null);
    const sse = try eventsFrom(a, web.port, &before, "\"run_done\"");
    defer a.free(sse);
    const lines = try dataLines(a, sse);
    defer a.free(lines);
    const user = try expectLine(lines, "{\"v\":1,\"type\":\"user_message\",\"data\":{\"run_id\":1,\"trace_id\":null,\"text\":\"escalate\",\"replaces\":null}}");
    try std.testing.expectEqual(user, 2 + try expectLine(lines, "{\"v\":1,\"type\":\"config_changed\",\"data\":{\"model\":\"" ++ TURN_MODEL ++ "\"}}"));
    try std.testing.expectEqual(user, 1 + try expectLine(lines, "{\"v\":1,\"type\":\"config_changed\",\"data\":{\"mode\":\"bypass_permissions\"}}"));
    try std.testing.expectEqual(@as(usize, 0), countLines(lines, "\"message_rejected\""));
    try std.testing.expectEqualStrings("\"" ++ TURN_MODEL ++ "\"", try requestModel(fx.mock, requests_before));

    var applied = try getState(a, web.port);
    defer applied.deinit();
    try std.testing.expectEqualStrings("bypass_permissions", applied.str("permission_mode"));
    try std.testing.expectEqualStrings(TURN_MODEL, applied.str("model"));

    // disableAutoMode refuses auto, and only auto.
    {
        const result = try commandResult(a, web.port, "/mode auto", &applied);
        defer a.free(result);
        try std.testing.expectEqualStrings("{\"v\":1,\"type\":\"command_result\",\"data\":{\"command\":\"mode\",\"ok\":false,\"error_name\":\"CommandRefused\",\"message\":\"auto mode is disabled by settings\"}}", result);
        var after = try getState(a, web.port);
        defer after.deinit();
        try std.testing.expectEqualStrings("bypass_permissions", after.str("permission_mode"));
    }
    {
        var from = try getState(a, web.port);
        defer from.deinit();
        const result = try commandResult(a, web.port, "/mode default", &from);
        defer a.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "\"ok\":true") != null);
    }
    {
        var from = try getState(a, web.port);
        defer from.deinit();
        const result = try commandResult(a, web.port, "/mode bypass", &from);
        defer a.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "\"ok\":true") != null);
        var after = try getState(a, web.port);
        defer after.deinit();
        try std.testing.expectEqualStrings("bypass_permissions", after.str("permission_mode"));
    }

    try web.stop();
    stopped = true;
}

// ── the daemon driver: SessionHost + app_driver, over HTTP and UDS ───────────

const SessionHost = cc.daemon_registry.SessionHost;

/// `metacodes serve`'s single-session wiring (daemon/serve.zig), in place.
const DaemonHost = struct {
    host: *SessionHost,
    wb: cc.web_backend.WebBackend,
    dctx: cc.daemon_app_driver.DriverCtx,
    config_sink: cc.web_session.WebConfigSink,
    state_src: cc.web_session.StateSource,
    srv: *cc.web_server.WebServer,

    fn start(self: *DaemonHost, app: *cc.app_module.App) !void {
        const a = std.testing.allocator;
        self.host = try SessionHost.create(a, app.session_id, @ptrCast(&self.dctx), cc.daemon_app_driver.driverFn, null, cc.daemon_app_driver.abortFn);
        errdefer self.host.destroy();
        self.wb = cc.web_backend.WebBackend.init(a, &self.host.journal);
        errdefer self.wb.deinit();
        self.wb.abort = &app.abort;
        self.wb.usage_totals = &app.usage;
        self.dctx = .{ .app = app, .wb = &self.wb };
        self.config_sink = .{ .wb = &self.wb };
        app.setConfigEventSink(self.config_sink.sink());
        errdefer app.setConfigEventSink(null);
        app.permission_ctx.ui_requester = self.wb.requester();
        errdefer app.permission_ctx.ui_requester = null;
        self.state_src = .{ .app = app, .wb = &self.wb, .cmdbox = &self.host.cmdbox, .journal = &self.host.journal, .generating = &self.host.generating };
        self.srv = try cc.web_server.WebServer.start(a, .{ .version = "0.0.0-test" }, .{
            .journal = &self.host.journal,
            .web_backend = &self.wb,
            .inbox = &self.host.inbox,
            .abort = &app.abort,
            .generating = &self.host.generating,
            .state_ctx = @ptrCast(&self.state_src),
            .state_fn = &cc.web_session.StateSource.snapshot,
            .command_fn = &cc.web_session.StateSource.command,
        });
        errdefer {
            self.host.journal.close();
            self.srv.stop();
        }
        // serve.zig's first journal line (seq 0).
        cc.web_session.journalSessionLifecycle(&self.host.journal, a, .{ .created = app.session_id.asSlice() });
        // The driver starts last, so no failure above leaves it running over a freed wb.
        try self.host.start();
    }

    /// serve.zig's shutdown order: transport first, then the driver, then wb.
    fn stop(self: *DaemonHost) void {
        const app = self.dctx.app;
        self.host.journal.close();
        self.srv.stop();
        self.host.destroy();
        app.setConfigEventSink(null);
        app.permission_ctx.ui_requester = null;
        self.wb.deinit();
    }

    fn resolve(ctx: *anyopaque, id: []const u8) ?cc.web_server.Lease {
        const self: *DaemonHost = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, id, self.dctx.app.session_id.asSlice())) return null;
        return .{
            .view = .{
                .journal = &self.host.journal,
                .web_backend = &self.wb,
                .inbox = &self.host.inbox,
                .abort = &self.dctx.app.abort,
                .generating = &self.host.generating,
                .state_ctx = @ptrCast(&self.state_src),
                .state_fn = &cc.web_session.StateSource.snapshot,
            },
            .ctx = ctx,
            .release_fn = &release,
        };
    }

    /// The one session outlives every transport here (`stop` stops them
    /// first), so a lease has nothing to give back (#254).
    fn release(_: *anyopaque) void {}

    /// The journal's lines since `from`, waiting (bounded) for `needle`.
    fn linesUntil(self: *DaemonHost, a: std.mem.Allocator, from: usize, needle: []const u8) ![][]u8 {
        const deadline = cc.util_time.nowMs() + 10_000;
        while (cc.util_time.nowMs() <= deadline) {
            // Returns at once while lines exist since `from`, so poll rather than spin.
            if (try self.host.journal.waitSince(a, from, 20)) |lines| {
                for (lines) |l| if (std.mem.indexOf(u8, l, needle) != null) return lines;
                freeLines(a, lines);
                cc.util_time.sleepMs(10);
            }
        }
        return error.TestTimedOutWaitingForJournal;
    }
};

fn freeLines(a: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |l| a.free(l);
    a.free(lines);
}

test "L2 serve: the daemon driver applies message configuration the same way (HTTP)" {
    const a = std.testing.allocator;
    var fx: AppFixture = undefined;
    try fx.setup(&.{TEXT_SSE});
    defer fx.deinit();
    try fx.saveLoginModel(START_MODEL);

    var daemon: DaemonHost = undefined;
    try daemon.start(fx.app);
    defer daemon.stop();

    try expectAppliedBeforeTurn(a, &fx, daemon.srv.port);
}

test "L2 serve: the daemon driver's run_done carries the model failure's detail too (#408)" {
    const a = std.testing.allocator;
    var fx: AppFixture = undefined;
    try fx.setup(&.{ BUSINESS_ERROR_SSE, TEXT_SSE });
    defer fx.deinit();
    var daemon: DaemonHost = undefined;
    try daemon.start(fx.app);
    defer daemon.stop();
    try expectModelFailureOnRunDone(a, daemon.srv.port);
}

test "L2 serve: the UDS message op carries the same fields, checks and order" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // UDS is POSIX-only
    const a = std.testing.allocator;
    var fx: AppFixture = undefined;
    try fx.setup(&.{TEXT_SSE});
    defer fx.deinit();
    try fx.saveLoginModel(START_MODEL);

    var daemon: DaemonHost = undefined;
    try daemon.start(fx.app);
    defer daemon.stop();

    var nonce: [6]u8 = undefined;
    if (!@import("platform").rng.randomBytes(&nonce)) return error.TestNoRandomness;
    var path_buf: [256]u8 = undefined;
    const sock_path = try std.fmt.bufPrint(&path_buf, "{s}/mc-msgcfg-{s}.sock", .{ std.mem.trimEnd(u8, ppaths.tempDir(), "/"), &std.fmt.bytesToHex(nonce, .lower) });
    const uds = try cc.daemon_uds.UdsServer.start(a, sock_path, .{
        .allocator = a,
        .resolver = &DaemonHost.resolve,
        .resolver_ctx = @ptrCast(&daemon),
    });
    defer uds.stop();

    const conn = try pnet.connectUnix(sock_path);
    defer pnet.closeSocket(conn);
    pnet.setRecvTimeoutMs(conn, 500);

    const sid = fx.app.session_id.asSlice();
    var line_buf: [512]u8 = undefined;

    // Refused before anything is queued.
    {
        const line = try std.fmt.bufPrint(&line_buf, "{{\"op\":\"message\",\"session\":\"{s}\",\"text\":\"bad\",\"permission_mode\":\"plan\"}}\n", .{sid});
        const reply = try udsRoundtrip(a, conn, line);
        defer a.free(reply);
        try std.testing.expect(std.mem.startsWith(u8, reply, "{\"ok\":false,\"error\":\"invalid permission_mode"));
        try std.testing.expectEqual(@as(usize, 0), daemon.host.inbox.len());
    }

    const from = daemon.host.journal.count();
    const requests_before = fx.mock.requestCount();
    {
        const line = try std.fmt.bufPrint(&line_buf, "{{\"op\":\"message\",\"session\":\"{s}\",\"text\":\"over uds\",\"model\":\"{s}\",\"permission_mode\":\"dontAsk\"}}\n", .{ sid, TURN_MODEL });
        const reply = try udsRoundtrip(a, conn, line);
        defer a.free(reply);
        try std.testing.expectEqualStrings("{\"ok\":true}", reply);
    }
    const lines = try daemon.linesUntil(a, from, "\"run_done\"");
    defer freeLines(a, lines);
    const user = try expectLine(lines, "{\"v\":1,\"type\":\"user_message\",\"data\":{\"run_id\":1,\"trace_id\":null,\"text\":\"over uds\",\"replaces\":null}}");
    try std.testing.expectEqual(user, 2 + try expectLine(lines, "{\"v\":1,\"type\":\"config_changed\",\"data\":{\"model\":\"" ++ TURN_MODEL ++ "\"}}"));
    try std.testing.expectEqual(user, 1 + try expectLine(lines, "{\"v\":1,\"type\":\"config_changed\",\"data\":{\"mode\":\"dont_ask\"}}"));
    try std.testing.expect(user < try expectLine(lines, "\"run_done\""));
    try std.testing.expectEqual(@as(usize, 0), countLines(lines, "\"bad\""));
    try std.testing.expectEqualStrings("\"" ++ TURN_MODEL ++ "\"", try requestModel(fx.mock, requests_before));
    try std.testing.expectEqual(cc.types_mod.PermissionMode.dont_ask, fx.app.permMode());
    try fx.expectLoginModel(START_MODEL);
}

/// Send one NDJSON request line and read one reply line (without the newline).
/// A timed-out recv is retried for up to 10 s (see `roundtrip`).
fn udsRoundtrip(a: std.mem.Allocator, conn: pnet.Socket, line: []const u8) ![]u8 {
    const deadline = cc.util_time.nowMs() + 10_000;
    var off: usize = 0;
    while (off < line.len) {
        const n = pnet.send(conn, line[off..]);
        if (n > 0) {
            off += @intCast(n);
        } else if (n == 0 or !pnet.recvRetriable() or cc.util_time.nowMs() > deadline) {
            return error.WriteFailed;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var chunk: [512]u8 = undefined;
    while (std.mem.indexOfScalar(u8, out.items, '\n') == null) {
        if (cc.util_time.nowMs() > deadline) return error.TestUdsReplyMissing;
        const n = pnet.recv(conn, &chunk);
        if (n == 0) return error.TestUdsReplyMissing;
        if (n < 0) {
            if (!pnet.recvRetriable()) return error.TestUdsReplyMissing;
            continue;
        }
        try out.appendSlice(a, chunk[0..@intCast(n)]);
    }
    const nl = std.mem.indexOfScalar(u8, out.items, '\n').?;
    out.shrinkRetainingCapacity(nl);
    return out.toOwnedSlice(a);
}

// ── every journal line is wire v1; a Run's lines carry its run_id (#444) ─────

/// How a journal line's `type` stands in the wire grammar.
const LineClass = enum { core, host, other };

fn classOf(type_name: []const u8) LineClass {
    inline for (std.meta.fields(cc.ui_event.CoreEvent)) |field| {
        if (std.mem.eql(u8, field.name, type_name)) return .core;
    }
    inline for (std.meta.fields(cc.wire.HostEvent)) |field| {
        if (std.mem.eql(u8, field.name, type_name)) return .host;
    }
    return .other;
}

/// A web/serve journal, in order, against wire v1: each line is one JSON
/// object with `v` 1 and a `type` of the grammar (`wire.isLineType`). A Run's
/// lines - its `user_message`, the kernel events journaled while it runs, its
/// `run_done` - carry its `run_id`, numbered 1, 2, … in order; no other line
/// carries one and no other host line falls inside a Run. These hosts take no
/// trace ID, so no line has one. Returns how many Runs the journal holds.
fn checkWireJournal(a: std.mem.Allocator, lines: []const []const u8, bad_line: *usize) !u64 {
    var open: ?u64 = null;
    var runs: u64 = 0;
    for (lines, 0..) |line, index| {
        bad_line.* = index;
        try checkWireLine(a, line, &open, &runs);
    }
    bad_line.* = lines.len;
    if (open != null) return error.TestRunNeverEnded;
    return runs;
}

/// `checkWireJournal`, naming the line that breaks it.
fn expectWireJournal(a: std.mem.Allocator, lines: []const []const u8) !u64 {
    var bad_line: usize = 0;
    return checkWireJournal(a, lines, &bad_line) catch |err| {
        if (bad_line < lines.len) {
            std.debug.print("journal line {d} is not wire v1 ({s}): {s}\n", .{ bad_line, @errorName(err), lines[bad_line] });
        } else std.debug.print("journal ends inside a Run ({s})\n", .{@errorName(err)});
        return err;
    };
}

fn checkWireLine(a: std.mem.Allocator, line: []const u8, open: *?u64, runs: *u64) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch return error.TestLineNotJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.TestLineNotObject;
    const object = parsed.value.object;
    const version = object.get("v") orelse return error.TestUnversionedLine;
    if (version != .integer or version.integer != cc.wire.SCHEMA_VERSION) return error.TestWrongVersion;
    const type_value = object.get("type") orelse return error.TestLineWithoutType;
    if (type_value != .string or !cc.wire.isLineType(type_value.string)) return error.TestUnknownLineType;
    const type_name = type_value.string;
    if (object.get("trace_id") != null) return error.TestTraceIdWithoutOne;
    switch (classOf(type_name)) {
        .core => if (object.get("run_id")) |value| {
            try enterRun(open, runs, try runIdOf(value));
        } else if (open.* != null) return error.TestRunEventWithoutRunId,
        .host => {
            const data = object.get("data") orelse return error.TestHostLineWithoutData;
            if (data != .object) return error.TestHostLineWithoutData;
            const run_line = std.mem.eql(u8, type_name, "user_message") or std.mem.eql(u8, type_name, "run_done");
            if (!run_line) {
                if (open.* != null) return error.TestHostLineInsideRun;
                return;
            }
            const trace = data.object.get("trace_id") orelse return error.TestHostLineWithoutTraceId;
            if (trace != .null) return error.TestTraceIdWithoutOne;
            try enterRun(open, runs, try runIdOf(data.object.get("run_id") orelse return error.TestHostLineWithoutRunId));
            if (std.mem.eql(u8, type_name, "run_done")) open.* = null;
        },
        // UI request and capability lines belong to no Run.
        .other => if (object.get("run_id") != null) return error.TestRunIdOnRequestLine,
    }
}

/// A line of Run `run_id`: the Run in progress, or the next one, which it
/// opens (a Run a macro started has no `user_message`).
fn enterRun(open: *?u64, runs: *u64, run_id: u64) !void {
    if (open.*) |current| {
        if (run_id != current) return error.TestLineOfAnotherRun;
        return;
    }
    if (run_id != runs.* + 1) return error.TestRunIdOutOfOrder;
    runs.* = run_id;
    open.* = run_id;
}

fn runIdOf(value: std.json.Value) !u64 {
    if (value != .integer or value.integer < 1) return error.TestBadRunId;
    return @intCast(value.integer);
}

test "#444 the journal check refuses an unversioned line, an unknown type and a Run line without its run_id" {
    const a = std.testing.allocator;
    var bad: usize = 0;
    const user1 = "{\"v\":1,\"type\":\"user_message\",\"data\":{\"run_id\":1,\"trace_id\":null,\"text\":\"hi\",\"replaces\":null}}";
    const done1 = "{\"v\":1,\"type\":\"run_done\",\"data\":{\"run_id\":1,\"trace_id\":null,\"stop_reason\":\"end_turn\",\"error_name\":null,\"model_error\":null}}";
    // What the web/serve host wrote before #444.
    try std.testing.expectError(error.TestUnversionedLine, checkWireJournal(a, &.{"{\"user_message\":\"hi\"}"}, &bad));
    try std.testing.expectError(error.TestUnversionedLine, checkWireJournal(a, &.{"{\"session_lifecycle\":{\"created\":\"x\"}}"}, &bad));
    try std.testing.expectError(error.TestUnknownLineType, checkWireJournal(a, &.{"{\"v\":1,\"type\":\"keepalive\"}"}, &bad));
    try std.testing.expectError(error.TestRunEventWithoutRunId, checkWireJournal(a, &.{ user1, "{\"v\":1,\"type\":\"text_chunk\",\"data\":\"x\"}", done1 }, &bad));
    try std.testing.expectError(error.TestHostLineInsideRun, checkWireJournal(a, &.{ user1, "{\"v\":1,\"type\":\"command_result\",\"data\":{\"command\":\"mode\",\"ok\":true,\"error_name\":null,\"message\":null}}", done1 }, &bad));
    try std.testing.expectError(error.TestRunNeverEnded, checkWireJournal(a, &.{user1}, &bad));
    try std.testing.expectError(error.TestRunIdOutOfOrder, checkWireJournal(a, &.{"{\"v\":1,\"type\":\"text_chunk\",\"run_id\":2,\"data\":\"x\"}"}, &bad));
    try std.testing.expectEqual(@as(u64, 1), try checkWireJournal(a, &.{ "{\"v\":1,\"type\":\"stream_done\",\"data\":null}", user1, "{\"v\":1,\"type\":\"text_chunk\",\"run_id\":1,\"data\":\"x\"}", done1 }, &bad));
}

/// A provider turn that calls Write on `path`; in `default` mode its
/// permission prompt goes to the frontend (caller frees).
fn writeToolSse(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_w\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_w\",\"name\":\"Write\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\",\\\"content\\\":\\\"wire\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{path});
}

/// Where the granted Write lands: a fresh file under the system temporary
/// directory, outside the repository (forward slashes, so it sits in JSON as
/// is). Caller frees.
fn wireWritePath(a: std.mem.Allocator) ![:0]u8 {
    var nonce: [6]u8 = undefined;
    if (!@import("platform").rng.randomBytes(&nonce)) return error.TestNoRandomness;
    const path = try std.fmt.allocPrintSentinel(a, "{s}/mc-wire-{s}.txt", .{ std.mem.trimEnd(u8, ppaths.tempDir(), "/\\"), &std.fmt.bytesToHex(nonce, .lower) }, 0);
    for (path) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return path;
}

/// The SSE stream from seq 0 of the journal `epoch` names, read until `until`.
fn eventsFromStart(a: std.mem.Allocator, port: u16, epoch: []const u8, until: []const u8) ![]u8 {
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/events?since=0&epoch={s}", .{epoch});
    return request(a, port, "GET", path, "", until);
}

/// The id of the newest `ui_request` of `kind` in an SSE body.
fn requestIdIn(sse: []const u8, kind: []const u8) !u64 {
    const key = "\"type\":\"ui_request\",\"id\":";
    var id: ?u64 = null;
    var rest = sse;
    while (std.mem.indexOf(u8, rest, key)) |at| {
        rest = rest[at + key.len ..];
        const comma = std.mem.indexOfScalar(u8, rest, ',') orelse break;
        const after = rest[comma..];
        var kind_buf: [48]u8 = undefined;
        if (std.mem.startsWith(u8, after, try std.fmt.bufPrint(&kind_buf, ",\"kind\":\"{s}\"", .{kind})))
            id = try std.fmt.parseInt(u64, rest[0..comma], 10);
    }
    return id orelse error.TestExpectedUiRequest;
}

/// The scenario's last line. Read to its end: the SSE read stops at the first
/// match, and every line it returns must be whole.
const RUN2_DONE = "{\"v\":1,\"type\":\"run_done\",\"data\":{\"run_id\":2,\"trace_id\":null,\"stop_reason\":\"end_turn\",\"error_name\":null,\"model_error\":null}}";

/// One session's journal over the HTTP surface, shared by both drivers:
///   Run 1: a message whose Write asks permission; the test, as the browser,
///          answers it `allow_once`, the file is written, the turn ends;
///   between Runs: `/mode dont-ask` (its command_result and config_changed),
///          then a message whose model is refused (message_rejected, no Run);
///   Run 2: a prompt through `/command` (its command_result, then its
///          user_message).
/// Returns the data lines of the whole journal, read over SSE from seq 0
/// (caller frees `sse` and the slice).
fn driveWireScenario(a: std.mem.Allocator, port: u16, write_path: [:0]const u8, sse_out: *[]u8) ![]const []const u8 {
    var start = try getState(a, port);
    defer start.deinit();

    const ack = try postMessage(a, port, "{\"text\":\"write the file\"}");
    defer a.free(ack);
    try std.testing.expect(std.mem.indexOf(u8, ack, "200 OK") != null);
    const asked = try eventsFrom(a, port, &start, "\"kind\":\"permission\"");
    defer a.free(asked);
    const id = try requestIdIn(asked, "permission");
    var answer_buf: [64]u8 = undefined;
    const answer = try std.fmt.bufPrint(&answer_buf, "{{\"id\":{d},\"choice\":\"allow_once\"}}", .{id});
    const granted = try request(a, port, "POST", "/respond", answer, null);
    defer a.free(granted);
    try std.testing.expect(std.mem.indexOf(u8, granted, "200 OK") != null);
    const first = try eventsFrom(a, port, &start, "\"type\":\"run_done\"");
    defer a.free(first);
    try std.testing.expect(pfs.exists(write_path.ptr)); // the answer reached the tool

    var idle = try getState(a, port);
    defer idle.deinit();
    try postCommand(a, port, "/mode dont-ask");
    const moded = try eventsFrom(a, port, &idle, "permission mode \xe2\x86\x92 dont_ask");
    defer a.free(moded);
    const refused = try postMessage(a, port, "{\"text\":\"refused\",\"model\":\"" ++ FOREIGN_MODEL ++ "\"}");
    defer a.free(refused);
    const rejected = try eventsFrom(a, port, &idle, "\"type\":\"message_rejected\"");
    defer a.free(rejected);
    try postCommand(a, port, "say hi");

    const sse = try eventsFromStart(a, port, start.str("epoch"), RUN2_DONE ++ "\n");
    errdefer a.free(sse);
    sse_out.* = sse;
    return dataLines(a, sse);
}

/// What the scenario journals, beyond the grammar: the lines that make it a
/// Run with a permission prompt, in their places.
fn expectWireScenario(a: std.mem.Allocator, lines: []const []const u8, session_id: []const u8) !void {
    try std.testing.expectEqual(@as(u64, 2), try expectWireJournal(a, lines));

    var created_buf: [128]u8 = undefined;
    const created = try std.fmt.bufPrint(&created_buf, "{{\"v\":1,\"type\":\"session_lifecycle\",\"data\":{{\"created\":\"{s}\"}}}}", .{session_id});
    try std.testing.expectEqualStrings(created, lines[0]);

    const user1 = try expectLine(lines, "{\"v\":1,\"type\":\"user_message\",\"data\":{\"run_id\":1,\"trace_id\":null,\"text\":\"write the file\",\"replaces\":null}}");
    const prompt = try expectLine(lines, "\"type\":\"ui_request\",\"id\":");
    try std.testing.expect(std.mem.indexOf(u8, lines[prompt], "\"kind\":\"permission\",\"request\":{\"tool\":\"Write\"") != null);
    const closed = try expectLine(lines, "\"type\":\"ui_request_closed\"");
    try std.testing.expect(std.mem.endsWith(u8, lines[closed], "\"outcome\":\"answered\"}"));
    const tool = try expectLine(lines, "{\"v\":1,\"type\":\"tool_result\",\"run_id\":1,\"data\":{\"id\":\"tu_w\",\"name\":\"Write\"");
    const done1 = try expectLine(lines, "{\"v\":1,\"type\":\"run_done\",\"data\":{\"run_id\":1,\"trace_id\":null,\"stop_reason\":\"end_turn\",\"error_name\":null,\"model_error\":null}}");
    try std.testing.expect(user1 < prompt and prompt < closed and closed < tool and tool < done1);

    const mode = try expectLine(lines, "{\"v\":1,\"type\":\"command_result\",\"data\":{\"command\":\"mode\",\"ok\":true,\"error_name\":null,\"message\":\"permission mode \xe2\x86\x92 dont_ask\"}}");
    const mode_changed = try expectLine(lines, "{\"v\":1,\"type\":\"config_changed\",\"data\":{\"mode\":\"dont_ask\"}}");
    const rejected = try expectLine(lines, "{\"v\":1,\"type\":\"message_rejected\",\"data\":{\"message\":\"model not available for current provider\",\"text\":\"refused\",\"model\":\"" ++ FOREIGN_MODEL ++ "\",\"permission_mode\":null}}");
    const queued = try expectLine(lines, "{\"v\":1,\"type\":\"command_result\",\"data\":{\"command\":\"prompt\",\"ok\":true,\"error_name\":null,\"message\":\"queued for run\"}}");
    const user2 = try expectLine(lines, "{\"v\":1,\"type\":\"user_message\",\"data\":{\"run_id\":2,\"trace_id\":null,\"text\":\"say hi\",\"replaces\":null}}");
    const text2 = try expectLine(lines, "{\"v\":1,\"type\":\"text_chunk\",\"run_id\":2,\"data\":");
    try std.testing.expect(done1 < mode_changed and mode_changed < mode and mode < rejected and rejected < queued);
    try std.testing.expect(queued < user2 and user2 < text2 and text2 < try expectLine(lines, RUN2_DONE));
}

test "L2 web: every journal line is wire v1 and a Run's lines carry its run_id, through a permission prompt (#444)" {
    const a = std.testing.allocator;
    const write_path = try wireWritePath(a);
    defer a.free(write_path);
    defer pfs.unlinkPath(write_path.ptr) catch {};
    const write_sse = try writeToolSse(a, write_path);
    defer a.free(write_sse);
    var fx: AppFixture = undefined;
    try fx.setup(&.{ write_sse, TEXT_SSE });
    defer fx.deinit();

    var web = WebRun{ .app = fx.app, .port = try freePort() };
    try web.start();
    var stopped = false;
    defer if (!stopped) web.stop() catch {};

    var sse: []u8 = &.{};
    const lines = try driveWireScenario(a, web.port, write_path, &sse);
    defer a.free(sse);
    defer a.free(lines);
    try expectWireScenario(a, lines, fx.app.session_id.asSlice());

    try web.stop();
    stopped = true;
}

/// Every NDJSON line a UDS attachment from seq 0 streams, until it has
/// carried `want` journal lines. The transport's own keepalive frame is not
/// a journal line (doc/WIRE_PROTOCOL.md §1.3) and is left out.
fn udsAttachLines(a: std.mem.Allocator, sock_path: []const u8, sid: []const u8, want: usize) ![][]u8 {
    const conn = try pnet.connectUnix(sock_path);
    defer pnet.closeSocket(conn);
    pnet.setRecvTimeoutMs(conn, 500);
    var line_buf: [128]u8 = undefined;
    const attach = try std.fmt.bufPrint(&line_buf, "{{\"op\":\"attach\",\"session\":\"{s}\",\"since\":0}}\n", .{sid});
    var off: usize = 0;
    while (off < attach.len) {
        const n = pnet.send(conn, attach[off..]);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
    var lines: std.ArrayList([]u8) = .empty;
    errdefer {
        for (lines.items) |l| a.free(l);
        lines.deinit(a);
    }
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(a);
    var chunk: [4096]u8 = undefined;
    const deadline = cc.util_time.nowMs() + 10_000;
    while (lines.items.len < want) {
        if (cc.util_time.nowMs() > deadline) return error.TestUdsAttachShort;
        const n = pnet.recv(conn, &chunk);
        if (n == 0) return error.TestUdsAttachShort;
        if (n < 0) {
            if (!pnet.recvRetriable()) return error.TestUdsAttachShort;
            continue;
        }
        try pending.appendSlice(a, chunk[0..@intCast(n)]);
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |nl| {
            const line = pending.items[0..nl];
            if (!std.mem.eql(u8, line, "{\"type\":\"keepalive\"}")) try lines.append(a, try a.dupe(u8, line));
            const rest = pending.items.len - nl - 1;
            std.mem.copyForwards(u8, pending.items[0..rest], pending.items[nl + 1 ..]);
            pending.shrinkRetainingCapacity(rest);
        }
    }
    return lines.toOwnedSlice(a);
}

test "L2 serve: the daemon driver journals the same wire v1 lines; SSE and UDS attach carry exactly them (#444)" {
    const a = std.testing.allocator;
    const write_path = try wireWritePath(a);
    defer a.free(write_path);
    defer pfs.unlinkPath(write_path.ptr) catch {};
    const write_sse = try writeToolSse(a, write_path);
    defer a.free(write_sse);
    var fx: AppFixture = undefined;
    try fx.setup(&.{ write_sse, TEXT_SSE });
    defer fx.deinit();

    var daemon: DaemonHost = undefined;
    try daemon.start(fx.app);
    defer daemon.stop();

    var sse: []u8 = &.{};
    const lines = try driveWireScenario(a, daemon.srv.port, write_path, &sse);
    defer a.free(sse);
    defer a.free(lines);
    try expectWireScenario(a, lines, fx.app.session_id.asSlice());

    // The journal itself, which SSE replayed line for line.
    const journal = (try daemon.host.journal.waitSince(a, 0, 0)) orelse return error.TestEmptyJournal;
    defer freeLines(a, journal);
    try std.testing.expect(journal.len >= lines.len);
    for (lines, journal[0..lines.len]) |streamed, journaled| try std.testing.expectEqualStrings(journaled, streamed);
    _ = try expectWireJournal(a, journal);

    if (builtin.os.tag == .windows) return; // UDS is POSIX-only
    var nonce: [6]u8 = undefined;
    if (!@import("platform").rng.randomBytes(&nonce)) return error.TestNoRandomness;
    var path_buf: [256]u8 = undefined;
    const sock_path = try std.fmt.bufPrint(&path_buf, "{s}/mc-wire-{s}.sock", .{ std.mem.trimEnd(u8, ppaths.tempDir(), "/"), &std.fmt.bytesToHex(nonce, .lower) });
    const uds = try cc.daemon_uds.UdsServer.start(a, sock_path, .{
        .allocator = a,
        .resolver = &DaemonHost.resolve,
        .resolver_ctx = @ptrCast(&daemon),
    });
    defer {
        // As serve shuts down: the journal's close ends the attachment, whose
        // thread waits on the journal, before the socket stops (`stop` closes
        // it again, which is harmless).
        daemon.host.journal.close();
        uds.stop();
    }
    const attached = try udsAttachLines(a, sock_path, fx.app.session_id.asSlice(), journal.len);
    defer freeLines(a, attached);
    try std.testing.expect(attached.len >= journal.len);
    for (journal, attached[0..journal.len]) |journaled, line| try std.testing.expectEqualStrings(journaled, line);
}
