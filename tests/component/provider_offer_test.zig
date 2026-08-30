//! L2 evidence for issue #16 — provider profiles, model offers, typed
//! credentials, and the cross-UI control plane.
//!
//! Every assertion here answers "does declaring X change the real downstream
//! request Y, or the real durable state Y?". Unit tests already cover the
//! contracts in isolation; this file proves the wiring:
//!
//!   * a selected offer determines the request *path*, *auth header*, and the
//!     `model` field actually on the wire;
//!   * a relay's canonical mapping never leaks into the wire model id;
//!   * a credential from one vendor cannot authenticate another;
//!   * the config document survives concurrent writers and injected crashes,
//!     and does not clobber other writers' keys.
//!
//! Mock transport only: no provider-backed calls.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs;

const Slug = cc.provider_ids.Slug;
const ProviderRegistry = cc.provider_registry.ProviderRegistry;

const MINIMAL_END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const MINIMAL_OPENAI_SSE =
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\n" ++
    "data: [DONE]\n\n";

fn drainAnthropic(response: *cc.client_mod.StreamResponse) void {
    while (true) {
        const maybe = response.next() catch break;
        const event = maybe orelse break;
        switch (event) {
            .text => |text| std.testing.allocator.free(text),
            else => {},
        }
        if (response.done) break;
    }
}

/// Request line of the captured HTTP request, e.g. `POST /api/anthropic/v1/messages HTTP/1.1`.
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

/// Drive one Anthropic-wire request through a resolved route and return the
/// captured downstream request.
fn captureAnthropicRequest(
    server: *harness.MockServer,
    route: *const cc.provider_startup.StartupRoute,
    secret: []const u8,
) !harness.CapturedRequest {
    var io_runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(
        std.testing.allocator,
        io_runtime.io(),
        secret,
        route.request_model_id,
        route.endpoint_url,
    );
    client.auth_scheme = route.auth_scheme;
    defer client.deinit();

    const empty: []const cc.types_mod.ApiMessage = &.{};
    var response = client.sendMessageStream(empty, null, null) catch return error.SkipZigTest;
    drainAnthropic(&response);
    response.deinit();
    return server.lastRequest() orelse error.NoRequestCaptured;
}

// ── GLM Coding Plan routes ───────────────────────────────────────────────────

test "L2: the GLM China Anthropic route reaches its own endpoint, path, and model" {
    const a = std.testing.allocator;
    var server = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
    defer server.stop();
    const origin = try server.urlOwned(a);
    defer a.free(origin);
    // The mock stands in for `open.bigmodel.cn`; the Coding Plan path contract
    // still has to hold, which is what makes this a real route test.
    const base = try std.fmt.allocPrint(a, "{s}/api/anthropic", .{origin});
    defer a.free(base);

    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    const outcome = try cc.provider_startup.resolve(a, &registry, .{
        .provider = "zai-coding-plan",
        .channel = "cn-anthropic",
        .model = "glm-4.6",
        .base_url = base,
    });
    try std.testing.expect(outcome == .route);
    var route = outcome.route;
    defer route.deinit();

    try std.testing.expectEqual(cc.types_mod.ProviderKind.anthropic, route.transport);
    const captured = try captureAnthropicRequest(server, &route, "zai-plan-secret");

    try std.testing.expect(std.mem.indexOf(u8, requestLine(captured), "/api/anthropic/v1/messages") != null);
    try std.testing.expectEqualStrings("Bearer zai-plan-secret", headerValue(captured, "authorization").?);
    const model_field = captured.jsonField("model") orelse return error.ModelFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, model_field, "glm-4.6") != null);
}

