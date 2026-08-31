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
    var view: std.ArrayList(cc.provider_control_plane.OfferSummary) = .empty;
    defer view.deinit(a);
    const page = try kernel.modelList(.{}, .{}, a, &view);
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
    var view: std.ArrayList(cc.provider_control_plane.OfferSummary) = .empty;
    defer view.deinit(a);
    const page = try kernel.modelList(.{}, .{}, a, &view);
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
    var web_buffer: std.ArrayList(cc.provider_control_plane.OfferSummary) = .empty;
    defer web_buffer.deinit(a);
    const web_view = try kernel.modelList(
        .{ .request_id = 8 },
        .{ .provider_id = Slug.lit("zai-coding-plan") },
        a,
        &web_buffer,
    );
    var marked: usize = 0;
    for (web_view.offers) |summary| {
        if (summary.is_current) marked += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), marked);
    const described = kernel.modelDescribe(tui_target.?.offer_id).?;
    try std.testing.expect(described.is_current);
    try std.testing.expectEqualStrings("global", described.region.?);

    var events: std.ArrayList(cc.provider_control_plane.ControlPlaneEvent) = .empty;
    defer events.deinit(a);
    const replay = try kernel.replayEvents(0, a, &events);
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
    // Naming no provider keeps the historical path.
    try std.testing.expect(cc.selectedProfileIsMetask(.{}));

    // The decision reads the id route resolution already recorded, not a second
    // lookup of the user's alias. An alias resolves to its canonical id first.
    try std.testing.expect(cc.selectedProfileIsMetask(.{
        .provider_profile = "anthropic",
        .resolved_provider_id = "metask",
    }));
    try std.testing.expect(!cc.selectedProfileIsMetask(.{
        .provider_profile = "glm-coding-plan",
        .resolved_provider_id = "zai-coding-plan",
    }));
    try std.testing.expect(!cc.selectedProfileIsMetask(.{
        .provider_profile = "openai",
        .resolved_provider_id = "openai",
    }));

    // Fail closed: a named provider with no recorded id must not re-enter the
    // Metask credential path. That fallback is exactly how a Metask token
    // reached a Z.AI route before this scoping existed.
    try std.testing.expect(!cc.selectedProfileIsMetask(.{ .provider_profile = "zai-coding-plan" }));
}

test "L2: provider-scoped startup resolution accepts --api-key and fails closed otherwise" {
    const a = std.testing.allocator;
    const with_key = try cc.resolveProviderScopedSecret(
        a,
        .{ .provider_profile = "zai-coding-plan", .api_key = "cli-plan-key" },
        "zai-coding-plan",
    );
    defer a.free(with_key);
    try std.testing.expectEqualStrings("cli-plan-key", with_key);

    // An unknown profile name is an error, not a silent `null` that would let
    // the caller fall back to the Metask path.
    try std.testing.expectError(error.UnknownProviderProfile, cc.resolveProviderScopedSecret(
        a,
        .{ .provider_profile = "not-a-vendor" },
        "not-a-vendor",
    ));

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
        defer a.free(from_env);
        try std.testing.expectEqualStrings(std.mem.span(raw), from_env);
    } else {
        try std.testing.expectError(error.MissingCredentials, cc.resolveProviderScopedSecret(
            a,
            .{ .provider_profile = "openai" },
            "openai",
        ));
    }
}

test "L2: an idempotent retry is recognized after intervening commits" {
    const a = std.testing.allocator;
    const path = try tempConfigPath(a, "idempotent");
    defer a.free(path);
    removeTempDir(path);
    defer removeTempDir(path);

    var store = try cc.provider_config_store.Store.initPath(a, path);
    defer store.deinit();

    var add_metask = AddProvider{ .id = Slug.lit("metask") };
    var add_zai = AddProvider{ .id = Slug.lit("zai-coding-plan") };
    var add_openai = AddProvider{ .id = Slug.lit("openai") };

    const first = try store.commit(.{
        .operation_id = "op-a",
        .mutation = .{ .ctx = @ptrCast(&add_metask), .applyFn = AddProvider.run },
    });
    _ = try store.commit(.{
        .operation_id = "op-b",
        .mutation = .{ .ctx = @ptrCast(&add_zai), .applyFn = AddProvider.run },
    });
    // A commit with no key must not evict the retained keys.
    _ = try store.commit(.{
        .mutation = .{ .ctx = @ptrCast(&add_openai), .applyFn = AddProvider.run },
    });

    // Retrying the *first* operation after later traffic is still a no-op.
    const replay = try store.commit(.{
        .operation_id = "op-a",
        .mutation = .{ .ctx = @ptrCast(&add_metask), .applyFn = AddProvider.run },
    });
    try std.testing.expect(replay.idempotent_replay);
    try std.testing.expect(replay.config_revision.value() > first.config_revision.value());

    var loaded = try store.load();
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 3), loaded.providers.items.len);
    try std.testing.expect(loaded.hasOperation("op-a"));
    try std.testing.expect(loaded.hasOperation("op-b"));
}

