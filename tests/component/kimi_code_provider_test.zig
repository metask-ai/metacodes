//! L2 evidence for the Kimi Code subscription profile (#487).
//!
//! - `--provider kimi-code` resolves to the subscription's Responses route,
//!   and the request carries the subscription key (`KIMI_CODE_API_KEY`, or
//!   `KIMI_API_KEY`) to `/coding/v1/responses`; the Chat Completions channel
//!   sends the Kimi Code reasoning parameters to `/coding/v1/chat/completions`.
//! - `KIMI_API_KEY` belongs to Kimi Code now: the Moonshot open-platform
//!   profile (`kimi`) refuses to start on it, before any request exists, so a
//!   subscription key is never sent to the platform's account.
//! - A pasted key is checked against `/coding/v1/models` and stored in
//!   `<state root>/keys/kimi-code.json` (0600) as a Kimi Code key, which only
//!   that provider's resolution reads.
//!
//! Each case clears every Kimi and Moonshot variable first, so the developer's
//! own keys can never reach a test, and every request goes to a MockServer.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const ppaths = @import("platform").paths;
const pfs = @import("platform").fs;

const Slug = cc.provider_ids.Slug;
const key_store = cc.provider_api_key_store;
const provider_login = cc.api_provider_login;

const SUBSCRIPTION_KEY = "sk-kimi-test-subscription";
const RESPONSES_SSE =
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"ok\"}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":1}}}\n\n";
const CHAT_SSE =
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"thinking\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\n" ++
    "data: [DONE]\n\n";
const MODELS_OK = "{\"object\":\"list\",\"data\":[{\"id\":\"k3.1-pro\",\"context_length\":262144}]}";

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

/// Every variable that could supply a Kimi or Moonshot credential, move a
/// route, or answer the key check the case did not ask for.
const cleared_variables = [_][*:0]const u8{
    "KIMI_CODE_API_KEY",
    "KIMI_API_KEY",
    "MOONSHOT_API_KEY",
    "METASK_API_KEY",
    "METASK_GATEWAY_URL",
    "METACODES_PROVIDER",
    "METACODES_BASE_URL",
    "METACODES_KEY_CHECK_URL",
    "METACODES_CONFIG_FILE",
    "METACODES_OPENAI_PROTOCOL",
};

/// A scratch state root as HOME, every key variable cleared, no probe, no KG.
const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    root: []const u8,
    guards: [cleared_variables.len + 4]EnvGuard,
    guard_count: usize,

    fn init(self: *Case) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.tmp = std.testing.tmpDir(.{});
        self.guard_count = 0;
        self.root = self.root_buf[0..try self.tmp.dir.realPath(std.testing.io, &self.root_buf)];
        for (cleared_variables) |name| try self.setEnv(name, null);
        try self.setEnv("HOME", (try self.arena.allocator().dupeZ(u8, self.root)).ptr);
        try self.setEnv("METACODES_NO_PROBE", "1");
        try self.setEnv("METACODES_KG_AUTOSTART", "0");
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

    /// `http://127.0.0.1:<port>`, the origin `urlOwned` puts `/v1/messages` behind.
    fn originOf(self: *Case, server: *harness.MockServer) ![]const u8 {
        const url = try server.urlOwned(self.arena.allocator());
        return url[0 .. url.len - "/v1/messages".len];
    }

    /// The subscription's OpenAI-protocol base URL on `server`.
    fn codingBase(self: *Case, server: *harness.MockServer) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/coding/v1", .{try self.originOf(server)});
    }

    /// The credential `metacodes --provider <name>` would start with.
    fn secretFor(self: *Case, name: [:0]const u8) ![]u8 {
        const argv = [_][*:0]const u8{ "metacodes", "--provider", name.ptr };
        return cc.resolveProviderScopedSecret(std.testing.allocator, try self.config(&argv), name);
    }
};

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

fn resolveRoute(
    registry: *const cc.provider_registry.ProviderRegistry,
    request: cc.provider_startup.StartupRequest,
) !cc.provider_startup.StartupRoute {
    const outcome = try cc.provider_startup.resolve(std.testing.allocator, registry, request);
    return switch (outcome) {
        .route => |route| route,
        .failure => error.RouteNotResolved,
    };
}

/// One request on `route`, built the way a session binds it: the route's
/// endpoint, wire, auth scheme and declared dialect.
fn sendOne(
    route: *const cc.provider_startup.StartupRoute,
    secret: []const u8,
    effort: ?cc.types_mod.ReasoningEffort,
    server: *harness.MockServer,
) !harness.CapturedRequest {
    const a = std.testing.allocator;
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client = cc.api_openai.OpenAIClient.init(a, io_runtime.io(), secret, route.request_model_id, route.endpoint_url);
    defer client.deinit();
    client.protocol = route.openai_protocol;
    client.auth_scheme = route.auth_scheme;
    client.declared_dialect = route.dialect;
    client.reasoning_effort = effort;

    const messages = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    var handle = try client.provider().sendStream(&messages, null, null, null, null, null, "");
    while (try handle.next()) |event| switch (event) {
        .text, .thinking, .reasoning_item, .web_search_query => |bytes| a.free(bytes),
        else => {},
    };
    handle.deinit();
    return server.lastRequest() orelse error.NoRequestCaptured;
}