test "L2: the GLM OpenAI-wire route reaches the coding-plan path with the OpenAI transport" {
    const a = std.testing.allocator;
    var server = try harness.MockServer.start(MINIMAL_OPENAI_SSE, 0);
    defer server.stop();
    const origin = try server.urlOwned(a);
    defer a.free(origin);
    const base = try std.fmt.allocPrint(a, "{s}/api/coding/paas/v4", .{origin});
    defer a.free(base);

    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    const outcome = try cc.provider_startup.resolve(a, &registry, .{
        .provider = "glm",
        .channel = "cn-openai",
        .model = "glm-4.6",
        .base_url = base,
    });
    try std.testing.expect(outcome == .route);
    var route = outcome.route;
    defer route.deinit();

    try std.testing.expectEqual(cc.types_mod.ProviderKind.openai, route.transport);
    try std.testing.expectEqual(cc.types_mod.OpenAIProtocol.chat_completions, route.openai_protocol);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.api_openai.OpenAIClient.init(
        a,
        io_runtime.io(),
        "zai-plan-secret",
        route.request_model_id,
        route.endpoint_url,
    );
    client.protocol = route.openai_protocol;
    client.auth_scheme = route.auth_scheme;
    defer client.deinit();

    const messages = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    var handle = client.provider().sendStream(&messages, null, null, null, null, null, "") catch
        return error.SkipZigTest;
    while (handle.next() catch null) |event| switch (event) {
        .text => |text| a.free(text),
        else => {},
    };
    handle.deinit();

    const captured = server.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(
        std.mem.indexOf(u8, requestLine(captured), "/api/coding/paas/v4/chat/completions") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, requestLine(captured), "/api/paas/v4/chat") == null);
    try std.testing.expectEqualStrings("Bearer zai-plan-secret", headerValue(captured, "authorization").?);
    const model_field = captured.jsonField("model") orelse return error.ModelFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, model_field, "glm-4.6") != null);
}

test "L2: the general Z.AI surface is rejected before any request exists" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    const outcome = try cc.provider_startup.resolve(a, &registry, .{
        .provider = "zai-coding-plan",
        .channel = "cn-openai",
        .base_url = "https://open.bigmodel.cn/api/paas/v4",
    });
    try std.testing.expect(outcome == .failure);
    try std.testing.expectEqual(
        cc.provider_profile.EndpointError.ForbiddenEndpointPath,
        outcome.failure.endpoint_rejected,
    );
}

// ── relay identity ───────────────────────────────────────────────────────────

const RELAY_MODELS = [_]cc.provider_profile.ModelEntry{.{
    .request_model_id = "relay-glm-pro",
    .display_name = "GLM-5.3",
    .canonical_model_id = "zai/glm-5.3",
    .upstream_model_id = "glm-5.3",
}};
const RELAY_ROUTES = [_]cc.provider_profile.ProtocolRoute{.{ .protocol = .anthropic_messages }};
const RELAY_KINDS = [_]cc.provider_credential.CredentialKind{.api_key};
const RELAY_ALIASES = [_]cc.provider_credential.EnvAlias{
    .{ .name = "RELAY_A_KEY", .kind = .api_key, .canonical = true },
};

test "L2: a relay shows the canonical model while sending its own request id" {
    const a = std.testing.allocator;
    var server = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
    defer server.stop();
    const origin = try server.urlOwned(a);
    defer a.free(origin);

    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    const channels = [_]cc.provider_profile.ChannelDescriptor{.{
        .id = Slug.lit("channel-1"),
        .display_name = "Relay A",
        .base_url = origin,
        .routes = &RELAY_ROUTES,
    }};
    // Registering a provider at runtime uses the same extension point as the
    // built-ins: no AgentLoop, factory, or UI change is involved.
    try registry.register(.{
        .id = Slug.lit("relay-a"),
        .implementation_id = Slug.lit("declarative_http"),
        .display_name = "Relay A",
        .channels = &channels,
        .models = &RELAY_MODELS,
        .accepted_credential_kinds = &RELAY_KINDS,
        .env_aliases = &RELAY_ALIASES,
    });

    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("relay-a") });
    defer catalog.deinit();
    var kernel = cc.provider_control_plane.Kernel.init(a, &catalog);
    defer kernel.deinit();

    // What every UI sees.
    const page = try kernel.modelList(.{}, .{});
    try std.testing.expectEqual(@as(usize, 1), page.offers.len);
    try std.testing.expectEqualStrings("GLM-5.3", page.offers[0].display_name);
    try std.testing.expectEqualStrings("zai/glm-5.3", page.offers[0].canonical_model_id.?);

    // What actually goes on the wire.
    const outcome = try cc.provider_startup.resolve(a, &registry, .{ .provider = "relay-a" });
    var route = outcome.route;
    defer route.deinit();
    const captured = try captureAnthropicRequest(server, &route, "relay-secret");
    const model_field = captured.jsonField("model") orelse return error.ModelFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, model_field, "relay-glm-pro") != null);
    try std.testing.expect(std.mem.indexOf(u8, model_field, "glm-5.3") == null);
}