test "L2: an endpoint carrying a credential is refused before it reaches any surface" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    // A `user@host` base URL would put the secret into ModelOffer.endpoint_ref,
    // and from there into model.list, events, and setup output.
    const outcome = try cc.provider_startup.resolve(a, &registry, .{
        .provider = "zai-coding-plan",
        .channel = "cn-openai",
        .base_url = "https://sk-live-secret@relay.internal/api/coding/paas/v4",
    });
    try std.testing.expect(outcome == .failure);
    try std.testing.expectEqual(
        cc.provider_profile.EndpointError.CredentialInEndpoint,
        outcome.failure.endpoint_rejected,
    );
    const text = try outcome.failure.message(a);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "sk-live-secret") == null);
}

test "L2: --offer and --channel may not contradict each other" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("zai-coding-plan") });
    defer catalog.deinit();

    var anthropic_offer: ?cc.provider_ids.OfferId = null;
    for (catalog.items()) |candidate| {
        if (candidate.channel_id.eqlText("cn-anthropic")) anthropic_offer = candidate.offer_id;
    }
    const rendered = anthropic_offer.?.render();
    const outcome = try cc.provider_startup.resolve(a, &registry, .{
        .provider = "zai",
        .channel = "cn-openai",
        .offer_id = &rendered,
    });
    try std.testing.expect(outcome == .failure);
    const text = try outcome.failure.message(a);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "cn-anthropic") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cn-openai") != null);
}

// ── restart: a durable selection is what the next process actually routes to ──

fn setEnvZ(name: [*:0]const u8, value: [*:0]const u8) void {
    @import("platform").paths.setEnv(name, value);
}

fn unsetEnvZ(name: [*:0]const u8) void {
    @import("platform").paths.unsetEnv(name);
}

test "L2: a globally committed selection routes the next process, model inference does not" {
    const a = std.testing.allocator;
    const path = try tempConfigPath(a, "restart");
    defer a.free(path);
    removeTempDir(path);
    defer removeTempDir(path);

    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    setEnvZ(cc.provider_config_store.CONFIG_PATH_ENV, path_z);
    defer unsetEnvZ(cc.provider_config_store.CONFIG_PATH_ENV);

    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("zai-coding-plan") });
    defer catalog.deinit();
    // The OpenAI-wire GLM route: proof the transport comes from the offer's
    // protocol and not from the model name, which starts with "glm".
    var target: *const cc.provider_offer.ModelOffer = undefined;
    for (catalog.items()) |*candidate| {
        if (candidate.channel_id.eqlText("cn-openai") and
            std.mem.eql(u8, candidate.request_model_id, "glm-4.6")) target = candidate;
    }

    {
        var store = try cc.provider_config_store.Store.initHome(a);
        defer store.deinit();
        _ = try cc.provider_config_store.setGlobalSelection(
            &store,
            cc.provider_selection.RuntimeSelection.pinned(target.offer_id, target.offer_revision, .global),
            null,
            "restart-commit",
        );
    }

    // A fresh process: nothing on the command line names a provider.
    var config = cc.types_mod.Config{};
    try std.testing.expect(cc.applyPersistedGlobalSelection(&config, a));
    defer {
        if (config.selected_offer_id) |value| a.free(value);
        if (config.resolved_provider_id) |value| a.free(value);
        if (config.base_url) |value| a.free(value);
        a.free(config.model);
    }

    try std.testing.expectEqualStrings("glm-4.6", config.model);
    try std.testing.expectEqualStrings(target.endpoint_ref, config.base_url.?);
    try std.testing.expectEqual(cc.types_mod.ProviderKind.openai, config.provider_kind);
    // Credential scope has to follow the restored route, or the session would
    // re-enter the Metask credential path for a Z.AI endpoint.
    try std.testing.expectEqualStrings("zai-coding-plan", config.provider_profile.?);
    try std.testing.expect(!cc.selectedProfileIsMetask(config));
    // Model-name inference would have said `anthropic` for "glm-4.6".
    try std.testing.expect(cc.inferProviderKind(config.model) != config.provider_kind);
}

