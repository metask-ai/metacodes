//! L2 evidence: a route's declared vendor dialect (`ProtocolRoute.dialect`,
//! `ModelEntry.dialect`, `custom_providers.*.dialect`) — not the model name —
//! decides what the request body says, on every path a route reaches a
//! transport: the startup route through the client factory, a `/model` switch
//! inside a running App, and the child-agent registry.
//!
//! Mock transport only: no provider-backed calls.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const ppaths = @import("platform").paths;

const App = cc.app_module.App;
const Vendor = cc.api_dialect.Vendor;

const OPENAI_END_TURN_SSE =
    "data: {\"id\":\"c1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"id\":\"c1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\n" ++
    "data: [DONE]\n\n";
const ANTHROPIC_END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const RELAY_ENV = "VENDOR_DIALECT_RELAY_KEY";
const RELAY_KEY = "relay-secret";

/// `http://127.0.0.1:<port>`, the origin `urlOwned` puts `/v1/messages` behind.
fn originOf(allocator: std.mem.Allocator, server: *harness.MockServer) ![]u8 {
    const url = try server.urlOwned(allocator);
    return url[0 .. url.len - "/v1/messages".len];
}

fn drain(allocator: std.mem.Allocator, provider: cc.api_provider.Provider, messages: []const cc.types_mod.ApiMessage) !void {
    var handle = try provider.sendStream(messages, null, null, null, null, null, "");
    defer handle.deinit();
    while (try handle.next()) |event| switch (event) {
        .text, .thinking => |bytes| allocator.free(bytes),
        else => {},
    };
}

const HI = [_]cc.types_mod.ApiMessage{
    .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
};

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
        } else ppaths.unsetEnv(self.name);
        self.* = undefined;
    }
};

const cleared_variables = [_][*:0]const u8{
    "METASK_API_KEY",
    "METASK_GATEWAY_URL",
    "METACODES_PROVIDER",
    "METACODES_CONFIG_FILE",
    "DEEPSEEK_API_KEY",
};