test "L2 Kimi Code: KIMI_CODE_API_KEY reaches the subscription's Responses endpoint; the Moonshot platform gets nothing" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.setEnv("KIMI_CODE_API_KEY", SUBSCRIPTION_KEY);
    var subscription = try harness.MockServer.start(RESPONSES_SSE, 0);
    defer subscription.stop();
    var platform = try harness.MockServer.start(CHAT_SSE, 0);
    defer platform.stop();

    var registry = try cc.provider_registry.ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    // `--provider kimi-code` with the mock standing in for api.kimi.com.
    var route = try resolveRoute(&registry, .{ .provider = "kimi-code", .base_url = try case.codingBase(subscription) });
    defer route.deinit();
    try std.testing.expect(route.channel_id.eqlText("cn-responses"));
    try std.testing.expectEqual(cc.types_mod.ProviderKind.openai, route.transport);
    try std.testing.expectEqual(cc.types_mod.OpenAIProtocol.responses, route.openai_protocol);
    try std.testing.expectEqualStrings("k3.1-pro", route.request_model_id);

    const secret = try case.secretFor("kimi-code");
    defer std.testing.allocator.free(secret);
    try std.testing.expectEqualStrings(SUBSCRIPTION_KEY, secret);

    const captured = try sendOne(&route, secret, .high, subscription);
    try std.testing.expectEqualStrings("POST /coding/v1/responses HTTP/1.1", requestLine(captured));
    try std.testing.expectEqualStrings("Bearer " ++ SUBSCRIPTION_KEY, (headerValue(captured, "authorization") orelse return error.NoAuthorizationHeader));
    try std.testing.expectEqualStrings("\"k3.1-pro\"", (captured.jsonField("model") orelse return error.ModelFieldMissing));
    try std.testing.expectEqualStrings("false", (captured.jsonField("store") orelse return error.StoreFieldMissing));
    try std.testing.expect(std.mem.indexOf(u8, captured.body(), "\"reasoning\":{\"effort\":\"high\"}") != null);

    // The platform is another account: its profile does not start on the
    // subscription key, so nothing is ever sent to its endpoint.
    var platform_route = try resolveRoute(&registry, .{
        .provider = "kimi",
        .base_url = try std.fmt.allocPrint(case.arena.allocator(), "{s}/v1", .{try case.originOf(platform)}),
    });
    defer platform_route.deinit();
    try std.testing.expectError(error.MissingCredentials, case.secretFor("kimi"));
    try std.testing.expectEqual(@as(usize, 0), platform.requestCount());
}

test "L2 Kimi Code: KIMI_API_KEY belongs to Kimi Code, and the Moonshot platform no longer reads it" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.setEnv("KIMI_API_KEY", SUBSCRIPTION_KEY);

    // Kimi Code starts on it ...
    const secret = try case.secretFor("kimi-code");
    defer std.testing.allocator.free(secret);
    try std.testing.expectEqualStrings(SUBSCRIPTION_KEY, secret);
    // ... the open platform does not: before #487 it took KIMI_API_KEY as an
    // alias of MOONSHOT_API_KEY and sent a subscription key to another account.
    try std.testing.expectError(error.MissingCredentials, case.secretFor("kimi"));

    // MOONSHOT_API_KEY stays the platform's and never becomes a Kimi Code key.
    try case.setEnv("KIMI_API_KEY", null);
    try case.setEnv("MOONSHOT_API_KEY", "sk-platform-test");
    const platform_secret = try case.secretFor("kimi");
    defer std.testing.allocator.free(platform_secret);
    try std.testing.expectEqualStrings("sk-platform-test", platform_secret);
    try std.testing.expectError(error.MissingCredentials, case.secretFor("kimi-code"));
}