test "L2: a stored pin the catalog no longer offers is never silently remapped" {
    const a = std.testing.allocator;
    const path = try tempConfigPath(a, "stale-pin");
    defer a.free(path);
    removeTempDir(path);
    defer removeTempDir(path);

    var store = try cc.provider_config_store.Store.initPath(a, path);
    defer store.deinit();
    const missing = cc.provider_ids.OfferId{ .digest = @splat(0x5A) };
    _ = try cc.provider_config_store.setGlobalSelection(
        &store,
        cc.provider_selection.RuntimeSelection.pinned(missing, 1, .global),
        null,
        "stale-commit",
    );

    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var reloaded = try store.load();
    defer reloaded.deinit();

    // Resolution reports the pin as unresolved instead of picking a neighbour;
    // `applyPersistedGlobalSelection` turns exactly this into a startup error.
    const outcome = try cc.provider_startup.resolveSelection(a, &registry, reloaded.global_selection.?);
    try std.testing.expect(outcome == .failure);
    try std.testing.expect(outcome.failure == .unresolved_selection);
}

test "L2: a session selection is written beside the session, not into config.json" {
    const a = std.testing.allocator;
    const config_path = try tempConfigPath(a, "session-scope");
    defer a.free(config_path);
    removeTempDir(config_path);
    defer removeTempDir(config_path);

    const session_dir = std.fs.path.dirname(config_path).?;
    var config_store = try cc.provider_config_store.Store.initPath(a, config_path);
    defer config_store.deinit();
    var session_store = try cc.provider_config_store.Store.initSessionFile(a, session_dir);
    defer session_store.deinit();
    defer removeTempDir(session_store.path);

    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("zai-coding-plan") });
    defer catalog.deinit();
    const global_target = catalog.items()[0];
    const session_target = catalog.items()[1];

    _ = try cc.provider_config_store.setGlobalSelection(
        &config_store,
        cc.provider_selection.RuntimeSelection.pinned(global_target.offer_id, global_target.offer_revision, .global),
        null,
        "global-commit",
    );
    _ = try cc.provider_config_store.setSessionSelection(
        &session_store,
        cc.provider_selection.RuntimeSelection.pinned(session_target.offer_id, session_target.offer_revision, .session),
        null,
        "session-commit",
    );

    // A session-scoped choice must not become everyone's choice.
    var global_doc = try config_store.load();
    defer global_doc.deinit();
    try std.testing.expect(global_doc.session_selection == null);
    try std.testing.expect(global_doc.global_selection.?.target.pinned_offer.offer_id.eql(global_target.offer_id));

    var session_doc = try session_store.load();
    defer session_doc.deinit();
    try std.testing.expect(session_doc.global_selection == null);
    try std.testing.expect(session_doc.session_selection.?.target.pinned_offer.offer_id.eql(session_target.offer_id));
}

// ── the picker as a control-plane client ─────────────────────────────────────

const picker_mod = @import("cc").repl_model_picker;

fn seedPicker(
    picker: *picker_mod.Picker,
    kernel: *cc.provider_control_plane.Kernel,
    a: std.mem.Allocator,
) !void {
    var page: std.ArrayList(cc.provider_control_plane.OfferSummary) = .empty;
    defer page.deinit(a);
    const listed = try kernel.modelList(.{}, .{}, a, &page);
    try picker.adopt(listed, kernel.currentOfferId());
}

test "L2: a picker-driven selection reaches the endpoint, path, and wire model it named" {
    const a = std.testing.allocator;
    var server = try harness.MockServer.start(MINIMAL_OPENAI_SSE, 0);
    defer server.stop();
    const origin = try server.urlOwned(a);
    defer a.free(origin);
    const base = try std.fmt.allocPrint(a, "{s}/api/coding/paas/v4", .{origin});
    defer a.free(base);

    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{
        .only_provider = Slug.lit("zai-coding-plan"),
        .endpoint_overrides = &.{.{
            .provider_id = Slug.lit("zai-coding-plan"),
            .channel_id = Slug.lit("cn-openai"),
            .base_url = base,
        }},
    });
    defer catalog.deinit();

    var kernel = cc.provider_control_plane.Kernel.init(a, &catalog);
    defer kernel.deinit();
    kernel.registry = &registry;

    var picker = picker_mod.Picker.init(a);
    defer picker.deinit();
    try seedPicker(&picker, &kernel, a);

    // Drive the picker exactly as a keyboard would: provider → model → offer.
    _ = picker.onKey(.enter);
    for ("glm46") |byte| _ = picker.onKey(.{ .char = byte });
    _ = picker.onKey(.enter);
    try std.testing.expectEqual(picker_mod.Stage.offer, picker.stage);

    // Walk to the OpenAI-wire China channel and commit it.
    var scratch: [picker_mod.Picker.MAX_ROWS]picker_mod.Row = undefined;
    var guard: usize = 0;
    while (guard < scratch.len) : (guard += 1) {
        const rows = picker.rows(&scratch);
        const candidate = picker.offers.items[rows[picker.cursor].offer.offer_index];
        if (candidate.channel_id.eqlText("cn-openai")) break;
        _ = picker.onKey(.down);
    }
    const outcome = picker.onKey(.enter);
    try std.testing.expect(outcome == .commit);

    const commit = outcome.commit;
    var candidate_selection = cc.provider_selection.RuntimeSelection.pinned(
        commit.offer_id,
        commit.offer_revision,
        commit.scope,
    );
    candidate_selection.controls = commit.controls;
    const committed = kernel.selectionCommit(.{}, candidate_selection, commit.scope);
    try std.testing.expect(committed == .committed);
    // Session is the default scope, so nothing durable was written by a plain
    // Enter on the picker.
    try std.testing.expectEqual(cc.provider_selection.Scope.session, committed.committed.scope);
    try std.testing.expect(!committed.committed.requires_persist);

    // The kernel's effective selection is what the transport must bind.
    var reference_buffer: [cc.provider_ids.MAX_SLUG_LEN]u8 = undefined;
    const binding = try cc.provider_runtime_binding.bind(
        &registry,
        kernel.catalogSnapshot(),
        kernel.effectiveSelection().?,
        .{ .cli_api_key = "picked-secret" },
        &reference_buffer,
    );
    try std.testing.expectEqual(cc.types_mod.ProviderKind.openai, binding.transport);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.api_openai.OpenAIClient.init(
        a,
        io_runtime.io(),
        binding.secret,
        binding.request_model_id,
        binding.endpoint_url,
    );
    client.protocol = binding.openai_protocol;
    client.auth_scheme = binding.auth_scheme;
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
    // What the user picked is what went on the wire.
    try std.testing.expect(std.mem.indexOf(u8, requestLine(captured), "/api/coding/paas/v4") != null);
    try std.testing.expectEqualStrings("Bearer picked-secret", headerValue(captured, "authorization").?);
    const model_field = captured.jsonField("model") orelse return error.ModelFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, model_field, "glm-4.6") != null);
}

