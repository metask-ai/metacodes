//! L2 evidence: `--api-key` is the credential of the provider the session
//! started on, and a `/model` commit never hands it to another provider.
//!
//! On the historical path (no `--provider`) the flag is the Metask key. Before
//! this was scoped, `App.bindCommittedSelection` passed it as provider-less
//! material and provider resolution took it ahead of env and stored
//! credentials for whatever offer was committed, so `--api-key <metask key>`
//! followed by `/model use <another provider's model>` sent the Metask key to
//! that provider — and outranked that provider's own key.
//!
//! The other provider is a configured relay in the state root's
//! `config.json`, so the turn after the commit reaches a MockServer instead of
//! a real vendor. Mock transport only: no provider-backed calls.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const ppaths = @import("platform").paths;

const App = cc.app_module.App;

const METASK_KEY = "metask-secret";
const RELAY_KEY = "relay-secret";
/// The relay's own environment alias. Cleared by every case so the developer's
/// environment cannot supply a credential the test did not.
const RELAY_ENV = "HOUSE_RELAY_TOKEN";

const ANTHROPIC_END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";
const OPENAI_END_TURN_SSE =
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\n" ++
    "data: [DONE]\n\n";
const GATEWAY_MODELS = "{\"object\":\"list\",\"data\":[{\"id\":\"kimi-k3\",\"display_name\":\"Kimi K3\",\"max_input_tokens\":262144,\"max_tokens\":32768}]}";

