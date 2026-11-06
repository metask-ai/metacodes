//! L2 evidence: a route's declared vendor dialect (`ProtocolRoute.dialect`,
//! `ModelEntry.dialect`, `custom_providers.*.dialect`) — not the model name —
//! decides what the request body says, on every path a route reaches a
//! transport: the startup route through the client factory, a `/model` switch
//! inside a running App, and the child-agent and teammate registries. A model
//! entry's declaration covers that model only: a child or teammate on another
//! model of the same route is written in that model's own dialect.
//!
//! Also: the DeepSeek dialect's reasoning passback reaches the wire as
//! `reasoning_content` on assistant history, and a dialect that does not
//! declare passback keeps the request bytes free of thinking.
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
    return drainAs(allocator, provider, messages, null, null);
}

/// One request with a system prompt and a per-call model, the way a child
/// agent whose definition names another model sends it. `allocator` is the
/// provider's own: registry-built providers allocate events with
/// `std.heap.c_allocator`.
fn drainAs(allocator: std.mem.Allocator, provider: cc.api_provider.Provider, messages: []const cc.types_mod.ApiMessage, system: ?[]const u8, model_override: ?[]const u8) !void {
    var handle = try provider.sendStream(messages, system, null, null, model_override, null, "");
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

/// A scratch HOME holding a `config.json` with three relays on the same mock
/// server: `declared` says its route speaks DeepSeek, `plain` says nothing,
/// and `gateway` declares Kimi on one of its two models only. Their model ids
/// carry no vendor name, so only the declarations can matter.
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
            \\    "models": [{{"request_model_id": "house-model-b"}}]}},
            \\  "gateway": {{
            \\    "env_aliases": [{{"name": "{s}", "kind": "api_key", "canonical": true}}],
            \\    "channels": [{{"id": "c", "base_url": "{s}/gateway/v1", "protocol": "openai_chat"}}],
            \\    "models": [{{"request_model_id": "house-model-c", "dialect": "kimi"}}, {{"request_model_id": "house-model-d"}}]}}}}}}
        , .{ RELAY_ENV, origin, RELAY_ENV, origin, RELAY_ENV, origin });
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
    var relay = try harness.MockServer.startCassette(&.{ OPENAI_END_TURN_SSE, OPENAI_END_TURN_SSE, OPENAI_END_TURN_SSE, OPENAI_END_TURN_SSE }, 0);
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
    // A child agent spawned now inherits the declaration with the route, and
    // the route's covers every model, including a child's own.
    try std.testing.expectEqual(Vendor.deepseek, app.agent_jobs.?.dialect.route.?);
    try std.testing.expectEqual(Vendor.deepseek, app.swarm.dialect.route.?);
    {
        var child = try app.agent_jobs.?.makeProvider();
        defer child.deinit();
        try drainAs(std.heap.c_allocator, child.provider(), &HI, null, "house-model-z");
        const sent = relay.lastRequest() orelse return error.NoRequestCaptured;
        try std.testing.expect(std.mem.indexOf(u8, sent.raw, "POST /declared/v1/chat/completions ") != null);
        try std.testing.expect(std.mem.indexOf(u8, sent.body(), "\"model\":\"house-model-z\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, sent.body(), "\"thinking\":{\"type\":\"enabled\"}") != null);
    }

    // The plain relay: no declaration, an unrecognisable name — OpenAI native.
    try std.testing.expect(cc.repl_picker_host.useSelector(app, "house-model-b") == .switched);
    try app.provider().setReasoningEffort(.high);
    try drain(app.allocator, app.provider(), &HI);
    const plain = relay.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, plain.raw, "POST /plain/v1/chat/completions ") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain.body(), "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain.body(), "\"thinking\"") == null);
    try std.testing.expect(app.agent_jobs.?.dialect.bound() == null);
    {
        var child = try app.agent_jobs.?.makeProvider();
        defer child.deinit();
        try drainAs(std.heap.c_allocator, child.provider(), &HI, null, null);
        const sent = relay.lastRequest() orelse return error.NoRequestCaptured;
        try std.testing.expect(std.mem.indexOf(u8, sent.raw, "POST /plain/v1/chat/completions ") != null);
        try std.testing.expect(std.mem.indexOf(u8, sent.body(), "\"thinking\"") == null);
    }
}