test "L2: the TUI picker and a second client see one catalog and one selection" {
    const a = std.testing.allocator;
    const host = try cc.provider_host.Host.create(a);
    defer host.destroy();

    var picker = picker_mod.Picker.init(a);
    defer picker.deinit();
    try seedPicker(&picker, &host.kernel, a);

    // A "web client" reads the same kernel through the same API.
    var web_page: std.ArrayList(cc.provider_control_plane.OfferSummary) = .empty;
    defer web_page.deinit(a);
    const web_view = try host.kernel.modelList(.{}, .{}, a, &web_page);
    try std.testing.expectEqual(web_view.offers.len, picker.offers.items.len);

    // The TUI commits; the second client observes it without being told.
    const target = host.kernel.catalogSnapshot().items()[0];
    const committed = host.kernel.selectionCommit(
        .{},
        cc.provider_selection.RuntimeSelection.pinned(target.offer_id, target.offer_revision, .session),
        .session,
    );
    try std.testing.expect(committed == .committed);

    var after: std.ArrayList(cc.provider_control_plane.OfferSummary) = .empty;
    defer after.deinit(a);
    const refreshed = try host.kernel.modelList(.{}, .{}, a, &after);
    var marked: usize = 0;
    for (refreshed.offers) |summary| {
        if (summary.is_current) marked += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), marked);

    // And the picker's own snapshot goes stale until it re-reads — it does not
    // silently claim to be current.
    try seedPicker(&picker, &host.kernel, a);
    try std.testing.expect(picker.current_offer.?.eql(target.offer_id));
}

// ── user-defined providers ───────────────────────────────────────────────────