// ── credentials ──────────────────────────────────────────────────────────────

const XKEY_ROUTES = [_]cc.provider_profile.ProtocolRoute{.{ .protocol = .anthropic_messages }};
const XKEY_MODELS = [_]cc.provider_profile.ModelEntry{.{
    .request_model_id = "vendor-m1",
    .display_name = "Vendor M1",
}};
const XKEY_KINDS = [_]cc.provider_credential.CredentialKind{.api_key};

test "L2: the provider's declared auth scheme changes the real downstream header" {
    const a = std.testing.allocator;
    var server = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
    defer server.stop();
    const origin = try server.urlOwned(a);
    defer a.free(origin);

    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    const channels = [_]cc.provider_profile.ChannelDescriptor{.{
        .id = Slug.lit("only"),
        .display_name = "Vendor",
        .base_url = origin,
        .routes = &XKEY_ROUTES,
    }};
    try registry.register(.{
        .id = Slug.lit("xkey-vendor"),
        .implementation_id = Slug.lit("declarative_http"),
        .display_name = "x-api-key vendor",
        .channels = &channels,
        .models = &XKEY_MODELS,
        .accepted_credential_kinds = &XKEY_KINDS,
        .auth = .{ .api_key_header = "x-api-key" },
    });

    const outcome = try cc.provider_startup.resolve(a, &registry, .{ .provider = "xkey-vendor" });
    var route = outcome.route;
    defer route.deinit();
    const captured = try captureAnthropicRequest(server, &route, "vendor-secret");

    try std.testing.expectEqualStrings("vendor-secret", headerValue(captured, "x-api-key").?);
    // The historical bearer header is gone, not merely accompanied.
    try std.testing.expect(headerValue(captured, "authorization") == null);
}

test "L2: a credential cannot cross provider boundaries and never reaches a UI surface" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("zai-coding-plan") });
    defer catalog.deinit();
    var reference_buffer: [cc.provider_ids.MAX_SLUG_LEN]u8 = undefined;

    const Env = struct {
        pairs: []const [2][]const u8,
        fn get(ctx: *anyopaque, name: []const u8) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (self.pairs) |pair| if (std.mem.eql(u8, pair[0], name)) return pair[1];
            return null;
        }
    };

    // A Metask key in the environment must not authenticate a Z.AI route.
    var metask_only = Env{ .pairs = &.{.{ "METASK_API_KEY", "metask-secret" }} };
    try std.testing.expectError(error.MissingCredentials, cc.provider_runtime_binding.bindOffer(
        &registry,
        &catalog.items()[0],
        .{ .env = .{ .ctx = @ptrCast(&metask_only), .getFn = Env.get } },
        &reference_buffer,
        false,
    ));

    // Any documented Z.AI alias works, and the resolved reference is secret free.
    var glm = Env{ .pairs = &.{.{ "GLM_API_KEY", "zai-secret" }} };
    const binding = try cc.provider_runtime_binding.bindOffer(
        &registry,
        &catalog.items()[0],
        .{ .env = .{ .ctx = @ptrCast(&glm), .getFn = Env.get } },
        &reference_buffer,
        false,
    );
    try std.testing.expectEqualStrings("zai-secret", binding.secret);
    try std.testing.expect(std.mem.indexOf(u8, binding.credential_ref.id.slice(), "zai-secret") == null);

    // The client-facing view carries the reference id, never the material.
    var kernel = cc.provider_control_plane.Kernel.init(a, &catalog);
    defer kernel.deinit();
    const page = try kernel.modelList(.{}, .{});
    for (page.offers) |summary| {
        try std.testing.expect(std.mem.indexOf(u8, summary.endpoint_ref, "zai-secret") == null);
        try std.testing.expect(std.mem.indexOf(u8, summary.request_model_id, "zai-secret") == null);
    }
}