test "L2 dialect: a model entry's declaration writes that model's requests; its child on another model is not written in it" {
    var anthropic = try harness.MockServer.startCassette(&.{ANTHROPIC_END_TURN_SSE}, 0);
    defer anthropic.stop();
    var relay = try harness.MockServer.startCassette(&.{ OPENAI_END_TURN_SSE, OPENAI_END_TURN_SSE, OPENAI_END_TURN_SSE }, 0);
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

    // house-model-c declares Kimi on its entry: Kimi's always-on thinking
    // object, never the OpenAI-native top-level effort.
    try std.testing.expect(cc.repl_picker_host.useSelector(app, "house-model-c") == .switched);
    try app.provider().setReasoningEffort(.high);
    try drain(app.allocator, app.provider(), &HI);
    const declared = relay.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, declared.raw, "POST /gateway/v1/chat/completions ") != null);
    try std.testing.expect(std.mem.indexOf(u8, declared.body(), "\"thinking\":{\"type\":\"enabled\",\"keep\":\"all\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, declared.body(), "\"reasoning_effort\"") == null);
    try std.testing.expectEqual(Vendor.kimi, app.agent_jobs.?.dialect.model.?);
    try std.testing.expect(app.agent_jobs.?.dialect.route == null);

    var child = try app.agent_jobs.?.makeProvider();
    defer child.deinit();
    // A child on the parent's model keeps the entry's declaration.
    try drainAs(std.heap.c_allocator, child.provider(), &HI, null, null);
    const same = relay.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, same.body(), "\"model\":\"house-model-c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, same.body(), "\"thinking\":{\"type\":\"enabled\",\"keep\":\"all\"}") != null);
    // A child naming the gateway's other model is not written in Kimi's
    // dialect: the route declares nothing, so its name decides (OpenAI native).
    try drainAs(std.heap.c_allocator, child.provider(), &HI, null, "house-model-d");
    const other = relay.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, other.body(), "\"model\":\"house-model-d\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, other.body(), "\"thinking\"") == null);
}

const STRICT_SKILL = cc.api_capability_activation.STRICT_SKILL_SECTION_MARKER;
const SKILLS_SYSTEM = "base\n\n" ++ cc.api_capability_activation.SKILLS_SECTION_MARKER ++ "\n- verify: bounded review";