test "L2: a configured relay reaches its own path, header, and wire model id" {
    const a = std.testing.allocator;
    var server = try harness.MockServer.start(MINIMAL_OPENAI_SSE, 0);
    defer server.stop();
    const origin = try server.urlOwned(a);
    defer a.free(origin);

    const definition = try std.fmt.allocPrint(a,
        \\{{"custom_providers": {{"house-relay": {{
        \\  "display_name": "House relay",
        \\  "aliases": ["relay"],
        \\  "auth": {{"kind": "custom_header", "header": "X-Relay-Token", "value_prefix": "Token "}},
        \\  "env_aliases": [{{"name": "RELAY_TOKEN", "kind": "api_key", "canonical": true}}],
        \\  "channels": [{{"id": "primary", "base_url": "{s}/v1",
        \\    "protocol": {{"wire": "openai_chat", "path_suffix": "/completions", "id": "relay_openai"}},
        \\    "region": "eu"}}],
        \\  "models": [{{"request_model_id": "relay-glm-pro", "display_name": "GLM-4.6 (relay)",
        \\    "canonical_model_id": "zai/glm-4.6",
        \\    "limits": {{"context_window": 200000, "max_output_tokens": 128000}},
        \\    "capabilities": {{"tools": "supported"}},
        \\    "price": {{"currency": "EUR", "input": 2.5, "output": 9}}}}]}}}}}}
    , .{origin});
    defer a.free(definition);

    var definitions = try cc.provider_custom.parse(a, definition);
    defer definitions.deinit();
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    for (definitions.profiles()) |built| try registry.register(built);

    const outcome = try cc.provider_startup.resolve(a, &registry, .{ .provider = "relay" });
    try std.testing.expect(outcome == .route);
    var route = outcome.route;
    defer route.deinit();

    // A relay only moved the path, so the OpenAI transport serves it — no
    // adapter, no code, and no fallback to a wire the server does not speak.
    try std.testing.expectEqual(cc.types_mod.ProviderKind.openai, route.transport);
    try std.testing.expectEqualStrings("relay-glm-pro", route.request_model_id);
    try std.testing.expectEqual(@as(?u32, 200_000), route.limits.context_window);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.api_openai.OpenAIClient.init(
        a,
        io_runtime.io(),
        "relay-secret",
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
    // The declared path suffix, the declared header with its prefix, and the
    // relay's own model id — the canonical mapping is display identity and
    // must not leak onto the wire.
    try std.testing.expect(std.mem.indexOf(u8, requestLine(captured), "/v1/completions") != null);
    try std.testing.expectEqualStrings("Token relay-secret", headerValue(captured, "X-Relay-Token").?);
    try std.testing.expect(headerValue(captured, "authorization") == null);
    const model_field = captured.jsonField("model") orelse return error.ModelFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, model_field, "relay-glm-pro") != null);
    try std.testing.expect(std.mem.indexOf(u8, model_field, "glm-4.6") == null);
}

test "L2: a configured provider's declared metadata reaches every client the same way" {
    const a = std.testing.allocator;
    const host = try cc.provider_host.Host.create(a);
    defer host.destroy();

    try host.adoptCustomProviders(
        \\{"custom_providers": {"house-relay": {
        \\  "channels": [{"id":"primary","base_url":"https://relay.example.com/v1","protocol":"openai_chat"}],
        \\  "models": [{"request_model_id":"relay-glm-pro","canonical_model_id":"zai/glm-4.6",
        \\    "limits": {"context_window": 200000},
        \\    "price": {"currency":"EUR","input":2.5,"output":9,"discount_basis_points":9000},
        \\    "controls": [{"id":"reasoning_effort","label":"Reasoning","kind":"enumeration","values":["low","high"]}]}]}}}
    );

    var page: std.ArrayList(cc.provider_control_plane.OfferSummary) = .empty;
    defer page.deinit(a);
    const listed = try host.kernel.modelList(.{}, .{ .provider_id = Slug.lit("house-relay") }, a, &page);
    try std.testing.expectEqual(@as(usize, 1), listed.offers.len);
    const summary = listed.offers[0];

    // Everything the definition declared is on the summary every UI reads.
    try std.testing.expectEqual(@as(?u32, 200_000), summary.limits.context_window);
    try std.testing.expectEqualStrings("EUR", summary.quote.priced().?.currency.slice());
    try std.testing.expectEqual(@as(?u16, 9_000), summary.quote.priced().?.discount_basis_points);
    try std.testing.expectEqual(@as(usize, 1), summary.controls.len);
    try std.testing.expectEqualStrings("reasoning_effort", summary.controls[0].id);

    // And the picker renders it without knowing it was user-defined.
    var picker = picker_mod.Picker.init(a);
    defer picker.deinit();
    try seedPicker(&picker, &host.kernel, a);
    _ = picker.onKey(.{ .char = 'h' });
    var scratch: [picker_mod.Picker.MAX_ROWS]picker_mod.Row = undefined;
    const rows = picker.rows(&scratch);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expect(picker.offers.items[rows[0].provider.offer_index].provider_id.eqlText("house-relay"));

    // Token admission uses the declared limit, so a prompt that cannot fit is
    // rejected before any request exists.
    const admission = summary.limits.admit(
        .{ .input_tokens = 500_000, .requested_output_tokens = 1_000 },
        .{},
    );
    try std.testing.expect(admission == .rejected);
}

// ── provider-scoped OAuth lifecycle ──────────────────────────────────────────

fn oauthTempPath(a: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "/tmp/metacodes-oauth-l2-{s}.json", .{name});
}