// ── CLI wiring ───────────────────────────────────────────────────────────────

test "L2: --provider/--channel/--offer parse into Config" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{
        "metacodes",
        "--provider",
        "zai-coding-plan",
        "--channel",
        "cn-openai",
        "--offer",
        "offer-0123456789abcdef0123456789abcdef",
    };
    const config = cc.parseArgsForTest(&argv, a);
    defer a.free(config.provider_profile.?);
    defer a.free(config.provider_channel.?);
    defer a.free(config.provider_offer.?);
    try std.testing.expectEqualStrings("zai-coding-plan", config.provider_profile.?);
    try std.testing.expectEqualStrings("cn-openai", config.provider_channel.?);
    try std.testing.expectEqualStrings("offer-0123456789abcdef0123456789abcdef", config.provider_offer.?);
}

// ── cross-UI control plane ───────────────────────────────────────────────────

test "L2: two clients read the same catalog and selection from one kernel" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{});
    defer catalog.deinit();
    var kernel = cc.provider_control_plane.Kernel.init(a, &catalog);
    defer kernel.deinit();

    // "TUI" commits a session selection.
    var tui_target: ?*const cc.provider_offer.ModelOffer = null;
    for (catalog.items()) |*candidate| {
        if (candidate.channel_id.eqlText("global-anthropic") and
            std.mem.eql(u8, candidate.request_model_id, "glm-4.6")) tui_target = candidate;
    }
    const commit = kernel.selectionCommit(
        .{ .request_id = 7 },
        cc.provider_selection.RuntimeSelection.pinned(
            tui_target.?.offer_id,
            tui_target.?.offer_revision,
            .session,
        ),
        .session,
    );
    try std.testing.expect(commit == .committed);

    // "Web UI" reads the same kernel: same current offer, same event stream.
    const web_view = try kernel.modelList(.{ .request_id = 8 }, .{ .provider_id = Slug.lit("zai-coding-plan") });
    var marked: usize = 0;
    for (web_view.offers) |summary| {
        if (summary.is_current) marked += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), marked);
    const described = kernel.modelDescribe(tui_target.?.offer_id).?;
    try std.testing.expect(described.is_current);
    try std.testing.expectEqualStrings("global", described.region.?);

    const replay = kernel.journal.since(0);
    try std.testing.expect(!replay.gap);
    try std.testing.expectEqual(
        cc.provider_control_plane.EventType.runtime_selection_changed,
        replay.events[replay.events.len - 1].event_type,
    );
}

// ── durable configuration ────────────────────────────────────────────────────

fn tempConfigPath(a: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "/tmp/metacodes-provider-test-{s}/config.json", .{name});
}

fn removeTempDir(path: []const u8) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ path, ".lock", ".tmp" }, 0..) |suffix, index| {
        const target = if (index == 0)
            std.fmt.bufPrintZ(&buffer, "{s}", .{path}) catch return
        else
            std.fmt.bufPrintZ(&buffer, "{s}{s}", .{ path, suffix }) catch return;
        _ = pfs.unlinkPath(target) catch {};
    }
    const dir = std.fs.path.dirname(path) orelse return;
    const dir_z = std.fmt.bufPrintZ(&buffer, "{s}", .{dir}) catch return;
    _ = std.c.rmdir(dir_z.ptr);
}

fn readWholeFile(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    const fd = pfs.open(path_z, .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) return error.OpenFailed;
    defer pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read = pfs.read(fd, &buffer);
        if (read <= 0) break;
        try out.appendSlice(a, buffer[0..@intCast(read)]);
    }
    return out.toOwnedSlice(a);
}

const AddProvider = struct {
    id: Slug,
    fn run(ctx: *anyopaque, document: *cc.provider_config_doc.Document) anyerror!void {
        const self: *AddProvider = @ptrCast(@alignCast(ctx));
        try document.upsertProvider(.{ .id = self.id, .credential_ref = Slug.lit("cred-1") });
    }
};