test "L2 dialect: on the Metask gateway a child or teammate on glm-5.2 keeps GLM's dialect, not the lead's Claude entry's" {
    const a = std.testing.allocator;
    var server = try harness.MockServer.startCassette(&.{ ANTHROPIC_END_TURN_SSE, ANTHROPIC_END_TURN_SSE, ANTHROPIC_END_TURN_SSE }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    const origin = url[0 .. url.len - "/v1/messages".len];

    var registry = try cc.provider_registry.ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    const outcome = try cc.provider_startup.resolve(a, &registry, .{
        .provider = "metask",
        .model = "claude-sonnet-4-6",
        .base_url = origin,
    });
    try std.testing.expect(outcome == .route);
    var route = outcome.route;
    defer route.deinit();
    // Metask declares Claude on its Claude entries, not on the route: the
    // gateway serves other vendors' models over the same wire.
    try std.testing.expectEqual(Vendor.claude, route.dialect.model.?);
    try std.testing.expect(route.dialect.route == null);

    // Child agents: a provider bound to the lead's model, the child's model
    // per call.
    var jobs = try cc.agent_job_registry.AgentJobRegistry.init(a, "metask-key", route.endpoint_url, route.request_model_id, route.transport);
    defer jobs.deinit();
    try jobs.setRoute("metask-key", route.endpoint_url, route.transport, route.openai_protocol, route.auth_scheme, route.dialect);
    var child = try jobs.makeProvider();
    defer child.deinit();
    try drainAs(std.heap.c_allocator, child.provider(), &HI, SKILLS_SYSTEM, null);
    const lead_model = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, lead_model, "\"model\":\"claude-sonnet-4-6\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lead_model, STRICT_SKILL) == null);
    // A child whose definition names glm-5.2: GLM's strict Skill section, as
    // the name gave it before routes could declare.
    try drainAs(std.heap.c_allocator, child.provider(), &HI, SKILLS_SYSTEM, "glm-5.2");
    const child_glm = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, child_glm, "\"model\":\"glm-5.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, child_glm, STRICT_SKILL) != null);

    // A teammate: its provider is bound to the teammate's own model.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    var teammates = try cc.swarm_teammate.TeammateRegistry.initWithDialectResolver(a, "metask-key", route.endpoint_url, route.request_model_id, route.transport, route.openai_protocol, root, .builtin());
    defer teammates.deinit();
    teammates.auth_scheme = route.auth_scheme;
    teammates.dialect = route.dialect;
    var mate = try teammates.makeProvider("glm-5.2");
    defer mate.deinit();
    try drainAs(std.heap.c_allocator, mate.provider(), &HI, SKILLS_SYSTEM, null);
    const mate_glm = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, mate_glm, "\"model\":\"glm-5.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mate_glm, STRICT_SKILL) != null);
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
    try std.testing.expectEqual(Vendor.glm, route.dialect.route.?);

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

fn historyWithThinking(conv: *cc.conversation.Conversation, a: std.mem.Allocator) !void {
    try conv.appendText(.user, "list the files");
    const assistant = try a.alloc(cc.core_message.Block, 2);
    assistant[0] = .{ .thinking = try a.dupe(u8, "plan: call Glob first") };
    assistant[1] = .{ .tool_use = .{ .id = try a.dupe(u8, "call_1"), .name = try a.dupe(u8, "Glob"), .input = try a.dupe(u8, "{\"pattern\":\"*\"}") } };
    try conv.append(.{ .role = .assistant, .blocks = assistant });
    const result = try a.alloc(cc.core_message.Block, 1);
    result[0] = .{ .tool_result = .{ .tool_use_id = try a.dupe(u8, "call_1"), .content = try a.dupe(u8, "a.txt"), .is_error = false } };
    try conv.append(.{ .role = .user, .blocks = result });
}

fn runOneTurn(conv: *cc.conversation.Conversation, provider: cc.api_provider.Provider, a: std.mem.Allocator) !void {
    const perm = cc.permission.createContext(.bypass_permissions, a);
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = try cc.agent_loop.run(conv, provider, &.{}, &perm, .{
        .max_turns = 1,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &be, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
}

test "L2 dialect: DeepSeek gets the assistant's thinking back as reasoning_content, OpenAI does not" {
    const a = std.testing.allocator;
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();

    inline for (.{ .{ Vendor.deepseek, true }, .{ Vendor.openai, false } }) |case| {
        var server = try harness.MockServer.startCassette(&.{OPENAI_END_TURN_SSE}, 0);
        defer server.stop();
        const url = try server.urlOwned(a);
        defer a.free(url);
        var client = cc.api_openai.OpenAIClient.init(a, io_rt.io(), "key", "house-model", url);
        defer client.deinit();
        client.dialect_vendor = case[0];

        var conv = cc.conversation.Conversation.init(a);
        defer conv.deinit();
        try historyWithThinking(&conv, a);
        try runOneTurn(&conv, client.provider(), a);

        const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
        const echoed = std.mem.indexOf(u8, body, "\"reasoning_content\":\"plan: call Glob first\"") != null;
        try std.testing.expectEqual(case[1], echoed);
        // Whichever dialect, the thinking never leaks into visible content.
        try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"plan: call Glob first\"") == null);
    }
}

test "L2 dialect: Claude never receives an unsigned thinking block; DeepSeek's Anthropic wire does" {
    const a = std.testing.allocator;
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();

    inline for (.{ .{ @as(?Vendor, null), "claude-sonnet-4-6", false }, .{ @as(?Vendor, .deepseek), "deepseek-v4-pro", true } }) |case| {
        var server = try harness.MockServer.startCassette(&.{ANTHROPIC_END_TURN_SSE}, 0);
        defer server.stop();
        const url = try server.urlOwned(a);
        defer a.free(url);
        var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "key", case[1], url);
        defer client.deinit();
        client.dialect_vendor = case[0];

        var conv = cc.conversation.Conversation.init(a);
        defer conv.deinit();
        try historyWithThinking(&conv, a);
        try runOneTurn(&conv, client.provider(), a);

        const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
        const echoed = std.mem.indexOf(u8, body, "{\"type\":\"thinking\",\"thinking\":\"plan: call Glob first\"}") != null;
        try std.testing.expectEqual(case[2], echoed);
    }
}
