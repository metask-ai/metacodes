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

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const pnet = @import("platform").net;
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
    const user = try expectLine(lines, "{\"user_message\":\"turn one\"}");
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
    _ = try expectLine(lines2, "{\"user_message\":\"turn two\"}");
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
    const user3 = try expectLine(lines3, "{\"user_message\":\"turn three\"}");
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
    _ = try expectLine(failed_lines, "{\"run_done\":{\"stop_reason\":\"api_error\",\"err\":\"Balance too low\",\"model_error\":{\"category\":\"unknown\",\"code\":\"insufficient_balance\",\"type\":\"billing_error\",\"message\":\"Balance too low\",\"http_status\":200,\"request_id\":\"req-web-1\",\"retry\":\"unknown\",\"retry_after_ms\":null,\"attempts\":1,\"truncated\":false}}}");

    var after = try getState(a, port);
    defer after.deinit();
    const ack2 = try postMessage(a, port, "{\"text\":\"succeeds\"}");
    defer a.free(ack2);
    const clean = try eventsFrom(a, port, &after, "\"run_done\"");
    defer a.free(clean);
    const clean_lines = try dataLines(a, clean);
    defer a.free(clean_lines);
    _ = try expectLine(clean_lines, "{\"run_done\":{\"stop_reason\":\"end_turn\",\"err\":null}}");
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
        "{\"message_rejected\":{\"message\":\"model not available for current provider\",\"text\":\"turn three\",\"model\":\"" ++ FOREIGN_MODEL ++ "\",\"permission_mode\":\"bypass_permissions\"}}",
        rejected,
    );
    // FIFO: the refused bodies would have been taken before this one.
    try std.testing.expectEqual(@as(usize, 0), countLines(lines, "\"user_message\""));
    try std.testing.expectEqual(@as(usize, 0), countLines(lines, "\"type\":\"config_changed\""));
    try std.testing.expectEqual(@as(usize, 0), countLines(lines, "bad mode"));
    try std.testing.expectEqual(@as(usize, 0), countLines(lines, "bad model"));

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
        "{\"message_rejected\":{\"message\":\"bypassPermissions is disabled by settings\",\"text\":\"escalate\",\"model\":\"" ++ TURN_MODEL ++ "\",\"permission_mode\":\"bypass_permissions\"}}",
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
        try std.testing.expectEqualStrings("{\"command_result\":{\"ok\":false,\"message\":\"bypassPermissions is disabled by settings\"}}", result);
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
    const user = try expectLine(lines, "{\"user_message\":\"escalate\"}");
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
        try std.testing.expectEqualStrings("{\"command_result\":{\"ok\":false,\"message\":\"auto mode is disabled by settings\"}}", result);
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
        self.config_sink = .{ .journal = &self.host.journal, .alloc = a };
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
    const user = try expectLine(lines, "{\"user_message\":\"over uds\"}");
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