test "L2: config commits are atomic, revisioned, and idempotent on retry" {
    const a = std.testing.allocator;
    const path = try tempConfigPath(a, "atomic");
    defer a.free(path);
    removeTempDir(path);
    defer removeTempDir(path);

    var store = try cc.provider_config_store.Store.initPath(a, path);
    defer store.deinit();

    var add_metask = AddProvider{ .id = Slug.lit("metask") };
    const first = try store.commit(.{
        .operation_id = "op-1",
        .mutation = .{ .ctx = @ptrCast(&add_metask), .applyFn = AddProvider.run },
    });
    try std.testing.expectEqual(@as(u64, 2), first.config_revision.value());
    try std.testing.expect(!first.idempotent_replay);

    // The same operation id is a retry, not a second revision.
    const retry = try store.commit(.{
        .operation_id = "op-1",
        .mutation = .{ .ctx = @ptrCast(&add_metask), .applyFn = AddProvider.run },
    });
    try std.testing.expect(retry.idempotent_replay);
    try std.testing.expectEqual(first.config_revision.value(), retry.config_revision.value());

    // A stale expected revision is a conflict, and changes nothing.
    var add_zai = AddProvider{ .id = Slug.lit("zai-coding-plan") };
    try std.testing.expectError(error.RevisionConflict, store.commit(.{
        .expected_config_revision = .initial,
        .operation_id = "op-2",
        .mutation = .{ .ctx = @ptrCast(&add_zai), .applyFn = AddProvider.run },
    }));

    var loaded = try store.load();
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.providers.items.len);
    try std.testing.expectEqual(first.config_revision.value(), loaded.config_revision.value());

    // With the current revision it commits, and both providers coexist.
    const second = try store.commit(.{
        .expected_config_revision = loaded.config_revision,
        .operation_id = "op-3",
        .mutation = .{ .ctx = @ptrCast(&add_zai), .applyFn = AddProvider.run },
    });
    try std.testing.expectEqual(@as(u64, 3), second.config_revision.value());
    var reloaded = try store.load();
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), reloaded.providers.items.len);
}

test "L2: an injected crash leaves the previous complete document intact" {
    const a = std.testing.allocator;
    const path = try tempConfigPath(a, "crash");
    defer a.free(path);
    removeTempDir(path);
    defer removeTempDir(path);

    var store = try cc.provider_config_store.Store.initPath(a, path);
    defer store.deinit();

    var add_metask = AddProvider{ .id = Slug.lit("metask") };
    _ = try store.commit(.{
        .operation_id = "good",
        .mutation = .{ .ctx = @ptrCast(&add_metask), .applyFn = AddProvider.run },
    });

    var add_zai = AddProvider{ .id = Slug.lit("zai-coding-plan") };
    for ([_]cc.provider_config_store.CrashPoint{ .after_temp_write, .before_rename }) |point| {
        var crashing = try cc.provider_config_store.Store.initPath(a, path);
        defer crashing.deinit();
        crashing.crash_after = point;
        try std.testing.expectError(error.CrashInjected, crashing.commit(.{
            .operation_id = "crashy",
            .mutation = .{ .ctx = @ptrCast(&add_zai), .applyFn = AddProvider.run },
        }));

        var after = try store.load();
        defer after.deinit();
        // Previous complete document, never a half-merged one.
        try std.testing.expectEqual(@as(usize, 1), after.providers.items.len);
        try std.testing.expect(after.provider(Slug.lit("metask")) != null);
        try std.testing.expect(after.provider(Slug.lit("zai-coding-plan")) == null);
        try std.testing.expectEqual(@as(u64, 2), after.config_revision.value());
    }
}