test "L2 Kimi Code: the Chat Completions channel sends the Kimi Code reasoning parameters" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const bodies = [_][]const u8{ CHAT_SSE, CHAT_SSE, CHAT_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();

    var registry = try cc.provider_registry.ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    const base = try case.codingBase(server);
    var route = try resolveRoute(&registry, .{ .provider = "kimi-code", .channel = "cn-chat", .model = "kimi-for-coding", .base_url = base });
    defer route.deinit();
    try std.testing.expectEqual(cc.types_mod.OpenAIProtocol.chat_completions, route.openai_protocol);

    // A chosen level goes out as the top-level reasoning_effort, in Kimi's words.
    const chosen = try sendOne(&route, SUBSCRIPTION_KEY, .medium, server);
    try std.testing.expectEqualStrings("POST /coding/v1/chat/completions HTTP/1.1", requestLine(chosen));
    try std.testing.expectEqualStrings("\"kimi-for-coding\"", (chosen.jsonField("model") orelse return error.ModelFieldMissing));
    try std.testing.expectEqualStrings("\"high\"", (chosen.jsonField("reasoning_effort") orelse return error.ReasoningEffortMissing));
    try std.testing.expect(chosen.jsonField("thinking") == null);

    // No level chosen: nothing is sent, and the server's own default applies
    // (max for K2.8 Preview, high for K3.1 Pro), not a level picked for the user.
    const unset = try sendOne(&route, SUBSCRIPTION_KEY, null, server);
    try std.testing.expect(unset.jsonField("reasoning_effort") == null);
    try std.testing.expect(unset.jsonField("thinking") == null);

    // K2.7 Code Highspeed: thinking always on, no levels.
    var highspeed = try resolveRoute(&registry, .{ .provider = "kimi-code", .channel = "cn-chat", .model = "kimi-for-coding-highspeed", .base_url = base });
    defer highspeed.deinit();
    const always_on = try sendOne(&highspeed, SUBSCRIPTION_KEY, .none, server);
    try std.testing.expect(always_on.jsonField("reasoning_effort") == null);
    try std.testing.expect(std.mem.indexOf(u8, always_on.body(), "\"thinking\":{\"type\":\"enabled\",\"keep\":\"all\"}") != null);
}

test "L2 Kimi Code key login: checked on the subscription's model list, stored 0600 for Kimi Code only" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    var check = try harness.MockServer.start(MODELS_OK, 0);
    defer check.stop();
    const check_url = try std.fmt.allocPrintSentinel(case.arena.allocator(), "{s}/models", .{try case.codingBase(check)}, 0);
    try case.setEnv("METACODES_KEY_CHECK_URL", check_url.ptr);

    var registry = try cc.provider_registry.ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    const profile = registry.find("kimi-code") orelse return error.KimiCodeNotRegistered;
    // The page the dialog offers first for the default channel.
    try std.testing.expectEqualStrings("cn", profile.defaultKeyPage(profile.default_channel).?.id.slice());
    try std.testing.expectEqualStrings("https://api.kimi.com/coding/v1/models", profile.keyPage("cn").?.check_url.?);

    var io_runtime = @import("platform").signal.threadedIo(case.arena.allocator(), .{});
    defer io_runtime.deinit();
    const prepared = try provider_login.prepareApiKey(profile, "cn", null, " " ++ SUBSCRIPTION_KEY ++ "\n", .{ .state_root = case.root });
    _ = try prepared.run(std.testing.allocator, io_runtime.io(), cc.api_oauth_login.stderrNotify(), null);

    const captured = check.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expectEqualStrings("GET /coding/v1/models HTTP/1.1", requestLine(captured));
    try std.testing.expectEqualStrings("Bearer " ++ SUBSCRIPTION_KEY, (headerValue(captured, "authorization") orelse return error.NoAuthorizationHeader));

    const kimi_code = Slug.lit("kimi-code");
    var stored = (try key_store.load(std.testing.allocator, case.root, kimi_code)) orelse return error.KeyNotStored;
    defer stored.deinit();
    try std.testing.expectEqualStrings(SUBSCRIPTION_KEY, stored.secret);
    try std.testing.expectEqual(cc.provider_credential.CredentialKind.kimi_code_api_key, stored.kind);
    try std.testing.expectEqualStrings("cn", stored.page.?);

    const path = try key_store.pathFor(case.arena.allocator(), case.root, kimi_code);
    try std.testing.expect(std.mem.endsWith(u8, path, "/keys/kimi-code.json"));
    if (@import("builtin").os.tag != .windows) {
        const path_z = try case.arena.allocator().dupeZ(u8, path);
        const fd = try pfs.openZ(path_z, .{ .ACCMODE = .RDONLY }, 0);
        defer pfs.close(fd);
        try std.testing.expectEqual(@as(u32, 0o600), (try pfs.fileInfo(fd)).mode & 0o777);
    }

    // The stored key starts Kimi Code with no variable set, and only Kimi Code.
    const secret = try case.secretFor("kimi-code");
    defer std.testing.allocator.free(secret);
    try std.testing.expectEqualStrings(SUBSCRIPTION_KEY, secret);
    try std.testing.expectError(error.MissingCredentials, case.secretFor("kimi"));
    try std.testing.expect(try key_store.load(std.testing.allocator, case.root, Slug.lit("kimi")) == null);
}