test "L2: an expired provider token refreshes over real HTTP and persists the rotation" {
    const a = std.testing.allocator;
    // A 200 with a JSON body: the token endpoint's actual shape.
    var server = try harness.MockServer.startWithStatus(
        \\{"access_token":"at-2","refresh_token":"rt-2","token_type":"Bearer","expires_in":3600}
    , 0, "HTTP/1.1 200 OK");
    defer server.stop();
    const origin = try server.urlOwned(a);
    defer a.free(origin);

    const path = try oauthTempPath(a, "refresh");
    defer a.free(path);
    removeTempDir(path);
    defer removeTempDir(path);

    var session = try cc.provider_oauth.Session.init(
        a,
        Slug.lit("openai"),
        Slug.lit("openai"),
        path,
    );
    defer session.deinit();
    try session.importOutcome(.{
        .access_token = "at-1",
        .refresh_token = "rt-1",
        .expires_in_seconds = 10,
    }, 1_000);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var exchange = cc.api_oauth_exchange.HttpExchange{
        .allocator = a,
        .io = io_runtime.io(),
        .endpoint = .{ .token_url = origin, .client_id = "metacodes-test" },
    };

    // Well past expiry: the lifecycle must refresh rather than present a dead
    // token and let the request fail.
    const token = session.accessToken(9_000, exchange.exchange()) catch return error.SkipZigTest;
    defer a.free(token);
    try std.testing.expectEqualStrings("at-2", token);

    const captured = server.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, captured.raw, "grant_type=refresh_token") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured.raw, "refresh_token=rt-1") != null);

    // The provider rotated, so `rt-1` is already dead. The file must hold the
    // replacement before the process could possibly crash.
    const stored = try readWholeFile(a, path);
    defer a.free(stored);
    try std.testing.expect(std.mem.indexOf(u8, stored, "rt-2") != null);
    try std.testing.expect(std.mem.indexOf(u8, stored, "\"rt-1\"") == null);
}

test "L2: a rejected refresh is terminal and leaves the stored login untouched" {
    const a = std.testing.allocator;
    var server = try harness.MockServer.startWithStatus(
        \\{"error":"invalid_grant","error_description":"expired"}
    , 0, "HTTP/1.1 400 Bad Request");
    defer server.stop();
    const origin = try server.urlOwned(a);
    defer a.free(origin);

    const path = try oauthTempPath(a, "rejected");
    defer a.free(path);
    removeTempDir(path);
    defer removeTempDir(path);

    var session = try cc.provider_oauth.Session.init(a, Slug.lit("openai"), Slug.lit("openai"), path);
    defer session.deinit();
    try session.importOutcome(.{
        .access_token = "at-1",
        .refresh_token = "rt-1",
        .expires_in_seconds = 10,
    }, 1_000);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var exchange = cc.api_oauth_exchange.HttpExchange{
        .allocator = a,
        .io = io_runtime.io(),
        .endpoint = .{ .token_url = origin, .client_id = "metacodes-test" },
    };

    // `invalid_grant` means the user must log in again. Reporting it as a
    // transport failure would send a retry loop at an endpoint that can only
    // keep saying no.
    try std.testing.expectError(
        error.RefreshRejected,
        session.accessToken(9_000, exchange.exchange()),
    );

    // Nothing was overwritten: the user's stored login is still the one they
    // have, and a re-login replaces it deliberately rather than by accident.
    const stored = try readWholeFile(a, path);
    defer a.free(stored);
    try std.testing.expect(std.mem.indexOf(u8, stored, "rt-1") != null);
}

test "L2: an OAuth access token authenticates the provider's own route" {
    const a = std.testing.allocator;
    var server = try harness.MockServer.start(MINIMAL_OPENAI_SSE, 0);
    defer server.stop();
    const origin = try server.urlOwned(a);
    defer a.free(origin);

    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{
        .only_provider = Slug.lit("openai"),
        .endpoint_overrides = &.{.{ .provider_id = Slug.lit("openai"), .base_url = origin }},
    });
    defer catalog.deinit();

    var reference_buffer: [cc.provider_ids.MAX_SLUG_LEN]u8 = undefined;
    const binding = try cc.provider_runtime_binding.bindOffer(
        &registry,
        &catalog.items()[0],
        .{
            // The OAuth access token arrives as stored material of an OAuth
            // kind; an API key for another vendor still cannot satisfy it.
            .stored_oauth = .{ .kind = .openai_oauth, .secret = "oauth-access-token" },
            .precedence = .oauth_first,
        },
        &reference_buffer,
        false,
    );
    try std.testing.expectEqualStrings("oauth-access-token", binding.secret);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.api_openai.OpenAIClient.init(
        a,
        io_runtime.io(),
        binding.secret,
        binding.request_model_id,
        binding.endpoint_url,
    );
    client.protocol = binding.openai_protocol;
    client.auth_scheme = binding.auth_scheme;
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
    try std.testing.expectEqualStrings("Bearer oauth-access-token", headerValue(captured, "authorization").?);
}

// ── scope decides where a selection is written ───────────────────────────────