const EnvGuard = struct {
    allocator: std.mem.Allocator,
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(allocator: std.mem.Allocator, name: [*:0]const u8, value: ?[*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try allocator.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
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

/// Variables that would supply a credential, move the route, or start
/// background work the case did not ask for.
const cleared_variables = [_][*:0]const u8{
    RELAY_ENV,
    "METASK_API_KEY",
    "METASK_GATEWAY_URL",
    "METACODES_PROVIDER",
    "METACODES_CONFIG_FILE",
};

/// A scratch state root as HOME, holding a `config.json` that declares the
/// relay; credentials and route variables cleared; no probe, no KG daemon.
const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    root: []const u8,
    guards: [cleared_variables.len + 3]EnvGuard,
    guard_count: usize,

    fn init(self: *Case, relay_origin: []const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.tmp = std.testing.tmpDir(.{});
        self.guard_count = 0;
        self.root = self.root_buf[0..try self.tmp.dir.realPath(std.testing.io, &self.root_buf)];
        const allocator = self.arena.allocator();
        for (cleared_variables) |name| try self.setEnv(name, null);
        try self.setEnv("HOME", (try allocator.dupeZ(u8, self.root)).ptr);
        try self.setEnv("METACODES_NO_PROBE", "1");
        try self.setEnv("METACODES_KG_AUTOSTART", "0");

        // An API-key relay on the OpenAI wire, with two models so a session
        // started on it can switch between them.
        const definition = try std.fmt.allocPrint(allocator,
            \\{{"custom_providers": {{"house-relay": {{
            \\  "display_name": "House relay",
            \\  "credential_kinds": ["api_key"],
            \\  "env_aliases": [{{"name": "{s}", "kind": "api_key", "canonical": true}}],
            \\  "channels": [{{"id": "primary", "base_url": "{s}/relay/v1", "protocol": "openai_chat"}}],
            \\  "models": [{{"request_model_id": "relay-model", "display_name": "Relay model"}},
            \\             {{"request_model_id": "relay-model-b", "display_name": "Relay model B"}}]}}}}}}
        , .{ RELAY_ENV, relay_origin });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = definition });
    }

    /// A variable already guarded is set in place: its first guard holds the
    /// value to restore.
    fn setEnv(self: *Case, name: [*:0]const u8, value: ?[*:0]const u8) !void {
        for (self.guards[0..self.guard_count]) |*guard| {
            if (std.mem.orderZ(u8, guard.name, name) == .eq) {
                if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
                return;
            }
        }
        self.guards[self.guard_count] = try EnvGuard.set(self.arena.allocator(), name, value);
        self.guard_count += 1;
    }

    fn deinit(self: *Case) void {
        var index = self.guard_count;
        while (index > 0) {
            index -= 1;
            self.guards[index].restore();
        }
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn config(self: *Case, argv: []const [*:0]const u8) !cc.types_mod.Config {
        var parsed = cc.parseArgsForTest(argv, self.arena.allocator());
        try std.testing.expect(parsed.parse_error == null);
        parsed.state_root = self.root;
        return parsed;
    }
};

/// `http://127.0.0.1:<port>`, the origin `urlOwned` puts `/v1/messages` behind.
fn originOf(allocator: std.mem.Allocator, server: *harness.MockServer) ![]u8 {
    const url = try server.urlOwned(allocator);
    return url[0 .. url.len - "/v1/messages".len];
}

fn requestLine(captured: harness.CapturedRequest) []const u8 {
    const end = std.mem.indexOf(u8, captured.raw, "\r\n") orelse captured.raw.len;
    return captured.raw[0..end];
}

fn headerValue(captured: harness.CapturedRequest, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, captured.raw, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

/// No request `server` received carries `secret` anywhere: not in the
/// authorization header, not in `x-api-key`, not in the body.
fn expectNeverSent(server: *harness.MockServer, secret: []const u8) !void {
    for (0..server.requestCount()) |index| {
        const captured = server.requestAt(index) orelse continue;
        if (std.mem.indexOf(u8, captured.raw, secret) != null) {
            std.debug.print("leaked to {s}: authorization={?s} x-api-key={?s}\n", .{
                requestLine(captured),
                headerValue(captured, "authorization"),
                headerValue(captured, "x-api-key"),
            });
            return error.CredentialCrossedProviders;
        }
    }
}

/// Send one turn on whatever route the session is on now, through the
/// transport it selects.
fn sendOneTurn(app: *App) !void {
    const messages = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    var handle = try app.provider().sendStream(&messages, null, null, null, null, null, "");
    defer handle.deinit();
    while (try handle.next()) |event| switch (event) {
        .text => |text| app.allocator.free(text),
        else => {},
    };
}

/// The rendered offer id of `provider`'s offer for `model` on `protocol`.
fn offerIdText(app: *App, provider: []const u8, model: []const u8, protocol: []const u8) ![cc.provider_ids.OFFER_ID_TEXT_LEN]u8 {
    const host = try app.providerHost();
    for (host.kernel.catalogSnapshot().items()) |offer| {
        if (!offer.provider_id.eqlText(provider)) continue;
        if (!std.mem.eql(u8, offer.request_model_id, model)) continue;
        if (!std.mem.eql(u8, offer.protocol, protocol)) continue;
        return offer.offer_id.render();
    }
    return error.OfferMissing;
}

test "L2 --api-key scope: the Metask key never reaches another provider's pick" {
    var metask = try harness.MockServer.startCassette(&.{ANTHROPIC_END_TURN_SSE}, 0);
    defer metask.stop();
    var relay = try harness.MockServer.startCassette(&.{OPENAI_END_TURN_SSE}, 0);
    defer relay.stop();

    var case: Case = undefined;
    var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup_arena.deinit();
    try case.init(try originOf(setup_arena.allocator(), relay));
    defer case.deinit();
    const allocator = case.arena.allocator();
    const metask_url = try allocator.dupeZ(u8, try metask.urlOwned(allocator));

    // The historical path: no provider named, the flag is the Metask key, and
    // `main` hands it to App as the session's bearer.
    const argv = [_][*:0]const u8{ "metacodes", "--api-key", METASK_KEY, "--base-url", metask_url.ptr, "--model", "claude-sonnet-4-6" };
    const config = try case.config(&argv);
    try std.testing.expect(config.provider_profile == null);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, METASK_KEY);
    defer app.deinit();

    // `/model use` the relay's model. The relay has no credential of its own
    // here, so the only key available is the Metask one.
    const outcome = cc.repl_picker_host.useSelector(app, "relay-model");
    try sendOneTurn(app);

    // Whatever the commit did, no byte of the Metask key went to the relay.
    try expectNeverSent(relay, METASK_KEY);
    try std.testing.expectEqual(@as(usize, 0), relay.requestCount());
    // The commit was refused for want of a relay credential, which the picker
    // turns into "no credential for house-relay" ...
    try std.testing.expect(outcome == .failed);
    try std.testing.expectEqualStrings("MissingCredentials", outcome.failed);
    // ... and the session is still on its Metask route, with its own key.
    try std.testing.expectEqualStrings("claude-sonnet-4-6", app.activeModel());
    const captured = metask.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /v1/messages "));
    try std.testing.expectEqualStrings("Bearer " ++ METASK_KEY, headerValue(captured, "authorization").?);
    try std.testing.expectEqualStrings("\"claude-sonnet-4-6\"", captured.jsonField("model").?);
}

test "L2 --api-key scope: another provider's pick uses that provider's own key, not the flag" {
    var relay = try harness.MockServer.startCassette(&.{OPENAI_END_TURN_SSE}, 0);
    defer relay.stop();

    var case: Case = undefined;
    var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup_arena.deinit();
    try case.init(try originOf(setup_arena.allocator(), relay));
    defer case.deinit();
    const allocator = case.arena.allocator();
    // The relay's key is in its own declared variable. Before scoping, the
    // flag outranked it and the relay received the Metask key instead.
    try case.setEnv(RELAY_ENV, RELAY_KEY);

    const argv = [_][*:0]const u8{ "metacodes", "--api-key", METASK_KEY, "--base-url", "http://127.0.0.1:9/v1/messages", "--model", "claude-sonnet-4-6" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, METASK_KEY);
    defer app.deinit();

    try std.testing.expect(cc.repl_picker_host.useSelector(app, "relay-model") == .switched);
    try sendOneTurn(app);

    try expectNeverSent(relay, METASK_KEY);
    const captured = relay.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /relay/v1/chat/completions "));
    try std.testing.expectEqualStrings("Bearer " ++ RELAY_KEY, headerValue(captured, "authorization").?);
    try std.testing.expectEqualStrings("\"relay-model\"", captured.jsonField("model").?);
}

test "L2 --api-key scope: on the historical path a Metask pick still authenticates with the flag" {
    var gateway = try harness.MockServer.startCassette(&.{ANTHROPIC_END_TURN_SSE}, 0);
    defer gateway.stop();

    var case: Case = undefined;
    try case.init("http://127.0.0.1:9");
    defer case.deinit();
    const allocator = case.arena.allocator();

    const argv = [_][*:0]const u8{ "metacodes", "--api-key", METASK_KEY, "--model", "claude-sonnet-4-6" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, METASK_KEY);
    defer app.deinit();

    // A Metask catalog at the mock gateway, so the pick has somewhere real to go.
    const host = try app.providerHost();
    try host.ingestMetask(try originOf(allocator, gateway), GATEWAY_MODELS, .messages_and_chat);
    const offer = try offerIdText(app, "metask", "kimi-k3", "anthropic_messages");

    try std.testing.expect(cc.repl_picker_host.useSelector(app, &offer) == .switched);
    try sendOneTurn(app);

    const captured = gateway.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /v1/messages "));
    try std.testing.expectEqualStrings("Bearer " ++ METASK_KEY, headerValue(captured, "authorization").?);
    try std.testing.expectEqualStrings("\"kimi-k3\"", captured.jsonField("model").?);
}

test "L2 --api-key scope: --provider X --api-key is X's key, for X's picks only" {
    var relay = try harness.MockServer.startCassette(&.{OPENAI_END_TURN_SSE}, 0);
    defer relay.stop();

    var case: Case = undefined;
    var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup_arena.deinit();
    const relay_origin = try originOf(setup_arena.allocator(), relay);
    try case.init(relay_origin);
    defer case.deinit();
    const allocator = case.arena.allocator();

    const argv = [_][*:0]const u8{ "metacodes", "--provider", "house-relay", "--api-key", RELAY_KEY };
    var config = try case.config(&argv);
    // What `main`'s startup route resolution records for `--provider
    // house-relay`: the relay's first model on its one channel, and the
    // provider identity the credential was resolved in.
    config.resolved_provider_id = "house-relay";
    config.provider_kind = .openai;
    config.base_url = try std.fmt.allocPrint(allocator, "{s}/relay/v1/chat/completions", .{relay_origin});
    config.model = "relay-model";
    config.model_explicit = true;
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, RELAY_KEY);
    defer app.deinit();

    // A Metask pick cannot borrow the relay's key. Refused before any request
    // exists, so nothing is dialled.
    const metask_offer = try offerIdText(app, "metask", "claude-sonnet-4-6", "anthropic_messages");
    const refused = cc.repl_picker_host.useSelector(app, &metask_offer);
    try std.testing.expect(refused == .failed);
    try std.testing.expectEqualStrings("MissingCredentials", refused.failed);
    try std.testing.expectEqualStrings("relay-model", app.activeModel());

    // The relay's own other model keeps working with the flag.
    try std.testing.expect(cc.repl_picker_host.useSelector(app, "relay-model-b") == .switched);
    try sendOneTurn(app);
    const captured = relay.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /relay/v1/chat/completions "));
    try std.testing.expectEqualStrings("Bearer " ++ RELAY_KEY, headerValue(captured, "authorization").?);
    try std.testing.expectEqualStrings("\"relay-model-b\"", captured.jsonField("model").?);
}