/// A scratch HOME holding a `config.json` with two relays on the same mock
/// server: `declared` says its route speaks DeepSeek, `plain` says nothing.
/// Their model ids carry no vendor name, so only the declaration can matter.
const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    root: []const u8,
    guards: [cleared_variables.len + 4]EnvGuard,
    guard_count: usize,

    fn init(self: *Case, origin: []const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.tmp = std.testing.tmpDir(.{});
        self.guard_count = 0;
        self.root = self.root_buf[0..try self.tmp.dir.realPath(std.testing.io, &self.root_buf)];
        const allocator = self.arena.allocator();
        for (cleared_variables) |name| try self.guard(name, null);
        try self.guard("HOME", (try allocator.dupeZ(u8, self.root)).ptr);
        try self.guard("METACODES_NO_PROBE", "1");
        try self.guard("METACODES_KG_AUTOSTART", "0");
        try self.guard(RELAY_ENV, RELAY_KEY);
        const definition = try std.fmt.allocPrint(allocator,
            \\{{"custom_providers": {{
            \\  "declared": {{
            \\    "env_aliases": [{{"name": "{s}", "kind": "api_key", "canonical": true}}],
            \\    "channels": [{{"id": "c", "base_url": "{s}/declared/v1", "protocol": "openai_chat", "dialect": "deepseek"}}],
            \\    "models": [{{"request_model_id": "house-model-a"}}]}},
            \\  "plain": {{
            \\    "env_aliases": [{{"name": "{s}", "kind": "api_key", "canonical": true}}],
            \\    "channels": [{{"id": "c", "base_url": "{s}/plain/v1", "protocol": "openai_chat"}}],
            \\    "models": [{{"request_model_id": "house-model-b"}}]}}}}}}
        , .{ RELAY_ENV, origin, RELAY_ENV, origin });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = definition });
    }

    fn guard(self: *Case, name: [*:0]const u8, value: ?[*:0]const u8) !void {
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

test "L2 dialect: a /model switch writes the request in the route's declared dialect, not the model name's" {
    var anthropic = try harness.MockServer.startCassette(&.{ANTHROPIC_END_TURN_SSE}, 0);
    defer anthropic.stop();
    var relay = try harness.MockServer.startCassette(&.{ OPENAI_END_TURN_SSE, OPENAI_END_TURN_SSE }, 0);
    defer relay.stop();

    var case: Case = undefined;
    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    try case.init(try originOf(setup.allocator(), relay));
    defer case.deinit();
    const allocator = case.arena.allocator();
    const start_url = try allocator.dupeZ(u8, try anthropic.urlOwned(allocator));

    const argv = [_][*:0]const u8{ "metacodes", "--api-key", "metask-key", "--base-url", start_url.ptr, "--model", "claude-sonnet-4-6" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, "metask-key");
    defer app.deinit();

    // The declared relay: DeepSeek's thinking switch and effort words.
    try std.testing.expect(cc.repl_picker_host.useSelector(app, "house-model-a") == .switched);
    try app.provider().setReasoningEffort(.high);
    try drain(app.allocator, app.provider(), &HI);
    const declared = relay.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, declared.raw, "POST /declared/v1/chat/completions ") != null);
    try std.testing.expect(std.mem.indexOf(u8, declared.body(), "\"thinking\":{\"type\":\"enabled\"},\"reasoning_effort\":\"high\"") != null);
    // A child agent spawned now inherits the declaration with the route.
    try std.testing.expectEqual(Vendor.deepseek, app.agent_jobs.?.dialect.?);
    try std.testing.expectEqual(Vendor.deepseek, app.swarm.dialect.?);

    // The plain relay: no declaration, an unrecognisable name — OpenAI native.
    try std.testing.expect(cc.repl_picker_host.useSelector(app, "house-model-b") == .switched);
    try app.provider().setReasoningEffort(.high);
    try drain(app.allocator, app.provider(), &HI);
    const plain = relay.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, plain.raw, "POST /plain/v1/chat/completions ") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain.body(), "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain.body(), "\"thinking\"") == null);
    try std.testing.expect(app.agent_jobs.?.dialect == null);
}

test "L2 dialect: the startup route of a built-in vendor reaches the factory-built client" {
    const a = std.testing.allocator;
    var server = try harness.MockServer.startCassette(&.{OPENAI_END_TURN_SSE}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    const origin = url[0 .. url.len - "/v1/messages".len];

    var registry = try cc.provider_registry.ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    // The mock stands in for the Coding Plan's OpenAI channel; loopback
    // plaintext passes the route policy, which still requires `/coding/`.
    const base_url = try std.fmt.allocPrint(a, "{s}/api/coding/paas/v4", .{origin});
    defer a.free(base_url);
    const outcome = try cc.provider_startup.resolve(a, &registry, .{
        .provider = "zai-coding-plan",
        .channel = "cn-openai",
        .model = "house-deployment",
        .base_url = base_url,
    });
    try std.testing.expect(outcome == .route);
    var route = outcome.route;
    defer route.deinit();
    try std.testing.expectEqual(Vendor.glm, route.dialect.?);

    var owned = try cc.api_provider_factory.makeProviderWithOptions(
        a,
        route.transport,
        .{ .fixed = "zai-key" },
        route.request_model_id,
        route.endpoint_url,
        route.openai_protocol,
        .builtin(),
        .{ .auth_scheme = route.auth_scheme, .dialect = route.dialect },
    );
    defer owned.deinit();
    try owned.provider().setReasoningEffort(.high);
    try drain(a, owned.provider(), &HI);

    // "house-deployment" names no vendor; the route says GLM, so the request
    // carries GLM's thinking switch, not the OpenAI-native top-level effort only.
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"enabled\"},\"clear_thinking\":false,\"reasoning_effort\":\"high\"") != null);
}