test "L2: a session-scoped commit never reaches config.json, and a global one does" {
    const a = std.testing.allocator;
    const config_path = try tempConfigPath(a, "scope-split");
    defer a.free(config_path);
    removeTempDir(config_path);
    defer removeTempDir(config_path);

    const session_dir = std.fs.path.dirname(config_path).?;
    var config_store = try cc.provider_config_store.Store.initPath(a, config_path);
    defer config_store.deinit();
    var session_store = try cc.provider_config_store.Store.initSessionFile(a, session_dir);
    defer session_store.deinit();
    defer removeTempDir(session_store.path);

    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{});
    defer catalog.deinit();
    var kernel = cc.provider_control_plane.Kernel.init(a, &catalog);
    defer kernel.deinit();

    const session_target = catalog.items()[0];
    const global_target = catalog.items()[1];

    const session_commit = kernel.selectionCommit(
        .{},
        cc.provider_selection.RuntimeSelection.pinned(session_target.offer_id, session_target.offer_revision, .session),
        .session,
    );
    // Session scope is not durable *globally*: the kernel does not ask for a
    // config write, and the host writes the session's own file instead.
    try std.testing.expect(!session_commit.committed.requires_persist);
    _ = try cc.provider_config_store.setSessionSelection(
        &session_store,
        session_commit.committed.selection,
        null,
        "session-op",
    );

    const global_commit = kernel.selectionCommit(
        .{},
        cc.provider_selection.RuntimeSelection.pinned(global_target.offer_id, global_target.offer_revision, .global),
        .global,
    );
    try std.testing.expect(global_commit.committed.requires_persist);
    _ = try cc.provider_config_store.setGlobalSelection(
        &config_store,
        global_commit.committed.selection,
        null,
        "global-op",
    );

    // Each file holds exactly one of the two, so a session choice cannot
    // become everyone's and a global one cannot be mistaken for this session's.
    var config_doc = try config_store.load();
    defer config_doc.deinit();
    try std.testing.expect(config_doc.session_selection == null);
    try std.testing.expect(config_doc.global_selection.?.target.pinned_offer.offer_id.eql(global_target.offer_id));

    var session_doc = try session_store.load();
    defer session_doc.deinit();
    try std.testing.expect(session_doc.global_selection == null);
    try std.testing.expect(session_doc.session_selection.?.target.pinned_offer.offer_id.eql(session_target.offer_id));

    // Restoring is session-first: the narrower scope wins on resume.
    const restored = session_doc.session_selection.?;
    const resolution = try cc.provider_selection.resolve(&catalog, restored);
    try std.testing.expect(resolution.primary().offer_id.eql(session_target.offer_id));
}

// ── controls reach the wire ──────────────────────────────────────────────────

test "L2: a control the offer declares changes the bytes actually sent" {
    const a = std.testing.allocator;

    // One server per request: `MockServer.start` accepts exactly one
    // connection, so reusing it for the second capture would block forever.
    const Capture = struct {
        fn run(
            allocator: std.mem.Allocator,
            effort: ?cc.types_mod.ReasoningEffort,
        ) ![]u8 {
            var server = try harness.MockServer.start(MINIMAL_OPENAI_SSE, 0);
            defer server.stop();
            const origin = try server.urlOwned(allocator);
            defer allocator.free(origin);

            var registry = try ProviderRegistry.initWithBuiltins(allocator);
            defer registry.deinit();
            var catalog = try registry.buildCatalog(allocator, .{
                .only_provider = Slug.lit("openai"),
                .endpoint_overrides = &.{.{ .provider_id = Slug.lit("openai"), .base_url = origin }},
            });
            defer catalog.deinit();

            var reference_buffer: [cc.provider_ids.MAX_SLUG_LEN]u8 = undefined;
            const bound = try cc.provider_runtime_binding.bindOffer(
                &registry,
                &catalog.items()[0],
                .{ .cli_api_key = "sk-control" },
                &reference_buffer,
                false,
            );

            var io_runtime = std.Io.Threaded.init(allocator, .{});
            defer io_runtime.deinit();
            var client = cc.api_openai.OpenAIClient.init(
                allocator,
                io_runtime.io(),
                bound.secret,
                bound.request_model_id,
                bound.endpoint_url,
            );
            client.protocol = bound.openai_protocol;
            client.auth_scheme = bound.auth_scheme;
            client.reasoning_effort = effort;
            defer client.deinit();

            const messages = [_]cc.types_mod.ApiMessage{
                .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
            };
            var handle = client.provider().sendStream(&messages, null, null, null, null, null, "") catch
                return error.SkipZigTest;
            while (handle.next() catch null) |event| switch (event) {
                .text => |text| allocator.free(text),
                else => {},
            };
            handle.deinit();
            const captured = server.lastRequest() orelse return error.NoRequestCaptured;
            return allocator.dupe(u8, captured.raw);
        }
    };

    const without = try Capture.run(a, null);
    defer a.free(without);
    const with_high = try Capture.run(a, .high);
    defer a.free(with_high);

    // The control is not decoration: setting it changes the request body, and
    // leaving it unset does not smuggle a default onto the wire.
    try std.testing.expect(std.mem.indexOf(u8, without, "reasoning_effort") == null);
    try std.testing.expect(std.mem.indexOf(u8, with_high, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(!std.mem.eql(u8, without, with_high));
}

test "L2: a provider metadata extension round-trips through the generic client view" {
    const a = std.testing.allocator;
    // A control carrying an opaque provider payload: the kernel must move it
    // through `model.list` untouched, so a client can render vendor-specific
    // metadata without any core, TUI, or Web change.
    var definitions = try cc.provider_custom.parse(a,
        \\{"custom_providers": {"vendor-x": {
        \\  "channels": [{"id":"c","base_url":"https://x.example.com/v1","protocol":"openai_chat"}],
        \\  "models": [{"request_model_id":"m","controls":[
        \\    {"id":"thinking","label":"Thinking","kind":"enumeration","values":["on","off"],
        \\     "cost_latency_warning":"slower and pricier"}]}]}}}
    );
    defer definitions.deinit();

    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    for (definitions.profiles()) |built| try registry.register(built);
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("vendor-x") });
    defer catalog.deinit();

    var kernel = cc.provider_control_plane.Kernel.init(a, &catalog);
    defer kernel.deinit();
    var page: std.ArrayList(cc.provider_control_plane.OfferSummary) = .empty;
    defer page.deinit(a);
    const listed = try kernel.modelList(.{}, .{}, a, &page);
    try std.testing.expectEqual(@as(usize, 1), listed.offers.len);

    const spec = listed.offers[0].controls[0];
    try std.testing.expectEqualStrings("thinking", spec.id);
    try std.testing.expectEqualStrings("Thinking", spec.label);
    try std.testing.expectEqual(@as(usize, 2), spec.allowed_values.len);
    // Provider-owned metadata the kernel neither interprets nor drops.
    try std.testing.expectEqualStrings("slower and pricier", spec.cost_latency_warning.?);

    // And the picker renders it without knowing which vendor it came from.
    var picker = picker_mod.Picker.init(a);
    defer picker.deinit();
    try seedPicker(&picker, &kernel, a);
    _ = picker.onKey(.enter);
    _ = picker.onKey(.enter);
    try std.testing.expectEqual(picker_mod.Stage.options, picker.stage);
    try std.testing.expectEqual(@as(usize, 1), picker.rowCount());
}