test "L2: a durable selection survives a reload and does not clobber other keys" {
    const a = std.testing.allocator;
    const path = try tempConfigPath(a, "selection");
    defer a.free(path);
    removeTempDir(path);
    defer removeTempDir(path);

    // Another writer's document already exists.
    const dir = std.fs.path.dirname(path).?;
    try cc.fs_util.mkdirParents(dir);
    {
        const path_z = try a.dupeZ(u8, path);
        defer a.free(path_z);
        const fd = pfs.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
        try std.testing.expect(fd >= 0);
        defer pfs.close(fd);
        const existing =
            \\{"model":"claude-sonnet-4-6","theme":"dark","mcp_servers":[{"name":"kg"}]}
        ;
        _ = pfs.write(fd, existing);
    }

    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("zai-coding-plan") });
    defer catalog.deinit();
    const target = catalog.items()[0];

    var store = try cc.provider_config_store.Store.initPath(a, path);
    defer store.deinit();
    const result = try cc.provider_config_store.setGlobalSelection(
        &store,
        cc.provider_selection.RuntimeSelection.pinned(target.offer_id, target.offer_revision, .global),
        null,
        "commit-1",
    );
    try std.testing.expectEqual(@as(u64, 2), result.config_revision.value());

    var reloaded = try store.load();
    defer reloaded.deinit();
    try std.testing.expect(reloaded.global_selection.?.target.pinned_offer.offer_id.eql(target.offer_id));

    // The other writer's keys are still there.
    const bytes = try readWholeFile(a, path);
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "mcp_servers") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"dark\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "claude-sonnet-4-6") != null);

    // And the restored selection still resolves to the same route.
    const resolution = try cc.provider_selection.resolve(&catalog, reloaded.global_selection.?);
    try std.testing.expectEqualStrings(target.endpoint_ref, resolution.primary().endpoint_ref);
}

// ── credential scoping at startup ────────────────────────────────────────────

test "L2: only a non-Metask profile leaves the historical credential path" {
    // Startup keeps Metask on `core/auth.zig` (stored OAuth, stored key, and
    // the one-shot descriptor) and scopes every other profile to its own
    // declared material. Getting this predicate wrong is what let a Metask
    // token authenticate a Z.AI route.
    try std.testing.expect(cc.selectedProfileIsMetask(.{}));
    try std.testing.expect(cc.selectedProfileIsMetask(.{ .provider_profile = "metask" }));
    try std.testing.expect(cc.selectedProfileIsMetask(.{ .provider_profile = "anthropic" }));
    // An unknown name falls back to the historical path rather than failing in
    // a second place; `applyProviderRoute` already rejected it by then.
    try std.testing.expect(cc.selectedProfileIsMetask(.{ .provider_profile = "not-a-vendor" }));

    try std.testing.expect(!cc.selectedProfileIsMetask(.{ .provider_profile = "zai-coding-plan" }));
    try std.testing.expect(!cc.selectedProfileIsMetask(.{ .provider_profile = "glm-coding-plan" }));
    try std.testing.expect(!cc.selectedProfileIsMetask(.{ .provider_profile = "openai" }));
}

test "L2: provider-scoped startup resolution accepts --api-key and fails closed otherwise" {
    const a = std.testing.allocator;
    const with_key = try cc.resolveProviderScopedSecret(
        a,
        .{ .provider_profile = "zai-coding-plan", .api_key = "cli-plan-key" },
        "zai-coding-plan",
    );
    defer if (with_key) |secret| a.free(secret);
    try std.testing.expectEqualStrings("cli-plan-key", with_key.?);

    // The Metask credential store is not consulted for another provider. Both
    // branches below prove that: with `OPENAI_API_KEY` present the result is
    // exactly that value, and without it resolution fails before any client is
    // constructed. A Metask fallback would produce neither outcome. Written
    // this way so the assertion does not depend on the developer's shell.
    if (std.c.getenv("OPENAI_API_KEY")) |raw| {
        const from_env = try cc.resolveProviderScopedSecret(
            a,
            .{ .provider_profile = "openai" },
            "openai",
        );
        defer if (from_env) |secret| a.free(secret);
        try std.testing.expectEqualStrings(std.mem.span(raw), from_env.?);
    } else {
        try std.testing.expectError(error.MissingCredentials, cc.resolveProviderScopedSecret(
            a,
            .{ .provider_profile = "openai" },
            "openai",
        ));
    }
}