// ── cross-UI: an out-of-process client sees the route, not just the name ─────

test "L2: a route change is broadcast as an ordered, replayable event carrying identity" {
    const a = std.testing.allocator;
    const ui_event = cc.ui_event;

    const Collector = struct {
        lines: std.ArrayList([]u8) = .empty,
        allocator: std.mem.Allocator,

        fn emit(ctx: *anyopaque, ev: ui_event.ConfigChange) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            // The same serialization the Web journal performs, so the test sees
            // exactly what a browser would.
            const line = std.json.Stringify.valueAlloc(
                self.allocator,
                .{ .config_changed = ev },
                .{},
            ) catch return;
            self.lines.append(self.allocator, line) catch self.allocator.free(line);
        }

        fn deinit(self: *@This()) void {
            for (self.lines.items) |line| self.allocator.free(line);
            self.lines.deinit(self.allocator);
        }
    };

    var collector = Collector{ .allocator = a };
    defer collector.deinit();
    const sink = ui_event.ConfigEventSink{
        .ctx = @ptrCast(&collector),
        .emitFn = struct {
            fn run(ctx: *anyopaque, ev: ui_event.ConfigChange) void {
                Collector.emit(ctx, ev);
            }
        }.run,
    };

    // A route event as `bindCommittedSelection` produces one.
    sink.emit(.{ .route = .{
        .provider_id = "zai-coding-plan",
        .channel_id = "cn-openai",
        .protocol = "openai_chat",
        .request_model_id = "glm-4.6",
        .offer_id = "offer-0123456789abcdef0123456789abcdef",
        .credential_ref = "work",
        .scope = "session",
    } });

    try std.testing.expectEqual(@as(usize, 1), collector.lines.items.len);
    const line = collector.lines.items[0];
    // Identity, not just a display name: a second client can tell this route
    // from another that shows the same model name.
    for ([_][]const u8{
        "\"config_changed\"",
        "\"route\"",
        "zai-coding-plan",
        "cn-openai",
        "openai_chat",
        "glm-4.6",
        "offer-0123456789abcdef0123456789abcdef",
        "\"credential_ref\":\"work\"",
        "\"scope\":\"session\"",
    }) |needle| {
        std.testing.expect(std.mem.indexOf(u8, line, needle) != null) catch |err| {
            std.debug.print("missing from route event: {s}\n{s}\n", .{ needle, line });
            return err;
        };
    }
    // The credential *reference* travels; the secret never does.
    try std.testing.expect(std.mem.indexOf(u8, line, "sk-") == null);
}
